// Reproducible struct -> JSON throughput benchmark for the encoder's write
// path. The schema and record builder are the espresso bench3 /records route
// (community-libs/espresso/examples/bench3), the document the encoder issue
// #143 measures: a thousand records, ~247 KB, whose bytes are dominated by a
// ~105-byte note field and a ~22-byte email — long enough that the escape
// scan's 16-byte SIMD path carries most of the string bytes.
//
// It calls json.encode_into into one reused buffer, so what it times is the
// writer alone: no fresh string, no copy out. Best of several trials, buffer
// capacity kept between rounds. File I/O and record construction are outside
// the timer.

import std.encoding.json
import std.io
import std.os
import std.time

struct Record {
    pub id: int
    pub name: string
    pub email: string
    pub active: bool
    pub score: int
    pub tags: List<string>
    pub note: string
    pub balance: int
}

// A string-scan-dominated document. The records shape spends most of its time
// in the per-field append and format machinery, not the escape scan, so it
// barely moves when the scan gets faster; this shape isolates the scan, where
// the 16-byte SIMD path is the whole story, and is what the bench's A/B floor
// checks. Long plain runs, one escape in the middle so the scan cannot be
// elided as trivially clean.
struct Prose {
    pub body: string
}

fn long_body(length: int) -> string {
    let bytes: Bytes = new Bytes(0)
    bytes.reserve(length)
    for index: int in 0..length {
        if index == length / 2 { bytes.push(34) } else {
            bytes.push(97 + (index % 26))
        }
    }
    return bytes.to_string()
}

fn tag_at(index: int) -> string {
    return match index % 5 {
        0 => "alpha",
        1 => "beta",
        2 => "gamma",
        3 => "delta",
        _ => "epsilon",
    }
}

fn make_record(index: int) -> Record {
    return Record {
        id: index,
        name: "record-{index}",
        email: "user{index}@example.com",
        active: index % 3 == 0,
        score: (index * 2654435761) % 100000,
        tags: [tag_at(index), tag_at(index + 2), tag_at(index + 4)],
        note: "record {index}: the quick brown fox jumps over the lazy dog while the barista pulls a double ristretto shot",
        balance: (index * 7919) % 1000000,
    }
}

fn fnv1a64(data: Bytes) -> u64 {
    var hash: u64 = 14695981039346656037
    for index: int in 0..data.len() {
        hash = (hash ^ (data.get(index) as u64)) * 1099511628211
    }
    return hash
}

fn report(label: string, size: int, rounds: int, best: int, checksum: u64) {
    var floor: int = best
    if floor < 1 { floor = 1 }
    let total_bytes: int = size * rounds
    // bytes per nanosecond is bytes per gigabyte-second; scale by 1000 and
    // report as GB/s * 1000 so the integer keeps three significant digits.
    let gbps_milli: int = (total_bytes * 1000) / floor
    io.println("{label} bytes={size} rounds={rounds} best_ns={floor} gbps={gbps_milli / 1000}.{gbps_milli % 1000} gbps_milli={gbps_milli} fnv1a64={checksum}")
}

fn main() {
    let mode: string = os.env("MODE").or("records")
    let rounds: int = os.env("ROUNDS").or("400").to_int().or(400)
    let trials: int = os.env("TRIALS").or("7").to_int().or(7)
    var buffer: Bytes = new Bytes(0)

    if mode == "strings" {
        // A string-scan-dominated document: encode a list of long plain
        // bodies. The SIMD scan carries almost the whole time here, so the
        // bench's A/B floor separates the vector scan from the SWAR one.
        let count: int = os.env("PROSE").or("64").to_int().or(64)
        let length: int = os.env("PROSE_LEN").or("4000").to_int().or(4000)
        var docs: List<Prose> = []
        for index: int in 0..count {
            docs.push(Prose { body: long_body(length) })
        }
        let size: int = json.encode_into(docs, buffer).expect("encode")
        let checksum: u64 = fnv1a64(buffer)
        var best: int = 0
        for trial: int in 0..trials {
            let started: int = time.monotonic_nanos()
            for round: int in 0..rounds {
                buffer.resize(0)
                if json.encode_into(docs, buffer).expect("encode") != size {
                    io.eprintln("encode_into byte count moved")
                    os.exit(1)
                }
            }
            let elapsed: int = time.monotonic_nanos() - started
            if trial == 0 || elapsed < best { best = elapsed }
        }
        report("strings", size, rounds, best, checksum)
        return
    }

    let count: int = os.env("RECORDS").or("1000").to_int().or(1000)
    var rows: List<Record> = []
    for index: int in 0..count { rows.push(make_record(index)) }
    let size: int = json.encode_into(rows, buffer).expect("encode")
    let checksum: u64 = fnv1a64(buffer)

    // What encode_into removes, on the same document and the same buffer: the
    // shape a server takes without it. json.encode fills the writer's own
    // malloc, copies that into a fresh Beans string, hands the string over,
    // and the caller copies it again into the buffer the response is built
    // in. MODE=copy times exactly that, so the pair of numbers is the cost of
    // the string and its two copies and nothing else.
    if mode == "copy" {
        var copy_best: int = 0
        for trial: int in 0..trials {
            let started: int = time.monotonic_nanos()
            for round: int in 0..rounds {
                buffer.resize(0)
                buffer.append_string(json.encode(rows).expect("encode"))
                if buffer.len() != size {
                    io.eprintln("encode byte count moved")
                    os.exit(1)
                }
            }
            let elapsed: int = time.monotonic_nanos() - started
            if trial == 0 || elapsed < copy_best { copy_best = elapsed }
        }
        report("copy", size, rounds, copy_best, fnv1a64(buffer))
        return
    }

    var best: int = 0
    for trial: int in 0..trials {
        let started: int = time.monotonic_nanos()
        for round: int in 0..rounds {
            buffer.resize(0)
            if json.encode_into(rows, buffer).expect("encode") != size {
                io.eprintln("encode_into byte count moved")
                os.exit(1)
            }
        }
        let elapsed: int = time.monotonic_nanos() - started
        if trial == 0 || elapsed < best { best = elapsed }
    }
    report("records", size, rounds, best, checksum)
}
