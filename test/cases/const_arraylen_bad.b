// An array length is read while types are laid out, before any name has a
// value. The parser cannot know which kind of name it is looking at — the
// module constant it was written for, a local, a type, or a typo — so the
// message has to be true of all four, and every one of them reaches it.
const SIZE: int = 4

class Widget { fn init() {} }

fn main() {
    let count: int = 4
    let sized: [int; SIZE] = [1, 2, 3, 4]
    let local: [int; count] = [1, 2, 3, 4]
    let typed: [int; Widget] = [1, 2, 3, 4]
    let typo: [int; nosuchname] = [1, 2, 3, 4]
}
