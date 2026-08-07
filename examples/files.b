// stdlib phase 2: File and Dir — statics, handles, positional I/O, errors.
// Everything happens inside a scratch dir under Dir.temp_path(); output is
// deterministic, so run vs build must be byte-identical.
import std.io
import std.fs
import std.os
import std.path
import std.time

fn main() {
    let base: string = "{Dir.temp_path()}/beans_files_example"
    Dir.remove_all(base)
    Dir.create_all("{base}/sub").expect("create_all")
    io.println("{Dir.exists(base)} {Dir.exists("{base}/nope")}")

    let f1: string = "{base}/hello.txt"
    io.println("{fs.write(f1, "hello\nworld\n").expect("write")}")
    io.print(fs.read(f1).expect("read"))
    io.println("{fs.append(f1, "again\n").expect("append")}")
    io.println("{File.size(f1).expect("size")}")
    io.println("{File.exists(f1)} {File.exists("{base}/nope.txt")}")

    // binary round-trip
    let page: Bytes = new Bytes(32)
    page.put_u32(0, 7).put_u64(4, 123456789).append_string("tail")
    fs.write_bytes("{base}/page.bin", page).expect("write_bytes")
    let back: Bytes = fs.read_bytes("{base}/page.bin").expect("read_bytes")
    io.println("{back.len()} {back.get_u32(0)} {back.get_u64(4)}")

    // listing is sorted, so it diffs clean
    fs.write("{base}/sub/a.txt", "a").expect("a")
    fs.write("{base}/sub/b.txt", "b").expect("b")
    io.println(Dir.list("{base}/sub").expect("list").join(","))

    // walk is recursive: relative paths, sorted, files only
    io.println(Dir.walk(base).expect("walk"))

    // Path is pure string math — join/parent/base/ext/stem
    let deep: string = path.join(path.join(base, "sub"), "a.txt")
    io.println("{path.name(deep)} {path.extension(deep)} {path.stem(deep)}")
    io.println("{path.parent("/a/b/c")} {path.join("a/", "/abs")} {path.extension(".bashrc")}")

    // copy / rename / remove
    io.println("{fs.copy(f1, "{base}/copy.txt").expect("copy")}")
    File.rename("{base}/copy.txt", "{base}/moved.txt").expect("rename")
    io.println("{File.exists("{base}/moved.txt")}")
    File.remove("{base}/moved.txt").expect("remove")
    io.println("{File.exists("{base}/moved.txt")}")

    // an open handle: positional writes, seek family, truncate, sync, close
    let db: string = "{base}/store.dat"
    let f: File = File.open(db, "create").expect("open")
    f.write_at(0, new Bytes(16).fill(170)).expect("prefill")
    f.write_at(4, new Bytes(4).put_u32(0, 999)).expect("patch")
    let got: Bytes = f.read_at(4, 4).expect("read_at")
    io.println("{got.get_u32(0)}")
    io.println("{f.size().expect("fsize")} {f.tell()}")
    io.println("{f.seek_from_end(0)} {f.seek(2)}")
    let cur: Bytes = f.read(2).expect("cursor read")
    io.println("{cur.get(0)} {cur.get(1)} {f.tell()}")
    f.truncate(8).expect("truncate")
    io.println("{f.size().expect("after truncate")}")
    f.sync().expect("sync")
    f.close().expect("close")
    match f.close() {
        ok(x) => io.println("double close ok?"),
        err(e) => io.println("double close: {e.kind}: {e.msg}"),
    }

    // error kinds ride on Error.kind
    match fs.read("{base}/missing.txt") {
        ok(s) => io.println("read? {s.len()}"),
        err(e) => io.println("kind {e.kind}"),
    }
    match File.open(f1, "sideways") {
        ok(x) => io.println("opened?"),
        err(e) => io.println("{e.kind}: {e.msg}"),
    }

    // os basics, printed deterministically
    io.println("{os.args().len()}")
    match os.env("PATH") {
        some(p) => io.println("PATH set {p.len() > 0}"),
        none => io.println("no PATH"),
    }
    match os.env("BEANS_NO_SUCH_VAR") {
        some(p) => io.println("set?"),
        none => io.println("unset"),
    }
    io.println("{time.monotonic_millis() >= 0} {time.wall_millis() > 0}")
    time.sleep_millis(1)
    io.eprintln("stderr says hi")

    Dir.remove_all(base).expect("cleanup")
    io.println("{Dir.exists(base)}")
}
