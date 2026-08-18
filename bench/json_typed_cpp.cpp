#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "runtime/encoding/vendor/yyjson/yyjson.h"

struct Row {
    uint64_t id = 0;
    uint64_t user_id = 0;
    bool active = false;
    double score = 0;
    std::string name;
    std::optional<std::string> note;
};

static uint64_t nanos() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

static int field_index(yyjson_val* key) {
    const char* name = yyjson_get_str(key);
    size_t length = yyjson_get_len(key);
    if (length == 2 && std::memcmp(name, "id", 2) == 0) return 0;
    if (length == 6 && std::memcmp(name, "userId", 6) == 0) return 1;
    if (length == 6 && std::memcmp(name, "active", 6) == 0) return 2;
    if (length == 5 && std::memcmp(name, "score", 5) == 0) return 3;
    if (length == 4 && std::memcmp(name, "name", 4) == 0) return 4;
    if (length == 4 && std::memcmp(name, "note", 4) == 0) return 5;
    return -1;
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    FILE* file = std::fopen(argv[1], "rb");
    if (!file) return 2;
    std::fseek(file, 0, SEEK_END);
    long length_word = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    size_t length = static_cast<size_t>(length_word);
    std::vector<char> input(length);
    if (std::fread(input.data(), 1, length, file) != length) return 2;
    std::fclose(file);

    uint64_t started = nanos();
    yyjson_doc* doc = yyjson_read(input.data(), length, 0);
    if (!doc) return 3;
    yyjson_val* root = yyjson_doc_get_root(doc);
    if (!yyjson_is_arr(root)) return 4;
    std::vector<Row> rows;
    rows.reserve(yyjson_arr_size(root));
    yyjson_arr_iter array;
    yyjson_arr_iter_init(root, &array);
    yyjson_val* object;
    while ((object = yyjson_arr_iter_next(&array)) != nullptr) {
        if (!yyjson_is_obj(object)) return 4;
        Row row;
        uint64_t seen = 0;
        yyjson_obj_iter fields;
        yyjson_obj_iter_init(object, &fields);
        yyjson_val* key;
        while ((key = yyjson_obj_iter_next(&fields)) != nullptr) {
            int field = field_index(key);
            if (field < 0 || (seen & (UINT64_C(1) << field))) return 4;
            seen |= UINT64_C(1) << field;
            yyjson_val* value = yyjson_obj_iter_get_val(key);
            switch (field) {
                case 0:
                    if (!yyjson_is_uint(value)) return 4;
                    row.id = yyjson_get_uint(value);
                    break;
                case 1:
                    if (!yyjson_is_uint(value)) return 4;
                    row.user_id = yyjson_get_uint(value);
                    break;
                case 2:
                    if (!yyjson_is_bool(value)) return 4;
                    row.active = yyjson_get_bool(value);
                    break;
                case 3:
                    if (!yyjson_is_num(value)) return 4;
                    row.score = yyjson_get_num(value);
                    break;
                case 4:
                    if (!yyjson_is_str(value)) return 4;
                    row.name.assign(yyjson_get_str(value), yyjson_get_len(value));
                    break;
                case 5:
                    if (yyjson_is_null(value)) break;
                    if (!yyjson_is_str(value)) return 4;
                    row.note.emplace(yyjson_get_str(value), yyjson_get_len(value));
                    break;
            }
        }
        if ((seen & UINT64_C(0x1f)) != UINT64_C(0x1f)) return 4;
        rows.push_back(std::move(row));
    }
    yyjson_doc_free(doc);
    uint64_t elapsed = nanos() - started;

    uint64_t checksum = 0;
    for (const Row& row : rows) {
        checksum += row.id + row.user_id + row.active + row.name.size();
        if (row.note) checksum += row.note->size();
    }
    uint64_t mib_s = static_cast<uint64_t>(length) * UINT64_C(1000000000) /
                     (elapsed ? elapsed : 1) / UINT64_C(1048576);
    uint64_t records_s = static_cast<uint64_t>(rows.size()) *
                         UINT64_C(1000000000) / (elapsed ? elapsed : 1);
    std::printf("cpp_yyjson_strict size=%zu records=%zu nanos=%llu mib_s=%llu records_s=%llu checksum=%llu\n",
                length, rows.size(), (unsigned long long)elapsed,
                (unsigned long long)mib_s, (unsigned long long)records_s,
                (unsigned long long)checksum);
    return 0;
}
