// Cryptographic hashing — from the platform, minimal by design.
//
// SHA-1 and SHA-256, taken from the OS crypto library (CommonCrypto on
// macOS, CNG on Windows, libcrypto at runtime on Linux/BSD), behind a small
// streaming digest. HMAC is built here on top of the primitive with the
// standard ipad/opad construction, so nothing extra rides in the C bridge.
//
// This is not a general crypto toolkit. It exists because a WebSocket
// handshake needs SHA-1 and the protocols above need SHA-256; anything more
// belongs in a library that makes cryptography its whole job.
package crypto

// The hash bridge (runtime/net/beans_net_hash.c). algorithm 0 = SHA-1,
// 1 = SHA-256; the platform provides the implementation.
extern "C" fn beans_hash_new(algorithm: int) -> int
extern "C" fn beans_hash_update(handle: int, data: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_hash_finish(handle: int, out: RawPtr<u8>, req: RawPtr<u64>) -> int
extern "C" fn beans_hash_free(handle: int) -> int
extern "C" fn beans_hash_available() -> int

/// Which digest to compute.
pub enum Algorithm {
    sha1
    sha256
}

fn algorithm_code(algorithm: Algorithm) -> int {
    return match algorithm { sha1 => 0, sha256 => 1 }
}

fn digest_size(algorithm: Algorithm) -> int {
    return match algorithm { sha1 => 20, sha256 => 32 }
}

fn block_size(algorithm: Algorithm) -> int {
    // Both SHA-1 and SHA-256 use a 64-byte block, which is what HMAC's
    // key padding is measured against.
    return 64
}

/// True when the platform offers a hash provider. Always true on macOS and
/// Windows; on Linux it depends on a libcrypto being present.
pub fn available() -> bool {
    var yes: int = 0
    unsafe {
        yes = beans_hash_available()
    }
    return yes == 1
}

/// A streaming digest. Feed with `update`, read once with `finish`; the
/// handle is spent afterward. Move-only, closed by `deinit`.
pub unique class Hasher implements Send {
    handle: int = 0
    algorithm: Algorithm = Algorithm.sha256
    done: bool = false

    fn init(handle: int, algorithm: Algorithm) {
        self.handle = handle
        self.algorithm = algorithm
    }

    fn deinit() {
        if self.handle != 0 && !self.done {
            var ignored: int = 0
            unsafe {
                ignored = beans_hash_free(self.handle)
            }
        }
    }

    /// Opens a hasher for the given algorithm.
    pub static fn open(algorithm: Algorithm) -> Result<Hasher> {
        var handle: int = 0
        unsafe {
            handle = beans_hash_new(algorithm_code(algorithm))
        }
        if handle == 0 {
            return err("the platform has no hash provider available", "unsupported")
        }
        return ok(new Hasher(handle, algorithm))
    }

    /// Adds bytes to the running digest.
    pub fn update(data: Bytes) -> Result<bool> {
        if self.done { return err("update: the digest is already finished", "closed") }
        var status: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(data.len() as u64)
            status = beans_hash_update(self.handle, data.as_ptr(), req)
            req.free()
        }
        if status != 0 { return err("update failed (status {status})", "io") }
        return ok(true)
    }

    /// Produces the digest and spends the hasher.
    pub fn finish() -> Result<Bytes> {
        if self.done { return err("finish: the digest is already finished", "closed") }
        let size: int = digest_size(self.algorithm)
        let out: Bytes = new Bytes(size)
        var written: int = 0
        unsafe {
            let req: RawPtr<u64> = RawPtr.alloc(1)
            req.write(size as u64)
            written = beans_hash_finish(self.handle, out.as_ptr(), req)
            req.free()
        }
        self.done = true
        unsafe {
            let ignored: int = beans_hash_free(self.handle)
        }
        self.handle = 0
        if written != size {
            return err("the digest returned {written} of {size} bytes", "io")
        }
        return ok(move out)
    }
}

/// The SHA-1 digest of `data`, twenty bytes. Used for the WebSocket
/// handshake; not for anything needing collision resistance.
pub fn sha1(data: Bytes) -> Result<Bytes> {
    let hasher: Hasher = Hasher.open(Algorithm.sha1)?
    hasher.update(data)?
    return hasher.finish()
}

/// The SHA-256 digest of `data`, thirty-two bytes.
pub fn sha256(data: Bytes) -> Result<Bytes> {
    let hasher: Hasher = Hasher.open(Algorithm.sha256)?
    hasher.update(data)?
    return hasher.finish()
}

/// HMAC over `data` with `key`, using the given algorithm — the standard
/// keyed-hash construction (RFC 2104), built on the platform digest.
pub fn hmac(algorithm: Algorithm, key: Bytes, data: Bytes) -> Result<Bytes> {
    let block: int = block_size(algorithm)
    // A key longer than the block is replaced by its own digest.
    var normalized: Bytes = new Bytes(0)
    if key.len() > block {
        let hasher: Hasher = Hasher.open(algorithm)?
        hasher.update(key)?
        normalized = hasher.finish()?
    } else {
        normalized = key.slice(0, key.len())
    }
    normalized.resize(block)

    var inner_pad: Bytes = new Bytes(block)
    var outer_pad: Bytes = new Bytes(block)
    for index: int in 0..block {
        let byte: int = normalized.get(index)
        inner_pad.set(index, byte ^ 0x36)
        outer_pad.set(index, byte ^ 0x5c)
    }

    let inner: Hasher = Hasher.open(algorithm)?
    inner.update(inner_pad)?
    inner.update(data)?
    let inner_digest: Bytes = inner.finish()?

    let outer: Hasher = Hasher.open(algorithm)?
    outer.update(outer_pad)?
    outer.update(inner_digest)?
    return outer.finish()
}
