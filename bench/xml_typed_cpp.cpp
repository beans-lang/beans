#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "runtime/encoding/vendor/pugixml/pugixml.hpp"

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

static bool uint_value(const char* text, uint64_t& value) {
    size_t length = std::strlen(text);
    auto parsed = std::from_chars(text, text + length, value);
    return parsed.ec == std::errc() && parsed.ptr == text + length;
}

static bool double_value(const char* text, double& value) {
    size_t length = std::strlen(text);
    auto parsed = std::from_chars(text, text + length, value);
    return parsed.ec == std::errc() && parsed.ptr == text + length &&
           std::isfinite(value);
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
    pugi::xml_document document;
    pugi::xml_parse_result parsed = document.load_buffer(
        input.data(), input.size(), pugi::parse_default, pugi::encoding_utf8);
    if (!parsed) return 3;
    pugi::xml_node root = document.document_element();
    if (std::strcmp(root.name(), "rows") != 0) return 4;
    std::vector<Row> rows;
    size_t count = 0;
    for (pugi::xml_node child = root.first_child(); child;
         child = child.next_sibling())
        if (child.type() == pugi::node_element) ++count;
    rows.reserve(count);

    for (pugi::xml_node node = root.first_child(); node;
         node = node.next_sibling()) {
        if (node.type() != pugi::node_element) continue;
        if (std::strcmp(node.name(), "row") != 0) return 4;
        Row row;
        uint64_t seen = 0;
        for (pugi::xml_attribute attribute = node.first_attribute(); attribute;
             attribute = attribute.next_attribute()) {
            uint64_t bit = 0;
            if (std::strcmp(attribute.name(), "id") == 0) {
                bit = UINT64_C(1) << 0;
                if (!uint_value(attribute.value(), row.id)) return 4;
            } else if (std::strcmp(attribute.name(), "userId") == 0) {
                bit = UINT64_C(1) << 1;
                if (!uint_value(attribute.value(), row.user_id)) return 4;
            } else return 4;
            if (seen & bit) return 4;
            seen |= bit;
        }
        for (pugi::xml_node field = node.first_child(); field;
             field = field.next_sibling()) {
            if (field.type() != pugi::node_element) continue;
            uint64_t bit = 0;
            const char* value = field.child_value();
            if (std::strcmp(field.name(), "active") == 0) {
                bit = UINT64_C(1) << 2;
                if (std::strcmp(value, "true") == 0) row.active = true;
                else if (std::strcmp(value, "false") == 0) row.active = false;
                else return 4;
            } else if (std::strcmp(field.name(), "score") == 0) {
                bit = UINT64_C(1) << 3;
                if (!double_value(value, row.score)) return 4;
            } else if (std::strcmp(field.name(), "name") == 0) {
                bit = UINT64_C(1) << 4;
                row.name.assign(value);
            } else if (std::strcmp(field.name(), "note") == 0) {
                bit = UINT64_C(1) << 5;
                row.note.emplace(value);
            } else return 4;
            if (seen & bit) return 4;
            seen |= bit;
        }
        if ((seen & UINT64_C(0x1f)) != UINT64_C(0x1f)) return 4;
        rows.push_back(std::move(row));
    }
    document.reset();
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
    std::printf("cpp_pugixml_strict size=%zu records=%zu nanos=%llu mib_s=%llu records_s=%llu checksum=%llu\n",
                length, rows.size(), (unsigned long long)elapsed,
                (unsigned long long)mib_s, (unsigned long long)records_s,
                (unsigned long long)checksum);
    return 0;
}
