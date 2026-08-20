import std.io
import std.log
import std.os

fn run() -> Result<bool> {
    let exported: log.ExportSink = log.ExportSink.open(8)?
    let logger: log.Logger = log.Logger.create(
        "beans-test", [exported.sink()])?

    if !logger.log_at(
            log.Level.info, "hello beans", "sample/main.b", "run", 12, 7) {
        return err("the first record was not queued", "log")
    }
    logger.flush()?
    match exported.next(1000)? {
        some(record) => {
            io.println("{record.logger}|{record.message}")
            io.println("{record.file}|{record.function}|{record.line}|{record.column}")
            io.println("{record.level == log.Level.info}")
        }
        none => { return err("the first record did not arrive", "log") }
    }

    logger.log_at_fields(
        log.Level.info, "structured",
        [new log.Field("request_id", "42"),
         new log.Field("region", "west")],
        "sample/fields.b", "run", 21, 4)?
    logger.flush()?
    match exported.next(1000)? {
        some(record) => {
            io.println("{record.fields[0].key}={record.fields[0].value}|{record.fields[1].key}={record.fields[1].value}")
            io.println("{record.file}|{record.line}|{record.column}")
        }
        none => { return err("the structured record did not arrive", "log") }
    }

    if !logger.info("method source") {
        return err("the method record was not queued", "log")
    }
    logger.flush()?
    match exported.next(1000)? {
        some(record) => {
            io.println(record.message)
            io.println("{record.file.ends_with("log_basic.b")}|{record.function == "main.run"}|{record.line > 0}")
        }
        none => { return err("the method record did not arrive", "log") }
    }

    log.set_default(logger)
    if !log.warn("through default") {
        return err("the default record was not queued", "log")
    }
    log.flush()?
    match exported.next(1000)? {
        some(record) => {
            io.println(record.message)
            io.println("{record.file.ends_with("log_basic.b")}|{record.function == "main.run"}|{record.line > 0}")
        }
        none => { return err("the default record did not arrive", "log") }
    }
    io.println("dropped={log.dropped()} export={exported.dropped()}")
    log.shutdown()?
    return ok(true)
}

fn main() {
    match run() {
        ok(_) => {}
        err(problem) => {
            io.println("failed: {problem.msg}")
            os.exit(1)
        }
    }
}
