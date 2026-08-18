import std.io

class Vault {
    priv value: int

    fn init(value: int) {
        self.value = value
    }

    fn read() -> int {
        return self.value
    }

    static fn read_other(other: Vault) -> int {
        return other.value
    }
}

struct Token {
    priv value: int

    static fn make(value: int) -> Token {
        return Token { value: value }
    }

    fn read() -> int {
        return self.value
    }
}

class ContextualName {
    priv: int = 29

    fn read() -> int {
        return self.priv
    }
}

fn main() {
    let vault: Vault = new Vault(17)
    io.println(vault.read())
    io.println(Vault.read_other(vault))
    let token: Token = Token.make(23)
    io.println("{token.read()}")
    io.println("{new ContextualName().read()}")
}
