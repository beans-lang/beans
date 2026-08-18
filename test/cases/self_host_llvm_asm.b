import std.asm
import std.io

fn through_register(value: int) -> int {
    unsafe {
        return asm.value("mov $0, $1", "=r,r", value)
    }
}

fn main() {
    io.println("{through_register(42)} {through_register(0)}")
}
