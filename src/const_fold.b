package main

// Folding a module constant.
//
// `const NAME: T = <expression>` has no storage: every use is the value,
// written where the use is. Folding therefore happens once, on the *checked*
// HIR of the initializer, so the language's own typing decides what each
// operator means and the fold cannot invent a promotion rule the rest of the
// compiler does not have. What comes back is the spelling a literal of that
// type is written in, which is what a use site materializes — so a constant
// behaves exactly as if its value had been typed at the use site, in both
// backends, with nothing left for them to disagree about.

struct ConstValue {
    // "int", "float", "decimal", "bool", "string", or "" when folding failed
    kind: string
    // the exact value for "int"; 0 or 1 for "bool"
    number: int
    // the literal spelling a use site materializes: "42", "-42", "0xFF",
    // "1.5", "true", "\"hi\"" — a leading '-' becomes unary minus over the
    // magnitude, which is the shape source itself produces
    text: string
}

fn const_value_failed() -> ConstValue {
    return ConstValue { kind: "", number: 0, text: "" }
}

// The length a constant supplies for a fixed array, and why it supplies
// none. `length` is -1 exactly when the constant cannot be one; `reason` is
// then the sentence to report, or "" when the constant's own declaration
// already reported the reason and a second line would only repeat it.
//
// One rule, in one place: a length written in a signature, in a body, or
// inside a string's `{}` piece is decided here, so the same constant is
// refused for the same reason with the same words wherever it is written.
struct ConstArrayLength {
    length: int
    reason: string
}

fn const_array_length(constant: HirConst) -> ConstArrayLength {
    if !constant.folded {
        return ConstArrayLength { length: -1, reason: "" }
    }
    if constant.kind != "int" {
        return ConstArrayLength {
            length: -1,
            reason: "an array length must be an integer, and const {constant.name} is {constant_kind_article(constant.kind)}",
        }
    }
    // The same bounds a written length has. They are checked here, at the
    // name, because a reader handed "must be between 1 and 4096" about a
    // number they never typed has nothing to trace it back to.
    if constant.number < 1 || constant.number > 4096 {
        return ConstArrayLength {
            length: -1,
            reason: "fixed array length must be between 1 and 4096, and const {constant.name} is {constant.number}",
        }
    }
    return ConstArrayLength {
        length: constant.number, reason: "",
    }
}

// What a folded constant is, in the words a diagnostic uses about it. The
// kind is the fold's own word for the value; a reader who used a constant
// where a number was wanted needs to be told what it holds instead.
fn constant_kind_article(kind: string) -> string {
    if kind == "int" { return "an integer" }
    if kind == "float" { return "a float" }
    if kind == "decimal" { return "a decimal" }
    if kind == "bool" { return "a bool" }
    if kind == "string" { return "a string" }
    return "a {kind}"
}

fn const_value_int(value: int, text: string) -> ConstValue {
    return ConstValue { kind: "int", number: value, text: text }
}

fn const_value_bool(value: bool) -> ConstValue {
    return ConstValue {
        kind: "bool",
        number: if value { 1 } else { 0 },
        text: if value { "true" } else { "false" },
    }
}

// The decimal spelling of a folded integer. Negative values keep the sign
// here and are split back out when the node is built.
fn const_int_text(value: int) -> string {
    return "{value}"
}

// The one place a folded integer is narrowed. Every operation runs at 64
// bits and lands here, so a constant answers what the same expression would
// answer at run time on the same type — `1 << 31` is i32's minimum, not an
// out-of-range error, because that is what the backends compute.
fn const_wrap(value: int, type: HirType) -> int {
    let bits: int = integer_literal_bits(type.name)
    if bits == 0 || bits >= 64 { return value }
    if integer_literal_signed(type.name) {
        return tree_signed_from_bits(value as u64, bits)
    }
    return tree_mask_unsigned(value as u64, bits) as int
}

// u64 is the one integer type a 64-bit signed accumulator cannot carry
// whole. Rather than fold it to a different number than the program would
// compute, folding stops at the first value whose bit pattern has run past
// i64 — the literal path still works, so a mask written out in full is fine.
fn const_unsigned_64(type: HirType) -> bool {
    return canonical_hir_name(type.name) == "u64"
}

// The smallest value the type can hold, as an int. Only the signed types
// have one that division by -1 cannot produce, which is the single case
// where an integer divide has no answer in its own type.
fn const_int_minimum(type: HirType) -> int {
    if !integer_literal_signed(type.name) { return 0 }
    let bits: int = integer_literal_bits(type.name)
    if bits == 0 { return 0 }
    if bits >= 64 { return -9223372036854775807 - 1 }
    return 0 - ((1 as int) << ((bits - 1) as int))
}
