# beans

A small OOP language: Java-style objects, Go-sized grammar, predictable
ownership, native systems access, and C++-class performance as a goal. Files
end in `.b`.

- [spec/SYNTAX.md](spec/SYNTAX.md) — the 1.0 candidate language contract
- [examples/](examples/) — real `.b` programs
- [src/](src/) — the self-hosted compiler
- [stdlib/std/](stdlib/std/) — compiler-shipped standard library packages
- [docs/REFLECTION.md](docs/REFLECTION.md) — typed runtime reflection and safety rules
- [docs/RUNTIME_HOOKS.md](docs/RUNTIME_HOOKS.md) — active annotations and app lifecycle
- [docs/STD_LOG.md](docs/STD_LOG.md) — asynchronous structured logging
- [docs/JSON_STRUCT_DECODING.md](docs/JSON_STRUCT_DECODING.md) — typed JSON structs
- [docs/XML_STRUCT_DECODING.md](docs/XML_STRUCT_DECODING.md) — direct typed XML decoding
- [docs/ZERO_COPY_WORK.md](docs/ZERO_COPY_WORK.md) — copy removal rules and measured results

## Status

The latest release is **v0.1.28**. It carries language contract `1.0` and runtime
ABI `8` while the project finishes the evidence needed for a production 1.0
claim.

| piece | current state |
|---|---|
| language | 1.0 candidate; grammar and semantics are specified |
| compiler | self-hosted `beansc`; stage 2 and stage 3 build a byte-identical compiler |
| frontend | whole-program loader, resolver, generic type checker, typed annotations, runtime hooks and reflection, typed JSON/XML lowering, HIR, checked MIR and ownership verification |
| native backend | MIR-to-textual-LLVM emitter, debug/release/LTO builds, ARC plus cycle collection |
| interpreter | reference executor with the same checked program and runtime behaviour as native builds |
| concurrency | native threads, typed atomics, mutexes, channels, structured async/await and readiness waits |
| modules | canonical package identity, hashed `beans.lock`, locked/offline builds and a content-addressed Git cache |
| C interop | imports and exports, C headers, bindgen, C layouts, globals/TLS/errno, typed and stored callbacks |
| tooling | semantic LSP, interpreter DAP debugger, native debug artifacts and parser recovery for live edits |
| reflection | checked type/member discovery, runtime annotations, dynamic values, field access, calls and construction through `std.reflect` |
| encoding | strict DOM APIs, generated JSON encode/decode, and generated XML decode for nested structs, lists, options, field annotations and XML namespaces |
| logging | asynchronous default and named loggers, level filters, structured fields, file rotation, NDJSON and bounded export sinks through `std.log` |
| systems access | files, mappings, processes, sockets, DNS, polling, signals, shared memory, dynamic libraries, SIMD and intrinsics, HTTP/1.1 and HTTP/2, WebSocket, TLS, compression and platform hashes |

The release workflow builds and install-tests all 26 required host packages and
publishes checksums, an SPDX SBOM and GitHub attestations. That is release
engineering evidence, not yet a general production-ready claim: clean
performance floors, the long fuzz run and the public beta/RC soak are still
open in [ROADMAP.md](ROADMAP.md).

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
curl -fsSL .../beans-install.sh | sh -s -- --version 0.1.28 --prefix /opt/beans
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

An archive proves that the compiler was built and smoke-tested for that target;
it does not by itself make the target production tier. Native program,
self-host and archive status are tracked separately in
[`targets/support.tsv`](targets/support.tsv).

On macOS, native builds need Apple's Command Line Tools — Apple's SDK is not ours
to redistribute. `beansc check` and `beansc run` work without them:

```bash
xcode-select --install
```

Git is needed only to download Git-based package dependencies. Nothing else in
the toolchain requires Python, Node, jq or a package manager.

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

`make` compiles `src/` with the `beansc` already on your PATH and
writes `build/beansc`. Point it somewhere else with
`make BEANSC_BOOT=/path/to/beansc`.

`src/` uses `partial class`, so the compiler you build with must be new enough
to have it. `make` says so in one line if yours is not; build once with a
newer `beansc` and `make install` to clear it.

Test what you changed:

```bash
make test-core
```

To install the compiler under a prefix:

```bash
sudo make install PREFIX=/usr/local
```

`VERSION` is the one source of the compiler, language and runtime-ABI
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

A plain `beansc build` runs no optimizer (`-O0`), because the loop it belongs to
is edit, build, run, and most of a build is the optimizer. For an optimized
native build, ask for one:

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
| `beansc mir file.b` | print the checked, ownership-planned MIR |
| `beansc llvm file.b` | print the LLVM IR used by native builds |
| `beansc run file.b` | check, then run on the reference interpreter |
| `beansc build file.b [-o out]` | compile to a native binary via LLVM, unoptimized (`-O0`) for a fast loop |
| `beansc build --emit static --header api.h file.b` | build a C-facing Beans library |
| `beansc build --release --lto --cpu native file.b` | optimized native build |
| `beansc build --debug file.b -o out` | unoptimized native build with platform debug information |
| `beansc build --target <triple> file.b` | compile for another machine |
| `beansc target <triple>` | print one target's layout and capability facts |
| `beansc lsp` | language server on stdio |
| `beansc debug-adapter` | debug adapter (DAP) on stdio |
| `beansc bindgen header.h... -o bindings.b [--pub]` | generate Beans C declarations with Clang |
| `beansc pot init <module-name>` | create `beans.pot` in the current directory |
| `beansc pot add <dependency> [ref]` | add a Git dependency; `owner/repo` means GitHub and the ref defaults to `HEAD` |
| `beansc pot add --system <pkg-config-name>` | add linker rows for an installed C library |
| `beansc pot tidy` | resolve used dependencies and write `beans.lock` |
| `beansc pot remove <dependency>` | remove a Git dependency and tidy `beans.lock` |
| `beansc pot remove --system <pkg-config-name>` | remove generated linker rows for a C library |
| `beansc pot update [dependency]` | refresh all locked dependencies, or one dependency |
| `beansc pot update --system <pkg-config-name>` | refresh a generated C-library link block from pkg-config |
| `beansc upgrade` | upgrade this Beans installation to the latest release |

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
the requested Git reference. Every file in a package starts with a `package`
clause — `package main` in an application's root, a normal name elsewhere.
A package's **identity** is its whole import path, so `shop.a.cart` and
`shop.b.cart` can both call themselves `cart` and still be two different
packages; a declared name and an `as` alias are source-facing only, and an
alias binds in the one file that wrote it. Import cycles are refused with the
whole chain of import sites. `beansc pot add acme/http v1.2` adds
`github.com/acme/http`; full host paths and Git URLs work too. `pot remove`
removes a dependency, `pot tidy` resolves the dependencies the code uses, and
`pot update` refreshes locked commits. The exact commit and Git tree hash go in
`beans.lock`; dependencies are cached by commit under `$BEANS_HOME/pkg`.
`--locked` rejects drift, while `--offline` requires the locked, hashed cache
and never contacts the network. Git is started directly with an argument
vector; dependency paths never pass through a shell. No `beans.pot` means a
plain single file.
For local development, `require path "../module"` imports the target's declared
module name without adding a lock row. Manifest `#` and `//` comments work
outside quoted values. Native `link` rows propagate from local and git
dependencies; both `build` and `run` honor them.
`beansc pot add --system sqlite3` asks `pkg-config` for an installed C
library's search paths and library names, then writes a marked `link` block.
`pot remove --system sqlite3` removes that block. System libraries are owned by
the host package manager and do not enter `beans.lock`.
[examples/shop/](examples/shop/) is a working three-package program.

### Libraries

Declare a library project in `beans.pot`:

```text
module acme.math
kind library
```

A library root has no `main`. An application under `examples/` or `tests/` can
run in place and import the library by module name. `beansc build api.b` produces
`build/libmath.a` by default; `--emit shared` produces a `.dylib` or `.so`.
Add `--header math.h` to generate the matching C header for every
`pub extern "C"` export. A plain single file can also omit `main` when built
with explicit `--emit static` or `--emit shared`.

Beans-to-Beans libraries stay as source modules imported through `beans.pot`.
This keeps generics, classes, and ARC layouts on the same compiler/runtime ABI.
The static/shared artifact path is the stable C ABI path.

### C headers and bindgen

`beansc bindgen` asks the selected Clang target for the real C scalar widths,
enum representation, linkage and declaration layout. It resolves typedefs and
callback types from included headers, keeps nested function pointers typed as
`CFunctionPtr<F>`, and emits declarations from every requested header in one
shared type universe. `--pub` makes generated records, constants, globals, and
functions usable by another Beans package. The generated file is checked like
normal Beans source:

```bash
beansc bindgen vendor/api.h -o api_bindings.b --package main -- -Ivendor/include
beansc bindgen vendor/core.h vendor/service.h -o api_bindings.b --package api --pub
beansc bindgen --system sqlite3 sqlite3.h -o sqlite3_bindings.b --package main --only sqlite3_open --only sqlite3_close
beansc check api_bindings.b
```

Strict mode refuses declarations whose ABI Beans cannot reproduce, including
varargs, flexible arrays, bitfields, anonymous records, non-default calling
conventions and callbacks wider than the supported bridge. Use
`--allow-unsupported` to omit each unsafe declaration and anything that depends
on it while keeping the safe part of a large header. This mode produces usable,
type-checked bindings for the supported parts of SQLite, zlib and curl; it does
not pretend to bind their unsupported C surface.

### Compatibility

Beans follows SemVer. Before 1.0, the language, standard library, CLI, module
format and ABI may still change between minor releases; pin the compiler and
`beans.lock` for serious projects. The runtime ABI number changes whenever
generated code and the shipped runtime stop being compatible. After 1.0, a
breaking public change needs a new major version and the current and previous
minor release lines receive fixes. Git remains the v1 dependency source; a
central package registry is not required.

### Editor support

Editor integrations for **VS Code** and **Zed** live in
[beans-lang/editors](https://github.com/beans-lang/editors). They are thin
clients: every answer comes from the compiler.

`beansc lsp` is the language server. It keeps one checked view of the project
and answers from it, so a position becomes an exact symbol rather than a name
that happens to match. It provides diagnostics, completion (including members
of the receiver's real type, built-in receivers included), hover, signature
help, go to definition, declaration, implementation and type definition,
references, document highlights, document and workspace symbols, call and type
hierarchy, semantic tokens, and rename. Two same-named methods on two
same-named types in two packages stay two different symbols, so a rename never
reaches past the one you meant — and a rename that *would* rebind something
else, such as a local taking a name already in scope, is refused with a reason
rather than applied.

Renaming a member checks the whole hierarchy it sits in, not just the part
above it. A base member cannot take a name a subtype already declares, however
many levels down it is: for a method the subtype would start hiding it, and
for a field the two would quietly share one slot and the base would read the
child's value. A method that is part of an override family — an interface or
base declaration and every implementation of it — is renamed as one family,
from whichever end you start, because a virtual name belongs to all of them.

`$/cancelRequest` is accepted and ignored: the server answers strictly in
order, so a cancellation always arrives after its request was answered.

`beansc debug-adapter` is the debugger. It speaks the Debug Adapter Protocol on
stdio and runs your program with the reference interpreter, so there is no
build step: breakpoints are Beans file and line positions, frames name Beans
functions, and locals come from the interpreter's own frames with the binding
ids the checker allocated — a shadowed local stays two separate variables.

### Debugging

```bash
beansc debug-adapter         # what an editor starts; DAP over stdio
```

Press F5 in VS Code on a `.b` file. You get breakpoints, stop-on-entry, a Beans
call stack, `self`/parameters/locals, paging through large lists, maps and
objects, watch expressions over variable paths, step over/into/out, continue,
and a stop on a runtime panic with the stack still standing.

**Native debugging is a different thing and is not available yet.** `beansc
build --debug` gives an unoptimized binary (`-O0`, frame pointers kept, LTO
off) carrying the platform's debug information — DWARF on macOS and Linux,
CodeView where the toolchain targets MSVC — for the Beans C runtime. That makes
a native backtrace, a crash report or a profiler readable, and it is the
foundation a native debugger needs. It is not Beans source-level debugging: the
LLVM emitter writes no line table for Beans statements, so lldb and gdb cannot
stop on a Beans line. `test/native_debug.sh` asserts that boundary and fails if
the emitter starts writing debug metadata, so this paragraph cannot go stale
without someone noticing.

## Developing

```bash
make test              # interpreter/native differential suite
make test-quick        # fast developer gate
make test-linux        # the whole gate inside a Linux container
make test-self-host-full # all locally available promotion gates
make test-ffi          # layouts, C ABI, bindgen, callbacks and library output
make access-score      # executable systems-access scorecard
make fuzz-oop-smoke    # generated OOP shapes, exact errors, interpreter/debug
make fuzz-oop          # OOP interpreter/debug/release/LTO comparison
make fuzz-oop-long     # 1,000 structural OOP cases; tune with OOP_FUZZ_CASES
make bench-quick       # quick benchmark pass (not claim-eligible)
make bench-verify      # checksum + output-parity over every benchmark
make bench-full        # the full, claim-eligible benchmark run
make bench-abstractions-quick # paired Beans abstraction checks
make bench-abstractions       # full paired abstraction proof run
make bench-profile NAME=trees
make test-self-host     # the fixed point: the compiler rebuilt by itself
make bench-compiler     # frontend, MIR, LLVM, stdlib, large source and packages
```

OOP fuzz failures are saved under `build/oop-fuzz/failures/` with their source,
lane output, and a `replay.txt` command. `OOP_FUZZ_SEED`, `OOP_FUZZ_START`,
`OOP_FUZZ_CASES`, and `OOP_FUZZ_LANES` can also select a run by hand.

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

The low-level layer includes `RawPtr<T>`, which can allocate and access primitive
scalar, raw-pointer, fixed-array, or nested `extern "C" struct`/`union` memory
inside an explicit `unsafe {}` block, including LLVM volatile
loads/stores and sequentially consistent raw integer atomics. Top-level
`extern "C" fn` declarations can call mixed integer, bool, raw-pointer,
floating-point, and C-layout aggregate functions in both backends, with no
argument-count limit — arguments past every register bank are handled by Clang. `Simd4f32` is a real inline
four-lane LLVM vector with arithmetic, reduction, and unaligned-safe raw
load/store. `[T; N]` is an inline fixed array for inline scalar, pointer, array,
and struct elements, and `Slice<T>` is an inline pointer/length view with
checked access over raw-compatible memory. `struct` values copy, pass, and return inline; ordinary structs support generics, methods, and mutating `inout fn` methods. `extern "C" struct`
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

The native backend emits textual LLVM IR and hands it to clang — no LLVM library dependency. The C runtime lives in `runtime/beans_rt.c`, not inside the compiler binary. Development builds link a cached runtime object; `--release --lto` links cached runtime bitcode so LLVM can optimize across the boundary. `BEANS_RUNTIME` can point at another runtime source. The backend covers the whole language: classes (descriptor/vtable dispatch, inheritance, interface defaults, abstract classes, singleton instances, static fields, `override`, `as?`), monomorphized generics on classes, structs, and functions, enums + `match` (block-bodied arms included), Option/Result + `?`, exact-width integers and `f32`, exact `decimal`, lists and maps, closures (lambda-lifted, captured variables live in shared heap cells — mutation works, escaping works), real pthreads for `thread.spawn`/`Mutex`/`Channel`/`AtomicInt`, `defer`, string interpolation, and multi-package programs (every symbol carries its package's whole import path, so two packages with the same name never collide; cross-package calls, inheritance, generics, and interface dispatch all compile into one flat module). Every test file produces byte-identical output under `beansc build` and `beansc run` — panics included, same message, same exit code.

High-level standard-library policy is written in Beans. The loader ships
packages from `stdlib/std/`; `std.collections`, `std.math`, `std.bytes`,
`std.path`, `std.fmt`, `std.fs`, `std.reader`, and the four
`std.encoding` packages cover collections, formatting, files and common wire
formats. `std.log` adds asynchronous structured logging and export sinks. Generic collection
`filter`/`transform`, inout Map increment/insert/merge/remove/map policies,
Option and Result combinators, `frequencies`, `unique`, `gcd`, `clamp`,
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
let order: Order = json.decode(json_text)?
let order_text: string = json.encode(order)?
// Native encode makes only the returned string; it does not build a second
// full-size Bytes result and copy it afterward.
let cart: string = base64.encode(Bytes.from("beans"))
```

The public APIs are ordinary Beans — `Result` errors with kinds and byte
positions, classes and enums, no C types anywhere. The native halves are
vendored, pinned upstream releases (see
[runtime/encoding/vendor/VENDOR.md](runtime/encoding/vendor/VENDOR.md))
compiled into per-feature cached objects: importing JSON links yyjson and
nothing else, and a program with no encoding import gains no encoding code or
size. `beansc run` uses the same bridge sources through a cached per-host
library, so interpreter and native output stay byte-identical. JSON and XML
are safe by default — strict RFC 8259 with explicit opt-in extensions, XML
DOCTYPE rejected by default, exactly one root element required, and no entity
expansion or network/file fetching ever. Generated `json.encode<T>`,
`json.decode<T>`, and `xml.decode<T>` paths map nested structs, lists, and options directly without
public DOM wrappers or runtime reflection. XML mappings can match namespace
URIs independently of source prefixes. The full API and limits are in
[spec/SYNTAX.md](spec/SYNTAX.md).

Verified by executing the bridges' own smoke program on each target
(`bash test/encoding_targets.sh`): macOS arm64, Linux glibc on x86-64 and
ARM64, Alpine musl on both, and **big-endian s390x** under emulation, where
`std.encoding.binary`'s own golden also runs. Windows is covered by
`make test-encoding-windows` locally — every bridge compiles with the
Windows toolchain and all four packages cross-build for the GNU, GNullVM,
32-bit and ARM64 ABIs — and CI's `windows-native` job builds and runs the
same cases on real `windows-latest` and `windows-11-arm` machines.
`wasm32-wasi` compiles with a complete WASI SDK but has not been executed.

### Logging

`std.log` is an asynchronous structured logger backed by the pinned Quill
12.1.0 C++17 engine. The default logger writes `info` and above to stderr.
Named loggers can fan one record out to console, plain file, size-rotating
file, NDJSON and bounded pull-based export sinks. Short level calls preserve
the Beans source file, function, line and column in interpreted and native
programs.

```beans
import std.log

fn start() -> Result<bool> {
    let output: log.Sink = log.Sink.json_file("service.ndjson")?
    let logger: log.Logger = log.Logger.create_with_level(
        "service", [log.Sink.console()?, output], log.Level.debug)?

    logger.info("ready")
    logger.log_fields(
        log.Level.info, "request complete",
        [new log.Field("request_id", "42")])?
    logger.flush()?
    return ok(true)
}
```

Disabled `trace` through `fatal` short calls skip their message expression.
Writes return `false` if their level is disabled or the fixed producer queue is
full. Producer and export-sink drops have separate counters. Export consumers
pull safe Beans `Record` batches and may move an `ExportReader` to a worker;
Beans callbacks never run on Quill's backend thread. Programs that do not
import `std.log` link no Quill code. The full API, overload rules, examples,
current limits, vendor record and benchmark commands are in
[docs/STD_LOG.md](docs/STD_LOG.md).

## Memory

Native binaries use automatic reference counting **plus a cycle collector** — no tracing GC, no pauses on the straight-line path. Every heap value carries a 16-byte header (atomic count + shape info); the compiler emits retains and releases at ownership boundaries and a generic destructor walks nested structures. String constants are immortal.

Reference cycles (`a.next = some(b); b.next = some(a)`) are caught by trial deletion (Bacon–Rajan, the Nim ORC family): a decrement that doesn't hit zero parks the object as a possible cycle root; when enough roots pile up, the collector trial-deletes each root's subgraph, restores anything still externally referenced, and frees the rest. Once threads start, every Beans thread collects its own candidates at allocation boundaries. It never stops or polls another worker. Capture cells and graphs that reach `Mutex`, `Channel`, or another shared boundary move to the global fallback, which runs only after the workers drain. All walks are iterative — a 300k-node dropped ring is fine.

Verified with Apple's `leaks` tool: **0 leaked bytes** on every test program — including [examples/cycles.b](examples/cycles.b), which drops 400k cycle pairs, a self-cycle, a 300k ring, and a closure that captures its own cell. **2M dropped cycle pairs run in 1.4MB flat**, same as the acyclic stress test, and live rings survive collections untouched.

The design keeps RC off hot paths: function arguments, loop variables, and reads borrow instead of retaining. `move local` moves an owned value with compile-time use-after-move checks, and `return move local` transfers its last reference instead of retaining it. List, Map, OrderedMap, `Box<T>`, and the typed append-only `Arena<T>` are move-only outer handles; collections copy only through explicit `clone()`, and Arena values drop in bulk on `clear` or scope exit. `Shared<T>`/`Weak<T>` add an explicit atomic control block for cross-thread ownership without making local classes pay that cost. `Send`/`Sync` interface bounds are enforced, and `thread.spawn` rejects non-`Send` captures and returns. Pointer-valued `Option` uses a null niche in native code, while structs, fixed arrays, SIMD vectors, slices, and nested wide Options use an inline `{has_value, payload}` aggregate. A Result with a wide branch is also inline. Ordinary structs can own ARC fields. Typed-width List, Map-value, Box, Arena, Shared, Mutex, Channel, Thread-result, and user-enum payload storage keeps wide values and checked 32-byte decimals inline with ARC pointer masks. Map keeps its existing narrow fast path and uses a parallel buffer only for wide values. Wide value keys are boxed once when stored; lookup uses a stack copy and generated field-wise equality and hashing, so queries do not allocate. The compiler tracks nested references through copies, calls, captures, assignments, class nesting, collection operations, matches, and `?`. Inline Option/Result forms do not allocate their own aggregate box; user enums remain ARC values but keep wide payloads inline inside that allocation. The benchmark numbers below are measured *with* ARC and the collector enabled. Known limits: an unreachable cycle that crosses a shared synchronization boundary waits for global thread quiescence, nested move-only collection clones, consuming Map reads, and a `?` early-return can hold mid-statement temporaries a little longer. Use `Weak<T>` to break long-lived shared ownership cycles.

## Benchmarks

The benchmark harness compares safe Beans with both tuned C++ and C++ using
Beans-like ownership. It uses runtime inputs, fixed checksums, randomized run
order, cold-start separation, process CPU/RSS data, and raw JSON samples. Full
mode uses ten timing batches and at least ten measured seconds per target.
Rows above 3% variation are retried with longer batches; discarded attempts
remain in the JSON.

`make bench-verify` currently builds all 39 workloads and checks their fixed
outputs against the C++ references. Beans does not yet have a current,
claim-eligible performance result on both required machines. Old development
numbers are not a release claim; the next accepted result must come from clean
`bench-full` runs on native Linux x86-64 and macOS arm64.

`make bench-verify` is a correctness gate, not a timing result.
`make bench-quick` is useful during development but is
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
```

`make bench-verify` rejects a changed suite, policy, machine, compiler flags,
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
