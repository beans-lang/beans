// #46: a custom error with no `to_error` cannot cross into a plain Result<T>.
// The `?` must be refused here, at the boundary, naming both types and the
// method that would let them meet — not accepted and left to a backend.
class DbError {
    fn init() {}
}

fn query() -> Result<int, DbError> {
    return err(new DbError())
}

fn service() -> Result<int> {
    let rows: int = query()?
    return ok(rows)
}
