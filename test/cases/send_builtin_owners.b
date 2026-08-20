import std.io
import std.os
import std.thread

fn moved_bytes() -> bool {
    let data: Bytes = Bytes.filled(8, 3)
    let worker: Thread<int> = thread.spawn(
        fn() move(data) -> int {
            data.set(0, 9)
            return data.get(0) + data.len()
        })
    return worker.join() == 17
}

fn moved_file(path: string) -> Result<bool> {
    let file: File = File.open(path, "create")?
    file.truncate(0)?
    let worker: Thread<Result<int>> = thread.spawn(
        fn() move(file) -> Result<int> {
            file.write_at(0, Bytes.from("file"))?
            // Drop the live file on this worker.
            return file.size()
        })
    return ok(worker.join().or(-1) == 4)
}

fn moved_mmap(path: string) -> Result<bool> {
    let seed: File = File.open(path, "create")?
    seed.truncate(16)?
    seed.close()?
    let mapping: MMap = MMap.open(path, true)?
    let worker: Thread<Result<int>> = thread.spawn(
        fn() move(mapping) -> Result<int> {
            mapping.put_u32(0, 0x12345678)
            mapping.flush()?
            // Drop the live mapping on this worker.
            return ok(mapping.get_u32(0))
        })
    return ok(worker.join().or(0) == 0x12345678)
}

fn main() {
    let path: string = os.args().get(0).expect("scratch file")
    io.println("{moved_bytes()} {moved_file(path).or(false)} {moved_mmap(path).or(false)}")
}
