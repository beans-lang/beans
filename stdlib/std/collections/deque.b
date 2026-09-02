// A queue open at both ends. `List.insert(0, v)` and `List.remove(0)` shift
// every other element, so a list used as a queue is quadratic; this is not.
//
// The storage is std::deque's idea — fixed-size blocks, so an element body is
// written once and never moved again — with the block map split into two
// stacks so both ends grow by `push` alone:
//
//   front: List<List<T>>   front[len-1] is the HEAD block (outermost), front[0]
//                          the innermost. A front block is stored REVERSED:
//                          block[block.len()-1] is that block's deque-earliest
//                          element, so push_front is one `push` at the end.
//   back:  List<List<T>>   back[len-1] is the TAIL block (outermost), back[0]
//                          the innermost. A back block is stored in order.
//   spare: List<List<T>>   0 or 1 recycled empty block, so a push/pop that
//                          straddles a block boundary neither allocates nor
//                          frees — it moves one block handle to and from spare.
//
// Invariants, true by construction (the fuzz model in test/ catches a breach):
//   * every block except a side's outermost is exactly BLOCK long;
//   * a side holds no empty block — a side with no elements is an empty list,
//     and its lone emptied block is handed to `spare`, never left in place;
//   * front_count + back_count == len().
//
// A pop from an empty end does not rebuild the other end element by element;
// it moves HALF of it across as block handles (`remove(len-1)` + `push(move)`,
// O(1) each) and flips each moved block's contents with one C `reverse`, never
// a Beans-level per-element copy. That C reverse still touches the elements it
// moves, so a single crossover is O(k) in the k elements it carries — up to
// O(n) for one unlucky pop. Halving is what amortizes it: across a run of pops
// each element is carried across at most O(1) times (n/2 + n/4 + ... = n), so
// the amortized cost stays O(1) per pop. Moving ALL of the far end instead
// would let pops alternating between the two ends pay O(n) every turn. A lone
// block is split down its middle rather than moved.

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
/// Elements live in fixed 512-slot blocks held by two stacks of block handles,
/// the front stack reversed so both ends grow by `push`. An element body is
/// written once on a push and read once on a pop; it is never shifted by an
/// insert or a remove. A rebalance across the middle moves whole blocks by
/// their handle and flips a moved block's contents with one C `reverse`, rather
/// than copying elements across one at a time. `get`, `first`, `last`, `len`
/// and `is_empty` are O(1); `push_*` and `pop_*` are amortized O(1) — a pop that
/// triggers a rebalance is O(k) in the elements it carries but such carries
/// amortize to O(1) per pop; `clear` and `to_list` are O(n).
pub class Deque<T implements Clone> {
    // front[len-1] is the head block; a front block is stored reversed.
    front: List<List<T>> = []
    // back[len-1] is the tail block; a back block is stored in order.
    back: List<List<T>> = []
    // At most one recycled empty block, reserved to BLOCK, to keep a
    // push/pop straddling a block boundary free of allocation.
    spare: List<List<T>> = []
    // Element counts per side; block counts are front.len()/back.len().
    front_count: int = 0
    back_count: int = 0

    /// An empty deque.
    pub fn init() {}

    /// Add `value` at the head.
    pub fn push_front(value: T) {
        if self.front.len() == 0 ||
           self.front[self.front.len() - 1].len() == 512 {
            self.open_block_front()
        }
        self.front[self.front.len() - 1].push(value)
        self.front_count += 1
    }

    /// Add `value` at the tail.
    pub fn push_back(value: T) {
        if self.back.len() == 0 ||
           self.back[self.back.len() - 1].len() == 512 {
            self.open_block_back()
        }
        self.back[self.back.len() - 1].push(value)
        self.back_count += 1
    }

    /// Remove and answer the head, or `none` when the deque is empty.
    pub fn pop_front() -> Option<T> {
        if self.front_count == 0 {
            if self.back_count == 0 { return none }
            self.crossover_to_front()
        }
        let head: int = self.front.len() - 1
        let got: Option<T> = self.front[head].pop()
        self.front_count -= 1
        if self.front[head].len() == 0 {
            let empty: List<T> = self.front.remove(head)
            if self.spare.len() == 0 { self.spare.push(move empty) }
        }
        return got
    }

    /// Remove and answer the tail, or `none` when the deque is empty.
    pub fn pop_back() -> Option<T> {
        if self.back_count == 0 {
            if self.front_count == 0 { return none }
            self.crossover_to_back()
        }
        let tail: int = self.back.len() - 1
        let got: Option<T> = self.back[tail].pop()
        self.back_count -= 1
        if self.back[tail].len() == 0 {
            let empty: List<T> = self.back.remove(tail)
            if self.spare.len() == 0 { self.spare.push(move empty) }
        }
        return got
    }

    /// The head without removing it.
    pub fn first() -> Option<T> {
        if self.front_count != 0 {
            let head: int = self.front.len() - 1
            return some(self.front[head][self.front[head].len() - 1])
        }
        if self.back_count == 0 { return none }
        return some(self.back[0][0])
    }

    /// The tail without removing it.
    pub fn last() -> Option<T> {
        if self.back_count != 0 {
            let tail: int = self.back.len() - 1
            return some(self.back[tail][self.back[tail].len() - 1])
        }
        if self.front_count == 0 { return none }
        return some(self.front[0][0])
    }

    /// The element `index` places from the head, or `none` when `index` is
    /// outside the deque.
    pub fn get(index: int) -> Option<T> {
        if index < 0 || index >= self.len() { return none }
        if index < self.front_count {
            let head: int = self.front.len() - 1
            let filled: int = self.front[head].len()
            if index < filled {
                return some(self.front[head][filled - 1 - index])
            }
            let rest: int = index - filled
            return some(self.front[head - 1 - rest / 512][512 - 1 - rest % 512])
        }
        let offset: int = index - self.front_count
        return some(self.back[offset / 512][offset % 512])
    }

    /// How many elements.
    pub fn len() -> int {
        return self.front_count + self.back_count
    }

    /// True while the deque holds nothing.
    pub fn is_empty() -> bool {
        return self.len() == 0
    }

    /// Drop every element.
    pub fn clear() {
        // Settle the deque before dropping what it owns: an element's deinit
        // can read this deque (directly, or from another fiber while this one
        // parks), and a panic from one aborts the rest of the clear. Zeroing
        // the counters first means every such observer sees an empty deque
        // rather than the old length over storage that is already gone, and a
        // contained panic leaves it empty rather than permanently torn. This
        // is the rule the runtime containers follow.
        self.front_count = 0
        self.back_count = 0
        self.front.clear()
        self.back.clear()
        self.spare.clear()
    }

    /// Every element, head first, as a new list.
    pub fn to_list() -> List<T> {
        var out: List<T> = []
        out.reserve(self.len())
        // Front blocks, head block (outermost) first; each is read back to
        // front because a front block is stored reversed.
        var block: int = self.front.len() - 1
        for block >= 0 {
            var slot: int = self.front[block].len() - 1
            for slot >= 0 {
                out.push(self.front[block][slot])
                slot -= 1
            }
            block -= 1
        }
        // Back blocks, innermost first; each is read in order.
        var index: int = 0
        for index < self.back.len() {
            let filled: int = self.back[index].len()
            var slot: int = 0
            for slot < filled {
                out.push(self.back[index][slot])
                slot += 1
            }
            index += 1
        }
        return move out
    }

    // Put a fresh block at the head of `front`, reusing the spare if there is
    // one so a boundary-straddling push does not allocate.
    fn open_block_front() {
        if self.spare.len() > 0 {
            let block: List<T> = self.spare.remove(self.spare.len() - 1)
            self.front.push(move block)
        } else {
            self.front.push([])
            self.front[self.front.len() - 1].reserve(512)
        }
    }

    fn open_block_back() {
        if self.spare.len() > 0 {
            let block: List<T> = self.spare.remove(self.spare.len() - 1)
            self.back.push(move block)
        } else {
            self.back.push([])
            self.back[self.back.len() - 1].reserve(512)
        }
    }

    // `front` is empty and `back` is not: move the head half of `back` to the
    // front side. One block is split; two or more move as whole handles.
    fn crossover_to_front() {
        if self.back.len() == 1 {
            // Split the lone block down the middle. `back[0]` is in order, so
            // reverse it and pop the head half; those come off in deque order,
            // so reverse the new head block into a front block's reversed
            // storage, then restore what is left of the tail block.
            self.back[0].reverse()
            let total: int = self.back[0].len()
            let moved: int = (total + 1) / 2
            var head_block: List<T> = []
            head_block.reserve(512)
            var taken: int = 0
            for taken < moved {
                match self.back[0].pop() {
                    some(value) => { head_block.push(value) }
                    none => {}
                }
                taken += 1
            }
            head_block.reverse()
            self.back[0].reverse()
            self.front.push(move head_block)
            self.front_count = moved
            self.back_count = total - moved
            if self.back[0].len() == 0 {
                let empty: List<T> = self.back.remove(0)
                if self.spare.len() == 0 { self.spare.push(move empty) }
            }
        } else {
            // Move the innermost ceil(k/2) blocks — all full — as handles.
            let blocks: int = self.back.len()
            let moved_blocks: int = (blocks + 1) / 2
            self.back.reverse()
            var moved_elems: int = 0
            var taken: int = 0
            for taken < moved_blocks {
                let block: List<T> = self.back.remove(self.back.len() - 1)
                moved_elems += block.len()
                self.front.push(move block)
                taken += 1
            }
            self.back.reverse()
            // The moved blocks are now front[0..], innermost first; the head
            // block must be outermost, and each block's order must flip to a
            // front block's reversed storage.
            self.front.reverse()
            var index: int = 0
            for index < self.front.len() {
                self.front[index].reverse()
                index += 1
            }
            self.front_count = moved_elems
            self.back_count = self.back_count - moved_elems
        }
    }

    // The mirror image: `back` is empty and `front` is not: move the tail half
    // of `front` to the back side.
    fn crossover_to_back() {
        if self.front.len() == 1 {
            self.front[0].reverse()
            let total: int = self.front[0].len()
            let moved: int = (total + 1) / 2
            var tail_block: List<T> = []
            tail_block.reserve(512)
            var taken: int = 0
            for taken < moved {
                match self.front[0].pop() {
                    some(value) => { tail_block.push(value) }
                    none => {}
                }
                taken += 1
            }
            tail_block.reverse()
            self.front[0].reverse()
            self.back.push(move tail_block)
            self.back_count = moved
            self.front_count = total - moved
            if self.front[0].len() == 0 {
                let empty: List<T> = self.front.remove(0)
                if self.spare.len() == 0 { self.spare.push(move empty) }
            }
        } else {
            let blocks: int = self.front.len()
            let moved_blocks: int = (blocks + 1) / 2
            self.front.reverse()
            var moved_elems: int = 0
            var taken: int = 0
            for taken < moved_blocks {
                let block: List<T> = self.front.remove(self.front.len() - 1)
                moved_elems += block.len()
                block.reverse()
                self.back.push(move block)
                taken += 1
            }
            self.front.reverse()
            self.back.reverse()
            self.back_count = moved_elems
            self.front_count = self.front_count - moved_elems
        }
    }
}
