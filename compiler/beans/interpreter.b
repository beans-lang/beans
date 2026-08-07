package main

import std.io
import std.c as host_c
import std.cpu as host_cpu
import std.dl as host_dl
import std.fmt as host_fmt
import std.fs as host_fs
import std.intrinsic as host_intrinsic
import std.os as host_os
import std.proc as host_proc
import std.random as host_random
import std.ready as host_ready
import std.sig as host_sig
import std.sock as host_sock
import std.thread as host_thread
import std.time as host_time

extern "C" fn beans_tree_ffi_invoke_bridge(
    bridge: RawPtr<u8>,
    symbol: RawPtr<u8>,
    result: RawPtr<u8>,
    arguments: RawPtr<RawPtr<u8> >,
    dispatch: fn(RawPtr<u8>, RawPtr<u8>,
                 RawPtr<RawPtr<u8> >),
    contexts: RawPtr<RawPtr<u8> >)
extern "C" fn beans_tree_stored_close(
    value: RawPtr<u8>)

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

class TreeValue {
    kind: string
    bool_data: bool
    int_data: int
    uint_data: u64
    int_bits: int
    int_unsigned: bool
    float_data: float
    decimal_data: decimal
    bytes_data: Option<Bytes>
    text: string
    items: List<TreeValue>
    fields: Map<string, TreeValue>
    map_keys: List<TreeValue>
    map_values: Map<string, TreeValue>
    object_id: int
    closure_node: Option<HirNode>
    closure_frame: Option<TreeFrame>
    reference_frame: Option<TreeFrame>
    reference_binding: int
    memory: Option<TreeMemory>
    memory_address: u64
    memory_host: bool
    memory_type: Option<HirType>
    slice_len: int
    shared_value: Option<Shared<TreeValue>>
    weak_value: Option<Weak<TreeValue>>
    file_value: Option<File>
    mmap_value: Option<MMap>
    mutex_cell:
        Option<Mutex<TreeMutexCell>>
    channel_value:
        Option<Channel<Mutex<TreeMutexCell>>>
    thread_handle: Option<Thread<int>>
    thread_work:
        Option<Mutex<TreeThreadWork>>

    fn init(kind: string) {
        self.kind = kind
        self.bool_data = false
        self.int_data = 0
        self.uint_data = 0
        self.int_bits = 64
        self.int_unsigned = false
        self.float_data = 0.0
        self.decimal_data = 0.0
        self.bytes_data = none
        self.text = ""
        self.items = []
        self.fields = {}
        self.map_keys = []
        self.map_values = {}
        self.object_id = -1
        self.closure_node = none
        self.closure_frame = none
        self.reference_frame = none
        self.reference_binding = -1
        self.memory = none
        self.memory_address = 0
        self.memory_host = false
        self.memory_type = none
        self.slice_len = 0
        self.shared_value = none
        self.weak_value = none
        self.file_value = none
        self.mmap_value = none
        self.mutex_cell = none
        self.channel_value = none
        self.thread_handle = none
        self.thread_work = none
    }

    static fn unit() -> TreeValue {
        return new TreeValue("unit")
    }

    static fn boolean(value: bool) -> TreeValue {
        let result: TreeValue = new TreeValue("bool")
        result.bool_data = value
        return result
    }

    static fn integer(value: int) -> TreeValue {
        let result: TreeValue = new TreeValue("int")
        result.int_data = value
        result.uint_data = value as u64
        return result
    }

    static fn unsigned_integer(
        value: u64, bits: int) -> TreeValue {
        let result: TreeValue = new TreeValue("int")
        result.uint_data =
            tree_mask_unsigned(value, bits)
        result.int_data =
            tree_signed_from_bits(
                result.uint_data, bits)
        result.int_bits = bits
        result.int_unsigned = true
        return result
    }

    static fn signed_integer(
        value: int, bits: int) -> TreeValue {
        return TreeValue.signed_integer_bits(
            value as u64, bits)
    }

    static fn signed_integer_bits(
        value: u64, bits: int) -> TreeValue {
        let result: TreeValue = new TreeValue("int")
        result.uint_data =
            tree_mask_unsigned(value, bits)
        result.int_data =
            tree_signed_from_bits(
                result.uint_data, bits)
        result.int_bits = bits
        return result
    }

    static fn floating(value: float) -> TreeValue {
        let result: TreeValue = new TreeValue("float")
        result.float_data = value
        return result
    }

    static fn decimal_value(value: decimal) -> TreeValue {
        let result: TreeValue =
            new TreeValue("decimal")
        result.decimal_data = value
        return result
    }

    static fn string(value: string) -> TreeValue {
        let result: TreeValue = new TreeValue("string")
        result.text = value
        return result
    }

    static fn bytes(value: Bytes) -> TreeValue {
        let result: TreeValue = new TreeValue("bytes")
        result.bytes_data = some(value)
        return result
    }

    static fn sequence(kind: string,
                       values: List<TreeValue>) -> TreeValue {
        let result: TreeValue = new TreeValue(kind)
        for value: TreeValue in values {
            result.items.push(value)
        }
        return result
    }

    static fn option_some(value: TreeValue) -> TreeValue {
        return TreeValue.sequence("some", [value])
    }

    static fn option_none() -> TreeValue {
        return new TreeValue("none")
    }

    static fn result_ok(value: TreeValue) -> TreeValue {
        return TreeValue.sequence("ok", [value])
    }

    static fn result_err(value: TreeValue) -> TreeValue {
        return TreeValue.sequence("err", [value])
    }

    static fn error(message: string,
                    kind: string) -> TreeValue {
        let result: TreeValue =
            new TreeValue("error")
        result.text = "Error"
        result.fields["msg"] =
            TreeValue.string(message)
        result.fields["kind"] =
            TreeValue.string(kind)
        return result
    }

    static fn propagation(value: TreeValue) -> TreeValue {
        return TreeValue.sequence(
            "propagate", [value])
    }

    static fn reference(frame: TreeFrame,
                        binding: int) -> TreeValue {
        let result: TreeValue =
            new TreeValue("reference")
        result.reference_frame = some(frame)
        result.reference_binding = binding
        return result
    }

    static fn raw_pointer(
        memory: Option<TreeMemory>,
        address: u64, type: HirType) -> TreeValue {
        let result: TreeValue =
            new TreeValue("raw_ptr")
        result.memory = memory
        result.memory_address = address
        result.memory_type = some(type)
        return result
    }

    static fn host_pointer(
        address: u64, type: HirType) -> TreeValue {
        let result: TreeValue =
            TreeValue.raw_pointer(
                none, address, type)
        result.memory_host = address != 0
        return result
    }

    static fn slice(
        pointer: TreeValue,
        length: int) -> TreeValue {
        let result: TreeValue =
            new TreeValue("slice")
        result.memory = pointer.memory
        result.memory_address =
            pointer.memory_address
        result.memory_host = pointer.memory_host
        result.memory_type =
            pointer.memory_type
        result.slice_len = length
        return result
    }

    static fn file(value: File) -> TreeValue {
        let result: TreeValue =
            new TreeValue("file")
        result.file_value = some(value)
        return result
    }

    static fn mmap(value: MMap) -> TreeValue {
        let result: TreeValue =
            new TreeValue("mmap")
        result.mmap_value = some(value)
        return result
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

class TreeThreadWork {
    program: HirProgram
    closure: TreeValue
    node: HirNode
    result: Option<TreeValue>
    failed: bool
    panic_text: string

    fn init(program: HirProgram,
            closure: TreeValue, node: HirNode) {
        self.program = program
        self.closure = closure
        self.node = node
        self.result = none
        self.failed = false
        self.panic_text = ""
    }

    fn run() {
        let interpreter: TreeInterpreter =
            new TreeInterpreter(self.program, [])
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

// Only represented class objects pay for a host-level deinit. The native
// TreeObjectValue lifetime is the represented object's reference count: aliases
// and containers keep the same wrapper alive, and a native reference cycle
// skips this hook just like a Beans program cycle skips its own deinit.
class TreeObjectValue extends TreeValue {
    interpreter: TreeInterpreter
    deinit_active: bool

    fn init(interpreter: TreeInterpreter) {
        self.interpreter = interpreter
        self.deinit_active = true
        super.init("object")
    }

    fn deinit() {
        if self.deinit_active {
            self.deinit_active = false
            self.interpreter.deinit_object(self)
        }
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

class TreeFormatSpec {
    has: bool
    width: int
    places: int
    left: bool

    fn init() {
        self.has = false
        self.width = 0
        self.places = -1
        self.left = false
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

fn tree_unquote(source: string) -> string {
    var start: int = 0
    var end: int = source.len()
    if source.len() >= 2 &&
       source.starts_with("\"") &&
       source.ends_with("\"") {
        start = 1
        end -= 1
    }
    var result: string = ""
    var index: int = start
    for index < end {
        let byte: int = source.byte_at(index)
        if byte != 92 || index + 1 >= end {
            result =
                "{result}{source.slice(index, index + 1)}"
            index += 1
            continue
        }
        let escaped: int = source.byte_at(index + 1)
        if escaped == 110 {
            result = "{result}\n"
        } else if escaped == 114 {
            result = "{result}\r"
        } else if escaped == 116 {
            result = "{result}\t"
        } else {
            result =
                "{result}{source.slice(index + 1, index + 2)}"
        }
        index += 2
    }
    return result
}

fn tree_format_spec(segment: string) -> TreeFormatSpec {
    let result: TreeFormatSpec =
        new TreeFormatSpec()
    var depth: int = 0
    var in_string: bool = false
    var colon: int = -1
    var index: int = 0
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte == 92 {
            index += 2
            continue
        }
        if in_string {
            if byte == 34 { in_string = false }
            index += 1
            continue
        }
        if byte == 34 {
            in_string = true
        } else if byte == 40 || byte == 91 ||
                  byte == 123 {
            depth += 1
        } else if byte == 41 || byte == 93 ||
                  byte == 125 {
            depth -= 1
        } else if byte == 58 && depth == 0 {
            colon = index
            break
        }
        index += 1
    }
    if colon < 0 { return result }

    result.has = true
    index = colon + 1
    if index < segment.len() &&
       segment.byte_at(index) == 45 {
        result.left = true
        index += 1
    }
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte < 48 || byte > 57 { break }
        result.width =
            result.width * 10 + byte - 48
        index += 1
    }
    if index < segment.len() &&
       segment.byte_at(index) == 46 {
        result.places = 0
        index += 1
        for index < segment.len() {
            let byte: int = segment.byte_at(index)
            if byte < 48 || byte > 57 { break }
            result.places =
                result.places * 10 + byte - 48
            index += 1
        }
    }
    return result
}

fn tree_float_bits(value: float, bits: int) -> u64 {
    unsafe {
        if bits == 32 {
            let number: RawPtr<f32> =
                RawPtr.alloc(1)
            number.write(value as f32)
            let raw: RawPtr<u32> =
                RawPtr.from_address(number.address())
            let result: u64 = raw.read() as u64
            number.free()
            return result
        }
        let number: RawPtr<f64> =
            RawPtr.alloc(1)
        number.write(value)
        let raw: RawPtr<u64> =
            RawPtr.from_address(number.address())
        let result: u64 = raw.read()
        number.free()
        return result
    }
}

fn tree_float_from_bits(value: u64,
                        bits: int) -> float {
    unsafe {
        if bits == 32 {
            let raw: RawPtr<u32> =
                RawPtr.alloc(1)
            raw.write(value as u32)
            let number: RawPtr<f32> =
                RawPtr.from_address(raw.address())
            let result: float =
                number.read() as float
            raw.free()
            return result
        }
        let raw: RawPtr<u64> =
            RawPtr.alloc(1)
        raw.write(value)
        let number: RawPtr<f64> =
            RawPtr.from_address(raw.address())
        let result: float = number.read()
        raw.free()
        return result
    }
}

fn tree_integer_bits(name: string) -> int {
    let clean: string = canonical_hir_name(name)
    if clean == "i8" || clean == "u8" {
        return 8
    }
    if clean == "i16" || clean == "u16" {
        return 16
    }
    if clean == "i32" || clean == "u32" {
        return 32
    }
    return 64
}

fn tree_integer_unsigned(name: string) -> bool {
    let clean: string = canonical_hir_name(name)
    return clean == "u8" || clean == "u16" ||
           clean == "u32" || clean == "u64"
}

fn tree_mask_unsigned(value: u64,
                      bits: int) -> u64 {
    if bits >= 64 { return value }
    return value & (((1 as u64) << (bits as u64)) - 1)
}

fn tree_signed_from_bits(value: u64,
                         bits: int) -> int {
    let narrowed: u64 =
        tree_mask_unsigned(value, bits)
    if bits >= 64 {
        if narrowed <=
           (9223372036854775807 as u64) {
            return narrowed as int
        }
        return -1 - ((~narrowed) as int)
    }
    let sign: u64 =
        (1 as u64) << ((bits - 1) as u64)
    if (narrowed & sign) != 0 {
        let mask: u64 =
            ((1 as u64) << (bits as u64)) - 1
        let extended: u64 =
            narrowed | ~mask
        return -1 - ((~extended) as int)
    }
    return narrowed as int
}

fn tree_parse_unsigned(source: string) -> u64 {
    let clean: string = source.replace("_", "")
    var base: u64 = 10
    var index: int = 0
    if clean.starts_with("0x") ||
       clean.starts_with("0X") {
        base = 16
        index = 2
    } else if clean.starts_with("0b") ||
              clean.starts_with("0B") {
        base = 2
        index = 2
    }
    var value: u64 = 0
    for index < clean.len() {
        let byte: int = clean.byte_at(index)
        var digit: u64 = 0
        if byte >= 48 && byte <= 57 {
            digit = (byte - 48) as u64
        } else if byte >= 97 && byte <= 102 {
            digit = (byte - 87) as u64
        } else if byte >= 65 && byte <= 70 {
            digit = (byte - 55) as u64
        }
        value = value * base + digit
        index += 1
    }
    return value
}

fn tree_crc32c_step(initial: int, input: int) -> int {
    var crc: u32 = initial as u32
    let value: u64 = input as u64
    let polynomial: u32 = 0x82f63b78
    for byte: int in 0..8 {
        crc = crc ^ (((value >> ((byte * 8) as u64)) &
                      (0xff as u64)) as u32)
        for bit: int in 0..8 {
            crc =
                (crc >> (1 as u32)) ^
                (polynomial &
                 ((0 as u32) - (crc & (1 as u32))))
        }
    }
    return crc as int
}

fn tree_simd_lanes(name: string) -> int {
    if !name.starts_with("Simd") {
        return 0
    }
    var index: int = 4
    var lanes: int = 0
    for index < name.len() {
        let byte: int = name.byte_at(index)
        if byte < 48 || byte > 57 { break }
        lanes = lanes * 10 + byte - 48
        index += 1
    }
    return lanes
}

fn tree_simd_element(name: string) -> string {
    var index: int = 4
    for index < name.len() {
        let byte: int = name.byte_at(index)
        if byte < 48 || byte > 57 { break }
        index += 1
    }
    return name.slice(index, name.len())
}

fn tree_value_text(value: TreeValue) -> string {
    if value.kind == "unit" { return "()" }
    if value.kind == "bool" {
        return if value.bool_data { "true" } else { "false" }
    }
    if value.kind == "int" {
        return if value.int_unsigned {
            "{value.uint_data}"
        } else {
            "{value.int_data}"
        }
    }
    if value.kind == "float" {
        return "{value.float_data}"
    }
    if value.kind == "decimal" {
        return "{value.decimal_data}"
    }
    if value.kind == "string" {
        return value.text
    }
    if value.kind == "none" { return "none" }
    if value.kind == "some" && value.items.len() == 1 {
        return "some({tree_value_text(value.items[0])})"
    }
    if value.kind == "ok" && value.items.len() == 1 {
        return "ok({tree_value_text(value.items[0])})"
    }
    if value.kind == "err" && value.items.len() == 1 {
        return "err({tree_value_text(value.items[0])})"
    }
    if value.kind == "list" || value.kind == "array" {
        var pieces: List<string> = []
        for item: TreeValue in value.items {
            pieces.push(tree_value_text(item))
        }
        return "[{pieces.join(", ")}]"
    }
    if value.kind == "map" {
        var pieces: List<string> = []
        for key: TreeValue in value.map_keys {
            let encoded: string = tree_value_key(key)
            match value.map_values.get(encoded) {
                some(item) => {
                    pieces.push(
                        "{tree_value_text(key)}: {tree_value_text(item)}")
                }
                none => {}
            }
        }
        return "\{{pieces.join(", ")}\}"
    }
    if value.kind == "variant" {
        if value.items.len() == 0 {
            return value.text
        }
        var payload: List<string> = []
        for item: TreeValue in value.items {
            payload.push(tree_value_text(item))
        }
        return "{value.text}({payload.join(", ")})"
    }
    if value.kind == "closure" {
        return "<fn>"
    }
    if value.kind == "object" {
        return value.text
    }
    if value.kind == "raw_ptr" {
        return "RawPtr({value.memory_address})"
    }
    if value.kind == "slice" {
        return "Slice(len={value.slice_len})"
    }
    if value.kind == "error" {
        return "Error"
    }
    return "<{value.kind}>"
}

fn tree_value_key(value: TreeValue) -> string {
    if value.kind == "string" {
        return "s:{value.text}"
    }
    if value.kind == "int" {
        return if value.int_unsigned {
            "u{value.int_bits}:{value.uint_data}"
        } else {
            "i{value.int_bits}:{value.int_data}"
        }
    }
    if value.kind == "bool" {
        return if value.bool_data { "b:1" } else { "b:0" }
    }
    if value.kind == "float" {
        return "f:{value.float_data}"
    }
    if value.kind == "decimal" {
        return "d:{value.decimal_data}"
    }
    if value.kind == "object" {
        return "o:{value.object_id}"
    }
    if value.kind == "record" {
        var names: List<string> =
            value.fields.keys()
        names.sort()
        var result: string =
            "r:{value.text.len()}:{value.text}"
        for name: string in names {
            let field_key: string =
                tree_value_key(value.fields[name])
            result =
                "{result}:{name.len()}:{name}:{field_key.len()}:{field_key}"
        }
        return result
    }
    if value.kind == "variant" ||
       value.kind == "some" ||
       value.kind == "ok" ||
       value.kind == "err" {
        var result: string =
            "v:{value.kind.len()}:{value.kind}:{value.text.len()}:{value.text}"
        for item: TreeValue in value.items {
            let item_key: string =
                tree_value_key(item)
            result =
                "{result}:{item_key.len()}:{item_key}"
        }
        return result
    }
    return "{value.kind}:{tree_value_text(value)}"
}

fn tree_value_equal(left: TreeValue,
                    right: TreeValue) -> bool {
    if left.kind != right.kind { return false }
    if left.kind == "unit" ||
       left.kind == "none" {
        return true
    }
    if left.kind == "bool" {
        return left.bool_data == right.bool_data
    }
    if left.kind == "int" {
        if left.int_unsigned ||
           right.int_unsigned {
            return left.uint_data ==
                   right.uint_data
        }
        return left.int_data == right.int_data
    }
    if left.kind == "float" {
        return left.float_data == right.float_data
    }
    if left.kind == "decimal" {
        return left.decimal_data ==
               right.decimal_data
    }
    if left.kind == "string" {
        return left.text == right.text
    }
    if left.kind == "bytes" {
        match left.bytes_data {
            some(left_bytes) => {
                match right.bytes_data {
                    some(right_bytes) => {
                        return left_bytes ==
                               right_bytes
                    }
                    none => {}
                }
            }
            none => {}
        }
        return false
    }
    if left.kind == "object" ||
       left.kind == "closure" {
        return left.object_id == right.object_id
    }
    if left.kind == "raw_ptr" {
        return left.memory_address ==
               right.memory_address
    }
    if left.kind == "slice" {
        return left.memory_address ==
                   right.memory_address &&
               left.slice_len == right.slice_len
    }
    if left.kind == "record" {
        if left.text != right.text ||
           left.fields.len() != right.fields.len() {
            return false
        }
        for name: string in left.fields.keys() {
            match right.fields.get(name) {
                some(value) => {
                    if !tree_value_equal(
                           left.fields[name], value) {
                        return false
                    }
                }
                none => { return false }
            }
        }
        return true
    }
    if left.kind == "variant" &&
       left.text != right.text {
        return false
    }
    if left.kind == "simd" &&
       left.text != right.text {
        return false
    }
    if left.kind == "variant" ||
       left.kind == "some" ||
       left.kind == "ok" ||
       left.kind == "err" ||
       left.kind == "list" ||
       left.kind == "array" ||
       left.kind == "simd" ||
       left.kind == "range" {
        if left.items.len() != right.items.len() {
            return false
        }
        for index: int in 0..left.items.len() {
            if !tree_value_equal(
                   left.items[index],
                   right.items[index]) {
                return false
            }
        }
        return true
    }
    return false
}

fn tree_value_less(left: TreeValue,
                   right: TreeValue) -> bool {
    if left.kind == "int" &&
       right.kind == "int" {
        if left.int_unsigned ||
           right.int_unsigned {
            return left.uint_data <
                   right.uint_data
        }
        return left.int_data < right.int_data
    }
    if left.kind == "float" &&
       right.kind == "float" {
        return left.float_data < right.float_data
    }
    if left.kind == "decimal" &&
       right.kind == "decimal" {
        return left.decimal_data <
               right.decimal_data
    }
    if left.kind == "string" &&
       right.kind == "string" {
        return left.text < right.text
    }
    if left.kind == "bool" &&
       right.kind == "bool" {
        return !left.bool_data &&
               right.bool_data
    }
    return false
}

// TreeValue is a host class so reference-shaped values can alias. Beans
// records, fixed arrays and inline enums are values, however, and must receive
// an independent wrapper whenever source semantics copy them.
fn tree_value_copy(value: TreeValue) -> TreeValue {
    if value.kind == "record" {
        let result: TreeValue =
            new TreeValue("record")
        result.text = value.text
        result.object_id = value.object_id
        match value.bytes_data {
            some(data) => {
                result.bytes_data =
                    some(data.slice(0, data.len()))
            }
            none => {}
        }
        for name: string in value.fields.keys() {
            result.fields[name] =
                tree_value_copy(value.fields[name])
        }
        return result
    }
    if value.kind == "array" ||
       value.kind == "simd" ||
       value.kind == "variant" ||
       value.kind == "some" ||
       value.kind == "ok" ||
       value.kind == "err" {
        var items: List<TreeValue> = []
        for item: TreeValue in value.items {
            items.push(tree_value_copy(item))
        }
        let result: TreeValue =
            TreeValue.sequence(
                value.kind, move items)
        result.text = value.text
        result.bool_data = value.bool_data
        return result
    }
    return value
}

fn tree_spawn_closure(value: TreeValue) -> TreeValue {
    let result: TreeValue =
        new TreeValue(value.kind)
    result.text = value.text
    result.closure_node = value.closure_node
    match value.closure_frame {
        some(frame) => {
            result.closure_frame =
                some(frame.snapshot())
        }
        none => {}
    }
    return result
}

fn tree_parse_int(source: string) -> int {
    let clean: string = source.replace("_", "")
    if clean.starts_with("0x") ||
       clean.starts_with("0X") ||
       clean.starts_with("0b") ||
       clean.starts_with("0B") {
        return tree_signed_from_bits(
            tree_parse_unsigned(clean), 64)
    }
    if clean.starts_with("-0x") ||
       clean.starts_with("-0X") ||
       clean.starts_with("-0b") ||
       clean.starts_with("-0B") {
        return tree_signed_from_bits(
            (0 as u64) -
                tree_parse_unsigned(
                    clean.slice(1, clean.len())),
            64)
    }
    match clean.to_int() {
        ok(value) => { return value }
        err(error) => {
            // The magnitude of int.min is one larger than int.max.
            // The checker only permits it below unary minus; parsing its
            // bits here lets that negation wrap to the one valid value.
            return tree_signed_from_bits(
                tree_parse_unsigned(clean), 64)
        }
    }
}

class TreeInterpreter {
    program: HirProgram
    arguments: List<string>
    failed: bool
    panic_text: string
    next_object_id: int
    memories: List<TreeMemory>
    next_memory_address: u64
    ffi_bridge_addresses: Map<string, int>
    ffi_bridge_handles: List<int>
    ffi_bridge_sequence: int
    encoding_handles: Map<string, int>
    encoding_error: string
    stored_callbacks: Map<int, TreeStoredCallback>
    // Set only by `beansc debug-adapter`. When present, every statement asks
    // it whether to stop, every call tells it about the frame, and the
    // program's own output is forwarded to the client instead of being
    // written to the protocol stream.
    debugger: Option<DebugSession>

    fn init(program: HirProgram,
            move arguments: List<string>) {
        self.program = program
        self.arguments = move arguments
        self.failed = false
        self.panic_text = ""
        self.next_object_id = 0
        self.memories = []
        self.next_memory_address = 1048576
        self.ffi_bridge_addresses = {}
        self.ffi_bridge_handles = []
        self.ffi_bridge_sequence = 0
        self.encoding_handles = {}
        self.encoding_error = ""
        self.stored_callbacks = {}
        self.debugger = none
    }

    fn fail(node: HirNode, message: string) -> TreeValue {
        return self.fail_at(
            node, node.col, message)
    }

    fn fail_at(node: HirNode, col: int,
               message: string) -> TreeValue {
        if !self.failed {
            self.failed = true
            self.panic_text =
                "runtime panic at {node.line}:{col}: {message}"
            // Stop with the frames still standing, so a person can see what
            // the program was doing when it failed.
            match self.debugger {
                some(session) => {
                    session.at_panic(self.panic_text)
                }
                none => {}
            }
        }
        return TreeValue.unit()
    }

    fn floating_value(type: HirType,
                      value: float) -> TreeValue {
        if canonical_hir_name(type.name) == "f32" {
            let narrow: f32 = value as f32
            return TreeValue.floating(
                narrow as float)
        }
        return TreeValue.floating(value)
    }

    fn decimal_binary_value(
        node: HirNode, operation: string,
        left: decimal, right: decimal) -> TreeValue {
        let zero: decimal = 0.0
        let one: decimal = 1.0
        let maximum: decimal =
            99999999999999999999999999999999999999
        let minimum: decimal = -maximum
        if operation == "+" {
            if (right > zero &&
                left > maximum - right) ||
               (right < zero &&
                left < minimum - right) {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left + right)
        }
        if operation == "-" {
            if (right > zero &&
                left < minimum + right) ||
               (right < zero &&
                left > maximum + right) {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left - right)
        }
        if operation == "*" {
            let left_magnitude: decimal = left.abs()
            let right_magnitude: decimal = right.abs()
            var product_limit: decimal = maximum
            if right_magnitude >= one {
                product_limit =
                    maximum / right_magnitude
            }
            if right_magnitude >= one &&
               left_magnitude > product_limit {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left * right)
        }
        if operation == "/" {
            let right_magnitude: decimal = right.abs()
            if right_magnitude == zero {
                return self.fail(
                    node, "divide by zero")
            }
            var quotient_limit: decimal = maximum
            if right_magnitude < one {
                quotient_limit =
                    maximum * right_magnitude
            }
            if right_magnitude < one &&
               left.abs() > quotient_limit {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left / right)
        }
        return self.fail(
            node,
            "decimal operator '{operation}' is not in the Beans interpreter yet")
    }

    fn find_function(name: string) -> Option<HirFunction> {
        for function: HirFunction in self.program.functions {
            if function.qualified == name {
                return some(function)
            }
        }
        for function: HirFunction in self.program.functions {
            if function.owner == "" &&
               function.name == name {
                return some(function)
            }
        }
        return none
    }

    fn declaration(name: string) ->
        Option<HirDeclaration> {
        // Exact qualified matches first: a dependency's class may share its
        // short name with one from the root package (user Task beside
        // std.async's Task), and the short-name fallback must not let
        // whichever loaded first shadow the other.
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.qualified == name {
                return some(declaration)
            }
        }
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.name == name {
                return some(declaration)
            }
        }
        return none
    }

    fn c_global(name: string) ->
        Option<HirCGlobal> {
        for global: HirCGlobal in
            self.program.c_globals {
            if global.qualified == name ||
               global.name == name {
                return some(global)
            }
        }
        return none
    }

    fn c_global_address(node: HirNode,
                        global: HirCGlobal) -> int {
        if global.is_thread_local {
            var source: string =
                "#include <stdint.h>\n"
            source =
                "{source}extern _Thread_local unsigned char {global.extern_name};\n"
            source =
                "{source}{ffi_export_attribute()}"
            source =
                "{source}void* beans_ffi_bridge(void) \{ return &{global.extern_name}; \}\n"
            let function: HirFunction =
                new HirFunction(
                    global.name, global.qualified, "",
                    false, node.file, node.line, node.col)
            let bridge: int =
                self.ffi_bridge(function, source)
            if self.failed { return 0 }
            unsafe {
                return host_dl.call0(bridge)
            }
        }
        match host_dl.global_symbol(
                  global.extern_name) {
            ok(found) => { return found }
            err(error) => {
                self.fail(
                    node,
                    "C symbol not found: {global.extern_name}")
                return 0
            }
        }
    }

    fn read_c_global(node: HirNode,
                     global: HirCGlobal) -> TreeValue {
        let address: int =
            self.c_global_address(node, global)
        if self.failed { return TreeValue.unit() }
        let name: string =
            canonical_hir_name(global.type.name)
        unsafe {
            if name == "i8" {
                let pointer: RawPtr<i8> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.signed_integer(
                    pointer.read() as int, 8)
            }
            if name == "i16" {
                let pointer: RawPtr<i16> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.signed_integer(
                    pointer.read() as int, 16)
            }
            if name == "i32" {
                let pointer: RawPtr<i32> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.signed_integer(
                    pointer.read() as int, 32)
            }
            if name == "int" {
                let pointer: RawPtr<i64> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.integer(
                    pointer.read() as int)
            }
            if name == "u8" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read() as u64, 8)
            }
            if name == "u16" {
                let pointer: RawPtr<u16> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read() as u64, 16)
            }
            if name == "u32" {
                let pointer: RawPtr<u32> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read() as u64, 32)
            }
            if name == "u64" {
                let pointer: RawPtr<u64> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read(), 64)
            }
            if name == "bool" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.boolean(
                    pointer.read() != 0)
            }
            if name == "f32" {
                let pointer: RawPtr<f32> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.floating(
                    pointer.read() as float)
            }
            if name == "float" {
                let pointer: RawPtr<f64> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.floating(
                    pointer.read())
            }
            if name == "RawPtr" {
                let slot: RawPtr<RawPtr<u8> > =
                    RawPtr.from_address(
                        address as u64)
                let pointer: RawPtr<u8> =
                    slot.read()
                return TreeValue.host_pointer(
                    pointer.address(), global.type)
            }
        }
        return self.fail(
            node,
            "extern C global type {render_hir_type(global.type)} is not in the Beans interpreter yet")
    }

    fn write_c_global(node: HirNode,
                      global: HirCGlobal,
                      value: TreeValue) {
        let address: int =
            self.c_global_address(node, global)
        if self.failed { return }
        let name: string =
            canonical_hir_name(global.type.name)
        unsafe {
            if name == "i8" {
                let pointer: RawPtr<i8> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i8)
                return
            }
            if name == "i16" {
                let pointer: RawPtr<i16> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i16)
                return
            }
            if name == "i32" {
                let pointer: RawPtr<i32> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i32)
                return
            }
            if name == "int" {
                let pointer: RawPtr<i64> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i64)
                return
            }
            if name == "u8" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.uint_data as u8)
                return
            }
            if name == "u16" {
                let pointer: RawPtr<u16> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.uint_data as u16)
                return
            }
            if name == "u32" {
                let pointer: RawPtr<u32> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.uint_data as u32)
                return
            }
            if name == "u64" {
                let pointer: RawPtr<u64> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(value.uint_data)
                return
            }
            if name == "bool" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    if value.bool_data {
                        1 as u8
                    } else {
                        0 as u8
                    })
                return
            }
            if name == "f32" {
                let pointer: RawPtr<f32> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.float_data as f32)
                return
            }
            if name == "float" {
                let pointer: RawPtr<f64> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(value.float_data)
                return
            }
            if name == "RawPtr" {
                let slot: RawPtr<RawPtr<u8> > =
                    RawPtr.from_address(
                        address as u64)
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        value.memory_address)
                slot.write(pointer)
                return
            }
        }
        self.fail(
            node,
            "extern C global type {render_hir_type(global.type)} is not in the Beans interpreter yet")
    }

    fn layout(type: HirType) -> LayoutAnswer {
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        return engine.layout_type(type)
    }

    fn find_memory(address: u64) ->
        Option<TreeMemory> {
        for memory: TreeMemory in self.memories {
            let end: u64 =
                memory.base +
                (memory.data.len() as u64)
            if address >= memory.base &&
               address <= end {
                return some(memory)
            }
        }
        return none
    }

    fn allocate_memory(size: int,
                       alignment: int) -> TreeMemory {
        let align: u64 = alignment as u64
        let remainder: u64 =
            self.next_memory_address % align
        if remainder != 0 {
            self.next_memory_address +=
                align - remainder
        }
        let result: TreeMemory =
            new TreeMemory(
                self.next_memory_address,
                size, alignment)
        self.memories.push(result)
        self.next_memory_address +=
            (if size == 0 { 1 } else { size }) as u64
        self.next_memory_address += 64
        return result
    }

    fn memory_contains(memory: TreeMemory,
                       address: u64,
                       width: int) -> bool {
        if memory.freed ||
           address < memory.base {
            return false
        }
        let offset: u64 =
            address - memory.base
        return offset <=
                   (memory.data.len() as u64) &&
               (width as u64) <=
                   (memory.data.len() as u64) -
                   offset
    }

    fn memory_read_uint(memory: TreeMemory,
                        address: u64,
                        width: int) -> u64 {
        let offset: int =
            (address - memory.base) as int
        var result: u64 = 0
        for index: int in 0..width {
            let shift: int =
                if self.program.target.endian ==
                       "little" {
                    index * 8
                } else {
                    (width - index - 1) * 8
                }
            result =
                result |
                ((memory.data.get(offset + index) as u64) <<
                 (shift as u64))
        }
        return result
    }

    fn memory_write_uint(memory: TreeMemory,
                         address: u64,
                         width: int,
                         value: u64) {
        let offset: int =
            (address - memory.base) as int
        for index: int in 0..width {
            let shift: int =
                if self.program.target.endian ==
                       "little" {
                    index * 8
                } else {
                    (width - index - 1) * 8
                }
            memory.data.set(
                offset + index,
                ((value >> (shift as u64)) &
                 (255 as u64)) as int)
        }
    }

    fn memory_write_value(
        node: HirNode, memory: TreeMemory,
        address: u64, type: HirType,
        value: TreeValue) -> bool {
        let answer: LayoutAnswer =
            self.layout(type)
        if !answer.ok ||
           !self.memory_contains(
               memory, address, answer.value.size) {
            self.fail(node, "invalid raw memory write")
            return false
        }
        let name: string =
            canonical_hir_name(type.name)
        if hir_is_integer(type) {
            let bits: int =
                tree_integer_bits(name)
            self.memory_write_uint(
                memory, address, bits / 8,
                if value.int_unsigned {
                    value.uint_data
                } else {
                    value.int_data as u64
                })
            return true
        }
        if name == "bool" {
            self.memory_write_uint(
                memory, address, 1,
                if value.bool_data {
                    1 as u64
                } else {
                    0 as u64
                })
            return true
        }
        if name == "f32" || name == "f64" ||
           name == "float" {
            let bits: int =
                if name == "f32" { 32 } else { 64 }
            self.memory_write_uint(
                memory, address, bits / 8,
                tree_float_bits(
                    value.float_data, bits))
            return true
        }
        if name == "RawPtr" {
            self.memory_write_uint(
                memory, address,
                self.program.target.pointer_size(),
                value.memory_address)
            return true
        }
        if name == "Slice" ||
           name == "RawSlice" {
            let width: int =
                self.program.target.pointer_size()
            self.memory_write_uint(
                memory, address, width,
                value.memory_address)
            self.memory_write_uint(
                memory,
                address + (width as u64),
                width, value.slice_len as u64)
            return true
        }
        if name == "array" &&
           type.args.len() == 1 {
            let element: LayoutAnswer =
                self.layout(type.args[0])
            if !element.ok { return false }
            for index: int in 0..type.array_length {
                if index < value.items.len() &&
                   !self.memory_write_value(
                       node, memory,
                       address +
                           ((index *
                             element.value.size) as u64),
                       type.args[0],
                       value.items[index]) {
                    return false
                }
            }
            return true
        }
        if name.starts_with("Simd") {
            let element_type: HirType =
                new HirType(
                    tree_simd_element(name))
            let element: LayoutAnswer =
                self.layout(element_type)
            if !element.ok { return false }
            for index: int in 0..value.items.len() {
                if !self.memory_write_value(
                       node, memory,
                       address +
                           ((index *
                             element.value.size) as u64),
                       element_type,
                       value.items[index]) {
                    return false
                }
            }
            return true
        }
        match self.declaration(type.name) {
            some(declaration) => {
                if declaration.kind != "struct" &&
                   declaration.kind != "union" {
                    self.fail(
                        node,
                        "{type.name} cannot be stored in raw memory")
                    return false
                }
                let engine: LayoutEngine =
                    new LayoutEngine(
                        self.program,
                        self.program.target)
                let record: RecordLayoutAnswer =
                    engine.layout_record(declaration)
                if declaration.kind == "union" {
                    match value.bytes_data {
                        some(data) => {
                            let at: int =
                                (address -
                                 memory.base) as int
                            memory.data.copy_from(
                                data, at)
                            return true
                        }
                        none => {}
                    }
                }
                for field: HirField in
                    declaration.fields {
                    match value.fields.get(field.name) {
                        some(field_value) => {
                            match record.offsets.get(
                                    field.name) {
                                some(offset) => {
                                    if !self.memory_write_value(
                                           node, memory,
                                           address +
                                               (offset as u64),
                                           field.type,
                                           field_value) {
                                        return false
                                    }
                                }
                                none => {}
                            }
                        }
                        none => {}
                    }
                }
                return true
            }
            none => {}
        }
        self.fail(
            node,
            "{render_hir_type(type)} cannot be stored in raw memory")
        return false
    }

    fn memory_read_value(
        node: HirNode, memory: TreeMemory,
        address: u64,
        type: HirType) -> TreeValue {
        let answer: LayoutAnswer =
            self.layout(type)
        if !answer.ok ||
           !self.memory_contains(
               memory, address, answer.value.size) {
            return self.fail(
                node, "invalid raw memory read")
        }
        let name: string =
            canonical_hir_name(type.name)
        if hir_is_integer(type) {
            let bits: int =
                tree_integer_bits(name)
            let raw: u64 =
                self.memory_read_uint(
                    memory, address, bits / 8)
            return if tree_integer_unsigned(name) {
                TreeValue.unsigned_integer(
                    raw, bits)
            } else {
                TreeValue.signed_integer(
                    tree_signed_from_bits(raw, bits),
                    bits)
            }
        }
        if name == "bool" {
            return TreeValue.boolean(
                self.memory_read_uint(
                    memory, address, 1) != 0)
        }
        if name == "f32" || name == "f64" ||
           name == "float" {
            let bits: int =
                if name == "f32" { 32 } else { 64 }
            return TreeValue.floating(
                tree_float_from_bits(
                    self.memory_read_uint(
                        memory, address, bits / 8),
                    bits))
        }
        if name == "RawPtr" {
            let pointer_address: u64 =
                self.memory_read_uint(
                    memory, address,
                    self.program.target.pointer_size())
            let element: HirType =
                if type.args.len() == 1 {
                    type.args[0]
                } else {
                    new HirType("u8")
                }
            match self.find_memory(pointer_address) {
                some(target) => {
                    return TreeValue.raw_pointer(
                        some(target),
                        pointer_address, element)
                }
                none => {
                    return TreeValue.host_pointer(
                        pointer_address, element)
                }
            }
        }
        if name == "Slice" ||
           name == "RawSlice" {
            let width: int =
                self.program.target.pointer_size()
            let pointer_address: u64 =
                self.memory_read_uint(
                    memory, address, width)
            let length: int =
                self.memory_read_uint(
                    memory,
                    address + (width as u64),
                    width) as int
            let element: HirType =
                if type.args.len() == 1 {
                    type.args[0]
                } else {
                    new HirType("u8")
                }
            var pointer: TreeValue =
                TreeValue.host_pointer(
                    pointer_address, element)
            match self.find_memory(pointer_address) {
                some(target) => {
                    pointer = TreeValue.raw_pointer(
                        some(target),
                        pointer_address, element)
                }
                none => {}
            }
            return TreeValue.slice(pointer, length)
        }
        if name == "array" &&
           type.args.len() == 1 {
            let element: LayoutAnswer =
                self.layout(type.args[0])
            var values: List<TreeValue> = []
            for index: int in 0..type.array_length {
                values.push(
                    self.memory_read_value(
                        node, memory,
                        address +
                            ((index *
                              element.value.size) as u64),
                        type.args[0]))
            }
            return TreeValue.sequence(
                "array", move values)
        }
        if name.starts_with("Simd") {
            let element_type: HirType =
                new HirType(
                    tree_simd_element(name))
            let element: LayoutAnswer =
                self.layout(element_type)
            var values: List<TreeValue> = []
            for index: int in
                0..tree_simd_lanes(name) {
                values.push(
                    self.memory_read_value(
                        node, memory,
                        address +
                            ((index *
                              element.value.size) as u64),
                        element_type))
            }
            let result: TreeValue =
                TreeValue.sequence(
                    "simd", move values)
            result.text = name
            return result
        }
        match self.declaration(type.name) {
            some(declaration) => {
                let engine: LayoutEngine =
                    new LayoutEngine(
                        self.program,
                        self.program.target)
                let record: RecordLayoutAnswer =
                    engine.layout_record(declaration)
                let result: TreeValue =
                    new TreeValue("record")
                result.text =
                    declaration.qualified
                if declaration.kind == "union" {
                    let at: int =
                        (address -
                         memory.base) as int
                    result.bytes_data =
                        some(memory.data.slice(
                            at,
                            at +
                                record.answer.value.size))
                }
                for field: HirField in
                    declaration.fields {
                    match record.offsets.get(
                            field.name) {
                        some(offset) => {
                            result.fields[field.name] =
                                self.memory_read_value(
                                    node, memory,
                                    address +
                                        (offset as u64),
                                    field.type)
                        }
                        none => {}
                    }
                }
                return result
            }
            none => {}
        }
        return self.fail(
            node,
            "{render_hir_type(type)} cannot be read from raw memory")
    }

    fn pointer_memory(
        node: HirNode,
        pointer: TreeValue) -> Option<TreeMemory> {
        if pointer.memory_address == 0 {
            self.fail(node, "null raw pointer")
            return none
        }
        match pointer.memory {
            some(memory) => {
                if memory.freed {
                    self.fail(
                        node, "dangling raw pointer")
                    return none
                }
                return some(memory)
            }
            none => {
                match self.find_memory(
                        pointer.memory_address) {
                    some(memory) => {
                        if !memory.freed {
                            return some(memory)
                        }
                    }
                    none => {}
                }
            }
        }
        self.fail(node, "invalid raw pointer")
        return none
    }

    fn host_pointer_read(
        node: HirNode, pointer: TreeValue,
        type: HirType) -> TreeValue {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        unsafe {
            let host: RawPtr<u8> =
                RawPtr.from_address(
                    pointer.memory_address)
            for index: int in 0..answer.value.size {
                temporary.data.set(
                    index,
                    host.offset(index).read() as int)
            }
        }
        return self.memory_read_value(
            node, temporary, 0, type)
    }

    fn host_pointer_write(
        node: HirNode, pointer: TreeValue,
        type: HirType, value: TreeValue) {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        if !self.memory_write_value(
               node, temporary, 0, type, value) {
            return
        }
        unsafe {
            let host: RawPtr<u8> =
                RawPtr.from_address(
                    pointer.memory_address)
            for index: int in 0..answer.value.size {
                host.offset(index).write(
                    temporary.data.get(index) as u8)
            }
        }
    }

    fn write_union_field(
        node: HirNode,
        value: TreeValue,
        declaration: HirDeclaration,
        field_name: string,
        written: TreeValue) {
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        let record: RecordLayoutAnswer =
            engine.layout_record(declaration)
        let memory: TreeMemory =
            new TreeMemory(
                0, record.answer.value.size,
                record.answer.value.align)
        match value.bytes_data {
            some(data) => {
                memory.data.copy_from(data, 0)
            }
            none => {}
        }
        for field: HirField in
            declaration.fields {
            if field.name == field_name {
                self.memory_write_value(
                    node, memory, 0,
                    field.type, written)
                break
            }
        }
        value.bytes_data = some(memory.data)
        for field: HirField in
            declaration.fields {
            value.fields[field.name] =
                self.memory_read_value(
                    node, memory, 0, field.type)
        }
    }

    fn needs_deinit(name: string) -> bool {
        match self.declaration(name) {
            some(declaration) => {
                match self.find_function(
                        "{declaration.qualified}.deinit") {
                    some(function) => {
                        if function.owner ==
                               declaration.qualified {
                            return true
                        }
                    }
                    none => {}
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       self.needs_deinit(
                           declaration.relations[index].name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn is_instance(type_name: string,
                   target_name: string) -> bool {
        if type_name == target_name {
            return true
        }
        match self.declaration(type_name) {
            some(declaration) => {
                if declaration.name == target_name ||
                   declaration.qualified ==
                       target_name {
                    return true
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       self.is_instance(
                           declaration.relations[index].name,
                           target_name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn deinit_chain(name: string,
                    object: TreeValue) {
        match self.declaration(name) {
            some(declaration) => {
                match self.find_function(
                        "{declaration.qualified}.deinit") {
                    some(function) => {
                        if function.owner ==
                               declaration.qualified {
                            self.invoke(
                                function, [], some(object))
                            if self.failed { return }
                        }
                    }
                    none => {}
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" {
                        self.deinit_chain(
                            declaration.relations[index].name,
                            object)
                        return
                    }
                }
            }
            none => {}
        }
    }

    // A field whose type is a class or interface reference can hold the
    // last reference to an object with observable teardown, so the order
    // this object releases its fields is program-visible.
    fn chain_frees_objects(name: string) -> bool {
        match self.declaration(name) {
            some(declaration) => {
                for field: HirField in declaration.fields {
                    match self.declaration(field.type.name) {
                        some(field_decl) => {
                            if field_decl.kind == "class" ||
                               field_decl.kind ==
                                   "interface" {
                                return true
                            }
                        }
                        none => {}
                    }
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       self.chain_frees_objects(
                           declaration.relations[index].name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    // Canonical field release order shared with the stage-0 interpreter
    // and both native backends: the object's own class first, fields in
    // reverse declaration order, then each base class up the chain.
    fn release_fields(name: string,
                      object: TreeValue) {
        match self.declaration(name) {
            some(declaration) => {
                var index: int =
                    declaration.fields.len() - 1
                for index >= 0 {
                    object.fields.remove(
                        declaration.fields[index].name)
                    index -= 1
                }
                for rel: int in
                    0..declaration.relations.len() {
                    if rel <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[rel] ==
                           "extends" {
                        self.release_fields(
                            declaration.relations[rel].name,
                            object)
                        return
                    }
                }
            }
            none => {}
        }
    }

    fn deinit_object(object: TreeValue) {
        if self.failed || object.kind != "object" {
            return
        }
        self.deinit_chain(object.text, object)
        if self.failed {
            return
        }
        self.release_fields(object.text, object)
    }

    fn map_key(map: TreeValue,
               key: TreeValue) -> string {
        for stored: TreeValue in map.map_keys {
            if tree_value_equal(stored, key) {
                return tree_value_key(stored)
            }
        }
        return tree_value_key(key)
    }

    fn dynamic_method(type_name: string,
                      method: string,
                      dispatch_slot: string) ->
        Option<HirFunction> {
        match self.find_function(
            "{type_name}.{method}") {
            some(function) => {
                if dispatch_slot == "" ||
                   function.dispatch_slots.contains(
                       dispatch_slot) {
                    return some(function)
                }
            }
            none => {}
        }
        for declaration: HirDeclaration in
            self.program.declarations {
            if declaration.qualified != type_name &&
               declaration.name != type_name {
                continue
            }
            for index: int in
                0..declaration.relations.len() {
                if index <
                       declaration.relation_kinds.len() &&
                   declaration.relation_kinds[index] ==
                       "extends" {
                    return self.dynamic_method(
                        declaration.relations[index].name,
                        method, dispatch_slot)
                }
            }
        }
        return none
    }

    fn local(frame: TreeFrame,
             node: HirNode) -> TreeValue {
        match frame.get(node.binding_id) {
            some(value) => {
                // references can chain — an inout taken on a binding
                // a closure captured reaches the value through the
                // shared cell — so follow them to the end
                var current: TreeValue = value
                for current.kind == "reference" {
                    var advanced: Option<TreeValue> =
                        none
                    match current.reference_frame {
                        some(target) => {
                            advanced = target.get(
                                current.reference_binding)
                        }
                        none => {}
                    }
                    match advanced {
                        some(actual) => {
                            current = actual
                        }
                        none => { return current }
                    }
                }
                return current
            }
            none => {
                return self.fail(
                    node,
                    "unknown name '{node.value}' (binding {node.binding_id})")
            }
        }
    }

    fn interpolation(node: HirNode,
                     frame: TreeFrame) -> string {
        let source: string = tree_unquote(node.value)
        var values: List<TreeValue> = []
        for child: HirNode in node.children {
            values.push(self.expression(child, frame))
            if self.failed { return "" }
        }
        var result: string = ""
        var index: int = 0
        var value_index: int = 0
        for index < source.len() {
            if source.byte_at(index) == 123 {
                if index + 1 < source.len() &&
                   source.byte_at(index + 1) == 123 {
                    result = "{result}\{"
                    index += 2
                    continue
                }
                var depth: int = 1
                var close: int = index + 1
                for close < source.len() && depth > 0 {
                    if source.byte_at(close) == 123 {
                        depth += 1
                    } else if source.byte_at(close) == 125 {
                        depth -= 1
                    }
                    close += 1
                }
                if value_index < values.len() {
                    let value: TreeValue =
                        values[value_index]
                    let segment: string =
                        source.slice(index + 1, close - 1)
                    let format: TreeFormatSpec =
                        tree_format_spec(segment)
                    var piece: string =
                        tree_value_text(value)
                    if format.has &&
                       format.places >= 0 {
                        if value.kind == "float" {
                            piece = host_fmt.float(
                                value.float_data,
                                format.places)
                        } else if value.kind ==
                                      "decimal" {
                            piece = host_fmt.decimal(
                                value.decimal_data,
                                format.places)
                        }
                    }
                    if format.has &&
                       format.width > 0 {
                        piece =
                            if format.left {
                                host_fmt.pad_right(
                                    piece, format.width)
                            } else {
                                host_fmt.pad_left(
                                    piece, format.width)
                            }
                    }
                    result = "{result}{piece}"
                    value_index += 1
                }
                index = close
                continue
            }
            if source.byte_at(index) == 125 &&
               index + 1 < source.len() &&
               source.byte_at(index + 1) == 125 {
                result = "{result}\}"
                index += 2
                continue
            }
            result =
                "{result}{source.slice(index, index + 1)}"
            index += 1
        }
        return result
    }

    fn literal(node: HirNode,
               frame: TreeFrame) -> TreeValue {
        let name: string =
            canonical_hir_name(node.type.name)
        if name == "string" {
            if node.children.len() != 0 {
                return TreeValue.string(
                    self.interpolation(node, frame))
            }
            return TreeValue.string(
                tree_unquote(node.value))
        }
        if name == "bool" {
            return TreeValue.boolean(
                node.value == "true")
        }
        if hir_is_integer(node.type) {
            if tree_integer_unsigned(name) {
                return TreeValue.unsigned_integer(
                    tree_parse_unsigned(node.value),
                    tree_integer_bits(name))
            }
            return TreeValue.signed_integer_bits(
                tree_parse_unsigned(node.value),
                tree_integer_bits(name))
        }
        if hir_is_float(node.type) {
            let clean: string =
                node.value.replace("_", "")
            return self.floating_value(
                node.type,
                clean.to_float().or(0.0))
        }
        if name == "decimal" {
            let clean: string =
                node.value.replace("_", "")
            return TreeValue.decimal_value(
                clean.to_decimal().or(0.0))
        }
        return self.fail(
            node,
            "literal type {render_hir_type(node.type)} is not in the Beans interpreter yet")
    }

    fn layout_query(node: HirNode) -> TreeValue {
        if node.children.len() == 0 {
            return self.fail(
                node, "layout query has no type")
        }
        let queried: HirType =
            node.children[0].type
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        if node.value == "offset_of" {
            match self.declaration(queried.name) {
                some(declaration) => {
                    let record: RecordLayoutAnswer =
                        engine.layout_record(declaration)
                    match record.offsets.get(
                            node.resolved) {
                        some(offset) => {
                            return TreeValue.integer(offset)
                        }
                        none => {
                            return self.fail(
                                node,
                                "{queried.name} has no field '{node.resolved}'")
                        }
                    }
                }
                none => {
                    return self.fail(
                        node,
                        "offset_of needs a struct or union")
                }
            }
        }
        let answer: LayoutAnswer =
            engine.layout_type(queried)
        if !answer.ok {
            return self.fail(node, answer.message)
        }
        return TreeValue.integer(
            if node.value == "size_of" {
                answer.value.size
            } else {
                answer.value.align
            })
    }

    fn truth(node: HirNode,
             value: TreeValue) -> bool {
        if value.kind != "bool" {
            self.fail(node, "condition is not bool")
            return false
        }
        return value.bool_data
    }

    fn integer_binary(node: HirNode,
                      left: TreeValue,
                      right: TreeValue) -> TreeValue {
        if left.int_unsigned ||
           right.int_unsigned {
            let bits: int =
                if left.int_unsigned {
                    left.int_bits
                } else {
                    right.int_bits
                }
            let lhs: u64 = left.uint_data
            let rhs: u64 = right.uint_data
            if node.value == "+" {
                return TreeValue.unsigned_integer(
                    lhs + rhs, bits)
            }
            if node.value == "-" {
                return TreeValue.unsigned_integer(
                    lhs - rhs, bits)
            }
            if node.value == "*" {
                return TreeValue.unsigned_integer(
                    lhs * rhs, bits)
            }
            if node.value == "/" {
                if rhs == 0 {
                    return self.fail(
                        node, "divide by zero")
                }
                return TreeValue.unsigned_integer(
                    lhs / rhs, bits)
            }
            if node.value == "%" {
                if rhs == 0 {
                    return self.fail(
                        node, "modulo by zero")
                }
                return TreeValue.unsigned_integer(
                    lhs % rhs, bits)
            }
            if node.value == "&" {
                return TreeValue.unsigned_integer(
                    lhs & rhs, bits)
            }
            if node.value == "|" {
                return TreeValue.unsigned_integer(
                    lhs | rhs, bits)
            }
            if node.value == "^" {
                return TreeValue.unsigned_integer(
                    lhs ^ rhs, bits)
            }
            if node.value == "<<" {
                // the count is masked by the operand width, not by 64
                return TreeValue.unsigned_integer(
                    lhs << (rhs & ((bits - 1) as u64)), bits)
            }
            if node.value == ">>" {
                return TreeValue.unsigned_integer(
                    lhs >> (rhs & ((bits - 1) as u64)), bits)
            }
            if node.value == "<" {
                return TreeValue.boolean(lhs < rhs)
            }
            if node.value == "<=" {
                return TreeValue.boolean(lhs <= rhs)
            }
            if node.value == ">" {
                return TreeValue.boolean(lhs > rhs)
            }
            if node.value == ">=" {
                return TreeValue.boolean(lhs >= rhs)
            }
            if node.value == ".." ||
               node.value == "..=" {
                let result: TreeValue =
                    TreeValue.sequence(
                        "range",
                        [tree_value_copy(left),
                         tree_value_copy(right)])
                result.bool_data =
                    node.value == "..="
                return result
            }
            return self.fail(
                node,
                "integer operator '{node.value}' is not in the Beans interpreter yet")
        }
        let lhs: int = left.int_data
        let rhs: int = right.int_data
        let bits: int = left.int_bits
        if node.value == "+" {
            return TreeValue.signed_integer(
                lhs + rhs, bits)
        }
        if node.value == "-" {
            return TreeValue.signed_integer(
                lhs - rhs, bits)
        }
        if node.value == "*" {
            return TreeValue.signed_integer(
                lhs * rhs, bits)
        }
        if node.value == "/" {
            if rhs == 0 {
                return self.fail(node, "divide by zero")
            }
            return TreeValue.signed_integer(
                lhs / rhs, bits)
        }
        if node.value == "%" {
            if rhs == 0 {
                return self.fail(node, "modulo by zero")
            }
            return TreeValue.signed_integer(
                lhs % rhs, bits)
        }
        if node.value == "&" {
            return TreeValue.signed_integer(
                lhs & rhs, bits)
        }
        if node.value == "|" {
            return TreeValue.signed_integer(
                lhs | rhs, bits)
        }
        if node.value == "^" {
            return TreeValue.signed_integer(
                lhs ^ rhs, bits)
        }
        if node.value == "<<" {
            // the count is masked by the operand width, not by 64
            return TreeValue.signed_integer(
                lhs << (rhs & (bits - 1)), bits)
        }
        if node.value == ">>" {
            return TreeValue.signed_integer(
                lhs >> (rhs & (bits - 1)), bits)
        }
        if node.value == "==" {
            return TreeValue.boolean(lhs == rhs)
        }
        if node.value == "!=" {
            return TreeValue.boolean(lhs != rhs)
        }
        if node.value == "<" {
            return TreeValue.boolean(lhs < rhs)
        }
        if node.value == "<=" {
            return TreeValue.boolean(lhs <= rhs)
        }
        if node.value == ">" {
            return TreeValue.boolean(lhs > rhs)
        }
        if node.value == ">=" {
            return TreeValue.boolean(lhs >= rhs)
        }
        if node.value == ".." ||
           node.value == "..=" {
            let result: TreeValue =
                TreeValue.sequence(
                "range",
                [tree_value_copy(left),
                 tree_value_copy(right)])
            result.bool_data =
                node.value == "..="
            return result
        }
        return self.fail(
            node,
            "integer operator '{node.value}' is not in the Beans interpreter yet")
    }

    fn binary(node: HirNode,
              frame: TreeFrame) -> TreeValue {
        let left: TreeValue =
            self.expression(node.children[0], frame)
        if left.kind == "propagate" { return left }
        if node.value == "&&" {
            if !self.truth(node, left) {
                return TreeValue.boolean(false)
            }
            return TreeValue.boolean(self.truth(
                node,
                self.expression(node.children[1], frame)))
        }
        if node.value == "||" {
            if self.truth(node, left) {
                return TreeValue.boolean(true)
            }
            return TreeValue.boolean(self.truth(
                node,
                self.expression(node.children[1], frame)))
        }
        let right: TreeValue =
            self.expression(node.children[1], frame)
        if right.kind == "propagate" { return right }
        if node.value == "==" || node.value == "!=" {
            let equal: bool =
                tree_value_equal(left, right)
            return TreeValue.boolean(
                if node.value == "==" {
                    equal
                } else {
                    !equal
                })
        }
        if left.kind == "int" && right.kind == "int" {
            return self.integer_binary(
                node, left, right)
        }
        if left.kind == "simd" &&
           right.kind == "simd" {
            let result: TreeValue =
                tree_value_copy(left)
            for index: int in
                0..left.items.len() {
                result.items[index] =
                    self.simd_scalar(
                        node, node.value,
                        left.items[index],
                        right.items[index])
            }
            return result
        }
        if left.kind == "float" &&
           right.kind == "float" {
            if node.value == "+" {
                return self.floating_value(
                    node.type,
                    left.float_data + right.float_data)
            }
            if node.value == "-" {
                return self.floating_value(
                    node.type,
                    left.float_data - right.float_data)
            }
            if node.value == "*" {
                return self.floating_value(
                    node.type,
                    left.float_data * right.float_data)
            }
            if node.value == "/" {
                return self.floating_value(
                    node.type,
                    left.float_data / right.float_data)
            }
            if node.value == "==" {
                return TreeValue.boolean(
                    left.float_data == right.float_data)
            }
            if node.value == "!=" {
                return TreeValue.boolean(
                    left.float_data != right.float_data)
            }
            if node.value == "<" {
                return TreeValue.boolean(
                    left.float_data < right.float_data)
            }
            if node.value == "<=" {
                return TreeValue.boolean(
                    left.float_data <= right.float_data)
            }
            if node.value == ">" {
                return TreeValue.boolean(
                    left.float_data > right.float_data)
            }
            if node.value == ">=" {
                return TreeValue.boolean(
                    left.float_data >= right.float_data)
            }
        }
        if left.kind == "decimal" &&
           right.kind == "decimal" {
            if node.value == "+" ||
               node.value == "-" ||
               node.value == "*" ||
               node.value == "/" {
                return self.decimal_binary_value(
                    node, node.value,
                    left.decimal_data,
                    right.decimal_data)
            }
            if node.value == "<" {
                return TreeValue.boolean(
                    left.decimal_data <
                    right.decimal_data)
            }
            if node.value == "<=" {
                return TreeValue.boolean(
                    left.decimal_data <=
                    right.decimal_data)
            }
            if node.value == ">" {
                return TreeValue.boolean(
                    left.decimal_data > right.decimal_data)
            }
            if node.value == ">=" {
                return TreeValue.boolean(
                    left.decimal_data >=
                    right.decimal_data)
            }
        }
        if left.kind == "string" &&
           right.kind == "string" {
            if node.value == "+" {
                return TreeValue.string(
                    "{left.text}{right.text}")
            }
            if node.value == "==" {
                return TreeValue.boolean(
                    left.text == right.text)
            }
            if node.value == "!=" {
                return TreeValue.boolean(
                    left.text != right.text)
            }
            if node.value == "<" {
                return TreeValue.boolean(
                    left.text < right.text)
            }
            if node.value == "<=" {
                return TreeValue.boolean(
                    left.text <= right.text)
            }
            if node.value == ">" {
                return TreeValue.boolean(
                    left.text > right.text)
            }
            if node.value == ">=" {
                return TreeValue.boolean(
                    left.text >= right.text)
            }
        }
        if left.kind == "bool" &&
           right.kind == "bool" {
            if node.value == "==" {
                return TreeValue.boolean(
                    left.bool_data == right.bool_data)
            }
            if node.value == "!=" {
                return TreeValue.boolean(
                    left.bool_data != right.bool_data)
            }
        }
        if left.kind == "object" &&
           right.kind == "object" &&
           (node.value == "==" || node.value == "!=") {
            let equal: bool =
                left.object_id == right.object_id
            return TreeValue.boolean(
                if node.value == "==" {
                    equal
                } else {
                    !equal
                })
        }
        return self.fail(
            node,
            "operator '{node.value}' cannot evaluate {left.kind} and {right.kind}")
    }

    fn unary(node: HirNode,
             frame: TreeFrame) -> TreeValue {
        if node.value == "inout" &&
           node.children.len() == 1 &&
           node.children[0].kind == "local" {
            // a binding a closure captured already lives in a shared
            // cell; hand that cell out rather than wrapping the slot
            // again, which would take two dereferences to read
            match frame.get(
                    node.children[0].binding_id) {
                some(current) => {
                    if current.kind == "reference" {
                        return current
                    }
                }
                none => {}
            }
            return TreeValue.reference(
                frame,
                node.children[0].binding_id)
        }
        let value: TreeValue =
            self.expression(node.children[0], frame)
        if value.kind == "propagate" { return value }
        if node.value == "move" || node.value == "+" ||
           node.value == "inout" {
            return value
        }
        if node.value == "!" {
            return TreeValue.boolean(
                !self.truth(node, value))
        }
        if node.value == "-" && value.kind == "int" {
            if value.int_unsigned {
                return TreeValue.unsigned_integer(
                    (0 as u64) - value.uint_data,
                    value.int_bits)
            }
            return TreeValue.signed_integer_bits(
                (0 as u64) - value.uint_data,
                value.int_bits)
        }
        if node.value == "-" && value.kind == "float" {
            return self.floating_value(
                node.type, -value.float_data)
        }
        if node.value == "-" && value.kind == "decimal" {
            return TreeValue.decimal_value(
                -value.decimal_data)
        }
        if node.value == "~" && value.kind == "int" {
            if value.int_unsigned {
                return TreeValue.unsigned_integer(
                    ~value.uint_data,
                    value.int_bits)
            }
            return TreeValue.signed_integer(
                ~value.int_data,
                value.int_bits)
        }
        return self.fail(
            node,
            "unary operator '{node.value}' cannot evaluate {value.kind}")
    }

    fn builtin_call(node: HirNode,
                    arguments: List<TreeValue>) -> TreeValue {
        if node.resolved == "panic" {
            if arguments.len() != 1 {
                return self.fail(
                    node, "panic needs one string")
            }
            return self.fail(node, arguments[0].text)
        }
        if node.resolved == "std.io.println" ||
           node.resolved == "std.io.print" ||
           node.resolved == "std.io.eprintln" ||
           node.resolved == "std.io.eprint" {
            let shown: string =
                if arguments.len() == 0 {
                    ""
                } else {
                    tree_value_text(arguments[0])
                }
            let to_error: bool =
                node.resolved == "std.io.eprintln" ||
                node.resolved == "std.io.eprint"
            let newline: bool =
                node.resolved == "std.io.println" ||
                node.resolved == "std.io.eprintln"
            match self.debugger {
                some(session) => {
                    // stdout is the protocol stream under the debugger, so
                    // the program's own output travels as an output event.
                    session.program_output(
                        if newline { "{shown}\n" } else { shown },
                        if to_error { "stderr" } else { "stdout" })
                    return TreeValue.unit()
                }
                none => {}
            }
            if node.resolved == "std.io.println" {
                io.println(shown)
            } else if node.resolved ==
                          "std.io.print" {
                io.print(shown)
            } else if node.resolved ==
                          "std.io.eprintln" {
                io.eprintln(shown)
            } else {
                io.eprint(shown)
            }
            return TreeValue.unit()
        }
        if node.resolved == "std.io.read_line" {
            match io.read_line() {
                some(value) => {
                    return TreeValue.option_some(
                        TreeValue.string(value))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if node.resolved == "std.io.read_all" {
            return TreeValue.string(io.read_all())
        }
        if node.resolved == "std.thread.spawn" &&
           arguments.len() == 1 &&
           arguments[0].kind == "closure" {
            let work:
                Mutex<TreeThreadWork> =
                new Mutex(
                    new TreeThreadWork(
                        self.program,
                        tree_spawn_closure(
                            arguments[0]),
                        node))
            let handle: Thread<int> =
                host_thread.spawn(fn() -> int {
                    work.with_lock(
                        fn(state: TreeThreadWork) {
                            state.run()
                        })
                    return 0
                })
            let result: TreeValue =
                new TreeValue("thread")
            result.thread_handle =
                some(handle)
            result.thread_work = some(work)
            return result
        }
        if node.resolved == "std.thread.yield_now" {
            return TreeValue.unit()
        }
        if node.resolved == "std.c.errno" {
            return TreeValue.signed_integer(
                host_c.errno() as int, 32)
        }
        if node.resolved == "std.c.set_errno" &&
           arguments.len() == 1 {
            host_c.set_errno(arguments[0].int_data as i32)
            return TreeValue.unit()
        }
        if node.resolved == "std.os.args" {
            var values: List<TreeValue> = []
            for argument: string in self.arguments {
                values.push(
                    TreeValue.string(argument))
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if node.resolved == "std.os.env" &&
           arguments.len() == 1 {
            match host_os.env(arguments[0].text) {
                some(value) => {
                    return TreeValue.option_some(
                        TreeValue.string(value))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if node.resolved == "std.os.exit" &&
           arguments.len() == 1 {
            host_os.exit(
                arguments[0].int_data)
            return TreeValue.unit()
        }
        if node.resolved ==
               "std.time.monotonic_nanos" {
            return TreeValue.integer(
                host_time.monotonic_nanos())
        }
        if node.resolved == "std.time.wall_nanos" {
            return TreeValue.integer(
                host_time.wall_nanos())
        }
        if node.resolved == "std.time.sleep_nanos" &&
           arguments.len() == 1 {
            host_time.sleep_nanos(
                arguments[0].int_data)
            return TreeValue.unit()
        }
        if node.resolved ==
               "std.time.monotonic_millis" {
            return TreeValue.integer(
                host_time.monotonic_millis())
        }
        if node.resolved == "std.time.wall_millis" {
            return TreeValue.integer(
                host_time.wall_millis())
        }
        if node.resolved == "std.time.sleep_millis" &&
           arguments.len() == 1 {
            host_time.sleep_millis(
                arguments[0].int_data)
            return TreeValue.unit()
        }
        if node.resolved == "std.random.bytes" &&
           arguments.len() == 1 {
            match host_random.bytes(
                    arguments[0].int_data) {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.bytes(value))
                }
                err(error) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            error.msg, error.kind))
                }
            }
        }
        if node.resolved == "std.random.u64" {
            match host_random.u64() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.integer(value))
                }
                err(error) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            error.msg, error.kind))
                }
            }
        }
        if node.resolved == "std.random.below" &&
           arguments.len() == 1 {
            match host_random.below(
                    arguments[0].int_data) {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.integer(value))
                }
                err(error) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            error.msg, error.kind))
                }
            }
        }
        if node.resolved == "std.proc.run" &&
           arguments.len() == 5 {
            return self.host_bytes_result(
                host_proc.run(
                    arguments[0].bytes_data.expect(
                        "proc.run argv"),
                    arguments[1].bytes_data.expect(
                        "proc.run env"),
                    arguments[2].text,
                    arguments[3].bytes_data.expect(
                        "proc.run stdin"),
                    arguments[4].int_data))
        }
        if node.resolved == "std.proc.start" &&
           arguments.len() == 3 {
            return self.host_bytes_result(
                host_proc.start(
                    arguments[0].bytes_data.expect(
                        "proc.start argv"),
                    arguments[1].bytes_data.expect(
                        "proc.start env"),
                    arguments[2].text))
        }
        if node.resolved == "std.proc.status" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_proc.status(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.signal" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_proc.signal(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.write" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_proc.write(
                    arguments[0].int_data,
                    arguments[1].bytes_data.expect(
                        "proc.write data"),
                    arguments[2].int_data))
        }
        if node.resolved == "std.proc.read" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_proc.read(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.close" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_proc.close(
                    arguments[0].int_data))
        }
        if node.resolved == "std.sock.listen" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_sock.listen(
                    arguments[0].text,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sock.connect" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_sock.connect(
                    arguments[0].text,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sock.udp_bind" &&
           arguments.len() == 2 {
            return self.host_int_result(
                host_sock.udp_bind(
                    arguments[0].text,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.accept" &&
           arguments.len() == 2 {
            return self.host_int_result(
                host_sock.accept(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.send" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_sock.send(
                    arguments[0].int_data,
                    arguments[1].bytes_data.expect(
                        "sock.send data"),
                    arguments[2].int_data))
        }
        if node.resolved == "std.sock.recv" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_sock.recv(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.send_to" &&
           arguments.len() == 4 {
            return self.host_int_result(
                host_sock.send_to(
                    arguments[0].int_data,
                    arguments[1].bytes_data.expect(
                        "sock.send_to data"),
                    arguments[2].text,
                    arguments[3].int_data))
        }
        if node.resolved == "std.sock.recv_from" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_sock.recv_from(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.address" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_sock.address(
                    arguments[0].int_data,
                    arguments[1].bool_data))
        }
        if node.resolved == "std.sock.shutdown" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_sock.shutdown(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved ==
               "std.sock.set_timeouts" &&
           arguments.len() == 3 {
            return self.host_bool_result(
                host_sock.set_timeouts(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved ==
               "std.sock.set_nonblocking" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_sock.set_nonblocking(
                    arguments[0].int_data,
                    arguments[1].bool_data))
        }
        if node.resolved == "std.sock.close" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_sock.close(
                    arguments[0].int_data))
        }
        if node.resolved == "std.sock.resolve" &&
           arguments.len() == 2 {
            return self.host_strings_result(
                host_sock.resolve(
                    arguments[0].text,
                    arguments[1].int_data))
        }
        if node.resolved == "std.ready.task_slot" &&
           arguments.len() == 1 {
            return TreeValue.integer(host_ready.task_slot(
                arguments[0].int_data))
        }
        if node.resolved == "std.ready.set_task_slot" &&
           arguments.len() == 2 {
            return TreeValue.integer(host_ready.set_task_slot(
                arguments[0].int_data,
                arguments[1].int_data))
        }
        if node.resolved == "std.ready.park_note" &&
           arguments.len() == 1 {
            return TreeValue.integer(host_ready.park_note(
                arguments[0].int_data))
        }
        if node.resolved == "std.ready.park_bind" &&
           arguments.len() == 2 {
            return TreeValue.integer(host_ready.park_bind(
                arguments[0].int_data,
                arguments[1].int_data))
        }
        if node.resolved == "std.ready.park_forget" &&
           arguments.len() == 1 {
            return TreeValue.integer(host_ready.park_forget(
                arguments[0].int_data))
        }
        if node.resolved == "std.ready.park_stale" {
            return TreeValue.integer(host_ready.park_stale())
        }
        if node.resolved == "std.ready.park_dead" &&
           arguments.len() == 1 {
            return TreeValue.integer(host_ready.park_dead(
                arguments[0].int_data))
        }
        if node.resolved == "std.ready.park_shutdown" {
            return TreeValue.integer(host_ready.park_shutdown())
        }
        if node.resolved == "std.ready.open" {
            return self.host_bytes_result(
                host_ready.open())
        }
        if node.resolved == "std.ready.add" &&
           arguments.len() == 6 {
            return self.host_bool_result(
                host_ready.add(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].bool_data,
                    arguments[4].bool_data,
                    arguments[5].bool_data))
        }
        if node.resolved == "std.ready.remove" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_ready.remove(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.ready.wait" &&
           arguments.len() == 4 {
            return self.host_bytes_result(
                host_ready.wait(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].int_data))
        }
        if node.resolved == "std.ready.wake" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_ready.wake(
                    arguments[0].int_data))
        }
        if node.resolved == "std.ready.close" &&
           arguments.len() == 3 {
            return self.host_bool_result(
                host_ready.close(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sig.watch" &&
           arguments.len() == 1 {
            return self.host_int_result(
                host_sig.watch(
                    arguments[0].bytes_data.expect(
                        "sig.watch signals")))
        }
        if node.resolved == "std.sig.pending" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_sig.pending(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sig.close" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_sig.close(
                    arguments[0].int_data,
                    arguments[1].bytes_data.expect(
                        "sig.close signals")))
        }
        if node.resolved == "std.sig.raise" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_sig.raise(
                    arguments[0].int_data))
        }
        if node.resolved == "std.sig.number" &&
           arguments.len() == 1 {
            return self.host_int_result(
                host_sig.number(
                    arguments[0].text))
        }
        if node.resolved == "std.sig.name" &&
           arguments.len() == 1 {
            return self.host_string_result(
                host_sig.name(
                    arguments[0].int_data))
        }
        if node.resolved.starts_with("std.dl.") {
            unsafe {
                if node.resolved == "std.dl.open" &&
                   arguments.len() == 1 {
                    return self.host_int_result(
                        host_dl.open(
                            arguments[0].text))
                }
                if node.resolved == "std.dl.symbol" &&
                   arguments.len() == 2 {
                    return self.host_int_result(
                        host_dl.symbol(
                            arguments[0].int_data,
                            arguments[1].text))
                }
                if node.resolved ==
                       "std.dl.global_symbol" &&
                   arguments.len() == 1 {
                    return self.host_int_result(
                        host_dl.global_symbol(
                            arguments[0].text))
                }
                if node.resolved == "std.dl.close" &&
                   arguments.len() == 1 {
                    return self.host_bool_result(
                        host_dl.close(
                            arguments[0].int_data))
                }
                if node.resolved == "std.dl.call0" &&
                   arguments.len() == 1 {
                    return TreeValue.integer(
                        host_dl.call0(
                            arguments[0].int_data))
                }
                if node.resolved == "std.dl.call1" &&
                   arguments.len() == 2 {
                    return TreeValue.integer(
                        host_dl.call1(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
                if node.resolved == "std.dl.call2" &&
                   arguments.len() == 3 {
                    return TreeValue.integer(
                        host_dl.call2(
                            arguments[0].int_data,
                            arguments[1].int_data,
                            arguments[2].int_data))
                }
                if node.resolved == "std.dl.call3" &&
                   arguments.len() == 4 {
                    return TreeValue.integer(
                        host_dl.call3(
                            arguments[0].int_data,
                            arguments[1].int_data,
                            arguments[2].int_data,
                            arguments[3].int_data))
                }
                if node.resolved ==
                       "std.dl.call_void0" &&
                   arguments.len() == 1 {
                    host_dl.call_void0(
                        arguments[0].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_void1" &&
                   arguments.len() == 2 {
                    host_dl.call_void1(
                        arguments[0].int_data,
                        arguments[1].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_void2" &&
                   arguments.len() == 3 {
                    host_dl.call_void2(
                        arguments[0].int_data,
                        arguments[1].int_data,
                        arguments[2].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_void3" &&
                   arguments.len() == 4 {
                    host_dl.call_void3(
                        arguments[0].int_data,
                        arguments[1].int_data,
                        arguments[2].int_data,
                        arguments[3].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_f64_1" &&
                   arguments.len() == 2 {
                    return TreeValue.floating(
                        host_dl.call_f64_1(
                            arguments[0].int_data,
                            arguments[1].float_data))
                }
                if node.resolved ==
                       "std.dl.call_f64_i32" &&
                   arguments.len() == 3 {
                    return TreeValue.floating(
                        host_dl.call_f64_i32(
                            arguments[0].int_data,
                            arguments[1].float_data,
                            arguments[2].int_data))
                }
                if node.resolved ==
                       "std.dl.call_f32_1" &&
                   arguments.len() == 2 {
                    return TreeValue.floating(
                        host_dl.call_f32_1(
                            arguments[0].int_data,
                            arguments[1].float_data))
                }
                if node.resolved ==
                       "std.dl.call_f32_i32" &&
                   arguments.len() == 3 {
                    return TreeValue.floating(
                        host_dl.call_f32_i32(
                            arguments[0].int_data,
                            arguments[1].float_data,
                            arguments[2].int_data))
                }
            }
        }
        if node.resolved.starts_with("std.target.") {
            let target: TargetDescription =
                self.program.target
            if node.value == "triple" {
                return TreeValue.string(target.triple)
            }
            if node.value == "arch" {
                return TreeValue.string(target.arch)
            }
            if node.value == "os" {
                return TreeValue.string(target.os)
            }
            if node.value == "env" {
                return TreeValue.string(target.env)
            }
            if node.value == "object_format" {
                return TreeValue.string(
                    target.object_format)
            }
            if node.value == "endian" {
                return TreeValue.string(target.endian)
            }
            if node.value == "pointer_bits" {
                return TreeValue.integer(
                    target.pointer_bits)
            }
            if node.value == "pointer_size" {
                return TreeValue.integer(
                    target.pointer_size())
            }
            if node.value == "stack_align" {
                return TreeValue.integer(
                    target.stack_align)
            }
            if node.value == "max_simd_bits" {
                return TreeValue.integer(
                    target.max_simd_bits())
            }
        }
        if node.resolved == "std.cpu.has" &&
           arguments.len() == 1 {
            return TreeValue.boolean(
                host_cpu.has_name(
                    arguments[0].text))
        }
        if node.resolved == "std.cpu.has_name" &&
           arguments.len() == 1 {
            return TreeValue.boolean(
                host_cpu.has_name(
                    arguments[0].text))
        }
        if node.resolved == "std.asm.value" &&
           arguments.len() == 3 {
            // The checker only accepts templates whose meaning is known.
            // Current value rows are identity moves, so the reference
            // interpreter returns the already-evaluated input.
            return arguments[2]
        }
        if node.resolved == "std.asm.run" &&
           arguments.len() == 2 {
            // Current run rows are ordering barriers. This interpreter
            // executes one step at a time, so that order already holds.
            return TreeValue.unit()
        }
        if (node.resolved == "std.fmt.pad_left" ||
            node.resolved == "std.fmt.pad_right") &&
           arguments.len() == 2 {
            return TreeValue.string(
                if node.value == "pad_left" {
                    host_fmt.pad_left(
                        arguments[0].text,
                        arguments[1].int_data)
                } else {
                    host_fmt.pad_right(
                        arguments[0].text,
                        arguments[1].int_data)
                })
        }
        if node.resolved == "std.fmt.float" &&
           arguments.len() == 2 {
            return TreeValue.string(
                host_fmt.float(
                    arguments[0].float_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.fmt.decimal" &&
           arguments.len() == 2 {
            return TreeValue.string(
                host_fmt.decimal(
                    arguments[0].decimal_data,
                    arguments[1].int_data))
        }
        if node.resolved.starts_with(
               "std.intrinsic.") {
            unsafe {
                if node.value == "popcount" {
                    return TreeValue.integer(
                        host_intrinsic.popcount(
                            arguments[0].int_data))
                }
                if node.value == "leading_zeros" {
                    return TreeValue.integer(
                        host_intrinsic.leading_zeros(
                            arguments[0].int_data))
                }
                if node.value == "trailing_zeros" {
                    return TreeValue.integer(
                        host_intrinsic.trailing_zeros(
                            arguments[0].int_data))
                }
                if node.value == "bswap16" {
                    return TreeValue.integer(
                        host_intrinsic.bswap16(
                            arguments[0].int_data))
                }
                if node.value == "bswap32" {
                    return TreeValue.integer(
                        host_intrinsic.bswap32(
                            arguments[0].int_data))
                }
                if node.value == "bswap64" {
                    return TreeValue.integer(
                        host_intrinsic.bswap64(
                            arguments[0].int_data))
                }
                if node.value == "rotate_left" {
                    return TreeValue.integer(
                        host_intrinsic.rotate_left(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
                if node.value == "rotate_right" {
                    return TreeValue.integer(
                        host_intrinsic.rotate_right(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
                if node.value == "sqrt" {
                    return TreeValue.floating(
                        host_intrinsic.sqrt(
                            arguments[0].float_data))
                }
                if node.value == "sqrt32" {
                    let wide: float =
                        arguments[0].float_data
                    let input: f32 = wide as f32
                    let value: f32 =
                        host_intrinsic.sqrt32(input)
                    return TreeValue.floating(
                        value as float)
                }
                if node.value == "fma" {
                    return TreeValue.floating(
                        host_intrinsic.fma(
                            arguments[0].float_data,
                            arguments[1].float_data,
                            arguments[2].float_data))
                }
                if node.value == "fma32" {
                    let first_wide: float =
                        arguments[0].float_data
                    let second_wide: float =
                        arguments[1].float_data
                    let third_wide: float =
                        arguments[2].float_data
                    let first: f32 =
                        first_wide as f32
                    let second: f32 =
                        second_wide as f32
                    let third: f32 =
                        third_wide as f32
                    let value: f32 =
                        host_intrinsic.fma32(
                            first, second, third)
                    return TreeValue.floating(
                        value as float)
                }
                if node.value == "crc32c" {
                    return TreeValue.integer(
                        tree_crc32c_step(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
            }
            if node.value == "prefetch" ||
               node.value == "spin_hint" {
                return TreeValue.unit()
            }
        }
        return self.fail(
            node,
            "builtin call '{node.resolved}' is not in the Beans interpreter yet")
    }

    fn bytes_method(node: HirNode,
                    receiver: TreeValue,
                    arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "bytes" {
            return none
        }
        let data: Bytes =
            receiver.bytes_data.expect(
                "Bytes TreeValue payload")
        if node.value == "len" {
            return some(
                TreeValue.integer(data.len()))
        }
        if node.value == "reserve" &&
           arguments.len() == 2 {
            data.reserve(arguments[1].int_data)
            return some(receiver)
        }
        if node.value == "resize" &&
           arguments.len() == 2 {
            data.resize(arguments[1].int_data)
            return some(receiver)
        }
        if node.value == "fill" &&
           arguments.len() == 2 {
            data.fill(arguments[1].int_data)
            return some(receiver)
        }
        if node.value == "push" &&
           arguments.len() == 2 {
            data.push(arguments[1].int_data)
            return some(receiver)
        }
        if (node.value == "get" ||
            node.value == "get_u8") &&
           arguments.len() == 2 {
            let offset: int = arguments[1].int_data
            if offset < 0 || offset >= data.len() {
                self.fail_at(
                    node,
                    node.col,
                    "byte index {offset} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            return some(TreeValue.integer(
                if node.value == "get" {
                    data.get(offset)
                } else {
                    data.get_u8(offset)
                }))
        }
        if node.value == "set" &&
           arguments.len() == 3 {
            let offset: int = arguments[1].int_data
            if offset < 0 || offset >= data.len() {
                self.fail_at(
                    node,
                    node.col,
                    "byte index {offset} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            data.set(offset, arguments[2].int_data)
            return some(receiver)
        }
        var width: int = 0
        if node.value == "get_u16" ||
           node.value == "put_u16" {
            width = 2
        } else if node.value == "get_u32" ||
                  node.value == "put_u32" {
            width = 4
        } else if node.value == "get_u64" ||
                  node.value == "get_i64" ||
                  node.value == "put_u64" ||
                  node.value == "put_i64" {
            width = 8
        } else if node.value == "put_u8" {
            width = 1
        }
        if width != 0 && arguments.len() >= 2 {
            let offset: int = arguments[1].int_data
            if offset < 0 || width > data.len() ||
               offset > data.len() - width {
                let operation: string =
                    if node.value.starts_with("get") {
                        "read"
                    } else {
                        "write"
                    }
                let word: string =
                    if node.value.ends_with("_u8") {
                        "u8"
                    } else {
                        node.value.slice(
                            node.value.len() - 3,
                            node.value.len())
                    }
                self.fail_at(
                    node,
                    node.col,
                    "{word} {operation} at {offset} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            if node.value == "get_u16" {
                return some(TreeValue.integer(
                    data.get_u16(offset)))
            }
            if node.value == "get_u32" {
                return some(TreeValue.integer(
                    data.get_u32(offset)))
            }
            if node.value == "get_u64" {
                return some(TreeValue.integer(
                    data.get_u64(offset)))
            }
            if node.value == "get_i64" {
                return some(TreeValue.integer(
                    data.get_i64(offset)))
            }
            let value: int = arguments[2].int_data
            if node.value == "put_u8" {
                data.put_u8(offset, value)
            } else if node.value == "put_u16" {
                data.put_u16(offset, value)
            } else if node.value == "put_u32" {
                data.put_u32(offset, value)
            } else if node.value == "put_u64" {
                data.put_u64(offset, value)
            } else {
                data.put_i64(offset, value)
            }
            return some(receiver)
        }
        if node.value == "slice" &&
           arguments.len() == 3 {
            let start: int = arguments[1].int_data
            let end: int = arguments[2].int_data
            if start < 0 || end < start ||
               end > data.len() {
                self.fail_at(
                    node,
                    node.col,
                    "byte slice {start}..{end} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            return some(TreeValue.bytes(
                data.slice(start, end)))
        }
        if node.value == "copy_from" &&
           arguments.len() == 3 {
            let source: Bytes =
                arguments[1].bytes_data.expect(
                    "Bytes copy source")
            data.copy_from(
                source, arguments[2].int_data)
            return some(receiver)
        }
        if node.value == "append" &&
           arguments.len() == 2 {
            data.append(
                arguments[1].bytes_data.expect(
                    "Bytes append source"))
            return some(receiver)
        }
        if node.value == "append_string" &&
           arguments.len() == 2 {
            data.append_string(arguments[1].text)
            return some(receiver)
        }
        if node.value == "append_i64" &&
           arguments.len() == 2 {
            data.append_i64(arguments[1].int_data)
            return some(receiver)
        }
        if node.value == "append_range" &&
           arguments.len() == 4 {
            data.append_range(
                arguments[1].bytes_data.expect(
                    "Bytes range source"),
                arguments[2].int_data,
                arguments[3].int_data)
            return some(receiver)
        }
        if node.value == "to_string_until_nul" {
            return some(TreeValue.string(
                data.to_string_until_nul()))
        }
        if node.value == "to_string" {
            return some(TreeValue.string(
                data.to_string()))
        }
        if node.value == "append_uvarint" &&
           arguments.len() == 2 {
            data.append_uvarint(arguments[1].int_data)
            return some(receiver)
        }
        if node.value == "get_uvarint" &&
           arguments.len() == 2 {
            return some(TreeValue.integer(
                data.get_uvarint(
                    arguments[1].int_data)))
        }
        if node.value == "crc32" &&
           arguments.len() == 3 {
            return some(TreeValue.integer(
                data.crc32(
                    arguments[1].int_data,
                    arguments[2].int_data) as int))
        }
        return none
    }

    fn simd_scalar(node: HirNode,
                   operation: string,
                   left: TreeValue,
                   right: TreeValue) -> TreeValue {
        if left.kind == "int" &&
           right.kind == "int" {
            if operation == "min" {
                return if tree_value_less(left, right) {
                    left
                } else {
                    right
                }
            }
            if operation == "max" {
                return if tree_value_less(left, right) {
                    right
                } else {
                    left
                }
            }
            let binary: HirNode =
                new HirNode(
                    "binary", operation,
                    node.type, node.file,
                    node.line, node.col)
            return self.integer_binary(
                binary, left, right)
        }
        if left.kind == "float" &&
           right.kind == "float" {
            if operation == "add" ||
               operation == "+" {
                return TreeValue.floating(
                    left.float_data +
                    right.float_data)
            }
            if operation == "sub" ||
               operation == "-" {
                return TreeValue.floating(
                    left.float_data -
                    right.float_data)
            }
            if operation == "mul" ||
               operation == "*" {
                return TreeValue.floating(
                    left.float_data *
                    right.float_data)
            }
            if operation == "div" ||
               operation == "/" {
                return TreeValue.floating(
                    left.float_data /
                    right.float_data)
            }
            if operation == "min" {
                if left.float_data <
                   right.float_data {
                    return TreeValue.floating(
                        left.float_data)
                }
                return TreeValue.floating(
                    right.float_data)
            }
            if operation == "max" {
                if right.float_data <
                   left.float_data {
                    return TreeValue.floating(
                        left.float_data)
                }
                return TreeValue.floating(
                    right.float_data)
            }
            if operation == "gt" ||
               operation == ">" {
                return TreeValue.boolean(
                    right.float_data <
                    left.float_data)
            }
            if operation == "ge" ||
               operation == ">=" {
                return TreeValue.boolean(
                    right.float_data <=
                    left.float_data)
            }
            if operation == "lt" ||
               operation == "<" {
                return TreeValue.boolean(
                    left.float_data <
                    right.float_data)
            }
            if operation == "le" ||
               operation == "<=" {
                return TreeValue.boolean(
                    left.float_data <=
                    right.float_data)
            }
            if operation == "eq" ||
               operation == "==" {
                return TreeValue.boolean(
                    left.float_data ==
                    right.float_data)
            }
        }
        return self.fail(
            node,
            "SIMD scalar operation '{operation}' cannot evaluate {left.kind}")
    }

    fn simd_method(node: HirNode,
                   receiver: TreeValue,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "simd" {
            return none
        }
        if (node.value == "store" ||
            node.value == "store_unaligned") &&
           arguments.len() == 2 {
            let pointer: TreeValue =
                arguments[1]
            if pointer.memory_address == 0 {
                self.fail(
                    node, "null SIMD store")
                return some(TreeValue.unit())
            }
            let vector_type: HirType =
                node.children[0].type
            let vector: LayoutAnswer =
                self.layout(vector_type)
            if node.value == "store" &&
               pointer.memory_address %
                   (vector.value.size as u64) != 0 {
                self.fail(
                    node,
                    "unaligned SIMD store — use store_unaligned")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, pointer) {
                some(memory) => {
                    self.memory_write_value(
                        node, memory,
                        pointer.memory_address,
                        vector_type, receiver)
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "lane_count" {
            return some(TreeValue.integer(
                receiver.items.len()))
        }
        if node.value == "lane" &&
           arguments.len() == 2 {
            let lane: int = arguments[1].int_data
            if lane < 0 ||
               lane >= receiver.items.len() {
                self.fail_at(
                    node,
                    node.col,
                    "SIMD lane out of range (lanes {receiver.items.len()})")
                return some(TreeValue.unit())
            }
            return some(tree_value_copy(
                receiver.items[lane]))
        }
        if node.value == "with_lane" &&
           arguments.len() == 3 {
            let lane: int = arguments[1].int_data
            if lane < 0 ||
               lane >= receiver.items.len() {
                self.fail_at(
                    node,
                    node.col,
                    "SIMD lane out of range (lanes {receiver.items.len()})")
                return some(TreeValue.unit())
            }
            let result: TreeValue =
                tree_value_copy(receiver)
            result.items[lane] =
                tree_value_copy(arguments[2])
            return some(result)
        }
        if node.value == "sum" ||
           node.value == "product" {
            if receiver.items.len() == 0 {
                return some(TreeValue.integer(0))
            }
            var result: TreeValue =
                tree_value_copy(receiver.items[0])
            for index: int in
                1..receiver.items.len() {
                result = self.simd_scalar(
                    node,
                    if node.value == "sum" {
                        "+"
                    } else {
                        "*"
                    },
                    result,
                    receiver.items[index])
            }
            return some(result)
        }
        if node.value == "any_true" ||
           node.value == "all_true" {
            var answer: bool =
                node.value == "all_true"
            for lane: TreeValue in receiver.items {
                let set: bool =
                    if lane.kind == "bool" {
                        lane.bool_data
                    } else if lane.kind == "int" {
                        lane.uint_data != 0
                    } else {
                        lane.float_data != 0.0
                    }
                if node.value == "any_true" &&
                   set {
                    answer = true
                }
                if node.value == "all_true" &&
                   !set {
                    answer = false
                }
            }
            return some(TreeValue.boolean(answer))
        }
        if node.value == "bit_not" {
            let result: TreeValue =
                tree_value_copy(receiver)
            for index: int in
                0..result.items.len() {
                let lane: TreeValue =
                    result.items[index]
                result.items[index] =
                    if lane.int_unsigned {
                        TreeValue.unsigned_integer(
                            ~lane.uint_data,
                            lane.int_bits)
                    } else {
                        TreeValue.signed_integer(
                            ~lane.int_data,
                            lane.int_bits)
                    }
            }
            return some(result)
        }
        if node.value == "select" &&
           arguments.len() == 3 {
            let yes: TreeValue = arguments[1]
            let no: TreeValue = arguments[2]
            let result: TreeValue =
                tree_value_copy(yes)
            for index: int in
                0..receiver.items.len() {
                let mask: TreeValue =
                    receiver.items[index]
                let selected: bool =
                    if mask.kind == "bool" {
                        mask.bool_data
                    } else {
                        mask.uint_data != 0
                    }
                result.items[index] =
                    tree_value_copy(
                        if selected {
                            yes.items[index]
                        } else {
                            no.items[index]
                        })
            }
            return some(result)
        }
        let lane_wise: bool =
            node.value == "add" ||
            node.value == "sub" ||
            node.value == "mul" ||
            node.value == "div" ||
            node.value == "min" ||
            node.value == "max" ||
            node.value == "gt" ||
            node.value == "ge" ||
            node.value == "lt" ||
            node.value == "le" ||
            node.value == "eq" ||
            node.value == "bit_or" ||
            node.value == "bit_and" ||
            node.value == "bit_xor"
        if lane_wise &&
           arguments.len() == 2 {
            let other: TreeValue = arguments[1]
            let result: TreeValue =
                tree_value_copy(receiver)
            var operation: string = node.value
            if operation == "add" { operation = "+" }
            if operation == "sub" { operation = "-" }
            if operation == "mul" { operation = "*" }
            if operation == "div" { operation = "/" }
            if operation == "bit_or" { operation = "|" }
            if operation == "bit_and" { operation = "&" }
            if operation == "bit_xor" { operation = "^" }
            if operation == "gt" { operation = ">" }
            if operation == "ge" { operation = ">=" }
            if operation == "lt" { operation = "<" }
            if operation == "le" { operation = "<=" }
            if operation == "eq" { operation = "==" }
            for index: int in
                0..receiver.items.len() {
                result.items[index] =
                    self.simd_scalar(
                        node, operation,
                        receiver.items[index],
                        other.items[index])
            }
            return some(result)
        }
        if (node.value == "shl" ||
            node.value == "shr") &&
           arguments.len() == 2 {
            let result: TreeValue =
                tree_value_copy(receiver)
            let shift: TreeValue = arguments[1]
            let width: int =
                if receiver.items.len() == 0 {
                    0
                } else {
                    receiver.items[0].int_bits
                }
            if shift.int_data < 0 ||
               shift.int_data >= width {
                self.fail_at(
                    node,
                    node.col,
                    "SIMD shift outside 0..{width - 1}")
                return some(TreeValue.unit())
            }
            for index: int in
                0..receiver.items.len() {
                result.items[index] =
                    self.simd_scalar(
                        node,
                        if node.value == "shl" {
                            "<<"
                        } else {
                            ">>"
                        },
                        receiver.items[index],
                        shift)
            }
            return some(result)
        }
        return none
    }

    fn host_error(error: Error) -> TreeValue {
        return TreeValue.result_err(
            TreeValue.error(
                error.msg, error.kind))
    }

    fn host_bool_result(
        result: Result<bool>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.boolean(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_int_result(
        result: Result<int>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.integer(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_bytes_result(
        result: Result<Bytes>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.bytes(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_strings_result(
        result: Result<List<string>>) -> TreeValue {
        match result {
            ok(source) => {
                var values: List<TreeValue> = []
                for value: string in source {
                    values.push(
                        TreeValue.string(value))
                }
                return TreeValue.result_ok(
                    TreeValue.sequence(
                        "list", move values))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_string_result(
        result: Result<string>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.string(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_file_result(
        result: Result<File>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.file(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_mmap_result(
        result: Result<MMap>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.mmap(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn file_static(node: HirNode,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if node.resolved == "File.exists" &&
           arguments.len() == 1 {
            return some(TreeValue.boolean(
                File.exists(arguments[0].text)))
        }
        if node.resolved == "File.size" &&
           arguments.len() == 1 {
            return some(self.host_int_result(
                File.size(arguments[0].text)))
        }
        if node.resolved == "File.remove" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                File.remove(arguments[0].text)))
        }
        if node.resolved == "File.rename" &&
           arguments.len() == 2 {
            return some(self.host_bool_result(
                File.rename(
                    arguments[0].text,
                    arguments[1].text)))
        }
        if node.resolved == "File.open" &&
           arguments.len() == 2 {
            return some(self.host_file_result(
                File.open(
                    arguments[0].text,
                    arguments[1].text)))
        }
        if node.resolved == "Dir.temp_path" {
            return some(TreeValue.string(
                Dir.temp_path()))
        }
        if node.resolved == "Dir.exists" &&
           arguments.len() == 1 {
            return some(TreeValue.boolean(
                Dir.exists(arguments[0].text)))
        }
        if node.resolved == "Dir.create" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.create(arguments[0].text)))
        }
        if node.resolved == "Dir.create_all" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.create_all(arguments[0].text)))
        }
        if node.resolved == "Dir.list" &&
           arguments.len() == 1 {
            return some(self.host_strings_result(
                Dir.list(arguments[0].text)))
        }
        if node.resolved == "Dir.walk" &&
           arguments.len() == 1 {
            return some(self.host_strings_result(
                Dir.walk(arguments[0].text)))
        }
        if node.resolved == "Dir.remove" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.remove(arguments[0].text)))
        }
        if node.resolved == "Dir.remove_all" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.remove_all(arguments[0].text)))
        }
        if node.resolved == "Dir.sync" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.sync(arguments[0].text)))
        }
        if node.resolved == "MMap.open" &&
           arguments.len() == 2 {
            return some(self.host_mmap_result(
                MMap.open(
                    arguments[0].text,
                    arguments[1].bool_data)))
        }
        if node.resolved == "MMap.open_shared_memory" &&
           arguments.len() == 3 {
            return some(self.host_mmap_result(
                MMap.open_shared_memory(
                    arguments[0].text,
                    arguments[1].int_data,
                    arguments[2].bool_data)))
        }
        if node.resolved ==
               "MMap.unlink_shared_memory" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                MMap.unlink_shared_memory(
                    arguments[0].text)))
        }
        return none
    }

    fn file_method(node: HirNode,
                   receiver: TreeValue,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "file" {
            return none
        }
        let file: File =
            receiver.file_value.expect(
                "File TreeValue payload")
        if node.value == "read_at" &&
           arguments.len() == 3 {
            return some(self.host_bytes_result(
                file.read_at(
                    arguments[1].int_data,
                    arguments[2].int_data)))
        }
        if node.value == "write_at" &&
           arguments.len() == 3 {
            return some(self.host_int_result(
                file.write_at(
                    arguments[1].int_data,
                    arguments[2].bytes_data.expect(
                        "File.write_at Bytes"))))
        }
        if node.value == "read" &&
           arguments.len() == 2 {
            return some(self.host_bytes_result(
                file.read(
                    arguments[1].int_data)))
        }
        if node.value == "write" &&
           arguments.len() == 2 {
            return some(self.host_int_result(
                file.write(
                    arguments[1].bytes_data.expect(
                        "File.write Bytes"))))
        }
        if node.value == "seek" &&
           arguments.len() == 2 {
            return some(TreeValue.integer(
                file.seek(arguments[1].int_data)))
        }
        if node.value == "seek_from_end" &&
           arguments.len() == 2 {
            return some(TreeValue.integer(
                file.seek_from_end(
                    arguments[1].int_data)))
        }
        if node.value == "tell" {
            return some(TreeValue.integer(
                file.tell()))
        }
        if node.value == "size" {
            return some(self.host_int_result(
                file.size()))
        }
        if node.value == "truncate" &&
           arguments.len() == 2 {
            return some(self.host_bool_result(
                file.truncate(
                    arguments[1].int_data)))
        }
        if node.value == "sync" {
            return some(self.host_bool_result(
                file.sync()))
        }
        if node.value == "close" {
            return some(self.host_bool_result(
                file.close()))
        }
        if node.value == "lock" {
            return some(self.host_bool_result(
                file.lock()))
        }
        if node.value == "try_lock" {
            return some(self.host_bool_result(
                file.try_lock()))
        }
        if node.value == "unlock" {
            return some(self.host_bool_result(
                file.unlock()))
        }
        return none
    }

    fn mmap_method(node: HirNode,
                   receiver: TreeValue,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "mmap" {
            return none
        }
        let mapping: MMap =
            receiver.mmap_value.expect(
                "MMap TreeValue payload")
        if node.value == "len" {
            return some(TreeValue.integer(
                mapping.len()))
        }
        var width: int = 0
        if node.value == "get_u8" ||
           node.value == "put_u8" {
            width = 1
        } else if node.value == "get_u16" ||
                  node.value == "put_u16" {
            width = 2
        } else if node.value == "get_u32" ||
                  node.value == "put_u32" {
            width = 4
        } else if node.value == "get_u64" ||
                  node.value == "get_i64" ||
                  node.value == "put_u64" ||
                  node.value == "put_i64" {
            width = 8
        }
        if width != 0 &&
           arguments.len() >= 2 {
            let offset: int =
                arguments[1].int_data
            if offset < 0 || width > mapping.len() ||
               offset > mapping.len() - width {
                let word: string =
                    if width == 1 {
                        "u8"
                    } else if width == 2 {
                        "u16"
                    } else if width == 4 {
                        "u32"
                    } else if node.value.contains(
                                  "i64") {
                        "i64"
                    } else {
                        "u64"
                    }
                self.fail_at(
                    node,
                    node.col,
                    "{word} {if node.value.starts_with("get") { "read" } else { "write" }} at {offset} out of range (len {mapping.len()})")
                return some(TreeValue.unit())
            }
            if node.value == "get_u8" {
                return some(TreeValue.integer(
                    mapping.get_u8(offset)))
            }
            if node.value == "get_u16" {
                return some(TreeValue.integer(
                    mapping.get_u16(offset)))
            }
            if node.value == "get_u32" {
                return some(TreeValue.integer(
                    mapping.get_u32(offset)))
            }
            if node.value == "get_u64" {
                return some(TreeValue.integer(
                    mapping.get_u64(offset)))
            }
            if node.value == "get_i64" {
                return some(TreeValue.integer(
                    mapping.get_i64(offset)))
            }
            let value: int =
                arguments[2].int_data
            if node.value == "put_u8" {
                mapping.put_u8(offset, value)
            } else if node.value == "put_u16" {
                mapping.put_u16(offset, value)
            } else if node.value == "put_u32" {
                mapping.put_u32(offset, value)
            } else if node.value == "put_u64" {
                mapping.put_u64(offset, value)
            } else {
                mapping.put_i64(offset, value)
            }
            return some(receiver)
        }
        if node.value == "read" &&
           arguments.len() == 3 {
            return some(TreeValue.bytes(
                mapping.read(
                    arguments[1].int_data,
                    arguments[2].int_data)))
        }
        if node.value == "write" &&
           arguments.len() == 3 {
            mapping.write(
                arguments[1].int_data,
                arguments[2].bytes_data.expect(
                    "MMap.write Bytes"))
            return some(receiver)
        }
        if node.value == "flush" {
            return some(self.host_bool_result(
                mapping.flush()))
        }
        if node.value == "flush_range" &&
           arguments.len() == 3 {
            return some(self.host_bool_result(
                mapping.flush_range(
                    arguments[1].int_data,
                    arguments[2].int_data)))
        }
        if node.value == "resize" &&
           arguments.len() == 2 {
            return some(self.host_bool_result(
                mapping.resize(
                    arguments[1].int_data)))
        }
        if node.value == "close" {
            return some(self.host_bool_result(
                mapping.close()))
        }
        return none
    }

    fn stored_callback_dispatch(
        state: TreeStoredState,
        result: RawPtr<u8>,
        arguments: RawPtr<RawPtr<u8> >) {
        var values: List<TreeValue> = []
        unsafe {
            for index: int in
                0..state.parameters.len() {
                let storage: RawPtr<u8> =
                    arguments.offset(index).read()
                values.push(
                    self.ffi_read_host_storage(
                        state.function,
                        state.parameters[index],
                        storage))
            }
        }
        let returned: TreeValue =
            self.invoke_closure(
                new HirNode(
                    "stored_callback",
                    state.function.name,
                    state.result,
                    state.function.file,
                    state.function.line,
                    state.function.col),
                state.callable, move values)
        if self.failed ||
           state.result.name == "unit" {
            return
        }
        unsafe {
            if !result.is_null() {
                var bridges: List<TreeFfiMemory> = []
                self.ffi_write_host_storage(
                    state.function,
                    state.result,
                    returned, result, bridges)
            }
        }
    }

    fn stored_callback_source(
        full: HirType,
        context_index: int) -> string {
        let builder: CAbiTextBuilder =
            new CAbiTextBuilder(self.program)
        let result_type: HirType =
            if full.fn_parameter_count <
                   full.args.len() {
                full.args[
                    full.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        let c_result: string =
            builder.base(result_type)
        var declarations: List<string> = []
        var addresses: List<string> = []
        for index: int in
            0..full.fn_parameter_count {
            declarations.push(
                "{builder.base(full.args[index])} value{index}")
            if index != context_index {
                addresses.push("&value{index}")
            }
        }
        let parameters: string =
            if declarations.len() == 0 {
                "void"
            } else {
                declarations.join(", ")
            }
        var slots: int = addresses.len()
        if slots == 0 { slots = 1 }
        let address_text: string =
            if addresses.len() == 0 {
                "0"
            } else {
                addresses.join(", ")
            }
        var source: string =
            "#include <stdint.h>\n"
        source =
            "{source}typedef void (*BeansFfiDispatch)(void*, void*, void**);\n"
        source =
            "{source}static BeansFfiDispatch stored_dispatch;\n"
        source =
            "{source}{c_result} beans_stored_entry({parameters}) \{\n  void* context = (void*)value{context_index};\n  void* arguments[{slots}] = \{{address_text}\};\n"
        if c_result == "void" {
            source =
                "{source}  stored_dispatch(context, 0, arguments);\n\}\n"
        } else {
            source =
                "{source}  {c_result} result = \{0\};\n  stored_dispatch(context, &result, arguments);\n  return result;\n\}\n"
        }
        source =
            "{source}{ffi_export_attribute()}"
        source =
            "{source}void beans_ffi_bridge(void* symbol, void* result, void** args, BeansFfiDispatch dispatch, void** contexts) \{\n  (void)symbol; (void)args; (void)contexts;\n  stored_dispatch = dispatch;\n  *(void**)result = (void*)(uintptr_t)&beans_stored_entry;\n\}\n"
        return source
    }

    fn create_stored_callback(
        node: HirNode,
        arguments: List<TreeValue>) -> TreeValue {
        if arguments.len() != 2 ||
           node.type.args.len() != 1 {
            return self.fail(
                node,
                "StoredCallback.create needs an index and closure")
        }
        let prefix: string =
            "StoredCallback.create:"
        var context_index: int = -1
        if node.resolved.starts_with(prefix) {
            match node.resolved.slice(
                    prefix.len(),
                    node.resolved.len()).to_int() {
                ok(value) => {
                    context_index = value
                }
                err(error) => {}
            }
        }
        let full: HirType = node.type.args[0]
        if context_index < 0 ||
           context_index >=
               full.fn_parameter_count {
            return self.fail(
                node,
                "invalid StoredCallback userdata index")
        }
        var parameters: List<HirType> = []
        for index: int in
            0..full.fn_parameter_count {
            if index != context_index {
                parameters.push(full.args[index])
            }
        }
        let result_type: HirType =
            if full.fn_parameter_count <
                   full.args.len() {
                full.args[
                    full.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        let function: HirFunction =
            new HirFunction(
                "StoredCallback.create", "",
                "", false, node.file,
                node.line, node.col)
        function.result = result_type
        let state: Mutex<TreeStoredState> =
            new Mutex(
                new TreeStoredState(
                    self, function,
                    arguments[1],
                    move parameters,
                    result_type))
        let dispatch:
            StoredCallback<
                fn(RawPtr<u8>, RawPtr<u8>,
                   RawPtr<RawPtr<u8> >)> =
            StoredCallback.create(
                0,
                fn(result: RawPtr<u8>,
                   callback_arguments:
                       RawPtr<RawPtr<u8> >) {
                    state.with_lock(
                        fn(value: TreeStoredState) {
                            let owner:
                                TreeInterpreter =
                                value.owner
                            owner.stored_callback_dispatch(
                                value, result,
                                callback_arguments)
                        })
                })
        let source: string =
            self.stored_callback_source(
                full, context_index)
        let bridge: int =
            self.ffi_bridge(function, source)
        if self.failed {
            return TreeValue.unit()
        }
        var function_address: int = 0
        let context: RawPtr<u8> =
            dispatch.context()
        unsafe {
            let output:
                RawPtr<RawPtr<u8> > =
                RawPtr.alloc(1)
            beans_tree_ffi_invoke_bridge(
                RawPtr.from_address(
                    bridge as u64),
                RawPtr.null(),
                RawPtr.from_address(
                    output.address()),
                RawPtr.null(),
                dispatch.function(),
                RawPtr.null())
            function_address =
                output.read().address() as int
            output.free()
        }
        let id: int = self.next_object_id
        self.next_object_id += 1
        self.stored_callbacks[id] =
            new TreeStoredCallback(
                context, function_address, state)
        let result: TreeValue =
            new TreeValue("stored_callback")
        result.object_id = id
        return result
    }

    fn stored_callback_method(
        node: HirNode,
        receiver: TreeValue) ->
        Option<TreeValue> {
        if receiver.kind != "stored_callback" &&
           receiver.kind != "stored_function" {
            return none
        }
        match self.stored_callbacks.get(
                  receiver.object_id) {
            some(callback) => {
                if node.value == "function" {
                    let result: TreeValue =
                        new TreeValue(
                            "stored_function")
                    result.object_id =
                        receiver.object_id
                    result.int_data =
                        callback.function
                    return some(result)
                }
                if node.value == "context" {
                    unsafe {
                        return some(
                            TreeValue.host_pointer(
                                callback.context.address(),
                                new HirType("u8")))
                    }
                }
                if node.value == "close" {
                    unsafe {
                        beans_tree_stored_close(
                            callback.context)
                    }
                    self.stored_callbacks.remove(
                        receiver.object_id)
                    return some(TreeValue.unit())
                }
            }
            none => {
                self.fail(
                    node,
                    "StoredCallback is already closed")
                return some(TreeValue.unit())
            }
        }
        return none
    }

    fn raw_static(node: HirNode,
                  arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if node.resolved == "RawPtr.with_local" &&
           arguments.len() == 2 &&
           node.children.len() == 2 {
            let reference: TreeValue =
                arguments[0]
            if reference.kind != "reference" {
                self.fail(
                    node,
                    "RawPtr.with_local needs an inout local")
                return some(TreeValue.unit())
            }
            match reference.reference_frame {
                some(target) => {
                    match target.get(
                            reference.reference_binding) {
                        some(value) => {
                            let element: HirType =
                                node.children[0].type
                            let answer: LayoutAnswer =
                                self.layout(element)
                            if !answer.ok {
                                self.fail(
                                    node,
                                    "RawPtr.with_local cannot lay out {render_hir_type(element)}")
                                return some(
                                    TreeValue.unit())
                            }
                            let memory: TreeMemory =
                                self.allocate_memory(
                                    answer.value.size,
                                    answer.value.align)
                            if !self.memory_write_value(
                                   node, memory,
                                   memory.base,
                                   element, value) {
                                return some(
                                    TreeValue.unit())
                            }
                            let pointer: TreeValue =
                                TreeValue.raw_pointer(
                                    some(memory),
                                    memory.base, element)
                            self.invoke_closure(
                                node, arguments[1],
                                [pointer])
                            if !self.failed {
                                let changed: TreeValue =
                                    self.memory_read_value(
                                        node, memory,
                                        memory.base,
                                        element)
                                target.assign(
                                    reference.reference_binding,
                                    changed)
                            }
                            memory.freed = true
                            return some(
                                TreeValue.unit())
                        }
                        none => {}
                    }
                }
                none => {}
            }
            self.fail(
                node,
                "RawPtr.with_local local is no longer live")
            return some(TreeValue.unit())
        }
        let name: string =
            canonical_hir_name(node.type.name)
        if name == "Slice" &&
           node.value == "from_raw" &&
           arguments.len() == 2 {
            let length: int =
                arguments[1].int_data
            if length < 0 {
                self.fail_at(
                    node,
                    node.col,
                    "negative slice length")
                return some(TreeValue.unit())
            }
            if length > 0 &&
               arguments[0].memory_address == 0 {
                self.fail_at(
                    node,
                    node.col,
                    "null pointer with non-empty slice")
                return some(TreeValue.unit())
            }
            return some(TreeValue.slice(
                arguments[0], length))
        }
        if name != "RawPtr" ||
           node.type.args.len() != 1 {
            return none
        }
        let element: HirType =
            node.type.args[0]
        if node.value == "null" {
            return some(TreeValue.raw_pointer(
                none, 0, element))
        }
        if node.value == "from_address" &&
           arguments.len() == 1 {
            let address: u64 =
                arguments[0].uint_data
            return some(TreeValue.raw_pointer(
                self.find_memory(address),
                address, element))
        }
        if (node.value == "alloc" ||
            node.value == "alloc_aligned") &&
           arguments.len() >= 1 {
            let count: int =
                arguments[0].int_data
            if count < 0 {
                self.fail_at(
                    node,
                    node.col,
                    "negative raw allocation count")
                return some(TreeValue.unit())
            }
            let piece: LayoutAnswer =
                self.layout(element)
            if !piece.ok ||
               piece.value.size == 0 ||
               count > 288230376151711744 /
                       piece.value.size {
                self.fail_at(
                    node,
                    node.col,
                    "raw allocation too large")
                return some(TreeValue.unit())
            }
            var alignment: int =
                piece.value.align
            if node.value == "alloc_aligned" &&
               arguments.len() >= 2 {
                let requested: int =
                    arguments[1].int_data
                if requested <= 0 ||
                   !layout_power_of_two(requested) {
                    self.fail_at(
                        node,
                        node.col,
                        "raw allocation alignment must be a power of two")
                    return some(TreeValue.unit())
                }
                if requested < alignment {
                    self.fail_at(
                        node,
                        node.col,
                        "raw allocation alignment is below the element's own alignment")
                    return some(TreeValue.unit())
                }
                alignment = requested
            }
            let memory: TreeMemory =
                self.allocate_memory(
                    count * piece.value.size,
                    alignment)
            return some(TreeValue.raw_pointer(
                some(memory), memory.base, element))
        }
        return none
    }

    fn raw_method(node: HirNode,
                  receiver: TreeValue,
                  arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind == "slice" {
            let element: HirType =
                receiver.memory_type.expect(
                    "slice element type")
            let piece: LayoutAnswer =
                self.layout(element)
            if node.value == "len" {
                return some(TreeValue.integer(
                    receiver.slice_len))
            }
            if (node.value == "get" ||
                node.value == "set") &&
               arguments.len() >= 2 {
                let index: int =
                    arguments[1].int_data
                if index < 0 ||
                   index >= receiver.slice_len {
                    self.fail(
                        node,
                        "slice index {index} out of range (len {receiver.slice_len})")
                    return some(TreeValue.unit())
                }
                match self.pointer_memory(
                        node, receiver) {
                    some(memory) => {
                        let address: u64 =
                            receiver.memory_address +
                            ((index *
                              piece.value.size) as u64)
                        if node.value == "get" {
                            return some(
                                self.memory_read_value(
                                    node, memory,
                                    address, element))
                        }
                        self.memory_write_value(
                            node, memory, address,
                            element, arguments[2])
                        return some(TreeValue.unit())
                    }
                    none => {
                        return some(TreeValue.unit())
                    }
                }
            }
            if node.value == "subslice" &&
               arguments.len() == 3 {
                let start: int =
                    arguments[1].int_data
                let end: int =
                    arguments[2].int_data
                if start < 0 || end < start ||
                   end > receiver.slice_len {
                    self.fail(
                        node,
                        "slice range out of bounds")
                    return some(TreeValue.unit())
                }
                let pointer: TreeValue =
                    TreeValue.raw_pointer(
                        receiver.memory,
                        receiver.memory_address +
                            ((start *
                              piece.value.size) as u64),
                        element)
                pointer.memory_host =
                    receiver.memory_host
                return some(TreeValue.slice(
                    pointer, end - start))
            }
            if node.value == "as_ptr" {
                let pointer: TreeValue =
                    TreeValue.raw_pointer(
                        receiver.memory,
                        receiver.memory_address,
                        element)
                pointer.memory_host =
                    receiver.memory_host
                return some(pointer)
            }
            return none
        }
        if receiver.kind != "raw_ptr" {
            return none
        }
        let element: HirType =
            receiver.memory_type.expect(
                "raw pointer element type")
        let piece: LayoutAnswer =
            self.layout(element)
        if node.value == "is_null" {
            return some(TreeValue.boolean(
                receiver.memory_address == 0))
        }
        if node.value == "address" {
            return some(
                TreeValue.unsigned_integer(
                    receiver.memory_address, 64))
        }
        if node.value == "element_size" {
            return some(TreeValue.integer(
                piece.value.size))
        }
        if node.value == "element_align" {
            return some(TreeValue.integer(
                piece.value.align))
        }
        if node.value == "offset" &&
           arguments.len() == 2 {
            let address: int =
                receiver.memory_address as int +
                arguments[1].int_data *
                    piece.value.size
            let result: TreeValue =
                TreeValue.raw_pointer(
                    receiver.memory,
                    address as u64, element)
            result.memory_host =
                receiver.memory_host
            return some(result)
        }
        if node.value == "free" {
            if receiver.memory_host &&
               receiver.memory_address != 0 {
                unsafe {
                    let host: RawPtr<u8> =
                        RawPtr.from_address(
                            receiver.memory_address)
                    host.free()
                }
                return some(TreeValue.unit())
            }
            match receiver.memory {
                some(memory) => {
                    memory.freed = true
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "read" ||
           node.value == "read_volatile" ||
           node.value == "atomic_load" {
            if receiver.memory_address == 0 {
                self.fail_at(
                    node,
                    node.col,
                    if node.value == "atomic_load" {
                        "null raw pointer atomic load"
                    } else {
                        "null raw pointer read"
                    })
                return some(TreeValue.unit())
            }
            if node.value == "atomic_load" &&
               piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            if receiver.memory_host {
                return some(
                    self.host_pointer_read(
                        node, receiver, element))
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    if node.value ==
                           "atomic_load" {
                        var result: TreeValue =
                            TreeValue.unit()
                        memory.atomic_guard.with_lock(
                            fn(locked: bool) {
                                result =
                                    self.memory_read_value(
                                        node, memory,
                                        receiver.memory_address,
                                        element)
                            })
                        return some(result)
                    }
                    return some(
                        self.memory_read_value(
                            node, memory,
                            receiver.memory_address,
                            element))
                }
                none => {
                    return some(TreeValue.unit())
                }
            }
        }
        if node.value == "write" ||
           node.value == "write_volatile" ||
           node.value == "atomic_store" {
            if receiver.memory_address == 0 {
                self.fail_at(
                    node,
                    node.col,
                    if node.value == "atomic_store" {
                        "null raw pointer atomic store"
                    } else {
                        "null raw pointer write"
                    })
                return some(TreeValue.unit())
            }
            if node.value == "atomic_store" &&
               piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            if receiver.memory_host {
                self.host_pointer_write(
                    node, receiver, element,
                    arguments[1])
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    if node.value ==
                           "atomic_store" {
                        memory.atomic_guard.with_lock(
                            fn(locked: bool) {
                                self.memory_write_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element,
                                    arguments[1])
                            })
                        return some(
                            TreeValue.unit())
                    }
                    self.memory_write_value(
                        node, memory,
                        receiver.memory_address,
                        element, arguments[1])
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "copy_from" &&
           arguments.len() == 3 {
            let count: int =
                arguments[2].int_data
            if count < 0 {
                self.fail(
                    node,
                    "negative raw copy count")
                return some(TreeValue.unit())
            }
            let bytes: int =
                count * piece.value.size
            if bytes > 0 &&
               (receiver.memory_address == 0 ||
                arguments[1].memory_address == 0) {
                self.fail(
                    node, "null raw pointer copy")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(destination) => {
                    match self.pointer_memory(
                            node, arguments[1]) {
                        some(source) => {
                            if !self.memory_contains(
                                   destination,
                                   receiver.memory_address,
                                   bytes) ||
                               !self.memory_contains(
                                   source,
                                   arguments[1].memory_address,
                                   bytes) {
                                self.fail(
                                    node,
                                    "invalid raw pointer copy")
                                return some(
                                    TreeValue.unit())
                            }
                            let from: int =
                                (arguments[1].memory_address -
                                 source.base) as int
                            let temporary: Bytes =
                                source.data.slice(
                                    from, from + bytes)
                            let at: int =
                                (receiver.memory_address -
                                 destination.base) as int
                            let copied_memory: Bytes =
                                destination.data.copy_from(
                                    temporary, at)
                        }
                        none => {}
                    }
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "fill_zero" &&
           arguments.len() == 2 {
            let count: int =
                arguments[1].int_data
            if count < 0 {
                self.fail(
                    node,
                    "negative raw zero count")
                return some(TreeValue.unit())
            }
            let bytes: int =
                count * piece.value.size
            if bytes > 0 &&
               receiver.memory_address == 0 {
                self.fail(
                    node, "null raw pointer zero")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    let start: int =
                        (receiver.memory_address -
                         memory.base) as int
                    for index: int in 0..bytes {
                        memory.data.set(
                            start + index, 0)
                    }
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "atomic_fetch_add" &&
           arguments.len() == 2 {
            if receiver.memory_address == 0 {
                self.fail(
                    node,
                    "null raw pointer atomic fetch_add")
                return some(TreeValue.unit())
            }
            if piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    var old: TreeValue =
                        TreeValue.unit()
                    memory.atomic_guard.with_lock(
                        fn(locked: bool) {
                            old =
                                self.memory_read_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element)
                            let updated: TreeValue =
                                if old.int_unsigned {
                                    TreeValue.unsigned_integer(
                                        old.uint_data +
                                            arguments[1].uint_data,
                                        old.int_bits)
                                } else {
                                    TreeValue.signed_integer(
                                        old.int_data +
                                            arguments[1].int_data,
                                        old.int_bits)
                                }
                            self.memory_write_value(
                                node, memory,
                                receiver.memory_address,
                                element, updated)
                        })
                    return some(old)
                }
                none => {
                    return some(TreeValue.unit())
                }
            }
        }
        if node.value ==
               "atomic_compare_exchange" &&
           arguments.len() == 3 {
            if receiver.memory_address == 0 {
                self.fail(
                    node,
                    "null raw pointer atomic_compare_exchange")
                return some(TreeValue.unit())
            }
            if piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    var equal: bool = false
                    memory.atomic_guard.with_lock(
                        fn(locked: bool) {
                            let old: TreeValue =
                                self.memory_read_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element)
                            equal =
                                tree_value_equal(
                                    old, arguments[1])
                            if equal {
                                self.memory_write_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element,
                                    arguments[2])
                            }
                        })
                    return some(
                        TreeValue.boolean(equal))
                }
                none => {
                    return some(TreeValue.unit())
                }
            }
        }
        return none
    }

    fn atomic_snapshot(
        receiver: TreeValue) -> TreeValue {
        var result: TreeValue =
            TreeValue.unit()
        match receiver.mutex_cell {
            some(cell) => {
                cell.with_lock(fn(state: TreeMutexCell) {
                    result =
                        tree_value_copy(state.value)
                })
            }
            none => {}
        }
        return result
    }

    fn atomic_replace(
        receiver: TreeValue,
        value: TreeValue) {
        match receiver.mutex_cell {
            some(cell) => {
                cell.with_lock(fn(state: TreeMutexCell) {
                    state.value =
                        tree_value_copy(value)
                })
            }
            none => {}
        }
    }

    fn atomic_method(
        node: HirNode, receiver: TreeValue,
        arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "atomic" ||
           receiver.mutex_cell.is_none() {
            return none
        }
        if node.value == "load" {
            return some(
                self.atomic_snapshot(receiver))
        }
        if node.value == "store" &&
           arguments.len() >= 2 {
            self.atomic_replace(
                receiver, arguments[1])
            return some(TreeValue.unit())
        }
        if node.value == "exchange" &&
           arguments.len() >= 2 {
            var previous: TreeValue =
                TreeValue.unit()
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeMutexCell) {
                        previous =
                            tree_value_copy(
                                state.value)
                        state.value =
                            tree_value_copy(
                                arguments[1])
                    })
                }
                none => {}
            }
            return some(previous)
        }
        if node.value == "compare_exchange" &&
           arguments.len() >= 3 {
            var equal: bool = false
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeMutexCell) {
                        equal =
                            tree_value_equal(
                                state.value,
                                arguments[1])
                        if equal {
                            state.value =
                                tree_value_copy(
                                    arguments[2])
                        }
                    })
                }
                none => {}
            }
            return some(TreeValue.boolean(equal))
        }
        if (node.value == "fetch_add" ||
            node.value == "fetch_sub" ||
            node.value == "fetch_and" ||
            node.value == "fetch_or" ||
            node.value == "fetch_xor" ||
            node.value == "add_and_get") &&
           arguments.len() >= 2 {
            var previous: TreeValue =
                TreeValue.unit()
            // AtomicInt.add_and_get is the one op here that hands back the
            // value it wrote; the fetch_* family reports what was there.
            var updated: TreeValue =
                TreeValue.unit()
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeMutexCell) {
                        previous =
                            tree_value_copy(
                                state.value)
                        let left: u64 =
                            previous.uint_data
                        let right: u64 =
                            arguments[1].uint_data
                        var raw: u64 = left
                        if node.value == "fetch_add" ||
                           node.value == "add_and_get" {
                            raw = left + right
                        } else if node.value ==
                                      "fetch_sub" {
                            raw = left - right
                        } else if node.value ==
                                      "fetch_and" {
                            raw = left & right
                        } else if node.value ==
                                      "fetch_or" {
                            raw = left | right
                        } else {
                            raw = left ^ right
                        }
                        state.value =
                            if previous.int_unsigned {
                                TreeValue.unsigned_integer(
                                    raw,
                                    previous.int_bits)
                            } else {
                                TreeValue.signed_integer(
                                    tree_signed_from_bits(
                                        raw,
                                        previous.int_bits),
                                    previous.int_bits)
                            }
                        updated =
                            tree_value_copy(state.value)
                    })
                }
                none => {}
            }
            if node.value == "add_and_get" {
                return some(updated)
            }
            return some(previous)
        }
        if node.value == "wait" &&
           arguments.len() >= 2 {
            var waiting: bool = true
            for waiting {
                var signal:
                    Option<Channel<int>> = none
                match receiver.mutex_cell {
                    some(cell) => {
                        cell.with_lock(
                            fn(state: TreeMutexCell) {
                                if tree_value_equal(
                                       state.value,
                                       arguments[1]) {
                                    let channel:
                                        Channel<int> =
                                        new Channel<int>(1)
                                    state.waiters.push(
                                        channel)
                                    signal =
                                        some(channel)
                                } else {
                                    waiting = false
                                }
                            })
                    }
                    none => {
                        waiting = false
                    }
                }
                match signal {
                    some(channel) => {
                        channel.receive()
                    }
                    none => {}
                }
            }
            return some(TreeValue.unit())
        }
        if node.value == "wait_timeout" &&
           arguments.len() >= 3 {
            if !tree_value_equal(
                   self.atomic_snapshot(receiver),
                   arguments[1]) {
                return some(
                    TreeValue.boolean(true))
            }
            let started: int =
                host_time.monotonic_nanos()
            let budget: int =
                arguments[2].int_data
            for host_time.monotonic_nanos() -
                    started < budget {
                host_time.sleep_nanos(
                    if budget < 100000 {
                        budget
                    } else {
                        100000
                    })
                if !tree_value_equal(
                       self.atomic_snapshot(
                           receiver),
                       arguments[1]) {
                    return some(
                        TreeValue.boolean(true))
                }
            }
            return some(TreeValue.boolean(false))
        }
        if node.value == "notify_all" ||
           node.value == "notify_one" {
            var woke: int = 0
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(
                        fn(state: TreeMutexCell) {
                            if node.value ==
                                   "notify_one" {
                                match state.waiters.pop() {
                                    some(waiter) => {
                                        waiter.send(1)
                                        woke = 1
                                    }
                                    none => {}
                                }
                            } else {
                                woke =
                                    state.waiters.len()
                                for waiter:
                                        Channel<int> in
                                    state.waiters {
                                    waiter.send(1)
                                }
                                state.waiters = []
                            }
                        })
                }
                none => {}
            }
            return some(
                TreeValue.integer(woke))
        }
        return none
    }

    fn builtin_method(node: HirNode,
                      arguments: List<TreeValue>) -> TreeValue {
        if arguments.len() == 0 {
            return self.fail(node, "method has no receiver")
        }
        let receiver: TreeValue = arguments[0]
        match self.stored_callback_method(
                node, receiver) {
            some(value) => { return value }
            none => {}
        }
        match self.mmap_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.file_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.raw_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        if receiver.kind == "atomic" {
            match self.atomic_method(
                    node, receiver, arguments) {
                some(value) => { return value }
                none => {}
            }
        }
        match self.bytes_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.simd_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        if receiver.kind == "int" &&
           node.value == "abs" {
            return TreeValue.integer(
                receiver.int_data.abs())
        }
        if receiver.kind == "float" &&
           node.value == "abs" {
            return TreeValue.floating(
                receiver.float_data.abs())
        }
        if receiver.kind == "float" &&
           node.value == "round" {
            return TreeValue.integer(
                receiver.float_data.round())
        }
        if receiver.kind == "decimal" &&
           node.value == "abs" {
            return TreeValue.decimal_value(
                receiver.decimal_data.abs())
        }
        if receiver.kind == "decimal" &&
           node.value == "round" &&
           arguments.len() >= 2 {
            let places: int =
                arguments[1].int_data
            if arguments.len() < 3 ||
               arguments[2].text == "half_even" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.half_even))
            }
            if arguments[2].text == "half_away" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.half_away))
            }
            if arguments[2].text == "toward_zero" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.toward_zero))
            }
            if arguments[2].text == "floor" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.floor))
            }
            return TreeValue.decimal_value(
                receiver.decimal_data.round(
                    places,
                    RoundingMode.ceil))
        }
        if node.value == "len" {
            if receiver.kind == "string" {
                return TreeValue.integer(
                    receiver.text.len())
            }
            if receiver.kind == "list" ||
               receiver.kind == "array" {
                return TreeValue.integer(
                    receiver.items.len())
            }
            if receiver.kind == "map" {
                return TreeValue.integer(
                    receiver.map_values.len())
            }
        }
        if node.value == "is_empty" {
            if receiver.kind == "string" {
                return TreeValue.boolean(
                    receiver.text.len() == 0)
            }
            if receiver.kind == "list" ||
               receiver.kind == "array" {
                return TreeValue.boolean(
                    receiver.items.len() == 0)
            }
            if receiver.kind == "map" {
                return TreeValue.boolean(
                    receiver.map_values.len() == 0)
            }
        }
        if receiver.kind == "string" &&
           (node.value == "last" ||
            node.value == "first" ||
            node.value == "repeat") &&
           arguments.len() == 2 &&
           arguments[1].kind == "int" {
            let count: int =
                arguments[1].int_data
            if node.value == "last" {
                return TreeValue.string(
                    receiver.text.last(count))
            }
            if node.value == "first" {
                return TreeValue.string(
                    receiver.text.first(count))
            }
            return TreeValue.string(
                receiver.text.repeat(count))
        }
        if receiver.kind == "string" &&
           (node.value == "contains" ||
            node.value == "starts_with" ||
            node.value == "ends_with") &&
           arguments.len() == 2 &&
           arguments[1].kind == "string" {
            if node.value == "contains" {
                return TreeValue.boolean(
                    receiver.text.contains(
                        arguments[1].text))
            }
            if node.value == "starts_with" {
                return TreeValue.boolean(
                    receiver.text.starts_with(
                        arguments[1].text))
            }
            return TreeValue.boolean(
                receiver.text.ends_with(
                    arguments[1].text))
        }
        if receiver.kind == "string" &&
           node.value == "slice" &&
           arguments.len() == 3 {
            let start: int = arguments[1].int_data
            let end: int = arguments[2].int_data
            if start < 0 || end < start ||
               end > receiver.text.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "slice {start}..{end} out of range (len {receiver.text.len()})")
            }
            return TreeValue.string(
                receiver.text.slice(
                    start, end))
        }
        if receiver.kind == "string" &&
           node.value == "byte_at" &&
           arguments.len() == 2 {
            return TreeValue.integer(
                receiver.text.byte_at(
                    arguments[1].int_data))
        }
        if receiver.kind == "string" &&
           (node.value == "find" ||
            node.value == "rfind") &&
           arguments.len() == 2 {
            let found: Option<int> =
                if node.value == "find" {
                    receiver.text.find(
                        arguments[1].text)
                } else {
                    receiver.text.rfind(
                        arguments[1].text)
                }
            match found {
                some(index) => {
                    return TreeValue.option_some(
                        TreeValue.integer(index))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if receiver.kind == "string" &&
           (node.value == "lines" ||
            node.value == "chars") {
            let source: List<string> =
                if node.value == "lines" {
                    receiver.text.lines()
                } else {
                    receiver.text.chars()
                }
            var values: List<TreeValue> = []
            for value: string in source {
                values.push(TreeValue.string(value))
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if receiver.kind == "string" &&
           node.value == "count_chars" &&
           arguments.len() == 3 {
            return TreeValue.integer(
                receiver.text.count_chars(
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if receiver.kind == "string" &&
           node.value == "find_byte" &&
           arguments.len() == 3 {
            return TreeValue.integer(
                receiver.text.find_byte(
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if receiver.kind == "string" &&
           node.value == "range_equals" &&
           arguments.len() == 4 {
            return TreeValue.boolean(
                receiver.text.range_equals(
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].text))
        }
        if receiver.kind == "string" &&
           node.value == "parse_int_range_or" &&
           arguments.len() == 4 {
            return TreeValue.integer(
                receiver.text.parse_int_range_or(
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].int_data))
        }
        if receiver.kind == "string" &&
           (node.value == "trim" ||
            node.value == "trim_start" ||
            node.value == "trim_end" ||
            node.value == "to_upper" ||
            node.value == "to_lower") {
            if node.value == "trim" {
                return TreeValue.string(
                    receiver.text.trim())
            }
            if node.value == "trim_start" {
                return TreeValue.string(
                    receiver.text.trim_start())
            }
            if node.value == "trim_end" {
                return TreeValue.string(
                    receiver.text.trim_end())
            }
            if node.value == "to_upper" {
                return TreeValue.string(
                    receiver.text.to_upper())
            }
            return TreeValue.string(
                receiver.text.to_lower())
        }
        if receiver.kind == "string" &&
           node.value == "replace" &&
           arguments.len() == 3 {
            return TreeValue.string(
                receiver.text.replace(
                    arguments[1].text,
                    arguments[2].text))
        }
        if receiver.kind == "string" &&
           node.value == "split" &&
           arguments.len() == 2 {
            var pieces: List<TreeValue> = []
            for piece: string in receiver.text.split(
                arguments[1].text) {
                pieces.push(TreeValue.string(piece))
            }
            return TreeValue.sequence(
                "list", move pieces)
        }
        if receiver.kind == "list" &&
           node.value == "push" &&
           arguments.len() == 2 {
            receiver.items.push(
                tree_value_copy(arguments[1]))
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "insert" &&
           arguments.len() == 3 {
            receiver.items.insert(
                arguments[1].int_data,
                tree_value_copy(arguments[2]))
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "pop" {
            if receiver.items.len() == 0 {
                return TreeValue.option_none()
            }
            return TreeValue.option_some(
                receiver.items.pop().expect("non-empty list"))
        }
        if receiver.kind == "list" &&
           (node.value == "first" ||
            node.value == "last") {
            if receiver.items.len() == 0 {
                return TreeValue.option_none()
            }
            let index: int =
                if node.value == "first" {
                    0
                } else {
                    receiver.items.len() - 1
                }
            return TreeValue.option_some(
                tree_value_copy(
                    receiver.items[index]))
        }
        if receiver.kind == "list" &&
           (node.value == "contains" ||
            node.value == "index_of") &&
           arguments.len() == 2 {
            for index: int in 0..receiver.items.len() {
                if tree_value_equal(
                       receiver.items[index],
                       arguments[1]) {
                    if node.value == "contains" {
                        return TreeValue.boolean(true)
                    }
                    return TreeValue.option_some(
                        TreeValue.integer(index))
                }
            }
            if node.value == "contains" {
                return TreeValue.boolean(false)
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "list" &&
           node.value == "remove" &&
           arguments.len() == 2 {
            let index: int = arguments[1].int_data
            if index < 0 ||
               index >= receiver.items.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "list index {index} out of range (len {receiver.items.len()})")
            }
            return receiver.items.remove(
                index)
        }
        if receiver.kind == "list" &&
           node.value == "clear" {
            receiver.items = []
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "clone" {
            var copy: List<TreeValue> = []
            for value: TreeValue in receiver.items {
                copy.push(tree_value_copy(value))
            }
            return TreeValue.sequence(
                "list", move copy)
        }
        if receiver.kind == "list" &&
           node.value == "reverse" {
            var left: int = 0
            var right: int =
                receiver.items.len() - 1
            for left < right {
                let saved: TreeValue =
                    receiver.items[left]
                receiver.items[left] =
                    receiver.items[right]
                receiver.items[right] = saved
                left += 1
                right -= 1
            }
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "slice" &&
           arguments.len() == 3 {
            let start: int = arguments[1].int_data
            let end: int = arguments[2].int_data
            if start < 0 || end < start ||
               end > receiver.items.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "list slice {start}..{end} out of range (len {receiver.items.len()})")
            }
            var values: List<TreeValue> = []
            for index: int in start..end {
                values.push(receiver.items[index])
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if receiver.kind == "list" &&
           (node.value == "min" ||
            node.value == "max") {
            if receiver.items.len() == 0 {
                return TreeValue.option_none()
            }
            var best: TreeValue =
                receiver.items[0]
            for index: int in
                1..receiver.items.len() {
                let candidate: TreeValue =
                    receiver.items[index]
                let replace: bool =
                    if node.value == "min" {
                        tree_value_less(
                            candidate, best)
                    } else {
                        tree_value_less(
                            best, candidate)
                    }
                if replace { best = candidate }
            }
            return TreeValue.option_some(best)
        }
        if receiver.kind == "list" &&
           node.value == "join" &&
           arguments.len() == 2 {
            var pieces: List<string> = []
            for value: TreeValue in receiver.items {
                pieces.push(tree_value_text(value))
            }
            return TreeValue.string(
                pieces.join(arguments[1].text))
        }
        if receiver.kind == "list" &&
           (node.value == "sort" ||
            node.value == "sort_by" ||
            node.value == "sort_by_key") {
            var keys: List<TreeValue> = []
            if node.value == "sort_by_key" &&
               arguments.len() == 2 {
                for value: TreeValue in receiver.items {
                    keys.push(
                        self.invoke_closure(
                            node, arguments[1], [value]))
                }
            }
            var index: int = 1
            for index < receiver.items.len() {
                var current: int = index
                for current > 0 {
                    var less: bool = false
                    if node.value == "sort" {
                        less = tree_value_less(
                            receiver.items[current],
                            receiver.items[current - 1])
                    } else if node.value == "sort_by" &&
                              arguments.len() == 2 {
                        let compared: TreeValue =
                            self.invoke_closure(
                                node, arguments[1],
                                [receiver.items[current],
                                 receiver.items[current - 1]])
                        less = self.truth(node, compared)
                    } else if node.value ==
                                  "sort_by_key" {
                        less = tree_value_less(
                            keys[current],
                            keys[current - 1])
                    }
                    if !less { break }
                    let saved: TreeValue =
                        receiver.items[current - 1]
                    receiver.items[current - 1] =
                        receiver.items[current]
                    receiver.items[current] = saved
                    if node.value == "sort_by_key" {
                        let saved_key: TreeValue =
                            keys[current - 1]
                        keys[current - 1] =
                            keys[current]
                        keys[current] = saved_key
                    }
                    current -= 1
                }
                index += 1
            }
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "get" &&
           arguments.len() == 2 &&
           arguments[1].kind == "int" {
            let index: int = arguments[1].int_data
            if index >= 0 &&
               index < receiver.items.len() {
                return TreeValue.option_some(
                    tree_value_copy(
                        receiver.items[index]))
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "map" &&
           (node.value == "set" ||
            node.value == "insert") &&
           arguments.len() == 3 {
            let encoded: string =
                self.map_key(
                    receiver, arguments[1])
            let inserted: bool =
                !receiver.map_values.contains_key(encoded)
            if node.value == "insert" &&
               !inserted {
                return TreeValue.boolean(false)
            }
            if !receiver.map_values.contains_key(
                   encoded) {
                receiver.map_keys.push(
                    tree_value_copy(arguments[1]))
            }
            receiver.map_values[encoded] =
                tree_value_copy(arguments[2])
            return if node.value == "insert" {
                TreeValue.boolean(inserted)
            } else {
                TreeValue.unit()
            }
        }
        if receiver.kind == "map" &&
           node.value == "get" &&
           arguments.len() == 2 {
            match receiver.map_values.get(
                self.map_key(
                    receiver, arguments[1])) {
                some(value) => {
                    return TreeValue.option_some(
                        tree_value_copy(value))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if receiver.kind == "map" &&
           node.value == "contains_key" &&
           arguments.len() == 2 {
            return TreeValue.boolean(
                receiver.map_values.contains_key(
                    self.map_key(
                        receiver, arguments[1])))
        }
        if receiver.kind == "map" &&
           node.value == "remove" &&
           arguments.len() == 2 {
            let encoded: string =
                self.map_key(
                    receiver, arguments[1])
            if !receiver.map_values.contains_key(encoded) {
                return TreeValue.boolean(false)
            }
            receiver.map_values.remove(encoded)
            var kept: List<TreeValue> = []
            for key: TreeValue in receiver.map_keys {
                if tree_value_key(key) != encoded {
                    kept.push(key)
                }
            }
            receiver.map_keys = move kept
            return TreeValue.boolean(true)
        }
        if receiver.kind == "map" &&
           node.value == "keys" {
            var keys: List<TreeValue> = []
            for key: TreeValue in receiver.map_keys {
                keys.push(tree_value_copy(key))
            }
            return TreeValue.sequence(
                "list", move keys)
        }
        if receiver.kind == "map" &&
           node.value == "values" {
            var values: List<TreeValue> = []
            for key: TreeValue in receiver.map_keys {
                match receiver.map_values.get(
                    tree_value_key(key)) {
                    some(value) => {
                        values.push(
                            tree_value_copy(value))
                    }
                    none => {}
                }
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if receiver.kind == "map" &&
           node.value == "clear" {
            receiver.map_keys = []
            receiver.map_values = {}
            return TreeValue.unit()
        }
        if receiver.kind == "map" &&
           node.value == "clone" {
            let result: TreeValue =
                new TreeValue("map")
            for key: TreeValue in receiver.map_keys {
                let encoded: string =
                    tree_value_key(key)
                result.map_keys.push(
                    tree_value_copy(key))
                result.map_values[encoded] =
                    tree_value_copy(
                        receiver.map_values[encoded])
            }
            return result
        }
        if receiver.kind == "atomic" &&
           receiver.items.len() == 1 {
            if node.value == "load" {
                return tree_value_copy(
                    receiver.items[0])
            }
            if node.value == "store" &&
               arguments.len() >= 2 {
                receiver.items[0] =
                    tree_value_copy(arguments[1])
                return TreeValue.unit()
            }
            if node.value == "exchange" &&
               arguments.len() >= 2 {
                let previous: TreeValue =
                    tree_value_copy(
                        receiver.items[0])
                receiver.items[0] =
                    tree_value_copy(arguments[1])
                return previous
            }
            if node.value == "compare_exchange" &&
               arguments.len() >= 3 {
                let equal: bool =
                    tree_value_equal(
                        receiver.items[0],
                        arguments[1])
                if equal {
                    receiver.items[0] =
                        tree_value_copy(
                            arguments[2])
                }
                return TreeValue.boolean(equal)
            }
            if (node.value == "fetch_add" ||
                node.value == "fetch_sub" ||
                node.value == "fetch_and" ||
                node.value == "fetch_or" ||
                node.value == "fetch_xor") &&
               arguments.len() >= 2 {
                let previous: TreeValue =
                    tree_value_copy(
                        receiver.items[0])
                let left: u64 =
                    previous.uint_data
                let right: u64 =
                    arguments[1].uint_data
                var raw: u64 = left
                if node.value == "fetch_add" {
                    raw = left + right
                } else if node.value ==
                              "fetch_sub" {
                    raw = left - right
                } else if node.value ==
                              "fetch_and" {
                    raw = left & right
                } else if node.value ==
                              "fetch_or" {
                    raw = left | right
                } else {
                    raw = left ^ right
                }
                receiver.items[0] =
                    if previous.int_unsigned {
                        TreeValue.unsigned_integer(
                            raw,
                            previous.int_bits)
                    } else {
                        TreeValue.signed_integer(
                            tree_signed_from_bits(
                                raw,
                                previous.int_bits),
                            previous.int_bits)
                    }
                return previous
            }
            if node.value == "wait" {
                return TreeValue.unit()
            }
            if node.value == "wait_timeout" &&
               arguments.len() >= 2 {
                return TreeValue.boolean(
                    !tree_value_equal(
                        receiver.items[0],
                        arguments[1]))
            }
            if node.value == "notify_all" ||
               node.value == "notify_one" {
                return TreeValue.integer(0)
            }
        }
        if (receiver.kind == "box" ||
            receiver.kind == "mutex") &&
           node.value == "get" &&
           receiver.items.len() == 1 {
            return receiver.items[0]
        }
        if receiver.kind == "atomic" &&
           node.value == "load" &&
           receiver.items.len() == 1 {
            return receiver.items[0]
        }
        if receiver.kind == "shared" &&
           node.value == "get" {
            match receiver.shared_value {
                some(value) => {
                    return tree_value_copy(
                        value.get())
                }
                none => {}
            }
        }
        if receiver.kind == "box" &&
           node.value == "set" &&
           arguments.len() == 2 {
            receiver.items[0] = arguments[1]
            return TreeValue.unit()
        }
        if receiver.kind == "atomic" &&
           node.value == "store" &&
           arguments.len() == 2 {
            receiver.items[0] = arguments[1]
            return TreeValue.unit()
        }
        if receiver.kind == "atomic" &&
           node.value == "add_and_get" &&
           arguments.len() == 2 &&
           receiver.items.len() == 1 {
            let next: int =
                receiver.items[0].int_data +
                arguments[1].int_data
            receiver.items[0] =
                TreeValue.integer(next)
            return TreeValue.integer(next)
        }
        if receiver.kind == "shared" &&
           node.value == "downgrade" {
            let result: TreeValue =
                new TreeValue("weak")
            match receiver.shared_value {
                some(value) => {
                    result.weak_value =
                        some(value.downgrade())
                }
                none => {}
            }
            return result
        }
        if receiver.kind == "weak" &&
           node.value == "is_expired" {
            match receiver.weak_value {
                some(value) => {
                    return TreeValue.boolean(
                        value.is_expired())
                }
                none => {}
            }
            return TreeValue.boolean(true)
        }
        if receiver.kind == "weak" &&
           node.value == "upgrade" {
            match receiver.weak_value {
                some(value) => {
                    match value.upgrade() {
                        some(shared) => {
                            let result: TreeValue =
                                new TreeValue("shared")
                            result.shared_value =
                                some(shared)
                            return TreeValue.option_some(
                                result)
                        }
                        none => {}
                    }
                }
                none => {}
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "arena" &&
           node.value == "add" &&
           arguments.len() == 2 {
            let slot: int = receiver.items.len()
            receiver.items.push(
                tree_value_copy(arguments[1]))
            return TreeValue.integer(slot)
        }
        if receiver.kind == "arena" &&
           node.value == "get" &&
           arguments.len() == 2 {
            let slot: int = arguments[1].int_data
            if slot >= 0 &&
               slot < receiver.items.len() {
                return TreeValue.option_some(
                    tree_value_copy(
                        receiver.items[slot]))
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "arena" &&
           node.value == "clear" {
            receiver.items = []
            return TreeValue.unit()
        }
        if receiver.kind == "arena" &&
           node.value == "len" {
            return TreeValue.integer(
                receiver.items.len())
        }
        if receiver.kind == "arena" &&
           node.value == "at" &&
           arguments.len() == 2 {
            let slot: int = arguments[1].int_data
            if slot < 0 ||
               slot >= receiver.items.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "arena handle {slot} out of range (len {receiver.items.len()})")
            }
            return tree_value_copy(
                receiver.items[slot])
        }
        if receiver.kind == "channel" &&
           node.value == "send" &&
           arguments.len() == 2 {
            if receiver.bool_data {
                return self.fail(
                    node, "send on closed channel")
            }
            match receiver.channel_value {
                some(channel) => {
                    channel.send(
                        new Mutex(
                            new TreeMutexCell(
                                tree_value_copy(
                                    arguments[1]))))
                }
                none => {
                    return self.fail(
                        node,
                        "channel has no host queue")
                }
            }
            return TreeValue.unit()
        }
        if receiver.kind == "channel" &&
           (node.value == "receive" ||
            node.value == "try_receive") {
            match receiver.channel_value {
                some(channel) => {
                    match channel.receive() {
                        some(cell) => {
                            var value: TreeValue =
                                TreeValue.unit()
                            cell.with_lock(
                                fn(state: TreeMutexCell) {
                                    value =
                                        tree_value_copy(
                                            state.value)
                                })
                            return TreeValue.option_some(
                                value)
                        }
                        none => {
                            return TreeValue.option_none()
                        }
                    }
                }
                none => {
                    return self.fail(
                        node,
                        "channel has no host queue")
                }
            }
        }
        if receiver.kind == "channel" &&
           node.value == "close" {
            receiver.bool_data = true
            match receiver.channel_value {
                some(channel) => {
                    channel.close()
                }
                none => {}
            }
            return TreeValue.unit()
        }
        if receiver.kind == "thread" &&
           node.value == "join" {
            if receiver.items.len() == 1 {
                return tree_value_copy(
                    receiver.items[0])
            }
            match receiver.thread_handle {
                some(handle) => {
                    handle.join()
                }
                none => {
                    return self.fail(
                        node,
                        "thread has no host handle")
                }
            }
            var result: TreeValue =
                TreeValue.unit()
            match receiver.thread_work {
                some(work) => {
                    work.with_lock(
                        fn(state: TreeThreadWork) {
                            if state.failed {
                                self.failed = true
                                self.panic_text =
                                    state.panic_text
                            }
                            match state.result {
                                some(value) => {
                                    result =
                                        tree_value_copy(
                                            value)
                                }
                                none => {}
                            }
                        })
                }
                none => {}
            }
            receiver.items = [
                tree_value_copy(result)]
            return result
        }
        if receiver.kind == "mutex" &&
           node.value == "with_lock" &&
           arguments.len() == 2 &&
           (arguments[1].kind == "closure" ||
            arguments[1].kind == "function") {
            var result: TreeValue =
                TreeValue.unit()
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(
                        fn(state: TreeMutexCell) {
                            let holder: TreeFrame =
                                new TreeFrame()
                            holder.set(
                                -1, state.value)
                            result =
                                self.invoke_closure(
                                    node, arguments[1],
                                    [TreeValue.reference(
                                        holder, -1)])
                            match holder.get(-1) {
                                some(value) => {
                                    state.value = value
                                }
                                none => {}
                            }
                        })
                }
                none => {
                    return self.fail(
                        node,
                        "mutex has no host lock")
                }
            }
            return result
        }
        if (receiver.kind == "map" ||
            receiver.kind == "list") &&
           node.value == "reserve" {
            return TreeValue.unit()
        }
        if receiver.kind == "string" &&
           node.value == "to_int" {
            match receiver.text.to_int() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.integer(value))
                }
                err(message) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            message.msg,
                            message.kind))
                }
            }
        }
        if receiver.kind == "string" &&
           node.value == "to_float" {
            match receiver.text.to_float() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.floating(value))
                }
                err(message) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            message.msg,
                            message.kind))
                }
            }
        }
        if receiver.kind == "string" &&
           node.value == "to_decimal" {
            match receiver.text.to_decimal() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.decimal_value(value))
                }
                err(message) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            message.msg,
                            message.kind))
                }
            }
        }
        if (receiver.kind == "some" ||
            receiver.kind == "none" ||
            receiver.kind == "ok" ||
            receiver.kind == "err") &&
           (node.value == "map" ||
            node.value == "and_then" ||
            node.value == "filter" ||
            node.value == "recover") &&
           arguments.len() == 2 &&
           arguments[1].kind == "closure" {
            let active: bool =
                receiver.kind == "some" ||
                receiver.kind == "ok"
            if node.value == "recover" {
                if active && receiver.items.len() == 1 {
                    return tree_value_copy(
                        receiver.items[0])
                }
                if receiver.kind == "err" &&
                   receiver.items.len() == 1 {
                    return self.invoke_closure(
                        node, arguments[1],
                        [receiver.items[0]])
                }
                return TreeValue.unit()
            }
            if !active {
                return if receiver.kind == "none" {
                    TreeValue.option_none()
                } else {
                    receiver
                }
            }
            if receiver.items.len() != 1 {
                return self.fail(
                    node,
                    "{receiver.kind} has no payload")
            }
            if node.value == "filter" {
                let kept: TreeValue =
                    self.invoke_closure(
                        node, arguments[1],
                        [receiver.items[0]])
                if self.truth(node, kept) {
                    return receiver
                }
                return TreeValue.option_none()
            }
            let mapped: TreeValue =
                self.invoke_closure(
                    node, arguments[1],
                    [receiver.items[0]])
            if node.value == "and_then" {
                return mapped
            }
            return if receiver.kind == "some" {
                TreeValue.option_some(mapped)
            } else {
                TreeValue.result_ok(mapped)
            }
        }
        if (receiver.kind == "some" ||
            receiver.kind == "none") &&
           (node.value == "is_some" ||
            node.value == "is_none") {
            return TreeValue.boolean(
                if node.value == "is_some" {
                    receiver.kind == "some"
                } else {
                    receiver.kind == "none"
                })
        }
        if (receiver.kind == "ok" ||
            receiver.kind == "err") &&
           node.value == "is_ok" {
            return TreeValue.boolean(
                receiver.kind == "ok")
        }
            if (receiver.kind == "some" ||
            receiver.kind == "ok") &&
           receiver.items.len() == 1 &&
           (node.value == "or" ||
            node.value == "expect") {
            return tree_value_copy(
                receiver.items[0])
        }
        if (receiver.kind == "none" ||
            receiver.kind == "err") &&
           node.value == "or" &&
           arguments.len() == 2 {
            return arguments[1]
        }
        if (receiver.kind == "none" ||
            receiver.kind == "err") &&
           node.value == "expect" {
            let message: string =
                if arguments.len() > 1 {
                    tree_value_text(arguments[1])
                } else {
                    "expected a value"
                }
            return self.fail(node, message)
        }
        return self.fail(
            node,
            "builtin method '{node.resolved}' is not in the Beans interpreter yet")
    }

    // A closure used to keep its whole creation frame alive. A local in
    // that frame holding the closure back (through an object field) then
    // made a host-level cycle the program never wrote — frame -> object
    // -> closure -> frame — and the frame's deinits never ran, where the
    // native backend runs them at end of scope. Capture only the
    // bindings the body actually names, each promoted to the shared
    // cell TreeFrame.snapshot uses, so mutation stays shared through
    // the cell and nothing else rides along. A closure that names the
    // object holding it still cycles — the same cycle the native
    // reference counts would leak, per the TreeObjectValue note.
    fn closure(node: HirNode,
               frame: TreeFrame) -> TreeValue {
        let result: TreeValue =
            new TreeValue("closure")
        result.closure_node = some(node)
        let captured: TreeFrame = new TreeFrame()
        self.collect_closure_captures(
            node, frame, captured)
        result.closure_frame = some(captured)
        return result
    }

    fn collect_closure_captures(node: HirNode,
                                frame: TreeFrame,
                                captured: TreeFrame) {
        if node.kind == "local" &&
           node.binding_id >= 0 &&
           !captured.values.contains_key(node.binding_id) {
            match self.capture_cell(
                    frame, node.binding_id) {
                some(cell) => {
                    captured.values[node.binding_id] =
                        cell
                }
                none => {}
            }
        }
        for child: HirNode in node.children {
            self.collect_closure_captures(
                child, frame, captured)
        }
    }

    // The owner's slot is promoted to a reference into a one-slot
    // holder frame, the same shape TreeFrame.snapshot leaves behind,
    // and both sides keep that one cell: assignments follow the
    // reference, so the closure and the enclosing scope stay in sync.
    // A binding the body names but declares itself is not in the
    // enclosing chain yet and comes back none.
    fn capture_cell(frame: TreeFrame,
                    binding: int) -> Option<TreeValue> {
        if frame.values.contains_key(binding) {
            let current: TreeValue =
                frame.values[binding]
            if current.kind == "reference" {
                return some(current)
            }
            let holder: TreeFrame = new TreeFrame()
            holder.values[-1] = current
            let cell: TreeValue =
                TreeValue.reference(holder, -1)
            frame.values[binding] = cell
            return some(cell)
        }
        match frame.parent {
            some(outer) => {
                return self.capture_cell(
                    outer, binding)
            }
            none => { return none }
        }
    }

    fn invoke_closure(node: HirNode,
                      closure: TreeValue,
                      arguments: List<TreeValue>) -> TreeValue {
        if closure.kind == "function" {
            match self.find_function(
                    closure.text) {
                some(function) => {
                    return self.invoke(
                        function, arguments,
                        none)
                }
                none => {
                    return self.fail(
                        node,
                        "unknown function '{closure.text}'")
                }
            }
        }
        var syntax: Option<HirNode> =
            closure.closure_node
        var captured: Option<TreeFrame> =
            closure.closure_frame
        match syntax {
            some(function) => {
                match captured {
                    some(outer) => {
                        let frame: TreeFrame =
                            TreeFrame.captured(outer)
                        var argument: int = 0
                        var body: Option<HirNode> = none
                        for child: HirNode in
                            function.children {
                            if child.kind ==
                                   "closure_parameter" {
                                if argument <
                                       arguments.len() {
                                    frame.set(
                                        child.binding_id,
                                        tree_value_copy(
                                            arguments[argument]))
                                }
                                argument += 1
                            } else if child.kind == "block" {
                                body = some(child)
                            }
                        }
                        var result: TreeValue =
                            TreeValue.unit()
                        match body {
                            some(block) => {
                                let flow: TreeExec =
                                    self.block(block, frame)
                                if flow.kind == "return" {
                                    result = flow.value
                                }
                            }
                            none => {
                                return self.fail(
                                    node,
                                    "closure has no body")
                            }
                        }
                        self.run_defers(frame)
                        return result
                    }
                    none => {}
                }
            }
            none => {}
        }
        return self.fail(
            node, "invalid closure value")
    }

    fn closure_call(node: HirNode,
                    frame: TreeFrame) -> TreeValue {
        if node.children.len() == 0 {
            return self.fail(
                node, "closure call has no callee")
        }
        let callee: TreeValue =
            self.expression(node.children[0], frame)
        if callee.kind == "propagate" {
            return callee
        }
        if callee.kind != "closure" &&
           callee.kind != "function" {
            return self.fail(
                node, "{callee.kind} is not callable")
        }
        var arguments: List<TreeValue> = []
        for index: int in 1..node.children.len() {
            let value: TreeValue =
                self.expression(
                    node.children[index], frame)
            if value.kind == "propagate" {
                return value
            }
            arguments.push(value)
        }
        return self.invoke_closure(
            node, callee, move arguments)
    }

    fn call(node: HirNode,
            frame: TreeFrame) -> TreeValue {
        var arguments: List<TreeValue> = []
        for child: HirNode in node.children {
            let argument: TreeValue =
                self.expression(child, frame)
            if self.failed {
                return TreeValue.unit()
            }
            if argument.kind == "propagate" {
                return argument
            }
            arguments.push(argument)
        }
        if node.kind == "builtin_call" {
            return self.builtin_call(node, move arguments)
        }
        if node.kind == "builtin_method" {
            return self.builtin_method(
                node, move arguments)
        }
        if node.kind == "static_call" &&
           node.resolved == "Atomic.fence" {
            return TreeValue.unit()
        }
        if node.kind == "static_call" &&
           node.resolved.starts_with(
               "StoredCallback.create:") {
            return self.create_stored_callback(
                node, arguments)
        }
        if node.kind == "static_call" {
            match self.file_static(
                    node, arguments) {
                some(value) => { return value }
                none => {}
            }
            match self.raw_static(
                    node, arguments) {
                some(value) => { return value }
                none => {}
            }
        }
        if node.kind == "static_call" &&
           node.resolved == "Bytes.from" &&
           arguments.len() == 1 {
            return TreeValue.bytes(
                Bytes.from(arguments[0].text))
        }
        if node.kind == "static_call" &&
           node.resolved == "Bytes.uvarint_size" &&
           arguments.len() == 1 {
            return TreeValue.integer(
                Bytes.uvarint_size(
                    arguments[0].int_data))
        }
        if node.kind == "static_call" &&
           node.type.name.starts_with("Simd") &&
           (node.value == "of" ||
            node.value == "splat" ||
            node.value == "load" ||
            node.value == "load_unaligned") {
            if node.value == "load" ||
               node.value == "load_unaligned" {
                let pointer: TreeValue =
                    arguments[0]
                if pointer.memory_address == 0 {
                    return self.fail(
                        node, "null SIMD load")
                }
                let vector: LayoutAnswer =
                    self.layout(node.type)
                if node.value == "load" &&
                   pointer.memory_address %
                       (vector.value.size as u64) != 0 {
                    return self.fail(
                        node,
                        "unaligned SIMD load — use load_unaligned")
                }
                match self.pointer_memory(
                        node, pointer) {
                    some(memory) => {
                        return self.memory_read_value(
                            node, memory,
                            pointer.memory_address,
                            node.type)
                    }
                    none => {
                        return TreeValue.unit()
                    }
                }
            }
            var lanes: List<TreeValue> = []
            if node.value == "of" {
                for argument: TreeValue in arguments {
                    lanes.push(
                        tree_value_copy(argument))
                }
            } else if arguments.len() == 1 {
                for index: int in
                    0..tree_simd_lanes(
                        node.type.name) {
                    lanes.push(
                        tree_value_copy(arguments[0]))
                }
            }
            let result: TreeValue =
                TreeValue.sequence(
                    "simd", move lanes)
            result.text = node.type.name
            return result
        }
        var receiver: Option<TreeValue> = none
        if node.kind == "method_call" &&
           arguments.len() != 0 {
            receiver = some(arguments[0])
            var method_arguments: List<TreeValue> = []
            for index: int in 1..arguments.len() {
                method_arguments.push(arguments[index])
            }
            arguments = move method_arguments
        }
        var target: string = node.resolved
        match receiver {
            some(value) => {
                if value.kind == "object" {
                    match self.dynamic_method(
                        value.text, node.value,
                        node.dispatch_slot) {
                        some(function) => {
                            target = function.qualified
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        match self.find_function(target) {
            some(function) => {
                return self.invoke(
                    function, move arguments, receiver)
            }
            none => {
                return self.fail(
                    node,
                    "unknown function '{node.resolved}'")
            }
        }
    }

    fn builtin_object(name: string,
                      arguments: List<TreeValue>) ->
        Option<TreeValue> {
        var kind: string = ""
        if name == "Box" {
            kind = "box"
        } else if name == "Arena" {
            kind = "arena"
        } else if name == "Shared" {
            kind = "shared"
        } else if name == "Weak" {
            kind = "weak"
        } else if name == "Mutex" {
            kind = "mutex"
        } else if name == "Atomic" ||
                  name == "AtomicInt" {
            kind = "atomic"
        } else if name == "Channel" {
            kind = "channel"
        } else if name == "Bytes" {
            kind = "bytes"
        } else {
            return none
        }
        let result: TreeValue =
            new TreeValue(kind)
        if kind == "bytes" {
            let size: int =
                if arguments.len() != 0 {
                    arguments[0].int_data
                } else {
                    0
                }
            result.bytes_data =
                some(new Bytes(size))
        } else if kind == "shared" {
            if arguments.len() != 0 {
                result.shared_value =
                    some(new Shared(
                        tree_value_copy(
                            arguments[0])))
            }
        } else if kind == "arena" ||
                  kind == "channel" {
            if arguments.len() != 0 &&
               arguments[0].kind == "int" {
                result.int_data =
                    arguments[0].int_data
            }
            if kind == "channel" {
                result.channel_value =
                    some(new Channel<
                        Mutex<TreeMutexCell>>(
                            result.int_data))
            }
        } else if kind == "mutex" ||
                  kind == "atomic" {
            if arguments.len() != 0 {
                result.mutex_cell =
                    some(new Mutex(
                        new TreeMutexCell(
                            tree_value_copy(
                                arguments[0]))))
            }
        } else if arguments.len() != 0 {
            result.items.push(
                tree_value_copy(arguments[0]))
        }
        return some(result)
    }

    fn object_value(name: string) -> TreeValue {
        if self.needs_deinit(name) ||
           self.chain_frees_objects(name) {
            return (new TreeObjectValue(self)) as TreeValue
        }
        return new TreeValue("object")
    }

    fn new_object(node: HirNode,
                  frame: TreeFrame) -> TreeValue {
        var arguments: List<TreeValue> = []
        for child: HirNode in node.children {
            let argument: TreeValue =
                self.expression(child, frame)
            if self.failed {
                return TreeValue.unit()
            }
            if argument.kind == "propagate" {
                return argument
            }
            arguments.push(argument)
        }
        match self.builtin_object(
            node.type.name, arguments) {
            some(value) => { return value }
            none => {}
        }
        let result: TreeValue =
            self.object_value(node.type.name)
        result.text = node.type.name
        result.object_id = self.next_object_id
        self.next_object_id += 1
        self.apply_field_defaults(
            node.type.name, result, frame)
        match self.find_function(node.resolved) {
            some(initializer) => {
                self.invoke(
                    initializer,
                    move arguments,
                    some(result))
            }
            none => {
                if node.children.len() != 0 {
                    self.fail(
                        node,
                        "unknown initializer '{node.resolved}'")
                }
            }
        }
        return result
    }

    fn apply_field_defaults(
        name: string,
        object: TreeValue,
        frame: TreeFrame) {
        // Same two-pass rule as declaration(): an exact qualified name wins
        // before any short-name fallback, so a dependency's class cannot
        // shadow a root-package class that shares its short name.
        match self.declaration(name) {
            some(declaration) => {
                self.apply_declaration_defaults(
                    declaration, object, frame)
            }
            none => {}
        }
    }

    fn apply_declaration_defaults(
        declaration: HirDeclaration,
        object: TreeValue,
        frame: TreeFrame) {
        for field: HirField in declaration.fields {
            match field.default_value {
                some(value) => {
                    object.fields[field.name] =
                        tree_value_copy(
                            self.expression(value, frame))
                }
                none => {}
            }
        }
        for index: int in
            0..declaration.relations.len() {
            if index <
                   declaration.relation_kinds.len() &&
               declaration.relation_kinds[index] ==
                   "extends" {
                self.apply_field_defaults(
                    declaration.relations[index].name,
                    object, frame)
            }
        }
    }

    fn field(node: HirNode,
             frame: TreeFrame) -> TreeValue {
        if node.children.len() != 1 {
            return self.fail(node, "field has no receiver")
        }
        let receiver: TreeValue =
            self.expression(node.children[0], frame)
        if receiver.kind == "propagate" {
            return receiver
        }
        match receiver.fields.get(node.value) {
            some(value) => {
                return tree_value_copy(value)
            }
            none => {
                return self.fail(
                    node,
                    "{receiver.text} has no initialized field '{node.value}'")
            }
        }
    }

    fn index(node: HirNode,
             frame: TreeFrame) -> TreeValue {
        let receiver: TreeValue =
            self.expression(node.children[0], frame)
        if receiver.kind == "propagate" {
            return receiver
        }
        let key: TreeValue =
            self.expression(node.children[1], frame)
        if key.kind == "propagate" { return key }
        if (receiver.kind == "list" ||
            receiver.kind == "array") &&
           key.kind == "int" {
            if key.int_data < 0 ||
               key.int_data >= receiver.items.len() {
                return self.fail(
                    node,
                    "{if receiver.kind == "array" { "array" } else { "list" }} index {key.int_data} out of range (len {receiver.items.len()})")
            }
            return tree_value_copy(
                receiver.items[key.int_data])
        }
        if receiver.kind == "map" {
            match receiver.map_values.get(
                self.map_key(receiver, key)) {
                some(value) => {
                    return tree_value_copy(value)
                }
                none => {
                    return self.fail_at(
                        node, node.col,
                        "map key not found: {tree_value_text(key)}")
                }
            }
        }
        if receiver.kind == "slice" &&
           key.kind == "int" {
            if key.int_data < 0 ||
               key.int_data >= receiver.slice_len {
                return self.fail(
                    node,
                    "slice index {key.int_data} out of range (len {receiver.slice_len})")
            }
            let element: HirType =
                receiver.memory_type.expect(
                    "slice element type")
            let piece: LayoutAnswer =
                self.layout(element)
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    return self.memory_read_value(
                        node, memory,
                        receiver.memory_address +
                            ((key.int_data *
                              piece.value.size) as u64),
                        element)
                }
                none => {
                    return TreeValue.unit()
                }
            }
        }
        return self.fail(
            node,
            "indexing {receiver.kind} is not in the Beans interpreter yet")
    }

    fn pattern_literal(pattern: HirNode,
                       value: TreeValue) -> bool {
        if pattern.value == "true" ||
           pattern.value == "false" {
            return value.kind == "bool" &&
                   value.bool_data ==
                       (pattern.value == "true")
        }
        if pattern.value.starts_with("\"") {
            return value.kind == "string" &&
                   value.text ==
                       tree_unquote(pattern.value)
        }
        if pattern.value.contains(".") ||
           pattern.value.contains("e") ||
           pattern.value.contains("E") {
            return value.kind == "float" &&
                   value.float_data ==
                       pattern.value.to_float().or(0.0)
        }
        return value.kind == "int" &&
               value.int_data ==
                   tree_parse_int(pattern.value)
    }

    fn pattern_matches(pattern: HirNode,
                       value: TreeValue,
                       frame: TreeFrame) -> bool {
        if pattern.kind == "pattern_wildcard" {
            return true
        }
        if pattern.kind == "pattern_literal" {
            return self.pattern_literal(
                pattern, value)
        }
        if pattern.kind == "pattern_alternative" {
            for child: HirNode in pattern.children {
                if self.pattern_matches(
                       child, value, frame) {
                    return true
                }
            }
            return false
        }
        if pattern.kind == "pattern_range" &&
           pattern.children.len() == 2 &&
           value.kind == "int" {
            return value.int_data >=
                       tree_parse_int(
                           pattern.children[0].value) &&
                   value.int_data <=
                       tree_parse_int(
                           pattern.children[1].value)
        }
        if pattern.kind != "pattern_name" {
            return false
        }
        let variant: string =
            if value.kind == "variant" {
                value.text
            } else {
                value.kind
            }
        if variant != pattern.value {
            return false
        }
        for index: int in 0..pattern.children.len() {
            let binding: HirNode =
                pattern.children[index]
            if binding.kind == "pattern_binding" &&
               index < value.items.len() {
                frame.set(
                    binding.binding_id,
                    tree_value_copy(
                        value.items[index]))
            }
        }
        return true
    }

    fn match_expression(node: HirNode,
                        frame: TreeFrame) -> TreeValue {
        if node.children.len() == 0 {
            return self.fail(node, "match has no subject")
        }
        let subject: TreeValue =
            self.expression(node.children[0], frame)
        if subject.kind == "propagate" {
            return subject
        }
        for index: int in 1..node.children.len() {
            let arm: HirNode = node.children[index]
            if arm.children.len() != 2 {
                continue
            }
            let arm_frame: TreeFrame =
                TreeFrame.scope(frame)
            if self.pattern_matches(
                   arm.children[0], subject,
                   arm_frame) {
                return self.expression(
                    arm.children[1], arm_frame)
            }
        }
        return self.fail(node, "non-exhaustive match")
    }

    fn match_statement(node: HirNode,
                       frame: TreeFrame) -> TreeExec {
        if node.children.len() == 0 {
            self.fail(node, "match has no subject")
            return TreeExec.next()
        }
        let subject: TreeValue =
            self.expression(node.children[0], frame)
        if subject.kind == "propagate" &&
           subject.items.len() == 1 {
            return TreeExec.returned(subject.items[0])
        }
        for index: int in 1..node.children.len() {
            let arm: HirNode = node.children[index]
            if arm.children.len() != 2 {
                continue
            }
            let arm_frame: TreeFrame =
                TreeFrame.scope(frame)
            if self.pattern_matches(
                   arm.children[0], subject,
                   arm_frame) {
                if arm.children[1].kind == "block" {
                    return self.block(
                        arm.children[1], arm_frame)
                }
                let value: TreeValue =
                    self.expression(
                        arm.children[1], arm_frame)
                if value.kind == "propagate" &&
                   value.items.len() == 1 {
                    return TreeExec.returned(
                        value.items[0])
                }
                return TreeExec.next()
            }
        }
        self.fail(node, "non-exhaustive match")
        return TreeExec.next()
    }

    fn expression(node: HirNode,
                  frame: TreeFrame) -> TreeValue {
        if self.failed { return TreeValue.unit() }
        if node.kind == "literal" {
            return self.literal(node, frame)
        }
        if node.kind == "layout_query" {
            return self.layout_query(node)
        }
        if node.kind == "selector" {
            let result: TreeValue =
                new TreeValue("selector")
            result.text = node.value
            return result
        }
        if node.kind == "local" {
            return self.local(frame, node)
        }
        if node.kind == "c_global" {
            match self.c_global(node.resolved) {
                some(global) => {
                    return self.read_c_global(
                        node, global)
                }
                none => {
                    return self.fail(
                        node,
                        "unknown extern C global '{node.value}'")
                }
            }
        }
        if node.kind == "unary" {
            return self.unary(node, frame)
        }
        if node.kind == "binary" {
            return self.binary(node, frame)
        }
        if node.kind == "closure" {
            return self.closure(node, frame)
        }
        if node.kind == "function" {
            let result: TreeValue =
                new TreeValue("function")
            result.text = node.resolved
            return result
        }
        if node.kind == "closure_call" {
            return self.closure_call(node, frame)
        }
        if node.kind == "match" {
            return self.match_expression(node, frame)
        }
        if node.kind == "call" ||
           node.kind == "builtin_call" ||
           node.kind == "method_call" ||
           node.kind == "builtin_method" ||
           node.kind == "static_call" {
            return self.call(node, frame)
        }
        if node.kind == "new" {
            return self.new_object(node, frame)
        }
        if node.kind == "super_init" ||
           node.kind == "super_call" {
            var arguments: List<TreeValue> = []
            for child: HirNode in node.children {
                let value: TreeValue =
                    self.expression(child, frame)
                if value.kind == "propagate" {
                    return value
                }
                arguments.push(value)
            }
            match self.find_function(node.resolved) {
                some(initializer) => {
                    match frame.self_value {
                        some(receiver) => {
                            return self.invoke(
                                initializer,
                                move arguments,
                                some(receiver))
                        }
                        none => {
                            return self.fail(
                                node,
                                "super.{node.value} has no self")
                        }
                    }
                }
                none => {
                    return self.fail(
                        node,
                        "unknown parent method '{node.resolved}'")
                }
            }
        }
        if node.kind == "initializer" {
            let result: TreeValue =
                new TreeValue("record")
            result.text = node.type.name
            result.object_id = self.next_object_id
            self.next_object_id += 1
            for field: HirNode in node.children {
                if field.kind == "field_init" &&
                   field.children.len() == 1 {
                    result.fields[field.value] =
                        tree_value_copy(
                            self.expression(
                                field.children[0], frame))
                }
            }
            match self.declaration(node.type.name) {
                some(declaration) => {
                    if declaration.kind == "union" {
                        for field: HirNode in
                            node.children {
                            if field.kind ==
                                   "field_init" {
                                self.write_union_field(
                                    node, result,
                                    declaration,
                                    field.value,
                                    result.fields[
                                        field.value])
                                break
                            }
                        }
                    }
                }
                none => {}
            }
            return result
        }
        if node.kind == "field" {
            return self.field(node, frame)
        }
        if node.kind == "index" {
            return self.index(node, frame)
        }
        if node.kind == "cast" &&
           node.children.len() == 1 {
            let value: TreeValue =
                self.expression(node.children[0], frame)
            if value.kind == "propagate" {
                return value
            }
            if node.value == "as?" {
                if value.kind == "object" &&
                   self.is_instance(
                       value.text, node.type.args[0].name) {
                    return TreeValue.option_some(value)
                }
                return TreeValue.option_none()
            }
            let target: string =
                canonical_hir_name(node.type.name)
            if hir_is_integer(node.type) {
                let bits: int =
                    tree_integer_bits(target)
                let unsigned: bool =
                    tree_integer_unsigned(target)
                if value.kind == "int" {
                    let raw: u64 =
                        if value.int_unsigned {
                            value.uint_data
                        } else {
                            value.int_data as u64
                        }
                    return if unsigned {
                        TreeValue.unsigned_integer(
                            raw, bits)
                    } else {
                        TreeValue.signed_integer(
                            tree_signed_from_bits(
                                raw, bits),
                            bits)
                    }
                }
                if value.kind == "float" {
                    return if unsigned {
                        TreeValue.unsigned_integer(
                            value.float_data as u64,
                            bits)
                    } else {
                        TreeValue.signed_integer(
                            value.float_data as int,
                            bits)
                    }
                }
                if value.kind == "decimal" {
                    return if unsigned {
                        TreeValue.unsigned_integer(
                            value.decimal_data as u64,
                            bits)
                    } else {
                        TreeValue.signed_integer(
                            value.decimal_data as int,
                            bits)
                    }
                }
                return value
            }
            if hir_is_float(node.type) {
                if value.kind == "int" {
                    return self.floating_value(
                        node.type,
                        if value.int_unsigned {
                            value.uint_data as float
                        } else {
                            value.int_data as float
                        })
                }
                if value.kind == "decimal" {
                    return self.floating_value(
                        node.type,
                        value.decimal_data as float)
                }
                if value.kind == "float" {
                    return self.floating_value(
                        node.type, value.float_data)
                }
                return value
            }
            if target == "decimal" {
                if value.kind == "int" {
                    return TreeValue.decimal_value(
                        if value.int_unsigned {
                            value.uint_data as decimal
                        } else {
                            value.int_data as decimal
                        })
                }
                if value.kind == "float" {
                    // validate here so the panic carries the guest
                    // program's location, not this file's: the host
                    // cast would panic at its own line otherwise
                    let source: float = value.float_data
                    if !(source == source) ||
                       source.abs() >=
                           100000000000000000000000000000000000000.0 {
                        return self.fail(
                            node, "decimal overflow")
                    }
                    return TreeValue.decimal_value(
                        source as decimal)
                }
            }
            return value
        }
        if node.kind == "list" {
            var values: List<TreeValue> = []
            for child: HirNode in node.children {
                let value: TreeValue =
                    self.expression(child, frame)
                if value.kind == "propagate" {
                    return value
                }
                values.push(tree_value_copy(value))
            }
            let kind: string =
                if node.type.name == "array" {
                    "array"
                } else {
                    "list"
                }
            return TreeValue.sequence(
                kind, move values)
        }
        if node.kind == "map" {
            let result: TreeValue =
                new TreeValue("map")
            var index: int = 0
            for index + 1 < node.children.len() {
                let key: TreeValue =
                    self.expression(
                        node.children[index], frame)
                if key.kind == "propagate" {
                    return key
                }
                let value: TreeValue =
                    self.expression(
                        node.children[index + 1], frame)
                if value.kind == "propagate" {
                    return value
                }
                let encoded: string =
                    self.map_key(result, key)
                if !result.map_values.contains_key(
                       encoded) {
                    result.map_keys.push(
                        tree_value_copy(key))
                }
                result.map_values[encoded] =
                    tree_value_copy(value)
                index += 2
            }
            return result
        }
        if node.kind == "none" {
            return TreeValue.option_none()
        }
        if node.kind == "variant" {
            var payload: List<TreeValue> = []
            for child: HirNode in node.children {
                let value: TreeValue =
                    self.expression(child, frame)
                if value.kind == "propagate" {
                    return value
                }
                payload.push(tree_value_copy(value))
            }
            let result: TreeValue =
                TreeValue.sequence(
                    "variant", move payload)
            result.text = node.value
            return result
        }
        if node.kind == "some" ||
           node.kind == "ok" ||
           node.kind == "err" {
            let value: TreeValue =
                self.expression(node.children[0], frame)
            if value.kind == "propagate" {
                return value
            }
            if node.kind == "some" {
                return TreeValue.option_some(
                    tree_value_copy(value))
            }
            if node.kind == "ok" {
                return TreeValue.result_ok(
                    tree_value_copy(value))
            }
            if value.kind == "string" &&
               (node.type.args.len() == 1 ||
                (node.type.args.len() > 1 &&
                 canonical_hir_name(
                     node.type.args[1].name) ==
                     "Error")) {
                var kind: string = ""
                if node.children.len() > 1 {
                    let kind_value: TreeValue =
                        self.expression(
                            node.children[1], frame)
                    if kind_value.kind == "string" {
                        kind = kind_value.text
                    }
                }
                return TreeValue.result_err(
                    TreeValue.error(
                        value.text, kind))
            }
            return TreeValue.result_err(
                tree_value_copy(value))
        }
        if node.kind == "try" {
            let result: TreeValue =
                self.expression(node.children[0], frame)
            if (result.kind == "ok" ||
                result.kind == "some") &&
               result.items.len() == 1 {
                return tree_value_copy(
                    result.items[0])
            }
            if result.kind == "err" ||
               result.kind == "none" {
                return TreeValue.propagation(result)
            }
            return self.fail(node, "'?' received a non-result value")
        }
        if node.kind == "if_expression" &&
           node.children.len() == 3 {
            let condition: TreeValue =
                self.expression(
                    node.children[0], frame)
            if condition.kind == "propagate" {
                return condition
            }
            if self.truth(node, condition) {
                return self.expression(
                    node.children[1], frame)
            }
            return self.expression(
                node.children[2], frame)
        }
        if node.kind == "block" {
            let scope: TreeFrame =
                TreeFrame.scope(frame)
            if node.children.len() == 0 {
                return TreeValue.unit()
            }
            for index: int in
                0..node.children.len() - 1 {
                let flow: TreeExec =
                    self.statement(
                        node.children[index], scope)
                if flow.kind == "return" {
                    return TreeValue.propagation(
                        flow.value)
                }
            }
            let tail: HirNode =
                node.children[node.children.len() - 1]
            if tail.kind == "expression" &&
               tail.children.len() == 1 {
                return self.expression(
                    tail.children[0], scope)
            }
            let flow: TreeExec =
                self.statement(tail, scope)
            if flow.kind == "return" {
                return TreeValue.propagation(
                    flow.value)
            }
            return flow.value
        }
        return self.fail(
            node,
            "expression '{node.kind}' is not in the Beans interpreter yet")
    }

    fn assign(node: HirNode,
              frame: TreeFrame) -> TreeExec {
        if node.children.len() != 2 {
            self.fail(node, "assignment has no value")
            return TreeExec.next()
        }
        let target: HirNode = node.children[0]
        let written: TreeValue =
            self.expression(node.children[1], frame)
        if written.kind == "propagate" &&
           written.items.len() == 1 {
            return TreeExec.returned(
                written.items[0])
        }
        var value: TreeValue = written
        if node.value != "=" {
            let current: TreeValue =
                self.expression(target, frame)
            let operation: HirNode =
                new HirNode(
                    "binary",
                    node.value.slice(
                        0, node.value.len() - 1),
                    target.type,
                    node.file, node.line, node.col)
            operation.children.push(target)
            operation.children.push(node.children[1])
            if current.kind == "int" &&
               written.kind == "int" {
                value = self.integer_binary(
                    operation,
                    current,
                    written)
            } else if current.kind == "float" &&
                      written.kind == "float" {
                if operation.value == "+" {
                    value = self.floating_value(
                        target.type,
                        current.float_data +
                        written.float_data)
                } else if operation.value == "-" {
                    value = self.floating_value(
                        target.type,
                        current.float_data -
                        written.float_data)
                } else if operation.value == "*" {
                    value = self.floating_value(
                        target.type,
                        current.float_data *
                        written.float_data)
                } else if operation.value == "/" {
                    value = self.floating_value(
                        target.type,
                        current.float_data /
                        written.float_data)
                }
            } else if current.kind == "decimal" &&
                      written.kind == "decimal" {
                value = self.decimal_binary_value(
                    node, operation.value,
                    current.decimal_data,
                    written.decimal_data)
            } else {
                value = self.fail(
                    node,
                    "compound assignment is not in the Beans interpreter yet for {current.kind}")
            }
        }
        if target.kind == "local" {
            if !frame.assign(
                   target.binding_id,
                   tree_value_copy(value)) {
                frame.set(
                    target.binding_id,
                    tree_value_copy(value))
            }
            return TreeExec.next()
        }
        if target.kind == "c_global" {
            match self.c_global(target.resolved) {
                some(global) => {
                    self.write_c_global(
                        node, global, value)
                }
                none => {
                    self.fail(
                        node,
                        "unknown extern C global '{target.value}'")
                }
            }
            return TreeExec.next()
        }
        if target.kind == "field" &&
           target.children.len() == 1 {
            let receiver: TreeValue =
                self.expression(
                    target.children[0], frame)
            match self.declaration(receiver.text) {
                some(declaration) => {
                    if declaration.kind == "union" {
                        self.write_union_field(
                            node, receiver,
                            declaration,
                            target.value,
                            tree_value_copy(value))
                        return TreeExec.next()
                    }
                }
                none => {}
            }
            receiver.fields[target.value] =
                tree_value_copy(value)
            return TreeExec.next()
        }
        if target.kind == "index" &&
           target.children.len() == 2 {
            let receiver: TreeValue =
                self.expression(
                    target.children[0], frame)
            let key: TreeValue =
                self.expression(
                    target.children[1], frame)
            if (receiver.kind == "list" ||
                receiver.kind == "array") &&
               key.kind == "int" {
                if key.int_data < 0 ||
                   key.int_data >= receiver.items.len() {
                    self.fail(
                        node,
                        "{if receiver.kind == "array" { "array" } else { "list" }} index {key.int_data} out of range (len {receiver.items.len()})")
                    return TreeExec.next()
                }
                receiver.items[key.int_data] =
                    tree_value_copy(value)
                return TreeExec.next()
            }
            if receiver.kind == "map" {
                let encoded: string =
                    self.map_key(receiver, key)
                if !receiver.map_values.contains_key(
                       encoded) {
                    receiver.map_keys.push(
                        tree_value_copy(key))
                }
                receiver.map_values[encoded] =
                    tree_value_copy(value)
                return TreeExec.next()
            }
            if receiver.kind == "slice" &&
               key.kind == "int" {
                if key.int_data < 0 ||
                   key.int_data >= receiver.slice_len {
                    self.fail(
                        node,
                        "slice index {key.int_data} out of range (len {receiver.slice_len})")
                    return TreeExec.next()
                }
                let element: HirType =
                    receiver.memory_type.expect(
                        "slice element type")
                let piece: LayoutAnswer =
                    self.layout(element)
                match self.pointer_memory(
                        node, receiver) {
                    some(memory) => {
                        self.memory_write_value(
                            node, memory,
                            receiver.memory_address +
                                ((key.int_data *
                                  piece.value.size) as u64),
                            element, value)
                    }
                    none => {}
                }
                return TreeExec.next()
            }
        }
        self.fail(
            node,
            "assignment target '{target.kind}' is not in the Beans interpreter yet")
        return TreeExec.next()
    }

    fn block(node: HirNode,
             frame: TreeFrame) -> TreeExec {
        let scope: TreeFrame =
            TreeFrame.scope(frame)
        for statement: HirNode in node.children {
            let result: TreeExec =
                self.statement(statement, scope)
            if result.kind != "next" {
                return result
            }
        }
        return TreeExec.next()
    }

    fn loop(node: HirNode,
            frame: TreeFrame) -> TreeExec {
        if node.children.len() == 1 {
            for !self.failed {
                let result: TreeExec =
                    self.block(node.children[0], frame)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
            }
            return TreeExec.next()
        }
        if node.children.len() == 2 {
            var running: bool = true
            for running {
                let condition: TreeValue =
                    self.expression(
                        node.children[0], frame)
                if condition.kind == "propagate" &&
                   condition.items.len() == 1 {
                    return TreeExec.returned(
                        condition.items[0])
                }
                if !self.truth(node, condition) {
                    running = false
                    continue
                }
                let result: TreeExec =
                    self.block(node.children[1], frame)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
            }
            return TreeExec.next()
        }
        if node.children.len() == 3 {
            let iterable: TreeValue =
                self.expression(node.children[0], frame)
            if iterable.kind == "propagate" &&
               iterable.items.len() == 1 {
                return TreeExec.returned(
                    iterable.items[0])
            }
            let binding: HirNode = node.children[1]
            var values: List<TreeValue> = []
            if iterable.kind == "range" &&
               iterable.items.len() == 2 {
                var value: int =
                    iterable.items[0].int_data
                let end: int =
                    iterable.items[1].int_data
                for value < end ||
                    (iterable.bool_data &&
                     value == end) {
                    values.push(
                        TreeValue.integer(value))
                    if iterable.bool_data &&
                       value == end {
                        break
                    }
                    value += 1
                }
            } else if iterable.kind == "list" ||
                      iterable.kind == "array" {
                for value: TreeValue in iterable.items {
                    values.push(value)
                }
            } else if iterable.kind == "slice" {
                let element: HirType =
                    iterable.memory_type.expect(
                        "slice element type")
                let piece: LayoutAnswer =
                    self.layout(element)
                match self.pointer_memory(
                        node, iterable) {
                    some(memory) => {
                        for index: int in
                            0..iterable.slice_len {
                            values.push(
                                self.memory_read_value(
                                    node, memory,
                                    iterable.memory_address +
                                        ((index *
                                          piece.value.size) as u64),
                                    element))
                        }
                    }
                    none => {}
                }
            } else {
                self.fail(
                    node,
                    "{iterable.kind} is not iterable")
            }
            for value: TreeValue in values {
                let iteration: TreeFrame =
                    TreeFrame.scope(frame)
                iteration.set(
                    binding.binding_id, value)
                let result: TreeExec =
                    self.block(
                        node.children[2], iteration)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
            }
        }
        return TreeExec.next()
    }

    fn statement(node: HirNode,
                 frame: TreeFrame) -> TreeExec {
        if self.failed {
            return TreeExec.stopped("panic")
        }
        match self.debugger {
            some(session) => {
                session.at_statement(node, frame)
                if session.terminated || session.disconnected {
                    return TreeExec.stopped("panic")
                }
            }
            none => {}
        }
        if node.kind == "block" ||
           node.kind == "unsafe" {
            let block: HirNode =
                if node.kind == "unsafe" {
                    node.children[0]
                } else {
                    node
                }
            return self.block(block, frame)
        }
        if node.kind == "let" || node.kind == "var" {
            let value: TreeValue =
                if node.children.len() == 0 {
                    TreeValue.unit()
                } else {
                    self.expression(
                        node.children[0], frame)
                }
            if value.kind == "propagate" &&
               value.items.len() == 1 {
                return TreeExec.returned(
                    value.items[0])
            }
            frame.set(
                node.binding_id,
                tree_value_copy(value))
            return TreeExec.next()
        }
        if node.kind == "expression" &&
           node.children.len() == 1 &&
           node.children[0].kind == "match" {
            // a statement match runs its arm as statements, so break and
            // continue inside an arm reach the enclosing loop instead of
            // being swallowed by expression evaluation
            return self.match_statement(
                node.children[0], frame)
        }
        if node.kind == "expression" {
            if node.children.len() != 0 {
                let value: TreeValue =
                    self.expression(
                        node.children[0], frame)
                if value.kind == "propagate" &&
                   value.items.len() == 1 {
                    return TreeExec.returned(
                        value.items[0])
                }
            }
            return TreeExec.next()
        }
        if node.kind == "assign" {
            return self.assign(node, frame)
        }
        if node.kind == "return" {
            let value: TreeValue =
                if node.children.len() == 0 {
                    TreeValue.unit()
                } else {
                    self.expression(
                        node.children[0], frame)
                }
            if value.kind == "propagate" &&
               value.items.len() == 1 {
                return TreeExec.returned(
                    value.items[0])
            }
            return TreeExec.returned(value)
        }
        if node.kind == "if" {
            let condition_value: TreeValue =
                self.expression(
                    node.children[0], frame)
            if condition_value.kind == "propagate" &&
               condition_value.items.len() == 1 {
                return TreeExec.returned(
                    condition_value.items[0])
            }
            let condition: bool =
                self.truth(node, condition_value)
            if condition {
                return self.statement(
                    node.children[1], frame)
            }
            if node.children.len() > 2 {
                return self.statement(
                    node.children[2], frame)
            }
            return TreeExec.next()
        }
        if node.kind == "for" {
            return self.loop(node, frame)
        }
        if node.kind == "break" ||
           node.kind == "continue" {
            return TreeExec.stopped(node.kind)
        }
        if node.kind == "defer" &&
           node.children.len() == 1 {
            frame.add_defer(node.children[0])
            return TreeExec.next()
        }
        self.fail(
            node,
            "statement '{node.kind}' is not in the Beans interpreter yet")
        return TreeExec.next()
    }

    fn run_defers(frame: TreeFrame) {
        var index: int = frame.defers.len()
        for index > 0 {
            index -= 1
            self.expression(frame.defers[index], frame)
        }
    }

    fn fail_extern(function: HirFunction,
                   message: string) -> TreeValue {
        if !self.failed {
            self.failed = true
            self.panic_text =
                "runtime panic at {function.line}:{function.col}: {message}"
        }
        return TreeValue.unit()
    }

    fn ffi_pointer_word(
        function: HirFunction,
        value: TreeValue,
        bridges: List<TreeFfiMemory>) -> int {
        if value.memory_address == 0 { return 0 }
        if value.memory_host {
            return value.memory_address as int
        }
        var memory_value: Option<TreeMemory> =
            value.memory
        if memory_value.is_none() {
            memory_value =
                self.find_memory(value.memory_address)
        }
        match memory_value {
            some(memory) => {
                if memory.freed {
                    self.fail_extern(
                        function,
                        "dangling raw pointer passed to extern C function")
                    return 0
                }
                for bridge: TreeFfiMemory in bridges {
                    if bridge.memory.base == memory.base {
                        unsafe {
                            return (bridge.host.address() +
                                    value.memory_address -
                                    memory.base) as int
                        }
                    }
                }
                unsafe {
                    let host: RawPtr<u8> =
                        RawPtr.alloc_aligned(
                            memory.data.len(),
                            memory.alignment)
                    for index: int in
                        0..memory.data.len() {
                        host.offset(index).write(
                            memory.data.get(index) as u8)
                    }
                    bridges.push(
                        new TreeFfiMemory(
                            memory, host,
                            value.memory_type.expect(
                                "FFI pointer element type")))
                    return (host.address() +
                            value.memory_address -
                            memory.base) as int
                }
            }
            none => {
                self.fail_extern(
                    function,
                    "invalid raw pointer passed to extern C function")
                return 0
            }
        }
        return 0
    }

    fn ffi_sync_and_free(
        bridges: List<TreeFfiMemory>) {
        unsafe {
            for bridge: TreeFfiMemory in bridges {
                for index: int in
                    0..bridge.memory.data.len() {
                    let byte: u8 =
                        bridge.host.offset(index).read()
                    bridge.memory.data.set(
                        index, byte as int)
                }
                bridge.host.free()
            }
        }
    }

    fn ffi_pointer_result(
        type: HirType, raw: int,
        bridges: List<TreeFfiMemory>) -> TreeValue {
        let element: HirType =
            if type.args.len() == 1 {
                type.args[0]
            } else {
                new HirType("u8")
            }
        if raw == 0 {
            return TreeValue.raw_pointer(
                none, 0, element)
        }
        let address: u64 = raw as u64
        for bridge: TreeFfiMemory in bridges {
            var base: u64 = 0
            unsafe {
                base = bridge.host.address()
            }
            let size: u64 =
                bridge.memory.data.len() as u64
            if address >= base &&
               address <= base + size {
                return TreeValue.raw_pointer(
                    some(bridge.memory),
                    bridge.memory.base +
                        address - base,
                    element)
            }
        }
        return TreeValue.host_pointer(
            address, element)
    }

    fn ffi_integer_result(
        type: HirType, raw: int) -> TreeValue {
        let name: string =
            canonical_hir_name(type.name)
        if name == "bool" {
            return TreeValue.boolean(raw != 0)
        }
        let bits: int = tree_integer_bits(name)
        if tree_integer_unsigned(name) {
            return TreeValue.unsigned_integer(
                raw as u64, bits)
        }
        return TreeValue.signed_integer(raw, bits)
    }

    fn ffi_memory_write_value(
        function: HirFunction,
        memory: TreeMemory, address: u64,
        type: HirType, value: TreeValue,
        bridges: List<TreeFfiMemory>) -> bool {
        let name: string =
            canonical_hir_name(type.name)
        if name == "RawPtr" {
            self.memory_write_uint(
                memory, address,
                self.program.target.pointer_size(),
                self.ffi_pointer_word(
                    function, value, bridges) as u64)
            return !self.failed
        }
        if name == "array" &&
           type.args.len() == 1 {
            let element: LayoutAnswer =
                self.layout(type.args[0])
            for index: int in 0..type.array_length {
                if index >= value.items.len() ||
                   !self.ffi_memory_write_value(
                       function, memory,
                       address +
                           ((index *
                             element.value.size) as u64),
                       type.args[0], value.items[index],
                       bridges) {
                    return false
                }
            }
            return true
        }
        match self.declaration(type.name) {
            some(declaration) => {
                if declaration.is_c_layout &&
                   declaration.kind != "union" {
                    let engine: LayoutEngine =
                        new LayoutEngine(
                            self.program,
                            self.program.target)
                    let record: RecordLayoutAnswer =
                        engine.layout_record(declaration)
                    for field: HirField in
                        declaration.fields {
                        match record.offsets.get(
                                field.name) {
                            some(offset) => {
                                if !self.ffi_memory_write_value(
                                       function, memory,
                                       address +
                                           (offset as u64),
                                       field.type,
                                       value.fields[field.name],
                                       bridges) {
                                    return false
                                }
                            }
                            none => {}
                        }
                    }
                    return true
                }
            }
            none => {}
        }
        return self.memory_write_value(
            new HirNode(
                "ffi", function.name,
                type, function.file,
                function.line, function.col),
            memory, address, type, value)
    }

    fn ffi_host_storage(
        function: HirFunction, type: HirType,
        value: TreeValue,
        bridges: List<TreeFfiMemory>) ->
        RawPtr<u8> {
        let answer: LayoutAnswer = self.layout(type)
        unsafe {
            let host: RawPtr<u8> =
                RawPtr.alloc(answer.value.size)
            let temporary: TreeMemory =
                new TreeMemory(
                    0, answer.value.size,
                    answer.value.align)
            if self.ffi_memory_write_value(
                   function, temporary, 0,
                   type, value, bridges) {
                for index: int in
                    0..answer.value.size {
                    let byte: u8 =
                        temporary.data.get(index) as u8
                    host.offset(index).write(
                        byte)
                }
            }
            return host
        }
    }

    fn ffi_read_host_storage(
        function: HirFunction, type: HirType,
        host: RawPtr<u8>) -> TreeValue {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        unsafe {
            for index: int in 0..answer.value.size {
                let byte: u8 =
                    host.offset(index).read()
                temporary.data.set(
                    index, byte as int)
            }
        }
        return self.memory_read_value(
            new HirNode(
                "ffi", function.name,
                type, function.file,
                function.line, function.col),
            temporary, 0, type)
    }

    fn ffi_write_host_storage(
        function: HirFunction, type: HirType,
        value: TreeValue, host: RawPtr<u8>,
        bridges: List<TreeFfiMemory>) {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        if !self.ffi_memory_write_value(
               function, temporary, 0,
               type, value, bridges) {
            return
        }
        unsafe {
            for index: int in 0..answer.value.size {
                host.offset(index).write(
                    temporary.data.get(index) as u8)
            }
        }
    }

    fn ffi_callback_dispatch(
        function: HirFunction,
        captured_arguments: List<TreeValue>,
        context: RawPtr<u8>,
        result: RawPtr<u8>,
        raw_arguments: RawPtr<RawPtr<u8> >,
        bridges: List<TreeFfiMemory>) {
        var parameter_index: int = -1
        unsafe {
            parameter_index =
                ((context.address() as int - 1) /
                 2) - 1
        }
        if parameter_index < 0 ||
           parameter_index >=
               function.parameters.len() ||
           parameter_index >=
               captured_arguments.len() {
            self.fail_extern(
                function,
                "invalid C callback context")
            return
        }
        let callback_type: HirType =
            function.parameters[
                parameter_index].type
        let count: int =
            callback_type.fn_parameter_count
        var arguments: List<TreeValue> = []
        unsafe {
            for index: int in 0..count {
                let slot: RawPtr<u8> =
                    raw_arguments.offset(index).read()
                arguments.push(
                    self.ffi_read_host_storage(
                        function,
                        callback_type.args[index],
                        slot))
            }
        }
        let node: HirNode =
            new HirNode(
                "ffi_callback", function.name,
                callback_type, function.file,
                function.line, function.col)
        let returned: TreeValue =
            self.invoke_closure(
                node,
                captured_arguments[
                    parameter_index],
                move arguments)
        if self.failed ||
           count >= callback_type.args.len() ||
           callback_type.args[count].name ==
               "unit" {
            return
        }
        unsafe {
            if !result.is_null() {
                self.ffi_write_host_storage(
                    function,
                    callback_type.args[count],
                    returned, result, bridges)
            }
        }
    }

    fn ffi_bridge_source(
        function: HirFunction,
        abi: CAbiDescription) -> string {
        var parameters: string =
            abi.parameter_declarations.join(", ")
        if parameters == "" { parameters = "void" }
        var source: string =
            "#include <stdint.h>\n{abi.definitions}"
        source =
            "{source}typedef void (*BeansFfiDispatch)(void*, void*, void**);\n"
        for callback: CAbiCallbackDescription in
            abi.callbacks {
            let prefix: string =
                "beans_ffi_cb{callback.parameter_index}"
            source =
                "{source}static _Thread_local BeansFfiDispatch {prefix}_dispatch;\n"
            source =
                "{source}static _Thread_local void* {prefix}_context;\n"
            var callback_parameters: string =
                callback.parameter_declarations.join(", ")
            if callback_parameters == "" {
                callback_parameters = "void"
            }
            source =
                "{source}static {callback.return_type} {prefix}({callback_parameters}) \{\n"
            let slot_count: int =
                if callback.parameter_types.len() == 0 {
                    1
                } else {
                    callback.parameter_types.len()
                }
            var callback_arguments: List<string> = []
            for index: int in
                0..callback.parameter_types.len() {
                callback_arguments.push(
                    "&value{index}")
            }
            if callback_arguments.len() == 0 {
                callback_arguments.push("0")
            }
            source =
                "{source}  void* callback_args[{slot_count}] = \{{callback_arguments.join(", ")}\};\n"
            if callback.return_type == "void" {
                source =
                    "{source}  {prefix}_dispatch({prefix}_context, 0, callback_args);\n\}\n"
            } else {
                source =
                    "{source}  {callback.return_type} callback_result = \{0\};\n"
                source =
                    "{source}  {prefix}_dispatch({prefix}_context, &callback_result, callback_args);\n"
                source =
                    "{source}  return callback_result;\n\}\n"
            }
        }
        source =
            "{source}typedef {abi.return_type} (*BeansFfiFn)({parameters});\n"
        source =
            "{source}{ffi_export_attribute()}"
        source =
            "{source}void beans_ffi_bridge(void* symbol, void* result, void** args, BeansFfiDispatch dispatch, void** contexts) \{\n"
        source =
            "{source}  BeansFfiFn fn = (BeansFfiFn)symbol;\n  "
        for callback: CAbiCallbackDescription in
            abi.callbacks {
            let prefix: string =
                "beans_ffi_cb{callback.parameter_index}"
            source =
                "{source}BeansFfiDispatch {prefix}_old_dispatch = {prefix}_dispatch;\n  "
            source =
                "{source}void* {prefix}_old_context = {prefix}_context;\n  "
            source =
                "{source}{prefix}_dispatch = dispatch;\n  "
            source =
                "{source}{prefix}_context = contexts[{callback.parameter_index}];\n  "
            source =
                "{source}void* {prefix}_stored = (((uintptr_t){prefix}_context & 1u) == 0) ? *(void**)args[{callback.parameter_index}] : 0;\n  "
        }
        if function.result.name != "unit" {
            source =
                "{source}{abi.return_type} call_result = "
        }
        source = "{source}fn("
        var calls: List<string> = []
        for index: int in
            0..abi.parameter_types.len() {
            var callback_name: string = ""
            for callback: CAbiCallbackDescription in
                abi.callbacks {
                if callback.parameter_index == index {
                    callback_name =
                        "beans_ffi_cb{index}"
                }
            }
            if callback_name == "" {
                calls.push(
                    "*({abi.parameter_types[index]}*)args[{index}]")
            } else {
                var callback_types: string =
                    "void"
                var callback_result: string =
                    "void"
                for callback:
                        CAbiCallbackDescription in
                    abi.callbacks {
                    if callback.parameter_index ==
                       index {
                        callback_result =
                            callback.return_type
                        if callback.parameter_types.len() !=
                               0 {
                            callback_types =
                                callback.parameter_types.join(
                                    ", ")
                        }
                    }
                }
                calls.push(
                    "({callback_name}_stored ? ({callback_result} (*)({callback_types})){callback_name}_stored : {callback_name})")
            }
        }
        source = "{source}{calls.join(", ")});\n"
        for callback: CAbiCallbackDescription in
            abi.callbacks {
            let prefix: string =
                "beans_ffi_cb{callback.parameter_index}"
            source =
                "{source}  {prefix}_dispatch = {prefix}_old_dispatch;\n"
            source =
                "{source}  {prefix}_context = {prefix}_old_context;\n"
        }
        if function.result.name != "unit" {
            source =
                "{source}  *({abi.return_type}*)result = call_result;\n"
        }
        return "{source}\}\n"
    }

    fn ffi_pack_argument(
        packed: Bytes, value: string) {
        packed.append_string(value)
        packed.push(0)
    }

    // The bridge has to be built by the same C driver `beansc build` would
    // select, so an installation that names its compiler through BEANS_CC
    // cannot build programs and still fail the moment one is interpreted.
    fn ffi_c_driver() -> string {
        match host_os.env("BEANS_CC") {
            some(value) => {
                if value != "" { return value }
            }
            none => {}
        }
        return "clang"
    }

    // Forward one host environment variable into a packed "NAME=value" block,
    // dropping it silently when the host does not set it.
    fn ffi_forward_env(
        environment: Bytes, name: string) {
        match host_os.env(name) {
            some(value) => {
                self.ffi_pack_argument(
                    environment, "{name}={value}")
            }
            none => {}
        }
    }

    fn ffi_bridge(
        function: HirFunction,
        source: string) -> int {
        match self.ffi_bridge_addresses.get(
                source) {
            some(address) => { return address }
            none => {}
        }
        let sequence: int =
            self.ffi_bridge_sequence
        self.ffi_bridge_sequence += 1
        let stem: string =
            "{Dir.temp_path()}/beans-ffi-{host_time.monotonic_nanos()}-{sequence}"
        let c_path: string = "{stem}.c"
        let library_path: string =
            if self.program.target.os == "macos" {
                "{stem}.dylib"
            } else if self.program.target.os == "windows" {
                "{stem}.dll"
            } else {
                "{stem}.so"
            }
        match host_fs.write(c_path, source) {
            ok(_) => {}
            err(error) => {
                return self.fail_extern(
                    function,
                    "cannot write C ABI bridge: {error.msg}").int_data
            }
        }
        let c_driver: string =
            self.ffi_c_driver()
        let argv: Bytes = new Bytes(0)
        self.ffi_pack_argument(argv, c_driver)
        self.ffi_pack_argument(argv, "-O2")
        if self.program.target.os == "macos" {
            self.ffi_pack_argument(
                argv, "-dynamiclib")
            self.ffi_pack_argument(
                argv, "-undefined")
            self.ffi_pack_argument(
                argv, "dynamic_lookup")
        } else {
            self.ffi_pack_argument(argv, "-shared")
            // Windows code is position-independent by construction, so there
            // is nothing for -fPIC to ask for; clang rejects it outright for
            // the MSVC targets rather than ignoring it.
            if self.program.target.os != "windows" {
                self.ffi_pack_argument(argv, "-fPIC")
            }
        }
        if self.program.target.os == "windows" {
            // The bridge is loaded into this process, so it has to match this
            // process's ABI — and clang on Windows defaults to the MSVC
            // environment, which is a different one. Naming the triple is not
            // cross-compiling here; it is refusing to let the default pick a
            // stranger's ABI.
            self.ffi_pack_argument(
                argv, "--target={self.program.target.llvm_triple()}")
        }
        self.ffi_pack_argument(argv, c_path)
        self.ffi_pack_argument(argv, "-o")
        self.ffi_pack_argument(argv, library_path)
        let environment: Bytes = new Bytes(0)
        // clang writes its intermediate object to the system temp directory, so a
        // child handed only PATH cannot compile the bridge on Windows: unlike
        // POSIX clang, which falls back to /tmp, Windows clang has no default and
        // dies with "unable to make temporary file". The failure surfaced as a
        // bare "C symbol not found: fabsf" — fabsf reaches the bridge because
        // msvcrt exports no float-suffixed math symbol for the module walk to
        // find, and the swallowed clang error left only the generic message. The
        // stage-0 interpreter hands clang the whole environment for this helper;
        // forward at least PATH and the temp-dir variables it needs.
        self.ffi_forward_env(environment, "PATH")
        self.ffi_forward_env(environment, "TMPDIR")
        self.ffi_forward_env(environment, "TEMP")
        self.ffi_forward_env(environment, "TMP")
        // MSVC's clang and lld find the Windows SDK and CRT through these
        // developer-prompt variables. Without them the fallback shim for a
        // static CRT symbol such as fabsf cannot compile or link.
        self.ffi_forward_env(environment, "INCLUDE")
        self.ffi_forward_env(environment, "LIB")
        self.ffi_forward_env(environment, "LIBPATH")
        var compiled: bool = false
        var compiler_error: string = ""
        match host_proc.run(
                argv, environment, "",
                new Bytes(0), 1048576) {
            ok(output) => {
                let status: int =
                    output.get_i64(0)
                let out_size: int =
                    output.get_i64(8)
                let err_size: int =
                    output.get_i64(16)
                compiled = status == 0
                if err_size != 0 {
                    let error_bytes: Bytes =
                        output.slice(
                            24 + out_size,
                            24 + out_size +
                                err_size)
                    compiler_error =
                        error_bytes.to_string()
                }
            }
            err(error) => {
                compiler_error = error.msg
            }
        }
        if !compiled {
            File.remove(c_path)
            File.remove(library_path)
            return self.fail_extern(
                function,
                "{c_driver} could not build the C ABI bridge: {compiler_error}").int_data
        }
        var handle: int = 0
        match host_dl.open(library_path) {
            ok(value) => { handle = value }
            err(error) => {
                File.remove(c_path)
                File.remove(library_path)
                return self.fail_extern(
                    function,
                    "cannot load C ABI bridge: {error.msg}").int_data
            }
        }
        var address: int = 0
        match host_dl.symbol(
                handle, "beans_ffi_bridge") {
            ok(value) => { address = value }
            err(error) => {
                host_dl.close(handle)
                File.remove(c_path)
                File.remove(library_path)
                return self.fail_extern(
                    function,
                    "cannot resolve C ABI bridge: {error.msg}").int_data
            }
        }
        File.remove(c_path)
        File.remove(library_path)
        self.ffi_bridge_handles.push(handle)
        self.ffi_bridge_addresses[source] =
            address
        return address
    }

    fn call_extern_bridge(
        function: HirFunction,
        arguments: List<TreeValue>,
        symbol: int,
        abi: CAbiDescription) -> TreeValue {
        let source: string =
            self.ffi_bridge_source(function, abi)
        let bridge: int =
            self.ffi_bridge(function, source)
        if self.failed { return TreeValue.unit() }

        var pointer_bridges: List<TreeFfiMemory> = []
        var storage: List<RawPtr<u8>> = []
        unsafe {
            // The bridge indexes these slots as void**, so each one is a host
            // pointer, not a fixed u64 — on a 32-bit host args[1] would land
            // in the high half of a widened slot and read as null.
            let pointers: RawPtr<RawPtr<u8> > =
                RawPtr.alloc(arguments.len())
            let contexts:
                RawPtr<RawPtr<u8> > =
                RawPtr.alloc(arguments.len())
            for index: int in 0..arguments.len() {
                let parameter_type: HirType =
                    function.parameters[index].type
                if parameter_type.name == "fn" {
                    pointers.offset(index).write(
                        RawPtr.null())
                    if arguments[index].kind ==
                           "stored_function" {
                        let stored_value:
                            TreeValue =
                            arguments[index]
                        match self.stored_callbacks.get(
                                  stored_value.object_id) {
                            some(callback) => {
                                let stored:
                                    RawPtr<u8> =
                                    RawPtr.alloc(
                                        self.program.target.pointer_size())
                                let slot:
                                    RawPtr<RawPtr<u8> > =
                                    RawPtr.from_address(
                                        stored.address())
                                slot.write(
                                    RawPtr.from_address(
                                        stored_value.int_data as u64))
                                storage.push(stored)
                                pointers.offset(
                                    index).write(
                                        stored)
                                contexts.offset(
                                    index).write(
                                        callback.context)
                            }
                            none => {
                                self.fail_extern(
                                    function,
                                    "StoredCallback is already closed")
                            }
                        }
                    } else {
                        contexts.offset(index).write(
                            RawPtr.from_address(
                                (((index + 1) * 2 +
                                  1) as u64)))
                    }
                } else {
                    let argument: RawPtr<u8> =
                        self.ffi_host_storage(
                            function,
                            function.parameters[index].type,
                            arguments[index],
                            pointer_bridges)
                    storage.push(argument)
                    pointers.offset(index).write(
                        argument)
                    contexts.offset(index).write(
                        RawPtr.null())
                }
            }
            var result_storage: RawPtr<u8> =
                RawPtr.null()
            if function.result.name != "unit" {
                let result_layout: LayoutAnswer =
                    self.layout(function.result)
                result_storage =
                    RawPtr.alloc(
                        result_layout.value.size)
            }
            let dispatch:
                fn(RawPtr<u8>, RawPtr<u8>,
                   RawPtr<RawPtr<u8> >) =
                fn(context: RawPtr<u8>,
                   callback_result: RawPtr<u8>,
                   callback_arguments:
                       RawPtr<RawPtr<u8> >) {
                    self.ffi_callback_dispatch(
                        function, arguments,
                        context, callback_result,
                        callback_arguments,
                        pointer_bridges)
                }
            beans_tree_ffi_invoke_bridge(
                RawPtr.from_address(
                    bridge as u64),
                RawPtr.from_address(
                    symbol as u64),
                result_storage,
                RawPtr.from_address(
                    pointers.address()),
                dispatch, contexts)
            var result: TreeValue =
                TreeValue.unit()
            if function.result.name != "unit" {
                if canonical_hir_name(
                       function.result.name) ==
                   "RawPtr" {
                    // A returned pointer can land inside one of the host
                    // copies made for the pointer arguments. Map it back to
                    // the interpreter memory the copy mirrors — exactly what
                    // the direct word path does — before ffi_sync_and_free
                    // frees the copy and the address dangles.
                    var raw_address: u64 = 0
                    if self.program.target.pointer_size() ==
                       8 {
                        let slot: RawPtr<u64> =
                            RawPtr.from_address(
                                result_storage.address())
                        raw_address = slot.read()
                    } else {
                        let slot: RawPtr<u32> =
                            RawPtr.from_address(
                                result_storage.address())
                        raw_address =
                            slot.read() as u64
                    }
                    result =
                        self.ffi_pointer_result(
                            function.result,
                            raw_address as int,
                            pointer_bridges)
                } else {
                    result =
                        self.ffi_read_host_storage(
                            function, function.result,
                            result_storage)
                }
                result_storage.free()
            }
            for argument: RawPtr<u8> in storage {
                argument.free()
            }
            pointers.free()
            contexts.free()
            self.ffi_sync_and_free(
                pointer_bridges)
            return result
        }
    }

    // dlsym(RTLD_DEFAULT, ...) finds libc's symbols because libc is a shared
    // library and exports them. Windows links the CRT's math and string helpers
    // out of a static archive, so they belong to no module's export table and no
    // walk of the loader's module list can reach them — fabsf resolves nowhere
    // while memset, which msvcrt.dll does export, resolves fine. The C compiler
    // can still name either one, so a symbol the loader cannot find is asked for
    // the same way c_global_address asks for a thread-local: compile a shim that
    // takes its address and hand the pointer back. The bridge is cached by
    // source text, so this costs one compile per symbol per run.
    // Resolves and caches the shared bridge library for one std.encoding
    // feature. The library is compiled once per host from the same vendored
    // sources `beansc build` links, cached content-addressed under
    // BEANS_HOME, and reused across runs — so `beansc run` needs the C
    // driver at most once per checkout or upgrade.
    fn ensure_encoding_bridge(feature: string) -> int {
        match self.encoding_handles.get(feature) {
            some(handle) => { return handle }
            none => {}
        }
        let library: string =
            self.encoding_bridge_library(feature)
        if library == "" {
            self.encoding_handles[feature] = 0
            return 0
        }
        var handle: int = 0
        match host_dl.open(library) {
            ok(value) => { handle = value }
            err(error) => {
                self.encoding_error =
                    "cannot load {library}: {error.msg}"
            }
        }
        self.encoding_handles[feature] = handle
        return handle
    }

    fn encoding_bridge_library(feature: string) -> string {
        let root: string = encoding_source_root()
        let source: string =
            encoding_bridge_translation_unit(root, feature)
        if !File.exists(source) {
            self.encoding_error =
                "cannot find the bridge sources under {root}; set BEANS_ENCODING to the directory holding runtime/encoding"
            return ""
        }
        var blob: string =
            "{self.program.target.triple}|interp"
        for input: string in
            encoding_bridge_inputs(root, feature) {
            match host_fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => {
                    blob = "{blob}|missing:{input}"
                }
            }
        }
        var hash: int = 0
        for index: int in 0..blob.len() {
            hash =
                (hash * 131 + blob.byte_at(index)) %
                2147483647
        }
        let extension: string =
            if self.program.target.os == "macos" {
                "dylib"
            } else if self.program.target.os == "windows" {
                "dll"
            } else {
                "so"
            }
        let cache_dir: string =
            "{beans_home()}/cache/encoding"
        let library: string =
            "{cache_dir}/beans_enc_{feature}.{self.program.target.triple}.{hash}.{extension}"
        if File.exists(library) { return library }
        match Dir.create_all(cache_dir) {
            ok(_) => {}
            err(error) => {
                self.encoding_error =
                    "cannot create {cache_dir}: {error.msg}"
                return ""
            }
        }
        let staging: string =
            "{library}.{host_time.monotonic_nanos()}"
        let c_driver: string = self.ffi_c_driver()
        let argv: Bytes = new Bytes(0)
        self.ffi_pack_argument(argv, c_driver)
        if encoding_bridge_is_cxx(feature) {
            self.ffi_pack_argument(argv, "-x")
            self.ffi_pack_argument(argv, "c++")
            self.ffi_pack_argument(argv, "-std=c++17")
            self.ffi_pack_argument(argv, "-fno-exceptions")
            self.ffi_pack_argument(argv, "-fno-rtti")
        }
        self.ffi_pack_argument(argv, "-O2")
        self.ffi_pack_argument(argv, "-fvisibility=hidden")
        if self.program.target.os == "macos" {
            self.ffi_pack_argument(argv, "-dynamiclib")
        } else {
            self.ffi_pack_argument(argv, "-shared")
            // See ffi_bridge above: -fPIC is not a thing to ask for on
            // Windows, and clang errors on it for the MSVC targets.
            if self.program.target.os != "windows" {
                self.ffi_pack_argument(argv, "-fPIC")
            }
        }
        if self.program.target.os == "windows" {
            // The bridge is loaded into this process, so it has to match
            // this process's ABI; see ffi_bridge above.
            self.ffi_pack_argument(
                argv,
                "--target={self.program.target.llvm_triple()}")
        }
        self.ffi_pack_argument(argv, source)
        self.ffi_pack_argument(argv, "-o")
        self.ffi_pack_argument(argv, staging)
        let environment: Bytes = new Bytes(0)
        self.ffi_forward_env(environment, "PATH")
        self.ffi_forward_env(environment, "TMPDIR")
        self.ffi_forward_env(environment, "TEMP")
        self.ffi_forward_env(environment, "TMP")
        self.ffi_forward_env(environment, "INCLUDE")
        self.ffi_forward_env(environment, "LIB")
        self.ffi_forward_env(environment, "LIBPATH")
        var compiled: bool = false
        var compiler_error: string = ""
        match host_proc.run(
                argv, environment, "",
                new Bytes(0), 8388608) {
            ok(output) => {
                let status: int = output.get_i64(0)
                let out_size: int = output.get_i64(8)
                let err_size: int = output.get_i64(16)
                compiled = status == 0
                if err_size != 0 {
                    let error_bytes: Bytes =
                        output.slice(
                            24 + out_size,
                            24 + out_size + err_size)
                    compiler_error =
                        error_bytes.to_string()
                }
            }
            err(error) => {
                compiler_error = error.msg
            }
        }
        if !compiled {
            File.remove(staging)
            self.encoding_error =
                "building the bridge with {c_driver} failed: {compiler_error.trim()}"
            return ""
        }
        match File.rename(staging, library) {
            ok(_) => {}
            err(_) => {
                // a concurrent run already published the same content
                File.remove(staging)
            }
        }
        if File.exists(library) { return library }
        self.encoding_error =
            "cannot place the bridge library at {library}"
        return ""
    }

    fn extern_symbol_address(
        function: HirFunction) -> int {
        match host_dl.global_symbol(
                  function.extern_name) {
            ok(address) => { return address }
            err(error) => {}
        }
        // The std.encoding bridges live in RTLD_LOCAL shared libraries the
        // interpreter loads on demand, so their symbols are resolved through
        // the library handle rather than the global namespace.
        if function.extern_name.starts_with("beans_enc_") {
            let feature: string =
                encoding_feature_for_symbol(
                    function.extern_name)
            if feature != "" {
                let handle: int =
                    self.ensure_encoding_bridge(feature)
                if handle != 0 {
                    match host_dl.symbol(
                              handle,
                              function.extern_name) {
                        ok(address) => { return address }
                        err(_) => {}
                    }
                } else {
                    return self.fail_extern(
                        function,
                        "std.encoding.{feature} bridge library is unavailable: {self.encoding_error}").int_data
                }
            }
        }
        let builder: CAbiTextBuilder =
            new CAbiTextBuilder(self.program)
        let abi: CAbiDescription =
            builder.describe(function)
        var parameters: string =
            abi.parameter_declarations.join(", ")
        if parameters == "" { parameters = "void" }
        // This declaration must carry the real signature. Clang knows the CRT
        // builtins, so spelling fabsf as `extern void fabsf()` conflicts with
        // its `float(float)` declaration before the shim can reach the linker.
        var source: string =
            "#include <stdint.h>\n{abi.definitions}"
        source =
            "{source}extern {abi.return_type} {function.extern_name}({parameters});\n"
        source =
            "{source}{ffi_export_attribute()}"
        source =
            "{source}void* beans_ffi_bridge(void) \{ return (void*)&{function.extern_name}; \}\n"
        let bridge: int =
            self.ffi_bridge(function, source)
        if self.failed {
            // A shim that will not link means the symbol is genuinely absent.
            // Say that, rather than blaming the bridge the caller never asked
            // for — the message has to match what every other platform prints.
            self.panic_text =
                "runtime panic at {function.line}:{function.col}: C symbol not found: {function.extern_name}"
            return 0
        }
        unsafe {
            return host_dl.call0(bridge)
        }
    }

    fn call_extern(
        function: HirFunction,
        arguments: List<TreeValue>) -> TreeValue {
        let symbol: int =
            self.extern_symbol_address(function)
        if self.failed { return TreeValue.unit() }

        let result_name: string =
            canonical_hir_name(function.result.name)
        let first_name: string =
            if function.parameters.len() > 0 {
                canonical_hir_name(
                    function.parameters[0].type.name)
            } else {
                ""
            }
        var result: TreeValue = TreeValue.unit()
        var called: bool = false
        unsafe {
            if arguments.len() == 1 &&
               (first_name == "float" ||
                first_name == "f32") &&
               result_name == first_name {
                result = TreeValue.floating(
                    if first_name == "f32" {
                        host_dl.call_f32_1(
                            symbol,
                            arguments[0].float_data)
                    } else {
                        host_dl.call_f64_1(
                            symbol,
                            arguments[0].float_data)
                    })
                called = true
            } else if arguments.len() == 2 &&
                      (first_name == "float" ||
                       first_name == "f32") &&
                      hir_is_integer(
                          function.parameters[1].type) &&
                      result_name == first_name {
                result = TreeValue.floating(
                    if first_name == "f32" {
                        host_dl.call_f32_i32(
                            symbol,
                            arguments[0].float_data,
                            arguments[1].int_data)
                    } else {
                        host_dl.call_f64_i32(
                            symbol,
                            arguments[0].float_data,
                            arguments[1].int_data)
                    })
                called = true
            }
        }
        if called { return result }

        // host_dl.callN passes every argument as one 8-byte word. A 64-bit
        // host gives each word its own argument slot, so a narrower integer
        // still lands where the callee reads it. A 32-bit host splits the
        // word across two native slots (i386 stack halves, EABI register
        // pairs): a parameter narrower than the word leaves a stray
        // high-half slot that shifts every argument after it, so only the
        // final parameter may be narrow there. Anything else routes to the
        // Clang-classified bridge, which marshals by declared width.
        let host_pointer_bytes: int =
            self.program.target.pointer_size()
        var direct_words: bool =
            arguments.len() <= 3
        for index: int in
            0..function.parameters.len() {
            let parameter_type: HirType =
                function.parameters[index].type
            let name: string =
                canonical_hir_name(
                    parameter_type.name)
            var native_bytes: int = 0
            if name == "RawPtr" {
                native_bytes = host_pointer_bytes
            } else if hir_is_integer(
                          parameter_type) &&
                      tree_integer_bits(name) >= 32 {
                native_bytes =
                    tree_integer_bits(name) / 8
            } else {
                direct_words = false
            }
            if host_pointer_bytes < 8 &&
               native_bytes < 8 &&
               index + 1 <
                   function.parameters.len() {
                direct_words = false
            }
        }
        if result_name == "bool" {
            direct_words = false
        } else if result_name != "unit" &&
                  result_name != "RawPtr" &&
                  (!hir_is_integer(function.result) ||
                   tree_integer_bits(
                       result_name) < 32) {
            direct_words = false
        }
        if !direct_words {
            let builder: CAbiTextBuilder =
                new CAbiTextBuilder(self.program)
            return self.call_extern_bridge(
                function, arguments, symbol,
                builder.describe(function))
        }

        var bridges: List<TreeFfiMemory> = []
        var words: List<int> = []
        var word_signature: bool =
            arguments.len() <= 3
        for index: int in 0..arguments.len() {
            let type: HirType =
                function.parameters[index].type
            let name: string =
                canonical_hir_name(type.name)
            if name == "RawPtr" {
                words.push(
                    self.ffi_pointer_word(
                        function, arguments[index],
                        bridges))
            } else if hir_is_integer(type) {
                words.push(arguments[index].int_data)
            } else if name == "bool" {
                words.push(
                    if arguments[index].bool_data {
                        1
                    } else {
                        0
                    })
            } else {
                word_signature = false
                words.push(0)
            }
        }
        if self.failed {
            self.ffi_sync_and_free(bridges)
            return TreeValue.unit()
        }
        if !word_signature ||
           (result_name != "unit" &&
            result_name != "RawPtr" &&
            result_name != "bool" &&
            !hir_is_integer(function.result)) {
            self.ffi_sync_and_free(bridges)
            return self.fail_extern(
                function,
                "extern C signature is not in the Beans interpreter yet")
        }

        var raw: int = 0
        unsafe {
            if result_name == "unit" {
                if words.len() == 0 {
                    host_dl.call_void0(symbol)
                } else if words.len() == 1 {
                    host_dl.call_void1(
                        symbol, words[0])
                } else if words.len() == 2 {
                    host_dl.call_void2(
                        symbol, words[0], words[1])
                } else {
                    host_dl.call_void3(
                        symbol, words[0], words[1],
                        words[2])
                }
            } else {
                if words.len() == 0 {
                    raw = host_dl.call0(symbol)
                } else if words.len() == 1 {
                    raw = host_dl.call1(
                        symbol, words[0])
                } else if words.len() == 2 {
                    raw = host_dl.call2(
                        symbol, words[0], words[1])
                } else {
                    raw = host_dl.call3(
                        symbol, words[0], words[1],
                        words[2])
                }
            }
        }
        if result_name == "RawPtr" {
            result = self.ffi_pointer_result(
                function.result, raw, bridges)
        } else if result_name != "unit" {
            result = self.ffi_integer_result(
                function.result, raw)
        }
        self.ffi_sync_and_free(bridges)
        return result
    }

    fn invoke(function: HirFunction,
              arguments: List<TreeValue>,
              receiver: Option<TreeValue>) -> TreeValue {
        if function.is_async && !function.expanded {
            // The async expander rewrites every async body into a task
            // maker before execution; reaching one here is a compiler bug,
            // not a user error.
            self.fail_extern(
                function,
                "internal: async function '{function.name}' was not expanded before execution")
            return TreeValue.unit()
        }
        if function.is_extern_c && !function.is_c_export {
            return self.call_extern(
                function, arguments)
        }
        let frame: TreeFrame = new TreeFrame()
        match receiver {
            some(value) => {
                frame.self_value = some(value)
                if function.self_binding_id >= 0 {
                    frame.set(
                        function.self_binding_id, value)
                }
            }
            none => {}
        }
        for index: int in 0..function.parameters.len() {
            if index < arguments.len() {
                let argument: TreeValue =
                    if function.parameters[index].passing ==
                           "move" ||
                       function.parameters[index].passing ==
                           "inout" {
                        arguments[index]
                    } else {
                        tree_value_copy(
                            arguments[index])
                    }
                frame.set(
                    function.parameters[index].binding_id,
                    argument)
            }
        }
        match self.debugger {
            some(session) => {
                session.push_frame(function, frame)
            }
            none => {}
        }
        var result: TreeValue = TreeValue.unit()
        for statement: HirNode in function.body {
            let flow: TreeExec =
                self.statement(statement, frame)
            if flow.kind == "return" {
                result = flow.value
                break
            }
            if flow.kind != "next" { break }
        }
        self.run_defers(frame)
        match self.debugger {
            some(session) => { session.pop_frame() }
            none => {}
        }
        return result
    }

    fn run() -> bool {
        match self.find_function(self.program.entry_symbol) {
            some(entry) => {
                self.invoke(entry, [], none)
            }
            none => {
                self.failed = true
                self.panic_text =
                    "runtime panic: program has no main function"
            }
        }
        return !self.failed
    }
}
