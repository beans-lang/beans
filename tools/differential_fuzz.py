#!/usr/bin/env python3
"""Semantic differential fuzzer for Beans.

Generates deterministic, valid, terminating Beans programs from a typed
program model, computes each program's expected output with an independent
evaluator written here, and compares that expectation against every
implementation lane: both interpreters, and native binaries from both
compilers in debug, release and LTO configurations.

The generator only emits constructs whose semantics the evaluator models
exactly (two's-complement wrapping integer math, C-style truncating
division guarded against zero divisors, masked shift counts, byte-based
ASCII string operations, value-copy structs, tagged enums). Every case is
reproducible from (seed, case): the same pair produces byte-identical
source on every host, so a corpus generated on one OS is directly
comparable on another.

Failures are saved under build/differential-fuzz/failures/<seed>-<case>/
with the program, the expected output, and every lane's stdout, stderr,
exit status and exact command. A structural reducer shrinks a failing
case while re-checking the failure after each candidate edit.

Python 3 standard library only.
"""

import argparse
import copy
import hashlib
import json
import os
import platform
import random
import shlex
import shutil
import subprocess
import sys
import time

GENERATOR_VERSION = "1"

# ---------------------------------------------------------------------------
# types

INT_TYPES = {
    # name: (bits, signed)
    "int": (64, True),
    "i8": (8, True),
    "i16": (16, True),
    "i32": (32, True),
    "i64": (64, True),
    "u8": (8, False),
    "u16": (16, False),
    "u32": (32, False),
    "u64": (64, False),
}

BOOL = "bool"
STR = "string"


def is_int_type(t):
    return t in INT_TYPES


def norm_int(t, v):
    """Wrap v to the two's-complement value set of integer type t."""
    bits, signed = INT_TYPES[t]
    v &= (1 << bits) - 1
    if signed and v >= (1 << (bits - 1)):
        v -= 1 << bits
    return v


def int_range(t):
    bits, signed = INT_TYPES[t]
    if signed:
        return -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return 0, (1 << bits) - 1


class StructType:
    def __init__(self, name, fields):
        self.name = name
        self.fields = fields  # list of (field_name, type)

    def field_type(self, fname):
        for n, t in self.fields:
            if n == fname:
                return t
        raise KeyError(fname)


class EnumType:
    def __init__(self, name, variants):
        self.name = name
        # list of (variant_name, [payload types]); [] means plain
        self.variants = variants


# ---------------------------------------------------------------------------
# oracle values

class StructVal:
    __slots__ = ("type_name", "fields")

    def __init__(self, type_name, fields):
        self.type_name = type_name
        self.fields = fields  # dict name -> value

    def copy(self):
        return StructVal(
            self.type_name,
            {k: (v.copy() if isinstance(v, StructVal) else v)
             for k, v in self.fields.items()})


class EnumVal:
    __slots__ = ("type_name", "variant", "payload")

    def __init__(self, type_name, variant, payload):
        self.type_name = type_name
        self.variant = variant
        self.payload = tuple(payload)

    def __eq__(self, other):
        return (isinstance(other, EnumVal)
                and self.type_name == other.type_name
                and self.variant == other.variant
                and self.payload == other.payload)


def copy_value(v):
    return v.copy() if isinstance(v, StructVal) else v


def show_value(v):
    """Render a value the way io.println / interpolation renders it."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return v
    if isinstance(v, EnumVal):
        if not v.payload:
            return v.variant
        inner = ", ".join(show_value(p) for p in v.payload)
        return "{}({})".format(v.variant, inner)
    raise OracleUnsupported("unprintable value {!r}".format(v))


class OracleUnsupported(Exception):
    """The oracle cannot give this program a defined meaning (a reducer
    edit introduced a panic, or evaluation exceeded its fuel)."""


# ---------------------------------------------------------------------------
# AST — expressions
#
# Each node carries emit() (Beans source) and eval() (oracle semantics).
# eval() here is a method on our own AST model — Python's builtin eval()
# is never used anywhere in this tool.

class Expr:
    type = None

    def children(self):
        return []

    def replace_child(self, i, new):
        raise NotImplementedError


class IntLit(Expr):
    def __init__(self, t, value):
        self.type = t
        self.value = norm_int(t, value)

    def emit(self):
        # Literal demand does not flow through every expression position
        # (if-value branches, shift operands, payload arguments), and the
        # two checkers do not draw that line identically. Sized literals
        # are therefore always spelled as a cast from a plain int, which
        # both checkers type the same way in any position.
        v = self.value
        if self.type != "int":
            bits, signed = INT_TYPES[self.type]
            if not signed and v > (1 << 63) - 1:
                v -= 1 << 64  # same bit pattern, signed spelling
        if v == -(1 << 63):
            # the most negative value has no literal spelling: its
            # positive half is out of range before unary minus applies
            inner = "(-9223372036854775807 - 1)"
        elif v < 0:
            inner = "(-{})".format(-v)
        else:
            inner = str(v)
        if self.type == "int":
            return inner
        return "({} as {})".format(inner, self.type)

    def eval(self, env):
        return self.value


class BoolLit(Expr):
    type = BOOL

    def __init__(self, value):
        self.value = value

    def emit(self):
        return "true" if self.value else "false"

    def eval(self, env):
        return self.value


class StrLit(Expr):
    type = STR

    def __init__(self, value):
        self.value = value  # ASCII, no quotes/braces/backslashes

    def emit(self):
        return '"{}"'.format(self.value)

    def eval(self, env):
        return self.value


class VarRef(Expr):
    def __init__(self, name, t):
        self.name = name
        self.type = t

    def emit(self):
        return self.name

    def eval(self, env):
        return copy_value(env.lookup(self.name))


class Unary(Expr):
    def __init__(self, op, e):
        self.op = op  # '-', '!', '~'
        self.e = e
        self.type = e.type

    def children(self):
        return [self.e]

    def replace_child(self, i, new):
        self.e = new

    def emit(self):
        return "({}{})".format(self.op, self.e.emit())

    def eval(self, env):
        v = self.e.eval(env)
        if self.op == "!":
            return not v
        if self.op == "-":
            return norm_int(self.type, -v)
        if self.op == "~":
            return norm_int(self.type, ~v)
        raise AssertionError(self.op)


ARITH_OPS = ("+", "-", "*", "&", "|", "^", "<<", ">>")
CMP_OPS = ("==", "!=", "<", "<=", ">", ">=")


class Binary(Expr):
    def __init__(self, op, l, r, t):
        self.op = op
        self.l = l
        self.r = r
        self.type = t

    def children(self):
        return [self.l, self.r]

    def replace_child(self, i, new):
        if i == 0:
            self.l = new
        else:
            self.r = new

    def emit(self):
        return "({} {} {})".format(self.l.emit(), self.op, self.r.emit())

    def eval(self, env):
        op = self.op
        if op == "&&":
            return self.l.eval(env) and self.r.eval(env)
        if op == "||":
            return self.l.eval(env) or self.r.eval(env)
        a = self.l.eval(env)
        b = self.r.eval(env)
        if op == "==":
            return a == b
        if op == "!=":
            return a != b
        if op == "<":
            return a < b
        if op == "<=":
            return a <= b
        if op == ">":
            return a > b
        if op == ">=":
            return a >= b
        t = self.type
        if op == "+":
            return norm_int(t, a + b)
        if op == "-":
            return norm_int(t, a - b)
        if op == "*":
            return norm_int(t, a * b)
        if op == "&":
            return norm_int(t, a & b)
        if op == "|":
            return norm_int(t, a | b)
        if op == "^":
            return norm_int(t, a ^ b)
        if op in ("<<", ">>"):
            bits, signed = INT_TYPES[t]
            count = b & (bits - 1)
            if op == "<<":
                return norm_int(t, a << count)
            if signed:
                return norm_int(t, a >> count)  # Python >> floors = arithmetic
            return norm_int(t, (a & ((1 << bits) - 1)) >> count)
        if op == "/":
            if b == 0:
                raise OracleUnsupported("division by zero reached the oracle")
            q = abs(a) // abs(b)
            if (a < 0) != (b < 0):
                q = -q
            return norm_int(t, q)
        if op == "%":
            if b == 0:
                raise OracleUnsupported("modulo by zero reached the oracle")
            q = abs(a) // abs(b)
            if (a < 0) != (b < 0):
                q = -q
            return norm_int(t, a - q * b)
        raise AssertionError(op)


class Cast(Expr):
    def __init__(self, e, to):
        self.e = e
        self.type = to

    def children(self):
        return [self.e]

    def replace_child(self, i, new):
        self.e = new

    def emit(self):
        return "({} as {})".format(self.e.emit(), self.type)

    def eval(self, env):
        return norm_int(self.type, self.e.eval(env))


class Call(Expr):
    def __init__(self, fn, args):
        self.fn = fn  # FnDecl
        self.args = args
        self.type = fn.ret

    def children(self):
        return list(self.args)

    def replace_child(self, i, new):
        self.args[i] = new

    def emit(self):
        return "{}({})".format(self.fn.name,
                               ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        vals = [a.eval(env) for a in self.args]
        # resolve by name: reducer edits clone subtrees, and a cloned
        # FnDecl must not shadow the program's registered one
        return env.interp.call_by_name(self.fn.name, vals)


class FieldGet(Expr):
    def __init__(self, base, field, t):
        self.base = base
        self.field = field
        self.type = t

    def children(self):
        return [self.base]

    def replace_child(self, i, new):
        self.base = new

    def emit(self):
        return "{}.{}".format(self.base.emit(), self.field)

    def eval(self, env):
        return copy_value(self.base.eval(env).fields[self.field])


class StructLit(Expr):
    def __init__(self, struct, values):
        self.struct = struct  # StructType
        self.values = values  # list aligned with struct.fields
        self.type = struct.name

    def children(self):
        return list(self.values)

    def replace_child(self, i, new):
        self.values[i] = new

    def emit(self):
        parts = ["{}: {}".format(n, v.emit())
                 for (n, _), v in zip(self.struct.fields, self.values)]
        return "{} {{ {} }}".format(self.struct.name, ", ".join(parts))

    def eval(self, env):
        return StructVal(
            self.struct.name,
            {n: v.eval(env)
             for (n, _), v in zip(self.struct.fields, self.values)})


class EnumLit(Expr):
    def __init__(self, enum, variant, args):
        self.enum = enum  # EnumType
        self.variant = variant
        self.args = args
        self.type = enum.name

    def children(self):
        return list(self.args)

    def replace_child(self, i, new):
        self.args[i] = new

    def emit(self):
        if not self.args:
            return "{}.{}".format(self.enum.name, self.variant)
        return "{}.{}({})".format(self.enum.name, self.variant,
                                  ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        return EnumVal(self.enum.name, self.variant,
                       [a.eval(env) for a in self.args])


class StrMethod(Expr):
    SIGS = {
        # name: (result type, [arg types])
        "len": ("int", []),
        "is_empty": (BOOL, []),
        "contains": (BOOL, [STR]),
        "starts_with": (BOOL, [STR]),
        "ends_with": (BOOL, [STR]),
        "to_upper": (STR, []),
        "to_lower": (STR, []),
        "trim": (STR, []),
        "repeat": (STR, ["int"]),
        "replace": (STR, [STR, STR]),
    }

    def __init__(self, recv, name, args):
        self.recv = recv
        self.name = name
        self.args = args
        self.type = self.SIGS[name][0]

    def children(self):
        return [self.recv] + list(self.args)

    def replace_child(self, i, new):
        if i == 0:
            self.recv = new
        else:
            self.args[i - 1] = new

    def emit(self):
        return "{}.{}({})".format(self.recv.emit(), self.name,
                                  ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        s = self.recv.eval(env)
        args = [a.eval(env) for a in self.args]
        n = self.name
        if n == "len":
            return len(s)
        if n == "is_empty":
            return len(s) == 0
        if n == "contains":
            return args[0] in s
        if n == "starts_with":
            return s.startswith(args[0])
        if n == "ends_with":
            return s.endswith(args[0])
        if n == "to_upper":
            return s.upper()
        if n == "to_lower":
            return s.lower()
        if n == "trim":
            return s.strip(" \t\r\n")
        if n == "repeat":
            if args[0] < 0:
                raise OracleUnsupported("repeat on a negative count")
            return s * args[0]
        if n == "replace":
            if args[0] == "":
                return s  # empty `old` changes nothing
            return s.replace(args[0], args[1])
        raise AssertionError(n)


class IfValue(Expr):
    def __init__(self, cond, then_e, else_e):
        self.cond = cond
        self.then_e = then_e
        self.else_e = else_e
        self.type = then_e.type

    def children(self):
        return [self.cond, self.then_e, self.else_e]

    def replace_child(self, i, new):
        if i == 0:
            self.cond = new
        elif i == 1:
            self.then_e = new
        else:
            self.else_e = new

    def emit(self):
        return "(if {} {{ {} }} else {{ {} }})".format(
            self.cond.emit(), self.then_e.emit(), self.else_e.emit())

    def eval(self, env):
        if self.cond.eval(env):
            return self.then_e.eval(env)
        return self.else_e.eval(env)


class MatchIntValue(Expr):
    """match on an int scrutinee: literal / a | b / lo..=hi arms, then _."""

    def __init__(self, scrut, arms, default):
        self.scrut = scrut
        self.arms = arms  # list of (pattern, Expr); pattern below
        self.default = default
        self.type = default.type

    def children(self):
        return [self.scrut] + [e for _, e in self.arms] + [self.default]

    def replace_child(self, i, new):
        if i == 0:
            self.scrut = new
        elif i - 1 < len(self.arms):
            p, _ = self.arms[i - 1]
            self.arms[i - 1] = (p, new)
        else:
            self.default = new

    @staticmethod
    def emit_pattern(pat):
        kind = pat[0]
        if kind == "lit":
            return str(pat[1])
        if kind == "or":
            return " | ".join(str(v) for v in pat[1])
        if kind == "range":
            return "{}..={}".format(pat[1], pat[2])
        raise AssertionError(pat)

    @staticmethod
    def pattern_matches(pat, v):
        kind = pat[0]
        if kind == "lit":
            return v == pat[1]
        if kind == "or":
            return v in pat[1]
        if kind == "range":
            return pat[1] <= v <= pat[2]
        raise AssertionError(pat)

    def emit(self):
        arms = ["        {} => {},".format(self.emit_pattern(p), e.emit())
                for p, e in self.arms]
        arms.append("        _ => {},".format(self.default.emit()))
        return "(match {} {{\n{}\n    }})".format(
            self.scrut.emit(), "\n".join(arms))

    def eval(self, env):
        v = self.scrut.eval(env)
        for p, e in self.arms:
            if self.pattern_matches(p, v):
                return e.eval(env)
        return self.default.eval(env)


class MatchEnumValue(Expr):
    """match on an enum scrutinee; one arm per variant, payloads bound."""

    def __init__(self, scrut, enum, arms, t):
        self.scrut = scrut
        self.enum = enum
        # arms: list of (variant_name, [binding names], Expr)
        self.arms = arms
        self.type = t

    def children(self):
        return [self.scrut] + [e for _, _, e in self.arms]

    def replace_child(self, i, new):
        if i == 0:
            self.scrut = new
        else:
            v, b, _ = self.arms[i - 1]
            self.arms[i - 1] = (v, b, new)

    def emit(self):
        out = []
        for variant, bindings, e in self.arms:
            pat = variant if not bindings else "{}({})".format(
                variant, ", ".join(bindings))
            out.append("        {} => {},".format(pat, e.emit()))
        return "(match {} {{\n{}\n    }})".format(
            self.scrut.emit(), "\n".join(out))

    def eval(self, env):
        v = self.scrut.eval(env)
        for variant, bindings, e in self.arms:
            if v.variant == variant:
                env.push()
                for name, pv in zip(bindings, v.payload):
                    env.declare(name, pv)
                try:
                    return e.eval(env)
                finally:
                    env.pop()
        raise OracleUnsupported("enum match fell through")


# ---------------------------------------------------------------------------
# AST — statements

class Stmt:
    pass


class Let(Stmt):
    def __init__(self, name, t, init, mutable):
        self.name = name
        self.type = t
        self.init = init
        self.mutable = mutable

    def emit(self, ind):
        kw = "var" if self.mutable else "let"
        return ["{}{} {}: {} = {}".format(ind, kw, self.name, self.type,
                                          self.init.emit())]

    def exec(self, env):
        env.declare(self.name, self.init.eval(env))


class Assign(Stmt):
    def __init__(self, name, expr, op="="):
        self.name = name
        self.expr = expr
        self.op = op  # '=', '+=', '-=', '*=' ('/=' and '%=' can trap)

    def emit(self, ind):
        return ["{}{} {} {}".format(ind, self.name, self.op,
                                    self.expr.emit())]

    def exec(self, env):
        v = self.expr.eval(env)
        if self.op != "=":
            old = env.lookup(self.name)
            t = self.expr.type
            v = Binary(self.op[0], IntLit(t, old), IntLit(t, v), t).eval(env)
        env.assign(self.name, v)


class FieldAssign(Stmt):
    """local.field = expr — one level only; both checkers accept that."""

    def __init__(self, name, field, expr):
        self.name = name
        self.field = field
        self.expr = expr

    def emit(self, ind):
        return ["{}{}.{} = {}".format(ind, self.name, self.field,
                                      self.expr.emit())]

    def exec(self, env):
        env.lookup(self.name).fields[self.field] = self.expr.eval(env)


class Print(Stmt):
    def __init__(self, parts):
        # parts: list of ('lit', text) / ('expr', Expr)
        self.parts = parts

    def emit(self, ind):
        buf = []
        for kind, p in self.parts:
            if kind == "lit":
                buf.append(p)
            else:
                buf.append("{" + p.emit() + "}")
        return ['{}io.println("{}")'.format(ind, "".join(buf))]

    def exec(self, env):
        buf = []
        for kind, p in self.parts:
            if kind == "lit":
                buf.append(p)
            else:
                buf.append(show_value(p.eval(env)))
        env.interp.out.append("".join(buf))


class If(Stmt):
    def __init__(self, cond, then_body, else_body):
        self.cond = cond
        self.then_body = then_body
        self.else_body = else_body  # may be None

    def emit(self, ind):
        out = ["{}if {} {{".format(ind, self.cond.emit())]
        for s in self.then_body:
            out.extend(s.emit(ind + "    "))
        if self.else_body is not None:
            out.append(ind + "} else {")
            for s in self.else_body:
                out.extend(s.emit(ind + "    "))
        out.append(ind + "}")
        return out

    def exec(self, env):
        if self.cond.eval(env):
            env.interp.run_block(self.then_body, env)
        elif self.else_body is not None:
            env.interp.run_block(self.else_body, env)


class ForRange(Stmt):
    def __init__(self, var, lo, hi, inclusive, body):
        self.var = var
        self.lo = lo  # int literal value
        self.hi = hi
        self.inclusive = inclusive
        self.body = body

    def emit(self, ind):
        dots = "..=" if self.inclusive else ".."
        out = ["{}for {}: int in {}{}{} {{".format(
            ind, self.var, self.lo, dots, self.hi)]
        for s in self.body:
            out.extend(s.emit(ind + "    "))
        out.append(ind + "}")
        return out

    def exec(self, env):
        hi = self.hi + 1 if self.inclusive else self.hi
        for i in range(self.lo, hi):
            env.push()
            env.declare(self.var, i)
            try:
                env.interp.run_block(self.body, env)
            except ContinueLoop:
                pass
            except BreakLoop:
                env.pop()
                break
            else:
                env.pop()
                continue
            env.pop()


class Break(Stmt):
    def emit(self, ind):
        return [ind + "break"]

    def exec(self, env):
        raise BreakLoop()


class Continue(Stmt):
    def emit(self, ind):
        return [ind + "continue"]

    def exec(self, env):
        raise ContinueLoop()


class Return(Stmt):
    def __init__(self, expr):
        self.expr = expr  # None for bare return

    def emit(self, ind):
        if self.expr is None:
            return [ind + "return"]
        return ["{}return {}".format(ind, self.expr.emit())]

    def exec(self, env):
        raise ReturnValue(None if self.expr is None
                          else self.expr.eval(env))


class MatchEnumStmt(Stmt):
    """Statement match over an enum with block arms."""

    def __init__(self, scrut, enum, arms):
        self.scrut = scrut
        self.enum = enum
        self.arms = arms  # list of (variant, [bindings], [stmts])

    def emit(self, ind):
        out = ["{}match {} {{".format(ind, self.scrut.emit())]
        for variant, bindings, body in self.arms:
            pat = variant if not bindings else "{}({})".format(
                variant, ", ".join(bindings))
            out.append("{}    {} => {{".format(ind, pat))
            for s in body:
                out.extend(s.emit(ind + "        "))
            out.append(ind + "    }")
        out.append(ind + "}")
        return out

    def exec(self, env):
        v = self.scrut.eval(env)
        for variant, bindings, body in self.arms:
            if v.variant == variant:
                env.push()
                for name, pv in zip(bindings, v.payload):
                    env.declare(name, pv)
                try:
                    env.interp.run_block(body, env)
                finally:
                    env.pop()
                return
        raise OracleUnsupported("enum match fell through")


class Exit(Stmt):
    def __init__(self, code):
        self.code = code

    def emit(self, ind):
        return ["{}os.exit({})".format(ind, self.code)]

    def exec(self, env):
        raise ProgramExit(self.code)


# ---------------------------------------------------------------------------
# declarations and the program

class FnDecl:
    def __init__(self, name, params, ret, body):
        self.name = name
        self.params = params  # list of (name, type)
        self.ret = ret        # type name or None
        self.body = body

    def emit(self):
        sig = ", ".join("{}: {}".format(n, t) for n, t in self.params)
        head = "fn {}({})".format(self.name, sig)
        if self.ret is not None:
            head += " -> {}".format(self.ret)
        out = [head + " {"]
        for s in self.body:
            out.extend(s.emit("    "))
        out.append("}")
        return out


class Program:
    def __init__(self):
        self.structs = []   # StructType
        self.enums = []     # EnumType
        self.fns = []       # FnDecl, callable helpers in definition order
        self.main = []      # statements
        self.uses_os = False

    def emit(self):
        out = ["import std.io"]
        if self.uses_os:
            out.append("import std.os")
        out.append("")
        for st in self.structs:
            out.append("struct {} {{".format(st.name))
            for n, t in st.fields:
                out.append("    {}: {}".format(n, t))
            out.append("}")
            out.append("")
        for en in self.enums:
            out.append("enum {} {{".format(en.name))
            for v, payload in en.variants:
                if payload:
                    args = ", ".join("p{}: {}".format(i, t)
                                     for i, t in enumerate(payload))
                    out.append("    {}({})".format(v, args))
                else:
                    out.append("    " + v)
            out.append("}")
            out.append("")
        for fn in self.fns:
            out.extend(fn.emit())
            out.append("")
        out.append("fn main() {")
        for s in self.main:
            out.extend(s.emit("    "))
        out.append("}")
        return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# oracle interpreter

class BreakLoop(Exception):
    pass


class ContinueLoop(Exception):
    pass


class ReturnValue(Exception):
    def __init__(self, value):
        self.value = value


class ProgramExit(Exception):
    def __init__(self, code):
        self.code = code


class Env:
    def __init__(self, interp):
        self.interp = interp
        self.scopes = [{}]

    def push(self):
        self.scopes.append({})

    def pop(self):
        self.scopes.pop()

    def declare(self, name, value):
        self.scopes[-1][name] = value

    def lookup(self, name):
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        raise OracleUnsupported("unbound name " + name)

    def assign(self, name, value):
        for scope in reversed(self.scopes):
            if name in scope:
                scope[name] = value
                return
        raise OracleUnsupported("assign to unbound name " + name)


class Oracle:
    FUEL = 2_000_000

    def __init__(self, program, sabotage=None):
        self.program = program
        self.fns = {fn.name: fn for fn in program.fns}
        self.out = []
        self.fuel = self.FUEL
        self.sabotage = sabotage

    def burn(self):
        self.fuel -= 1
        if self.fuel <= 0:
            raise OracleUnsupported("evaluation fuel exhausted")

    def run_block(self, stmts, env):
        for s in stmts:
            self.burn()
            s.exec(env)

    def call_by_name(self, name, args):
        self.burn()
        fn = self.fns.get(name)
        if fn is None:
            raise OracleUnsupported("call to a removed function " + name)
        env = Env(self)
        for (pname, _), v in zip(fn.params, args):
            env.declare(pname, v)
        try:
            self.run_block(fn.body, env)
        except ReturnValue as r:
            return r.value
        if fn.ret is not None:
            raise OracleUnsupported(
                "function {} finished without a return".format(fn.name))
        return None

    def run(self):
        """Returns (stdout_text, exit_code)."""
        env = Env(self)
        if self.sabotage:
            apply_sabotage(self, self.sabotage)
        code = 0
        try:
            self.run_block(self.program.main, env)
        except ProgramExit as e:
            code = e.code
        text = "".join(line + "\n" for line in self.out)
        return text, code


def apply_sabotage(oracle, mode):
    """Deliberately wrong evaluation, for testing the detection and
    reduction machinery against real lanes. Never used while fuzzing."""
    if mode == "flip-gt":
        orig = Binary.eval

        def wrong(self, env):
            if self.op == ">":
                a = self.l.eval(env)
                b = self.r.eval(env)
                return a >= b
            return orig(self, env)
        # patch bound per-oracle by tagging: simplest is a module-level flag,
        # but that would leak across runs; instead swap the method on the
        # class for the duration of this oracle run only. Runs are
        # sequential within one process, so this is safe.
        oracle._saved_binary_eval = orig
        Binary.eval = wrong
    else:
        raise SystemExit("unknown sabotage mode: " + mode)


def oracle_expected(program, sabotage=None):
    """(stdout, exit) or None when the program has no defined meaning."""
    oracle = Oracle(program, sabotage)
    try:
        return oracle.run()
    except OracleUnsupported:
        return None
    finally:
        if getattr(oracle, "_saved_binary_eval", None):
            Binary.eval = oracle._saved_binary_eval


# ---------------------------------------------------------------------------
# generator

GROUPS = ("core", "widths", "strings", "structs", "enums")

STR_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789 _-"


class Scope:
    def __init__(self, parent=None):
        self.parent = parent
        self.vars = []  # (name, type, mutable)

    def all_vars(self):
        out = []
        s = self
        while s is not None:
            out.extend(s.vars)
            s = s.parent
        return out


class Gen:
    def __init__(self, seed, case, groups, max_depth=4, max_stmts=12):
        self.rng = random.Random(1_000_003 * seed + case)
        self.groups = set(groups)
        self.max_depth = max_depth
        self.max_stmts = max_stmts
        self.prog = Program()
        self.counter = 0
        self.loop_depth = 0
        self.in_while = 0
        self.in_print = 0
        self.print_budget = 40

    def fresh(self, prefix):
        self.counter += 1
        return "{}{}".format(prefix, self.counter)

    def int_types(self):
        if "widths" in self.groups:
            return ["int", "int", "int", "i8", "i16", "i32", "i64",
                    "u8", "u16", "u32", "u64"]
        return ["int"]

    def scalar_types(self):
        out = list(self.int_types()) + [BOOL]
        if "strings" in self.groups:
            out.append(STR)
        return out

    def value_types(self):
        out = self.scalar_types()
        if "structs" in self.groups:
            out.extend(st.name for st in self.prog.structs)
        if "enums" in self.groups:
            out.extend(en.name for en in self.prog.enums)
        return out

    def struct_for(self, name):
        for st in self.prog.structs:
            if st.name == name:
                return st
        return None

    def enum_for(self, name):
        for en in self.prog.enums:
            if en.name == name:
                return en
        return None

    # ---- declarations ----------------------------------------------------

    def gen_program(self):
        r = self.rng
        if "structs" in self.groups:
            for _ in range(r.randint(1, 2)):
                self.gen_struct()
        if "enums" in self.groups:
            for _ in range(r.randint(1, 2)):
                self.gen_enum()
        for _ in range(r.randint(1, 4)):
            self.gen_fn()
        self.gen_main()
        return self.prog

    def gen_struct(self):
        r = self.rng
        fields = []
        pool = list(self.int_types()) + [BOOL]
        if "strings" in self.groups:
            pool.append(STR)
        # a later struct may nest an earlier one
        pool.extend(st.name for st in self.prog.structs)
        for _ in range(r.randint(1, 3)):
            fields.append((self.fresh("f"), r.choice(pool)))
        self.prog.structs.append(StructType(self.fresh("St"), fields))

    def gen_enum(self):
        r = self.rng
        variants = []
        payload_pool = list(self.int_types()) + [BOOL]
        if "strings" in self.groups:
            payload_pool.append(STR)
        for _ in range(r.randint(2, 4)):
            name = self.fresh("tag")
            if r.random() < 0.5:
                variants.append((name, []))
            else:
                variants.append(
                    (name, [r.choice(payload_pool)
                            for _ in range(r.randint(1, 2))]))
        self.prog.enums.append(EnumType(self.fresh("En"), variants))

    def gen_fn(self):
        r = self.rng
        params = []
        param_pool = self.scalar_types()
        if "structs" in self.groups:
            param_pool.extend(st.name for st in self.prog.structs)
        if "enums" in self.groups:
            param_pool.extend(en.name for en in self.prog.enums)
        for _ in range(r.randint(0, 3)):
            params.append((self.fresh("p"), r.choice(param_pool)))
        ret_pool = self.scalar_types()
        if "structs" in self.groups:
            ret_pool.extend(st.name for st in self.prog.structs)
        ret = r.choice(ret_pool)
        fn = FnDecl(self.fresh("fn"), params, ret, [])
        scope = Scope()
        for name, t in params:
            scope.vars.append((name, t, False))
        body = self.gen_block(scope, r.randint(1, 6), in_fn=fn)
        # an early return inside an if is fine; the final one is mandatory
        body.append(Return(self.gen_expr(ret, self.max_depth, scope)))
        fn.body = body
        self.prog.fns.append(fn)

    def gen_main(self):
        r = self.rng
        scope = Scope()
        body = self.gen_block(scope, r.randint(4, self.max_stmts),
                              in_fn=None, top=True)
        # checksum: print every live scalar so silent state corruption
        # in any lane becomes visible output
        parts = [("lit", "chk")]
        for name, t, _ in scope.vars:
            if is_int_type(t) or t == BOOL:
                parts.append(("lit", " "))
                parts.append(("expr", VarRef(name, t)))
            elif t == STR:
                parts.append(("lit", " "))
                parts.append(("expr", StrMethod(VarRef(name, t), "len", [])))
            elif self.struct_for(t):
                for path in self.scalar_paths(VarRef(name, t)):
                    parts.append(("lit", " "))
                    parts.append(("expr", path))
            elif self.enum_for(t):
                parts.append(("lit", " "))
                parts.append(("expr", VarRef(name, t)))
        body.append(Print(parts))
        if r.random() < 0.10:
            self.prog.uses_os = True
            body.append(Exit(r.randint(0, 99)))
        self.prog.main = body

    def scalar_paths(self, base):
        """Expressions reaching every printable leaf of a struct value."""
        st = self.struct_for(base.type)
        out = []
        for fname, ftype in st.fields:
            fg = FieldGet(base, fname, ftype)
            if is_int_type(ftype) or ftype == BOOL:
                out.append(fg)
            elif ftype == STR:
                out.append(StrMethod(fg, "len", []))
            elif self.struct_for(ftype):
                out.extend(self.scalar_paths(fg))
        return out

    # ---- statements ------------------------------------------------------

    def gen_block(self, scope, n, in_fn, top=False, depth=0):
        out = []
        for _ in range(n):
            out.append(self.gen_stmt(scope, in_fn, top, depth))
        return out

    def gen_stmt(self, scope, in_fn, top, depth):
        r = self.rng
        choices = ["let", "let", "let"]
        mutables = [v for v in scope.all_vars() if v[2]]
        if mutables:
            choices += ["assign", "assign"]
            if any(self.struct_for(t) for _, t, m in mutables if m):
                choices.append("field_assign")
        if scope.all_vars() and self.print_budget > 0:
            choices.append("print")
        if depth < 2:
            choices += ["if"]
            choices += ["for"] * 2
            if "enums" in self.groups and self.prog.enums:
                choices.append("match_enum")
        if self.loop_depth > 0:
            choices.append("loopctl")
        kind = r.choice(choices)

        if kind == "let":
            t = r.choice(self.value_types())
            mut = r.random() < 0.6
            name = self.fresh("v")
            init = self.gen_expr(t, r.randint(1, self.max_depth), scope)
            scope.vars.append((name, t, mut))
            return Let(name, t, init, mut)

        if kind == "assign":
            name, t, _ = r.choice(mutables)
            if t == "int" and r.random() < 0.4:
                op = r.choice(["+=", "-=", "*="])
                return Assign(name, self.gen_expr(t, 2, scope), op)
            return Assign(name, self.gen_expr(
                t, r.randint(1, self.max_depth), scope))

        if kind == "field_assign":
            svars = [v for v in mutables if self.struct_for(v[1])]
            name, t, _ = r.choice(svars)
            st = self.struct_for(t)
            fname, ftype = r.choice(st.fields)
            return FieldAssign(name, fname,
                               self.gen_expr(ftype, 2, scope))

        if kind == "print":
            self.print_budget -= 1
            return self.gen_print(scope)

        if kind == "if":
            cond = self.gen_expr(BOOL, 2, scope)
            then_scope = Scope(scope)
            then_body = self.gen_block(then_scope, r.randint(1, 3),
                                       in_fn, depth=depth + 1)
            else_body = None
            if r.random() < 0.6:
                else_scope = Scope(scope)
                else_body = self.gen_block(else_scope, r.randint(1, 3),
                                           in_fn, depth=depth + 1)
            if (in_fn is not None and in_fn.ret is not None
                    and else_body is not None and r.random() < 0.25):
                then_body.append(Return(self.gen_expr(
                    in_fn.ret, 2, then_scope)))
            return If(cond, then_body, else_body)

        if kind == "for":
            if r.random() < 0.7:
                var = self.fresh("li")
                lo = r.randint(0, 3)
                hi = lo + r.randint(1, 6)
                inner = Scope(scope)
                inner.vars.append((var, "int", False))
                self.loop_depth += 1
                body = self.gen_block(inner, r.randint(1, 4), in_fn,
                                      depth=depth + 1)
                self.loop_depth -= 1
                return ForRange(var, lo, hi, r.random() < 0.5, body)
            counter = self.fresh("lc")
            limit = r.randint(1, 6)
            # registered immutable so no generated statement reassigns
            # it — the loop's own advance is what terminates it
            scope.vars.append((counter, "int", False))
            inner = Scope(scope)
            self.loop_depth += 1
            self.in_while += 1
            body = self.gen_block(inner, r.randint(1, 3), in_fn,
                                  depth=depth + 1)
            self.in_while -= 1
            self.loop_depth -= 1
            body.insert(0, Assign(counter, IntLit("int", 1), "+="))
            # the counter loop runs after a fresh declaration right here,
            # so the whole shape stays a single statement pair
            return CounterLoop(counter, limit, body)

        if kind == "match_enum":
            en = r.choice(self.prog.enums)
            scrut = self.gen_expr(en.name, 2, scope)
            arms = []
            for variant, payload in en.variants:
                bindings = [self.fresh("b") for _ in payload]
                inner = Scope(scope)
                for bname, btype in zip(bindings, payload):
                    inner.vars.append((bname, btype, False))
                body = self.gen_block(inner, r.randint(1, 2), in_fn,
                                      depth=depth + 1)
                arms.append((variant, bindings, body))
            return MatchEnumStmt(scrut, en, arms)

        if kind == "loopctl":
            # break/continue only make sense guarded, or everything
            # after them in the block is dead
            cond = self.gen_expr(BOOL, 1, scope)
            if self.in_while > 0:
                ctl = Break()
            else:
                ctl = r.choice([Break(), Continue()])
            return If(cond, [ctl], None)

        raise AssertionError(kind)

    def gen_print(self, scope):
        r = self.rng
        parts = []
        candidates = [v for v in scope.all_vars()
                      if is_int_type(v[1]) or v[1] in (BOOL, STR)
                      or self.enum_for(v[1])]
        n = r.randint(1, 3)
        for i in range(n):
            if i > 0 or r.random() < 0.5:
                parts.append(("lit", r.choice(
                    ["out ", " ", " : ", "-", " g", " t "])))
            if candidates and r.random() < 0.8:
                name, t, _ = r.choice(candidates)
                parts.append(("expr", VarRef(name, t)))
            else:
                t = r.choice(self.scalar_types())
                self.in_print += 1
                parts.append(("expr", self.gen_expr(t, 2, scope)))
                self.in_print -= 1
        return Print(parts)

    # ---- expressions -----------------------------------------------------

    def gen_expr(self, t, depth, scope):
        r = self.rng
        if depth <= 0:
            return self.gen_leaf(t, scope)
        if is_int_type(t):
            return self.gen_int_expr(t, depth, scope)
        if t == BOOL:
            return self.gen_bool_expr(t, depth, scope)
        if t == STR:
            return self.gen_str_expr(depth, scope)
        st = self.struct_for(t)
        if st is not None:
            return self.gen_struct_expr(st, depth, scope)
        en = self.enum_for(t)
        if en is not None:
            return self.gen_enum_expr(en, depth, scope)
        raise AssertionError(t)

    def vars_of(self, t, scope):
        return [v for v in scope.all_vars() if v[1] == t]

    def gen_leaf(self, t, scope):
        r = self.rng
        vs = self.vars_of(t, scope)
        if vs and r.random() < 0.6:
            name, vt, _ = r.choice(vs)
            return VarRef(name, vt)
        if is_int_type(t):
            return IntLit(t, self.gen_int_value(t))
        if t == BOOL:
            return BoolLit(r.random() < 0.5)
        if t == STR:
            return StrLit(self.gen_str_value())
        st = self.struct_for(t)
        if st is not None:
            return StructLit(st, [self.gen_leaf(ft, scope)
                                  for _, ft in st.fields])
        en = self.enum_for(t)
        if en is not None:
            variant, payload = r.choice(en.variants)
            return EnumLit(en, variant,
                           [self.gen_leaf(pt, scope) for pt in payload])
        raise AssertionError(t)

    def gen_int_value(self, t):
        r = self.rng
        lo, hi = int_range(t)
        pick = r.random()
        if pick < 0.5:
            return r.randint(0, 20)
        if pick < 0.7:
            return r.randint(max(lo, -20), 0)
        if pick < 0.9:
            return r.randint(lo, hi)
        return r.choice([lo, hi, 0, 1, hi - 1 if hi > 0 else hi,
                         lo + 1 if lo < 0 else lo])

    def gen_str_value(self):
        r = self.rng
        n = r.randint(0, 10)
        return "".join(r.choice(STR_ALPHABET) for _ in range(n))

    def maybe_call(self, t, depth, scope):
        r = self.rng
        fns = [f for f in self.prog.fns if f.ret == t]
        if not fns:
            return None
        fn = r.choice(fns)
        args = [self.gen_expr(pt, min(depth - 1, 2), scope)
                for _, pt in fn.params]
        return Call(fn, args)

    def maybe_field(self, t, scope):
        outs = []
        for name, vt, _ in scope.all_vars():
            st = self.struct_for(vt)
            if not st:
                continue
            for fname, ftype in st.fields:
                if ftype == t:
                    outs.append(FieldGet(VarRef(name, vt), fname, t))
                nested = self.struct_for(ftype)
                if nested:
                    for f2, t2 in nested.fields:
                        if t2 == t:
                            outs.append(FieldGet(
                                FieldGet(VarRef(name, vt), fname, ftype),
                                f2, t2))
        if not outs:
            return None
        return self.rng.choice(outs)

    def gen_int_expr(self, t, depth, scope):
        r = self.rng
        roll = r.random()
        if roll < 0.34:
            op = r.choice(ARITH_OPS)
            return Binary(op, self.gen_expr(t, depth - 1, scope),
                          self.gen_expr(t, depth - 1, scope), t)
        if roll < 0.42:
            # guarded division: total by construction
            den = self.gen_expr(t, depth - 1, scope)
            num = self.gen_expr(t, depth - 1, scope)
            alt = self.gen_expr(t, min(depth - 1, 1), scope)
            op = r.choice(["/", "%"])
            return IfValue(
                Binary("!=", den, IntLit(t, 0), BOOL),
                Binary(op, num, copy.deepcopy(den), t), alt)
        if roll < 0.50:
            op = r.choice(["/", "%"])
            div = 0
            while div == 0:
                div = self.gen_int_value(t)
            return Binary(op, self.gen_expr(t, depth - 1, scope),
                          IntLit(t, div), t)
        if roll < 0.56:
            return Unary(r.choice(["-", "~"]),
                         self.gen_expr(t, depth - 1, scope))
        if roll < 0.64 and "widths" in self.groups:
            src = r.choice(self.int_types())
            return Cast(self.gen_expr(src, depth - 1, scope), t)
        if roll < 0.72:
            call = self.maybe_call(t, depth, scope)
            if call is not None:
                return call
        if roll < 0.78 and "structs" in self.groups:
            fg = self.maybe_field(t, scope)
            if fg is not None:
                return fg
        if roll < 0.86:
            return IfValue(self.gen_expr(BOOL, depth - 1, scope),
                           self.gen_expr(t, depth - 1, scope),
                           self.gen_expr(t, depth - 1, scope))
        if roll < 0.92 and t == "int" and not self.in_print:
            # a match value spans lines, which a string template cannot
            return self.gen_match_int(t, depth, scope)
        if roll < 0.96 and "strings" in self.groups and t == "int":
            return StrMethod(self.gen_str_expr(depth - 1, scope), "len", [])
        return self.gen_leaf(t, scope)

    def gen_match_int(self, t, depth, scope):
        r = self.rng
        scrut = self.gen_expr(t, depth - 1, scope)
        arms = []
        used = set()
        for _ in range(r.randint(1, 3)):
            kind = r.choice(["lit", "or", "range"])
            if kind == "lit":
                v = r.randint(0, 30)
                pat = ("lit", v)
            elif kind == "or":
                vals = sorted({r.randint(0, 30)
                               for _ in range(r.randint(2, 3))})
                pat = ("or", tuple(vals))
            else:
                lo = r.randint(0, 25)
                pat = ("range", lo, lo + r.randint(1, 10))
            key = repr(pat)
            if key in used:
                continue
            used.add(key)
            arms.append((pat, self.gen_expr(t, min(depth - 1, 2), scope)))
        default = self.gen_expr(t, min(depth - 1, 2), scope)
        return MatchIntValue(scrut, arms, default)

    def gen_bool_expr(self, t, depth, scope):
        r = self.rng
        roll = r.random()
        if roll < 0.40:
            ct = r.choice(self.int_types())
            op = r.choice(CMP_OPS)
            return Binary(op, self.gen_expr(ct, depth - 1, scope),
                          self.gen_expr(ct, depth - 1, scope), BOOL)
        if roll < 0.55:
            op = r.choice(["&&", "||"])
            return Binary(op, self.gen_expr(BOOL, depth - 1, scope),
                          self.gen_expr(BOOL, depth - 1, scope), BOOL)
        if roll < 0.62:
            return Unary("!", self.gen_expr(BOOL, depth - 1, scope))
        if roll < 0.68:
            call = self.maybe_call(BOOL, depth, scope)
            if call is not None:
                return call
        if roll < 0.74 and "strings" in self.groups:
            s = self.gen_str_expr(depth - 1, scope)
            m = r.choice(["is_empty", "contains", "starts_with",
                          "ends_with"])
            args = [] if m == "is_empty" else [StrLit(self.gen_str_value())]
            return StrMethod(s, m, args)
        if roll < 0.80 and "strings" in self.groups:
            op = r.choice(["==", "!=", "<", "<=", ">", ">="])
            return Binary(op, self.gen_str_expr(depth - 1, scope),
                          self.gen_str_expr(depth - 1, scope), BOOL)
        if roll < 0.86 and "enums" in self.groups and self.prog.enums:
            en = r.choice(self.prog.enums)
            op = r.choice(["==", "!="])
            return Binary(op, self.gen_expr(en.name, 1, scope),
                          self.gen_expr(en.name, 1, scope), BOOL)
        if roll < 0.92 and "structs" in self.groups:
            fg = self.maybe_field(BOOL, scope)
            if fg is not None:
                return fg
        return self.gen_leaf(BOOL, scope)

    def gen_str_expr(self, depth, scope):
        r = self.rng
        if depth <= 0:
            return self.gen_leaf(STR, scope)
        roll = r.random()
        if roll < 0.30:
            return self.gen_leaf(STR, scope)
        if roll < 0.45:
            s = self.gen_str_expr(depth - 1, scope)
            return StrMethod(s, r.choice(["to_upper", "to_lower", "trim"]),
                             [])
        if roll < 0.55:
            s = self.gen_str_expr(depth - 1, scope)
            return StrMethod(s, "repeat",
                             [IntLit("int", r.randint(0, 3))])
        if roll < 0.65:
            s = self.gen_str_expr(depth - 1, scope)
            old = r.choice(STR_ALPHABET.replace(" ", ""))
            new = self.gen_str_value()[:3]
            return StrMethod(s, "replace", [StrLit(old), StrLit(new)])
        if roll < 0.75:
            call = self.maybe_call(STR, depth, scope)
            if call is not None:
                return call
        if roll < 0.85:
            return IfValue(self.gen_expr(BOOL, depth - 1, scope),
                           self.gen_str_expr(depth - 1, scope),
                           self.gen_str_expr(depth - 1, scope))
        if roll < 0.92 and "structs" in self.groups:
            fg = self.maybe_field(STR, scope)
            if fg is not None:
                return fg
        return self.gen_leaf(STR, scope)

    def gen_struct_expr(self, st, depth, scope):
        r = self.rng
        roll = r.random()
        vs = self.vars_of(st.name, scope)
        if vs and roll < 0.35:
            name, vt, _ = r.choice(vs)
            return VarRef(name, vt)
        if roll < 0.50:
            call = self.maybe_call(st.name, depth, scope)
            if call is not None:
                return call
        if roll < 0.60 and "structs" in self.groups:
            fg = self.maybe_field(st.name, scope)
            if fg is not None:
                return fg
        return StructLit(st, [self.gen_expr(ft, min(depth - 1, 2), scope)
                              for _, ft in st.fields])

    def gen_enum_expr(self, en, depth, scope):
        r = self.rng
        vs = self.vars_of(en.name, scope)
        if vs and r.random() < 0.4:
            name, vt, _ = r.choice(vs)
            return VarRef(name, vt)
        variant, payload = r.choice(en.variants)
        return EnumLit(en, variant,
                       [self.gen_expr(pt, min(depth - 1, 2), scope)
                        for pt in payload])


class CounterLoop(Stmt):
    """A `while`-shaped loop that always terminates: it declares its own
    counter and the first body statement advances it. `continue` is never
    generated inside, so the advance cannot be skipped."""

    def __init__(self, counter, limit, body):
        self.counter = counter
        self.limit = limit
        self.body = body

    def emit(self, ind):
        out = ["{}var {}: int = 0".format(ind, self.counter),
               "{}for {} < {} {{".format(ind, self.counter, self.limit)]
        for s in self.body:
            out.extend(s.emit(ind + "    "))
        out.append(ind + "}")
        return out

    def exec(self, env):
        env.declare(self.counter, 0)
        guard = 0
        while env.lookup(self.counter) < self.limit:
            guard += 1
            if guard > 100000:
                raise OracleUnsupported("counter loop failed to terminate")
            try:
                env.interp.run_block(self.body, env)
            except BreakLoop:
                break


def generate_case(seed, case, groups, max_depth, max_stmts):
    """Deterministic (seed, case) -> (Program, source_text)."""
    gen = Gen(seed, case, groups, max_depth, max_stmts)
    prog = gen.gen_program()
    return prog, prog.emit()


# NOTE for future groups: the counter declaration emitted by gen_stmt is a
# `var lcN: int = 0` via scope bookkeeping; CounterLoop re-zeroes it before
# the loop so a reducer dropping the declaration is caught by the checker,
# never silently different.


# ---------------------------------------------------------------------------
# lanes and the runner

class LaneResult:
    def __init__(self, lane, status, stdout, stderr, exit_code, commands,
                 note=""):
        self.lane = lane
        self.status = status  # ok | check-reject | build-fail | timeout |
                              # crash | error | skipped
        self.stdout = stdout
        self.stderr = stderr
        self.exit_code = exit_code
        self.commands = commands
        self.note = note


def run_proc(cmd, timeout, cwd=None):
    """(kind, stdout, stderr, exit). kind: ok | timeout | crash."""
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout,
                           cwd=cwd)
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if e.stdout else ""
        err = e.stderr.decode("utf-8", "replace") if e.stderr else ""
        return "timeout", out, err, None
    except OSError as e:
        return "crash", "", str(e), None
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    if p.returncode < 0:
        return "crash", out, err, p.returncode
    return "ok", out, err, p.returncode


class Runner:
    ALL_LANES = ("interp0", "interp1", "native0", "native1",
                 "release0", "release1", "lto0", "lto1")

    def __init__(self, beansc0, beansc, lanes, timeout_build, timeout_run,
                 workdir):
        self.beansc0 = beansc0
        self.beansc = beansc
        self.lanes = list(lanes)
        self.timeout_build = timeout_build
        self.timeout_run = timeout_run
        self.workdir = workdir
        self.skipped = {}  # lane -> reason

    def compiler_for(self, lane):
        return self.beansc0 if lane.endswith("0") else self.beansc

    def probe_lto(self):
        """LTO needs host linker support; probe once, skip with a reason."""
        wanted = [l for l in self.lanes if l.startswith("lto")]
        if not wanted:
            return
        probe_dir = os.path.join(self.workdir, "lto-probe")
        os.makedirs(probe_dir, exist_ok=True)
        src = os.path.join(probe_dir, "p.b")
        with open(src, "w") as f:
            f.write('import std.io\n\nfn main() {\n'
                    '    io.println("x")\n}\n')
        for lane in wanted:
            cc = self.compiler_for(lane)
            out = os.path.join(probe_dir, "p-" + lane)
            kind, _, err, code = run_proc(
                [cc, "build", "--lto", src, "-o", out], self.timeout_build)
            if kind != "ok" or code != 0:
                reason = err.strip().splitlines()
                reason = reason[-1] if reason else "build failed"
                self.skipped[lane] = "lto probe failed: " + reason
                self.lanes.remove(lane)
                print("lane {} skipped: {}".format(
                    lane, self.skipped[lane]))

    def check_case(self, main_file):
        """Both checkers must accept a generator-valid program."""
        results = []
        for lane, cc in (("check0", self.beansc0), ("check1", self.beansc)):
            cmd = [cc, "check", main_file]
            kind, out, err, code = run_proc(cmd, self.timeout_build)
            if kind != "ok" or code != 0:
                results.append(LaneResult(
                    lane, "check-reject" if kind == "ok" else kind,
                    out, err, code, [cmd]))
        return results

    def run_case(self, case_dir, main_file):
        """Run every configured lane; returns list of LaneResult."""
        results = []
        for lane in self.lanes:
            cc = self.compiler_for(lane)
            cmds = []
            if lane.startswith("interp"):
                cmd = [cc, "run", main_file]
                cmds.append(cmd)
                kind, out, err, code = run_proc(cmd, self.timeout_run)
                results.append(LaneResult(lane, kind, out, err, code, cmds))
                continue
            flags = []
            if lane.startswith("release"):
                flags = ["--release"]
            elif lane.startswith("lto"):
                flags = ["--lto"]
            binary = os.path.join(case_dir, "bin-" + lane)
            build_cmd = [cc, "build"] + flags + [main_file, "-o", binary]
            cmds.append(build_cmd)
            kind, out, err, code = run_proc(build_cmd, self.timeout_build)
            if kind == "timeout":
                results.append(LaneResult(lane, "timeout", out, err, code,
                                          cmds, "compiler timed out"))
                continue
            if kind == "crash":
                results.append(LaneResult(lane, "crash", out, err, code,
                                          cmds, "compiler crashed"))
                continue
            if code != 0:
                results.append(LaneResult(lane, "build-fail", out, err,
                                          code, cmds))
                continue
            run_cmd = [binary]
            cmds.append(run_cmd)
            kind, out, err, code = run_proc(run_cmd, self.timeout_run)
            results.append(LaneResult(lane, kind, out, err, code, cmds))
        return results


def classify_failures(expected, lane_results):
    """expected: (stdout, exit). Returns list of failure dicts."""
    failures = []
    exp_out, exp_exit = expected
    for lr in lane_results:
        if lr.status == "check-reject":
            failures.append({"lane": lr.lane, "kind": "check-reject"})
        elif lr.status == "build-fail":
            failures.append({"lane": lr.lane, "kind": "build-fail"})
        elif lr.status == "timeout":
            failures.append({"lane": lr.lane, "kind": "timeout"})
        elif lr.status == "crash":
            failures.append({"lane": lr.lane, "kind": "crash"})
        elif lr.status == "ok":
            if (lr.stdout != exp_out or lr.exit_code != exp_exit
                    or lr.stderr != ""):
                failures.append({"lane": lr.lane, "kind": "mismatch"})
    return failures


# ---------------------------------------------------------------------------
# artifacts

def save_failure(out_root, seed, case, files, expected, lane_results,
                 failures, config):
    name = "{}-{}".format(seed, case)
    fail_dir = os.path.join(out_root, "failures", name)
    if os.path.exists(fail_dir):
        shutil.rmtree(fail_dir)
    os.makedirs(fail_dir)
    for rel, text in files.items():
        path = os.path.join(fail_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
    with open(os.path.join(fail_dir, "expected_stdout.txt"), "w") as f:
        f.write(expected[0])
    lanes_meta = {}
    cmd_lines = []
    for lr in lane_results:
        with open(os.path.join(fail_dir,
                               "{}.stdout".format(lr.lane)), "w") as f:
            f.write(lr.stdout or "")
        with open(os.path.join(fail_dir,
                               "{}.stderr".format(lr.lane)), "w") as f:
            f.write(lr.stderr or "")
        lanes_meta[lr.lane] = {
            "status": lr.status,
            "exit": lr.exit_code,
            "note": lr.note,
        }
        for cmd in lr.commands:
            cmd_lines.append("{}: {}".format(
                lr.lane, " ".join(shlex.quote(c) for c in cmd)))
    with open(os.path.join(fail_dir, "commands.txt"), "w") as f:
        f.write("\n".join(cmd_lines) + "\n")
    meta = {
        "generator_version": GENERATOR_VERSION,
        "seed": seed,
        "case": case,
        "groups": sorted(config["groups"]),
        "max_depth": config["max_depth"],
        "max_stmts": config["max_stmts"],
        "lanes": config["lanes"],
        "expected_exit": expected[1],
        "failures": failures,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": sys.version.split()[0],
        },
    }
    with open(os.path.join(fail_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2, sort_keys=True)
        f.write("\n")
    return fail_dir


# ---------------------------------------------------------------------------
# reducer

def model_closed(prog):
    """Static validity of a (possibly reduced) model: every name, call
    and type reference resolves. Reduction edits that orphan a use would
    otherwise be rejected by both checkers and read as a 'failure'."""
    fn_names = {fn.name for fn in prog.fns}
    type_names = ({st.name for st in prog.structs}
                  | {en.name for en in prog.enums}
                  | set(INT_TYPES) | {BOOL, STR})
    ok = [True]

    def check_type(t):
        if t is not None and t not in type_names:
            ok[0] = False

    def walk_expr(e, names):
        if isinstance(e, VarRef):
            if e.name not in names:
                ok[0] = False
        if isinstance(e, Call):
            if e.fn.name not in fn_names:
                ok[0] = False
        if isinstance(e, StructLit):
            check_type(e.struct.name)
        if isinstance(e, EnumLit):
            check_type(e.enum.name)
        if isinstance(e, MatchEnumValue):
            walk_expr(e.scrut, names)
            for variant, bindings, arm in e.arms:
                walk_expr(arm, names | set(bindings))
            return
        for c in e.children():
            walk_expr(c, names)

    def walk_block(stmts, names):
        names = set(names)
        for s in stmts:
            if isinstance(s, Let):
                walk_expr(s.init, names)
                check_type(s.type)
                names.add(s.name)
            elif isinstance(s, Assign):
                if s.name not in names:
                    ok[0] = False
                walk_expr(s.expr, names)
            elif isinstance(s, FieldAssign):
                if s.name not in names:
                    ok[0] = False
                walk_expr(s.expr, names)
            elif isinstance(s, Print):
                for kind, p in s.parts:
                    if kind == "expr":
                        walk_expr(p, names)
            elif isinstance(s, If):
                walk_expr(s.cond, names)
                walk_block(s.then_body, names)
                if s.else_body is not None:
                    walk_block(s.else_body, names)
            elif isinstance(s, ForRange):
                walk_block(s.body, names | {s.var})
            elif isinstance(s, CounterLoop):
                names.add(s.counter)
                walk_block(s.body, names)
            elif isinstance(s, MatchEnumStmt):
                walk_expr(s.scrut, names)
                check_type(s.enum.name)
                for variant, bindings, body in s.arms:
                    walk_block(body, names | set(bindings))
            elif isinstance(s, Return):
                if s.expr is not None:
                    walk_expr(s.expr, names)

    for st in prog.structs:
        for _, t in st.fields:
            check_type(t)
    for en in prog.enums:
        for _, payload in en.variants:
            for t in payload:
                check_type(t)
    for fn in prog.fns:
        for _, t in fn.params:
            check_type(t)
        check_type(fn.ret)
        walk_block(fn.body, {n for n, _ in fn.params})
    walk_block(prog.main, set())
    return ok[0]


class Reducer:
    """Structural reduction: keep applying source-shrinking edits while the
    failure predicate stays true. The predicate re-computes the oracle's
    expectation for each candidate, so edits are free to change behavior —
    they only have to keep some lane disagreeing."""

    def __init__(self, predicate, budget=400, log=None):
        self.predicate = predicate  # fn(Program) -> bool (still failing?)
        self.budget = budget
        self.evals = 0
        self.seen = set()
        self.log = log if log is not None else []

    def check(self, prog):
        if self.evals >= self.budget:
            return False
        if not model_closed(prog):
            return False
        src = prog.emit()
        key = hashlib.sha256(src.encode()).hexdigest()
        if key in self.seen:
            return False
        self.seen.add(key)
        self.evals += 1
        return self.predicate(prog)

    def reduce(self, prog):
        best = copy.deepcopy(prog)
        improved = True
        while improved and self.evals < self.budget:
            improved = False
            for pass_fn in (self.pass_drop_main_stmts,
                            self.pass_drop_fn_stmts,
                            self.pass_gut_functions,
                            self.pass_unwrap,
                            self.pass_drop_decls,
                            self.pass_simplify_exprs):
                candidate = pass_fn(best)
                if candidate is not None:
                    best = candidate
                    improved = True
        return best

    # each pass returns an improved program or None

    def blocks_of(self, prog):
        """Yield (owner, list) for every statement list in the program."""
        def walk(stmts):
            yield stmts
            for s in stmts:
                for attr in ("then_body", "else_body", "body"):
                    b = getattr(s, attr, None)
                    if isinstance(b, list):
                        yield from walk(b)
                if isinstance(s, MatchEnumStmt):
                    for _, _, arm_body in s.arms:
                        yield from walk(arm_body)
        yield from walk(prog.main)
        for fn in prog.fns:
            yield from walk(fn.body)

    def pass_drop_main_stmts(self, prog):
        return self._drop_stmts(prog, main_only=True)

    def pass_drop_fn_stmts(self, prog):
        return self._drop_stmts(prog, main_only=False)

    def _drop_stmts(self, prog, main_only):
        made_progress = None
        work = copy.deepcopy(prog)
        blocks = list(self.blocks_of(work))
        if main_only:
            blocks = blocks[:1]
        for block in blocks:
            i = 0
            while i < len(block):
                s = block[i]
                # a valued function keeps its final return
                if isinstance(s, Return) and block and s is block[-1]:
                    i += 1
                    continue
                removed = block.pop(i)
                if self.check(work):
                    made_progress = copy.deepcopy(work)
                    self.log.append("dropped a statement")
                else:
                    block.insert(i, removed)
                    i += 1
        return made_progress

    def pass_gut_functions(self, prog):
        made_progress = None
        work = copy.deepcopy(prog)
        for fn in work.fns:
            if len(fn.body) <= 1:
                continue
            saved = fn.body
            tail = saved[-1]
            if isinstance(tail, Return):
                fn.body = [tail]
            else:
                fn.body = []
            if self.check(work):
                made_progress = copy.deepcopy(work)
                self.log.append("gutted " + fn.name)
            else:
                fn.body = saved
        return made_progress

    def pass_drop_decls(self, prog):
        work = copy.deepcopy(prog)
        used_fns = set()
        used_structs = set()
        used_enums = set()

        def walk_expr(e):
            if isinstance(e, Call):
                used_fns.add(e.fn.name)
            if isinstance(e, StructLit):
                used_structs.add(e.struct.name)
            if isinstance(e, EnumLit):
                used_enums.add(e.enum.name)
            if isinstance(e, (MatchEnumValue,)):
                used_enums.add(e.enum.name)
            for c in e.children():
                walk_expr(c)

        def walk_stmts(stmts):
            for s in stmts:
                for attr in ("init", "expr", "cond", "scrut"):
                    e = getattr(s, attr, None)
                    if isinstance(e, Expr):
                        walk_expr(e)
                if isinstance(s, Print):
                    for kind, p in s.parts:
                        if kind == "expr":
                            walk_expr(p)
                if isinstance(s, Return) and s.expr is not None:
                    walk_expr(s.expr)
                for attr in ("then_body", "else_body", "body"):
                    b = getattr(s, attr, None)
                    if isinstance(b, list):
                        walk_stmts(b)
                if isinstance(s, MatchEnumStmt):
                    for _, _, arm_body in s.arms:
                        walk_stmts(arm_body)

        # roots: main + every kept function's body and signature types
        changed = True
        while changed:
            changed = False
            used_fns.clear()
            used_structs.clear()
            used_enums.clear()
            walk_stmts(work.main)
            for fn in work.fns:
                walk_stmts(fn.body)
                for _, t in fn.params:
                    used_structs.add(t)
                    used_enums.add(t)
                used_structs.add(fn.ret)
                used_enums.add(fn.ret)

            def struct_closure():
                more = True
                while more:
                    more = False
                    for st in work.structs:
                        if st.name in used_structs:
                            for _, t in st.fields:
                                if t not in used_structs:
                                    used_structs.add(t)
                                    more = True
            struct_closure()
            # declared types referenced from kept variable declarations
            def walk_types(stmts):
                for s in stmts:
                    t = getattr(s, "type", None)
                    if isinstance(t, str):
                        used_structs.add(t)
                        used_enums.add(t)
                    for attr in ("then_body", "else_body", "body"):
                        b = getattr(s, attr, None)
                        if isinstance(b, list):
                            walk_types(b)
                    if isinstance(s, MatchEnumStmt):
                        for _, _, arm_body in s.arms:
                            walk_types(arm_body)
            walk_types(work.main)
            for fn in work.fns:
                walk_types(fn.body)
            struct_closure()

            kept_fns = [f for f in work.fns if f.name in used_fns]
            kept_structs = [s for s in work.structs
                            if s.name in used_structs]
            kept_enums = [e for e in work.enums if e.name in used_enums]
            if (len(kept_fns) < len(work.fns)
                    or len(kept_structs) < len(work.structs)
                    or len(kept_enums) < len(work.enums)):
                saved = (work.fns, work.structs, work.enums)
                work.fns = kept_fns
                work.structs = kept_structs
                work.enums = kept_enums
                if self.check(work):
                    self.log.append("dropped unused declarations")
                    changed = True
                else:
                    work.fns, work.structs, work.enums = saved
        base = copy.deepcopy(prog)
        if work.emit() != base.emit():
            return work
        return None

    def pass_unwrap(self, prog):
        made_progress = None
        work = copy.deepcopy(prog)
        for block in self.blocks_of(work):
            i = 0
            while i < len(block):
                s = block[i]
                candidates = []
                if isinstance(s, If):
                    candidates.append(list(s.then_body))
                    if s.else_body:
                        candidates.append(list(s.else_body))
                elif isinstance(s, ForRange):
                    # one trip with the loop variable pinned, then none
                    candidates.append(
                        [Let(s.var, "int", IntLit("int", s.lo), False)]
                        + list(s.body))
                    candidates.append([])
                elif isinstance(s, CounterLoop):
                    candidates.append(
                        [Let(s.counter, "int", IntLit("int", 0), True)]
                        + list(s.body))
                    candidates.append([])
                if not candidates:
                    i += 1
                    continue
                # break/continue cannot float up out of their loop
                def has_loopctl(stmts):
                    for x in stmts:
                        if isinstance(x, (Break, Continue)):
                            return True
                        for attr in ("then_body", "else_body", "body"):
                            b = getattr(x, attr, None)
                            if isinstance(b, list) and has_loopctl(b):
                                return True
                        if isinstance(x, MatchEnumStmt):
                            for _, _, ab in x.arms:
                                if has_loopctl(ab):
                                    return True
                    return False
                saved = block[i]
                applied = False
                for replacement in candidates:
                    if has_loopctl(replacement):
                        continue
                    block[i:i + 1] = replacement
                    if self.check(work):
                        made_progress = copy.deepcopy(work)
                        self.log.append("unwrapped a block")
                        applied = True
                        break
                    block[i:i + len(replacement)] = [saved]
                if not applied:
                    i += 1
        return made_progress

    def exprs_of(self, prog):
        """(holder, setter) pairs for every expression slot."""
        slots = []

        def stmt_slots(s):
            for attr in ("init", "expr", "cond", "scrut"):
                e = getattr(s, attr, None)
                if isinstance(e, Expr):
                    slots.append((s, attr, None))
            if isinstance(s, Print):
                for idx, (kind, _) in enumerate(s.parts):
                    if kind == "expr":
                        slots.append((s, "parts", idx))

        for block in self.blocks_of(prog):
            for s in block:
                stmt_slots(s)
        return slots

    def simple_literal(self, prog, t):
        if t is None:
            return None
        if is_int_type(t):
            return IntLit(t, 0)
        if t == BOOL:
            return BoolLit(False)
        if t == STR:
            return StrLit("a")
        for st in prog.structs:
            if st.name == t:
                vals = []
                for _, ft in st.fields:
                    lit = self.simple_literal(prog, ft)
                    if lit is None:
                        return None
                    vals.append(lit)
                return StructLit(st, vals)
        for en in prog.enums:
            if en.name == t:
                for v, payload in en.variants:
                    if not payload:
                        return EnumLit(en, v, [])
                v, payload = en.variants[0]
                vals = []
                for pt in payload:
                    lit = self.simple_literal(prog, pt)
                    if lit is None:
                        return None
                    vals.append(lit)
                return EnumLit(en, v, vals)
        return None

    def pass_simplify_exprs(self, prog):
        made_progress = None
        work = copy.deepcopy(prog)
        for holder, attr, idx in self.exprs_of(work):
            def current():
                if idx is None:
                    return getattr(holder, attr)
                return holder.parts[idx][1]

            def install(e):
                if idx is None:
                    setattr(holder, attr, e)
                else:
                    holder.parts[idx] = ("expr", e)

            target = current()
            candidates = []
            lit = self.simple_literal(work, target.type)
            if lit is not None and lit.emit() != target.emit():
                candidates.append(lit)
            for child in target.children():
                if child.type == target.type:
                    candidates.append(child)
            for cand in candidates:
                saved = current()
                install(cand)
                if self.check(work):
                    made_progress = copy.deepcopy(work)
                    self.log.append("simplified an expression")
                    break
                install(saved)
        return made_progress


# ---------------------------------------------------------------------------
# top-level fuzz loop

def make_runner(args, workdir):
    lanes = resolve_lanes(args.lanes)
    runner = Runner(args.beansc0, args.beansc, lanes,
                    args.timeout_build, args.timeout_run, workdir)
    runner.probe_lto()
    for lane in Runner.ALL_LANES:
        if lane not in runner.lanes and lane not in runner.skipped:
            print("lane {} skipped: not selected".format(lane))
    return runner


def resolve_lanes(spec):
    if spec == "all":
        return list(Runner.ALL_LANES)
    if spec == "debug":
        return ["interp0", "interp1", "native0", "native1"]
    if spec == "interp":
        return ["interp0", "interp1"]
    lanes = [l.strip() for l in spec.split(",") if l.strip()]
    for l in lanes:
        if l not in Runner.ALL_LANES:
            raise SystemExit("unknown lane: " + l)
    return lanes


def case_files(source):
    return {"main.b": source}


def run_one_case(runner, out_root, seed, case, config, keep=False,
                 expected_override=None, sabotage=None):
    """Generate, evaluate, run and compare one case.
    Returns (failures, fail_dir_or_None, prog, source)."""
    prog, source = generate_case(seed, case, config["groups"],
                                 config["max_depth"], config["max_stmts"])
    expected = (oracle_expected(prog, sabotage)
                if expected_override is None else expected_override)
    if expected is None:
        raise SystemExit(
            "generator bug: case {}-{} has no defined meaning".format(
                seed, case))
    files = case_files(source)
    case_dir = os.path.join(out_root, "work", "{}-{}".format(seed, case))
    if os.path.exists(case_dir):
        shutil.rmtree(case_dir)
    os.makedirs(case_dir)
    main_file = os.path.join(case_dir, "main.b")
    for rel, text in files.items():
        with open(os.path.join(case_dir, rel), "w") as f:
            f.write(text)

    lane_results = runner.check_case(main_file)
    if not any(r.status in ("check-reject", "timeout", "crash")
               for r in lane_results):
        lane_results = runner.run_case(case_dir, main_file)
    failures = classify_failures(expected, lane_results)
    fail_dir = None
    if failures:
        fail_dir = save_failure(out_root, seed, case, files, expected,
                                lane_results, failures, config)
    if not keep:
        shutil.rmtree(case_dir, ignore_errors=True)
    return failures, fail_dir, prog, source


def failure_predicate(runner, out_root, config, sabotage=None):
    """Builds the reducer predicate: does this program still fail?"""
    scratch = os.path.join(out_root, "reduce-work")

    def predicate(prog):
        expected = oracle_expected(prog, sabotage)
        if expected is None:
            return False
        source = prog.emit()
        if os.path.exists(scratch):
            shutil.rmtree(scratch)
        os.makedirs(scratch)
        main_file = os.path.join(scratch, "main.b")
        with open(main_file, "w") as f:
            f.write(source)
        lane_results = runner.check_case(main_file)
        if not any(r.status in ("check-reject", "timeout", "crash")
                   for r in lane_results):
            lane_results = runner.run_case(scratch, main_file)
        return bool(classify_failures(expected, lane_results))

    return predicate


def reduce_failure(runner, out_root, seed, case, config, budget,
                   sabotage=None):
    prog, _ = generate_case(seed, case, config["groups"],
                            config["max_depth"], config["max_stmts"])
    log = []
    reducer = Reducer(failure_predicate(runner, out_root, config, sabotage),
                      budget=budget, log=log)
    if not reducer.check(prog):
        print("case {}-{} does not fail; nothing to reduce".format(
            seed, case))
        return None
    reduced = reducer.reduce(prog)
    expected = oracle_expected(reduced, sabotage)
    fail_dir = os.path.join(out_root, "failures",
                            "{}-{}".format(seed, case))
    if os.path.isdir(fail_dir):
        with open(os.path.join(fail_dir, "reduced.b"), "w") as f:
            f.write(reduced.emit())
        with open(os.path.join(fail_dir,
                               "reduced_expected_stdout.txt"), "w") as f:
            f.write(expected[0])
        with open(os.path.join(fail_dir, "reduced_meta.json"), "w") as f:
            json.dump({"expected_exit": expected[1],
                       "reduction_evals": reducer.evals}, f)
            f.write("\n")
        with open(os.path.join(fail_dir, "reduction.log"), "w") as f:
            f.write("\n".join(log) + "\n")
    print("reduced {}-{}: {} bytes -> {} bytes ({} evaluations)".format(
        seed, case, len(prog.emit()), len(reduced.emit()), reducer.evals))
    return reduced, expected


def fuzz_loop(args):
    out_root = args.out
    os.makedirs(out_root, exist_ok=True)
    runner = make_runner(args, out_root)
    config = {
        "groups": args.groups.split(","),
        "max_depth": args.max_depth,
        "max_stmts": args.max_stmts,
        "lanes": runner.lanes,
    }
    total_failures = 0
    started = time.time()
    for case in range(args.start, args.start + args.cases):
        failures, fail_dir, _, _ = run_one_case(
            runner, out_root, args.seed, case, config, keep=args.keep)
        if failures:
            total_failures += 1
            kinds = sorted({f["kind"] for f in failures})
            lanes = sorted({f["lane"] for f in failures})
            print("FAIL case {}-{}: {} in lanes {} -> {}".format(
                args.seed, case, ",".join(kinds), ",".join(lanes),
                fail_dir))
            if args.reduce_failures:
                reduce_failure(runner, out_root, args.seed, case, config,
                               args.reduce_budget)
            if not args.keep_going:
                break
        elif args.verbose:
            print("ok case {}-{}".format(args.seed, case))
        elif (case - args.start + 1) % 10 == 0:
            elapsed = time.time() - started
            print("... {} cases, {} failures, {:.0f}s".format(
                case - args.start + 1, total_failures, elapsed))
    print("done: {} cases, {} failing, seed {}, groups {}".format(
        args.cases, total_failures, args.seed, ",".join(config["groups"])))
    return 1 if total_failures else 0


# ---------------------------------------------------------------------------
# replay

def replay_case(args):
    seed, case = parse_case_ref(args.replay)
    out_root = args.out
    os.makedirs(out_root, exist_ok=True)
    runner = make_runner(args, out_root)
    config = {
        "groups": args.groups.split(","),
        "max_depth": args.max_depth,
        "max_stmts": args.max_stmts,
        "lanes": runner.lanes,
    }
    failures, fail_dir, _, source = run_one_case(
        runner, out_root, seed, case, config, keep=True)
    print(source, end="")
    if failures:
        print("replay {}-{}: still failing -> {}".format(
            seed, case, fail_dir))
        return 1
    print("replay {}-{}: passing".format(seed, case))
    return 0


def replay_dir(args):
    """Re-run a saved failure directory from its recorded metadata."""
    fail_dir = args.replay_dir
    with open(os.path.join(fail_dir, "meta.json")) as f:
        meta = json.load(f)
    seed, case = meta["seed"], meta["case"]
    prog, source = generate_case(seed, case, meta["groups"],
                                 meta["max_depth"], meta["max_stmts"])
    saved = open(os.path.join(fail_dir, "main.b")).read()
    if saved != source:
        print("replay-dir: regenerated source differs from the saved "
              "program (generator changed since the failure was recorded); "
              "re-running the saved artifacts only")
    out_root = args.out
    os.makedirs(out_root, exist_ok=True)
    runner = make_runner(args, out_root)
    scratch = os.path.join(out_root, "replay-work")
    if os.path.exists(scratch):
        shutil.rmtree(scratch)
    os.makedirs(scratch)
    main_file = os.path.join(scratch, "main.b")
    with open(main_file, "w") as f:
        f.write(saved)
    expected = (open(os.path.join(fail_dir, "expected_stdout.txt")).read(),
                meta["expected_exit"])
    lane_results = runner.check_case(main_file)
    if not any(r.status in ("check-reject", "timeout", "crash")
               for r in lane_results):
        lane_results = runner.run_case(scratch, main_file)
    failures = classify_failures(expected, lane_results)
    if failures:
        kinds = sorted({f["kind"] for f in failures})
        print("replay-dir {}: still failing ({})".format(
            fail_dir, ",".join(kinds)))
        return 1
    print("replay-dir {}: no longer failing".format(fail_dir))
    return 0


def parse_case_ref(text):
    try:
        seed, case = text.split(":")
        return int(seed), int(case)
    except ValueError:
        raise SystemExit("expected SEED:CASE, got " + text)


# ---------------------------------------------------------------------------
# fixed corpus for target gates (qemu / wine)

def emit_corpus(args):
    """Write N deterministic cases with their expected stdout/exit to a
    directory. The target gates cross-build each program, execute it on
    the emulated machine, and compare against these expectations."""
    os.makedirs(args.corpus, exist_ok=True)
    manifest = []
    for case in range(args.start, args.start + args.cases):
        prog, source = generate_case(args.seed, case,
                                     args.groups.split(","),
                                     args.max_depth, args.max_stmts)
        expected = oracle_expected(prog)
        if expected is None:
            raise SystemExit("generator bug: corpus case has no meaning")
        name = "case_{}_{}".format(args.seed, case)
        with open(os.path.join(args.corpus, name + ".b"), "w") as f:
            f.write(source)
        with open(os.path.join(args.corpus, name + ".stdout"), "w") as f:
            f.write(expected[0])
        with open(os.path.join(args.corpus, name + ".exit"), "w") as f:
            f.write(str(expected[1]) + "\n")
        manifest.append(name)
    with open(os.path.join(args.corpus, "MANIFEST"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    print("wrote {} corpus cases (seed {}) to {}".format(
        args.cases, args.seed, args.corpus))
    return 0


# ---------------------------------------------------------------------------
# self-tests

def self_test(args):
    out_root = args.out
    os.makedirs(out_root, exist_ok=True)
    failures = []

    def report(name, ok, detail=""):
        print("self-test {:<28} {}".format(name, "PASS" if ok else
                                           "FAIL " + detail))
        if not ok:
            failures.append(name)

    groups = args.groups.split(",")
    config = {"groups": groups, "max_depth": args.max_depth,
              "max_stmts": args.max_stmts, "lanes": ["interp0", "interp1"]}

    # 1. determinism: byte-identical regeneration
    ok = True
    for case in range(20):
        _, a = generate_case(11, case, groups, args.max_depth,
                             args.max_stmts)
        _, b = generate_case(11, case, groups, args.max_depth,
                             args.max_stmts)
        if a != b:
            ok = False
            break
    report("determinism", ok)

    # 2. the oracle accepts its own programs and both checkers agree
    runner = Runner(args.beansc0, args.beansc, ["interp0", "interp1"],
                    args.timeout_build, args.timeout_run, out_root)
    ok = True
    detail = ""
    for case in range(args.selftest_cases):
        prog, source = generate_case(23, case, groups, args.max_depth,
                                     args.max_stmts)
        if oracle_expected(prog) is None:
            ok, detail = False, "oracle rejected case 23-{}".format(case)
            break
        scratch = os.path.join(out_root, "selftest-work")
        if os.path.exists(scratch):
            shutil.rmtree(scratch)
        os.makedirs(scratch)
        main_file = os.path.join(scratch, "main.b")
        with open(main_file, "w") as f:
            f.write(source)
        rejects = runner.check_case(main_file)
        if rejects:
            ok = False
            detail = "case 23-{} rejected by {}".format(
                case, rejects[0].lane)
            break
    report("checkers-accept", ok, detail)

    # 3. a wrong expectation is detected
    prog, source = generate_case(23, 0, groups, args.max_depth,
                                 args.max_stmts)
    expected = oracle_expected(prog)
    corrupted = (expected[0] + "unexpected line\n", expected[1])
    scratch = os.path.join(out_root, "selftest-work")
    if os.path.exists(scratch):
        shutil.rmtree(scratch)
    os.makedirs(scratch)
    main_file = os.path.join(scratch, "main.b")
    with open(main_file, "w") as f:
        f.write(source)
    results = runner.run_case(scratch, main_file)
    fails = classify_failures(corrupted, results)
    report("mismatch-detected",
           bool(fails) and all(f["kind"] == "mismatch" for f in fails))
    # ... and the true expectation passes
    fails = classify_failures(expected, results)
    report("true-expectation-passes", not fails)

    # 4. a crash is detected (panic exits 3 and writes to stderr)
    crash_src = ('import std.io\n\nfn main() {\n'
                 '    io.println("before")\n'
                 '    panic("boom")\n}\n')
    with open(main_file, "w") as f:
        f.write(crash_src)
    results = runner.run_case(scratch, main_file)
    fails = classify_failures(("before\n", 0), results)
    report("crash-detected", bool(fails))

    # 5. a timeout is detected
    hang_src = 'fn main() {\n    for { }\n}\n'
    with open(main_file, "w") as f:
        f.write(hang_src)
    quick = Runner(args.beansc0, args.beansc, ["interp0"],
                   args.timeout_build, 2, out_root)
    results = quick.run_case(scratch, main_file)
    fails = classify_failures(("", 0), results)
    report("timeout-detected",
           any(f["kind"] == "timeout" for f in fails))

    # 6. an exit-code difference is detected
    exit_src = ('import std.os\n\nfn main() {\n    os.exit(5)\n}\n')
    with open(main_file, "w") as f:
        f.write(exit_src)
    results = runner.run_case(scratch, main_file)
    fails = classify_failures(("", 0), results)
    ok = bool(fails) and not classify_failures(("", 5), results)
    report("exit-code-detected", ok)

    # 7. failure artifacts replay: force a failure with a sabotaged
    # oracle, save it, then replay the directory
    sab_case = find_sabotage_case(groups, args)
    if sab_case is None:
        report("replay-artifacts", False, "no sabotage-visible case")
    else:
        prog, source = generate_case(97, sab_case, groups, args.max_depth,
                                     args.max_stmts)
        wrong = oracle_expected(prog, sabotage="flip-gt")
        with open(main_file, "w") as f:
            f.write(source)
        results = runner.run_case(scratch, main_file)
        fails = classify_failures(wrong, results)
        fail_dir = save_failure(out_root, 97, sab_case,
                                {"main.b": source}, wrong, results, fails,
                                config)
        saved = open(os.path.join(fail_dir, "main.b")).read()
        _, regen = generate_case(97, sab_case, groups, args.max_depth,
                                 args.max_stmts)
        meta_ok = os.path.exists(os.path.join(fail_dir, "meta.json"))
        report("replay-artifacts",
               bool(fails) and saved == regen and meta_ok)

    # 8. the reducer preserves a (simulated) failure
    if sab_case is None:
        report("reducer", False, "no sabotage-visible case")
    else:
        prog, _ = generate_case(97, sab_case, groups, args.max_depth,
                                args.max_stmts)
        original_len = len(prog.emit())
        pred = failure_predicate(runner, out_root, config,
                                 sabotage="flip-gt")
        reducer = Reducer(pred, budget=args.reduce_budget)
        if not reducer.check(prog):
            report("reducer", False, "sabotaged case does not fail")
        else:
            reduced = reducer.reduce(prog)
            still = pred(reduced)
            smaller = len(reduced.emit()) <= original_len
            report("reducer", still and smaller,
                   "still-failing={} size {}->{}".format(
                       still, original_len, len(reduced.emit())))

    print("self-test: {} of 9 checks failed".format(len(failures))
          if failures else "self-test: all 9 checks passed")
    return 1 if failures else 0


def find_sabotage_case(groups, args):
    """First case of seed 97 whose sabotaged expectation differs."""
    for case in range(120):
        prog, _ = generate_case(97, case, groups, args.max_depth,
                                args.max_stmts)
        real = oracle_expected(prog)
        wrong = oracle_expected(prog, sabotage="flip-gt")
        if real is not None and wrong is not None and real != wrong:
            return case
    return None


# ---------------------------------------------------------------------------
# CLI

def main():
    ap = argparse.ArgumentParser(
        description="semantic differential fuzzer for Beans")
    ap.add_argument("--seed", type=int,
                    default=int(os.environ.get("FUZZ_SEED", "1")))
    ap.add_argument("--cases", type=int,
                    default=int(os.environ.get("FUZZ_CASES", "50")))
    ap.add_argument("--start", type=int,
                    default=int(os.environ.get("FUZZ_START", "0")))
    ap.add_argument("--max-depth", type=int,
                    default=int(os.environ.get("FUZZ_DEPTH", "4")))
    ap.add_argument("--max-stmts", type=int,
                    default=int(os.environ.get("FUZZ_STMTS", "12")))
    ap.add_argument("--groups",
                    default=os.environ.get(
                        "FUZZ_GROUPS",
                        "core,widths,strings,structs,enums"))
    ap.add_argument("--lanes",
                    default=os.environ.get("FUZZ_LANES", "all"))
    ap.add_argument("--timeout-run", type=float,
                    default=float(os.environ.get("FUZZ_TIMEOUT", "20")))
    ap.add_argument("--timeout-build", type=float,
                    default=float(os.environ.get("FUZZ_TIMEOUT_BUILD",
                                                 "120")))
    ap.add_argument("--beansc0", default="build/beansc0")
    ap.add_argument("--beansc", default="build/beansc")
    ap.add_argument("--out", default="build/differential-fuzz")
    ap.add_argument("--keep", action="store_true",
                    help="keep per-case work directories")
    ap.add_argument("--keep-going", action="store_true",
                    help="continue after a failing case")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--replay", metavar="SEED:CASE",
                    help="regenerate and run one case, print its source")
    ap.add_argument("--replay-dir", metavar="DIR",
                    help="re-run a saved failure directory")
    ap.add_argument("--reduce", metavar="SEED:CASE",
                    help="reduce one failing case")
    ap.add_argument("--reduce-failures", action="store_true",
                    help="reduce every failure found while fuzzing")
    ap.add_argument("--reduce-budget", type=int, default=400)
    ap.add_argument("--corpus", metavar="DIR",
                    help="write a fixed corpus with expectations to DIR")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--selftest-cases", type=int, default=6)
    args = ap.parse_args()

    if args.self_test:
        return self_test(args)
    if args.corpus:
        return emit_corpus(args)
    if args.replay:
        return replay_case(args)
    if args.replay_dir:
        return replay_dir(args)
    if args.reduce:
        seed, case = parse_case_ref(args.reduce)
        out_root = args.out
        os.makedirs(out_root, exist_ok=True)
        runner = make_runner(args, out_root)
        config = {"groups": args.groups.split(","),
                  "max_depth": args.max_depth,
                  "max_stmts": args.max_stmts, "lanes": runner.lanes}
        result = reduce_failure(runner, out_root, seed, case, config,
                                args.reduce_budget)
        return 0 if result else 1
    return fuzz_loop(args)


if __name__ == "__main__":
    sys.exit(main())
