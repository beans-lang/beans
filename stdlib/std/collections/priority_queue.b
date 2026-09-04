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
///
/// **Reads answer from a published view, not from the heap mid-sift.** A user's
/// `deinit` can run in the middle of a `push` or a `pop`: the cycle collector
/// runs deinits, an allocation is where it runs, and a sift allocates — under
/// the tree interpreter essentially every operation does. A sift moves the heap
/// through a hole, so between its first write and its last the root slot holds a
/// stale entry and `entries.len()` has already changed; `len()` and `peek()`
/// reading the heap directly would see a queue whose count and whose smallest
/// disagree. That was #92. So `len()`, `peek()` and `peek_priority()` never read
/// the heap. They read `view`, a small object holding the settled count and a
/// copy of the settled smallest entry together, and a `push` or a `pop`
/// rearranges the heap first and then republishes `view` with a single store.
/// Before that store the queue is entirely its old shape and after it entirely
/// the new one; there is no half-sifted state a reader can find, because a
/// reader never looks at the heap. The copy is one entry per `push` or `pop`,
/// which the sift's own per-level entry moves already dwarf.
pub class PriorityQueue<P implements Order & Clone, V implements Clone> {
    // The working heap. No reader reads this: a `push` or a `pop` rearranges it
    // through a hole and leaves it torn at every allocation inside that loop.
    // Reads answer from `view` instead.
    entries: List<Entry<P, V>> = []
    // The settled count and the settled smallest entry, together, so one store
    // publishes both. A reader caught between two heap writes sees the `view`
    // from before the operation — the whole old shape — until the final store
    // swaps in the whole new one.
    view: PqView<P, V> = new()
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
        // The heap is a heap again; publish its new count and smallest in one
        // store, so no reader ever saw the sift in flight.
        self.view = self.snapshot()
    }

    /// The smallest-priority value, without removing it. O(1).
    pub fn peek() -> Option<V> {
        match self.view.top {
            some(entry) => { return some(entry.value) }
            none => { return none }
        }
    }

    /// The smallest priority, without removing its entry. This is the "when
    /// does the next thing happen" question, answered without taking it. O(1).
    pub fn peek_priority() -> Option<P> {
        match self.view.top {
            some(entry) => { return some(entry.priority) }
            none => { return none }
        }
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
        // The heap is settled; publish the smaller count and the new smallest
        // together, so a reader never saw `len()` drop before the root did.
        self.view = self.snapshot()
        return some(top)
    }

    /// How many entries. O(1).
    pub fn len() -> int {
        return self.view.count
    }

    /// True while the queue holds nothing. O(1).
    pub fn is_empty() -> bool {
        return self.view.count == 0
    }

    /// Drop every entry. The push counter keeps running, so tie order stays
    /// consistent across a clear.
    pub fn clear() {
        // Publish the empty view before dropping anything, so an element's
        // `deinit` running as the heap releases it reads the count it will have
        // — empty — rather than the old count over storage already going away.
        self.view = new()
        self.entries.clear()
    }

    // The published answer to every read: the settled heap's size and a copy of
    // its smallest entry, held together so a reader decodes them from one
    // object. Built only when the heap is a valid heap again and swapped in with
    // one store, so `len()`, `peek()` and `peek_priority()` never decode a
    // half-sifted heap. The copy is a plain field-by-field read of `entries[0]`,
    // which leaves the heap slot intact.
    fn snapshot() -> PqView<P, V> {
        var next: PqView<P, V> = new()
        next.count = self.entries.len()
        if next.count > 0 {
            next.top = some(Entry {
                priority: self.entries[0].priority,
                value: self.entries[0].value,
                sequence: self.entries[0].sequence,
            })
        }
        return move next
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

// The published view of a settled queue: how many entries it holds and a copy
// of its smallest, together, so a `push` or a `pop` swaps both in with one
// store and a reader between the heap writes never sees a count that disagrees
// with the smallest. Module-private: it is how the queue answers, not part of
// its surface.
class PqView<P implements Order & Clone, V implements Clone> {
    count: int = 0
    top: Option<Entry<P, V>> = none
    pub fn init() {}
}

// Priority, payload and sequence in one cache line's worth of struct, so a
// single indexed read or write moves a whole heap entry. Module-private: it is
// the queue's storage, not part of its surface.
struct Entry<P, V> {
    priority: P
    value: V
    sequence: int
}
