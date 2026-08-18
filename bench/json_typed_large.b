// Large automatic JSON -> struct benchmark. File I/O is outside the timer.

import std.encoding.json
import std.fs
import std.io
import std.os
import std.time

@json.naming(value: json.Naming.camel_case)
struct JsonBenchRow {
    pub id: u64
    pub user_id: u64
    pub active: bool
    pub score: float
    pub name: string
    pub note: Option<string>
}

fn throughput(bytes: int, nanos: int) -> int {
    var elapsed: int = nanos
    if elapsed < 1 { elapsed = 1 }
    return (bytes * 1_000_000_000) / (elapsed * 1_048_576)
}

fn typed(data: Bytes) -> Result<bool> {
    let started: int = time.monotonic_nanos()
    let rows: List<JsonBenchRow> = json.decode_bytes(data)?
    let elapsed: int = time.monotonic_nanos() - started
    var checksum: u64 = 0
    for row: JsonBenchRow in rows {
        checksum += row.id + row.user_id + row.name.len() as u64
        if row.active { checksum += 1 }
        match row.note {
            some(note) => { checksum += note.len() as u64 }
            none => {}
        }
    }
    let records_per_second: int =
        (rows.len() * 1_000_000_000) / if elapsed < 1 { 1 } else { elapsed }
    io.println("typed size={data.len()} records={rows.len()} nanos={elapsed} mib_s={throughput(data.len(), elapsed)} records_s={records_per_second} checksum={checksum}")
    return ok(true)
}

fn typed_in_place(move data: Bytes) -> Result<bool> {
    let size: int = data.len()
    let started: int = time.monotonic_nanos()
    let rows: List<JsonBenchRow> =
        json.decode_bytes_in_place(move data)?
    let elapsed: int = time.monotonic_nanos() - started
    var checksum: u64 = 0
    for row: JsonBenchRow in rows {
        checksum += row.id + row.user_id + row.name.len() as u64
        if row.active { checksum += 1 }
        match row.note {
            some(note) => { checksum += note.len() as u64 }
            none => {}
        }
    }
    let records_per_second: int =
        (rows.len() * 1_000_000_000) / if elapsed < 1 { 1 } else { elapsed }
    io.println("typed_in_place size={size} records={rows.len()} nanos={elapsed} mib_s={throughput(size, elapsed)} records_s={records_per_second} checksum={checksum}")
    return ok(true)
}

fn dom(data: Bytes) -> Result<bool> {
    let started: int = time.monotonic_nanos()
    let root: json.Value = json.parse_bytes(data)?
    let rows: List<json.Value> = root.elements()?
    var checksum: u64 = 0
    for row: json.Value in rows {
        checksum += row.get("id").or(json.Value.null()).to_uint().or(0)
        checksum += row.get("userId").or(json.Value.null()).to_uint().or(0)
        checksum += row.get("name").or(json.Value.null()).to_string().or("").len() as u64
        if row.get("active").or(json.Value.null()).to_bool().or(false) {
            checksum += 1
        }
        match row.get("note") {
            some(note) => {
                if !note.is_null() {
                    checksum += note.to_string().or("").len() as u64
                }
            }
            none => {}
        }
    }
    let elapsed: int = time.monotonic_nanos() - started
    let records_per_second: int =
        (rows.len() * 1_000_000_000) / if elapsed < 1 { 1 } else { elapsed }
    io.println("dom size={data.len()} records={rows.len()} nanos={elapsed} mib_s={throughput(data.len(), elapsed)} records_s={records_per_second} checksum={checksum}")
    return ok(true)
}

fn run_file(mode: string, path: string) -> Result<bool> {
    let data: Bytes = fs.read_bytes(path)?
    if mode == "dom" {
        return dom(data)
    }
    if mode == "typed_in_place" {
        return typed_in_place(move data)
    }
    return typed(data)
}

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("typed")
    let path: string = args.get(1).or("build/json-typed-10mb.json")
    match run_file(mode, path) {
        ok(_) => {}
        err(error) => {
            io.eprintln("{mode} failed: {error.kind}: {error.msg}")
        }
    }
}
