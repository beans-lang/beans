// #46: the builtin Error cannot carry a to_error, so `?` cannot turn it into a
// custom error. The refusal says so rather than pointing at a missing method.
class MyErr {
    fn init() {}
}

fn inner() -> Result<int, Error> {
    return err(new Error("x"))
}

fn outer() -> Result<int, MyErr> {
    let n: int = inner()?
    return ok(n)
}
