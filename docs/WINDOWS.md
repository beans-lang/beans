# Windows targets

Seven Windows host targets across GNU/MinGW, GNullVM/UCRT, and MSVC.
[spec/SYNTAX.md](../spec/SYNTAX.md) is the contract — what each target refuses and why
lives there. This file is the operational half: which toolchain, which machine
can run what, and the exact commands.

## The targets

| target | environment | pointer | stack align | `decimal` |
|---|---|---|---|---|
| `x86_64-pc-windows-gnu` | MinGW/MSVCRT | 8 | 16 | yes |
| `i686-pc-windows-gnu` | MinGW/MSVCRT | 4 | 4 | yes |
| `x86_64-pc-windows-gnullvm` | LLVM-MinGW/UCRT | 8 | 16 | yes |
| `aarch64-pc-windows-gnullvm` | LLVM-MinGW/UCRT | 8 | 16 | yes |
| `x86_64-pc-windows-msvc` | MSVC | 8 | 16 | yes |
| `i686-pc-windows-msvc` | MSVC | 4 | 4 | yes |
| `aarch64-pc-windows-msvc` | MSVC | 8 | 16 | yes |

The `i686` rows are compatibility targets and run through WOW64 on an x64
machine. Their smaller inline-assembly and intrinsic sets are recorded in
spec/SYNTAX.md's refusal table. ARM64 runs on a real `windows-11-arm` runner.

Every row has a CI job that runs programs, runs `beansc.exe`, and rebuilds the
compiler to a fixed point. Decimal uses portable two-limb arithmetic, so i686
does not need C++ `__int128`.
The current pass/missing result is kept in `targets/support.tsv`; adding a job
does not mark its row passed before a real Windows run succeeds.

**Minimum Windows version: Windows 10.** Windows on ARM has no earlier release
worth targeting, and the runtime's Win32 calls are the Windows 10 set.

Every machine fact above was measured from the toolchain rather than assumed —
the data layout's trailing `S` field for the stack alignment and
`__atomic_always_lock_free` for the atomic widths. None was copied from a Linux
or macOS entry. Decimal is implemented by portable limbs on every row.

## Toolchain

GNU and GNullVM builds use LLVM-MinGW. MSVC builds use LLVM's compiler and
linker from an MSVC developer command prompt, so the matching Windows SDK and
MSVC libraries are available. The runtime uses Win32 threads directly; none of
the seven targets needs winpthreads.

`test/windows_toolchain.sh` fetches one and prints its `bin` directory. It
installs beside the checkout under `toolchains/` (gitignored) and never touches
the system:

```bash
export PATH="$(bash test/windows_toolchain.sh):$PATH"
```

It picks the archive for the machine it runs on. The CRT is `msvcrt` where
upstream publishes one — that is what the existing x86-64 target already links
against — and `ucrt` on an ARM64 or macOS host, where no msvcrt build exists.
Override with `BEANS_LLVM_MINGW_VERSION` or `BEANS_LLVM_MINGW_CRT`;
`BEANS_TOOLCHAIN_OFFLINE=1` makes a missing toolchain an error rather than a
download.

## Building

```bash
beansc build --target x86_64-pc-windows-gnu  app.b -o app.exe
beansc build --target i686-pc-windows-gnu    app.b -o app.exe
beansc build --target aarch64-pc-windows-gnullvm app.b -o app.exe
beansc build --target x86_64-pc-windows-msvc app.b -o app.exe
```

`--emit obj` and `--emit ir` need no Windows libraries at all, so a cross
*compile* works from any host; only a cross *link* needs the toolchain above.

## Testing

Compile-only proves nothing here, so every gate ends in execution.

### Which machine can run what

| binary architecture | x64 Windows | ARM64 Windows | Linux + Wine |
|---|---|---|---|
| x86-64 | yes | yes, emulated | yes |
| i686 | yes, through WOW64 | yes, emulated | needs a 32-bit Wine |
| aarch64 | **no** | yes, native | **no** |

An ARM64 bundle cannot be executed on an x64 machine; Windows refuses to load
it. That is why the ARM64 gate is a `windows-11-arm` CI runner and not
something an x64 developer machine can stand in for.

### The Wine gate (fast loop, x86-64 only)

```bash
make test-windows
```

### The real-Windows differential gate

Staging is cross-compilation and runs anywhere; the run half needs a Windows
machine of the matching architecture.

```bash
# on the build host
make test-windows-native            # x86-64 GNU -> build/windows_native
make test-windows-native-i686       # i686 GNU   -> build/windows_i686
make test-windows-native-arm64      # ARM64 GNullVM -> build/windows_arm64
make test-windows-arch              # the fast GNU/GNullVM architecture set

# on the Windows machine, against the staged bundle
bash test/windows_native_run.sh build/windows_native x86_64
bash test/windows_native_run.sh build/windows_i686   i686
bash test/windows_native_run.sh build/windows_arm64  aarch64
```

The run half asserts the PE Machine field of every binary before executing
anything, holds each one to the interpreter's output and exit code byte for
byte, and treats `STATUS_INVALID_IMAGE_FORMAT` as a failure rather than a skip.
Per-target floors (53 for the 64-bit pair, 36 for i686) mean a capability skip
that starts swallowing examples fails the gate instead of quietly shrinking it.

`c_layout_structs` is held to a positive golden on i686 rather than diffed: it
prints a pointer's size and alignment, which are constants of the *selected*
target, and `beansc run` always interprets for the host. A running 32-bit
binary must report 4/4; a regression to the host's 8/8 is the exact shape of
the bug that once made `deinit` never run on a 32-bit board.

### The hosted gate

`beansc.exe` itself on Windows, running its own interpret-compile-diff loop:

```bash
BEANSC=build/windows_native/beansc.exe bash test/windows_hosted.sh
```

CI additionally requires the hosted compiler to rebuild itself byte-identically
for its own architecture — the per-architecture fixed point.

## CI

`.github/workflows/targets.yml`:

- `windows-stage` — GNU/GNullVM staging for x86-64, i686 and ARM64. It stages
  the differential bundle and cross-builds `beansc.exe` for each ABI.
- `windows-native` — runs each bundle on a real Windows machine.
  `windows-latest` carries x86-64 and i686; **`windows-11-arm` carries
  aarch64**, natively. Each job first asserts the native Windows architecture
  matches what it expects through PowerShell's
  `RuntimeInformation.OSArchitecture`. This reads the operating system rather
  than Git Bash's emulated process environment, so an ARM64 job that landed on
  an x64 runner fails instead of silently measuring emulation.
  It also requires stage 2 and stage 3 to be byte-identical.
- `windows-msvc` — repeats the program, hosted compiler and fixed-point gates
  for x86-64, i686 and ARM64 with MSVC libraries.
- `windows-gate` — the Wine loop, unchanged.

## Known gaps

- **Signals are refusing stubs on every Windows target.** The language's
  contract is that a watched signal is blocked and read from a descriptor;
  Windows has neither `signalfd` nor `kqueue` and cannot express it. Every
  `std.signal` operation reports the gap in a sentence. The symbols still link
  because the compiler's own interpreter imports `std.sig`.
- **`sha3` always reports absent on Windows/ARM.** Windows exposes no
  processor-feature flag for it, so it is reported absent rather than guessed;
  the cost is only that a guarded fast path takes the generic branch. `fp16`
  *is* detected, via `PF_ARM_V82_FP16_INSTRUCTIONS_AVAILABLE`.
- **`std.asm` and `intrinsic.crc32c` are refused on i686**, for the reasons in
  spec/SYNTAX.md's refusal table.
- **No ARM64EC target.** ARM64EC is a different mixed x64/ARM64 ABI, not an
  alias for ARM64 MSVC.
