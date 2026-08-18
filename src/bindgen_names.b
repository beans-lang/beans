package main

class BindgenRecord {
    c_name: string
    beans: string
    is_union: bool
    complete: bool
    node: BindgenJson

    fn init(c_name: string, beans: string,
            is_union: bool, complete: bool,
            node: BindgenJson) {
        self.c_name = c_name
        self.beans = beans
        self.is_union = is_union
        self.complete = complete
        self.node = node
    }
}

fn bindgen_identifier_byte(byte: int) -> bool {
    return (byte >= 48 && byte <= 57) ||
           (byte >= 65 && byte <= 90) ||
           (byte >= 97 && byte <= 122) ||
           byte == 95
}

fn bindgen_strip_qualifier(
    written: string,
    qualifier: string) -> string {
    var type: string = written
    var offset: int = 0
    for offset < type.len() {
        let found: int =
            bindgen_find(
                type.slice(offset, type.len()),
                qualifier)
        if found < 0 { break }
        let start: int = offset + found
        var after: int = start + qualifier.len()
        let joined: bool =
            (start > 0 &&
             bindgen_identifier_byte(
                 type.byte_at(start - 1))) ||
            (after < type.len() &&
             bindgen_identifier_byte(
                 type.byte_at(after)))
        if joined {
            offset = after
            continue
        }
        var begin: int = start
        if begin > 0 &&
           type.byte_at(begin - 1) == 32 {
            begin -= 1
        } else if after < type.len() &&
                  type.byte_at(after) == 32 {
            after += 1
        }
        type =
            "{type.slice(0, begin)}{type.slice(after, type.len())}"
        offset = begin
    }
    return move type
}

// Clang writes its nullability qualifiers into the type strings we parse, as in
// `ImpellerTexture  _Nonnull * _Nullable`. They say nothing about layout, so
// they are dropped before anything reads the type. They are matched as whole
// tokens: a header is free to name something `my_Nonnull_table`.
fn bindgen_strip_nullability(
    written: string) -> string {
    var type: string =
        bindgen_strip_qualifier(
            written, "_Nullable")
    type =
        bindgen_strip_qualifier(type, "_Nonnull")
    return bindgen_strip_qualifier(
        type, "_Null_unspecified")
}

// One pointer level around an already-rendered type. Nested pointers close with
// `> >`: the lexer reads `>>` as a shift and the parsers only recover it by
// splitting the token, which the generated file should not lean on.
fn bindgen_pointer_to(inner: string) -> string {
    if inner.ends_with(">") {
        return "RawPtr<{inner} >"
    }
    return "RawPtr<{inner}>"
}

fn bindgen_function_pointer_to(inner: string) -> string {
    if inner.ends_with(">") {
        return "CFunctionPtr<{inner} >"
    }
    return "CFunctionPtr<{inner}>"
}

fn bindgen_owned_tag_id(node: BindgenJson) -> string {
    match node.get("ownedTagDecl") {
        some(tag) => {
            let id: string = tag.string("id")
            if id != "" { return id }
        }
        none => {}
    }
    match node.get("inner") {
        some(inner) => {
            for child: BindgenJson in inner.items {
                let found: string =
                    bindgen_owned_tag_id(child)
                if found != "" { return found }
            }
        }
        none => {}
    }
    return ""
}

fn bindgen_collect_type_nodes(
    node: BindgenJson,
    inout output: List<BindgenJson>) {
    let kind: string = node.string("kind")
    if kind == "RecordDecl" ||
       kind == "EnumDecl" ||
       kind == "TypedefDecl" {
        output.push(node)
    }
    match node.get("inner") {
        some(inner) => {
            for child: BindgenJson in inner.items {
                bindgen_collect_type_nodes(
                    child, inout output)
            }
        }
        none => {}
    }
}

fn bindgen_contains_identifier(
    text: string, wanted: string) -> bool {
    if wanted == "" || wanted.len() > text.len() {
        return false
    }
    for index: int in
        0..(text.len() - wanted.len() + 1) {
        if text.slice(index, index + wanted.len()) !=
           wanted {
            continue
        }
        let left_ok: bool =
            index == 0 ||
            !bindgen_identifier_byte(
                text.byte_at(index - 1))
        let right: int = index + wanted.len()
        let right_ok: bool =
            right == text.len() ||
            !bindgen_identifier_byte(
                text.byte_at(right))
        if left_ok && right_ok { return true }
    }
    return false
}

fn bindgen_name(value: string,
                is_type: bool) -> string {
    var result: string = ""
    var upper: bool = is_type
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        let alphanumeric: bool =
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122)
        if !alphanumeric {
            upper = is_type
            if !is_type && result != "" &&
               !result.ends_with("_") {
                result = "{result}_"
            }
            continue
        }
        let character: string =
            value.slice(index, index + 1)
        if is_type {
            let added: string =
                if upper {
                    character.to_upper()
                } else {
                    character
                }
            result = "{result}{added}"
            upper = false
        } else {
            result =
                "{result}{character.to_lower()}"
        }
    }
    if result == "" {
        result =
            if is_type { "Anonymous" } else { "value" }
    }
    if result.byte_at(0) >= 48 &&
       result.byte_at(0) <= 57 {
        result =
            if is_type {
                "T{result}"
            } else {
                "_{result}"
            }
    }
    let reserved: List<string> = [
        "as", "break", "case", "class", "continue",
        "defer", "else", "enum", "extern", "false",
        "fn", "for", "if", "import", "in", "inout",
        "interface", "let", "match", "move", "new",
        "none", "override", "pub", "return", "self",
        "static", "struct", "take", "true", "unsafe",
        "var", "while"]
    if !is_type && reserved.contains(result) {
        result = "{result}_"
    }
    return result
}

fn bindgen_type_text(node: BindgenJson) -> string {
    match node.get("type") {
        some(type) => {
            let desugared: string =
                type.string("desugaredQualType")
            if node.string("kind") == "TypedefDecl" &&
               desugared == node.string("name") {
                return type.string("qualType")
            }
            if desugared != "" { return desugared }
            return type.string("qualType")
        }
        none => { return "" }
    }
}

// Clang names files that are not really files, such as the `<scratch space>`
// it invents for tokens a macro pasted together. Those never own a header.
fn bindgen_real_file(name: string) -> bool {
    return name != "" && !name.starts_with("<")
}

// The header a declaration belongs to, or "" when Clang left the location out
// because it repeats the one before it.
//
// A declaration written out by hand carries `loc.file`. One created by a macro
// carries a spelling location — where the tokens were written, which for a
// pasted name is `<scratch space>` — and an expansion location, which is where
// the macro was used. The expansion location is the one that says which header
// the declaration belongs to.
fn bindgen_declaration_file(
    node: BindgenJson) -> string {
    match node.get("loc") {
        some(location) => {
            let direct: string =
                location.string("file")
            if direct != "" { return direct }
            match location.get("expansionLoc") {
                some(expansion) => {
                    let file: string =
                        expansion.string("file")
                    if bindgen_real_file(file) {
                        return file
                    }
                }
                none => {}
            }
            match location.get("spellingLoc") {
                some(spelling) => {
                    let file: string =
                        spelling.string("file")
                    if bindgen_real_file(file) {
                        return file
                    }
                }
                none => {}
            }
            return ""
        }
        none => { return "" }
    }
}

fn bindgen_requested_file(
    file: string, headers: List<string>) -> bool {
    for header: string in headers {
        if file == header || file.ends_with(header) {
            return true
        }
    }
    return false
}
