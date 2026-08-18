// DEFLATE compression — zlib-ng behind a bomb-proof API.
//
// Three decisions shape the package:
//
//   **Decompression limits are mandatory.** Every inflate call names the
//   most bytes it is prepared to receive, and crossing that bound is an
//   `err` of kind `limit` — never an allocation racing a hostile ratio. A
//   96-byte bomb that claims four gigabytes gets 96 honest bytes of effort.
//
//   **Three formats, spelled out.** `zlib` (RFC 1950), `raw` (RFC 1951),
//   and `gzip` (RFC 1952) are separate names, not window-bits folklore.
//   gzip decoding accepts multi-member files, the way `gzip -d` reads
//   concatenated archives.
//
//   **One-shot for buffers, streams for everything else.** The module
//   functions take and return whole `Bytes`; `Deflater` and `Inflater`
//   are move-only handles for data that arrives in pieces, with the same
//   limit discipline enforced across a whole Inflater's lifetime.
package compress

// The zlib bridge (runtime/net/beans_net_zlib.c): zlib-ng compat mode,
// generic lane, statuses 100 corrupt / 101 cap / 102 truncated.
extern "C" fn beans_zlib_bound(len: int, format: int) -> int
extern "C" fn beans_zlib_deflate(src: RawPtr<u8>, dst: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_zlib_inflate(src: RawPtr<u8>, dst: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_zlib_stream_new(req: RawPtr<u64>) -> int
extern "C" fn beans_zlib_stream_run(src: RawPtr<u8>, dst: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_zlib_stream_free(handle: int) -> int

/// The wire format of a DEFLATE stream.
pub enum Format {
    zlib
    raw
    gzip
}

fn format_code(format: Format) -> int {
    return match format { zlib => 0, raw => 1, gzip => 2 }
}

fn compress_one_shot(data: Bytes, level: int, format: Format) -> Result<Bytes> {
    if level < 0 || level > 9 {
        return err("deflate: level must be between 0 and 9", "invalid")
    }
    var bound: int = 0
    unsafe {
        bound = beans_zlib_bound(data.len(), format_code(format))
    }
    if bound < 0 { return err("deflate: input too large", "invalid") }
    let out: Bytes = new Bytes(bound)
    var status: int = 0
    var written: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(5)
        req.write(data.len() as u64)
        req.offset(1).write(bound as u64)
        req.offset(2).write(level as u64)
        req.offset(3).write(format_code(format) as u64)
        status = beans_zlib_deflate(data.as_ptr(), out.as_ptr(), req)
        written = req.offset(4).read() as int
        req.free()
    }
    if status == 3 { return err("deflate: out of memory", "memory") }
    if status != 0 { return err("deflate failed (status {status})", "io") }
    out.resize(written)
    return ok(out)
}

fn decompress_one_shot(data: Bytes, limit: int, format: Format) -> Result<Bytes> {
    if limit <= 0 {
        return err("inflate: a positive output limit is required — the limit is what makes a decompression bomb an error instead of an allocation", "invalid")
    }
    let out: Bytes = new Bytes(limit)
    var status: int = 0
    var written: int = 0
    unsafe {
        let req: RawPtr<u64> = RawPtr.alloc(4)
        req.write(data.len() as u64)
        req.offset(1).write(limit as u64)
        req.offset(2).write(format_code(format) as u64)
        status = beans_zlib_inflate(data.as_ptr(), out.as_ptr(), req)
        written = req.offset(3).read() as int
        req.free()
    }
    if status == 0 {
        out.resize(written)
        return ok(out)
    }
    if status == 101 {
        return err("inflate: the output exceeds the declared limit of {limit} bytes", "limit")
    }
    if status == 102 {
        return err("inflate: the stream ends before its data does", "eof")
    }
    if status == 3 { return err("inflate: out of memory", "memory") }
    return err("inflate: the stream is corrupt", "invalid")
}

/// Compresses into the zlib format (RFC 1950). Level 0..9; 6 balances.
pub fn deflate(data: Bytes, level: int = 6) -> Result<Bytes> {
    return compress_one_shot(data, level, Format.zlib)
}

/// Decompresses a zlib stream, refusing to produce more than `limit` bytes.
pub fn inflate(data: Bytes, limit: int) -> Result<Bytes> {
    return decompress_one_shot(data, limit, Format.zlib)
}

/// Compresses into a single-member gzip file (RFC 1952).
pub fn gzip_compress(data: Bytes, level: int = 6) -> Result<Bytes> {
    return compress_one_shot(data, level, Format.gzip)
}

/// Decompresses gzip data — all members of a multi-member file — within
/// `limit` bytes of output.
pub fn gzip_decompress(data: Bytes, limit: int) -> Result<Bytes> {
    return decompress_one_shot(data, limit, Format.gzip)
}

/// Compresses to a raw DEFLATE stream (RFC 1951) — no header, no checksum.
/// The framing protocol above owns integrity; this is what WebSocket
/// permessage-deflate and ZIP entries speak.
pub fn deflate_raw(data: Bytes, level: int = 6) -> Result<Bytes> {
    return compress_one_shot(data, level, Format.raw)
}

/// Decompresses a raw DEFLATE stream within `limit` bytes of output.
pub fn inflate_raw(data: Bytes, limit: int) -> Result<Bytes> {
    return decompress_one_shot(data, limit, Format.raw)
}

// ---- streaming ------------------------------------------------------------------

// Shared driving loop: pushes `data` through the bridge stream, growing
// the output in bounded steps. `finishing` runs the end-of-stream drain.
// `state` reports back through its bytes: [0] stream ended, [1] input
// left unconsumed after the end.
fn drive_stream(handle: int,
                data: Bytes,
                finishing: bool,
                total_limit: int,
                produced_before: int,
                state: Bytes) -> Result<Bytes> {
    var out: Bytes = new Bytes(0)
    var consumed_total: int = 0
    var rounds: int = 0
    for rounds < 100000 {
        rounds += 1
        var chunk: int = 65536
        if total_limit > 0 {
            let remaining: int = total_limit - produced_before - out.len()
            if remaining < 0 {
                return err("inflate: the output exceeds the declared limit of {total_limit} bytes", "limit")
            }
            if remaining < chunk { chunk = remaining }
        }
        let start: int = out.len()
        out.resize(start + chunk)
        var status: int = 0
        var consumed: int = 0
        var produced: int = 0
        var done: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(7)
            req.write(handle as u64)
            req.offset(1).write((data.len() - consumed_total) as u64)
            req.offset(2).write(chunk as u64)
            req.offset(3).write(if finishing { 2 as u64 } else { 0 as u64 })
            let src: RawPtr<u8> = if data.len() == consumed_total {
                RawPtr.null()
            } else {
                data.as_ptr().offset(consumed_total)
            }
            let dst: RawPtr<u8> = if chunk == 0 {
                RawPtr.null()
            } else {
                out.as_ptr().offset(start)
            }
            status = beans_zlib_stream_run(src, dst, req)
            consumed = req.offset(4).read() as int
            produced = req.offset(5).read() as int
            done = req.offset(6).read() as int
            req.free()
        }
        out.resize(start + produced)
        if status == 100 { return err("inflate: the stream is corrupt", "invalid") }
        if status == 5 { return err("the stream is closed", "closed") }
        if status != 0 { return err("compression stream failed (status {status})", "io") }
        consumed_total += consumed
        if total_limit > 0 && produced_before + out.len() > total_limit {
            return err("inflate: the output exceeds the declared limit of {total_limit} bytes", "limit")
        }
        if done == 1 {
            let ignored: Bytes = state.set(0, 1)
            if consumed_total < data.len() {
                let also: Bytes = state.set(1, 1)
            }
            return ok(out)
        }
        // With no caller-approved room left, one zero-capacity step lets
        // zlib consume a trailer and announce an exact-boundary end. If it
        // still needs output, the next byte would cross the limit.
        if total_limit > 0 && chunk == 0 {
            return err("inflate: the output exceeds the declared limit of {total_limit} bytes", "limit")
        }
        if consumed_total >= data.len() && produced < chunk {
            // Input drained and the last round had output room to spare:
            // the stream has said all it can for now.
            if !finishing { return ok(out) }
            // Finishing: keep draining until `done` — unless nothing came
            // out at all, which for deflate means "call again", and for a
            // truncated inflate would spin forever, so stop there.
            if produced == 0 && consumed == 0 { return ok(out) }
        }
    }
    return err("compression stream made no progress", "io")
}

/// A streaming compressor. Move-only; `finish` ends the stream and the
/// handle refuses work afterwards.
pub unique class Deflater {
    handle: int = 0
    live: bool = true

    fn init(handle: int) {
        self.handle = handle
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_zlib_stream_free(self.handle)
            }
        }
    }

    /// A compressor for the given format. Level 0..9; 6 balances.
    pub static fn open(format: Format, level: int = 6) -> Result<Deflater> {
        if level < 0 || level > 9 {
            return err("deflater: level must be between 0 and 9", "invalid")
        }
        var handle: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(0 as u64)
            req.offset(1).write(format_code(format) as u64)
            req.offset(2).write(level as u64)
            handle = beans_zlib_stream_new(req)
            req.free()
        }
        if handle == 0 { return err("deflater: out of memory", "memory") }
        return ok(new Deflater(handle))
    }

    /// Compresses one piece, returning whatever output is ready — possibly
    /// nothing, because DEFLATE buffers freely until `finish`.
    pub fn push(data: Bytes) -> Result<Bytes> {
        if !self.live { return err("push: the deflater is finished", "closed") }
        return drive_stream(self.handle, data, false, 0, 0, new Bytes(2))
    }

    /// Ends the stream and returns the remaining output whole.
    pub fn finish() -> Result<Bytes> {
        if !self.live { return err("finish: the deflater is finished", "closed") }
        self.live = false
        return drive_stream(self.handle, new Bytes(0), true, 0, 0, new Bytes(2))
    }
}

/// A streaming decompressor with one limit across its whole life — the
/// bound holds however many pieces the data arrives in.
pub unique class Inflater {
    handle: int = 0
    live: bool = true
    limit: int = 0
    produced: int = 0
    ended: bool = false

    fn init(handle: int, limit: int) {
        self.handle = handle
        self.limit = limit
    }

    fn deinit() {
        if self.handle != 0 {
            var ignored: int = 0
            unsafe {
                ignored = beans_zlib_stream_free(self.handle)
            }
        }
    }

    /// A decompressor for the given format, bounded to `limit` total
    /// output bytes.
    pub static fn open(format: Format, limit: int) -> Result<Inflater> {
        if limit <= 0 {
            return err("inflater: a positive output limit is required", "invalid")
        }
        var handle: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(3)
            req.write(1 as u64)
            req.offset(1).write(format_code(format) as u64)
            req.offset(2).write(0 as u64)
            handle = beans_zlib_stream_new(req)
            req.free()
        }
        if handle == 0 { return err("inflater: out of memory", "memory") }
        return ok(new Inflater(handle, limit))
    }

    /// Decompresses one arriving piece. Kind `limit` the moment the total
    /// output would cross the bound; kind `invalid` for corruption or for
    /// bytes arriving after the stream already ended.
    pub fn push(data: Bytes) -> Result<Bytes> {
        if !self.live { return err("push: the inflater is closed", "closed") }
        if self.ended && data.len() > 0 {
            return err("push: data after the end of the stream", "invalid")
        }
        let state: Bytes = new Bytes(2)
        let out: Bytes = drive_stream(
            self.handle, data, false, self.limit, self.produced, state)?
        self.produced += out.len()
        if state.get(0) == 1 { self.ended = true }
        if state.get(1) == 1 {
            return err("push: data after the end of the stream", "invalid")
        }
        return ok(out)
    }

    /// True once the underlying stream announced its end — after this,
    /// the bytes are complete and further input is an error.
    pub fn finished() -> bool {
        return self.ended
    }

    /// Declares end-of-input. An incomplete stream is kind `eof`.
    pub fn finish() -> Result<Bytes> {
        if !self.live { return err("finish: the inflater is closed", "closed") }
        self.live = false
        let state: Bytes = new Bytes(2)
        let out: Bytes = drive_stream(
            self.handle, new Bytes(0), true, self.limit, self.produced, state)?
        self.produced += out.len()
        if state.get(0) == 1 { self.ended = true }
        if !self.ended {
            return err("finish: the stream ends before its data does", "eof")
        }
        return ok(out)
    }
}
