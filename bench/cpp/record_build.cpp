#include "common.h"

#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

// The five tags are string literals in the Beans source, which are immortal
// statics: reading one costs nothing and allocates nothing. Both C++ builds
// mirror that — the tuned one copies from a static table, the matched one
// shares five process-lifetime control blocks — so the comparison is about the
// record's own strings and its tag list, not about how each language spells a
// constant.
static const char* const kTags[5] = {"alpha", "beta", "gamma", "delta",
                                     "epsilon"};

#ifdef BEANS_MATCHED
// Beans' representation, spelled in C++: a string is a refcounted heap object
// and so is a list, and a list of strings is a refcount over refcounts.
using Str = std::shared_ptr<std::string>;
using Tags = std::shared_ptr<std::vector<Str>>;

static const Str& tag_at(std::int64_t index) {
    static const Str table[5] = {
        std::make_shared<std::string>(kTags[0]),
        std::make_shared<std::string>(kTags[1]),
        std::make_shared<std::string>(kTags[2]),
        std::make_shared<std::string>(kTags[3]),
        std::make_shared<std::string>(kTags[4]),
    };
    return table[index % 5];
}
static Str own(std::string text) {
    return std::make_shared<std::string>(std::move(text));
}
static std::size_t size_of(const Str& s) { return s->size(); }
static Tags make_tags(std::int64_t index) {
    auto tags = std::make_shared<std::vector<Str>>();
    tags->reserve(3);
    tags->push_back(tag_at(index));
    tags->push_back(tag_at(index + 2));
    tags->push_back(tag_at(index + 4));
    return tags;
}
static std::size_t tag_count(const Tags& t) { return t->size(); }
#else
using Str = std::string;
using Tags = std::vector<Str>;

static Str tag_at(std::int64_t index) { return Str(kTags[index % 5]); }
static Str own(std::string text) { return text; }
static std::size_t size_of(const Str& s) { return s.size(); }
static Tags make_tags(std::int64_t index) {
    Tags tags;
    tags.reserve(3);
    tags.push_back(tag_at(index));
    tags.push_back(tag_at(index + 2));
    tags.push_back(tag_at(index + 4));
    return tags;
}
static std::size_t tag_count(const Tags& t) { return t.size(); }
#endif

struct Record {
    std::int64_t id;
    Str name;
    Str email;
    bool active;
    std::int64_t score;
    Tags tags;
    Str note;
    std::int64_t balance;
};

static Record make_record(std::int64_t index) {
    Record record;
    record.id = index;
    record.name = own("record-" + std::to_string(index));
    record.email = own("user" + std::to_string(index) + "@example.com");
    record.active = index % 3 == 0;
    record.score = (index * 2654435761) % 100000;
    record.tags = make_tags(index);
    record.note = own("record " + std::to_string(index) +
                      ": the quick brown fox jumps over the lazy dog while "
                      "the barista pulls a double ristretto shot");
    record.balance = (index * 7919) % 1000000;
    return record;
}

int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 400000);
    const auto seed = bench_arg(argc, argv, 1, 1);
    std::vector<Record> keep;
    keep.reserve(static_cast<std::size_t>(n / 1000 + 1));
    std::int64_t bytes = 0;
    std::int64_t total = 0;
    for (std::int64_t i = 0; i < n; ++i) {
        Record record = make_record(i + seed);
        bytes += static_cast<std::int64_t>(size_of(record.name)) +
                 static_cast<std::int64_t>(size_of(record.email)) +
                 static_cast<std::int64_t>(size_of(record.note));
        total += record.id + record.score + record.balance +
                 static_cast<std::int64_t>(tag_count(record.tags));
        if (record.active) total += 1;
        // No bench_escape here: the three string sizes above are read into
        // `bytes`, which is printed, so the record's own allocations are
        // already observable and eliding them would change the output. Adding
        // a memory clobber to 999 of every 1000 iterations would cost the C++
        // side work the Beans side does not do.
        if (i % 1000 == 0) keep.push_back(std::move(record));
    }
    std::cout << "bytes " << bytes << " total " << total << " kept "
              << keep.size() << '\n';
}
