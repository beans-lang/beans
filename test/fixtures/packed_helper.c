// C side of the packed/aligned ABI round trip.
//
// The layout assertions elsewhere check the *numbers* Beans reports. These
// functions check the *bytes*: Clang lays these records out from the C
// declaration, Beans lays them out from its own rules, and the values only
// survive the call if the two agree field by field. A one-byte disagreement
// turns into a wrong number in the output, not a crash, which is exactly why
// this has to be an executed test.
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t tag;
    uint32_t count;
    _Bool flag;
    uint64_t value;
} __attribute__((packed)) BeansPackedHeader;

typedef struct {
    uint32_t seq;
    uint8_t data[12];
} __attribute__((aligned(64))) BeansCacheline;

// Reads every field, so a misplaced one shows up in the sum.
uint64_t beans_test_packed_sum(BeansPackedHeader header) {
    return (uint64_t)header.tag + header.count + (header.flag ? 1000u : 0u) +
           header.value;
}

// Builds the record on the C side for Beans to read back.
BeansPackedHeader beans_test_packed_make(uint8_t tag, uint32_t count, uint64_t value) {
    BeansPackedHeader header;
    memset(&header, 0, sizeof header);
    header.tag = tag;
    header.count = count;
    header.flag = 1;
    header.value = value;
    return header;
}

// Reports the low bits of the address the pointer actually arrived with, so an
// over-aligned record's *storage* is checked and not just its reported align_of.
// The mask comes from the caller so a stricter request can be checked strictly:
// `& 63` would pass for a merely 64-aligned pointer that was asked to be
// 256-aligned.
uint64_t beans_test_misalign(void* p, uint64_t mask) {
    return (uint64_t)((uintptr_t)p & mask);
}

uint64_t beans_test_cacheline_seq(BeansCacheline* line) { return line->seq; }

uint64_t beans_test_cacheline_tail(BeansCacheline* line) {
    return line->data[11];
}

// Sizes as C sees them, so the ABI test also pins sizeof across the boundary.
uint64_t beans_test_packed_sizes(void) {
    return sizeof(BeansPackedHeader) * 1000u + sizeof(BeansCacheline);
}
