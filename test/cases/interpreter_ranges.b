import std.io

class RangeDrop {
    name: string

    pub fn init(name: string) {
        self.name = name
    }

    fn deinit() {
        io.println("drop {self.name}")
    }
}

fn lower() -> int {
    io.println("lower evaluated")
    return 2
}

fn upper() -> int {
    io.println("upper evaluated")
    return 5
}

fn early_return() -> int {
    defer io.println("return defer")
    for value: int in 0..3 {
        let held: RangeDrop = new RangeDrop("return {value}")
        return value + 40
    }
    return -1
}

fn main() {
    var sum: int = 0
    for value: int in lower()..upper() {
        sum += value
    }
    io.println("once {sum}")

    var high: int = 5
    var fixed: int = 0
    for value: int in 2..high {
        high = 2
        fixed += value
    }
    io.println("fixed {fixed}")

    var empty: int = 0
    let unsigned_low: u8 = 254
    let unsigned_high: u8 = 255
    for value: int in 5..5 { empty += 1 }
    for value: int in 5..4 { empty += 1 }
    for value: int in 5..=4 { empty += 1 }
    for value: u8 in unsigned_high..unsigned_low { empty += 1 }
    for value: u8 in unsigned_high..=unsigned_low { empty += 1 }
    io.println("empty {empty}")

    let signed_low: i8 = -128
    let signed_low_end: i8 = -126
    let signed_high_start: i8 = 126
    let signed_high: i8 = 127
    for value: i8 in signed_low..=signed_low_end {
        io.println("i8 low {value}")
    }
    for value: i8 in signed_high_start..=signed_high {
        io.println("i8 high {value}")
    }
    for value: u8 in unsigned_low..=unsigned_high {
        io.println("u8 high {value}")
    }
    for value: int in 9223372036854775806..=9223372036854775807 {
        io.println("int high {value}")
        continue
    }
    let wide_low: u64 = 18446744073709551614
    let wide_high: u64 = 18446744073709551615
    for value: u64 in wide_low..=wide_high {
        io.println("u64 high {value}")
        continue
    }

    var reads: List<fn() -> int> = []
    for value: int in 4..7 {
        reads.push(fn() -> int { return value })
    }
    for read: fn() -> int in reads {
        io.println("captured {read()}")
    }

    for value: int in 0..4 {
        let held: RangeDrop = new RangeDrop("loop {value}")
        if value == 0 { continue }
        break
    }
    io.println("returned {early_return()}")
}
