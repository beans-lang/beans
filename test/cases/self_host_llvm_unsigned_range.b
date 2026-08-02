// range patterns must compare with the subject's signedness: the
// emitter once pinned every range to sge/sle, so 150u8 — whose
// sign bit reads as -106 — landed outside 100..=200. Unsigned
// subjects take uge/ule/ult; signed subjects keep the s-forms.
import std.io

fn band(value: u8) -> string {
    match value {
        100..=200 => { return "inside" }
        _ => { return "outside" }
    }
}

fn high(value: u8) -> string {
    match value {
        200..=255 => { return "high" }
        _ => { return "low" }
    }
}

fn half(value: u16) -> string {
    match value {
        0..32768 => { return "low" }
        _ => { return "high" }
    }
}

fn small(value: i8) -> string {
    match value {
        -10..=0 => { return "small" }
        _ => { return "other" }
    }
}

fn main() {
    io.println(band(150 as u8))
    io.println(band(99 as u8))
    io.println(band(100 as u8))
    io.println(band(200 as u8))
    io.println(band(201 as u8))
    io.println(band(250 as u8))
    io.println(high(250 as u8))
    io.println(high(255 as u8))
    io.println(high(199 as u8))
    io.println(half(40000 as u16))
    io.println(half(32768 as u16))
    io.println(half(32767 as u16))
    io.println(half(200 as u16))
    io.println(small(-5 as i8))
    io.println(small(-10 as i8))
    io.println(small(0 as i8))
    io.println(small(3 as i8))
    io.println(small(-11 as i8))
}
