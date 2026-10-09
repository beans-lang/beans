// The freestanding runtime uses no libc; the host supplies these five hooks:
//
//     void* beans_host_alloc(unsigned long long size, unsigned long long align)
//     void* beans_host_realloc(void* block, unsigned long long size)
//     void  beans_host_free(void* block)
//     void  beans_host_write(int stream, const char* bytes, unsigned long long len)
//     void  beans_host_exit(int code)
//
// The compiler rejects OS capabilities at check time. `make test` runs this source under both runtimes.

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

// Decimal uses a 128-bit coefficient; division helpers are its only runtime support.
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
