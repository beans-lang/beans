#include "common.h"

#include <cstdint>
#include <iostream>
#include <queue>
#include <vector>

// The heap entry the Beans PriorityQueue carries: priority, the push sequence
// that breaks ties FIFO, and the payload. `Later` makes std::priority_queue a
// min-heap by (priority, sequence), so its top is the same entry Beans pops.
struct Entry {
    std::int64_t priority;
    std::int64_t seq;
    std::int64_t value;
};

struct Later {
    bool operator()(const Entry& a, const Entry& b) const {
        if (a.priority != b.priority) return a.priority > b.priority;
        return a.seq > b.seq;
    }
};

// The workload is method calls only — push, pop, top, size — with no
// user-level indexing, so there is no `[]` to turn into `.at()`: the tuned and
// matched builds share this one path over the standard std::priority_queue.
// (BEANS_MATCHED is defined by the runner for the matched build; it changes
// nothing here because the Beans program indexes nothing either.)
int main(int argc, char** argv) {
    const auto n = bench_arg(argc, argv, 0, 1000000);
    const auto seed = bench_arg(argc, argv, 1, 1);
    std::int64_t checksum = 0;
    std::int64_t x = 1 + (seed % 2147483646);

    // 1. Fill with n random priorities, then drain in full.
    std::priority_queue<Entry, std::vector<Entry>, Later> q;
    std::int64_t seq = 0;
    for (std::int64_t i = 0; i < n; ++i) {
        x = (x * 48271) % 2147483647;
        q.push({x % 1000000, seq++, i});
    }
    while (!q.empty()) {
        const std::int64_t v = q.top().value;
        q.pop();
        checksum = (checksum * 31 + v) % 1000000007;
    }

    // 2. Scheduler: pop the due entry while more than 1024 remain live.
    std::priority_queue<Entry, std::vector<Entry>, Later> sched;
    seq = 0;
    for (std::int64_t i = 0; i < n; ++i) {
        x = (x * 48271) % 2147483647;
        sched.push({x % 1000000, seq++, i});
        if (static_cast<std::int64_t>(sched.size()) > 1024) {
            const std::int64_t v = sched.top().value;
            sched.pop();
            checksum = (checksum + v) % 1000000007;
        }
    }

    std::cout << "priority_queue " << checksum << ' ' << sched.size() << '\n';
}
