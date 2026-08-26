package main

struct Token {
    kind: string
    text: string
    line: int
    col: int
}

fn keyword_kind(text: string) -> string {
    if text == "class" || text == "struct" || text == "union" ||
       text == "interface" || text == "enum" || text == "fn" ||
       text == "let" || text == "var" || text == "pub" ||
       text == "override" || text == "if" || text == "else" ||
       text == "for" || text == "in" || text == "match" ||
       text == "return" || text == "break" || text == "continue" ||
       text == "import" || text == "as" || text == "defer" ||
       text == "unsafe" || text == "extern" || text == "new" ||
       text == "extends" || text == "implements" || text == "static" ||
       text == "move" || text == "take" || text == "inout" ||
       text == "self" || text == "true" || text == "false" {
        return text
    }
    return "ident"
}

// A bare `while` followed by the start of another expression can only be the
// loop keyword other languages have: two expressions never sit side by side in
// one statement, so a valid program cannot reach this. `while(` is deliberately
// left out — `while` is an ordinary identifier in Beans, and that one is a call.
fn starts_loop_condition(kind: string) -> bool {
    return kind == "ident" || kind == "int" || kind == "float" ||
           kind == "string" || kind == "true" || kind == "false" ||
           kind == "self" || kind == "!"
}

fn ends_statement(kind: string) -> bool {
    return kind == "ident" || kind == "int" || kind == "float" ||
           kind == "string" || kind == "return" || kind == "break" ||
           kind == "continue" || kind == "self" || kind == "true" ||
           kind == "false" || kind == ")" || kind == "]" ||
           kind == "}" || kind == "?" || kind == ">" || kind == ">>"
}
