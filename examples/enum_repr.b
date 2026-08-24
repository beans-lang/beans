// enum(u8): a payload-free enum can opt into a fixed one-byte layout.
// The value is the bare tag — no pointer, no ARC — so structs holding one
// keep a fixed inline layout and size_of answers.
import std.io

enum(u8) Display { flex, grid, none_ }

enum(u8) Corner {
    top_left
    top_right
    bottom_left
    bottom_right

    fn label() -> string {
        match self {
            top_left => { return "TL" }
            top_right => { return "TR" }
            bottom_left => { return "BL" }
            bottom_right => { return "BR" }
        }
    }
}

// a plain enum can carry an enum(u8) as a payload
enum Wrapped { of(d: Display), nothing }

struct Style {
    display: Display
    gap: int
}

struct Pair {
    a: Display
    b: Display
}

fn pick(d: Display) -> Display {
    match d {
        flex => { return Display.grid }
        _ => { return d }
    }
}

fn main() {
    // the layout is committed: one byte, byte-aligned
    io.println("Display {size_of(Display)}/{align_of(Display)}")
    io.println("Style inline@{offset_of(Style, display)} grows {size_of(Style) > size_of(int)}")
    io.println("Pair {size_of(Pair)} b@{offset_of(Pair, b)} array {size_of([Display; 4])}")

    // fixed arrays store one byte per element
    let cells: [Display; 4] = [
        Display.flex, Display.grid,
        Display.none_, Display.grid,
    ]
    var grids: int = 0
    for cell: Display in cells {
        if cell == Display.grid { grids += 1 }
    }
    io.println("array grids = {grids}")

    // lists, contains, index_of
    var stack: List<Display> = [Display.none_, Display.flex]
    stack.push(Display.grid)
    io.println("list = {stack}")
    io.println("contains flex = {stack.contains(Display.flex)}, grid at = {stack.index_of(Display.grid)}")

    // map keys and map values
    var counts: Map<Display, int> = {}
    counts[Display.flex] = 1
    counts[Display.grid] = 2
    counts[Display.none_] = 3
    io.println("counts {counts[Display.flex]} {counts[Display.grid]} {counts[Display.none_]} len {counts.len()}")
    var reverse: Map<int, Display> = {}
    reverse[7] = Display.grid
    io.println("reverse[7] = {reverse[7]}")

    // struct embedding, equality, show
    let one: Style = Style { display: Display.flex, gap: 8 }
    let two: Pair = Pair { a: Display.grid, b: Display.grid }
    io.println("style {one.display}/{one.gap} pair {two.a}+{two.b} eq {two.a == two.b}")

    // Option, match, methods, closures
    var maybe: Option<Display> = some(Display.none_)
    match maybe {
        some(d) => { io.println("some {d}") }
        none => { io.println("none") }
    }
    io.println("corners {Corner.bottom_left.label()} {Corner.top_right.label()}")
    io.println("picked {pick(Display.flex)} {pick(Display.none_)}")
    let wanted: Display = Display.grid
    let matches: fn(Display) -> bool = fn(d: Display) -> bool {
        return d == wanted
    }
    io.println("closure {matches(Display.grid)} {matches(Display.flex)}")

    // as a payload of a boxed enum
    let boxed: Wrapped = Wrapped.of(Display.none_)
    match boxed {
        of(d) => { io.println("wrapped {d}") }
        nothing => { io.println("wrapped nothing") }
    }
    io.println("shown = {boxed} bare = {Display.flex} {Display.grid} {Display.none_}")
}
