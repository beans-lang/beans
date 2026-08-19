package main

// The LLVM named type for a record. A canonical name carries the package's
// whole import path, so it goes through symbol_text: '/' and ':' are not
// legal in an LLVM identifier, and two same-named records in different
// packages must not collapse onto one type.
fn llvm_record_name(qualified: string) -> string {
    return "%bs.{symbol_text(qualified)}"
}

fn llvm_record_instance_name(type: HirType) -> string {
    if type.args.len() == 0 {
        return llvm_record_name(type.name)
    }
    return llvm_record_name(render_hir_type(type))
}

fn llvm_unquote(source: string) -> string {
    var start: int = 0
    var end: int = source.len()
    if source.len() >= 2 &&
       source.starts_with("\"") &&
       source.ends_with("\"") {
        start = 1
        end -= 1
    }
    var result: string = ""
    var index: int = start
    for index < end {
        let byte: int = source.byte_at(index)
        if byte != 92 || index + 1 >= end {
            result =
                "{result}{source.slice(index, index + 1)}"
            index += 1
            continue
        }
        let escaped: int = source.byte_at(index + 1)
        if escaped == 110 {
            result = "{result}\n"
        } else if escaped == 114 {
            result = "{result}\r"
        } else if escaped == 116 {
            result = "{result}\t"
        } else if escaped == 48 {
            result = "{result}\0"
        } else {
            result =
                "{result}{source.slice(index + 1, index + 2)}"
        }
        index += 2
    }
    return result
}

fn llvm_hex_digit(value: int) -> string {
    let digits: string = "0123456789ABCDEF"
    return digits.slice(value, value + 1)
}

fn llvm_escape_bytes(value: string) -> string {
    var result: string = ""
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte >= 32 && byte <= 126 &&
           byte != 34 && byte != 92 {
            result =
                "{result}{value.slice(index, index + 1)}"
        } else {
            result =
                "{result}\\{llvm_hex_digit(byte / 16)}{llvm_hex_digit(byte % 16)}"
        }
    }
    return result
}

// ---- reading the emitted text back, for the chunked backend ----
//
// Splitting the module across several clang processes needs three facts about
// a body the emitter has already written: whether it defines a function,
// under what symbol, and what a declaration of it looks like. Reading them
// back off the text is deliberate — the alternative is a second printer that
// has to agree with the first one forever, and the two spellings drift.

// End of the line starting at `start`, not counting its newline.
fn llvm_line_end(text: string, start: int) -> int {
    var end: int = start
    for end < text.len() && text.byte_at(end) != 10 {
        end += 1
    }
    return end
}

// Offset of the body's opening line, which must start with `prefix`. Only a
// comment or a blank line may come before it, so a body that opens with
// something else answers -1 rather than being searched to the end.
fn llvm_body_line(body: string, prefix: string) -> int {
    var start: int = 0
    for start < body.len() {
        let end: int = llvm_line_end(body, start)
        if body.slice(start, end).starts_with(prefix) {
            return start
        }
        let byte: int = body.byte_at(start)
        if byte != 59 && byte != 10 { return -1 }
        start = end + 1
    }
    return -1
}

// How many bytes of `private ` or `internal ` sit at `at`, which is where a
// definition's linkage keyword would be. Zero means external linkage, which
// is what a chunk can already reach.
fn llvm_local_linkage_width(text: string,
                            at: int,
                            end: int) -> int {
    if at + 8 <= end &&
       text.slice(at, at + 8) == "private " {
        return 8
    }
    if at + 9 <= end &&
       text.slice(at, at + 9) == "internal " {
        return 9
    }
    return 0
}

// A linkage a chunked build must not touch, because dropping it would change
// what the linker does with the symbol rather than just who can see it. Such
// a definition is repeated in every chunk instead.
fn llvm_define_is_opaque(body: string, offset: int) -> bool {
    let end: int = llvm_line_end(body, offset)
    var stop: int = offset + 30
    if stop > end { stop = end }
    let head: string = body.slice(offset + 7, stop)
    return head.starts_with("linkonce") ||
           head.starts_with("weak") ||
           head.starts_with("appending ") ||
           head.starts_with("common ") ||
           head.starts_with("available_externally ")
}

// The same definition with `private` or `internal` dropped, so the chunk
// beside it can call what it defines. One definition still, in one chunk, so
// the symbol keeps one address.
fn llvm_shared_define(body: string,
                      offset: int,
                      width: int) -> string {
    if width == 0 { return body }
    return "{body.slice(0, offset + 7)}{body.slice(offset + 7 + width, body.len())}"
}

// The symbol a definition line defines.
fn llvm_define_symbol(body: string, offset: int) -> string {
    let end: int = llvm_line_end(body, offset)
    var at: int = offset
    for at < end && body.byte_at(at) != 64 { at += 1 }
    var stop: int = at
    for stop < end && body.byte_at(stop) != 40 { stop += 1 }
    return body.slice(at, stop)
}

// A declaration of the same function: the definition's own header line with
// `define` swapped for `declare`, any local linkage dropped, and the opening
// brace removed. Parameter names are left in place, which LLVM accepts on a
// declaration, so the two spellings can never disagree about a type. An empty
// answer means the line was not the shape this expects, and the caller keeps
// the body whole rather than declaring something it guessed at.
fn llvm_declaration_for(body: string,
                        offset: int,
                        width: int) -> string {
    let end: int = llvm_line_end(body, offset)
    if end <= offset || body.byte_at(end - 1) != 123 {
        return ""
    }
    var cut: int = end - 1
    for cut > offset && body.byte_at(cut - 1) == 32 {
        cut -= 1
    }
    if cut <= offset + 7 + width { return "" }
    return "declare {body.slice(offset + 7 + width, cut)}\n"
}

// Which chunk owns a group — a source file, or a lone symbol when the body
// came from no file. Hashing the name rather than counting positions is what
// makes the object cache worth having: a group keeps the chunk it had no
// matter what was added or deleted around it, so an edit rebuilds one chunk.
fn llvm_symbol_chunk(group: string, count: int) -> int {
    var hash: int = 2166136261
    for index: int in 0..group.len() {
        hash =
            (hash * 16777619 + group.byte_at(index)) %
            2147483629
    }
    return hash % count
}

// True when the line at `start` opens a function definition. The byte test
// comes first so the common line never pays for a substring.
fn llvm_line_defines(text: string,
                     start: int,
                     end: int) -> bool {
    if text.byte_at(start) != 100 { return false }
    if start + 7 > end { return false }
    let head: string = text.slice(start, start + 7)
    return head == "define "
}

// Index just past the ` = ` that opens a global's initializer, or -1.
fn llvm_assignment_at(text: string,
                      start: int,
                      end: int) -> int {
    var at: int = start
    for at + 3 <= end {
        if text.byte_at(at) == 32 &&
           text.byte_at(at + 1) == 61 &&
           text.byte_at(at + 2) == 32 {
            return at + 3
        }
        at += 1
    }
    return -1
}

// The definitions one chunk owns, with `private` and `internal` dropped.
//
// A chunked build defines every global exactly once, in the chunk that owns
// them, so a string literal still has one address across the whole program.
// But a `private` symbol is invisible to the object file next to it, and
// every other chunk has to reach these, so the owning chunk publishes them
// under external linkage. Function definitions can ride in here too — a
// singleton's accessor arrives welded to the storage it caches into — and
// they are published the same way.
fn llvm_shared_globals(text: string) -> string {
    var output: List<string> = []
    var start: int = 0
    for start < text.len() {
        var end: int = llvm_line_end(text, start)
        if end < text.len() { end += 1 }
        var mark: int = -1
        if text.byte_at(start) == 64 {
            mark = llvm_assignment_at(text, start, end)
        } else if llvm_line_defines(text, start, end) {
            mark = start + 7
        }
        if mark < 0 {
            output.push(text.slice(start, end))
            start = end
            continue
        }
        let width: int =
            llvm_local_linkage_width(text, mark, end)
        if width == 0 {
            output.push(text.slice(start, end))
            start = end
            continue
        }
        output.push(
            "{text.slice(start, mark)}{text.slice(mark + width, end)}")
        start = end
    }
    return output.join("")
}

// A declaration of everything those definitions publish, for the chunks that
// only reach them. A global is declared as `i8`: nothing but the symbol's
// address crosses a chunk boundary, the definition's own type is what lays
// out the bytes, and a linker resolves names rather than types. A function
// keeps its signature, which is what a call site needs.
fn llvm_global_externs(text: string) -> string {
    var output: List<string> = []
    var start: int = 0
    for start < text.len() {
        let end: int = llvm_line_end(text, start)
        if text.byte_at(start) == 64 {
            let mark: int =
                llvm_assignment_at(text, start, end)
            if mark >= 0 {
                output.push(
                    "{text.slice(start, mark - 3)} = external global i8\n")
            }
        } else if llvm_line_defines(text, start, end) {
            output.push(
                llvm_declaration_for(text, start, 0))
        }
        start = end + 1
    }
    return output.join("")
}
