// Large automatic XML -> struct benchmark. File I/O is outside the timer.

import std.encoding.xml
import std.fs
import std.io
import std.os
import std.time

@xml.name(value: "row")
@xml.naming(value: xml.Naming.camel_case)
struct XmlBenchRow {
    @xml.attribute
    pub id: u64
    @xml.attribute
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

fn report(label: string, size: int, elapsed: int,
          rows: List<XmlBenchRow>) {
    var checksum: u64 = 0
    for row: XmlBenchRow in rows {
        checksum += row.id + row.user_id + row.name.len() as u64
        if row.active { checksum += 1 }
        match row.note {
            some(note) => { checksum += note.len() as u64 }
            none => {}
        }
    }
    let records_per_second: int =
        (rows.len() * 1_000_000_000) /
        if elapsed < 1 { 1 } else { elapsed }
    io.println("{label} size={size} records={rows.len()} nanos={elapsed} mib_s={throughput(size, elapsed)} records_s={records_per_second} checksum={checksum}")
}

fn typed(data: Bytes) -> Result<bool> {
    let size: int = data.len()
    let started: int = time.monotonic_nanos()
    let decoded: Result<List<XmlBenchRow>> = xml.decode_bytes(data)
    let elapsed: int = time.monotonic_nanos() - started
    match decoded {
        ok(rows) => {
            report("beans_xml_typed", size, elapsed, rows)
            return ok(true)
        }
        err(error) => { return err(error.msg, error.kind) }
    }
}

fn typed_in_place(move data: Bytes) -> Result<bool> {
    let size: int = data.len()
    let started: int = time.monotonic_nanos()
    let decoded: Result<List<XmlBenchRow>> =
        xml.decode_bytes_in_place(move data)
    let elapsed: int = time.monotonic_nanos() - started
    match decoded {
        ok(rows) => {
            report("beans_xml_typed_in_place", size, elapsed, rows)
            return ok(true)
        }
        err(error) => { return err(error.msg, error.kind) }
    }
}

fn run_file(path: string, mode: string) -> Result<bool> {
    let data: Bytes = fs.read_bytes(path)?
    if mode == "in_place" {
        return typed_in_place(move data)
    }
    return typed(data)
}

fn main() {
    let args: List<string> = os.args()
    let path: string = args.get(0).or("build/xml-typed-100mb.xml")
    let mode: string = args.get(1).or("typed")
    match run_file(path, mode) {
        ok(_) => {}
        err(error) => {
            io.eprintln("typed XML failed: {error.kind}: {error.msg}")
        }
    }
}
