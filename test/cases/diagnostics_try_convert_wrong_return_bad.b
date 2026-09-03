// #46: a to_error that answers something the caller's error type cannot be
// reached from is not a usable hook. The refusal names what it answered.
class Weird {
    fn init() {}
    fn to_error() -> int { return 0 }
}

fn inner() -> Result<int, Weird> {
    return err(new Weird())
}

fn outer() -> Result<int> {
    let n: int = inner()?
    return ok(n)
}
