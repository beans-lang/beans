// ok() carries exactly one value; the kind form is err-only.
fn f() -> Result<int> {
    return ok(1, 2)
}
fn main() { let x: Result<int> = f() }
