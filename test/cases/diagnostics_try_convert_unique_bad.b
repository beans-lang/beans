// #46: reaching the caller's error type as a subtype must not shed move-only
// ownership. A to_error answering a unique class widened to a shared interface
// is the same erasure a plain widening refuses, in the same words.
interface AppError {
    fn slug() -> string
}

unique class Pinned implements AppError {
    fn init() {}
    pub fn slug() -> string { return "pinned" }
}

class Weird {
    fn init() {}
    fn to_error() -> Pinned { return new Pinned() }
}

fn op() -> Result<int, Weird> {
    return err(new Weird())
}

fn outer() -> Result<int, AppError> {
    let n: int = op()?
    return ok(n)
}
