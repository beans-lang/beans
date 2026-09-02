package main

import std.target as running_target

class TargetDescription {
    triple: string
    arch: string
    os: string
    env: string
    object_format: string
    endian: string
    pointer_bits: int
    stack_align: int
    max_scalar_align: int
    max_declared_align: int
    atomic_widths: List<int>
    has_decimal: bool
    features: List<string>

    fn init(triple: string, arch: string, os: string, env: string,
            object_format: string, pointer_bits: int, stack_align: int,
            move atomic_widths: List<int>, has_decimal: bool,
            move features: List<string>) {
        self.triple = triple
        self.arch = arch
        self.os = os
        self.env = env
        self.object_format = object_format
        self.endian =
            if arch == "powerpc" || arch == "powerpc64" ||
               arch == "s390x" { "big" } else { "little" }
        self.pointer_bits = pointer_bits
        self.stack_align = stack_align
        // The i386 System V ABI caps every fundamental scalar at 4-byte
        // alignment — `long long` and `double` included, where every other
        // 32-bit target here (Win32 x86, ARM EABI, RV32) keeps 8. SSE vectors
        // stay 16 through the uncapped vector path. Getting this wrong put a
        // struct's i64 (and everything after it) one slot too far out: Error's
        // kind landed past the object, so a failed builtin read it as null.
        self.max_scalar_align =
            if arch == "x86" && pointer_bits == 32 &&
               os != "windows" { 4 } else { 8 }
        self.max_declared_align = 4096
        self.atomic_widths = move atomic_widths
        self.has_decimal = has_decimal
        self.features = move features
    }

    fn pointer_size() -> int { return self.pointer_bits / 8 }

    // Does this target carry the controlled unwind a contained panic needs
    // (spec/CONCURRENCY.md)? The mechanism is the Itanium C++ ABI unwinder —
    // `invoke`/`landingpad` cleanup pads walked by _Unwind_ForcedUnwind with
    // __gcc_personality_v0 — so it needs a DWARF-EH object format and an
    // architecture whose _Unwind_Exception matches that ABI. COFF wants SEH
    // funclets instead of landing pads, wasm has no unwinder and no fibers,
    // and 32-bit ARM's EHABI is a different personality with a wider
    // exception record. Those keep the earlier behaviour: a contained panic
    // ends the fiber without unwinding its frames, which leaks what they
    // held. Widening this list means proving the pairing on that target
    // first, not assuming it.
    fn supports_unwind() -> bool {
        if self.object_format != "elf" &&
           self.object_format != "macho" {
            return false
        }
        if self.os == "wasi" || self.os == "none" {
            return false
        }
        return self.arch == "x86_64" ||
               self.arch == "arm64"
    }

    fn supports_atomic(width: int) -> bool {
        return self.atomic_widths.contains(width)
    }

    // (Runtime builtins used to ask here whether a 16-byte BRes/BOpt return rides
    // in a register pair or an sret pointer. They no longer do: generated code
    // calls scalar `<sym>_out` wrappers with an output pointer, so the boundary is
    // the same on every target. User `extern "C"` aggregate ABI is Clang's job in
    // the C ABI bridge, not a compiler-side guess, so no such predicate lives here.)

    fn known_features() -> List<string> {
        if self.arch == "x86_64" {
            return [
                "sse2", "sse3", "ssse3", "sse4.1", "sse4.2",
                "popcnt", "avx", "avx2", "fma", "bmi", "bmi2",
                "f16c", "aes", "pclmul", "avx512f",
            ]
        }
        // 32-bit x86 knows the same optional extensions as x86-64; they are the
        // same ISA extensions. Only the baseline and the CPU model names differ.
        if self.arch == "x86" {
            return [
                "sse2", "sse3", "ssse3", "sse4.1", "sse4.2",
                "popcnt", "avx", "avx2", "fma", "bmi", "bmi2",
                "f16c", "aes", "pclmul", "avx512f",
            ]
        }
        if self.arch == "arm64" {
            return [
                "neon", "fp16", "dotprod", "crc", "aes",
                "sha2", "sha3", "lse",
            ]
        }
        if self.arch == "arm32" { return ["dsp"] }
        if self.arch == "riscv32" {
            return ["m", "a", "c", "f", "d"]
        }
        if self.arch == "riscv64" {
            return ["m", "a", "c", "f", "d"]
        }
        if self.arch == "loongarch64" { return ["lsx"] }
        if self.arch == "wasm32" { return ["simd128"] }
        return []
    }

    fn is_known_feature(name: string) -> bool {
        return self.known_features().contains(name)
    }

    fn has_feature(name: string) -> bool {
        return self.features.contains(name)
    }

    fn normalize_feature(written: string) -> string {
        if self.is_known_feature(written) { return written }
        let dotted: string = written.replace("_", ".")
        if self.is_known_feature(dotted) { return dotted }
        return written
    }

    fn feature_spelling(name: string) -> string {
        return name.replace(".", "_")
    }

    fn enable_feature(name: string) {
        if !self.features.contains(name) {
            self.features.push(name)
        }
    }

    fn disable_feature(name: string) {
        var kept: List<string> = []
        for feature: string in self.features {
            if feature != name { kept.push(feature) }
        }
        self.features = move kept
    }

    fn apply_feature_list(written: string) -> string {
        for entry: string in written.split(",") {
            if entry == "" {
                return "empty --features entry; use +name or -name"
            }
            let sign: int = entry.byte_at(0)
            if sign != 43 && sign != 45 {
                return "--features entry '{entry}' must start with + or - (for example +avx2,-sse4.2)"
            }
            let name: string = entry.slice(1, entry.len())
            if name == "" {
                return "--features entry '{entry}' names no feature"
            }
            if !self.is_known_feature(name) {
                let known: List<string> = self.known_features()
                if known.len() == 0 {
                    return "unknown feature '{name}': {self.arch} has no optional features"
                }
                return "unknown feature '{name}' for {self.arch}; known features are {known.join(", ")}"
            }
            if sign == 43 {
                self.enable_feature(name)
            } else {
                // rv64gc and LP64D are one ABI contract. Its libc, generated
                // IR and C runtime must never be built for different extension
                // sets, so none of this target's baseline letters is optional.
                if (self.arch == "riscv64" &&
                    ["m", "a", "c", "f", "d"].contains(name)) ||
                   (self.arch == "loongarch64" && name == "lsx") {
                    if self.arch == "riscv64" {
                        return "feature '{name}' is required by {self.triple}'s rv64gc/LP64D ABI and cannot be disabled"
                    }
                    return "feature '{name}' is required by {self.triple}'s baseline ABI and cannot be disabled"
                }
                self.disable_feature(name)
            }
        }
        return ""
    }

    fn apply_cpu(cpu: string) -> string {
        if cpu == "generic" || cpu == "native" { return "" }
        var known: List<string> = ["generic", "native"]
        var implied: List<string> = []
        var found: bool = false
        if self.arch == "x86_64" {
            known.push("x86-64")
            known.push("x86-64-v2")
            known.push("x86-64-v3")
            known.push("haswell")
            if cpu == "x86-64" {
                found = true
            } else if cpu == "x86-64-v2" {
                found = true
                implied = [
                    "sse3", "ssse3", "sse4.1", "sse4.2",
                    "popcnt",
                ]
            } else if cpu == "x86-64-v3" {
                found = true
                implied = [
                    "sse3", "ssse3", "sse4.1", "sse4.2",
                    "popcnt", "avx", "avx2", "fma", "bmi",
                    "bmi2", "f16c",
                ]
            } else if cpu == "haswell" {
                found = true
                implied = [
                    "sse3", "ssse3", "sse4.1", "sse4.2",
                    "popcnt", "avx", "avx2", "fma", "bmi",
                    "bmi2", "f16c", "aes", "pclmul",
                ]
            }
        } else if self.arch == "x86" {
            // Read out of Clang's own predefines for -march=<name> on
            // i686-pc-windows-gnu, not carried over from the 64-bit table:
            // haswell does not claim aes there because Clang does not
            // define __AES__ for it.
            known.push("pentium4")
            known.push("core2")
            known.push("nehalem")
            known.push("haswell")
            if cpu == "pentium4" {
                found = true
            } else if cpu == "core2" {
                found = true
                implied = ["sse3", "ssse3"]
            } else if cpu == "nehalem" {
                found = true
                implied = [
                    "sse3", "ssse3", "sse4.1", "sse4.2", "popcnt",
                ]
            } else if cpu == "haswell" {
                found = true
                implied = [
                    "sse3", "ssse3", "sse4.1", "sse4.2",
                    "popcnt", "avx", "avx2", "fma", "bmi",
                    "bmi2", "f16c", "pclmul",
                ]
            }
        } else if self.arch == "arm64" {
            known.push("apple-m1")
            known.push("apple-m2")
            known.push("neoverse-n1")
            known.push("cortex-a72")
            if cpu == "apple-m1" || cpu == "apple-m2" {
                found = true
                implied = [
                    "fp16", "dotprod", "crc", "aes", "sha2", "lse",
                ]
            } else if cpu == "neoverse-n1" {
                found = true
                implied = [
                    "dotprod", "crc", "aes", "sha2", "lse",
                ]
            } else if cpu == "cortex-a72" {
                found = true
            }
        } else if self.arch == "arm32" {
            known.push("cortex-m4")
            known.push("cortex-m7")
            known.push("cortex-m33")
            if cpu == "cortex-m4" || cpu == "cortex-m7" ||
               cpu == "cortex-m33" {
                found = true
                implied = ["dsp"]
            }
        } else if self.arch == "riscv32" {
            known.push("generic-rv32")
            known.push("sifive-e31")
            found = cpu == "generic-rv32" ||
                    cpu == "sifive-e31"
        } else if self.arch == "riscv64" {
            known.push("generic-rv64")
            found = cpu == "generic-rv64"
        } else if self.arch == "loongarch64" {
            known.push("loongarch64")
            found = cpu == "loongarch64"
        }
        if !found {
            return "unknown --cpu '{cpu}' for {self.arch}; known CPUs are {known.join(", ")}"
        }
        for feature: string in implied {
            self.enable_feature(feature)
        }
        return ""
    }

    fn max_simd_bits() -> int {
        // Both x86 widths answer identically: the vector register file is the
        // same hardware, and 32-bit mode reaches all of it.
        if self.arch == "x86_64" || self.arch == "x86" {
            if self.features.contains("avx512f") { return 512 }
            if self.features.contains("avx2") ||
               self.features.contains("avx") {
                return 256
            }
            if self.features.contains("sse2") { return 128 }
        } else if self.arch == "arm64" &&
                  self.features.contains("neon") {
            return 128
        } else if self.arch == "wasm32" &&
                  self.features.contains("simd128") {
            return 128
        }
        return 0
    }

    fn c_driver_flags() -> List<string> {
        if self.triple == "arm-unknown-linux-gnueabi" {
            return [
                "-march=armv6", "-mfloat-abi=soft",
                "-mno-unaligned-access",
            ]
        }
        if self.triple == "arm-unknown-linux-gnueabihf" {
            return [
                "-march=armv6", "-mfloat-abi=hard", "-mfpu=vfp",
                "-mno-unaligned-access",
            ]
        }
        if self.arch == "loongarch64" {
            return ["-march=loongarch64", "-mabi=lp64d", "-mlsx"]
        }
        if self.arch == "powerpc" {
            // Ubuntu Clang otherwise resolves libgcc_s through the host
            // /usr/lib32 before the PowerPC sysroot.
            return ["-m32", "-msecure-plt", "-static-libgcc"]
        }
        if self.arch == "powerpc64" {
            let abi: string =
                if self.env == "musl" { "elfv2" } else { "elfv1" }
            return ["-mcpu=ppc64", "-mabi={abi}"]
        }
        if self.arch == "s390x" { return ["-march=z10"] }
        if self.arch != "riscv32" && self.arch != "riscv64" {
            return []
        }
        var march: string =
            if self.arch == "riscv32" { "rv32i" } else { "rv64i" }
        for extension: string in ["m", "a", "f", "d", "c"] {
            if self.has_feature(extension) {
                march = "{march}{extension}"
            }
        }
        // rv32 keeps the registered soft-float ABI even when f/d instructions
        // are enabled. rv64gc is the hard-float ABI its Linux sysroot uses.
        let abi: string =
            if self.arch == "riscv32" { "ilp32" } else { "lp64d" }
        return ["-march={march}", "-mabi={abi}"]
    }

    fn llvm_triple() -> string {
        if self.env != "gnullvm" { return self.triple }
        if self.arch == "arm64" { return "aarch64-pc-windows-gnu" }
        if self.arch == "x86_64" { return "x86_64-pc-windows-gnu" }
        if self.arch == "x86" { return "i686-pc-windows-gnu" }
        return self.triple
    }
}

fn supported_targets() -> List<TargetDescription> {
    return [
        new TargetDescription(
            "arm64-apple-darwin", "arm64", "macos", "none",
            "macho", 64, 16, [8, 16, 32, 64], true, ["neon"]),
        new TargetDescription(
            "x86_64-unknown-linux-gnu", "x86_64", "linux", "gnu",
            "elf", 64, 16, [8, 16, 32, 64], true, ["sse2"]),
        new TargetDescription(
            "aarch64-unknown-linux-gnu", "arm64", "linux", "gnu",
            "elf", 64, 16, [8, 16, 32, 64], true, ["neon"]),
        // musl is a separate environment even where the machine ABI matches
        // GNU. The distinct triple keeps sysroots and runtime caches apart.
        new TargetDescription(
            "x86_64-unknown-linux-musl", "x86_64", "linux", "musl",
            "elf", 64, 16, [8, 16, 32, 64], true, ["sse2"]),
        new TargetDescription(
            "aarch64-unknown-linux-musl", "arm64", "linux", "musl",
            "elf", 64, 16, [8, 16, 32, 64], true, ["neon"]),
        // The first RISC-V Linux target: rv64gc, LP64D, 8-byte pointers and a
        // 16-byte stack. RV64A gives 64-bit lock-free atomics, and portable
        // decimal is available. Both programs and beansc
        // itself pass their qemu-riscv64 gates. The position in this list is
        // the order `beansc target` prints, so it is not free to change.
        new TargetDescription(
            "riscv64-unknown-linux-gnu", "riscv64", "linux", "gnu",
            "elf", 64, 16, [8, 16, 32, 64], true, ["m", "a", "c", "f", "d"]),
        new TargetDescription(
            "riscv64-unknown-linux-musl", "riscv64", "linux", "musl",
            "elf", 64, 16, [8, 16, 32, 64], true, ["m", "a", "c", "f", "d"]),
        // 32-bit x86 Linux — same Arch as i686 Windows, but probed facts differ:
        // stack is 16-byte aligned (S128, not the Windows cdecl 4), ELF not COFF,
        // portable decimal is available. 64-bit atomics stay (CMPXCHG8B), and
        // SSE2 is the shared x86 baseline so 128-bit SIMD is available.
        new TargetDescription(
            "i686-unknown-linux-gnu", "x86", "linux", "gnu",
            "elf", 32, 16, [8, 16, 32, 64], true, ["sse2"]),
        // 32-bit hard-float ARM Linux. Same arm32 Arch as the Cortex-M board but
        // hosted, gnueabihf: stack 8-byte aligned (S64), 64-bit atomics lower to
        // LDREXD/STREXD, portable decimal is available, and no NEON baseline
        // so SIMD is refused. Clang reads the hard-float ABI from the triple.
        new TargetDescription(
            "armv7-unknown-linux-gnueabihf", "arm32", "linux", "gnueabihf",
            "elf", 32, 8, [8, 16, 32, 64], true, ["dsp"]),
        // Rust's plain `arm` Linux targets are ARMv6K. Their machine and float
        // ABI flags are emitted by c_driver_flags; neither inherits the
        // Cortex-M/ARMv7 `dsp` feature merely because all use arm32 layouts.
        new TargetDescription(
            "arm-unknown-linux-gnueabi", "arm32", "linux", "gnueabi",
            "elf", 32, 8, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "arm-unknown-linux-gnueabihf", "arm32", "linux", "gnueabihf",
            "elf", 32, 8, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "loongarch64-unknown-linux-gnu", "loongarch64", "linux", "gnu",
            "elf", 64, 16, [8, 16, 32, 64], true, ["lsx"]),
        new TargetDescription(
            "loongarch64-unknown-linux-musl", "loongarch64", "linux", "musl",
            "elf", 64, 16, [8, 16, 32, 64], true, ["lsx"]),
        // 64-bit little-endian POWER. 8-byte pointers, 16-byte stack, 64-bit
        // lock-free atomics and portable decimal, so beansc
        // passes its hosted gate. No feature set: VSX has no Beans SIMD lowering
        // yet, so SIMD is refused. Clang reads ELFv2/POWER8 from the triple.
        new TargetDescription(
            "powerpc64le-unknown-linux-gnu", "powerpc64le", "linux", "gnu",
            "elf", 64, 16, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "powerpc64le-unknown-linux-musl", "powerpc64le", "linux", "musl",
            "elf", 64, 16, [8, 16, 32, 64], true, []),
        // Big-endian hosted targets. The driver pins their Rust-compatible
        // PowerPC ABI and s390x CPU baseline below.
        new TargetDescription(
            "powerpc-unknown-linux-gnu", "powerpc", "linux", "gnu",
            "elf", 32, 16, [8, 16, 32], true, []),
        new TargetDescription(
            "powerpc64-unknown-linux-gnu", "powerpc64", "linux", "gnu",
            "elf", 64, 16, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "powerpc64-unknown-linux-musl", "powerpc64", "linux", "musl",
            "elf", 64, 16, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "s390x-unknown-linux-gnu", "s390x", "linux", "gnu",
            "elf", 64, 8, [8, 16, 32, 64], true, []),
        // Windows through the GNU environment first, not MSVC: MinGW-w64 ships
        // winpthreads and a POSIX-shaped CRT, so the C runtime ports as #ifdef
        // branches instead of a rewrite. Decimal uses portable limbs.
        new TargetDescription(
            "x86_64-pc-windows-gnu", "x86_64", "windows", "gnu",
            "coff", 64, 16, [8, 16, 32, 64], true, ["sse2"]),
        // Windows on ARM. Probed from clang --target=aarch64-pc-windows-gnu:
        // the data layout ends in S128 so the stack is 16-byte aligned, and
        // portable decimal is available. 128-bit atomics stay
        // out here for the same reason as on every other architecture.
        new TargetDescription(
            "aarch64-pc-windows-gnullvm", "arm64", "windows", "gnullvm",
            "coff", 64, 16, [8, 16, 32, 64], true, ["neon"]),
        new TargetDescription(
            "x86_64-pc-windows-gnullvm", "x86_64", "windows", "gnullvm",
            "coff", 64, 16, [8, 16, 32, 64], true, ["sse2"]),
        new TargetDescription(
            "x86_64-pc-windows-msvc", "x86_64", "windows", "msvc",
            "coff", 64, 16, [8, 16, 32, 64], true, ["sse2"]),
        new TargetDescription(
            "i686-pc-windows-msvc", "x86", "windows", "msvc",
            "coff", 32, 4, [8, 16, 32, 64], true, ["sse2"]),
        new TargetDescription(
            "aarch64-pc-windows-msvc", "arm64", "windows", "msvc",
            "coff", 64, 16, [8, 16, 32, 64], true, ["neon"]),
        // 32-bit Windows. Nothing here matches the 64-bit Windows entry above:
        // pointers are 4 bytes and the data layout ends in S32, so the stack is
        // 4-byte aligned rather than 16. Decimal uses portable limbs. 64-bit
        // atomics stay in, because CMPXCHG8B makes them genuinely lock-free.
        new TargetDescription(
            "i686-pc-windows-gnu", "x86", "windows", "gnu",
            "coff", 32, 4, [8, 16, 32, 64], true, ["sse2"]),
        new TargetDescription(
            "wasm32-wasip1", "wasm32", "wasi", "none",
            "wasm", 32, 16, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "wasm32-unknown-unknown", "wasm32", "none", "none",
            "wasm", 32, 16, [8, 16, 32, 64], true, []),
        new TargetDescription(
            "thumbv7em-none-eabi", "arm32", "none", "eabi",
            "elf", 32, 8, [8, 16, 32], false, ["dsp"]),
        new TargetDescription(
            "riscv32-unknown-none-elf", "riscv32", "none", "none",
            "elf", 32, 16, [8, 16, 32], false, ["m", "a", "c"]),
    ]
}

fn canonical_target_name(written: string) -> string {
    if written == "aarch64-apple-darwin" ||
       written == "arm64-apple-macosx" ||
       written == "aarch64-apple-macosx" {
        return "arm64-apple-darwin"
    }
    if written == "x86_64-linux-gnu" ||
       written == "x86_64-unknown-linux" ||
       written == "x86_64-pc-linux-gnu" {
        return "x86_64-unknown-linux-gnu"
    }
    if written == "aarch64-linux-gnu" ||
       written == "aarch64-unknown-linux" ||
       written == "arm64-unknown-linux-gnu" {
        return "aarch64-unknown-linux-gnu"
    }
    if written == "arm64-unknown-linux-musl" {
        return "aarch64-unknown-linux-musl"
    }
    if written == "riscv64-linux-gnu" ||
       written == "riscv64gc-unknown-linux-gnu" ||
       written == "riscv64gc-linux-gnu" ||
       written == "riscv64-unknown-linux" ||
       written == "riscv64-pc-linux-gnu" {
        return "riscv64-unknown-linux-gnu"
    }
    if written == "riscv64gc-unknown-linux-musl" ||
       written == "riscv64-linux-musl" ||
       written == "riscv64gc-linux-musl" {
        return "riscv64-unknown-linux-musl"
    }
    if written == "i686-linux-gnu" ||
       written == "i686-pc-linux-gnu" ||
       written == "i686-unknown-linux" ||
       written == "i386-unknown-linux-gnu" ||
       written == "i386-linux-gnu" ||
       written == "i586-linux-gnu" {
        return "i686-unknown-linux-gnu"
    }
    if written == "armv7l-unknown-linux-gnueabihf" ||
       written == "armv7-linux-gnueabihf" ||
       written == "armv7l-linux-gnueabihf" {
        return "armv7-unknown-linux-gnueabihf"
    }
    if written == "armv6-unknown-linux-gnueabi" ||
       written == "arm-linux-gnueabi" {
        return "arm-unknown-linux-gnueabi"
    }
    if written == "armv6-unknown-linux-gnueabihf" ||
       written == "arm-linux-gnueabihf" {
        return "arm-unknown-linux-gnueabihf"
    }
    if written == "powerpc64le-linux-gnu" ||
       written == "ppc64le-linux-gnu" ||
       written == "ppc64le-unknown-linux-gnu" ||
       written == "powerpc64le-unknown-linux" {
        return "powerpc64le-unknown-linux-gnu"
    }
    if written == "ppc64le-unknown-linux-musl" ||
       written == "ppc64le-linux-musl" {
        return "powerpc64le-unknown-linux-musl"
    }
    if written == "powerpc-linux-gnu" ||
       written == "ppc-linux-gnu" ||
       written == "ppc-unknown-linux-gnu" {
        return "powerpc-unknown-linux-gnu"
    }
    if written == "powerpc64-linux-gnu" ||
       written == "ppc64-linux-gnu" ||
       written == "ppc64-unknown-linux-gnu" {
        return "powerpc64-unknown-linux-gnu"
    }
    if written == "powerpc64-linux-musl" ||
       written == "ppc64-linux-musl" ||
       written == "ppc64-unknown-linux-musl" {
        return "powerpc64-unknown-linux-musl"
    }
    if written == "s390x-linux-gnu" {
        return "s390x-unknown-linux-gnu"
    }
    // x86_64-w64-mingw32 is what the MinGW toolchain itself is named after
    // and what its users type; Clang normalizes it to the windows-gnu triple.
    if written == "x86_64-w64-mingw32" ||
       written == "x86_64-windows-gnu" ||
       written == "x86_64-unknown-windows-gnu" {
        return "x86_64-pc-windows-gnu"
    }
    // The same spellings for the other two Windows architectures. The
    // -w64-mingw32 forms are what LLVM-MinGW names its own drivers after, so
    // they are what a user reads off their bin directory.
    if written == "aarch64-pc-windows-gnu" ||
       written == "aarch64-w64-mingw32" ||
       written == "aarch64-windows-gnu" ||
       written == "aarch64-unknown-windows-gnu" ||
       written == "aarch64-w64-windows-gnu" ||
       written == "arm64-pc-windows-gnu" ||
       written == "arm64-w64-mingw32" {
        return "aarch64-pc-windows-gnullvm"
    }
    // i386/i586 name the same 32-bit Windows target people mean by "x86". They
    // normalize rather than register, so one canonical name reaches the IR.
    if written == "i686-w64-mingw32" ||
       written == "i686-windows-gnu" ||
       written == "i686-unknown-windows-gnu" ||
       written == "i686-w64-windows-gnu" ||
       written == "i386-pc-windows-gnu" ||
       written == "i586-pc-windows-gnu" {
        return "i686-pc-windows-gnu"
    }
    if written == "wasm32-wasi" ||
       written == "wasm32-unknown-wasi" {
        return "wasm32-wasip1"
    }
    if written == "wasm32-none" {
        return "wasm32-unknown-unknown"
    }
    if written == "riscv32imac-unknown-none-elf" ||
       written == "riscv32-none-elf" ||
       written == "riscv32-unknown-elf" {
        return "riscv32-unknown-none-elf"
    }
    if written == "thumbv7em-unknown-none-eabi" {
        return "thumbv7em-none-eabi"
    }
    return written
}

fn find_target(written: string) -> Option<TargetDescription> {
    let canonical: string = canonical_target_name(written)
    for target: TargetDescription in supported_targets() {
        if target.triple == canonical { return some(target) }
    }
    return none
}

fn host_target_description() -> Option<TargetDescription> {
    return find_target(running_target.triple())
}

fn host_target_name() -> string {
    return running_target.triple()
}

fn render_target(target: TargetDescription) -> string {
    return "target {target.triple}\narch {target.arch}\nos {target.os}\nenv {target.env}\nobject {target.object_format}\nendian {target.endian}\npointer_bits {target.pointer_bits}\nstack_align {target.stack_align}\nmax_scalar_align {target.max_scalar_align}\nmax_declared_align {target.max_declared_align}\natomics {target.atomic_widths.join(",")}\ndecimal {target.has_decimal}\nfeatures {target.features.join(",")}\nmax_simd_bits {target.max_simd_bits()}"
}
