// #167: std.fs named a file by its path and covered only its bytes — there was
// no way to remove one, so a program could create a temp file it could never
// release. The blocked shape is a spooled upload part: bytes go to a temp file
// named by a generated id, and the file must be released when the request
// finishes *or* unwinds. The ownership half already worked; the removal did
// not exist, and a release hook cannot spawn `rm` out of a path a client sent.
//
// So this walks a file's whole life through std.fs on both backends — where to
// put it, whether it is there, how big it is, moving it, and ending it — and
// then the real shape: a class whose deinit removes its spooled file, dropped
// on an ordinary scope exit and again on a contained panic, where the unwind
// runs the same hooks. The arc+/arc- markers pin that every part is built and
// released exactly once on both backends, and each release reports whether the
// bytes were actually gone, so a deinit that ran but removed nothing would
// still fail here.
//
// Nothing machine-specific is printed: the scratch directory is picked from
// fs.temp_dir() and never named in the output.
import std.fs
import std.io
import std.path
import std.time

class SpooledPart {
    tag: string
    file: string

    fn init(tag: string, dir: string, body: string) {
        self.tag = tag
        self.file = path.join(dir, "{tag}.part")
        fs.write(self.file, body).expect("spool")
        io.println("arc+{tag}")
    }

    fn deinit() {
        // A release hook cannot propagate a Result and cannot ask `exists`
        // first without racing, so remove answers the question itself:
        // ok(true) it was there, ok(false) it was not. Both are success.
        let removed: bool = fs.remove(self.file).or(false)
        io.println("arc-{self.tag}")
        io.println("  released {self.tag} removed={removed} left={fs.exists(self.file)}")
    }
}

fn handled(dir: string) -> int {
    let a: SpooledPart = new SpooledPart("ok-0", dir, "first")
    let b: SpooledPart = new SpooledPart("ok-1", dir, "second and longer")
    // The spooled bytes are on disk while their owners are alive; the deinits
    // below take them away again.
    var live: int = 0
    if fs.exists(a.file) { live += 1 }
    if fs.exists(b.file) { live += 1 }
    return live
}

fn failing(dir: string) -> int {
    let a: SpooledPart = new SpooledPart("panic-0", dir, "first")
    let b: SpooledPart = new SpooledPart("panic-1", dir, "second")
    let c: SpooledPart = new SpooledPart("panic-2", dir, "third")
    panic("the handler failed halfway")
}

fn kind_of(r: Result<bool>) -> string {
    match r {
        ok(v) => { return "ok {v}" }
        err(e) => { return "err {e.kind}" }
    }
}

fn lifecycle(dir: string) {
    let part: string = path.join(dir, "life.bin")
    let done: string = path.join(dir, "life.done")

    // Removing what was never there is not a failure.
    io.println("missing {kind_of(fs.remove(part))} exists={fs.exists(part)}")

    fs.write(part, "0123456789").expect("write")
    io.println("written exists={fs.exists(part)} size={fs.size(part).or(-1)}")

    // The commit half of the spool pattern: write a temp name, rename over an
    // existing one, and the old bytes are gone with the old name.
    fs.write(done, "stale").expect("stale")
    io.println("commit {kind_of(fs.rename(part, done))} src={fs.exists(part)} dst={fs.exists(done)}")
    let committed: string = fs.read(done).or("")
    io.println("committed bytes={committed} size={fs.size(done).or(-1)}")

    // Removing twice: gone, then nothing there.
    io.println("release {kind_of(fs.remove(done))} again {kind_of(fs.remove(done))}")

    // A directory is not a file, and the two questions are different.
    io.println("dir as file={fs.exists(dir)} as dir={Dir.exists(dir)}")

    // remove is the POSIX verb: an empty directory goes, a full one does not.
    let empty: string = path.join(dir, "empty")
    let full: string = path.join(dir, "full")
    let kept: string = path.join(full, "kept.txt")
    Dir.create(empty).expect("empty")
    Dir.create(full).expect("full")
    fs.write(kept, "kept").expect("kept")
    io.println("empty dir {kind_of(fs.remove(empty))} gone={Dir.exists(empty)}")
    io.println("full dir {kind_of(fs.remove(full))} still={Dir.exists(full)}")

    // A path that runs *through* a file is not "nothing was there": only
    // not_found becomes ok(false), every other kind stays an error.
    let through: string = kind_of(fs.remove(path.join(kept, "below.txt")))
    io.println("through a file {through}")

    fs.remove(kept).expect("kept remove")
    fs.remove(full).expect("full remove")
}

fn main() {
    // fs.temp_dir() has to name a directory this program can actually write
    // to, so everything below happens inside it.
    let temp: string = fs.temp_dir()
    let slash: bool = temp.ends_with("/")
    let backslash: bool = temp.ends_with("\\")
    io.println("temp named={temp.len() > 0} is_dir={Dir.exists(temp)} trailing_sep={slash || backslash}")

    let scratch: string = path.join(temp, "beans-issue167-{time.monotonic_nanos()}")
    Dir.create(scratch).expect("scratch")

    let probe: string = path.join(scratch, "probe.txt")
    fs.write(probe, "writable").expect("probe write")
    let probe_text: string = fs.read(probe).or("")
    io.println("temp writable={probe_text} removed={fs.remove(probe).or(false)}")

    lifecycle(scratch)

    io.println("handled {handled(scratch)}")
    match contained failing(scratch) {
        ok(n) => { io.println("panic path returned {n}") }
        err(e) => { io.println("contained {e.kind}") }
    }

    // Every part released its bytes, so the scratch directory is empty again
    // and removes with the plain empty-directory verb.
    let left: List<string> = Dir.list(scratch).expect("list")
    io.println("left behind {left.len()}")
    io.println("scratch {kind_of(fs.remove(scratch))}")
}
