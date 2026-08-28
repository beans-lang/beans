// What a `for` loop over a List is allowed to see while it runs.
// spec/SYNTAX.md, "Changing a collection while a loop reads it": the loop
// reads the list itself, so replacing an element in place is visible on the
// turn that reaches it, and everything that is not a structural change keeps
// the loop running. The structural changes that stop it are in
// test/cases/list_iteration_mutation.b and tools/list_iteration_probe.py.
//
// Every case runs at more than one size on purpose: at n = 1 a snapshot and a
// live read agree, and a List starts at capacity 4, so nothing below five
// elements ever reallocates its buffer.
import std.io

class Item {
    pub value: int
    fn init(value: int) { self.value = value }
}

fn build(n: int) -> List<int> {
    var xs: List<int> = []
    var i: int = 0
    for i < n {
        xs.push(i + 1)
        i += 1
    }
    return move xs
}

// Writing an index the loop has not reached yet. The loop must see 500.
fn write_ahead(n: int) {
    var xs: List<int> = build(n)
    var seen: List<int> = []
    for x: int in xs {
        seen.push(x)
        if seen.len() == 1 { xs[n - 1] = 500 }
    }
    io.println("ahead n {n}: {seen.join(",")}")
}

// Writing an index the loop has already passed. Nothing changes for it.
fn write_behind(n: int) {
    var xs: List<int> = build(n)
    var seen: List<int> = []
    for x: int in xs {
        seen.push(x)
        xs[0] = 900
    }
    io.println("behind n {n}: {seen.join(",")} head {xs[0]}")
}

// reserve moves capacity, never an element's index.
fn reserve_during(n: int) {
    var xs: List<int> = build(n)
    var total: int = 0
    for x: int in xs {
        total += x
        xs.reserve(0)
        xs.reserve(4096)
    }
    io.println("reserve n {n}: total {total} len {xs.len()}")
}

// Every read stays a read.
fn read_during(n: int) {
    var xs: List<int> = build(n)
    var total: int = 0
    for x: int in xs {
        total += xs.len()
        total += xs.get(0).or(0)
        total += xs.index_of(x).or(-1)
        if xs.contains(x) { total += 1 }
        total += xs.min().or(0) + xs.max().or(0)
        total += xs.slice(0, 1).len() + xs.clone().len()
        total += xs.join("-").len()
    }
    io.println("read n {n}: total {total}")
}

// A different list is a different list, even one made from this one.
fn other_list(n: int) {
    var xs: List<int> = build(n)
    var copy: List<int> = xs.clone()
    var out: List<int> = []
    for x: int in xs {
        copy.push(x)
        copy.sort()
        out.push(x)
    }
    io.println("other n {n}: {out.join(",")} copy {copy.len()}")
}

// The element's own fields are not the list's shape.
fn element_fields(n: int) {
    var items: List<Item> = []
    var i: int = 0
    for i < n {
        items.push(new Item(i + 1))
        i += 1
    }
    var total: int = 0
    for item: Item in items {
        item.value += 10
        total += item.value
    }
    io.println("fields n {n}: total {total} first {items[0].value}")
}

// The check happens before the next element is read, so a loop that never
// reads again never sees the change. One case per structural operation.
fn leave_after_change(n: int) {
    var pushed: List<int> = build(n)
    for x: int in pushed { pushed.push(1) ; break }
    var popped: List<int> = build(n)
    for x: int in popped { let _d: Option<int> = popped.pop() ; break }
    var inserted: List<int> = build(n)
    for x: int in inserted { inserted.insert(0, 1) ; break }
    var removed: List<int> = build(n)
    for x: int in removed { let _r: int = removed.remove(0) ; break }
    var cleared: List<int> = build(n)
    for x: int in cleared { cleared.clear() ; break }
    var reversed: List<int> = build(n)
    for x: int in reversed { reversed.reverse() ; break }
    var sorted: List<int> = build(n)
    for x: int in sorted { sorted.sort() ; break }
    io.println("break n {n}: {pushed.len()} {popped.len()} {inserted.len()} {removed.len()} {cleared.len()} {reversed.len()} {sorted.len()}")
}

fn return_after_change(n: int) -> int {
    var xs: List<int> = build(n)
    for x: int in xs {
        xs.clear()
        return x
    }
    return -1
}

// Two loops over one list, both reading.
fn nested_reads(n: int) {
    var xs: List<int> = build(n)
    var total: int = 0
    for a: int in xs {
        for b: int in xs {
            total += a * b
        }
    }
    io.println("nested n {n}: {total}")
}

// slice() answers a copy, so the loop walks the copy: writing the original
// does not reach it. (The compiler may skip materializing that copy and walk
// the original's storage, but only when it can prove the original does not
// change — which this body does, so the copy is real here.)
fn slice_loop(n: int) {
    var xs: List<int> = build(n)
    var seen: List<int> = []
    for x: int in xs.slice(0, n) {
        seen.push(x)
        if seen.len() == 1 { xs[n - 1] = 700 }
    }
    io.println("slice n {n}: {seen.join(",")}")
}

// A structural change to the parent inside a slice loop does not panic the way
// a direct list loop does: `xs.slice(0, n)` answers a copy and the loop walks
// the copy, so the change is invisible and there is nothing to invalidate. The
// push still happens -- xs grows -- the loop just never sees it. (The compiler
// fuses the copy away only when the body leaves xs untouched; touching xs, as
// here, materializes the copy, so the fused change-count guard is never the
// path a source program takes.)
fn slice_parent_change(n: int) {
    var xs: List<int> = build(n)
    var seen: List<int> = []
    for x: int in xs.slice(0, n) {
        seen.push(x)
        if seen.len() == 1 { xs.push(999) }
    }
    io.println("slicechg n {n}: {seen.join(",")} xslen {xs.len()}")
}

// Reference elements: the same rule, with ARC underneath.
fn strings_ahead(n: int) {
    var xs: List<string> = []
    var i: int = 0
    for i < n {
        xs.push("v{i + 1}")
        i += 1
    }
    var seen: List<string> = []
    for s: string in xs {
        seen.push(s)
        if seen.len() == 1 { xs[n - 1] = "last" }
    }
    io.println("strings n {n}: {seen.join(",")}")
}

// Wide inline elements take a different runtime path than i64 slots.
fn decimals_ahead(n: int) {
    var xs: List<decimal> = []
    var i: int = 0
    for i < n {
        xs.push((i + 1) as decimal)
        i += 1
    }
    var total: decimal = 0
    var count: int = 0
    for d: decimal in xs {
        total += d
        count += 1
        if count == 1 { xs[n - 1] = 50.5 }
    }
    io.println("decimals n {n}: total {total} count {count}")
}

// spec/SYNTAX.md: sort_by_key is one key call per item. The order is the same
// either way, so only a call counter can see the one-element case.
class Counter {
    pub calls: int = 0
    pub fn bump(v: int) -> int {
        self.calls += 1
        return v
    }
}

fn key_calls(n: int) {
    var xs: List<int> = []
    var i: int = 0
    for i < n {
        xs.push((n - i) * 7 % 101)
        i += 1
    }
    let c: Counter = new Counter()
    xs.sort_by_key(fn(v: int) -> int { return c.bump(v) })
    io.println("keys n {n}: calls {c.calls} head {xs.get(0).or(-1)}")
}

fn main() {
    for n: int in [1, 2, 5, 40] {
        write_ahead(n)
        write_behind(n)
        reserve_during(n)
        read_during(n)
        other_list(n)
        element_fields(n)
        leave_after_change(n)
        io.println("return n {n}: {return_after_change(n)}")
        nested_reads(n)
        slice_loop(n)
        slice_parent_change(n)
        strings_ahead(n)
        decimals_ahead(n)
    }
    for n: int in [0, 1, 2, 3, 4, 5, 8, 9, 64, 65] {
        key_calls(n)
    }
}
