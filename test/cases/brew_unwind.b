// A panic contained by brew/join unwinds the fiber's frames instead of
// abandoning them (issue #44, spec/CONCURRENCY.md): every frame between the
// failure and the fiber entry runs its defers newest-first and drops what it
// owns, exactly as a return would. The interpreter and the native backend
// host fibers on the same scheduler and run the same cleanup, so this is
// byte-identical between them — order included. Reverting either backend's
// half leaves cleanup unrun and this golden no longer matches.
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
}

// The innermost frame: two owned locals and three defers, then a panic. The
// defers must run newest-first (B, then A, then the counter defer), and the
// owned locals must drop newest-first after them.
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

// A middle frame with its own owned local and defer, so the unwind has to
// cross more than one function boundary to reach the fiber entry.
fn middle(c: Counter) -> int {
    let held: Res = new Res("middle-held")
    defer io.println("  middle defer")
    return deep(c)
}

// A move-only owned local must run its deinit on the way out too.
fn with_moveonly() -> int {
    let t: Token = new Token(7)
    defer io.println("  moveonly defer")
    let empty: List<int> = []
    return empty[0]
}

// A captured local lives in a heap cell shared with the closure; the cell,
// and the value it holds, must be released on the unwind (its Res deinit runs
// once). The closure is never called — only its capture matters here.
fn with_capture() -> int {
    let r: Res = new Res("captured-res")
    let f: fn() -> unit = fn() { io.println("  see {r.tag}") }
    defer io.println("  capture defer")
    let empty: List<int> = []
    return empty[0]
}

fn shielded(c: Counter, label: string) -> string {
    let child: Brew<int> = brew middle(c)
    match child.join() {
        ok(v) => { return "ok {v}" }
        err(problem) => { return "{label}: {problem.kind}" }
    }
}

fn shield_moveonly() -> string {
    let child: Brew<int> = brew with_moveonly()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "moveonly: {problem.kind}" }
    }
}

fn shield_capture() -> string {
    let child: Brew<int> = brew with_capture()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "capture: {problem.kind}" }
    }
}

// The espresso shielded-handle shape: a handler is called through `?`, and the
// handler panics. The operand's panic is already in flight when `?` is
// reached, so `?` must short-circuit rather than see the poisoned unit as a
// non-result and raise a second failure inside the unwind — which the
// interpreter would report as a double panic and abort. The handler still
// drops what it owns on the way out.
fn faulty() -> Result<int> {
    let held: Res = new Res("faulty-held")
    panic("faulty lost it")
    return ok(0)
}

fn pipeline() -> Result<int> {
    let produced: int = faulty()?
    return ok(produced)
}

fn shield_pipeline() -> string {
    let child: Brew<Result<int>> = brew pipeline()
    match child.join() {
        ok(r) => { return "ok" }
        err(problem) => { return "pipeline: {problem.kind}" }
    }
}

// A defer that panics on the normal return path. The panic is contained, so
// the unwind takes over the rest of the frame's cleanup: the defer that
// panicked does not run a second time, the older defer still runs, and the
// local drops. The native backend once re-ran the panicking defer from its
// cleanup pad and died of a double panic.
fn boom_unit() { let empty: List<int> = []; let unused: int = empty[2] }

fn defer_panics() -> int {
    let local: Res = new Res("dp-local")
    defer io.println("  dp older defer")
    defer boom_unit()
    return 0
}

fn shield_defer_panic() -> string {
    let child: Brew<int> = brew defer_panics()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "defer-panic: {problem.kind}" }
    }
}

// A deinit that panics while a frame drops its locals on the normal path.
// The panic is contained; the object whose deinit panicked is abandoned
// mid-destruction and is not released a second time, and the locals that
// had not dropped yet still drop.
class Bomb {
    fn deinit() {
        io.println("  deinit bomb panics")
        let empty: List<int> = []
        let unused: int = empty[0]
    }
}

fn deinit_panics() -> int {
    let first: Res = new Res("first")
    let bomb: Bomb = new Bomb()
    let last: Res = new Res("last")
    return 1
}

fn shield_deinit_panic() -> string {
    let child: Brew<int> = brew deinit_panics()
    match child.join() {
        ok(v) => { return "ok" }
        err(problem) => { return "deinit-panic: {problem.kind}" }
    }
}

// ---- what the failing statement was holding (issue #44, B1/B2) ----------
//
// A value that holds an owned reference and is still in flight when a later
// instruction panics belongs to no local: the plan releases it after its
// last use. The unwind releases it as the interpreter's expression frames
// do — newest first, before the frame's defers, before its locals.

fn boom() -> int { let empty: List<int> = []; return empty[3] }
fn mk(tag: string) -> Res { return new Res(tag) }
fn accept(a: Res, b: Res, n: int) -> int { return n }
fn accept_one(a: Res, n: int) -> int { return n }

// two temporaries in one argument list, a defer and a local beside them:
// temporaries newest-first, then the defer, then the local
fn temps_order() -> int {
    let local: Res = new Res("t-local")
    defer io.println("  t defer")
    return accept(new Res("t-first"), new Res("t-second"), boom())
}

// an outer call's temporary is live while the inner call's temporary dies
fn temps_nested() -> int {
    return accept_one(mk("t-outer"), accept_one(mk("t-inner"), boom()))
}

// a temporary of the enclosing statement, live across a block that owns a
// local: the block's local was created later, so it drops first
fn temps_across_block() -> int {
    let local: Res = new Res("tb-local")
    defer io.println("  tb defer")
    return accept_one(mk("tb-temp"), if true { let inner: Res = mk("tb-inner"); boom() } else { 0 })
}

// an interpolated piece, then a panicking call
fn temps_interpolation() -> string { return "{mk("t-piece").tag} {boom()}" }

// list literal elements, then a panicking element
fn boom_res() -> Res { let empty: List<int> = []; return new Res("never-{empty[0]}") }
fn temps_list_literal() -> int {
    let built: List<Res> = [mk("t-elem-1"), mk("t-elem-2"), boom_res()]
    return built.len()
}

// a value stored out of range: the list never took it, so it still drops
fn temps_index_store() -> int {
    var slots: List<Res> = [mk("t-slot0")]
    slots[7] = mk("t-assigned")
    return 0
}

// a runtime entry that refuses the value: an insert out of range panics in
// the runtime before it takes the value, so the value is still the frame's
// and drops on the unwind (the allowlist in src/llvm_unwind.b)
fn temps_insert_store() -> int {
    var slots: List<Res> = [mk("ti-slot0")]
    slots.insert(7, mk("ti-inserted"))
    return 0
}

// a send on a closed channel: the runtime declines the value and the inline
// panic follows, so the value drops on the unwind
fn temps_closed_send() -> int {
    let line: Channel<Res> = new Channel(2)
    line.close()
    line.send(mk("cs-sent"))
    return 0
}

// the collection a `for` took from a temporary, released when the body
// panics mid-iteration
fn make_list() -> List<Res> { return [mk("t-item-a"), mk("t-item-b")] }
fn temps_iterator() -> int {
    var seen: int = 0
    for item: Res in make_list() {
        seen += 1
        if seen == 1 { return boom() }
    }
    return seen
}

// a defer that panics on the normal return path while a return value is
// in flight: the older defer, the locals, then the value being returned
fn temps_pending_return() -> Res {
    let local: Res = new Res("pr-local")
    defer io.println("  pr older defer")
    defer boom_unit()
    return mk("pr-retval")
}

// a panic inside init after one field is assigned: the half-built object
// is released as a whole — its deinit runs, then its fields drop
class Half {
    pub a: Res
    pub b: Res
    fn init(fail: bool) {
        self.a = new Res("half-a")
        if fail { let empty: List<int> = []; let unused: int = empty[1] }
        self.b = new Res("half-b")
    }
    fn deinit() { io.println("  deinit half, a={self.a.tag}") }
}
fn init_after_field() -> int { let h: Half = new Half(true); return 1 }

// a panic inside init before anything is assigned: deinit sees defaults
class Early {
    pub tag: string = "default"
    fn init() { let empty: List<int> = []; let unused: int = empty[0]; self.tag = "set" }
    fn deinit() { io.println("  deinit early, tag={self.tag}") }
}
fn init_before_field() -> int { return accept_one(new Res("e-arg"), new Early().tag.len()) }

// a locals-only frame and a defer-only frame
fn locals_only() -> int {
    let first: Res = new Res("lo-first")
    let second: Res = new Res("lo-second")
    return boom()
}
fn defer_only() -> int {
    defer io.println("  do defer B")
    defer io.println("  do defer A")
    return boom()
}

// The panic point is an inline operation, not a call: integer / and %
// guard for zero, and every decimal operation can fail in its bridge.
// The temp scan must see these as panic points, or the argument built
// before them leaks on the unwind (it did: the effects table said "none").
fn int_zero() -> int { return 0 }
fn dec_zero() -> decimal { return 0.0 }
fn accept_moved(move a: Res, n: int) -> int { return n }
fn accept_moved_dec(move a: Res, d: decimal) -> int { return 1 }

fn temps_div_arg() -> int {
    let z: int = int_zero()
    return accept_moved(mk("dv-held"), 10 / z)
}
fn temps_mod_arg() -> int {
    let z: int = int_zero()
    return accept_moved(mk("md-held"), 10 % z)
}
fn temps_dec_arg() -> int {
    let z: decimal = dec_zero()
    return accept_moved_dec(mk("dc-held"), 4.5 / z)
}
fn temps_list_div() -> int {
    let z: int = int_zero()
    let items: List<Res> = [mk("ld-first"), mk("ld-div {10 / z}")]
    return items.len()
}
fn temps_interp_div() -> string {
    let z: int = int_zero()
    return "made {mk("id-held").tag} then {10 / z}"
}

// ---- a panic raised inside a map runtime entry point --------------------
//
// `for k, v in m` calls beans_map_iter_next, and a structural change makes
// that call panic. The entry point is always_inline (runtime/beans_rt.c),
// so in an --lto build the panic is raised from this frame instead of from
// a C frame above it, and the emitter's invoke rewrite is what carries the
// unwind either way. Same for the release beans_map_remove_raw runs when a
// removed value's deinit fails. test/map_inline.sh runs this whole file
// again with --lto against this same golden.

fn map_mutated() -> int {
    let local: Res = new Res("mm-local")
    defer io.println("  mm defer")
    var counts: Map<int, int> = {}
    var i: int = 0
    for i < 12 { counts[i] = i; i += 1 } // past the linear cutoff: indexed
    var seen: int = 0
    for key: int, value: int in counts {
        seen += value
        counts[key + 100] = 1 // structural: the next iter_next refuses
    }
    return seen
}

// The map the loop walks is a temporary that owns its values, so the frame
// releases the whole map when the body panics on the first turn.
fn make_res_map() -> Map<int, Res> {
    var built: Map<int, Res> = {}
    var i: int = 0
    for i < 10 {
        built[i] = new Res("rm-{i}")
        i += 1
    }
    return move built
}
fn temps_map_iterator() -> int {
    var seen: int = 0
    for key: int, value: Res in make_res_map() {
        seen += 1
        if seen == 1 { return boom() }
    }
    return seen
}

// A removal whose value deinit panics. The panic surfaces from inside
// beans_map_remove_raw, so the entry must already be unlinked when it does
// (issue #44's rule, applied to remove): the map goes on to drop its other
// eleven values with the removed key gone, not still present. Only one item
// is loud -- a map full of them would panic again during the unwind, which
// is the documented double-panic abort and would say nothing about this.
class MapItem {
    pub tag: string
    pub loud: bool
    fn init(tag: string, loud: bool) {
        self.tag = tag
        self.loud = loud
    }
    fn deinit() {
        io.println("  drop item {self.tag}")
        if self.loud {
            let empty: List<int> = []
            let unused: int = empty[0]
        }
    }
}
fn map_remove_deinit() -> int {
    let local: Res = new Res("mr-local")
    defer io.println("  mr defer")
    var held: Map<int, MapItem> = {}
    var i: int = 0
    for i < 12 {
        held[i] = new MapItem("{i}", i == 5)
        i += 1
    }
    held.remove(5)
    return 0
}

fn run_shape(which: int) -> int {
    if which == 1 { return temps_order() }
    if which == 2 { return temps_nested() }
    if which == 3 { return temps_across_block() }
    if which == 4 { return temps_interpolation().len() }
    if which == 5 { return temps_list_literal() }
    if which == 6 { return temps_index_store() }
    if which == 7 { return temps_iterator() }
    if which == 8 { let r: Res = temps_pending_return(); return r.tag.len() }
    if which == 9 { return init_after_field() }
    if which == 10 { return init_before_field() }
    if which == 11 { return locals_only() }
    if which == 12 { return defer_only() }
    if which == 13 { return temps_insert_store() }
    if which == 14 { return temps_closed_send() }
    if which == 15 { return temps_div_arg() }
    if which == 16 { return temps_mod_arg() }
    if which == 17 { return temps_dec_arg() }
    if which == 18 { return temps_list_div() }
    if which == 19 { return temps_interp_div().len() }
    if which == 20 { return map_mutated() }
    if which == 21 { return temps_map_iterator() }
    return map_remove_deinit()
}

fn shield_shape(which: int, label: string) -> string {
    let child: Brew<int> = brew run_shape(which)
    match child.join() {
        ok(v) => { return "{label}: ok {v}" }
        err(problem) => { return "{label}: {problem.kind}" }
    }
}

fn main() {
    let c: Counter = new Counter()
    io.println(shielded(c, "first"))
    var i: int = 0
    for i < 4 {
        io.println(shielded(c, "loop"))
        i += 1
    }
    io.println("counter after 5 contained panics: {c.n}")
    io.println(shield_moveonly())
    io.println(shield_capture())
    io.println(shield_pipeline())
    io.println(shield_defer_panic())
    io.println(shield_deinit_panic())
    io.println(shield_shape(1, "temps"))
    io.println(shield_shape(2, "nested temps"))
    io.println(shield_shape(3, "temp across block"))
    io.println(shield_shape(4, "interpolation"))
    io.println(shield_shape(5, "list literal"))
    io.println(shield_shape(6, "index store"))
    io.println(shield_shape(7, "iterator"))
    io.println(shield_shape(8, "pending return"))
    io.println(shield_shape(9, "init after field"))
    io.println(shield_shape(10, "init before field"))
    io.println(shield_shape(11, "locals only"))
    io.println(shield_shape(12, "defer only"))
    io.println(shield_shape(13, "insert store"))
    io.println(shield_shape(14, "closed send"))
    io.println(shield_shape(15, "div arg"))
    io.println(shield_shape(16, "mod arg"))
    io.println(shield_shape(17, "decimal arg"))
    io.println(shield_shape(18, "list literal div"))
    io.println(shield_shape(19, "interpolation div"))
    io.println(shield_shape(20, "map iteration"))
    io.println(shield_shape(21, "map temporary"))
    io.println(shield_shape(22, "map remove deinit"))
}
