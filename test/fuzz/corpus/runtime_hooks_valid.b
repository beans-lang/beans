@runtime_hook(before: "fuzz_before", after_return: "fuzz_after")
@target(value: ["function", "method"])
@repeatable
annotation fuzz_hook {
    label: string
    attempt: int = 0
}

fn fuzz_before(target: string, label: string, attempt: int) {}
fn fuzz_after(target: string, label: string, attempt: int) {}

@runtime_start
fn fuzz_start() {}

@runtime_stop
fn fuzz_stop() {}

class FuzzWorker {
    @fuzz_hook(label: "method")
    fn run() {}
}

@fuzz_hook(label: "first")
@fuzz_hook(label: "second", attempt: 2)
fn fuzz_work() {}

fn main() {
    fuzz_work()
    let worker: FuzzWorker = new FuzzWorker()
    worker.run()
}
