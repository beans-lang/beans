// #162 across a package boundary. The receiver of a static call written
// `box.Holder.wrap(3)` is a package-qualified name, which reaches the checker
// through a different path than the bare `Holder.wrap(3)` of a single file —
// and the type it names was lowered while a different file was being checked.
// A promoted owner parameter has to bind the same way through both.
package box

pub class Holder<T> {
    pub value: Option<T> = none

    pub fn init() {}

    pub static fn wrap(value: T) -> Holder<T> {
        let held: Holder<T> = new Holder<T>()
        held.value = some(value)
        return held
    }

    pub static fn empty() -> Holder<T> { return new Holder<T>() }

    pub static fn pair(left: T, right: T) -> List<T> {
        return [left, right]
    }

    // the class's parameter beside the method's own, across the boundary
    pub static fn labelled<U>(value: T, note: U) -> Holder<T> {
        return Holder.wrap(value)
    }
}

pub class Sorted<K implements Order> {
    pub key: Option<K> = none

    pub fn init() {}

    pub static fn between(low: K, high: K) -> bool { return low < high }
}
