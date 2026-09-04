package main

// One object's field storage, boxed so several host-level wrappers can
// stand for one interpreted object (zeroing weak revival) while the map
// itself keeps a single owner.
//
// The entry order of this map IS the object's storage order, because the
// host runtime releases a map's entries back to front — so it has to be
// the order a native build lays the same class out in: every declared
// field takes its slot when the object is built, base class first and in
// declaration order within each class. A slot nothing has written yet
// holds `unset`, which reads as an absent field everywhere; that keeps
// the position without inventing a value for it.
class TreeFields {
    entries: Map<string, TreeValue>

    fn init() {
        self.entries = {}
    }

    // The written value in a slot, or none for a slot that is only
    // reserved. Every reader of a field goes through this, so a reserved
    // slot is indistinguishable from a field that was never stored.
    fn value(name: string) -> Option<TreeValue> {
        match self.entries.get(name) {
            some(stored) => {
                if stored.kind == "unset" { return none }
                return some(stored)
            }
            none => { return none }
        }
    }

    // How many fields actually hold a value; reserved slots do not count.
    fn written() -> int {
        var total: int = 0
        for name: string in self.entries.keys() {
            if self.entries[name].kind != "unset" {
                total += 1
            }
        }
        return total
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
    fields: TreeFields
    // A tree map keeps one entry as one value so the two halves die as a unit,
    // the way a native map entry does (#97). map_values maps the encoded key to
    // an entry (kind "map_entry", items = [key, value]); a beans Map preserves
    // insertion order, so a dropped map releases its entries back to front, each
    // releasing its value (item 1) before its key (item 0). map_keys holds the
    // key objects for enumeration order and indexed access, aliasing the keys
    // the entries own, and is declared AFTER map_values so the host releases the
    // alias list first -- as a no-op, the entries still hold the keys -- and the
    // entries last, which is where every key's and value's deinit runs. Reverse
    // that declaration order and a whole map goes back to all-values-then-all-
    // keys, which is the split #97 was.
    map_values: Map<string, TreeValue>
    map_keys: List<TreeValue>
    map_version: int
    // A list carries the same structural change count a map does, plus the
    // name of the operation that last moved it, so an invalidated loop can
    // say what changed. Mirrors BList's change_count and change_kind in
    // runtime/beans_rt.c -- the same two facts, held as a count and a name
    // here because a tree value has no ABI to keep.
    list_version: int
    list_change: string
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
    channel_cell:
        Option<Mutex<TreeChannelState>>
    thread_handle: Option<Thread<int>>
    thread_work:
        Option<Mutex<TreeThreadWork>>
    brew_work: Option<TreeBrewState>
    group_work: Option<TreeTaskGroupState>
    // Concrete type arguments captured by generic objects and closures.
    // The tree interpreter is type-erased at runtime, so reflective code
    // needs this small side channel for operations such as type_of(T).
    generic_types: Map<string, HirType>

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
        self.fields = new TreeFields()
        self.map_values = {}
        self.map_keys = []
        self.map_version = 0
        self.list_version = 0
        self.list_change = ""
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
        self.channel_cell = none
        self.thread_handle = none
        self.thread_work = none
        self.brew_work = none
        self.group_work = none
        self.generic_types = {}
    }

    static fn unit() -> TreeValue {
        return new TreeValue("unit")
    }

    // A field slot reserved by construction and not written yet. It is not
    // a value: TreeFields.value hides it, so a read still reports the field
    // as uninitialized. It exists only to fix where the field sits in the
    // object's storage, and therefore where it lands in the release order.
    static fn unset() -> TreeValue {
        return new TreeValue("unset")
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

    static fn bytes(move value: Bytes) -> TreeValue {
        let result: TreeValue = new TreeValue("bytes")
        result.bytes_data = some(move value)
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
        result.fields.entries["msg"] =
            TreeValue.string(message)
        result.fields.entries["kind"] =
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

    static fn file(move value: File) -> TreeValue {
        let result: TreeValue =
            new TreeValue("file")
        result.file_value = some(move value)
        return result
    }

    static fn mmap(move value: MMap) -> TreeValue {
        let result: TreeValue =
            new TreeValue("mmap")
        result.mmap_value = some(move value)
        return result
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
            self.interpreter.object_wrapper_died(self)
        }
    }
}

// A map entry owns both halves of one entry so they die as a unit (#97). The
// items are [key, value]: the host releases a list back to front, so the value
// (item 1) is released before the key (item 0), which is the order a native map
// releases an entry in. map_values stores these under the encoded key.
fn tree_map_entry(key: TreeValue,
                  value: TreeValue) -> TreeValue {
    let entry: TreeValue = new TreeValue("map_entry")
    entry.items.push(key)
    entry.items.push(value)
    return entry
}

fn tree_map_entry_key(entry: TreeValue) -> TreeValue {
    return entry.items[0]
}

fn tree_map_entry_value(entry: TreeValue) -> TreeValue {
    return entry.items[1]
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
                some(entry) => {
                    pieces.push(
                        "{tree_value_text(key)}: {tree_value_text(tree_map_entry_value(entry))}")
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
        // the bits, not the rendering: a map key is compared with
        // tree_value_total_equal, which separates -0.0 from +0.0 and one NaN
        // from another, and both of those render the same text
        return "f:{tree_float_total_key(value.float_data)}"
    }
    if value.kind == "decimal" {
        return "d:{value.decimal_data}"
    }
    if value.kind == "object" {
        return "o:{value.object_id}"
    }
    if value.kind == "record" {
        var names: List<string> =
            value.fields.entries.keys()
        names.sort()
        var result: string =
            "r:{value.text.len()}:{value.text}"
        for name: string in names {
            match value.fields.value(name) {
                some(stored) => {
                    let field_key: string =
                        tree_value_key(stored)
                    result =
                        "{result}:{name.len()}:{name}:{field_key.len()}:{field_key}"
                }
                none => {}
            }
        }
        return result
    }
    // Every kind whose equality tree_value_total_equal decides structurally
    // gets a structural key, built from its elements' keys rather than from
    // its rendering. A fixed array is the one that bit: `[nan, 1.0]` and
    // `[-nan, 1.0]` are two keys the native backend keeps apart, and both
    // render "array:[nan, 1]", so the tree collapsed them into one and the
    // second insert replaced the first. Every element is length-prefixed, so
    // no two element sequences can run together into the same string.
    //
    // `simd` is deliberately not here. Its lanes compare with IEEE `==`, not
    // by their bits (see tree_value_total_equal), so a bit-exact key would
    // separate two vectors the language calls equal. It is not a valid map
    // key either — the checker refuses one for want of `Hash`.
    if value.kind == "variant" ||
       value.kind == "some" ||
       value.kind == "ok" ||
       value.kind == "err" ||
       value.kind == "list" ||
       value.kind == "array" ||
       value.kind == "range" {
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

// A runtime type name for a diagnostic. A value carrying no type at all
// renders as a phrase rather than as nothing: printed bare it becomes two
// spaces in the middle of a sentence, which reads like a formatting slip.
// A dispatch bug hid behind exactly that gap — the message said what was
// wrong and nobody could see it.
fn tree_type_label(name: string) -> string {
    if name == "" { return "a value with no type" }
    return name
}

// `==` and `!=` as the source wrote them. A bare float pair is the one place
// IEEE still decides: `nan == nan` is false and `-0.0 == 0.0` is true, which
// is what numeric code needs. Everything else — including a struct, list,
// Option or enum that happens to hold a float — is the `Eq` interface, and
// `Eq` on a float is bit equality (spec/SYNTAX.md, "Number rules"), because
// that is the equality that belongs with the totalOrder `Order` uses.
fn tree_value_equal(left: TreeValue,
                    right: TreeValue) -> bool {
    if left.kind == "float" &&
       right.kind == "float" {
        return left.float_data == right.float_data
    }
    return tree_value_total_equal(left, right)
}

// The `Eq` interface: map and set keys, `contains`, `index_of`, and every
// structural comparison. Mirrors slot_eq and the .next.eq thunks in the
// native backend arm for arm.
fn tree_value_total_equal(left: TreeValue,
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
        return tree_float_total_equal(
            left.float_data, right.float_data)
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
           left.fields.entries.len() !=
               right.fields.entries.len() {
            return false
        }
        // A reserved slot on one side and a written one on the other are as
        // different as two written values that disagree; two reserved slots
        // are the same absence.
        for name: string in left.fields.entries.keys() {
            match left.fields.value(name) {
                some(mine) => {
                    match right.fields.value(name) {
                        some(value) => {
                            if !tree_value_total_equal(
                                   mine, value) {
                                return false
                            }
                        }
                        none => { return false }
                    }
                }
                none => {
                    if right.fields.value(name).is_some() {
                        return false
                    }
                }
            }
        }
        return true
    }
    if left.kind == "variant" &&
       left.text != right.text {
        return false
    }
    if left.kind == "simd" {
        // A SIMD vector is arithmetic, not a container: it is neither Eq nor
        // Hash, nothing sorts it, and it cannot be a key. Its `==` is the
        // lane-wise IEEE compare the native backend emits (fcmp oeq per lane,
        // and-ed), so its lanes take the operator's equality, not the
        // interface's. Anything else would be a backend split.
        if left.text != right.text { return false }
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
    if left.kind == "variant" ||
       left.kind == "some" ||
       left.kind == "ok" ||
       left.kind == "err" ||
       left.kind == "list" ||
       left.kind == "array" ||
       left.kind == "range" {
        if left.items.len() != right.items.len() {
            return false
        }
        for index: int in 0..left.items.len() {
            if !tree_value_total_equal(
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
        // sort, min and max order through the Order interface, and Order is
        // total: IEEE `<` leaves NaN unordered with everything, which sorted
        // [3, 1, nan, 2] to [1, 3, nan, 2]. totalOrder, matching slot_cmp
        // kind 1 in runtime/beans_rt.c.
        return tree_float_total_less(
            left.float_data, right.float_data)
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
    // `Order` on a payload-free enum is the declaration-order tag, which a
    // variant carries in int_data. Only payload-free enums satisfy Order, so
    // sort, min and max reach this with no payload to break the tie — the
    // same i8/loaded-i64 tag compare the native backend's slot_cmp does.
    if left.kind == "variant" &&
       right.kind == "variant" {
        return left.int_data < right.int_data
    }
    return false
}

// floor written with truncation only, because the bootstrap compiler that
// builds this interpreter has no floor of its own to lean on. NaN, both
// zeros, infinities, and everything at or past 2^53 are already integral
// (or must keep their payload/sign), so only the truncatable middle does
// arithmetic.
fn tree_float_floor(value: float) -> float {
    if value != value { return value }
    if value == 0.0 { return value }
    if value >= 9007199254740992.0 ||
       value <= -9007199254740992.0 {
        return value
    }
    let truncated: float = (value as int) as float
    if truncated > value { return truncated - 1.0 }
    return truncated
}

fn tree_float_truncate(value: float) -> float {
    if value != value { return value }
    if value == 0.0 { return value }
    if value >= 9007199254740992.0 ||
       value <= -9007199254740992.0 {
        return value
    }
    return (value as int) as float
}

// The truncated remainder LLVM's frem and C's fmod both produce: the sign
// follows the dividend, so -7.5 % 2.0 is -1.5 and 7.5 % -2.0 is 1.5. The
// floored substitute `a - (a / b).floor() * b` disagrees on exactly those
// operands, which is why it is not used here — the two backends have to
// print the same bytes.
fn tree_float_remainder(left: float,
                        right: float) -> float {
    // NaN in, NaN out, and x % 0 is NaN as well
    if left != left || right != right ||
       right == 0.0 {
        return tree_float_nan()
    }
    // an infinite dividend has no remainder; an infinite divisor leaves
    // the dividend untouched
    let huge: float = tree_float_infinity()
    if left == huge || left == -huge {
        return tree_float_nan()
    }
    if right == huge || right == -huge {
        return left
    }
    let quotient: float =
        tree_float_truncate(left / right)
    let scaled: float = quotient * right
    if scaled != scaled ||
       scaled == huge || scaled == -huge {
        return left
    }
    return left - scaled
}

fn tree_float_nan() -> float {
    let zero: float = 0.0
    return zero / zero
}

// the overflow product is the IEEE infinity both backends print the same
fn tree_float_infinity() -> float {
    var big: float = 1.0e308
    return big * 1.0e308
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
        result.generic_types = copy_type_map(value.generic_types)
        match value.bytes_data {
            some(data) => {
                result.bytes_data =
                    some(data.slice(0, data.len()))
            }
            none => {}
        }
        for name: string in value.fields.entries.keys() {
            result.fields.entries[name] =
                tree_value_copy(value.fields.entries[name])
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
        // an enum variant carries its declaration-order tag in int_data,
        // the key `Order` compares by; a copy has to keep it or a sorted
        // or compared copy would read tag 0 for every variant
        result.int_data = value.int_data
        result.generic_types = copy_type_map(value.generic_types)
        return result
    }
    return value
}

fn tree_spawn_closure(value: TreeValue) -> TreeValue {
    let result: TreeValue =
        new TreeValue(value.kind)
    result.text = value.text
    result.closure_node = value.closure_node
    result.generic_types = copy_type_map(value.generic_types)
    match value.closure_frame {
        some(frame) => {
            result.closure_frame =
                some(frame.snapshot())
        }
        none => {}
    }
    return result
}

// A structural change to a list: anything that changes its length or moves an
// element to a different index. Element replacement is not one, so a `for`
// loop over the list keeps running and sees the replacement.
fn tree_list_changed(list: TreeValue, what: string) {
    list.list_version += 1
    list.list_change = what
}

// The interpreter and beans_list_iter_invalid in runtime/beans_rt.c must
// produce the same sentence.
fn tree_list_changed_message(
    what: string, was: int, now: int) -> string {
    let name: string =
        if what == "" { "change" } else { what }
    if was != now {
        return "list changed during iteration ({name}, length {was} -> {now})"
    }
    return "list changed during iteration ({name}, length {was})"
}
