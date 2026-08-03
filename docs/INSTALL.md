# Installing Beans

One command installs a working compiler. Nothing here needs sudo, an
administrator prompt, a package manager, Python, Node, jq, or Git.

## The one-line installers

**macOS and Linux**

```bash
curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh
```

**Windows (PowerShell)**

```powershell
irm https://github.com/beans-lang/beans/releases/latest/download/beans-install.ps1 | iex
```

Open a new terminal afterwards, or run the exact command the installer prints to
enable Beans in the current one. Then:

```bash
beansc --version
beansc doctor
```

## What the installer does

1. Detects the operating system, CPU architecture and — on Linux — whether the
   libc is glibc or musl.
2. Downloads `beans-release-manifest.tsv` and picks the matching package,
   preferring a full package when one exists for your target.
3. Downloads the archive to a temporary directory and verifies its SHA-256.
4. Unpacks it into a staging directory and runs the staged `beansc --version`.
5. Only then moves it into place, so a failed download, checksum, unpack or
   validation never damages a working installation.
6. Adds the `bin` directory to your PATH, once — running the installer again
   never adds a second entry.
7. Deletes its temporary files, on success and on failure.

Running the installer twice is safe. It reports that the version is already
installed and exits; `--force` reinstalls.

## Install locations

| platform | default |
|---|---|
| macOS, Linux | `$HOME/.beans` |
| Windows | `%LOCALAPPDATA%\Beans` |

Override with `BEANS_HOME` or `--prefix` / `-Prefix`.

The layout is stable, and the installation can be moved after unpacking —
every path inside is resolved relative to the launcher:

```
<BEANS_HOME>/
  bin/          beansc launcher, the compiler, beans_rt.c, wasm_host.c
  lib/std/      the standard library
  toolchain/    bundled Clang, LLD and llvm-ar (full packages only)
  VERSION
```

## Options

| shell | PowerShell | meaning |
|---|---|---|
| `--version <v>` | `-Version <v>` | install a specific release |
| `--prefix <dir>` | `-Prefix <dir>` | install somewhere else |
| `--target <triple>` | `-Target <triple>` | force a target (advanced) |
| `--force` | `-Force` | reinstall over the same version |
| `--no-modify-path` | `-NoModifyPath` | do not touch shell startup files |
| `--help` | `-Help` | show usage |

Environment variables `BEANS_HOME`, `BEANS_VERSION` and `BEANS_TARGET` do the
same thing, which is how to configure the piped-into-shell form:

```bash
BEANS_VERSION=0.9.0 curl -fsSL .../beans-install.sh | sh
```

```powershell
$env:BEANS_TARGET = 'x86_64-pc-windows-msvc'; irm .../beans-install.ps1 | iex
```

## Uninstalling

Delete the install directory and remove the PATH line the installer added.

```bash
rm -rf "$HOME/.beans"
# then delete the "added by the Beans installer" line from
# ~/.profile, ~/.bashrc or ~/.zshrc
```

```powershell
Remove-Item -Recurse -Force $env:LOCALAPPDATA\Beans
# then remove the bin directory from your user PATH
```

## Full and slim packages

A **full** package bundles a complete native C toolchain — Clang, LLD, llvm-ar,
the Clang resource directory, and the headers, startup objects and target
libraries needed to link. `beansc build` works with nothing else installed.

| full package targets |
|---|
| `x86_64-unknown-linux-gnu` |
| `aarch64-unknown-linux-gnu` |
| `x86_64-pc-windows-gnullvm` (LLVM-MinGW/UCRT) |
| `aarch64-pc-windows-gnullvm` (LLVM-MinGW/UCRT) |
| `i686-pc-windows-gnu` (LLVM-MinGW) |

A **slim** package ships for every other supported host: macOS, musl Linux, the
less common Linux CPUs, and the MSVC and msvcrt-MinGW Windows ABIs. A complete,
correct native toolchain cannot be bundled for these — the MSVC toolchain and
the Windows SDK are Microsoft's to distribute, Apple's SDK is Apple's, and a
cross-built package cannot carry a Clang of the wrong architecture.

Slim packages fully support:

- `beansc --version`, `beansc doctor`
- `beansc check`, `beansc lex`, `beansc parse`, `beansc mir`, `beansc llvm`
- `beansc run`
- `beansc build --emit ir`

For a native `beansc build` they use the Clang already on your PATH. If it is
missing, Beans says so in one message naming the command to run, instead of
letting you reach a Clang or linker error.

`beansc doctor` prints exactly what your installation can and cannot do.

## What each command needs

| command | external dependency |
|---|---|
| `beansc --version`, `beansc doctor` | none |
| `beansc lex`, `parse`, `check`, `mir`, `llvm` | none |
| `beansc run` (no C FFI) | none |
| `beansc build --emit ir` | none |
| `beansc build` (native) | bundled toolchain in a full package; Clang otherwise |
| `beansc build --emit obj` | same as native `build` |
| `beansc build --emit static` | Clang **and** an archiver (`llvm-ar` or `ar`) |
| `beansc build --emit shared` | same as native `build` |
| `beansc bindgen` | Clang |
| `beansc run` with C FFI | Clang — the interpreter's C bridge compiles a shim |
| `beansc mod tidy`, `mod update` | Git, and only for Git-based dependencies |

Beans emits LLVM IR, so the C compiler must be Clang. GCC cannot compile that
IR, and is not a supported substitute.

Override the tools Beans uses with `BEANS_CC`, `BEANS_AR`, `BEANS_RUNTIME`,
`BEANS_WASM_HOST` and `BEANS_STDLIB`, or per build with `--cc`, `--ar`,
`--linker` and `--sysroot`.

## macOS

Apple's SDK is not redistributable, so no Beans package bundles it. `beansc
check` and `beansc run` work without any Apple tooling. A native build needs
Command Line Tools:

```bash
xcode-select --install
```

If they are missing, `beansc build` stops with that exact command rather than a
missing-header or linker error, and `beansc doctor` reports the same thing.

## Verifying a download by hand

Every release publishes:

- `beans-release-manifest.tsv` — version, target, OS, arch, libc, full/slim,
  asset name, SHA-256, and whether native builds are self-contained
- `beans-release-checksums.txt` — SHA-256 of every published file
- an SPDX SBOM and build attestations covering the files you download

```bash
curl -fLO https://github.com/beans-lang/beans/releases/latest/download/beans-release-checksums.txt
sha256sum -c beans-release-checksums.txt --ignore-missing
```

## Installing from source

See [the README](../README.md#from-source). `make install` installs the
self-hosted `beansc` only.

`beansc0` is the internal C++ stage-0 bootstrap compiler. It is never installed,
never packaged, never listed in a checksum file or SBOM, and never placed on your
PATH. It exists so a clean machine can build the compiler at all, and it stays in
the build directory.
