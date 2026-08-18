// err(message, kind) takes two strings; a number is not a slug.
fn f() -> Result<int> {
    return err(1, 2)
}
fn main() { let x: Result<int> = f() }
