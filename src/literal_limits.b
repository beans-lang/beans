package main

fn integer_literal_bits(name: string) -> int {
    let canonical: string = canonical_hir_name(name)
    if canonical == "i8" || canonical == "u8" { return 8 }
    if canonical == "i16" || canonical == "u16" { return 16 }
    if canonical == "i32" || canonical == "u32" { return 32 }
    if canonical == "int" || canonical == "u64" { return 64 }
    return 0
}

fn integer_literal_signed(name: string) -> bool {
    let canonical: string = canonical_hir_name(name)
    return canonical == "int" || canonical == "i8" ||
           canonical == "i16" || canonical == "i32"
}

fn without_leading_zeroes(value: string) -> string {
    var first: int = 0
    for first < value.len() && value.byte_at(first) == 48 {
        first += 1
    }
    return value.slice(first, value.len())
}

fn decimal_magnitude_at_most(value: string,
                             limit: string) -> bool {
    let magnitude: string =
        without_leading_zeroes(value)
    if magnitude.len() != limit.len() {
        return magnitude.len() < limit.len()
    }
    for index: int in 0..magnitude.len() {
        let digit: int = magnitude.byte_at(index)
        let edge: int = limit.byte_at(index)
        if digit != edge { return digit < edge }
    }
    return true
}

fn hex_digit_value(value: int) -> int {
    if value >= 48 && value <= 57 { return value - 48 }
    if value >= 65 && value <= 70 { return value - 65 + 10 }
    if value >= 97 && value <= 102 { return value - 97 + 10 }
    return 16
}

fn power_of_two_edge(value: string, edge: int) -> bool {
    if value.len() == 0 ||
       hex_digit_value(value.byte_at(0)) != edge {
        return false
    }
    for index: int in 1..value.len() {
        if hex_digit_value(value.byte_at(index)) != 0 {
            return false
        }
    }
    return true
}

fn integer_decimal_limit(bits: int,
                         signed: bool,
                         negative: bool) -> string {
    if bits == 8 {
        if signed {
            return if negative { "128" } else { "127" }
        }
        return "255"
    }
    if bits == 16 {
        if signed {
            return if negative { "32768" } else { "32767" }
        }
        return "65535"
    }
    if bits == 32 {
        if signed {
            return if negative { "2147483648" } else { "2147483647" }
        }
        return "4294967295"
    }
    if signed {
        return if negative {
            "9223372036854775808"
        } else {
            "9223372036854775807"
        }
    }
    return "18446744073709551615"
}

fn integer_literal_fits(text: string,
                        type_name: string,
                        negative: bool) -> bool {
    let bits: int = integer_literal_bits(type_name)
    let signed: bool = integer_literal_signed(type_name)
    if bits == 0 { return true }

    var base: int = 10
    var digits: string = text.replace("_", "")
    if digits.starts_with("0x") || digits.starts_with("0X") {
        base = 16
        digits = digits.slice(2, digits.len())
    } else if digits.starts_with("0b") ||
              digits.starts_with("0B") {
        base = 2
        digits = digits.slice(2, digits.len())
    }
    digits = without_leading_zeroes(digits)
    if digits.len() == 0 { return true }
    if negative && !signed { return false }

    if base == 10 {
        return decimal_magnitude_at_most(
            digits,
            integer_decimal_limit(bits, signed, negative))
    }
    if base == 2 {
        if !signed { return digits.len() <= bits }
        if digits.len() < bits { return true }
        if digits.len() > bits || !negative { return false }
        return power_of_two_edge(digits, 1)
    }

    let width: int = bits / 4
    if digits.len() < width { return true }
    if digits.len() > width { return false }
    if !signed { return true }
    let first: int = hex_digit_value(digits.byte_at(0))
    if !negative { return first <= 7 }
    if first < 8 { return true }
    return first == 8 && power_of_two_edge(digits, 8)
}

fn integer_literal_range(type_name: string) -> string {
    let bits: int = integer_literal_bits(type_name)
    let signed: bool = integer_literal_signed(type_name)
    if signed {
        return "-{integer_decimal_limit(bits, true, true)}..{integer_decimal_limit(bits, true, false)}"
    }
    return "0..{integer_decimal_limit(bits, false, false)}"
}

fn integer_literal_syntax(node: AstNode) -> bool {
    if node.kind == "literal" && node.note == "int" {
        return true
    }
    return node.kind == "unary" && node.value == "-" &&
           node.children.len() == 1 &&
           integer_literal_syntax(node.children[0])
}

fn decimal_exponent_fits(value: string,
                         negative: bool) -> bool {
    return decimal_magnitude_at_most(
        value,
        if negative {
            "9223372036854775808"
        } else {
            "9223372036854775807"
        })
}

fn decimal_literal_fits(text: string) -> bool {
    let source: string = text.replace("_", "")
    var fractional: int = 0
    var after_dot: bool = false
    var significant: int = 0
    var saw_nonzero: bool = false
    var exponent_at: int = source.len()
    for index: int in 0..source.len() {
        let byte: int = source.byte_at(index)
        if byte == 101 || byte == 69 {
            exponent_at = index
            break
        }
        if byte == 46 {
            after_dot = true
            continue
        }
        if after_dot { fractional += 1 }
        if byte != 48 { saw_nonzero = true }
        if saw_nonzero { significant += 1 }
    }

    var exponent_negative: bool = false
    var exponent_digits: string = ""
    if exponent_at < source.len() {
        var start: int = exponent_at + 1
        if start < source.len() &&
           (source.byte_at(start) == 43 ||
            source.byte_at(start) == 45) {
            exponent_negative =
                source.byte_at(start) == 45
            start += 1
        }
        exponent_digits = without_leading_zeroes(
            source.slice(start, source.len()))
        if exponent_digits.len() > 0 &&
           !decimal_exponent_fits(
               exponent_digits, exponent_negative) {
            return false
        }
    }

    if exponent_digits.len() > 7 {
        return !saw_nonzero && !exponent_negative
    }
    var exponent: int = 0
    for index: int in 0..exponent_digits.len() {
        exponent =
            exponent * 10 +
            exponent_digits.byte_at(index) - 48
    }
    if exponent_negative { exponent = -exponent }

    let scale: int = fractional - exponent
    if !saw_nonzero {
        return scale <= 65535
    }
    if significant > 38 { return false }
    if scale < 0 {
        let append: int = -scale
        return append <= 38 &&
               significant + append <= 38
    }
    return scale <= 65535
}
