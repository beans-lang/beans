// A membership-only collection. `Map<T, bool>` does the same job with a byte
// of storage per member and a value nobody reads; this says what it means, and
// answers the set-algebra questions by walking the maps rather than copying
// their keys out into lists first.

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
/// ## Costs
///
/// `add`, `contains` and `remove` are one `Map` operation each: O(1) expected.
/// The algebra walks the maps directly and never builds an intermediate key
/// list — the cost of each is the number of members it must look at, not the
/// size of both sets:
///
/// - `union_with` clones the larger map (one C-level table copy) and inserts
///   the smaller side's members into the copy: O(larger) to clone, O(smaller)
///   to merge.
/// - `intersection`, `is_disjoint_from` walk the smaller side and probe the
///   larger: O(smaller) lookups.
/// - `difference`, `symmetric_difference` walk one side (both, for the
///   symmetric one) and probe the other: O(this) and O(this + other) lookups.
/// - `is_subset_of`, `equals` walk this side and probe the other with an early
///   exit, and allocate nothing at all beyond the boolean they return.
///
/// `items` is the exception: it exists to hand the members back as a `List<T>`,
/// so it allocates that list and clones each member into it. Reach for it when
/// you want the members, not to drive the algebra — the algebra above no longer
/// needs it.
///
/// The members live in one `Map<T, bool>`, so the storage cost is a map slot
/// plus a byte per member. What this type buys is the API and the algebra, not
/// a smaller footprint — a set with no per-entry value would need a key-only
/// table shape, and the runtime has one associative table (the open-addressed
/// `Map`) and no set-only one. That is a runtime-shape decision, not a stdlib
/// one: the value byte rides in the same cache line as the slot it belongs to,
/// so a dedicated shape would save the byte but not a lookup.
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
    /// order you may rely on. This allocates a list and clones each member into
    /// it; the algebra methods below do not use it.
    pub fn items() -> List<T> {
        return self.members.keys()
    }

    /// A new set holding every member of either set. Named `union_with`
    /// because `union` is a keyword — the same reason `poll.Interest` spells
    /// its constructor `read_only`.
    ///
    /// Clones the larger side's map — one C-level table copy sized for the
    /// result — and inserts the smaller side into the copy, so the work is
    /// O(larger) plus one lookup per member of the smaller side.
    pub fn union_with(other: Set<T>) -> Set<T> {
        let smaller: Set<T> = if self.len() >= other.len() { other } else { self }
        let larger: Set<T> = if self.len() >= other.len() { self } else { other }
        var result: Set<T> = new Set<T>()
        result.members = larger.members.clone()
        for value: T, present: bool in smaller.members {
            result.members.insert(value, true)
        }
        return result
    }

    /// A new set holding the members both sets have. Walks the smaller side and
    /// probes the larger, one lookup per member walked, and never reserves
    /// `self.len() + other.len()`: the result holds at most the smaller side.
    pub fn intersection(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        let smaller: Set<T> = if self.len() <= other.len() { self } else { other }
        let larger: Set<T> = if self.len() <= other.len() { other } else { self }
        for value: T, present: bool in smaller.members {
            if larger.members.contains_key(value) {
                result.members.insert(value, true)
            }
        }
        return result
    }

    /// A new set holding the members this set has and `other` does not. Walks
    /// this side and probes `other`, one lookup per member.
    pub fn difference(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        for value: T, present: bool in self.members {
            if !other.members.contains_key(value) {
                result.members.insert(value, true)
            }
        }
        return result
    }

    /// A new set holding the members exactly one of the two sets has. Walks
    /// both sides, probing the other, one lookup per member.
    pub fn symmetric_difference(other: Set<T>) -> Set<T> {
        var result: Set<T> = new Set<T>()
        for value: T, present: bool in self.members {
            if !other.members.contains_key(value) {
                result.members.insert(value, true)
            }
        }
        for value: T, present: bool in other.members {
            if !self.members.contains_key(value) {
                result.members.insert(value, true)
            }
        }
        return result
    }

    /// True when every member of this set is also a member of `other`. Walks
    /// this side probing `other`, and stops at the first member `other` lacks;
    /// allocates nothing.
    pub fn is_subset_of(other: Set<T>) -> bool {
        if self.len() > other.len() { return false }
        for value: T, present: bool in self.members {
            if !other.members.contains_key(value) { return false }
        }
        return true
    }

    /// True when every member of `other` is also a member of this set.
    pub fn is_superset_of(other: Set<T>) -> bool {
        return other.is_subset_of(self)
    }

    /// True when the two sets share no member. Walks the smaller side probing
    /// the larger, and stops at the first shared member; allocates nothing.
    pub fn is_disjoint_from(other: Set<T>) -> bool {
        let smaller: Set<T> = if self.len() <= other.len() { self } else { other }
        let larger: Set<T> = if self.len() <= other.len() { other } else { self }
        for value: T, present: bool in smaller.members {
            if larger.members.contains_key(value) { return false }
        }
        return true
    }

    /// True when the two sets hold exactly the same members. This is what
    /// comparing two sets means; `==` on two class references does not. Same
    /// length and every member of this set present in `other`, with an early
    /// exit and no allocation.
    pub fn equals(other: Set<T>) -> bool {
        if self.len() != other.len() { return false }
        for value: T, present: bool in self.members {
            if !other.members.contains_key(value) { return false }
        }
        return true
    }
}
