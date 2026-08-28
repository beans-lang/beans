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

    // Insertion order holds across an in-place update and a
    // delete-then-reinsert.
    var edited: Map<string, int> = {}
    edited["z"] = 1
    edited["a"] = 2
    edited["z"] = 9
    io.println("{edited}")
    edited.remove("z")
    edited["z"] = 100
    io.println("{edited}")

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

    // Width pads the rendered form of any printable value in columns.
    io.println("|{p:16}|")
    io.println("|{basic:20}|")
}
