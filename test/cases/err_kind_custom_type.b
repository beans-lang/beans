// A custom error type carries its own fields, so err(message, kind) — which builds the
// built-in Error — cannot be what the caller meant.
class MyError {
    detail: string
    fn init(detail: string) { self.detail = detail }
}
fn f() -> Result<int, MyError> {
    return err("boom", "eof")
}
fn main() { let x: Result<int, MyError> = f() }
