// Derived rendering of the shapes the language builds out of other values.
// A map prints as {k: v} in insertion order; a struct and a class instance
// print as Name { field: value } in declaration order; a reference cycle
// prints <cycle>. Every backend must print these bytes for byte.
import std.io

struct Point { x: int; y: int }

struct Mix { flag: bool; ratio: float; tag: u8; note: string }

class Person {
    pub name: string
    priv age: int
    fn init(name: string, age: int) { self.name = name; self.age = age }
}

class Empty { fn init() {} }

class Wrap<T> {
    value: T
    fn init(value: T) { self.value = value }
}

class Node {
    label: string
    next: Option<Node>
    weak owner: Option<Node> = none
    fn init(label: string) { self.label = label; self.next = none }
}

// A class that spells out its own string form: {money} renders through
// to_string, not through the derived Name { ... } form, at every depth.
class Money {
    cents: int
    fn init(cents: int) { self.cents = cents }
    fn to_string() -> string { return "money({self.cents})" }
}

class Wallet {
    holder: string
    balance: Money
    fn init(holder: string, balance: Money) { self.holder = holder; self.balance = balance }
}

// A generic class with its own string form. Its to_string is a template
// until a site raises it for these type arguments, and the show step is
// such a site: the derived form must never stand in for it.
class Cell<T> {
    value: T
    tag: string
    fn init(value: T, tag: string) { self.value = value; self.tag = tag }
    fn to_string() -> string { return "cell({self.tag})" }
}

// join inside a generic function is not refused: List<T> is not yet any one
// type, and its instantiations are checked where they are made.
fn joined<T>(xs: List<T>) -> string { return xs.join(" / ") }

fn main() {
    // A map, in insertion order, wrapped in braces.
    let basic: Map<string, int> = {"a": 1, "b": 2}
    io.println("{basic}")
    let empty_map: Map<string, int> = {}
    io.println("{empty_map}")

    // Nesting through a list value, an option value and a map value.
    let lists: Map<string, List<int>> = {"xs": [1, 2], "ys": []}
    io.println("{lists}")
    let opts: Map<int, Option<string>> = {1: some("hi"), 2: none}
    io.println("{opts}")

    // Insertion order holds across an in-place update: the key keeps the
    // place it was first given, and both backends agree on it.
    var edited: Map<string, int> = {}
    edited["z"] = 1
    edited["a"] = 2
    edited["m"] = 3
    edited["z"] = 9
    io.println("{edited}")

    // A removal is the one case a plain Map does not hold order through —
    // it swap-removes, and the two engines do not agree on what that
    // leaves behind, so nothing here pins it. OrderedMap is the one that
    // keeps its order across a removal, and both backends walk it alike.
    var kept: OrderedMap<string, int> = {}
    kept["p"] = 1
    kept["q"] = 2
    kept["r"] = 3
    kept["s"] = 4
    kept.remove("q")
    kept["q"] = 100
    io.println("{kept}")

    // A key too wide for one runtime slot — a struct, a decimal — is boxed
    // by the map and rendered from the box, not refused.
    var wide_keys: Map<Point, string> = {}
    wide_keys[Point { x: 1, y: 1 }] = "a"
    wide_keys[Point { x: 2, y: 2 }] = "b"
    io.println("{wide_keys}")
    var dec_keys: Map<decimal, string> = {}
    dec_keys[1.5] = "x"
    dec_keys[2.25] = "y"
    io.println("{dec_keys}")

    // A struct and a class instance, fields in declaration order.
    let p: Point = Point { x: 1, y: 2 }
    io.println("{p}")
    let m: Mix = Mix { flag: true, ratio: 1.5, tag: 200, note: "hi" }
    io.println("{m}")

    // A private field is shown; the derived form is the compiler's own view.
    let per: Person = new Person("Ada", 36)
    io.println("{per}")
    // A class with no fields is a name and empty braces.
    let e: Empty = new Empty()
    io.println("{e}")

    // A generic class carries the type it was bound to.
    let bi: Wrap<int> = new Wrap<int>(42)
    io.println("{bi}")
    let bp: Wrap<Point> = new Wrap<Point>(Point { x: 3, y: 4 })
    io.println("{bp}")

    // A class instance nested through every container the issue named:
    // Map<string, List<Option<Point>>>.
    let deep: Map<string, List<Option<Point>>> =
        {"row": [some(Point { x: 9, y: 9 }), none]}
    io.println("{deep}")

    // Class instances inside a list, and rendered by join the same way.
    let people: List<Person> =
        [new Person("Al", 1), new Person("Bo", 2)]
    io.println("{people}")
    io.println(people.join(" | "))

    // A reference cycle stops at <cycle>; a shared child that is not on the
    // path renders in full.
    let a: Node = new Node("a")
    let b: Node = new Node("b")
    a.next = some(b)
    b.next = some(a)
    io.println("{a}")
    let leaf: Node = new Node("leaf")
    let x: Node = new Node("x")
    x.next = some(leaf)
    io.println("{x}")

    // A weak field prints as <weak> without being followed.
    let root: Node = new Node("root")
    let kid: Node = new Node("kid")
    root.next = some(kid)
    kid.owner = some(root)
    io.println("{root}")

    // A result prints as ok(x) / err(e). The default err payload is an Error,
    // which prints as the message a caller passed to err(...); a custom err
    // type prints as itself. Nesting works both ways.
    let ok_int: Result<int> = ok(7)
    io.println("{ok_int}")
    let err_int: Result<int> = err("boom")
    io.println("{err_int}")
    let ok_pt: Result<Point> = ok(Point { x: 5, y: 6 })
    io.println("{ok_pt}")
    let custom: Result<bool, string> = err("nope")
    io.println("{custom}")
    let results: List<Result<int>> = [ok(1), err("x"), ok(3)]
    io.println("{results}")
    let by_key: Map<string, Result<int>> = {"a": ok(1), "b": err("no")}
    io.println("{by_key}")

    // A class's own string form wins over the derived one, and keeps
    // winning when the class is nested in a list, a map or another object.
    let cash: Money = new Money(1250)
    io.println("{cash}")
    let purse: List<Money> = [new Money(1), new Money(2)]
    io.println("{purse}")
    let wallet: Wallet = new Wallet("Ada", new Money(9999))
    io.println("{wallet}")

    let boxed: Cell<int> = new Cell<int>(7, "seven")
    io.println("{boxed}")
    let boxes: List<Cell<int>> =
        [new Cell<int>(1, "one"), new Cell<int>(2, "two")]
    io.println("{boxes}")
    io.println(boxes.join(" + "))
    let by_cell: Map<string, Cell<int>> =
        {"k": new Cell<int>(3, "three")}
    io.println("{by_cell}")

    // join renders what interpolation renders, for a wide element too: a
    // struct does not fit one runtime slot, so it is joined by address.
    let pts: List<Point> =
        [Point { x: 1, y: 2 }, Point { x: 3, y: 4 },
         Point { x: 5, y: 6 }]
    io.println("{pts}")
    io.println(pts.join(" | "))
    let one_pt: List<Point> = [Point { x: 9, y: 9 }]
    io.println(one_pt.join(" | "))
    let no_pt: List<Point> = []
    io.println("[{no_pt.join(" | ")}]")
    let opts_list: List<Option<int>> = [some(1), none, some(3)]
    io.println(opts_list.join(" ~ "))

    io.println(joined<int>([1, 2, 3]))
    io.println(joined<Point>(
        [Point { x: 1, y: 1 }, Point { x: 2, y: 2 }]))

    // Width pads the rendered form of any printable value in columns.
    io.println("|{p:16}|")
    io.println("|{basic:20}|")
}
