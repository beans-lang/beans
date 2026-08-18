package main

// LLVM integer constants use decimal text. Source base prefixes are parsed
// here so a u32 mask such as 0xffffffff does not become invalid IR.
fn llvm_integer_constant(text: string) -> string {
    let cleaned: string = text.replace("_", "")
    var index: int = 0
    var negative: bool = false
    if cleaned.starts_with("-") {
        negative = true
        index = 1
    }
    if index + 2 > cleaned.len() ||
       cleaned.byte_at(index) != 48 {
        return cleaned
    }
    let marker: int = cleaned.byte_at(index + 1)
    var base: int = 0
    if marker == 120 || marker == 88 {
        base = 16
    } else if marker == 98 || marker == 66 {
        base = 2
    } else if marker == 111 || marker == 79 {
        base = 8
    } else {
        return cleaned
    }
    index += 2
    let digits: string =
        cleaned.slice(index, cleaned.len())
    // These two full-width spellings cannot be accumulated in Beans int.
    if !negative &&
       base == 16 &&
       digits.to_lower() == "ffffffffffffffff" {
        return "-1"
    }
    if negative &&
       base == 16 &&
       digits.to_lower() == "8000000000000000" {
        return "-9223372036854775808"
    }
    var value: int = 0
    for position: int in 0..digits.len() {
        let byte: int = digits.byte_at(position)
        var digit: int = -1
        if byte >= 48 && byte <= 57 {
            digit = byte - 48
        } else if byte >= 65 && byte <= 70 {
            digit = byte - 65 + 10
        } else if byte >= 97 && byte <= 102 {
            digit = byte - 97 + 10
        }
        if digit < 0 || digit >= base {
            return cleaned
        }
        value = value * base + digit
    }
    if negative { value = 0 - value }
    return "{value}"
}

// Mirrors the interpreter's decimal parse: one digit string, a scale from the
// dot and exponent, leading zeros stripped, 38 digits and scale 65535 the
// caps. The i128 coefficient is emitted as its digit text — LLVM parses wide
// decimal constants, so no 128-bit arithmetic happens here. "" means the
// literal is out of range and the caller reports it.
fn llvm_decimal_constant(text: string) -> string {
    // The spare word stays i64, matching BDec. LLVM's s390x ABI lowering reads
    // an equivalent [8 x i8] tail from the wrong argument offsets after the
    // register arguments fill.
    var negative: bool = false
    var index: int = 0
    if text.len() > 0 {
        let sign: int = text.byte_at(0)
        if sign == 45 {
            negative = true
            index = 1
        } else if sign == 43 {
            index = 1
        }
    }
    var digits: string = ""
    var fractional: int = 0
    var after_dot: bool = false
    var exponent: int = 0
    var seen_digit: bool = false
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if byte == 95 {
            index += 1
            continue
        }
        if byte == 46 {
            if after_dot { return "" }
            after_dot = true
            index += 1
            continue
        }
        if byte == 101 || byte == 69 {
            var cleaned: string = ""
            let tail: string =
                text.slice(index + 1, text.len())
            for position: int in 0..tail.len() {
                if tail.byte_at(position) != 95 {
                    cleaned =
                        "{cleaned}{tail.slice(position, position + 1)}"
                }
            }
            if cleaned.starts_with("+") {
                cleaned =
                    cleaned.slice(1, cleaned.len())
            }
            if cleaned == "" { return "" }
            // the sentinel is unreachable as a real exponent: any
            // exponent near it fails the scale caps below anyway
            let unread: int = 0 - 88888888
            exponent = cleaned.to_int().or(unread)
            if exponent == unread { return "" }
            break
        }
        if byte < 48 || byte > 57 { return "" }
        digits =
            "{digits}{text.slice(index, index + 1)}"
        seen_digit = true
        if after_dot { fractional += 1 }
        index += 1
    }
    if !seen_digit { return "" }
    var first_nonzero: int = 0 - 1
    for position: int in 0..digits.len() {
        if digits.byte_at(position) != 48 {
            first_nonzero = position
            break
        }
    }
    if first_nonzero < 0 {
        var zero_scale: int = fractional - exponent
        if zero_scale < 0 { zero_scale = 0 }
        if zero_scale > 65535 { return "" }
        return "\{ i128 0, i64 {zero_scale}, i64 0 \}"
    }
    digits =
        digits.slice(first_nonzero, digits.len())
    var scale: int = fractional - exponent
    if scale < 0 {
        let append: int = 0 - scale
        if append > 38 ||
           digits.len() + append > 38 {
            return ""
        }
        for count: int in 0..append {
            digits = "{digits}0"
        }
        scale = 0
    }
    if scale > 65535 || digits.len() > 38 {
        return ""
    }
    let sign: string = if negative { "-" } else { "" }
    return "\{ i128 {sign}{digits}, i64 {scale}, i64 0 \}"
}
