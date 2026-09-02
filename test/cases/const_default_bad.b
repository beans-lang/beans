// A parameter default is read while signatures are checked, which happens
// before any constant is folded — the same ordering that stops a const from
// sizing an array (issue #59). The message names the constant rather than
// leaving "must be a constant literal" to be guessed at.
const LIMIT: int = 128

fn helper() -> int { return 1 }

fn named(n: int = LIMIT) -> int { return n }
fn computed(n: int = helper()) -> int { return n }

fn main() {
    let a: int = named(1)
    let b: int = computed(1)
}
