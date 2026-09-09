// A reflection box reports the type a value IS, not the type of the binding
// it was handed. That is what lets a program hold its children at a common
// base and still get one back as its own type — the thing a framework wants
// reflection for.
import std.io
import std.reflect

interface Paints {
    fn paint() -> string
}

class Node {
    pub name: string

    fn init(name: string) { self.name = name }

    pub fn kind() -> string { return "node" }
}

class Panel extends Node {
    fn init(name: string) { super.init(name) }

    pub override fn kind() -> string { return "panel" }
}

class Button extends Panel implements Paints {
    pub caption: string

    fn init(name: string, caption: string) {
        self.caption = caption
        super.init(name)
    }

    pub override fn kind() -> string { return "button" }

    pub fn paint() -> string { return "[{self.caption}]" }
}

// A generic class is one runtime class per instantiation, so a box of one
// carries the arguments and never comes back as the open name.
class Slot<T> {
    pub label: string
    pub value: T

    fn init(label: string, value: T) {
        self.label = label
        self.value = value
    }
}

// Children held at the base, each recovered as what it really is.
class Tree {
    pub root: Node

    pub fn init(root: Node) { self.root = root }

    pub fn top() -> Node { return self.root }
}

fn show(value: reflect.Value) -> string {
    return value.type().qualified_name()
}

fn main() {
    let button: Button = new Button("save", "Save")
    let as_panel: Panel = button
    let as_node: Node = button
    let as_paints: Paints = button

    io.println("one object, four bindings:")
    io.println("  Button:   {show(reflect.value(button))}")
    io.println("  Panel:    {show(reflect.value(as_panel))}")
    io.println("  Node:     {show(reflect.value(as_node))}")
    io.println("  Paints:   {show(reflect.value(as_paints))}")

    // held at the base, recovered as the leaf
    let boxed: reflect.Value = reflect.value(as_node)
    match boxed as? Button {
        some(recovered) => {
            io.println("recovered a {recovered.kind()}: {recovered.paint()}")
        }
        none => { io.println("lost the button") }
    }

    // a base instance is still the base, and does not become a leaf
    let panel: Panel = new Panel("body")
    let boxed_panel: reflect.Value = reflect.value(panel as Node)
    io.println("a plain panel boxes as {show(boxed_panel)}")
    io.println("  as? Button: {(boxed_panel as? Button).is_some()}")
    io.println("  as? Panel:  {(boxed_panel as? Panel).is_some()}")

    // a field read and a call result report what they carry
    let tree: Tree = new Tree(as_node)
    let boxed_tree: reflect.Value = reflect.value(tree)
    let root: reflect.Field = type_of(Tree).field("root").expect("root")
    io.println("field root:   {show(root.get(boxed_tree).expect("read root"))}")
    let top: reflect.Method = type_of(Tree).method("top").expect("top")
    io.println("method top:   {show(top.call(boxed_tree, []).expect("call top"))}")

    // a receiver boxed at the base runs the body its own class declares
    let kind: reflect.Method = type_of(Node).method("kind").expect("kind")
    let answered: reflect.Value = kind.call(boxed, []).expect("call kind")
    io.println("kind via Node: {(answered as? string).expect("string")}")

    // closed generics keep their arguments
    let counts: Slot<int> = new Slot<int>("counts", 3)
    let names: Slot<string> = new Slot<string>("names", "three")
    io.println("Slot<int>:    {show(reflect.value(counts))}")
    io.println("Slot<string>: {show(reflect.value(names))}")

    // and a value that is already its own type is unchanged
    io.println("int:          {show(reflect.value(7))}")
    io.println("string:       {show(reflect.value("seven"))}")
}
