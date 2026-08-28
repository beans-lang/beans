// A membership-only collection. `Map<T, bool>` does the same job with a byte
// of storage per member and a value nobody reads; this says what it means.

package collections

/// A collection of distinct values, with O(1) add, membership and removal.
///
/// ```
/// var seen: collections.Set<string> = new()
/// seen.add("beans")
/// if seen.contains("beans") { ... }
/// ```
///
/// `T` must be `Eq & Hash` — the same requirement `Map` makes of a key —
/// and `Clone`, because `items` and the set-algebra methods hand members back
/// out. That rules out a move-only element such as `Bytes`, `List` or `File`:
/// a value with one owner cannot also be a set member somebody can read.
///
/// Iteration order is the underlying `Map`'s, which promises nothing. Use
/// `SortedMap` when order matters.
///
/// The members live in one `Map<T, bool>`, so the storage cost is a map slot
/// plus a byte per member. What this type buys is the API and the algebra, not
/// a smaller footprint — a set with no per-entry value needs a storage shape
/// the runtime does not have yet.
pub class Set<T implements Eq & Hash & Clone> {
    members: Map<T, bool> = {}

    /// An empty set.
    pub fn init() {}

    /// Add `value`. True when it was not already there.
    pub fn add(value: T) -> bool {
        return self.members.insert(value, true)
    }

    /// Add every value in `values`, and answer how many were new.
    pub fn add_all(values: List<T>) -> int {
        var added: int = 0
        for value: T in values {
            if self.members.insert(value, true) { added += 1 }
        }
        return added
    }

    /// True when `value` is a member.
    pub fn contains(value: T) -> bool {
        return self.members.contains_key(value)
    }

    /// Remove `value`. True when it was there.
    pub fn remove(value: T) -> bool {
        return self.members.remove(value)
    }

    /// How many members.
    pub fn len() -> int {
        return self.members.len()
    }

    /// True while the set has no members.
    pub fn is_empty() -> bool {
        return self.members.len() == 0
    }

    /// Drop every member.
    pub fn clear() {
        self.members.clear()
    }

    /// Make room for at least `capacity` members.
    pub fn reserve(capacity: int) {
        if capacity > 0 {
            self.members.reserve(capacity)
        }
    }

    /// Every member, in the underlying map's order — which is to say, in no
    /// order you may rely on.
    pub fn items() -> List<T> {
        return self.members.keys()
    }

    /// A new set holding every member of either set. Named `union_with`
    /// because `union` is a keyword — the same reason `poll.Interest` spells
    /// its constructor `read_only`.
    pub fn union_with(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        result.reserve(self.len() + other.len())
        result.add_all(self.items())
        result.add_all(other.items())
        return result
    }

    /// A new set holding the members both sets have.
    pub fn intersection(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        // Walk the smaller side: the work is one lookup per member walked.
        let smaller: Set<T> = if self.len() <= other.len() { self } else { other }
        let larger: Set<T> = if self.len() <= other.len() { other } else { self }
        for value: T in smaller.items() {
            if larger.contains(value) { result.add(value) }
        }
        return result
    }

    /// A new set holding the members this set has and `other` does not.
    pub fn difference(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        for value: T in self.items() {
            if !other.contains(value) { result.add(value) }
        }
        return result
    }

    /// A new set holding the members exactly one of the two sets has.
    pub fn symmetric_difference(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        for value: T in self.items() {
            if !other.contains(value) { result.add(value) }
        }
        for value: T in other.items() {
            if !self.contains(value) { result.add(value) }
        }
        return result
    }

    /// True when every member of this set is also a member of `other`.
    pub fn is_subset_of(other: Set<T>) -> bool {
        if self.len() > other.len() { return false }
        for value: T in self.items() {
            if !other.contains(value) { return false }
        }
        return true
    }

    /// True when every member of `other` is also a member of this set.
    pub fn is_superset_of(other: Set<T>) -> bool {
        return other.is_subset_of(self)
    }

    /// True when the two sets share no member.
    pub fn is_disjoint_from(other: Set<T>) -> bool {
        let smaller: Set<T> = if self.len() <= other.len() { self } else { other }
        let larger: Set<T> = if self.len() <= other.len() { other } else { self }
        for value: T in smaller.items() {
            if larger.contains(value) { return false }
        }
        return true
    }

    /// True when the two sets hold exactly the same members. This is what
    /// comparing two sets means; `==` on two class references does not.
    pub fn equals(other: Set<T>) -> bool {
        if self.len() != other.len() { return false }
        for value: T in self.items() {
            if !other.contains(value) { return false }
        }
        return true
    }
}
