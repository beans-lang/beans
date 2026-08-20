#include "beans_log.h"

#include "quill/Backend.h"
#include "quill/Frontend.h"
#include "quill/LogMacros.h"
#include "quill/Logger.h"
#include "quill/core/MacroMetadata.h"
#include "quill/core/PatternFormatterOptions.h"
#include "quill/sinks/ConsoleSink.h"
#include "quill/sinks/FileSink.h"
#include "quill/sinks/JsonSink.h"
#include "quill/sinks/RotatingFileSink.h"
#include "quill/sinks/Sink.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#ifndef BEANS_RT_PROFILE
#define BEANS_RT_PROFILE 3
#endif

namespace {

thread_local std::string last_error;

std::string copy_string(const uint8_t* data, int64_t written_size) {
  if (written_size < 0) {
    throw std::invalid_argument("a string length is negative");
  }
  if (static_cast<uint64_t>(written_size) >
      static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    throw std::invalid_argument("a string is too large for this target");
  }
  size_t const size = static_cast<size_t>(written_size);
  if (size == 0) {
    return {};
  }
  if (data == nullptr) {
    throw std::invalid_argument("a string pointer is null");
  }
  return {reinterpret_cast<char const*>(data), size};
}

int64_t copy_out(std::string const& value, uint8_t* output,
                 int64_t written_capacity) noexcept {
  if (written_capacity < 0 ||
      static_cast<uint64_t>(written_capacity) >
          static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    return 0;
  }
  size_t const capacity = static_cast<size_t>(written_capacity);
  size_t const count = std::min(value.size(), capacity);
  if (count != 0 && output != nullptr) {
    std::copy_n(reinterpret_cast<uint8_t const*>(value.data()), count, output);
  }
  return static_cast<int64_t>(count);
}

quill::LogLevel to_quill_level(int64_t level) {
  switch (level) {
  case BEANS_LOG_TRACE: return quill::LogLevel::TraceL3;
  case BEANS_LOG_DEBUG: return quill::LogLevel::Debug;
  case BEANS_LOG_INFO: return quill::LogLevel::Info;
  case BEANS_LOG_WARN: return quill::LogLevel::Warning;
  case BEANS_LOG_ERROR: return quill::LogLevel::Error;
  case BEANS_LOG_FATAL: return quill::LogLevel::Critical;
  case BEANS_LOG_OFF: return quill::LogLevel::None;
  default: throw std::invalid_argument("invalid log level");
  }
}

int64_t from_quill_level(quill::LogLevel level) noexcept {
  switch (level) {
  case quill::LogLevel::TraceL3:
  case quill::LogLevel::TraceL2:
  case quill::LogLevel::TraceL1: return BEANS_LOG_TRACE;
  case quill::LogLevel::Debug: return BEANS_LOG_DEBUG;
  case quill::LogLevel::Info:
  case quill::LogLevel::Notice: return BEANS_LOG_INFO;
  case quill::LogLevel::Warning: return BEANS_LOG_WARN;
  case quill::LogLevel::Error: return BEANS_LOG_ERROR;
  case quill::LogLevel::Critical:
  case quill::LogLevel::Backtrace: return BEANS_LOG_FATAL;
  case quill::LogLevel::None: return BEANS_LOG_OFF;
  }
  return BEANS_LOG_OFF;
}

char hex_digit(uint8_t value) noexcept {
  return value < 10 ? static_cast<char>('0' + value)
                    : static_cast<char>('a' + value - 10);
}

std::string hex_encode(std::string_view value) {
  std::string output;
  output.reserve(value.size() * 2);
  for (unsigned char byte : value) {
    output.push_back(hex_digit(static_cast<uint8_t>(byte >> 4)));
    output.push_back(hex_digit(static_cast<uint8_t>(byte & 15)));
  }
  return output;
}

int hex_value(char value) noexcept {
  if (value >= '0' && value <= '9') { return value - '0'; }
  if (value >= 'a' && value <= 'f') { return value - 'a' + 10; }
  if (value >= 'A' && value <= 'F') { return value - 'A' + 10; }
  return -1;
}

bool hex_decode(std::string_view value, std::string& output) {
  if ((value.size() & 1u) != 0) { return false; }
  output.clear();
  output.reserve(value.size() / 2);
  for (size_t index = 0; index < value.size(); index += 2) {
    int const high = hex_value(value[index]);
    int const low = hex_value(value[index + 1]);
    if (high < 0 || low < 0) { return false; }
    output.push_back(static_cast<char>((high << 4) | low));
  }
  return true;
}

std::vector<std::pair<std::string, std::string>> parse_fields_blob(
    uint8_t const* data, int64_t written_size) {
  if (written_size < 0) {
    throw std::invalid_argument("the structured field blob length is negative");
  }
  if (static_cast<uint64_t>(written_size) >
      static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    throw std::invalid_argument(
        "the structured field blob is too large for this target");
  }
  size_t const size = static_cast<size_t>(written_size);
  if (size != 0 && data == nullptr) {
    throw std::invalid_argument("the structured field blob pointer is null");
  }
  std::vector<std::pair<std::string, std::string>> fields;
  size_t cursor = 0;
  while (cursor < size) {
    if (fields.size() >= 1024 || size - cursor < sizeof(int64_t) * 2) {
      throw std::invalid_argument("the structured field blob is invalid");
    }
    int64_t key_length = 0;
    int64_t value_length = 0;
    std::memcpy(&key_length, data + cursor, sizeof(key_length));
    cursor += sizeof(key_length);
    std::memcpy(&value_length, data + cursor, sizeof(value_length));
    cursor += sizeof(value_length);
    if (key_length <= 0 || value_length < 0) {
      throw std::invalid_argument("a structured log field length is invalid");
    }
    uint64_t const key_size = static_cast<uint64_t>(key_length);
    uint64_t const value_size = static_cast<uint64_t>(value_length);
    if (key_size > size - cursor) {
      throw std::invalid_argument("a structured log field key is truncated");
    }
    std::string key{reinterpret_cast<char const*>(data + cursor),
                    static_cast<size_t>(key_size)};
    cursor += static_cast<size_t>(key_size);
    if (value_size > size - cursor) {
      throw std::invalid_argument("a structured log field value is truncated");
    }
    std::string value{reinterpret_cast<char const*>(data + cursor),
                      static_cast<size_t>(value_size)};
    cursor += static_cast<size_t>(value_size);
    fields.emplace_back(std::move(key), std::move(value));
  }
  return fields;
}

std::string source_tags(
    int64_t column,
    std::vector<std::pair<std::string, std::string>> const& fields) {
  if (fields.empty()) { return std::to_string(column); }
  std::string output = "beans1|" + std::to_string(column) + "|";
  for (auto const& field : fields) {
    output.append(hex_encode(field.first));
    output.push_back('=');
    output.append(hex_encode(field.second));
    output.push_back(';');
  }
  return output;
}

void decode_source_tags(
    char const* raw, int64_t& column,
    std::vector<std::pair<std::string, std::string>>& fields) noexcept {
  column = 0;
  if (raw == nullptr || raw[0] == '\0') { return; }
  try {
    std::string_view tags{raw};
    if (tags.size() < 7 || tags.substr(0, 7) != "beans1|") {
      column = static_cast<int64_t>(std::stoull(std::string{tags}));
      return;
    }
    size_t const column_end = tags.find('|', 7);
    if (column_end == std::string_view::npos) { return; }
    column = static_cast<int64_t>(
        std::stoull(std::string{tags.substr(7, column_end - 7)}));
    size_t cursor = column_end + 1;
    while (cursor < tags.size()) {
      size_t const equals = tags.find('=', cursor);
      size_t const end = tags.find(';', cursor);
      if (equals == std::string_view::npos || end == std::string_view::npos ||
          equals > end) {
        fields.clear();
        return;
      }
      std::string key;
      std::string value;
      if (!hex_decode(tags.substr(cursor, equals - cursor), key) ||
          !hex_decode(tags.substr(equals + 1, end - equals - 1), value)) {
        fields.clear();
        return;
      }
      fields.emplace_back(std::move(key), std::move(value));
      cursor = end + 1;
    }
  } catch (...) {
    column = 0;
    fields.clear();
  }
}

struct Record {
  uint64_t timestamp_nanos{0};
  int64_t level{BEANS_LOG_INFO};
  int64_t line{0};
  int64_t column{0};
  std::string logger;
  std::string message;
  std::string file;
  std::string function;
  std::string thread_id;
  std::string thread_name;
  std::string process_id;
  std::vector<std::pair<std::string, std::string>> fields;
};

class ExportSink final : public quill::Sink {
public:
  ExportSink(int64_t capacity, int64_t overflow)
    : capacity_(static_cast<size_t>(capacity)), overflow_(overflow) {
    if (capacity <= 0) {
      throw std::invalid_argument("export capacity must be greater than zero");
    }
    if (overflow_ < BEANS_LOG_EXPORT_DROP_NEWEST ||
        overflow_ > BEANS_LOG_EXPORT_BLOCK) {
      throw std::invalid_argument("invalid export overflow policy");
    }
  }

  std::unique_ptr<Record> take(uint64_t timeout_millis) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (records_.empty() && !closed_) {
      if (timeout_millis == 0) {
        return {};
      }
      condition_.wait_for(lock, std::chrono::milliseconds(timeout_millis),
                          [this] { return closed_ || !records_.empty(); });
    }
    if (records_.empty()) {
      return {};
    }
    auto record = std::move(records_.front());
    records_.pop_front();
    lock.unlock();
    condition_.notify_all();
    return record;
  }

  void close() noexcept {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      closed_ = true;
    }
    condition_.notify_all();
  }

  uint64_t dropped() const noexcept {
    return dropped_.load(std::memory_order_relaxed);
  }

protected:
  void write_log(quill::MacroMetadata const* metadata, uint64_t timestamp,
                 std::string_view thread_id, std::string_view thread_name,
                 std::string const& process_id, std::string_view logger_name,
                 quill::LogLevel level, std::string_view,
                 std::string_view,
                 std::vector<std::pair<std::string, std::string>> const* fields,
                 std::string_view message, std::string_view) override {
    auto record = std::make_unique<Record>();
    record->timestamp_nanos = timestamp;
    record->level = from_quill_level(level);
    record->logger.assign(logger_name);
    record->message.assign(message);
    record->thread_id.assign(thread_id);
    record->thread_name.assign(thread_name);
    record->process_id = process_id;
    if (metadata != nullptr) {
      record->file.assign(metadata->full_path());
      record->function = metadata->caller_function();
      try {
        record->line = static_cast<int64_t>(std::stoull(metadata->line()));
      } catch (...) {
        record->line = 0;
      }
      decode_source_tags(metadata->tags(), record->column, record->fields);
    }
    if (fields != nullptr) {
      record->fields.insert(record->fields.end(), fields->begin(), fields->end());
    }

    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    if (overflow_ == BEANS_LOG_EXPORT_BLOCK) {
      condition_.wait(lock, [this] {
        return closed_ || records_.size() < capacity_;
      });
      if (closed_) {
        dropped_.fetch_add(1, std::memory_order_relaxed);
        return;
      }
    } else if (records_.size() >= capacity_) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      if (overflow_ == BEANS_LOG_EXPORT_DROP_NEWEST) {
        return;
      }
      records_.pop_front();
    }
    records_.push_back(std::move(record));
    lock.unlock();
    condition_.notify_all();
  }

  void flush_sink() override {}

private:
  size_t capacity_;
  int64_t overflow_;
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::unique_ptr<Record>> records_;
  std::atomic<uint64_t> dropped_{0};
  bool closed_{false};
};

class BeansJsonFileSink final : public quill::JsonFileSink {
public:
  BeansJsonFileSink(quill::fs::path const& filename,
                    quill::FileSinkConfig const& config)
    : quill::JsonFileSink(filename, config) {}

  void generate_json_message(
      quill::MacroMetadata const* metadata, uint64_t timestamp,
      std::string_view thread_id, std::string_view thread_name,
      std::string const& process_id, std::string_view logger_name,
      quill::LogLevel, std::string_view level, std::string_view,
      std::vector<std::pair<std::string, std::string>> const* fields,
      std::string_view message, std::string_view, char const*) override {
    int64_t column = 0;
    std::vector<std::pair<std::string, std::string>> all_fields;
    if (metadata != nullptr) {
      decode_source_tags(metadata->tags(), column, all_fields);
    }
    if (fields != nullptr) {
      all_fields.insert(all_fields.end(), fields->begin(), fields->end());
    }
    _json_message.append(std::string_view{"{\"timestamp_nanos\":"});
    _json_message.append(std::to_string(timestamp));
    _json_message.append(std::string_view{",\"level\":\""});
    _append_json_escaped(_json_message, level);
    _json_message.append(std::string_view{"\",\"logger\":\""});
    _append_json_escaped(_json_message, logger_name);
    _json_message.append(std::string_view{"\",\"message\":\""});
    _append_json_escaped(_json_message, message);
    _json_message.append(std::string_view{"\",\"file\":\""});
    _append_json_escaped(_json_message,
                         metadata == nullptr ? std::string_view{} : metadata->full_path());
    _json_message.append(std::string_view{"\",\"line\":"});
    _json_message.append(std::string_view{
        metadata == nullptr ? "0" : metadata->line()});
    _json_message.append(std::string_view{",\"column\":"});
    _json_message.append(std::to_string(column));
    _json_message.append(std::string_view{",\"function\":\""});
    _append_json_escaped(_json_message,
                         metadata == nullptr ? std::string_view{} :
                                               std::string_view{metadata->caller_function()});
    _json_message.append(std::string_view{"\",\"thread_id\":\""});
    _append_json_escaped(_json_message, thread_id);
    _json_message.append(std::string_view{"\",\"thread_name\":\""});
    _append_json_escaped(_json_message, thread_name);
    _json_message.append(std::string_view{"\",\"process_id\":\""});
    _append_json_escaped(_json_message, process_id);
    _json_message.append(std::string_view{"\",\"fields\":{"});
    if (!all_fields.empty()) {
      bool first = true;
      for (auto const& field : all_fields) {
        if (!first) {
          _json_message.push_back(',');
        }
        first = false;
        _json_message.push_back('"');
        _append_json_escaped(_json_message, field.first);
        _json_message.append(std::string_view{"\":\""});
        _append_json_escaped(_json_message, field.second);
        _json_message.push_back('"');
      }
    }
    _json_message.push_back('}');
  }
};

struct SinkEntry {
  std::shared_ptr<quill::Sink> sink;
  std::shared_ptr<ExportSink> export_sink;
};

struct LoggerEntry {
  quill::Logger* logger{nullptr};
  std::string public_name;
};

class Manager {
public:
  static Manager& instance() {
    static Manager manager;
    return manager;
  }

  void start() {
    std::unique_lock<std::shared_mutex> lock(lifecycle_mutex_);
    if (shut_down_ || stopping_.load(std::memory_order_acquire)) {
      throw std::runtime_error("logging has already been shut down");
    }
    if (quill::Backend::is_running()) {
      return;
    }
    quill::BackendOptions options;
    options.error_notifier = [this](std::string const& message) {
      std::lock_guard<std::mutex> error_lock(error_mutex_);
      backend_error_ = message;
      backend_error_count_.fetch_add(1, std::memory_order_relaxed);
    };
    quill::Backend::start(options);
    if (!atexit_registered_) {
      std::atexit([] {
        try {
          Manager::instance().shutdown();
        } catch (...) {
        }
      });
      atexit_registered_ = true;
    }
  }

  std::shared_lock<std::shared_mutex> running_lock() {
    std::shared_lock<std::shared_mutex> lock(lifecycle_mutex_);
    if (shut_down_ || stopping_.load(std::memory_order_acquire) ||
        !quill::Backend::is_running()) {
      throw std::runtime_error("logging has been shut down");
    }
    return lock;
  }

  uint64_t add_sink(std::shared_ptr<quill::Sink> sink,
                    std::shared_ptr<ExportSink> export_sink = {}) {
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t const handle = next_handle_++;
    sinks_.emplace(handle, SinkEntry{std::move(sink), std::move(export_sink)});
    return handle;
  }

  uint64_t add_logger(std::string name, std::vector<uint64_t> const& sink_handles,
                      quill::LogLevel level, std::string pattern) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto existing = logger_names_.find(name);
    if (existing != logger_names_.end()) {
      throw std::invalid_argument("a logger with that name already exists");
    }
    std::vector<std::shared_ptr<quill::Sink>> sinks;
    sinks.reserve(sink_handles.size());
    for (uint64_t handle : sink_handles) {
      auto found = sinks_.find(handle);
      if (found == sinks_.end()) {
        throw std::invalid_argument("logger refers to an unknown sink");
      }
      sinks.push_back(found->second.sink);
    }
    if (sinks.empty()) {
      throw std::invalid_argument("a logger needs at least one sink");
    }
    if (pattern.empty()) {
      pattern = "%(time) [%(thread_id)] %(log_level:<8) %(logger) %(message) (%(short_source_location))";
    }
    auto* logger = quill::Frontend::create_logger(
        name, std::move(sinks), quill::PatternFormatterOptions{std::move(pattern)},
        quill::ClockSourceType::System);
    logger->set_log_level(level);
    uint64_t const handle = next_handle_++;
    loggers_.emplace(handle, LoggerEntry{logger, name});
    logger_names_.emplace(std::move(name), handle);
    return handle;
  }

  LoggerEntry& logger(uint64_t handle) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = loggers_.find(handle);
    if (found == loggers_.end()) {
      throw std::invalid_argument("unknown logger handle");
    }
    return found->second;
  }

  std::shared_ptr<ExportSink> export_sink(uint64_t handle) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = sinks_.find(handle);
    if (found == sinks_.end() || !found->second.export_sink) {
      throw std::invalid_argument("unknown export sink handle");
    }
    return found->second.export_sink;
  }

  uint64_t add_record(std::unique_ptr<Record> record) {
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t const handle = next_handle_++;
    records_.emplace(handle, std::move(record));
    return handle;
  }

  Record& record(uint64_t handle) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = records_.find(handle);
    if (found == records_.end()) {
      throw std::invalid_argument("unknown export record handle");
    }
    return *found->second;
  }

  void remove_record(uint64_t handle) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    records_.erase(handle);
  }

  std::vector<quill::Logger*> all_loggers() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<quill::Logger*> result;
    result.reserve(loggers_.size());
    for (auto const& entry : loggers_) {
      result.push_back(entry.second.logger);
    }
    return result;
  }

  void close_exports() noexcept {
    std::vector<std::shared_ptr<ExportSink>> exports;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (auto const& entry : sinks_) {
        if (entry.second.export_sink) {
          exports.push_back(entry.second.export_sink);
        }
      }
    }
    for (auto const& sink : exports) {
      sink->close();
    }
  }

  void shutdown() {
    bool const first =
        !stopping_.exchange(true, std::memory_order_acq_rel);
    if (first) { close_exports(); }
    std::unique_lock<std::shared_mutex> lock(lifecycle_mutex_);
    if (shut_down_) {
      return;
    }
    shut_down_ = true;
    // A sink could have finished creation between the first close snapshot
    // and the lifecycle writer lock. No new operation can start now.
    close_exports();
    if (quill::Backend::is_running()) {
      quill::Backend::stop();
    }
  }

  uint64_t note_drop() noexcept {
    return dropped_.fetch_add(1, std::memory_order_relaxed) + 1;
  }

  uint64_t dropped() const noexcept {
    return dropped_.load(std::memory_order_relaxed);
  }

  uint64_t backend_error_count() const noexcept {
    return backend_error_count_.load(std::memory_order_relaxed);
  }

  std::string backend_error() const {
    std::lock_guard<std::mutex> lock(error_mutex_);
    return backend_error_;
  }

private:
  std::mutex mutex_;
  std::shared_mutex lifecycle_mutex_;
  mutable std::mutex error_mutex_;
  std::unordered_map<uint64_t, SinkEntry> sinks_;
  std::unordered_map<uint64_t, LoggerEntry> loggers_;
  std::unordered_map<std::string, uint64_t> logger_names_;
  std::unordered_map<uint64_t, std::unique_ptr<Record>> records_;
  std::string backend_error_;
  std::atomic<uint64_t> backend_error_count_{0};
  std::atomic<uint64_t> dropped_{0};
  std::atomic<bool> stopping_{false};
  uint64_t next_handle_{1};
  bool shut_down_{false};
  bool atexit_registered_{false};
};

template <typename Return, typename Function>
Return guarded(Return failure, Function&& function) noexcept {
  try {
    last_error.clear();
    return function();
  } catch (std::exception const& error) {
    last_error = error.what();
  } catch (...) {
    last_error = "unknown logging bridge error";
  }
  return failure;
}

template <typename Function>
int64_t guarded_status(Function&& function) noexcept {
  return guarded<int64_t>(0, [&] {
    function();
    return 1;
  });
}

std::string const& record_string(Record const& record, int64_t field) {
  switch (field) {
  case BEANS_LOG_RECORD_LOGGER: return record.logger;
  case BEANS_LOG_RECORD_MESSAGE: return record.message;
  case BEANS_LOG_RECORD_FILE: return record.file;
  case BEANS_LOG_RECORD_FUNCTION: return record.function;
  case BEANS_LOG_RECORD_THREAD_ID: return record.thread_id;
  case BEANS_LOG_RECORD_THREAD_NAME: return record.thread_name;
  case BEANS_LOG_RECORD_PROCESS_ID: return record.process_id;
  default: throw std::invalid_argument("invalid export record string field");
  }
}

quill::FileSinkConfig file_config(int64_t append, int64_t fsync) {
  quill::FileSinkConfig config;
  config.set_open_mode(append != 0 ? 'a' : 'w');
  config.set_fsync_enabled(fsync != 0);
  return config;
}

int64_t write_record(
    int64_t logger, int64_t level,
    uint8_t const* message, int64_t message_len,
    uint8_t const* file, int64_t file_len,
    uint8_t const* function, int64_t function_len,
    int64_t line, int64_t column,
    std::vector<std::pair<std::string, std::string>> const& fields) {
  auto running = Manager::instance().running_lock();
  auto* native_logger = Manager::instance().logger(logger).logger;
  quill::LogLevel const native_level = to_quill_level(level);
  if (!native_logger->should_log_statement(native_level)) { return 1; }
  std::string text = copy_string(message, message_len);
  std::string source = copy_string(file, file_len);
  std::string caller = copy_string(function, function_len);
  if (line < 0 || line > 4294967295 || column < 0) {
    throw std::invalid_argument("source position is out of range");
  }
  std::string tags = source_tags(column, fields);
  static constexpr quill::MacroMetadata metadata{
      "[beans]", "[beans]", "{}", "", quill::LogLevel::None,
      quill::MacroMetadata::Event::LogWithRuntimeMetadataDeepCopy};
  bool const queued = native_logger->log_statement_runtime_metadata<false>(
      &metadata, "{}", source.c_str(), caller.c_str(), tags.c_str(), line,
      native_level, text);
  if (!queued) {
    Manager::instance().note_drop();
    return 0;
  }
  return 1;
}

} // namespace

extern "C" {

int64_t beans_log_console_sink(int64_t use_stderr, int64_t colour_mode,
                               int64_t min_level) {
  return guarded<int64_t>(0, [&] {
    Manager::instance().start();
    auto running = Manager::instance().running_lock();
    quill::ConsoleSinkConfig config;
    config.set_stream(use_stderr != 0 ? "stderr" : "stdout");
    switch (colour_mode) {
    case 0: config.set_colour_mode(quill::ConsoleSinkConfig::ColourMode::Automatic); break;
    case 1: config.set_colour_mode(quill::ConsoleSinkConfig::ColourMode::Always); break;
    case 2: config.set_colour_mode(quill::ConsoleSinkConfig::ColourMode::Never); break;
    default: throw std::invalid_argument("invalid console colour mode");
    }
    static std::atomic<uint64_t> sequence{1};
    auto sink = quill::Frontend::create_sink<quill::ConsoleSink>(
        "beans-console-" + std::to_string(sequence.fetch_add(1)), config);
    sink->set_log_level_filter(to_quill_level(min_level));
    return Manager::instance().add_sink(std::move(sink));
  });
}

int64_t beans_log_file_sink(const uint8_t* path, int64_t path_len,
                            int64_t append, int64_t fsync, int64_t min_level) {
  return guarded<int64_t>(0, [&] {
#if BEANS_RT_PROFILE < 3
    (void)path; (void)path_len; (void)append; (void)fsync; (void)min_level;
    throw std::runtime_error("file log sinks need the full runtime profile");
    return int64_t{0};
#else
    Manager::instance().start();
    auto running = Manager::instance().running_lock();
    std::string filename = copy_string(path, path_len);
    auto config = file_config(append, fsync);
    auto sink = quill::Frontend::create_sink<quill::FileSink>(
        filename, config);
    sink->set_log_level_filter(to_quill_level(min_level));
    return Manager::instance().add_sink(std::move(sink));
#endif
  });
}

int64_t beans_log_rotating_file_sink(const uint8_t* path, int64_t path_len,
                                     int64_t max_bytes, int64_t max_backups,
                                     int64_t append, int64_t min_level) {
  return guarded<int64_t>(0, [&] {
#if BEANS_RT_PROFILE < 3
    (void)path; (void)path_len; (void)max_bytes; (void)max_backups;
    (void)append; (void)min_level;
    throw std::runtime_error("rotating log sinks need the full runtime profile");
    return int64_t{0};
#else
    Manager::instance().start();
    auto running = Manager::instance().running_lock();
    std::string filename = copy_string(path, path_len);
    quill::RotatingFileSinkConfig config;
    config.set_open_mode(append != 0 ? 'a' : 'w');
    if (max_bytes < 0 || max_backups < 0) {
      throw std::invalid_argument("rotation limits cannot be negative");
    }
    config.set_rotation_max_file_size(static_cast<size_t>(max_bytes));
    config.set_max_backup_files(static_cast<uint32_t>(max_backups));
    auto sink = quill::Frontend::create_sink<quill::RotatingFileSink>(
        filename, config);
    sink->set_log_level_filter(to_quill_level(min_level));
    return Manager::instance().add_sink(std::move(sink));
#endif
  });
}

int64_t beans_log_json_file_sink(const uint8_t* path, int64_t path_len,
                                 int64_t append, int64_t fsync,
                                 int64_t min_level) {
  return guarded<int64_t>(0, [&] {
#if BEANS_RT_PROFILE < 3
    (void)path; (void)path_len; (void)append; (void)fsync; (void)min_level;
    throw std::runtime_error("JSON file log sinks need the full runtime profile");
    return int64_t{0};
#else
    Manager::instance().start();
    auto running = Manager::instance().running_lock();
    std::string filename = copy_string(path, path_len);
    auto config = file_config(append, fsync);
    auto sink = quill::Frontend::create_sink<BeansJsonFileSink>(
        filename, config);
    sink->set_log_level_filter(to_quill_level(min_level));
    return Manager::instance().add_sink(std::move(sink));
#endif
  });
}

int64_t beans_log_export_sink(int64_t capacity, int64_t overflow,
                              int64_t min_level) {
  return guarded<int64_t>(0, [&] {
    Manager::instance().start();
    auto running = Manager::instance().running_lock();
    static std::atomic<uint64_t> sequence{1};
    auto base = quill::Frontend::create_sink<ExportSink>(
        "beans-export-" + std::to_string(sequence.fetch_add(1)), capacity, overflow);
    auto export_sink = std::static_pointer_cast<ExportSink>(base);
    export_sink->set_log_level_filter(to_quill_level(min_level));
    return Manager::instance().add_sink(base, std::move(export_sink));
  });
}

int64_t beans_log_logger_create(const uint8_t* name, int64_t name_len,
                                const int64_t* sinks, int64_t sink_count,
                                int64_t min_level, const uint8_t* pattern,
                                int64_t pattern_len) {
  return guarded<int64_t>(0, [&] {
    Manager::instance().start();
    auto running = Manager::instance().running_lock();
    if (sink_count < 0) {
      throw std::invalid_argument("the sink count is negative");
    }
    if (sink_count != 0 && sinks == nullptr) {
      throw std::invalid_argument("the sink handle pointer is null");
    }
    std::vector<uint64_t> handles;
    handles.reserve(static_cast<size_t>(sink_count));
    for (int64_t index = 0; index < sink_count; ++index) {
      if (sinks[index] <= 0) {
        throw std::invalid_argument("a sink handle is invalid");
      }
      handles.push_back(static_cast<uint64_t>(sinks[index]));
    }
    return Manager::instance().add_logger(
        copy_string(name, name_len), handles, to_quill_level(min_level),
        copy_string(pattern, pattern_len));
  });
}

int64_t beans_log_logger_enabled(int64_t logger, int64_t level) {
  return guarded<int64_t>(0, [&] {
    auto running = Manager::instance().running_lock();
    return Manager::instance().logger(logger).logger->should_log_statement(
               to_quill_level(level)) ? 1 : 0;
  });
}

int64_t beans_log_logger_set_level(int64_t logger, int64_t level) {
  return guarded_status([&] {
    auto running = Manager::instance().running_lock();
    Manager::instance().logger(logger).logger->set_log_level(to_quill_level(level));
  });
}

int64_t beans_log_write(int64_t logger, int64_t level,
                        const uint8_t* message, int64_t message_len,
                        const uint8_t* file, int64_t file_len,
                        const uint8_t* function, int64_t function_len,
                        int64_t line, int64_t column) {
  return guarded<int64_t>(0, [&] {
    static std::vector<std::pair<std::string, std::string>> const empty_fields;
    return write_record(
        logger, level, message, message_len, file, file_len,
        function, function_len, line, column, empty_fields);
  });
}

int64_t beans_log_write_fields(
    int64_t logger, int64_t level,
    const uint8_t* message, int64_t message_len,
    const uint8_t* file, int64_t file_len,
    const uint8_t* function, int64_t function_len,
    int64_t line, int64_t column,
    const uint8_t* fields_blob, int64_t fields_blob_len) {
  return guarded<int64_t>(0, [&] {
    auto fields = parse_fields_blob(fields_blob, fields_blob_len);
    return write_record(
        logger, level, message, message_len, file, file_len,
        function, function_len, line, column, fields);
  });
}

int64_t beans_log_flush(int64_t logger) {
  return guarded_status([&] {
    auto running = Manager::instance().running_lock();
    Manager::instance().logger(logger).logger->flush_log();
  });
}

int64_t beans_log_flush_all(void) {
  return guarded_status([&] {
    auto running = Manager::instance().running_lock();
    for (auto* logger : Manager::instance().all_loggers()) {
      logger->flush_log();
    }
  });
}

int64_t beans_log_shutdown(void) {
  return guarded_status([&] { Manager::instance().shutdown(); });
}

int64_t beans_log_dropped(void) {
  return static_cast<int64_t>(Manager::instance().dropped());
}

int64_t beans_log_export_take(int64_t sink, int64_t timeout_millis) {
  return guarded<int64_t>(0, [&] {
    if (timeout_millis < 0) {
      throw std::invalid_argument("export timeout cannot be negative");
    }
    auto record = Manager::instance().export_sink(sink)->take(timeout_millis);
    return record ? Manager::instance().add_record(std::move(record)) : 0;
  });
}

int64_t beans_log_export_dropped(int64_t sink) {
  return guarded<int64_t>(0, [&] {
    return static_cast<int64_t>(Manager::instance().export_sink(sink)->dropped());
  });
}

int64_t beans_log_record_timestamp_nanos(int64_t record) {
  return guarded<int64_t>(0, [&] {
    return static_cast<int64_t>(Manager::instance().record(record).timestamp_nanos);
  });
}

int64_t beans_log_record_level(int64_t record) {
  return guarded<int64_t>(BEANS_LOG_OFF, [&] {
    return Manager::instance().record(record).level;
  });
}

int64_t beans_log_record_line(int64_t record) {
  return guarded<int64_t>(0, [&] { return Manager::instance().record(record).line; });
}

int64_t beans_log_record_column(int64_t record) {
  return guarded<int64_t>(0, [&] { return Manager::instance().record(record).column; });
}

int64_t beans_log_record_string_len(int64_t record, int64_t field) {
  return guarded<int64_t>(0, [&] {
    return static_cast<int64_t>(
        record_string(Manager::instance().record(record), field).size());
  });
}

int64_t beans_log_record_string_copy(int64_t record, int64_t field,
                                     uint8_t* output, int64_t capacity) {
  return guarded<int64_t>(0, [&] {
    return copy_out(record_string(Manager::instance().record(record), field),
                    output, capacity);
  });
}

int64_t beans_log_record_field_count(int64_t record) {
  return guarded<int64_t>(0, [&] {
    return static_cast<int64_t>(Manager::instance().record(record).fields.size());
  });
}

int64_t beans_log_record_field_key_len(int64_t record, int64_t index) {
  return guarded<int64_t>(0, [&] {
    if (index < 0) { throw std::out_of_range("negative field index"); }
    return static_cast<int64_t>(Manager::instance().record(record).fields.at(
        static_cast<size_t>(index)).first.size());
  });
}

int64_t beans_log_record_field_key_copy(int64_t record, int64_t index,
                                        uint8_t* output, int64_t capacity) {
  return guarded<int64_t>(0, [&] {
    if (index < 0) { throw std::out_of_range("negative field index"); }
    return copy_out(Manager::instance().record(record).fields.at(
                        static_cast<size_t>(index)).first,
                    output, capacity);
  });
}

int64_t beans_log_record_field_value_len(int64_t record, int64_t index) {
  return guarded<int64_t>(0, [&] {
    if (index < 0) { throw std::out_of_range("negative field index"); }
    return static_cast<int64_t>(Manager::instance().record(record).fields.at(
        static_cast<size_t>(index)).second.size());
  });
}

int64_t beans_log_record_field_value_copy(int64_t record, int64_t index,
                                          uint8_t* output, int64_t capacity) {
  return guarded<int64_t>(0, [&] {
    if (index < 0) { throw std::out_of_range("negative field index"); }
    return copy_out(Manager::instance().record(record).fields.at(
                        static_cast<size_t>(index)).second,
                    output, capacity);
  });
}

void beans_log_record_destroy(int64_t record) {
  Manager::instance().remove_record(record);
}

int64_t beans_log_backend_error_count(void) {
  return static_cast<int64_t>(Manager::instance().backend_error_count());
}

int64_t beans_log_backend_error_len(void) {
  return static_cast<int64_t>(Manager::instance().backend_error().size());
}

int64_t beans_log_backend_error_copy(uint8_t* output, int64_t capacity) {
  return copy_out(Manager::instance().backend_error(), output, capacity);
}

int64_t beans_log_last_error_len(void) {
  return static_cast<int64_t>(last_error.size());
}

int64_t beans_log_last_error_copy(uint8_t* output, int64_t capacity) {
  return copy_out(last_error, output, capacity);
}

} // extern "C"
