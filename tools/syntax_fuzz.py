#!/usr/bin/env python3
"""Specification-linked syntax discovery, using differential_fuzz's runner.

No compiler fix or new language semantics lives here. Known-invalid cases have
authored expectations taken from spec/SYNTAX.md; arbitrary mutations assert
process safety only. The 256-layer nesting contract pins both acceptance at
the limit and a located refusal above it. Saved sources are portable and can
be replayed.

Known failures are tracked in test/cases/discovery/known_failures.json, each
tied to a finding in docs/BUGFIX_TODO.md. A per-change (smoke) run blocks on a
new failure, on a known failure whose signature changed, and on a known failure
that no longer reproduces (the record is stale). A candidate run ignores the
baseline: every failure blocks a release.
"""
import argparse
import copy
import json
import os
import pathlib
import random
import re
import sys
import tempfile
import time

import differential_fuzz as df

ROOT = pathlib.Path(__file__).resolve().parent.parent
GENERATOR_VERSION = "2"
NESTING_LIMIT = 256
BASELINE = ROOT / "test/cases/discovery/known_failures.json"
SPEC = ROOT / "spec/SYNTAX.md"
IO = "import std.io\n"


def case(name, source, feature, spec, disposition="valid", modes=None, **extra):
    if modes is None:
        modes = (["lex", "parse", "check"] if disposition == "valid"
                 else ["parse", "check"])
    result = {"name": name, "feature": feature, "spec": "spec/SYNTAX.md#" + spec,
              "files": {"main.b": source}, "disposition": disposition,
              "modes": modes}
    result.update(extra)
    return result


def main_body(body, prelude=""):
    """Wrap statements in main so every authored line number is stable."""
    return prelude + IO + "fn main() {\n    " + body.replace("\n", "\n    ") + "\n}\n"


def rejection(line, message, col=None, count=1, file="main.b"):
    result = {"file": file, "line": line, "message": message, "count": count}
    if col is not None:
        result["col"] = col
    return result


# Lexer-level errors must be visible to `lex`, parser-level to `parse`, and a
# checker-level error only to `check`: an earlier mode accepting a program the
# checker refuses is not an acceptance defect.
LEX = ["lex", "parse", "check"]
PARSE = ["parse", "check"]
CHECK = ["check"]


def valid_cases():
    """Positive controls with reviewed outputs from spec/SYNTAX.md rules."""
    body_line = 3  # first statement line inside main_body with no prelude
    assert body_line == 3
    yield case("numbers", main_body("io.println(0xFF + 0b1010 + 1_000 + 0XfF)"),
               "literals", "lexical", output="1520\n")
    yield case("precedence", main_body("io.println(1 + 2 * 3)\nio.println(8 - 3 - 1)\nio.println(100 / 10 / 2)\nio.println(7 % 3 * 2)"),
               "precedence-associativity", "number-rules", output="7\n4\n5\n2\n")
    yield case("precedence_shift_add", main_body("io.println(1 << 2 + 1)\nio.println((6 & 3) == 2)\nio.println(1 < 2 && 3 > 2)"),
               "precedence-associativity", "number-rules", output="8\ntrue\ntrue\n")
    yield case("precedence_unary", main_body("io.println(-2 * 3)\nio.println(- -2)\nio.println(!!true)\nio.println(1 + -2)"),
               "precedence-associativity", "number-rules", output="-6\n2\ntrue\n-1\n")
    yield case("cast_precedence", main_body("io.println((7 as float) / 2 as float)\nio.println(300 as i8)"),
               "casts", "number-rules", output="3.5\n44\n")
    yield case("literal_widths", main_body("let big: u64 = 0xffffffffffffffff\nlet low: int = -9223372036854775808\nio.println(big)\nio.println(low)\nio.println(1.5e3)\nio.println(1e-2)"),
               "literals", "number-rules", output="18446744073709551615\n-9223372036854775808\n1500\n0.01\n")
    yield case("generic_shift", "fn id<T>(x: T) -> T { return x }\n" + main_body(
        "let a: int = id<int>(8) >> 1\nlet b: bool = (a < 9) && (9 > a)\nlet nested: List<List<int>> = [[1]]\nlet deep: List<List<List<int>>> = [[[2]]]\nlet m: Map<string, List<int>> = {}\nio.println(a)\nio.println(b)\nio.println(nested[0][0] + deep[0][0][0] + m.len())\nio.println(\"{id<int>(3)}\")"),
        "generics-comparisons-shifts", "generics", output="4\ntrue\n3\n3\n")
    yield case("comparison_chain_words", main_body("let a: int = 1\nlet b: int = 2\nlet c: int = 3\nio.println(a < b && c > a)"),
               "generics-comparisons-shifts", "generics", output="true\n")
    yield case("function_types", "fn apply<T>(x: T, f: fn(T) -> T) -> T { return f(x) }\n" + main_body(
        "let x: int = apply<int>(1, fn(v: int) -> int { return v + 1 })\nlet g: fn() -> fn() -> int = fn() -> fn() -> int { return fn() -> int { return 7 } }\nlet h: fn(List<int>) -> int = fn(xs: List<int>) -> int { return xs.len() }\nvar n: int = 0\nlet bump: fn() = fn() { n += 1 }\nbump()\nio.println(x + g()() + h([1, 2]) + n)"),
        "function-types-closures-generics", "anonymous-functions", output="12\n")
    yield case("initializer", "struct Row {\n    value: int\n}\n" + main_body(
        "let rows: List<Row> = [Row { value: 1 }, Row { value: 2 }]\nlet one: Row = Row { value: 3, }\nlet tail: List<int> = [1, 2,]\nlet m: Map<string, int> = {}\nio.println(rows[1].value + one.value + tail.len() + m.len())"),
        "initializers-collections", "struct-and-collection-literals", output="7\n")
    yield case("nested_match", "fn id<T>(x: T) -> T { return x }\n" + main_body(
        "let x: int = match true {\n    true => id<int>(if true { 7 } else { 8 }),\n    false => 0,\n}\nio.println(\"answer {id<int>(x + (2 * 3))}\")\nio.println(1 + match x { 7 => 10, _ => 0 } * 2)\nio.println(\"v={match x { 7 => \"seven\", _ => \"other\" }}\")"),
        "match-interpolation-generic-call", "if-and-match-as-values", output="answer 13\n21\nv=seven\n")
    yield case("control_flow", main_body(
        "let x: int = 5\nif x < 3 { io.println(\"a\") } else if x < 10 { io.println(\"b\") } else { io.println(\"c\") }\nlet y: int = if true { 1 } else { 2 }\nvar n: int = 0\nfor i in 0..=3 { n += i }\nfor n < 10 { n += 1 }\nio.println(y)\nio.println(n)"),
        "control-flow", "control-flow", output="b\n1\n10\n")
    yield case("newline_chain", main_body(
        "let s: string = \"abcdef\"\nlet x: int = s\n    .len()\nlet y: int = s.\n    len()\nlet z: int = 1 +\n    2\nlet w: int = (1 +\n    2)\nlet xs: List<int> = [\n    1,\n    2,\n]\nio.println(x + y + z + w + xs.len())\nvar n: int = 0\nfor i in 0..3 { n += i }\nio.println(n)"),
        "newline-member-chain", "lexical", output="20\n3\n")
    yield case("comments_raw", main_body(
        "/* outer /* nested */ comment */\nlet x: string = r#\"{raw} \\ bytes\"#\nio.println(x)\nio.println(r\"a\\b{c}\")\nio.println(\"a\\{b\\}\")"),
        "nested-comments-raw-strings", "raw-string-literals", output="{raw} \\ bytes\na\\b{c}\na{b}\n")
    yield case("interpolation_forms", main_body(
        "let v: int = 7\nio.println(\"{\"x\"}\")\nio.println(\"{\"a{v}b\"}\")\nio.println(\"[{v:4}]\")\nio.println(\"[{v:-4}]\")"),
        "interpolation", "strings", output="x\na7b\n[   7]\n[7   ]\n")
    yield case("shadowing", main_body(
        "let x: int = 1\nif true {\n    let x: int = 2\n    io.println(x)\n}\nio.println(x)"),
        "scoping", "variables", output="2\n1\n")
    yield case("empty_file", "", "lexical-edges", "lexical", modes=CHECK)
    yield case("only_comment", "// nothing here\n", "lexical-edges", "lexical", modes=CHECK)
    yield case("long_line", "fn main() {\n    let x: int = " + " + ".join(["1"] * 20000) + "\n}\n",
               "shallow-long-chains", "number-rules", modes=CHECK)
    # #206: settled language contracts, with values authored from the rules.
    for name, literal, output in (("literal_double_separator", "1__0", "10\n"),
                                  ("literal_trailing_separator", "1_", "1\n"),
                                  ("literal_hex_leading_separator", "0x_F", "15\n")):
        yield case(name, main_body("let x: int = " + literal + "\nio.println(x)"),
                   "literals", "lexical", output=output)
    yield case("generic_args_trailing_comma", "fn id<T>(v: T) -> T { return v }\n" +
               main_body("let x: Map<int, int,> = {}\nio.println(x.len())\nio.println(id<int,>(7))"),
               "generics", "generics", output="0\n7\n")
    yield case("generic_params_empty", "fn f<>() -> int { return 4 }\n" + main_body("io.println(f())"),
               "generics", "generics", output="4\n")
    yield case("match_arms_no_commas", main_body(
        "let x: int = 2\nlet y: int = match x {\n    1 => 10\n    _ => 0\n}\nio.println(y)"),
        "match", "if-and-match-as-values", output="0\n")
    yield case("format_empty_spec", main_body('let v: int = 7\nio.println("[{v:}]")\nio.println("[{v}]")'),
               "interpolation", "strings", output="[7]\n[7]\n")
    yield case("if_parenthesized_condition", main_body('if (true) { io.println("condition") }'),
               "control-flow", "lexical", output="condition\n")
    yield case("operator_equality_chain", main_body("io.println(1 == 1 == true)"),
               "precedence-associativity", "number-rules", output="true\n")
    yield case("operator_bitand_equality", main_body("io.println(6 & 3 == 2)"),
               "precedence-associativity", "number-rules", output="true\n")


def reject_cases():
    """Each invalid program's expectation is authored from the rule it breaks."""
    # Lexical: a hex or binary prefix needs a digit (spec Lexical: `0xFF`, `0b1010`).
    for literal in ("0x", "0b", "0x_", "0b_"):
        yield case("bad_" + literal, "fn main() {\n    let x: int = " + literal + "\n}\n",
                   "literals", "lexical", "reject", modes=LEX,
                   rejection=rejection(2, "(?i)digit|literal|hex|binary"),
                   repair={"main.b": "fn main() {\n    let x: int = 0\n}\n"})
    for name, literal in (("hex_bad_digit", "0xG"), ("bin_bad_digit", "0b2"),
                          ("bin_trailing_digit", "0b102"), ("octal_prefix", "0o7"),
                          ("exponent_no_digits", "1e+")):
        yield case("literal_" + name, main_body("let x: int = " + literal),
                   "literals", "lexical", "reject", rejection=rejection(3, ""),
                   repair={"main.b": main_body("let x: int = 7")})
    yield case("literal_leading_dot", main_body("let x: float = .5"),
               "literals", "number-rules", "reject", rejection=rejection(3, "expected expression"),
               repair={"main.b": main_body("let x: float = 0.5")})
    yield case("literal_hex_fraction", main_body("let x: float = 0x1.8"),
               "literals", "number-rules", "reject", rejection=rejection(3, ""),
               repair={"main.b": main_body("let x: float = 0x10")})
    yield case("literal_int_overflow", main_body("let x: int = 9223372036854775808"),
               "literals", "number-rules", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)range|fit|large|overflow"))
    yield case("literal_u8_range", main_body("let x: u8 = 256\nlet y: u8 = -1"),
               "literals", "number-rules", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)range|fit|u8", count=2))
    yield case("literal_hex_too_wide", main_body("let x: u64 = 0x1ffffffffffffffff"),
               "literals", "number-rules", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)range|fit|large|overflow"))
    # Strings (spec Strings: escapes, pieces, raw strings).
    yield case("string_bad_escape", main_body('let s: string = "C:\\Users"'),
               "string-escapes", "strings", "reject", modes=LEX,
               rejection=rejection(3, "escape", col=24),
               repair={"main.b": main_body('let s: string = "C:\\\\Users"')})
    yield case("string_x_short", main_body('let s: string = "\\x1"'),
               "string-escapes", "strings", "reject", modes=LEX,
               rejection=rejection(3, "(?i)hex", col=22))
    yield case("string_u_range", main_body('let s: string = "\\u{110000}"\nlet t: string = "\\u{d800}"'),
               "string-escapes", "strings", "reject", modes=LEX,
               rejection=rejection(3, "(?i)codepoint|surrogate|10FFFF", count=2))
    yield case("string_unterminated", main_body('let s: string = "abc'),
               "string-delimiters", "strings", "reject", modes=LEX,
               rejection=rejection(3, "(?i)not closed|unterminated|string", col=21),
               repair={"main.b": main_body('let s: string = "abc"')})
    yield case("string_newline_inside", main_body('let s: string = "ab\ncd"'),
               "string-delimiters", "strings", "reject", modes=LEX,
               rejection=rejection(3, "(?i)not closed|unterminated|string", col=21),
               repair={"main.b": main_body('let s: string = "ab\\ncd"')})
    yield case("string_raw_unterminated", main_body('let s: string = r#"abc"'),
               "string-delimiters", "raw-string-literals", "reject", modes=LEX,
               rejection=rejection(3, "(?i)raw string|never closed|not closed", col=21),
               repair={"main.b": main_body('let s: string = r#"abc"#')})
    yield case("string_double_brace", main_body('let s: string = "{{}}"'),
               "interpolation", "strings", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)escape|interpolation|brace"),
               repair={"main.b": main_body('let s: string = "\\{\\}"')})
    yield case("string_empty_piece", main_body('let s: string = "{}"'),
               "interpolation", "strings", "reject", modes=CHECK, rejection=rejection(3, ""))
    yield case("string_piece_unterminated", main_body('let s: string = "{1 + "'),
               "interpolation", "strings", "reject", modes=LEX,
               rejection=rejection(3, "(?i)not closed|unterminated|string"))
    # Comments (spec Lexical: `/* */` block, nesting allowed).
    yield case("comment_unterminated", "fn main() {\n    /* never closed\n}\n",
               "comments", "lexical", "reject", modes=LEX,
               rejection=rejection(2, "(?i)comment|closed|\\*/", col=5),
               repair={"main.b": "fn main() {\n    /* closed */\n}\n"})
    yield case("comment_nested_unterminated", "fn main() {\n    /* a /* b */\n}\n",
               "comments", "lexical", "reject", modes=LEX,
               rejection=rejection(2, "(?i)comment|closed|\\*/", col=5),
               repair={"main.b": "fn main() {\n    /* a /* b */ c */\n}\n"})
    # Delimiters: the primary error sits where the parser noticed, and the
    # opener is context (the illustrative target in the campaign plan).
    for name, body, line, col, close, opener in (
            ("paren", "let x: int = (1 + 2", 3, 24, "\\)", (3, 18)),
            ("bracket", "let x: List<int> = [1, 2", 4, 1, "\\]", (3, 24)),
            # The literal takes main's `}` as its own closer, so the unclosed
            # delimiter the parser can still report is the function body.
            ("map_brace", "let x: Map<int, int> = {1: 2", 5, 1, "\\}", (2, 11)),
            ("call_paren", "io.println(1", 4, 1, "\\)", (3, 15))):
        yield case("delimiter_missing_" + name, main_body(body),
                   "delimiters", "lexical", "reject",
                   rejection=rejection(line, "expected '" + close + "'", col=col),
                   context=[{"file": "main.b", "line": opener[0], "col": opener[1], "message": "opened"},
                            {"file": "main.b", "line": 2, "col": 4, "message": "in function"}],
                   caret=True,
                   repair={"main.b": main_body(body + close.replace("\\", ""))})
    yield case("delimiter_missing_generic_close", main_body("let x: List<int = []"),
               "generic-delimiters", "types", "reject",
               rejection=rejection(3, "expected '>'", col=21),
               repair={"main.b": main_body("let x: List<int> = []")})
    for name, body, col in (("paren", "let x: int = 1)", 19), ("bracket", "let x: int = 1]", 19)):
        yield case("delimiter_extra_" + name, main_body(body), "delimiters", "lexical", "reject",
                   rejection=rejection(3, "", col=col),
                   repair={"main.b": main_body(body[:-1])})
    yield case("delimiter_extra_brace_toplevel", "fn main() {\n}\n}\n", "delimiters", "lexical", "reject",
               rejection=rejection(3, "", col=1), repair={"main.b": "fn main() {\n}\n"})
    yield case("extra_generic_close", "fn main() {\n    let x: List<int>> = []\n}\n",
               "generic-delimiters", "types", "reject",
               rejection=rejection(2, "expected|unexpected|extra|unmatched"),
               repair={"main.b": "fn main() {\n    let x: List<int> = []\n}\n"})
    yield case("extra_generic_close_nested", main_body("let x: Map<int, List<int>>> = {}"),
               "generic-delimiters", "types", "reject",
               rejection=rejection(3, "", col=31),
               repair={"main.b": main_body("let x: Map<int, List<int>> = {}")})
    yield case("generic_empty_args", main_body("let x: List<> = []"),
               "generic-delimiters", "types", "reject", modes=CHECK, rejection=rejection(3, ""))
    yield case("generic_double_open", main_body("let x: List<<int> = []"),
               "generic-delimiters", "types", "reject", rejection=rejection(3, ""))
    # Precedence and operand rules (spec Number rules: no implicit conversions).
    yield case("operator_not_int", main_body("let x: int = !1"), "operators", "number-rules", "reject",
               modes=CHECK, rejection=rejection(3, "bool", col=18),
               repair={"main.b": main_body("let x: bool = !true")})
    yield case("operator_chained_comparison", main_body("let x: bool = 1 < 2 < 3"),
               "operators", "number-rules", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)ordered|bool|int"),
               repair={"main.b": main_body("let x: bool = 1 < 2 && 2 < 3")})
    yield case("operator_mixed_numbers", main_body("io.println(1 + 2 as float)"),
               "operators", "number-rules", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)matching numbers|int|float"),
               repair={"main.b": main_body("io.println((1 as float) + 2 as float)")})
    yield case("operator_power", main_body("let x: int = 2 ** 3"), "operators", "number-rules", "reject",
               rejection=rejection(3, "", col=20))
    yield case("operator_assignment_chain", main_body("var a: int = 0\nvar b: int = 0\na = b = 1"),
               "operators", "variables", "reject", rejection=rejection(5, "", col=11))
    # Newline rules (spec Lexical).
    yield case("newline_before_operator", main_body("let x: int = 1\n    + 2"),
               "newline-rules", "lexical", "reject", rejection=rejection(4, "expected expression", col=9),
               repair={"main.b": main_body("let x: int = 1 +\n    2")})
    yield case("newline_else_own_line", "fn main() {\n    if true {\n    }\n    else {\n    }\n}\n",
               "newline-rules", "lexical", "reject",
               rejection=rejection(4, "else must follow '}' on the same line", col=5),
               repair={"main.b": "fn main() {\n    if true {\n    } else {\n    }\n}\n"})
    yield case("newline_inside_parentheses", main_body("let x: int = (1\n    + 2)"),
               "newline-rules", "lexical", "reject",
               rejection={"file": "main.b", "line": 3, "col": 20, "message": "expected '\\)'"},
               repair={"main.b": main_body("let x: int = (1 +\n    2)")})
    yield case("source_bom", "\ufefffn main() {\n}\n", "lexical-edges", "lexical", "reject", modes=LEX,
               rejection=rejection(1, "unexpected byte 239", col=1),
               repair={"main.b": "fn main() {\n}\n"})
    # Generics (spec Generics / Functions).
    yield case("generic_too_many_args", "fn id<T>(x: T) -> T { return x }\n" + main_body("let x: int = id<int, int>(1)"),
               "generics", "generics", "reject", modes=CHECK, rejection=rejection(4, "type argument", col=30))
    yield case("generic_args_on_scalar", main_body("let x: int<int> = 1"), "generics", "types", "reject",
               rejection=rejection(3, ""))
    yield case("generic_list_arity", main_body("let x: List = []\nlet y: List<int, int> = []"),
               "generics", "collections", "reject", modes=CHECK, rejection=rejection(3, "", count=2))
    yield case("generic_cannot_infer", "fn zero<T>() -> int { return 0 }\n" + main_body("let x: int = zero()"),
               "generics", "generics", "reject", modes=CHECK, rejection=rejection(4, "(?i)infer", col=22))
    # Function types and closures (spec Anonymous functions).
    yield case("closure_param_no_type", main_body("let f: fn(int) -> int = fn(v) -> int { return v }"),
               "function-types-closures-generics", "anonymous-functions", "reject",
               rejection=rejection(3, "expected ':'", col=33),
               repair={"main.b": main_body("let f: fn(int) -> int = fn(v: int) -> int { return v }")})
    yield case("closure_arrow_no_type", main_body("let f: fn(int) -> int = fn(v: int) -> { return v }"),
               "function-types-closures-generics", "anonymous-functions", "reject",
               rejection=rejection(3, "expected type", col=43),
               repair={"main.b": main_body("let f: fn(int) -> int = fn(v: int) -> int { return v }")})
    yield case("function_type_missing_arrow", main_body("let f: fn(int) int = fn(v: int) -> int { return v }"),
               "function-types-closures-generics", "functions", "reject",
               rejection=rejection(3, "", col=20),
               repair={"main.b": main_body("let f: fn(int) -> int = fn(v: int) -> int { return v }")})
    # Initializers (spec Struct and collection literals).
    row = "struct Row {\n    value: int\n    other: int\n}\n"
    yield case("initializer_missing_comma", row + main_body("let r: Row = Row { value: 1 other: 2 }"),
               "initializers-collections", "struct-and-collection-literals", "reject",
               rejection=rejection(7, "expected", col=33),
               repair={"main.b": row + main_body("let r: Row = Row { value: 1, other: 2 }")})
    yield case("initializer_fields", row + main_body(
        "let a: Row = Row { value: 1 }\nlet b: Row = Row { value: 1, other: 2, value: 3 }\nlet c: Row = Row { value: 1, other: 2, nope: 3 }"),
        "initializers-collections", "struct-and-collection-literals", "reject", modes=CHECK,
        rejection={"errors": [rejection(7, "missing field 'other'"), rejection(8, "twice|duplicate"),
                              rejection(9, "no field 'nope'")], "count": 3})
    yield case("initializer_list_no_type", main_body("let xs = []"),
               "initializers-collections", "variables", "reject",
               rejection=rejection(3, "type", col=12),
               repair={"main.b": main_body("let xs: List<int> = []")})
    yield case("initializer_list_mixed", main_body('let xs: List<int> = [1, "a"]'),
               "initializers-collections", "collections", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)string|int"))
    # Match (spec if and match as values).
    yield case("match_empty", main_body("let x: int = 2\nlet y: int = match x { }"),
               "match", "if-and-match-as-values", "reject", modes=CHECK, rejection=rejection(4, ""))
    yield case("match_non_exhaustive", "enum Color {\n    red\n    green\n}\n" + main_body(
        "let x: int = 2\nlet y: int = match x {\n    1 => 10,\n}\nlet c: Color = Color.red\nlet z: int = match c {\n    red => 1,\n}"),
        "match", "if-and-match-as-values", "reject", modes=CHECK,
        rejection={"errors": [rejection(8, "(?i)cover|exhaust|_"), rejection(12, "green")], "count": 2})
    yield case("match_block_arm_value", main_body("let x: int = 1\nlet y: int = match x {\n    1 => { 10 },\n    _ => { 0 },\n}"),
               "match", "if-and-match-as-values", "reject", modes=CHECK,
               rejection=rejection(5, "block arm", col=9, count=2))
    yield case("match_arm_type_mismatch", main_body('let x: int = 1\nlet y: int = match x {\n    1 => "a",\n    _ => 0,\n}'),
               "match", "if-and-match-as-values", "reject", modes=CHECK,
               rejection=rejection(5, "(?i)string|int"))
    # Control flow (spec Control flow).
    yield case("if_value_no_else", main_body("let x: int = if true { 1 }"),
               "control-flow", "if-and-match-as-values", "reject",
               rejection=rejection(4, "else"),
               repair={"main.b": main_body("let x: int = if true { 1 } else { 2 }")})
    yield case("loop_control_outside", main_body("break\ncontinue"),
               "control-flow", "control-flow", "reject", modes=CHECK,
               rejection=rejection(3, "(?i)loop|break", count=2))
    yield case("return_outside_fn", "return 1\nfn main() {}\n", "control-flow", "functions", "reject",
               rejection=rejection(1, "declaration", col=1))
    # Declarations (spec Variables, Functions, Classes, Enums).
    yield case("declaration_duplicates", "fn f() {}\nfn f() {}\nfn g(x: int, x: int) {}\nstruct S {\n    a: int\n    a: int\n}\nenum E {\n    a\n    a\n}\nclass C {\n    fn f() {}\n    fn f() {}\n}\nfn main() {\n    let x: int = 1\n    let x: int = 2\n}\n",
               "declarations", "functions", "reject", modes=CHECK,
               rejection={"errors": [rejection(2, ""), rejection(3, ""), rejection(6, ""), rejection(10, ""),
                                     rejection(14, ""), rejection(18, "")], "count": 6})
    yield case("declaration_let_forms", main_body("let x\nlet y: int = 1\ny = 2"),
               "declarations", "variables", "reject", modes=CHECK,
               rejection={"errors": [rejection(3, ""), rejection(5, "(?i)let|immutable|var|reassign")], "count": 2})
    yield case("declaration_missing_return", "fn f() -> int {\n}\nfn main() {}\n", "declarations", "functions",
               "reject", modes=CHECK, rejection=rejection(1, "return"))
    yield case("declaration_unknown_type", main_body("let x: Foo = 1"), "declarations", "types", "reject",
               modes=CHECK, rejection=rejection(3, "Foo"))
    yield case("declaration_pub_local", main_body("pub let x: int = 1"), "declarations", "variables", "reject",
               rejection=rejection(3, "", col=5), repair={"main.b": main_body("let x: int = 1")})
    yield case("declaration_unit_value", "fn f() {}\n" + main_body("let x: int = f()"),
               "declarations", "functions", "reject", modes=CHECK, rejection=rejection(4, "unit", col=19))
    # Text encoding and positions: columns count bytes the user wrote.
    yield case("position_tab", 'fn main() {\n\tlet x: int = "a"\n}\n', "positions", "lexical", "reject",
               modes=CHECK, rejection=rejection(2, "(?i)string|int", col=15))
    yield case("position_crlf", 'fn main() {\r\n    let x: int = 1\r\n    let y: int = "a"\r\n}\r\n',
               "positions", "lexical", "reject", modes=CHECK, rejection=rejection(3, "(?i)string|int", col=18))
    yield case("position_unicode", 'fn main() {\n    let s: string = "héllo 東京 🙂"\n    let y: int = "a"\n}\n',
               "positions", "lexical", "reject", modes=CHECK, rejection=rejection(3, "(?i)string|int", col=18))
    yield case("lexical_stray_character", "fn main() {\n    let x: int = 1 $ 2\n}\n", "lexical-edges", "lexical",
               "reject", modes=LEX, rejection=rejection(2, "(?i)unexpected|character|\\$", col=20),
               repair={"main.b": "fn main() {\n    let x: int = 1 + 2\n}\n"})
    yield case("lexical_nul_byte", "fn main() {\n    let x: int = 1\x00\n}\n", "lexical-edges", "lexical",
               "reject", rejection=rejection(2, ""))
    yield case("lexical_unicode_identifier", "fn main() {\n    let caf\u00e9: int = 1\n}\n", "lexical-edges",
               "lexical", "reject", rejection=rejection(2, ""))
    # Recovery: the following statement must survive and independent errors stay.
    yield case("missing_operand", "fn main() {\n    let x: int = 1 +\n    let kept: int = 5\n}\n",
               "delimiters-recovery", "number-rules", "reject", modes=["parse", "ast", "check"],
               rejection=rejection(3, "expected expression"),
               ast_contains=['(let "kept"', '(literal "5"'],
               repair={"main.b": "fn main() {\n    let x: int = 1 + 2\n    let kept: int = 5\n}\n"})
    yield case("incomplete_member", "fn main() {\n    let receiver: string = \"x\"\n    receiver.\n    let kept: int = 5\n}\n",
               "delimiters-recovery", "lexical", "reject", modes=["parse", "ast", "check"],
               rejection=rejection(4, "expected name after"),
               ast_contains=['(name "receiver")', '(let "kept"'],
               repair={"main.b": "fn main() {\n    let receiver: string = \"x\"\n    receiver.len()\n    let kept: int = 5\n}\n"})
    yield case("independent_errors_kept", 'fn main() {\n    let x: Nope = 1\n    let kept: string = 5\n    let a: int = "x"\n}\n',
               "delimiters-recovery", "variables", "reject", modes=CHECK,
               rejection={"errors": [rejection(2, "Nope"), rejection(3, "(?i)string|int"),
                                     rejection(4, "(?i)string|int")], "count": 3})


def explore_cases():
    """Behaviour spec/SYNTAX.md does not settle: crash/hang checks only."""
    for name, body in (("literal_trailing_dot", "let x: int = 1.\nio.println(x)"),
                       ("string_stray_close_brace", 'let s: string = "a}b"'),
                       ("map_duplicate_literal_key", "let m: Map<int, int> = {1: 2, 1: 3}")):
        yield case(name, main_body(body), "unspecified", "lexical", "explore", modes=CHECK)
    yield case("source_invalid_utf8", "fn main() {\n    let s: string = \"\\xff\\xfe\"\n}\n", "unspecified", "strings",
               "explore", modes=CHECK)


def corpus(seed, extreme=False, mutations=True):
    """Every case once: the crash witnesses overlap the extreme depths."""
    seen = set()
    for c in _corpus(seed, extreme, mutations):
        if c["name"] not in seen:
            seen.add(c["name"])
            yield c


def _corpus(seed, extreme=False, mutations=True):
    rng = random.Random(seed)
    valid = list(valid_cases())
    for c in valid:
        yield c
    for c in reject_cases():
        yield c
    for c in explore_cases():
        yield c
    for c in diagnostic_cases():
        yield c
    depths = [1, 32, 255, 256, 257]
    if extreme:
        depths += [4096, 8192, 32768]
    for shape in NESTED_SHAPES:
        for depth in depths:
            yield nested_case(shape, depth)
    yield nested_case("flat_operators", 512)
    yield nested_case("flat_members", 128)
    # Crash witnesses: recorded compiler faults, cheap to replay every run.
    for shape, depth in CRASH_WITNESSES:
        yield nested_case(shape, depth)
    if extreme:
        for shape in ("flat_operators", "flat_members"):
            for depth in (4096, 16384, 32768):
                yield nested_case(shape, depth)
    if mutations:
        for c in valid:
            source = c["files"]["main.b"]
            boundaries = [m.end() for m in re.finditer(r"[\s{}(),<>]", source)]
            if not boundaries:
                continue
            for index, offset in enumerate(rng.sample(boundaries, min(4, len(boundaries)))):
                yield case(c["name"] + "_truncate_" + str(index), source[:offset],
                           c["feature"], c["spec"].split("#")[-1], "explore")
            offset = rng.randrange(len(source) + 1)
            yield case(c["name"] + "_insert", source[:offset] + "]" + source[offset:],
                       c["feature"], c["spec"].split("#")[-1], "explore")


NESTED_SHAPES = ("parentheses", "types", "blocks", "interpolation", "prefix", "mixed", "calls")
CRASH_WITNESSES = (("parentheses", 32768), ("calls", 8192), ("flat_members", 16384),
                   ("flat_operators", 32768))


def nested_case(shape, depth):
    prelude = ""
    if shape == "parentheses":
        body = "let x: int = " + "(" * depth + "1" + ")" * depth
    elif shape == "types":
        body = "let x: " + "Option<" * depth + "int" + ">" * depth + " = none"
    elif shape == "blocks":
        body = "if true { " * depth + "let x: int = 1\n" + "}" * depth
    elif shape == "interpolation":
        body = 'let x: string = "value {' + "(" * depth + "1" + ")" * depth + '}"'
    elif shape == "mixed":
        expression = "1"
        for layer in range(depth):
            expression = ("(" + expression + ")" if layer % 2 == 0 else
                          "if true { " + expression + " } else { 1 }")
        body = "let x: int = " + expression
    elif shape == "calls":
        prelude = "fn id(v: int) -> int { return v }\n"
        body = "let x: int = " + "id(" * depth + "1" + ")" * depth
    elif shape == "flat_operators":
        body = "let x: int = " + " + ".join(["1"] * depth)
    elif shape == "flat_members":
        body = 'let x: int = "x"' + ".trim()" * depth + ".len()"
    else:
        body = "let x: bool = " + "!" * depth + "true"
    flat = shape.startswith("flat_")
    # A flat chain has no nesting contract yet (docs/BUGFIX_TODO.md); it must
    # simply never fault. Nested constructs follow the proposed 256 limit.
    disposition = ("explore" if flat else "valid" if depth <= NESTING_LIMIT else "reject")
    extra = {}
    if disposition == "reject":
        extra["rejection"] = {"file": "main.b", "message": "(?i)nest|depth|complexity|limit", "count": 1}
    return case("nest_{}_{}".format(shape, depth), prelude + "fn main() {\n    " + body + "\n}\n",
                ("shallow-long-chains" if flat else "nesting-" + shape),
                ("number-rules" if flat else "lexical"), disposition,
                modes=["parse", "check"], shape=shape, depth=depth, **extra)


def diagnostic_cases():
    directory = ROOT / "test/cases/discovery"
    if not directory.exists():
        return []
    result = []
    for manifest in sorted(directory.glob("*.json")):
        if manifest.name == "known_failures.json":
            continue
        c = json.loads(manifest.read_text())
        c["files"] = {rel: (directory / source).read_bytes().decode("utf-8")
                      for rel, source in c.pop("source_files").items()}
        c["snapshots"] = {stream: (directory / path).read_text()
                          for stream, path in c.get("snapshot_files", {}).items()}
        result.append(c)
    return result


def spec_anchors():
    """Slugs of every heading in spec/SYNTAX.md, as a Markdown renderer links them."""
    anchors = set()
    for line in SPEC.read_text().splitlines():
        if not line.startswith("#"):
            continue
        text = re.sub(r"^#+\s*", "", line).strip().replace("`", "").lower()
        text = re.sub(r"[^\w\s-]", "", text)
        anchors.add(re.sub(r"\s+", "-", text.strip()))
    return anchors


# GNU make raises the soft stack limit to the hard limit for everything it
# runs, so a depth that faults from a shell survives under `make`. Every
# compiler invocation here gets the same 8 MiB main-thread stack, which is the
# Linux and macOS shell default, so a crash witness means the same thing on
# every host and in every runner. Windows sizes the stack in the executable.
STACK_LIMIT_BYTES = 8 * 1024 * 1024


def limit_stack():
    try:
        import resource
    except ImportError:
        return None
    soft, hard = resource.getrlimit(resource.RLIMIT_STACK)
    wanted = STACK_LIMIT_BYTES if hard == resource.RLIM_INFINITY else min(STACK_LIMIT_BYTES, hard)

    def apply():
        resource.setrlimit(resource.RLIMIT_STACK, (wanted, hard))
    return apply


def execute(beansc, mode, directory, timeout):
    cmd = [beansc, mode, os.path.join(directory, "main.b")]
    started = time.monotonic()
    kind, out, err, code = df.run_proc(cmd, timeout, preexec_fn=limit_stack())
    return df.LaneResult(mode, kind, out, err, code, [cmd],
                         elapsed_seconds=time.monotonic() - started)


def context_failures(result, c, directory):
    text = df.normalize_diagnostics(result.stdout + result.stderr, directory)
    failures = []
    for stream, expected in c.get("snapshots", {}).items():
        actual = df.normalize_diagnostics(getattr(result, stream), directory)
        if actual != expected:
            failures.append({"lane": result.lane, "kind": "snapshot-" + stream})
    # Ordered notes must carry the actual authored source locations. Merely
    # printing an enclosing function's name somewhere is not sufficient.
    cursor = 0
    for context in c.get("context", []):
        pattern = (r"(?m)^.*note:.*" + context["message"] + r".*" +
                   re.escape(context["file"]) + ":" + str(context["line"]) +
                   ":" + str(context["col"]) + r"\b.*$")
        match = re.search(pattern, text[cursor:])
        if not match:
            failures.append({"lane": result.lane, "kind": "missing-context"})
            break
        cursor += match.end()
    if c.get("caret") and "^" not in text:
        failures.append({"lane": result.lane, "kind": "missing-source-caret"})
    return failures


def evaluate(result, c, directory, quality=True):
    if c["disposition"] == "reject":
        failures = df.rejection_failures(result, c["rejection"], directory)
        if quality and result.lane == "check":
            failures += context_failures(result, c, directory)
    elif result.status != "ok":
        failures = [{"lane": result.lane, "kind": result.status}]
    elif c["disposition"] == "valid":
        failures = ([] if result.exit_code == 0 else
                    [{"lane": result.lane, "kind": "valid-rejected"}])
    else:
        # A truncation can still be valid. Do not label it invalid by guessing.
        failures = ([] if result.exit_code in (0, 1) else
                    [{"lane": result.lane, "kind": "unexpected-exit"}])
        if result.exit_code == 1:
            text = df.normalize_diagnostics(result.stdout + result.stderr, directory)
            if not re.search(r"main\.b:[1-9]\d*:[1-9]\d*: error:", text):
                failures.append({"lane": result.lane, "kind": "missing-diagnostic"})
    if result.lane == "ast":
        for fragment in c.get("ast_contains", []):
            if fragment not in result.stdout:
                failures.append({"lane": result.lane, "kind": "recovery-lost-statement"})
    return failures


def run_case(args, c, index, out_root):
    directory = os.path.join(out_root, "work", c["name"])
    os.makedirs(directory, exist_ok=True)
    df.write_case_files(directory, c["files"])
    results = [execute(args.beansc, mode, directory, args.timeout) for mode in c["modes"]]
    failures = [f for result in results for f in evaluate(result, c, directory)]
    if c.get("repair"):
        repair_dir = os.path.join(directory, "repair")
        df.write_case_files(repair_dir, c["repair"])
        control = execute(args.beansc, "check", repair_dir, args.timeout)
        control.lane = "repair-check"
        results.append(control)
        if control.status != "ok" or control.exit_code != 0:
            failures.append({"lane": control.lane, "kind": "repair-invalid"})
    if "output" in c and args.runtime:
        runner = df.Runner(args.beansc, df.resolve_lanes(args.lanes), args.timeout_build,
                           args.timeout_run, directory)
        runner.probe_lto()
        if runner.skipped:
            failures.append({"lane": "lto", "kind": "missing-lanes"})
        extra = runner.run_case(directory, os.path.join(directory, "main.b"))
        results += extra
        failures += df.classify_failures((c["output"], 0), extra, df.resolve_lanes(args.lanes))
    artifact = None
    if failures:
        config = {"groups": ["syntax", c["feature"]], "max_depth": c.get("depth", 0),
                  "max_stmts": 0, "lanes": c["modes"], "beansc": args.beansc,
                  "syntax_generator_version": GENERATOR_VERSION, "syntax_case": c,
                  "stack_limit_bytes": STACK_LIMIT_BYTES if limit_stack() else None}
        artifact = df.save_failure(out_root, "syntax-" + str(args.seed), index,
                                   c["files"], (c.get("output", ""),
                                   1 if c["disposition"] == "reject" else 0),
                                   results, failures, config)
        reduce_nesting(args, c, failures, artifact)
    return {"case": c["name"], "feature": c["feature"], "spec": c["spec"],
            "disposition": c["disposition"], "failures": failures,
            "artifact": artifact,
            "results": [{"mode": r.lane, "status": r.status, "exit": r.exit_code,
                         "seconds": r.elapsed_seconds} for r in results]}


def reduce_nesting(args, c, failures, artifact):
    """Reduce a depth failure while preserving its lane and category."""
    if not c.get("depth") or not args.reduce:
        return
    flat = c["shape"].startswith("flat_")
    floor = 1 if flat else NESTING_LIMIT + 1
    if c["depth"] <= floor:
        return
    target = df.failure_signature(failures)
    lo, hi = floor, c["depth"]
    best = c
    observations = []
    with tempfile.TemporaryDirectory(prefix="beans-syntax-reduce-") as directory:
        for _ in range(16):
            if lo > hi:
                break
            depth = (lo + hi) // 2
            candidate = nested_case(c["shape"], depth)
            df.write_case_files(directory, candidate["files"])
            results = [execute(args.beansc, mode, directory, args.timeout) for mode in c["modes"]]
            current = [f for r in results for f in evaluate(r, candidate, directory)]
            preserved = target.issubset(df.failure_signature(current))
            observations.append({"depth": depth, "preserved": preserved, "failures": current})
            if preserved:
                best, hi = candidate, depth - 1
            else:
                lo = depth + 1
        df.write_case_files(os.path.join(artifact, "reduced"), best["files"])
        df.write_case_files(directory, best["files"])
        final = [execute(args.beansc, mode, directory, args.timeout) for mode in c["modes"]]
        reduced_failures = [f for r in final for f in evaluate(r, best, directory)]
        # Record final evidence; do not call an unreproduced shrink confirmed.
        with open(os.path.join(artifact, "reduced_meta.json"), "w") as f:
            json.dump({"case": best, "target_failures": failures, "failures": reduced_failures,
                       "preserved": target.issubset(df.failure_signature(reduced_failures)),
                       "search": observations}, f, indent=2)
        for r in final:
            pathlib.Path(artifact, "reduced-" + r.lane + ".stdout").write_text(r.stdout)
            pathlib.Path(artifact, "reduced-" + r.lane + ".stderr").write_text(r.stderr)


def replay(args):
    meta = json.loads(pathlib.Path(args.replay_dir, "meta.json").read_text())
    c = meta["configuration"]["syntax_case"]
    c["files"] = {rel: pathlib.Path(args.replay_dir, rel).read_bytes().decode()
                  for rel in meta["files"]}
    if args.replay_reduced:
        reduced = json.loads(pathlib.Path(args.replay_dir, "reduced_meta.json").read_text())
        c = reduced["case"]
        c["files"] = {rel: pathlib.Path(args.replay_dir, "reduced", rel).read_bytes().decode()
                      for rel in c["files"]}
    c["original_failures"] = meta["failures"]
    expected = reduced["target_failures"] if args.replay_reduced else meta["failures"]
    result = run_case(args, c, meta["case"], args.out)
    print(json.dumps(result, indent=2))
    if not result["failures"]:
        return 0
    if set(limit_signature(expected)) <= set(limit_signature(result["failures"])):
        return 1
    # Some failure, but not the retained one: the evidence is not confirmed.
    print("replay reproduced a different failure: retained {}, observed {}".format(
        ",".join(signature(expected)), ",".join(signature(result["failures"]))), file=sys.stderr)
    return 3


def limit_signature(failures):
    """Signature for reproduction: the two resource limits count as one kind.

    At a boundary depth the time limit and the output limit race (a `parse`
    that prints a quadratic tree trips one or the other), and which one wins
    says nothing about the compiler; crash, hang, acceptance and diagnostic
    kinds stay distinct.
    """
    return sorted({"{}:{}".format(f["lane"], "limit" if f["kind"] in ("timeout", "output-limit")
                                  else f["kind"]) for f in failures})


# ---------------------------------------------------------------------------
# known-failure baseline

def signature(failures):
    return sorted({"{}:{}".format(f["lane"], f["kind"]) for f in failures})


def load_baseline(path):
    if not path or not os.path.exists(path):
        return {}
    data = json.loads(pathlib.Path(path).read_text())
    for name, entry in data.items():
        if not isinstance(entry, dict) or not entry.get("finding") or \
                not isinstance(entry.get("failures"), list) or not entry["failures"]:
            raise SystemExit("known_failures.json: {} needs a finding and a failure list".format(name))
    return data


def classify(row, baseline):
    """passed | known | new | changed | stale. Only `passed` and `known` are green."""
    actual = signature(row["failures"])
    known = baseline.get(row["case"])
    if not actual:
        return "stale" if known else "passed"
    if known is None:
        return "new"
    if actual == sorted(known["failures"]):
        return "known"
    return "changed"


def self_test():
    checks = list(df.harness_fault_checks()) + list(df.oracle_contract_checks())
    first = list(corpus(11, mutations=True))
    checks.append(("syntax-determinism", first == list(corpus(11, mutations=True))))
    checks.append(("mutation-dispositions", all(c["disposition"] == "explore"
                   for c in first if "_truncate_" in c["name"] or c["name"].endswith("_insert"))))
    checks.append(("nesting-boundaries", [nested_case("parentheses", n)["disposition"]
                   for n in (255, 256, 257)] == ["valid", "valid", "reject"]))
    extreme = list(corpus(11, extreme=True))
    checks.append(("unique-case-names", len({c["name"] for c in first}) == len(first) and
                   len({c["name"] for c in extreme}) == len(extreme)))
    anchors = spec_anchors()
    unlinked = sorted({c["spec"] for c in first if c["spec"].split("#")[-1] not in anchors})
    checks.append(("spec-anchors-exist", not unlinked))
    if unlinked:
        print("unlinked spec anchors: " + ", ".join(unlinked))
    # Every must-reject case names a located expectation; every valid case with
    # an output has one; explore cases claim nothing.
    checks.append(("reject-expectations-located", all(
        c["disposition"] != "reject" or
        all(e.get("line") for e in c["rejection"].get("errors", [c["rejection"]])) or
        c.get("depth") for c in first)))
    checks.append(("explore-claims-nothing", all(
        "rejection" not in c and "output" not in c for c in first if c["disposition"] == "explore")))
    checks.append(("checker-rejects-not-lexed", all(
        c["disposition"] != "reject" or c["modes"] != CHECK or not c.get("depth") for c in first)))
    snapshot = {"name": "control", "disposition": "reject",
                "rejection": {"file": "main.b", "line": 2, "message": "expected", "count": 1},
                "context": [{"file": "main.b", "line": 1, "col": 8, "message": "in function"}],
                "caret": True}
    good = df.LaneResult("check", "ok", "", "main.b:2:4: error: expected ')'\n"
                         "  ^\nnote: in function main at main.b:1:8\n", 1, [])
    checks.append(("context-control", not evaluate(good, snapshot, "/tmp/case")))
    broken = copy.deepcopy(good)
    broken.stderr = broken.stderr.split("note:")[0]
    checks.append(("context-omission", bool(evaluate(broken, snapshot, "/tmp/case"))))
    broken = copy.deepcopy(good)
    broken.stderr = broken.stderr.replace("main.b:1:8", "main.b:9:8")
    checks.append(("context-wrong-location", bool(evaluate(broken, snapshot, "/tmp/case"))))
    broken = copy.deepcopy(good)
    broken.stderr = broken.stderr.replace("^", " ")
    checks.append(("caret-omission", bool(evaluate(broken, snapshot, "/tmp/case"))))
    snapshot["snapshots"] = {"stderr": good.stderr}
    broken = copy.deepcopy(good)
    broken.stderr += "main.b:8:1: error: injected derivative error\n"
    checks.append(("snapshot-extra-error", bool(evaluate(broken, snapshot, "/tmp/case"))))
    # The baseline must never turn a new or drifted failure green, and a
    # known failure that stops reproducing must demand a record update.
    baseline = {"k": {"finding": "CD-0", "failures": ["check:invalid-accepted"]}}
    known = {"case": "k", "failures": [{"lane": "check", "kind": "invalid-accepted"}]}
    checks.append(("baseline-known", classify(known, baseline) == "known"))
    checks.append(("baseline-new-case", classify(dict(known, case="other"), baseline) == "new"))
    checks.append(("baseline-changed-signature", classify(dict(known, failures=known["failures"] + [
        {"lane": "parse", "kind": "crash"}]), baseline) == "changed"))
    checks.append(("baseline-stale", classify(dict(known, failures=[]), baseline) == "stale"))
    checks.append(("baseline-clean-pass", classify(dict(known, case="fresh", failures=[]), baseline) == "passed"))
    if BASELINE.exists():
        recorded = load_baseline(BASELINE)
        names = {c["name"] for c in corpus(1, extreme=True)}
        orphans = sorted(set(recorded) - names)
        checks.append(("baseline-names-exist", not orphans))
        if orphans:
            print("baseline entries without a case: " + ", ".join(orphans))
        todo = (ROOT / "docs/BUGFIX_TODO.md").read_text() if (ROOT / "docs/BUGFIX_TODO.md").exists() else ""
        untracked = sorted({e["finding"] for e in recorded.values() if e["finding"] not in todo})
        checks.append(("baseline-findings-tracked", not untracked))
        if untracked:
            print("baseline findings missing from docs/BUGFIX_TODO.md: " + ", ".join(untracked))
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    return int(not all(ok for _, ok in checks))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--beansc", default="build/beansc")
    ap.add_argument("--out", default="build/compiler-discovery/syntax")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--timeout-build", type=float, default=120)
    ap.add_argument("--timeout-run", type=float, default=20)
    ap.add_argument("--extreme", action="store_true")
    ap.add_argument("--reduce", action="store_true")
    ap.add_argument("--runtime", action="store_true")
    ap.add_argument("--lanes", default="debug")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--replay-dir")
    ap.add_argument("--replay-reduced", action="store_true")
    ap.add_argument("--emit-corpus")
    ap.add_argument("--case", action="append", help="run an exact named case from the matrix")
    ap.add_argument("--mutations-only", action="store_true",
                    help="only the generated truncation/insertion edits (fresh-seed process-safety stress)")
    ap.add_argument("--baseline", default=str(BASELINE),
                    help="known failures that stay green in a per-change run")
    ap.add_argument("--ignore-baseline", action="store_true",
                    help="release candidate: every failure blocks")
    ap.add_argument("--write-baseline", metavar="PATH",
                    help="write the observed failure signatures (findings must then be assigned)")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.replay_dir:
        return replay(args)
    cases = list(corpus(args.seed, args.extreme))
    if args.case:
        missing = set(args.case) - {c["name"] for c in cases}
        if missing:
            ap.error("unknown cases: " + ", ".join(sorted(missing)))
        cases = [c for c in cases if c["name"] in args.case]
    if args.mutations_only:
        # The generated incomplete edits only: authored probes and the crash
        # witnesses have their own place in the matrix and the baseline.
        cases = [c for c in cases if "_truncate_" in c["name"] or c["name"].endswith("_insert")]
    if args.emit_corpus:
        os.makedirs(args.emit_corpus, exist_ok=True)
        for c in cases:
            df.write_case_files(os.path.join(args.emit_corpus, c["name"]), c["files"])
        pathlib.Path(args.emit_corpus, "manifest.json").write_text(json.dumps(cases, indent=2) + "\n")
        return 0
    baseline = {} if args.ignore_baseline else load_baseline(args.baseline)
    os.makedirs(args.out, exist_ok=True)
    started = time.monotonic()
    rows = []
    for index, c in enumerate(cases):
        row = run_case(args, c, index, args.out)
        row["status"] = classify(row, baseline)
        row["finding"] = baseline.get(c["name"], {}).get("finding")
        rows.append(row)
        if row["failures"]:
            print("{} {}: {}".format("KNOWN" if row["status"] == "known" else "FAIL", c["name"],
                                     ",".join(signature(row["failures"]))), flush=True)
        elif row["status"] == "stale":
            print("STALE {}: baseline entry no longer reproduces".format(c["name"]), flush=True)
    counts = {status: sum(r["status"] == status for r in rows)
              for status in ("passed", "known", "new", "changed", "stale")}
    blocked = counts["new"] + counts["changed"] + counts["stale"] > 0
    report = {"generator_version": GENERATOR_VERSION, "seed": args.seed,
              "proposed_nesting_limit": NESTING_LIMIT,
              "stack_limit_bytes": STACK_LIMIT_BYTES if limit_stack() else None,
              "baseline": None if args.ignore_baseline else args.baseline,
              "compiler": df.compiler_evidence(args.beansc), "cases": rows,
              "counts": counts, "seconds": time.monotonic() - started,
              "status": "blocked" if blocked else "passed"}
    pathlib.Path(args.out, "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if args.write_baseline:
        observed = {r["case"]: {"finding": (r["finding"] or "UNASSIGNED"),
                                "failures": signature(r["failures"])}
                    for r in rows if r["failures"]}
        pathlib.Path(args.write_baseline).write_text(json.dumps(observed, indent=2, sort_keys=True) + "\n")
    matrix = ["# Syntax discovery coverage", "",
              "Seed: `{}`; status: **{}**; {} passed, {} known, {} new, {} changed, {} stale.".format(
                  args.seed, report["status"], counts["passed"], counts["known"], counts["new"],
                  counts["changed"], counts["stale"]),
              "", "Compiler revision `{}`, binary SHA-256 `{}`.".format(
                  report["compiler"]["revision"][:12], report["compiler"]["sha256"][:16]),
              "", "| Case | Contract | Modes | Expected | Result | Status |",
              "|---|---|---|---|---|---|"]
    matrix += ["| {} | [{}]({}) | {} | {} | {} | {} |".format(
        r["case"], r["feature"], "../../../" + r["spec"],
        ", ".join(x["mode"] for x in r["results"]), r["disposition"],
        ", ".join(signature(r["failures"])) or "passed",
        r["status"] + (" ({})".format(r["finding"]) if r["finding"] else "")) for r in rows]
    pathlib.Path(args.out, "coverage.md").write_text("\n".join(matrix) + "\n")
    print("syntax discovery: {} cases; {} passed, {} known, {} new, {} changed, {} stale; {}".format(
        len(rows), counts["passed"], counts["known"], counts["new"], counts["changed"],
        counts["stale"], report["status"]))
    return int(blocked)


if __name__ == "__main__":
    sys.exit(main())
