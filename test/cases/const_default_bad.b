// A parameter default is read while the signature holding it is lowered,
// which is before constants are folded — the fold runs at the end of that
// stage, which is where an array length reads it (#59). The array length two
// lines down is the control: the same constant, in the position the same
// ordering does reach. The message names the constant rather than leaving
// "must be a constant literal" to be guessed at.
const LIMIT: int = 128

fn helper() -> int { return 1 }

fn sized(row: [int; LIMIT]) -> int { return row[0] }
fn named(n: int = LIMIT) -> int { return n }
fn computed(n: int = helper()) -> int { return n }

fn main() {
    let a: int = named(1)
    let b: int = computed(1)
}
