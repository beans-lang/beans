// What a program can still do with no operating system underneath it.
//
// Built with `--runtime freestanding`, this links against a runtime that calls no libc
// at all. Memory, output and exit come from five hooks the surrounding program supplies:
//
//     void* beans_host_alloc(unsigned long long size, unsigned long long align)
//     void* beans_host_realloc(void* block, unsigned long long size)
//     void  beans_host_free(void* block)
//     void  beans_host_write(int stream, const char* bytes, unsigned long long len)
//     void  beans_host_exit(int code)
//
// Everything below is arithmetic, containers, strings and decimal — none of which needs
// a kernel. What is *absent* is the point: no files, no sockets, no processes, no clocks,
// no threads, no environment. The compiler refuses those at check time under this
// profile, naming the capability, rather than letting the link fail on a mangled symbol.
//
// This is the same source `make test` runs on the full runtime, so the output being
// identical either way is the actual claim.

import std.io
import std.collections

// Reference counting works: this object's deinit runs at a knowable moment, with the
// memory coming from and going back to the host's allocator.
class Ledger {
    pub name: string
    entries: List<int> = []

    pub fn init(name: string) {
        self.name = name
    }

    pub fn add(amount: int) -> Ledger {
        self.entries.push(amount)
        return self
    }

    pub fn total() -> int {
        var sum: int = 0
        for e: int in self.entries {
            sum += e
        }
        return sum
    }

    pub fn count() -> int {
        return self.entries.len()
    }
}

// Containers grow, which means the host's realloc is doing real work.
fn containers() {
    var words: List<string> = []
    var i: int = 0
    for i < 200 {
        words.push("entry {i}")
        i += 1
    }
    io.println("built {words.len()} strings")

    var lengths: Map<string, int> = {}
    for w: string in words {
        lengths.set(w, w.len())
    }
    io.println("indexed {lengths.len()} of them")

    var total: int = 0
    for w: string in words {
        total += lengths.get(w).or(0)
    }
    io.println("their names are {total} bytes altogether")

    words.sort()
    io.println("first sorted is {words.first().or("none")}")
    words.clear()
    io.println("cleared, now {words.len()}")
}

// Decimal is exact arithmetic on a 128-bit coefficient. It needs the compiler's 128-bit
// division helpers — which every freestanding toolchain provides — and nothing else.
fn money() {
    let price: decimal = 19.99
    let quantity: decimal = 3
    let subtotal: decimal = price * quantity
    io.println("three at 19.99 is {subtotal}")
    io.println("and exactly 59.97 {subtotal == 59.97}")

    // The failure that floats have and decimal does not.
    let tenth: decimal = 0.1
    var running: decimal = 0
    var i: int = 0
    for i < 10 {
        running = running + tenth
        i += 1
    }
    io.println("ten tenths make exactly one {running == 1}")
}

// Text, including the number formatting the runtime now does itself rather than through
// snprintf. Every panic message and every printed integer goes through that code.
fn text() {
    let big: int = 9223372036854775807
    io.println("the largest int is {big}")
    let small: int = 0 - 9223372036854775807
    io.println("and going the other way {small - 1}")
    let parsed: int = "12345".to_int().or(0)
    io.println("parsed back {parsed}")
    let joined: string = ["a", "b", "c"].join("-")
    io.println("joined {joined}")
    io.println("upper {"beans".to_upper()} and sliced {"freestanding".slice(0, 4)}")
}

// Ownership still ends deterministically with no OS to help.
fn ownership() {
    var books: Ledger = new Ledger("main")
    books.add(100).add(250).add(-50)
    io.println("{books.name} has {books.count()} entries totalling {books.total()}")
}

fn main() {
    containers()
    money()
    text()
    ownership()
    io.println("done with no operating system underneath")
}
