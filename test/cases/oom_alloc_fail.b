// Drives every runtime allocation site that #108 fixed: the map insert path
// (untyped and typed grows, the deadbits grow a removed key leaves behind, the
// index rebuild a growing map triggers, and reserve), plus the two other
// container-storage grows that had the same unchecked-realloc omission — an
// untyped List insert and a Bytes append. The managed-key and managed-value
// maps also make a refused grow run its owned-reference release before it
// panics, so that path is exercised under the sanitizers.
//
// test/oom.sh compiles this with the runtime's test-only allocation-failure
// injection (-DBEANS_RT_ALLOC_FAILTEST) and sweeps BEANS_OOM_AFTER across every
// allocation the program makes. Each failure must be the runtime's documented
// "out of memory" panic, never a NULL dereference. Before the fix, a failed
// grow here stored into a NULL buffer and the process took SIGSEGV.
//
// The counts are the smallest that still force each grow, reindex and deadbits
// path, so the whole allocation sequence is short enough to sweep exhaustively.

import std.io

fn main() {
    // Untyped Map<int,int>: initial data alloc, data grows, the index rebuild
    // once it outgrows the linear scan, the deadbits a remove creates, and the
    // reindex that compacts them.
    var mi: Map<int, int> = {}
    var i: int = 0
    for i < 70 { mi[i] = i * 3; i += 1 }
    i = 0
    for i < 25 { mi.remove(i * 2); i += 1 }
    i = 70
    for i < 110 { mi[i] = i * 3; i += 1 }

    // Typed Map<int,string>: the wide-value store grows alongside the key data,
    // and a refused grow releases the value and key it was handed
    // (map_insert_miss_typed) rather than leaking them.
    var ms: Map<int, string> = {}
    i = 0
    for i < 70 { ms[i] = "value"; i += 1 }
    i = 0
    for i < 25 { ms.remove(i * 3); i += 1 }

    // Managed KEY, plain value: exercises map_insert_miss's own key release on a
    // refused grow (the untyped path, where the value is a raw int).
    var mk: Map<string, int> = {}
    i = 0
    for i < 40 { mk["k{i}"] = i; i += 1 }

    // reserve on a map that already carries deadbits, so its deadbits realloc
    // runs as well as its data realloc.
    var mr: Map<int, int> = {}
    i = 0
    for i < 40 { mr[i] = i; i += 1 }
    i = 0
    for i < 20 { mr.remove(i * 2); i += 1 }
    mr.reserve(9000)

    // Untyped List insert at the front, which grows the storage.
    var li: List<int> = []
    i = 0
    for i < 60 { li.insert(0, i); i += 1 }

    // Bytes append, which grows its buffer.
    var b: Bytes = new Bytes(0)
    i = 0
    for i < 400 { b.append_uvarint(i); i += 1 }

    io.println("oom-probe complete keys {mi.len()} {ms.len()} {mk.len()} {mr.len()} list {li.len()} bytes {b.len()}")
}
