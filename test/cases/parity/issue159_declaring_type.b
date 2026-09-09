// Issue #159: `declaring_type()` reported the name a member is filed under,
// which for a generic declaration is the open one. A field or method of
// `main.Grid<int>` said it was declared by `main.Grid` with no type arguments
// at all, so the obvious guard --
//
//     member.declaring_type().type_arguments().len() != 0
//
// -- was false for exactly the members whose types are erased, and a caller
// wanting to detect the condition had to walk the receiver's base chain, strip
// each link's arguments and match them itself.
//
// It now answers with the link the queried type reaches the member through,
// which is the form the source wrote: `main.Grid<int>` for a member of
// `Grid<int>` and for the one an `OrderGrid` inherits, `main.Grid<string>` for
// the same member reached through the other instantiation, and `main.Node` for
// what either of them inherits from a plain base. Every control -- a plain
// class with a plain base, a class with no base at all, an override, the base
// itself -- keeps answering exactly what it did.
//
// Two instantiations run side by side on purpose: one would pass with the
// argument list hard-coded, and one link would pass without walking.
//
// This is in the parity gate because the answer has to be the same on both
// backends -- the interpreter reads HIR declarations and the native runtime
// reads a registry filled at startup, two separate implementations of the same
// walk. Every row carries the answer it must have and the program panics if
// any row misses, so a leg that is wrong fails the run rather than quietly
// agreeing with the other one being wrong the same way. No arc markers: this
// case builds nothing, it only asks descriptors questions.
package main

import std.io
import std.reflect

// Annotation rows are filed under the declaring declaration's name too, and
// `Field.annotations()` / `Method.annotations()` key on `declaring_type()`.
// The native runtime matched an annotation's owner by exact string, so a
// closed generic's own annotations were unreachable -- `type_of(Grid<int>)
// .annotations()` found none at all while the interpreter, which resolves the
// owner to a declaration first, found them -- and once `declaring_type()`
// began answering the closed form its members' annotations went the same way.
// It matches by base name now, like every other row lookup.
@target(value: ["type", "field", "method"])
@retention(value: "runtime")
annotation note { text: string }

@note(text: "on-node")
pub class Node {
    @note(text: "on-label")
    pub label: string = ""
    pub fn init() {}
    pub fn touch() -> string { return "node" }
}

@note(text: "on-grid")
pub class Grid<T> extends Node {
    @note(text: "on-title")
    pub title: string = ""
    pub items: List<T> = []
    pub fn init() { super.init() }
    @note(text: "on-touch")
    pub override fn touch() -> string { return "grid" }
}

// a non-generic subclass of one instantiation, and of the other
pub class OrderGrid extends Grid<int> {
    pub fn init() { super.init() }
}
pub class TextGrid extends Grid<string> {
    pub fn init() { super.init() }
    // an override: the member is declared here, not by the generic base
    pub override fn touch() -> string { return "text" }
}
// two links above the generic base
pub class DeepGrid extends OrderGrid {
    pub fn init() { super.init() }
}

// a generic subclass of a generic base. Its base link is recorded as the
// source wrote it, `main.Grid<T>`, because reflection substitutes nothing --
// the guard still fires, and the descriptor says plainly that it has not
// resolved the argument.
pub class Sub<T> extends Grid<T> {
    pub fn init() { super.init() }
}

// controls: same shape, no type parameter anywhere
@note(text: "on-hint")
pub class Hint extends Node {
    @note(text: "on-hint-title")
    pub title: string = ""
    pub fn init() { super.init() }
    pub override fn touch() -> string { return "hint" }
}
pub class Plain {
    pub title: string = ""
    pub fn init() {}
    pub fn touch() -> string { return "plain" }
}

class Checks {
    bad: int = 0
    fn init() {}
    fn text(label: string, got: string, want: string) {
        io.println("{label} = {got}")
        if got != want {
            io.println("  WRONG: wanted {want}")
            self.bad += 1
        }
    }
    fn count(label: string, got: int, want: int) {
        io.println("{label} = {got}")
        if got != want {
            io.println("  WRONG: wanted {want}")
            self.bad += 1
        }
    }
    fn flag(label: string, got: bool, want: bool) {
        io.println("{label} = {got}")
        if got != want {
            io.println("  WRONG: wanted {want}")
            self.bad += 1
        }
    }
    fn done() {
        if self.bad != 0 {
            panic("{self.bad} reflection answers were wrong")
        }
    }
}

// One field: who declares it, and does the guard the issue names fire?
fn field_row(checks: Checks, subject: reflect.Type,
             name: string, want: string, want_generic: bool) {
    let label: string = "{subject.qualified_name()}.{name}"
    match subject.field(name) {
        some(found) => {
            let declared: reflect.Type = found.declaring_type()
            checks.text("  {label} declared by",
                        declared.qualified_name(), want)
            checks.flag("  {label} declarer is generic",
                        declared.type_arguments().len() != 0,
                        want_generic)
        }
        none => {
            checks.text("  {label} declared by", "<missing>", want)
        }
    }
}

fn method_row(checks: Checks, subject: reflect.Type,
              name: string, want: string, want_generic: bool) {
    let label: string = "{subject.qualified_name()}.{name}()"
    match subject.method(name) {
        some(found) => {
            let declared: reflect.Type = found.declaring_type()
            checks.text("  {label} declared by",
                        declared.qualified_name(), want)
            checks.flag("  {label} declarer is generic",
                        declared.type_arguments().len() != 0,
                        want_generic)
        }
        none => {
            checks.text("  {label} declared by", "<missing>", want)
        }
    }
}

fn main() {
    let checks: Checks = new Checks()

    io.println("-- the closed generic itself, at two argument lists")
    field_row(checks, type_of(Grid<int>), "title", "main.Grid<int>", true)
    field_row(checks, type_of(Grid<int>), "items", "main.Grid<int>", true)
    field_row(checks, type_of(Grid<int>), "label", "main.Node", false)
    method_row(checks, type_of(Grid<int>), "touch", "main.Grid<int>", true)
    field_row(checks, type_of(Grid<string>), "title",
              "main.Grid<string>", true)
    method_row(checks, type_of(Grid<string>), "touch",
               "main.Grid<string>", true)

    io.println("-- inherited by a non-generic subclass of each instantiation")
    field_row(checks, type_of(OrderGrid), "title", "main.Grid<int>", true)
    field_row(checks, type_of(OrderGrid), "items", "main.Grid<int>", true)
    field_row(checks, type_of(OrderGrid), "label", "main.Node", false)
    method_row(checks, type_of(OrderGrid), "touch", "main.Grid<int>", true)
    field_row(checks, type_of(TextGrid), "title", "main.Grid<string>", true)
    // the override belongs to the subclass, generic base or not
    method_row(checks, type_of(TextGrid), "touch", "main.TextGrid", false)

    io.println("-- two links above the generic base")
    field_row(checks, type_of(DeepGrid), "title", "main.Grid<int>", true)
    field_row(checks, type_of(DeepGrid), "label", "main.Node", false)
    method_row(checks, type_of(DeepGrid), "touch", "main.Grid<int>", true)

    io.println("-- a generic base of a generic subclass stays as written")
    field_row(checks, type_of(Sub<int>), "title", "main.Grid<T>", true)
    method_row(checks, type_of(Sub<int>), "touch", "main.Grid<T>", true)

    io.println("-- controls: nothing generic anywhere")
    field_row(checks, type_of(Hint), "title", "main.Hint", false)
    field_row(checks, type_of(Hint), "label", "main.Node", false)
    method_row(checks, type_of(Hint), "touch", "main.Hint", false)
    field_row(checks, type_of(Plain), "title", "main.Plain", false)
    method_row(checks, type_of(Plain), "touch", "main.Plain", false)
    field_row(checks, type_of(Node), "label", "main.Node", false)
    method_row(checks, type_of(Node), "touch", "main.Node", false)

    io.println("-- the base chain each of them reports")
    checks.text("Grid<int> base",
                type_of(Grid<int>).base_type()
                    .expect("base").qualified_name(), "main.Node")
    checks.text("OrderGrid base",
                type_of(OrderGrid).base_type()
                    .expect("base").qualified_name(), "main.Grid<int>")
    checks.text("TextGrid base",
                type_of(TextGrid).base_type()
                    .expect("base").qualified_name(), "main.Grid<string>")
    checks.text("Hint base",
                type_of(Hint).base_type()
                    .expect("base").qualified_name(), "main.Node")
    checks.flag("Plain has a base",
                type_of(Plain).base_type().is_some(), false)

    // A receiver-less operation on a generic declaration names no
    // instantiation, so it is not a reflective target and `initializer()`
    // answers none -- spec/SYNTAX.md, Reflection. The controls next to it are
    // what show that having a type parameter is the whole reason.
    io.println("-- a closed generic has no reflective initializer")
    checks.flag("Grid<int> initializer",
                type_of(Grid<int>).initializer().is_some(), false)
    checks.flag("Grid<string> initializer",
                type_of(Grid<string>).initializer().is_some(), false)
    checks.flag("Sub<int> initializer",
                type_of(Sub<int>).initializer().is_some(), false)
    checks.flag("OrderGrid initializer",
                type_of(OrderGrid).initializer().is_some(), true)
    checks.flag("Hint initializer",
                type_of(Hint).initializer().is_some(), true)
    checks.flag("Plain initializer",
                type_of(Plain).initializer().is_some(), true)

    io.println("-- annotations are filed under the declaration, found by base")
    checks.count("Grid<int> type annotations",
                 type_of(Grid<int>).annotations().len(), 1)
    checks.count("Grid<string> type annotations",
                 type_of(Grid<string>).annotations().len(), 1)
    checks.count("Grid<int>.title annotations",
                 type_of(Grid<int>).field("title")
                     .expect("title").annotations().len(), 1)
    checks.count("Grid<int>.touch annotations",
                 type_of(Grid<int>).method("touch")
                     .expect("touch").annotations().len(), 1)
    checks.count("OrderGrid.title annotations",
                 type_of(OrderGrid).field("title")
                     .expect("title").annotations().len(), 1)
    checks.count("OrderGrid.touch annotations",
                 type_of(OrderGrid).method("touch")
                     .expect("touch").annotations().len(), 1)
    checks.count("DeepGrid.label annotations",
                 type_of(DeepGrid).field("label")
                     .expect("label").annotations().len(), 1)
    // controls: a plain hierarchy answered these all along
    checks.count("Hint type annotations",
                 type_of(Hint).annotations().len(), 1)
    checks.count("Hint.title annotations",
                 type_of(Hint).field("title")
                     .expect("title").annotations().len(), 1)
    checks.count("Node.label annotations",
                 type_of(Node).field("label")
                     .expect("label").annotations().len(), 1)
    checks.count("Plain type annotations",
                 type_of(Plain).annotations().len(), 0)

    checks.done()
    io.println("all rows answered as declared")
}
