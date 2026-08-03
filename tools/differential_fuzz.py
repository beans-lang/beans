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
import concurrent.futures
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


class ClassType:
    """A generated class. Dispatch identity lives in integer slots: an
    override shares its parent method's slot; a child method that merely
    reuses the name of a parent method it cannot see (private, other
    package) gets a fresh slot, so the two never dispatch to each other."""

    def __init__(self, name, parent, package):
        self.name = name
        self.parent = parent      # ClassType or None
        self.package = package    # "" is the module root package
        self.parent_display = None  # how `extends` spells the parent
        self.is_pub = False
        self.fields = []          # (fname, type, default_or_None, is_pub)
        self.methods = []         # MethodDecl declared in this class
        self.init = None          # InitDecl
        self.has_deinit = False
        self.deinit_body = []     # Print statements over self fields

    def chain(self):
        c = self
        while c is not None:
            yield c
            c = c.parent

    def field_owner(self, fname):
        for c in self.chain():
            for n, _t, _d, _p in c.fields:
                if n == fname:
                    return c
        return None

    def field_type(self, fname):
        for c in self.chain():
            for n, t, _d, _p in c.fields:
                if n == fname:
                    return t
        raise KeyError(fname)

    def is_descendant_of(self, other):
        return any(c is other for c in self.chain())


class InitDecl:
    def __init__(self, params, own_assigns, super_args, post):
        self.params = params            # list of (name, type)
        self.own_assigns = own_assigns  # list of (fname, Expr)
        self.super_args = super_args    # list of Expr, or None: no super
        self.post = post                # trailing statements (prints)


class MethodDecl:
    def __init__(self, name, params, ret, is_pub, is_override, slot):
        self.name = name
        self.params = params      # list of (name, type)
        self.ret = ret            # type name or None
        self.ret_class = None     # ClassType when ret is a class
        self.body = []
        self.is_pub = is_pub
        self.is_override = is_override
        self.slot = slot          # int dispatch slot
        self.owner = None         # ClassType, set when attached


def resolve_impl(cls, slot):
    """Most-derived implementation of a dispatch slot at or above cls."""
    for c in cls.chain():
        for m in c.methods:
            if m.slot == slot:
                return m
    return None


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


class ObjVal:
    """A class instance under explicit reference counting. The oracle
    retains and releases at the same points the implementations do, so
    deinit output lands on exactly the same line in every lane."""

    __slots__ = ("cls", "fields", "rc", "oid")

    def __init__(self, cls, oid):
        self.cls = cls
        self.fields = {}
        self.rc = 1
        self.oid = oid


def copy_value(v):
    return v.copy() if isinstance(v, StructVal) else v


def owned_value(interp, v):
    """Turn a stored value into an owned result: class references gain a
    reference count, structs copy, scalars pass through."""
    if isinstance(v, ObjVal):
        v.rc += 1
        return v
    return copy_value(v)


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
        return owned_value(env.interp, env.lookup(self.name))


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
    def __init__(self, fn, args, display=None):
        self.fn = fn  # FnDecl
        self.args = args
        self.type = fn.ret
        self.display = display  # qualified spelling for cross-package calls

    def children(self):
        return list(self.args)

    def replace_child(self, i, new):
        self.args[i] = new

    def emit(self):
        return "{}({})".format(self.display or self.fn.name,
                               ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        vals = [a.eval(env) for a in self.args]
        # resolve by name: reducer edits clone subtrees, and a cloned
        # FnDecl must not shadow the program's registered one
        result = env.interp.call_by_name(self.fn.name, vals)
        # temporaries made for a call's arguments die when it returns,
        # newest first — every implementation lane releases here
        for v in reversed(vals):
            env.interp.release(v)
        return result


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
        base = self.base.eval(env)
        result = owned_value(env.interp, base.fields[self.field])
        env.interp.release(base)
        return result


class NewObj(Expr):
    def __init__(self, cls, args, display=None):
        self.cls = cls
        self.args = args
        self.type = display or cls.name
        self.display = display or cls.name

    def children(self):
        return list(self.args)

    def replace_child(self, i, new):
        self.args[i] = new

    def emit(self):
        return "new {}({})".format(self.display,
                                   ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        vals = [a.eval(env) for a in self.args]
        obj = env.interp.construct(self.cls, vals)
        for v in reversed(vals):
            env.interp.release(v)
        return obj


class MethodCall(Expr):
    """recv.m(args) — dynamic dispatch through the receiver's slot."""

    def __init__(self, recv, mname, slot, args, t):
        self.recv = recv
        self.mname = mname
        self.slot = slot
        self.args = args
        self.type = t

    def children(self):
        return [self.recv] + list(self.args)

    def replace_child(self, i, new):
        if i == 0:
            self.recv = new
        else:
            self.args[i - 1] = new

    def emit(self):
        return "{}.{}({})".format(self.recv.emit(), self.mname,
                                  ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        obj = self.recv.eval(env)
        if not isinstance(obj, ObjVal):
            raise OracleUnsupported("method call on a non-object")
        vals = [a.eval(env) for a in self.args]
        impl = resolve_impl(obj.cls, self.slot)
        if impl is None:
            raise OracleUnsupported("no implementation of slot")
        result = env.interp.invoke_method(impl, obj, vals)
        for v in reversed(vals):
            env.interp.release(v)
        env.interp.release(obj)
        return result


class SuperCall(Expr):
    """super.m(args) inside a method of owner_cls: the nearest parent
    implementation runs directly on the current self, no dispatch."""

    def __init__(self, owner_cls, mname, slot, args, t):
        self.owner_cls = owner_cls
        self.mname = mname
        self.slot = slot
        self.args = args
        self.type = t

    def children(self):
        return list(self.args)

    def replace_child(self, i, new):
        self.args[i] = new

    def emit(self):
        return "super.{}({})".format(self.mname,
                                     ", ".join(a.emit() for a in self.args))

    def eval(self, env):
        obj = env.lookup("self")
        vals = [a.eval(env) for a in self.args]
        impl = resolve_impl(self.owner_cls.parent, self.slot)
        if impl is None:
            raise OracleUnsupported("no parent implementation")
        result = env.interp.invoke_method(impl, obj, vals)
        for v in reversed(vals):
            env.interp.release(v)
        return result


class SelfField(Expr):
    def __init__(self, fname, t):
        self.fname = fname
        self.type = t

    def emit(self):
        return "self.{}".format(self.fname)

    def eval(self, env):
        obj = env.lookup("self")
        return owned_value(env.interp, obj.fields[self.fname])


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
                    env.declare(name, pv, owned=False)
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
        holder = env.lookup(self.name)
        value = self.expr.eval(env)
        old = holder.fields.get(self.field)
        holder.fields[self.field] = value
        env.interp.release(old)


class SelfFieldAssign(Stmt):
    """self.field = expr inside a method body."""

    def __init__(self, field, expr):
        self.field = field
        self.expr = expr

    def emit(self, ind):
        return ["{}self.{} = {}".format(ind, self.field,
                                        self.expr.emit())]

    def exec(self, env):
        holder = env.lookup("self")
        value = self.expr.eval(env)
        old = holder.fields.get(self.field)
        holder.fields[self.field] = value
        env.interp.release(old)


class ExprStmt(Stmt):
    """A call whose value is discarded; an owned result dies here."""

    def __init__(self, expr):
        self.expr = expr

    def emit(self, ind):
        return [ind + self.expr.emit()]

    def exec(self, env):
        env.interp.release(self.expr.eval(env))


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
            env.push()
            try:
                env.interp.run_block(self.then_body, env)
            finally:
                env.pop()
        elif self.else_body is not None:
            env.push()
            try:
                env.interp.run_block(self.else_body, env)
            finally:
                env.pop()


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
                    env.declare(name, pv, owned=False)
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
        self.ret = ret        # type name (possibly qualified) or None
        self.body = body
        self.package = ""     # "" is the module root package
        self.is_pub = False
        self.param_class_refs = {}  # index -> ClassType
        self.ret_class = None       # ClassType when ret names a class

    def emit(self):
        sig = ", ".join("{}: {}".format(n, t) for n, t in self.params)
        head = "fn {}({})".format(self.name, sig)
        if self.is_pub:
            head = "pub " + head
        if self.ret is not None:
            head += " -> {}".format(self.ret)
        out = [head + " {"]
        for s in self.body:
            out.extend(s.emit("    "))
        out.append("}")
        return out


MODULE_NAME = "dfuzz"


def emit_class(cls):
    head = "class " + cls.name
    if cls.is_pub:
        head = "pub " + head
    if cls.parent is not None:
        head += " extends " + (cls.parent_display or cls.parent.name)
    out = [head + " {"]
    for fname, ftype, dflt, fpub in cls.fields:
        line = "    {}{}: {}".format("pub " if fpub else "", fname, ftype)
        if dflt is not None:
            line += " = {}".format(IntLit(ftype, dflt).emit()
                                   if ftype != BOOL else
                                   ("true" if dflt else "false"))
        out.append(line)
    if cls.fields:
        out.append("")
    ini = cls.init
    sig = ", ".join("{}: {}".format(n, t) for n, t in ini.params)
    out.append("    {}fn init({}) {{".format(
        "pub " if cls.is_pub else "", sig))
    for fname, expr in ini.own_assigns:
        out.append("        self.{} = {}".format(fname, expr.emit()))
    if ini.super_args is not None:
        out.append("        super.init({})".format(
            ", ".join(a.emit() for a in ini.super_args)))
    for s in ini.post:
        out.extend(s.emit("        "))
    out.append("    }")
    if cls.has_deinit:
        out.append("")
        out.append("    fn deinit() {")
        for s in cls.deinit_body:
            out.extend(s.emit("        "))
        out.append("    }")
    for m in cls.methods:
        out.append("")
        sig = ", ".join("{}: {}".format(n, t) for n, t in m.params)
        head = "    {}{}fn {}({})".format(
            "pub " if m.is_pub else "",
            "override " if m.is_override else "", m.name, sig)
        if m.ret is not None:
            head += " -> {}".format(m.ret)
        out.append(head + " {")
        for s in m.body:
            out.extend(s.emit("        "))
        out.append("    }")
    out.append("}")
    return out


class Program:
    def __init__(self):
        self.structs = []   # StructType
        self.enums = []     # EnumType
        self.fns = []       # FnDecl, callable helpers in definition order
        self.classes = []   # ClassType in declaration order
        self.main = []      # statements
        self.uses_os = False
        self.packages = []       # sub-package names, generation order
        self.imports = {}        # (from_pkg, to_pkg) -> alias or None
        self.pkg_prints = set()  # packages whose bodies print

    def body_decls(self, package):
        for st in self.structs:
            yield ("struct", st)
        for en in self.enums:
            yield ("enum", en)
        for cls in self.classes:
            if cls.package == package:
                yield ("class", cls)
        for fn in self.fns:
            if fn.package == package:
                yield ("fn", fn)

    def emit_decl_lines(self, package):
        out = []
        for kind, d in self.body_decls(package):
            if kind == "struct":
                out.append("struct {} {{".format(d.name))
                for n, t in d.fields:
                    out.append("    {}: {}".format(n, t))
                out.append("}")
            elif kind == "enum":
                out.append("enum {} {{".format(d.name))
                for v, payload in d.variants:
                    if payload:
                        args = ", ".join("p{}: {}".format(i, t)
                                         for i, t in enumerate(payload))
                        out.append("    {}({})".format(v, args))
                    else:
                        out.append("    " + v)
                out.append("}")
            elif kind == "class":
                out.extend(emit_class(d))
            else:
                out.extend(d.emit())
            out.append("")
        return out

    def import_lines(self, package, prints):
        out = []
        if prints:
            out.append("import std.io")
        if self.uses_os and package == "":
            out.append("import std.os")
        deps = sorted((to, alias)
                      for (frm, to), alias in self.imports.items()
                      if frm == package)
        for to, alias in deps:
            line = "import {}.{}".format(MODULE_NAME, to)
            if alias:
                line += " as " + alias
            out.append(line)
        return out

    def emit(self):
        """The root file. For a single-file program this is everything."""
        out = self.import_lines("", True)
        out.append("")
        out.extend(self.emit_decl_lines(""))
        out.append("fn main() {")
        for s in self.main:
            out.extend(s.emit("    "))
        out.append("}")
        return "\n".join(out) + "\n"

    def emit_files(self):
        files = {"main.b": self.emit()}
        if self.packages:
            files["beans.pot"] = "module {}\n".format(MODULE_NAME)
            for pkg in self.packages:
                out = self.import_lines(pkg, pkg in self.pkg_prints)
                if out:
                    out.append("")
                out.extend(self.emit_decl_lines(pkg))
                while out and out[-1] == "":
                    out.pop()
                files["{}/{}.b".format(pkg, pkg)] = "\n".join(out) + "\n"
        return files


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
    """Scoped bindings with ownership: leaving a scope releases the class
    references its locals own, newest declaration first — the drop order
    every implementation lane produces. Borrowed bindings (parameters,
    self, loop and match variables) are never released here."""

    def __init__(self, interp):
        self.interp = interp
        self.scopes = [{}]  # name -> [value, owned]

    def push(self):
        self.scopes.append({})

    def pop(self):
        scope = self.scopes.pop()
        for name in reversed(list(scope)):
            value, owned = scope[name]
            if owned:
                self.interp.release(value)

    def pop_all(self):
        while self.scopes:
            self.pop()

    def declare(self, name, value, owned=True):
        self.scopes[-1][name] = [value, owned]

    def lookup(self, name):
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name][0]
        raise OracleUnsupported("unbound name " + name)

    def assign(self, name, value):
        for scope in reversed(self.scopes):
            if name in scope:
                slot = scope[name]
                old, owned = slot
                slot[0] = value
                slot[1] = True
                if owned:
                    self.interp.release(old)
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
        self.next_oid = 1

    def burn(self):
        self.fuel -= 1
        if self.fuel <= 0:
            raise OracleUnsupported("evaluation fuel exhausted")

    def run_block(self, stmts, env):
        for s in stmts:
            self.burn()
            s.exec(env)

    # ---- reference counting ---------------------------------------------

    def release(self, v):
        if not isinstance(v, ObjVal):
            return
        v.rc -= 1
        if v.rc == 0:
            self.teardown(v)
        elif v.rc < 0:
            raise AssertionError("negative refcount on " + v.cls.name)

    def teardown(self, obj):
        """deinit bodies run child first, then each base; afterwards the
        fields release, the object's own class first and each class's
        fields in reverse declaration order — the shared canonical order
        of the stage-0 interpreter and both native backends."""
        self.burn()
        for c in obj.cls.chain():
            if c.has_deinit:
                env = Env(self)
                env.declare("self", obj, owned=False)
                self.run_block(c.deinit_body, env)
        for c in obj.cls.chain():
            for fname, _t, _d, _p in reversed(c.fields):
                value = obj.fields.get(fname)
                if isinstance(value, ObjVal):
                    del obj.fields[fname]
                    self.release(value)

    # ---- classes ---------------------------------------------------------

    def construct(self, cls, owned_args):
        self.burn()
        obj = ObjVal(cls, self.next_oid)
        self.next_oid += 1
        for c in cls.chain():
            for fname, _t, dflt, _p in c.fields:
                if dflt is not None:
                    obj.fields[fname] = dflt
        self.run_init(cls, obj, owned_args)
        return obj

    def run_init(self, cls, obj, owned_args):
        ini = cls.init
        if ini is None:
            raise OracleUnsupported("class without init constructed")
        env = Env(self)
        env.declare("self", obj, owned=False)
        for (pname, _t), v in zip(ini.params, owned_args):
            env.declare(pname, v, owned=False)
        for fname, expr in ini.own_assigns:
            old = obj.fields.get(fname)
            obj.fields[fname] = expr.eval(env)
            self.release(old)
        if ini.super_args is not None:
            sup = [a.eval(env) for a in ini.super_args]
            self.run_init(cls.parent, obj, sup)
            for v in reversed(sup):
                self.release(v)
        self.run_block(ini.post, env)

    def invoke_method(self, impl, obj, owned_args):
        self.burn()
        env = Env(self)
        env.declare("self", obj, owned=False)
        for (pname, _t), v in zip(impl.params, owned_args):
            env.declare(pname, v, owned=False)
        try:
            self.run_block(impl.body, env)
        except ReturnValue as r:
            return r.value
        finally:
            env.pop_all()
        if impl.ret is not None:
            raise OracleUnsupported(
                "method {} finished without a return".format(impl.name))
        return None

    def call_by_name(self, name, args):
        self.burn()
        fn = self.fns.get(name)
        if fn is None:
            raise OracleUnsupported("call to a removed function " + name)
        env = Env(self)
        for (pname, _), v in zip(fn.params, args):
            env.declare(pname, v, owned=False)
        try:
            self.run_block(fn.body, env)
        except ReturnValue as r:
            return r.value
        finally:
            env.pop_all()
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
            # normal completion drops main's locals; os.exit does not run
            # deinit in any lane, so ProgramExit skips the release walk
            env.pop_all()
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

GROUPS = ("core", "widths", "strings", "structs", "enums", "classes",
          "packages")

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
        # classes / packages state
        self.class_mode = bool(self.groups & {"classes", "packages"})
        self.slot_seq = 0
        self.var_class = {}       # local var name -> static ClassType
        self.alias_choice = {}    # (from_pkg, to_pkg) -> alias or None
        self.cur_pkg = ""         # package whose code is being generated
        self.cur_class = None     # class whose method body is generated
        self.cur_slot = None      # ceiling: bodies call only lower slots

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
        # structs and enums are declared in the module root package, so
        # code generated for a sub-package cannot name them
        if "structs" in self.groups and not self.cur_pkg:
            out.extend(st.name for st in self.prog.structs)
        if "enums" in self.groups and not self.cur_pkg:
            out.extend(en.name for en in self.prog.enums)
        return out

    def class_for_type(self, t):
        if not self.class_mode:
            return None
        bare = t.split(".")[-1]
        for c in self.prog.classes:
            if c.name == bare:
                return c
        return None

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

    # ---- classes and packages --------------------------------------------

    def display(self, cls, from_pkg):
        """How code in from_pkg spells cls, registering the import."""
        if cls.package == from_pkg:
            return cls.name
        key = (from_pkg, cls.package)
        if key not in self.prog.imports:
            self.prog.imports[key] = self.alias_choice.get(key)
        prefix = self.prog.imports[key] or cls.package
        return "{}.{}".format(prefix, cls.name)

    def fn_display(self, fn, from_pkg):
        if fn.package == from_pkg:
            return None
        key = (from_pkg, fn.package)
        if key not in self.prog.imports:
            self.prog.imports[key] = self.alias_choice.get(key)
        prefix = self.prog.imports[key] or fn.package
        return "{}.{}".format(prefix, fn.name)

    def pkg_index(self, pkg):
        """Import direction: pkg i may import pkg j only for j < i, and
        the module root ("") imports every sub-package but is imported
        by none of them."""
        if pkg == "":
            return len(self.prog.packages)
        return self.prog.packages.index(pkg)

    def pkg_reachable(self, from_pkg, decl_pkg):
        if decl_pkg == from_pkg:
            return True
        return self.pkg_index(decl_pkg) < self.pkg_index(from_pkg)

    def class_visible(self, cls, from_pkg):
        if cls.package == from_pkg:
            return True
        return cls.is_pub and self.pkg_reachable(from_pkg, cls.package)

    def constructible(self, cls, from_pkg):
        # init visibility follows the class: `pub fn init` iff pub class
        return self.class_visible(cls, from_pkg)

    def visible_int_fields(self, cls, from_pkg):
        """(fname, ftype) of scalar fields reachable from from_pkg."""
        out = []
        for c in cls.chain():
            for fname, ftype, _d, fpub in c.fields:
                if not (is_int_type(ftype) or ftype == BOOL):
                    continue
                if c.package == from_pkg or (fpub and c.is_pub):
                    out.append((fname, ftype))
        return out

    def own_int_fields(self, cls):
        return [(n, t) for n, t, _d, _p in cls.fields
                if is_int_type(t) or t == BOOL]

    def visible_methods(self, cls, from_pkg):
        """Nearest declaration per name that from_pkg may call."""
        out = []
        seen = set()
        for c in cls.chain():
            for m in c.methods:
                if m.name in seen:
                    continue
                seen.add(m.name)
                if m.is_pub or c.package == from_pkg:
                    out.append(m)
        return out

    def note_prints(self):
        if self.cur_pkg:
            self.prog.pkg_prints.add(self.cur_pkg)

    def gen_class_world(self):
        r = self.rng
        if "packages" in self.groups:
            self.prog.packages = [
                "pk" + chr(ord("a") + i) for i in range(r.randint(1, 3))]
            pair_pool = [(f, t)
                         for f in [""] + self.prog.packages
                         for t in self.prog.packages if f != t]
            for key in pair_pool:
                if r.random() < 0.25:
                    self.alias_choice[key] = self.fresh("al")
        pkgs = self.prog.packages
        for _ in range(r.randint(1, 2)):
            depth = r.randint(1, 3)
            parent = None
            first = None
            for _level in range(depth):
                cls = self.gen_class_skeleton(parent)
                if first is None:
                    first = cls
                parent = cls
            if depth >= 2 and r.random() < 0.35:
                self.gen_class_skeleton(first)
        # bodies fill in declaration order; a body only calls dispatch
        # slots numbered below its own, so the runtime call graph is a DAG
        for cls in self.prog.classes:
            for m in list(cls.methods):
                self.fill_method_body(m)
        self.cur_class = None
        self.cur_slot = None
        self.cur_pkg = ""

    def pick_class_package(self, parent):
        r = self.rng
        pkgs = self.prog.packages
        if not pkgs:
            return ""
        choices = [""] + pkgs
        if parent is None:
            return r.choice(choices)
        if not parent.is_pub:
            return parent.package
        # the child's package must be able to import the parent's: the
        # root imports everything; pkg i sees pkg j only for j < i
        legal = [""]
        if parent.package:
            base = pkgs.index(parent.package)
            legal += pkgs[base:]
        else:
            legal = [""]
        return r.choice(legal)

    def gen_class_skeleton(self, parent):
        r = self.rng
        cls = ClassType(self.fresh("K"), parent,
                        self.pick_class_package(parent))
        if parent is not None:
            cls.parent_display = self.display(parent, cls.package)
        if self.prog.packages:
            cls.is_pub = parent.is_pub if parent is not None \
                else r.random() < 0.85
            if parent is not None and cls.package != parent.package:
                cls.is_pub = True if r.random() < 0.7 else cls.is_pub
        else:
            cls.is_pub = r.random() < 0.3
        n_fields = r.randint(1, 3) if parent is None else r.randint(0, 2)
        int_pool = self.int_types() + [BOOL]
        for _ in range(n_fields):
            ftype = r.choice(int_pool)
            dflt = None
            if ftype != BOOL and r.random() < 0.4:
                dflt = r.randint(0, 9)
            fpub = r.random() < (0.7 if self.prog.packages else 0.5)
            cls.fields.append((self.fresh("g"), ftype, dflt, fpub))
        # at most one class-typed field, initialized inline so the
        # construction graph follows declaration order
        targets = [c for c in self.prog.classes
                   if self.class_visible(c, cls.package)
                   and self.constructible(c, cls.package)]
        obj_field = None
        if targets and r.random() < 0.35:
            target = r.choice(targets)
            obj_field = (self.fresh("g"),
                         self.display(target, cls.package), None,
                         r.random() < 0.5)
            cls.fields.append(obj_field)
            self.register_class_field(cls, obj_field[0], target)
        self.gen_init(cls, obj_field)
        if r.random() < 0.5:
            cls.has_deinit = True
            parts = [("lit", "d" + cls.name)]
            for fname, _t in self.own_int_fields(cls)[:2]:
                parts.append(("lit", " "))
                parts.append(("expr", SelfField(fname, _t)))
            cls.deinit_body = [Print(parts)]
            if cls.package:
                self.prog.pkg_prints.add(cls.package)
        self.gen_method_skeletons(cls)
        self.prog.classes.append(cls)
        return cls

    def register_class_field(self, cls, fname, target):
        if not hasattr(cls, "obj_fields"):
            cls.obj_fields = {}
        cls.obj_fields[fname] = target

    def class_field_target(self, cls, fname):
        for c in cls.chain():
            found = getattr(c, "obj_fields", {}).get(fname)
            if found is not None:
                return found
        return None

    def gen_init(self, cls, obj_field):
        r = self.rng
        params = []
        own_assigns = []
        for fname, ftype, dflt, _p in cls.fields:
            if obj_field is not None and fname == obj_field[0]:
                target = self.class_field_target(cls, fname)
                args = [IntLit(t, self.gen_int_value(t))
                        if t != BOOL else BoolLit(r.random() < 0.5)
                        for _n, t in target.init.params]
                own_assigns.append(
                    (fname, NewObj(target, args,
                                   self.display(target, cls.package))))
                continue
            if dflt is not None:
                if r.random() < 0.3:
                    own_assigns.append(
                        (fname, IntLit(ftype, self.gen_int_value(ftype))))
                continue
            if ftype != BOOL and r.random() < 0.6:
                pname = self.fresh("q")
                params.append((pname, ftype))
                own_assigns.append((fname, VarRef(pname, ftype)))
            elif ftype == BOOL:
                own_assigns.append((fname, BoolLit(r.random() < 0.5)))
            else:
                own_assigns.append(
                    (fname, IntLit(ftype, self.gen_int_value(ftype))))
        super_args = None
        if cls.parent is not None:
            super_args = []
            for _pn, pt in cls.parent.init.params:
                if pt == BOOL:
                    super_args.append(BoolLit(r.random() < 0.5))
                elif params and r.random() < 0.4:
                    same = [p for p in params if p[1] == pt]
                    if same:
                        pick = r.choice(same)
                        super_args.append(VarRef(pick[0], pt))
                    else:
                        super_args.append(
                            IntLit(pt, self.gen_int_value(pt)))
                else:
                    super_args.append(
                        IntLit(pt, self.gen_int_value(pt)))
        post = []
        if r.random() < 0.3 and self.print_budget > 0:
            self.print_budget -= 1
            if cls.package:
                self.prog.pkg_prints.add(cls.package)
            parts = [("lit", "i" + cls.name)]
            for fname, ftype in self.own_int_fields(cls)[:1]:
                parts.append(("lit", " "))
                parts.append(("expr", SelfField(fname, ftype)))
            post.append(Print(parts))
        cls.init = InitDecl(params, own_assigns, super_args, post)

    def gen_method_skeletons(self, cls):
        r = self.rng
        pub_p = 0.75 if self.prog.packages else 0.5
        for _ in range(r.randint(1, 2)):
            roll = r.random()
            ret_class = None
            if roll < 0.5:
                params = ([(self.fresh("q"), "int")]
                          if r.random() < 0.5 else [])
                ret = "int"
            elif roll < 0.8:
                params = ([(self.fresh("q"), "int")]
                          if r.random() < 0.7 else [])
                ret = None
            else:
                pool = [c for c in self.prog.classes
                        if self.constructible(c, cls.package)
                        and (not self.prog.packages or c.is_pub)]
                if pool:
                    ret_class = r.choice(pool)
                    ret = self.display(ret_class, cls.package)
                    params = []
                else:
                    params = []
                    ret = "int"
            m = MethodDecl(self.fresh("m"), params, ret,
                           r.random() < pub_p, False, self.slot_seq)
            m.ret_class = ret_class
            self.slot_seq += 1
            m.owner = cls
            cls.methods.append(m)
        if cls.parent is None:
            return
        # overrides of visible inherited slots, and package-private
        # shadows of slots the child cannot see
        seen = set(m.name for m in cls.methods)
        for c in list(cls.parent.chain()):
            for m in list(c.methods):
                if m.name in seen:
                    continue
                seen.add(m.name)
                visible = m.is_pub or c.package == cls.package
                # a return type is spelled from the declaring package,
                # so an override in another package respells it
                ret = m.ret
                if m.ret_class is not None:
                    if not self.class_visible(m.ret_class, cls.package):
                        continue
                    ret = self.display(m.ret_class, cls.package)
                if visible and r.random() < 0.4:
                    o = MethodDecl(m.name, [(self.fresh("q"), t)
                                            for _n, t in m.params],
                                   ret, m.is_pub, True, m.slot)
                    o.ret_class = m.ret_class
                    o.owner = cls
                    cls.methods.append(o)
                elif not visible and r.random() < 0.5:
                    # a fresh public method wearing a private parent
                    # method's name: a new dispatch slot, never an override
                    s = MethodDecl(m.name, [(self.fresh("q"), t)
                                            for _n, t in m.params],
                                   ret, True, False, self.slot_seq)
                    s.ret_class = m.ret_class
                    self.slot_seq += 1
                    s.owner = cls
                    cls.methods.append(s)
                    self.ensure_revealer(c, m)

    def ensure_revealer(self, owner, private_method):
        """A pub parent method whose body calls the private slot, so the
        shadow-vs-override distinction shows up in program output."""
        if private_method.ret != "int":
            return
        for m in owner.methods:
            if getattr(m, "reveals", None) == private_method.slot:
                return
        m = MethodDecl(self.fresh("m"), [], "int", True, False,
                       self.slot_seq)
        self.slot_seq += 1
        m.owner = owner
        m.reveals = private_method.slot
        owner.methods.append(m)

    def method_int_terms(self, cls, params):
        terms = [SelfField(n, t)
                 for n, t in self.visible_int_fields(cls, cls.package)
                 if t == "int"]
        terms += [VarRef(n, t) for n, t in params if t == "int"]
        return terms

    def gen_method_int_expr(self, m, depth):
        r = self.rng
        cls = m.owner
        terms = self.method_int_terms(cls, m.params)
        callables = [c for c in self.visible_methods(cls, cls.package)
                     if c.ret == "int" and c.slot < m.slot]
        roll = r.random()
        if depth > 0 and roll < 0.35 and terms:
            op = r.choice(("+", "-", "*"))
            return Binary(op, self.gen_method_int_expr(m, depth - 1),
                          self.gen_method_int_expr(m, depth - 1), "int")
        if depth > 0 and roll < 0.55 and callables:
            target = r.choice(callables)
            args = [self.gen_method_int_expr(m, 0)
                    if t == "int" else BoolLit(r.random() < 0.5)
                    for _n, t in target.params]
            return MethodCall(VarRef("self", cls.name), target.name,
                              target.slot, args, target.ret)
        if terms and roll < 0.85:
            return copy.deepcopy(r.choice(terms))
        return IntLit("int", r.randint(0, 30))

    def fill_method_body(self, m):
        r = self.rng
        cls = m.owner
        self.cur_class = cls
        self.cur_slot = m.slot
        self.cur_pkg = cls.package
        body = []
        if getattr(m, "reveals", None) is not None:
            impl = None
            for c in cls.chain():
                for cand in c.methods:
                    if cand.slot == m.reveals:
                        impl = cand
                        break
                if impl:
                    break
            args = [IntLit(t, self.gen_int_value(t))
                    if t != BOOL else BoolLit(r.random() < 0.5)
                    for _n, t in impl.params]
            body.append(Return(MethodCall(
                VarRef("self", cls.name), impl.name, impl.slot, args,
                "int")))
            m.body = body
            return
        writable = [(n, t)
                    for n, t in self.visible_int_fields(cls, cls.package)]
        if m.ret is None:
            for _ in range(r.randint(1, 2)):
                if writable and r.random() < 0.8:
                    fname, ftype = r.choice(writable)
                    if ftype == BOOL:
                        body.append(SelfFieldAssign(
                            fname, BoolLit(r.random() < 0.5)))
                    elif ftype == "int":
                        body.append(SelfFieldAssign(
                            fname, self.gen_method_int_expr(m, 2)))
                    else:
                        body.append(SelfFieldAssign(
                            fname,
                            IntLit(ftype, self.gen_int_value(ftype))))
            if m.is_override and r.random() < 0.6 and \
                    resolve_impl(cls.parent, m.slot) is not None:
                args = [self.gen_method_int_expr(m, 1)
                        if t == "int" else BoolLit(r.random() < 0.5)
                        for _n, t in m.params]
                body.append(ExprStmt(SuperCall(cls, m.name, m.slot, args,
                                               m.ret)))
            if r.random() < 0.25 and self.print_budget > 0:
                self.print_budget -= 1
                self.note_prints()
                parts = [("lit", "t" + m.name)]
                fields = self.visible_int_fields(cls, cls.package)
                if fields:
                    fname, ftype = r.choice(fields)
                    parts.append(("lit", " "))
                    parts.append(("expr", SelfField(fname, ftype)))
                body.append(Print(parts))
            m.body = body
            return
        if m.ret == "int":
            expr = self.gen_method_int_expr(m, 2)
            if m.is_override and r.random() < 0.6 and \
                    resolve_impl(cls.parent, m.slot) is not None:
                args = [self.gen_method_int_expr(m, 1)
                        if t == "int" else BoolLit(r.random() < 0.5)
                        for _n, t in m.params]
                sup = SuperCall(cls, m.name, m.slot, args, "int")
                expr = Binary(r.choice(("+", "-", "*")), sup, expr, "int")
            body.append(Return(expr))
            m.body = body
            return
        # object-returning method
        target = m.ret_class
        own_obj = [(n, self.class_field_target(cls, n))
                   for n, t, _d, _p in cls.fields
                   if self.class_field_target(cls, n) is not None]
        own_obj = [(n, t) for n, t in own_obj
                   if t is not None and t.is_descendant_of(target)]
        if own_obj and r.random() < 0.5:
            fname, _t = r.choice(own_obj)
            body.append(Return(SelfField(fname, m.ret)))
        else:
            args = [IntLit(t, self.gen_int_value(t))
                    if t != BOOL else BoolLit(r.random() < 0.5)
                    for _n, t in target.init.params]
            body.append(Return(NewObj(
                target, args, self.display(target, cls.package))))
        m.body = body

    # ---- declarations ----------------------------------------------------

    def gen_program(self):
        r = self.rng
        if "structs" in self.groups:
            for _ in range(r.randint(1, 2)):
                self.gen_struct()
        if "enums" in self.groups:
            for _ in range(r.randint(1, 2)):
                self.gen_enum()
        if self.class_mode:
            self.gen_class_world()
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
        fn_pkg = ""
        if self.prog.packages:
            fn_pkg = r.choice([""] + self.prog.packages)
        self.cur_pkg = fn_pkg
        self.var_class = {}
        params = []
        param_pool = self.scalar_types()
        if "structs" in self.groups:
            param_pool.extend(st.name for st in self.prog.structs)
        if "enums" in self.groups:
            param_pool.extend(en.name for en in self.prog.enums)
        if fn_pkg:
            param_pool = self.scalar_types()
        class_params = []
        if self.class_mode:
            class_params = [c for c in self.prog.classes
                            if self.class_visible(c, fn_pkg)]
        for _ in range(r.randint(0, 3)):
            if class_params and r.random() < 0.3:
                cls = r.choice(class_params)
                pname = self.fresh("p")
                params.append((pname, self.display(cls, fn_pkg)))
                self.var_class[pname] = cls
            else:
                params.append((self.fresh("p"), r.choice(param_pool)))
        ret_pool = self.scalar_types()
        if "structs" in self.groups and not fn_pkg:
            ret_pool.extend(st.name for st in self.prog.structs)
        ret_class = None
        if self.class_mode and class_params and r.random() < 0.3:
            ret_class = r.choice(
                [c for c in class_params
                 if self.constructible(c, fn_pkg)] or class_params)
            ret = self.display(ret_class, fn_pkg)
        else:
            ret = r.choice(ret_pool)
        fn = FnDecl(self.fresh("fn"), params, ret, [])
        fn.package = fn_pkg
        fn.is_pub = r.random() < 0.75 if self.prog.packages else False
        fn.ret_class = ret_class
        for i, (pname, _t) in enumerate(params):
            if pname in self.var_class:
                fn.param_class_refs[i] = self.var_class[pname]
        scope = Scope()
        for name, t in params:
            scope.vars.append((name, t, False))
        body = self.gen_block(scope, r.randint(1, 6), in_fn=fn)
        # an early return inside an if is fine; the final one is mandatory
        body.append(Return(self.gen_expr(ret, self.max_depth, scope)))
        fn.body = body
        self.prog.fns.append(fn)
        self.cur_pkg = ""

    def gen_main(self):
        r = self.rng
        self.cur_pkg = ""
        self.var_class = {}
        scope = Scope()
        body = self.gen_block(scope, r.randint(4, self.max_stmts),
                              in_fn=None, top=True)
        # checksum: print every live scalar so silent state corruption
        # in any lane becomes visible output
        parts = [("lit", "chk")]
        for name, t, _ in scope.vars:
            cls = self.var_class.get(name)
            if cls is not None:
                probe = self.checksum_obj(name, cls)
                if probe is not None:
                    parts.append(("lit", " "))
                    parts.append(("expr", probe))
            elif is_int_type(t) or t == BOOL:
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
        # objects dying at main's end print deinit lines the oracle
        # models; os.exit skips that teardown, so the class groups never
        # generate it (the draw stays so other groups keep their streams)
        exit_roll = r.random()
        if exit_roll < 0.10 and not self.class_mode:
            self.prog.uses_os = True
            body.append(Exit(r.randint(0, 99)))
        self.prog.main = body

    def checksum_obj(self, name, cls):
        recv = VarRef(name, self.display(cls, ""))
        for m in self.visible_methods(cls, ""):
            if m.ret == "int" and m.ret_class is None and not m.params:
                return MethodCall(recv, m.name, m.slot, [], "int")
        fields = self.visible_int_fields(cls, "")
        if fields:
            fname, ftype = fields[0]
            return FieldGet(recv, fname, ftype)
        return None

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
        if self.class_mode:
            if self.constructible_classes():
                choices += ["class_let"] * 2
            objs = self.scope_obj_vars(scope)
            if objs:
                if any(self.visible_int_fields(c, self.cur_pkg)
                       for _n, c in objs):
                    choices.append("obj_field_assign")
                if any(self.callable_slots(c) for _n, c in objs):
                    choices.append("method_stmt")
                obj_mut = [(n, c) for n, c in objs
                           if self.var_mutable(scope, n)]
                if obj_mut:
                    choices.append("class_assign")
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

        if kind == "class_let":
            concrete = r.choice(self.constructible_classes())
            declared = concrete
            ancestors = [c for c in concrete.chain()
                         if c is not concrete
                         and self.class_visible(c, self.cur_pkg)]
            if ancestors and r.random() < 0.4:
                declared = r.choice(ancestors)
            args = [self.gen_expr(pt, min(self.max_depth - 1, 2), scope)
                    for _n, pt in concrete.init.params]
            name = self.fresh("o")
            mut = r.random() < 0.5
            scope.vars.append(
                (name, self.display(declared, self.cur_pkg), mut))
            self.var_class[name] = declared
            return Let(name, self.display(declared, self.cur_pkg),
                       NewObj(concrete, args,
                              self.display(concrete, self.cur_pkg)),
                       mut)

        if kind == "class_assign":
            objs = [(n, c) for n, c in self.scope_obj_vars(scope)
                    if self.var_mutable(scope, n)]
            name, declared = r.choice(objs)
            src = self.gen_class_expr(declared, 2, scope)
            if src is None:
                src = self.gen_leaf(
                    self.display(declared, self.cur_pkg), scope)
            return Assign(name, src)

        if kind == "obj_field_assign":
            objs = [(n, c) for n, c in self.scope_obj_vars(scope)
                    if self.visible_int_fields(c, self.cur_pkg)]
            name, cls = r.choice(objs)
            fname, ftype = r.choice(
                self.visible_int_fields(cls, self.cur_pkg))
            if ftype == BOOL:
                value = self.gen_expr(BOOL, 1, scope)
            else:
                value = self.gen_expr(ftype, 2, scope)
            return FieldAssign(name, fname, value)

        if kind == "method_stmt":
            objs = [(n, c) for n, c in self.scope_obj_vars(scope)
                    if self.callable_slots(c)]
            name, cls = r.choice(objs)
            target = r.choice(self.callable_slots(cls))
            args = [self.gen_expr(pt, 2, scope)
                    for _n, pt in target.params]
            call = MethodCall(
                VarRef(name, self.display(cls, self.cur_pkg)),
                target.name, target.slot, args, target.ret)
            return ExprStmt(call)

        raise AssertionError(kind)

    def var_mutable(self, scope, name):
        for n, _t, m in scope.all_vars():
            if n == name:
                return m
        return False

    def constructible_classes(self):
        return [c for c in self.prog.classes
                if self.constructible(c, self.cur_pkg)]

    def callable_slots(self, cls):
        """Methods callable from the current package on this static type,
        excluding object-returning ones used as statements."""
        return [m for m in self.visible_methods(cls, self.cur_pkg)
                if m.ret_class is None]

    def gen_print(self, scope):
        r = self.rng
        self.note_prints()
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
        cls = self.class_for_type(t)
        if cls is not None:
            e = self.gen_class_expr(cls, depth, scope)
            if e is None:
                raise AssertionError("no expression for class " + t)
            return e
        raise AssertionError(t)

    def scope_obj_vars(self, scope, want=None):
        """(name, ClassType) locals whose static class satisfies want."""
        out = []
        for name, _t, _m in scope.all_vars():
            cls = self.var_class.get(name)
            if cls is None:
                continue
            if want is None or cls.is_descendant_of(want):
                out.append((name, cls))
        return out

    def constructible_descendants(self, want):
        return [c for c in self.prog.classes
                if c.is_descendant_of(want)
                and self.constructible(c, self.cur_pkg)]

    def gen_class_expr(self, cls, depth, scope):
        """An expression whose static type is cls (or a subclass being
        upcast). None when the current context cannot produce one."""
        r = self.rng
        vs = self.scope_obj_vars(scope, cls)
        makeable = self.constructible_descendants(cls)
        helpers = None
        if depth > 0:
            helpers = self.maybe_call_class(cls, depth, scope)
        choices = []
        if vs:
            choices += ["var"] * 3
        if makeable:
            choices += ["new"] * 3
        if helpers is not None:
            choices.append("call")
        if not choices:
            return None
        kind = r.choice(choices)
        if kind == "var":
            name, c = r.choice(vs)
            return VarRef(name, self.display(c, self.cur_pkg))
        if kind == "call":
            return helpers
        target = r.choice(makeable)
        args = [self.gen_expr(pt, min(depth - 1, 2), scope)
                for _n, pt in target.init.params]
        return NewObj(target, args, self.display(target, self.cur_pkg))

    def maybe_call_class(self, want, depth, scope):
        return self.maybe_call(self.display(want, self.cur_pkg),
                               depth, scope)

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
        cls = self.class_for_type(t)
        if cls is not None:
            vs = self.scope_obj_vars(scope, cls)
            if vs and r.random() < 0.6:
                name, c = r.choice(vs)
                return VarRef(name, self.display(c, self.cur_pkg))
            makeable = self.constructible_descendants(cls)
            if makeable:
                target = makeable[0]
                args = [self.gen_leaf(pt, scope)
                        for _n, pt in target.init.params]
                return NewObj(target, args,
                              self.display(target, self.cur_pkg))
            if vs:
                name, c = vs[0]
                return VarRef(name, self.display(c, self.cur_pkg))
            raise AssertionError("class leaf for " + t)
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
        want_cls = self.class_for_type(t)
        fns = []
        for f in self.prog.fns:
            if f.package != self.cur_pkg and not (
                    f.is_pub
                    and self.pkg_reachable(self.cur_pkg, f.package)):
                continue
            if want_cls is not None:
                if f.ret_class is not None and \
                        f.ret_class.is_descendant_of(want_cls):
                    fns.append(f)
            elif f.ret == t and f.ret_class is None:
                fns.append(f)
        if not fns:
            return None
        fn = r.choice(fns)
        args = []
        for i, (_n, pt) in enumerate(fn.params):
            cls = fn.param_class_refs.get(i)
            if cls is not None:
                arg = self.gen_class_expr(cls, min(depth - 1, 1), scope)
                if arg is None:
                    return None
                args.append(arg)
            else:
                args.append(self.gen_expr(pt, min(depth - 1, 2), scope))
        return Call(fn, args, self.fn_display(fn, self.cur_pkg))

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
        if roll < 0.80 and self.class_mode:
            obj = self.maybe_obj_int(t, depth, scope)
            if obj is not None:
                return obj
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

    def maybe_obj_int(self, t, depth, scope):
        """An int-typed read of an object in scope: a getter call or a
        field access on the variable's static type."""
        r = self.rng
        objs = self.scope_obj_vars(scope)
        if not objs:
            return None
        options = []
        for name, cls in objs:
            for m in self.visible_methods(cls, self.cur_pkg):
                if m.ret == t and m.ret_class is None:
                    options.append(("call", name, cls, m))
            for fname, ftype in self.visible_int_fields(
                    cls, self.cur_pkg):
                if ftype == t:
                    options.append(("field", name, cls, fname))
        if not options:
            return None
        pick = r.choice(options)
        recv = VarRef(pick[1], self.display(pick[2], self.cur_pkg))
        if pick[0] == "call":
            m = pick[3]
            args = [self.gen_expr(pt, min(depth - 1, 1), scope)
                    for _n, pt in m.params]
            return MethodCall(recv, m.name, m.slot, args, m.ret)
        return FieldGet(recv, pick[3], t)

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
            env.push()
            try:
                env.interp.run_block(self.body, env)
            except BreakLoop:
                env.pop()
                break
            except ContinueLoop:
                env.pop()
            else:
                env.pop()


def generate_case(seed, case, groups, max_depth, max_stmts):
    """Deterministic (seed, case) -> (Program, source_text)."""
    gen = Gen(seed, case, groups, max_depth, max_stmts)
    prog = gen.gen_program()
    return prog, prog.emit()


def generate_case_files(seed, case, groups, max_depth, max_stmts):
    """Deterministic (seed, case) -> (Program, {relpath: text})."""
    gen = Gen(seed, case, groups, max_depth, max_stmts)
    prog = gen.gen_program()
    return prog, prog.emit_files()


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
                 workdir, jobs=1):
        self.beansc0 = beansc0
        self.beansc = beansc
        self.lanes = list(lanes)
        self.timeout_build = timeout_build
        self.timeout_run = timeout_run
        self.workdir = workdir
        self.jobs = max(1, jobs)
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

    def run_lane(self, lane, case_dir, main_file):
        """Build and run one lane; every artifact path is lane-unique, so
        lanes are safe to run concurrently."""
        cc = self.compiler_for(lane)
        cmds = []
        if lane.startswith("interp"):
            cmd = [cc, "run", main_file]
            cmds.append(cmd)
            kind, out, err, code = run_proc(cmd, self.timeout_run)
            return LaneResult(lane, kind, out, err, code, cmds)
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
            return LaneResult(lane, "timeout", out, err, code,
                              cmds, "compiler timed out")
        if kind == "crash":
            return LaneResult(lane, "crash", out, err, code,
                              cmds, "compiler crashed")
        if code != 0:
            return LaneResult(lane, "build-fail", out, err, code, cmds)
        run_cmd = [binary]
        cmds.append(run_cmd)
        kind, out, err, code = run_proc(run_cmd, self.timeout_run)
        return LaneResult(lane, kind, out, err, code, cmds)

    def run_case(self, case_dir, main_file):
        """Run every configured lane; returns list of LaneResult in lane
        order regardless of completion order, so reports stay stable."""
        if self.jobs > 1 and len(self.lanes) > 1:
            by_lane = {}
            with concurrent.futures.ThreadPoolExecutor(
                    max_workers=self.jobs) as pool:
                futures = {
                    pool.submit(self.run_lane, lane, case_dir, main_file):
                    lane for lane in self.lanes}
                for future in concurrent.futures.as_completed(futures):
                    result = future.result()
                    by_lane[result.lane] = result
            return [by_lane[lane] for lane in self.lanes]
        return [self.run_lane(lane, case_dir, main_file)
                for lane in self.lanes]


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
        "files": sorted(files),
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
    and type reference resolves, every override still has a parent
    implementation, and every dispatch or super target is reachable.
    Reduction edits that orphan a use would otherwise be rejected by
    both checkers and read as a 'failure'."""
    fn_names = {fn.name for fn in prog.fns}
    class_names = {c.name for c in prog.classes}
    type_names = ({st.name for st in prog.structs}
                  | {en.name for en in prog.enums}
                  | set(INT_TYPES) | {BOOL, STR})
    ok = [True]

    def class_by_name(t):
        bare = t.split(".")[-1] if t else t
        for c in prog.classes:
            if c.name == bare:
                return c
        return None

    def check_type(t):
        if t is None or t in type_names:
            return
        if t.split(".")[-1] in class_names:
            return
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
        if isinstance(e, NewObj):
            if e.cls not in prog.classes:
                ok[0] = False
            elif e.cls.init is None:
                ok[0] = False
        if isinstance(e, MethodCall):
            recv_cls = None
            if isinstance(e.recv, VarRef):
                if e.recv.name == "self":
                    recv_cls = class_by_name(e.recv.type)
                else:
                    recv_cls = class_by_name(e.recv.type)
            if recv_cls is None or resolve_impl(recv_cls, e.slot) is None:
                ok[0] = False
        if isinstance(e, SuperCall):
            if e.owner_cls not in prog.classes or \
                    e.owner_cls.parent is None or \
                    resolve_impl(e.owner_cls.parent, e.slot) is None:
                ok[0] = False
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
            elif isinstance(s, (SelfFieldAssign, ExprStmt)):
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
    for cls in prog.classes:
        if cls.parent is not None and cls.parent not in prog.classes:
            ok[0] = False
        for _fname, ftype, _d, _p in cls.fields:
            check_type(ftype)
        for m in cls.methods:
            if m.is_override and (
                    cls.parent is None
                    or resolve_impl(cls.parent, m.slot) is None):
                ok[0] = False
            check_type(m.ret)
            for _n, t in m.params:
                check_type(t)
            names = {"self"} | {n for n, _ in m.params}
            walk_block(m.body, names)
        if cls.init is not None:
            names = {"self"} | {n for n, _ in cls.init.params}
            for _fname, expr in cls.init.own_assigns:
                walk_expr(expr, names)
            if cls.init.super_args is not None:
                if cls.parent is None or cls.parent.init is None:
                    ok[0] = False
                else:
                    for a in cls.init.super_args:
                        walk_expr(a, names)
            elif cls.parent is not None and cls.parent.init is not None:
                # a parent that declares init makes super.init mandatory
                ok[0] = False
            walk_block(cls.init.post, names)
        if cls.has_deinit:
            walk_block(cls.deinit_body, {"self"})
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
                            self.pass_drop_methods,
                            self.pass_drop_deinits,
                            self.pass_unwrap,
                            self.pass_drop_decls,
                            self.pass_drop_classes,
                            self.pass_simplify_exprs):
                candidate = pass_fn(best)
                if candidate is not None:
                    best = candidate
                    improved = True
        return best

    # each pass returns an improved program or None

    def blocks_of(self, prog):
        """Yield every statement list in the program: main, functions,
        method bodies, init tails, and deinit bodies."""
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
        for cls in prog.classes:
            for m in cls.methods:
                yield from walk(m.body)
            if cls.init is not None:
                yield from walk(cls.init.post)
            if cls.has_deinit:
                yield from walk(cls.deinit_body)

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
        bodies = [(fn.name, fn) for fn in work.fns]
        for cls in work.classes:
            bodies.extend(
                ("{}.{}".format(cls.name, m.name), m)
                for m in cls.methods)
        for label, holder in bodies:
            if len(holder.body) <= 1:
                continue
            saved = holder.body
            tail = saved[-1]
            if isinstance(tail, Return):
                holder.body = [tail]
            else:
                holder.body = []
            if self.check(work):
                made_progress = copy.deepcopy(work)
                self.log.append("gutted " + label)
            else:
                holder.body = saved
        return made_progress

    def pass_drop_methods(self, prog):
        """Remove whole method declarations; model_closed guards against
        orphaned overrides and unresolvable calls, and the predicate
        re-checks behavior."""
        made_progress = None
        work = copy.deepcopy(prog)
        for cls in work.classes:
            i = 0
            while i < len(cls.methods):
                removed = cls.methods.pop(i)
                if self.check(work):
                    made_progress = copy.deepcopy(work)
                    self.log.append("dropped method " + removed.name)
                else:
                    cls.methods.insert(i, removed)
                    i += 1
        return made_progress

    def pass_drop_deinits(self, prog):
        made_progress = None
        work = copy.deepcopy(prog)
        for cls in work.classes:
            if not cls.has_deinit:
                continue
            saved = cls.deinit_body
            cls.has_deinit = False
            cls.deinit_body = []
            if self.check(work):
                made_progress = copy.deepcopy(work)
                self.log.append("dropped deinit of " + cls.name)
            else:
                cls.has_deinit = True
                cls.deinit_body = saved
        return made_progress

    def pass_drop_classes(self, prog):
        """Remove whole classes, leaves first; model_closed rejects a
        removal that orphans a parent link, construction, or call."""
        made_progress = None
        work = copy.deepcopy(prog)
        i = len(work.classes) - 1
        while i >= 0:
            removed = work.classes.pop(i)
            if self.check(work):
                made_progress = copy.deepcopy(work)
                self.log.append("dropped class " + removed.name)
            else:
                work.classes.insert(i, removed)
            i -= 1
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
                    args.timeout_build, args.timeout_run, workdir,
                    jobs=args.jobs)
    runner.probe_lto()
    for lane in Runner.ALL_LANES:
        if lane not in runner.lanes and lane not in runner.skipped:
            print("lane {} skipped: not selected".format(lane))
    return runner


def write_case_files(case_dir, files):
    for rel, text in files.items():
        path = os.path.join(case_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)


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


def run_one_case(runner, out_root, seed, case, config, keep=False,
                 expected_override=None, sabotage=None):
    """Generate, evaluate, run and compare one case.
    Returns (failures, fail_dir_or_None, prog, source)."""
    prog, files = generate_case_files(seed, case, config["groups"],
                                      config["max_depth"],
                                      config["max_stmts"])
    source = files["main.b"]
    expected = (oracle_expected(prog, sabotage)
                if expected_override is None else expected_override)
    if expected is None:
        raise SystemExit(
            "generator bug: case {}-{} has no defined meaning".format(
                seed, case))
    case_dir = os.path.join(out_root, "work", "{}-{}".format(seed, case))
    if os.path.exists(case_dir):
        shutil.rmtree(case_dir)
    os.makedirs(case_dir)
    main_file = os.path.join(case_dir, "main.b")
    write_case_files(case_dir, files)

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
        if os.path.exists(scratch):
            shutil.rmtree(scratch)
        os.makedirs(scratch)
        main_file = os.path.join(scratch, "main.b")
        write_case_files(scratch, prog.emit_files())
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
        reduced_files = reduced.emit_files()
        if len(reduced_files) == 1:
            with open(os.path.join(fail_dir, "reduced.b"), "w") as f:
                f.write(reduced.emit())
        else:
            # a package project reduces to a smaller package project
            reduced_dir = os.path.join(fail_dir, "reduced")
            if os.path.exists(reduced_dir):
                shutil.rmtree(reduced_dir)
            os.makedirs(reduced_dir)
            write_case_files(reduced_dir, reduced_files)
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
    failures, fail_dir, prog, source = run_one_case(
        runner, out_root, seed, case, config, keep=True)
    files = prog.emit_files()
    if len(files) == 1:
        print(source, end="")
    else:
        for rel in sorted(files):
            print("// ==== {} ====".format(rel))
            print(files[rel], end="")
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
    file_list = meta.get("files", ["main.b"])
    prog, regenerated = generate_case_files(
        seed, case, meta["groups"], meta["max_depth"], meta["max_stmts"])
    saved = {}
    for rel in file_list:
        saved[rel] = open(os.path.join(fail_dir, rel)).read()
    if saved != regenerated:
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
    write_case_files(scratch, saved)
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
    the emulated machine, and compare against these expectations.

    A single-file case keeps the flat case_S_N.b layout. A package
    project becomes a directory case_S_N/ holding beans.pot, every .b
    file, and its expectations; the entry point is always main.b."""
    os.makedirs(args.corpus, exist_ok=True)
    manifest = []
    for case in range(args.start, args.start + args.cases):
        prog, files = generate_case_files(args.seed, case,
                                          args.groups.split(","),
                                          args.max_depth, args.max_stmts)
        expected = oracle_expected(prog)
        if expected is None:
            raise SystemExit("generator bug: corpus case has no meaning")
        name = "case_{}_{}".format(args.seed, case)
        if len(files) == 1:
            with open(os.path.join(args.corpus, name + ".b"), "w") as f:
                f.write(files["main.b"])
            with open(os.path.join(args.corpus,
                                   name + ".stdout"), "w") as f:
                f.write(expected[0])
            with open(os.path.join(args.corpus, name + ".exit"), "w") as f:
                f.write(str(expected[1]) + "\n")
        else:
            case_dir = os.path.join(args.corpus, name)
            if os.path.exists(case_dir):
                shutil.rmtree(case_dir)
            os.makedirs(case_dir)
            write_case_files(case_dir, files)
            with open(os.path.join(case_dir,
                                   "expected_stdout.txt"), "w") as f:
                f.write(expected[0])
            with open(os.path.join(case_dir, "expected_exit.txt"),
                      "w") as f:
                f.write(str(expected[1]) + "\n")
        manifest.append(name)
    with open(os.path.join(args.corpus, "MANIFEST"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    print("wrote {} corpus cases (seed {}) to {}".format(
        args.cases, args.seed, args.corpus))
    return 0


# ---------------------------------------------------------------------------
# checker-parity mode: intentionally invalid access cases
#
# These cases never touch the runtime oracle. Both compilers must reject
# each generated project, and after paths are normalized away their
# diagnostics must agree line for line — a compiler accepting an invalid
# access, or wording a rejection differently, is the failure.

NEGATIVE_KINDS = (
    "private_class", "private_field", "private_method",
    "through_value", "private_override", "super_private",
    "super_outside", "super_static", "super_no_parent",
    "super_unknown", "unknown_import", "unknown_member",
    "private_fn", "builtin_reuse",
)

# Names the language reserves for its own types: redeclaring one anywhere is
# "type name '<name>' already taken" from both compilers.
RESERVED_TYPE_NAMES = (
    "Box", "List", "Map", "OrderedMap", "Option", "Result", "Error",
    "Mutex", "Channel", "Arena", "Shared", "Weak", "Slice", "Atomic",
    "int", "string", "bool", "f64", "u16",
)


def negative_case_files(seed, case):
    rng = random.Random(7_777_777 * seed + case)
    kind = NEGATIVE_KINDS[case % len(NEGATIVE_KINDS)]
    n = rng.randint(0, 9999)
    cls = "Vault{}".format(n)
    field = "secret{}".format(n)
    method = "hidden{}".format(n)
    fn = "helper{}".format(n)
    pot = "module {}\n".format(MODULE_NAME)
    base = []
    base.append("pub class {} {{".format(cls))
    base.append("    pub open{}: int".format(n))
    base.append("    {}: int = 3".format(field))
    base.append("")
    base.append("    pub fn init(open{}: int) {{".format(n))
    base.append("        self.open{0} = open{0}".format(n))
    base.append("    }")
    base.append("")
    base.append("    fn {}() -> int {{".format(method))
    base.append("        return self.{}".format(field))
    base.append("    }")
    base.append("}")
    base.append("")
    base.append("class Inner{} {{".format(n))
    base.append("    pub fn init() {}")
    base.append("}")
    base.append("")
    base.append("pub fn make{0}() -> {1} {{".format(n, cls))
    base.append("    return new {}(1)".format(cls))
    base.append("}")
    base.append("")
    base.append("fn {}() -> int {{ return 4 }}".format(fn))
    base_text = "\n".join(base) + "\n"

    main = ["import {}.pkx".format(MODULE_NAME), ""]
    if kind == "private_class":
        main += ["fn main() {",
                 "    let x: pkx.Inner{} = new pkx.Inner{}()".format(n, n),
                 "}"]
    elif kind == "private_field":
        main += ["fn main() {",
                 "    let v: pkx.{} = new pkx.{}(2)".format(cls, cls),
                 "    let got: int = v.{}".format(field),
                 "}"]
    elif kind == "private_method":
        main += ["fn main() {",
                 "    let v: pkx.{} = new pkx.{}(2)".format(cls, cls),
                 "    let got: int = v.{}()".format(method),
                 "}"]
    elif kind == "through_value":
        main += ["fn main() {",
                 "    let v: pkx.{} = pkx.make{}()".format(cls, n),
                 "    let got: int = v.{}".format(field),
                 "}"]
    elif kind == "private_override":
        main += ["pub class Child{} extends pkx.{} {{".format(n, cls),
                 "    pub fn init() {",
                 "        super.init(5)",
                 "    }",
                 "",
                 "    pub override fn {}() -> int {{".format(method),
                 "        return 9",
                 "    }",
                 "}",
                 "",
                 "fn main() {",
                 "    let c: Child{0} = new Child{0}()".format(n),
                 "}"]
    elif kind == "super_private":
        main += ["pub class Child{} extends pkx.{} {{".format(n, cls),
                 "    pub fn init() {",
                 "        super.init(5)",
                 "    }",
                 "",
                 "    pub fn reveal() -> int {",
                 "        return super.{}()".format(method),
                 "    }",
                 "}",
                 "",
                 "fn main() {",
                 "    let c: Child{0} = new Child{0}()".format(n),
                 "}"]
    elif kind == "super_outside":
        main += ["fn loose{}() -> int {{".format(n),
                 "    return super.{}()".format(method),
                 "}",
                 "",
                 "fn main() {}"]
    elif kind == "super_static":
        main += ["class Solo{} {{".format(n),
                 "    pub fn init() {}",
                 "",
                 "    static fn probe() -> int {",
                 "        return super.{}()".format(method),
                 "    }",
                 "}",
                 "",
                 "fn main() {}"]
    elif kind == "super_no_parent":
        main += ["class Solo{} {{".format(n),
                 "    pub fn init() {}",
                 "",
                 "    fn probe() -> int {",
                 "        return super.{}()".format(method),
                 "    }",
                 "}",
                 "",
                 "fn main() {}"]
    elif kind == "super_unknown":
        main += ["class Base{} {{".format(n),
                 "    pub fn init() {}",
                 "}",
                 "",
                 "class Kid{0} extends Base{0} {{".format(n),
                 "    pub fn init() {",
                 "        super.init()",
                 "    }",
                 "",
                 "    fn probe() -> int {",
                 "        return super.absent{}()".format(n),
                 "    }",
                 "}",
                 "",
                 "fn main() {}"]
    elif kind == "unknown_import":
        main = ["import {}.nowhere{}".format(MODULE_NAME, n), "",
                "fn main() {}"]
    elif kind == "unknown_member":
        main += ["fn main() {",
                 "    let got: int = pkx.absent{}()".format(n),
                 "}"]
    elif kind == "builtin_reuse":
        taken = rng.choice(RESERVED_TYPE_NAMES)
        shape = rng.choice(("class", "struct", "enum"))
        if shape == "class":
            base += ["", "pub class {} {{".format(taken),
                     "    pub fn init() {}", "}"]
        elif shape == "struct":
            base += ["", "pub struct {} {{".format(taken),
                     "    x: i32", "}"]
        else:
            base += ["", "pub enum {} {{".format(taken),
                     "    one", "    two", "}"]
        base_text = "\n".join(base) + "\n"
        main += ["fn main() {",
                 "    let got: int = pkx.make{}().open{}".format(n, n),
                 "}"]
    else:  # private_fn
        main += ["fn main() {",
                 "    let got: int = pkx.{}()".format(fn),
                 "}"]
    files = {
        "beans.pot": pot,
        "pkx/pkx.b": base_text,
        "main.b": "\n".join(main) + "\n",
    }
    return kind, files


def normalize_diagnostics(text, case_dir):
    """Strip the machine-specific path prefix — absolute or as given —
    so the two compilers' reports are comparable byte for byte."""
    prefixes = [os.path.abspath(case_dir), os.path.normpath(case_dir),
                case_dir]
    out = []
    for line in text.splitlines():
        for prefix in prefixes:
            line = line.replace(prefix + os.sep, "")
            line = line.replace(prefix, "")
        out.append(line.rstrip())
    while out and not out[-1]:
        out.pop()
    return "\n".join(out) + "\n"


def run_negative_case(args, out_root, seed, case):
    kind, files = negative_case_files(seed, case)
    case_dir = os.path.join(out_root, "neg-work",
                            "{}-{}".format(seed, case))
    if os.path.exists(case_dir):
        shutil.rmtree(case_dir)
    os.makedirs(case_dir)
    write_case_files(case_dir, files)
    main_file = os.path.join(case_dir, "main.b")
    failures = []
    outputs = {}
    for lane, cc in (("check0", args.beansc0), ("check1", args.beansc)):
        pkind, out, err, code = run_proc([cc, "check", main_file],
                                         args.timeout_build)
        outputs[lane] = normalize_diagnostics(out + err, case_dir)
        if pkind != "ok":
            failures.append({"lane": lane, "kind": pkind})
        elif code == 0:
            failures.append({"lane": lane, "kind": "invalid-accepted"})
    if not failures and outputs["check0"] != outputs["check1"]:
        failures.append({"lane": "check0+check1",
                         "kind": "diagnostic-mismatch"})
    fail_dir = None
    if failures:
        fail_dir = os.path.join(out_root, "failures",
                                "neg-{}-{}".format(seed, case))
        if os.path.exists(fail_dir):
            shutil.rmtree(fail_dir)
        os.makedirs(fail_dir)
        write_case_files(fail_dir, files)
        for lane in outputs:
            with open(os.path.join(fail_dir, lane + ".diag"), "w") as f:
                f.write(outputs[lane])
        with open(os.path.join(fail_dir, "meta.json"), "w") as f:
            json.dump({"negative_kind": kind, "seed": seed, "case": case,
                       "files": sorted(files), "failures": failures},
                      f, indent=2, sort_keys=True)
            f.write("\n")
    shutil.rmtree(case_dir, ignore_errors=True)
    return kind, failures, fail_dir


def negative_loop(args):
    out_root = args.out
    os.makedirs(out_root, exist_ok=True)
    total = 0
    for case in range(args.start, args.start + args.cases):
        kind, failures, fail_dir = run_negative_case(
            args, out_root, args.seed, case)
        if failures:
            total += 1
            kinds = sorted({f["kind"] for f in failures})
            print("FAIL negative {}-{} ({}): {} -> {}".format(
                args.seed, case, kind, ",".join(kinds), fail_dir))
            if not args.keep_going:
                break
        elif args.verbose:
            print("ok negative {}-{} ({})".format(args.seed, case, kind))
    print("negative parity: {} cases, {} failing".format(
        args.cases, total))
    return 1 if total else 0


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

    # 9. classes and packages generate deterministic, meaningful cases
    # that both checkers accept
    for label, cgroups in (("classes", ["core", "classes"]),
                           ("packages", ["core", "classes", "packages"])):
        ok = True
        detail = ""
        for case in range(args.selftest_cases):
            _, a = generate_case_files(31, case, cgroups, args.max_depth,
                                       args.max_stmts)
            prog, b = generate_case_files(31, case, cgroups,
                                          args.max_depth, args.max_stmts)
            if a != b:
                ok, detail = False, "case 31-{} not deterministic".format(
                    case)
                break
            if oracle_expected(prog) is None:
                ok, detail = False, "case 31-{} has no meaning".format(
                    case)
                break
            scratch = os.path.join(out_root, "selftest-work")
            if os.path.exists(scratch):
                shutil.rmtree(scratch)
            os.makedirs(scratch)
            write_case_files(scratch, b)
            rejects = runner.check_case(
                os.path.join(scratch, "main.b"))
            if rejects:
                ok = False
                detail = "case 31-{} rejected by {}".format(
                    case, rejects[0].lane)
                break
        if label == "packages" and ok and "beans.pot" not in b:
            ok, detail = False, "packages case has no manifest"
        report(label + "-generate", ok, detail)

    # 10. every negative kind is rejected by both compilers with
    # matching diagnostics
    ok = True
    detail = ""
    for case in range(len(NEGATIVE_KINDS)):
        kind, neg_failures, _ = run_negative_case(args, out_root, 53,
                                                  case)
        if neg_failures:
            ok = False
            detail = "{} -> {}".format(
                kind, sorted({f["kind"] for f in neg_failures}))
            break
    report("negative-parity", ok, detail)

    total = 12
    print("self-test: {} of {} checks failed".format(len(failures), total)
          if failures else
          "self-test: all {} checks passed".format(total))
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
    ap.add_argument("--jobs", type=int,
                    default=int(os.environ.get(
                        "FUZZ_JOBS",
                        str(min(4, os.cpu_count() or 1)))),
                    help="parallel workers for independent lanes")
    ap.add_argument("--negative", action="store_true",
                    help="checker-parity mode: generated invalid access "
                         "cases both compilers must reject identically")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--selftest-cases", type=int, default=6)
    args = ap.parse_args()

    if args.self_test:
        return self_test(args)
    if args.negative:
        return negative_loop(args)
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
