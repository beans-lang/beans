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
extern, variadic, and `inout` calls are not reflective call targets.
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
cflags all -DSHIM_BUILD -I native/include
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

### Named imports

`import {…} from path` binds exactly the names it selects — no module
name — and resolves at compile time like the module-qualified form, so
the two spellings produce identical programs:

```beans
import {println} from std.io
import {Value, parse, encode as to_json} from std.encoding.json
import {json, xml} from std.encoding

fn main() {
    println(to_json(parse("[1]").expect("parse")).expect("encode"))
    let v: Value = parse("true").expect("again")
    json.encode(3).expect("modules still work")
}
```

- A selection names anything `pub` in the target: functions, classes,
  structs, enums, interfaces, annotations. The bare name then works
  everywhere the qualified name did — calls, values, types, `new`,
  static access, patterns, `@annotations`.
- `as` renames one selection inside the braces
  (`{encode as to_json}`); the list itself takes no trailing `as`.
- When the path is a namespace folder rather than a package
  (`std.encoding`), the selection names its sub-packages and each binds
  as a module: `import {json, xml} from std.encoding` is
  `import std.encoding.json` + `import std.encoding.xml` on one line.
- Selected names share the one namespace of the file's import bindings:
  colliding with another import or with a declaration of the importing
  package is an error at the import line, and locals still shadow.
- The import line also checks the selection: a name the target does not
  declare, or one that is not `pub`, fails where it is written.

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
- `cflags <selector> <flag> [<flag>...]` adds Clang flags to the `csrc` files
  **the same package declared**. A dependency's `-D` never reaches another
  package's C, so one package cannot silently miscompile another's code with a
  define its author never saw. Flags are separate words rather than one quoted
  string, so a path with a space stays one argument. Every flag is part of the
  object's cache key: changing one recompiles instead of reusing the object
  built with the old set. `-o` and `-c` are refused — the object path belongs
  to the build.

## Lexical

- No semicolons. Newline ends a statement (Go-style: only after a token that can end one).
- A member chain may break at a `.` on either side: a line ending in `.`
  continues (the dot can never end a statement), and a newline is not a
  terminator when the next line begins with `.name` — so fluent chains write
  trailing-dot or leading-dot style. `..` stays a range operator and never
  continues a line. `...` is one token and means only the C variadic tail in
  an `extern "C" fn` signature.
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
- **Width is measured in display columns, not bytes.** `{s:12}` fills until the
  rendered value occupies twelve terminal columns, so `"café 東京 🍜"` (17 bytes,
  9 characters, 12 columns) is already full and `"ok"` gets ten spaces. Byte
  padding lined up only ASCII; there is no caller that wanted it for anything
  else. `s.width()` is the same measure, spelled out.
- **There is no `+` for strings.** To render *one* string, use interpolation
  (`"hi {name}"`) or `std.fmt` (sprintf-style: padding, precision, alignment).
  To *accumulate* a string across a loop, use `fmt.StringBuilder` (push the
  pieces, `to_string()` once) or `list.join(sep)` — never `text = "{text}piece"`
  in a loop, which rebuilds the whole string every turn and so costs O(n²) in
  the total length. Interpolation is the readable tool for a single value and
  the wrong one for a growing buffer; a builder is the other way round.
- Escapes: `\n \t \r \0 \\ \" \{ \} \xNN \u{...}`. Anything else after a
  backslash is an error, not the character itself — `"C:\Users"` says so
  instead of quietly becoming `C:Users`. The backslash forms are the *only*
  brace escapes: `{{` is not one. A `{` right after another `{` begins an
  interpolation whose expression starts with a map literal, so `"{{}}"` is an
  (illegal) empty-map piece, not a literal `{}`. Both compilers render every
  escape identically, in and out of interpolated strings.
- `\xNN` is exactly two hex digits and stands for **one raw byte**, whatever
  that byte is. `"\x1b[2J"` is the ANSI clear-screen sequence. A value at or
  above `\x80` puts a byte in the string that is not valid UTF-8 on its own,
  and that is the point: a string is binary-safe (`\0` has always been
  spellable), so a protocol byte is written as the byte. `chars()` hands such
  a byte back one at a time, the same as any other malformed sequence.
- `\u{...}` is one to six hex digits and stands for a **Unicode scalar**,
  encoded UTF-8: `"\u{1f600}"` is four bytes. The value must be at most
  `10FFFF`, and the surrogate range `D800`–`DFFF` is refused because it has no
  UTF-8 form. This is `chars()`'s inverse: every element `chars()` returns for
  well-formed text can be written back with `\u{...}`.
- There is no `\e`. `\x1b` already names that byte, in the spelling C, C++,
  Rust and Python all use; a second name for one byte would reserve a letter
  forever and buy nothing.

### Raw string literals

```
r"/users/{id}"           // a route template, brace and all
r"\d+"                   // a regex, backslash and all
r#"say "hi""#            // n hashes when the body holds a quote
r##"…"#…"##              // more hashes when the body holds `"#`
```

A raw literal is bytes, not syntax. Nothing in it is an escape and nothing in
it opens an interpolation, so a literal meant to be read by something other
than Beans — a route template, a regex, a Windows path, a printf format, a
JSON fixture — is written the way its own reader spells it. The opener is `r`
followed by any number of `#`, then `"`; the terminator is `"` followed by the
same number of `#`. A raw literal may span lines: the terminator is explicit,
so there is no end of line to guess at.

`r` is only a prefix when the quote follows it with nothing in between, so `r`
stays an ordinary name everywhere else.

Rawness is a spelling, not a kind. The two forms make the same string, they
are the same type, they compare equal, and below the checker there is one
spelling: a raw literal used as a match pattern or folded into a `const` is
rewritten with ordinary escapes, so nothing downstream ever meets a second
shape. A raw literal is a compile-time constant, so it works where one is
required — an annotation argument most of all:

```
@route(path: r"/users/{id}")
pub fn show(id: int) -> int { return id }
```

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

`width() -> int` is the third measure, beside `len()` in bytes and
`chars().len()` in characters: how many terminal columns the string occupies.
It is what `{s:N}` and `std.fmt`'s pads fill to. The rules, from the Unicode
Character Database (`tools/gen_width_table.py` regenerates the tables in
`runtime/beans_rt.c`; the shipped ones are Unicode 17.0.0):

- East_Asian_Width `W` and `F`, and anything with `Emoji_Presentation`, take
  two columns; everything else takes one.
- Combining marks (`Mn`, `Me`), format characters (`Cf`), control characters
  (`Cc`), conjoining Hangul jamo (`V`, `T`) and the emoji skin-tone modifiers
  take none. `U+00AD SOFT HYPHEN` is the one exception: terminals draw it, so
  it counts one.
- `U+200D ZERO WIDTH JOINER` welds the next scalar onto the current glyph, so
  that scalar takes no column either: a four-person family emoji is two
  columns, not eight.
- `U+FE0F` promotes the pictograph before it to two columns and `U+FE0E`
  pulls it back to one, so `❤` is one column and `❤️` is two.
- Two regional indicators make one flag and two columns; a third starts a new
  pair.
- Invalid UTF-8 counts one column per bad byte, which is what a terminal draws
  for the replacement character it substitutes. A byte is bad when it does not
  start a well-formed sequence, when its sequence is truncated, and when the
  bytes are well formed but spell what UTF-8 does not encode — an overlong
  form, half a surrogate pair, a scalar past the last plane. A bad byte also
  stands between whatever was joining or pairing across it.

This is a column count, not a grapheme count: a `Mc` spacing mark advances the
caret and counts one, and no normalization happens first.

## Bytes (v0.5, implemented)

The binary buffer — strings stay text; anything binary is `Bytes`. `Bytes` is a
move-only `Send` owner, not `Sync`: one thread may mutate it, and ownership may
move to another thread, but aliases cannot race. Mutating methods return
`unit`; write page-building steps as separate statements. `slice` makes an
explicit deep copy.

- `new Bytes(n)` (zeroed, panics on negative), `Bytes.filled(n, byte)`,
  `Bytes.from(s)` (copies the text bytes)
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
  `append_int_text(v)`, `append_i64(v)` (little-endian),
  `append_range(src, from, to)` (no slice allocation)
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
  the durability call), `close` (double close is an error result). `File` is a
  move-only `Send` owner, not `Sync`. Dropping the owner closes the fd as a
  safety net; `close()` is still the API.
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
- **std.reader**: `new reader.Reader(move f)` then `read_line()` → `Result<Option<string>>` —
  `ok(some(line))` without its newline, a partial last line, then `ok(none)` at EOF.
  The reader owns the file and reads at its own offset (pread), so the file's
  cursor never moves. `file_position()` reports that offset and `close()` closes
  the owned file. Buffering and line policy are Beans source; only
  `File.read_at` stays native. The old native `BufReader` type is gone.
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
provides integer `clamp` and `gcd`, the float helpers `fmax`, `fmin`, `fclamp`,
`rem_euclid`, `is_finite`, `infinity`, `sqrt` and `hypot`, and the
transcendentals `exp`, `sin` and `cos` — each with an `f32` twin named with a
`32` suffix, the convention `std.intrinsic` sets with `sqrt`/`sqrt32`. They are
written in Beans rather than bound to the platform's libm, because a
freestanding or `wasm32-unknown-unknown` build has no libm and a std module
that silently does not exist on some targets is worse than one that works
everywhere. Measured against libm on raw bit patterns: `exp` within 1
representable step over its whole finite range and exact where the result is
subnormal, `sin` and `cos` within 2, and bit-identical at the multiples of
pi/2. Past `angle_limit()` an f64 carries fewer bits than a full turn needs, so
`sin` and `cos` answer NaN rather than invent one; `std.bytes` provides Beans-written `crc32`,
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
enums, as `variant` or `variant(payload, ...)`; options as `some(x)` / `none` and results as
`ok(x)` / `err(e)`; lists of printable things, as `[a, b, c]`; maps of printable keys and
values, as `{k: v, k: v}`; and structs and class instances, as `Name { field: value, ... }` —
nesting included, and `join(sep)` renders the same way. A result's default `err` payload is an
`Error`, which prints as the message a caller passed to `err(...)`; a custom err type prints
as itself. A map renders its entries in the order `keys()` walks. For a map only inserted into and
updated in place that is **insertion order** — an updated key keeps the place it was first
given — and both backends impose the same one, so a golden file can pin it. A **removal** is
the exception: a plain `Map` swap-removes, and the two engines do not agree today on the order
that leaves behind, so nothing should pin the rendering of a `Map` a key has been removed
from. `OrderedMap` keeps its order across a removal, on both. Strings render without quotes,
the same as inside a list.

A struct or class instance renders its fields **in declaration order**, using the bare type
name (`Point { x: 1, y: 2 }`, `Empty {}`). A **class** that declares its own string form —
a `to_string() -> string` method taking no argument — renders through it instead: `{obj}` and
every nested position (a list element, a map key or value, another object's field, `join`)
print what `to_string` returns, so a class's own form wins over the derived one everywhere,
a generic class included. A class with a `to_string` is printable even when a field of it is
not, since the derived form is never used. A **struct** does not take this path: its
`to_string` is an ordinary method you can call, and `{p}` still renders the derived form —
both backends agree on that, and widening it to structs is a separate change.
When there is no `to_string`, the derived form is the compiler's own view of the value, so:

- A **private** field is shown like any other — hiding half the object would make the debug
  form lie.
- A **move-only** field is shown by borrowing it; rendering never moves or consumes a value.
- A **weak** field prints as `<weak>` and is **not followed**. It is the one edge the cycle
  collector refuses to trace, and the printer refuses it too — so a cleared weak cannot fault
  the printer and a back-reference cannot loop it. Its type need not be printable.
- Static fields belong to the type, not the instance, and never appear.
- A **reference cycle** prints `<cycle>` where it closes; a shared value that is not on the
  current path renders in full each time it is reached.

Only a class whose declared type is the one concrete type a value of it can carry prints this
way: a **leaf, standalone class** (not an interface, not `abstract`, not a base another class
`extends`, and — until inherited fields render — not itself extending one). A base, an
interface or an abstract class is refused, because its value's real type is not knowable from
its declared one and the two backends would render different fields; give it a string form
first, or match on it.

A key or an element too wide for one runtime slot — a struct, a `decimal`, an inline
`Option` — is rendered from where it really lives rather than refused, so `{m}` on a
`Map<Point, string>` and `xs.join(", ")` on a `List<Point>` print what `{xs}` prints.
`join` refuses exactly what interpolation refuses, at check time and with the same message
on both backends.

[examples/kv.b](examples/kv.b) is the proof: an append-only KV store with binary records and a
durable compaction (write temp, sync, rename over, sync the parent dir).

## MMap (v0.5, implemented)

A shared mapping of a whole file — the page-cache path a database wants. `MMap`
is a move-only `Send` owner, not `Sync`. The mapped region is not Beans heap;
one owner may move between threads, but concurrent aliases are forbidden.

- `MMap.open(path, writable)` → `Result<MMap>` — maps the entire file (`MAP_SHARED`); the
  handle keeps its fd for `resize`, and the mapping outlives the path — unlink while mapped
  is fine. An empty file maps with `len() == 0`.
- `len()`; `get_u8/u16/u32/u64/i64(pos)` and `put_...(pos, v)` — little-endian,
  bounds-checked panics; `put` panics on a read-only map; `put`/`write` return
  `unit`.
- `read(pos, n)` → `Bytes` (copy out), `write(pos, b)` — panics out of range.
- `flush()` / `flush_range(pos, n)` → `Result<bool>` (msync — the durability call),
  `close()` → `Result<bool>` (double close is an error; access after close panics).
- `resize(n)` → `Result<bool>` — ftruncate + remap in place, grow or shrink; read-only
  maps refuse with a `permission` error. On a remap failure the handle stays open but empty.
- Dropping the owner unmaps (and closes the fd) as a safety net.
- The backing descriptor is close-on-exec while the mapping owns it.

## std.fmt (v0.5, implemented)

Interpolation assembles, fmt formats. No printf — the language has no varargs.

- `pad_left(s, width)` / `pad_right(s, width)` — spaces, **display columns**
  (`string.width()`, not `len()`); already-wide input comes back unchanged.
- `float(x, places)` — fixed decimals (`3.14`), places clamped to 0..100.
- `decimal(d, places)` — exact decimals: rounds half-even when narrowing, zero-pads
  when widening. `fmt.decimal(19.995, 2)` is `"20.00"`.
- `hex(n)` / `binary(n)` — the 64-bit two's-complement pattern, lowercase, no prefix:
  `hex(-1)` is 16 f's.
- `group_digits(n, sep)` — thousands grouping: `group_digits(1234567, ",")` is `"1,234,567"`.
- `StringBuilder` — accumulate a string across a loop into one growing buffer:
  `push(text)`, `push_int`, `push_bool`, `push_line`, `push_byte`, then
  `to_string()` (or `to_bytes()`) once. `text = "{text}piece"` in a loop rebuilds
  the whole string every turn — O(n²) in the length; a builder is O(n).

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

struct User {
    pub id: u64
    pub name: string
}
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
  are rejected, and so is a string whose bytes are not valid UTF-8. A value
  that carries more than one such fault is reported by the first one the
  writer reaches in document order — a field that is omitted from the document
  cannot be the one reported.
- `encode_into<T>(value, target)` appends that same compact encoding to the
  caller's `Bytes` — after whatever it already holds — and returns
  `Result<int>`, the number of bytes appended. `T` is validated exactly as for
  `encode`, and the bytes it writes equal `encode(value)` byte for byte; it
  exists so a body can be serialized straight into an output buffer without a
  fresh string and its copy. A refused `T` refuses identically to `encode`, and
  a refusal at run time leaves `target` exactly as it was — every byte it held
  before the call, and nothing appended.
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
- `Reader` and `Writer` are cursors holding a position and an order. They do
  not own a buffer; every method borrows the caller's `Bytes` per call.
  `remaining(data)` and `skip(data, n)` complete the cursor surface.

## Variables

```
let x: int = 5              // can't be reassigned (like Java final)
var total: decimal = 0.0    // can be reassigned
```

`let` means the *variable* can't be rebound. The object it points to can still change inside (Java-style — no borrow checker, no `mut` markers).

`_` in a binding position is a **discard**, not a name. It works wherever a name
is bound — `let`, `var`, function and closure parameters, loop bindings, and the
payload bindings of a match pattern:

```
let _: Report = build_report()      // built, then dropped at the end of the scope
fn log(_: Request, id: int) { ... }
for _: int in 0..3 { work() }
match shape { line(_, _) => "line", dot => "dot" }
```

A discard binds nothing, so any number of them may share one scope and none of
them can be read, moved, lent, or assigned to. Reading one is an error that says
so, not "unknown name". A bare `_` arm of a match is the same character used as
a wildcard pattern and is unaffected.

The value is still owned. A discard takes the value it is given and drops it at
the end of its scope, exactly like a named binding — once, and never twice — so
`let _: Packet = open()` and `fn eat(move _: Packet)` release what they take at
the same point a named `let` or `move` parameter would. `_` removes the name,
not the ownership.

### Module constants (v0.9, implemented)

`let` and `var` are statements and live inside a function. A named value that
belongs to the module is a `const`:

```
const TERMIOS_BYTES: int = 128
const TCSAFLUSH: i32 = 2
const O_NONBLOCK: i32 = 1 << 11
const GREETING: string = "hello"
pub const MAX_FRAME: int = 1 << 20      // pub, for a library package
```

A `const` has **no storage and no address**. The checker folds the initializer
once, and every use is that value written where the use is — so a constant
costs exactly what typing the literal there would cost, in both backends. It
cannot be assigned to, and `&`-style address-taking never applied to it.

- The type is written out and is a number, `bool` or `string`. There is no
  composite constant: with no storage there is nothing for a list or an object
  to live in.
- The initializer is a **constant expression**: literals; other constants,
  including ones declared further down the file or in another package
  (`pkg.NAME`, or selected with `import {NAME} from pkg`); unary `-`, `!`, `~`;
  and the binary operators `+ - * / % & | ^ << >> && || == != < <= > >=`.
  Anything else is refused with a message that names what was not constant —
  a call, a local, a field read, an `as` cast, a `{}` piece in a string.
- Integer folding answers what the same expression answers at run time: every
  result is narrowed to its own type, so `const X: i32 = 1 << 31` is `i32`'s
  smallest value, not an error. Division or modulo by zero, a shift count
  outside `0..bits-1`, and dividing a signed minimum by `-1` are refused. `u64`
  is the one type the fold cannot carry whole: a `u64` value at or above
  `2^63` may be **declared** and used like any other constant, but no
  operator may fold with one — arithmetic, shifts and comparisons alike are
  refused, because the fold computes in signed 64 bits and would otherwise
  answer with signed order for a number the program never holds.
- Floats and decimals fold a literal and unary minus, and no arithmetic. The
  compiler will not re-round a value the source did not write.
- A constant that names itself, directly or through another constant, is
  refused.
- A constant stands where a literal stands. That includes match arms and
  annotation arguments:

```
const LIMIT: int = 128

match n {
    LIMIT => { … }
    _ => { … }
}
```

- `size_of`, `align_of` and `offset_of` are **not** constant expressions: they
  are answered after layout, which runs later than a constant is folded, so
  they cannot appear in a `const` initializer.
- A constant may **size a fixed array**, in every position a type is written
  — a local, a field, a parameter, a result, and nested inside another fixed
  array. Constants are folded at the end of signature checking, before any
  type is laid out, so the length is the folded value:

```
const LIMIT: int = 128

let frame: [int; LIMIT] = […]
struct Row { cells: [int; LIMIT] }
fn widen(row: [int; LIMIT]) -> [[int; LIMIT]; 2] { … }
```

  The constant is reached the way one is reached anywhere: bare in its own
  package, qualified through a package alias (`[int; limits.SLOTS]`), or
  selected with `import {SLOTS} from pkg`. A name that is not a constant is
  refused for what it is, and a constant that cannot supply a length — not an
  integer, or outside `1..4096` — is refused at the name and says which
  constant it is and what it holds.

- A `const` **cannot be a parameter default** — a default is read while the
  signature holding it is lowered, and the fold runs at the end of that stage
  (`fn f(n: int = 128)`, not `= LIMIT`). It is refused where it is written,
  with a message that names the name and says why an array length differs.
- `const` is contextual. It is a declaration keyword only in `const <NAME>` at
  the start of a module-level declaration, and stays an ordinary identifier
  everywhere else.

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
synchronization boundary: it is `Send` and `Sync` when `T` is `Send`, and also
when the mutex owns `T` outright — a move-only `T` whose own state cannot be
reached any other way. An ordinary `class` is not that, because it is an
aliasable handle and the move into the mutex takes nothing away from whoever
else holds it; a `unique class` is, so long as every field is `Send` or owned
the same way.

### Struct and collection literals

Structs keep named field literals. Lists and maps keep their literal forms:

```
let point: Point = Point { x: 3, y: 4 }
let values: List<int> = [1, 2, 3]
let counts: Map<string, int> = {"beans": 2}
```

Struct fields may declare defaults exactly like class fields, and a field
literal only needs the fields without one. A struct whose fields all carry
defaults builds from the empty literal:

```
struct Style {
    size: int = 12
    name: string = "plain"
}

let plain: Style = Style {}                  // size 12, name "plain"
let big: Style = Style { size: 20 }          // name still "plain"
```

Omitting a field that has no default is an error naming the missing field.

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
- **Scale is part of the answer.** `a + b` and `a - b` carry
  `max(scale(a), scale(b))`; `a * b` carries `scale(a) + scale(b)`; `a / b`
  carries the smallest scale that represents the exact quotient, and when the
  quotient is zero it carries `max(0, scale(a) - scale(b))` — so `1.25 + 1.25`
  is `2.50`, `123.45 * 10000000` is `1234500000.00`, and `0.000 / 0.7` is
  `0.00`. Growing toward that scale stops at 38 significant digits, because the
  appended zeros are significant; a zero coefficient has none to protect and
  always reaches the full scale, which is what makes `0E-45 + 0E-1` and
  `0E-1 + 0E-45` the same number. There is no negative scale and no negative
  zero: a scale the rules put below 0 is 0, and `-0` and `0` are one value.
- Decimal stays an inline value in locals, fields, parameters, returns, List,
  Map values, Box, Arena, Shared, Mutex, Channel, and thread results.
- Native layout is `{i128 coefficient, i64 scale}` (32 bytes, 16-byte
  alignment). Arithmetic uses checked wide intermediates so a valid input can
  never wrap before its 38-digit result is checked.

### Number rules

- A number literal takes the type the spot demands: `let p: decimal = 19.99` makes a decimal, `let f: f64 = 19.99` makes a float. No suffix zoo.
- With no demand, an integer literal is `int` and a decimal-point literal is `f64`.
- **A cast is a demand when its operand is a number literal.** A number written
  straight under `as decimal`, `as float`/`as f64` or `as f32` is read *in* that
  type: `19.99 as decimal` is the decimal 19.99, exactly like `let p: decimal =
  19.99`, and the f64 that would otherwise stand between them never exists. A
  leading `-` belongs to the literal, so `-19.99 as decimal` is the decimal
  -19.99. It reaches through nothing else: `rate as decimal` where `rate` is a
  `float` variable still says exactly what that float is, because the operand is
  a value and not a spelling. Integer targets are excluded so the wrapping rule
  below keeps its meaning — `300 as i8` is still `44`.
- A hex or binary literal is the integer it spells, in `float`, `f32` and
  `decimal` as much as in an integer type, and there it must be an `int` value:
  `0xffffffffffffffff` is a bit pattern, which `u64` has a rule for and a
  real-number type does not.
- **No implicit numeric conversions, ever.** Mixing `int`/`float`/`decimal` needs `as`: `price * (qty as decimal)`.
- Integer literals must fit their demanded type. The checker rejects both ends outside the exact `i8`..`u64` range.
- Fixed-width integer `+`, `-`, `*`, unary `-`, and bit operations wrap to that width. Shift counts are masked by `width - 1`. Divide or modulo by zero panics.
- Integer casts keep the low target-width bits. Widening sign-extends a signed source and zero-extends an unsigned source.
- **A float-to-integer cast saturates at the target type's own range**, and NaN
  is `0`. `+inf` and anything above the maximum give the maximum, `-inf` and
  anything below the minimum give the minimum, and a value inside the range
  truncates toward zero as usual. The bound is the target's, not `int`'s and
  then narrowed: `1e300 as i32` is `2147483647`, never `-1`. `float.round()`
  and `f32.round()` answer the same way. The rule holds for every width from
  both `f32` and `f64`, in the interpreter and the native backend alike — the
  native one emits `llvm.fptosi.sat` / `llvm.fptoui.sat`, because a bare
  `fptosi` is *poison* for exactly these inputs and the same expression
  answered a different number on every build. Saturation is the rule and
  not a panic, deliberately: the interpreter already answered this way, so
  making the two backends agree meant giving the native one that same rule,
  not turning a shipped total conversion into a fault. It maps every float —
  NaN and both infinities included — to a defined value at no codegen cost
  (one saturating instruction), and it is what the nearest neighbours do (a
  Rust `as` from float to integer, WebAssembly's `trunc_sat`). The cost is
  named here rather than hidden: a magnitude past the target's range becomes
  the bound silently instead of stopping the program, so code that must not
  proceed on such a value checks the range before the cast. `decimal` still
  panics on NaN, an infinity, or a magnitude past 38 digits (below), because
  those have no nearest decimal to land on, where a bounded integer type has
  an obvious one at each end.
- `f32` rounds after every literal, cast, and arithmetic operation. It is a real 32-bit LLVM value in locals, calls, and fields, not an alias for `f64`.
- Float comparisons are IEEE-754: a NaN operand makes `==`, `<`, `<=`, `>`, and
  `>=` false and `!=` true, in the interpreter and the native backend alike.
  (Decided after an audit found the interpreter collapsing NaN to "equal" while
  the native backend answered `!=` with an ordered compare — every implementation
  now agrees.) Casting NaN or an infinity to `decimal` panics as `decimal
  overflow`, the same as any float whose magnitude exceeds 38 digits.
- **`Order` and `Eq` on a float are total, and the operators above are not.**
  IEEE comparison is not an order: NaN is unordered with everything, so
  `[3.0, 1.0, nan, 2.0].sort()` answered `[1, 3, nan, 2]`, a map read `nan`
  as equal to no key including itself — every re-insert appended and no read
  could ever find it — and anything that binary-searches read "neither less
  nor greater" as "found it" and overwrote an unrelated key. `float` and
  `f32` therefore order by IEEE 754 **totalOrder** wherever the comparing is
  done by the `Order` or `Eq` interface rather than by an operator:

  ```
  -NaN < -inf < ... < -1.0 < -0.0 < +0.0 < 1.0 < ... < +inf < +NaN
  ```

  The equality that belongs with that order is **bit equality**. Two NaNs are
  one value when their sign and payload match, and `-0.0` and `+0.0` are two
  values — so they are two map keys, they do not find each other, and a sort
  puts `-0.0` first. This is the same split Java draws between `a < b` on a
  `double` and `Double.compare`/`Double.equals`, and it reaches:

  - `List.sort`, `max`, `min`, `contains`, `index_of`, and `List == List`;
  - `Map` and `OrderedMap` keys — lookup, replacement, removal and hashing;
  - the structural `==` of a struct, fixed array, `Option` or enum that holds
    a float, and the same value used as a wide map key;
  - `<`, `<=`, `>`, `>=`, `==` and `!=` applied to a value whose type is a
    **type parameter**, which is how a container written in Beans compares
    the keys it was handed. `fn less<T implements Order>(a: T, b: T) -> bool
    { return a < b }` answers `true` for `less(1.0, nan)`, while a bare
    `1.0 < nan` in the same program answers `false`: one is the interface,
    the other is the operator. Only `float` and `f32` read differently
    between the two — every other `Order` type has one order.

  A bare `float == float` or `float < float` stays IEEE in every one of those
  spots. Which NaN an operation produces is the platform's business, as it is
  everywhere; totalOrder only promises a defined answer for the bits it is
  given.

  `decimal` needs none of this and gets none: it has no NaN and no negative
  zero (see *decimal* above — a scale below 0 is 0, and `-0` and `0` are one
  value), so its order is already total and its comparison is unchanged.

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
is strict less-than), `sort_by_key(fn(T) -> int)` (one key call per item — including the
one item a one-element list holds, which nothing sorts), `join(sep)`.
Sorts are **stable**. The native backend uses a stable radix path for integers and integer
keys, and the shared merge semantics for other values and custom predicates. Both backends
run the same bottom-up stable merge for a custom predicate, so they produce the same order
even for a predicate that is not a strict weak ordering; a comparator that reads the list
it is sorting (through a captured reference) sees the same intermediate states on both —
each merged block is committed to the list when it completes; and a comparator or key
function that panics (contained, spec/CONCURRENCY.md) leaves the list exactly as it was
before the call, on both backends. Reading is as far as it goes: a callback that
*structurally changes* the list mid-sort (push, remove, clear — anything that moves its
length or storage) is refused with `list changed during sort (length A -> B)` at the first
callback return after the change, on both backends — the sort would otherwise permute
stale storage. The list stays as the mutation left it; there is nothing coherent to
restore. Writing an element in place (`l[i] = v`) moves nothing and stays allowed.
`reserve(capacity)` on a List, `Map` or `OrderedMap` asks for room, never for less:
a negative capacity is a bug in the caller and panics as `negative reserve capacity
<n>`, and a capacity above 2^58 panics as `reserve capacity too large`. `reserve(0)`
and a capacity the collection already has are no-ops.

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

### Changing a collection while a loop reads it

`for x: T in xs` over a `List` reads the list itself, one element at a time. It
takes no copy, so a change the body makes is a change to what the loop is
walking.

A **structural** change is one that alters the list's length or moves an
element to a different index: `push`, `pop`, `insert`, `remove`, `clear`,
`reverse`, `sort`, `sort_by` and `sort_by_key`. Any of them invalidates the
iterator, and the loop panics before it reads another element — the same rule a
map follows, and the same rule whether the change came from the loop body, from
a function the body called, or from a closure it invoked. The message names the
operation that last changed the list and what its length did:

```
var xs: List<int> = [1, 2, 3, 4, 5]
for x: int in xs {
    xs.push(99)             // runtime panic at 2:1:
}                           // list changed during iteration (push, length 5 -> 6)
```

Everything else is allowed and the loop keeps running:

- `xs[i] = v` at an index the list already has. The loop sees the replacement
  when it reaches that index — exactly as replacing an existing map key's value
  is allowed and read live. Writing an index the list does not have still
  panics as an out-of-range write, iteration or no iteration.
- `reserve(n)` on a List changes only its capacity and moves no element, so it
  never invalidates the loop. (A map is stricter: it counts *every* `reserve`
  among the changes that invalidate its iterator, `reserve(0)` included, because
  a map that grows rehashes and moves its entries between buckets. A List has no
  buckets to rehash, so its `reserve` is always safe to call mid-loop.)
- Every read: `len`, `get`, `first`, `last`, `contains`, `index_of`, `min`,
  `max`, `slice`, `clone`, `join`.
- Mutating a *different* list, including one built from this one by `clone` or
  `slice`.
- Mutating the *element* — a class element's fields are its own value, not the
  list's shape.
- Leaving the loop with `break` or `return` immediately after a structural
  change. The check happens before the next element is read, so a loop that
  never reads again never sees it.

This is not the same refusal as `list changed during sort`, and the two do not
overlap: that one is a *sort callback* changing the list its own sort is
permuting, and it fires inside the sort whether or not a loop is running. This
one is a *loop* reading a list something changed, and it fires on the loop's
next turn. A `sort_by` whose comparator pushes, called from inside a `for` loop
over that same list, hits the sort's refusal first — the sort never returns to
the loop.

`xs.slice(from, to)` answers a copy, so `for x: T in xs.slice(from, to)` walks
that copy and a change to `xs` does not reach it. The compiler may skip
materializing the copy and walk `xs`'s own storage when it can prove `xs`
cannot change while the loop runs; that is invisible, and if the proof were
ever wrong the loop stops with the same `list changed during iteration` panic
rather than reading storage that moved out from under it.

The rule for the other iterables follows from what they are:

- A **fixed array** is a value. `for value: T in a` walks the value `a` held
  when the loop started, and a write to `a` during the loop does not reach it.
- A **`Slice<T>`** is a borrowed `{pointer, length}` view of memory something
  else owns. Its length cannot change, so there is nothing to invalidate, and
  each turn reads the memory as it is now: a write to the memory it views during
  the loop -- made through whatever owns that memory -- is visible to the turns
  that have not run yet.
- A **range** is fixed when the loop starts.

Bracket reads are checked, required reads: `list[i]` panics when the index is
outside the list, and `map[key]` panics when the key is missing. Use
`list.get(i)` or `map.get(key)` when absence is expected; both return `Option`.
Bracket assignment stays `list[i] = value` and `map[key] = value`; List and
Map bracket assignment does not have compound forms. Fixed arrays support
numeric compound element assignment because their element is a real inline
place. Every assignment evaluates left to right — receiver, then index or
key, then the right-hand side — and a compound form evaluates its receiver
and its index once, not once to read and again to store. A field target
follows the same rule as a bracket target. Both backends run this order; a
side-effecting receiver, key and value observe it.

A `?` anywhere on the left short-circuits the whole statement, exactly as it
does on the right: `find(id)?.count = next()` leaves the function with the
propagated value and never runs `next()`.

A `Map` or `OrderedMap` **key must be copyable**, so a move-only type cannot be
one: the map owns a copy of every key it stores, and `keys()` hands copies back.
The type this rule is usually met with is `Bytes`, and the answer is `string`: a
Beans string is binary-safe — it keeps NULs and every other byte, and
`Bytes.to_string()` is every byte — so a byte-keyed map is a `Map<string, V>`
and nothing is lost in the conversion.

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

`Map.get` on a move-only value type is the one read that answers the
collection's own value rather than a copy — which is why the index forms are
refused there, and why the binding it lands in cannot be moved out. That makes
it a borrow of the map, and a move-only value has one live reader at a time:
reading the same map again while an earlier read is still in scope is refused,
because two such bindings would be two mutating names for one value. Reads that
do not overlap, reads of a different map, and reads of a value type that is not
move-only are all unaffected.

Writing one is a different question and has always had an answer. `m[k] = v`
takes a move-only value the same way `m.set(k, v)` does — it moves the value in,
drops whatever the key held before, and lowers to the same instruction — so the
read rule above applies to reads only. An existing move-only local still needs
`move`: `m[k] = move packet`.

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

A plain `fn(...) -> T` value is local, aliasable, and `Clone`. A
`send fn(...) -> T` value is move-only and implements `Send`, not `Sync` or
`Clone`. A closure gets the sendable form from its declared or parameter type;
a named function may also take that form because it has no captures.

Every capture of a `send fn` must implement `Send`. A move-only, mutable, or
non-`Sync` capture must also appear in `move(...)`, so the old thread keeps no
mutable alias. Immutable `Sync` captures may be shared. A plain `fn` never
silently converts to `send fn`.

**Capture by move.** `fn(...) move(a, b) -> T { ... }` captures the listed
enclosing locals by move: the closure owns them, the enclosing bindings are
spent (using one afterward is a use-after-move error), and each owned capture
is released exactly once when the closure value dies. This is how a move-only
value — a socket, a `Box`, a `List` — lives inside a callback and is torn
down with it. Each listed name must be an enclosing local the body actually
uses; `inout` parameters cannot be move-captured. Plain closure values stay
shared `fn` values: copying one shares the same closure and captures rather
than duplicating them. A `send fn` is move-only instead. Inside the body a
move capture still reads as a borrowed binding — it cannot be moved out again,
because the closure may be called more than once.

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
- `static fn` is required for class statics. A static method has no `self`, is
  not inherited, and is not dispatched: it is called on the type that declares
  it, as `User.guest()`, and `u.guest()` on a value is refused. See
  *Inheritance and interfaces* for the rule that follows from it — one name in
  a class family is a static or an instance method, never both.
- An unmarked method is package-visible, `pub fn` is visible from other
  packages, and `priv fn` is visible only inside its exact declaring class or
  struct. The same rule applies to `priv static fn`, `priv inout fn`, and
  `priv fn init`.
- A class field may also be `static`. It needs an initial value and is read or
  written through its declaring type, such as `User.created += 1`. Static
  fields are initialized once before `main`, in declaration order, and are not
  inherited. Generic classes cannot declare static fields.
- A static field — and a singleton's fields with it — lives for the whole
  process and is **never torn down**. What a static still owns when `main`
  returns is not released, so no `deinit` runs for it. The reverse of `init`
  at exit has no order to run in that the rest of the language would honour
  (unwind order is newest-first, but statics initialize oldest-first across
  files), and it would have to be skipped anyway for the two exits that
  matter most — `os.exit` and a panic. A process-lifetime resource that must
  be released closes itself explicitly; `deinit` is for values with owners.
- `new Class(...)` and target-typed `new(...)` are the class-construction forms.
  Both follow the class's `init` rules. `new(...)` gets its class from the
  declared result, assignment target, return type, or function parameter. It is
  an error when that context does not name a concrete class. Class field
  literals and plain `Class(...)` calls are errors.
- Compiler-owned types such as `Bytes`, `File`, `List`, and `Map` are not class
  declarations and cannot be extended. Put one in a field when a class needs
  to wrap it.
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
  rest start unassigned. Every default in the class chain is evaluated before any `init` body
  runs, in declaration order with the base class's fields first — so a default whose
  expression has an effect (a call that prints, a counter) has one order, not one per
  backend. **The checker proves every field is assigned before the object can be read**, so no
  path through the constructor reaches code that reads a field the constructor has not set yet.
  It is a definite-assignment proof, so branches count: a field assigned on every arm of an
  `if` or of an exhaustive `match` is assigned after it, one assigned in only some arms is not,
  and one assigned inside a loop is not (the loop may run zero times — a loop body never
  credits a field, so a value it computes has to be hoisted out to be assigned once); an arm
  that `panic`s or `return`s, and an unconditional `for {}` with no `break`, drop out of the
  merge because nothing after them runs. Two rules follow. A field cannot be read until it is
  assigned — not through `self.f`, not through a method that would read it, not in a string
  interpolation (`"{self.f}"` reads `f` and is checked exactly as `self.f` is). And until
  **every** field is assigned, `self` itself cannot escape: no method call on `self` (including
  `super.m(...)`, which runs the base method on this object), no passing `self` on, no
  `return`, no interpolating `self` whole — each could read a field that is not there yet. A
  field with a default counts as assigned from the start, and a `weak` field always does (its
  slot starts `none`); after the last field, anything goes.
- The proof is about the paths the checker can see, and a `panic` mid-`init` is not one of
  them — so the guarantee is held at that boundary by a release rule instead. **An object
  whose `init` has not returned is released without running its `deinit` body.** The fields it
  did assign are still released, in the ordinary order; only the class's own `deinit` chain is
  skipped, so nothing hands user code a `self` whose fields the initializer never reached.
  This covers every way construction can stop partway: a `panic` in the `init` body, in a
  field's default expression (evaluated before any body runs), or in a base `init` reached
  through `super.init`, and it covers a `deinit` the class inherits as much as one it declares.
  It is about that one object: everything it had already built and stored dies normally, and
  a reference the initializer handed out — possible only once every field is assigned — keeps
  the object alive, so its eventual death is an ordinary one that does run `deinit`. Both
  backends pick the same moments (#120). Note the language gives construction no other way to
  fail partway: `init` returns nothing, so `?` cannot leave it, and construction that can fail
  is a named static returning `Result<T>`.
- A class whose fields all have defaults receives an implicit zero-argument
  initializer. A class with any required field must declare `init` — the implicit
  initializer assigns nothing, so a required field left to it would never be assigned. Every
  `init` must leave every field assigned on every path that returns, the implicit return at
  the end included.
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
- Once the whole `deinit` chain has run, the object's fields are released in **reverse
  declaration order**: the object's own class first, then each base class up the chain, and
  within each class the last-declared field goes first. Each field's release finishes — its
  own `deinit`, its own fields, the whole subtree it owned — before the next field is
  touched. The declared *type* of a field does not change this: a field holding a class
  directly, one holding `Option<C>`, `Result<C, E>`, `List<C>`, `Map<K, C>`, a struct with a
  class inside, or a generic parameter bound to a class all release at their declared
  position. A struct value releases its own fields by the same reverse-declaration rule,
  wherever it is stored and whatever order a literal named them in. The release cascade is
  iterative, so a chain a million links long is dropped without recursion.
- `self` must not escape a `deinit`. The object is being destroyed; storing `self` anywhere
  is use-after-free by definition.
- A panic inside `deinit` is the same rule as one inside a `defer`: uncontained it ends
  the process, and contained by `brew`/`join` (spec/CONCURRENCY.md) the join reports it —
  **without stopping the destruction that was running it**. The `deinit` is not run again,
  but the object's fields are still released and its memory still returned, and everything
  else the release was going to destroy is still destroyed: the remaining elements of a
  container being cleared, the rest of a dying object graph, the rest of a cycle the
  collector killed. A container is empty and usable either way. A *second* `deinit` (or
  `defer`) panicking before the first has been delivered is the one unrecoverable case —
  both reports go out and the process stops.
- `deinit` runs when the last reference dies, which is a thing that happens
  *while the program runs*. Leaving the program is not a death: a value a
  static or a singleton still holds at exit has no `deinit` call, and neither
  does anything alive when `os.exit` or a panic ends the process.
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

A subclass field may not reuse the name of a field it inherits. Every field of
every class in the chain takes its own slot, laid out base class first, so one
name shared by two classes in a chain would be two slots — an inherited field
is storage the base already owns, and the subclass has to pick a different
name. This holds whatever the redeclared field's type or visibility, and
across the parts of a `partial class`. Fields have no counterpart to the
`priv`-method carve-out: a method can be a distinct member under a reused
name, but storage is never shadowed. (Only instance fields collide this way; a
`static` field is per-type storage reached through its declaring type and is
not inherited, so it does not share a slot with an instance field of the same
name.)

`extends` and `implements` belong to classes and interfaces. A struct, union
or enum that names either is refused at the declaration: an interface value is
an object whose first word is its descriptor, and a value type has none.

Only an instance method is dispatched. A `static fn` declares no `self`, so no
receiver picks it: it is called on its type, `value.some_static()` is refused,
and it holds no row in any class's method table. Within one class family a
name is therefore either a static or an instance method, never both — a
`static fn` beside an instance method the class inherits, and an instance
method beside a static a base declares, are each refused at the declaration
naming the other. A `priv` method is outside this rule in both directions: it
belongs to its exact declaring type, is never inherited and shares no slot, so
a subclass writing the same name is already a separate method. Reflection
follows the same rule: `Method.call` prefers the body the receiver's runtime
class declares, and a static is never one of those.

**Generic interfaces.** An interface may take type parameters, and an
implementor binds them at the `implements` site: `class IntBox implements
Producer<int>` requires `fn make() -> int`, not the interface's own `T`. A
generic class may pass its own parameter through instead — `class BoxOf<T>
implements Producer<T>` — and each instantiation binds the interface at that
instantiation's argument. Either way the interface stands as a type of its
own: `Producer<int>` is a variable, parameter and element type that
dispatches dynamically, and `Producer<int>` and `Producer<string>` are two
unrelated types. A chain pins arguments the same way, so `interface
IntProducer extends Producer<int>` answers `int`.

**A method that declares generics of its own does not dispatch.** It binds
them at the call site, so it is a template with one function per
instantiation and there is no single body a method table could hold. The
checker refuses every form that exists only to be reached through one: an
interface may not declare such a method, with or without a default body; an
`abstract fn` may not declare one; and a subclass may not replace one, nor
replace a plain method with one — each is refused at the declaration naming
the method it collides with. What stays is the ordinary case: the receiver's
static type picks the body, walking its base chain the way any other name
lookup does, so a subclass inherits its base's generic method and a base
pinned at an argument — `class IntHolder extends Holder<int>` — raises the
instantiation that argument names.

A generic bound carries type arguments the same way: `fn read<P implements
Producer<int>>(p: P)` accepts only implementors pinned to `int`, and a bound
may forward the call's own parameters, as in `fn twice<U, P implements
Producer<U>>`. A class may also extend a generic base at a concrete
argument — `class IntHolder extends Holder<int>` — and two subclasses may
pin the same base differently.

**A generic class inherits like any other.** It may extend a plain class, a
generic base at its own parameter (`class Sub<T> extends Base<T>`), or one
pinned at a concrete argument (`class Sub<T> extends Base<int>`), and it may
extend and implement at once. Each instantiation is its own class: `Sub<int>`
and `Sub<string>` have their own field offsets and their own method table, so a
field typed at the parameter is a traced reference in one instantiation and a
plain word in the other, and subclasses of the two are unrelated types. A
method a generic class overrides wins over the base's for every receiver,
including one written at the base. A class chain is bounded only by the number
of classes in the program — a cycle is refused at the declaration, and nothing
else caps its depth.

**`as?` cannot name an instantiation.** `b as? Sub<int>` is refused, and not
because the relation is missing — `Sub<int>` really is a child of `Base<int>`.
A downcast is decided at run time from the object's own class, and an object
does not carry its type arguments, so `Sub<int>` and `Sub<string>` cannot be
told apart there. The downcast that does work reads the other way round: the
*source* may be written at an instantiation, and the target is a non-generic
class that extends it.

```
class Crate<T> {
    v: T
    fn init(v: T) { self.v = v }
}
class IntLeaf extends Crate<int> { fn init() { super.init(1) } }

fn probe(c: Crate<int>) -> string {
    match c as? IntLeaf {          // allowed: the target is a plain class
        some(leaf) => { return "leaf" }
        none => { return "other" }
    }
}
```

```
class Base<T> {
    v: T
    fn init(v: T) { self.v = v }
    fn weight() -> int { return 1 }
}
class Sub<T> extends Base<T> {
    fn init(v: T) { super.init(v) }
    override fn weight() -> int { return 2 }
}
class Leaf extends Sub<int> { fn init() { super.init(9) } }

fn weigh(b: Base<int>) -> int { return b.weight() }
weigh(new Sub<int>(1))     // 2
weigh(new Leaf())          // 2
weigh(new Base<int>(1))    // 1
```

```
interface Producer<T> {
    fn make() -> T
    fn twice() -> List<T> { return [self.make(), self.make()] }
}

class IntBox implements Producer<int> {
    fn make() -> int { return 7 }
}

class BoxOf<T> implements Producer<T> {
    value: T
    fn init(value: T) { self.value = value }
    fn make() -> T { return self.value }
}

let a: Producer<int> = new IntBox()
let b: Producer<int> = new BoxOf<int>(3)
let c: Producer<string> = new BoxOf<string>("box")
```

**`Self` return type.** A class or interface instance method may declare
`-> Self`: at every call site the result has the receiver expression's own
static type, so a fluent chain inherited from a base class keeps the
subclass's type instead of degrading mid-chain. The guarantee is enforced in
the body — a Self-returning method must `return self` (or a chain of
Self-returning calls on `self`, which provably evaluates to the receiver).
`Self` matches only `Self` in overrides and interface conformance, carries
the owner's own type parameters on a generic class, changes no layout or ABI
(the stored result stays the declaring class), and is not available on
static methods or free functions.

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

An enum carries methods (`fn label() -> string { ... }` inside the enum body,
with implicit `self`) and static methods, but no enum object has a descriptor
word for dynamic dispatch to read, which is why the relation rules below refuse
one.

An enum has no base type and cannot implement an interface: the checker refuses
`enum Colour implements Shows` and `enum Colour extends Base` at the
declaration, naming the enum and the relation. An enum satisfies the `Clone`,
`Eq` and `Hash` bounds and works as a map key without ever naming them. A
**payload-free** enum also satisfies `Order`, by its declaration-order tag —
the same numbering `enum(u8)` exposes as its `u8` and the same shape as
`bool`'s false-before-true — so `sort`, `max`, `min` and a generic
`T implements Order` body work on it with no representation change. A bare
`a < b` on two enum values is still refused as an unordered operand, exactly as
it is for `bool`; the comparison can only be written inside a generic `Order`
body. A **payload** enum does **not** satisfy `Order` even when its payload
types happen to: ordering it would mean tag-then-payload, which needs every
payload type to be `Order` and a deep compare in both backends' sort path, and
that is not offered — it still satisfies `Clone`, `Eq` and `Hash`.

### Fixed representation: `enum(u8)`

A payload-free enum can opt into a committed one-byte layout on the
declaration:

```
enum(u8) Display { flex, grid, none }
```

The value is then the bare `u8` tag, variants numbered in declaration order —
the same numbering an ordinary enum's tags use, so behaviour is unchanged.
What changes is layout: `size_of` answers 1, `align_of` answers 1, a struct
holding one keeps a fixed inline layout with no pointer bits or ARC
bookkeeping, and a `[Display; N]` array stores one byte per element. Matching,
equality, printing, methods, map keys, and reflection all work the same as
without the marker, and the two compilers agree on every observable behaviour.

The checker refuses the marker, naming the rule, on enums with payload
variants, on generic enums, on more than 256 variants, and on any
representation other than `u8` (wider ones can follow the same path). An
`enum(u8)` stays a distinct nominal type — there is no implicit conversion to
or from integers — and it is still not a C ABI type: an `extern "C"` record
field or typed JSON keeps its existing refusal.

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
- **`new Error(message)`** and **`new Error(message, kind)`** build the built-in
  error object itself — the same value `err(message, kind)` wraps, without the
  `Result` around it. This is what a `to_error` hook (below) returns; before it,
  no Beans code could name an `Error`, only a `Result` carrying one.
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

**`?` over an `Option` carries nothing.** In a function returning
`Option<U>`, `x?` on an `x: Option<T>` answers this function's `none` when `x`
is `none` — `none` is `none` whatever `T` and `U` are, and no payload crosses.
`?` never crosses between the two kinds: an `Option` cannot propagate out of a
`Result` function or the other way, and each is refused at the `?`.

**`?` across an error boundary.** In a function returning `Result<U, F>`, `x?`
on an `x: Result<T, E>` requires `E` to *reach* `F`. There are exactly three
ways, checked at the `?` itself:

1. `E` is `F` — nothing happens, the error propagates unchanged.
2. `E` is a subtype of `F` (it `implements`/`extends` it) — the reference
   widens to `F`, the same object read as the wider type. No code runs and
   nothing is lost, exactly as a plain assignment to an `F` binding would.
3. `E` declares `fn to_error() -> F` — on the error path `?` calls it on the
   error and propagates the `F` it returns.

```
fn query() -> Result<int, DbError>   // DbError has `fn to_error() -> Error`
fn service() -> Result<int> {        // Result<int, Error>
    let rows: int = query()?         // ? calls DbError.to_error() on an err
    return ok(rows)
}
```

Any other `E` is refused at the `?`, naming both `E` and `F` and the method
that would let them meet. The conversion runs only on the error path, only
once — a `to_error` result is never itself put through a second `to_error`.
Each `?` negotiates its own boundary: `x??` on an
`x: Result<Result<T, E1>, E2>` crosses `E2` at the first `?` and `E1` at the
second, each by whichever of the three ways applies to it.
`std.reflect` relies on this: it answers `Result<T, ReflectError>`, and
`ReflectError.to_error()` lets a reflection failure cross into a plain
`Result<T>` carrying the reflect kind as the error slug.

Still refused, deliberately:

- The built-in `Error` as the *source* `E`. It cannot carry a `to_error`
  method, so `Error → some custom F` has no hook; unpack it with `match`.
- A `to_error` that is `static`, takes any parameter, or has type parameters —
  `?` calls it with no arguments on the error, so it must be a plain instance
  method taking none. A method that misses this is reported, not silently
  skipped.
- A `to_error` whose result does not itself reach `F`.
- Erasing move-only ownership: a move-only `E` cannot widen to a
  non-move-only `F`, and a `to_error` answering a move-only subtype of a
  non-move-only `F` is refused the same way.
- `return err(e)` is **not** a conversion point. It builds this function's own
  `Result`, so `e` must already be an `F` (or a subtype that widens to one);
  `to_error` is never called there. Conversion is a property of `?`, not of
  `err`.

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
The exception is `enum(u8)`: a payload-free enum that declares the fixed
representation is a bare one-byte tag with no ARC object at all.

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

A variant's payload binds by position, and a payload the arm does not need
binds to `_`, as many times as there are fields to ignore: `line(_, _) =>
"line"`. Those are discards, not names — see Variables.

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
**`Order` is a total order and `Eq` is the equality that goes with it**, for
every type that has them — which for `float` and `f32` means IEEE 754
totalOrder and bit equality, not the IEEE operators (see *Number rules*).
User interfaces, including imported interfaces, may also be bounds. Generic
code may call the instance methods promised by those interfaces.

`Order` on a `bool` is `false` before `true`, which `sort`, `max` and `min`
have always answered; a generic body is the only place the comparison can be
written, since a bare `a < b` on two bools is refused as an unordered operand.

`Map<K, V>` and `OrderedMap<K, V>` require `K implements Eq & Hash`. Collection
`clone()` is available only when every stored type is `Clone`; ordering and
equality methods likewise require `Order` or `Eq`. Unknown interfaces are errors,
not ignored notes.

## Concurrency

Direction: **OS threads, not green threads.** Reason: green threads make every
C/C++ call expensive (Go's cgo problem — stack switching at the boundary).
Beans lives on C++ interop and wants to write databases, so real threads it is.
Closures plus `std.thread` do the whole job.

**`main()` runs on the real process main thread — guaranteed.** A built binary
starts `main()` on the thread the OS handed the process, and `beansc run`
executes `main()` on its own process main thread (`pthread_main_np()` answers 1
there on macOS). Frameworks that insist on the first thread — AppKit, the
dispatch main queue, most GUI event loops — can be driven from `main()` under
either compiler. Spawned threads make no such promise.

```
import std.thread

// spawn: run a closure on another thread
let t: Thread<int> = thread.spawn(fn() -> int {
    return heavy_work()
})
let n: int = t.join()               // wait + get the value

// discard the result and release the OS thread resource when it finishes
let background: Thread<int> = thread.spawn(fn() -> int { return work() })
background.detach()

// mutex wraps the data itself — no way to touch it without holding the lock
let ledger: Mutex<Ledger> = new Mutex(new Ledger())
ledger.with_lock(fn(l: Ledger) {
    l.post(entry)                   // locked for exactly this block, auto-unlock
})

// channels move work between threads
let ch: Channel<string> = new Channel(64)      // buffered
ch.send("job")
let job: Option<string> = ch.receive()         // none when closed and empty
let queued: bool = ch.try_send("job")          // false instead of waiting
let next: Option<string> = ch.try_receive()    // none instead of waiting

// atomics for plain counters
let hits: AtomicInt = new AtomicInt(0)
hits.add(1)
```

- `Mutex<T>` holds the value inside it — `with_lock` locks, runs your closure, unlocks on any exit path. No forgotten unlocks.
- `thread.spawn` consumes a zero-argument `send fn` and its result must be
  `Send`. A direct closure literal is inferred as `send fn`. An existing
  sendable function local needs `move` at the call. Plain class references
  remain local. `List<T>`, `Box<T>`, and `Arena<T>` are `Send` when `T` is;
  `Map<K, V>` and `OrderedMap<K, V>` are `Send` when both arguments are.
  `Bytes`, `File`, and `MMap` are move-only `Send` owners. `Channel<T>`
  requires `T: Send`; `Shared<T>` and `Weak<T>` require `T: Send + Sync`.
  `Mutex<T>` takes `T: Send`, or any move-only `T` it can own outright:
  `new Mutex(move v)` consumes the value and `with_lock` lends it to the body
  without letting the body keep it, so the lock is the only way in as long as
  every field of `T` is itself `Send` or owned the same way. This makes
  `class` a local ARC reference by default; wrap shared mutable data in a
  `Mutex` — as a `unique class`, so the mutex really owns it — instead of
  silently racing it.
- A `unique class` may explicitly implement `Send` to promise that transferring
  its sole owner is safe. This does not make it `Sync`, copyable, or shared.
  `TcpListener`, `TcpStream`, `UdpSocket`, `http.Server`, and
  `http.ServerConn` make this promise. `Result<T>` is `Send` when `T` and its
  error type are, so a worker can use `?` and return a typed error.
- `Thread<T>.detach()` discards the result without waiting. The running thread
  keeps its work alive and the OS thread resource is released when it finishes.
- `Thread<T>.join()` is called **once**, and the value it answers **moves** out
  of the handle. The handle keeps no reference to what it handed over, so the
  value dies with the binding that took it, not with the handle. Joining a
  handle a second time — or joining one that was detached — is a panic
  ("thread already joined"), not a second copy of the answer.

### brew — child fibers (spec/CONCURRENCY.md)

`brew f(args)` starts the call on a **child fiber of the current scope**, on
the current worker, pinned there for life. Arguments are evaluated at the
brew; the callee runs when the current fiber parks or reaches the scope's
end. There are no colored functions — any function may park, and its caller
neither knows nor cares.

```
fn handle(order: Order) -> Result<Receipt> {
    brew audit(order)                     // keep no handle; scope exit joins
    let h: Brew<int> = brew price(order)  // keep the handle
    let value: Result<int> = h.join()     // park until the child finishes
    h.cancel()                            // request cancellation; no wait
    return ok(receipt(value?))
}                                         // every child joined before return
```

- `brew` is contextual, like `unique` and `packed`: it starts a fiber only
  before a call to a user function or method; a local named `brew` stays an
  ordinary name. It appears as its own statement or as a `let` initializer,
  nowhere else.
- `Brew<T>` is scope-bound: it cannot be rebound (`let` only), moved,
  returned, passed, captured, stored in a field, or nested in another type.
  It lives and dies a local of the scope that brewed it.
- `join()` borrows the handle and answers `Result<T>`: `ok(value)`, or an
  `err` whose kind is `panic` (the child panicked — message and position
  carried), `cancelled`, or `closed` (a second join). The joined flag, not a
  move, is what makes a second join answer `closed`.
- **A panic ends only the fiber it happened on.** An outcome nobody joined
  escalates at the scope exit: the parent panics at the brew's position with
  the child's report. A cancelled child stays quiet.
- Method calls brew through class receivers only — a value receiver would
  run on the fiber's own copy. `inout` arguments cannot cross to a fiber.
- Fibers need the thread runtime: `--runtime freestanding` and wasm targets
  refuse `brew` at check time.

### async and await (removed)

Earlier versions carried an `async`/`await` effect system (v0.9). It was
removed: `async` and `await` are ordinary identifiers with no grammar rule
behind them, and no function is a different color from any other. The
replacement is the fiber model above — uncolored functions that may park on
one pinned worker — whose contract lives in spec/CONCURRENCY.md.

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
| `--linker <name\|path>` | passed through as `-fuse-ld=<value>`. A full path works, which is how a linker that is not on `PATH` is reached — `--linker /path/to/wasm-ld` links a wasm target without touching `PATH` |
| `--emit <bin\|obj\|static\|shared\|ir>` | choose a binary, object, archive, shared library, or `.ll` |
| `--ar <path>` | static archive tool, default `ar` |
| `--header <path>` | write a C header for `pub extern "C"` library exports |
| `--release`, `--lto` | optimize the build (`-O3`, `NDEBUG`) and link across the runtime boundary; a build without `--release` or `--debug` is `-O0` |

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
  `extern "C" struct`/`union`, class or interface references, and `enum(u8)`
  declarations (one byte, byte-aligned).
- **A class or interface reference reports one pointer.** The object behind it is
  a heap allocation carrying a 16-byte ARC header; what a *reference* costs and
  what the object costs are different questions, and this answers the first.
- Rejected, with a specific message: a type parameter (`size_of(T)` inside a
  generic body), `Option`/`Result`/user enums without a declared
  representation — they choose between a null niche, an inline aggregate and a
  boxed form depending on payload, so there is no single number to report —
  and a size that would overflow. A payload-free enum opts out of that
  rejection by declaring `enum(u8)`.
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
pub extern "C" packed struct Header {
    kind: u8
    length: u32
    checksum: u32
}
extern "C" align(64) struct Counter { hits: u32 }
extern "C" struct Slot {
    tag: u8
    align(16) payload: u64
}
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
let scratch: Bytes = new Bytes(65536)
let count: int = session.read_into(scratch)? // reuses scratch; 0 means EOF

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
  `deinit`. One owner, one close, and a double close is impossible to write. They
  explicitly implement `Send`, so an explicit closure move can transfer that one
  owner to a worker thread. A plain capture is refused. A socket still cannot be
  copied or shared, and one trapped in a reference cycle never runs `deinit`.
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
  `read_into(buffer)` writes into existing storage, returns a byte count (`0` is EOF),
  and leaves the buffer length unchanged so a server can reuse one allocation.
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
  `TcpListener.bind_reuse_port` opts into `SO_REUSEPORT`, letting independent
  accept loops bind one port on macOS and Linux; Windows reports `unsupported`.
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
- **To wake from another thread, pass `wake_handle()`** — a plain `int`, so the poller
  itself stays with its owner — and call
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

### std.term (v1.0, implemented)

```beans
import std.term
import std.proc

if !term.is_tty(0) { return }
let size: term.Size = term.size(0)?                       // ioctl(TIOCGWINSZ), in the runtime's C
let raw: term.RawMode = term.RawMode.enter(0)?            // restored on drop, exit, and panic

var frame: term.Frame = new term.Frame()
frame.enter_alt_screen()
frame.hide_cursor()
frame.clear()
frame.move_to(1, 1)
frame.fg(2)
frame.text("hello, {size.rows}x{size.cols}")
frame.reset_style()
frame.flush(1)?                                            // one unbuffered write(2)

var keys: term.KeyDecoder = new term.KeyDecoder()
keys.feed(proc.read(0, 64)?)                              // a read can split a sequence
for going {
    match keys.next() {                                   // holds an incomplete sequence
        some(key) => { match key { up(mods) => { ... } char(c) => { ... } _ => {} } }
        none => { going = false }                         // feed more and call again
    }
}
```

- **The struct-shaped calls live in the runtime's C**, because their layout is the
  platform's: `struct termios` is 72 bytes on macOS and 60 on Linux, and `struct
  winsize` and the Windows console have no portable Beans spelling. `is_tty`, `size`,
  and raw mode set/restore are four `beans_term_*` entry points; everything with a
  portable shape — the ANSI writers, the CSI decoder — is Beans.
- **`RawMode.enter(fd)`** puts a terminal into raw mode — no echo, no line buffering, no
  signal generation (`Ctrl-C` is delivered as the byte `0x03`, not `SIGINT`), no input or
  output translation — and hands back a `unique class` guard. `err` with kind `invalid`
  when `fd` is not a terminal, kind `unsupported` where raw mode is not offered.
- **Restore is guaranteed on three paths and honest about the fourth.** The guard
  restores cooked mode on `restore()`, on going out of scope (`deinit`), and — because the
  runtime registers the restore with `atexit` — on a normal exit and on a **panic**, which
  reaches `exit()` without unwinding on both backends. What it does **not** cover is a
  crash by `SIGSEGV`/`SIGBUS`: only the runtime's fault reporter runs then, and it is
  fenced to flushing output (adding a second signal disposition is what `test/signals.sh`
  forbids). A full-screen program watches `terminate` and `hangup` through `std.signal`
  and restores from its own loop, which needs no handler.
- **`Frame`** builds a screen's worth of escapes and text and writes it whole:
  `clear`, `clear_line`, `move_to(row, col)`, `home`, `hide_cursor`/`show_cursor`,
  `enter_alt_screen`/`leave_alt_screen`, `reset_style`, `bold`, `fg`/`bg` (256-colour),
  `fg_rgb`/`bg_rgb` (24-bit), `text`, `byte`, then `flush(fd)` — one unbuffered `write(2)`,
  because `io.print` goes through stdio and a frame with no trailing newline would sit in
  the buffer. `reset` empties it for reuse.
- **`KeyDecoder`** turns bytes into `Key`s and buffers an incomplete escape sequence
  across `feed`s, so a sequence **split across two reads** is one key, not two wrong ones.
  `next()` returns `none` while what is buffered is only a prefix; a lone `ESC` is held as
  ambiguous and `flush()` — called once input has settled — resolves it to the Escape key.
  It decodes arrows, Home/End, Page-Up/Down, Insert/Delete, F1–F12, printable characters
  (UTF-8), `Alt`+key, `Ctrl`+key, Enter, Tab and Backspace, with the xterm modifier mask
  read back through `has_shift`/`has_alt`/`has_ctrl`.
- **Platform.** `std.term` needs the **full** runtime — its calls live in the full-profile
  runtime — so `import std.term` is **refused by the checker** on the minimal and
  freestanding profiles, with a message naming the program (`'std.term' needs terminal
  control, which the minimal runtime does not have`), never a link error about a missing
  symbol. macOS and Linux are complete. On Windows `is_tty` and `size` work through the
  console API; **raw mode is refused** with kind `unsupported` at runtime (the console-mode
  and virtual-terminal-input path is not driven yet) rather than left half-configured.
  `wasi` has no terminal and the checker refuses it there too.

### std.http (v1.0, implemented)

```beans
import std.http
import std.thread

// Parsing: push bytes in, take typed events out. Any byte-split of the same
// input produces the same events.
let parser: http.RequestParser = new http.RequestParser()
for event: http.RequestEvent in parser.feed(arrived)? {
    match event {
        head(request) => { io.println("{request.method} {request.target}") }
        body(chunk) => { collected.append(chunk) }
        trailers(fields) => {}
        done(keep_alive) => {}
        upgraded(request, remainder) => {}   // the connection is no longer HTTP
    }
}
// With a reused read buffer, feed only the bytes that arrived; no slice copy.
let count: int = stream.read_into(scratch)?
let ranged: List<http.RequestEvent> = parser.feed_range(scratch, 0, count)?

// A client: one connection, sequential exchanges, keep-alive by default.
let client: http.Client = http.Client.connect("127.0.0.1", port)?
let answer: http.ClientResponse = client.get("/hello")?

// A server: accept, read whole requests, frame responses.
let server: http.Server = http.Server.bind("127.0.0.1", 0)?
let conn: http.ServerConn = server.accept()?
match conn.read_request()? {
    some(request) => {
        conn.respond(200, "OK", new http.Headers(), body, request.keep_alive)?
    }
    none => {}   // the client finished cleanly
}

// Or move each accepted connection to a worker. Plain capture is refused.
let worker: Thread<Result<bool>> = thread.spawn(
    fn() move(conn) -> Result<bool> {
        let request: http.ServedRequest = conn.read_request()?.expect("request")
        return conn.respond(200, "OK", new http.Headers(), Bytes.from("hello"),
                            request.keep_alive)
    })
worker.detach()

// HTTP/2 is the same message model with streams named explicitly.
let session: http.Http2Connection = http.Http2Connection.adopt(move socket, true)?
for event: http.Http2Event in session.run()? {
    match event {
        message(exchange) => {
            session.respond(exchange.id, 200, new http.Headers(), body)?
        }
        stream_closed(id, code) => {}
        goaway(last, code) => {}
    }
}

// TLS is a transport choice, not a second HTTP/2 message model. This call
// requires ALPN to select h2 before it returns the same stream API.
import std.http_tls
let secure_h2 = http_tls.connect("example.test", 443)?

// Large bodies can obey flow control instead of being staged whole.
let id: int = secure_h2.request_headers(
    "POST", "https", "example.test", "/upload", new http.Headers())?
secure_h2.send_data(id, first_chunk, false)?
secure_h2.send_data(id, last_chunk, true)?
```

- **Parsing is push-based and cannot block.** `feed` takes whatever arrived
  and returns the events it completed. Any byte-split of the same input yields
  the identical event stream, so the shape of a caller's read loop can never
  change what it parses. The property is tested directly, and against llhttp's
  own corpus split at every byte. `feed_range(data, from, to)` reads directly
  from a reused buffer and creates strings only for typed fields that survive
  the parser.
- **Server concurrency is an ownership choice.** `ServerConn` is a move-only
  `Send` handle, so an accept loop can move each connection to a worker and
  detach it. `Server.bind_reuse_port` supports one accept loop per worker on
  macOS and Linux. `ServerConn` reuses its read and response buffers.
- **Strict mode is the only mode.** The lenient flags that exist for ancient
  peers and request-smuggling papers are not exposed. What llhttp rejects, this
  package rejects: a malformed message is kind `protocol`, and the connection it
  came from is finished. A parse failure does not discard the events that
  arrived before it, so a pipelined buffer whose third message is malformed
  still yields the first two.
- **The limits llhttp does not own live here.** `Limits` bounds header count,
  total header bytes, target length, and — through `max_head_span_bytes` — every
  other head field llhttp leaves unbounded, namely the status reason phrase and
  the chunk-extension name and value. Crossing one is kind `too_large`, never a
  truncation. `Client` and `ServerConn` bound the buffered body the same way,
  and `Http2Connection.max_body` bounds a stream's body.
- **The write side is as strict as the read side.** A header name or value
  carrying CR, LF or NUL is refused with kind `invalid` before anything reaches
  the socket, so an application that puts user input in a `Location` cannot
  splice a second response into the stream. `http.field_is_safe(text)` answers
  the same question for a caller that wants to check first. Names may not carry
  `:` over HTTP/1.1; over HTTP/2 a leading one is the pseudo-header form and is
  allowed.
- **Header order and case are preserved.** `Headers` is an ordered list, not a
  map: repeated fields combine in order and a proxy that reorders them changes
  the message. Lookups are ASCII-case-insensitive and `get` answers the first
  match, which is what a compliant reader must do.
- **HTTP/2 is a property of the connection, not a different API.** Streams
  carry the same `Headers`, pseudo-headers included in arrival order. There is
  no h2c upgrade dance; a connection speaks HTTP/2 because ALPN said so or
  because both sides knew in advance.
- `request_headers` and `respond_headers` leave a stream open for
  flow-controlled `send_data` chunks. Kind `would_block` means run the
  connection to process WINDOW_UPDATE, then retry the same chunk.
- `Content-Encoding: gzip` and `deflate` responses decompress through
  `std.compress` under the same body limit, so a compressed bomb is an error
  rather than an allocation.
- Error kinds: `protocol` (malformed), `too_large` (a bound crossed), `eof`
  (cut short), `closed` (the connection is done), plus the transport's own.

### std.websocket (v1.0, implemented)

```beans
import std.websocket

// Client: TCP, the HTTP upgrade, then framing.
let socket: websocket.Connection =
    websocket.Connection.connect("127.0.0.1", port, "/chat")?
socket.send_text("hello")?
match socket.receive()? {
    some(message) => {
        match message {
            text(body) => { io.println(body) }
            binary(body) => {}
            ping(body) => {}     // a pong already went out
            pong(body) => {}
            closed(code, reason) => {}
        }
    }
    none => {}                   // the close handshake finished
}
socket.close(1000, "done")?

// Server: std.http parses the upgrade, this takes the socket from there.
let live: websocket.Connection =
    websocket.Connection.accept(move stream, request)?

// WSS keeps the same framing and upgrade rules over a TLS byte stream.
import std.websocket_tls
let secure = websocket_tls.connect("example.test", 443, "/chat")?
```

- **A message, not a frame.** `receive` yields whole messages; fragmentation,
  continuation frames and interleaved control frames are handled underneath,
  because every protocol built on WebSocket cares about messages.
- **Text means valid UTF-8**, checked on the assembled message because a code
  point may straddle a fragment boundary. Invalid UTF-8 is kind `protocol`.
- **Ping is answered for you.** The pong is on the wire before the `ping`
  reaches your loop. Received pings are still reported, for callers who count.
- **Close is a handshake.** `close` sends the close frame and waits, bounded,
  for the peer's. A protocol violation sends the close frame the RFC requires
  and then closes the TCP connection immediately, as 7.1.1 demands.
- `max_message` bounds an assembled message; crossing it is kind `too_large`.
  A peer cannot make a server allocate by fragmenting forever.
- The framing is wslay, vendored under `runtime/net`. The Autobahn TestSuite is
  the gate, run against both an echo server and an echo client.

### std.compress (v1.0, implemented)

```beans
import std.compress

let packed: Bytes = compress.gzip_compress(data)?
// The limit is not optional: it is what makes a decompression bomb an error
// instead of an allocation.
let back: Bytes = compress.gzip_decompress(packed, 1048576)?

// Streaming, with one limit across the whole life of the Inflater.
let press: compress.Deflater = compress.Deflater.open(compress.Format.zlib)?
wire.append(press.push(first_half)?)
wire.append(press.finish()?)
```

- **Decompression limits are mandatory.** Every inflate names the most bytes it
  will produce, and crossing that bound is kind `limit` — never an allocation
  racing a hostile ratio. A tiny input claiming gigabytes gets a bounded amount
  of honest effort and an error.
- **Three formats, spelled out**: `zlib` (RFC 1950), `raw` (RFC 1951) and
  `gzip` (RFC 1952). gzip decoding reads multi-member files the way `gzip -d`
  reads concatenated archives.
- One-shot functions take and return whole `Bytes`; `Deflater` and `Inflater`
  are move-only handles for data that arrives in pieces, with the limit
  enforced across an Inflater's whole life.
- The codec is zlib-ng in `ZLIB_COMPAT` mode, vendored under `runtime/net`.

### std.crypto (v1.0, implemented)

```beans
import std.crypto

let digest: Bytes = crypto.sha256(data)?
let mac: Bytes = crypto.hmac(crypto.Algorithm.sha256, key, data)?

let hasher: crypto.Hasher = crypto.Hasher.open(crypto.Algorithm.sha1)?
hasher.update(first)?
let whole: Bytes = hasher.finish()?
```

- **The hashes come from the platform**, never from an implementation shipped
  here: CommonCrypto on macOS, CNG on Windows, libcrypto loaded at runtime on
  Linux and BSD. `available()` reports whether a provider is present.
- SHA-1 exists for the WebSocket handshake and SHA-256 for everything after;
  HMAC is the standard construction built on top. This is not a general crypto
  toolkit, and is not meant to become one.
- A `Hasher` is spent by `finish`; using it again is kind `closed`.

### std.tls (v1.0, implemented)

```beans
import std.tls

let secure: tls.TlsStream =
    tls.TlsStream.connect("example.test", 443, "h2,http/1.1")?
io.println(secure.protocol())            // the ALPN protocol that was agreed
secure.write_all(request)?
let reply: Bytes = secure.read(16384)?   // empty = the peer sent close_notify
secure.close()?

// A server needs one empty-name default identity. Named entries are selected
// by SNI; PEM chains and PKCS#12 bundles are both accepted.
var identities: List<tls.TlsIdentity> = []
identities.push(tls.TlsIdentity.pem("", cert, key))
identities.push(tls.TlsIdentity.pkcs12("api.example.test", p12, password))
let listener = tls.TlsListener.bind(
    "0.0.0.0", 443, move identities, "h2,http/1.1")?
let accepted = listener.accept()?
```

- **The platform owns the cryptography.** macOS uses SecureTransport, Windows
  SChannel, Linux and BSD OpenSSL 3 loaded at runtime. Chain building and
  hostname verification always belong to the platform verifier and are never
  reimplemented. `connect_with_roots` ADDS anchors for a private CA or a pin;
  it never replaces the system store.
- **A stream cut without `close_notify` is kind `eof`**, whether the transport
  ended in FIN or RST. That is the truncation attack surfaced rather than
  hidden; an empty `read` means a real, announced end.
- A macOS `TlsStream` wrapped around an existing `TcpStream` uses
  SecureTransport. That path negotiates TLS 1.2 at most and cannot report a
  selected server ALPN value. `TlsListener` uses Network.framework on macOS,
  so its accepted streams support TLS 1.3, SNI identities, and server ALPN.
- `TlsListener.bind` accepts port 0 and reports the chosen port with `port()`.
  `accept_timeout(0)` is a non-blocking check. A Network.framework listener
  has no file descriptor, so `poll_handle()` returns -1 on macOS.
- A `TlsStream` wraps a `TcpStream` as a filter and owns it: bytes in, bytes
  out, handshake driven by readiness like any other nonblocking IO.
- Error kinds: `handshake` (certificate, hostname or protocol), `eof`
  (truncation), `protocol` (record layer), `unsupported` (no backend).

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
- **The host may also owe libc memory routines, and which ones depends on the
  program.** LLVM lowers a struct copy or a bulk clear to `memcpy` and `memset`
  rather than emitting the loop, so those arrive as ordinary imports beside the
  `beans_host_*` hooks; a program that copies nothing asks for neither. A loader
  built from a fixed list will therefore be right for one module and wrong for
  the next. Read the imports off the module instead — for a wasm build:

  ```js
  const module = await WebAssembly.compile(bytes)
  console.log(WebAssembly.Module.imports(module).map(i => `${i.module}.${i.name}`))
  ```

  A module holding one integer static asks only for `beans_host_write` and
  `beans_host_exit`; one that builds a list of structs asks for the three
  allocator hooks, `memcpy` and `memset` as well. Supplying an import the module
  never requests is harmless; missing one it does means instantiation fails.
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
- The sysroot itself lands somewhere different on every machine, so it reads from the
  environment rather than from a project's build script: `BEANS_WASM_SYSROOT` when the
  target emits wasm, `BEANS_SYSROOT` otherwise, and `--sysroot` wins over both. A
  directory that does not exist is reported with the setting that named it, because
  Clang's own answer is a header error from inside the sysroot it did not find.
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
  `return` and `?`, newest first. A return leaves every scope it sits in, innermost
  first: the locals of the nested blocks (`if`, loop bodies, match arms) drop as their
  blocks exit, *then* the function's defers run, *then* the function's own locals drop —
  so a defer sees the function-level locals still alive and the block-level ones already
  gone. Must sit at the top level of the function body (not inside `if`/`for`/blocks — it
  is a function-exit hook, and nested registration would need runtime capture the native
  backend does not do); the checker refuses a nested one. Each defer runs at most once. An *uncontained* panic exits the
  process without running defers. A panic *contained* by `brew`/`join`
  (spec/CONCURRENCY.md) does the opposite: it unwinds the fiber's frames on the way to the
  fiber entry, running each function's defers newest-first and dropping what it owns — the
  same cleanup a return runs, in the same order — and the join reports the failure. A defer
  that panics while the function is exiting normally is a contained panic like any other
  when the fiber is brewed: it is not run again, the older defers still run, and the locals
  still drop. A panic inside a defer *during* a contained unwind is fatal — it aborts the
  process (the one unrecoverable case — there is no second unwind to give it) — and an
  uncontained one exits.
  `?` is not allowed inside a deferred expression because the function's
  return path is already being processed.
  (Go's best idea, with an unwind only where a panic is caught.)
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
  that a plain call cannot express.
  **The runtime's own entries are the exception, and are never bridged.** A
  `beans_*` name the Beans runtime hosts lives in the process already, so the
  interpreter calls it there through the runtime's dispatcher whatever the
  signature's width — `beansc run` never needs a C toolchain to reach one, which
  is what lets a program write to a socket on a host whose Clang cannot link for
  itself. A declaration naming one of those entries that does not fit its real
  signature is refused where the call is made, with a message about the
  declaration. Native builds cannot see that mistake — a linker does not compare
  types — so, as everywhere else here, a wrong `extern "C"` signature is the
  programmer's job; the interpreter simply cannot guess past it.
  A parameter may be a C callback such
  as `fn(i32, i32) -> i32`; its arguments and return use the same C-safe type
  set and may include C-layout records. Beans closures and stored top-level
  functions both work. `as "native_name"` gives an import a different C symbol
  name. A `pub extern "C" fn` with a body exports its `as` name for C callers;
  only C-safe parameters and results are accepted. The callback is borrowed,
  synchronous, and same-thread:
  C may call it only before the surrounding extern call returns, must not store
  it, and must not invoke it from another thread.
- `extern "C" fn name(fixed: T, ...) -> R` declares a C function with a
  variadic tail — `ioctl`, `fcntl`, three-argument `open`, `printf`. `...`
  comes last and needs at least one named parameter in front of it, exactly as
  C requires. There is no `va_list` in Beans, so a variadic declaration never
  has a body and a `pub extern "C" fn` export is never variadic.
  A **call site writes its own tail**, and the type it writes is the C type
  that crosses: the backend hands Clang that spelling at that call site, so the
  target's own variadic rules classify it. That is the point of the form — on
  Apple arm64 the whole tail goes on the stack while the fixed head stays in
  registers, while SysV x86-64 and generic AAPCS64 keep filling the register
  banks, so a variadic function declared with a fixed signature passes its
  arguments in the wrong place with no diagnostic.
  **C's default argument promotions apply to the tail**, because the tail is
  written as C: `i8`, `u8`, `i16`, `u16` and `bool` arrive as `int`, and `f32`
  arrives as `double`. A tail argument must be an integer, float, bool,
  `RawPtr` or `CFunctionPtr` — an `extern "C"` struct or union by value, a
  callback and every managed Beans value are refused, because past the last
  named parameter the prototype describes nothing and only a type with one
  unambiguous C spelling can cross. Beans `int` is 64 bits, so a bare integer
  literal in a tail passes as C `long long`; write `value as i32` where the
  callee reads an `int`.
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
- `LocalStoredCallback<F>.create(userdata_index, closure)` is the owned callback
  for the most common C event-loop shape: the library
  stores the callback once and always invokes it on the thread that
  registered it. Captures are unrestricted — no `Send`, no `Sync` — because
  the registering thread is recorded and an invocation from any other thread
  is a checked runtime abort, not a data race. Same `function()` /
  `function_pointer()` / `context()` surface and the same
  unregister-then-`close()` discipline.

A **borrowed callback** is an `fn(...)` parameter on an `extern "C" fn`. It is
lent to C for the length of that one call, so a Beans closure can be passed
directly and no lifetime question arises. A callback C *stores* is a different
thing and needs `StoredCallback` or `LocalStoredCallback`, whose value stays
alive until you `close()` it — close after unregistering, because it waits for
calls already running. Both registration-owner types are local and move-only;
"any-thread" describes where C may invoke the callback, not where its owner may
be moved.
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
`service.h` APIs one shared record and opaque-handle identity. A variadic C
function binds as `fn name(fixed: T, ...)`; a variadic *callback* type does not
bind at all, since `fn(...)` would have to name a tail only a call site knows. Nested function
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
  nested fixed-array, and struct elements with `1 <= N <= 4096`. `N` is an
  integer literal — decimal, hex, binary, digit separators and all — or a
  module constant that folds to an integer in that range ("Module constants").
  A list-shaped
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
  Indexing is a place: `view[i] = v` stores through the pointer, and — as with
  a fixed array, and unlike `List` and `Map` — a compound `view[i] += v` on a
  numeric element is the read-modify-write of that one cell. The write lands in
  the memory the view borrows, so it is visible through any other view of it,
  and needs no `var` on the binding: the view is read-only, the memory it names
  is not. A non-empty slice rejects a null pointer. The caller must keep the
  backing allocation alive and must not use the view after `free`.

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
  and lookups use a stack copy.

  A struct field is written through the storage the struct lives in, at any
  depth: `rect.origin.x = 1` and `config.limits.retries += 1` write the one
  struct, not a copy of it. The chain walks back through as many struct fields
  and fixed-array elements as the source writes, and ends at a mutable local's
  slot or at the heap object a class field sits in — so `holder.settings.size =
  9` on a class works too, as does an `inout` parameter, a local a closure
  captured, and a struct method declared `inout fn`. A `let` local's fields
  cannot be reassigned, and neither can a method receiver that is not
  `inout fn`. What is refused is storage the write could not reach and would
  silently drop: a temporary such as a call result, a `List` or `Map` element
  (the element read answers a copy), and a struct read out of a `union` (a
  union field read reinterprets bytes rather than naming a place). Each says
  which one it is; the remedy in every case is to copy the value into a `var`,
  update it, and assign it back.

  A **static field is the third root**, beside a local's slot and a heap
  object: `Cfg.home.origin.y = 3` and `Cfg.cells[0] = 9` write the static
  itself. A static has no owning object whose bit could gate the write and no
  scope that orders it, so a reference stored beneath one takes the cycle
  collector's static barrier — the one a whole-static assignment already
  emits — and the read that reaches the place runs the same
  initialisation-order guard a whole-static read runs. One thing is still
  refused there and it is refused for a class object too: storing a value
  that may own references into a **fixed-array element** inside a static or a
  class, because an element store emits no write barrier and would leave the
  collector an untracked edge. A struct field beneath either root is fine —
  it is a field store, and field stores carry the barrier.

  A struct is **move-only when any field is**. A struct is a value, so it can
  only be copied if everything it holds can, and `List`, `Map`, `Bytes`, `Box`,
  `Arena` and a `unique class` cannot be. That propagates: adding one such field
  changes the copy semantics of a struct that already has callers, and the
  refusal appears at those call sites rather than at the declaration, so it
  names the field responsible — `main.Wrapper is move-only — a struct is
  move-only when any field is, and 'inner.tags' is List<string>` — following the
  chain down to the field that actually fails rather than stopping at the type
  on the left.

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
library function, not a keyword. `async` and `await` are ordinary
identifiers — the effect system that once gave them contextual meaning was
removed. `package` is contextual — only `package <name>` at the top of a
file declares one, so `package` stays usable as an ordinary identifier. So is
`const`: only `const <NAME>` starting a module-level declaration declares one.
`r` is a string prefix only when a `"` follows it immediately, and a name
everywhere else.

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
  callback (`LocalStoredCallback.create`), unrestricted captures
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
- async/await removal 1.0 bake (implemented): the v0.9 effect system left
  the language whole — the words are ordinary identifiers again, the state
  machine expander, the hidden `std.async$rt` package, and the runtime's
  parked-readiness registry are gone, and reflection no longer reports an
  async flag. Threads, channels, and `std.poll` carry concurrency until the
  planned fiber model (uncolored functions parking on a pinned worker) lands
  through ROADMAP P4.
- async/await v0.9 (first version implemented; since removed): contextual words, never
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
  enums without a declared representation and type parameters are rejected
  rather than given a wrong number
- Fixed enum representation v1.0 (implemented): `enum(u8)` on a payload-free
  enum commits the value to a bare one-byte tag — `size_of` answers 1, structs
  holding one keep a fixed pointer-free inline layout, and construction,
  match, equality, printing, and storage agree between both compilers; the
  checker refuses payload variants, generic enums, more than 256 variants,
  and any representation other than `u8`, each with a message naming the rule
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
  into whatever inherited the descriptor
- Live children v0.8 (implemented): `Command.start()` gives a `Child` whose streams stay
  open; a dropped `Child` is asked to stop, killed if it refuses, and always reaped, so
  neither an orphan nor a zombie can escape; "still running" is `none` rather than an
  error because escalation is the normal path; and the child's inherited signal mask is
  cleared before exec, without which a child of a signal-watching parent starts
  unstoppable
- Sockets v0.8 (implemented): `TcpListener`/`TcpStream`/`UdpSocket` as move-only
  `unique class` handles, so one owner closes exactly once and can transfer to a
  worker only through explicit move; the address family is resolved rather than
  chosen, so IPv4 and IPv6 need no flag; reads and writes are partial by contract
  with an empty `Bytes` meaning EOF, while `read_into` reuses storage; every blocking
  call retries `EINTR`, every timeout is an `err` with kind `timeout` rather than a
  hang, every descriptor is close-on-exec, and reuse-port listeners support separate
  accept loops on one port
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
- Stdlib v0.5 phase 3 (implemented): the List/Map method set with **stable** sorts (`sort_by` takes a less-than closure; both backends run the identical merge), `Bytes` value `==`, advisory file locks, `MMap` (whole-file, shared, drop unmaps, grow = close + reopen), `std.fmt`, and printing widened to enums and lists — `variant(payload)` / `[a, b]` — everywhere strings interpolate; maps, class instances, and `Result` stayed unprintable until the derived rendering above landed
- Stdlib v0.5: the string method set, `Bytes`, `File`/`Dir`, `std.os`, and the `std.io` console set (implemented); byte semantics, panics carry positions, byte-owner mutators return `unit`, fs errors carry kind slugs
- Modules: `beans.pot`, one folder = one package, git imports with a global cache (v0.4, implemented)
- Block-bodied match arms in statement position (v0.4, implemented)
- `pub interface` exposes its method set implicitly (v0.4)
- Explicit types everywhere, no inference (v0.2) — match bindings relaxed in v0.3
- Named field literals remain for structs; classes construct only with `new`
- No `+` on strings — interpolation / `std.fmt` / `join` only (v0.3)
- Package-private by default, `pub` to expose, and `priv` for declaring-type
  private fields and methods
- OS threads + checked `Send` captures/returns + explicit move transfer for unique
  `Send` handles + detach + `Mutex<T>.with_lock` + `Channel<T>`
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
