import std.io
import std.log
import std.os

fn lazy_message(counter: AtomicInt) -> string {
    let call: int = counter.add_and_get(1)
    return "lazy-{call}"
}

fn run() -> Result<bool> {
    let exported: log.ExportSink = log.ExportSink.open(16)?
    let logger: log.Logger = log.Logger.create_with_level(
        "levels", [exported.sink()], log.Level.trace)?
    let levels: List<log.Level> = [
        log.Level.trace, log.Level.debug, log.Level.info,
        log.Level.warn, log.Level.error, log.Level.fatal]
    var matched: int = 0
    for index: int in 0..levels.len() {
        if !logger.log_at(
                levels[index], "level-{index}", "levels.b", "run", index + 1, 2) {
            return err("level was not queued", "log")
        }
    }
    logger.flush()?
    let level_records: List<log.Record> =
        exported.next_batch(levels.len(), 1000)?
    if level_records.len() != levels.len() {
        return err("level record batch did not arrive", "log")
    }
    for index: int in 0..levels.len() {
        let record: log.Record = level_records[index]
        if record.level == levels[index] &&
           record.message == "level-{index}" {
            matched += 1
        }
    }
    io.println("levels={matched}")

    logger.set_level(log.Level.error)?
    let method_calls: AtomicInt = new AtomicInt(0)
    let warn_blocked: bool = !logger.warn(lazy_message(method_calls))
    let error_queued: bool = logger.error("accepted error")
    let lazy_error_queued: bool = logger.error(lazy_message(method_calls))
    logger.flush()?
    let filter_ok: bool = match exported.next(1000)? {
        some(record) => record.level == log.Level.error,
        none => false,
    }
    io.println("logger-filter={warn_blocked}|{error_queued}|{filter_ok}")
    let lazy_method_ok: bool = match exported.next(1000)? {
        some(record) => record.message == "lazy-1",
        none => false,
    }
    io.println("lazy-method={lazy_error_queued}|{method_calls.load() == 1}|{lazy_method_ok}")

    log.set_default(logger)
    let default_calls: AtomicInt = new AtomicInt(0)
    let default_warn_blocked: bool = !log.warn(lazy_message(default_calls))
    let default_error_queued: bool = log.error(lazy_message(default_calls))
    log.flush()?
    let lazy_default_ok: bool = match exported.next(1000)? {
        some(record) => record.message == "lazy-1",
        none => false,
    }
    io.println("lazy-default={default_warn_blocked}|{default_error_queued}|{default_calls.load() == 1}|{lazy_default_ok}")

    let fatal_only: log.ExportSink = log.ExportSink.open_with(
        8, log.Overflow.drop_oldest, log.Level.fatal)?
    let sink_logger: log.Logger = log.Logger.create(
        "sink-filter", [fatal_only.sink()])?
    sink_logger.error("filtered by sink")
    sink_logger.fatal("accepted by sink")
    sink_logger.flush()?
    let sink_ok: bool = match fatal_only.next(1000)? {
        some(record) => record.level == log.Level.fatal,
        none => false,
    }
    let empty: bool = match fatal_only.next()? {
        some(_) => false,
        none => true,
    }
    io.println("sink-filter={sink_ok}|{empty}")
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
