// Shared memory.
//
// A POSIX shared-memory object is a named region that several processes map at once.
// Writes through one mapping are visible through every other — it is the cheapest way
// for two processes to agree on a number without a pipe or a socket.
//
// It comes back as an ordinary `MMap`, because shared memory is a *source* of a
// mapping rather than a new kind of thing: the same accessors, and the same
// deterministic unmap when the handle goes away.
//
// The size is stated on every open, in both modes. `fstat` on a shared-memory object
// reports a page-rounded size — 16384 for a 64-byte object on macOS — so a reader that
// trusted it would get a length its writer never agreed to. Stating it keeps both
// sides on the same protocol.

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

    // Open it again — a second mapping of the same object, which is what another
    // process would get. The values written through the first mapping are there.
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
