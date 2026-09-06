// Growing a backing across the large-block map threshold must not lose, move
// or truncate a byte.
//
// A Bytes or List backing at or past the runtime's threshold is mmap'd and
// below it malloc'd, so a grow that crosses the line is not a realloc at all:
// it is a fresh block, a memcpy of the overlap, and a release of the old one.
// A grow of an already-mapped block is the same three steps. Nothing asserted
// that the overlap arrives intact — the RSS gate beside this one counts pages,
// not contents, and every other crossing in the suite happens to copy eight
// bytes of an empty buffer, which would survive almost any mistake in the
// copy's length or its direction.
//
// So each of the growth call sites is driven here with a payload large enough
// to see: push, reserve and resize on a Bytes, and push, reserve and insert on
// a List — insert because it also memmoves inside the new block right after
// the copy. Each is run twice: once starting below the threshold so the grow
// crosses it, and once starting above so the grow is map-to-map.
//
// Contents are checked with crc32 over the whole range, which changes if a
// copy started at the wrong offset, stopped short, or landed in the wrong
// block. Every number is printed rather than compared in the program, so the
// two backends are diffed against each other and against a golden.
//
// The sizes are chosen against a 256 KB (262144-byte) threshold, and a Bytes
// or List capacity only ever doubles, so which side of the line a case lands on
// is a property of the number written here. Move the threshold and these stop
// crossing — they keep passing, having tested nothing — so test/rss_release.sh
// pins the threshold's value and fails if it changes, which is the signal to
// come back and retune every size below.

import std.io

// A byte that changes with the index in a way a shifted copy cannot reproduce:
// the period is 251, which shares no factor with any power of two or any page
// size, so a copy off by a page or by a power of two lands on a different
// value at every index rather than realigning.
fn pattern_byte(index: int) -> int {
    return (index % 251) + 1
}

fn built_by_push(count: int) -> Bytes {
    let out: Bytes = new Bytes(0)
    for index: int in 0..count {
        out.push(pattern_byte(index))
    }
    return move out
}

// Bytes.filled is one memset, so a big block is cheap to make; the markers put
// distinguishable values on and around every size a copy could stop at.
fn filled_with_markers(count: int, base: int) -> Bytes {
    let out: Bytes = Bytes.filled(count, base)
    let marks: List<int> = [0, 1, 4095, 4096, 65535, 65536, 65537,
                            131071, 131072, 131073, 262143, 262144, 262145,
                            524287, 524288]
    for i: int in 0..marks.len() {
        let at: int = marks[i]
        if at < count { out.set(at, (i % 200) + 40) }
    }
    if count > 0 { out.set(count - 1, 199) }
    return move out
}

fn report(label: string, b: Bytes) {
    io.println("{label} len {b.len()} crc {b.crc32(0, b.len())}")
}

// A positional weight so a list that lost an element, or kept them in the
// wrong order, does not collide with the right answer.
fn list_digest(values: List<int>) -> int {
    var total: int = 0
    for i: int in 0..values.len() {
        total = (total * 31 + values[i] * (i + 7)) % 1000000007
    }
    return total
}

fn main() {
    // --- Bytes: push, from an empty buffer up past two doublings of the
    // threshold. The doublings go 8, 16, ... 131072 (heap), 262144 (mapped),
    // 524288 (mapped), so this crosses once and then grows map-to-map.
    let pushed: Bytes = built_by_push(300000)
    report("bytes-push", pushed)

    // --- Bytes: reserve, heap block to mapped block, with a real payload to
    // copy. 200000 bytes sits under the threshold; the reserve doubles it to
    // 400000, which is over.
    let grown: Bytes = filled_with_markers(200000, 65)
    let before_grown: int = grown.crc32(0, grown.len())
    grown.reserve(300000)
    io.println("bytes-reserve-cross len {grown.len()} crc {grown.crc32(0, grown.len())} unchanged {grown.crc32(0, grown.len()) == before_grown}")

    // --- Bytes: reserve, mapped block to a larger mapped block. 300000 is
    // already over the threshold, so this is the map-to-map copy.
    let mapped: Bytes = filled_with_markers(300000, 66)
    let before_mapped: int = mapped.crc32(0, mapped.len())
    mapped.reserve(700000)
    io.println("bytes-reserve-mapped len {mapped.len()} crc {mapped.crc32(0, mapped.len())} unchanged {mapped.crc32(0, mapped.len()) == before_mapped}")

    // --- Bytes: resize across the threshold. The kept prefix must survive the
    // copy and the regrown range must read zero, which is the rule resize has
    // whichever side of the threshold it lands on. 100000 doubles to 200000 and
    // then to 400000, which is over.
    let resized: Bytes = filled_with_markers(100000, 67)
    let before_resized: int = resized.crc32(0, 100000)
    resized.resize(300000)
    io.println("bytes-resize len {resized.len()} kept {resized.crc32(0, 100000) == before_resized} tail-crc {resized.crc32(100000, 300000)}")

    // --- List: push across the threshold. Slots are eight bytes, so the
    // capacity doublings cross at 32768 slots = 262144 bytes and grow
    // map-to-map at 65536 slots after that.
    var ints: List<int> = []
    for index: int in 0..70000 {
        ints.push(index * 3 + 1)
    }
    io.println("list-push len {ints.len()} digest {list_digest(ints)} first {ints[0]} last {ints[ints.len() - 1]}")

    // --- List: reserve from a heap backing (16384 slots = 131072 bytes) to a
    // mapped one (32768 slots = 262144 bytes), copying 128 KB of live slots.
    var reserved: List<int> = []
    for index: int in 0..16384 {
        reserved.push(index * 7 + 2)
    }
    let before_reserved: int = list_digest(reserved)
    reserved.reserve(20000)
    io.println("list-reserve len {reserved.len()} unchanged {list_digest(reserved) == before_reserved} digest {list_digest(reserved)}")

    // --- List: insert at the front on a full heap backing, which grows across
    // the threshold and then memmoves every live slot up one inside the new
    // block. Pushing exactly 16384 (131072 bytes, the last heap doubling)
    // leaves length equal to capacity, so the insert is the call that grows.
    var inserted: List<int> = []
    for index: int in 0..16384 {
        inserted.push(index * 11 + 5)
    }
    inserted.insert(0, 424242)
    io.println("list-insert len {inserted.len()} head {inserted[0]} second {inserted[1]} last {inserted[inserted.len() - 1]} digest {list_digest(inserted)}")
}
