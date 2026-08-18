# Rust-level Windows and Linux support

The exact target list and current result live in
[`targets/support.tsv`](../targets/support.tsv). Run `make platform-status` to
check it against both compilers. This document is the implementation order.

The scope is the 25 Windows and Linux targets for which Rust ships host tools:
seven tier-1 hosts and eighteen tier-2 hosts. Android, OpenHarmony, other Unix
systems, embedded targets and Rust tier 3 are separate work.

## What complete means

A target is complete only when all four columns in the manifest say `pass`:

1. Programs pass a real native, Wine or QEMU differential execution gate.
2. The self-hosted compiler runs and rebuilds itself byte-identically.
3. A clean checkout on that target builds a compiler that reaches the same
   fixed point.
4. The release workflow publishes and smoke-tests an archive for that target.

Registering a triple or producing an object file is not platform support.

## Work order

### 0. Make support claims mechanical

- [x] List the 25 Rust host targets in one manifest.
- [x] Keep Rust's triple beside Beans' spelling where they differ.
- [x] Check that the compiler and the manifest register the same
  Windows/Linux targets.
- [x] Track program, compiler, fixed-point and archive gates separately.

### 1. Remove the portable-decimal blocker

- [x] Add signed and unsigned 128-bit integers made from two `u64` limbs. They
  must compile on hosts whose C compiler has no `__int128`.
- [x] Move integer and decimal literal parsing onto those types, including
  exact overflow messages.
- [x] Move `Decimal`, constant folding and rounding in the interpreter and
  emitter onto the portable representation.
- [x] Change the generated-code/runtime decimal boundary so no C declaration
  contains `__int128`. Prefer scalar out-parameters, as the fallible builtin ABI
  already does.
- [x] Port the same representation and operations through `src/*.b`. LLVM
  may use `i128` as a target-independent bit container, but the C ABI uses two
  scalar limbs and pointers, never a C `__int128` value.
- [x] Cover zero, signs, all 38-digit edges, overflow, multiply, divide, every
  rounding mode, parsing and formatting in interpreter/native parity tests.
- [x] Bump the runtime ABI and pass the final fixed-point, ASan, UBSan, TSan
  and leak gates after the whole branch is assembled.

Exit gate: the compiler and runtime build with a 32-bit C toolchain and the
`has_int128` target refusal is no longer needed for `decimal`.

### 2. Promote the three registered 32-bit targets

- [x] Add i686 Linux and ARMv7 Linux to host detection.
- [x] Run their compiler fixed point and differential loop under QEMU.
- [x] Add i686 Windows to the hosted compiler and fixed-point jobs.
- [ ] Publish Linux i686, Linux ARMv7 and Windows i686 archives.

Exit gate: those three manifest rows have four `pass` values.

### 3. Make Windows rebuild the compiler from source

- [x] Put process creation behind one host abstraction. Keep `posix_spawnp` on
  Unix and use `CreateProcessW` with exact Windows quoting.
- [x] Port temporary files, dynamic-library lookup and interpreter C-bridge
  loading.
- [ ] On x64, ARM64 and x86 Windows, rebuild the compiler with itself and
  require stages 2 and 3 to be byte-identical.
- [ ] Package and smoke-test Windows compiler archives.

Exit gate: all seven Windows rows pass `bootstrap` and
`archive`.

### 4. Add musl on existing 64-bit CPUs

- [x] Add a `musl` environment to both target models and both drivers.
- [x] Register x86-64, ARM64, RISC-V 64 and PowerPC64LE musl triples.
- [x] Make sysroot, linker flags and runtime cache keys include the libc.
- [x] Add full build and hosted gates in Alpine/QEMU environments.
- [ ] Publish one archive per musl target.

### 5. Add the remaining Windows ABIs

- [x] Use Rust's `aarch64-pc-windows-gnullvm` spelling and keep the old GNU
  spelling as an alias.
- [x] Register `x86_64-pc-windows-gnullvm`.
- [x] Add `msvc` as a real environment, not an alias for MinGW.
- [x] Use the MSVC SDK/libraries and COFF export rules for MSVC builds.
- [x] Remove the winpthreads dependency from the Windows runtime.
- [ ] Run the fixed-point and release jobs for GNU/GNullVM/MSVC x86, x64
  and ARM64 on the matching real Windows runners.

### 6. Add new little-endian Linux CPUs

- [x] Add LoongArch64 target facts, C ABI probes, runtime support and GNU gate.
- [x] Add and run the LoongArch64 musl build gate.
- [x] Add ARMv6 soft-float and hard-float as distinct ABI targets.
- [x] Run compiler fixed-point gates on real architecture code through QEMU.
- [ ] Publish and smoke-test their release archives.

### 7. Do the big-endian port

- [x] Remove every remaining unconditional little-endian read or write from
  codegen, the interpreter and `runtime/beans_rt.c`.
- [x] Test object headers, pointer masks, enums, wide Option/Result values,
  numeric byte access, C records and callbacks on a big-endian runner.
- [x] Add PowerPC64 GNU and musl, then s390x GNU, then PowerPC32 GNU.
- [x] Run program differential and compiler fixed-point gates for every row.
- [ ] Publish and smoke-test each release archive.

### 8. Final parity audit

- [ ] `make platform-status` reports `complete 25 / 25` and no partial or
  missing rows.
- [ ] Every passing manifest cell names a required CI/release gate.
- [ ] Fresh release archives build and run `examples/hello.b` on every target.
- [ ] Documentation uses the support tiers and does not say "all Windows" or
  "all Linux" where only one tier is meant.
