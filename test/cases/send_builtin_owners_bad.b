import std.thread

class Local {}

fn needs_sync<T implements Sync>(value: T) {}

fn copy_bytes(value: Bytes) {
    let alias: Bytes = value
    let cloned: Bytes = value.clone()
    needs_sync(value)
}

fn copy_file(value: File) {
    let alias: File = value
}

fn copy_mmap(value: MMap) {
    let alias: MMap = value
}

fn local_mutex() {
    let guarded: Mutex<Local> = new Mutex(new Local())
    let worker: Thread<int> = thread.spawn(
        fn() -> int {
            guarded.with_lock(fn(value: Local) {})
            return 1
        })
}

fn main() {}
