// File locks belong to the open file description, so separately opened handles contend.
// `try_lock()` keeps output deterministic; `lock()` waits and retries EINTR.
// Use `try_lock()` when the same thread may already hold the description.
import std.io
import std.fs

fn main() {
    let p: string = "{Dir.temp_path()}/beans_locks_example.dat"
    fs.write(p, "guarded").expect("seed")

    let writer: File = File.open(p, "rw").expect("open writer")
    let rival: File = File.open(p, "rw").expect("open rival")

    io.println("{writer.lock().expect("lock")}")
    io.println("{rival.try_lock().expect("try while held")}")
    io.println("{writer.unlock().expect("unlock")}")
    io.println("{rival.try_lock().expect("try after release")}")
    rival.unlock().expect("unlock rival")

    writer.close().expect("close writer")
    match writer.lock() {
        ok(x) => io.println("locked a closed file?"),
        err(e) => io.println("{e.kind}: {e.msg}"),
    }
    rival.close().expect("close rival")

    File.remove(p).expect("cleanup")
    io.println("done")
}
