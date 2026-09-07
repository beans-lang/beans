// contained <call> — a catch frame on the CURRENT fiber (issue #145,
// spec/CONCURRENCY.md). A panic raised anywhere under the call unwinds the
// frames between it and the boundary — defers newest-first, owned values
// dropped — and arrives at the call site as err(kind panic) with the report a
// brewed fiber's join would have delivered. No fiber is spawned, nothing
// switches, nothing is joined.
//
// The interpreter walks the same unwind the native backend's landing pads
// walk, so this is byte-identical between them, cleanup order included.
// Revert either half and the cleanup stops running, so the golden no longer
// matches.
import std.io

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

// A move-only local, to exercise the move-only drop on the unwind path.
unique class Token {
    pub id: int
    fn init(id: int) { self.id = id }
    fn deinit() { io.println("  drop token {self.id}") }
}

class Counter {
    pub n: int = 0
    pub fn up() { self.n += 1 }
    pub fn down() { self.n -= 1 }
    pub fn scaled(by: int) -> int {
        if by == 0 { panic("scale by zero") }
        return self.n * by
    }
}

// ---- 1. the fast path ------------------------------------------------------

fn doubled(n: int) -> int { return n * 2 }

fn ok_path() {
    match contained doubled(21) {
        ok(v) => { io.println("fast path: ok {v}") }
        err(p) => { io.println("fast path: err {p.kind}") }
    }
}

// ---- 2. a panic three frames down, with cleanup at every level -------------

fn deep(c: Counter) -> int {
    let first: Res = new Res("deep-first")
    let second: Res = new Res("deep-second")
    c.up()
    defer c.down()
    defer io.println("  deep defer A")
    defer io.println("  deep defer B")
    let empty: List<int> = []
    return empty[7]
}

fn middle(c: Counter) -> int {
    let held: Res = new Res("middle-held")
    defer io.println("  middle defer")
    return deep(c)
}

fn outer(c: Counter) -> int {
    let carried: Res = new Res("outer-carried")
    defer io.println("  outer defer")
    return middle(c)
}

fn nested_frames() {
    let c: Counter = new Counter()
    io.println("nested frames:")
    match contained outer(c) {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  caught {p.kind}: {p.msg}") }
    }
    io.println("  counter back to {c.n}")
}

// ---- 3. live resources of every drop shape --------------------------------

fn with_moveonly() -> int {
    let t: Token = new Token(7)
    defer io.println("  moveonly defer")
    let empty: List<int> = []
    return empty[0]
}

// A captured local lives in a heap cell shared with the closure; the cell and
// the value it holds must be released on the unwind. The closure is never
// called — only its capture matters here.
fn with_capture() -> int {
    let r: Res = new Res("captured-res")
    let f: fn() -> unit = fn() { io.println("  see {r.tag}") }
    defer io.println("  capture defer")
    let empty: List<int> = []
    return empty[0]
}

// A container of owned elements: the list's own drop has to reach them.
fn with_container() -> int {
    let held: List<Res> = [new Res("in-list-1"),
                           new Res("in-list-2")]
    defer io.println("  container defer")
    let empty: List<int> = []
    return empty[0]
}

fn resources() {
    io.println("move-only:")
    match contained with_moveonly() {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  caught {p.kind}") }
    }
    io.println("captured cell:")
    match contained with_capture() {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  caught {p.kind}") }
    }
    io.println("container:")
    match contained with_container() {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  caught {p.kind}") }
    }
}

// ---- 4. nesting: the innermost frame catches ------------------------------

fn always_fails(tag: string) -> int {
    let r: Res = new Res(tag)
    panic("{tag} refused")
}

// The inner boundary catches, so the outer one sees an ordinary return.
fn inner_catches() -> string {
    let guard: Res = new Res("inner-guard")
    defer io.println("  inner-catches defer")
    match contained always_fails("inner") {
        ok(v) => { return "ok {v}" }
        err(p) => { return "inner caught {p.kind}" }
    }
}

// The inner boundary catches, then this frame panics on its own, so the
// OUTER boundary is what catches the second failure.
fn inner_then_own() -> string {
    let guard: Res = new Res("second-guard")
    defer io.println("  inner-then-own defer")
    match contained always_fails("first") {
        ok(v) => { io.println("  unexpected ok") }
        err(p) => { io.println("  first caught {p.kind}") }
    }
    panic("and then this frame")
}

fn nesting() {
    io.println("nested containment:")
    match contained inner_catches() {
        ok(v) => { io.println("  outer sees ok: {v}") }
        err(p) => { io.println("  outer caught {p.kind}") }
    }
    io.println("nested then own failure:")
    match contained inner_then_own() {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  outer caught {p.kind}: {p.msg}") }
    }
}

// ---- 5. a contained call inside a defer, on the normal path ---------------

fn contain_in_cleanup() {
    match contained always_fails("in-defer") {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  defer caught {p.kind}") }
    }
}

fn defer_contains() -> int {
    defer contain_in_cleanup()
    return 3
}

fn contained_in_defer() {
    io.println("contained inside a defer:")
    io.println("  returned {defer_contains()}")
}

// ---- 6. a contained call on a brewed fiber -------------------------------

fn on_fiber() -> int {
    match contained always_fails("on-fiber") {
        ok(v) => { return v }
        err(p) => {
            io.println("  fiber caught {p.kind}")
            return 11
        }
    }
}

fn brewed_child() {
    io.println("contained on a brewed fiber:")
    let child: Brew<int> = brew on_fiber()
    match child.join() {
        ok(v) => { io.println("  join ok {v}") }
        err(p) => { io.println("  join err {p.kind}") }
    }
}

// ---- 7. a brew under a contained call ------------------------------------
//
// The child's panic belongs to the child's own boundary, not to the catch
// frame standing on the parent: the join reports it and the contained call
// returns ok.

fn joins_a_failing_child() -> string {
    let child: Brew<int> = brew always_fails("child")
    match child.join() {
        ok(v) => { return "ok {v}" }
        err(p) => { return "child {p.kind}" }
    }
}

// The child is never joined, so the synthesized scope join escalates its
// panic into THIS frame — and that panic is the contained boundary's.
fn never_joins() -> int {
    brew always_fails("unjoined")
    return 4
}

fn with_fibers() {
    io.println("brew under a contained call:")
    match contained joins_a_failing_child() {
        ok(v) => { io.println("  ok: {v}") }
        err(p) => { io.println("  caught {p.kind}") }
    }
    io.println("escalated scope join:")
    match contained never_joins() {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  caught {p.kind}: {p.msg}") }
    }
}

// ---- 8. every payload shape ----------------------------------------------

fn as_string(fail: bool) -> string {
    if fail { panic("string refused") }
    return "a string"
}

fn as_resource(fail: bool) -> Res {
    if fail { panic("resource refused") }
    return new Res("returned-res")
}

fn as_option(fail: bool) -> Option<int> {
    if fail { panic("option refused") }
    return some(9)
}

fn as_decimal(fail: bool) -> decimal {
    if fail { panic("decimal refused") }
    return 1.25
}

fn as_result(fail: bool) -> Result<int> {
    if fail { panic("result refused") }
    return err("declined", "domain")
}

fn as_list(fail: bool) -> List<int> {
    if fail { panic("list refused") }
    return [1, 2, 3]
}

fn payloads() {
    io.println("payload shapes:")
    match contained as_string(false) {
        ok(v) => { io.println("  string ok {v}") }
        err(p) => { io.println("  string err {p.kind}") }
    }
    match contained as_string(true) {
        ok(v) => { io.println("  string unexpected ok {v}") }
        err(p) => { io.println("  string err {p.kind}") }
    }
    match contained as_resource(false) {
        ok(v) => { io.println("  resource ok {v.tag}") }
        err(p) => { io.println("  resource err {p.kind}") }
    }
    match contained as_resource(true) {
        ok(v) => { io.println("  resource unexpected ok {v.tag}") }
        err(p) => { io.println("  resource err {p.kind}") }
    }
    match contained as_option(false) {
        ok(v) => {
            match v {
                some(n) => { io.println("  option ok {n}") }
                none => { io.println("  option ok none") }
            }
        }
        err(p) => { io.println("  option err {p.kind}") }
    }
    match contained as_option(true) {
        ok(_) => { io.println("  option unexpected ok") }
        err(p) => { io.println("  option err {p.kind}") }
    }
    match contained as_decimal(false) {
        ok(v) => { io.println("  decimal ok {v}") }
        err(p) => { io.println("  decimal err {p.kind}") }
    }
    match contained as_decimal(true) {
        ok(v) => { io.println("  decimal unexpected ok {v}") }
        err(p) => { io.println("  decimal err {p.kind}") }
    }
    match contained as_result(false) {
        ok(inner) => {
            match inner {
                ok(n) => { io.println("  result ok ok {n}") }
                err(q) => { io.println("  result ok err {q.kind}") }
            }
        }
        err(p) => { io.println("  result err {p.kind}") }
    }
    match contained as_result(true) {
        ok(_) => { io.println("  result unexpected ok") }
        err(p) => { io.println("  result err {p.kind}") }
    }
    match contained as_list(false) {
        ok(v) => { io.println("  list ok {v.len()}") }
        err(p) => { io.println("  list err {p.kind}") }
    }
    match contained as_list(true) {
        ok(v) => { io.println("  list unexpected ok {v.len()}") }
        err(p) => { io.println("  list err {p.kind}") }
    }
}

// ---- 9. a method through a class receiver --------------------------------

fn methods() {
    let c: Counter = new Counter()
    c.up()
    c.up()
    io.println("method receiver:")
    match contained c.scaled(5) {
        ok(v) => { io.println("  ok {v}") }
        err(p) => { io.println("  err {p.kind}") }
    }
    match contained c.scaled(0) {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  err {p.kind}") }
    }
}

// ---- 10. an initializer that does not finish -----------------------------

class HalfBuilt {
    pub kept: Res
    pub tag: string = "half"
    fn init(fail: bool) {
        self.kept = new Res("half-built-field")
        if fail { panic("init refused") }
        self.tag = "whole"
    }
    fn deinit() { io.println("  drop HalfBuilt {self.tag}") }
}

fn build(fail: bool) -> string {
    let made: HalfBuilt = new HalfBuilt(fail)
    return made.tag
}

fn half_built() {
    io.println("unfinished construction:")
    match contained build(false) {
        ok(v) => { io.println("  ok {v}") }
        err(p) => { io.println("  err {p.kind}") }
    }
    match contained build(true) {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  err {p.kind}") }
    }
}

// ---- 11. depth: contained is legal wherever an expression is -------------

fn maybe(n: int) -> int {
    if n % 3 == 0 { panic("divisible by three: {n}") }
    return n
}

fn in_nested_blocks() {
    io.println("nested blocks and loops:")
    var caught: int = 0
    var summed: int = 0
    for n: int in 1..7 {
        if n != 5 {
            match contained maybe(n) {
                ok(v) => { summed += v }
                err(_) => { caught += 1 }
            }
        }
    }
    io.println("  summed {summed}, caught {caught}")
}

// ---- 12. the fiber keeps running, many times over ------------------------

// Quiet on the way out, so two hundred catches do not drown the golden. What
// it proves is that the fiber is genuinely running again after each one — the
// count is only reached if every catch returned to this loop — and, under the
// sanitize gate, that two hundred unwinds leak nothing: each carries an owned
// buffer and a defer that has to run.
fn quietly_fails(n: int) -> int {
    let held: List<int> = [n, n + 1, n + 2]
    let name: string = "quiet {n}"
    defer held.clear()
    if n >= 0 { panic(name) }
    return n
}

fn repeated() {
    var caught: int = 0
    for n: int in 0..200 {
        match contained quietly_fails(n) {
            ok(_) => {}
            err(_) => { caught += 1 }
        }
    }
    io.println("repeated: {caught} caught, still running")
}

// ---- 13. contained as a plain expression, not only a match scrutinee -----

fn as_expression() {
    let good: Result<int> = contained doubled(4)
    let bad: Result<int> = contained always_fails("bound")
    io.println("bound results: {good.is_ok()} {bad.is_ok()}")
    match good {
        ok(v) => { io.println("bound value: {v}") }
        err(p) => { io.println("bound value: err {p.kind}") }
    }
}

fn main() {
    ok_path()
    nested_frames()
    resources()
    nesting()
    contained_in_defer()
    brewed_child()
    with_fibers()
    payloads()
    methods()
    half_built()
    in_nested_blocks()
    repeated()
    as_expression()
    io.println("done")
}
