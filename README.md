# beans

A small OOP language: Java-style objects, Go-sized grammar, with C++-class performance and systems access as goals. Files end in `.b`.

- [spec/SYNTAX.md](spec/SYNTAX.md) — the language draft (start here)
- [examples/](examples/) — real `.b` programs
- [compiler/beans/](compiler/beans/) — the self-hosted compiler
- [compiler/bootstrap/](compiler/bootstrap/) — the C++20 stage-0 bootstrap compiler
- [stdlib/std/](stdlib/std/) — compiler-shipped standard library packages

## Status

| piece | state |
|---|---|
| language contract | 1.0 candidate |
| lexer | done |
| parser | done |
| module loader | modules, hashed `beans.lock`, offline builds, compiler-shipped `.b` std packages |
| type checker | v3 — whole-program HIR types, target layouts, MIR ownership plan |
| interpreter | done (v2) — `beansc run` |
| LLVM native backend | checked MIR emitter, ARC + cycle collector |
| Beans-written compiler | default `beansc`; stage 2 and stage 3 reach a byte-identical IR fixed point |
| C++ compiler | retained as the stage-0 `beansc0` bootstrap and comparison compiler |

The executable is currently `0.9.0-dev`. This is the 1.0 stabilization line,
not a production release yet. The remaining release and self-hosting gates are
tracked at the top of [ROADMAP.md](ROADMAP.md).

## Install

One command. No other software required on the platforms that ship a full
package.

**macOS and Linux**

```bash
curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://github.com/beans-lang/beans/releases/latest/download/beans-install.ps1 | iex
```

Open a new terminal, then:

```bash
beansc --version
beansc doctor
beansc run hello.b
```

The installer detects your OS, CPU and libc, picks the right package, verifies
its SHA-256 before unpacking, installs under your home directory without sudo or
administrator rights, and adds `bin` to your PATH. Running it again is safe. If a
download, checksum or unpack fails, an existing installation is left untouched.

Default locations, overridable with `BEANS_HOME` or `--prefix`:

| platform | path |
|---|---|
| macOS, Linux | `$HOME/.beans` |
| Windows | `%LOCALAPPDATA%\Beans` |

The layout inside is stable: `bin/`, `lib/`, `toolchain/` and `VERSION`.

Pick a version, a location, or a target:

```bash
curl -fsSL .../beans-install.sh | sh -s -- --version 0.9.0 --prefix /opt/beans
BEANS_TARGET=x86_64-unknown-linux-musl curl -fsSL .../beans-install.sh | sh
```

Other options: `--force`, `--no-modify-path`, `--help`. To uninstall, delete the
install directory and remove the PATH line the installer added to your shell
profile:

```bash
rm -rf "$HOME/.beans"
```

Full details, including the command-by-command dependency table, are in
[docs/INSTALL.md](docs/INSTALL.md).

### Full and slim packages

A **full** package bundles Clang, LLD and llvm-ar, so `beansc build` produces
native executables with nothing else installed. Full packages ship for Linux
x86-64 and ARM64 (GNU), and for Windows x64, ARM64 and x86 (LLVM-MinGW).

A **slim** package ships everywhere else — macOS, musl, and the less common
Linux and Windows ABIs. `beansc --version`, `doctor`, `check`, `run`, `llvm` and
`build --emit ir` need nothing but the package. A native `build` needs Clang on
your PATH, because Beans emits LLVM IR and GCC cannot compile it. When a tool is
missing, Beans says which one and how to install it instead of leaking a Clang or
linker error.

On macOS, native builds need Apple's Command Line Tools — Apple's SDK is not ours
to redistribute. `beansc check` and `beansc run` work without them:

```bash
xcode-select --install
```

Git is needed only to download Git-based package dependencies. Nothing else in
the toolchain requires Python, Node, jq or a package manager.

`beansc0` is the internal C++ stage-0 bootstrap. It is never installed, never
packaged, and never on your PATH.

### From source

Beans is self-hosted: the compiler is written in Beans, so building it from
source needs a Beans compiler. Install one first — that is what the one-line
installer above is for — then build with it.

```bash
sudo apt-get update && sudo apt-get install -y clang lld make git   # Debian/Ubuntu
curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh
git clone https://github.com/beans-lang/beans.git
cd beans
make
./build/beansc --version
./build/beansc run examples/hello.b
```

`make` compiles `compiler/beans/` with the `beansc` already on your PATH and
writes `build/beansc`. Point it somewhere else with
`make BEANSC_BOOT=/path/to/beansc`.

Test what you changed:

```bash
make test-core
```

To install the compiler under a prefix:

```bash
sudo make install PREFIX=/usr/local
```

### The stage-0 bootstrap

`beansc0` is a C++ compiler for Beans that exists only so the compiler can be
built on a machine that has no Beans at all. It is internal: never installed,
never packaged, never on your PATH, and not needed to build or test Beans.

It lives in a separate private repository, mounted here as the
`compiler/bootstrap` submodule. Without it everything above works. With it,
`make` runs the full stage 0 → 1 → 2 → 3 chain and `make test` adds the gates
that compare the two implementations against each other:

```bash
git submodule update --init compiler/bootstrap
make
make test
```

`compiler/version.h` is the one source of the compiler, language and runtime-ABI
versions, and stays in this repository so every checkout can read it.

To use the checkout's compiler directly, add its absolute `build` directory to
your PATH and keep the checkout in place — `build/beans_rt.c` and `stdlib/std/`
are part of that development installation.

The exact Windows/Linux host status is in
[`targets/support.tsv`](targets/support.tsv), checked by `make platform-status`.
The packages a complete release must contain are listed in
[`targets/release_assets.tsv`](targets/release_assets.tsv).

## Use

A first program, `hello.b`:

```
import std.io

fn main() {
    let name: string = "beans"
    io.println("hello from {name}")
}
```

Save that as `hello.b`. Check it, run it in the reference interpreter, or
compile it to a native binary:

```bash
beansc check hello.b
beansc run hello.b
beansc build hello.b -o hello
./hello
```

For an optimized native build:

```bash
beansc build --release --lto --cpu native hello.b -o hello
```

The subcommands:

| command | what it does |
|---|---|
| `beansc --version` | print compiler, language, and runtime ABI versions |
| `beansc doctor` | report what this installation can build, and how to fix what it cannot |
| `beansc lex file.b` | dump the token stream |
| `beansc parse file.b` | parse and print the AST |
| `beansc check file.b` | type-check; prints `ok` or `file:line:col: error: …` |
| `beansc run file.b` | check, then run on the reference interpreter |
| `beansc build file.b [-o out]` | compile to a native binary via LLVM |
| `beansc build --emit static --header api.h file.b` | build a C-facing Beans library |
| `beansc build --release --lto --cpu native file.b` | optimized native build |
| `beansc build --target <triple> file.b` | compile for another machine |
| `beansc bindgen header.h -o bindings.b` | generate Beans C declarations with Clang |
| `beansc mod tidy` | resolve used modules and write `beans.lock` |
| `beansc mod update [module]` | refresh all locked modules, or one module |

### Targets

`build` compiles for one selected target; the host is the default. Thirty
triples are registered — `beansc target <triple>` prints any one's layout and
capability facts. These include GNU and musl Linux hosts, seven Windows host
ABIs, WebAssembly, and bare-metal ARM/RISC-V. Portable decimal is available on
the hosted 32-bit Linux and Windows targets. Common alternate spellings,
including Rust's `riscv64gc-unknown-linux-musl`, normalize to the Clang triple.

The Rust-level Windows/Linux expansion is tracked separately in
[`docs/PLATFORM_SUPPORT.md`](docs/PLATFORM_SUPPORT.md). `make platform-status`
checks its 25-target manifest against both compilers and reports complete,
partial and missing host targets without treating compile-only support as done.

```bash
beansc build app.b                                          # the host
beansc target riscv64-unknown-linux-gnu                     # a target's facts
beansc build --target x86_64-unknown-linux-gnu --emit obj app.b -o app.o
beansc build --target aarch64-unknown-linux-gnu --sysroot /path/to/root app.b
beansc build --cpu x86-64-v3 --features +avx2,-sse4.2 app.b
```

| option | meaning |
|---|---|
| `--target <triple>` | target to compile for; default is the host |
| `--cpu <generic\|native\|name>` | CPU model; `native` needs a host build |
| `--features <+f,-f,...>` | enable or disable CPU features |
| `--sysroot <path>` | target sysroot for a cross link |
| `--cc <path>` | C driver, default `clang` |
| `--linker <name>` | passed through as `-fuse-ld=<name>` |
| `--emit <bin\|obj\|static\|shared\|ir>` | choose the output kind |
| `--ar <path>` | static archive tool, default `ar` |
| `--header <path>` | write a C header for exported library functions |
| `--locked` | require `beans.lock` to match `beans.pot` exactly |
| `--offline` | forbid network access and use verified cached dependencies |

A cross *compile* needs no target libraries, so `--emit obj` works without a
sysroot; only a cross *link* needs one. Every setting is checked before clang
runs, and tools are executed directly rather than through a shell. The
RISC-V Linux target is fixed to rv64gc/LP64D, so its `m`, `a`, `c`, `f` and `d`
baseline extensions cannot be disabled with `--features`.

`import std.target` reads the selected target's facts — `target.triple()`,
`target.arch()`, `target.os()`, `target.pointer_bits()`, `target.max_simd_bits()`
and friends — as compile-time constants.

`check` / `run` / `build` load the whole program: if a `beans.pot` sits next to
the file, every `.b` file in that directory joins the root package,
`import shop.util` pulls in `util/`, and `import github.com/owner/repo` resolves
the requested Git reference. `beansc mod tidy` writes the exact commit and Git
tree hash to `beans.lock`; dependencies are cached by commit under
`$BEANS_HOME/pkg`. `--locked` rejects drift, while `--offline` requires the
locked, hashed cache and never contacts the network. Git is started directly
with an argument vector; dependency paths never pass through a shell. No
`beans.pot` means a plain single file.
[examples/shop/](examples/shop/) is a working three-package program.

### Libraries

Declare a library project in `beans.pot`:

```text
module acme.math
kind library
```

A library has no `main`. `beansc build api.b` produces
`build/libmath.a` by default; `--emit shared` produces a `.dylib` or `.so`.
Add `--header math.h` to generate the matching C header for every
`pub extern "C"` export. A plain single file can also omit `main` when built
with explicit `--emit static` or `--emit shared`.

Beans-to-Beans libraries stay as source modules imported through `beans.pot`.
This keeps generics, classes, and ARC layouts on the same compiler/runtime ABI.
The static/shared artifact path is the stable C ABI path.

### Compatibility

The language, standard library, CLI, module and lock formats, and supported
runtime ABI follow SemVer. A breaking change needs a new major version. After
1.0, the current and previous minor release lines receive fixes. Git remains
the v1 dependency source; a central package registry is not required.

### Editor support

Syntax highlighting, live diagnostics, hover docs, and completion for **VS Code**
and **Zed** live in
[beans-lang/editors](https://github.com/beans-lang/editors) — thin editor
clients over the compiler's built-in language server (`beansc lsp`).

## Developing

```bash
make test              # interpreter/native differential suite
make test-sanitize     # ASan, TSan, and (macOS) leak checks
make test-linux        # the whole gate inside a Linux container
make test-bootstrap    # stage 2/stage 3 fixed point and no-stage0 workflow
make test-self-host-full # all locally available promotion gates
make bench-quick       # quick benchmark pass (not claim-eligible)
make bench-verify      # checksum + output-parity over every benchmark
make bench-full        # the full, claim-eligible benchmark run
make bench-profile NAME=trees
make stage0             # rebuild the C++ bootstrap compiler only
make test-self-host     # compare stage 0 and the self-hosted compiler
make bench-compiler     # frontend, MIR, LLVM, stdlib, large source and packages
```

### Linux in a container

`test/docker/linux.Dockerfile` builds one image with clang, lld, the ASan/TSan
runtimes, both Linux cross toolchains and `qemu-user-static`. The runner script
bind-mounts the repository **read-only** and copies it inside, so a Linux build
can never overwrite the host's `build/` directory with foreign objects.

The image carries the embedded target tools because Apple clang has no RISC-V
backend and ships no lld: `qemu-system-arm` and `qemu-system-riscv32` for the
boards, plus the two bare-metal GCC libraries. WebAssembly uses WASI SDK directly
through `BEANS_WASM_CC` and runs under `wasmtime`; `test/wasm.sh` also loads a
no-entry browser module through Node's standard `WebAssembly` API. Each target
test skips with a clear message when its toolchain is absent.

```bash
make test-linux                                  # host architecture
bash test/linux_docker.sh                        # the same thing
bash test/linux_docker.sh --build-only           # just build the image
bash test/linux_docker.sh --platform linux/amd64 # force x86-64
bash test/linux_docker.sh -- bash test/targets.sh  # one script
bash test/linux_docker.sh -- shell                 # interactive
```

Inside the container the gate is `make && make test && make test-sanitize &&
make access-score && bash test/cross_link.sh`.

A container whose platform does not match the host runs under emulation. The
script prints a banner saying so, and **emulated timings are never a performance
result** — the only native x86-64 numbers come from the Linux CI runner. On an
Apple-silicon host, `linux/arm64` is native and `linux/amd64` is emulated.

`test/cross_link.sh` is the other half of cross-compilation: `test/targets.sh`
proves a cross *compile* with `--emit obj`, and this links against a real target
sysroot and runs the result under `qemu-user`. It skips cleanly on a host without
a Linux cross libc, which is every macOS machine.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the architecture and contributor test loop.
The exact MIR coverage map is in
[docs/MIR_INVENTORY.md](docs/MIR_INVENTORY.md).

The interpreter is the reference implementation: exact `decimal` math, real OS threads for `thread.spawn`, real mutexes and blocking channels, `defer`, dynamic dispatch, and runtime panics with line numbers.

The low-level layer has started: `RawPtr<T>` can allocate and access primitive
scalar, raw-pointer, fixed-array, or nested `extern "C" struct`/`union` memory
inside an explicit `unsafe {}` block, including LLVM volatile
loads/stores and sequentially consistent raw integer atomics. Top-level
`extern "C" fn` declarations can call mixed integer, bool, raw-pointer,
floating-point, and C-layout aggregate functions in both backends, with no
argument-count limit — arguments past every register bank are handled by Clang. `Simd4f32` is a real inline
four-lane LLVM vector with arithmetic, reduction, and unaligned-safe raw
load/store. `[T; N]` is an inline fixed array for inline scalar, pointer, array,
and struct elements, and `Slice<T>` is an inline pointer/length view with
checked access over raw-compatible memory. `struct` values copy, pass, and return inline; `extern "C" struct`
uses target C field order and alignment and can be read or written through
`RawPtr` and `Slice`. `extern "C" union` adds overlapping scalar storage with
field access kept behind `unsafe`. Struct and union fields accept nested inline
values; infinite inline recursion is rejected. `extern "C"` accepts these
records by value in arguments and returns. Small generated C wrappers leave
the target-specific calling convention to Clang in native and interpreter
paths. Extern parameters can also take borrowed synchronous C callbacks made
from Beans closures or stored top-level functions. Callback values may cross
the ABI only for the duration of that call and on the same thread.
Imports can use `as "native_name"`, while body-bearing `pub extern "C"`
functions export stable C names. Opaque C structs stay behind `RawPtr`; C
globals, TLS, and hosted errno use generated C accessors. `RawPtr.with_local`
lends a scoped stack pointer. `StoredCallback` covers callbacks registered for
later or cross-thread use, with `Send + Sync` captures and an explicit
unregister then `close()` lifetime.

The native backend emits textual LLVM IR and hands it to clang — no LLVM library dependency. The C runtime lives in `runtime/beans_rt.c`, not inside the compiler binary. Development builds link a cached runtime object; `--release --lto` links cached runtime bitcode so LLVM can optimize across the boundary. `BEANS_RUNTIME` can point at another runtime source. The backend covers the whole language: classes (descriptor/vtable dispatch, inheritance, interface defaults, `override`, `as?`), monomorphized generics on classes *and* functions, enums + `match` (block-bodied arms included), Option/Result + `?`, exact-width integers and `f32`, exact `decimal`, lists and maps, closures (lambda-lifted, captured variables live in shared heap cells — mutation works, escaping works), real pthreads for `thread.spawn`/`Mutex`/`Channel`/`AtomicInt`, `defer`, string interpolation, and multi-package programs (symbols are package-qualified; cross-package calls, inheritance, generics, and interface dispatch all compile into one flat module). Every test file produces byte-identical output under `beansc build` and `beansc run` — panics included, same message, same exit code.

High-level standard-library code can now be written in Beans. The loader ships
packages from `stdlib/std/`; `std.collections`, `std.math`, `std.bytes`,
`std.path`, `std.fmt`, `std.fs`, `std.reader`, and the four
`std.encoding` packages are the first ones. Generic collection
`filter`/`transform`, inout Map increment/insert/merge/remove/map policies,
Option and Result combinators, `frequencies`, `unique`, `gcd`, `clamp_int`,
CRC32, unsigned varint append/encoding/decoding, path handling,
integer hex/binary/group formatting, high-level whole-file text/byte/write/copy
helpers, and buffered line reading are normal `.b` functions. Only their current
low-level storage operations remain native. The scored bytes workload calls the
Beans-written varint and CRC32 code, not the older native compatibility methods.
Set `BEANS_STDLIB` to use a
different shipped library root.

### Encoding

Four compiler-shipped packages cover the common wire formats:

```
import std.encoding.json      // yyjson 0.12.0 underneath (MIT)
import std.encoding.xml       // pugixml 1.16 underneath (MIT)
import std.encoding.base64    // simdutf 9.0.0 underneath (MIT)
import std.encoding.binary    // pure Beans over Bytes

let parsed: json.Value = json.parse("[1, \"two\"]")?
let cart: string = base64.encode(Bytes.from("beans"))
```

The public APIs are ordinary Beans — `Result` errors with kinds and byte
positions, classes and enums, no C types anywhere. The native halves are
vendored, pinned upstream releases (see
[runtime/encoding/vendor/VENDOR.md](runtime/encoding/vendor/VENDOR.md))
compiled into per-feature cached objects: importing JSON links yyjson and
nothing else, and a program with no encoding import gains no encoding code or
size. `beansc run` uses the same bridge sources through a cached per-host
library, so interpreter and native output stay byte-identical — and so does
the C++ stage 0, which needed no changes to support any of this. JSON and XML
are safe by default — strict RFC 8259 with explicit opt-in extensions, XML
DOCTYPE rejected by default, exactly one root element required, and no entity
expansion or network/file fetching ever. The full API and limits are in
[spec/SYNTAX.md](spec/SYNTAX.md).

Verified by executing the bridges' own smoke program on each target
(`bash test/encoding_targets.sh`): macOS arm64, Linux glibc on x86-64 and
ARM64, Alpine musl, and **big-endian s390x** under emulation. `wasm32-wasi`
compiles with a complete WASI SDK but has not been executed. **Windows is
not supported**: it has never been built or run there, and the C++ ABI shim
pugixml needs is written for the Itanium ABI, not MSVC's.

## Memory

Native binaries use automatic reference counting **plus a cycle collector** — no tracing GC, no pauses on the straight-line path. Every heap value carries a 16-byte header (atomic count + shape info); the compiler emits retains and releases at ownership boundaries and a generic destructor walks nested structures. String constants are immortal.

Reference cycles (`a.next = some(b); b.next = some(a)`) are caught by trial deletion (Bacon–Rajan, the Nim ORC family): a decrement that doesn't hit zero parks the object as a possible cycle root; when enough roots pile up, the collector trial-deletes each root's subgraph, restores anything still externally referenced, and frees the rest. It runs only between statements when no worker threads are live, and once more at exit. All walks are iterative — a 300k-node dropped ring is fine.

Verified with Apple's `leaks` tool: **0 leaked bytes** on every test program — including [examples/cycles.b](examples/cycles.b), which drops 400k cycle pairs, a self-cycle, a 300k ring, and a closure that captures its own cell. **2M dropped cycle pairs run in 1.4MB flat**, same as the acyclic stress test, and live rings survive collections untouched.

The design keeps RC off hot paths: function arguments, loop variables, and reads borrow instead of retaining. `move local` moves an owned value with compile-time use-after-move checks, and `return move local` transfers its last reference instead of retaining it. List, Map, OrderedMap, `Box<T>`, and the typed append-only `Arena<T>` are move-only outer handles; collections copy only through explicit `clone()`, and Arena values drop in bulk on `clear` or scope exit. `Shared<T>`/`Weak<T>` add an explicit atomic control block for cross-thread ownership without making local classes pay that cost. `Send`/`Sync` interface bounds are enforced, and `thread.spawn` rejects non-`Send` captures and returns. Pointer-valued `Option` uses a null niche in native code, while structs, fixed arrays, SIMD vectors, slices, and nested wide Options use an inline `{has_value, payload}` aggregate. A Result with a wide branch is also inline. Ordinary structs can own ARC fields. Typed-width List, Map-value, Box, Arena, Shared, Mutex, Channel, Thread-result, and user-enum payload storage keeps wide values and checked 32-byte decimals inline with ARC pointer masks. Map keeps its existing narrow fast path and uses a parallel buffer only for wide values. Wide value keys are boxed once when stored; lookup uses a stack copy and generated field-wise equality and hashing, so queries do not allocate. The compiler tracks nested references through copies, calls, captures, assignments, class nesting, collection operations, matches, and `?`. Inline Option/Result forms do not allocate their own aggregate box; user enums remain ARC values but keep wide payloads inline inside that allocation. The benchmark numbers below are measured *with* ARC and the collector enabled. Known limits: collection is deferred while worker threads run (a program that churns cycles forever while never letting its threads drain will grow until they do), nested move-only collection clones, consuming Map reads, and a `?` early-return that can hold mid-statement temporaries a little longer.

## Benchmarks

The benchmark harness compares safe Beans with both tuned C++ and C++ using
Beans-like ownership. It uses runtime inputs, fixed checksums, randomized run
order, cold-start separation, process CPU/RSS data, and raw JSON samples. Full
mode uses ten timing batches and at least ten measured seconds per target.
Rows above 3% variation are retried with longer batches; discarded attempts
remain in the JSON.

Beans does not have a claim-eligible 90% result yet. The older 103.4% number
came from a dirty tree and an older policy that allowed very slow individual
rows to hide behind group averages. It is historical data, not the current
claim.

The first stricter Phase 0 development baseline on an Apple M1 scored 98.7%
overall and used 1.16x tuned-C++ peak memory, but it correctly failed the goal:
the tree was dirty, the application group was just under 80%, and five rows
were below the 75% floor. Deep teardown was 26.9%, Option-heavy chains 37.9%,
exact Decimal arithmetic 49.3%, the mixed allocation application 55.1%, and
slices 72.1%. UTF-8 rose above C++ after its baseline was fixed to perform the
same validation, and the tuned strings baseline now materializes the same split
result as Beans. The generated report contains every median, CV, group score,
memory result, compile time, binary size, and semantic comparison label.

`make bench-verify` builds every target and enforces fixed checksum and
byte-output parity. `make bench-quick` is useful during development but is
never claim-eligible. A claim also requires a clean tree, every scored target
below 3% CV, every workload at 75% or better, every group at 80% or better,
and peak memory at or below 1.25x tuned C++. The exact limits live in
`bench/policy.tsv`.

Performance changes use two complete runs on the same machine:

```
make bench-full BENCH_RUN=before
# make one performance change, then run the full correctness suite
make test
make bench-full BENCH_RUN=after
make bench-compare BEFORE=before AFTER=after EXPECT=affected_workload
```

The comparator rejects a changed suite, policy, machine, compiler flags,
inputs, outputs, workload set, or noisy result. It prints all workloads and
checks every row against its own Beans before/after time. Group and overall
gates stay normalized to tuned C++, and reference-only shifts are printed as
warnings. This keeps a C++ timing outlier from hiding a Beans slowdown or
turning a faster Beans binary into a false regression. It also checks overall
memory. Timed runs without a name write `bench/report.md`; named runs stay
under `build/bench/`.
The suite hash covers only workload sources, shared C++ workload headers, and
`suite.tsv`; harness code and the separately hashed policy do not change the
workload contract.
If a row is noisy, the full runner repeats all three scored targets with
successively longer batches. The retry limit is part of `bench/policy.tsv`;
the 3% CV gate is never relaxed.

`make access-score` runs the tests behind the 100-point systems-access
scorecard in `test/access_scorecard.tsv`. Planned features score zero until
their executable test passes.

`kv_store` measures the append/restart/compact algorithm in memory so storage
hardware does not enter the compiler score. File and mmap tests belong in the
systems report. C++ has no cycle collector, so the cycle baselines explicitly
break their test cycles; the report keeps that difference visible.

Errors print as `file:line:col: error: message`; the parser recovers and keeps going so you see many errors at once.

## License

Beans is licensed under the [Apache License 2.0](LICENSE).
