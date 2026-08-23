import std.async as aio
import std.io

unique class Token {
    pub value: int

    pub fn init(value: int) { self.value = value }
}

async fn make_token(value: int) -> Token {
    return new Token(value)
}

fn print_token(value: Option<Token>) {
    match value {
        some(token) => { io.println("{token.value}") }
        none => { panic("missing token") }
    }
}

async fn main() {
    let group: aio.TaskGroup<Token> = new aio.TaskGroup<Token>()

    group.start(make_token(1))
    print_token(group.try_next())

    group.start(make_token(2))
    print_token(await group.next())

    group.start(make_token(3))
    group.start(make_token(4))
    let tokens: List<Token> = await group.wait_all()
    let first: Token = tokens.remove(0)
    let second: Token = tokens.remove(0)
    io.println("{first.value}")
    io.println("{second.value}")
}
