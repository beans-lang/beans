# Beans

Beans is a compiled language for backend services and business systems. It
builds native binaries through LLVM, manages memory with reference counting
instead of a tracing GC, and has no null and no exceptions. The compiler,
`beansc`, is written in Beans.

[Documentation](https://beans-lang.github.io/docs/) ·
[Releases](https://github.com/beans-lang/beans/releases) ·
[Examples](examples/) ·
[Contributing](CONTRIBUTING.md)

### A web API with [Espresso](https://github.com/beans-lang/espresso)

Controllers, constructor injection, model binding, and middleware, served by a
non-blocking HTTP/1.1 event loop on fibers.

```beans
import github.com/beans-lang/espresso

@espresso.controller(route: "/hello")
pub class HelloController extends espresso.Controller {
    pub fn init() {}

    @espresso.get(route: r"/{name}")
    pub fn hello(@espresso.route name: string) ->
        Result<espresso.ActionResult> {
        return self.ok_text("Hello, {name}!")
    }
}

fn main() {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_controllers(builder).expect("controllers")
    let app: espresso.WebApplication = builder.build().expect("app")
    espresso.map_controllers(app).expect("map")

    let server: espresso.WebServer = espresso.WebServer.bind(
        app, new espresso.ServerOptions()).expect("bind")
    server.run().expect("run")
}
```

### A live UI with [Latte](https://github.com/beans-lang/latte)

Components are `.bx` files: markup with Beans in it. The server keeps state and
streams DOM edits over a WebSocket. Add `render:mode="client"` and the same
component runs in the browser as WebAssembly.

```html
<beans>
package site

import {param} from latte

pub partial class Counter extends Component {
    @param pub label: string = "count"
    @param pub start: int = 0
    pub clicks: int = 0

    pub fn total() -> int { return self.start + self.clicks }
}
</beans>

<section class="counter">
  <output>$self.label = $self.total()</output>
  <button on:click={fn(e: MouseEvent) { self.clicks += 1 }}>add one</button>
</section>
```

### Errors are values, checked at compile time

A function that can fail returns `Result`. You handle it with `match` or pass
it up with `?`. Using it as a plain value does not compile.

```beans
import std.io

fn parse_qty(text: string) -> Result<int> {
    let qty: int = text.to_int()?
    if qty <= 0 {
        return err("quantity must be positive, got {qty}")
    }
    return ok(qty)
}

fn main() {
    match parse_qty("abc") {
        ok(qty) => { io.println("qty {qty}") }
        err(e) => { io.println("rejected: {e}") }  // can't read 'abc' as int
    }
    let qty: int = parse_qty("5")  // error: expected int, got Result<int>
}
```

## Why Beans

- **Native speed, predictable memory.** LLVM native code. Reference counting
  with a cycle collector, so no stop-the-world GC pauses. `move`, `Shared<T>`,
  and `Weak<T>` when you need control over ownership.
- **Safe by default.** No null: absence is `Option`. No exceptions: failure is
  `Result`. Raw memory and pointers only inside `unsafe` blocks.
- **Concurrency built in.** Fibers, threads, channels, mutexes, and typed atomics.
- **Exact `decimal` arithmetic** for money, alongside fixed-width ints and floats.
- **C interop.** Import C headers, generate bindings, export C functions.
- **Two engines, one language.** `beansc run` interprets for fast iteration.
  `beansc build` makes the native binary. The test suite checks that both give
  the same output, and that the compiler rebuilds itself byte for byte.
- **Measured against C++.** The [benchmark suite](bench/README.md) runs every
  workload against tuned C++ references, with fixed checksums and a strict
  variance policy.

## Ecosystem

- [Espresso](https://github.com/beans-lang/espresso): web APIs with DI, middleware, routing, and OpenAPI.
- [Latte](https://github.com/beans-lang/latte): server-rendered UI components, or WebAssembly in the browser.
- [Cortado](https://github.com/beans-lang/cortado): native desktop apps on AppKit, UIKit, GTK4, and Win32.
- Database drivers: [PostgreSQL](https://github.com/beans-lang/postgres),
  [MySQL](https://github.com/beans-lang/mysql), [SQLite](https://github.com/beans-lang/sqlite),
  and [Redis](https://github.com/beans-lang/redis).
- Packages install with `pot`. Editor support for [VS Code and Zed](https://github.com/beans-lang/editors).

If Beans looks useful, a star helps other people find it.

## Install

macOS and Linux:

```bash
curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://github.com/beans-lang/beans/releases/latest/download/beans-install.ps1 | iex
```

Open a new terminal and check the installation:

```bash
beansc --version
beansc doctor
```

Full packages include Clang and the tools needed for native builds. They are
available for GNU Linux on x86-64 and ARM64, and Windows with LLVM-MinGW on x64,
ARM64, and x86. Other hosts use slim packages, which need a separate Clang
installation for native builds.

On macOS, install Apple's Command Line Tools to build native programs:

```bash
xcode-select --install
```

`beansc check` and `beansc run` work without these tools for programs that do not
use C interop. See the [installation guide](docs/INSTALL.md) for package options,
manual downloads, upgrades, and other dependencies.

## Run a program

Save this as `hello.b`:

```beans
import std.io

fn main() {
    let name: string = "beans"
    io.println("hello from {name}")
}
```

Check it and run it in the interpreter:

```bash
beansc check hello.b
beansc run hello.b
```

Build and run a native executable:

```bash
beansc build hello.b -o hello
./hello
```

For an optimized build:

```bash
beansc build --release --lto --cpu native hello.b -o hello
```

Use `beansc build --debug hello.b -o hello` for native debugging with LLDB or GDB.
[VS Code and Zed integrations](https://github.com/beans-lang/editors) provide
language server support and an interpreter debugger.

## Language features

- Functions, closures, generics, structs, enums, classes, and interfaces.
- Pattern matching, `Option`, `Result`, and `?` for error propagation.
- Fixed-width integers, floating-point numbers, and checked decimal arithmetic.
- Automatic reference counting with cycle collection, plus explicit `move`,
  `Shared<T>`, and `Weak<T>` for ownership.
- Threads, fibers, channels, mutexes, and typed atomics.
- C imports and exports, bindings generated from C headers, and raw memory access
  inside `unsafe` blocks.

The [standard library](stdlib/std/) includes collections, file and network I/O,
JSON and XML, compression, and structured logging. The
[language specification](spec/SYNTAX.md) defines the syntax, behavior, and limits.

## Status

The latest release is **v0.1.52**. It carries language contract `1.0` and runtime
ABI `22`.

Beans is pre-1.0. The language, standard library, command-line tools, module
format, and ABI may still change between minor releases. Pin the compiler
version and `beans.lock` when a project needs consistent builds.

Production readiness checks, including performance testing, long fuzz runs, and
beta/RC testing, are still open. The first dependability pilot is a small
file-to-SQLite command-line tool on macOS ARM64 or GNU Linux x86-64; independent
user acceptance is still pending. See the
[pilot checklist](CONTRIBUTING.md#dependability-pilot) and
[changelog](CHANGELOG.md).

Compiler, native program, and package support vary by target. Check the
[platform guide](docs/PLATFORM_SUPPORT.md) and
[target support table](targets/support.tsv) for their separate status. Libraries
may support fewer targets than the compiler.

## Documentation

- [User guide and API reference](https://beans-lang.github.io/docs/)
- [Language specification](spec/SYNTAX.md)
- [Example programs](examples/), including a [multi-package project](examples/shop/)
- [Compiler development](docs/COMPILER_DEV.md) and [MIR coverage](docs/MIR_INVENTORY.md)
- [Reflection](docs/REFLECTION.md) and [runtime hooks](docs/RUNTIME_HOOKS.md)
- [Typed JSON](docs/JSON_STRUCT_DECODING.md), [typed XML](docs/XML_STRUCT_DECODING.md),
  and [logging](docs/STD_LOG.md)
- [Copy removal work](docs/ZERO_COPY_WORK.md) and [benchmarks](bench/README.md)

## From source

Install a released Beans compiler, Clang, Make, and Git first. Then:

```bash
git clone https://github.com/beans-lang/beans.git
cd beans
make
./build/beansc --version
./build/beansc run examples/hello.b
```

`make` uses the `beansc` on your PATH and writes `build/beansc`. Use
`make BEANSC_BOOT=/path/to/beansc` to choose another compiler. The build checks
that the bootstrap compiler supports the language features used in `src/`.

This checkout reports compiler `0.1.52` and runtime ABI `22`.
[VERSION](VERSION) defines the compiler, language, and runtime ABI versions.

## Developing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the project layout and test guidance.

```bash
make test-core
make test
```

`test-core` runs the behavior tests. `test` also compares interpreter and native
execution and checks that the compiler can rebuild itself byte for byte.

Report bugs through [GitHub issues](https://github.com/beans-lang/beans/issues).
Include a small program that shows the problem and the output of
`beansc --version`.

## License

Beans is licensed under the [Apache License 2.0](LICENSE).
