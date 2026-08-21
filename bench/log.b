// Focused std.log benchmark through the public Beans API. File setup and
// logger setup are outside the timer; flush is inside it because delivery is
// part of the logging contract.
import std.io
import std.log
import std.os
import std.thread
import std.time

fn measure(logger: log.Logger, level: log.Level,
           iterations: int) -> Result<int> {
    var queued: int = 0
    let started: int = time.monotonic_nanos()
    for index: int in 0..iterations {
        if logger.log(level, "hello from beans") { queued += 1 }
    }
    logger.flush()?
    let elapsed: int = time.monotonic_nanos() - started
    io.println("queued={queued}")
    return ok(elapsed)
}

fn run() -> Result<bool> {
    let args: List<string> = os.args()
    let mode: string = args.get(0).or("disabled")
    let path: string = args.get(1).or("beans-log-benchmark.log")
    let iterations: int = args.get(2).or("1000000").to_int().or(1000000)
    var elapsed: int = 0
    var sink_dropped: int = 0

    if mode == "disabled" {
        let exported: log.ExportSink = log.ExportSink.open(1)?
        let logger: log.Logger = log.Logger.create_with_level(
            "bench-disabled", [exported.sink()], log.Level.off)?
        elapsed = measure(logger, log.Level.debug, iterations)?
    } else if mode == "export" {
        let exported: log.ExportSink = log.ExportSink.open(1024)?
        let logger: log.Logger = log.Logger.create(
            "bench-export", [exported.sink()])?
        elapsed = measure(logger, log.Level.info, iterations)?
        sink_dropped = exported.dropped()
    } else if mode == "export_live" {
        let exported: log.ExportSink = log.ExportSink.open_with(
            4096, log.Overflow.block, log.Level.trace)?
        let logger: log.Logger = log.Logger.create(
            "bench-export-live", [exported.sink()])?
        let done: AtomicInt = new AtomicInt(0)
        let reader: log.ExportReader = exported.reader()
        let consumer: Thread<int> = thread.spawn(
            fn() move(reader) -> int {
                var received: int = 0
                for done.load() == 0 {
                    let batch: List<log.Record> =
                        reader.next_batch(256, 10).or([])
                    received += batch.len()
                }
                for {
                    let batch: List<log.Record> =
                        reader.next_batch(256).or([])
                    if batch.len() == 0 { break }
                    received += batch.len()
                }
                return received
            })
        var queued: int = 0
        let started: int = time.monotonic_nanos()
        for index: int in 0..iterations {
            if logger.info("hello from beans") { queued += 1 }
        }
        logger.flush()?
        done.store(1)
        let received: int = consumer.join()
        elapsed = time.monotonic_nanos() - started
        io.println("queued={queued}")
        if received != queued {
            return err(
                "live exporter received {received} of {queued} queued records",
                "log")
        }
        sink_dropped = exported.dropped()
    } else if mode == "file" {
        let sink: log.Sink = log.Sink.file(path, false)?
        let logger: log.Logger = log.Logger.create("bench-file", [sink])?
        elapsed = measure(logger, log.Level.info, iterations)?
    } else if mode == "json" {
        let sink: log.Sink = log.Sink.json_file(path, false)?
        let logger: log.Logger = log.Logger.create("bench-json", [sink])?
        elapsed = measure(logger, log.Level.info, iterations)?
    } else {
        return err(
            "mode must be disabled, export, export_live, file, or json",
            "invalid")
    }
    io.println(
        "log {mode} {iterations} {elapsed} {log.dropped()} {sink_dropped}")
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
