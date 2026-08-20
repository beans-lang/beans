import std.io
import std.log
import std.os

fn run() -> Result<bool> {
    let exported: log.ExportSink = log.ExportSink.open(16)?
    let logger: log.Logger = log.Logger.create(
        "example", [exported.sink()])?
    logger.log_at_fields(
        log.Level.info, "ready",
        [new log.Field("service", "beans")],
        "examples/logging.b", "run", 12, 5)?
    logger.flush()?
    match exported.next(1000)? {
        some(record) => {
            io.println("{record.level == log.Level.info} {record.logger} {record.message}")
            io.println("{record.fields[0].key}={record.fields[0].value}")
        }
        none => { return err("the exported log record did not arrive", "log") }
    }
    log.shutdown()?
    return ok(true)
}

fn main() {
    match run() {
        ok(_) => {}
        err(problem) => {
            io.eprintln(problem.msg)
            os.exit(1)
        }
    }
}
