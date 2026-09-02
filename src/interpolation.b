package main

// Where a slot's expression ends and its format spec begins.
//
// The question is asked three times about one program — the checker splits
// the expression here, the tree interpreter reads the spec here, and the
// LLVM emitter emits it here — so it is answered once. When the three
// disagreed the two compilers printed different strings for the same
// literal: the emitter counted only braces, so the `:` in a closure
// parameter's type ended the expression for it and not for anybody else,
// and `"{apply(fn(x: int) -> int { ... }, 9):6}"` came out padded under the
// interpreter and unpadded native.

// The index of the `:` that starts the format spec, or -1 when the slot has
// none. A `:` inside `(`, `[` or `{`, inside a nested string, or inside a
// raw literal is part of the expression, not a separator.
fn interpolation_format_colon(segment: string) -> int {
    var depth: int = 0
    var in_string: bool = false
    var index: int = 0
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte == 92 {
            index += string_escape_length(
                segment, index, segment.len())
            continue
        }
        // A raw literal is bytes: a `:` or a bracket in it is not a format
        // separator and does not nest. Step over it whole so `{r"a:b"}`
        // keeps its own reader's colon.
        if !in_string &&
           raw_open_at(segment, index, segment.len()) {
            index = raw_literal_end(
                segment, index, segment.len())
            continue
        }
        if in_string {
            if byte == 34 { in_string = false }
            index += 1
            continue
        }
        if byte == 34 {
            in_string = true
        } else if byte == 40 || byte == 91 ||
                  byte == 123 {
            depth += 1
        } else if byte == 41 || byte == 93 ||
                  byte == 125 {
            depth -= 1
        } else if byte == 58 && depth == 0 {
            return index
        }
        index += 1
    }
    return -1
}

fn interpolation_expression_source(segment: string) -> string {
    let colon: int = interpolation_format_colon(segment)
    if colon < 0 { return segment }
    return segment.slice(0, colon)
}

// The format spec itself: everything after that `:`, or "" when there is
// none. The emitter and the tree interpreter both start from this, so a
// slot's spec is one substring decided in one place.
fn interpolation_format_spec(segment: string) -> string {
    let colon: int = interpolation_format_colon(segment)
    if colon < 0 { return "" }
    return segment.slice(colon + 1, segment.len())
}
