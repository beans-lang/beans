// Focused file-boundary benchmark. File contents are prepared before timing,
// so each row measures only the public fs operation named by its mode.
import std.fs
import std.io
import std.os
import std.time

fn main() {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("read")
    let root: string = args.get(1).or(Dir.temp_path())
    let size: int = args.get(2).or("").to_int().or(67108864)
    let rounds: int = args.get(3).or("").to_int().or(5)
    let prepared: bool = args.get(4).or("") == "prepared"
    let source: string = "{root}/beans_io_boundary_source"
    let destination: string = "{root}/beans_io_boundary_destination"
    var payload: string = ""
    if !prepared || mode == "write" {
        let bytes: Bytes = new Bytes(size)
        bytes.fill(97)
        payload = bytes.to_string()
    }
    if !prepared {
        fs.write(source, payload).expect("seed source")
    }

    var checksum: int = 0
    let started: int = time.monotonic_nanos()
    if mode == "read" {
        for round: int in 0..rounds {
            let text: string = fs.read(source).expect("read")
            checksum += text.len()
            checksum += text.byte_at(round % text.len())
        }
    } else if mode == "write" {
        for round: int in 0..rounds {
            checksum += fs.write(destination, payload).expect("write")
        }
    } else if mode == "copy" {
        for round: int in 0..rounds {
            checksum += fs.copy(source, destination).expect("copy")
        }
    } else {
        io.eprintln("mode must be read, write, or copy")
        os.exit(2)
    }
    let elapsed: int = time.monotonic_nanos() - started
    io.println("io {mode} {size} {rounds} {elapsed} {checksum}")

    if File.exists(destination) { File.remove(destination).expect("remove destination") }
    File.remove(source).expect("remove source")
}
