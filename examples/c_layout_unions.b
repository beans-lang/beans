/*
extern "C" union — several fields sharing one piece of storage.

What it is:
  Every field starts at offset zero, so they overlap. The union is as big as
  its largest field and as aligned as its strictest one. You initialize it with
  exactly one named field, but you may read any field afterwards — writing
  `bits` and reading `number` reinterprets the same bytes as a different type.
  Beans does not track which field is active, which is why initialization,
  reads, and writes all need `unsafe`. Reading the wrong field is not caught;
  you get whatever those bytes mean in that type.

Use it when:
  - You are matching a C struct/union in a header and need the same memory
    layout for FFI, syscalls, or a wire/file format.
  - You want a bit-level reinterpret: `Word` below reads the raw IEEE-754 bits
    of an f32 (1065353216 is exactly 1.0).
  - You need a block with a guaranteed size and alignment. `AlignedBlock`
    below is 16 bytes of storage that is also addressable as a u64.

Don't use it when:
  - You want "one of these several cases" with the tag checked for you. That is
    an `enum`, and the compiler makes reading the wrong case impossible.
  - The fields hold strings, classes, lists, or anything reference counted.
    C-layout unions only take inline scalars, RawPtr, fixed arrays, and nested
    C-layout records, so the C ABI carries no hidden ownership rules.

This first slice has no defaults, methods, generics, or inheritance.
*/

import std.io

extern "C" union Word {
    bits: u32
    number: f32
}

extern "C" union AlignedBlock {
    bytes: [u8; 16]
    word: u64
}

fn passthrough(value: Word) -> Word {
    return value
}

fn main() {
    unsafe {
        var word: Word = Word { bits: 1065353216 }
        io.println("union bits {word.bits} number {word.number}")
        word.number = 2.5
        let copy: Word = passthrough(word)
        io.println("union write {copy.bits} number {copy.number}")

        let memory: RawPtr<Word> = RawPtr.alloc(1)
        memory.write(copy)
        let loaded: Word = memory.read()
        io.println("union layout {memory.element_size()} {memory.element_align()} raw {loaded.number}")
        memory.free()

        let block: AlignedBlock = AlignedBlock {
            bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
        }
        io.println("union aligned {block.word}")
        let block_memory: RawPtr<AlignedBlock> = RawPtr.alloc(1)
        block_memory.write(block)
        io.println("union aligned layout {block_memory.element_size()} {block_memory.element_align()} {block_memory.read().bytes[15]}")
        block_memory.free()
    }
}
