// A program for a microcontroller: 32-bit, no operating system, no libc.
//
// This is `examples/freestanding.b` taken one step further down. That one drops the OS;
// this one also drops the assumption that the machine is 64-bit, which turns out to be a
// much sharper constraint:
//
//   * a pointer is four bytes, so every object header, pointer-slot mask and container
//     stride is a different size than on the host;
//   * `int` is still 64 bits, so ordinary division and modulo become calls into the
//     compiler's runtime helpers rather than one instruction;
//   * there is no 64-bit atomic instruction, so the reference counts cannot be atomic —
//     which is fine, because a freestanding build has one thread by construction;
//   * `decimal` is missing entirely. Clang has no 128-bit integer type on 32-bit ARM or
//     RV32, so the type is refused at check time, naming the target. That is why this
//     example exists next to freestanding.b instead of replacing it.
//
// Built for `thumbv7em-none-eabi` and `riscv32-unknown-none-elf`, linked against the
// twelve-symbol host in test/fixtures/embedded_host.c, and run on a QEMU Cortex-M4 and
// RISC-V board by test/embedded.sh. It also runs on the host under the full runtime,
// which is the point: the output has to be identical everywhere.

import std.io
import std.collections

// Deterministic destruction with four-byte pointers: the generic destructor walks this
// object's fields through a mask whose stride is the *target's* pointer size. Getting
// that wrong drops children on the floor, which shows up here as a wrong count.
class Sensor {
    pub label: string
    samples: List<int> = []
    closed: bool = false

    pub fn init(label: string) {
        self.label = label
    }

    pub fn record(value: int) -> Sensor {
        self.samples.push(value)
        return self
    }

    pub fn peak() -> int {
        var best: int = 0
        for s: int in self.samples {
            if s > best { best = s }
        }
        return best
    }

    pub fn count() -> int {
        return self.samples.len()
    }

    fn deinit() {
        self.closed = true
        io.println("closing {self.label} after {self.samples.len()} samples")
    }
}

// 64-bit arithmetic on a 32-bit machine. Every one of these is a libcall on both
// embedded targets, and each has a sign convention that is easy to get wrong: C
// truncates division toward zero, so a negative quotient rounds up, and the remainder
// keeps the sign of the dividend.
fn wide_arithmetic() {
    let big: int = 9223372036854775807
    io.println("the largest int is {big}")
    io.println("one less doubles down to {(big - 1) / 2}")
    io.println("negative division truncates toward zero: {(0 - 7) / 2}")
    io.println("and the remainder keeps the sign: {(0 - 7) % 2}")

    // A multiply that overflows 32 bits several times over, then divides back down.
    var product: int = 1
    var i: int = 1
    for i <= 20 {
        product = product * i
        i += 1
    }
    io.println("twenty factorial is {product}")
    io.println("divided by nineteen factorial gives {product / 121645100408832000}")

    // Shifts across the 32-bit boundary, which is where a naive 64-bit shift helper
    // gives zero instead of the high word.
    let one: int = 1
    io.println("bit 40 is {one << 40} and back down {(one << 40) >> 40}")
}

// Floating point with no FPU: thumbv7em-none-eabi is the soft-float ABI, so every one
// of these goes through the compiler's double-precision helpers.
fn soft_float() {
    let half: float = 0.5
    let third: float = 1.0 / 3.0
    io.println("half plus a third is {half + third}")
    io.println("and ordering still works: {third < half}")
}

// Containers, which is where the allocator, the pointer-slot stride and the string
// formatter all get exercised at once.
fn containers() {
    var readings: List<int> = []
    var i: int = 0
    for i < 120 {
        readings.push(i * i)
        i += 1
    }
    io.println("collected {readings.len()} readings")

    var index: Map<string, int> = {}
    for r: int in readings {
        index.set("r{r}", r)
    }
    io.println("indexed {index.len()} of them")

    var total: int = 0
    for r: int in readings {
        total += index.get("r{r}").or(0)
    }
    io.println("their squares total {total}")

    readings.clear()
    io.println("cleared, now {readings.len()}")
}

// A reference cycle, collected by trial deletion. The collector reads pointer slots
// through the same target-sized stride the destructor does, so a 32-bit mistake here
// is a use-after-free rather than a wrong number — which is why it is worth running
// under an emulator instead of only compiling.
class Node {
    pub name: string
    pub link: Option<Node> = none

    pub fn init(name: string) {
        self.name = name
    }
}

fn cycles() {
    var first: Node = new Node("first")
    var second: Node = new Node("second")
    first.link = some(second)
    second.link = some(first)
    io.println("linked {first.name} to {second.link.or(first).name}")
}

fn ownership() {
    var left: Sensor = new Sensor("left")
    left.record(3).record(41).record(17)
    io.println("{left.label} peaked at {left.peak()} over {left.count()} samples")
}

// Virtual dispatch through the class descriptor, which is `{i64 id, [N x ptr]}`: the
// id is eight bytes on every target, but the method slots after it are pointer sized —
// four bytes here. Six implementations is past the point where the compiler emits
// guarded direct calls, so the loop below goes through the table indirectly, and an
// index counted in pointer strides instead of bytes reads the high half of the class
// id and calls it. On the 64-bit host the two spellings agree, so only this run can
// tell them apart.
class Pin {
    pub number: int

    pub fn init(number: int) {
        self.number = number
    }

    pub fn strength() -> int {
        return 0
    }
}

class Input extends Pin {
    pub fn init(number: int) { super.init(number) }
    pub override fn strength() -> int { return 1 }
}

class Output extends Pin {
    pub fn init(number: int) { super.init(number) }
    pub override fn strength() -> int { return 2 }
}

class Pwm extends Pin {
    pub fn init(number: int) { super.init(number) }
    pub override fn strength() -> int { return 3 }
}

class Analog extends Pin {
    pub fn init(number: int) { super.init(number) }
    pub override fn strength() -> int { return 4 }
}

class I2c extends Pin {
    pub fn init(number: int) { super.init(number) }
    pub override fn strength() -> int { return 5 }
}

fn dispatch() {
    var pins: List<Pin> = []
    pins.push(new Pin(0))
    pins.push(new Input(1))
    pins.push(new Output(2))
    pins.push(new Pwm(3))
    pins.push(new Analog(4))
    pins.push(new I2c(5))
    var total: int = 0
    for pin: Pin in pins {
        total += pin.strength()
    }
    io.println("six pins drive a total strength of {total}")
}

fn main() {
    wide_arithmetic()
    soft_float()
    containers()
    cycles()
    ownership()
    dispatch()
    io.println("done on a 32-bit machine with no operating system")
}
