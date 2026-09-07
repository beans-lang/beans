// A decoded string leaves the pooled size classes at 992 bytes.
//
// The typed decoder allocates a decoded string's payload with
// beans_alloc_bytes, which pools blocks under 1024 bytes total (16 of header
// plus the bytes plus the NUL, rounded to 16) and takes a non-pooled arm above
// that. Both arms are freed by one release path, and that path frees a
// non-pooled block through rt_obj_free — which reads the 16-byte origin prefix
// rt_obj_alloc writes in front of the object. An arm that allocated without
// that prefix therefore freed a pointer no allocator ever returned.
//
// So this walks a decoded string across every boundary the allocator has:
// nothing, one byte, the last pooled size, the first non-pooled size, sizes
// either side of it, and a string past RT_BIG_MMAP_MIN (256 KiB) where the
// prefix records a mapping rather than a malloc. Each size is decoded and
// dropped many times over, because the fault is in the free and one free may
// land on a prefix that happens to read as zero. Lists of records cover n = 0,
// 1, 2 and many so the same payloads are also reached through a list's
// element storage rather than a single struct.
//
// Typed decoding is native only (the tree interpreter answers kind
// "unsupported"), so this case, like the other typed cases, is a native gate.
import std.io
import std.encoding.json
import std.fmt as fmt

struct Row {
    pub id: u64
    pub name: string
    pub note: string
}

fn filler(n: int) -> string {
    if n <= 0 { return "" }
    let bytes: Bytes = Bytes.filled(n, 120)
    return bytes.to_string()
}

fn document(len: int) -> string {
    let body: string = filler(len)
    return "\{\"id\":7,\"name\":\"{body}\",\"note\":\"tail\"\}"
}

// Decode `rounds` times at `len` and report how many came back whole. A
// mismatch is reported as a count, never as the string itself: at 300 KiB the
// transcript would be the test.
fn sweep(len: int, rounds: int) -> int {
    var good: int = 0
    for _: int in 0..rounds {
        let result: Result<Row> = json.decode(document(len))
        match result {
            ok(row) => {
                if row.id == 7 && row.name.len() == len && row.note == "tail" {
                    good += 1
                }
            }
            err(_) => {}
        }
    }
    return good
}

fn list_document(count: int, len: int) -> string {
    let body: string = filler(len)
    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("[")
    for index: int in 0..count {
        if index != 0 { out.push(",") }
        out.push("\{\"id\":7,\"name\":\"{body}\",\"note\":\"tail\"\}")
    }
    out.push("]")
    return out.to_string()
}

fn sweep_list(count: int, len: int, rounds: int) -> int {
    var good: int = 0
    for _: int in 0..rounds {
        let result: Result<List<Row>> = json.decode(list_document(count, len))
        match result {
            ok(rows) => {
                var whole: int = 0
                for row: Row in rows {
                    if row.name.len() == len && row.note == "tail" { whole += 1 }
                }
                if whole == count { good += 1 }
            }
            err(_) => {}
        }
    }
    return good
}

fn main() {
    // Either side of the pooled/non-pooled boundary, one byte at a time: the
    // last size that pools is 991, the first that does not is 992.
    var boundary_good: int = 0
    var boundary_total: int = 0
    for len: int in 985..1000 {
        boundary_good += sweep(len, 40)
        boundary_total += 40
    }
    io.println("boundary: {boundary_good}/{boundary_total}")

    // The small sizes the same code takes when nothing leaves the pool, so a
    // fix that broke the pooled arm would show here rather than nowhere.
    io.println("empty: {sweep(0, 40)}/40")
    io.println("one: {sweep(1, 40)}/40")
    io.println("two: {sweep(2, 40)}/40")

    // Well past the boundary, many times: the arm that malloc'd without the
    // prefix aborts here within a few dozen frees.
    io.println("wide: {sweep(4096, 200)}/200")

    // Past RT_BIG_MMAP_MIN, where the origin prefix records a mapping length
    // and a wrong free is an munmap of whatever sat in front of the block.
    io.println("mapped: {sweep(300000, 8)}/8")

    // The same payloads reached through a list's element storage.
    io.println("list0: {sweep_list(0, 4096, 20)}/20")
    io.println("list1: {sweep_list(1, 4096, 20)}/20")
    io.println("list2: {sweep_list(2, 4096, 20)}/20")
    io.println("listn: {sweep_list(64, 4096, 20)}/20")
    io.println("ok json_typed_large_strings")
}
