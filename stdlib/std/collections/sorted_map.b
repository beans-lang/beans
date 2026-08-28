// The ordered half of the map story. `Map` and `OrderedMap` answer "is this
// key here" and "what went in first"; neither answers "what is the next key
// after this one", "how many keys are below it", or "give me every key in
// this range" — the questions a leaderboard, a time series index or an expiry
// scan is made of. Sorting a `List` answers them once and is wrong the moment
// the collection changes again.

package collections

// One node of the balanced tree. Not public: the tree shape is an
// implementation choice, and a caller holding a node would freeze it.
class SortedNode<K implements Order & Clone, V implements Clone> {
    key: K
    value: V
    left: Option<SortedNode<K, V>> = none
    right: Option<SortedNode<K, V>> = none
    // 1 for a leaf, so an absent child can answer 0 and the arithmetic works
    // without a special case.
    height: int = 1
    // Nodes in this subtree, which is what makes rank and select O(log n)
    // instead of O(n).
    size: int = 1

    fn init(key: K, value: V) {
        self.key = key
        self.value = value
    }
}

/// A map that keeps its keys in ascending order, with O(log n) lookup,
/// insertion and removal, and ordered queries no hash map can answer:
/// neighbours, rank, position and range scans.
///
/// ```
/// var scores: collections.SortedMap<int, string> = new()
/// scores.set(1500, "ada")
/// scores.set(1200, "bo")
/// let top: Option<int> = scores.last_key()
/// let band: List<string> = scores.range_values(1000, 1400)   // [from, to)
/// ```
///
/// This is not `OrderedMap`, which is a hash map that remembers insertion
/// order. The two names are close and the promises are not: `OrderedMap`
/// visits keys in the order they were first inserted and cannot tell you what
/// comes after a key it has never seen; `SortedMap` visits them in key order
/// and can. `OrderedMap` is the right answer for "keep my configuration in
/// file order", this one for "what expires next" and "the ten scores above
/// 1200". A separate type rather than a mode on the existing one, because the
/// storage is a balanced tree rather than a hash table and every operation has
/// a different cost.
///
/// `K` must be `Order & Clone`. `Order` is what lets the tree compare keys at
/// all, and today the language grants it only to the primitives — the integer
/// and float types, `decimal`, `bool` and `string`. A class, struct or enum
/// key is refused; order it by a primitive key it maps to.
///
/// `V` must be `Clone`, because `get` hands the stored value back. A move-only
/// value such as `Bytes` is refused for the same reason `Deque` refuses one.
///
/// The tree is an AVL tree: every node keeps the height of its subtree and a
/// rotation restores the invariant that the two sides differ by at most one,
/// so the depth stays under 1.44 log2(n) no matter what order the keys arrive
/// in. Sorted input — timestamps, sequence numbers, exactly the input a time
/// series index has — is the case an unbalanced tree degrades to a linked list
/// on, so balance is not optional here.
pub class SortedMap<K implements Order & Clone, V implements Clone> {
    root: Option<SortedNode<K, V>> = none

    /// An empty map.
    pub fn init() {}

    /// How many keys.
    pub fn len() -> int {
        return self.size_of(self.root)
    }

    /// True while the map holds nothing.
    pub fn is_empty() -> bool {
        return self.len() == 0
    }

    /// Drop every entry.
    pub fn clear() {
        self.root = none
    }

    /// Store `value` under `key`, replacing any value already there.
    pub fn set(key: K, value: V) {
        self.root = some(self.insert_into(self.root, key, value, true))
    }

    /// Store `value` under `key` only when the key is new. False leaves the
    /// old value in place, matching `Map.insert`.
    pub fn insert(key: K, value: V) -> bool {
        let before: int = self.len()
        self.root = some(self.insert_into(self.root, key, value, false))
        return self.len() != before
    }

    /// The value stored under `key`, or `none`.
    pub fn get(key: K) -> Option<V> {
        var node: Option<SortedNode<K, V>> = self.root
        for {
            match node {
                some(current) => {
                    if key < current.key {
                        node = current.left
                    } else if current.key < key {
                        node = current.right
                    } else {
                        return some(current.value)
                    }
                }
                none => { return none }
            }
        }
    }

    /// True when `key` has a value here.
    pub fn contains_key(key: K) -> bool {
        var node: Option<SortedNode<K, V>> = self.root
        for {
            match node {
                some(current) => {
                    if key < current.key {
                        node = current.left
                    } else if current.key < key {
                        node = current.right
                    } else {
                        return true
                    }
                }
                none => { return false }
            }
        }
    }

    /// Remove `key`. True when it was there.
    pub fn remove(key: K) -> bool {
        let before: int = self.len()
        self.root = self.remove_from(self.root, key)
        return self.len() != before
    }

    /// Every key, ascending.
    pub fn keys() -> List<K> {
        var out: List<K> = []
        out.reserve(self.len())
        self.collect_keys(self.root, out)
        return move out
    }

    /// Every value, in ascending key order.
    pub fn values() -> List<V> {
        var out: List<V> = []
        out.reserve(self.len())
        self.collect_values(self.root, out)
        return move out
    }

    /// The smallest key, or `none` when the map is empty.
    pub fn first_key() -> Option<K> {
        match self.edge_node(true) {
            some(node) => { return some(node.key) }
            none => { return none }
        }
    }

    /// The largest key, or `none` when the map is empty.
    pub fn last_key() -> Option<K> {
        match self.edge_node(false) {
            some(node) => { return some(node.key) }
            none => { return none }
        }
    }

    /// The value under the smallest key.
    pub fn first_value() -> Option<V> {
        match self.edge_node(true) {
            some(node) => { return some(node.value) }
            none => { return none }
        }
    }

    /// The value under the largest key.
    pub fn last_value() -> Option<V> {
        match self.edge_node(false) {
            some(node) => { return some(node.value) }
            none => { return none }
        }
    }

    /// The largest key less than or equal to `key`.
    pub fn floor_key(key: K) -> Option<K> {
        return self.neighbour_key(key, true, true)
    }

    /// The smallest key greater than or equal to `key`.
    pub fn ceiling_key(key: K) -> Option<K> {
        return self.neighbour_key(key, false, true)
    }

    /// The largest key strictly less than `key`.
    pub fn lower_key(key: K) -> Option<K> {
        return self.neighbour_key(key, true, false)
    }

    /// The smallest key strictly greater than `key`.
    pub fn higher_key(key: K) -> Option<K> {
        return self.neighbour_key(key, false, false)
    }

    /// How many keys sort before `key`, whether or not `key` itself is here.
    /// A key's rank is also its position in `keys()`.
    pub fn rank(key: K) -> int {
        var count: int = 0
        var node: Option<SortedNode<K, V>> = self.root
        for {
            match node {
                some(current) => {
                    if key < current.key {
                        node = current.left
                    } else if current.key < key {
                        count += self.size_of(current.left) + 1
                        node = current.right
                    } else {
                        return count + self.size_of(current.left)
                    }
                }
                none => { return count }
            }
        }
    }

    /// The key at 0-based position `index` in ascending order, or `none` when
    /// `index` is outside the map. O(log n), not O(n): this is what the
    /// per-node subtree sizes are for.
    pub fn key_at(index: int) -> Option<K> {
        match self.node_at(index) {
            some(node) => { return some(node.key) }
            none => { return none }
        }
    }

    /// The value at 0-based position `index` in ascending key order.
    pub fn value_at(index: int) -> Option<V> {
        match self.node_at(index) {
            some(node) => { return some(node.value) }
            none => { return none }
        }
    }

    /// Every key in `[from, to)` — `from` included, `to` excluded, ascending.
    /// A range whose end is not after its start is empty.
    pub fn range_keys(from: K, to: K) -> List<K> {
        var out: List<K> = []
        self.collect_range_keys(self.root, from, to, out)
        return move out
    }

    /// Every value whose key is in `[from, to)`, in ascending key order.
    pub fn range_values(from: K, to: K) -> List<V> {
        var out: List<V> = []
        self.collect_range_values(self.root, from, to, out)
        return move out
    }

    /// How many keys are in `[from, to)`, without building a list.
    pub fn range_count(from: K, to: K) -> int {
        if !(from < to) { return 0 }
        return self.rank(to) - self.rank(from)
    }

    // ---- the tree ----------------------------------------------------------

    fn height_of(node: Option<SortedNode<K, V>>) -> int {
        match node {
            some(current) => { return current.height }
            none => { return 0 }
        }
    }

    fn size_of(node: Option<SortedNode<K, V>>) -> int {
        match node {
            some(current) => { return current.size }
            none => { return 0 }
        }
    }

    // Recompute one node's height and subtree size from its children. Called
    // after every structural change, including both halves of a rotation.
    fn refresh(node: SortedNode<K, V>) {
        let left_height: int = self.height_of(node.left)
        let right_height: int = self.height_of(node.right)
        node.height =
            1 + if left_height > right_height { left_height } else { right_height }
        node.size = 1 + self.size_of(node.left) + self.size_of(node.right)
    }

    fn balance_of(node: SortedNode<K, V>) -> int {
        return self.height_of(node.left) - self.height_of(node.right)
    }

    fn rotate_right(node: SortedNode<K, V>) -> SortedNode<K, V> {
        let pivot: SortedNode<K, V> =
            node.left.expect("a left-heavy node has a left child")
        node.left = pivot.right
        pivot.right = some(node)
        self.refresh(node)
        self.refresh(pivot)
        return pivot
    }

    fn rotate_left(node: SortedNode<K, V>) -> SortedNode<K, V> {
        let pivot: SortedNode<K, V> =
            node.right.expect("a right-heavy node has a right child")
        node.right = pivot.left
        pivot.left = some(node)
        self.refresh(node)
        self.refresh(pivot)
        return pivot
    }

    // Restore the AVL invariant at one node and answer the new subtree root.
    // The inner rotation is the zig-zag case: a subtree leaning the other way
    // has to be straightened before the outer rotation can fix anything.
    fn rebalance(node: SortedNode<K, V>) -> SortedNode<K, V> {
        self.refresh(node)
        let balance: int = self.balance_of(node)
        if balance > 1 {
            let left: SortedNode<K, V> =
                node.left.expect("a left-heavy node has a left child")
            if self.balance_of(left) < 0 {
                node.left = some(self.rotate_left(left))
            }
            return self.rotate_right(node)
        }
        if balance < -1 {
            let right: SortedNode<K, V> =
                node.right.expect("a right-heavy node has a right child")
            if self.balance_of(right) > 0 {
                node.right = some(self.rotate_right(right))
            }
            return self.rotate_left(node)
        }
        return node
    }

    fn insert_into(node: Option<SortedNode<K, V>>, key: K, value: V,
                   replace: bool) -> SortedNode<K, V> {
        match node {
            some(current) => {
                if key < current.key {
                    current.left =
                        some(self.insert_into(current.left, key, value, replace))
                } else if current.key < key {
                    current.right =
                        some(self.insert_into(current.right, key, value, replace))
                } else {
                    // The key is already here. Nothing structural changes, so
                    // there is nothing to rebalance.
                    if replace { current.value = value }
                    return current
                }
                return self.rebalance(current)
            }
            none => { return new SortedNode<K, V>(key, value) }
        }
    }

    fn remove_from(node: Option<SortedNode<K, V>>,
                   key: K) -> Option<SortedNode<K, V>> {
        match node {
            some(current) => {
                if key < current.key {
                    current.left = self.remove_from(current.left, key)
                } else if current.key < key {
                    current.right = self.remove_from(current.right, key)
                } else {
                    // Found it. With one child or none, the child takes this
                    // node's place. With two, the in-order successor's entry
                    // moves up here and the successor is removed instead —
                    // it has no left child, so that removal is the easy case.
                    if self.height_of(current.left) == 0 {
                        return current.right
                    }
                    if self.height_of(current.right) == 0 {
                        return current.left
                    }
                    let successor: SortedNode<K, V> =
                        self.leftmost(
                            current.right.expect("a two-child node has a right child"))
                    current.key = successor.key
                    current.value = successor.value
                    current.right =
                        self.remove_from(current.right, successor.key)
                }
                return some(self.rebalance(current))
            }
            none => { return none }
        }
    }

    fn leftmost(node: SortedNode<K, V>) -> SortedNode<K, V> {
        var current: SortedNode<K, V> = node
        for {
            match current.left {
                some(next) => { current = next }
                none => { return current }
            }
        }
    }

    // The smallest or largest node, or none when the map is empty.
    fn edge_node(smallest: bool) -> Option<SortedNode<K, V>> {
        var node: Option<SortedNode<K, V>> = self.root
        var found: Option<SortedNode<K, V>> = none
        for {
            match node {
                some(current) => {
                    found = some(current)
                    node = if smallest { current.left } else { current.right }
                }
                none => { return found }
            }
        }
    }

    fn node_at(index: int) -> Option<SortedNode<K, V>> {
        if index < 0 || index >= self.len() { return none }
        var remaining: int = index
        var node: Option<SortedNode<K, V>> = self.root
        for {
            match node {
                some(current) => {
                    let left: int = self.size_of(current.left)
                    if remaining < left {
                        node = current.left
                    } else if remaining == left {
                        return some(current)
                    } else {
                        remaining -= left + 1
                        node = current.right
                    }
                }
                none => { return none }
            }
        }
    }

    // One descent covering floor, ceiling, lower and higher. `below` picks the
    // direction, `inclusive` decides whether an exact hit counts.
    fn neighbour_key(key: K, below: bool, inclusive: bool) -> Option<K> {
        var best: Option<K> = none
        var node: Option<SortedNode<K, V>> = self.root
        for {
            match node {
                some(current) => {
                    if current.key < key {
                        if below {
                            best = some(current.key)
                            node = current.right
                        } else {
                            node = current.right
                        }
                    } else if key < current.key {
                        if below {
                            node = current.left
                        } else {
                            best = some(current.key)
                            node = current.left
                        }
                    } else {
                        if inclusive { return some(current.key) }
                        node = if below { current.left } else { current.right }
                    }
                }
                none => { return best }
            }
        }
    }

    fn collect_keys(node: Option<SortedNode<K, V>>, out: List<K>) {
        match node {
            some(current) => {
                self.collect_keys(current.left, out)
                out.push(current.key)
                self.collect_keys(current.right, out)
            }
            none => {}
        }
    }

    fn collect_values(node: Option<SortedNode<K, V>>, out: List<V>) {
        match node {
            some(current) => {
                self.collect_values(current.left, out)
                out.push(current.value)
                self.collect_values(current.right, out)
            }
            none => {}
        }
    }

    // A pruned in-order walk. A subtree is skipped entirely when its whole
    // key span sits outside the range: nothing left of a node whose key is at
    // or below `from` can be in it, and nothing right of a node whose key is
    // at or above `to` can be either. That is what makes a range scan cost
    // O(log n + hits) rather than O(n).
    fn collect_range_keys(node: Option<SortedNode<K, V>>, from: K, to: K,
                          out: List<K>) {
        match node {
            some(current) => {
                if from < current.key {
                    self.collect_range_keys(current.left, from, to, out)
                }
                if !(current.key < from) && current.key < to {
                    out.push(current.key)
                }
                if current.key < to {
                    self.collect_range_keys(current.right, from, to, out)
                }
            }
            none => {}
        }
    }

    fn collect_range_values(node: Option<SortedNode<K, V>>, from: K, to: K,
                            out: List<V>) {
        match node {
            some(current) => {
                if from < current.key {
                    self.collect_range_values(current.left, from, to, out)
                }
                if !(current.key < from) && current.key < to {
                    out.push(current.value)
                }
                if current.key < to {
                    self.collect_range_values(current.right, from, to, out)
                }
            }
            none => {}
        }
    }
}
