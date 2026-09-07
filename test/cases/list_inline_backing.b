// A small list's element buffer lives inside the list's own allocation, right
// behind the 48-byte header; a list that outgrows it moves to a buffer of its
// own. This drives every list operation on both sides of that move, and the
// move itself, for element widths that land either side of the threshold.
//
// The sizes are printed, not assumed: if a struct's layout changes and moves a
// case across the boundary, the golden says so instead of silently testing one
// side twice.
//
//   generic slot element   8 bytes -> 4 slots =  32   inline
//   Pair                  16 bytes -> 4 slots =  64   inline
//   Quad                  32 bytes -> 4 slots = 128   inline, exactly at the edge
//   Five                  40 bytes -> 4 slots = 160   its own buffer from the start
//
// Lengths 0..5 straddle the initial capacity of 4, 17 forces two doublings, and
// 100 forces the buffer well past anything that could ride inside a block.

import std.io

struct Pair {
    pub a: int
    pub b: int
}

struct Quad {
    pub a: int
    pub b: int
    pub c: int
    pub d: int
}

struct Five {
    pub a: int
    pub b: int
    pub c: int
    pub d: int
    pub e: int
}

class Tag {
    pub name: string
    pub fn init(name: string) {
        self.name = name
    }
}

fn mix(seed: int) -> int {
    return (seed * 2654435761) % 100003
}

// ---- generic slot lists (one 8-byte slot per element) ----------------------

fn ints_of(count: int) -> List<int> {
    var out: List<int> = []
    for index: int in 0..count {
        out.push(mix(index + 1))
    }
    return move out
}

fn digest_ints(values: List<int>) -> int {
    var total: int = 7
    for index: int in 0..values.len() {
        total = (total * 31 + values[index] + index) % 1000000007
    }
    return total
}

fn drive_ints(count: int) {
    var values: List<int> = ints_of(count)
    io.println("ints n={count} len={values.len()} digest={digest_ints(values)}")

    // insert at the front, the middle and the end: each one may be the push
    // that moves the buffer, and each one memmoves what was already there.
    values.insert(0, 11)
    values.insert(values.len() / 2, 22)
    values.insert(values.len(), 33)
    io.println("  after insert len={values.len()} digest={digest_ints(values)}")

    // slice and clone build a list at an exact capacity, which is the other
    // constructor that decides inline-or-not.
    let copy: List<int> = values.clone()
    let head: List<int> = values.slice(0, values.len() / 2)
    io.println("  clone={digest_ints(copy)} head len={head.len()} digest={digest_ints(head)}")

    // remove from both ends and the middle, then read what is left.
    if values.len() >= 3 {
        let front: int = values.remove(0)
        let middle: int = values.remove(values.len() / 2)
        let back: int = values.remove(values.len() - 1)
        io.println("  removed {front} {middle} {back} len={values.len()}")
    }

    values.reverse()
    io.println("  reversed digest={digest_ints(values)}")
    values.sort()
    io.println("  sorted digest={digest_ints(values)} first={values.first()} last={values.last()}")

    // reserve past the inline room, then keep pushing into the new buffer.
    values.reserve(64)
    for index: int in 0..8 {
        values.push(index)
    }
    io.println("  reserved+pushed len={values.len()} digest={digest_ints(values)}")

    // clear keeps the buffer and the length goes back to zero; pushing after
    // it must land in whichever buffer the list is holding by then.
    values.clear()
    for index: int in 0..3 {
        values.push(index * 5)
    }
    io.println("  cleared+pushed len={values.len()} digest={digest_ints(values)}")

    for values.len() > 0 {
        let _: Option<int> = values.pop()
    }
    io.println("  drained len={values.len()}")
}

// ---- lists of inline struct elements ---------------------------------------

fn drive_pairs(count: int) {
    var rows: List<Pair> = []
    for index: int in 0..count {
        rows.push(Pair { a: index, b: mix(index) })
    }
    var total: int = 0
    for index: int in 0..rows.len() {
        total = (total * 17 + rows[index].a * 3 + rows[index].b) % 1000000007
    }
    rows.insert(0, Pair { a: -1, b: -2 })
    let copy: List<Pair> = rows.clone()
    let part: List<Pair> = rows.slice(1, rows.len())
    io.println("pairs n={count} len={rows.len()} total={total} copy={copy.len()} part={part.len()} first={rows[0].a}")
}

fn drive_quads(count: int) {
    var rows: List<Quad> = []
    for index: int in 0..count {
        rows.push(Quad { a: index, b: index + 1, c: index + 2, d: mix(index) })
    }
    var total: int = 0
    for index: int in 0..rows.len() {
        let row: Quad = rows[index]
        total = (total * 13 + row.a + row.b + row.c + row.d) % 1000000007
    }
    rows.reserve(40)
    rows.push(Quad { a: 9, b: 9, c: 9, d: 9 })
    let copy: List<Quad> = rows.clone()
    io.println("quads n={count} len={rows.len()} total={total} copy={copy.len()} last={rows[rows.len() - 1].d}")
}

fn drive_fives(count: int) {
    var rows: List<Five> = []
    for index: int in 0..count {
        rows.push(Five { a: index, b: index + 1, c: index + 2, d: index + 3, e: mix(index) })
    }
    var total: int = 0
    for index: int in 0..rows.len() {
        let row: Five = rows[index]
        total = (total * 11 + row.a + row.e) % 1000000007
    }
    rows.insert(0, Five { a: 0, b: 0, c: 0, d: 0, e: 0 })
    let part: List<Five> = rows.slice(0, rows.len())
    io.println("fives n={count} len={rows.len()} total={total} part={part.len()}")
}

// ---- lists that own references ---------------------------------------------
//
// Every element here is a heap object the list owns. Growing the buffer must
// carry the references across without retaining or releasing them, and freeing
// the list must release each one exactly once — which is what the sanitizer
// lane of this case is checking.

fn drive_tags(count: int) {
    var tags: List<Tag> = []
    for index: int in 0..count {
        tags.push(new Tag("tag-{index}"))
    }
    var names: List<string> = []
    for index: int in 0..tags.len() {
        names.push(tags[index].name)
    }
    tags.insert(0, new Tag("head"))
    let copy: List<Tag> = tags.clone()
    let sliced: List<Tag> = tags.slice(0, tags.len() / 2 + 1)
    io.println("tags n={count} len={tags.len()} names={names.join(",")} copy={copy.len()} sliced={sliced.len()} first={tags[0].name}")
    if tags.len() >= 2 {
        let gone: Tag = tags.remove(1)
        io.println("  removed {gone.name} len={tags.len()}")
    }
    tags.clear()
    io.println("  cleared len={tags.len()}")
}

fn drive_strings(count: int) {
    var words: List<string> = []
    for index: int in 0..count {
        words.push("w{mix(index)}")
    }
    words.sort()
    let joined: string = words.join("|")
    let copy: List<string> = words.clone()
    copy.reverse()
    io.println("strings n={count} len={words.len()} joined_len={joined.len()} copy_first={copy.first()}")
}

// ---- lists of lists ---------------------------------------------------------

fn drive_nested(count: int) {
    var rows: List<List<int>> = []
    for index: int in 0..count {
        var row: List<int> = []
        for step: int in 0..(index % 6) {
            row.push(index * 10 + step)
        }
        rows.push(move row)
    }
    var total: int = 0
    for index: int in 0..rows.len() {
        total = total + rows[index].len()
    }
    io.println("nested n={count} rows={rows.len()} elements={total}")
}

// ---- map-built lists --------------------------------------------------------
//
// keys() and values() build a list at the map's exact size, which is the
// exact-capacity constructor again, reached from somewhere other than slice.

fn drive_map_lists(count: int) {
    var counts: Map<int, int> = {}
    for index: int in 0..count {
        counts[index] = mix(index)
    }
    var keys: List<int> = counts.keys()
    var values: List<int> = counts.values()
    keys.sort()
    values.sort()
    io.println("map n={count} keys={keys.len()} values={values.len()} key_digest={digest_ints(keys)} value_digest={digest_ints(values)}")
}

fn main() {
    io.println("sizes pair={size_of(Pair)} quad={size_of(Quad)} five={size_of(Five)}")

    let lengths: List<int> = [0, 1, 3, 4, 5, 17, 100]
    for index: int in 0..lengths.len() {
        drive_ints(lengths[index])
    }
    for index: int in 0..lengths.len() {
        drive_pairs(lengths[index])
        drive_quads(lengths[index])
        drive_fives(lengths[index])
    }
    for index: int in 0..lengths.len() {
        drive_tags(lengths[index])
        drive_strings(lengths[index])
        drive_nested(lengths[index])
        drive_map_lists(lengths[index])
    }
    io.println("done")
}
