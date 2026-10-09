// POSIX shared-memory objects map to ordinary `MMap` handles; mappings share writes across processes.
// Supply the agreed logical size on every open because `fstat` reports page-rounded allocation size.

import std.io


fn main() {
    let name: string = "/beans_example"

    // Create it. `true` makes the object and fixes its size.
    match MMap.open_shared_memory(name, 128, true) {
        ok(region) => {
            region.put_u64(0, 7)
            region.put_u32(8, 99)
            region.put_u8(12, 255)
            io.println("created {region.len()} bytes")
            io.println("wrote back {region.get_u64(0)} {region.get_u32(8)} {region.get_u8(12)}")
        }
        err(e) => io.println("create failed: {e.kind}")
    }

    // The second mapping sees values written through the first.
    match MMap.open_shared_memory(name, 128, false) {
        ok(again) => io.println("second mapping sees {again.get_u64(0)} {again.get_u32(8)}"),
        err(e) => io.println("open failed: {e.kind}"),
    }

    // Asking for more than the object holds is refused rather than producing a
    // mapping that faults on first touch.
    match MMap.open_shared_memory(name, 1048576, false) {
        ok(toobig) => io.println("unexpected {toobig.len()}"),
        err(e) => io.println("oversized request refused: {e.kind}"),
    }

    // A size of zero has no meaning for a mapping.
    match MMap.open_shared_memory(name, 0, false) {
        ok(empty) => io.println("unexpected {empty.len()}"),
        err(e) => io.println("zero size refused: {e.kind}"),
    }

    // Unlink removes the name. Mappings that already exist keep working until their
    // last user drops them, exactly like unlinking an open file.
    match MMap.unlink_shared_memory(name) {
        ok(gone) => io.println("unlinked {gone}"),
        err(e) => io.println("unlink failed: {e.kind}"),
    }

    // Opening it now fails, because the name is gone.
    match MMap.open_shared_memory(name, 128, false) {
        ok(zombie) => io.println("unexpected {zombie.len()}"),
        err(e) => io.println("gone after unlink: {e.kind}"),
    }
}
