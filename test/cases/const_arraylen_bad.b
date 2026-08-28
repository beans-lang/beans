// A const is folded after types are laid out, so it cannot size a fixed
// array; the parser says so at the constant instead of cascading.
const SIZE: int = 4

fn main() {
    let buffer: [int; SIZE] = [1, 2, 3, 4]
}
