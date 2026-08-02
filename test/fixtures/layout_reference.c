// The C half of the layout cross-check. Declarations must mirror
// test/cases/layout_ref.b field for field, and the output text must match byte
// for byte. Clang -- not the other Beans backend -- is the authority here: two
// backends that share an assumption can be wrong the same way and the
// differential suite would never notice. That is exactly how the narrow-integer
// C ABI bug survived for as long as extern "C" existed.
#include <stdalign.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    uint8_t tag;
    uint32_t count;
    float ratio;
} Packet;

typedef struct {
    _Bool flag;
    uint64_t wide;
    int16_t small;
} Mixed;

typedef struct {
    uint32_t values[4];
    uint8_t tail;
} Lanes;

typedef struct {
    Packet head;
    uint16_t lanes[3];
    uint64_t tail;
} Nested;

typedef struct {
    Nested outer;
    void* pointer;
    int8_t edge;
} Deep;

typedef union {
    uint32_t bits;
    float number;
} Word;

typedef union {
    uint8_t small;
    uint64_t big;
    uint32_t pair[2];
} Wide;

#define SA(name, type) printf("%s %zu %zu\n", name, sizeof(type), alignof(type))
#define OFF(name, type, field) \
    printf("%s %zu\n", name, offsetof(type, field))

int main(void) {
    SA("i8", int8_t);
    SA("i16", int16_t);
    SA("i32", int32_t);
    SA("i64", int64_t);
    SA("u8", uint8_t);
    SA("u16", uint16_t);
    SA("u32", uint32_t);
    SA("u64", uint64_t);
    SA("f32", float);
    SA("f64", double);
    SA("bool", _Bool);
    SA("ptr", void*);

    SA("array_u8_7", uint8_t[7]);
    SA("array_u32_4", uint32_t[4]);
    SA("array_u16_2_3", uint16_t[3][2]);

    SA("Packet", Packet);
    OFF("Packet.tag", Packet, tag);
    OFF("Packet.count", Packet, count);
    OFF("Packet.ratio", Packet, ratio);

    SA("Mixed", Mixed);
    OFF("Mixed.flag", Mixed, flag);
    OFF("Mixed.wide", Mixed, wide);
    OFF("Mixed.small", Mixed, small);

    SA("Lanes", Lanes);
    OFF("Lanes.values", Lanes, values);
    OFF("Lanes.tail", Lanes, tail);

    SA("Nested", Nested);
    OFF("Nested.head", Nested, head);
    OFF("Nested.lanes", Nested, lanes);
    OFF("Nested.tail", Nested, tail);

    SA("Deep", Deep);
    OFF("Deep.outer", Deep, outer);
    OFF("Deep.pointer", Deep, pointer);
    OFF("Deep.edge", Deep, edge);

    SA("Word", Word);
    OFF("Word.bits", Word, bits);
    OFF("Word.number", Word, number);

    SA("Wide", Wide);
    OFF("Wide.small", Wide, small);
    OFF("Wide.big", Wide, big);
    OFF("Wide.pair", Wide, pair);
    return 0;
}
