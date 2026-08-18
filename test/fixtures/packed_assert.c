// Cross-target proof for packed and over-aligned records: no libc, no sysroot,
// no emulator.
//
// Every number below is what Beans reports for the same declaration in
// test/cases/packed_ref.b. The _Static_asserts make *Clang* check them for
// whichever -target it is given, so a disagreement is a compile error rather
// than a wrong offset discovered at run time on one machine.
//
// Compiled with -ffreestanding -fsyntax-only, which is why the fixed-width
// types are spelled out instead of included. Companion to
// test/fixtures/layout_assert.c, which does the same for plain records.
typedef unsigned char u8_t;
typedef unsigned short u16_t;
typedef unsigned int u32_t;
typedef unsigned long long u64_t;

typedef struct {
    u8_t tag;
    u32_t count;
    _Bool flag;
    u64_t value;
} __attribute__((packed)) Packed;

_Static_assert(sizeof(Packed) == 14, "Packed size");
_Static_assert(_Alignof(Packed) == 1, "Packed align");
_Static_assert(__builtin_offsetof(Packed, tag) == 0, "Packed.tag");
_Static_assert(__builtin_offsetof(Packed, count) == 1, "Packed.count");
_Static_assert(__builtin_offsetof(Packed, flag) == 5, "Packed.flag");
_Static_assert(__builtin_offsetof(Packed, value) == 6, "Packed.value");

typedef struct {
    u32_t seq;
    u8_t data[56];
} __attribute__((aligned(64))) Cacheline;

_Static_assert(sizeof(Cacheline) == 64, "Cacheline size");
_Static_assert(_Alignof(Cacheline) == 64, "Cacheline align");
_Static_assert(__builtin_offsetof(Cacheline, seq) == 0, "Cacheline.seq");
_Static_assert(__builtin_offsetof(Cacheline, data) == 4, "Cacheline.data");

typedef struct {
    u8_t head;
    Cacheline line;
    u8_t tail;
} Holder;

_Static_assert(sizeof(Holder) == 192, "Holder size");
_Static_assert(_Alignof(Holder) == 64, "Holder align");
_Static_assert(__builtin_offsetof(Holder, head) == 0, "Holder.head");
_Static_assert(__builtin_offsetof(Holder, line) == 64, "Holder.line");
_Static_assert(__builtin_offsetof(Holder, tail) == 128, "Holder.tail");

typedef struct {
    u8_t a;
    u32_t b __attribute__((aligned(16)));
    u8_t c;
} FieldAligned;

_Static_assert(sizeof(FieldAligned) == 32, "FieldAligned size");
_Static_assert(_Alignof(FieldAligned) == 16, "FieldAligned align");
_Static_assert(__builtin_offsetof(FieldAligned, a) == 0, "FieldAligned.a");
_Static_assert(__builtin_offsetof(FieldAligned, b) == 16, "FieldAligned.b");
_Static_assert(__builtin_offsetof(FieldAligned, c) == 20, "FieldAligned.c");

typedef struct {
    u8_t lead;
    Packed inner;
    u16_t trail;
} __attribute__((packed)) PackedNest;

_Static_assert(sizeof(PackedNest) == 17, "PackedNest size");
_Static_assert(_Alignof(PackedNest) == 1, "PackedNest align");
_Static_assert(__builtin_offsetof(PackedNest, lead) == 0, "PackedNest.lead");
_Static_assert(__builtin_offsetof(PackedNest, inner) == 1, "PackedNest.inner");
_Static_assert(__builtin_offsetof(PackedNest, trail) == 15, "PackedNest.trail");

typedef union {
    u64_t word;
    u8_t bytes[3];
} __attribute__((packed)) PackedUnion;

_Static_assert(sizeof(PackedUnion) == 8, "PackedUnion size");
_Static_assert(_Alignof(PackedUnion) == 1, "PackedUnion align");

typedef union {
    u64_t word;
    u32_t half;
} __attribute__((aligned(32))) AlignedUnion;

_Static_assert(sizeof(AlignedUnion) == 32, "AlignedUnion size");
_Static_assert(_Alignof(AlignedUnion) == 32, "AlignedUnion align");
