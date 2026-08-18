# Zero-copy work

This work keeps the Beans grammar and the hot `string`, `List`, `Map`, and
`Bytes` layouts unchanged. An API that returns an independent owned value
still copies when that value escapes. The compiler and standard library avoid
the copy only when ownership and lifetime rules already make that safe.

Every completed group must pass its focused tests, examples, benchmark, and
the self-host and fixed-point checks for compiler changes. The final group must also
pass the full test and benchmark gates.

## Work list

- [x] Collections and ranges
  - [x] Stop copying stable fixed arrays only to iterate over them.
  - [x] Extend compile-time borrowed List and Map iteration where bindings do
        not escape and the collection cannot change.
  - [x] Fuse temporary `slice` consumers and keep the owned fallback.
  - [x] Allocate owned `keys()` and `values()` snapshots at their final size;
        keep snapshot behavior where direct iteration would change mutation
        rules.
- [x] Base64
  - [x] Shrink decoded output in place.
  - [x] Validate an unpadded tail without copying the full input.
  - [x] Write encoded output into its final string allocation.
- [x] JSON
  - [x] Make `decode_bytes_in_place` use yyjson in-situ parsing.
  - [x] Pass borrowed inputs and lookup keys directly to the native bridge.
  - [x] Remove payload staging from strings, object entries, and output. Array
        traversal keeps one compact handle table because removing it would add
        a C-to-Beans call per item and slow the existing API.
- [x] XML
  - [x] Pass borrowed parse input directly to pugixml.
  - [x] Use consumed input in place where ownership permits it.
  - [x] Remove payload staging from names, values, attributes, builders, and
        output. Child traversal keeps one compact handle table to avoid a
        C-to-Beans callback for every child.
- [x] I/O boundaries
  - [x] Remove temporary slices from buffered reading.
  - [x] Read and write strings without a temporary `Bytes` value.
  - [x] Use the platform file-copy primitive with a buffered fallback.
  - [x] Return process streams and datagrams without pack-and-slice copies.
- [x] Final proof
  - [x] Run all tests and examples.
  - [x] Run the full benchmark suite and compare it with the clean baseline.
  - [x] Document measured copy, allocation, time, and memory changes.

## Non-goals

- No new syntax.
- No global copy-on-write collection storage.
- No borrowed result hidden inside an API documented to return an independent
  mutable value.
- No claimed speedup without a repeatable benchmark result.

## Verified results

### Collection iteration

The focused `Map<string, class>` benchmark used 10,000 entries and 1,000
read-only passes. The output and peak memory matched the `main` build.

- ARC retains: 20,014 -> 14.
- Retired instructions after warm-up: about 1.94 billion -> 419 million.
- CPU cycles after warm-up: about 317 million -> 87 million.

The mutation tests also replace a Map value during iteration. That loop keeps
its owned binding, so the old value remains alive and behavior is unchanged.

Stable fixed-array loops now use the local's existing stack slot. The IR test
shows no iterator snapshot allocation for the read-only loop. A loop that
changes its source still allocates one snapshot and produces the old values.

A temporary `List.slice` used by one read-only loop now checks its bounds once
and walks the source range. A loop that changes the source still gets an owned
snapshot. Direct `Bytes.slice(...).to_string()` calls also copy only once into
the required string instead of first allocating a temporary `Bytes`.

The focused 1,000,000-item, 50-pass List benchmark gave:

- Tracked allocations: 57 -> 7.
- Warmed median: 14.0 ms -> 5.3 ms.
- Peak RSS: 17.6 MB -> 9.6 MB.

The stored owned-slice benchmark stayed at about 168 million instructions and
9.6 MB on both builds. Its snapshot behavior and cost did not change.

### Base64

Native encode now has one exact final string allocation; simdutf fills it
directly. Decode already writes into its result `Bytes`, now shrinks that same
buffer in place, and validates strict unpadded tails without a padded copy.

On an Apple M1, the median of three warmed runs gave these end-to-end rates:

- 1 MiB encode: 8,154 -> 13,972 MiB/s.
- 8 MiB encode: 5,029 -> 10,648 MiB/s.
- 1 MiB decode: 4,387 -> 5,059 MiB/s.
- 8 MiB decode: 3,263 -> 4,284 MiB/s.

Checksums matched. Peak memory for the whole encoding benchmark fell from
61,760 KiB to 60,608 KiB. `bench/encoding.b` also accepts `base64`, `json`,
`xml`, or `binary` so each group can be measured without allocation history
from an earlier group. The isolated binary group showed no slowdown: its
varint row was 614 ms before and 600 ms after.

### JSON

`json.decode_bytes_in_place(move data)` now gives yyjson the consumed Bytes
allocation after adding its required four padding bytes outside the logical
length. The parse tree borrows that allocation only until the final Beans
values have been built. Normal DOM parsing also passes Bytes or string input
straight to yyjson. Lookups borrow key strings, object entries copy keys once
into their final strings, and stringify copies yyjson's writer buffer once
into its final string.

On the 10 MiB generated dataset, five warmed runs on an Apple M1 gave:

- Typed decode: 579 -> 589 MiB/s.
- Consumed in-place decode: 570 -> 613 MiB/s.
- DOM/manual mapping: 54 -> 70 MiB/s.
- In-place peak RSS: 60,032 -> 49,760 KiB.

All modes produced 111,959 rows and checksum 12,536,637,012. Tracked Beans
allocations for typed output did not change: 195,942 before and after. The
speed and memory changes come from removing temporary payload copies, not
from changing the returned value layout.

### XML

Borrowed string and Bytes inputs now cross the Beans bridge without a staging
block; pugixml still makes its required private parse copy. The explicit
`parse_bytes_in_place(move data)` and `decode_bytes_in_place(move data)` forms
let pugixml tokenize consumed UTF-8 bytes directly. A DOM document keeps that
buffer alive. Typed decode destroys its temporary document before releasing
the buffer.

Names, values, lookup keys, attributes, builder inputs, and serialized output
also skip their old raw blocks. Owned result strings still copy once, because
they must outlive the document. Whole-child traversal keeps a compact table of
handles, which is faster than crossing from C++ into Beans for every child.

On the 10 MiB typed dataset, nine warmed runs gave:

- Borrowed decode: 222 -> 221 MiB/s, within 0.1 ms.
- Consumed in-place decode: 230 MiB/s.
- In-place peak RSS: 89,312 -> 79,024 KiB.

All paths returned 89,126 rows and checksum 7,944,892,169. The existing XML
DOM benchmark also improved with matching checksums: the 423 KiB parse rose
from 706 to 726 MiB/s and write rose from 864 to 947 MiB/s.

### File I/O

`fs.read` now fills its final string allocation from the file. `fs.write` and
`fs.append` write string storage directly. Binary `Bytes` APIs keep their
owned result behavior. `fs.copy` uses `fcopyfile` on macOS, `sendfile` on
Linux, and `CopyFileW` on Windows, with a fixed 1 MiB fallback. Same-file and
hard-link copies are checked before the destination can be truncated.

The focused benchmark read, wrote, or copied a 32 MiB file four times. Five
warmed runs on an Apple M1 gave:

- Text read: 33.3 -> 20.1 ms.
- Text write: 144.7 -> 121.4 ms.
- File copy: 178.0 -> 75.8 ms.

The read checksum matched. A separate 64 MiB read with pooling disabled used
132,640 -> 67,120 KiB peak RSS and 22 -> 20 tracked Beans allocations.

Finished process output now returns status, stdout and stderr as separate
private runtime parts. The public `Output` object takes those owned buffers
without joining or slicing payloads. UDP does the same for metadata, host and
payload. `Stream.write_text` and `TcpStream.write_text` use string storage
directly. Process and TCP `read_to_end`, plus TCP `read_exact`, grow one result
buffer instead of allocating and appending one `Bytes` per read.

The focused payload benchmark gave these five-run medians:

- Two 16 MiB process captures: 37.9 -> 30.2 ms.
- 10,000 loopback 8 KiB datagrams: 157.1 -> 153.9 ms.

Checksums matched. A separate 64 MiB process capture with pooling disabled
used 134,832 -> 69,264 KiB peak RSS. The 16 MiB capture also dropped from 25
to 24 tracked Beans allocations. UDP adds one small three-part list but removes
the two full payload copies; its measured time did not regress.

### Full regression gate

The final proof used clean full runs of all 39 declared workloads on the same
Apple M1. The baseline was release `0.1.14` (`205b113`) plus the identical
benchmark-harness hash fix; no baseline compiler, runtime, standard-library,
or workload source changed. Both runs used ten batches per target, fixed
checksums, randomized order, the same C++ and Beans flags, and the strict 3%
CV gate with no noise bypass. Their suite hash matched at `33cca8d21905e156`.

The official before/after comparator passed every regression limit:

- Overall score: 101.6% -> 101.6% of tuned C++.
- Overall peak-memory ratio: 1.17x -> 1.17x tuned C++.
- Worst direct Beans time change: -0.5%, inside the 5% row limit.
- Maximum accepted CV: 2.91%.
- Every output checksum matched across Beans and both C++ references.

Mutex contention's reference-normalized score moved by -9.7%, but Beans itself
moved by only -0.5%; the comparator reported this as C++ reference drift, not
a Beans regression. The focused results above cover the new zero-copy paths
that are intentionally outside the general 39-workload suite.
