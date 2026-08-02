// Clang's own answer for the packed and over-aligned records in
// test/cases/packed_ref.b. The two programs print byte-identical text, so a
// disagreement shows up as a diff instead of as a silently misplaced field.
//
// Declaration order, field names and types are field-for-field identical to the
// Beans source on purpose. Keep them that way.
#include <stdio.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t tag;
    uint32_t count;
    _Bool flag;
    uint64_t value;
} __attribute__((packed)) Packed;

typedef struct {
    uint32_t seq;
    uint8_t data[56];
} __attribute__((aligned(64))) Cacheline;

typedef struct {
    uint8_t head;
    Cacheline line;
    uint8_t tail;
} Holder;

typedef struct {
    uint8_t a;
    uint32_t b __attribute__((aligned(16)));
    uint8_t c;
} FieldAligned;

typedef struct {
    uint8_t lead;
    Packed inner;
    uint16_t trail;
} __attribute__((packed)) PackedNest;

typedef union {
    uint64_t word;
    uint8_t bytes[3];
} __attribute__((packed)) PackedUnion;

typedef union {
    uint64_t word;
    uint32_t half;
} __attribute__((aligned(32))) AlignedUnion;

#define SHOW(T) printf("%s %zu %zu\n", #T, sizeof(T), _Alignof(T))
#define AT(T, field) printf("%s.%s %zu\n", #T, #field, offsetof(T, field))

int main(void) {
    SHOW(Packed);
    AT(Packed, tag);
    AT(Packed, count);
    AT(Packed, flag);
    AT(Packed, value);

    SHOW(Cacheline);
    AT(Cacheline, seq);
    AT(Cacheline, data);

    SHOW(Holder);
    AT(Holder, head);
    AT(Holder, line);
    AT(Holder, tail);

    SHOW(FieldAligned);
    AT(FieldAligned, a);
    AT(FieldAligned, b);
    AT(FieldAligned, c);

    SHOW(PackedNest);
    AT(PackedNest, lead);
    AT(PackedNest, inner);
    AT(PackedNest, trail);

    SHOW(PackedUnion);
    AT(PackedUnion, word);
    AT(PackedUnion, bytes);

    SHOW(AlignedUnion);
    AT(AlignedUnion, word);
    AT(AlignedUnion, half);
    return 0;
}
