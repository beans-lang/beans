import std.fs
import std.io
import std.os

fn main() {
    let root: string = os.args().get(0).expect("root")
    let source: string = "{root}/source.bin"
    let copied: string = "{root}/copied.bin"
    let text: string = "{root}/text.txt"

    let first: Bytes = new Bytes(6)
    first.put_u32(0, 0x12345678)
    first.put_u16(4, 0xabcd)
    let tail: Bytes = new Bytes(3)
    tail.put_u8(0, 9)
    tail.put_u8(1, 8)
    tail.put_u8(2, 7)
    let source_written: int = fs.write_bytes(source, first).expect("source write")
    let source_appended: int = fs.append_bytes(source, tail).expect("source append")
    let source_data: Bytes = fs.read_bytes(source).expect("source read")
    let copied_count: int = fs.copy(source, copied).expect("copy")
    let copied_data: Bytes = fs.read_bytes(copied).expect("copied read")

    let text_count: int = fs.write(text, "hello").expect("text write")
    let text_append: int = fs.append(text, " world").expect("text append")
    let source_text: string = fs.read(text).expect("source text read")
    let same_count: int = fs.copy(text, text).expect("same-file copy")
    let same_text: string = fs.read(text).expect("same-file read")
    let binary_data: Bytes = new Bytes(3)
    binary_data.put_u8(0, 97)
    binary_data.put_u8(1, 0)
    binary_data.put_u8(2, 98)
    let binary_text: string = binary_data.to_string()
    fs.write(text, binary_text).expect("binary text write")
    let binary_back: string = fs.read(text).expect("binary text read")
    io.println("fs bytes {source_written} {source_appended} {source_data == copied_data} {copied_count}")
    io.println("fs text {text_count} {text_append} {source_text}")
    io.println("fs direct {same_count} {same_text == source_text} {binary_back.len()} {binary_back.byte_at(1)}")

    fs.remove(text).expect("remove text")
    fs.remove(copied).expect("remove copy")
    fs.remove(source).expect("remove source")

    // issue #167: a path's whole life, not only its bytes. Seven parts rather
    // than one, because the interesting half is the *error* path — a remove
    // that finds nothing builds an Error the wrapper then answers `ok(false)`
    // instead of propagating, and that discarded Error is exactly the kind of
    // thing a single run under the sanitizers would not weigh enough to catch.
    let spool: string = "{root}/spool"
    Dir.create(spool).expect("spool dir")
    var made: int = 0
    var released: int = 0
    var vanished: int = 0
    var bytes_seen: int = 0
    var i: int = 0
    for i < 7 {
        let part: string = "{spool}/part-{i}.bin"
        let done: string = "{spool}/part-{i}.done"
        if !fs.remove(part).expect("absent part") { vanished += 1 }
        fs.write(part, "x".repeat(i + 1)).expect("part write")
        if fs.exists(part) { made += 1 }
        bytes_seen += fs.size(part).expect("part size")
        fs.rename(part, done).expect("commit")
        if !fs.exists(part) && fs.exists(done) {
            if fs.remove(done).expect("release") { released += 1 }
        }
        if !fs.remove(done).expect("release twice") { vanished += 1 }
        i += 1
    }
    let leftover: int = Dir.list(spool).expect("spool list").len()
    io.println("fs life {made} {released} {vanished} {bytes_seen} {leftover}")
    io.println("fs dirs {fs.remove(spool).expect("spool remove")} {Dir.exists(spool)}")

    // temp_dir has to name a directory this program can actually write to. The
    // tag comes from the caller's own scratch directory, so two runs of this
    // program can never pick the same probe name inside one shared temp dir.
    let tag: string = os.args().get(1).expect("tag")
    let temp: string = fs.temp_dir()
    let probe: string = "{temp}/beans-fs-source-{tag}.probe"
    fs.write(probe, "probe").expect("probe write")
    let probe_size: int = fs.size(probe).expect("probe size")
    let probe_gone: bool = fs.remove(probe).expect("probe remove")
    io.println("fs temp {temp == Dir.temp_path()} {Dir.exists(temp)} {temp.ends_with("/")} {probe_size} {probe_gone} {fs.exists(probe)}")

    // Symlinks, seeded by the harness because Beans cannot make one. `exists`
    // follows the link and `remove` does not, and the gap between them is the
    // whole reason `remove` asks the filesystem instead of asking `exists`
    // first: a dangling link answers false to `exists` and is still removed.
    // A link to a directory goes the same way — the link, never the directory.
    let live: string = "{root}/links/live.link"
    let dead: string = "{root}/links/dead.link"
    let to_dir: string = "{root}/links/dir.link"
    let target: string = "{root}/links/target.txt"
    let pointed_at: string = "{root}/links/adir"
    io.println("fs links {fs.exists(live)} {fs.exists(dead)} {fs.exists(to_dir)} {Dir.exists(to_dir)}")
    let live_gone: bool = fs.remove(live).expect("remove live link")
    let dead_gone: bool = fs.remove(dead).expect("remove dangling link")
    let dir_gone: bool = fs.remove(to_dir).expect("remove link to a directory")
    io.println("fs unlink {live_gone} {dead_gone} {dir_gone} {fs.exists(target)} {Dir.exists(pointed_at)}")

    // The same link, before and after its target goes: `exists` said true a
    // moment ago and says false now, and the link is still there to remove.
    // This is the window a check-then-act remove would answer wrongly — it is
    // not a hypothetical race, it is one call apart in a single thread.
    let breaks: string = "{root}/links/breaks.link"
    let doomed: string = "{root}/links/broken_target.txt"
    let before_break: bool = fs.exists(breaks)
    fs.remove(doomed).expect("remove the target")
    let after_break: bool = fs.exists(breaks)
    let broken_gone: bool = fs.remove(breaks).expect("remove the broken link")
    io.println("fs broken {before_break} {after_break} {broken_gone} {fs.exists(breaks)}")

    // A symlink loop resolves to nothing, so `exists` is false; `remove` never
    // resolves it and takes the link itself, one side at a time.
    let loop_a: string = "{root}/links/loop_a.link"
    let loop_b: string = "{root}/links/loop_b.link"
    let loop_seen: bool = fs.exists(loop_a)
    let loop_gone: bool = fs.remove(loop_a).expect("remove one side of a loop")
    let loop_rest: bool = fs.remove(loop_b).expect("remove the other side")
    io.println("fs loop {loop_seen} {loop_gone} {loop_rest} {fs.exists(loop_b)}")
}
