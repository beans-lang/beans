// #46: `?` calls to_error with no arguments on the error, so a to_error that
// demands a parameter is refused as unusable rather than silently skipped.
class Weird {
    fn init() {}
    fn to_error(extra: int) -> Error { return new Error("x") }
}

fn inner() -> Result<int, Weird> {
    return err(new Weird())
}

fn outer() -> Result<int> {
    let n: int = inner()?
    return ok(n)
}
