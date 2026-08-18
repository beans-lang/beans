// A function value must not erase the feature requirement of its source function.
import std.cpu

feature "aes" fn needs_aes() -> int { return 1 }

fn main() {
    let erased: fn() -> int = needs_aes
    let value: int = erased()
}
