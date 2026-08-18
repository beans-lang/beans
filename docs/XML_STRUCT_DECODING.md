# Typed XML decoding

Status: nested struct fast path implemented.

The fast path is `xml.decode<T>`. Concrete schemas are built by the compiler;
the runtime never scans reflection metadata.

## Contract

- [x] Child elements are the default field source.
- [x] Add `@xml.attribute`, `@xml.text`, `@xml.name`, `@xml.ignore`,
      `@xml.naming`, and `@xml.allow_unknown`.
- [x] Reject unknown and duplicate attributes/elements by default.
- [x] A missing `Option<T>` is `none`; required missing fields fail.
- [x] `List<Row>` consumes repeated row elements under one wrapper.

## First native slice

- [x] Validate concrete scalar structs at compile time.
- [x] Generate static field/root schemas in both compilers.
- [x] Decode booleans, integer widths, `f32`, `float`, strings, and options.
- [x] Support text, borrowed bytes, and explicit XML parser options.
- [x] Write directly into final struct and list storage.
- [x] Clean partial strings, boxed options, and list rows on every failure.
- [x] Match interpreter and native output.
- [x] Pass ASan, UBSan, and macOS leak tests.

`@xml.ignore` is declared for the full mapping model, but the scalar native
slice rejects it and defaulted fields at compile time. It will become usable
when generated default initializers are added.

## Nested types

- [x] Nested structs and repeated `List<T>` fields.
- [x] `List<string>`, `Option<Struct>`, `Option<List<T>>`, and nullable
      `Option<string>` fields.
- [x] Namespace URI matching and explicit namespace annotations.

## Later types

- [ ] Decimal, payload-free enums, arrays, maps, and Bytes/base64.
- [ ] Interpreter parity and exact field-aware diagnostics.

## Performance

- [x] Generate deterministic exact-size XML data.
- [x] Compare Beans, handwritten C++/pugixml, Go `encoding/xml`, and Bun.
- [x] Verify equal row counts/checksums and report medians plus peak RSS.

Latest 100 MiB result on Darwin arm64, five-run median. File I/O and checksum
time are excluded. Every program produced 876,398 rows and checksum
768,087,695,867.

| implementation | MiB/s | rows/s | peak RSS |
|---|---:|---:|---:|
| C++/pugixml, handwritten strict mapper | 280 | 2,455,458 | 818,672 KiB |
| Beans `xml.decode_bytes<List<Row>>` | 253 | 2,218,835 | 832,864 KiB |
| Go `encoding/xml` structs | 34 | 300,511 | 450,224 KiB |
| Bun `fast-xml-parser` objects | 13 | 116,911 | 1,955,968 KiB |

Beans reached 90.4% of the handwritten C++ mapper, 7.4x Go, and 19.5x Bun.
The C++ and Beans paths enforce the same scalar schema. Go and Bun use their
normal automatic mapping and accept some inputs that the strict Beans schema
rejects.

This path is direct-to-struct, not zero-copy. pugixml owns a parse buffer and
Beans strings own their bytes. The decoder avoids the public DOM and all
runtime reflection lookups.

When the caller owns the input, `decode_bytes_in_place(move data)` lets
pugixml tokenize a UTF-8 Bytes allocation directly. The temporary document is
destroyed before the call returns, and every returned Beans string still owns
its bytes. `parse_bytes_in_place(move data)` applies the same rule to the DOM;
its internal owner keeps the consumed buffer alive until the last Document or
Node is gone.

On the focused 10 MiB data, nine warmed runs gave 222 MiB/s before and
221 MiB/s after for the unchanged borrowed path, within one millisecond. The
consumed path reached 230 MiB/s and cut peak RSS from 89,312 to 79,024 KiB.
All paths returned 89,126 rows and checksum 7,944,892,169.
