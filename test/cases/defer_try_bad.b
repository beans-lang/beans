fn fallible() -> Result<int> {
    return err("no")
}

fn invalid_defer() -> Result<int> {
    defer fallible()?
    return ok(1)
}
