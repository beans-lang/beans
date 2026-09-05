// An array length is an integer literal or a module constant, and nothing
// else can be one: a length is read while types are laid out, which is after
// constants are folded and before any function runs. Every name that is not
// a constant, and every constant that cannot supply a length, reaches this
// file — and each is told which of those it is, once, at the name.
const SIZE: int = 4
const ZERO: int = 0
const HUGE: int = 5000
const TEXT: string = "hi"
const FLAG: bool = true
const REAL: float = 2.5
const CALLED: int = helper()
const SELFREF: int = SELFREF

class Widget { fn init() {} }

// A type parameter is in scope where a length is written and stands for a
// type, which is the shape someone reaching for a const generic writes.
class Slots<N> {
    cells: [int; N]
    fn init() { self.cells = [1] }
}

fn helper() -> int { return 4 }

// A length in a signature reads the same constants a body does, and is
// refused for the same reasons.
fn parameter(a: [int; TEXT]) -> int { return a[0] }
fn result() -> [int; ZERO] { return [1] }

struct Field { cells: [int; HUGE] }

fn main() {
    let count: int = 4
    let sized: [int; SIZE] = [1, 2, 3, 4]
    let local: [int; count] = [1, 2, 3, 4]
    let typed: [int; Widget] = [1, 2, 3, 4]
    let typo: [int; nosuchname] = [1, 2, 3, 4]
    let called: [int; CALLED] = [1, 2, 3, 4]
    let cyclic: [int; SELFREF] = [1, 2, 3, 4]
    let zero: [int; ZERO] = [1, 2, 3, 4]
    let huge: [int; HUGE] = [1, 2, 3, 4]
    let text: [int; TEXT] = [1, 2, 3, 4]
    let flag: [int; FLAG] = [1, 2, 3, 4]
    let real: [int; REAL] = [1, 2, 3, 4]
    let missing: [int; helper] = [1, 2, 3, 4]
}
