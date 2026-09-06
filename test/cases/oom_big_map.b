// The large-block allocator's two refusal shapes, driven by test/oom.sh.
//
// Blocks at or past the runtime's map threshold are mmap'd so freeing one hands
// its pages back. Two allocators reach that path and they answer a failed
// mapping differently, because they know different things at free time:
//
//   * A Bytes or List backing has no header — its free is told the byte size
//     the allocation was given, and decides munmap-or-free from that size
//     alone. So a block at or past the threshold MUST be a mapping; serving one
//     from the heap instead would hand a malloc'd pointer to munmap. A refused
//     mapping is therefore a refused allocation, and the caller turns it into
//     the runtime's documented "out of memory" panic.
//
//   * A non-pooled beans_alloc object — which is what a large string is —
//     carries a 16-byte prefix recording whether it was mapped, so its free
//     can tell. That one CAN fall back to the heap, and must, since refusing
//     an allocation that can still be served would be a worse answer.
//
// The phases run in that order so one run shows both: the string is built
// after the small buffer and before the backing, so a run with mapping refused
// prints `small` and `string` and then dies on `bytes`.
//
// Sizes are 256 KB so the case does not depend on where the threshold sits, as
// long as it is at or below that; the small buffer is far under any of them.

import std.io

fn main() {
    // Under any threshold this is a plain heap block, so it must succeed even
    // when every mapping is refused.
    let small: Bytes = Bytes.filled(1024, 65)
    io.println("small {small.len()}")

    // A large string: a non-pooled object, prefix-tagged, so a refused mapping
    // falls back to the heap and the string is still built and still correct.
    let text: string = "x".repeat(262144)
    io.println("string {text.len()}")

    // A large Bytes backing: header-less, so a refused mapping is a refused
    // allocation and this line is never reached when mapping is off.
    let big: Bytes = Bytes.filled(262144, 66)
    io.println("bytes {big.len()}")
}
