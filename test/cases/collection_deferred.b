import std.io
import std.intrinsic
import std.thread
import std.os

class State {
    pub left: int = 0
    pub right: int = 0
    pub observed: int = 0
    pub torn: int = 0
    pub immediate: int = 0
    pub before_panic: int = -1
    pub fn settle() { self.right = self.left }
}

class Probe {
    pub next: Option<Probe> = none
    owner: State
    fn init(owner: State) { self.owner = owner }
    fn deinit() {
        self.owner.observed += 1
        if self.owner.left != self.owner.right { self.owner.torn += 1 }
    }
}

class ArcProbe {
    owner: State
    fn init(owner: State) { self.owner = owner }
    fn deinit() { self.owner.immediate += 1 }
}

fn last_release(state: State) { let value: ArcProbe = new ArcProbe(state) }

fn cycles(state: State, count: int) {
    var i: int = 0
    for i < count {
        let a: Probe = new Probe(state)
        let b: Probe = new Probe(state)
        a.next = some(b)
        b.next = some(a)
        i += 1
    }
}

fn fail_nested(state: State, count: int) -> int {
    unsafe {
        intrinsic.with_collection_deferred(fn() {
            intrinsic.with_collection_deferred(fn() {
                state.left = 2
                // A mutation must settle its own writes on failure; the gate
                // supplies collection exclusion, not transaction rollback.
                defer state.settle()
                cycles(state, count)
                state.before_panic = state.observed
                panic("nested mutation failed")
            })
        })
    }
    return 0
}

fn isolated_worker() -> bool {
    let state: State = new State()
    var deferred: bool = false
    unsafe {
        intrinsic.with_collection_deferred(fn() {
            state.left = 1
            cycles(state, 512)
            intrinsic.with_collection_deferred(fn() { cycles(state, 512) })
            cycles(state, 512)
            deferred = state.observed == 0
            state.settle()
        })
    }
    cycles(state, 3000)
    let after_panic: State = new State()
    var caught: bool = false
    match contained fail_nested(after_panic, 512) {
        ok(v) => {}
        err(e) => { caught = true }
    }
    return deferred && state.torn == 0 && caught &&
           after_panic.before_panic == 0 && after_panic.torn == 0
}

fn main() {
    let args: List<string> = os.args()
    let state: State = new State()
    var nested_deferred: bool = false
    var immediate_arc: bool = false
    unsafe {
        intrinsic.with_collection_deferred(fn() {
            state.left = 1
            cycles(state, 6000)
            intrinsic.with_collection_deferred(fn() { cycles(state, 6000) })
            // The inner return must not reopen the outer region.
            cycles(state, 6000)
            last_release(state)
            nested_deferred = state.observed == 0
            immediate_arc = state.immediate == 1
            state.right = 1
        })
    }
    io.println("nested deferred: {nested_deferred}")
    io.println("immediate ARC: {immediate_arc}")
    cycles(state, 24000)
    io.println("collection resumed: {state.observed > 0}")
    io.println("normal tears: {state.torn}")
    // ASan's forced-unwind path fails in the existing contained_threads
    // regression too. The sanitizer lane covers normal nesting and ARC;
    // both ordinary backends above/below cover the complete panic contract.
    if args.len() > 0 && args[0] == "--normal-only" { return }

    let after_panic: State = new State()
    match contained fail_nested(after_panic, 6000) {
        ok(v) => { io.println("panic caught: false") }
        err(e) => { io.println("panic caught: {e.kind == "panic"}") }
    }
    io.println("panic deferred: {after_panic.before_panic == 0}")
    cycles(after_panic, 24000)
    io.println("panic collection resumed: {after_panic.observed > 0}")
    io.println("panic tears: {after_panic.torn}")
    // The main thread remains live, so this exercises the owner-local
    // collector and its TLS gate, not the global quiescent collector.
    let worker: Thread<bool> = thread.spawn(fn() -> bool { return isolated_worker() })
    let returned: bool = worker.join()
    // Interpreter graphs can cross the shared walker, so require collection
    // after quiescence rather than pretending every candidate is owner-local.
    let final_state: State = new State()
    cycles(final_state, 24000)
    io.println("worker region: {returned && final_state.observed > 0 && final_state.torn == 0}")
}
