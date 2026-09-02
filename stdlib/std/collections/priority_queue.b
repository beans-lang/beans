// "What happens next" — an expiry wheel, a scheduler, a Dijkstra frontier.
// A sorted list gives the same answer and pays O(n) for every insert; a heap
// pays O(log n) and never sorts what it is not asked about.

package collections

/// A binary min-heap keyed on a separate priority: the smallest priority comes
/// out first.
///
/// ```
/// var expiring: collections.PriorityQueue<int, string> = new()
/// expiring.push(deadline_nanos, "session:42")
/// match expiring.peek_priority() {
///     some(due) => { if due <= now { expiring.pop() } }
///     none => {}
/// }
/// ```
///
/// The priority and the payload are separate type parameters on purpose. Only
/// `Order` types compare — the numbers, `bool` and `string` — so a queue over
/// one comparable type could not carry a class, a struct or a list as its
/// payload. Splitting them means the thing being ordered is always something
/// the language can order, and the thing being carried is anything at all.
///
/// **Ties keep push order.** Two entries pushed with the same priority come
/// out in the order they went in, because every entry carries the sequence
/// number of its push and that number breaks ties. A heap does not give this
/// for free; it is worth the one extra `int` per entry, because "no defined
/// order" turns into a bug the day two deadlines land on the same nanosecond.
///
/// For largest-first over a numeric priority, push the negated value. There is
/// no reversing flag: one shape, no ambiguity about which end `pop` takes.
///
/// `P` must be `Order & Clone` and `V` must be `Clone`, because both are read
/// back out; a move-only payload such as `Bytes` is refused.
///
/// **Storage is one list of entries, sifted with a hole.** Priority, payload
/// and sequence travel together in a single `Entry`, so one bounds check reads
/// a whole entry and one write stores one. `push` and `pop` do not swap; they
/// carve a hole where the removed entry was and slide parents or children into
/// it, one entry read and one entry write per level, and drop the held entry
/// in once at the end. `push` and `pop` are O(log n); `peek`, `peek_priority`,
/// `len` and `is_empty` are O(1). A comparison reads only the priority and the
/// sequence of the two entries it is handed and never touches the payload, so
/// ordering an `<int, string>` queue never retains a string.
pub class PriorityQueue<P implements Order & Clone, V implements Clone> {
    entries: List<Entry<P, V>> = []
    next_sequence: int = 0

    /// An empty queue.
    pub fn init() {}

    /// Add `value` under `priority`. O(log n): the new entry is appended and
    /// sifted toward the root through a hole until a parent it does not sort
    /// before stops it.
    pub fn push(priority: P, value: V) {
        let entry: Entry<P, V> = Entry {
            priority: priority,
            value: value,
            sequence: self.next_sequence,
        }
        self.next_sequence += 1
        self.entries.push(entry)
        let last: int = self.entries.len() - 1
        var hole: int = last
        for hole > 0 {
            let parent: int = (hole - 1) / 2
            if !self.sorts_before(entry, self.entries[parent]) { break }
            self.entries[hole] = self.entries[parent]
            hole = parent
        }
        // `push` already left an equal copy at `last`, so only write the held
        // entry back when the hole actually moved.
        if hole != last {
            self.entries[hole] = entry
        }
    }

    /// The smallest-priority value, without removing it. O(1).
    pub fn peek() -> Option<V> {
        if self.entries.len() == 0 { return none }
        return some(self.entries[0].value)
    }

    /// The smallest priority, without removing its entry. This is the "when
    /// does the next thing happen" question, answered without taking it. O(1).
    pub fn peek_priority() -> Option<P> {
        if self.entries.len() == 0 { return none }
        return some(self.entries[0].priority)
    }

    /// Remove and answer the smallest-priority value. O(log n): the tail entry
    /// is lifted out and sifted down from the root through a hole, each level
    /// taking the smaller child, until neither child sorts before it.
    pub fn pop() -> Option<V> {
        if self.entries.len() == 0 { return none }
        let top: V = self.entries[0].value
        match self.entries.pop() {
            some(last) => {
                let count: int = self.entries.len()
                if count > 0 {
                    var hole: int = 0
                    for {
                        var child: int = hole * 2 + 1
                        if child >= count { break }
                        let right: int = child + 1
                        if right < count && self.sorts_before(self.entries[right], self.entries[child]) {
                            child = right
                        }
                        if !self.sorts_before(self.entries[child], last) { break }
                        self.entries[hole] = self.entries[child]
                        hole = child
                    }
                    // The root slot still holds the entry just returned; the
                    // held tail entry always lands, even when it stays at 0.
                    self.entries[hole] = last
                }
            }
            none => {}
        }
        return some(top)
    }

    /// How many entries. O(1).
    pub fn len() -> int {
        return self.entries.len()
    }

    /// True while the queue holds nothing. O(1).
    pub fn is_empty() -> bool {
        return self.entries.len() == 0
    }

    /// Drop every entry. The push counter keeps running, so tie order stays
    /// consistent across a clear.
    pub fn clear() {
        self.entries.clear()
    }

    // `left` sorts before `right`: smaller priority first, and among equal
    // priorities the earlier push. Reads only the priority and the sequence of
    // the two entries, so it never retains a payload; both entries arrive as
    // borrows, so no entry is copied to compare it.
    fn sorts_before(left: Entry<P, V>, right: Entry<P, V>) -> bool {
        if left.priority < right.priority { return true }
        if right.priority < left.priority { return false }
        return left.sequence < right.sequence
    }
}

// Priority, payload and sequence in one cache line's worth of struct, so a
// single indexed read or write moves a whole heap entry. Module-private: it is
// the queue's storage, not part of its surface.
struct Entry<P, V> {
    priority: P
    value: V
    sequence: int
}
