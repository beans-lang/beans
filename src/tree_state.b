package main

class TreeMemory {
    base: u64
    data: Bytes
    alignment: int
    freed: bool
    atomic_guard: Mutex<bool>

    fn init(base: u64, size: int, alignment: int) {
        self.base = base
        self.data = new Bytes(size)
        self.alignment = alignment
        self.freed = false
        self.atomic_guard = new Mutex(false)
    }
}

// C cannot dereference the interpreter's synthetic addresses. An extern call
// gets a real host allocation for each distinct represented allocation, then
// mutations are copied back before the host allocation is released.
class TreeFfiMemory {
    memory: TreeMemory
    host: RawPtr<u8>
    element: HirType

    fn init(memory: TreeMemory, host: RawPtr<u8>,
            element: HirType) {
        self.memory = memory
        self.host = host
        self.element = element
    }
}

class TreeReflectField {
    field: HirField
    owner: string

    fn init(field: HirField, owner: string) {
        self.field = field
        self.owner = owner
    }
}

class TreeReflectMethod {
    callable: HirFunction
    owner: string

    fn init(callable: HirFunction, owner: string) {
        self.callable = callable
        self.owner = owner
    }
}

class TreeReflectAnnotationValue {
    name: string
    type: HirType
    value: HirNode

    fn init(name: string, type: HirType, value: HirNode) {
        self.name = name
        self.type = type
        self.value = value
    }
}

class TreeMutexCell {
    value: TreeValue
    waiters: List<Channel<int>>

    fn init(value: TreeValue) {
        self.value = value
        self.waiters = []
    }
}

// One interpreted channel: the buffered values plus the parked senders and
// receivers, all behind one Mutex. Waiters park on their own one-slot signal
// channel, so the try halves can answer without ever joining the queue.
class TreeChannelState {
    values: List<TreeValue>
    capacity: int
    closed: bool
    send_waiters: List<Channel<int>>
    receive_waiters: List<Channel<int>>

    fn init(capacity: int) {
        self.values = []
        self.capacity = if capacity > 0 { capacity } else { 1 }
        self.closed = false
        self.send_waiters = []
        self.receive_waiters = []
    }
}

class TreeSingletonState {
    values: Map<string, TreeValue>
    static_values: Map<string, TreeValue>

    fn init() {
        self.values = {}
        self.static_values = {}
    }
}

// These two boxes cross host threads only behind Mutex. Their callers also
// keep the owning interpreter stopped while the foreign call runs.
unique class TreeThreadWork implements Send {
    program: HirProgram
    closure: TreeValue
    node: HirNode
    singletons: TreeSingletonState
    result: Option<TreeValue>
    failed: bool
    panic_text: string

    fn init(program: HirProgram,
            closure: TreeValue, node: HirNode,
            singletons: TreeSingletonState) {
        self.program = program
        self.closure = closure
        self.node = node
        self.singletons = singletons
        self.result = none
        self.failed = false
        self.panic_text = ""
    }

    fn run() {
        let interpreter: TreeInterpreter =
            new TreeInterpreter(self.program, [])
        interpreter.singletons = self.singletons
        self.result =
            some(interpreter.invoke_closure(
                self.node, self.closure, []))
        self.failed = interpreter.failed
        self.panic_text = interpreter.panic_text
    }
}

// One brewed fiber's interpreter-side record (spec/CONCURRENCY.md). The C
// fiber core only schedules the stack; every outcome fact lives here at
// tree level: run() contains an interpreted panic before the walker's
// failed flag could cross a park, and join or the scope join read the
// answer back out. A plain aliased class on purpose — every touch is on
// the one worker thread (the entry rides a LocalStoredCallback), and a
// lock here would be held across the child's parks: the first parked
// child would deadlock its own join.
class TreeBrewState {
    owner: TreeInterpreter
    closure: TreeValue
    node: HirNode
    fiber: u64
    // The BStoredCallback record behind the fiber's entry, closed by
    // address at the reap — the Beans-level handle is trivial and cannot
    // be closed through a borrowed field.
    entry_context: u64
    done: bool
    panicked: bool
    // The child observed a cancel at a park and left through it, so its
    // frame never returned: no result, no panic message, just the ending.
    cancelled: bool
    panic_message: string
    result: Option<TreeValue>
    joined: bool
    reaped: bool
    // TaskGroup rows only: the group clock's completion order, 0 while
    // the child still runs. Stamped by the group entry's tail — an
    // interpreted panic still returns through run(), so a panicked child
    // gets its stamp too, exactly like native's fiber done hook.
    done_stamp: int

    fn init(owner: TreeInterpreter,
            closure: TreeValue, node: HirNode) {
        self.owner = owner
        self.closure = closure
        self.node = node
        self.fiber = 0
        self.entry_context = 0
        self.done = false
        self.panicked = false
        self.cancelled = false
        self.panic_message = ""
        self.result = none
        self.joined = false
        self.reaped = false
        self.done_stamp = 0
    }

    fn run() {
        // This runs on the child's own fiber, so the walker's per-fiber
        // unwind entry it reads and writes is this fiber's alone: an outer
        // fiber parked mid-unwind inside a defer or a deinit keeps its own
        // entry untouched, however many siblings finish or panic while it
        // waits — the same thing the native runtime's per-fiber
        // unwind_status gives it.
        let value: TreeValue =
            self.owner.invoke_closure(
                self.node, self.closure, [])
        if self.owner.failed {
            // The body panicked and its frames have already unwound to here —
            // the fiber entry, where a contained unwind ends: defers ran and
            // owned locals dropped on the way up. Deliver the failure to the
            // join and put the interpreter back to a running state.
            self.panicked = true
            self.panic_message = self.owner.panic_text
            self.owner.failed = false
            self.owner.panic_text = ""
        } else {
            self.result = some(value)
        }
        self.owner.end_unwind()
        self.done = true
    }
}

// One fleet's interpreter-side record (spec/CONCURRENCY.md, F3). The
// children reuse TreeBrewState rows; delivery order is their done_stamp
// under this clock, and a joined row counts as delivered. A plain aliased
// class for the same reason TreeBrewState is: everything runs on the one
// worker thread, and a lock would be held across the waiter's parks.
class TreeTaskGroupState {
    children: List<TreeBrewState>
    delivered: int
    clock: int
    waiter: u64 // parked next()/wait_all fiber address, or 0

    fn init() {
        self.children = []
        self.delivered = 0
        self.clock = 0
        self.waiter = 0
    }
}

unique class TreeStoredState implements Send {
    owner: TreeInterpreter
    function: HirFunction
    callable: TreeValue
    parameters: List<HirType>
    result: HirType

    fn init(owner: TreeInterpreter,
            function: HirFunction,
            callable: TreeValue,
            move parameters: List<HirType>,
            result: HirType) {
        self.owner = owner
        self.function = function
        self.callable = callable
        self.parameters = move parameters
        self.result = result
    }
}

class TreeStoredCallback {
    context: RawPtr<u8>
    function: int
    state: Mutex<TreeStoredState>

    fn init(context: RawPtr<u8>,
            function: int,
            state: Mutex<TreeStoredState>) {
        self.context = context
        self.function = function
        self.state = state
    }
}

// One registered defer: the expression and the scope frame it was
// registered in. The frame reference keeps that scope's locals alive past
// the block's pop, so a defer inside a nested block (or a brew's
// synthesized scope join) still sees its bindings at function exit — the
// same thing native's stack slots give for free. The back-reference makes
// a frame cycle; the collector owns those.
class TreeDeferred {
    expression: HirNode
    frame: TreeFrame

    fn init(expression: HirNode, frame: TreeFrame) {
        self.expression = expression
        self.frame = frame
    }
}

class TreeFrame {
    values: Map<int, TreeValue>
    defers: List<TreeDeferred>
    parent: Option<TreeFrame>
    defer_owner: Option<TreeFrame>
    self_value: Option<TreeValue>

    fn init() {
        self.values = {}
        self.defers = []
        self.parent = none
        self.defer_owner = none
        self.self_value = none
    }

    // A captured frame is the lookup parent of a new function. Its defers must
    // not become the new function's defers.
    static fn captured(parent: TreeFrame) -> TreeFrame {
        let result: TreeFrame = new TreeFrame()
        result.parent = some(parent)
        return result
    }

    // A lexical scope shares the enclosing function's defer stack but owns its
    // locals. Dropping this frame is the represented block's cleanup point.
    //
    // It is the SAME function, so it has the same `self`. Without carrying it,
    // `super.method(...)` panicked with "has no self" anywhere but the top
    // level of a method body — inside an `if`, a block, a loop or a match arm
    // — while the native backend compiled all of them correctly.
    static fn scope(parent: TreeFrame) -> TreeFrame {
        let result: TreeFrame = new TreeFrame()
        result.parent = some(parent)
        result.self_value = parent.self_value
        match parent.defer_owner {
            some(owner) => {
                result.defer_owner = some(owner)
            }
            none => {
                result.defer_owner = some(parent)
            }
        }
        return result
    }

    fn add_defer(expression: HirNode, at: TreeFrame) {
        match self.defer_owner {
            some(owner) => {
                owner.add_defer(expression, at)
            }
            none => {
                self.defers.push(
                    new TreeDeferred(expression, at))
            }
        }
    }

    fn set(binding: int, value: TreeValue) {
        self.values[binding] = value
    }

    fn get(binding: int) -> Option<TreeValue> {
        match self.values.get(binding) {
            some(value) => { return some(value) }
            none => {}
        }
        match self.parent {
            some(outer) => {
                return outer.get(binding)
            }
            none => { return none }
        }
    }

    fn assign(binding: int,
              value: TreeValue) -> bool {
        if self.values.contains_key(binding) {
            let current: TreeValue =
                self.values[binding]
            if current.kind == "reference" {
                match current.reference_frame {
                    some(target) => {
                        return target.assign(
                            current.reference_binding,
                            value)
                    }
                    none => {}
                }
            }
            self.values[binding] = value
            return true
        }
        match self.parent {
            some(outer) => {
                return outer.assign(binding, value)
            }
            none => { return false }
        }
    }

    fn snapshot() -> TreeFrame {
        let result: TreeFrame = new TreeFrame()
        for binding: int in self.values.keys() {
            let current: TreeValue =
                self.values[binding]
            var captured: TreeValue = current
            if current.kind != "reference" {
                let holder: TreeFrame =
                    new TreeFrame()
                holder.values[-1] = current
                captured =
                    TreeValue.reference(
                        holder, -1)
                // The parent and the worker now share one stable binding
                // cell. Adding another parent local cannot resize the map
                // the worker reads.
                self.values[binding] =
                    captured
            }
            result.values[binding] = captured
        }
        result.self_value = self.self_value
        match self.parent {
            some(outer) => {
                result.parent =
                    some(outer.snapshot())
            }
            none => {}
        }
        return result
    }
}

class TreeExec {
    kind: string
    value: TreeValue

    fn init(kind: string, value: TreeValue) {
        self.kind = kind
        self.value = value
    }

    static fn next() -> TreeExec {
        return new TreeExec("next", TreeValue.unit())
    }

    static fn returned(value: TreeValue) -> TreeExec {
        return new TreeExec("return", value)
    }

    static fn stopped(kind: string) -> TreeExec {
        return new TreeExec(kind, TreeValue.unit())
    }
}

// What marks a generated bridge's entry point as exported.
//
// The Windows spelling is not a nicety. MSVC's linker exports exactly what a
// dllexport directive names, and a visibility attribute emits no directive at
// all, so a bridge DLL built for the MSVC ABI carries an empty export table
// and the load that follows cannot find beans_ffi_bridge in it. MinGW honours
// dllexport too, so one branch covers every Windows ABI. Everywhere else the
// visibility attribute is what keeps the entry point out of reach of
// -fvisibility=hidden.
fn ffi_export_attribute() -> string {
    var text: string = "#if defined(_WIN32)\n"
    text = "{text}__declspec(dllexport)\n"
    text = "{text}#else\n"
    text = "{text}__attribute__((visibility(\"default\")))\n"
    return "{text}#endif\n"
}
