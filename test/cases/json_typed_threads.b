// A decoded string payload is allocated on the thread that decodes it.
//
// The typed decoder's string payloads come from beans_alloc_bytes, which
// carves them out of the *calling thread's* allocator pool: an unlocked
// freelist, a bump pointer and its end, all three living in the runtime's hot
// per-thread struct. Every other typed-decode case here runs on the entry
// thread alone, where one struct cannot be confused with another and a pool
// shared between threads would look exactly like a pool that is not. This one
// decodes from four worker threads at once, so the per-thread resolution is
// load-bearing: two threads carving from one bump pointer would hand the same
// block to both, and two threads popping one freelist head would do the same.
//
// The check that catches it is the payload itself. Each worker fills its
// strings with a byte no other worker uses, so a block another thread was
// also handed comes back holding that thread's letter, and a full string
// compare says so. The comparison is deferred to the end of a round, with all
// four rows of the round still alive, so the blocks stay out of the freelist
// while the other workers are still carving -- a compare that ran the instant
// each row decoded would narrow the window it is here to open.
//
// The four lengths are chosen at the allocator's boundary, not at random.
// beans_alloc_bytes pools a block whose total (16 of header, the bytes, the
// NUL, rounded to 16) stays under 1024, so a payload of 991 bytes is the last
// pooled size and 992 the first non-pooled one; 7 sits deep inside the pooled
// classes and 4096 well past them. Both arms read the hot struct -- the
// non-pooled arm still tests the collector's per-thread pending flags on the
// way in -- so both belong here.
//
// It also drives all four public typed-decode entries, not one standing in
// for the other three. json.decode, json.decode_bytes,
// json.decode_bytes_in_place and json.decode_with_options lower to the same
// bridge call, which is why the diagnostic probe that call used to write to a
// file-scope array was a data race on every one of them (issue #152). The
// round number picks the entry, so each is decoded concurrently by four
// threads over a quarter of the run, and the entry count is printed with the
// other counts so dropping one is a diff.
//
// Typed decoding is native only (the tree interpreter answers kind
// "unsupported"), so this case, like the other typed cases, is a native gate.
package main

import std.encoding.json
import std.io
import std.thread

struct Row {
    pub id: u64
    pub name: string
    pub note: string
}

fn filler(n: int, fill: int) -> string {
    let bytes: Bytes = Bytes.filled(n, fill)
    return bytes.to_string()
}

fn document(body: string) -> string {
    return "\{\"id\":7,\"name\":\"{body}\",\"note\":\"tail\"\}"
}

// Built here rather than captured: a List is move-only, and four closures
// cannot each move the same one.
fn payload_sizes() -> List<int> {
    return [7, 991, 992, 4096]
}

fn decode_entry_count() -> int {
    return 4
}

// Every public typed-decode entry, decoding the same document into the same
// shape. Each arm binds its result before returning it, so the concrete T comes
// from the binding exactly as a caller writes it.
fn decode_entry(entry: int, text: string) -> Result<Row> {
    if entry == 1 {
        let data: Bytes = Bytes.from(text)
        let decoded: Result<Row> = json.decode_bytes(data)
        return decoded
    }
    if entry == 2 {
        // The in-place entry rewrites the buffer it is handed, so it gets a
        // fresh one; `text` is untouched.
        var scratch: Bytes = Bytes.from(text)
        let decoded: Result<Row> = json.decode_bytes_in_place(move scratch)
        return decoded
    }
    if entry == 3 {
        // Default options on purpose: what this arm is here for is the second
        // lowering, which reads the options object into the request's flag
        // word before making the same bridge call, not a different policy.
        let options: json.DecodeOptions = new json.DecodeOptions()
        let decoded: Result<Row> = json.decode_with_options(text, options)
        return decoded
    }
    let decoded: Result<Row> = json.decode(text)
    return decoded
}

// Decode every size `rounds` times and answer how many rows came back wrong.
// A mismatch is counted, never printed: at 4 KiB the transcript would be the
// test.
fn decode_worker(fill: int, rounds: int, workers: int,
                 started: Atomic<i64>, decodes: Atomic<i64>) -> int {
    var bad: int = 0
    var bodies: List<string> = []
    for len: int in payload_sizes() { bodies.push(filler(len, fill)) }
    // Do not start decoding until every worker is here. Without this the four
    // could run one after another -- four threads that never overlap prove
    // nothing about a pool shared between them -- and on a fast machine the
    // decoding is short enough that they would.
    started.fetch_add(1, MemoryOrder.acq_rel)
    for started.load(MemoryOrder.acquire) < workers as i64 {
    }
    for round: int in 0..rounds {
        var rows: List<Row> = []
        let entry: int = round % decode_entry_count()
        for index: int in 0..bodies.len() {
            let body: string = bodies.get(index).expect("body")
            let decoded: Result<Row> = decode_entry(entry, document(body))
            match decoded {
                ok(row) => { rows.push(row) }
                err(_) => { bad += 1 }
            }
            decodes.fetch_add(1, MemoryOrder.relaxed)
        }
        for index: int in 0..rows.len() {
            let row: Row = rows.get(index).expect("row")
            let want: string = bodies.get(index).expect("body")
            if row.id != 7 { bad += 1 }
            else if row.note != "tail" { bad += 1 }
            else if row.name != want { bad += 1 }
        }
    }
    return bad
}

fn main() {
    let workers: int = 4
    let rounds: int = 2000
    let started: Atomic<i64> = new Atomic<i64>(0)
    let decodes: Atomic<i64> = new Atomic<i64>(0)

    var crew: List<Thread<int>> = []
    for index: int in 0..workers {
        // 'a', 'b', 'c', 'd' -- one letter per worker, so a payload that
        // crossed threads names the thread it came from.
        let fill: int = 97 + index
        crew.push(thread.spawn(fn() -> int {
            return decode_worker(fill, rounds, workers, started, decodes)
        }))
    }
    var wrong: int = 0
    for index: int in 0..workers {
        let handle: Thread<int> = crew.pop().expect("worker handle")
        wrong += handle.join()
    }
    // The counts are printed so a run that quietly did less work than the
    // header claims is a diff, not a pass.
    io.println("workers {workers} rounds {rounds} sizes {payload_sizes().len()} entries {decode_entry_count()}")
    io.println("decodes {decodes.load(MemoryOrder.acquire)} wrong {wrong}")
}
