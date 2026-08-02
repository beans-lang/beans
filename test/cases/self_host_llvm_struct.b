import std.io

struct Span {
    line: int
    col: int
}

struct TokenLike {
    kind: string
    text: string
    span: Span
}

fn describe(value: TokenLike) -> string {
    return "{value.kind}:{value.text}@{value.span.line}:{value.span.col}"
}

fn identity(value: TokenLike) -> TokenLike {
    return value
}

fn main() {
    let token: TokenLike = TokenLike {
        kind: "ident",
        text: "beans",
        span: Span {
            line: 7,
            col: 11,
        },
    }
    let copied: TokenLike = token
    io.println(describe(copied))
    io.println("{token.kind} {token.span.line}")
    var changed: TokenLike = identity(token)
    changed = TokenLike {
        kind: "keyword",
        text: "class",
        span: Span {
            line: 9,
            col: 2,
        },
    }
    io.println(describe(changed))
}
