#include "beans_log.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

static int64_t file_sink(std::string const& path) {
  return beans_log_file_sink(
      reinterpret_cast<uint8_t const*>(path.data()), path.size(), 0, 0,
      BEANS_LOG_TRACE);
}

static int64_t json_sink(std::string const& path) {
  return beans_log_json_file_sink(
      reinterpret_cast<uint8_t const*>(path.data()), path.size(), 0, 0,
      BEANS_LOG_TRACE);
}

static std::string record_string(int64_t record, int64_t field) {
  std::string value(beans_log_record_string_len(record, field), '\0');
  beans_log_record_string_copy(
      record, field, reinterpret_cast<uint8_t*>(value.data()), value.size());
  return value;
}

static std::string read_all(std::string const& path) {
  std::ifstream input(path);
  return {std::istreambuf_iterator<char>(input),
          std::istreambuf_iterator<char>()};
}

static void append_i64(std::vector<uint8_t>& output, int64_t value) {
  uint64_t bits = static_cast<uint64_t>(value);
  for (unsigned shift = 0; shift < 64; shift += 8) {
    output.push_back(static_cast<uint8_t>(bits >> shift));
  }
}

static void append_field(std::vector<uint8_t>& output, std::string const& key,
                         std::string const& value) {
  append_i64(output, static_cast<int64_t>(key.size()));
  append_i64(output, static_cast<int64_t>(value.size()));
  output.insert(output.end(), key.begin(), key.end());
  output.insert(output.end(), value.begin(), value.end());
}

static std::string record_field(int64_t record, int64_t index, bool key) {
  int64_t const size = key ? beans_log_record_field_key_len(record, index)
                           : beans_log_record_field_value_len(record, index);
  std::string value(size, '\0');
  if (key) {
    beans_log_record_field_key_copy(
        record, index, reinterpret_cast<uint8_t*>(value.data()), value.size());
  } else {
    beans_log_record_field_value_copy(
        record, index, reinterpret_cast<uint8_t*>(value.data()), value.size());
  }
  return value;
}

int main(int argc, char** argv) {
  assert(argc == 2);
  std::string const text_path = std::string(argv[1]) + "/bridge.log";
  std::string const json_path = std::string(argv[1]) + "/bridge.ndjson";

  int64_t const text = file_sink(text_path);
  int64_t const json = json_sink(json_path);
  int64_t const exported = beans_log_export_sink(
      8, BEANS_LOG_EXPORT_DROP_NEWEST, BEANS_LOG_TRACE);
  assert(text != 0 && json != 0 && exported != 0);

  int64_t sinks[] = {text, json, exported};
  std::string const name = "bridge-test";
  int64_t const logger = beans_log_logger_create(
      reinterpret_cast<uint8_t const*>(name.data()), name.size(), sinks, 3,
      BEANS_LOG_TRACE, nullptr, 0);
  assert(logger != 0);
  assert(beans_log_logger_enabled(logger, BEANS_LOG_DEBUG) == 1);

  std::string const message = "hello \"beans\"\nsecond line";
  std::string const file = "test/cases/log.b";
  std::string const function = "main";
  assert(beans_log_write(
      logger, BEANS_LOG_INFO,
      reinterpret_cast<uint8_t const*>(message.data()), message.size(),
      reinterpret_cast<uint8_t const*>(file.data()), file.size(),
      reinterpret_cast<uint8_t const*>(function.data()), function.size(),
      17, 9) == 1);
  assert(beans_log_flush(logger) == 1);

  int64_t const record = beans_log_export_take(exported, 1000);
  assert(record != 0);
  assert(beans_log_record_level(record) == BEANS_LOG_INFO);
  assert(beans_log_record_line(record) == 17);
  assert(beans_log_record_column(record) == 9);
  assert(record_string(record, BEANS_LOG_RECORD_LOGGER) == name);
  assert(record_string(record, BEANS_LOG_RECORD_MESSAGE) == message);
  assert(record_string(record, BEANS_LOG_RECORD_FILE) == file);
  assert(record_string(record, BEANS_LOG_RECORD_FUNCTION) == function);
  beans_log_record_destroy(record);

  std::vector<uint8_t> fields;
  append_field(fields, "request_id", "42");
  append_field(fields, "note", "a\"b\n");
  std::string const structured = "structured";
  assert(beans_log_write_fields(
      logger, BEANS_LOG_INFO,
      reinterpret_cast<uint8_t const*>(structured.data()), structured.size(),
      reinterpret_cast<uint8_t const*>(file.data()), file.size(),
      reinterpret_cast<uint8_t const*>(function.data()), function.size(),
      18, 3, fields.data(), fields.size()) == 1);
  assert(beans_log_flush(logger) == 1);
  int64_t const structured_record = beans_log_export_take(exported, 1000);
  assert(structured_record != 0);
  assert(beans_log_record_line(structured_record) == 18);
  assert(beans_log_record_column(structured_record) == 3);
  assert(beans_log_record_field_count(structured_record) == 2);
  assert(record_field(structured_record, 0, true) == "request_id");
  assert(record_field(structured_record, 0, false) == "42");
  assert(record_field(structured_record, 1, true) == "note");
  assert(record_field(structured_record, 1, false) == "a\"b\n");
  beans_log_record_destroy(structured_record);

  std::string const text_output = read_all(text_path);
  assert(text_output.find("hello \"beans\"") != std::string::npos);
  assert(text_output.find("second line") != std::string::npos);
  assert(text_output.find("log.b:17") != std::string::npos);

  std::string const json_output = read_all(json_path);
  assert(json_output.find("\"message\":\"hello \\\"beans\\\"\\nsecond line\"") !=
         std::string::npos);
  assert(json_output.find("\"line\":17") != std::string::npos);
  assert(json_output.find("\"column\":9") != std::string::npos);
  assert(json_output.find(
      "\"fields\":{\"request_id\":\"42\",\"note\":\"a\\\"b\\n\"}") !=
         std::string::npos);
  assert(beans_log_backend_error_count() == 0);

  std::string const rotate_path = std::string(argv[1]) + "/rotate.log";
  int64_t const rotating = beans_log_rotating_file_sink(
      reinterpret_cast<uint8_t const*>(rotate_path.data()), rotate_path.size(),
      512, 2, 0, BEANS_LOG_TRACE);
  assert(rotating != 0);
  int64_t const rotate_logger = beans_log_logger_create(
      reinterpret_cast<uint8_t const*>("rotate"), 6, &rotating, 1,
      BEANS_LOG_TRACE, nullptr, 0);
  assert(rotate_logger != 0);
  std::string const large(700, 'x');
  assert(beans_log_write(
      rotate_logger, BEANS_LOG_INFO,
      reinterpret_cast<uint8_t const*>(large.data()), large.size(),
      nullptr, 0, nullptr, 0, 0, 0) == 1);
  assert(beans_log_write(
      rotate_logger, BEANS_LOG_INFO,
      reinterpret_cast<uint8_t const*>(large.data()), large.size(),
      nullptr, 0, nullptr, 0, 0, 0) == 1);
  assert(beans_log_flush(rotate_logger) == 1);
  assert(!read_all(std::string(argv[1]) + "/rotate.1.log").empty());

  int64_t const drop_newest = beans_log_export_sink(
      1, BEANS_LOG_EXPORT_DROP_NEWEST, BEANS_LOG_TRACE);
  std::string const drop_name = "drop-newest";
  int64_t const drop_logger = beans_log_logger_create(
      reinterpret_cast<uint8_t const*>(drop_name.data()), drop_name.size(),
      &drop_newest, 1, BEANS_LOG_TRACE, nullptr, 0);
  std::string const first = "first";
  std::string const second = "second";
  beans_log_write(drop_logger, BEANS_LOG_INFO,
                  reinterpret_cast<uint8_t const*>(first.data()), first.size(),
                  nullptr, 0, nullptr, 0, 0, 0);
  beans_log_write(drop_logger, BEANS_LOG_INFO,
                  reinterpret_cast<uint8_t const*>(second.data()), second.size(),
                  nullptr, 0, nullptr, 0, 0, 0);
  assert(beans_log_flush(drop_logger) == 1);
  int64_t dropped_record = beans_log_export_take(drop_newest, 1000);
  assert(record_string(dropped_record, BEANS_LOG_RECORD_MESSAGE) == first);
  beans_log_record_destroy(dropped_record);
  assert(beans_log_export_dropped(drop_newest) == 1);

  int64_t const drop_oldest = beans_log_export_sink(
      1, BEANS_LOG_EXPORT_DROP_OLDEST, BEANS_LOG_TRACE);
  std::string const oldest_name = "drop-oldest";
  int64_t const oldest_logger = beans_log_logger_create(
      reinterpret_cast<uint8_t const*>(oldest_name.data()), oldest_name.size(),
      &drop_oldest, 1, BEANS_LOG_TRACE, nullptr, 0);
  beans_log_write(oldest_logger, BEANS_LOG_INFO,
                  reinterpret_cast<uint8_t const*>(first.data()), first.size(),
                  nullptr, 0, nullptr, 0, 0, 0);
  beans_log_write(oldest_logger, BEANS_LOG_INFO,
                  reinterpret_cast<uint8_t const*>(second.data()), second.size(),
                  nullptr, 0, nullptr, 0, 0, 0);
  assert(beans_log_flush(oldest_logger) == 1);
  dropped_record = beans_log_export_take(drop_oldest, 1000);
  assert(record_string(dropped_record, BEANS_LOG_RECORD_MESSAGE) == second);
  beans_log_record_destroy(dropped_record);
  assert(beans_log_export_dropped(drop_oldest) == 1);

  int64_t const concurrent = beans_log_export_sink(
      2048, BEANS_LOG_EXPORT_DROP_NEWEST, BEANS_LOG_TRACE);
  std::string const concurrent_name = "concurrent";
  int64_t const concurrent_logger = beans_log_logger_create(
      reinterpret_cast<uint8_t const*>(concurrent_name.data()),
      concurrent_name.size(), &concurrent, 1, BEANS_LOG_TRACE, nullptr, 0);
  std::vector<std::thread> workers;
  for (int worker = 0; worker < 4; ++worker) {
    workers.emplace_back([=] {
      std::string const message = "worker-" + std::to_string(worker);
      for (int index = 0; index < 500; ++index) {
        assert(beans_log_write(
            concurrent_logger, BEANS_LOG_INFO,
            reinterpret_cast<uint8_t const*>(message.data()), message.size(),
            nullptr, 0, nullptr, 0, 0, 0) == 1);
      }
    });
  }
  for (auto& worker : workers) {
    worker.join();
  }
  assert(beans_log_flush(concurrent_logger) == 1);
  for (int index = 0; index < 2000; ++index) {
    int64_t const concurrent_record = beans_log_export_take(concurrent, 1000);
    assert(concurrent_record != 0);
    beans_log_record_destroy(concurrent_record);
  }
  assert(beans_log_export_dropped(concurrent) == 0);

  // A blocked exporter must not make normal process shutdown hang.
  int64_t const blocking = beans_log_export_sink(
      1, BEANS_LOG_EXPORT_BLOCK, BEANS_LOG_TRACE);
  std::string const blocking_name = "blocking";
  int64_t const blocking_logger = beans_log_logger_create(
      reinterpret_cast<uint8_t const*>(blocking_name.data()), blocking_name.size(),
      &blocking, 1, BEANS_LOG_TRACE, nullptr, 0);
  beans_log_write(blocking_logger, BEANS_LOG_INFO,
                  reinterpret_cast<uint8_t const*>(first.data()), first.size(),
                  nullptr, 0, nullptr, 0, 0, 0);
  beans_log_write(blocking_logger, BEANS_LOG_INFO,
                  reinterpret_cast<uint8_t const*>(second.data()), second.size(),
                  nullptr, 0, nullptr, 0, 0, 0);
  std::atomic<int64_t> blocked_flush{0};
  std::thread flusher([&] {
    blocked_flush.store(beans_log_flush(blocking_logger));
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  assert(beans_log_shutdown() == 1);
  flusher.join();
  assert(blocked_flush.load() == 1);
  assert(beans_log_shutdown() == 1);
  assert(beans_log_write(
      logger, BEANS_LOG_INFO,
      reinterpret_cast<uint8_t const*>(first.data()), first.size(),
      nullptr, 0, nullptr, 0, 0, 0) == 0);
  assert(beans_log_last_error_len() != 0);
  return 0;
}
