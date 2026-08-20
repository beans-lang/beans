// Beans-written std.reader.Reader — buffered lines over a File. It reads at its
// own offset (pread), so the file's cursor never moves; buffered data keeps
// serving after close, and the closed error surfaces on the next refill.
import std.io
import std.fs
import std.reader

fn main() {
    let p: string = "{Dir.temp_path()}/beans_reader_example.txt"
    fs.write(p, "alpha\nbeta\n\ngamma with spaces\nlast no newline").expect("seed")

    let f: File = File.open(p, "r").expect("open")
    let r: reader.Reader = new reader.Reader(move f)
    var n: int = 0
    var stop: bool = false
    for !stop {
        match r.read_line().expect("line") {
            some(line) => {
                io.println("{n}: [{line}]")
                n += 1
            },
            none => {
                stop = true
            },
        }
    }
    io.println("lines: {n}")
    r.close().expect("close")

    // a second reader starts from the top, and the cursor never moved
    let again_file: File = File.open(p, "r").expect("open again")
    let again: reader.Reader = new reader.Reader(move again_file)
    io.println(again.read_line().expect("first again").or("?"))
    io.println("{again.file_position()}")
    again.close().expect("close again")

    // a file bigger than the 8KB buffer: lines keep serving from the buffer
    // after close, then the refill reports the closed file
    var big: string = ""
    var i: int = 0
    for i < 1200 {
        big = "{big}row number {i}\n"
        i += 1
    }
    fs.write(p, big).expect("big")
    let fb: File = File.open(p, "r").expect("open big")
    let rb: reader.Reader = new reader.Reader(move fb)
    io.println(rb.read_line().expect("big first").or("?"))
    rb.close().expect("close big")
    var served: int = 0
    var done: bool = false
    for !done {
        match rb.read_line() {
            ok(o) => {
                served += 1
            },
            err(e) => {
                io.println("served {served} buffered, then: {e.kind}: {e.msg}")
                done = true
            },
        }
    }

    // empty file: none straight away
    fs.write(p, "").expect("empty")
    let fe: File = File.open(p, "r").expect("open empty")
    match new reader.Reader(move fe).read_line().expect("eof") {
        some(x) => io.println("line in empty?"),
        none => io.println("empty: none"),
    }
    File.remove(p).expect("rm")
    io.println("done")
}
