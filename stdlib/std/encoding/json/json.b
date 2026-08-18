// JSON over the vendored yyjson bridge (runtime/encoding).
//
// This is a native Value/DOM API: parse gives a Value view over yyjson's
// immutable document, and child Values keep that document alive through a
// shared owner object — nothing is eagerly copied into Beans collections.
// Typed decoding entry points are declared here and lowered by the compiler.
// Their schemas use tool-retained annotations; the hot path never needs
// runtime reflection or public Value wrappers.
//
// Numbers keep their parsed kind: signed integers, unsigned integers and
// floating-point values are distinct (`Kind.integer`, `Kind.unsigned_integer`,
// `Kind.floating`), never collapsed into f64. An integer too large for both
// i64 and u64 parses as floating, the same reading every RFC 8259 parser
// gives it.
//
// Strict RFC 8259 is the default. The explicit opt-ins in `Options` accept
// three common extensions — comments, trailing commas, and inf/nan literals.
// That is a subset of JSON5, deliberately not called JSON5: unquoted keys,
// single quotes and the rest are not accepted.
//
// Object entries preserve document order, duplicates included: `entries()`
// reports every entry; `get()` returns the first match for a duplicated key.
// Values built with the `Value.of_*`/`array`/`object` constructors live in
// mutable documents; `push` and `add` deep-copy their argument into the
// target's document, so a Value can be inserted twice or shared freely.
// Values from `parse` are read-only: `push`/`add` on them report kind
// "immutable".

package json

/// How an unannotated Beans field name maps to a JSON object key.
pub enum Naming {
    exact
    camel_case
    snake_case
}

/// How a Bytes field is represented in JSON.
pub enum BytesFormat {
    base64
    array
}

/// Overrides one field or payload-free enum variant's JSON name.
@target(value: ["field", "variant"])
@retention(value: "tool")
pub annotation name {
    value: string
}

/// Extra input names accepted for one field. The first name stays canonical.
@target(value: ["field"])
@retention(value: "tool")
pub annotation alias {
    value: List<string>
}

/// Leaves a field out of automatic JSON decoding.
@target(value: ["field"])
@retention(value: "tool")
pub annotation ignore {}

/// Selects the default JSON naming rule for one struct.
@target(value: ["type"])
@retention(value: "tool")
pub annotation naming {
    value: Naming = Naming.exact
}

/// Lets a struct ignore JSON object keys it does not declare.
@target(value: ["type"])
@retention(value: "tool")
pub annotation allow_unknown {}

/// Selects the JSON representation of one Bytes field.
@target(value: ["field"])
@retention(value: "tool")
pub annotation bytes {
    value: BytesFormat = BytesFormat.base64
}

extern "C" fn beans_enc_json_parse(source: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_free_doc(doc: int) -> int
extern "C" fn beans_enc_json_kind(doc: int, val: int) -> int
extern "C" fn beans_enc_json_get_bool(doc: int, val: int) -> int
extern "C" fn beans_enc_json_get_sint(doc: int, val: int) -> int
extern "C" fn beans_enc_json_get_uint(doc: int, val: int) -> int
extern "C" fn beans_enc_json_get_real_bits(doc: int, val: int) -> int
extern "C" fn beans_enc_json_str_len(doc: int, val: int) -> int
extern "C" fn beans_enc_json_str_copy(doc: int, val: int, target: RawPtr<u8>) -> int
extern "C" fn beans_enc_json_container_len(doc: int, val: int) -> int
extern "C" fn beans_enc_json_arr_get(doc: int, val: int, index: int) -> int
extern "C" fn beans_enc_json_arr_items(doc: int, val: int, out: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_obj_entries_words(doc: int, val: int) -> int
extern "C" fn beans_enc_json_obj_entries_pack(doc: int, val: int, out: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_obj_entries_refs(doc: int, val: int, out: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_obj_get(key: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_mut_new() -> int
extern "C" fn beans_enc_json_mut_null(doc: int) -> int
extern "C" fn beans_enc_json_mut_bool(doc: int, value: int) -> int
extern "C" fn beans_enc_json_mut_sint(doc: int, value: int) -> int
extern "C" fn beans_enc_json_mut_uint(doc: int, bits: int) -> int
extern "C" fn beans_enc_json_mut_real(doc: int, bits: int) -> int
extern "C" fn beans_enc_json_mut_str(doc: int, source: RawPtr<u8>, len: int) -> int
extern "C" fn beans_enc_json_mut_arr(doc: int) -> int
extern "C" fn beans_enc_json_mut_obj(doc: int) -> int
extern "C" fn beans_enc_json_arr_push(req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_obj_add(key: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_write(req: RawPtr<u64>) -> int
extern "C" fn beans_enc_json_take_buf(buf: int, len: int, target: RawPtr<u8>) -> int

// Native code replaces these private helpers with the address of the
// existing immutable string and one exact final-string allocation. The
// interpreters return 0/empty and use the portable raw-buffer path below.
fn enc_bytes_address(data: Bytes) -> int {
    return 0
}

fn enc_string_address(text: string) -> int {
    return 0
}

fn enc_string_uninit(length: int) -> string {
    return ""
}

// ---- raw-buffer marshalling (word-at-a-time, no per-byte Beans calls) ----

// Bulk copy through the public Bytes pointer bridge. This is one memcpy on
// both native and interpreted paths and does not assume word alignment.
fn raw_copy_from_bytes(data: Bytes, from: int, address: int, count: int) {
    if from < 0 || count < 0 || from + count > data.len() {
        panic("encoding raw copy out of range")
    }
    if count == 0 { return }
    unsafe {
        let target: RawPtr<u8> = RawPtr.from_address(address as u64)
        target.copy_from(data.as_ptr().offset(from), count)
    }
}

fn raw_copy_to_bytes(address: int, target: Bytes, at: int, count: int) {
    if at < 0 || count < 0 || at + count > target.len() {
        panic("encoding raw copy out of range")
    }
    if count == 0 { return }
    unsafe {
        let source: RawPtr<u8> = RawPtr.from_address(address as u64)
        target.as_ptr().offset(at).copy_from(source, count)
    }
}

fn raw_from_bytes(data: Bytes) -> int {
    let count: int = data.len()
    let address: int = alloc_words((count + 7) / 8)
    raw_copy_from_bytes(data, 0, address, count)
    return address
}

fn bytes_from_raw(address: int, count: int) -> Bytes {
    unsafe {
        return Bytes.from_raw(RawPtr.from_address(address as u64), count)
    }
}

fn free_raw(address: int) {
    unsafe {
        let block: RawPtr<u8> = RawPtr.from_address(address as u64)
        block.free()
    }
}

fn alloc_words(count: int) -> int {
    var address: int = 0
    unsafe {
        let block: RawPtr<u64> = RawPtr.alloc(if count == 0 { 1 } else { count })
        address = block.address() as int
    }
    return address
}

// Bit-preserving f64 conversion through a scoped stack slot: no heap
// allocation on either backend.
fn f64_from_bits(bits: u64) -> float {
    var scratch: u64 = bits
    var value: float = 0.0
    unsafe {
        RawPtr.with_local(inout scratch, fn(slot: RawPtr<u64>) {
            let view: RawPtr<f64> = RawPtr.from_address(slot.address())
            value = view.read()
        })
    }
    return value
}

fn f64_bits(value: float) -> u64 {
    var scratch: u64 = 0
    unsafe {
        RawPtr.with_local(inout scratch, fn(slot: RawPtr<u64>) {
            let view: RawPtr<f64> = RawPtr.from_address(slot.address())
            view.write(value)
        })
    }
    return scratch
}

/// What a Value holds.
pub enum Kind {
    null
    boolean
    integer
    unsigned_integer
    floating
    text
    array
    object
}

/// Strict parsing accepts RFC 8259 exactly; each field opts into one named
/// extension. This is not JSON5.
pub class Options {
    pub allow_comments: bool = false
    pub allow_trailing_commas: bool = false
    pub allow_inf_nan: bool = false

    fn flag_bits() -> int {
        var bits: int = 0
        if self.allow_comments { bits = bits | 1 }
        if self.allow_trailing_commas { bits = bits | 2 }
        if self.allow_inf_nan { bits = bits | 4 }
        return bits
    }
}

/// Runtime limits and parser extensions for typed decoding.
pub class DecodeOptions {
    pub parse: Options = new Options()
    pub max_depth: int = 128
}

// The shared owner of one yyjson document. Every Value holds a reference,
// so the native document lives exactly as long as any Value over it, and
// deinit frees it exactly once — on whichever thread drops the last Value.
class Doc {
    handle: int
    writable: bool

    fn init(handle: int, writable: bool) {
        self.handle = handle
        self.writable = writable
    }

    fn deinit() {
        if self.handle != 0 {
            unsafe {
                beans_enc_json_free_doc(self.handle)
            }
        }
    }
}

/// One entry of an object, in document order.
pub struct Entry {
    pub key: string
    pub value: Value
}

/// A JSON value: a view into its document. Copying a Value is cheap and
/// safe; the document is freed when the last Value over it is dropped.
pub class Value {
    owner: Doc
    node: int

    fn init(owner: Doc, node: int) {
        self.owner = owner
        self.node = node
    }

    pub fn kind() -> Kind {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        return match raw {
            0 => Kind.null,
            1 => Kind.boolean,
            2 => Kind.integer,
            3 => Kind.unsigned_integer,
            4 => Kind.floating,
            5 => Kind.text,
            6 => Kind.array,
            _ => Kind.object,
        }
    }

    pub fn is_null() -> bool {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        return raw == 0
    }

    pub fn to_bool() -> Result<bool> {
        var raw: int = -1
        var value: int = 0
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
            value = beans_enc_json_get_bool(self.owner.handle, self.node)
        }
        if raw != 1 { return err("expected a bool", "type") }
        return ok(value != 0)
    }

    /// Signed access. A signed integer always succeeds; an unsigned integer
    /// succeeds when it fits in i64.
    pub fn to_int() -> Result<int> {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        if raw == 2 {
            var value: int = 0
            unsafe {
                value = beans_enc_json_get_sint(self.owner.handle, self.node)
            }
            return ok(value)
        }
        if raw == 3 {
            var bits: int = 0
            unsafe {
                bits = beans_enc_json_get_uint(self.owner.handle, self.node)
            }
            if bits < 0 {
                return err("unsigned integer does not fit in i64", "range")
            }
            return ok(bits)
        }
        return err("expected an integer", "type")
    }

    /// Unsigned access. An unsigned integer always succeeds; a signed
    /// integer succeeds when it is not negative.
    pub fn to_uint() -> Result<u64> {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        if raw == 3 {
            var bits: int = 0
            unsafe {
                bits = beans_enc_json_get_uint(self.owner.handle, self.node)
            }
            return ok(bits as u64)
        }
        if raw == 2 {
            var value: int = 0
            unsafe {
                value = beans_enc_json_get_sint(self.owner.handle, self.node)
            }
            if value < 0 {
                return err("negative integer does not fit in u64", "range")
            }
            return ok(value as u64)
        }
        return err("expected an integer", "type")
    }

    /// Floating access: exactly the parsed double, only for Kind.floating.
    pub fn to_float() -> Result<float> {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        if raw != 4 { return err("expected a float", "type") }
        var bits: int = 0
        unsafe {
            bits = beans_enc_json_get_real_bits(self.owner.handle, self.node)
        }
        return ok(f64_from_bits(bits as u64))
    }

    /// Any numeric kind as f64 — a convenience that accepts integers too,
    /// converting with the usual f64 rounding above 2^53.
    pub fn number() -> Result<float> {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        if raw == 4 {
            var bits: int = 0
            unsafe {
                bits = beans_enc_json_get_real_bits(self.owner.handle, self.node)
            }
            return ok(f64_from_bits(bits as u64))
        }
        if raw == 2 {
            var value: int = 0
            unsafe {
                value = beans_enc_json_get_sint(self.owner.handle, self.node)
            }
            return ok(value as float)
        }
        if raw == 3 {
            var bits: int = 0
            unsafe {
                bits = beans_enc_json_get_uint(self.owner.handle, self.node)
            }
            return ok((bits as u64) as float)
        }
        return err("expected a number", "type")
    }

    pub fn to_string() -> Result<string> {
        var length: int = -1
        unsafe {
            length = beans_enc_json_str_len(self.owner.handle, self.node)
        }
        if length < 0 { return err("expected a string", "type") }
        if length == 0 { return ok("") }

        let direct: string = enc_string_uninit(length)
        let direct_address: int = enc_string_address(direct)
        if direct_address != 0 {
            unsafe {
                let target: RawPtr<u8> =
                    RawPtr.from_address(direct_address as u64)
                beans_enc_json_str_copy(self.owner.handle, self.node, target)
            }
            return ok(direct)
        }

        let target: int = alloc_words((length + 7) / 8)
        unsafe {
            let view: RawPtr<u8> = RawPtr.from_address(target as u64)
            beans_enc_json_str_copy(self.owner.handle, self.node, view)
        }
        let text: string = bytes_from_raw(target, length).to_string()
        free_raw(target)
        return ok(text)
    }

    /// Element or entry count of an array or object.
    pub fn len() -> Result<int> {
        var count: int = -1
        unsafe {
            count = beans_enc_json_container_len(self.owner.handle, self.node)
        }
        if count < 0 { return err("expected an array or object", "type") }
        return ok(count)
    }

    /// Array element at `index`.
    pub fn at(index: int) -> Result<Value> {
        var raw: int = -1
        unsafe {
            raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        if raw != 6 { return err("expected an array", "type") }
        var item: int = 0
        unsafe {
            item = beans_enc_json_arr_get(self.owner.handle, self.node, index)
        }
        if item == 0 {
            return err("array index {index} is out of range", "range")
        }
        return ok(new Value(self.owner, item))
    }

    /// Every array element, in order. One bridge crossing however long the
    /// array is.
    pub fn elements() -> Result<List<Value>> {
        var count: int = -1
        var kind_raw: int = -1
        unsafe {
            kind_raw = beans_enc_json_kind(self.owner.handle, self.node)
            count = beans_enc_json_container_len(self.owner.handle, self.node)
        }
        if kind_raw != 6 { return err("expected an array", "type") }
        var values: List<Value> = []
        if count == 0 { return ok(move values) }
        values.reserve(count)
        let block: int = alloc_words(count)
        unsafe {
            let view: RawPtr<u64> = RawPtr.from_address(block as u64)
            beans_enc_json_arr_items(self.owner.handle, self.node, view)
            for index: int in 0..count {
                values.push(new Value(self.owner,
                                      view.offset(index).read() as int))
            }
        }
        free_raw(block)
        return ok(move values)
    }

    /// First value under `key`, or none when absent (or when this is not an
    /// object). With duplicate keys this is the first entry; `entries()`
    /// reports them all.
    pub fn get(key: string) -> Option<Value> {
        var kind_raw: int = -1
        unsafe {
            kind_raw = beans_enc_json_kind(self.owner.handle, self.node)
        }
        if kind_raw != 7 { return none }
        let borrowed: int = enc_string_address(key)
        let key_bytes: Bytes = if borrowed == 0 {
            Bytes.from(key)
        } else {
            new Bytes(0)
        }
        let key_block: int = if borrowed == 0 {
            raw_from_bytes(key_bytes)
        } else {
            borrowed
        }
        var found: int = 0
        unsafe {
            let key_view: RawPtr<u8> = RawPtr.from_address(key_block as u64)
            let req: RawPtr<u64> = RawPtr.alloc(4)
            req.write(self.owner.handle as u64)
            req.offset(1).write(self.node as u64)
            req.offset(2).write(key.len() as u64)
            beans_enc_json_obj_get(key_view, req)
            found = req.offset(3).read() as int
            req.free()
        }
        if borrowed == 0 { free_raw(key_block) }
        if found == 0 { return none }
        return some(new Value(self.owner, found))
    }

    /// Every object entry in document order, duplicates included.
    pub fn entries() -> Result<List<Entry>> {
        // Native strings expose their final address, so native code only
        // marshals borrowed key pointers. Interpreters keep the portable
        // packed-key stream because their pointer validator cannot import a
        // pointer nested inside an integer result buffer.
        let direct_keys: bool = enc_string_address("x") != 0
        var kind_raw: int = -1
        var count: int = -1
        var words: int = -1
        unsafe {
            kind_raw = beans_enc_json_kind(self.owner.handle, self.node)
            if kind_raw == 7 {
                count = beans_enc_json_container_len(
                    self.owner.handle, self.node)
                if direct_keys {
                    words = count * 3
                } else {
                    words = beans_enc_json_obj_entries_words(
                        self.owner.handle, self.node)
                }
            }
        }
        if words < 0 { return err("expected an object", "type") }
        var found: List<Entry> = []
        if words == 0 { return ok(move found) }
        found.reserve(count)
        let block: int = alloc_words(words)
        unsafe {
            let view: RawPtr<u64> = RawPtr.from_address(block as u64)
            if direct_keys {
                beans_enc_json_obj_entries_refs(
                    self.owner.handle, self.node, view)
            } else {
                beans_enc_json_obj_entries_pack(
                    self.owner.handle, self.node, view)
            }
            var cursor: int = 0
            for cursor < words {
                let key_len: int = view.offset(cursor).read() as int
                let handle: int = if direct_keys {
                    view.offset(cursor + 2).read() as int
                } else {
                    view.offset(cursor + 1).read() as int
                }
                let key_address: int = if direct_keys {
                    view.offset(cursor + 1).read() as int
                } else {
                    view.offset(cursor + 2).address() as int
                }
                cursor += if direct_keys {
                    3
                } else {
                    2 + (key_len + 7) / 8
                }
                let direct: string = enc_string_uninit(key_len)
                let direct_address: int = enc_string_address(direct)
                var key_text: string = ""
                if direct_address != 0 {
                    if key_len != 0 {
                        let source: RawPtr<u8> =
                            RawPtr.from_address(key_address as u64)
                        let target: RawPtr<u8> =
                            RawPtr.from_address(direct_address as u64)
                        target.copy_from(source, key_len)
                    }
                    key_text = direct
                } else {
                    key_text = bytes_from_raw(key_address, key_len).to_string()
                }
                found.push(Entry {
                    key: key_text,
                    value: new Value(self.owner, handle),
                })
            }
        }
        free_raw(block)
        return ok(move found)
    }

    // ---- building ----

    pub static fn null() -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_null(doc.handle)
        }
        return new Value(doc, node)
    }

    pub static fn from_bool(value: bool) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_bool(doc.handle, if value { 1 } else { 0 })
        }
        return new Value(doc, node)
    }

    pub static fn from_int(value: int) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_sint(doc.handle, value)
        }
        return new Value(doc, node)
    }

    pub static fn from_uint(value: u64) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_uint(doc.handle, value as int)
        }
        return new Value(doc, node)
    }

    pub static fn from_float(value: float) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_real(doc.handle, f64_bits(value) as int)
        }
        return new Value(doc, node)
    }

    pub static fn from_string(value: string) -> Value {
        let doc: Doc = fresh_doc()
        let borrowed: int = enc_string_address(value)
        let data: Bytes = if borrowed == 0 {
            Bytes.from(value)
        } else {
            new Bytes(0)
        }
        let block: int = if borrowed == 0 {
            raw_from_bytes(data)
        } else {
            borrowed
        }
        var node: int = 0
        unsafe {
            let view: RawPtr<u8> = RawPtr.from_address(block as u64)
            node = beans_enc_json_mut_str(doc.handle, view, value.len())
        }
        if borrowed == 0 { free_raw(block) }
        return new Value(doc, node)
    }

    /// A new, empty, growable array in its own document.
    pub static fn array() -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_arr(doc.handle)
        }
        return new Value(doc, node)
    }

    /// A new, empty, growable object in its own document.
    pub static fn object() -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_obj(doc.handle)
        }
        return new Value(doc, node)
    }

    /// Appends a deep copy of `item` to this array. Values from `parse` are
    /// read-only and report kind "immutable".
    pub fn push(item: Value) -> Result<bool> {
        if !self.owner.writable {
            return err("values from parse are read-only; build with Value.array()", "immutable")
        }
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(4)
            req.write(self.owner.handle as u64)
            req.offset(1).write(self.node as u64)
            req.offset(2).write(item.owner.handle as u64)
            req.offset(3).write(item.node as u64)
            status = beans_enc_json_arr_push(req)
            req.free()
        }
        if status == 3 { return err("expected an array", "type") }
        if status != 0 { return err("cannot push into this value", "invalid") }
        return ok(true)
    }

    /// Appends `key` with a deep copy of `item` to this object. Duplicate
    /// keys are kept in order, matching what parsed documents report.
    pub fn add(key: string, item: Value) -> Result<bool> {
        if !self.owner.writable {
            return err("values from parse are read-only; build with Value.object()", "immutable")
        }
        let borrowed: int = enc_string_address(key)
        let key_bytes: Bytes = if borrowed == 0 {
            Bytes.from(key)
        } else {
            new Bytes(0)
        }
        let key_block: int = if borrowed == 0 {
            raw_from_bytes(key_bytes)
        } else {
            borrowed
        }
        var status: int = 0
        unsafe {
            let key_view: RawPtr<u8> = RawPtr.from_address(key_block as u64)
            let req: RawPtr<u64> = RawPtr.alloc(5)
            req.write(self.owner.handle as u64)
            req.offset(1).write(self.node as u64)
            req.offset(2).write(key.len() as u64)
            req.offset(3).write(item.owner.handle as u64)
            req.offset(4).write(item.node as u64)
            status = beans_enc_json_obj_add(key_view, req)
            req.free()
        }
        if borrowed == 0 { free_raw(key_block) }
        if status == 3 { return err("expected an object", "type") }
        if status != 0 { return err("cannot add into this value", "invalid") }
        return ok(true)
    }
}

fn fresh_doc() -> Doc {
    var handle: int = 0
    unsafe {
        handle = beans_enc_json_mut_new()
    }
    return new Doc(handle, true)
}

fn parse_phrase(code: int) -> string {
    return match code {
        2 => "unexpected end of input",
        3 => "out of memory",
        4 => "unexpected content after the document",
        5 => "invalid number",
        6 => "invalid string",
        7 => "invalid literal",
        8 => "invalid comment",
        9 => "unbalanced structure",
        10 => "empty input",
        _ => "unexpected character",
    }
}

fn parse_kind(code: int) -> string {
    return match code {
        2 => "eof",
        10 => "eof",
        3 => "memory",
        _ => "invalid",
    }
}

fn parse_address(address: int, length: int, options: Options) -> Result<Value> {
    var status: int = 0
    var doc_handle: int = 0
    var root: int = 0
    var code: int = 0
    var position: int = 0
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(address as u64)
        let req: RawPtr<u64> = RawPtr.alloc(6)
        req.write(length as u64)
        req.offset(1).write(options.flag_bits() as u64)
        status = beans_enc_json_parse(view, req)
        doc_handle = req.offset(2).read() as int
        root = req.offset(3).read() as int
        code = req.offset(4).read() as int
        position = req.offset(5).read() as int
        req.free()
    }
    if status != 0 {
        return err("invalid JSON at byte {position}: {parse_phrase(code)}",
                   parse_kind(code))
    }
    return ok(new Value(new Doc(doc_handle, false), root))
}

fn parse_data(data: Bytes, options: Options) -> Result<Value> {
    let borrowed: int = enc_bytes_address(data)
    if borrowed != 0 {
        return parse_address(borrowed, data.len(), options)
    }
    let block: int = raw_from_bytes(data)
    let result: Result<Value> = parse_address(block, data.len(), options)
    free_raw(block)
    return result
}

fn parse_text(text: string, options: Options) -> Result<Value> {
    let borrowed: int = enc_string_address(text)
    if borrowed != 0 {
        return parse_address(borrowed, text.len(), options)
    }
    return parse_data(Bytes.from(text), options)
}

/// Parses strict RFC 8259 JSON. The whole input must be one document;
/// trailing content is an error with its byte position.
pub fn parse(text: string) -> Result<Value> {
    return parse_text(text, new Options())
}

/// Like `parse`, for binary buffers. The bytes must be UTF-8 JSON.
pub fn parse_bytes(data: Bytes) -> Result<Value> {
    return parse_data(data, new Options())
}

/// Parse with explicit extension opt-ins.
pub fn parse_with_options(text: string, options: Options) -> Result<Value> {
    return parse_text(text, options)
}

pub fn parse_bytes_with_options(data: Bytes, options: Options) -> Result<Value> {
    return parse_data(data, options)
}

/// Decodes one JSON document into the type inferred from the result.
/// The compiler replaces this body after it validates the concrete type.
pub fn decode<T>(text: string) -> Result<T> {
    return err("typed JSON decoding was not lowered", "unsupported")
}

/// Like `decode`, for a borrowed UTF-8 byte buffer.
pub fn decode_bytes<T>(data: Bytes) -> Result<T> {
    return err("typed JSON decoding was not lowered", "unsupported")
}

/// The zero-copy input form. The decoder may add yyjson padding and mutate
/// the consumed buffer while the temporary parse tree is alive.
pub fn decode_bytes_in_place<T>(move data: Bytes) -> Result<T> {
    return err("typed JSON decoding was not lowered", "unsupported")
}

/// Typed decoding with explicit parser extensions and a depth limit.
pub fn decode_with_options<T>(text: string,
                              options: DecodeOptions) -> Result<T> {
    return err("typed JSON decoding was not lowered", "unsupported")
}

/// Encodes a struct, or a List of structs, as compact RFC 8259 JSON.
/// The compiler validates the concrete type and replaces this body.
pub fn encode<T>(value: T) -> Result<string> {
    return err("typed JSON encoding was not lowered", "unsupported")
}

/// Encodes a struct, or a List of structs, as pretty JSON. The indent must
/// be either two or four spaces.
pub fn encode_pretty<T>(value: T, indent: string) -> Result<string> {
    return err("typed JSON encoding was not lowered", "unsupported")
}

fn write_value(value: Value, mode: int) -> Result<string> {
    var status: int = 0
    var buffer: int = 0
    var length: int = 0
    var code: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(6)
        req.write(value.owner.handle as u64)
        req.offset(1).write(value.node as u64)
        req.offset(2).write(mode as u64)
        status = beans_enc_json_write(req)
        buffer = req.offset(3).read() as int
        length = req.offset(4).read() as int
        code = req.offset(5).read() as int
        req.free()
    }
    if status != 0 {
        if code == 2 {
            return err("cannot write NaN or infinity as JSON", "invalid")
        }
        if code == 3 {
            return err("out of memory while writing JSON", "memory")
        }
        return err("cannot write this value as JSON", "invalid")
    }
    if length == 0 { return ok("") }

    let direct: string = enc_string_uninit(length)
    let direct_address: int = enc_string_address(direct)
    if direct_address != 0 {
        unsafe {
            let target: RawPtr<u8> =
                RawPtr.from_address(direct_address as u64)
            beans_enc_json_take_buf(buffer, length, target)
        }
        return ok(direct)
    }

    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_json_take_buf(buffer, length, view)
    }
    let text: string = bytes_from_raw(block, length).to_string()
    free_raw(block)
    return ok(text)
}

/// Compact RFC 8259 output.
pub fn stringify(value: Value) -> Result<string> {
    return write_value(value, 0)
}

/// Pretty output. yyjson's writer offers two indents: pass "  " for two
/// spaces or "    " for four; anything else is refused as kind "invalid".
pub fn stringify_pretty(value: Value, indent: string) -> Result<string> {
    if indent == "  " { return write_value(value, 2) }
    if indent == "    " { return write_value(value, 1) }
    return err("pretty indent must be \"  \" or \"    \"", "invalid")
}
