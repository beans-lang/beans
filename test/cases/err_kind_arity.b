// Two arguments at most: a message and a kind.
fn f() -> Result<int> {
    return err("boom", "eof", "extra")
}
fn main() { let x: Result<int> = f() }
