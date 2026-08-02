import std.io

enum MirMarker {
    ready,
}

struct MirPair {
    left: int
    right: int
}

class Item {
    value: int

    fn init(value: int) {
        self.value = value
    }
}

class DeinitItem {
    value: int

    fn init(value: int) {
        self.value = value
    }

    fn deinit() {}
}

fn scalar_default() -> int {
    return 7
}

fn scalar_arg(value: int) -> int {
    return value
}

class DefaultScalar {
    first: int = scalar_default()
    second: int

    fn init(second: int) {
        self.second = second
    }
}

class FixedScalar {
    values: [int; 2]

    fn init(values: [int; 2]) {
        self.values = values
    }
}

class EffectItem {
    value: int

    fn init(value: int) {
        self.value = scalar_arg(value)
    }
}

fn default_label() -> string {
    return "bean"
}

class Defaulted {
    label: string = default_label()
}

class OwnedSink {
    label: string

    fn init(label: string) {
        self.label = label
    }
}

class ConditionalSink {
    label: string = ""

    fn init(label: string, keep: bool) {
        if keep {
            self.label = label
        }
    }
}

class DoubleSink {
    first: string
    second: string

    fn init(value: string) {
        self.first = value
        self.second = value
    }
}

class OverwriteSink {
    label: string

    fn init(value: string) {
        self.label = value
        self.label = ""
    }
}

class DeferredSelf {
    label: string

    fn init(label: string) {
        self.label = label
    }

    fn show() {
        defer io.println("self {self.label}")
    }
}

class MoveBox {
    value: string

    fn init(move value: string) {
        self.value = move value
    }
}

fn choose(flag: bool) -> int {
    if flag {
        return 1
    } else {
        return 2
    }
}

fn select(flag: bool) -> int {
    return if flag { 10 } else { 20 }
}

fn branch_owned(flag: bool) -> string {
    return if flag { "left {flag}" } else { "right {flag}" }
}

fn formatted(value: float) -> string {
    return "{value:8.2}"
}

fn interpolation_closure(base: int) -> string {
    return "{(fn() -> int { return base })()}"
}

fn two_strings(first: string, second: string) -> int {
    return first.len() + second.len()
}

fn temporary_order(flag: bool) -> int {
    return two_strings("first {flag}", "second {flag}")
}

fn marker_value(value: MirMarker) -> int {
    return match value {
        ready => 1,
    }
}

fn bump(inout value: int) {
    value += 1
}

fn moved_constructor() -> int {
    var value: string = "owned"
    let box: MoveBox = new MoveBox(move value)
    return box.value.len()
}

fn lazy(flag: bool) -> bool {
    return flag && (if flag { true } else { false })
}

fn make_adder(base: int) -> fn(int) -> int {
    return fn(value: int) -> int { return base + value }
}

fn make_nested(base: int) -> fn() -> fn() -> int {
    return fn() -> fn() -> int {
        return fn() -> int { return base }
    }
}

fn unwrap(value: Option<int>) -> int {
    return match value {
        some(item) => item,
        none => 0,
    }
}

fn move_then_replace() -> string {
    var value: string = "old"
    let old: string = move value
    value = "new"
    return old
}

fn cleanup() {}

fn deferred(value: Result<int>) -> Result<int> {
    defer cleanup()
    let item: int = value?
    return ok(item)
}

fn deferred_capture(label: string) {
    defer io.println("cleanup {label}")
}

fn build_defaults() {
    let first: Defaulted = new Defaulted()
    let second: Defaulted = new Defaulted()
    first.label.len() + second.label.len()
}

fn loop_owner(move items: List<string>, limit: int) -> int {
    var index: int = 0
    for index < limit {
        items.len()
        index += 1
    }
    return items.len()
}

fn walk(limit: int) -> int {
    var total: int = 0
    var i: int = 0
    for i < limit {
        if i == 3 {
            break
        }
        i += 1
        if i == 2 {
            continue
        }
        total += i
    }
    return total
}

fn optimized_value() -> int {
    let base: int = 2
    let unused: int = 40 + 2
    return base + 3
}

fn escaping_value(move value: string) -> string {
    return value
}

fn scalar_partial_escape(limit: int) -> int {
    var keep: List<Item> = []
    var total: int = 0
    for i: int in 0..limit {
        var item: Item = new Item(i)
        var alias: Item = item
        total += alias.value
        if i % 2 == 0 {
            keep.push(item)
        }
    }
    return total + keep.len()
}

fn scalar_no_escape(value: int) -> int {
    let item: Item = new Item(value)
    return item.value
}

fn scalar_default_order() -> int {
    let item: DefaultScalar =
        new DefaultScalar(scalar_arg(4))
    return item.first + item.second
}

fn scalar_fixed_array(value: int) -> int {
    let item: FixedScalar =
        new FixedScalar([value, value + 1])
    return item.values[0] + item.values[1]
}

fn scalar_deinit_fallback(value: int) -> int {
    let item: DeinitItem = new DeinitItem(value)
    return item.value
}

fn scalar_effect_fallback(value: int) -> int {
    let item: EffectItem = new EffectItem(value)
    return item.value
}

fn scalar_owned_field_fallback() -> int {
    let item: OwnedSink = new OwnedSink(default_label())
    return item.label.len()
}

fn scalar_write_fallback(value: int) -> int {
    let item: Item = new Item(value)
    item.value += 1
    return item.value
}

fn scalar_identity_fallback(value: int) -> bool {
    let item: Item = new Item(value)
    return item == item
}

fn scalar_capture_fallback(value: int) -> int {
    let item: Item = new Item(value)
    let read: fn() -> int =
        fn() -> int { return item.value }
    return read()
}

fn scalar_two_escapes_fallback(value: int) -> int {
    var keep: List<Item> = []
    let item: Item = new Item(value)
    keep.push(item)
    keep.push(item)
    return keep.len()
}

fn map_accumulate() -> int {
    var counts: Map<int, int> = {}
    counts[1] = counts.get(1).or(0) + 2
    return counts[1]
}

fn main() {
    deferred_capture("held")
    let deferred_self: DeferredSelf =
        new DeferredSelf("held")
    deferred_self.show()
    let pair: MirPair = MirPair { left: 3, right: 4 }
    let marker: MirMarker = MirMarker.ready
    let keyed: Map<string, int> = {"pair": pair.right}
    let item: Item = new Item(choose(true))
    let sink: OwnedSink = new OwnedSink(default_label())
    let conditional: ConditionalSink =
        new ConditionalSink(default_label(), false)
    let doubled: DoubleSink = new DoubleSink(default_label())
    let overwritten: OverwriteSink = new OverwriteSink(default_label())
    let outer: fn() -> fn() -> int = make_nested(9)
    let inner: fn() -> int = outer()
    var changed: int = 4
    bump(inout changed)
    let values: List<int> = [
        item.value, sink.label.len(), conditional.label.len(),
        doubled.first.len(), overwritten.label.len(), walk(8),
        optimized_value(), scalar_partial_escape(5),
        scalar_no_escape(3), scalar_default_order(),
        scalar_fixed_array(4),
        scalar_deinit_fallback(1), scalar_effect_fallback(2),
        scalar_owned_field_fallback(), scalar_write_fallback(3),
        if scalar_identity_fallback(4) { 1 } else { 0 },
        scalar_capture_fallback(5),
        scalar_two_escapes_fallback(6), inner(),
        pair.left, keyed.get("pair").or(0),
        branch_owned(true).len(), formatted(1.25).len(),
        interpolation_closure(6).len(), temporary_order(true),
        marker_value(marker), changed, moved_constructor(),
        map_accumulate()]
    io.println("mir {values.len()} {choose(false)} {select(true)} {lazy(true)} {inner()}")
}
