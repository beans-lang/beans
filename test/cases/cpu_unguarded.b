// A feature-marked function called where the feature is not known present.
import std.cpu

feature "aes" fn needs_aes() -> int { return 1 }

fn main() {
    let v: int = needs_aes()
}
