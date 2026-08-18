# Typed JSON structs

Status: typed encoding and nested decoding implemented.

`json.encode<T>` and `json.decode<T>` use compile-time type and annotation
metadata. They do not use `std.reflect` or build public `json.Value` wrappers.

## 1. Contract

- [x] Add tool-retained JSON annotations for field names, aliases, ignores,
      naming rules, unknown fields, and byte formats.
- [x] Add typed string and byte decoders, parser options, compact encoding,
      and pretty encoding.
- [x] Define strict missing, null, unknown, duplicate, numeric, and depth rules.
- [x] Add checker failures for invalid mappings before native work begins.

Strict decoding rejects unknown and duplicate keys. A missing `Option<T>` is
`none`; JSON `null` is accepted only by `Option<T>`. Required fields must be
present. Integer conversions are exact and range checked. `DecodeOptions`
controls comments, trailing commas, Inf/NaN parsing, and a maximum nesting
depth. The default depth is 128.

`encode(value)` returns compact JSON. `encode_pretty(value, indent)` accepts
two or four spaces. `io.println(json.encode(value)?)` is the explicit way to
print a struct as JSON. Encoding uses the primary `@json.name` or naming-rule
name; aliases are input-only. Ignored fields are omitted. `Option.none` becomes
`null`. NaN and infinity are errors.

## 2. Type schemas

- [x] Build a schema only for concrete types used by `decode<T>`.
- [x] Support booleans, all integer and float spellings, strings, and structs
      in both directions.
- [x] Support nested structs, `Option<T>`, `List<T>`, `List<string>`, and
      `Option<List<T>>`.
- [ ] Support exact decimal, unit/null, payload-free enums, fixed arrays,
      `Map<string, T>`, and `OrderedMap<string, T>`.
- [ ] Support `Bytes` as base64 text and, by annotation, as a byte array.
- [x] Reject classes, enums, maps, fixed arrays, bytes, decimal, unit, generic
      structs, nested lists/options, and runtime/resource types before lowering.
- [x] Detect duplicate names, aliases, recursive schemas, and invalid defaults.

Both directions support struct roots and `List<Struct>` roots. Struct fields
may be booleans, every integer width, `f32`, `float`, `string`, nested structs,
lists, or options of those supported shapes. Ignored fields with defaults use
the portable binder. Decoding cannot yet combine an ignored field with nested
struct or list fields in the same schema; encoding has no such limit. The
direct final-layout path currently needs fields without defaults or ignores.

The complete core set above is not the extension ceiling. After it is stable,
add Java-style opt-in adapters for domain types, tagged or payload enums, and
user-defined codecs. Those must be statically selected and cached; they must not
put runtime reflection on the default path.

## 3. Native fast path

- [x] Add a private yyjson binding API that scans every object once.
- [x] Match keys through ordered static descriptors, with a static-hash
      fallback and no allocated key strings.
- [ ] Pre-size lists and maps. Lists are done; maps are not.
- [ ] Parse decimal from its original token text.
- [x] Copy each owned result string once.
- [x] Add consumed-Bytes in-situ parsing with yyjson padding.
- [x] Clean up every partially built value on failure for the supported slice.

## 4. Compiler parity

- [x] Lower typed decoding and encoding in the self-hosted compiler.
- [x] Implement typed encoding in both reference interpreters.
- [ ] Keep native and interpreter errors byte-identical.
- [x] Pass the compiler fixed-point check.

## 5. Correctness

- [x] Test the supported scalar slice and aliases.
- [x] Test missing, null, defaults, unknown fields, aliases, and duplicates.
- [x] Test nested structs, lists, optional structs, optional lists, and nullable
      optional strings.
- [x] Test compact and pretty struct output, root lists, empty lists, aliases,
      ignores, invalid indentation, parser extensions, and depth limits.
- [ ] Test arrays, maps, enums, and bytes.
- [ ] Test malformed UTF-8, malformed JSON, overflow, depth, and cleanup.
- [ ] Add malformed-input and schema-aware fuzz targets.

## 6. Performance

- [x] Add a deterministic generator for 10 MB, 100 MB, and opt-in 1 GB data.
- [x] Time parsing separately from typed construction and file I/O.
- [x] Compare parse-only, public DOM/manual mapping, handwritten typed mapping,
      and generated typed mapping.
- [x] Report MiB/s, records/s, allocations, peak RSS, and a result checksum.
- [ ] Require the 100 MB generated path to stay within 10% of handwritten;
      target 5%.
- [ ] Run the 1 GB case as a soak and peak-memory test.

XML work starts only after the 100 MB JSON gate passes.

Latest 100 MiB result on Darwin arm64: typed decoding reached 602 MiB/s and
6.62 million records/s, versus 53 MiB/s for the public DOM path. Peak RSS was
573,056 KiB. It made 1,922,747 Beans allocations for 1,098,705 rows, almost all
final owned strings, and no key or field wrappers. The checksum matched both
handwritten paths. Typed reached 62.6% of the strict handwritten Beans-layout
mapper in this run, so the 90% gate is still open.
The next performance step is a generated per-schema mapping kernel; the generic
descriptor loop has reached its useful limit.

For callers that own a byte buffer, `decode_bytes_in_place(move data)` avoids
yyjson's input copy. It adds four bytes of hidden capacity for yyjson, parses
the consumed allocation in place, builds the same owned Beans result, then
releases the input. This changes neither the grammar nor the result layout.

The 10 MiB focused median improved from 570 to 613 MiB/s and peak RSS fell
from 60,032 to 49,760 KiB. The ordinary borrowed typed path stayed within
noise (579 to 589 MiB/s), so callers that still need their input do not pay a
regression.

Cross-language 100 MiB median, five runs on the same Darwin arm64 host:

| Runtime | MiB/s | Rows/s | Peak RSS |
| --- | ---: | ---: | ---: |
| C++/yyjson, handwritten strict mapper | 818 | 8,997,398 | 523,936 KiB |
| Beans generated typed decoder | 608 | 6,683,242 | 573,056 KiB |
| Bun `JSON.parse` to JavaScript objects | 316 | 3,476,778 | 273,120 KiB |
| Go `encoding/json` to structs | 88 | 971,663 | 426,896 KiB |

All outputs had 1,098,705 rows and checksum 1,108,468,234,868. File I/O and
checksum time were excluded. Beans and C++ enforced the strict schema. Go's
standard automatic decoder accepts unknown and duplicate fields. Bun has no
runtime struct or schema check. The C++ strings in this data fit its small-string
storage, while Beans owns a separate allocation for every decoded string.
