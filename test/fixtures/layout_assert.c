// Cross-target layout proof that needs no libc, no sysroot and no emulator.
//
// Every number here is what Beans reports for size_of/align_of/offset_of. The
// _Static_asserts make *Clang* check them for whichever -target it is given, so
// a disagreement is a compile error rather than a wrong answer at run time.
// test/fixtures/layout_reference.c does the same job by execution on the host;
// this one is how the same reference reaches a target we cannot run.
//
// Compiled with -ffreestanding -fsyntax-only, so no header is included and the
// fixed-width types are spelled out with Clang's own builtins.
typedef signed char i8_t;
typedef short i16_t;
typedef int i32_t;
typedef long long i64_t;
typedef unsigned char u8_t;
typedef unsigned short u16_t;
typedef unsigned int u32_t;
typedef unsigned long long u64_t;

typedef struct {
    u8_t tag;
    u32_t count;
    float ratio;
} Packet;

typedef struct {
    _Bool flag;
    u64_t wide;
    i16_t small;
} Mixed;

typedef struct {
    u32_t values[4];
    u8_t tail;
} Lanes;

typedef struct {
    Packet head;
    u16_t lanes[3];
    u64_t tail;
} Nested;

typedef struct {
    Nested outer;
    void* pointer;
    i8_t edge;
} Deep;

typedef union {
    u32_t bits;
    float number;
} Word;

typedef union {
    u8_t small;
    u64_t big;
    u32_t pair[2];
} Wide;

#define OFFSET(type, field) __builtin_offsetof(type, field)

_Static_assert(sizeof(i8_t) == 1 && _Alignof(i8_t) == 1, "i8");
_Static_assert(sizeof(i16_t) == 2 && _Alignof(i16_t) == 2, "i16");
_Static_assert(sizeof(i32_t) == 4 && _Alignof(i32_t) == 4, "i32");
_Static_assert(sizeof(i64_t) == 8 && _Alignof(i64_t) == 8, "i64");
_Static_assert(sizeof(float) == 4 && _Alignof(float) == 4, "f32");
_Static_assert(sizeof(double) == 8 && _Alignof(double) == 8, "f64");
_Static_assert(sizeof(_Bool) == 1 && _Alignof(_Bool) == 1, "bool");

_Static_assert(sizeof(u8_t[7]) == 7 && _Alignof(u8_t[7]) == 1, "u8[7]");
_Static_assert(sizeof(u32_t[4]) == 16 && _Alignof(u32_t[4]) == 4, "u32[4]");
_Static_assert(sizeof(u16_t[3][2]) == 12 && _Alignof(u16_t[3][2]) == 2, "u16[3][2]");

_Static_assert(sizeof(Packet) == 12 && _Alignof(Packet) == 4, "Packet");
_Static_assert(OFFSET(Packet, tag) == 0, "Packet.tag");
_Static_assert(OFFSET(Packet, count) == 4, "Packet.count");
_Static_assert(OFFSET(Packet, ratio) == 8, "Packet.ratio");

_Static_assert(sizeof(Mixed) == 24 && _Alignof(Mixed) == 8, "Mixed");
_Static_assert(OFFSET(Mixed, flag) == 0, "Mixed.flag");
_Static_assert(OFFSET(Mixed, wide) == 8, "Mixed.wide");
_Static_assert(OFFSET(Mixed, small) == 16, "Mixed.small");

_Static_assert(sizeof(Lanes) == 20 && _Alignof(Lanes) == 4, "Lanes");
_Static_assert(OFFSET(Lanes, values) == 0, "Lanes.values");
_Static_assert(OFFSET(Lanes, tail) == 16, "Lanes.tail");

_Static_assert(sizeof(Nested) == 32 && _Alignof(Nested) == 8, "Nested");
_Static_assert(OFFSET(Nested, head) == 0, "Nested.head");
_Static_assert(OFFSET(Nested, lanes) == 12, "Nested.lanes");
_Static_assert(OFFSET(Nested, tail) == 24, "Nested.tail");

_Static_assert(OFFSET(Deep, outer) == 0, "Deep.outer");
_Static_assert(OFFSET(Deep, pointer) == 32, "Deep.pointer");
_Static_assert(OFFSET(Deep, edge) == 40, "Deep.edge");
_Static_assert(sizeof(Deep) == 48 && _Alignof(Deep) == 8, "Deep");

_Static_assert(sizeof(Word) == 4 && _Alignof(Word) == 4, "Word");
_Static_assert(OFFSET(Word, bits) == 0, "Word.bits");
_Static_assert(OFFSET(Word, number) == 0, "Word.number");

_Static_assert(sizeof(Wide) == 8 && _Alignof(Wide) == 8, "Wide");
_Static_assert(OFFSET(Wide, small) == 0, "Wide.small");
_Static_assert(OFFSET(Wide, big) == 0, "Wide.big");
_Static_assert(OFFSET(Wide, pair) == 0, "Wide.pair");

// Both supported Linux targets and the macOS target are LP64.
_Static_assert(sizeof(void*) == 8 && _Alignof(void*) == 8, "pointer");
