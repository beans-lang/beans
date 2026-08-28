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
pub class PriorityQueue<P implements Order & Clone, V implements Clone> {
    priorities: List<P> = []
    values: List<V> = []
    sequences: List<int> = []
    next_sequence: int = 0

    /// An empty queue.
    pub fn init() {}

    /// Add `value` under `priority`.
    pub fn push(priority: P, value: V) {
        self.priorities.push(priority)
        self.values.push(value)
        self.sequences.push(self.next_sequence)
        self.next_sequence += 1
        self.sift_up(self.values.len() - 1)
    }

    /// The smallest-priority value, without removing it.
    pub fn peek() -> Option<V> {
        if self.values.len() == 0 { return none }
        return some(self.values[0])
    }

    /// The smallest priority, without removing its entry. This is the "when
    /// does the next thing happen" question, answered without taking it.
    pub fn peek_priority() -> Option<P> {
        if self.priorities.len() == 0 { return none }
        return some(self.priorities[0])
    }

    /// Remove and answer the smallest-priority value.
    pub fn pop() -> Option<V> {
        if self.values.len() == 0 { return none }
        let top: V = self.values[0]
        let last: int = self.values.len() - 1
        if last > 0 {
            self.priorities[0] = self.priorities[last]
            self.values[0] = self.values[last]
            self.sequences[0] = self.sequences[last]
        }
        self.priorities.remove(last)
        self.values.remove(last)
        self.sequences.remove(last)
        if self.values.len() > 1 {
            self.sift_down(0)
        }
        return some(top)
    }

    /// How many entries.
    pub fn len() -> int {
        return self.values.len()
    }

    /// True while the queue holds nothing.
    pub fn is_empty() -> bool {
        return self.values.len() == 0
    }

    /// Drop every entry. The push counter keeps running, so tie order stays
    /// consistent across a clear.
    pub fn clear() {
        self.priorities.clear()
        self.values.clear()
        self.sequences.clear()
    }

    // Entry `left` sorts before entry `right`: smaller priority first, and
    // among equal priorities the earlier push.
    fn sorts_before(left: int, right: int) -> bool {
        let a: P = self.priorities[left]
        let b: P = self.priorities[right]
        if a < b { return true }
        if b < a { return false }
        return self.sequences[left] < self.sequences[right]
    }

    fn swap(left: int, right: int) {
        let priority: P = self.priorities[left]
        self.priorities[left] = self.priorities[right]
        self.priorities[right] = priority
        let value: V = self.values[left]
        self.values[left] = self.values[right]
        self.values[right] = value
        let sequence: int = self.sequences[left]
        self.sequences[left] = self.sequences[right]
        self.sequences[right] = sequence
    }

    fn sift_up(start: int) {
        var index: int = start
        for index > 0 {
            let parent: int = (index - 1) / 2
            if !self.sorts_before(index, parent) { return }
            self.swap(index, parent)
            index = parent
        }
    }

    fn sift_down(start: int) {
        let count: int = self.values.len()
        var index: int = start
        for {
            let left: int = index * 2 + 1
            if left >= count { return }
            var smallest: int = left
            let right: int = left + 1
            if right < count && self.sorts_before(right, left) {
                smallest = right
            }
            if !self.sorts_before(smallest, index) { return }
            self.swap(index, smallest)
            index = smallest
        }
    }
}
