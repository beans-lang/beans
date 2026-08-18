class Vault {
    priv secret: int = 7
}

class Peer {
    fn read(vault: Vault) -> int {
        return vault.secret
    }
}

class Child extends Vault {
    fn read() -> int {
        return self.secret
    }
}

struct Token {
    priv value: int
}

fn outside(vault: Vault) -> int {
    return vault.secret
}

fn main() {
    let token: Token = Token { value: 1 }
    let value: int = token.value
}
