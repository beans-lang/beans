#include "common.h"

#include <cstdint>
#include <deque>
#include <iostream>

int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 2000000);
    std::int64_t checksum = 0;

    // 1. FIFO stream.
    std::deque<std::int64_t> fifo;
    for (std::int64_t i = 0; i < n; ++i) fifo.push_back(i);
    while (!fifo.empty()) {
        const std::int64_t v = fifo.front();
        fifo.pop_front();
        checksum = (checksum * 31 + v) % 1000000007;
    }

    // 2. Sliding window of 1024.
    std::deque<std::int64_t> window;
    for (std::int64_t i = 0; i < n; ++i) {
        window.push_back(i);
        if (static_cast<std::int64_t>(window.size()) > 1024) {
            const std::int64_t v = window.front();
            window.pop_front();
            checksum = (checksum + v) % 1000000007;
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
        checksum = (checksum * 7 + got) % 1000000007;
    }

    // 4. Random access. Beans' `get` bounds-checks, so the matched build reads
    //    through std::deque::at(); the tuned build uses operator[].
    std::deque<std::int64_t> ra;
    for (std::int64_t i = 0; i < n; ++i) ra.push_back(i);
    std::int64_t x = 1;
    for (std::int64_t i = 0; i < n; ++i) {
        x = (x * 48271) % 2147483647;
        const std::int64_t idx = x % n;
#ifdef BEANS_MATCHED
        const std::int64_t v = ra.at(static_cast<std::size_t>(idx));
#else
        const std::int64_t v = ra[static_cast<std::size_t>(idx)];
#endif
        checksum = (checksum + v) % 1000000007;
    }

    std::cout << "deque " << checksum << '\n';
}
