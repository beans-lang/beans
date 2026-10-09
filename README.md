# Beans

Beans is a programming language for business apps and systems work. Run a
script, or ship a native binary. Money math is exact.

```beans
import std.io

fn main() {
    let a: float = 0.1
    let b: float = 0.2
    io.println("float:   {a + b}")    // 0.30000000000000004

    let x: decimal = 0.1
    let y: decimal = 0.2
    io.println("decimal: {x + y}")    // 0.3
}
```

[Documentation](https://beans-lang.github.io/docs/) ·
[Releases](https://github.com/beans-lang/beans/releases) ·
[Examples](examples/) ·
[Contributing](CONTRIBUTING.md)

## Why Beans

- **Exact money.** A built-in `decimal` type, so totals and taxes add up.
- **No null, no exceptions.** `Option`, `Result`, and `?` make failure explicit.
- **Explicit types.** Code stays boring and easy to read a year later.
- **Run or build.** `beansc run` interprets. `beansc build` makes a native binary through LLVM.
- **Self-hosted.** The compiler, `beansc`, is written in Beans and rebuilds itself byte for byte.
- **Systems access when you need it.** Sized ints, `unsafe` blocks, and C interop.

## Ecosystem

- [Espresso](https://github.com/beans-lang/espresso): web APIs with routing, middleware, DI, and OpenAPI.
- [Latte](https://github.com/beans-lang/latte): server-rendered UI components with `.bx` markup.
- [Cortado](https://github.com/beans-lang/cortado): native desktop apps on AppKit, GTK4, and Win32.
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
