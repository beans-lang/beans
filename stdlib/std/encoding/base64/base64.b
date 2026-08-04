// Base64 over the vendored simdutf bridge (runtime/encoding).
//
// Four RFC 4648 encodings, each an `Encoding` value with methods; the
// module-level `encode`/`decode`/`decode_forgiving` are the standard padded
// encoding with strict decoding — the common case in one call.
//
// Decode modes:
//   - strict (`decode`): RFC 4648. Padding must match the encoding exactly,
//     the trailing padding bits of a final partial group must be zero, and
//     any byte outside the alphabet — ASCII whitespace included — is an
//     error with its byte position.
//   - forgiving (`decode_forgiving`): the WHATWG forgiving-base64 shape.
//     ASCII whitespace is skipped, a partial final group is accepted with
//     or without padding, and non-zero trailing padding bits are ignored.
//     Bytes outside the alphabet are still errors.
//
// The transform itself runs in simdutf (SIMD where the target has it, its
// scalar fallback elsewhere); this file only moves bytes across the bridge
// and shapes errors. Output buffers are allocated at the exact encoded size
// and simdutf writes into them directly.

extern "C" fn beans_enc_b64_encoded_len(encoding: int, len: int) -> int
extern "C" fn beans_enc_b64_max_decoded_len(len: int) -> int
extern "C" fn beans_enc_b64_encode(source: RawPtr<u8>, target: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_enc_b64_decode(source: RawPtr<u8>, target: RawPtr<u8>, req: RawPtr<u64>) -> int

// ---- buffer marshalling ----
//
// Payloads cross the bridge as (pointer, length) into raw memory allocated
// as 64-bit words, so the copies below run word-at-a-time through the native
// Bytes accessors — never a Beans call per payload byte inside the codec.

// The two bulk-copy primitives every marshalling helper builds on. The
// native backend lowers calls to these exact functions to a bounds-checked
// @llvm.memcpy over the Bytes buffer; these bodies are the interpreters'
// definition, and the two agree on every outcome, including the panic.
// `address` must be word-aligned with `count` accessible bytes — every
// caller allocates through alloc_words.
fn enc_copy_to_raw(data: Bytes, from: int, address: int, count: int) {
    if from < 0 || count < 0 || from + count > data.len() {
        panic("encoding raw copy out of range")
    }
    unsafe {
        let tail: RawPtr<u8> = RawPtr.from_address(address as u64)
        var index: int = 0
        for index + 8 <= count {
            let word: RawPtr<u64> = RawPtr.from_address((address + index) as u64)
            word.write(data.get_u64(from + index) as u64)
            index += 8
        }
        for index < count {
            tail.offset(index).write(data.get(from + index) as u8)
            index += 1
        }
    }
}

fn enc_copy_from_raw(address: int, target: Bytes, at: int, count: int) {
    if at < 0 || count < 0 || at + count > target.len() {
        panic("encoding raw copy out of range")
    }
    unsafe {
        let tail: RawPtr<u8> = RawPtr.from_address(address as u64)
        var index: int = 0
        for index + 8 <= count {
            let word: RawPtr<u64> = RawPtr.from_address((address + index) as u64)
            target.put_u64(at + index, word.read() as int)
            index += 8
        }
        for index < count {
            target.set(at + index, tail.offset(index).read() as int)
            index += 1
        }
    }
}

fn raw_from_bytes(data: Bytes) -> int {
    let count: int = data.len()
    let address: int = alloc_words((count + 7) / 8)
    enc_copy_to_raw(data, 0, address, count)
    return address
}

fn bytes_from_raw(address: int, count: int) -> Bytes {
    var out: Bytes = new Bytes(count)
    enc_copy_from_raw(address, out, 0, count)
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

/// The four RFC 4648 alphabets and padding modes.
pub enum Encoding {
    standard
    standard_no_pad
    url_safe
    url_safe_no_pad

    fn id() -> int {
        return match self {
            standard => 0,
            standard_no_pad => 1,
            url_safe => 2,
            url_safe_no_pad => 3,
        }
    }

    /// Encodes `data`. The output length is exact for this encoding, and
    /// simdutf writes the text straight into the output buffer.
    pub fn encode(data: Bytes) -> string {
        let count: int = data.len()
        if count == 0 { return "" }
        let source: int = raw_from_bytes(data)
        var wrote: int = 0
        var target: int = 0
        unsafe {
            let need: int = beans_enc_b64_encoded_len(self.id(), count)
            target = alloc_words((need + 7) / 8)
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(count as u64)
            req.offset(1).write(need as u64)
            req.offset(2).write(self.id() as u64)
            let source_view: RawPtr<u8> = RawPtr.from_address(source as u64)
            let target_view: RawPtr<u8> = RawPtr.from_address(target as u64)
            wrote = beans_enc_b64_encode(source_view, target_view, req)
            req.free()
        }
        var text: string = ""
        if wrote >= 0 {
            text = bytes_from_raw(target, wrote).to_string_full()
        }
        free_raw(source)
        free_raw(target)
        return text
    }

    /// Strict RFC 4648 decoding. See the module comment for the contract.
    pub fn decode(text: string) -> Result<Bytes> {
        return self.decode_mode(text, 0)
    }

    /// Forgiving decoding: whitespace skipped, partial final group allowed,
    /// non-zero trailing padding bits ignored. Named so the relaxation is
    /// visible at the call site.
    pub fn decode_forgiving(text: string) -> Result<Bytes> {
        return self.decode_mode(text, 1)
    }

    fn decode_mode(text: string, mode: int) -> Result<Bytes> {
        let count: int = text.len()
        if count == 0 { return ok(new Bytes(0)) }
        let source: int = raw_from_bytes(Bytes.from(text))
        var status: int = 0
        var wrote: int = 0
        var position: int = 0
        var target: int = 0
        unsafe {
            let cap: int = beans_enc_b64_max_decoded_len(count)
            target = alloc_words((cap + 7) / 8)
            let req: RawPtr<u64> = RawPtr.alloc(6)
            req.write(count as u64)
            req.offset(1).write(cap as u64)
            req.offset(2).write(self.id() as u64)
            req.offset(3).write(mode as u64)
            let source_view: RawPtr<u8> = RawPtr.from_address(source as u64)
            let target_view: RawPtr<u8> = RawPtr.from_address(target as u64)
            status = beans_enc_b64_decode(source_view, target_view, req)
            wrote = req.offset(4).read() as int
            position = req.offset(5).read() as int
            req.free()
        }
        var payload: Bytes = new Bytes(0)
        if status == 0 {
            payload = bytes_from_raw(target, wrote)
        }
        free_raw(source)
        free_raw(target)
        if status == 0 { return ok(move payload) }
        if status == 1 {
            return err("invalid base64 character at byte {position}", "invalid")
        }
        if status == 2 {
            return err("base64 input length leaves a lone trailing character at byte {position}", "length")
        }
        if status == 3 {
            return err("base64 padding does not match this encoding at byte {position}", "padding")
        }
        if status == 4 {
            return err("base64 trailing padding bits are not zero at byte {position}", "bits")
        }
        if status == 5 {
            return err("whitespace at byte {position} is not allowed in strict base64", "whitespace")
        }
        return err("base64 decode failed at byte {position}", "invalid")
    }
}

/// Standard padded encoding — `Encoding.standard.encode` in one call.
pub fn encode(data: Bytes) -> string {
    return Encoding.standard.encode(data)
}

/// Strict decode of the standard padded encoding.
pub fn decode(text: string) -> Result<Bytes> {
    return Encoding.standard.decode(text)
}

/// Forgiving decode of the standard padded encoding.
pub fn decode_forgiving(text: string) -> Result<Bytes> {
    return Encoding.standard.decode_forgiving(text)
}
