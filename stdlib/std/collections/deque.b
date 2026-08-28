// A queue open at both ends. `List.insert(0, v)` and `List.remove(0)` shift
// every other element, so a list used as a queue is quadratic; this is not.

package collections

/// A double-ended queue: push and pop at either end in amortized O(1), and
/// indexed reads in O(1).
///
/// ```
/// var jobs: collections.Deque<string> = new()
/// jobs.push_back("second")
/// jobs.push_front("first")
/// let next: Option<string> = jobs.pop_front()
/// ```
///
/// `T` must be `Clone`, because every read hands a copy of the element back.
/// A move-only element such as `Bytes` is refused: a generic container cannot
/// return a value that has exactly one owner.
///
/// The storage is two stacks — the front half held in reverse — and a pop from
/// an empty end moves half of the other end across. Halving rather than moving
/// everything is what keeps the amortized cost constant when pushes and pops
/// alternate between the ends; moving all of it would let an alternating
/// pattern pay O(n) every turn.
pub class Deque<T implements Clone> {
    // front is stored last-element-first: front[len - 1] is the deque's head.
    front: List<T> = []
    // back is stored in order: back[len - 1] is the deque's tail.
    back: List<T> = []

    /// An empty deque.
    pub fn init() {}

    /// Add `value` at the head.
    pub fn push_front(value: T) {
        self.front.push(value)
    }

    /// Add `value` at the tail.
    pub fn push_back(value: T) {
        self.back.push(value)
    }

    /// Remove and answer the head, or `none` when the deque is empty.
    pub fn pop_front() -> Option<T> {
        if self.front.len() == 0 {
            if self.back.len() == 0 { return none }
            self.rebalance_into_front()
        }
        return self.front.pop()
    }

    /// Remove and answer the tail, or `none` when the deque is empty.
    pub fn pop_back() -> Option<T> {
        if self.back.len() == 0 {
            if self.front.len() == 0 { return none }
            self.rebalance_into_back()
        }
        return self.back.pop()
    }

    /// The head without removing it.
    pub fn first() -> Option<T> {
        if self.front.len() != 0 {
            return some(self.front[self.front.len() - 1])
        }
        if self.back.len() == 0 { return none }
        return some(self.back[0])
    }

    /// The tail without removing it.
    pub fn last() -> Option<T> {
        if self.back.len() != 0 {
            return some(self.back[self.back.len() - 1])
        }
        if self.front.len() == 0 { return none }
        return some(self.front[0])
    }

    /// The element `index` places from the head, or `none` when `index` is
    /// outside the deque.
    pub fn get(index: int) -> Option<T> {
        if index < 0 || index >= self.len() { return none }
        if index < self.front.len() {
            return some(self.front[self.front.len() - 1 - index])
        }
        return some(self.back[index - self.front.len()])
    }

    /// How many elements.
    pub fn len() -> int {
        return self.front.len() + self.back.len()
    }

    /// True while the deque holds nothing.
    pub fn is_empty() -> bool {
        return self.len() == 0
    }

    /// Drop every element.
    pub fn clear() {
        self.front.clear()
        self.back.clear()
    }

    /// Every element, head first, as a new list.
    pub fn to_list() -> List<T> {
        var out: List<T> = []
        out.reserve(self.len())
        var index: int = self.front.len() - 1
        for index >= 0 {
            out.push(self.front[index])
            index -= 1
        }
        for value: T in self.back {
            out.push(value)
        }
        return move out
    }

    // Move the head half of `back` into `front`, reversed. Both new lists are
    // built before either field is replaced, so nothing here reads a list it
    // is also changing.
    fn rebalance_into_front() {
        let total: int = self.back.len()
        let moved: int = (total + 1) / 2
        var head: List<T> = []
        head.reserve(moved)
        var index: int = moved - 1
        for index >= 0 {
            head.push(self.back[index])
            index -= 1
        }
        var tail: List<T> = []
        tail.reserve(total - moved)
        var rest: int = moved
        for rest < total {
            tail.push(self.back[rest])
            rest += 1
        }
        self.front = move head
        self.back = move tail
    }

    // The mirror image: move the tail half of `front` into `back`, reversed.
    fn rebalance_into_back() {
        let total: int = self.front.len()
        let moved: int = (total + 1) / 2
        var tail: List<T> = []
        tail.reserve(moved)
        var index: int = moved - 1
        for index >= 0 {
            tail.push(self.front[index])
            index -= 1
        }
        var head: List<T> = []
        head.reserve(total - moved)
        var rest: int = moved
        for rest < total {
            head.push(self.front[rest])
            rest += 1
        }
        self.back = move tail
        self.front = move head
    }
}
