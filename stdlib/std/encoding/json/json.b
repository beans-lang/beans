// JSON over the vendored yyjson bridge (runtime/encoding).
//
// This is a native Value/DOM API: parse gives a Value view over yyjson's
// immutable document, and child Values keep that document alive through a
// shared owner object — nothing is eagerly copied into Beans collections.
// Typed struct decoding is a possible later compiler feature, not part of
// this package.
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

// ---- raw-buffer marshalling (word-at-a-time, no per-byte Beans calls) ----

fn raw_from_bytes(data: Bytes) -> int {
    let count: int = data.len()
    let words: int = (count + 7) / 8
    var address: int = 0
    unsafe {
        let block: RawPtr<u64> = RawPtr.alloc(if words == 0 { 1 } else { words })
        let whole: int = count / 8
        for index: int in 0..whole {
            block.offset(index).write(data.get_u64(index * 8) as u64)
        }
        let tail: RawPtr<u8> = RawPtr.from_address(block.address())
        for index: int in (whole * 8)..count {
            tail.offset(index).write(data.get(index) as u8)
        }
        address = block.address() as int
    }
    return address
}

fn bytes_from_raw(address: int, count: int) -> Bytes {
    var out: Bytes = new Bytes(count)
    unsafe {
        let block: RawPtr<u64> = RawPtr.from_address(address as u64)
        let whole: int = count / 8
        for index: int in 0..whole {
            out.put_u64(index * 8, block.offset(index).read() as int)
        }
        let tail: RawPtr<u8> = RawPtr.from_address(address as u64)
        for index: int in (whole * 8)..count {
            out.set(index, tail.offset(index).read() as int)
        }
    }
    return out
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

fn f64_from_bits(bits: u64) -> float {
    var value: float = 0.0
    unsafe {
        let slot: RawPtr<u64> = RawPtr.alloc(1)
        slot.write(bits)
        let view: RawPtr<f64> = RawPtr.from_address(slot.address())
        value = view.read()
        slot.free()
    }
    return value
}

fn f64_bits(value: float) -> u64 {
    var bits: u64 = 0
    unsafe {
        let slot: RawPtr<f64> = RawPtr.alloc(1)
        slot.write(value)
        let view: RawPtr<u64> = RawPtr.from_address(slot.address())
        bits = view.read()
        slot.free()
    }
    return bits
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
        let target: int = alloc_words((length + 7) / 8)
        unsafe {
            let view: RawPtr<u8> = RawPtr.from_address(target as u64)
            beans_enc_json_str_copy(self.owner.handle, self.node, view)
        }
        let text: string = bytes_from_raw(target, length).to_string_full()
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
    pub fn items() -> Result<List<Value>> {
        var count: int = -1
        var kind_raw: int = -1
        unsafe {
            kind_raw = beans_enc_json_kind(self.owner.handle, self.node)
            count = beans_enc_json_container_len(self.owner.handle, self.node)
        }
        if kind_raw != 6 { return err("expected an array", "type") }
        var values: List<Value> = []
        if count == 0 { return ok(move values) }
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
        let key_bytes: Bytes = Bytes.from(key)
        let key_block: int = raw_from_bytes(key_bytes)
        var found: int = 0
        unsafe {
            let key_view: RawPtr<u8> = RawPtr.from_address(key_block as u64)
            let req: RawPtr<u64> = RawPtr.alloc(4)
            req.write(self.owner.handle as u64)
            req.offset(1).write(self.node as u64)
            req.offset(2).write(key_bytes.len() as u64)
            beans_enc_json_obj_get(key_view, req)
            found = req.offset(3).read() as int
            req.free()
        }
        free_raw(key_block)
        if found == 0 { return none }
        return some(new Value(self.owner, found))
    }

    /// Every object entry in document order, duplicates included.
    pub fn entries() -> Result<List<Entry>> {
        var words: int = -1
        unsafe {
            words = beans_enc_json_obj_entries_words(self.owner.handle, self.node)
        }
        if words < 0 { return err("expected an object", "type") }
        var found: List<Entry> = []
        if words == 0 { return ok(move found) }
        let block: int = alloc_words(words)
        unsafe {
            let view: RawPtr<u64> = RawPtr.from_address(block as u64)
            beans_enc_json_obj_entries_pack(self.owner.handle, self.node, view)
            var cursor: int = 0
            for cursor < words {
                let key_len: int = view.offset(cursor).read() as int
                let handle: int = view.offset(cursor + 1).read() as int
                cursor += 2
                let key_words: int = (key_len + 7) / 8
                var key_data: Bytes = new Bytes(key_len)
                let key_whole: int = key_len / 8
                for index: int in 0..key_whole {
                    key_data.put_u64(index * 8,
                                     view.offset(cursor + index).read() as int)
                }
                if key_whole * 8 < key_len {
                    let last: u64 = view.offset(cursor + key_whole).read()
                    for index: int in (key_whole * 8)..key_len {
                        let shift: int = (index - key_whole * 8) * 8
                        key_data.set(index,
                                     ((last >> (shift as u64)) & 0xff) as int)
                    }
                }
                cursor += key_words
                found.push(Entry {
                    key: key_data.to_string_full(),
                    value: new Value(self.owner, handle),
                })
            }
        }
        free_raw(block)
        return ok(move found)
    }

    // ---- building ----

    pub static fn of_null() -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_null(doc.handle)
        }
        return new Value(doc, node)
    }

    pub static fn of_bool(value: bool) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_bool(doc.handle, if value { 1 } else { 0 })
        }
        return new Value(doc, node)
    }

    pub static fn of_int(value: int) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_sint(doc.handle, value)
        }
        return new Value(doc, node)
    }

    pub static fn of_uint(value: u64) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_uint(doc.handle, value as int)
        }
        return new Value(doc, node)
    }

    pub static fn of_float(value: float) -> Value {
        let doc: Doc = fresh_doc()
        var node: int = 0
        unsafe {
            node = beans_enc_json_mut_real(doc.handle, f64_bits(value) as int)
        }
        return new Value(doc, node)
    }

    pub static fn of_string(value: string) -> Value {
        let doc: Doc = fresh_doc()
        let data: Bytes = Bytes.from(value)
        let block: int = raw_from_bytes(data)
        var node: int = 0
        unsafe {
            let view: RawPtr<u8> = RawPtr.from_address(block as u64)
            node = beans_enc_json_mut_str(doc.handle, view, data.len())
        }
        free_raw(block)
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
        let key_bytes: Bytes = Bytes.from(key)
        let key_block: int = raw_from_bytes(key_bytes)
        var status: int = 0
        unsafe {
            let key_view: RawPtr<u8> = RawPtr.from_address(key_block as u64)
            let req: RawPtr<u64> = RawPtr.alloc(5)
            req.write(self.owner.handle as u64)
            req.offset(1).write(self.node as u64)
            req.offset(2).write(key_bytes.len() as u64)
            req.offset(3).write(item.owner.handle as u64)
            req.offset(4).write(item.node as u64)
            status = beans_enc_json_obj_add(key_view, req)
            req.free()
        }
        free_raw(key_block)
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

fn parse_data(data: Bytes, options: Options) -> Result<Value> {
    let block: int = raw_from_bytes(data)
    var status: int = 0
    var doc_handle: int = 0
    var root: int = 0
    var code: int = 0
    var position: int = 0
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        let req: RawPtr<u64> = RawPtr.alloc(6)
        req.write(data.len() as u64)
        req.offset(1).write(options.flag_bits() as u64)
        status = beans_enc_json_parse(view, req)
        doc_handle = req.offset(2).read() as int
        root = req.offset(3).read() as int
        code = req.offset(4).read() as int
        position = req.offset(5).read() as int
        req.free()
    }
    free_raw(block)
    if status != 0 {
        return err("invalid JSON at byte {position}: {parse_phrase(code)}",
                   parse_kind(code))
    }
    return ok(new Value(new Doc(doc_handle, false), root))
}

/// Parses strict RFC 8259 JSON. The whole input must be one document;
/// trailing content is an error with its byte position.
pub fn parse(text: string) -> Result<Value> {
    return parse_data(Bytes.from(text), new Options())
}

/// Like `parse`, for binary buffers. The bytes must be UTF-8 JSON.
pub fn parse_bytes(data: Bytes) -> Result<Value> {
    return parse_data(data, new Options())
}

/// Parse with explicit extension opt-ins.
pub fn parse_with(text: string, options: Options) -> Result<Value> {
    return parse_data(Bytes.from(text), options)
}

pub fn parse_bytes_with(data: Bytes, options: Options) -> Result<Value> {
    return parse_data(data, options)
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
    let block: int = alloc_words((length + 7) / 8)
    unsafe {
        let view: RawPtr<u8> = RawPtr.from_address(block as u64)
        beans_enc_json_take_buf(buffer, length, view)
    }
    let text: string = bytes_from_raw(block, length).to_string_full()
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
