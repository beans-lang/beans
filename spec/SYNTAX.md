# beans language contract — 1.0 candidate

Language: **beans** · extension: **.b** · status: frozen 1.0 design, implementation stabilization in progress
Toolchain status: **self-hosted lexer + parser + loader + checker + MIR + interpreter + native backend implemented** — including multi-file modules, git imports, and selectable build targets. The default `beansc` is written in Beans and is the only compiler: a released `beansc` builds the next one, and stage 2 and stage 3 must come out byte-identical.

## What beans is for

Two target jobs, and the design serves both:

1. **Business apps** (accounting, ERP, billing) → mandatory explicit types, `decimal` money math, no null, no exceptions, boring and readable.
2. **Systems work** (databases, OS/hardware control) → sized ints, value types, `unsafe` layer with raw memory and C/C++ interop, no GC pauses.

## Design rules

1. Small grammar. Every keyword must remove more complexity than it adds.
2. Everything is an object. `5.abs()` works. Primitives are unboxed under the hood.
3. No null. No exceptions. `Option<T>` and `Result<T>` only.
4. **Every new name states its type.** No inference. Applies to `let`/`var`, params, fields, loop variables. One exception: match bindings — the matched value already pins the type, so `some(u) =>` is fine (`some(u: User) =>` allowed if you want it).
5. snake_case for functions, methods, variables, packages, enum variants. PascalCase for types. lowercase for primitives.
6. Package-private by default — classes, interfaces, enums, functions, methods,
   and fields. `pub` exposes a name outside its package. `priv` makes a field or
   method visible only inside its declaring class or struct.
7. If two designs work, pick the one with less syntax.

## Annotations

Beans annotations are typed metadata declared with `annotation` and applied
with `@snake_case`. Arguments are named compile-time constants. Annotations
may describe declarations, fields, enum variants, parameters, and locals, but
cannot change ownership, layout, visibility, ABI, or safety rules. The full
syntax, target list, retention rules, and implementation checklist live in
[`docs/ANNOTATIONS.md`](../docs/ANNOTATIONS.md).

An annotation schema may use `@runtime_hook(before: "fn",
after_return: "fn")` to add checked, synchronous function or method handlers.
Root applications may mark no-argument lifecycle functions with
`@runtime_start` and `@runtime_stop`. These are direct compiler-wired calls,
not text macros or per-call threads. The complete contract is in
[`docs/RUNTIME_HOOKS.md`](../docs/RUNTIME_HOOKS.md).

## Reflection

`type_of(T)` returns the `std.reflect.Type` descriptor for a checked static
type. Dynamic values cross the reflection boundary through an owned
`std.reflect.Value`; `Value.type()` reports the stored runtime type and checked
`as?` conversion copies or takes the payload according to normal ownership
rules.

`std.reflect` can inspect types, generic arguments, inheritance, interfaces,
fields, methods, initializers, enum variants, functions, parameters, annotation
declarations, and annotations retained with `@retention(value: "runtime")`.
Member lists preserve declaration order. Type, function, and annotation
registries are deterministic within one executable; descriptor IDs are not
stable across builds or shared-library boundaries.

Reflection does not bypass Beans rules. Private members stay inaccessible.
Field writes, calls, construction, and enum creation check receiver types,
argument types, argument counts, moves, and visibility. `deinit`, open generic,
async, extern, variadic, and `inout` calls are not reflective call targets.
There is no `setAccessible`, proxy generation, stack inspection, class loader,
or raw-memory escape.

Reflection supplies the metadata and checked operations a serializer needs.
JSON and XML naming, unknown-field, default, versioning, and numeric conversion
policies remain in `std.encoding`. The complete API and limits are specified in
[`docs/REFLECTION.md`](../docs/REFLECTION.md).

## Typed JSON and XML decoding

`std.encoding.json.decode<T>` and `std.encoding.xml.decode<T>` build a concrete
schema for each used `T` at compile time. Native code parses and writes directly
into final struct and list storage. It does not build public `Value` or `Node`
wrappers and does not scan runtime reflection metadata.

The implemented native shape is a struct tree containing scalar fields,
nested structs, `List<T>`, `List<string>`, `Option<T>`, and
`Option<List<T>>`. JSON `null` maps to `Option<T>`. XML lists
consume repeated elements. Both formats reject missing required fields,
duplicates, unknown input by default, overflow, and incompatible source kinds.

Tool-retained annotations control names, naming rules, ignored or unknown
fields, JSON aliases, and XML attributes, text, and namespace URIs. XML matches
namespace URI plus local name, not the source prefix. JSON ignored fields need
defaults and cannot yet share a decoding schema with nested structs or lists;
typed encoding has no such limit. XML ignore is declared for the mapping
contract but is not accepted by the native decoder yet. JSON byte-format
annotations are likewise reserved for later Bytes support. Invalid or
recursive schemas fail during checking.
Classes, payload enums, nested lists, maps, arrays, decimal, unit, and bytes are
not native typed-decoder targets in this release.

The full contracts, supported scalar types, limits, and performance evidence
are in [`docs/JSON_STRUCT_DECODING.md`](../docs/JSON_STRUCT_DECODING.md) and
[`docs/XML_STRUCT_DECODING.md`](../docs/XML_STRUCT_DECODING.md).

### Why `Option` is uppercase but `some` is lowercase

The case tells you what a thing is: PascalCase = type, snake_case = value. `Option<User>` is a type. `some(u)` is a value. And they're not special — Option and Result are just built-in enums, and beans enum variants are snake_case:

```
enum Option<T> {
    some(value: T)
    none
}

enum Result<T, E> {
    ok(value: T)
    err(error: E)
}
```

Rust capitalizes `Some`/`Ok` because Rust variants are PascalCase. Beans variants are snake_case, so lowercase is the consistent choice, not an accident.

## Files, modules, imports (implemented, v0.4)

Four separate things, and it pays to keep them apart:

| | example | what it is |
|---|---|---|
| module path | `shop` | the `beans.pot` unit: one dependency, one lock row |
| import path | `shop.money` | a **package's identity** — globally unique |
| package name | `money` | what the package calls itself, in its `package` clause |
| import binding | `cash` in `import shop.money as cash` | a name, in one file only |

- One folder = one package. `.b` files in it share the package — no import needed between them.
- Everything is private to its package unless marked `pub`. Private means
  *same import path*, never *same package name*.
- A field or method marked `priv` is stricter: only code inside its declaring
  class or struct may access it. The package and subclasses do not get access.
  Beans has no `protected` visibility.
- Application entry point: `fn main()`, in the module root. A library has no
  `main`.

### The package clause

Every `.b` file the compiler loads as a package starts with one:

```beans
package main

import std.io
import shop.money
```

```beans
package money

pub class Money {
    // ...
}
```

- Exactly one clause, before every import and declaration.
- Every file in a directory declares the same name.
- The name is a lowercase snake_case identifier.
- It need not match the directory. `shop/transport_v2/` may declare
  `package transport`, which is what versioned or internal directory names are
  for — the import path stays `shop.transport_v2`.
- An application's module root declares `package main`. A library root declares
  a normal name, usually the last segment of its module path. An importable
  package never declares `main`.
- A single file with no `beans.pot` may leave the clause out, or write
  `package main`.

A module is a directory tree with a `beans.pot` at its root:

```
module shop
kind application
require github.com/acme/http v1.2    // optional git tag pins
require path "../http"               # local development dependency
link all search "native/lib"
link all library "shop_native"
link macos framework "CoreFoundation"
link x86_64-unknown-linux-gnu library "platform_helper"
csrc all "native/shim.c"
csrc macos "native/shim_macos.c"
```

`kind` is `application` or `library` and defaults to `application`. Applications
need `fn main()` when built as a binary or run. A library root rejects `main`;
its root package exposes source APIs with `pub`, and native C APIs with
`pub extern "C"`. A library may run an application entry under `examples/` or
`tests/`. That entry imports the library by its module name; `main.b` loads its
`.b` siblings, while another selected filename runs alone.

```text
module acme.math
kind library
```

```bash
beansc build api.b                              # build/libmath.a
beansc build --emit shared api.b
beansc build --emit static --header math.h api.b
```

A single file passed with `--emit static` or `--emit shared` also needs no
`main`, preserving the small C-library workflow without a manifest. Beans
libraries imported by another Beans module remain source packages, so generics
and ARC layouts are compiled with the consuming program rather than frozen into
an unstable binary ABI. Native archives and shared libraries expose only the
C-safe functions explicitly declared `pub extern "C"`.

Imports are Go-style — std by dot path, local packages by module path, libraries straight from a git host:

```
import std.io
import std.thread
import shop.util                     // <root>/util/*.b, used as util.thing
import shop.money.fx                 // nested: <root>/money/fx/
import github.com/acme/http          // cloned to ~/.beans/src on first build
import gitlab.com/tools/csv as csvlib
```

- The **declared package name** is the name you use (`http.get(...)`), not the
  last path segment. `import shop.transport_v2` binds `transport` when that
  directory declares `package transport`. `as` overrides it.
- A binding belongs to the file that wrote the import. Two files of one package
  may give the same alias to different packages, and an import in one file
  qualifies nothing in its siblings.
- Two imports with the same local name in one file are an error; `as` separates
  them.
- Cross-package access: `util.some_fn()`, `util.User`, `new util.User(...)`, `util.color.red` — anything `pub`. Methods of a `pub interface` travel with it (an interface is its method set).
- `pub fn init(...)` controls class construction across package lines. Struct field literals still enforce field visibility.
- A git import needs `host/owner/repo`; the repo must carry its own `beans.pot`.
  `beansc pot tidy` resolves it and writes `beans.lock`. Each lock row stores the
  module path, requested reference, exact commit, and Git tree hash. Resolved
  trees live under `$BEANS_HOME/pkg/<module>/<commit>`.
- `beansc pot update [dependency]` refreshes all dependencies or one named dependency.
  `--locked` rejects a missing, stale, or changed lock; `--offline` forbids
  network access and accepts only a clean cached tree matching the locked hash.
  Dependency Git processes are started directly, never through a shell.
- `require path "../module"` is a local development dependency. The target's
  declared `module` name is its import path. Relative paths start at the
  requiring `beans.pot`, stay out of `beans.lock`, and work with `--locked
  --offline`. Duplicate module names pointing at different directories are an
  error.
- No `beans.pot` above the file = single-file mode: `std.*` and git imports still work, local packages don't.
- A package's identity is its whole canonical import path. Two packages may
  freely share a declared name, and two paths may freely share a final segment
  (`a/cart` + `b/cart`); give the imports different local names and both work:

  ```beans
  import shop.a.cart as retail
  import shop.b.cart as wholesale

  let a: retail.Cart = new retail.Cart()
  let b: wholesale.Cart = new wholesale.Cart()
  ```

  They stay separate everywhere — separate types, separate private methods,
  separate generated symbols. A declared name and an alias are source-facing
  only; neither decides visibility.
- Packages form a directed graph. A package importing itself, or a cycle
  through several packages, is refused with the whole chain:

  ```text
  package import cycle:
    shop.a imports shop.b at a/a.b:3
    shop.b imports shop.c at b/b.b:2
    shop.c imports shop.a at c/c.b:4
  ```

  Files of one package create no edges between each other, so mutually
  recursive functions in one package are fine. A diamond is acyclic and loads
  its shared dependency once.
- A declaration name is claimed once per package, whichever file writes it.
  Two `Cart` classes in one package are a duplicate, not an ambiguity.
- A manifest may use `#` or `//` comments outside quoted values.
- `link` selects `all`, an OS name, or one exact target triple. `search` paths
  are relative to the `beans.pot` that declared them. `library` and macOS
  `framework` entries are passed to the linker in declaration order. `beansc
  run` loads the same selected shared libraries and resolves extern symbols
  through their local handles. Link rows propagate from local and git
  dependencies, so a consumer does not repeat a native-backed library's rows.
- `csrc <selector> "<file.c>"` declares a C source the package owns; the
  toolchain compiles it, so a C-wrapping library vendors no prebuilt
  binaries and pushes no make step onto consumers — `import
  github.com/owner/lib` just works. Selectors and propagation follow `link`.
  Native builds compile each selected file with the build's own Clang and
  flags into a content-hash-cached object that rides every emit path (linked
  into binaries and shared objects, archived into `--emit static`, placed
  beside `--emit obj` output). `beansc run` compiles the selected set once
  into a host shared library cached under `$BEANS_HOME/cache/csrc` and
  resolves extern symbols through it. Quoted `#include "..."` headers resolve
  beside each source; a missing file is a manifest error.

## Lexical

- No semicolons. Newline ends a statement (Go-style: only after a token that can end one).
- A member chain may break at a `.` on either side: a line ending in `.`
  continues (the dot can never end a statement), and a newline is not a
  terminator when the next line begins with `.name` — so fluent chains write
  trailing-dot or leading-dot style. `..` stays a range operator and never
  continues a line.
- Style consequence, same as Go: `} else {` must be on one line.
- Comments: `//` line, `/* */` block (nesting allowed).
- Number literals can use `_` separators: `1_000_000`. Hex `0xFF`, binary `0b1010`.
- No parens around conditions: `if x > 3 { }`. Braces always required.

## Strings

- `"..."`, immutable, UTF-8.
- Interpolation with `{}`: `"hi {name}, total {price * (qty as decimal)}"`.
- Format specs ride after a `:` in the braces: `{x:8}` pads to width 8 (right-aligned),
  `{x:-8}` left-aligns, `{pi:.2}` fixes decimals (float/decimal only), `{pi:8.2}` both.
  Width pads anything printable — `{xs:12}` pads a whole list. Same rendering as `std.fmt`.
- **There is no `+` for strings.** Building strings happens through interpolation, `std.fmt` (sprintf-style: padding, precision, alignment), or `list.join(sep)`. One way to do it, and it's the readable one.
- Escapes: `\n \t \r \0 \\ \" \{ \}`.

**Methods (v0.5, implemented, byte-based — unicode arrives later as explicit `chars()`, `len` stays bytes forever):**
`len`, `is_empty`, `first(n)`, `last(n)`, `slice(from, to)` (half-open, panics out of range),
`byte_at(i)` (panics), `contains`, `starts_with`, `ends_with`, `find`/`rfind -> Option<int>`
(empty needle: `find` says 0, `rfind` says len), `trim`/`trim_start`/`trim_end` (ASCII whitespace),
`to_upper`/`to_lower` (ASCII), `replace(old, new)` (all occurrences; empty `old` changes nothing),
`repeat(n)` (panics on negative), `split(sep) -> List<string>` (keeps empties; empty sep = one piece),
`lines() -> List<string>` (a trailing newline makes no empty final line),
`to_int`/`to_float`/`to_decimal -> Result<...>`,
`chars() -> List<string>` (UTF-8 characters; malformed bytes come through one at a time),
`count_chars(from, to)` for a checked, allocation-free byte range scan,
`find_byte(byte, from) -> int` (`-1` when absent), `range_equals(from, to, other)`,
and `parse_int_range_or(from, to, fallback)` for allocation-free byte-range work.

## Bytes (v0.5, implemented)

The binary buffer — strings stay text; anything binary is `Bytes`. Mutating methods return
self, so page-building chains work: `new Bytes(4096).put_u32(0, root).put_u64(8, lsn)`.

- `new Bytes(n)` (zeroed, panics on negative), `Bytes.from(s)` (copies the text bytes)
- Unsafe FFI bridge: `Bytes.from_raw(pointer, len)` copies `len` bytes from a
  `RawPtr<u8>` in one bulk operation. It does not take ownership. A null pointer
  is accepted only when `len == 0`.
- Unsafe `bytes.as_ptr()` borrows the buffer's `RawPtr<u8>` without copying.
  The pointer is null for an empty buffer. It is valid only while the `Bytes`
  value stays alive and is not resized, reserved, appended to, or pushed to.
  Do not free the borrowed pointer.
- `len()`, `reserve(n)`, `resize(n)` (regrown range reads zero), `fill(v)`
- `get(i)` / `set(i, v)` — one byte, panics out of range; `push(v)` appends one
  byte. These are low-level storage operations used by Beans-written formats.
- `get_u8/u16/u32/u64/i64(pos)` / `put_...(pos, v)` — fixed width, little-endian, panics out of range
- `slice(from, to)`, `copy_from(src, at)`, `append(other)`, `append_string(s)`,
  `append_i64(v)` (little-endian), `append_range(src, from, to)` (no slice allocation)
- `to_string()` — every byte, NUL included (used by binary-safe source packages
  such as `std.reader`); `to_string_until_nul()` stops at an embedded NUL
- `==` / `!=` compare by value: length, then contents
- `append_uvarint(v)` / `get_uvarint(pos)` — unsigned LEB128 over the 64-bit pattern
  (negatives take 10 bytes); `Bytes.uvarint_size(v)` says how far to advance
- `crc32(from, to)` — IEEE crc32 of a range, panics out of range

## Files and the OS (v0.5, implemented)

Class-first, like everything builtin. Errors are `Result<T>`; `Error.kind` carries a slug
(`not_found`, `permission`, `exists`, `is_dir`, `not_dir`, `not_empty`, `closed`, `io`) and
`Error.msg` is `path: OS message`.

- **File statics/intrinsics**: `exists`, `size`, `remove`, `rename`, and
  `open(path, mode)` → `Result<File>` with modes `"r"`, `"rw"`,
  `"create"`, `"append"`.
- **std.fs**: Beans-written `read`, `read_bytes`, `write`/`append`, `write_bytes`/
  `append_bytes`, and `copy`. These compose `File.open`, positional/cursor I/O,
  truncate, close, and exact byte-to-string conversion; only that low-level layer
  stays native. The old native `File.read(path)` helper is gone.
- **File methods**: positional I/O first — `read_at(pos, n)` → `Result<Bytes>` (short read at
  EOF returns what's there), `write_at(pos, b)`; cursor `read(n)`/`write(b)`; `seek`/`seek_from_end`
  (return the new position, panic on a closed file), `tell`, `size`, `truncate`, `sync` (fsync —
  the durability call), `close` (double close is an error result). Dropping the last reference
  closes the fd as a safety net; `close()` is still the API.
- **File locks**: `lock()` (blocking, exclusive), `try_lock()` (`ok(false)` means someone else
  holds it), `unlock()` — advisory flock, owned by the open file description, so two handles on
  one file contend. Single-writer databases.
- Every owned file descriptor is close-on-exec, so running a child cannot leak a live
  `File` into it.
- **Dir statics**: `create`, `create_all`, `list` → `Result<List<string>>` (sorted), `remove`
  (empty only), `remove_all` (recursive), `exists`, `temp_path`, `sync` — fsync a directory, the
  rename-commit pattern's second half; `walk(path)` → `Result<List<string>>` — recursive,
  files and symlinks only (never follows a link), paths relative to the argument, sorted.
- **std.path** (pure Beans string math, no fs access): `join(a, b)` (absolute `b` wins),
  `parent`, `base`, `ext` (with the dot; a leading dot is a dotfile, not an extension),
  and `stem`. Import it with `import std.path`; the old native `Path.*` copy is gone.
- **std.reader**: `new reader.Reader(f)` then `read_line()` → `Result<Option<string>>` —
  `ok(some(line))` without its newline, a partial last line, then `ok(none)` at EOF.
  It reads at its own offset (pread), so the file's cursor never moves; buffered
  data keeps serving after `f.close()`, and the closed error surfaces on the next refill.
  Buffering and line policy are Beans source; only `File.read_at` stays native. The old
  native `BufReader` type is gone.
- **std.os**: `args()` (`beansc run f.b -- a b` passes them; the native binary uses argv),
  `env(name)` → `Option<string>`, `exit(code)`. The millisecond clocks live in
  `std.time` as `wall_millis`, `monotonic_millis` and `sleep_millis`.
- **std.io**: `println`/`print`, `eprintln`/`eprint` (stderr), `read_line()` → `Option<string>`

High-level compiler-shipped packages are normal Beans source under `stdlib/std`.
`std.collections` provides `sum_int` and `frequencies`, and the generic `count`,
`filter`, `transform`, and `unique` functions. Its `increment`,
`get_or_insert_with`, `merge_with`, `remove_if`, and `map_values_with_key`
functions mutate a caller Map through `inout`; these are ordinary generic Beans
functions, including for structural wide keys.
`Option` provides instance methods `map`, `and_then`, and `filter`; `Result`
provides instance methods `map`, `and_then`, and `recover`. There are no
`std.option` or `std.result` packages. `std.math`
provides `clamp` and `gcd`; `std.bytes` provides Beans-written `crc32`,
`uvarint_size`, `encode_uvarint`, `append_uvarint`, `decode_uvarint`, and
`decode_uvarint_at_or`; `std.path` is fully
Beans-written; `std.fmt` implements `hex`, `binary`, and `group_digits` in Beans; and
`std.fs` implements the high-level whole-file byte/write/copy helpers in Beans;
`std.reader` implements buffered line reading in Beans.
Floating-point/decimal conversion and guarded padding remain native. These go through
the same checker, interpreter, MIR, and native backend as user code.
`BEANS_STDLIB` can point the loader at another shipped-library root. Native
registry rows remain for low-level allocation/storage, raw bytes, OS calls,
atomics, and thread entry while more of `core` and `std` move to `.b` files.

**What prints** (same rule for `io.println` and `{x}` interpolation): numbers, bools, strings;
enums, as `variant` or `variant(payload, ...)`; lists of printable things, as `[a, b, c]`,
nesting included — and `join(sep)` renders the same way. Maps and class instances don't print
yet — give them a string form first. (`Result` carries an `Error` object, so it stays
unprintable too — match on it.)

[examples/kv.b](examples/kv.b) is the proof: an append-only KV store with binary records and a
durable compaction (write temp, sync, rename over, sync the parent dir).

## MMap (v0.5, implemented)

A shared mapping of a whole file — the page-cache path a database wants. One writer, no
collector interaction: the mapped region is not beans heap, only the handle is.

- `MMap.open(path, writable)` → `Result<MMap>` — maps the entire file (`MAP_SHARED`); the
  handle keeps its fd for `resize`, and the mapping outlives the path — unlink while mapped
  is fine. An empty file maps with `len() == 0`.
- `len()`; `get_u8/u16/u32/u64/i64(pos)` and `put_...(pos, v)` — little-endian, bounds-checked
  panics; `put` panics on a read-only map; `put`/`write` return self for chains.
- `read(pos, n)` → `Bytes` (copy out), `write(pos, b)` — panics out of range.
- `flush()` / `flush_range(pos, n)` → `Result<bool>` (msync — the durability call),
  `close()` → `Result<bool>` (double close is an error; access after close panics).
- `resize(n)` → `Result<bool>` — ftruncate + remap in place, grow or shrink; read-only
  maps refuse with a `permission` error. On a remap failure the handle stays open but empty.
- Dropping the last reference unmaps (and closes the fd) as a safety net.
- The backing descriptor is close-on-exec while the mapping owns it.

## std.fmt (v0.5, implemented)

Interpolation assembles, fmt formats. No printf — the language has no varargs.

- `pad_left(s, width)` / `pad_right(s, width)` — spaces, byte width; already-wide input
  comes back unchanged.
- `float(x, places)` — fixed decimals (`3.14`), places clamped to 0..100.
- `decimal(d, places)` — exact decimals: rounds half-even when narrowing, zero-pads
  when widening. `fmt.decimal(19.995, 2)` is `"20.00"`.
- `hex(n)` / `binary(n)` — the 64-bit two's-complement pattern, lowercase, no prefix:
  `hex(-1)` is 16 f's.
- `group_digits(n, sep)` — thousands grouping: `group_digits(1234567, ",")` is `"1,234,567"`.

## std.encoding (v0.9, implemented)

Four shipped packages for wire formats. Three wrap pinned, vendored native
libraries behind ordinary Beans APIs — no C functions, pointers, or upstream
types are visible — and one is pure Beans:

| package | underneath | license |
|---|---|---|
| `std.encoding.json` | yyjson 0.12.0 | MIT |
| `std.encoding.xml` | pugixml 1.16 | MIT |
| `std.encoding.base64` | simdutf 9.0.0 | MIT (upstream offers MIT or Apache-2.0) |
| `std.encoding.binary` | Beans source over `Bytes` | — |

Payload marshalling is not written as a Beans byte loop in native code: the
packages call four private helpers — two bulk copies and two payload-address
borrows — that the native backend lowers to `@llvm.memcpy`, a pointer load,
and overflow-safe bounds checks. Eligibility is validated, not assumed: a
helper qualifies only when its source file sits under the compiler-shipped
stdlib root, its package is one of the three shipped encoding packages, and
its parameter and result types match the intrinsic signature exactly. A user
module with its own `json`, `xml` or `base64` package therefore keeps its own
Beans bodies (`test/cases/encoding_shadow/`), and both interpreters always
run the Beans bodies, which is why the three backends stay byte-identical.

Vendored sources live in `runtime/encoding/vendor/` (exact release files,
recorded in `VENDOR.md` there) and ship with every package. Each feature
compiles to its own cached object, keyed on the bridge ABI version, the
target and its CPU/feature selection, the runtime profile, PIC/LTO/release
mode, the exact C compiler and its version, every effective compile flag,
and the full contents of the bridge and vendored sources
(`test/encoding_cache.sh` changes one input at a time and asserts the key
moves). Importing JSON links yyjson and nothing else, a program with no
encoding import carries no encoding code, and no vendored symbol appears in
a Beans library's export table.
`beansc run` builds one cached bridge library per feature per host from the
same sources, so both backends execute identical native code and stay
byte-identical. The bridges need a C library, so `--runtime freestanding`
refuses `std.encoding` by name; `full`, `minimal`, and `wasm32-wasip1`
builds work.

### std.encoding.json

```beans
import std.encoding.json

let root: json.Value = json.parse("\{\"a\":[1, 2.5, \"x\"]\}")?
match root.get("a") {
    some(list) => {
        for item: json.Value in list.elements()? {
            io.println("{item.kind()}")
        }
    }
    none => {}
}
let text: string = json.stringify(root)?

struct User { pub id: u64  pub name: string }
let user: User = User { id: 7, name: "Ada" }
io.println(json.encode(user)?)
```

- `parse(text)`, `parse_bytes(data)` → `Result<Value>`; `parse_with`/
  `parse_bytes_with` take an `Options`. Strict RFC 8259 is the default: the
  whole input must be one document, trailing content is an error, and every
  parse error carries a kind (`invalid`, `eof`, `memory`) and a byte
  position.
- `Options` opts into exactly three named extensions — `allow_comments`,
  `allow_trailing_commas`, `allow_inf_nan`. That is a subset of JSON5,
  deliberately not called JSON5; unquoted keys and single quotes stay
  errors.
- `decode<T>`, `decode_bytes<T>`, `decode_bytes_in_place<T>`, and
  `decode_with_options<T>` build a concrete mapping at compile time and write
  directly into final struct/list storage. Supported fields include scalars,
  nested structs, lists, and options. Strict defaults reject missing required
  fields, unknown or duplicate keys, wrong kinds, and overflow. Tool-retained
  `@json.name`, `@json.alias`, `@json.ignore`, `@json.naming`,
  and `@json.allow_unknown` annotations control the implemented mapping.
  `@json.bytes` reserves the byte-format contract, but typed Bytes decoding is
  not implemented in this release.
- `encode<T>(value)` writes a struct or `List<struct>` as compact JSON.
  `encode_pretty<T>(value, indent)` accepts two or four spaces. Both return
  `Result<string>`. Field order follows the struct declaration. Primary names
  come from `@json.name` or `@json.naming`; `@json.alias` is input-only;
  `@json.ignore` fields are omitted; and absent options write `null`. Use
  `io.println(json.encode(value)?)` to print a struct as JSON. NaN and infinity
  are rejected.
- Typed JSON currently supports bool, integer, float, string, nested struct,
  list, and option fields. Struct and `List<struct>` are the only root shapes.
  Classes, enums, maps, fixed arrays, bytes, decimal, unit, generic structs,
  recursive schemas, nested lists, and nested options are rejected at compile
  time instead of falling through to an unsupported runtime body.
- `Value.kind()` reports `null`, `boolean`, `integer`, `unsigned_integer`,
  `floating`, `text`, `array`, or `object`. Numbers keep their parsed kind:
  a non-negative integer is `unsigned_integer`, a negative one `integer`
  (yyjson's classification), a decimal-point or exponent form `floating` —
  nothing is silently collapsed to f64. An integer beyond u64 parses as
  `floating`, the reading every RFC 8259 parser gives it.
- Typed access returns `Result`: `to_bool`, `to_int` (signed, or unsigned
  when it fits), `to_uint`, `to_float` (floating only), `number()` (any
  numeric, converted), `to_string`. Arrays: `len`, `at(index)`, `elements()`.
  Objects: `len`, `get(key)` → `Option<Value>`, `entries()` →
  `List<Entry>`.
- Object entries keep document order, duplicates included: `entries()`
  reports every entry; `get` returns the first match for a duplicated key.
- **Ownership**: a `Value` is a cheap view holding a shared reference to its
  document; the yyjson document is freed when the last `Value` over it
  drops. Nothing is eagerly copied into Beans collections — this is a DOM
  API over yyjson's tree. Typed decoding is a separate generated compiler
  path and does not build `Value` wrappers or scan reflection metadata.
- Building: `Value.null/from_bool/from_int/from_uint/from_float/from_string`,
  `Value.array()`, `Value.object()`, then `push(item)` and
  `add(key, item)`. Inserts deep-copy the argument, so a value can be
  inserted twice or across documents safely. Values from `parse` are
  read-only; mutating one reports kind `immutable`.
- `stringify(value)` is compact RFC 8259; `stringify_pretty(value, indent)`
  accepts `"  "` or `"    "` (yyjson's two writers). Writing a NaN or
  infinity is an error, not invalid output.

### std.encoding.xml

```beans
import std.encoding.xml

let doc: xml.Document = xml.parse("<order id=\"7\">hi<b>x</b></order>")?
let root: xml.Node = doc.root()?
for child: xml.Node in root.children() {
    io.println("{child.kind()} {child.name()}")
}
let out: string = xml.stringify_pretty(doc, "  ")?
```

- `parse(text)`, `parse_bytes(data)` → `Result<Document>`. UTF-8, UTF-16 and
  UTF-32 byte-order marks are honoured, and a BOM-less input is read as
  UTF-8. A document must have **exactly one** root element: zero — which
  covers empty, whitespace-only, declaration-only, comment-only,
  processing-instruction-only and DOCTYPE-only inputs — and two or more are
  both errors. Trailing comments and processing instructions after the root
  are well-formed and accepted.
- `decode<T>`, `decode_bytes<T>`, and `decode_with_options<T>` build a concrete
  mapping at compile time and write directly into final struct/list storage.
  Supported fields include scalars, nested structs, repeated lists, and
  options. Tool-retained `@xml.name`, `@xml.namespace`, `@xml.attribute`,
  `@xml.text`, `@xml.naming`, and `@xml.allow_unknown` annotations control the
  implemented mapping. `@xml.ignore` is declared but rejected in this release.
- Parse errors carry a byte offset **into the caller's own bytes**, BOM
  included, whenever the input was consumed as UTF-8. A UTF-16 or UTF-32
  input is transcoded to UTF-8 before parsing, so pugixml's offsets index a
  buffer the caller never saw; those errors say "at an unknown byte offset
  (the input was transcoded from UTF-16 or UTF-32)" rather than quoting a
  number that means nothing.
- Node kinds: `element`, `text`, `cdata`, `comment`,
  `processing_instruction`, `declaration`, `doctype`. `children()` and
  `attributes()` preserve document order — mixed content included.
  `name()` is the raw qualified name; `prefix()`/`local_name()` split it at
  the colon. The DOM API does not resolve namespace URIs. The typed decoder
  does resolve `xmlns` declarations and matches namespace URI plus local name,
  so source prefixes may vary. This remains a DOM parser, not a streaming one.
- `text()` concatenates an element's direct text and CDATA children.
  Whitespace-only text nodes are dropped unless
  `Options.preserve_space_text` is set.
- **Security defaults**: DOCTYPE is rejected by default with its byte
  offset; `Options.allow_doctype` keeps the declaration as an inert node
  only. pugixml expands nothing beyond the five built-in entities and
  numeric character references — there is no external-entity mechanism, and
  parsing never touches the filesystem or network.
- **Ownership**: `Document` and `Node` share one owner; a child node stays
  valid after the binding that held its document is gone, and the native
  document is freed with the last reference.
- Building: `Document.empty()`, `append_declaration(version,
  encoding)`, `append_element`, `append_text`, `append_cdata`,
  `append_comment`, `append_processing_instruction`, `set_attribute` (duplicate attribute
  names on one element are refused with kind `exists`). Escaping and
  serialization are pugixml's writer; `stringify` is compact,
  `stringify_pretty(doc, indent)` takes any indent up to 16 bytes.

### std.encoding.base64

```beans
import std.encoding.base64

let text: string = base64.encode(Bytes.from("beans"))
let data: Bytes = base64.decode(text)?
let raw: string = base64.Encoding.url_safe_no_pad.encode(Bytes.from("x"))
```

- Four encodings as one enum: `Encoding.standard`,
  `Encoding.standard_no_pad`, `Encoding.url_safe`,
  `Encoding.url_safe_no_pad`, each with `encode`, `decode`, and
  `decode_forgiving`. Module-level `encode`/`decode`/`decode_forgiving`
  are the standard padded encoding.
- Strict decoding (`decode`) is RFC 4648 for the chosen encoding: padded
  encodings need exact padding, unpadded ones refuse `=` entirely,
  non-zero trailing padding bits are an error, and any byte outside the
  alphabet — whitespace included — is an error with kind and position
  (`invalid`, `length`, `padding`, `bits`, `whitespace`).
- `decode_forgiving` is the WHATWG forgiving-base64 shape, named so the
  relaxation is visible: ASCII whitespace skipped, partial final group
  accepted with or without padding, non-zero trailing bits ignored;
  alphabet violations still fail.
- Output buffers are allocated at the exact encoded size and simdutf writes
  into them directly — SIMD kernels where the target has them, upstream's
  scalar fallback elsewhere (including the big-endian and 32-bit targets).
  There is no streaming API: Beans has no generic Reader/Writer abstraction
  yet, and inventing one here would freeze a bad shape.
- simdutf is built in upstream's `SIMDUTF_NO_LIBCXX` mode, so the object
  references no C++ runtime symbol at all. pugixml still needs `operator
  delete` and `__cxa_pure_virtual` for its writer vtable; those are defined
  weak inside its own object for the Itanium C++ ABI, which every supported
  target uses — including Windows, where MinGW and GNullVM are Itanium-ABI
  toolchains. `test/encoding_symbols.sh` fails the build if either object
  grows a symbol outside libc, and `test/encoding_windows.sh` checks the same
  thing with the Windows toolchain.

### std.encoding.binary

```beans
import std.encoding.binary

var wire: Bytes = new Bytes(0)
binary.append_u32(wire, 0xdeadbeef, binary.ByteOrder.big)
binary.append_varint(wire, -2)                 // zigzag, Go-compatible
let value: u32 = binary.read_u32(wire, 0, binary.ByteOrder.big)?
```

- `ByteOrder.little`, `ByteOrder.big`, `ByteOrder.native` (the selected
  target's order, folded at compile time through `std.target`).
- Positional `read_`/`write_` and appending `append_` forms for
  `u8/i8/u16/i16/u32/i32/u64/i64`, plus `f32`/`f64` through bit-preserving
  conversion — infinities, quiet-NaN payloads, and negative zero survive
  the round trip. Reads and writes are checked: truncated input is kind
  `eof`, a bad write position kind `range` — never a panic, and never a
  read past the buffer.
- Byte swaps use the machine's byte-swap instruction through
  `std.intrinsic`, and float conversion borrows one scoped stack slot
  (`RawPtr.with_local`) rather than allocating.
- Varints: `append_uvarint`/`read_uvarint` are unsigned LEB128 — the same
  wire format as `Bytes.append_uvarint`, whose raw two's-complement
  behaviour is unchanged. `append_uvarint`/`read_varint` are the signed
  zigzag form matching Go's `PutVarint`. Reads report the value and its
  consumed byte count; running past ten bytes or 64 bits is kind
  `overflow`.
- `Reader` and `Writer` are cursors holding a position and an order;
  `Bytes` is move-only, so every method borrows the buffer per call
  instead of owning it. `remaining(data)` and `skip(data, n)` complete the
  cursor surface.

## Variables

```
let x: int = 5              // can't be reassigned (like Java final)
var total: decimal = 0.0    // can be reassigned
```

`let` means the *variable* can't be rebound. The object it points to can still change inside (Java-style — no borrow checker, no `mut` markers).

`move name` moves the value out of a local binding. The old binding cannot be
read again unless it is a `var` and gets a new value first:

```
var job: Job = next_job()
let running: Job = move job
job = next_job()                 // reinitializes it
```

The checker rejects use after move and a value moved on only one branch. A
move on every branch is definite. Normal parameters, loop variables, match
bindings, and closure captures are borrowed, so they cannot be moved. Moving an outer
local from a loop is also rejected because the next iteration would see an
empty binding. For now `move` names a whole local; field and index moves need
consuming accessors such as List `remove`.

Parameters borrow by default. A `move` parameter owns its argument and drops it
at function exit unless the body moves it onward:

```
fn enqueue(move jobs: List<Job>) { ... }

var batch: List<Job> = make_batch()
enqueue(move batch)
```

A fresh result can be passed directly; an existing move-only local needs
`move`. Move modes must match across interface methods and overrides. Function
values and closures do not carry ownership modes yet, so a function with move
or inout parameters cannot be stored as a closure value.

An `inout` parameter aliases one mutable caller local for the duration of the
call. It is not copy-in/copy-out:

```
fn swap(inout left: int, inout right: int) {
    let old: int = left
    left = right
    right = old
}

var a: int = 1
var b: int = 2
swap(inout a, inout b)
```

The caller must write `inout`, the argument must be a `var`, and the same local
cannot appear in two inout positions of one call. An inout parameter cannot be
captured by a closure. Native code passes the local's address directly; ARC
values release the old value and own the replacement on overwrite.

`unique class` gives the same outer-handle rule to a user type:

```
unique class Packet {
    bytes: Bytes
}
```

It cannot be copied by binding, assignment, return, or storage. Use `move` to
move it. A subclass of a move-only class is move-only too. This controls the
reference handle; fields inside the object still follow their own rules.

`Box<T>` and `Arena<T>` are move-only outer handles. Binding or assigning an
existing handle needs `move`; function parameters borrow by default.

```
var value: Box<int> = new Box(7)
value.set(9)
let owned: Box<int> = move value

var arena: Arena<string> = new Arena(1024)
let handle: int = arena.add("bean")
let word: string = arena.at(handle)       // checked; panics on a bad handle
let maybe: Option<string> = arena.get(handle)
arena.clear()                             // drops all values in one pass
```

`new Box(value)` owns one heap slot. `get()` returns the value and `set(value)`
replaces it. The native runtime uses the common iterative ownership walker, so
boxed chains do not recurse during teardown. Structs, fixed arrays, SIMD,
slices, inline Option/Result values, and decimals keep their real inline layout;
nested ARC fields are retained and dropped recursively.

`new Arena(capacity)` needs a declared `Arena<T>` type or an explicit type argument. `add(value)` appends and
returns a stable integer handle; `len`, `at`, `get`, and `clear` operate on the
current region. `clear` keeps capacity but invalidates every old handle. This
arena stores typed-width values in one contiguous region. Wide values and
32-byte decimals stay inline, and `clear` drops every nested ARC field before
reusing the buffer. References returned by `get` and `at` are owned copies;
there is no borrowed arena-reference type yet.

`Shared<T>` is the explicit thread-safe shared-ownership handle. `Weak<T>`
observes the same control block without keeping the value alive:

```
let shared: Shared<string> = new Shared("beans")
let weak: Weak<string> = shared.downgrade()
let live: Option<Shared<string>> = weak.upgrade()
let gone: bool = weak.is_expired()
```

`get()` returns a copy of the value. Wide values and decimals stay inline in a
typed payload box, and nested ARC fields use normal copy ownership. The control block owns one value reference
until its last strong handle dies; upgrade uses an atomic compare/exchange, so
it cannot revive a dead value. A cycle made through `Shared` must be broken with
`Weak`, like C++ `shared_ptr`/`weak_ptr` (plain class cycles use `weak`
fields); the local-class cycle collector does
not trace through explicit Shared control blocks. `Shared<T>` and `Weak<T>` are
`Send` and `Sync` only when `T` is both. `Mutex<T>` is the explicit lock-based
synchronization boundary, including for local ARC class values.

### Struct and collection literals

Structs keep named field literals. Lists and maps keep their literal forms:

```
let point: Point = Point { x: 3, y: 4 }
let values: List<int> = [1, 2, 3]
let counts: Map<string, int> = {"beans": 2}
```

Classes never use field literals or short `{}` initialization. Build them with
`new Class(...)` or target-typed `new(...)` so every construction path goes
through `init`.

## Types

Primitives (all unboxed in codegen):

- `int` (64-bit), `i8 i16 i32 i64`, `u8 u16 u32 u64`
- `float` (= `f64`), `f32 f64`
- `decimal` — base-10 exact number for money. See below.
- `bool`, `string` (immutable), `byte` (= `u8`)

### decimal

- Exact base-10 math: `0.1 + 0.2 == 0.3`. Always. Float can't do that.
- Use it for every money value. Using `float` for money should feel wrong in beans.
- The 1.0 contract is 38 significant digits. Literals and arithmetic are
  checked; exceeding the range panics as `decimal overflow`.
- `round(places, mode = RoundingMode.half_even)` supports `half_even`,
  `half_away`, `toward_zero`, `floor`, and `ceil`. The mode is written at the
  call site.
- Division produces up to 38 significant digits and rounds the last digit
  half-even.
- Decimal stays an inline value in locals, fields, parameters, returns, List,
  Map values, Box, Arena, Shared, Mutex, Channel, and thread results.
- Native layout is `{i128 coefficient, i64 scale}` (32 bytes, 16-byte
  alignment). Arithmetic uses checked wide intermediates so a valid input can
  never wrap before its 38-digit result is checked.

### Number rules

- A number literal takes the type the spot demands: `let p: decimal = 19.99` makes a decimal, `let f: f64 = 19.99` makes a float. No suffix zoo.
- With no demand, an integer literal is `int` and a decimal-point literal is `f64`.
- **No implicit numeric conversions, ever.** Mixing `int`/`float`/`decimal` needs `as`: `price * (qty as decimal)`.
- Integer literals must fit their demanded type. The checker rejects both ends outside the exact `i8`..`u64` range.
- Fixed-width integer `+`, `-`, `*`, unary `-`, and bit operations wrap to that width. Shift counts are masked by `width - 1`. Divide or modulo by zero panics.
- Integer casts keep the low target-width bits. Widening sign-extends a signed source and zero-extends an unsigned source.
- `f32` rounds after every literal, cast, and arithmetic operation. It is a real 32-bit LLVM value in locals, calls, and fields, not an alias for `f64`.
- Float comparisons are IEEE-754: a NaN operand makes `==`, `<`, `<=`, `>`, and
  `>=` false and `!=` true, in the interpreter and the native backend alike.
  (Decided after an audit found the interpreter collapsing NaN to "equal" while
  the native backend answered `!=` with an ordered compare — every implementation
  now agrees.) Casting NaN or an infinity to `decimal` panics as `decimal
  overflow`, the same as any float whose magnitude exceeds 38 digits.

The native backend uses exact LLVM integer, float, and decimal types for locals,
parameters, returns, arithmetic, and packed class fields. List keeps its old
data/len/cap prefix for hot scalar code, but wide structs, fixed arrays, SIMD,
slices, and inline Option/Result values use their real stride plus an ARC pointer
mask, including inline 32-byte decimals. Map keeps its existing one-slot key and
narrow-value path, while wide values use a parallel typed-width buffer with the
same ARC mask. Box, Arena, Shared, Mutex, and Channel also use typed-width
storage, as do thread results. User enums use aligned inline layout for wide
payloads inside their ARC object. A stored wide Map key gets one immutable ARC
box; lookup keys stay on the stack and generated equality/hash functions walk
their fields rather than padding bytes.

### Collections

```
var xs: List<int> = [1, 2, 3]
var m: Map<string, int> = {"a": 1, "b": 2}
var ordered: OrderedMap<string, int> = {}
xs.push(4)
let n: Option<int> = m.get("a")     // no null, no panic
```

**List methods (v0.5, implemented):** `clone`, `push`, `reserve(capacity)`,
`pop`/`first`/`last`/`get(i)` → `Option<T>`,
`len`, `max`/`min` → `Option<T>` (ordered elements: numbers, strings, bools — or a generic
param, trusting its constraint), `contains`, `index_of` → `Option<int>`, `insert(i, v)` and
`remove(i) -> T` (panic out of range), `reverse`, `clear`, `slice(from, to)` (copy, half-open,
panics), `sort` (ordered elements), `sort_by(fn(a: T, b: T) -> bool)` (any `T`; the predicate
is strict less-than), `sort_by_key(fn(T) -> int)` (one key call per item), `join(sep)`.
Sorts are **stable**. The native backend uses a stable radix path for integers and integer
keys, and the shared merge semantics for other values and custom predicates.

**Map and OrderedMap methods (v0.5, implemented):** `clone`, `get` → `Option<V>`,
`set` (also `m[k] = v` sugar), `insert(k, v) -> bool` (false leaves the old value),
`reserve(capacity)`,
`len`, `contains`, `remove(k) -> bool`, `keys` → `List<K>`, `values` → `List<V>`, `clear`.
`Map` makes no iteration-order promise. `OrderedMap` promises insertion order;
updating a key keeps its place, while removing and reinserting it moves it to the
end. Lookup is hash-indexed (O(1)) in both backends, and `remove` is amortized
O(1). Plain Map swap-removes entries, so deletion may change enumeration order;
OrderedMap keeps stable entry slots and compacts holes as needed.

Iterate a map directly with two bindings:

```
for key: string, value: int in counts {
    io.println("{key}: {value}")
}
```

This walks the map's entry storage in O(n) time. It does not build a `keys()`
or `values()` list and does not hash each key again. Each turn copies only the
current key and value into the loop bindings. `Map` keeps no order promise;
`OrderedMap` visits insertion order. A structural change (`insert` of a new
key, `remove`, `clear`, `reserve`, or bracket/set of a new key) invalidates the
iterator and panics before another entry is read. Replacing the value of an
existing key is allowed.
Direct map iteration is currently limited to synchronous functions.

Bracket reads are checked, required reads: `list[i]` panics when the index is
outside the list, and `map[key]` panics when the key is missing. Use
`list.get(i)` or `map.get(key)` when absence is expected; both return `Option`.
Bracket assignment stays `list[i] = value` and `map[key] = value`; List and
Map bracket assignment does not have compound forms. Fixed arrays support
numeric compound element assignment because their element is a real inline
place.

Map values may be wide structs, fixed arrays, SIMD vectors, slices, inline
Option/Result values, or decimals. Their nested ARC fields are retained, dropped,
cloned, returned by `get`, and copied into `values()` recursively. Struct,
fixed-array, and inline Option/Result keys work when their contents satisfy
`Eq` and `Hash`; `keys()` returns their real value layout. Stored keys own nested
ARC fields, while `get`, `contains`, and `remove` use allocation-free stack keys.

List, Map, and OrderedMap are move-only unique-buffer values. Binding,
assignment, storage, and return use `move`; function parameters and loop reads
borrow by default. `clone()` makes an independent collection buffer, so changing
the clone does not change the original. Class elements remain shared ARC
references. A collection holding another move-only value cannot be cloned yet,
because that needs a type-specialized deep clone. Likewise, `get`/index reads
cannot copy a move-only element; List `pop`/`remove` are consuming reads.

Everything has methods:

```
(-5).abs()          // 5
"42".to_int()       // Result<int>
3.7.round()         // 4
xs.len()
```

## Functions

```
fn add(a: int, b: int) -> int {
    return a + b
}

pub fn log_line(msg: string) {      // no -> means no return value
    io.println(msg)
}
```

**There is no implicit tail return.** A trailing expression is a statement like any other — its
value is discarded, not returned. A function with a `->` must say `return`, on every path:

```
fn wrong() -> int {
    var sum: int = 0
    if flag() { sum = 1 }
    sum                             // error: 'wrong' must return int
}
```

The checker rejects a body that can finish without returning. A path counts as returning if it
ends in `return`, an `if`/`else` where both sides return, a statement `match` whose arms all
return, or a `for { }` with no `break` (which never finishes at all).

**Trailing parameter defaults.** A parameter may declare a constant default —
a literal, a negated numeric literal, or `none` — and every parameter after a
defaulted one needs a default too. A call that leaves trailing arguments out
gets the declared constants, materialized at the call site by the checker, so
no ABI or backend knows defaults exist. Defaults are by-value only (`move` and
`inout` parameters cannot have them), never on `extern "C"` signatures, and a
function used as a value keeps its full arity. There are **no named
arguments** and **no overloading** — one name, one signature; a defaulted
tail is the one sanctioned way to make an argument optional.

```
fn greet(name: string, punct: string = "!", times: int = 1) -> string { ... }

greet("hi")            // punct "!", times 1
greet("hi", "?")       // times 1
greet("hi", "?", 3)
```

### Anonymous functions

`fn` without a name is a closure. It captures the variables around it. `fn(int) -> int` is also the type of a function.

```
let double: fn(int) -> int = fn(x: int) -> int { return x * 2 }
xs.map(fn(x: int) -> int { return x * 2 })
```

**Capture by move.** `fn(...) move(a, b) -> T { ... }` captures the listed
enclosing locals by move: the closure owns them, the enclosing bindings are
spent (using one afterward is a use-after-move error), and each owned capture
is released exactly once when the closure value dies. This is how a move-only
value — a socket, a `Box`, a `List` — lives inside a callback and is torn
down with it. Each listed name must be an enclosing local the body actually
uses; `inout` parameters cannot be move-captured. Closure values stay
ordinary shared `fn` values: copying one shares the same closure (and its
captures) rather than duplicating them, so single-ownership of the capture is
never violated. Inside the body a move capture still reads as a borrowed
binding — it cannot be moved out again, because the closure may be called
more than once.

## Classes

```
class User {
    name: string
    age: int = 0            // default value
    pub email: string       // visible from other packages
    priv token: string = "" // visible only inside User
    static created: int = 0

    pub fn init(name: string) {
        self.name = name
    }

    fn greet() -> string {
        return self.private_greeting()
    }

    priv fn private_greeting() -> string {
        return "hi {self.name}"
    }

    static fn guest() -> User {
        return new User("guest")
    }
}

let u: User = new("jul")
```

- Methods are instance methods by default. Their `self` binding is implicit and
  available in the body; it is never written in the parameter list.
- `static fn` is required for class statics. A static method has no `self` and is
  not inherited.
- An unmarked method is package-visible, `pub fn` is visible from other
  packages, and `priv fn` is visible only inside its exact declaring class or
  struct. The same rule applies to `priv static fn`, `priv inout fn`, and
  `priv fn init`.
- A class field may also be `static`. It needs an initial value and is read or
  written through its declaring type, such as `User.created += 1`. Static
  fields are initialized once before `main`, in declaration order, and are not
  inherited. Generic classes cannot declare static fields.
- `new Class(...)` and target-typed `new(...)` are the class-construction forms.
  Both follow the class's `init` rules. `new(...)` gets its class from the
  declared result, assignment target, return type, or function parameter. It is
  an error when that context does not name a concrete class. Class field
  literals and plain `Class(...)` calls are errors.
- Named statics remain for fallible or non-construction operations, including
  `File.open`, `MMap.open`, `MMap.open_shared_memory`, `KV.open_in`, `Bytes.from`,
  `RawPtr.alloc`, `Slice.from_raw`, `TcpListener.bind`, `TcpStream.connect`,
  `UdpSocket.bind`, `Address.resolve`, and every SIMD family's `splat`, `of`, `load`
  and `load_unaligned`.
- **Anything that produces an object belongs on that object's class**, as `new` or as a
  named static — never as a module function. A module function is for work that yields
  no object: `io.println`, `os.args`, `time.monotonic_nanos`, `random.below`,
  `cpu.has`, `intrinsic.popcount`, `fmt.pad_left`. So it is `TcpListener.bind(...)`,
  not `net.listen(...)`, and `MMap.open_shared_memory(...)`, not `shm.open(...)`. This is the
  line between the OOP surface and the handful of free functions, and it is the one
  rule to check when adding to `stdlib/std`.
- Infallible constructor-like builtins use `new`: `Bytes`, `Box`, `Arena`,
  `Shared`, `Mutex`, `Channel`, and `AtomicInt`.

### Singleton classes

`singleton class App` declares one eagerly created class value. Code reads it
as `App.instance`; `new App()` is an error. A singleton is concrete and
non-generic, has a zero-argument initializer, cannot declare `deinit`, and
cannot be extended. Static fields finish initialization before singleton
instances are created.

### Partial classes

`partial class Name` writes one class in more than one place. Every part
says `partial`, all parts must sit in the same package, and the members of
every part belong to the one class the parts describe together. It exists so
a class too large to read in one sitting can be split across files without
changing what it means.

```
// shape.b
pub partial class Shape extends Figure implements Named {
    name: string
    sides: int
}

// shape_text.b
partial class Shape {
    fn describe() -> string { return "{self.name} has {self.sides} sides" }
}
```

- **Exactly one part may carry the header** — modifiers (`pub`, `abstract`,
  `singleton`, `unique`), generic parameters, `extends` and `implements`.
  Every other part is written bare, as `partial class Name {`. Two parts
  carrying a header is an error: there would be no single answer to what the
  class is.
- The part carrying the header is the primary, **whichever file it is in**.
  Load order does not decide it, so moving a part between files never
  changes the class.
- Fields may be declared in any part. Field order follows the order the
  parts are declared in, so layout is decided by the source, not by
  filenames.
- A member declared in two parts is a duplicate member, exactly as it would
  be inside one class body.
- A plain `class` colliding with a `partial class` of the same name is still
  a redeclaration. Both sides must say `partial` to be joined.
- `partial` is contextual: it means something only directly before `class`,
  and stays available everywhere else as an ordinary name.

### init and deinit (v0.7, implemented)

`init` is the constructor body. `new Class(...)` or target-typed `new(...)`
allocates the object and invokes it. Like every instance method, `init` has
implicit `self`.

```
class Conn {
    host: string
    hits: int = 0

    pub fn init(host: string) {
        self.host = host
    }

    fn deinit() {
        io.println("closing {self.host}")
    }
}

let c: Conn = new Conn("db1")
```

- `init` returns nothing and runs on a fresh object: fields with defaults start at them, the
  rest start unassigned. **Until every field is assigned, the body is a straight-line prefix**:
  each statement either assigns a field (`self.f = ...`) or touches `self` only by reading
  fields already assigned — no method calls, no passing `self` on, no `return`, and no string
  interpolation (its pieces are checked too late to prove them safe). The checker proves all
  of it, so a half-built object can never escape. After the last field, anything goes.
- A class whose fields all have defaults receives an implicit zero-argument
  initializer. A class with any required field must declare `init`.
- Construction that can fail stays a named static, such as
  `static fn open(...) -> Result<Conn>`; it may call `new Conn(...)` after validation.
- Generic classes take type arguments from the declared spot or an explicit
  constructor type: `let a: Stack<int> = new()` or `new Stack<int>()`.
- `pub fn init` is what lets another package write `new Conn(...)` — the usual visibility rule.

**init and inheritance** work through `super.init(...)`, in Swift's order — own fields first:

```
class Dog extends Animal {
    breed: string
    fn init(breed: string, name: string) {
        self.breed = breed        // 1. this class's own fields
        super.init(name)          // 2. the parent's constructor, exactly once
        self.bark()               // 3. everything is assigned — anything goes
    }
}
```

- The order is what makes construction safe, not taste: a parent's init may call a method the
  subclass overrides, and by then the subclass's fields are already assigned. No vtable
  switching, no half-built reads — the checker just proves the order.
- Before `super.init`, parent fields don't exist yet — not even defaulted ones (the parent's
  init may be about to overwrite them). Assigning one is an error; `super.init` owns them.
- `super.init` runs exactly once, as a top-level statement, only inside `init`, and it is
  mandatory whenever a class above declares an init. `return` before it is an error.
- `super` is contextual. `super.method(...)` calls the nearest parent class
  implementation directly on the current object, bypassing virtual dispatch.
  It is only valid in an instance method and follows normal package visibility.
  Interfaces are not searched. `init` keeps the stricter constructor rules
  above, and `deinit` is always automatic.
- A subclass whose added fields all have defaults inherits the nearest ancestor
  initializer — `new Pup(args)` runs it on a Pup. A subclass that adds a required
  field must declare its own init.
- A class whose parent has *no* init may still declare one; its prefix then covers the
  inherited fields too, under normal field visibility rules.

`deinit` is the destructor. It runs exactly once, on whichever thread drops the last
reference, the moment the count hits zero — and before the fields are released, so the body
can still read them. Deterministic, like C++/Swift: no GC pause, no "sometime later".

- No parameters, no return value, never called by hand: construction calls `init`, death
  calls `deinit`.
- A subclass `deinit` runs first, then its parent's, automatically — no `override`, ever.
- `self` must not escape a `deinit`. The object is being destroyed; storing `self` anywhere
  is use-after-free by definition.
- A panic inside `deinit` is fatal (same rule as defer).
- An object that dies **inside a reference cycle** does not get its `deinit` — a cycle never
  drops to zero on its own, so if it owns a resource, break the cycle with a
  `weak` field instead of building it.

### weak fields (zeroing references)

A class field may be declared `weak`. Its type must be `Option<C>` for a
non-`unique` class `C`; the modifier sits right before the field name and
composes with visibility (`pub weak next: Option<Node> = none`).

```
class Node {
    child: Option<Node> = none        // owning: parent keeps child alive
    weak parent: Option<Node> = none  // non-owning: zeroes when parent dies
}
```

- A weak field holds **no ownership count** on its referent. Reads produce the
  declared `Option<C>`: `some` while the referent is alive — the loaded value
  is retained for the read, so it cannot die mid-use — and `none` from the
  first moment of the referent's death, **before** its `deinit` body runs, so
  a destructor can never resurrect itself through a weak slot.
- The cycle collector never traces through a weak field, so parent/child
  graphs and stored callbacks that point back at their owners stay acyclic:
  build the back edge `weak` and both objects get their `deinit`. When the
  collector does kill a strong cycle, weak fields pointing **into** that
  cycle read `none` from the kill onward.
- The slot's storage is a zeroing handle, not the object, so weak fields are
  invisible to reflection, and a weak field's default must be `none`.
- `weak` is for instance fields of classes only: no statics, no structs, no
  locals — a local strong reference is what keeps an object alive while you
  work with it.

## Inheritance and interfaces

Classes have one base class and may implement many interfaces. Interfaces may
extend other interfaces. An abstract class may leave instance methods for a
concrete subclass to implement:

```
interface Shape {
    fn area() -> f64

    // default method bodies allowed (kills most need for abstract classes)
    fn describe() -> string {
        return "shape with area {self.area()}"
    }
}

interface NamedShape extends Shape {
    fn name() -> string
}

abstract class Drawable {
    abstract fn draw()
}

class Circle implements Shape {
    r: f64

    fn area() -> f64 {
        return 3.14159265 * self.r * self.r
    }
}

class LoudCircle extends Circle implements NamedShape {
    // overriding a real method requires the keyword — typo protection
    override fn describe() -> string {
        return "A CIRCLE. AREA {self.area()}."
    }
}

class Button extends Drawable {
    override fn draw() {}
}
```

`extends` takes one class base, while `implements` takes comma-separated
interfaces. Interface requirements and default methods are instance methods.
Static interface methods are unsupported. `abstract fn` has no body and may
appear only in an `abstract class`; abstract classes cannot be built. A concrete
class must satisfy every inherited abstract method and interface requirement.

`override` means “replace a method body or abstract method that already
exists.” It is required when replacing a concrete or abstract method from a
base class, and when replacing an interface default body. A first
implementation of a bodyless interface requirement does not need `override`.
Private methods are not inherited and never satisfy or replace class or
interface contracts, so they cannot be `abstract` or `override`. Interfaces
cannot declare private methods. Beans has no `final` yet.

**`Self` return type.** A class or interface instance method may declare
`-> Self`: at every call site the result has the receiver expression's own
static type, so a fluent chain inherited from a base class keeps the
subclass's type instead of degrading mid-chain. The guarantee is enforced in
the body — a Self-returning method must `return self` (or a chain of
Self-returning calls on `self`, which provably evaluates to the receiver).
`Self` matches only `Self` in overrides and interface conformance, carries
the owner's own type parameters on a generic class, changes no layout or ABI
(the stored result stays the declaring class), and is not available on
static methods, free functions, or async methods.

```
class Base {
    pub fn tune(v: int) -> Self { ...; return self }
}
class Special extends Base { pub fn only_here() { ... } }

new Special().tune(1).only_here()   // tune returns Special here
```

### Downcast

`as?` checks and returns an Option — never crashes:

```
let s: Shape = pick_a_shape()
match s as? Circle {
    some(c) => io.println("circle, r = {c.r}"),
    none    => io.println("something else"),
}
```

(`as` stays for explicit numeric casts and upcasts only.)

## Enums

User-defined variants, snake_case, payloads allowed. Built for `match`:

```
enum Status {
    active
    suspended
    closed
}

enum Payment {
    cash
    card(number: string)
    transfer(iban: string, amount: decimal)
}

fn describe(p: Payment) -> string {
    return match p {
        cash => "cash",
        card(n) => "card ending {n.last(4)}",
        transfer(iban, amt) => "sent {amt} to {iban}",
    }
}
```

Enums are objects too — they can carry methods (`fn label() -> string { ... }`
inside the enum body, with implicit `self`).

## Option and Result

Core rule: **a function that can fail says so in its return type.**

```
fn find(users: List<User>, name: string) -> Option<User> {
    for u: User in users {
        if u.name == name {
            return some(u)
        }
    }
    return none
}

fn parse_age(s: string) -> Result<int> {
    let n: int = s.to_int()?         // ? = if err, return it up. else unwrap.
    if n < 0 {
        return err("negative age")
    }
    return ok(n)
}
```

- `some none ok err` are prelude names (enum variants), **not keywords**.
- `panic(message: string) -> unit` is a prelude function. It reports the call
  location and message, then exits with status 3. It never returns and does not
  run defers.
- `Result<T>` means `Result<T, Error>` — `Error` is a built-in class (msg, kind, cause). Custom error types via `Result<T, MyError>`.
- **`err(message, kind)`** sets the `kind` slug as well as the message:
  `return err("closed after 3 of 8 bytes", "eof")`. Only for the built-in `Error` —
  a custom error type carries its own fields, so `err(value)` is the form there. Without
  this a Beans-written package could not produce the slugs the stdlib convention is
  built on; only native builtins could.
- `?` propagates. `match` handles. Helpers for the rest:

```
match parse_age(input) {
    ok(n)  => io.println("age {n}"),
    err(e) => io.println("bad: {e.msg}"),
}

let age: int = parse_age(input).or(18)                    // fallback
let u: User = find(users, "jul").expect("must exist")     // crash with message

let adult: Option<User> = find(users, "jul").filter(fn(u: User) -> bool {
    return u.age >= 18
})
let label: Option<string> = adult.map(fn(u: User) -> string {
    return u.name
})
let parsed: Result<int> = load_text().and_then(fn(s: string) -> Result<int> {
    return s.to_int()
})
let count: int = parsed.recover(fn(e: Error) -> int { return 0 })
```

`Option` has `map`, `and_then`, and `filter`. `Result` has `map`,
`and_then`, and `recover`. They are instance methods on the value, not functions
in `std.option` or `std.result`. These methods copy the active input payload, so
its type must implement `Clone`. Their inline, boxed, and null-niche layouts do
not change.

Native `Option` uses three layouts without changing source semantics: pointer
payloads use null as `none`, wide inline values such as structs, fixed arrays,
SIMD vectors, slices, and nested wide values use `{has_value, payload}`, and
small scalar payloads keep the boxed enum ABI. A `Result` with either wide
payload uses `{is_error, ok_payload, error_payload}`; its inactive payload is
zero. The compiler retains and drops references nested inside these aggregates.
Wide Options and Results pass and return by value and do not allocate their own
enum box. List and Map values can store them inline, including nested ARC fields.
Box, Arena, Shared, Mutex, Channel, and thread results can store them inline too.
User enums remain ARC values, but wide payloads use their real aligned layout
inside the enum object and participate in matching, equality, hashing, and ARC.

## Control flow

One loop keyword, five shapes:

```
for { }                        // forever
for x < 10 { }                 // while
for i: int in 0..10 { }        // range, exclusive. 0..=10 inclusive
for u: User in users { }       // any iterable
for k: string, v: int in map { } // direct map key/value iteration
```

`break`, `continue`, `return` as usual. No `do-while`, no `switch`, no ternary, no `++`/`--`.

### if and match as values

```
let grade: string = if score >= 90 { "a" } else { "b" }
```

No `return` in there — and that's on purpose, not an inconsistency. `return` always means exactly one thing in beans: *leave the function*. If that branch said `return "a"`, it would exit the whole function, not produce a value. So the rule is:

- **Statement position:** branches hold statements, `return` works as usual.
- **Value position:** each branch is exactly one expression, and that expression is the value. It's a ternary that reads like an if. Need multiple statements in a branch? Use a `var` and the statement form.

`match` works the same way: `pattern => expression` in value position, and arms can pattern-match on values, variants, ranges, `_`:

```
match code {
    200        => "ok",
    301 | 302  => "moved",
    400..=499  => "client bug",
    _          => "who knows",
}
```

**Statement position** additionally allows block arms — several statements, no value (v0.4):

```
match ch.receive() {
    some(v) => {
        total += v
        io.println("got {v}")
    }
    none => { break }
}
```

The `{` must follow `=>` on the same line. A block arm in value position is an error — same rule as if. (Corner case: a map literal as an arm *value* needs parens, `x => ({"a": 1})`.)

## Generics

Monomorphized (a real copy per type, like C++ templates — this is a speed feature):

```
class Stack<T> {
    items: List<T> = []

    fn push(x: T) { self.items.push(x) }
    fn pop() -> Option<T> { return self.items.pop() }
}

struct Pair<T> {
    left: T
    right: T
}

fn largest<T implements Order>(xs: List<T>) -> Option<T> { ... }
fn index<K implements Eq & Hash, V>(key: K, value: V) -> Map<K, V> { ... }
```

The compiler-known interfaces are `Clone`, `Eq`, `Hash`, `Order`, `Send`, and `Sync`.
Bounds are checked when a generic function or type is used, and generic bodies
can only use operations promised by their bounds. `Order` also promises `Eq`.
User interfaces, including imported interfaces, may also be bounds. Generic
code may call the instance methods promised by those interfaces.

`Map<K, V>` and `OrderedMap<K, V>` require `K implements Eq & Hash`. Collection
`clone()` is available only when every stored type is `Clone`; ordering and
equality methods likewise require `Order` or `Eq`. Unknown interfaces are errors,
not ignored notes.

## Concurrency

Direction: **OS threads, not green threads.** Reason: green threads make every
C/C++ call expensive (Go's cgo problem — stack switching at the boundary).
Beans lives on C++ interop and wants to write databases, so real threads it is.
Closures plus `std.thread` do the whole job.

```
import std.thread

// spawn: run a closure on another thread
let t: Thread<int> = thread.spawn(fn() -> int {
    return heavy_work()
})
let n: int = t.join()               // wait + get the value

// mutex wraps the data itself — no way to touch it without holding the lock
let ledger: Mutex<Ledger> = new Mutex(new Ledger())
ledger.with_lock(fn(l: Ledger) {
    l.post(entry)                   // locked for exactly this block, auto-unlock
})

// channels move work between threads
let ch: Channel<string> = new Channel(64)      // buffered
ch.send("job")
let job: Option<string> = ch.receive()         // none when closed and empty

// atomics for plain counters
let hits: AtomicInt = new AtomicInt(0)
hits.add(1)
```

- `Mutex<T>` holds the value inside it — `with_lock` locks, runs your closure, unlocks on any exit path. No forgotten unlocks.
- A `thread.spawn` closure may capture only `Send` values and must return a
  `Send` value. Plain class references, List, Map, Box, Arena, Bytes, File, and
  MMap are non-`Send`. Scalars, immutable strings, AtomicInt, Mutex, a Channel
  of `Send` values, and `Shared<T>`/`Weak<T>` where
  `T implements Send & Sync` can cross.
  This makes `class` a local ARC reference by default; wrap shared mutable data
  in Mutex instead of silently racing it.

### async and await (v0.9, first version implemented)

Asyncness is an **effect on the callable**, not a type. `async fn f() -> R`
declares a function whose calls must be waited on; the call still has type
`R`. There is no public task, future, executor, or polling protocol — the
compiler and runtime schedule everything behind the scenes, on the one
thread that entered `main`. `thread.spawn` stays the tool for CPU-heavy or
blocking work.

```beans
import std.io

async fn double_later(a: int) -> int {
    return a * 2
}

async fn fetch_size(a: int) -> Result<int> {
    let doubled: int = await double_later(a)   // doubled: int
    return ok(doubled)
}

async fn main() {
    let n: Result<int> = await fetch_size(21)
    io.println("{n.or(-1)}")
}
```

- **`async` and `await` are not keywords.** `async` means something only
  immediately before `fn` — at the top level, in class and enum bodies, and
  in interfaces — and `await` only inside an async body. Everywhere else
  both stay ordinary identifiers, so existing functions, locals, fields, and
  methods by those names keep working, as do user classes named `Task` or
  `Future`.
- **Every async call is waited on, exactly where it happens.** A call to an
  async function is legal in two positions only: directly under `await`, or
  as the initializer of an `async let`. Anywhere else — bare statement,
  argument, receiver, stored into a variable — it is refused: *async call
  must be awaited or started with 'async let'*. A synchronous function
  cannot call an async one at all (*'f' is async and can only be called
  from an async function*), and an async function cannot be stored as a
  `fn` value. There is no run/block_on escape hatch back into sync code.
- **`async let` starts a structured child.** `async let x: R = f(args)` is
  legal only inside an async body; the initializer must be a direct async
  call, the arguments evaluate right there in the parent, and the child
  belongs to the enclosing lexical scope. The written type is the eventual
  result: `await x` produces `R`, exactly once — a plain read is refused
  (*async let binding 'x' must be awaited*), so the hidden handle can
  never escape, and a second await is refused (*was already awaited*).
  Leaving the scope without awaiting — early `return`, `?`, `break`,
  `continue`, or falling off the end — cancels the unfinished child
  before the parent's own result lands: its armed `defer`s run newest
  first, then everything its body still held drops, last created first —
  the order plain locals drop in — and children it started cancel in
  cascade the same way. The parent never finishes while a child is still
  running or cleaning.
- **When children run.** The child is registered the moment the
  `async let` executes, and its body first runs at the earlier of two
  points: its own `await`, or the parent's next suspension. Every time a
  frame is about to report pending — its awaited call parked or still
  working — it first gives each of its live children one poll, first
  declared first, and that full pass repeats on every re-poll, so a
  busy or repeatedly waking child cannot starve its siblings. A child's
  own suspensions reach its children the same way, so scheduling depth
  follows the task tree and nothing else. Between suspension points a
  task runs synchronously and uninterrupted; there is no preemption and
  no `yield`.
- **`await` takes a direct call and produces the declared result.** The
  operand must be a call to an async function: `await f(x)` has type `R`,
  awaiting anything else is refused (*await needs a direct call to an async
  function*; a sync call gets *this call is synchronous*). `await` binds
  tighter than every binary operator and looser than call, field, and
  index. `?` and `as` are the exception: they apply to the value the await
  produced — `await f(x)?` unwraps the awaited `Result` — so error
  propagation reads without parentheses.
- **`async fn main()` drives itself.** Declare the entry point async — no
  parameters, no type parameters, no result, same as ever — and a hidden
  single-threaded executor drives the body to completion. Nothing to
  import, nothing to call. A synchronous `fn main()` stays exactly as it
  was; it just cannot call async functions.
- **Checking uses the declared result.** `return`, `?`, and missing-return
  analysis in an async body use `R`. Overrides and interface
  implementations must match asyncness — a sync method never silently
  satisfies an async declaration or the other way around. `Result`,
  `Option`, generics, methods, and move-only values all work across
  suspension points.
- **Cleanup stays synchronous and exact.** `await` is refused inside
  `defer` and inside closures; `init` and `deinit` cannot be async. A
  `defer` armed before a suspension survives any number of them and runs
  exactly once — on return, on `?` propagation, and on cancellation when
  a scope's unfinished children are torn down. A completed child's
  locals drop at its completion; a cancelled child's drop during the
  cancellation, armed defers first, then values last-created-first. A
  panic inside an async body stops the program with the original source
  position, like every other panic; defers do not run on a panic (the
  base rule). A panic inside a never-awaited child surfaces when the
  scheduler first polls it — at the parent's next suspension.
- **What an async fn cannot do:** take `inout` parameters, be
  `extern "C"` (wrap the C call in an async Beans function instead), be
  `feature`-gated, or be an instance method on a `unique class` (statics
  are fine). The `inout` and unique-receiver rules share one honest
  reason: the body lowers to closures that outlive the call, and a
  closure cannot capture an `inout` parameter or keep a move-only
  receiver borrowed past the call that lent it. A **directly awaited**
  call could hold such a borrow safely — the caller is suspended for the
  child's whole life — but an `async let` child runs beside its caller
  and could not, and one lowering serves both call forms, so the
  declaration is refused rather than the call. Pass the value in and
  return the new one. `await` cannot sit inside string interpolation —
  bind the value to a local first — and cannot suspend while a `for`
  element or `match` payload borrows a move-only value.
- **Scheduling is hidden and cooperative.** An async call suspends only at
  `await` points; between them it runs synchronously on the executor's one
  thread. Long CPU work therefore blocks every other task — put it on
  `std.thread`. Cancellation is cooperative: it takes effect at suspension
  points, never mid-statement.
- **Readiness awaits.** `await net.readable(handle)` (and
  `writable`) suspends until the descriptor is ready — a socket's
  `.poll_handle()`, or any pollable descriptor on POSIX (Windows readiness is
  socket-handle only). Before the hidden reactor opens, POSIX validates with
  allocation-free `fcntl(F_GETFD)` and Windows with `getsockopt(SO_TYPE)`.
  An invalid watched number therefore cannot be reused for the reactor's own
  poller or wake channel. While one child is parked,
  its runnable siblings keep running through the scan above; when
  nothing can move and something is parked, the hidden driver blocks in
  the platform poller — never a busy spin — and the OS wakes it. When
  nothing can move and nothing is parked, the program stops with *async
  deadlock: every task is waiting and none is parked on readiness*.
  Level-triggered: already-ready completes on the spot. A readiness that
  can never come does not hang: an await on a closed or invalid
  descriptor finishes with `false`, including a descriptor closed while
  the await was parked. Two awaits parked on one descriptor at the same
  time are refused with a panic — the poller keys registration by
  descriptor, so the second would silently cancel the first; await the
  first before starting the second (sequential re-parks on one
  descriptor are fine). At most 64 awaits can be parked per executor. When
  `async fn main` finishes, the hidden poller closes and its state
  resets, so a full run leaves no descriptor behind.
- **Closing a watched descriptor.** Every close that goes through the
  runtime — a stream's `close()`, a drop of the owning handle, files,
  mappings, process streams, signal sources — marks every await parked on
  that descriptor, even when the close runs on another thread, on every
  platform including Windows. Park entries live in a locked shared registry,
  carry a stable token, and point at the owning reactor only through its
  generation-checked wake handle. The close marks under the registry lock,
  then wakes after unlocking; reactor shutdown makes any late copied handle
  stale rather than letting it address a reused descriptor. The marked await
  finishes `false` on its next turn without touching the descriptor
  number again, so the number is immediately safe to reuse: a fresh
  await parked on the reused number watches only the new resource, and
  the old await can neither wake off it nor block it. A close performed
  *outside* the runtime (raw extern C code) is caught on POSIX only
  while the number stays unused, and cannot be told apart from a live
  descriptor once the number is reused — close through the handle, not
  behind it. The same borrow rule guards the other direction: a
  `.poll_handle()` number is borrowed, so closing the handle and reusing the
  number *before* a child that holds the number first suspends means
  that child watches whatever the number means by then.
- **Runtime profiles.** Pure-compute async — `async fn`, `await`,
  `async let`, cancellation — builds and runs under every runtime
  profile, `minimal` and `freestanding` included: a program that never
  imports `std.net` gets an async runtime with no poller in it, and its
  binary carries no polling or socket code. Readiness awaits ride
  `std.net`, which needs the full profile; under a smaller profile that
  import is refused at check time, naming the capability. A pure async
  program that somehow ends up pending reports the async deadlock above
  rather than reaching for a poller it does not have.
- **Not yet in this first version:** dynamic task groups, detached tasks,
  async closures, `inout` on a directly awaited call. They layer on this
  model without changing it.

## Targets and the build (v0.8, implemented)

`beansc build` compiles for one **selected target**, described completely by the
compiler rather than inferred from the machine it runs on. The host is the
default; `--target` picks another.

```bash
beansc build app.b                                    # the host
beansc build --target x86_64-unknown-linux-gnu app.b  # somewhere else
beansc build --target aarch64-unknown-linux-gnu --emit obj app.b -o app.o
```

Supported targets: `arm64-apple-darwin`; Linux GNU
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`,
`riscv64-unknown-linux-gnu`, `i686-unknown-linux-gnu`,
`armv7-unknown-linux-gnueabihf`, `arm-unknown-linux-gnueabi`,
`arm-unknown-linux-gnueabihf`, `loongarch64-unknown-linux-gnu`,
`powerpc64le-unknown-linux-gnu`, `powerpc-unknown-linux-gnu`,
`powerpc64-unknown-linux-gnu`, `s390x-unknown-linux-gnu`; Linux musl
`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`,
`riscv64-unknown-linux-musl`, `loongarch64-unknown-linux-musl`,
`powerpc64le-unknown-linux-musl`, `powerpc64-unknown-linux-musl`; Windows
`x86_64-pc-windows-gnu`, `i686-pc-windows-gnu`,
`x86_64-pc-windows-gnullvm`, `aarch64-pc-windows-gnullvm`,
`x86_64-pc-windows-msvc`, `i686-pc-windows-msvc`,
`aarch64-pc-windows-msvc`; plus `wasm32-wasip1`,
`wasm32-unknown-unknown`, `thumbv7em-none-eabi`, and
`riscv32-unknown-none-elf`.
Common spellings normalize to those, so `aarch64-apple-darwin`,
`x86_64-linux-gnu`, `x86_64-w64-mingw32`, `aarch64-w64-mingw32`,
`i686-w64-mingw32`, `riscv64gc-unknown-linux-gnu`, `arm-linux-gnueabihf`,
`riscv64gc-unknown-linux-musl`, `ppc64le-linux-gnu` and
`riscv32imac-unknown-none-elf` all
work and still produce one canonical name in the IR and in every cache key. An
unknown triple is a plain compile error listing what is supported.

`riscv64-unknown-linux-gnu` (rv64gc/LP64D) and `powerpc64le-unknown-linux-gnu`
(64-bit little-endian POWER) are **hosts**. Beans compiles for them, the binaries
run byte-for-byte against the interpreter under qemu, and `beansc` *itself* —
cross-built to the target and run under `qemu-user` — reaches its own self-compile
fixed point and drives the example loop byte-identical, which is the bar for
hosting the compiler. The hosted gate also checks that the cross-built compiler's
no-`--target` default selects the real host and uses it to build a program;
that is what proves a source checkout can build a compiler there.
`test/linux_arch.sh <arch>` is the program gate and `test/linux_hosted.sh <arch>`
the hosted one; both run in CI. Neither baseline has
a usable vector unit (rv64gc has no V, ppc64le no VSX lowering), so `SimdNxT` and
inline assembly are refused by name at check time; both carry portable `decimal`.

The RISC-V Linux target is exactly rv64gc with the LP64D ABI. Both drivers pass
`-march=rv64imafdc -mabi=lp64d` to Clang, and `m`, `a`, `c`, `f` and `d` cannot
be disabled with `--features`: removing `d` while keeping LP64D, or removing `a`
while still promising 64-bit atomics, would describe two different targets.
`cpu.has` reports those five baseline extensions on a running RISC-V binary;
`BEANS_CPU_FEATURES` can still mask them down for dispatch tests.

ppc64le is the target that forced one layout fact into the open. The compiler
emits textual IR with a `target triple` but no `target datalayout`, so LLVM lays
out `i128` from the triple's default — and the ppc64le default drops `i128:128`,
aligning a stack `decimal` to 8 where the C runtime, compiled
through Clang's frontend, assumes 16. A decimal spilled to the stack and handed to
the runtime was accessed half-off, silently zeroing its i128 coefficient while the
i64 scale survived — `20.00` read back as `0.00`. Codegen now states `align 16` on
every decimal stack slot and emits its `{i128, i64, i64}` value as the same
32-byte size as the C `BDec`. The spare word is an `i64`, not an equivalent byte
array: LLVM's s390x ABI lowering reads a trailing byte array from wrong offsets
when earlier arguments fill the registers. Beans function calls therefore pass a
decimal as scalar `i128 coefficient, i64 scale` arguments and rebuild the spare
word in the callee; the aggregate never crosses the target's function ABI.
x86-64 and riscv64 tolerate the under-alignment,
which is why only POWER surfaced it.

`i686-unknown-linux-gnu` (32-bit i386 System V) and `armv7-unknown-linux-gnueabihf`
(32-bit ARM EABI hard-float) are hosted targets. Portable decimal removed the
old frontend-`__int128` blocker; the program and compiler fixed-point sweeps run
under `qemu-i386` / `qemu-arm` (`test/linux_arch.sh` and `test/linux_hosted.sh`). Two
32-bit facts had to be stated rather than assumed. The i386 SysV ABI caps every
fundamental scalar at 4-byte alignment — `long long` and `double` included, where
the ARM EABI and RV32 keep 8 — so `Error`'s i64 field sits at offset 4, not 8, and
codegen that assumed 8 read `kind` one slot past the object and faulted the instant
an error printed; the scalar cap is now a target fact honoured by both layout
paths. And the runtime needs `_FILE_OFFSET_BITS=64` on 32-bit Linux, or glibc's
`readdir` overflows an inode past 2^32 — routine on the overlay/tmpfs filesystems
containers use — and returns nothing, so `Dir.list` came back empty. ARMv7 does
have lock-free 64-bit atomics through LDREXD/STREXD, so its atomic example runs;
SIMD is the main capability ARMv7 still refuses.

The six musl hosts use the same machine ABI facts as their GNU peers, but musl
is a distinct target environment. The target triple is part of the runtime
cache key and every Clang invocation, so a GNU sysroot or cached runtime object
cannot leak into a musl build. CI performs a clean build, self-hosted
fixed point and differential loop inside Alpine for x86-64, ARM64, RISC-V 64
PowerPC64LE and LoongArch64. Big-endian PowerPC64 uses a pinned musl.cc sysroot
and the same hosted gate under qemu. Rust's
`riscv64gc-unknown-linux-musl` spelling is accepted as an alias; emitted LLVM
uses Clang's accepted `riscv64-unknown-linux-musl`.

The registered 32-bit targets are not a detail: a pointer
is four bytes, so `size_of(RawPtr<T>)` folds to 4 and every object's pointer-slot
stride follows. Three have no operating system, and **a target with no OS requires
`--runtime freestanding`** — asking for a hosted runtime there is refused with a
message rather than an undefined `pthread_create` at link time.

### The seven Windows targets

Beans registers the same seven Windows host ABIs as Rust: GNU/MinGW on x86-64
and i686, GNullVM/UCRT on x86-64 and ARM64, and MSVC on x86-64, i686 and ARM64.
They produce COFF objects and `.exe` files. GNU and GNullVM builds keep their
compiler support code in one static executable; MSVC builds use the native
MSVC libraries from a developer command prompt. The runtime uses Win32 threads
directly and does not require winpthreads.

| target | kind | pointer | stack | `decimal` | notes |
|---|---|---|---|---|---|
| `x86_64-pc-windows-gnu` | GNU | 8 | 16 | yes | MinGW, MSVCRT |
| `i686-pc-windows-gnu` | GNU | **4** | **4** | yes | MinGW, MSVCRT |
| `x86_64-pc-windows-gnullvm` | GNullVM | 8 | 16 | yes | LLVM-MinGW, UCRT |
| `aarch64-pc-windows-gnullvm` | GNullVM | 8 | 16 | yes | LLVM-MinGW, UCRT |
| `x86_64-pc-windows-msvc` | MSVC | 8 | 16 | yes | native MSVC ABI |
| `i686-pc-windows-msvc` | MSVC | **4** | **4** | yes | native 32-bit MSVC ABI |
| `aarch64-pc-windows-msvc` | MSVC | 8 | 16 | yes | native ARM64 MSVC ABI |

- **Minimum Windows version is Windows 10.** Windows on ARM has no earlier
  release worth targeting, and the runtime's Win32 calls are the Windows 10 set.
- **`i686` is a compatibility target.** 32-bit x86 is its own
  architecture in the compiler rather than a narrow mode of x86-64, because it
  agrees with it on almost nothing that matters: four-byte pointers, a
  four-byte stack alignment rather than sixteen. Decimal uses two portable
  64-bit limbs. 64-bit atomics remain available, unlike on the embedded boards,
  because `CMPXCHG8B` makes them genuinely lock-free.
- **Every row has a native Windows build and hosted job.** The job reaches a
  byte-identical stage-2/stage-3 fixed point, then makes the hosted compiler
  build and run `hello`. The current proof state is
  tracked in `targets/support.tsv`; a wired job is not marked passed until it
  has run on the matching Windows machine.
- **`std.asm` has no rows on 32-bit x86**, so inline assembly is refused there.
  This follows the existing rule that value rows exist only on 64-bit
  architectures: `mov $0, $1` with a 64-bit operand on a 32-bit machine moves
  the low half and silently drops the rest.
- **`intrinsic.crc32c` is refused on 32-bit x86.** It takes a 64-bit
  accumulator, and LLVM has no `.64.64` form of the instruction there. SSE4.2
  being present says nothing about it.
- **Signals are refusing stubs on every Windows target.** Windows has no
  `signalfd` and no `kqueue`, and the language's contract is that a watched
  signal is blocked and read from a descriptor rather than handled — which
  Windows cannot express. Every `std.signal` operation reports the gap in a
  sentence; the symbols still link because the compiler's own interpreter
  imports `std.sig`.
- **CPU feature detection on Windows/ARM uses `IsProcessorFeaturePresent`,**
  the documented API. It answers for `crc`, `aes`, `sha2`, `lse` and
  `dotprod`. `fp16` and `sha3` are reported **absent** rather than guessed,
  because Windows exposes no flag for either — claiming a feature the OS will
  not confirm is how a program ends up trapping on an instruction the machine
  does not have.

Build options:

| option | meaning |
|---|---|
| `--target <triple>` | the target to compile for; default is the host |
| `--cpu <generic\|native\|name>` | CPU model; `native` is a host build only |
| `--features <+f,-f,...>` | enable or disable CPU features |
| `--sysroot <path>` | target sysroot for a cross link |
| `--cc <path>` | C driver to use, default `clang` |
| `--linker <name>` | passed through as `-fuse-ld=<name>` |
| `--emit <bin\|obj\|static\|shared\|ir>` | choose a binary, object, archive, shared library, or `.ll` |
| `--ar <path>` | static archive tool, default `ar` |
| `--header <path>` | write a C header for `pub extern "C"` library exports |
| `--release`, `--lto` | optimization level and link-time optimization |

Every setting is validated **before** any native compilation: an unknown triple,
an unknown CPU for that architecture, a feature that architecture does not have,
an attempt to remove one of rv64gc's required baseline extensions,
a `--features` entry missing its `+`/`-`, a `--sysroot` that is not a directory,
a missing `--cc`, and `--cpu native` on a cross target all fail with a specific
message and a non-zero exit. Tools are executed directly, never through a shell,
so a path or feature name is never parsed as shell syntax.

`--emit obj` and `--emit ir` are how a cross target is checked without a sysroot:
a cross *compile* needs no target libraries, only a cross *link* does.

### What a target can refuse

A capability the selected target does not have is a **check-time error naming it**,
not a link error and never silently different code:

| refused | on | because |
|---|---|---|
| `decimal` | `thumbv7em-none-eabi`, `riscv32-unknown-none-elf` | these freestanding runtime profiles omit portable decimal |
| `Atomic<i64>`, `Atomic<u64>` | the first two only | ARMv7-M's LDREX/STREX and RV32A's LR.W/SC.W are word-sized; a 64-bit atomic would become a libatomic call, which is not an atomic guarantee worth making. 32-bit x86 keeps them: `CMPXCHG8B` is a real instruction |
| every `SimdNxT` | the first two, and wasm32 without `--features +simd128` | the target has no enabled vector register width; wasm exposes the 128-bit families only when the standard SIMD feature is selected |
| `asm.value` / `asm.run` | `i686-pc-windows-gnu` | 32-bit x86 has no rows at all, for the reason the table below states |
| `intrinsic.crc32c` | `i686-pc-windows-gnu` | the instruction takes a 64-bit accumulator and LLVM has no 32-bit-x86 form of it |
| `--runtime full` / `minimal` | any target with no OS | there is no OS to call |

`decimal` is refused through the type name *and* through any builtin whose
signature mentions it, so `"1.5".to_decimal()` reports the same reason rather
than a missing method. This is the same bargain the runtime profiles make.

### std.target

The selected target's facts are readable from Beans, as compile-time constants:

```beans
import std.target

fn main() {
    io.println(target.triple())          // "arm64-apple-darwin"
    io.println("{target.pointer_bits()}") // 64
}
```

`triple`, `arch`, `os`, `env`, `object_format` and `endian` give strings;
`pointer_bits`, `pointer_size`, `stack_align` and `max_simd_bits` give ints. They
describe the **selected** target, so `beansc build --target X` reports X. Under
`beansc run` the selected target is always the host, because interpretation
happens here — that is why the two backends still agree byte for byte.

`max_simd_bits` follows `--cpu` and `--features`: generic `x86_64` reports 128,
`--features +avx2` reports 256, `--features +avx512f` reports 512, and
`--features -sse2` reports 0. A wasm target reports 128 with
`--features +simd128` and 0 without it.

### size_of, align_of, offset_of (v0.8, implemented)

Three compile-time layout queries. Their argument is a **type**, which is why
they are their own form rather than an ordinary call — Beans has no `f<T>()`, so
`size_of([f32; 4])` would otherwise be unwritable:

```beans
let bytes: int = size_of(Packet)
let step: int = align_of([f32; 4])
let word: int = size_of(RawPtr<Packet>)
let at: int = offset_of(Packet, count)
```

- The three names are contextual: they only mean this immediately before `(`.
- Values are **compile-time constants** of the selected target, folded once by
  the checker. `beansc build --target X` reports X's layout, not the host's, and
  the two backends read the same folded number so they cannot disagree.
- Supported: integers, floats, `bool`, `decimal`, `string`, `RawPtr<T>`,
  `Slice<T>`, SIMD values, fixed arrays (nested included), `struct` and
  `extern "C" struct`/`union`, and class or interface references.
- **A class or interface reference reports one pointer.** The object behind it is
  a heap allocation carrying a 16-byte ARC header; what a *reference* costs and
  what the object costs are different questions, and this answers the first.
- Rejected, with a specific message: a type parameter (`size_of(T)` inside a
  generic body), `Option`/`Result`/user enums — they choose between a null
  niche, an inline aggregate and a boxed form depending on payload, so there is
  no single number to report — and a size that would overflow.
- `offset_of` needs a `struct` or `union` and an actual field name; both
  failures name what was wrong and list the fields that do exist.
- `extern "C"` records follow the target's C rules, so these numbers match
  `sizeof`/`alignof`/`offsetof` in C. That is checked against Clang, not against
  the other backend.

### packed and align(N) (v0.8, implemented)

Two contextual layout modifiers, in the same modifier chain as `extern "C"`.
`packed` removes every byte of padding between fields; `align(N)` raises a
record's — or a single field's — alignment:

```beans
pub extern "C" packed struct Header { kind: u8  length: u32  checksum: u32 }
extern "C" align(64) struct Counter { hits: u32 }
extern "C" struct Slot { tag: u8  align(16) payload: u64 }
```

- Both names are contextual: `packed` only means this before `struct`/`union`,
  and `align` only when followed by `(`. A field or variable may still be called
  either.
- **Allowed only on `extern "C"` structs and unions.** A modifier that moves
  bytes only means something against a fixed byte layout, and only `extern "C"`
  records promise one. On a class it would also break the ARC header's own
  alignment. Classes, interfaces, enums and functions reject both by name.
- `N` must be a power of two and no larger than the target's maximum declared
  alignment (4096 on every supported target).
- `align(N)` on a field can only **raise** its alignment. Lowering one field is
  what `packed` on the record is for, and a record cannot have both: a field
  `align(N)` inside a `packed` record is rejected rather than letting one
  silently win, which is what C does.
- Alignment raises size the same way C does: `align(64) struct Counter` holding
  one `u32` is 64 bytes, and an over-aligned record used as a *field* starts on
  the next multiple of its alignment.
- Semantics are C's, verified against Clang for every supported target — both by
  running a printing fixture on the host and by `_Static_assert` on triples that
  cannot be run here. `extern "C"` signatures carry the modifiers into the
  generated C, so Clang keeps classifying the aggregate for the target ABI.
- Reads and writes of a packed field are emitted as unaligned accesses, because a
  packed field may sit at an offset its own type is not aligned for.

### RawPtr.alloc_aligned (v0.8, implemented)

```beans
unsafe {
    let counters: RawPtr<Counter> = RawPtr.alloc(4)          // align_of(Counter)
    let page: RawPtr<Counter> = RawPtr.alloc_aligned(2, 4096)
}
```

- `RawPtr.alloc(count)` allocates with **the element type's own alignment**.
  `malloc` only promises 16 bytes on the supported targets, so before this an
  `align(64)` record could sit on a 16-byte boundary and `align_of` was promising
  something the allocation did not have.
- `RawPtr.alloc_aligned(count, align)` asks for a stricter one. `align` stays a
  runtime value so `align_of(T) * 2` works, and is checked when the allocation
  runs: it must be a power of two, and never weaker than the element's own
  alignment. Either failure panics with the same message in both backends rather
  than being silently upgraded — a silent upgrade would hide the caller's mistake.
- Memory from either call is released with the same `free()`.

### Atomic&lt;T&gt; and MemoryOrder (v0.8, implemented)

```beans
let counter: Atomic<i64> = new Atomic<i64>(0)
counter.fetch_add(1, MemoryOrder.relaxed)
let seen: i64 = counter.load(MemoryOrder.acquire)
counter.store(0, MemoryOrder.release)
let took: bool = counter.compare_exchange(0, 1, MemoryOrder.acq_rel, MemoryOrder.acquire)
Atomic.fence(MemoryOrder.seq_cst)
```

- `Atomic<T>` is a shared cell holding **one integer or `bool`**, and nothing
  else. The element's width must be one the selected target can read and write
  atomically in a single instruction. `decimal` and floats are rejected: LLVM
  lowers a 128-bit atomic through libatomic, which is a lock, and a lock-free
  promise that quietly becomes a mutex is worse than a refusal.
- Operations: `load`, `store`, `exchange`, `fetch_add`, `fetch_sub`, `fetch_and`,
  `fetch_or`, `fetch_xor`, `compare_exchange`, and the static `Atomic.fence`.
  `fetch_add`/`fetch_sub` need an integer; the rest also work on `bool`. Every
  read-modify-write returns the value it replaced.
- `MemoryOrder` is `relaxed`, `acquire`, `release`, `acq_rel`, `seq_cst`.
- **The order is written at the call site and cannot be a variable.** LLVM puts
  the ordering inside the instruction, so one call site is one instruction; a
  runtime order would mean a switch over every order. `MemoryOrder` is therefore
  not a type you can declare and not a value you can store — both are rejected by
  name, pointing at the call-site form.
- Combinations that mean nothing are compile errors, not weaker barriers: a load
  cannot `release` or `acq_rel`, a store cannot `acquire` or `acq_rel`, and a
  `compare_exchange` failure order can neither release nor be stronger than the
  success order. These are C++'s and LLVM's own rules; catching them here turns a
  verifier crash into a sentence about the call site.
- A narrow cell wraps inside its own width in both backends: `Atomic<u8>` holding
  250 plus 10 is 4. `Atomic<bool>` is a one-byte cell holding 0 or 1, because LLVM
  cannot do an atomic on a type that is not byte-sized.
- `AtomicInt` stays as it was — sequentially consistent, `load`/`store`/`add_and_get` — and is
  unaffected.

`wait` and `notify` park and wake threads instead of spinning:

```beans
for gate.load(MemoryOrder.acquire) == 0 {
    gate.wait(0, MemoryOrder.acquire)      // parks while the cell still holds 0
}
gate.store(9, MemoryOrder.release)
let woken: int = gate.notify_all()         // how many waiters were woken
let in_time: bool = gate.wait_timeout(9, 2000000, MemoryOrder.acquire)
```

- `wait(expected, order)` blocks while the cell holds `expected`. If it already
  holds something else it returns at once.
- **A wakeup is a hint, not a guarantee** — check in a loop. The value may have
  moved and moved back, and a waiter can be woken on another cell's behalf. This is
  the contract, not a limitation, and it matches C++20's `notify_one` being defined
  as "at least one".
- `wait_timeout(expected, nanos, order) -> bool` returns false when the budget ran
  out, so a wait can always be bounded.
- `notify_one()` / `notify_all()` return how many waiters were woken.
- The order is a load order, because it governs the re-read inside the wait.

### CPU feature detection and dispatch (v0.8, implemented)

```beans
import std.cpu

feature "aes" fn mix_fast(seed: int) -> int { ... }
fn mix_generic(seed: int) -> int { ... }

fn mix(seed: int) -> int {
    if cpu.has(CpuFeature.aes) { return mix_fast(seed) }
    return mix_generic(seed)
}
```

- `cpu.has(CpuFeature.x)` asks the machine that is **running**, not the one the
  program was compiled for. The feature is named at the call site, like a memory
  order, because it selects which detection bit is read — so `CpuFeature` is neither
  a declarable type nor a storable value.
- The name is validated against the **selected target's** feature set, so asking
  about `avx2` while targeting arm64 is a compile error listing that target's
  features, not a permanent `false`.
- x86 names two features with a dot — `sse4.1` and `sse4.2` — and those are written
  with an **underscore**: `CpuFeature.sse4_2`. `CpuFeature.sse4.2` would parse as a
  field of a field, so without this the two were unguardable and the compiler's own
  suggestion could not be typed. `--features` and `feature "x" fn` take strings, so
  they keep the dotted name.
- A **feature-gated intrinsic is emitted inside its own function** carrying LLVM's
  `target-features`, never inline at the call site. A `cpu.has` guard proves the
  feature at run time, but instruction selection is decided per function, so an
  inline one is a backend error on any target whose baseline lacks it. Marking the
  enclosing function instead would let the compiler hoist the instruction out of the
  guarded branch, onto a machine that traps on it.
- `feature "x" fn` marks a body as allowed to use that feature's instructions. Only
  a marked function carries LLVM's `target-features`, which is what stops the
  compiler hoisting a feature-requiring instruction out of it into a caller that
  never checked.
- **Calling a marked function, or storing it as a function value, requires the feature
  to be known present**: inside a matching `if cpu.has(...)` guard, from another
  function that requires the same feature, or in a build given `--features +x`.
  Function types do not carry a feature requirement, so checking when the value is
  made is what prevents an indirect call from erasing the safety rule. The check is
  deliberately syntactic — the guard has to be visible at the use.
- `BEANS_CPU_FEATURES` is an allowlist intersected with detection, so it can only
  hide features. A test may force the generic path; it can never claim hardware the
  machine lacks, which would make the test pass on a CPU that traps.
- On x86, AVX-family features are reported only when both the CPU supports them and
  the OS has enabled saving their register state. CPUID alone is not enough.
- `beansc check` takes `--target`, `--cpu` and `--features` too, because what type
  checks now depends on them.

### std.intrinsic (v0.8, implemented)

```beans
import std.intrinsic

unsafe {
    let bits: int = intrinsic.popcount(x)
    let be: int = intrinsic.bswap32(x)
    let root: float = intrinsic.sqrt(x)
    let exact: float = intrinsic.fma(a, b, c)   // one rounding, not two
}
```

- An intrinsic is a **named machine operation with a fixed signature**, not a way to
  write assembly or LLVM. `std.intrinsic` is a closed allowlist; a name that is not
  on it is a compile error that lists what is. `unsafe` is required.
- Available: `popcount`, `leading_zeros`, `trailing_zeros`, `bswap16`, `bswap32`,
  `bswap64`, `rotate_left`, `rotate_right`, `sqrt`, `sqrt32`, `fma`, `fma32`,
  `prefetch`, `spin_hint`, and `crc32c`.
- **Zero is defined**: `leading_zeros(0)` and `trailing_zeros(0)` are 64, matching
  what the instructions report. The narrow byte swaps work on the low bytes and
  leave the rest zero.
- `fma` rounds **once**, which is the reason to use it rather than writing
  `a * b + c`.
- `prefetch` and `spin_hint` are hints with no observable result.
- `crc32c` is feature-gated and goes through the same guard rule as a
  `feature "x" fn`: it needs `sse4.2` on x86-64 and `crc` on arm64, and an unguarded
  call is a compile error. One name covers both because x86's CRC32 and arm64's
  CRC32C are the same polynomial; it is the *instruction's* raw accumulator step, so
  a complete CRC32C still needs its own pre- and post-inversion.
- An intrinsic that exists on only one architecture is a compile error elsewhere,
  never a silent software fallback — a fallback would make code that looks like one
  instruction quietly run a loop.
- Every entry has an exact software definition in the interpreter, so intrinsics are
  differential-tested like everything else.

### std.time and std.random (v0.8, implemented)

```beans
import std.time
import std.random

let started: int = time.monotonic_nanos()
time.sleep_nanos(3000000)
let elapsed: int = time.monotonic_nanos() - started
let stamp: int = time.wall_nanos()

match random.bytes(32) { ok(key) => ..., err(e) => ... }
match random.below(6) { ok(roll) => ..., err(e) => ... }
```

- **Two clocks with separate names**, because choosing the wrong one is a real bug.
  `time.monotonic_nanos()` never goes backwards and is unaffected by anyone setting
  the date; it has no meaning as a moment, only differences do, and it is the only
  correct way to measure a duration. `time.wall_nanos()` names a moment —
  nanoseconds since 1970 — and can jump in either direction when the clock is
  adjusted, so measuring elapsed time with it is the mistake the two names prevent.
- `time.sleep_nanos(n)` sleeps **at least** `n`: a signal that cuts it short is
  retried with the remaining time, so it is a floor rather than an estimate.
- `std.random` is the **OS CSPRNG only** — `arc4random_buf` on macOS,
  `getrandom` on Linux. There is deliberately no pseudo-random fallback: a caller
  asking for random bytes is usually making a key, a token or a nonce, and quietly
  handing over a predictable sequence is worse than failing. Every entry point
  returns a `Result`, and an unavailable source is an error.
- `random.below(limit)` is uniform by **rejection sampling**, not `% limit` — modulo
  is biased unless the limit divides 2^64, and for a shuffle or a token that bias is
  the whole problem.
- Invalid input (a negative count, a non-positive bound) is a `Result` with kind
  `invalid`, not a panic: these are ordinary failures.
- The millisecond clocks are `time.wall_millis` and `time.monotonic_millis`; the
  nanosecond forms are the ones to
  reach for when resolution matters.

### Shared memory (v0.8, implemented)

```beans
match MMap.open_shared_memory("/name", 128, true) { ok(r) => r.put_u64(0, 7), err(e) => ... }
match MMap.open_shared_memory("/name", 128, false) { ok(r) => r.get_u64(0), err(e) => ... }
match MMap.unlink_shared_memory("/name") { ok(gone) => ..., err(e) => ... }
```

- A POSIX shared-memory object comes back as an ordinary **`MMap`** — shared memory is
  a source of a mapping, not a new kind of thing — so it has MMap's accessors and its
  deterministic unmap. That is also why it is **named construction on `MMap`** beside
  `MMap.open`, rather than a module function in a package of its own.
- **The size is given on every open**, creating or not. `fstat` reports a page-rounded
  size for a shm object (16384 for a 64-byte one on macOS), so trusting it would hand a
  reader a length its writer never agreed to. A request larger than the object is
  refused, because mapping past the real end faults on first touch rather than failing
  at map time. A size of zero or less is refused.
- The mapping is always readable and writable, and the descriptor is closed once the
  mapping exists — so `resize()` is not available on a shm mapping, which is correct:
  the size is fixed when the object is created.
- `MMap.unlink_shared_memory(name)` removes the **name**. Mappings that already exist keep working
  until their last user drops them, exactly like unlinking an open file. Opening the
  name afterwards fails with kind `not_found`.

### std.process (v0.8, implemented)

```beans
import std.process

var cmd: process.Command = new process.Command("/bin/echo")
cmd.arg("hello").arg("two words")
match cmd.run() {
    ok(done) => io.println("{done.text()} status {done.status}"),
    err(e) => io.println("could not start: {e.kind}"),
}
```

- **There is no shell.** A command is a program name and a list of arguments, and they
  reach `execvp` untouched. A filename containing a space, a quote or a semicolon is
  just a filename, so there is nothing to escape.
- `Command` is built up and then run: `arg`, `cwd`, `env`, `stdin_bytes`/`stdin_text`,
  `capture_limit`. `new process.Command(program).run()` is the short form; there is no
  module-level `run`, because a static `run` beside the instance `run` would read as
  two different things wearing one name.
- **A program that could not be started is `err`; a program that ran and failed is
  `ok` with a non-zero status.** Telling those apart needs a close-on-exec pipe in the
  runtime — without it "no such file" and "exited 127" are the same observation.
- `Output` carries `status`, `out` and `err` as `Bytes`, with `succeeded()`,
  `terminated_by_signal()`, `stdout_text()` and `stderr_text()`. A signal reports the
  **negative** signal number, so a clean exit and a kill stay distinguishable without
  a second field.
- Both output streams are drained **at once**, so a program writing heavily to both
  cannot deadlock. Capture is capped (8 MiB by default), and bytes past the cap are
  drained and discarded; the parent does not close the pipe early and change the
  child's result through `SIGPIPE` or `EPIPE`. `run()` still waits for the child to
  exit, so use `start()` plus `stop()` for a program meant to run forever.
- The first `env` call switches from inheriting the parent's environment to a fresh one
  holding only what was set, because a half-inherited environment works until it does
  not. Program names still use `PATH` from that fresh environment.
- The child's stdin is closed once the input is written, so a program that reads to EOF
  finishes. Every child is reaped.
- Program names, arguments, environment entries and working directories containing an
  embedded NUL byte are rejected with kind `invalid`; they are never silently split or
  truncated into different C strings.
- The low-level primitive is `std.proc.run`, the same split as `File` versus `std.fs`.
- The child's signal mask is cleared before `exec` for both `run()` and `start()`.
  A parent watching signals has them blocked, and that mask must not leak into a child.

**A child that outlives the call** — `Command.start()` gives a `Child` instead of waiting:

```beans
let child: process.Child = cmd.start()?
child.stdin.write_text("hello")?
child.stdin.close()?                       // ends a program reading to EOF
let said: Bytes = child.stdout.read_to_end(256)?
match child.wait_timeout(500)? { some(status) => ..., none => ... }
let status: int = child.stop(2000)?        // ask, then insist
```

- `Child` is a `unique class`, and **a dropped one is asked to stop, killed if it refuses,
  and reaped.** Not left running — an orphan outliving its parent is a bug found days
  later — and not left as a zombie. Call `wait()` for it to finish on its own terms.
- **`wait_timeout` reports "still running" as `none`, not an error**, because escalating
  from polite to forceful is the normal path. `stop(grace_ms)` is that escalation in one
  call: `SIGTERM`, wait, then `SIGKILL`.
- `stdin`/`stdout`/`stderr` are `Stream` values with partial `read`/`write`, the looping
  `write_all`/`read_to_end`, and `close`. An empty `read` means the other end closed.
  They are not `unique`, because the `Child` owns all three — closing one twice is an
  error, and the child closes whatever is left.
- **The child's signal mask is cleared before `exec`.** A mask is inherited, and a parent
  watching signals has them blocked, so without this a child would start with `SIGTERM`
  blocked and be unstoppable by anyone.
- `wait()` twice, or signalling after it finished, is an `err` — the status was already
  collected and the pid may belong to something else by now.
- `waitpid` has no timeout, so a bounded wait polls `WNOHANG` against a monotonic deadline
  with a sleep that grows to 20 ms. The test asserts a 600 ms wait costs under 200 ms of
  CPU, because "not a spin" is a promise worth checking rather than assuming.

### std.net (v0.8, implemented)

```beans
import std.net

// 0 = ask the system for a free port
let server: net.TcpListener = net.TcpListener.bind("127.0.0.1", 0)?
let port: int = server.port()?
let client: net.TcpStream = net.TcpStream.connect("127.0.0.1", port)?
let session: net.TcpStream = server.accept_timeout(2000)?

client.write_text("ping")?
client.shutdown_write()?                    // the reader sees EOF
let asked: Bytes = session.read(64)?        // empty means EOF

let radio: net.UdpSocket = net.UdpSocket.bind("127.0.0.1", 0)?
radio.send_to(Bytes.from("hi"), new net.Address("127.0.0.1", port))?
match radio.recv_from(64) { ok(note) => note.from.text(), err(e) => ... }

match net.Address.resolve("localhost", 80) {
    ok(found) => found.get(0).text(),
    err(e) => ...,
}
```

- **Sockets are made the way every other resource is made**: `TcpListener.bind`,
  `TcpStream.connect`, `UdpSocket.bind`, `Address.resolve` — named statics on the class
  each produces, the same shape as `File.open` and `MMap.open`, because construction
  that can fail cannot be a constructor. `std.net` has **no module-level functions**.
- **`TcpListener`, `TcpStream` and `UdpSocket` are `unique class`** — move-only, closed by
  `deinit`. One owner, one close, and a double close is impossible to write. The three
  `unique` rules apply: a socket cannot be copied, cannot cross `thread.spawn`
  (`unique` ⇒ not `Clone` ⇒ not `Send`), and a socket trapped in a reference cycle never
  runs `deinit`.
- **`Address` is an ordinary value**: `host` and `port`, with `to_string()`, `is_ipv6()` and
  `is_loopback()`. `to_string()` brackets an IPv6 host (`[::1]:80`) because that is the form
  that round-trips.
- **IPv4 and IPv6 both work, and the family is never chosen by the caller.** Every entry
  point resolves the host through `getaddrinfo` and tries each candidate in turn, so
  `"localhost"`, `"127.0.0.1"` and `"::1"` all work with no flag to get wrong. Failure
  reports the last address's error.
- **Reads and writes are partial by contract.** `read(max)` returns what has arrived —
  and an **empty `Bytes` means EOF**, the one thing a byte count cannot express;
  `write(data)` returns how much went out. `write_all` and `read_exact` are the looping
  forms, and `read_exact` fails with kind `eof` if the peer closes early.
- **Every blocking call retries `EINTR`.** A signal never turns into a short read or a
  spurious failure.
- Timeouts are set per socket (`set_timeouts(read_ms, write_ms)`) and `connect` and
  `accept` take one directly. A timeout is an `err` with kind `timeout`, never a hang.
- `set_nonblocking(on)` and `poll_handle()` exist so a socket can be handed to a readiness
  poller; `poll_handle()` is a borrow of the descriptor, never ownership.
- Errors are `Result` with a specific `kind`: `refused`, `in_use`, `timeout`, `reset`,
  `unreachable`, `not_found` (a name that does not resolve), `closed` (using a socket
  after `close`), `eof`, `invalid`, `permission`, `io`.
- `close()` is explicit for callers who want to see the error; `deinit` closes anyway and
  cannot report one, which is why `close()` exists.
- Every descriptor is created close-on-exec, so a socket never leaks into a child process.
  A listener sets `SO_REUSEADDR` so a restart is not blocked by `TIME_WAIT`.
- The low-level primitive is `std.sock`, the same split as `std.proc` versus
  `std.process`. It is the syscall layer over plain descriptors and is not the API —
  callers use the handles.

### std.poll (v0.8, implemented)

```beans
import std.poll

let watch: poll.Poller = poll.Poller.open()?
watch.add(server.poll_handle(), 1, poll.Interest.read_only())? // 1 = the caller's token
watch.add(stream.poll_handle(), 2, poll.Interest.both())?
watch.modify(stream.poll_handle(), 2, poll.Interest.write_only())?

for event: poll.Event in watch.wait(64, 500)? {
    if event.token == 1 && event.readable { ... }
    if event.hangup { watch.remove(stream.poll_handle())? }
}
watch.wake()?                                             // from this thread
let signal: int = watch.wake_handle()                   // an int crosses threads
poll.wake(signal)?                                        // from a worker
```

- One poller over **`epoll` on Linux and `kqueue` on macOS**, and it is
  **level-triggered** — while a socket has data, every `wait` reports it. That is the
  default on both, and it is the mode you can use incorrectly and still be right:
  edge-triggered requires reading until `EAGAIN` every single time or the connection
  silently stalls.
- **`add(fd, token, interest)`** takes the caller's own `token`, which is what comes
  back in each event. The poller never hands back an fd to key on, because an fd is
  reused the moment it is closed — a token is yours and means what you decided.
  Different descriptors may use the same token; they still produce separate events.
- `Interest` is a value: `new poll.Interest(read, write)`, or the presets
  `Interest.read_only()`, `Interest.write_only()`, `Interest.both()`. `modify` replaces the
  interest for a token, `remove` unregisters.
- `wait(max_events, timeout_ms)` returns a `List<Event>`, **capped at `max_events`** so
  one call cannot allocate without bound. A negative timeout waits indefinitely; 0 is a
  non-blocking check; running out returns an **empty list, not an error** — nothing being
  ready is not a failure.
- `Event` carries `token`, `readable`, `writable`, `hangup` and `error`. `hangup` means
  the peer is gone; a socket can be both readable and hung up, and the buffered data is
  still worth reading. kqueue's separate read and write filters are merged into one
  event; the internal kernel batch reserves two filter slots per requested event, plus
  the private wake slot, so a small `max_events` does not split the pair.
- **`wake()` makes a blocking `wait` return promptly**, and repeated wakes collapse into
  one: it writes one byte to an internal pipe the poller registered with itself, and the
  wake is never reported as an event.
- **To wake from another thread, pass `wake_handle()`** — an `int`, because only scalars
  cross a thread boundary (every class is a local ARC reference) — and call
  `poll.wake(signal)` there. The handle is deliberately **not the descriptor**: after the
  poller closes that number belongs to something else, and a late wake would write a stray
  byte into an unrelated file. It names a slot and a generation, so a wake to a closed
  poller is an `err` with kind `closed`, and a slot reused by a new poller gets a new
  handle rather than inheriting the old one's wakes.
- **`remove` before `close`.** Closing a registered descriptor does drop it from the
  kernel's set, but events already queued in the current batch still name its token, and
  by then the number may belong to something else. Removing first is the only way to be
  sure — and it is why the token is not an fd.
- Every blocking wait retries `EINTR` with the deadline recomputed from the monotonic
  clock, so a signal never shortens a wait and a stream of signals cannot extend one.
- `Poller` is a `unique class`, closed by `deinit`, like every other resource. The
  low-level layer is `std.ready`.

### std.signal (v0.8, implemented)

```beans
import std.signal

let want: int = signal.Signal.interrupt()?
let watch: signal.Signals = signal.Signals.watch_signal(want)?

// A readable descriptor, so signals and sockets wait in the same call
poller.add(watch.poll_handle(), 1, poll.Interest.read_only())?

for n: int in watch.drain()? { io.println("got {signal.Signal.name(n)?}") }
watch.close()?
```

- **There is no signal handler.** A watched signal is *blocked* and the fact that it
  arrived is read from a descriptor. Inside a real handler almost nothing is legal — no
  allocation, no locks, no reentrancy, and in this language no reference counting and no
  cycle collection — so running Beans code there is not something to be careful about, it
  is something to make impossible. `signalfd` on Linux; a private `kqueue` with
  `EVFILT_SIGNAL` on macOS, whose descriptor is itself readable so it nests in the poller.
- **`Signals` is a `unique class`.** `watch`/`watch_signal` block the signals, `drain()`
  reads and consumes them, `close()` (or `deinit`) unblocks.
- Signal mask ownership is counted per thread. Two `Signals` values may overlap;
  closing one leaves a number blocked until the last watcher for it closes.
- **Which signals exist is a safety decision.** `interrupt`, `terminate`, `hangup`,
  `quit`, `user1`, `user2`, `child`, `pipe`, `alarm`, `window_change`. Absent: `kill` and
  `stop`, which cannot be blocked by anyone; and the fault signals `segv`, `bus`, `fpe`,
  `ill`, because those are **synchronous** — they name an instruction that already failed,
  so deferring one and continuing re-runs it forever. Offering them would be offering a
  hang. Names are the portable part; the numbers differ per platform.
- **`drain()` never blocks**, and reports each signal **at most once per call** however
  many times it arrived. That is what Linux guarantees (pending signals are a bitmask, so
  repeats collapse) and macOS's per-signal count is discarded to match.
- **Reading consumes; closing discards.** A signal taken from the descriptor is removed
  from the process's pending set, and anything still unread when the watch is dropped is
  discarded rather than delivered — otherwise unblocking would kill the process with a
  signal the program had chosen to handle.
- Watch **before** spawning threads: the block applies to the calling thread and is
  inherited by threads created later, not by ones already running.
- `Signal.send_to_self(n)` sends a signal to this process, so handling is testable in one
  process. The low-level layer is `std.sig`.

### std.dylib (v0.8, implemented)

```beans
import std.dl
import std.dylib

let lib: dylib.Dylib = dylib.Dylib.open("./libplug.so")?
if lib.has("plug_add") {
    let add: dylib.Symbol = lib.find("plug_add")?
    unsafe {
        let sum: int = dl.call2(add.address, 40, 2)
    }
}
```

- `Dylib` is a `unique class`: `open` is a named static, `find` resolves a `Symbol`,
  `has` probes without treating absence as an error, and `close`/`deinit` unloads.
- **Opened `RTLD_LOCAL`, always.** `RTLD_GLOBAL` would publish the library's symbols where
  an `extern "C" fn` resolves them — through `dlsym` in the interpreter, through the
  linker in a native build — so the same program would link in one backend and not the
  other.
- **Calling requires `unsafe`, and nothing wraps it.** `dl.call0` … `dl.call3` are the
  only way, and they are refused outside `unsafe { }` by the checker. A wrapper in
  `std.dylib` would need its own `unsafe` block and would then let callers skip theirs —
  laundering exactly the property that matters. There is no `unsafe fn` in the language,
  so the block has to be at the call site.
- **One machine word per argument and per result**, which covers integers and pointers:
  every C function whose arguments pass in registers as words. A float, a narrow integer
  or a by-value struct needs `extern "C"`, where Clang classifies the signature for the
  target rather than the caller guessing.
- `std.dl.global_symbol`, the typed float rows, and the void-return rows are
  compiler plumbing for the checked `extern "C"` interpreter. They are not the
  general dynamic-library API. Their call rows still require `unsafe`; normal
  programs use `Dylib.find` plus `call0` … `call3`, or declare `extern "C"`.
- A symbol can legitimately resolve to address 0, so `find` reports failure as an `err`
  rather than by handing back a null address — `dlerror` is the real test.
- Every address from a library dies with it. `Symbol` holds the address and the name, and
  deliberately offers no way back into the library.

### Runtime profiles (v0.8, partly implemented)

```
beansc build --runtime full f.b        # everything (the default)
beansc build --runtime minimal f.b     # libc, no OS services
beansc check --runtime freestanding f.b
```

- **`full`** is the default and unchanged. **`minimal`** keeps memory, the collector,
  containers, strings, decimal, printing, clocks, secure random, the environment and
  threads, and drops the filesystem, sockets, the poller, processes, signals, shared
  memory and dynamic libraries. **`freestanding`** additionally drops threads, clocks,
  random and the environment: nothing that needs an operating system.
- **A capability a profile lacks is refused at check time, by name.** Dead-code stripping
  is deliberately not the mechanism: it turns "you cannot open a socket in this profile"
  into "undefined symbol beans_net_listen". The error names the package, the capability
  and both profiles, and it blames the caller's own import rather than a shipped
  package's internals.
- The levels, the capability table and the `BEANS_RT_PROFILE` macro live in one header
  the compiler and the C runtime both read, so they cannot drift.
- The profile is part of the runtime object's cache key, so an object built for one
  profile is never reused for another.
- **The freestanding runtime calls no libc.** Memory, output and exit come through five
  hooks the surrounding program defines:

```c
void* beans_host_alloc(unsigned long long size, unsigned long long align); // zeroed
void* beans_host_realloc(void* block, unsigned long long size);
void  beans_host_free(void* block);
void  beans_host_write(int stream, const char* bytes, unsigned long long len);
void  beans_host_exit(int code);                                          // no return
```

  `align` is a power of two and never below 16 — the reference-count header's own
  alignment, which is what puts the payload where the compiler expects it. `size` is
  never 0, `block` is never NULL, and NULL back from alloc means out of memory. Two more
  hooks, `beans_host_format_f64` and `beans_host_parse_f64`, cover floating-point text;
  they are weak everywhere and panic if a freestanding program uses a float without
  supplying them, so a program that never touches one never has to.
- **Three rules for an implementer.** A hook must not call back into any `beans_`
  function — the allocator runs inside allocation. The panic path must not allocate, so
  it formats into a fixed stack buffer and calls write then exit, and still works when
  memory is what ran out. Hooks are supplied by linking a definition, never by editing
  the emitted IR.
- The hooks are **weak in the hosted profiles**, so any of them can be replaced there
  too, and the runtime otherwise uses libc directly — a hook on the allocation hot path
  would cost every program to serve the one that overrides it.
- An application entry point is `main`. A freestanding application build is
  `--emit obj`: link it with your own startup, which calls `main`. A
  freestanding library has no startup. There is no `atexit`, so a program that
  wants the final cycle sweep calls `beans_collect_cycles()` itself.

### WebAssembly (v0.8, implemented)

```bash
# WASIp1 command module
beansc build --target wasm32-wasip1 app.b -o app.wasm
wasmtime app.wasm

# No-entry module for a browser or another embedder
beansc build --target wasm32-unknown-unknown --runtime freestanding \
  --emit shared library.b -o library.wasm
```

- **`wasm32-wasip1` and `wasm32-unknown-unknown` are registered targets** with 32-bit
  pointers, which is what the layout engine and the object ABI had to stop assuming
  otherwise. `size_of(RawPtr<T>)` folds to 4 and a slice to 8 for these, from the same
  `LayoutRules` the checker and codegen share.
- **WASIp1 command modules build directly.** `minimal` is the default profile and
  supplies arguments, environment, stdin, exit, errno, clocks, sleep and secure random.
  `--runtime full` also supplies files, directories, paths and buffered readers through
  the host's preopened directories. Threads, memory maps, processes, sockets, polling,
  signals and dynamic libraries are refused at check time.
- A direct WASIp1 link needs a WASI SDK C sysroot. Set `BEANS_WASM_CC` or pass `--cc`
  when the host's normal Clang has no WASI sysroot. `--emit ir` and `--emit obj` still
  need no sysroot.
- `runtime/wasm_host.c` is the shipped WASIp1 adapter. It declares the preview-1 imports,
  owns startup, caches arguments and environment, and implements the runtime hooks.
  wasi-libc supplies allocation, floating-point text and the filesystem ABI.
- **Browser/library modules have no startup.** `--emit shared` on
  `wasm32-unknown-unknown` exports linear memory and only selected
  `pub extern "C"` functions. Unresolved host functions become imports. A scalar-only
  library can have no imports at all and loads through JavaScript's standard
  `WebAssembly.Module` API.
- `--features +simd128` enables the 64- and 128-bit Beans SIMD families and is exercised
  under Wasmtime. It is opt-in so the default module uses only the core instruction set.
- WebAssembly threads and the component model are not implemented. Beans does not yet
  emit shared memory or the canonical component ABI, so `thread.spawn` and
  `wasm32-wasip2` are rejected rather than producing a module with false guarantees.
- `test/wasm_features.tsv` is the executable feature list. `test/wasm.sh` runs the core
  language, C ABI callbacks, WASIp1 services, files, allocation reuse, SIMD, no-main
  exports, JavaScript loading, panic behavior and both compiler implementations.

### Inline assembly (v0.8, implemented)

```beans
import std.asm

unsafe {
    let y: int = asm.value("mov $0, $1", "=r,r", x)   // one int in, one int out
    asm.run("dmb ish", "memory")                      // no operands, always volatile
}
```

`std.intrinsic` is for machine operations that have a name and an LLVM intrinsic; this is
for the ones that have neither. It is **constrained**: the caller writes the assembly, but
only a template the selected architecture has a row for in `asm_template_allowed`
in `src/expression.b`, and the constraint string has to be the row's too.

- Both strings must be **plain literals** — no variables, no interpolation, no escapes —
  because the compiler compares them against the allowlist before the assembler sees them.
  A template built at runtime could not be compared to anything.
- Operands are **one `int` in and one `int` out, or nothing**. No object references, so
  nothing is smuggled past ownership; no branches, so control flow cannot leave or enter.
- The **constraints belong to the row.** Varying them could turn a read into a write, or
  drop a barrier's memory clobber and leave it free to be reordered around. Clobbers are
  written as bare names (`"memory"`) because LLVM's `~{memory}` contains a brace, which in
  a Beans string is interpolation.
- Every row states what the **interpreter** does, because the interpreter is the reference:
  a register move returns its argument, a barrier does nothing. Rows that touch machine
  state the host cannot model — an interrupt mask — exist only on the embedded
  architectures, where the interpreter never runs; a test enforces that rather than
  leaving it to good intentions.
- `unsafe` is required, like every other raw-hardware operation.

Allowed templates, by architecture:

| architecture | templates |
|---|---|
| arm64 | `mov $0, $1`, `dmb ish`, `dmb ishst`, `isb` |
| x86_64 | `mov $0, $1` (Intel dialect), `mfence`, `lfence`, `sfence` |
| arm32 | `dmb sy`, `cpsid i`, `cpsie i`, `wfi` |
| riscv32 | `fence rw, rw`, `csrci mstatus, 8`, `csrsi mstatus, 8`, `wfi` |
| x86 (32-bit) | none |
| wasm32 | none |

Value rows exist only on the 64-bit architectures, deliberately: `mov $0, $1` with a
64-bit operand on a 32-bit machine expands to a move of the low half alone, silently
dropping the rest.

### Embedded targets (v0.8, implemented)

```
beansc build --target thumbv7em-none-eabi          --runtime freestanding f.b --emit obj
beansc build --target riscv32imac-unknown-none-elf --runtime freestanding f.b --emit obj
```

- **A Cortex-M4 and an RV32 board**, both 32-bit, both with no operating system and no
  libc. `examples/embedded.b` runs on QEMU's MPS2-AN386 and RISC-V `virt` with output
  byte-identical to the interpreter.
- `decimal` is **not available** on either — see the refusal table above. That is the one
  place a target changes what the language offers, it is stated at check time, and it is
  why `examples/embedded.b` exists next to `examples/freestanding.b`.
- `int` is still 64 bits and `float` is still a double, so ordinary division and
  arithmetic become calls into the toolchain's builtins. Those come from the bare-metal
  GCC's `libgcc.a`; the compiler and linker stay Clang and `ld.lld`.
- What the board supplies is the same five hooks as any freestanding build, plus a UART
  write, a power-off path and a reset entry. `test/fixtures/embedded_host.c` is a complete
  worked example for both boards, with one linker script each.
- Apple clang has no RISC-V backend and no lld, so both images are **built and run in the
  Linux container**; `test/embedded.sh` skips its emulator half with a message rather than
  passing quietly.

## Misc

- A `File` or `MMap` closed while worker threads are live keeps its OS fd/mapping open until
  the handle's last reference drops, then releases it. This stops a racing op on another thread
  from hitting an fd number that `close()` freed and the OS reused for a different file. The
  logical `closed` flag flips immediately, so same-thread `close()` semantics are unchanged; only
  the OS-level release is deferred, and only while threads run.
- `defer f.close()` — runs when the function exits normally, including through
  `return` and `?`, newest first and before local destruction. Must sit at the
  top level of the function body (not inside `if`/`for`/blocks — it is a function-exit hook,
  and nested registration would need runtime capture the native backend does not do). A panic
  exits the process without running defers, and a panic inside a defer is itself fatal.
  `?` is not allowed inside a deferred expression because the function's
  return path is already being processed.
  (Go's best idea, minus unwinding.)
- `unsafe { }` — gates low-level operations. The first implemented part is
  `RawPtr<T>` for primitive integer, float, bool, raw-pointer, fixed-array, and
  declared `extern "C" struct`/`union` values. These shapes can nest.
  `RawPtr.alloc(n)`
  allocates zeroed unmanaged storage. Safe `null()` creates an inert pointer,
  and safe `is_null()` tests it, so a variable can be initialized before an
  unsafe block. Unsafe `from_address(u64)` creates a pointer from an integer.
  `read`, `write`, `read_volatile`, `write_volatile`, `offset`,
  `address`, `element_size`, `element_align`, overlap-safe
  `copy_from`, zeroing `fill_zero`, and `free` are only legal inside an unsafe
  block. The
  volatile forms lower to LLVM volatile memory operations for device/shared
  memory; they are not atomic. Integer and bool pointers also provide
  sequentially consistent `atomic_load`, `atomic_store`, and
  `atomic_compare_exchange`; integer pointers add `atomic_fetch_add`, which
  returns the old value. A null memory operation gives a runtime
  panic, but lifetime, bounds, alignment, address validity, and one matching
  `free` are the programmer's job. Atomic access checks its natural alignment;
  ordinary and volatile access do not. Raw pointers are copyable, so freeing one
  alias leaves every other alias dangling.
- `extern "C" fn name(args) -> T` declares an unmangled host C symbol. Calls
  require `unsafe {}`. The ABI supports any number of integer, bool, `RawPtr`,
  `CFunctionPtr`, `f32`, `f64`, or `extern "C" struct`/`union` arguments and
  the same return types (or no return), including arguments past every
  register bank.
  Aggregates may contain nested C-layout records and
  fixed arrays. Clang owns the platform ABI lowering: native builds link a
  generated pointer-ABI wrapper, and the interpreter compiles and caches a tiny
  trampoline for each bridged signature. Sub-32-bit integers and `bool` also
  take that wrapper, because Clang gives them a sign/zero-extension contract
  that a plain call cannot express. A parameter may be a C callback such
  as `fn(i32, i32) -> i32`; its arguments and return use the same C-safe type
  set and may include C-layout records. Beans closures and stored top-level
  functions both work. `as "native_name"` gives an import a different C symbol
  name. A `pub extern "C" fn` with a body exports its `as` name for C callers;
  only C-safe parameters and results are accepted. The callback is borrowed,
  synchronous, and same-thread:
  C may call it only before the surrounding extern call returns, must not store
  it, and must not invoke it from another thread.
- `extern "C" opaque struct Handle` declares an incomplete C type. It is valid
  only behind `RawPtr`; allocation, field access, embedding, and layout queries
  are rejected.
- C data symbols use `extern "C" let`, `extern "C" var`, or
  `extern "C" thread_local var`, with optional `as "native_name"`. Reads and
  writes require `unsafe`. Hosted programs use `std.c.errno()` and
  `std.c.set_errno(value)` instead of assuming one platform's errno spelling.
- `RawPtr.with_local(inout value, fn(pointer: RawPtr<T>) { ... })` lends a
  pointer to one stack value for the duration of the closure. Native uses the
  real stack slot; the interpreter copies through aligned C storage. `T` must
  be a raw-memory-safe inline type.
- `StoredCallback<F>.create(userdata_index, closure)` makes an explicitly owned
  callback for C code that stores it or calls it on another thread.
  Pass `function()` to a borrowed C callback parameter. Use
  `function_pointer()` when C stores the callable address in a
  `CFunctionPtr<F>` field, global, parameter, or return value. `context()` is
  the separate userdata pointer. Captures must be `Send + Sync`. Unregister
  first, then call `close()`; close waits for active calls. The value is
  move-only, and a panic never unwinds through C.
- `StoredCallback<F>.create_same_thread(userdata_index, closure)` is the
  same owned callback for the most common C event-loop shape: the library
  stores the callback once and always invokes it on the thread that
  registered it. Captures are unrestricted — no `Send`, no `Sync` — because
  the registering thread is recorded and an invocation from any other thread
  is a checked runtime abort, not a data race. Same `function()` /
  `function_pointer()` / `context()` surface and the same
  unregister-then-`close()` discipline.

A **borrowed callback** is an `fn(...)` parameter on an `extern "C" fn`. It is
lent to C for the length of that one call, so a Beans closure can be passed
directly and no lifetime question arises. A callback C *stores* is a different
thing and needs `StoredCallback`, whose value stays alive until you `close()`
it — close after unregistering, because it waits for calls already running.
A callback type is not storage: an `extern "C" struct` field cannot hold a
plain `fn(...)`. C function-pointer storage uses `CFunctionPtr<F>`, which is
one pointer wide but stays distinct from `RawPtr` and ordinary Beans function
values. It is valid in C-layout records, extern globals, parameters, returns,
and exported C headers. `CFunctionPtr.null()` creates a null value,
`is_null()` tests it, and unsafe `call(...)` invokes a non-null pointer with
its exact C signature. Bindgen uses this type for C function-pointer fields,
globals, and returns.

`beansc bindgen header.h... -o bindings.b [--only symbol]* [--pub]` asks Clang for the
selected target's JSON AST. It handles typedefs, opaque and complete records,
unions, arrays, enums, globals, TLS, functions, and function pointers. C
nullability annotations (`_Nullable`, `_Nonnull`, `_Null_unspecified`) are
ignored for type mapping. Declarations come from every requested header, while
types may also come from any header they include. This gives split `core.h` +
`service.h` APIs one shared record and opaque-handle identity. Nested function
pointers keep each level: only a callback passed directly to an imported
function is borrowed as `fn(...)`; stored or nested callback addresses use
`CFunctionPtr<F>`.

The **common C scalar types** are mapped from what Clang reports for the
selected target, never from the host or from the pointer width. `long` is 8
bytes on 64-bit Linux and macOS and 4 on 64-bit Windows; plain `char` follows
the target's signedness and is a distinct type from `signed char`; `size_t`,
`ptrdiff_t`, `intptr_t` and `uintptr_t` each take their own reported width. A
width Beans has no exact integer for is an error, not a near-enough type.

A C **enum** binds only where Clang gives it the plain signed-`int`
representation. A fixed underlying type, or a constant that pushes the enum to
an unsigned or wider representation, is refused rather than reinterpreted.

Only declarations with an **external symbol** are imported. `static` functions
and variables, and C `inline` definitions with no external definition, are
skipped; naming one through `--only` reports that it is not linkable, and
`--only` with no match reports that too. A header whose declarations all turn
out to be unbindable is an error rather than a file holding one comment.

Constructs whose ABI bindgen cannot reproduce exactly are refused: varargs,
bitfields, flexible arrays, vectors, `_Atomic` members, packed or explicitly
aligned records, `#pragma pack` layouts, anonymous record members, non-default
calling conventions and other ABI attributes, and C++ declarations. Types with
no exact Beans equivalent — `long double`, 128-bit integers, `_Complex`,
`_BitInt`, extended and decimal floating types — are refused for the same
reason. `--allow-unsupported` skips the affected declaration and declarations
whose layout depends on it, with generated comments; it never invents a
usable-looking type in their place. Extra Clang
options follow `--`. `--package name` writes a `package` clause above the
bindings: every file in a package declares it, so generated bindings dropped
beside your own sources need one. Without it the output has no clause, which
loads only as a file on its own. `--pub` emits public records, enum constant
helpers, globals, and functions for a library package's consumers.
- **SIMD vector families** (v0.8): a vector type's name *is* its shape — `Simd` +
  lane count + element. `Simd4i32` is four 32-bit signed integers, `Simd16u8` is
  sixteen bytes, `Simd2f64` is two doubles, `Simd4f32` is four floats. Elements are
  `i8`/`i16`/`i32`/`i64`, their `u` forms, `f32` and `f64`; the lane count must be a
  power of two and the total width must be a register the machine has — 128 bits
  everywhere, 256 only where the features provide it, so `Simd8i32` needs
  `--features +avx2` on x86-64 and is refused by name otherwise. Available inside
  `unsafe`.
  - Construct: `splat(x)`, `of(...)` with one argument per lane, `load(ptr)` and
    `load_unaligned(ptr)`.
  - Lanes: `lane(i)`, `with_lane(i, v)` (a copy), `lane_count()`. A lane index
    outside the vector panics.
  - Arithmetic: `+ - * /` and `add`/`sub`/`mul`/`div`, plus `min`/`max`. Integer
    families also get `bit_and`/`bit_or`/`bit_xor`/`bit_not` and `shl`/`shr` — a
    shift at or past the element width panics, and `shr` follows the element's sign.
  - Comparisons `eq`/`ne`/`lt`/`le`/`gt`/`ge` return a **mask**: a vector of the
    same shape whose lanes are all-ones or all-zeros. `mask.select(a, b)` picks per
    lane, and `any_true()`/`all_true()` fold it — so a comparison feeds a choice
    with no branch. Unsigned families compare unsigned.
  - Reductions: `sum()`, `product()`. Whole-vector `==`/`!=` compares lane by lane
    and gives one `bool`.
  - `store(ptr)`/`load(ptr)` require the vector's own alignment and panic
    otherwise; the `_unaligned` forms take any address.
  - Native code uses LLVM vector instructions. SIMD values can be carried by inline
    `Option` and `Result` and stored directly in List, Map values, Box, Arena,
    Shared, Mutex, Channel, and thread results. SIMD does not implement `Hash`, so
    it cannot be a Map key.
- `[T; N]` is a fixed-size inline array. It accepts inline scalar, `RawPtr`,
  nested fixed-array, and struct elements with `1 <= N <= 4096`. A list-shaped
  literal gets fixed-array meaning from its declared spot:
  `var lanes: [f32; 4] = [1, 2, 3, 4]`. Arrays copy by value, pass and return
  inline, support checked integer indexing, element assignment on `var`
  locals, `len()`, equality, and `for` iteration. List, Box, and Arena store
  arrays inline; Map stores them inline as values and as structural keys when
  their element type implements `Hash`. Shared, Mutex, Channel, and thread
  results use the same typed-width layout.
- `Slice<T>` is a non-owning inline `{pointer, length}` view for the raw-memory
  element set above. `Slice.from_raw(ptr, len)`,
  `get`, `set`, indexing, `subslice`,
  `as_ptr`, and iteration require `unsafe`; reads and writes are bounds checked.
  A non-empty slice rejects a null pointer. The caller must keep the backing
  allocation alive and must not use the view after `free`.

- `struct` declares an inline value type. It copies by value and is passed and
  returned as an LLVM aggregate, with no ARC header or heap allocation. A
  struct may be generic and may declare instance or static methods:

  ```beans
  struct Point<T> {
      value: T
      moves: int

      fn move_count() -> int { return self.moves }

      inout fn moved() {
          self.moves += 1
      }
  }

  var point: Point<int> = Point { value: 3, moves: 0 }
  point.moved()
  ```

  A normal struct method gets read-only `self`. A method marked `inout fn`
  may change fields and must be called on a `var` local. Structs use field
  literals instead of `init` or `deinit`; a static method may be used as a
  named factory.

  ```beans
  extern "C" struct Packet {
      tag: u8
      count: u32
      ratio: f32
  }
  ```

  `extern "C"` fixes declaration order and the target C size/alignment rules, so
  `RawPtr<Packet>` and `Slice<Packet>` can access matching native memory.
  Fields and methods are package-private unless marked `pub`, as with classes;
  `priv` limits either one to its declaring struct. This includes normal,
  static, and `inout` methods. Ordinary structs can
  own strings, classes, collections, Options/Results, and other ARC values; the
  compiler retains and drops those fields recursively through copies, arrays,
  class fields, and typed List, Map-value, Box, and Arena storage. `extern "C"` structs stay restricted to
  inline scalars, `RawPtr`, fixed arrays, and nested C-layout structs so their C
  ABI has no hidden ownership policy. A direct or array-wrapped
  recursive value edge is rejected because it has no finite size; use `RawPtr`
  or `Box` for that edge. Struct inheritance and ARC reference fields in
  C-layout records remain unsupported. Ordinary structs that satisfy `Eq`
  and `Hash` can be Map keys; stored keys use an immutable compiler-owned box
  and lookups use a stack copy. A field can be changed only through a `var`
  local.

- `extern "C" union` declares overlapping inline scalar, `RawPtr`, fixed-array,
  or nested C-layout storage. It must be
  initialized with exactly one named field. Initialization, reads, and writes
  require `unsafe`, because Beans does not track which member is active:

  ```beans
  extern "C" union Word {
      bits: u32
      number: f32
  }
  ```

  Union values copy, pass, return, and round-trip through `RawPtr` inline.
  Fields have C size/alignment and all start at offset zero. This first slice
  has no defaults, methods, generics, inheritance, compound field assignment,
  ARC reference fields, or direct old-container storage.

`unique`, `abstract`, `singleton`, and `priv` are contextual modifiers;
`extern "C"` is a declaration modifier built from the `extern` keyword.
Standard modifier order includes `pub unique class`, `pub abstract class`,
`pub singleton class`, and `pub extern "C" struct`.

## Keywords and modifiers

```
class struct union interface enum fn let var pub priv override
if else for in match return break continue move inout
import as defer unsafe extern new extends implements static
self true false unique abstract singleton
```

`some none ok err` are ordinary names. `super` is contextual. `spawn` is a
library function, not a keyword. `async` and `await` are contextual too:
`async` only immediately before `fn`, `await` only inside an async body.
`package` is contextual as well — only `package <name>` at the top of a file
declares one, so `package` stays usable as an ordinary identifier.

## Decided

- Language gaps 1.0 (implemented): the nine findings of the 2026-08-18 gap
  report, verified against interpreter and native both. Multi-line method
  chains — a chain breaks before or after the `.`, since a dot can never end
  a statement; fn-typed fields are callable through member syntax, with a
  same-named method winning; covariant `Self` results on class and interface
  instance methods, enforced by the return-self rule so no layout changes;
  trailing constant parameter defaults, materialized at call sites — and the
  standing decision recorded: no named arguments, no overloading; zeroing
  `weak` fields for ARC classes, invisible to the cycle collector's trace and
  nil'd before the referent's deinit; closure capture-by-move
  (`fn() move(x) { ... }`), which lets a callback own a move-only resource
  and release it exactly once with the closure; the same-thread stored
  callback (`StoredCallback.create_same_thread`), unrestricted captures
  guarded by a checked thread abort; the `csrc` manifest row, compiling a
  package's own C sources for native links and `beansc run` alike, cached by
  content hash; and backend error poisoning, so one unsupported construct is
  one diagnostic instead of a cascade of MIR temporaries.
- Public API names v0.9 (implemented): a name says what it does or it changes,
  and there are no aliases for the old spelling — a rename that leaves the old
  name working is a rename nobody finishes. The pairs that lied got fixed
  first: `Bytes.to_string` truncated at a NUL while `to_string_full` was the
  honest conversion, so `to_string` is now every byte and the truncating one
  says `to_string_until_nul`; `Map.contains` read like `List.contains` but asks
  about a key, so it is `contains_key`; `Bytes.append_varint` meant unsigned
  LEB128 while `std.encoding.binary` used "varint" for zigzag, so the built-in
  pair carries the `u`. Names that hid what they cost or handed back got said
  out loud — `Mutex.with_lock`, `Weak.is_expired`, `Channel.receive`,
  `AtomicInt.load`/`store`/`add_and_get`, `Dir.create`/`create_all`, and
  `MMap.open_shared_memory`. A resource's pollable descriptor is `poll_handle`
  everywhere it appears, `Signals.drain` says that reading consumes, and the
  millisecond clocks moved to `std.time` beside the nanosecond forms, where
  their names name their clock. Internal `beans_*` runtime symbols keep their
  old spellings: they are an ABI, not a public API.
- async/await v0.9 (first version implemented): contextual words, never
  keywords, so every existing use of the names keeps parsing; the declared
  type is the body's, a call gets `std.async.Task` of it, and the split never
  leaks into `return` or `?`; a task is a cold, single-use, move-only value
  whose drop cancels it — armed defers newest-first, then every live value
  exactly once, children in cascade; a task panic stops the program at the
  poll site because panics never unwind in Beans; the poll/take/cancel
  closure triple is the public awaitable protocol and the compiler's own
  lowering target — the expander rewrites an async body into a synchronous
  maker over ordinary closures, so both executors, the ownership passes, and
  the verifiers run unchanged
- Layout introspection v0.8 (implemented): `size_of(T)`, `align_of(T)` and
  `offset_of(T, field)` as contextual forms taking a type, folded to constants
  of the selected target; class and interface references report one pointer;
  enums and type parameters are rejected rather than given a wrong number
- Signals v0.8 (implemented): **no handler exists** — a watched signal is blocked and read
  from a descriptor, which keeps Beans code, the reference counting and the cycle collector
  entirely out of async-signal context; the descriptor is registerable with the poller so
  signals and sockets wait together; which signals are offered is a safety decision, with
  kill/stop excluded as unblockable and the fault signals excluded as synchronous; reading
  consumes and closing discards, so a handled signal cannot come back at teardown
- Dynamic libraries v0.8 (implemented): `RTLD_LOCAL` always, so a loaded symbol can never
  change how `extern "C"` resolves in one backend but not the other; calling a resolved
  address is `unsafe` with **no wrapper**, because a wrapper would need its own `unsafe`
  block and would let callers skip theirs; one machine word per argument, and anything
  else belongs in `extern "C"` where Clang classifies the signature
- WebAssembly v0.8 (implemented): direct WASIp1 command modules with arguments,
  environment, stdin, errno, clocks, random and preopened filesystem access; no-entry
  `wasm32-unknown-unknown` modules for browser/library embedding; opt-in `simd128`;
  registered 32-bit layout and object ABI; interpreter/native/Wasm parity under Wasmtime
  and JavaScript loading through the standard `WebAssembly` API
- Freestanding runtime v0.8 (implemented): five hooks — alloc, realloc, free, write, exit
  — and the freestanding object needs nothing from libc, only the compiler primitives every
  freestanding toolchain provides; the core's `snprintf`, `strtoll` and `strtod` are written
  out so panic messages and integer text need no libc; float text stays a hook because
  correct decimal output for a double is not a page of code; the panic path allocates
  nothing so it still reports when memory is what ran out; and the hooks are weak in the
  hosted profiles, which keep calling libc directly so the default profile's hot paths are
  unchanged
- Readiness polling v0.8 (implemented): one `Poller` over epoll and kqueue,
  **level-triggered** because that is the mode a caller can use imprecisely and still be
  correct; events carry the caller's token rather than a descriptor, since a descriptor
  number is reused the instant it closes; kqueue's separate read and write filters are
  merged so the event count matches epoll's; and a cross-thread wake goes through a
  slot-plus-generation `int` handle, so a wake after close is reported instead of writing
  into whatever inherited the descriptor; async park tokens live in a locked shared
  registry, so a worker-thread close marks and wakes the executor that owns the park
- Live children v0.8 (implemented): `Command.start()` gives a `Child` whose streams stay
  open; a dropped `Child` is asked to stop, killed if it refuses, and always reaped, so
  neither an orphan nor a zombie can escape; "still running" is `none` rather than an
  error because escalation is the normal path; and the child's inherited signal mask is
  cleared before exec, without which a child of a signal-watching parent starts
  unstoppable
- Sockets v0.8 (implemented): `TcpListener`/`TcpStream`/`UdpSocket` as move-only
  `unique class` handles, so one owner closes exactly once; the address family is
  resolved rather than chosen, so IPv4 and IPv6 need no flag; reads and writes are
  partial by contract with an empty `Bytes` meaning EOF; every blocking call retries
  `EINTR`, every timeout is an `err` with kind `timeout` rather than a hang, and every
  descriptor is close-on-exec
- Processes v0.8 (implemented): `Command`/`Output` with no shell anywhere, both output
  streams drained at once so heavy output cannot deadlock, a start failure reported
  separately from a non-zero exit through a close-on-exec pipe, signals as a negative
  status, bounded capture, and every child reaped
- Shared memory v0.8 (implemented): a POSIX shm object as an ordinary `MMap`, with the
  size stated on every open because `fstat` page-rounds it, an oversized request
  refused rather than faulting on first touch, and `unlink` removing the name while
  existing mappings keep working
- Clocks and secure random v0.8 (implemented): a monotonic clock and a wall clock
  with separate names so a duration cannot be measured with the wrong one, a sleep
  that is a floor rather than an estimate, and random bytes from the OS CSPRNG with
  no pseudo-random fallback and no modulo bias
- Intrinsics v0.8 (implemented): `std.intrinsic` is a closed allowlist of named
  machine operations with fixed signatures — no LLVM text, `unsafe` only, arch and
  feature gated through the same guard rule as `feature "x" fn`, and every entry has
  an exact software definition so it is differential-tested
- CPU dispatch v0.8 (implemented): `cpu.has(CpuFeature.x)` asks the running
  machine, `feature "x" fn` marks a body allowed to use that feature, and the
  compiler *requires* the guard — an unguarded call to a marked function is an
  error, not a crash on the wrong machine; `BEANS_CPU_FEATURES` can only hide
  features, never invent them
- SIMD families v0.8 (implemented): a vector's name is its shape, parsed once into
  (lanes, element) so every family gets the same operations instead of each being
  hand-written; comparisons give an all-ones/all-zeros mask that `select` consumes
  bitwise; 256-bit shapes are gated on the target's features and refused by name
- Atomic wait/notify v0.8 (implemented): `wait`, `wait_timeout`, `notify_one`,
  `notify_all` — a futex on Linux for 32-bit cells and an address-keyed parking lot
  everywhere else, behind one API; a wakeup is explicitly a hint, so callers loop
- Typed atomics v0.8 (implemented): `Atomic<T>` over integers and `bool` with all
  five memory orders, `compare_exchange` taking success and failure orders, and
  `Atomic.fence`; the order is a call-site literal because LLVM puts it inside the
  instruction, so `MemoryOrder` is neither a declarable type nor a storable value;
  invalid order combinations are compile errors rather than silently stronger
  barriers
- Layout modifiers v0.8 (implemented): `packed` and `align(N)` as contextual
  modifiers on `extern "C"` structs and unions, plus `align(N)` on a single
  field; C's semantics, checked against Clang for every supported target; a
  field alignment inside a `packed` record is an error rather than a silent
  winner; classes keep their layout because `packed` there would break the ARC
  header's alignment
- OOP completion (implemented): `priv` fields and methods are declaring-type private;
  classes support initialized static fields, abstract methods/classes, and
  eager `singleton class` instances; structs support generics, read-only
  methods, and mutating `inout fn` methods
- Targets v0.8 (implemented): one explicit selected target instead of "whatever
  compiled the compiler" — `--target`/`--cpu`/`--features`/`--sysroot`/`--cc`/
  `--linker`/`--emit`, registered triples with alias normalization, every
  setting validated before native compilation runs, tools executed directly
  rather than through a shell, the selected triple emitted into the IR, and
  `std.target` exposing the selected target's facts as compile-time constants
- Syntax v0.7 (implemented): classes use `new Class(...)` or target-typed
  `new(...)` construction;
  implicit instance `self`; explicit `static fn`; `extends`/`implements`;
  `T implements A & B`; `move`; `unique class`; `extern "C" struct/union`;
  Option/Result combinators are instance methods; old forms have no aliases
- `init`/`deinit`: constructor and destructor bodies use implicit `self`;
  all-default classes get an implicit initializer; required fields require
  `init`; subclass initializer inheritance is allowed when added fields all
  have defaults; `super.init` keeps the Swift order — own fields, then parent,
  then full self; destruction runs at refcount zero before field release,
  subclass then parent, and is skipped for cycle garbage
- Stdlib v0.5 phase 4 (implemented): Beans-written `std.reader` line reading over positional I/O (the old native `BufReader` is gone), format specs in interpolation (`{x:8.2}` — first top-level `:` in the braces; the same rendering as `std.fmt`), `chars()` for UTF-8, varint + crc32 on `Bytes`, `MMap.resize` (the handle keeps its fd), `Dir.walk` (recursive, sorted, relative), and Beans-written `std.path`
- Stdlib v0.5 phase 3 (implemented): the List/Map method set with **stable** sorts (`sort_by` takes a less-than closure; both backends run the identical merge), `Bytes` value `==`, advisory file locks, `MMap` (whole-file, shared, drop unmaps, grow = close + reopen), `std.fmt`, and printing widened to enums and lists — `variant(payload)` / `[a, b]` — everywhere strings interpolate; maps, class instances, and `Result` stay unprintable
- Stdlib v0.5: the string method set, `Bytes`, `File`/`Dir`, `std.os`, and the `std.io` console set (implemented); byte semantics, panics carry positions, mutators return self for chaining, fs errors carry kind slugs
- Modules: `beans.pot`, one folder = one package, git imports with a global cache (v0.4, implemented)
- Block-bodied match arms in statement position (v0.4, implemented)
- `pub interface` exposes its method set implicitly (v0.4)
- Explicit types everywhere, no inference (v0.2) — match bindings relaxed in v0.3
- Named field literals remain for structs; classes construct only with `new`
- No `+` on strings — interpolation / `std.fmt` / `join` only (v0.3)
- Package-private by default, `pub` to expose, and `priv` for declaring-type
  private fields and methods
- OS threads + checked `Send` captures/returns + `Mutex<T>.with_lock` + `Channel<T>`
- `decimal` built-in for money (v0.2)
- Go-style remote imports from git hosts + beans.pot (v0.2)
- `Result<T>`, error type defaults to built-in `Error`
- User-defined enums in v1, payloads allowed
- Class methods use Java-style mutability. Struct methods use read-only `self`
  unless declared `inout fn`.
- `as?` checked downcast returning `Option<T>`
- `fn`

There are no open 1.0 language questions. Later language changes follow SemVer;
breaking syntax or behavior needs a new major version.
