import std.io
import std.thread

class Resource {
    value: int

    fn init(value: int) { self.value = value }
    fn deinit() { io.println("drop {self.value}") }
}

fn main() {
    let worker: Thread<int> = thread.spawn(fn() -> int {
        let resource: Resource = new Resource(7)
        return resource.value
    })
    io.println("joined {worker.join()}")
}
