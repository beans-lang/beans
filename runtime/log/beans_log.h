#ifndef BEANS_LOG_H
#define BEANS_LOG_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define BEANS_LOG_API __declspec(dllexport)
#else
#define BEANS_LOG_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Public levels. Larger values are more severe. */
enum beans_log_level {
    BEANS_LOG_TRACE = 0,
    BEANS_LOG_DEBUG = 1,
    BEANS_LOG_INFO = 2,
    BEANS_LOG_WARN = 3,
    BEANS_LOG_ERROR = 4,
    BEANS_LOG_FATAL = 5,
    BEANS_LOG_OFF = 6
};

/* Export overflow policy. */
enum beans_log_export_overflow {
    BEANS_LOG_EXPORT_DROP_NEWEST = 0,
    BEANS_LOG_EXPORT_DROP_OLDEST = 1,
    BEANS_LOG_EXPORT_BLOCK = 2
};

/* String fields exposed by beans_log_record_string_*(). */
enum beans_log_record_string {
    BEANS_LOG_RECORD_LOGGER = 0,
    BEANS_LOG_RECORD_MESSAGE = 1,
    BEANS_LOG_RECORD_FILE = 2,
    BEANS_LOG_RECORD_FUNCTION = 3,
    BEANS_LOG_RECORD_THREAD_ID = 4,
    BEANS_LOG_RECORD_THREAD_NAME = 5,
    BEANS_LOG_RECORD_PROCESS_ID = 6
};

BEANS_LOG_API int64_t beans_log_console_sink(
    int64_t use_stderr, int64_t colour_mode, int64_t min_level);
BEANS_LOG_API int64_t beans_log_file_sink(
    const uint8_t *path, int64_t path_len, int64_t append,
    int64_t fsync, int64_t min_level);
BEANS_LOG_API int64_t beans_log_rotating_file_sink(
    const uint8_t *path, int64_t path_len, int64_t max_bytes,
    int64_t max_backups, int64_t append, int64_t min_level);
BEANS_LOG_API int64_t beans_log_json_file_sink(
    const uint8_t *path, int64_t path_len, int64_t append,
    int64_t fsync, int64_t min_level);
BEANS_LOG_API int64_t beans_log_export_sink(
    int64_t capacity, int64_t overflow, int64_t min_level);

BEANS_LOG_API int64_t beans_log_logger_create(
    const uint8_t *name, int64_t name_len,
    const int64_t *sinks, int64_t sink_count,
    int64_t min_level, const uint8_t *pattern, int64_t pattern_len);
BEANS_LOG_API int64_t beans_log_logger_enabled(
    int64_t logger, int64_t level);
BEANS_LOG_API int64_t beans_log_logger_set_level(
    int64_t logger, int64_t level);
BEANS_LOG_API int64_t beans_log_write(
    int64_t logger, int64_t level,
    const uint8_t *message, int64_t message_len,
    const uint8_t *file, int64_t file_len,
    const uint8_t *function, int64_t function_len,
    int64_t line, int64_t column);
/* fields_blob repeats: little-endian u64 key length, little-endian u64 value
   length, key bytes, value bytes. It is copied before this call returns. */
BEANS_LOG_API int64_t beans_log_write_fields(
    int64_t logger, int64_t level,
    const uint8_t *message, int64_t message_len,
    const uint8_t *file, int64_t file_len,
    const uint8_t *function, int64_t function_len,
    int64_t line, int64_t column,
    const uint8_t *fields_blob, int64_t fields_blob_len);
BEANS_LOG_API int64_t beans_log_flush(int64_t logger);
BEANS_LOG_API int64_t beans_log_flush_all(void);
BEANS_LOG_API int64_t beans_log_shutdown(void);
BEANS_LOG_API int64_t beans_log_dropped(void);

/* Pull one export record. A zero result means timeout/no record. */
BEANS_LOG_API int64_t beans_log_export_take(
    int64_t sink, int64_t timeout_millis);
BEANS_LOG_API int64_t beans_log_export_dropped(int64_t sink);
BEANS_LOG_API int64_t beans_log_record_timestamp_nanos(int64_t record);
BEANS_LOG_API int64_t beans_log_record_level(int64_t record);
BEANS_LOG_API int64_t beans_log_record_line(int64_t record);
BEANS_LOG_API int64_t beans_log_record_column(int64_t record);
BEANS_LOG_API int64_t beans_log_record_string_len(
    int64_t record, int64_t field);
BEANS_LOG_API int64_t beans_log_record_string_copy(
    int64_t record, int64_t field, uint8_t *output, int64_t capacity);
BEANS_LOG_API int64_t beans_log_record_field_count(int64_t record);
BEANS_LOG_API int64_t beans_log_record_field_key_len(
    int64_t record, int64_t index);
BEANS_LOG_API int64_t beans_log_record_field_key_copy(
    int64_t record, int64_t index, uint8_t *output, int64_t capacity);
BEANS_LOG_API int64_t beans_log_record_field_value_len(
    int64_t record, int64_t index);
BEANS_LOG_API int64_t beans_log_record_field_value_copy(
    int64_t record, int64_t index, uint8_t *output, int64_t capacity);
BEANS_LOG_API void beans_log_record_destroy(int64_t record);

BEANS_LOG_API int64_t beans_log_backend_error_count(void);
BEANS_LOG_API int64_t beans_log_backend_error_len(void);
BEANS_LOG_API int64_t beans_log_backend_error_copy(
    uint8_t *output, int64_t capacity);
BEANS_LOG_API int64_t beans_log_last_error_len(void);
BEANS_LOG_API int64_t beans_log_last_error_copy(
    uint8_t *output, int64_t capacity);

#ifdef __cplusplus
}
#endif

#endif
