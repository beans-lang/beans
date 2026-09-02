#include "common.h"

#include <cstdint>
#include <iostream>
#include <string>
#include <unordered_set>

// Twin for bench/sets.b: std::unordered_set with the same operation stream and
// the same checksum. BEANS_MATCHED changes nothing here on purpose — a
// membership set is probed with count()/insert()/erase(), which have no
// unchecked variant a tuned build could use and a safe build would give up, the
// way vector::operator[] versus at() differ. Beans' Set does no element
// indexing either, so the tuned and the matched twin are the same program.

// The same bijection bench/sets.b uses to build the two algebra sets, so both
// sides hold identical members. Consecutive keys are a special case for this
// container: std::hash<int64_t> is the identity, so they never collide, and
// libc++'s __constrain_hash answers `h < bucket_count() ? h : h % bucket_count()`,
// so small ones skip the modulo entirely. See the comment in sets.b.
static inline int64_t scatter(int64_t index) {
    const uint64_t mixed =
        static_cast<uint64_t>(index) * 2654435761ULL & 1099511627775ULL;
    return static_cast<int64_t>(mixed ^ (mixed >> 20));
}

int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 1000000);
    const auto seed = bench_arg(argc, argv, 1, 1);
    int64_t x = 1 + (seed % 2147483646);

    std::unordered_set<int64_t> s;
    int64_t added = 0;
    for (int64_t i = 0; i < n; ++i) {
        x = (x * 48271) % 2147483647;
        if (s.insert(x % (n * 2)).second) ++added;
    }

    int64_t hits = 0;
    for (int64_t i = 0; i < n * 2; ++i)
        if (s.count(i)) ++hits;

    int64_t removed = 0;
    for (int64_t i = 0; i < n; ++i)
        if (s.erase(i * 2)) ++removed;

    std::unordered_set<int64_t> a, b;
    for (int64_t i = 0; i < n / 4; ++i) {
        a.insert(scatter(i));
        b.insert(scatter(i + n / 8));
    }
    // union: clone the larger, insert the smaller — the same shape Set uses.
    std::unordered_set<int64_t> u(a.size() >= b.size() ? a : b);
    {
        const auto& small = a.size() >= b.size() ? b : a;
        for (auto v : small) u.insert(v);
    }
    std::unordered_set<int64_t> inter;
    {
        const auto& small = a.size() <= b.size() ? a : b;
        const auto& large = a.size() <= b.size() ? b : a;
        for (auto v : small)
            if (large.count(v)) inter.insert(v);
    }
    std::unordered_set<int64_t> diff;
    for (auto v : a)
        if (!b.count(v)) diff.insert(v);
    std::unordered_set<int64_t> sym;
    for (auto v : a)
        if (!b.count(v)) sym.insert(v);
    for (auto v : b)
        if (!a.count(v)) sym.insert(v);
    bool sub = true;
    for (auto v : inter)
        if (!a.count(v)) {
            sub = false;
            break;
        }

    std::unordered_set<std::string> names;
    for (int64_t i = 0; i < n / 4; ++i)
        names.insert("key-" + std::to_string(i % (n / 8)));
    int64_t shits = 0;
    for (int64_t i = 0; i < n / 4; ++i)
        if (names.count("key-" + std::to_string(i))) ++shits;

    const int64_t checksum = added * 7 + hits * 11 + removed * 13 +
        static_cast<int64_t>(s.size()) * 17 + static_cast<int64_t>(u.size()) * 19 +
        static_cast<int64_t>(inter.size()) * 23 + static_cast<int64_t>(diff.size()) * 29 +
        static_cast<int64_t>(sym.size()) * 31 + (sub ? 1 : 0) + shits * 37 +
        static_cast<int64_t>(names.size()) * 41;
    std::cout << "sets " << checksum << '\n';
}
