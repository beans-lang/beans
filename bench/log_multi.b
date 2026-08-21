// Several Beans producer threads sharing one logger. The start gate keeps
// thread creation outside the timed region; the final flush stays inside it.
import std.io
import std.log
import std.os
import std.thread
import std.time

fn run() -> Result<bool> {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("disabled")
    let workers_count: int = args.get(1).or("4").to_int().or(4)
    let total: int = args.get(2).or("200000").to_int().or(200000)
    let path: string = args.get(3).or("beans-log-multi.log")
    if workers_count <= 0 || workers_count > 64 {
        return err("worker count must be between 1 and 64", "invalid")
    }
    if total < workers_count {
        return err("log count must be at least the worker count", "invalid")
    }
    if mode != "disabled" && mode != "file" {
        return err("mode must be disabled or file", "invalid")
    }

    let sink: log.Sink = log.Sink.file(path, false)?
    let logger: log.Logger = log.Logger.create_with_level(
        "bench-multi", [sink],
        if mode == "disabled" { log.Level.off } else { log.Level.trace })?
    log.set_default(logger)
    let ready: AtomicInt = new AtomicInt(0)
    let go: AtomicInt = new AtomicInt(0)
    var workers: List<Thread<int>> = []
    for lane: int in 0..workers_count {
        let lane_count: int =
            if lane == workers_count - 1 {
                total - (total / workers_count) * lane
            } else {
                total / workers_count
            }
        workers.push(thread.spawn(fn() -> int {
            ready.add_and_get(1)
            for go.load() == 0 { ready.load() }
            var queued: int = 0
            for index: int in 0..lane_count {
                if log.info("hello from beans") { queued += 1 }
            }
            return queued
        }))
    }
    for ready.load() != workers_count { go.load() }
    let started: int = time.monotonic_nanos()
    go.store(1)
    var queued: int = 0
    for worker: Thread<int> in workers {
        queued += worker.join()
    }
    log.flush()?
    let elapsed: int = time.monotonic_nanos() - started
    io.println(
        "log_multi {mode} {workers_count} {total} {elapsed} {queued} {log.dropped()}")
    log.shutdown()?
    return ok(true)
}

fn main() {
    match run() {
        ok(_) => {}
        err(problem) => {
            io.eprintln(problem.msg)
            os.exit(2)
        }
    }
}
