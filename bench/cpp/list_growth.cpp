#include "common.h"

#include <cstdint>
#include <iostream>
#include <vector>

int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 40000000);
    const auto seed = bench_arg(argc, argv, 1, 1);
    const std::int64_t chunk = 200000;
    std::int64_t rounds = n / chunk;
    if (rounds < 1) rounds = 1;
    std::int64_t checksum = 0;
    for (std::int64_t round = 0; round < rounds; ++round) {
        std::vector<std::int64_t> xs;
        for (std::int64_t i = 0; i < chunk; ++i) xs.push_back(i + seed);
#ifdef BEANS_MATCHED
        checksum += static_cast<std::int64_t>(xs.size()) +
                    xs.at(static_cast<std::size_t>(chunk / 2)) + round;
#else
        checksum += static_cast<std::int64_t>(xs.size()) +
                    xs[static_cast<std::size_t>(chunk / 2)] + round;
#endif
        std::int64_t drained = 0;
        while (!xs.empty()) {
            drained ^= xs.back();
            xs.pop_back();
        }
        checksum += drained % 1000003;
    }
    std::cout << "list_growth " << checksum << ' ' << rounds << ' ' << chunk
              << '\n';
}
