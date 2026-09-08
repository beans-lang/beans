// The second asking package (#164). The module root and this package
// compose different wrong names from the same simple name — the root would
// say `interp164.Widget`, this package `interp164.probe.Widget` — so one
// asker cannot prove the rule; both do.
package probe
import std.reflect
import std.fmt
import {Widget, Fancy, Point, SIZE, Tone, Shop, make, fancy, takes,
        transform, wrap, count, row} from interp164.kit

pub class Local {
    pub fn init() {}
    pub fn label() -> string { return "local" }
}

pub class LocalChild extends Local {
    pub fn init() { super.init() }
    pub override fn label() -> string { return "localchild" }
}

fn described(text: string = "default={new Widget().label()}") -> string {
    return text
}

pub fn ask() -> List<string> {
    var report: List<string> = []
    let w: Widget = make()
    let f: Fancy = fancy()

    // control: a type declared in this very file always resolved
    let local_outside: reflect.Type = type_of(Local)
    report.push(
        row("probe control local",
            "{type_of(Local).qualified_name()}",
            local_outside.qualified_name()))

    // the five forms the issue lists, plus every other type position
    let widget_outside: reflect.Type = type_of(Widget)
    let fancy_outside: reflect.Type = type_of(Fancy)
    report.push(
        row("probe type_of",
            "{type_of(Widget).qualified_name()}",
            widget_outside.qualified_name()))
    report.push(
        row("probe assignable",
            "{type_of(Widget).is_assignable_from(type_of(Fancy))}",
            "{widget_outside.is_assignable_from(fancy_outside)}"))
    report.push(
        row("probe roundtrip",
            "{reflect.find_type(type_of(Widget).qualified_name()).is_some()}",
            "{reflect.find_type(widget_outside.qualified_name()).is_some()}"))

    let new_outside: Widget = new Widget()
    report.push(
        row("probe new", "{new Widget().label()}",
            new_outside.label()))

    let up: Widget = f
    let cast_outside: Widget = f as Widget
    report.push(
        row("probe as", "{(f as Widget).label()}",
            cast_outside.label()))
    let down_outside: Option<Fancy> = up as? Fancy
    report.push(
        row("probe as?", "{(up as? Fancy).is_some()}",
            "{down_outside.is_some()}"))

    let targ_outside: int = count<Widget>(w)
    report.push(
        row("probe type argument", "{count<Widget>(w)}",
            "{targ_outside}"))

    let param_outside: int =
        takes(fn(x: Widget) -> int { return 1 }, w)
    report.push(
        row("probe closure parameter",
            "{takes(fn(x: Widget) -> int { return 1 }, w)}",
            "{param_outside}"))

    let result_outside: Widget =
        (fn() -> Widget { return make() })()
    report.push(
        row("probe closure result",
            "{(fn() -> Widget { return make() })().label()}",
            result_outside.label()))

    let annotation_outside: int =
        (fn() -> int { let q: Widget = make() ; return q.label().len() })()
    report.push(
        row("probe local annotation",
            "{(fn() -> int { let q: Widget = make() ; return q.label().len() })()}",
            "{annotation_outside}"))

    let nested_outside: int =
        (fn(xs: List<Widget>) -> int { return xs.len() })([make(), make()])
    report.push(
        row("probe nested type argument",
            "{(fn(xs: List<Widget>) -> int { return xs.len() })([make(), make()])}",
            "{nested_outside}"))

    let pattern_outside: string =
        match some(make()) {
            some(q: Widget) => q.label(),
            none => "none",
        }
    report.push(
        row("probe pattern binding",
            "{match some(make()) { some(q: Widget) => q.label(), none => "none" }}",
            pattern_outside))

    let fn_type_outside: int =
        wrap(fn(h: fn(Widget) -> int) -> int { return h(make()) })
    report.push(
        row("probe fn type parameter",
            "{wrap(fn(h: fn(Widget) -> int) -> int { return h(make()) })}",
            "{fn_type_outside}"))

    let size_outside: int = size_of(Point)
    let align_outside: int = align_of(Point)
    let offset_outside: int = offset_of(Point, y)
    report.push(
        row("probe size_of", "{size_of(Point)}", "{size_outside}"))
    report.push(
        row("probe align_of", "{align_of(Point)}", "{align_outside}"))
    report.push(
        row("probe offset_of", "{offset_of(Point, y)}",
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
    report.push(
        row("probe array element",
            "{(fn() -> int { let cells: [Point; SIZE] = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }, Point { x: 5, y: 6 }] ; return cells[2].y })()}",
            "{array_outside}"))

    report.push(
        row("probe nested interpolation",
            "outer {"inner {new Widget().label()}"}",
            "outer inner widget"))
    report.push(
        row("probe interpolation in a lambda in an interpolation",
            "{transform(fn(x: Widget) -> string { return "deep {new Widget().label()}" }, w)}",
            "deep widget"))
    report.push(
        row("probe default parameter value", described(),
            "default=widget"))

    // the shapes that always worked, kept so a fix that broke them is loud
    report.push(row("probe call", "{make().label()}", "widget"))
    report.push(row("probe enum path", "{Tone.loud}", "loud"))
    report.push(row("probe static call", "{Shop.tally()}", "7"))
    report.push(
        row("probe dot path",
            "{(fn() -> int { let b: fmt.StringBuilder = new fmt.StringBuilder() ; b.push("xy") ; return b.to_string().len() })()}",
            "2"))
    return move report
}
