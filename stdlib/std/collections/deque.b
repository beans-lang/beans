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
// ---- why the shape lives in one object ------------------------------------
//
// A user's `deinit` can run in the middle of any method here. The cycle
// collector runs deinits, an allocation is where the collector runs, and under
// the tree interpreter essentially every operation allocates — so between any
// two writes this class makes, code that reads this deque may run. A shape
// spread over four cells (`front`, `back`, `front_count`, `back_count`) is
// therefore torn for as long as it takes to write the second of them, and
// `len()`, `get()`, `first()`, `last()` and `to_list()` answer from that tear:
// a length over storage that no longer matches it, the contents backwards, or
// an index straight past a block that was just drained. That was #86.
//
// Two rules close it, and between them every state this class can be caught in
// is a deque that is telling the truth.
//
// **The counters never claim more than the storage holds.** A push writes the
// element and then raises the count; a pop lowers the count and then takes the
// element out. So the storage may hold one more element than the deque claims,
// never one fewer, and readers decode the layout from the *counters*: the head
// block's claimed size is `front_count - head * BLOCK`, not the block's own
// length. An uncounted element sits past the end of what every reader looks
// at. `to_list()` walks to the counters for the same reason, `first` and
// `last` answer through `get` so the layout is decoded in one place, and no
// empty block is ever attached — a new block is filled before it is linked in,
// where `open_block_*` used to link an empty one and then allocate its storage,
// which made `first()` read slot -1. This costs nothing: the claimed size is a
// subtract where the block's length was a load.
//
// **A rebalance publishes a whole new shape with a single store.** Moving half
// of one end to the other changes all four cells, and no ordering of four
// writes leaves the content right at every step — the elements would have to
// be claimed by both sides at once, or by neither. So `rebalance` never writes
// the live shape at all: it reads it, builds a complete replacement beside it,
// and swaps it in with `self.shape = built`. Before that store this deque is
// entirely the old shape and after it entirely the new one; there is no third
// state for a deinit to find. Everything the rebuild allocates is allocated
// while the deque is still exactly what it says it is.
//
// The rebuild copies the elements rather than carrying blocks across by their
// handle. It has to: a block changing sides must have its contents reversed,
// and reversing it in place is a write to storage the live shape is still
// answering from — and a `List` block cannot be in two block maps at once, so
// it cannot be shared with the replacement either. The copy is O(n) at a
// rebalance, which the halving keeps to O(1) per pop amortized: draining n
// elements from the far end copies n + n/2 + n/4 + ... = 2n in total, two
// element copies per pop. Moving ALL of the far end instead would let pops
// alternating between the two ends pay O(n) every turn.

package collections

// The four cells that describe a deque's shape, together, so a rebalance can
// publish all of them with one store. Nothing outside `Deque` sees this type.
class DequeShape<T implements Clone> {
    // front[len-1] is the head block; a front block is stored reversed.
    front: List<List<T>> = []
    // back[len-1] is the tail block; a back block is stored in order.
    back: List<List<T>> = []
    // Element counts per side. Never larger than the storage holds.
    front_count: int = 0
    back_count: int = 0

    pub fn init() {}
}

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
/// insert or a remove. `get`, `first`, `last`, `len` and `is_empty` are O(1);
/// `push_*` and `pop_*` are amortized O(1) — a pop that empties its end
/// rebalances, which is O(k) in the k elements the deque holds, but such
/// rebalances halve and so amortize to O(1) per pop; `clear` and `to_list`
/// are O(n).
///
/// Every state this deque can be caught in is a deque that is telling the
/// truth, so a `deinit` the cycle collector runs part-way through a push, a
/// pop or a rebalance reads exactly what the deque holds at that moment.
pub class Deque<T implements Clone> {
    shape: DequeShape<T> = new()
    // At most one recycled empty block, reserved to BLOCK, to keep a
    // push/pop straddling a block boundary free of allocation. Not part of
    // the shape: no reader can see it, so it may be touched at any time.
    spare: List<List<T>> = []

    /// An empty deque.
    pub fn init() {}

    /// Add `value` at the head.
    pub fn push_front(value: T) {
        let head: int = self.shape.front.len() - 1
        if head < 0 || self.shape.front[head].len() == 512 {
            // Build the block, put the value in it and make room for its
            // handle first, while the deque is still exactly what its
            // counters say. Attaching the block raises no count, so until the
            // line below it holds an element the deque does not claim.
            var block: List<T> = self.take_block()
            self.shape.front.reserve(self.shape.front.len() + 1)
            block.push(value)
            self.shape.front.push(move block)
            self.shape.front_count += 1
            return
        }
        self.shape.front[head].push(value)
        self.shape.front_count += 1
    }

    /// Add `value` at the tail.
    pub fn push_back(value: T) {
        let tail: int = self.shape.back.len() - 1
        if tail < 0 || self.shape.back[tail].len() == 512 {
            var block: List<T> = self.take_block()
            self.shape.back.reserve(self.shape.back.len() + 1)
            block.push(value)
            self.shape.back.push(move block)
            self.shape.back_count += 1
            return
        }
        self.shape.back[tail].push(value)
        self.shape.back_count += 1
    }

    /// Remove and answer the head, or `none` when the deque is empty.
    pub fn pop_front() -> Option<T> {
        if self.shape.front_count == 0 {
            if self.shape.back_count == 0 { return none }
            self.crossover_to_front()
        }
        let head: int = self.shape.front.len() - 1
        // The count comes down first. `pop` builds an `Option` to hand the
        // element back and building it allocates, which is a place the
        // collector runs a deinit; with the count already down, the element
        // it is about to take is one this deque no longer claims, so that
        // deinit reads the deque the pop is on its way to leaving behind.
        self.shape.front_count -= 1
        let got: Option<T> = self.shape.front[head].pop()
        if self.shape.front[head].len() == 0 {
            let empty: List<T> = self.shape.front.remove(head)
            // Settled: recycling the emptied block may allocate, and that is
            // fine now.
            if self.spare.len() == 0 { self.spare.push(move empty) }
        }
        return got
    }

    /// Remove and answer the tail, or `none` when the deque is empty.
    pub fn pop_back() -> Option<T> {
        if self.shape.back_count == 0 {
            if self.shape.front_count == 0 { return none }
            self.crossover_to_back()
        }
        let tail: int = self.shape.back.len() - 1
        self.shape.back_count -= 1
        let got: Option<T> = self.shape.back[tail].pop()
        if self.shape.back[tail].len() == 0 {
            let empty: List<T> = self.shape.back.remove(tail)
            if self.spare.len() == 0 { self.spare.push(move empty) }
        }
        return got
    }

    /// The head without removing it.
    pub fn first() -> Option<T> {
        return self.get(0)
    }

    /// The tail without removing it.
    pub fn last() -> Option<T> {
        return self.get(self.len() - 1)
    }

    /// The element `index` places from the head, or `none` when `index` is
    /// outside the deque.
    pub fn get(index: int) -> Option<T> {
        if index < 0 ||
           index >= self.shape.front_count + self.shape.back_count {
            return none
        }
        if index < self.shape.front_count {
            let head: int = self.shape.front.len() - 1
            // The head block's CLAIMED size, from the counter — not the
            // block's own length. A push writes its element before it raises
            // the count and a pop lowers the count before it takes its element
            // out, so the block may physically hold one more than the deque
            // claims; that one sits past `filled` and no reader reaches it.
            let filled: int = self.shape.front_count - head * 512
            if index < filled {
                return some(self.shape.front[head][filled - 1 - index])
            }
            let rest: int = index - filled
            let deep: int = head - 1 - rest / 512
            return some(self.shape.front[deep][512 - 1 - rest % 512])
        }
        let offset: int = index - self.shape.front_count
        return some(self.shape.back[offset / 512][offset % 512])
    }

    /// How many elements.
    pub fn len() -> int {
        return self.shape.front_count + self.shape.back_count
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
        self.shape.front_count = 0
        self.shape.back_count = 0
        self.shape.front.clear()
        self.shape.back.clear()
        self.spare.clear()
    }

    /// Every element, head first, as a new list.
    pub fn to_list() -> List<T> {
        var out: List<T> = []
        out.reserve(self.len())
        // Front blocks, head block (outermost) first; each is read back to
        // front because a front block is stored reversed. The head block is
        // read from its claimed size, exactly as `get` reads it.
        let head: int = self.shape.front.len() - 1
        if head >= 0 {
            var slot: int = self.shape.front_count - head * 512 - 1
            for slot >= 0 {
                out.push(self.shape.front[head][slot])
                slot -= 1
            }
            var block: int = head - 1
            for block >= 0 {
                var deep: int = 511
                for deep >= 0 {
                    out.push(self.shape.front[block][deep])
                    deep -= 1
                }
                block -= 1
            }
        }
        // Back blocks, innermost first, in order, stopping at what the back
        // side claims rather than at what its last block happens to hold.
        var taken: int = 0
        var index: int = 0
        for taken < self.shape.back_count {
            var room: int = self.shape.back_count - taken
            if room > 512 { room = 512 }
            var slot: int = 0
            for slot < room {
                out.push(self.shape.back[index][slot])
                slot += 1
            }
            taken += room
            index += 1
        }
        return move out
    }

    // A 512-slot block to fill: the recycled spare when there is one, a fresh
    // one otherwise. `spare` is scratch, not shape, so taking from it changes
    // no answer — which is the point, because this is where the allocation
    // goes.
    fn take_block() -> List<T> {
        if self.spare.len() > 0 {
            var recycled: List<T> = self.spare.remove(self.spare.len() - 1)
            recycled.reserve(512)
            return move recycled
        }
        var block: List<T> = []
        block.reserve(512)
        return move block
    }

    // `front` is empty and `back` is not: move the head half of `back` to the
    // front side. One block is split down its middle; two or more move a block
    // at a time, as the original did — the halving is what keeps a rebalance
    // to O(1) per pop amortized.
    //
    // Every block is COPIED into the replacement, with `slice`, which is one
    // bulk copy per block rather than a Beans-level loop. It has to be a copy:
    // a block changing sides must have its contents reversed, and reversing it
    // where it lies is a write to storage the live shape is still answering
    // from; a `List` block cannot sit in two block maps at once either, so the
    // blocks that stay cannot be shared with the replacement.
    fn crossover_to_front() {
        var built: DequeShape<T> = new()
        let blocks: int = self.shape.back.len()
        if blocks == 1 {
            let total: int = self.shape.back_count
            let moved: int = (total + 1) / 2
            // `back[0]` is in order, so the head half is its first `moved`
            // slots; a front block is stored reversed, so flip the copy.
            var head_block: List<T> = self.shape.back[0].slice(0, moved)
            head_block.reverse()
            head_block.reserve(512)
            built.front.reserve(1)
            built.front.push(move head_block)
            built.front_count = moved
            if total > moved {
                var tail_block: List<T> =
                    self.shape.back[0].slice(moved, total)
                tail_block.reserve(512)
                built.back.reserve(1)
                built.back.push(move tail_block)
                built.back_count = total - moved
            }
            self.shape = built
            return
        }
        // The innermost ceil(k/2) blocks — all full, since only a side's
        // outermost may be short — become the front side.
        let moved_blocks: int = (blocks + 1) / 2
        built.front.reserve(moved_blocks)
        var moved_elems: int = 0
        var index: int = 0
        for index < moved_blocks {
            var block: List<T> = self.shape.back[index].clone()
            moved_elems += block.len()
            block.reverse()
            built.front.push(move block)
            index += 1
        }
        // Pushed innermost first; the head block must be outermost.
        built.front.reverse()
        built.front_count = moved_elems
        built.back.reserve(blocks - moved_blocks)
        index = moved_blocks
        for index < blocks {
            var block: List<T> = self.shape.back[index].clone()
            built.back.push(move block)
            index += 1
        }
        // Only a side's outermost block can ever be pushed to, and `slice`
        // and `clone` hand back a list sized to what they copied.
        built.back[built.back.len() - 1].reserve(512)
        built.back_count = self.shape.back_count - moved_elems
        self.shape = built
    }

    // The mirror image: `back` is empty and `front` is not, so the tail half
    // of `front` moves to the back side.
    fn crossover_to_back() {
        var built: DequeShape<T> = new()
        let blocks: int = self.shape.front.len()
        if blocks == 1 {
            let total: int = self.shape.front_count
            let moved: int = (total + 1) / 2
            // `front[0]` is stored reversed, so the deque's tail half is its
            // first `moved` slots; a back block is stored in order.
            var tail_block: List<T> = self.shape.front[0].slice(0, moved)
            tail_block.reverse()
            tail_block.reserve(512)
            built.back.reserve(1)
            built.back.push(move tail_block)
            built.back_count = moved
            if total > moved {
                var head_block: List<T> =
                    self.shape.front[0].slice(moved, total)
                head_block.reserve(512)
                built.front.reserve(1)
                built.front.push(move head_block)
                built.front_count = total - moved
            }
            self.shape = built
            return
        }
        let moved_blocks: int = (blocks + 1) / 2
        built.back.reserve(moved_blocks)
        var moved_elems: int = 0
        // front[0] holds the deque's last elements, so the moved blocks go to
        // the back side outermost first: back[0] is front[moved_blocks-1].
        var index: int = moved_blocks - 1
        for index >= 0 {
            var block: List<T> = self.shape.front[index].clone()
            moved_elems += block.len()
            block.reverse()
            built.back.push(move block)
            index -= 1
        }
        built.back_count = moved_elems
        built.front.reserve(blocks - moved_blocks)
        index = moved_blocks
        for index < blocks {
            var block: List<T> = self.shape.front[index].clone()
            built.front.push(move block)
            index += 1
        }
        built.front[built.front.len() - 1].reserve(512)
        built.front_count = self.shape.front_count - moved_elems
        self.shape = built
    }
}
