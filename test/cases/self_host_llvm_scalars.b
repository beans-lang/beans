// The scalar-and-token batch through the self-host LLVM emitter:
// string ordering, Bytes equality, std.intrinsic rows on LLVM's own
// intrinsics, int/float abs and round, weak references, record field
// assignment through the local's storage, and Result carrying a
// plain string error. cpu.has lives in its own case because feature
// names are per-architecture and this one cross-compiles.
import std.io
import std.intrinsic

class Node {
    label: string

    fn init(label: string) {
        self.label = label
    }
}

struct Entry {
    path: string
    count: int
}

fn pick(flag: bool) -> Result<Node, string> {
    if flag {
        return ok(new Node("chosen"))
    }
    return err("nothing to pick")
}

fn main() {
    let words: List<string> = ["pear", "apple", "plum"]
    var smallest: string = words[0]
    for word: string in words {
        if word < smallest {
            smallest = word
        }
    }
    io.println("smallest {smallest}")
    io.println("ordered {"abc" <= "abd"} {"b" > "a"} {"z" >= "z"}")

    let left: Bytes = Bytes.from("beans")
    let right: Bytes = Bytes.from("beans")
    let other: Bytes = Bytes.from("toast")
    io.println("bytes {left == right} {left != other}")

    unsafe {
        let ones: int = intrinsic.popcount(255)
        let leading: int = intrinsic.leading_zeros(1)
        let trailing: int = intrinsic.trailing_zeros(8)
        io.println("bits {ones} {leading} {trailing}")
        let swap16: int = intrinsic.bswap16(4660)
        let swap32: int = intrinsic.bswap32(4660)
        let swap64: int = intrinsic.bswap64(1)
        io.println("swaps {swap16} {swap32} {swap64}")
        let spun_left: int = intrinsic.rotate_left(1, 4)
        let spun_right: int = intrinsic.rotate_right(16, 4)
        io.println("spin {spun_left} {spun_right}")
        let root: float = intrinsic.sqrt(81.0)
        let fused: float = intrinsic.fma(2.0, 3.0, 1.0)
        io.println("roots {root} {fused}")
    }

    io.println("abs {(0 - 9).abs()} {(0.0 - 2.5).abs()} {(2.6).round()}")

    var entry: Entry = Entry { path: "src", count: 1 }
    entry.path = "lib"
    entry.count += 41
    io.println("entry {entry.path} {entry.count}")

    let strong: Shared<Node> = new Shared(new Node("kept"))
    let weak: Weak<Node> = strong.downgrade()
    io.println("expired before {weak.is_expired()}")
    match weak.upgrade() {
        some(again) => { io.println("upgraded {again.get().label}") }
        none => { io.println("gone") }
    }

    match pick(true) {
        ok(node) => { io.println("picked {node.label}") }
        err(reason) => { io.println("failed {reason}") }
    }
    match pick(false) {
        ok(node) => { io.println("picked {node.label}") }
        err(reason) => { io.println("failed {reason}") }
    }
}
