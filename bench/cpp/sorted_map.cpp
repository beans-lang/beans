#include "common.h"

#include <cstdint>
#include <iostream>
#include <map>
#include <vector>

// Twin for bench/sorted_map.b: std::map, a red-black tree, over the same
// operation stream and the same checksum. `set` is `m[key] = value` — no
// insert hint, because SortedMap.set takes none and the ascending fill is
// exactly the case a hint would erase. `get` is `find`, which is what an
// Option-returning lookup costs; `ceiling_key` is `lower_bound`; the ordered
// scan copies the keys out into a reserved vector, matching SortedMap.keys().
//
// BEANS_MATCHED only reaches the scan: Beans' List index is bounds-checked, so
// the matched build reads through vector::at(). Every map operation here is
// already the safe one on both sides.

static inline std::int64_t scatter(std::int64_t index) {
    const std::uint64_t mixed =
        static_cast<std::uint64_t>(index) * 2654435761ULL & 1099511627775ULL;
    return static_cast<std::int64_t>(mixed ^ (mixed >> 20));
}

int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 400000);
    const auto seed = bench_arg(argc, argv, 1, 1);
    std::uint64_t checksum = 0;
    std::uint64_t weight = 1;

    // 1. Ascending fill.
    std::map<std::int64_t, std::int64_t> series;
    for (std::int64_t i = 0; i < n; ++i) series[i] = i + seed;
    checksum += static_cast<std::uint64_t>(series.size()) * weight;
    weight += 2654435761ULL;

    // 2. Scattered fill.
    std::map<std::int64_t, std::int64_t> index;
    for (std::int64_t i = 0; i < n; ++i) index[scatter(i)] = i + seed;
    checksum += static_cast<std::uint64_t>(index.size()) * weight;
    weight += 2654435761ULL;

    // 3. Point lookups, half of which miss.
    for (std::int64_t i = 0; i < n; ++i) {
        const auto found = index.find(scatter(i * 2));
        const std::int64_t value = found == index.end() ? 0 : found->second;
        checksum += static_cast<std::uint64_t>(value) * weight;
        weight += 2654435761ULL;
    }

    // 4. Neighbour queries on keys that are not members.
    for (std::int64_t i = 0; i < n; ++i) {
        const auto found = index.lower_bound(scatter(i) + 1);
        const std::int64_t key = found == index.end() ? -1 : found->first;
        checksum += static_cast<std::uint64_t>(key) * weight;
        weight += 2654435761ULL;
    }

    // 5. Ordered scan.
    std::vector<std::int64_t> keys;
    keys.reserve(series.size());
    for (const auto& entry : series) keys.push_back(entry.first);
    for (std::size_t i = 0; i < keys.size(); ++i) {
#ifdef BEANS_MATCHED
        checksum += static_cast<std::uint64_t>(keys.at(i)) * weight;
#else
        checksum += static_cast<std::uint64_t>(keys[i]) * weight;
#endif
        weight += 2654435761ULL;
    }

    // 6. Remove half the scattered map.
    std::int64_t removed = 0;
    for (std::int64_t i = 0; i < n / 2; ++i)
        if (index.erase(scatter(i * 2))) ++removed;
    checksum += static_cast<std::uint64_t>(removed) * weight;
    weight += 2654435761ULL;

    // 7. Scan what survived, so unlinking the wrong key cannot hide behind a
    //    right-looking count.
    std::vector<std::int64_t> left;
    left.reserve(index.size());
    for (const auto& entry : index) left.push_back(entry.first);
    for (std::size_t i = 0; i < left.size(); ++i) {
#ifdef BEANS_MATCHED
        checksum += static_cast<std::uint64_t>(left.at(i)) * weight;
#else
        checksum += static_cast<std::uint64_t>(left[i]) * weight;
#endif
        weight += 2654435761ULL;
    }
    checksum += static_cast<std::uint64_t>(index.size()) * weight;

    std::cout << "sorted_map " << static_cast<std::int64_t>(checksum) << ' '
              << series.size() << ' ' << index.size() << '\n';
}
