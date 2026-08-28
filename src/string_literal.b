package main

// What a string literal means, decided in exactly one place.
//
// A literal token keeps the bytes the source wrote — quotes, prefix and
// escapes included — all the way into HIR and MIR, so `beansc lex`, `beansc
// parse` and a diagnostic all show the spelling a reader typed. Everything
// that needs the *value* asks here. Before this file the escape table was
// written out four times (the tree interpreter, the LLVM emitter, and the
// interpolation walker inside each of them); a fifth spelling would have
// been a fifth chance for the two backends to disagree about one program.
//
// Two shapes exist:
//
//   "…"        escapes apply, `{` opens an interpolation
//   r"…"       raw: no escapes, no interpolation, may span lines
//   r#"…"#     raw with n hashes, so the body may hold `"` (and `"#…` for
//              fewer hashes than the opener used)

// ---- shape -----------------------------------------------------------------

// The number of '#' a raw literal opening at `index` uses, or -1 when a raw
// literal does not open there. `r"` opens with none, so it answers 0; `r#"`
// answers 1. This is the raw-literal test at an arbitrary position — the
// lexer asks it at the start of a token, and a brace-matcher asks it in the
// middle of an interpolation, so both agree on what `r"…"` means.
fn raw_hashes_at(source: string, index: int, end: int) -> int {
    if index >= end || source.byte_at(index) != 114 { return -1 }
    var at: int = index + 1
    for at < end && source.byte_at(at) == 35 {
        at += 1
    }
    if at >= end || source.byte_at(at) != 34 {
        return -1
    }
    return at - index - 1
}

// A raw literal opens at `index`, and its `r` is a fresh token: the byte
// before it is not an identifier byte, so a name that ends in `r` — `str`,
// `ptr` — right before a `"` is not read as a raw prefix. This is the rule
// the lexer already keeps by scanning a whole identifier before it ever
// looks for `r"`, restated so a walker re-reading a string token agrees with
// how that token was lexed.
fn raw_open_at(source: string, index: int, end: int) -> bool {
    if raw_hashes_at(source, index, end) < 0 { return false }
    if index > 0 && is_ident_byte(source.byte_at(index - 1)) {
        return false
    }
    return true
}

// One past the terminator of the raw literal that opens at `index`, or `end`
// when it never closes. `index` must be where `raw_hashes_at` said a raw
// literal opens. A walker stepping over a raw literal nested in an
// interpolation calls this, so the checker, both backends and the lexer all
// find the same end of `r"…"` and split one string the same way.
fn raw_literal_end(source: string, index: int, end: int) -> int {
    let hashes: int = raw_hashes_at(source, index, end)
    if hashes < 0 { return index }
    var at: int = index + hashes + 2
    for at < end {
        if source.byte_at(at) == 34 {
            var seen: int = 0
            for seen < hashes && at + 1 + seen < end &&
                source.byte_at(at + 1 + seen) == 35 {
                seen += 1
            }
            if seen == hashes {
                return at + 1 + hashes
            }
        }
        at += 1
    }
    return end
}

// The number of '#' a raw literal opened with, or -1 when `source` is an
// ordinary escaped literal. `r"…"` opened with none, so it answers 0.
fn string_literal_hashes(source: string) -> int {
    return raw_hashes_at(source, 0, source.len())
}

fn string_literal_is_raw(source: string) -> bool {
    return string_literal_hashes(source) >= 0
}

// True when this literal token's text is a string literal at all. Patterns
// and annotation arguments ask this instead of testing for a leading quote,
// which stopped being the whole answer when raw literals arrived.
fn string_literal_is_text(source: string) -> bool {
    return source.starts_with("\"") ||
           string_literal_is_raw(source)
}

// First byte of the body.
fn string_literal_body_start(source: string) -> int {
    let hashes: int = string_literal_hashes(source)
    if hashes >= 0 { return hashes + 2 }
    if source.starts_with("\"") { return 1 }
    return 0
}

// One past the last byte of the body. An unterminated literal still reaches
// here — the lexer reports it and keeps the token — so this never returns a
// bound before the body's start.
fn string_literal_body_end(source: string) -> int {
    let hashes: int = string_literal_hashes(source)
    let start: int = string_literal_body_start(source)
    if hashes >= 0 {
        let close: int = source.len() - hashes - 1
        if close < start { return start }
        return close
    }
    if source.len() >= 2 && source.starts_with("\"") &&
       source.ends_with("\"") {
        return source.len() - 1
    }
    if source.len() < start { return start }
    return source.len()
}

fn string_literal_body(source: string) -> string {
    return source.slice(
        string_literal_body_start(source),
        string_literal_body_end(source))
}

// ---- escapes ---------------------------------------------------------------

fn hex_digit_at(source: string, index: int, end: int) -> int {
    if index >= end { return 16 }
    return hex_digit_value(source.byte_at(index))
}

// The digits of a `\u{…}` escape that starts at `index`, or -1 when the
// braces or the digits are not there. The count is bounded at 6 so a runaway
// literal cannot be read as one enormous codepoint.
fn string_escape_unicode_digits(source: string, index: int,
                                end: int) -> int {
    if index + 2 >= end || source.byte_at(index + 2) != 123 {
        return -1
    }
    var digits: int = 0
    var at: int = index + 3
    for at < end && digits <= 6 &&
        hex_digit_at(source, at, end) < 16 {
        digits += 1
        at += 1
    }
    if digits == 0 || digits > 6 { return -1 }
    if at >= end || source.byte_at(at) != 125 { return -1 }
    return digits
}

fn string_escape_unicode_value(source: string, index: int,
                               digits: int) -> int {
    var value: int = 0
    for offset: int in 0..digits {
        value = value * 16 +
                hex_digit_value(
                    source.byte_at(index + 3 + offset))
    }
    return value
}

// A codepoint the language will encode: inside Unicode's range and not one
// half of a surrogate pair, which has no UTF-8 form.
fn string_escape_unicode_valid(value: int) -> bool {
    if value > 1114111 { return false }
    return value < 55296 || value > 57343
}

// How many source bytes the escape starting at `index` occupies. Always at
// least 1, so a walker that trusts this can never fail to advance. A
// malformed escape answers 2 — the lexer already refused it, and the walk
// only has to finish.
fn string_escape_length(source: string, index: int,
                        end: int) -> int {
    if index >= end || source.byte_at(index) != 92 { return 1 }
    if index + 1 >= end { return 1 }
    let marker: int = source.byte_at(index + 1)
    if marker == 120 {
        if hex_digit_at(source, index + 2, end) < 16 &&
           hex_digit_at(source, index + 3, end) < 16 {
            return 4
        }
        return 2
    }
    if marker == 117 {
        let digits: int =
            string_escape_unicode_digits(source, index, end)
        if digits < 0 { return 2 }
        return digits + 4
    }
    return 2
}

fn utf8_encode(codepoint: int) -> string {
    var out: Bytes = new Bytes(0)
    if codepoint < 128 {
        out.push(codepoint & 255)
    } else if codepoint < 2048 {
        out.push((192 | (codepoint >> 6)) & 255)
        out.push((128 | (codepoint & 63)) & 255)
    } else if codepoint < 65536 {
        out.push((224 | (codepoint >> 12)) & 255)
        out.push((128 | ((codepoint >> 6) & 63)) & 255)
        out.push((128 | (codepoint & 63)) & 255)
    } else {
        out.push((240 | (codepoint >> 18)) & 255)
        out.push((128 | ((codepoint >> 12) & 63)) & 255)
        out.push((128 | ((codepoint >> 6) & 63)) & 255)
        out.push((128 | (codepoint & 63)) & 255)
    }
    return out.to_string()
}

// The bytes the escape starting at `index` stands for. `\xNN` is one raw
// byte, whatever it is: Beans strings are binary-safe, `\0` has always been
// spellable, and a program that writes `\xff` means the byte, not a
// replacement character. `\u{…}` is a codepoint, encoded UTF-8.
fn string_escape_text(source: string, index: int,
                      end: int) -> string {
    if index + 1 >= end {
        return source.slice(index, index + 1)
    }
    let marker: int = source.byte_at(index + 1)
    if marker == 110 { return "\n" }
    if marker == 114 { return "\r" }
    if marker == 116 { return "\t" }
    if marker == 48 { return "\0" }
    if marker == 120 {
        if hex_digit_at(source, index + 2, end) < 16 &&
           hex_digit_at(source, index + 3, end) < 16 {
            var out: Bytes = new Bytes(0)
            out.push(
                (hex_digit_value(source.byte_at(index + 2)) * 16 +
                 hex_digit_value(source.byte_at(index + 3))) & 255)
            return out.to_string()
        }
        return source.slice(index + 1, index + 2)
    }
    if marker == 117 {
        let digits: int =
            string_escape_unicode_digits(source, index, end)
        if digits >= 0 {
            let value: int =
                string_escape_unicode_value(
                    source, index, digits)
            if string_escape_unicode_valid(value) {
                return utf8_encode(value)
            }
            return ""
        }
        return source.slice(index + 1, index + 2)
    }
    return source.slice(index + 1, index + 2)
}

// The escape spellings a literal may use. The lexer refuses everything else,
// so `"C:\Users"` names its own mistake instead of quietly becoming
// `C:Users`.
fn string_escape_known(marker: int) -> bool {
    return marker == 110 || marker == 114 || marker == 116 ||
           marker == 48 || marker == 92 || marker == 34 ||
           marker == 123 || marker == 125 ||
           marker == 120 || marker == 117
}

// ---- value -----------------------------------------------------------------

// The bytes a literal stands for. Both backends call this and only this, so
// there is nothing left for them to disagree about.
fn string_literal_decode(source: string) -> string {
    let start: int = string_literal_body_start(source)
    let end: int = string_literal_body_end(source)
    if string_literal_is_raw(source) {
        return source.slice(start, end)
    }
    var out: Bytes = new Bytes(0)
    var index: int = start
    for index < end {
        let byte: int = source.byte_at(index)
        if byte != 92 || index + 1 >= end {
            out.push(byte)
            index += 1
            continue
        }
        out.append_string(
            string_escape_text(source, index, end))
        index += string_escape_length(source, index, end)
    }
    return out.to_string()
}

// The ordinary escaped spelling of some bytes. A raw literal used as a match
// pattern or folded into a constant is rewritten this way at the HIR
// boundary, so everything downstream of the checker reads one spelling and
// the raw form stays a front-end convenience.
fn string_literal_quote(text: string) -> string {
    var out: Bytes = new Bytes(0)
    out.push(34)
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        if byte == 34 || byte == 92 || byte == 123 ||
           byte == 125 {
            out.push(92)
            out.push(byte)
        } else if byte == 10 {
            out.push(92)
            out.push(110)
        } else if byte == 13 {
            out.push(92)
            out.push(114)
        } else if byte == 9 {
            out.push(92)
            out.push(116)
        } else if byte == 0 {
            out.push(92)
            out.push(48)
        } else {
            out.push(byte)
        }
    }
    out.push(34)
    return out.to_string()
}

// A literal in the one spelling everything after the checker reads.
fn string_literal_cook(source: string) -> string {
    if !string_literal_is_raw(source) { return source }
    return string_literal_quote(
        string_literal_decode(source))
}
