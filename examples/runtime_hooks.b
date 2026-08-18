import std.io

@runtime_hook(before: "log_before", after_return: "log_after")
@target(value: ["function", "method"])
annotation log {
    level: string = "info"
}

fn log_before(target: string, level: string) {
    io.println("[{level}] enter {target}")
}

fn log_after(target: string, level: string) {
    io.println("[{level}] leave {target}")
}

@runtime_start
fn start_logging() {
    io.println("logging started")
}

@runtime_stop
fn stop_logging() {
    io.println("logging stopped")
}

@log(level: "debug")
fn work() {
    io.println("working")
}

fn main() {
    work()
}
