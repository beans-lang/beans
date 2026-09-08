// A type name written inside a string's `{}` piece means what the same
// name means one character outside it (#164).
//
// The bug this pins was invisible from one package: the piece was bound by
// composing `<the asking package>.<simple name>`, which is the right answer
// exactly when the type is declared in the asking package. So the fixture
// asks from two packages that would compose two different wrong names, for
// types that live in a third, reached only through `import {…} from`.
package main
import std.io
import std.reflect
import std.fmt
import {Widget, Fancy, Point, SIZE, Tone, Shop, make, fancy, takes,
        transform, wrap, count, row} from interp164.kit
import {ask} from interp164.probe

pub class Local {
    pub fn init() {}
    pub fn label() -> string { return "local" }
    // `Self` is a type name a piece can write, and the checker answers it
    // by handing the enclosing owner to the resolver rather than filling
    // it in itself.
    pub fn self_inside() -> string {
        return "{type_of(Self).qualified_name()}"
    }
    pub fn self_outside() -> string {
        return type_of(Self).qualified_name()
    }
    pub fn self_new() -> string { return "{new Self().label()}" }
}

pub class LocalChild extends Local {
    pub fn init() { super.init() }
    pub override fn label() -> string { return "localchild" }
}

// The enclosing type parameters are the third thing the checker hands the
// resolver. Nothing in the cross-package battery reaches them, because a
// type parameter is not qualified by a package and so cannot be composed
// into a wrong name — which is exactly why it needs pinning here.
pub class Crate<T> {
    item: T
    pub fn init(item: T) { self.item = item }
    pub fn inside() -> string { return "{type_of(T).qualified_name()}" }
    pub fn outside() -> string { return type_of(T).qualified_name() }
}

fn enclosing_fn_parameter<U>(value: U) -> string {
    return row("main enclosing fn type parameter",
               "{type_of(U).qualified_name()}",
               type_of(U).qualified_name())
}

fn described(text: string = "default={new Widget().label()}") -> string {
    return text
}

fn main() {
    let w: Widget = make()
    let f: Fancy = fancy()

    // control: a type declared in this very file always resolved
    let local_outside: reflect.Type = type_of(Local)
    let child_outside: reflect.Type = type_of(LocalChild)
    io.println(
        row("main control local",
            "{type_of(Local).qualified_name()}",
            local_outside.qualified_name()))
    io.println(
        row("main control assignable",
            "{type_of(Local).is_assignable_from(type_of(LocalChild))}",
            "{local_outside.is_assignable_from(child_outside)}"))

    let widget_outside: reflect.Type = type_of(Widget)
    let fancy_outside: reflect.Type = type_of(Fancy)
    io.println(
        row("main type_of",
            "{type_of(Widget).qualified_name()}",
            widget_outside.qualified_name()))
    io.println(
        row("main type_of subclass",
            "{type_of(Fancy).qualified_name()}",
            fancy_outside.qualified_name()))
    io.println(
        row("main assignable",
            "{type_of(Widget).is_assignable_from(type_of(Fancy))}",
            "{widget_outside.is_assignable_from(fancy_outside)}"))
    // docs/REFLECTION.md: find_type takes the full package name back, so
    // the name type_of answers with has to be one find_type can find.
    io.println(
        row("main roundtrip",
            "{reflect.find_type(type_of(Widget).qualified_name()).is_some()}",
            "{reflect.find_type(widget_outside.qualified_name()).is_some()}"))
    io.println(
        row("main reflection still answers",
            "{type_of(Widget).initializer().is_some()}",
            "{widget_outside.initializer().is_some()}"))

    let new_outside: Widget = new Widget()
    io.println(
        row("main new", "{new Widget().label()}",
            new_outside.label()))

    let up: Widget = f
    let cast_outside: Widget = f as Widget
    io.println(
        row("main as", "{(f as Widget).label()}",
            cast_outside.label()))
    let down_outside: Option<Fancy> = up as? Fancy
    io.println(
        row("main as?", "{(up as? Fancy).is_some()}",
            "{down_outside.is_some()}"))

    let targ_outside: int = count<Widget>(w)
    io.println(
        row("main type argument", "{count<Widget>(w)}",
            "{targ_outside}"))

    let param_outside: int =
        takes(fn(x: Widget) -> int { return 1 }, w)
    io.println(
        row("main closure parameter",
            "{takes(fn(x: Widget) -> int { return 1 }, w)}",
            "{param_outside}"))

    let result_outside: Widget =
        (fn() -> Widget { return make() })()
    io.println(
        row("main closure result",
            "{(fn() -> Widget { return make() })().label()}",
            result_outside.label()))

    let annotation_outside: int =
        (fn() -> int { let q: Widget = make() ; return q.label().len() })()
    io.println(
        row("main local annotation",
            "{(fn() -> int { let q: Widget = make() ; return q.label().len() })()}",
            "{annotation_outside}"))

    let nested_outside: int =
        (fn(xs: List<Widget>) -> int { return xs.len() })([make(), make()])
    io.println(
        row("main nested type argument",
            "{(fn(xs: List<Widget>) -> int { return xs.len() })([make(), make()])}",
            "{nested_outside}"))

    let pattern_outside: string =
        match some(make()) {
            some(q: Widget) => q.label(),
            none => "none",
        }
    io.println(
        row("main pattern binding",
            "{match some(make()) { some(q: Widget) => q.label(), none => "none" }}",
            pattern_outside))

    let fn_type_outside: int =
        wrap(fn(h: fn(Widget) -> int) -> int { return h(make()) })
    io.println(
        row("main fn type parameter",
            "{wrap(fn(h: fn(Widget) -> int) -> int { return h(make()) })}",
            "{fn_type_outside}"))

    let size_outside: int = size_of(Point)
    let align_outside: int = align_of(Point)
    let offset_outside: int = offset_of(Point, y)
    io.println(
        row("main size_of", "{size_of(Point)}", "{size_outside}"))
    io.println(
        row("main align_of", "{align_of(Point)}", "{align_outside}"))
    io.println(
        row("main offset_of", "{offset_of(Point, y)}",
            "{offset_outside}"))

    let array_outside: int =
        (fn() -> int {
            let cells: [Point; SIZE] = [
                Point { x: 1, y: 2 },
                Point { x: 3, y: 4 },
                Point { x: 5, y: 6 },
            ]
            return cells[2].y
        })()
    io.println(
        row("main array element",
            "{(fn() -> int { let cells: [Point; SIZE] = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }, Point { x: 5, y: 6 }] ; return cells[2].y })()}",
            "{array_outside}"))

    io.println(
        row("main nested interpolation",
            "outer {"inner {new Widget().label()}"}",
            "outer inner widget"))
    io.println(
        row("main interpolation in a lambda in an interpolation",
            "{transform(fn(x: Widget) -> string { return "deep {new Widget().label()}" }, w)}",
            "deep widget"))
    io.println(
        row("main default parameter value", described(),
            "default=widget"))

    // the shapes that always worked, kept so a fix that broke them is loud
    io.println(row("main call", "{make().label()}", "widget"))
    io.println(row("main enum path", "{Tone.loud}", "loud"))
    io.println(row("main static call", "{Shop.tally()}", "7"))
    io.println(
        row("main dot path",
            "{(fn() -> int { let b: fmt.StringBuilder = new fmt.StringBuilder() ; b.push("xy") ; return b.to_string().len() })()}",
            "2"))

    // The three arguments `bind_interpolated_type` hands the resolver that
    // the cross-package battery above never reaches: the enclosing owner
    // (`Self`), the enclosing type parameters, and a builtin name — which
    // the old rule skipped outright and the new one resolves like any
    // other. None of them can be composed into a wrong package name, so
    // none of them fails on the old code; they are here so that dropping
    // one from the call cannot stay green.
    let local: Local = new Local()
    io.println(
        row("main Self", local.self_inside(), local.self_outside()))
    io.println(row("main new Self", local.self_new(), "local"))
    let crate: Crate<Widget> = new Crate<Widget>(make())
    io.println(
        row("main enclosing class type parameter",
            crate.inside(), crate.outside()))
    io.println(enclosing_fn_parameter<Point>(Point { x: 1, y: 2 }))
    let int_outside: string = type_of(int).qualified_name()
    let string_outside: string = type_of(string).qualified_name()
    io.println(
        row("main builtin type_of",
            "{type_of(int).qualified_name()}", int_outside))
    io.println(
        row("main builtin type_of string",
            "{type_of(string).qualified_name()}", string_outside))
    let widths_outside: int =
        size_of(i64) + size_of(u8) + align_of(i32)
    io.println(
        row("main builtin widths",
            "{size_of(i64) + size_of(u8) + align_of(i32)}",
            "{widths_outside}"))

    for line: string in ask() { io.println(line) }
}
