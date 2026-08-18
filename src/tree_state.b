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

class TreeSingletonState {
    values: Map<string, TreeValue>
    static_values: Map<string, TreeValue>

    fn init() {
        self.values = {}
        self.static_values = {}
    }
}

class TreeThreadWork {
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

class TreeStoredState {
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

class TreeFrame {
    values: Map<int, TreeValue>
    defers: List<HirNode>
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
    static fn scope(parent: TreeFrame) -> TreeFrame {
        let result: TreeFrame = new TreeFrame()
        result.parent = some(parent)
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

    fn add_defer(expression: HirNode) {
        match self.defer_owner {
            some(owner) => {
                owner.add_defer(expression)
            }
            none => {
                self.defers.push(expression)
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
