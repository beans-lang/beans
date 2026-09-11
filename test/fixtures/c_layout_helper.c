#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t tag;
    uint32_t count;
    float ratio;
    _Bool live;
} BeansTestPacket;

typedef union {
    uint32_t bits;
    float number;
} BeansTestWord;

typedef struct {
    uint32_t code;
    uint8_t* next;
} BeansTestLink;

typedef struct {
    uint16_t small;
    uint8_t bytes[3];
} BeansTestPair;

typedef union {
    uint8_t bytes[16];
    uint64_t word;
} BeansTestAlignedBlock;

typedef struct {
    BeansTestPair pair;
    uint32_t values[2];
    BeansTestAlignedBlock block;
} BeansTestFrame;

static uint8_t beans_test_link_byte = 77;

unsigned long long beans_test_packet_size(void) { return sizeof(BeansTestPacket); }
unsigned long long beans_test_packet_align(void) { return _Alignof(BeansTestPacket); }
unsigned long long beans_test_packet_offset(unsigned long long index) {
    static const size_t offsets[] = {
        offsetof(BeansTestPacket, tag),
        offsetof(BeansTestPacket, count),
        offsetof(BeansTestPacket, ratio),
        offsetof(BeansTestPacket, live),
    };
    return index < 4 ? offsets[index] : (unsigned long long)-1;
}
void beans_test_packet_fill(void* raw) {
    BeansTestPacket* value = raw;
    value->tag = 9;
    value->count = 123;
    value->ratio = 2.5f;
    value->live = 1;
}
BeansTestPacket beans_test_packet_roundtrip(BeansTestPacket value,
                                             uint32_t extra) {
    value.count += extra;
    value.ratio += 0.5f;
    return value;
}

unsigned long long beans_test_word_size(void) { return sizeof(BeansTestWord); }
unsigned long long beans_test_word_align(void) { return _Alignof(BeansTestWord); }
unsigned long long beans_test_word_offset(unsigned long long index) {
    static const size_t offsets[] = {
        offsetof(BeansTestWord, bits),
        offsetof(BeansTestWord, number),
    };
    return index < 2 ? offsets[index] : (unsigned long long)-1;
}
void beans_test_word_fill(void* raw) {
    BeansTestWord* value = raw;
    value->number = 3.0f;
}
BeansTestWord beans_test_word_roundtrip(BeansTestWord value) {
    value.bits ^= UINT32_C(0x00800000);
    return value;
}

unsigned long long beans_test_link_size(void) { return sizeof(BeansTestLink); }
unsigned long long beans_test_link_align(void) { return _Alignof(BeansTestLink); }
unsigned long long beans_test_link_offset(unsigned long long index) {
    static const size_t offsets[] = {
        offsetof(BeansTestLink, code),
        offsetof(BeansTestLink, next),
    };
    return index < 2 ? offsets[index] : (unsigned long long)-1;
}
void beans_test_link_fill(void* raw) {
    BeansTestLink* value = raw;
    value->code = 55;
    value->next = &beans_test_link_byte;
}

unsigned long long beans_test_pair_size(void) { return sizeof(BeansTestPair); }
unsigned long long beans_test_pair_align(void) { return _Alignof(BeansTestPair); }
unsigned long long beans_test_pair_offset(unsigned long long index) {
    static const size_t offsets[] = {
        offsetof(BeansTestPair, small),
        offsetof(BeansTestPair, bytes),
    };
    return index < 2 ? offsets[index] : (unsigned long long)-1;
}
unsigned long long beans_test_block_size(void) { return sizeof(BeansTestAlignedBlock); }
unsigned long long beans_test_block_align(void) { return _Alignof(BeansTestAlignedBlock); }
unsigned long long beans_test_block_offset(unsigned long long index) {
    static const size_t offsets[] = {
        offsetof(BeansTestAlignedBlock, bytes),
        offsetof(BeansTestAlignedBlock, word),
    };
    return index < 2 ? offsets[index] : (unsigned long long)-1;
}

unsigned long long beans_test_frame_size(void) { return sizeof(BeansTestFrame); }
unsigned long long beans_test_frame_align(void) { return _Alignof(BeansTestFrame); }
unsigned long long beans_test_frame_offset(unsigned long long index) {
    static const size_t offsets[] = {
        offsetof(BeansTestFrame, pair),
        offsetof(BeansTestFrame, values),
        offsetof(BeansTestFrame, block),
    };
    return index < 3 ? offsets[index] : (unsigned long long)-1;
}
void beans_test_frame_fill(void* raw) {
    BeansTestFrame* value = raw;
    value->pair.small = 513;
    value->pair.bytes[0] = 4;
    value->pair.bytes[1] = 5;
    value->pair.bytes[2] = 6;
    value->values[0] = 1000;
    value->values[1] = 2000;
    value->block.word = UINT64_C(0x0102030405060708);
}
BeansTestFrame beans_test_frame_roundtrip(BeansTestFrame value) {
    value.pair.small += 1;
    value.values[1] += 3;
    value.block.word += 4;
    return value;
}

double beans_test_mixed_float(float first, double second, float third,
                              uint64_t whole) {
    return (double)first + second + (double)third + (double)whole;
}

/* ---- homogeneous float aggregates -------------------------------------
 *
 * A struct of one to four *identical* float or double members is an HFA, and
 * on arm64 it does not travel the way any other struct does: each member goes
 * in its own vector register, v0 to v3, and a returned one comes back the same
 * way. A struct of the same size with a mixed member list goes in the general
 * registers instead, and an HFA of five members goes indirectly through
 * memory.
 *
 * So these are three separate code paths in a backend, and until this block
 * existed every extern "C" struct in the test corpus was a mixed one — the
 * vector-register path had no test at all. It is not a hypothetical path:
 * raylib's Vector4, Rectangle and Color are exactly this shape.
 */
typedef struct { double x, y; } BeansTestV2d;          /* 2 doubles: HFA     */
typedef struct { float x, y, z, w; } BeansTestV4f;     /* 4 floats:  HFA     */
typedef struct { double a, b, c, d; } BeansTestV4d;    /* 4 doubles: HFA max */
typedef struct { double a, b, c, d, e; } BeansTestV5d; /* 5 doubles: indirect*/
typedef struct { double x; int64_t n; } BeansTestMixed;/* not an HFA         */

double beans_test_v2d_sum(BeansTestV2d v) { return v.x + v.y; }
BeansTestV2d beans_test_v2d_scale(BeansTestV2d v, double by) {
    BeansTestV2d out; out.x = v.x * by; out.y = v.y * by; return out;
}

double beans_test_v4f_sum(BeansTestV4f v) {
    return (double)v.x + (double)v.y + (double)v.z + (double)v.w;
}
BeansTestV4f beans_test_v4f_scale(BeansTestV4f v, float by) {
    BeansTestV4f out;
    out.x = v.x * by; out.y = v.y * by; out.z = v.z * by; out.w = v.w * by;
    return out;
}

double beans_test_v4d_sum(BeansTestV4d v) { return v.a + v.b + v.c + v.d; }
BeansTestV4d beans_test_v4d_scale(BeansTestV4d v, double by) {
    BeansTestV4d out;
    out.a = v.a * by; out.b = v.b * by; out.c = v.c * by; out.d = v.d * by;
    return out;
}

/* Five members is one too many to be an HFA, so this one is passed and
 * returned through memory. The arithmetic is the same; the calling convention
 * is not, which is the point of having it here beside the four-member one. */
double beans_test_v5d_sum(BeansTestV5d v) {
    return v.a + v.b + v.c + v.d + v.e;
}
BeansTestV5d beans_test_v5d_scale(BeansTestV5d v, double by) {
    BeansTestV5d out;
    out.a = v.a * by; out.b = v.b * by; out.c = v.c * by;
    out.d = v.d * by; out.e = v.e * by;
    return out;
}

double beans_test_mixed_pair(BeansTestMixed m) { return m.x + (double)m.n; }

/* An HFA arriving after the vector registers are already spoken for. Eight
 * doubles fill v0 to v7, so this struct has to go on the stack — a different
 * path again, and the one a wrapper that counted registers wrongly would get
 * right for the first argument and wrong for the last. */
double beans_test_v2d_after_eight(double a, double b, double c, double d,
                                  double e, double f, double g, double h,
                                  BeansTestV2d v) {
    return a + b + c + d + e + f + g + h + v.x + v.y;
}
