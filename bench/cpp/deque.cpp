#include "common.h"

#include <cstdint>
#include <deque>
#include <iostream>

// Twin for bench/deque.b. The checksum is the same position-weighted product
// folded into a wrapping sum, computed here in std::uint64_t so the wrap is
// defined; Beans' `int` is a wrapping two's-complement 64-bit integer, so the
// two agree bit for bit and the printed value is the same signed number.

int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 2000000);
    std::uint64_t checksum = 0;
    std::uint64_t weight = 1;

    // 1. FIFO stream.
    std::deque<std::int64_t> fifo;
    for (std::int64_t i = 0; i < n; ++i) fifo.push_back(i);
    while (!fifo.empty()) {
        const std::int64_t v = fifo.front();
        fifo.pop_front();
        checksum += static_cast<std::uint64_t>(v) * weight;
        weight += 2654435761ULL;
    }

    // 2. Sliding window of 1024.
    std::deque<std::int64_t> window;
    for (std::int64_t i = 0; i < n; ++i) {
        window.push_back(i);
        if (static_cast<std::int64_t>(window.size()) > 1024) {
            const std::int64_t v = window.front();
            window.pop_front();
            checksum += static_cast<std::uint64_t>(v) * weight;
            weight += 2654435761ULL;
        }
    }

    // 3. Both ends.
    std::deque<std::int64_t> both;
    for (std::int64_t i = 0; i < n; ++i) {
        if (i % 2 == 0) both.push_front(i); else both.push_back(i);
    }
    for (std::int64_t i = 0; i < n; ++i) {
        std::int64_t got = 0;
        if (i % 3 == 0) { if (!both.empty()) { got = both.front(); both.pop_front(); } }
        else { if (!both.empty()) { got = both.back(); both.pop_back(); } }
        checksum += static_cast<std::uint64_t>(got) * weight;
        weight += 2654435761ULL;
    }

    // 4. Random access. Beans' `get` bounds-checks, so the matched build reads
    //    through std::deque::at(); the tuned build uses operator[]. The index
    //    stream is the same wrapping LCG and multiply-shift.
    std::deque<std::int64_t> ra;
    for (std::int64_t i = 0; i < n; ++i) ra.push_back(i);
    std::uint64_t x = 1;
    for (std::int64_t i = 0; i < n; ++i) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        const std::int64_t idx = static_cast<std::int64_t>(
            ((x >> 33) & 2147483647ULL) * static_cast<std::uint64_t>(n) >> 31);
#ifdef BEANS_MATCHED
        const std::int64_t v = ra.at(static_cast<std::size_t>(idx));
#else
        const std::int64_t v = ra[static_cast<std::size_t>(idx)];
#endif
        checksum += static_cast<std::uint64_t>(v) * weight;
        weight += 2654435761ULL;
    }

    std::cout << "deque " << static_cast<std::int64_t>(checksum) << '\n';
}
