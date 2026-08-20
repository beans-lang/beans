// Fast asynchronous logging backed by the pinned Quill bridge in runtime/log.
// A logger can fan one record out to console, file, rotating file, NDJSON and
// export sinks. Export records are pulled by user code; user callbacks never
// run on the native logging thread.

package log

extern "C" fn beans_log_console_sink(stderr: int, colour: int, level: int) -> int
extern "C" fn beans_log_file_sink(path: RawPtr<u8>, path_len: int, append: int, fsync: int, level: int) -> int
extern "C" fn beans_log_rotating_file_sink(path: RawPtr<u8>, path_len: int, max_bytes: int, max_backups: int, append: int, level: int) -> int
extern "C" fn beans_log_json_file_sink(path: RawPtr<u8>, path_len: int, append: int, fsync: int, level: int) -> int
extern "C" fn beans_log_export_sink(capacity: int, overflow: int, level: int) -> int
extern "C" fn beans_log_logger_create(name: RawPtr<u8>, name_len: int, sinks: RawPtr<u64>, sink_count: int, level: int, pattern: RawPtr<u8>, pattern_len: int) -> int
extern "C" fn beans_log_logger_enabled(logger: int, level: int) -> int
extern "C" fn beans_log_logger_set_level(logger: int, level: int) -> int
extern "C" fn beans_log_write(logger: int, level: int, message: RawPtr<u8>, message_len: int, file: RawPtr<u8>, file_len: int, function: RawPtr<u8>, function_len: int, line: int, column: int) -> int
extern "C" fn beans_log_write_fields(logger: int, level: int, message: RawPtr<u8>, message_len: int, file: RawPtr<u8>, file_len: int, function: RawPtr<u8>, function_len: int, line: int, column: int, fields: RawPtr<u8>, fields_len: int) -> int
extern "C" fn beans_log_flush(logger: int) -> int
extern "C" fn beans_log_flush_all() -> int
extern "C" fn beans_log_shutdown() -> int
extern "C" fn beans_log_dropped() -> int
extern "C" fn beans_log_export_take(sink: int, timeout_millis: int) -> int
extern "C" fn beans_log_export_dropped(sink: int) -> int
extern "C" fn beans_log_record_timestamp_nanos(record: int) -> int
extern "C" fn beans_log_record_level(record: int) -> int
extern "C" fn beans_log_record_line(record: int) -> int
extern "C" fn beans_log_record_column(record: int) -> int
extern "C" fn beans_log_record_string_len(record: int, field: int) -> int
extern "C" fn beans_log_record_string_copy(record: int, field: int, output: RawPtr<u8>, capacity: int) -> int
extern "C" fn beans_log_record_field_count(record: int) -> int
extern "C" fn beans_log_record_field_key_len(record: int, index: int) -> int
extern "C" fn beans_log_record_field_key_copy(record: int, index: int, output: RawPtr<u8>, capacity: int) -> int
extern "C" fn beans_log_record_field_value_len(record: int, index: int) -> int
extern "C" fn beans_log_record_field_value_copy(record: int, index: int, output: RawPtr<u8>, capacity: int) -> int
extern "C" fn beans_log_record_destroy(record: int)
extern "C" fn beans_log_backend_error_count() -> int
extern "C" fn beans_log_backend_error_len() -> int
extern "C" fn beans_log_backend_error_copy(output: RawPtr<u8>, capacity: int) -> int
extern "C" fn beans_log_last_error_len() -> int
extern "C" fn beans_log_last_error_copy(output: RawPtr<u8>, capacity: int) -> int

/// Log severity. `off` is only useful as a logger or sink filter.
pub enum Level {
    trace
    debug
    info
    warn
    error
    fatal
    off
}

fn level_id(level: Level) -> int {
    return match level {
        trace => 0,
        debug => 1,
        info => 2,
        warn => 3,
        error => 4,
        fatal => 5,
        off => 6,
    }
}

fn level_from_id(value: int) -> Level {
    if value == 0 { return Level.trace }
    if value == 1 { return Level.debug }
    if value == 2 { return Level.info }
    if value == 3 { return Level.warn }
    if value == 4 { return Level.error }
    if value == 5 { return Level.fatal }
    return Level.off
}

/// Terminal colour policy for a console sink.
pub enum Colour {
    automatic
    always
    never
}

fn colour_id(colour: Colour) -> int {
    return match colour { automatic => 0, always => 1, never => 2 }
}

/// What an export sink does when its bounded queue is full.
pub enum Overflow {
    drop_newest
    drop_oldest
    block
}

fn overflow_id(overflow: Overflow) -> int {
    return match overflow { drop_newest => 0, drop_oldest => 1, block => 2 }
}

fn native_error(fallback: string) -> string {
    var count: int = 0
    unsafe { count = beans_log_last_error_len() }
    if count <= 0 { return fallback }
    let message: Bytes = new Bytes(count)
    unsafe {
        beans_log_last_error_copy(message.as_ptr(), count)
    }
    return message.to_string()
}

fn bridge_string(record: int, field: int) -> string {
    var count: int = 0
    unsafe { count = beans_log_record_string_len(record, field) }
    if count <= 0 { return "" }
    let value: Bytes = new Bytes(count)
    unsafe {
        beans_log_record_string_copy(record, field, value.as_ptr(), count)
    }
    return value.to_string()
}

fn bridge_field(record: int, index: int, key: bool) -> string {
    var count: int = 0
    unsafe {
        count = if key {
            beans_log_record_field_key_len(record, index)
        } else {
            beans_log_record_field_value_len(record, index)
        }
    }
    if count <= 0 { return "" }
    let value: Bytes = new Bytes(count)
    unsafe {
        if key {
            beans_log_record_field_key_copy(record, index, value.as_ptr(), count)
        } else {
            beans_log_record_field_value_copy(record, index, value.as_ptr(), count)
        }
    }
    return value.to_string()
}

// Native code lowers this shipped helper to one direct bridge call using the
// strings' borrowed payloads and O(1) lengths. The interpreter runs this
// Bytes-based reference body.
fn log_write_strings(logger: int, level: int, message: string,
                     file: string, function: string,
                     line: int, column: int) -> bool {
    let message_bytes: Bytes = Bytes.from(message)
    let file_bytes: Bytes = Bytes.from(file)
    let function_bytes: Bytes = Bytes.from(function)
    unsafe {
        return beans_log_write(
            logger, level,
            message_bytes.as_ptr(), message_bytes.len(),
            file_bytes.as_ptr(), file_bytes.len(),
            function_bytes.as_ptr(), function_bytes.len(),
            line, column) != 0
    }
}

/// One destination. Create sinks with the static factory methods.
pub class Sink {
    handle: int

    fn init(handle: int) { self.handle = handle }

    fn native_handle() -> int { return self.handle }

    /// stderr by default, with colours only when attached to a terminal.
    pub static fn console(stderr: bool = true) -> Result<Sink> {
        return Sink.console_with(Level.trace, Colour.automatic, stderr)
    }

    pub static fn console_with(level: Level, colour: Colour,
                               stderr: bool = true) -> Result<Sink> {
        var handle: int = 0
        unsafe {
            handle = beans_log_console_sink(
                if stderr { 1 } else { 0 }, colour_id(colour), level_id(level))
        }
        if handle == 0 {
            return err(native_error("cannot create console log sink"), "log")
        }
        return ok(new Sink(handle))
    }

    /// A plain text file. `append=false` truncates it on creation.
    pub static fn file(path: string, append: bool = true,
                       fsync: bool = false) -> Result<Sink> {
        return Sink.file_with(path, Level.trace, append, fsync)
    }

    pub static fn file_with(path: string, level: Level,
                            append: bool = true,
                            fsync: bool = false) -> Result<Sink> {
        let bytes: Bytes = Bytes.from(path)
        var handle: int = 0
        unsafe {
            handle = beans_log_file_sink(
                bytes.as_ptr(), bytes.len(), if append { 1 } else { 0 },
                if fsync { 1 } else { 0 }, level_id(level))
        }
        if handle == 0 {
            return err(native_error("cannot create file log sink"), "log")
        }
        return ok(new Sink(handle))
    }

    /// A size-based rotating text file. `max_bytes` must be at least 512.
    pub static fn rotating_file(path: string, max_bytes: int,
                                max_backups: int = 5,
                                append: bool = true) -> Result<Sink> {
        return Sink.rotating_file_with(
            path, max_bytes, Level.trace, max_backups, append)
    }

    pub static fn rotating_file_with(path: string, max_bytes: int,
                                     level: Level,
                                     max_backups: int = 5,
                                     append: bool = true) -> Result<Sink> {
        if max_bytes < 512 {
            return err("log rotation size must be at least 512 bytes", "invalid")
        }
        if max_backups < 0 {
            return err("log rotation backup count cannot be negative", "invalid")
        }
        let bytes: Bytes = Bytes.from(path)
        var handle: int = 0
        unsafe {
            handle = beans_log_rotating_file_sink(
                bytes.as_ptr(), bytes.len(), max_bytes, max_backups,
                if append { 1 } else { 0 }, level_id(level))
        }
        if handle == 0 {
            return err(native_error("cannot create rotating log sink"), "log")
        }
        return ok(new Sink(handle))
    }

    /// One complete JSON object per line, safe for streaming collectors.
    pub static fn json_file(path: string, append: bool = true,
                            fsync: bool = false) -> Result<Sink> {
        return Sink.json_file_with(path, Level.trace, append, fsync)
    }

    pub static fn json_file_with(path: string, level: Level,
                                 append: bool = true,
                                 fsync: bool = false) -> Result<Sink> {
        let bytes: Bytes = Bytes.from(path)
        var handle: int = 0
        unsafe {
            handle = beans_log_json_file_sink(
                bytes.as_ptr(), bytes.len(), if append { 1 } else { 0 },
                if fsync { 1 } else { 0 }, level_id(level))
        }
        if handle == 0 {
            return err(native_error("cannot create JSON log sink"), "log")
        }
        return ok(new Sink(handle))
    }
}

/// A structured key/value pair on an exported record.
pub class Field {
    pub key: string = ""
    pub value: string = ""

    pub fn init(key: string, value: string) {
        self.key = key
        self.value = value
    }
}

fn pack_fields(fields: List<Field>) -> Result<Bytes> {
    if fields.len() > 1024 {
        return err("a log record cannot have more than 1024 fields", "invalid")
    }
    let packed: Bytes = new Bytes(0)
    for index: int in 0..fields.len() {
        let field: Field = fields[index]
        if field.key == "" {
            return err("a log field key cannot be empty", "invalid")
        }
        for previous: int in 0..index {
            if fields[previous].key == field.key {
                return err("duplicate log field key '{field.key}'", "invalid")
            }
        }
        packed.append_i64(field.key.len())
        packed.append_i64(field.value.len())
        packed.append_string(field.key)
        packed.append_string(field.value)
    }
    return ok(move packed)
}

fn log_write_field_strings(
        logger: int, level: int, message: string,
        file: string, function: string, line: int, column: int,
        fields: List<Field>) -> Result<bool> {
    let packed: Bytes = pack_fields(fields)?
    let message_bytes: Bytes = Bytes.from(message)
    let file_bytes: Bytes = Bytes.from(file)
    let function_bytes: Bytes = Bytes.from(function)
    var status: int = 0
    unsafe {
        status = beans_log_write_fields(
            logger, level,
            message_bytes.as_ptr(), message_bytes.len(),
            file_bytes.as_ptr(), file_bytes.len(),
            function_bytes.as_ptr(), function_bytes.len(),
            line, column, packed.as_ptr(), packed.len())
    }
    if status == 0 {
        unsafe {
            if beans_log_last_error_len() != 0 {
                return err(native_error("cannot write structured log record"), "log")
            }
        }
        return ok(false)
    }
    return ok(true)
}

/// A record pulled from an `ExportSink`.
pub class Record {
    pub timestamp_nanos: int = 0
    pub level: Level = Level.info
    pub logger: string = ""
    pub message: string = ""
    pub file: string = ""
    pub function: string = ""
    pub line: int = 0
    pub column: int = 0
    pub thread_id: string = ""
    pub thread_name: string = ""
    pub process_id: string = ""
    pub fields: List<Field> = []
}

/// A sink whose records can be pulled by another Beans thread or event loop.
pub class ExportSink {
    handle: int
    output_sink: Sink

    fn init(handle: int) {
        self.handle = handle
        self.output_sink = new Sink(handle)
    }

    /// The ordinary sink value passed to `Logger.create`.
    pub fn sink() -> Sink { return self.output_sink }

    /// Creates a bounded export queue. Dropping oldest is the safe default:
    /// it preserves recent events and never stalls every logger in the process.
    pub static fn open(capacity: int = 1024) -> Result<ExportSink> {
        return ExportSink.open_with(
            capacity, Overflow.drop_oldest, Level.trace)
    }

    pub static fn open_with(capacity: int, overflow: Overflow,
                            level: Level) -> Result<ExportSink> {
        if capacity <= 0 {
            return err("log export capacity must be positive", "invalid")
        }
        var handle: int = 0
        unsafe {
            handle = beans_log_export_sink(
                capacity, overflow_id(overflow), level_id(level))
        }
        if handle == 0 {
            return err(native_error("cannot create export log sink"), "log")
        }
        return ok(new ExportSink(handle))
    }

    /// Waits up to `timeout_millis`. Zero polls without waiting.
    pub fn next(timeout_millis: int = 0) -> Result<Option<Record>> {
        if timeout_millis < 0 {
            return err("log export timeout cannot be negative", "invalid")
        }
        var native: int = 0
        unsafe { native = beans_log_export_take(self.handle, timeout_millis) }
        if native == 0 {
            unsafe {
                if beans_log_last_error_len() != 0 {
                    return err(native_error("cannot read exported log record"), "log")
                }
            }
            return ok(none)
        }
        let record: Record = new Record()
        var field_count: int = 0
        unsafe {
            record.timestamp_nanos = beans_log_record_timestamp_nanos(native)
            record.level = level_from_id(beans_log_record_level(native))
            record.line = beans_log_record_line(native)
            record.column = beans_log_record_column(native)
            field_count = beans_log_record_field_count(native)
        }
        record.logger = bridge_string(native, 0)
        record.message = bridge_string(native, 1)
        record.file = bridge_string(native, 2)
        record.function = bridge_string(native, 3)
        record.thread_id = bridge_string(native, 4)
        record.thread_name = bridge_string(native, 5)
        record.process_id = bridge_string(native, 6)
        for index: int in 0..field_count {
            record.fields.push(new Field(
                bridge_field(native, index, true),
                bridge_field(native, index, false)))
        }
        unsafe { beans_log_record_destroy(native) }
        return ok(some(record))
    }

    pub fn dropped() -> int {
        unsafe { return beans_log_export_dropped(self.handle) }
    }
}

/// A named logger with one or more sinks.
pub class Logger {
    handle: int

    fn init(handle: int) { self.handle = handle }
    fn native_handle() -> int { return self.handle }

    pub static fn create(name: string, sinks: List<Sink>,
                         pattern: string = "") -> Result<Logger> {
        return Logger.create_with_level(name, sinks, Level.trace, pattern)
    }

    pub static fn create_with_level(name: string, sinks: List<Sink>,
                                    level: Level,
                                    pattern: string = "") -> Result<Logger> {
        if name == "" { return err("logger name cannot be empty", "invalid") }
        if sinks.len() == 0 {
            return err("a logger needs at least one sink", "invalid")
        }
        let name_bytes: Bytes = Bytes.from(name)
        let pattern_bytes: Bytes = Bytes.from(pattern)
        var handle: int = 0
        unsafe {
            let native_sinks: RawPtr<u64> = RawPtr.alloc(sinks.len())
            for index: int in 0..sinks.len() {
                native_sinks.offset(index).write(
                    sinks[index].native_handle() as u64)
            }
            handle = beans_log_logger_create(
                name_bytes.as_ptr(), name_bytes.len(), native_sinks,
                sinks.len(), level_id(level), pattern_bytes.as_ptr(),
                pattern_bytes.len())
            native_sinks.free()
        }
        if handle == 0 {
            return err(native_error("cannot create logger"), "log")
        }
        return ok(new Logger(handle))
    }

    pub fn enabled(level: Level) -> bool {
        unsafe {
            return beans_log_logger_enabled(self.handle, level_id(level)) != 0
        }
    }

    pub fn set_level(level: Level) -> Result<bool> {
        unsafe {
            if beans_log_logger_set_level(self.handle, level_id(level)) != 0 {
                return ok(true)
            }
        }
        return err(native_error("cannot change logger level"), "log")
    }

    /// Logs with an explicit caller. The compiler uses this same path when it
    /// injects source data for the short level methods.
    pub fn log_at(level: Level, message: string, file: string,
                  function: string, line: int, column: int) -> bool {
        if !self.enabled(level) { return false }
        return self.log_at_code(
            level_id(level), message, file, function, line, column)
    }

    fn log_at_code(level: int, message: string, file: string,
                   function: string, line: int, column: int) -> bool {
        unsafe {
            if beans_log_logger_enabled(self.handle, level) == 0 { return false }
        }
        return log_write_strings(
            self.handle, level, message, file, function, line, column)
    }

    pub fn log(level: Level, message: string) -> bool {
        return self.log_at(level, message, "", "", 0, 0)
    }

    /// Logs string key/value fields. Use `log_at_fields` when the caller
    /// location is supplied by generated code or another logging wrapper.
    pub fn log_fields(level: Level, message: string,
                      fields: List<Field>) -> Result<bool> {
        return self.log_at_fields(level, message, fields, "", "", 0, 0)
    }

    pub fn log_at_fields(level: Level, message: string,
                         fields: List<Field>, file: string,
                         function: string, line: int,
                         column: int) -> Result<bool> {
        if !self.enabled(level) { return ok(false) }
        return log_write_field_strings(
            self.handle, level_id(level), message, file, function,
            line, column, fields)
    }

    pub fn trace(message: string) -> bool { return self.log(Level.trace, message) }
    pub fn debug(message: string) -> bool { return self.log(Level.debug, message) }
    pub fn info(message: string) -> bool { return self.log(Level.info, message) }
    pub fn warn(message: string) -> bool { return self.log(Level.warn, message) }
    pub fn error(message: string) -> bool { return self.log(Level.error, message) }
    pub fn fatal(message: string) -> bool { return self.log(Level.fatal, message) }

    pub fn flush() -> Result<bool> {
        unsafe {
            if beans_log_flush(self.handle) != 0 { return ok(true) }
        }
        return err(native_error("cannot flush logger"), "log")
    }
}

singleton class DefaultState {
    logger: int = 0

    fn get() -> int {
        if self.logger != 0 { return self.logger }
        var sink: int = 0
        unsafe { sink = beans_log_console_sink(1, 0, level_id(Level.trace)) }
        if sink == 0 { return 0 }
        let name: Bytes = Bytes.from("default")
        unsafe {
            let sinks: RawPtr<u64> = RawPtr.alloc(1)
            sinks.write(sink as u64)
            self.logger = beans_log_logger_create(
                name.as_ptr(), name.len(), sinks, 1,
                level_id(Level.info), RawPtr.null(), 0)
            sinks.free()
        }
        return self.logger
    }

    fn set(handle: int) { self.logger = handle }
}

/// Makes module-level `info`, `warn`, and friends use this logger.
pub fn set_default(logger: Logger) {
    DefaultState.instance.set(logger.native_handle())
}

pub fn enabled(level: Level) -> bool {
    let logger: int = DefaultState.instance.get()
    if logger == 0 { return false }
    unsafe { return beans_log_logger_enabled(logger, level_id(level)) != 0 }
}

fn default_write(level: Level, message: string) -> bool {
    return default_write_at_code(
        level_id(level), message, "", "", 0, 0)
}

fn default_write_at_code(level: int, message: string,
                         file: string, function: string,
                         line: int, column: int) -> bool {
    let logger: int = DefaultState.instance.get()
    if logger == 0 { return false }
    unsafe {
        if beans_log_logger_enabled(logger, level) == 0 { return false }
    }
    return log_write_strings(
        logger, level, message, file, function, line, column)
}

pub fn trace(message: string) -> bool { return default_write(Level.trace, message) }
pub fn debug(message: string) -> bool { return default_write(Level.debug, message) }
pub fn info(message: string) -> bool { return default_write(Level.info, message) }
pub fn warn(message: string) -> bool { return default_write(Level.warn, message) }
pub fn error(message: string) -> bool { return default_write(Level.error, message) }
pub fn fatal(message: string) -> bool { return default_write(Level.fatal, message) }

/// Logs string key/value fields through the default logger.
pub fn write_fields(level: Level, message: string,
                    fields: List<Field>) -> Result<bool> {
    return write_at_fields(level, message, fields, "", "", 0, 0)
}

pub fn write_at_fields(level: Level, message: string,
                       fields: List<Field>, file: string,
                       function: string, line: int,
                       column: int) -> Result<bool> {
    let logger: int = DefaultState.instance.get()
    if logger == 0 { return err("cannot create the default logger", "log") }
    unsafe {
        if beans_log_logger_enabled(logger, level_id(level)) == 0 {
            return ok(false)
        }
    }
    return log_write_field_strings(
        logger, level_id(level), message, file, function,
        line, column, fields)
}

pub fn flush() -> Result<bool> {
    unsafe {
        if beans_log_flush_all() != 0 { return ok(true) }
    }
    return err(native_error("cannot flush loggers"), "log")
}

pub fn dropped() -> int {
    unsafe { return beans_log_dropped() }
}

pub fn backend_error_count() -> int {
    unsafe { return beans_log_backend_error_count() }
}

pub fn backend_error() -> string {
    var count: int = 0
    unsafe { count = beans_log_backend_error_len() }
    if count <= 0 { return "" }
    let message: Bytes = new Bytes(count)
    unsafe { beans_log_backend_error_copy(message.as_ptr(), count) }
    return message.to_string()
}

/// Stops the backend after draining it. Logging cannot restart in this process.
pub fn shutdown() -> Result<bool> {
    unsafe {
        if beans_log_shutdown() != 0 { return ok(true) }
    }
    return err(native_error("cannot shut logging down"), "log")
}
