package main

import std.encoding.json
import std.io
import std.os

struct Inner {
    pub label: string
    pub count: int
    pub flag: bool
}

struct L6 {
    pub tail: string
}

struct L5 {
    pub next: L6
    pub n: int
}

struct L4 {
    pub next: L5
}

struct L3 {
    pub next: L4
    pub items: List<int>
}

struct L2 {
    pub next: L3
    pub name: string
}

struct L1 {
    pub next: L2
    pub ok: bool
}

struct Outer {
    pub message: string
    pub inner: Inner
    pub items: List<int>
    pub names: List<string>
    pub big: int
    pub small: int
    pub yes: bool
    pub no: bool
    pub maybe: Option<string>
    pub perhaps: Option<int>
    pub boxed: Option<Inner>
}

class Rng {
    seed: int
    // The giant section flips this on: parity for broken UTF-8 is proven by
    // the ordinary rounds, and one bad string would blank a whole giant case.
    pub clean: bool = false

    fn init(seed: int) { self.seed = seed }

    fn next() -> int {
        self.seed = (self.seed * 6364136223846793005 + 1442695040888963407)
        var value: int = self.seed
        if value < 0 { value = -(value + 1) }
        return value
    }

    fn below(limit: int) -> int {
        return self.next() % limit
    }
}

// A string of `size` bytes: mostly 'a', a quote near the middle so escaping
// runs land on odd boundaries, and one two-byte sequence near the end.
fn sized_string(size: int) -> string {
    let bytes: Bytes = new Bytes(0)
    bytes.reserve(size)
    for index: int in 0..size {
        bytes.push(97)
    }
    if size >= 8 {
        // overwrite is not in the Bytes surface; rebuild with markers instead
        let marked: Bytes = new Bytes(0)
        marked.reserve(size)
        for index: int in 0..size {
            if index == size / 2 { marked.push(34) }
            else if index == size - 3 { marked.push(195) }
            else if index == size - 2 { marked.push(169) }
            else { marked.push(97) }
        }
        return marked.to_string()
    }
    return bytes.to_string()
}

// Every byte 0x01..0x1F plus DEL — the \u00XX and short-escape paths.
fn control_string() -> string {
    let bytes: Bytes = new Bytes(0)
    for value: int in 1..32 {
        bytes.push(value)
        bytes.push(120)
    }
    bytes.push(127)
    return bytes.to_string()
}

// Deliberately broken UTF-8: both writers must refuse it identically.
fn invalid_string(which: int) -> string {
    let bytes: Bytes = new Bytes(0)
    bytes.push(111)
    if which == 0 { bytes.push(255) }
    else if which == 1 {
        bytes.push(192)
        bytes.push(128)
    } else if which == 2 {
        bytes.push(237)
        bytes.push(160)
        bytes.push(128)
    } else if which == 3 { bytes.push(128) }
    else {
        bytes.push(226)
    }
    bytes.push(107)
    return bytes.to_string()
}

fn build_string(rng: Rng) -> string {
    let pool: List<string> = [
        "", "a", "Z", "hello", "\"", "\\", "\n", "\t", "\r",
        "line\nbreak", "q\"uo\"te", "back\\slash", "café", "日本語",
        "🫘", "mix🫘ed\ttext", "ünïcødé", " tail", "end",
    ]
    let pick: int = rng.below(24)
    if pick == 20 { return control_string() }
    if pick == 21 { return sized_string(200 + rng.below(200)) }
    if pick == 22 && !rng.clean { return invalid_string(rng.below(5)) }
    var built: string = ""
    let parts: int = rng.below(5)
    for index: int in 0..parts {
        built = "{built}{pool[rng.below(pool.len())]}"
    }
    return built
}

fn build_int(rng: Rng) -> int {
    let pick: int = rng.below(8)
    if pick == 0 { return 0 }
    if pick == 1 { return -1 }
    if pick == 2 { return 9223372036854775807 }
    if pick == 3 { return -9223372036854775807 - 1 }
    if pick == 4 { return 42 }
    if pick == 5 { return -rng.below(1000000) }
    if pick == 6 { return rng.below(1000000000) }
    return rng.below(255)
}

fn build_inner(rng: Rng) -> Inner {
    return Inner {
        label: build_string(rng),
        count: build_int(rng),
        flag: rng.below(2) == 0,
    }
}

fn build_outer(rng: Rng) -> Outer {
    var items: List<int> = []
    for index: int in 0..rng.below(6) {
        items.push(build_int(rng))
    }
    var names: List<string> = []
    for index: int in 0..rng.below(4) {
        names.push(build_string(rng))
    }
    var maybe: Option<string> = none
    if rng.below(3) != 0 { maybe = some(build_string(rng)) }
    var perhaps: Option<int> = none
    if rng.below(3) != 0 { perhaps = some(build_int(rng)) }
    var boxed: Option<Inner> = none
    if rng.below(3) == 0 { boxed = some(build_inner(rng)) }
    return Outer {
        message: build_string(rng),
        inner: build_inner(rng),
        items: move items,
        names: move names,
        big: build_int(rng),
        small: rng.below(3) - 1,
        yes: true,
        no: false,
        maybe: maybe,
        perhaps: perhaps,
        boxed: boxed,
    }
}

fn show(tag: string, encoded: Result<string>) {
    match encoded {
        ok(text) => { io.println("{tag}:{text}") }
        err(problem) => { io.println("{tag}:ERR:{problem.kind}:{problem.msg}") }
    }
}

// encode_into is checked against encode on every seeded value: it must append
// exactly encode's bytes after the target's existing content, return that
// count, leave the prefix untouched, and — when encode refuses — refuse with
// the same kind and message while leaving the target unchanged. A mismatch is
// printed (so direct-vs-dom cmp and the interpreter run both see it) and
// counted, and the run asserts the count is zero and the checks ran.
class Tally {
    pub count: int = 0
    pub bad: int = 0
    fn init() {}
    fn note(matched: bool) {
        self.count += 1
        if !matched { self.bad += 1 }
    }
}

// `orig` is the target's content before encode_into; `target` its content
// after. Compare against what encode produced for the same value.
fn into_matches(encoded: Result<string>, orig: Bytes, target: Bytes,
                appended: Result<int>) -> bool {
    match encoded {
        ok(text) => {
            match appended {
                ok(count) => {
                    let want: Bytes = Bytes.from(text)
                    if target.len() < orig.len() { return false }
                    let head: Bytes = target.slice(0, orig.len())
                    let tail: Bytes = target.slice(orig.len(), target.len())
                    return head == orig && tail == want &&
                           count == want.len()
                }
                err(_) => { return false }
            }
        }
        err(problem) => {
            match appended {
                ok(_) => { return false }
                err(other) => {
                    return other.kind == problem.kind &&
                           other.msg == problem.msg && target == orig
                }
            }
        }
    }
}

fn verify_into(tag: string, tally: Tally, encoded: Result<string>,
               empty_orig: Bytes, empty: Bytes, r_empty: Result<int>,
               prefix_orig: Bytes, prefix: Bytes, r_prefix: Result<int>) {
    show(tag, encoded)
    let ok_empty: bool = into_matches(encoded, empty_orig, empty, r_empty)
    let ok_prefix: bool = into_matches(encoded, prefix_orig, prefix, r_prefix)
    tally.note(ok_empty && ok_prefix)
    if !(ok_empty && ok_prefix) {
        io.println("{tag}:INTO_MISMATCH empty={ok_empty} prefix={ok_prefix}")
    }
}

fn check_outer(tag: string, tally: Tally, value: Outer) {
    let encoded: Result<string> = json.encode(value)
    let empty: Bytes = new Bytes(0)
    let r_empty: Result<int> = json.encode_into(value, empty)
    let prefix: Bytes = Bytes.from("PFX-")
    let prefix_orig: Bytes = prefix.slice(0, prefix.len())
    let r_prefix: Result<int> = json.encode_into(value, prefix)
    verify_into(tag, tally, encoded, new Bytes(0), empty, r_empty,
                prefix_orig, prefix, r_prefix)
}

fn check_outer_list(tag: string, tally: Tally, value: List<Outer>) {
    let encoded: Result<string> = json.encode(value)
    let empty: Bytes = new Bytes(0)
    let r_empty: Result<int> = json.encode_into(value, empty)
    let prefix: Bytes = Bytes.from("PFX-")
    let prefix_orig: Bytes = prefix.slice(0, prefix.len())
    let r_prefix: Result<int> = json.encode_into(value, prefix)
    verify_into(tag, tally, encoded, new Bytes(0), empty, r_empty,
                prefix_orig, prefix, r_prefix)
}

fn check_inner(tag: string, tally: Tally, value: Inner) {
    let encoded: Result<string> = json.encode(value)
    let empty: Bytes = new Bytes(0)
    let r_empty: Result<int> = json.encode_into(value, empty)
    let prefix: Bytes = Bytes.from("PFX-")
    let prefix_orig: Bytes = prefix.slice(0, prefix.len())
    let r_prefix: Result<int> = json.encode_into(value, prefix)
    verify_into(tag, tally, encoded, new Bytes(0), empty, r_empty,
                prefix_orig, prefix, r_prefix)
}

fn check_l1(tag: string, tally: Tally, value: L1) {
    let encoded: Result<string> = json.encode(value)
    let empty: Bytes = new Bytes(0)
    let r_empty: Result<int> = json.encode_into(value, empty)
    let prefix: Bytes = Bytes.from("PFX-")
    let prefix_orig: Bytes = prefix.slice(0, prefix.len())
    let r_prefix: Result<int> = json.encode_into(value, prefix)
    verify_into(tag, tally, encoded, new Bytes(0), empty, r_empty,
                prefix_orig, prefix, r_prefix)
}

fn giant_cases(rng: Rng, tally: Tally) {
    rng.clean = true
    // Growth-boundary strings: sizes straddling every doubling edge. The
    // encode_into target's own backing crosses those same boundaries here.
    let sizes: List<int> = [1, 2, 3, 7, 8, 9, 127, 128, 129, 255, 256, 257,
                            511, 512, 513, 1023, 1024, 1025, 4095, 4096,
                            4097, 8191, 65536]
    for index: int in 0..sizes.len() {
        let value: Inner = Inner {
            label: sized_string(sizes[index]),
            count: sizes[index],
            flag: true,
        }
        check_inner("boundary{sizes[index]}", tally, value)
    }
    // A string a megabyte long, twice over.
    for index: int in 0..2 {
        let value: Inner = Inner {
            label: sized_string(1048576 + index * 524288),
            count: index,
            flag: false,
        }
        check_inner("mega{index}", tally, value)
    }
    // Fifty thousand integers in one list field.
    var wide: List<int> = []
    for index: int in 0..50000 {
        wide.push(build_int(rng))
    }
    let wide_outer: Outer = Outer {
        message: "wide",
        inner: build_inner(rng),
        items: move wide,
        names: [],
        big: 1,
        small: -1,
        yes: true,
        no: false,
        maybe: none,
        perhaps: some(50000),
        boxed: none,
    }
    check_outer("wide", tally, wide_outer)
    // Five thousand strings, escapes included.
    var chorus: List<string> = []
    for index: int in 0..5000 {
        chorus.push(build_string(rng))
    }
    let chorus_outer: Outer = Outer {
        message: "chorus",
        inner: build_inner(rng),
        items: [],
        names: move chorus,
        big: 2,
        small: 0,
        yes: false,
        no: true,
        maybe: some(control_string()),
        perhaps: none,
        boxed: some(build_inner(rng)),
    }
    check_outer("chorus", tally, chorus_outer)
    // Deep nesting through six struct levels.
    let deep: L1 = L1 {
        next: L2 {
            next: L3 {
                next: L4 {
                    next: L5 {
                        next: L6 { tail: control_string() },
                        n: build_int(rng),
                    },
                },
                items: [1, -2, 3],
            },
            name: sized_string(300),
        },
        ok: true,
    }
    check_l1("deep", tally, deep)
    // Two thousand structs as a root list.
    var flood: List<Outer> = []
    for index: int in 0..2000 {
        flood.push(build_outer(rng))
    }
    check_outer_list("flood", tally, flood)
}

fn main() {
    let seed: int = os.env("FUZZ_SEED").or("20260821").to_int().or(20260821)
    let rounds: int = os.env("FUZZ_ROUNDS").or("2000").to_int().or(2000)
    let rng: Rng = new Rng(seed)
    let tally: Tally = new Tally()
    for round: int in 0..rounds {
        check_outer("{round}", tally, build_outer(rng))
        if round % 7 == 0 {
            var batch: List<Outer> = []
            for extra: int in 0..rng.below(3) {
                batch.push(build_outer(rng))
            }
            check_outer_list("{round}L", tally, batch)
        }
    }
    // The giant section is heavy for the interpreter lane; FUZZ_GIANTS=0
    // keeps that lane to the ordinary rounds.
    if os.env("FUZZ_GIANTS").or("1") != "0" {
        giant_cases(rng, tally)
    }
    io.println("into: checks={tally.count} mismatches={tally.bad}")
    // Fail loudly and non-zero rather than lean on grepping a transcript that
    // carries raw control and multibyte bytes: reverting either backend's
    // encode_into makes this exit non-zero, which the gate's `set -e` catches.
    if tally.bad > 0 {
        io.println("FAIL: encode_into disagreed with encode on {tally.bad} of {tally.count} values")
        os.exit(1)
    }
    if tally.count == 0 {
        io.println("FAIL: no encode_into checks ran")
        os.exit(1)
    }
    io.println("ok json_direct_fuzz")
}
