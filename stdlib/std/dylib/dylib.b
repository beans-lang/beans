// Loading a shared library at run time.
//
// `Dylib` is move-only and closes on `deinit`, like every other resource. Two things
// about it are deliberate and worth reading before use.
//
// **Symbols never leak into the global namespace.** The library is opened with
// `RTLD_LOCAL`. `RTLD_GLOBAL` would publish its symbols where an `extern "C" fn`
// resolves them — and the interpreter resolves those through `dlsym`, while a native
// build resolves them through the linker. A program would then link in one backend and
// not the other, which is the exact failure this project tests against.
//
// **Calling a resolved address requires `unsafe`, and always will.** A symbol is just an
// address; nothing about it says what arguments it takes. The signature is your guess,
// and a wrong guess corrupts the stack rather than raising an error. Only word-sized
// arguments — integers and pointers — are offered. Anything with a float, a narrow
// integer or a by-value struct needs `extern "C"`, where Clang classifies the signature
// for the target instead of you.

import std.dl

/// A resolved symbol: its address, and the name it was looked up by.
///
/// Holding one is safe. *Calling* it is not, and goes through `std.dl` inside an
/// `unsafe { }` block — see the note at the bottom of this file for why there is no
/// wrapper here.
pub class Symbol {
    pub address: int = 0
    pub name: string = ""

    pub fn init(address: int, name: string) {
        self.address = address
        self.name = name
    }

    /// True when the symbol resolved to a real address. A symbol *can* legitimately live
    /// at address 0, so this is a convenience rather than the error check — `Dylib.find`
    /// already reported failure as an `err`.
    pub fn is_null() -> bool {
        return self.address == 0
    }
}

/// An open shared library.
pub unique class Dylib {
    handle: int
    pub path: string = ""
    live: bool = true

    fn init(handle: int, path: string) {
        self.handle = handle
        self.path = path
    }

    fn deinit() {
        if self.live {
            let ignored: Result<bool> = dl.close(self.handle)
            self.live = false
        }
    }

    /// Opens a library by path. Fails with `not_found` and the loader's own message,
    /// which names the missing dependency when that is the real problem.
    pub static fn open(path: string) -> Result<Dylib> {
        return ok(new Dylib(dl.open(path)?, path))
    }

    /// Finds a symbol. `not_found` if the library does not have it.
    pub fn find(name: string) -> Result<Symbol> {
        if !self.live { return err("library is closed", "closed") }
        return ok(new Symbol(dl.symbol(self.handle, name)?, name))
    }

    /// True when the library has this symbol. Useful for probing an optional entry point
    /// without treating its absence as an error.
    pub fn has(name: string) -> bool {
        if !self.live { return false }
        match dl.symbol(self.handle, name) {
            ok(address) => { return true }
            err(e) => { return false }
        }
    }

    /// Closes it. **Every address obtained from this library becomes invalid**, and
    /// calling one afterwards is undefined — which is why `Symbol` carries the address
    /// rather than a way to reach back into the library.
    pub fn close() -> Result<bool> {
        if !self.live { return err("library is closed", "closed") }
        self.live = false
        return dl.close(self.handle)
    }
}

// **Calling is deliberately not wrapped here.**
//
// A `dylib.call2(symbol, a, b)` helper would have to open its own `unsafe { }` block to
// reach the primitive, and then callers would not need one — the wrapper would launder
// the unsafety, which is the opposite of what it is for. So calling goes straight to
// `std.dl` at the call site, where `unsafe` is visible and the checker enforces it:
//
//     import std.dl
//
//     let add: dylib.Symbol = lib.find("plug_add")?
//     unsafe {
//         let sum: int = dl.call2(add.address, 40, 2)
//     }
//
// `call0` through `call3` take and return one machine word each, which covers integers
// and pointers — every C function whose arguments pass in registers as words. A float, a
// narrow integer or a by-value struct needs `extern "C"`, where Clang classifies the
// signature for the target instead of you guessing.
