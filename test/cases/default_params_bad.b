fn bad_order(a: int = 1, b: int) -> int { return a + b }
fn bad_const(a: int, b: int = a + 1) -> int { return a + b }
fn bad_move(move a: List<int> = 1) {}
extern "C" fn bad_extern(a: int = 2) -> int
fn needs(a: int, b: int = 2) -> int { return a + b }

fn main() {
    let underflow: int = needs()
    let overflow: int = needs(1, 2, 3)
}
