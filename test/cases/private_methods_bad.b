class Vault {
    priv fn init() {}

    priv fn hidden() -> int {
        return 1
    }

    priv static fn hidden_static() -> int {
        return 2
    }

    static fn make() -> Vault {
        return new Vault()
    }
}

class Peer {
    fn read(vault: Vault) -> int {
        return vault.hidden()
    }

    static fn read_static() -> int {
        return Vault.hidden_static()
    }
}

class Child extends Vault {
    fn read_parent() -> int {
        return super.hidden()
    }
}

struct Token {
    priv value: int

    priv fn read() -> int {
        return self.value
    }

    priv inout fn bump() {
        self.value += 1
    }

    priv static fn seed() -> int {
        return 7
    }

    static fn make() -> Token {
        return Token { value: Token.seed() }
    }
}

fn use_token() {
    var token: Token = Token.make()
    let value: int = token.read()
    token.bump()
    let seed: int = Token.seed()
}

fn main() {
    let vault: Vault = new Vault()
}
