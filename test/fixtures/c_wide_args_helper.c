#include <stdint.h>

// Every function here takes more arguments than one register bank holds, so
// the tail lands on the stack on both SysV x86-64 (6 GPR / 8 SSE) and
// AAPCS64 (8 GPR / 8 FP). Clang compiles this file, so it is the reference
// for what the caller must produce.

typedef struct {
    uint8_t tag;
    uint32_t count;
    float ratio;
} BeansWideRecord;

int64_t beans_test_wide_ints(int64_t a0, int64_t a1, int64_t a2, int64_t a3,
                             int64_t a4, int64_t a5, int64_t a6, int64_t a7,
                             int64_t a8, int64_t a9) {
    return a0 * 1 + a1 * 2 + a2 * 3 + a3 * 4 + a4 * 5 + a5 * 6 + a6 * 7 +
           a7 * 8 + a8 * 9 + a9 * 10;
}

double beans_test_wide_floats(double a0, double a1, double a2, double a3,
                              double a4, double a5, double a6, double a7,
                              double a8, double a9) {
    return a0 * 1.0 + a1 * 2.0 + a2 * 3.0 + a3 * 4.0 + a4 * 5.0 + a5 * 6.0 +
           a6 * 7.0 + a7 * 8.0 + a8 * 9.0 + a9 * 10.0;
}

// Narrow integers in stack positions. Apple's arm64 ABI gives each one its
// natural stack size while generic AAPCS64 widens every slot to eight bytes,
// so a caller that guesses slot sizes reads the wrong values here.
int64_t beans_test_wide_narrow(int8_t a0, uint8_t a1, int16_t a2, uint16_t a3,
                               int32_t a4, uint32_t a5, int8_t a6, uint16_t a7,
                               int32_t a8, uint8_t a9, _Bool a10, int64_t a11) {
    int64_t sum = (int64_t)a0 * 1 + (int64_t)a1 * 2 + (int64_t)a2 * 3 +
                  (int64_t)a3 * 4 + (int64_t)a4 * 5 + (int64_t)a5 * 6 +
                  (int64_t)a6 * 7 + (int64_t)a7 * 8 + (int64_t)a8 * 9 +
                  (int64_t)a9 * 10 + (int64_t)(a10 ? 11 : 0);
    return sum + a11 * 12;
}

// Narrow integers that all fit in registers. This shape has nothing to do with
// argument count, and both backends used to get it wrong: they zero-extended
// every argument, so a signed -3 arrived as 253.
int64_t beans_test_narrow_registers(int8_t a, uint8_t b, int16_t c, uint16_t d,
                                    _Bool e) {
    return (int64_t)a * 1 + (int64_t)b * 2 + (int64_t)c * 3 + (int64_t)d * 4 +
           (int64_t)(e ? 5 : 0);
}

int8_t beans_test_narrow_return(int32_t value) { return (int8_t)value; }

// Mixed classes past every register bank at once, including a pointer.
double beans_test_wide_mixed(int64_t i0, int64_t i1, int64_t i2, int64_t i3,
                             int64_t i4, int64_t i5, int64_t i6, int64_t i7,
                             double f0, double f1, double f2, double f3,
                             double f4, double f5, double f6, double f7,
                             uint8_t* pointer, _Bool flag) {
    double sum = 0.0;
    const int64_t ints[8] = {i0, i1, i2, i3, i4, i5, i6, i7};
    const double floats[8] = {f0, f1, f2, f3, f4, f5, f6, f7};
    for (int i = 0; i < 8; i++) sum += (double)ints[i] * (double)(i + 1);
    for (int i = 0; i < 8; i++) sum += floats[i] * (double)(i + 1) * 0.5;
    if (pointer) sum += (double)*pointer;
    return flag ? sum : -sum;
}

uint64_t beans_test_wide_records(BeansWideRecord r0, BeansWideRecord r1,
                                 BeansWideRecord r2, BeansWideRecord r3,
                                 BeansWideRecord r4, BeansWideRecord r5,
                                 BeansWideRecord r6, BeansWideRecord r7,
                                 int64_t extra) {
    const BeansWideRecord records[8] = {r0, r1, r2, r3, r4, r5, r6, r7};
    uint64_t sum = 0;
    for (int i = 0; i < 8; i++) {
        sum += (uint64_t)records[i].tag;
        sum += (uint64_t)records[i].count * 3u;
        sum += (uint64_t)(records[i].ratio * 4.0f);
    }
    return sum + (uint64_t)extra;
}

int64_t beans_test_wide_callback(int64_t a0, int64_t a1, int64_t a2, int64_t a3,
                                 int64_t a4, int64_t a5, int64_t a6,
                                 int32_t (*callback)(int32_t, int32_t),
                                 int64_t a8) {
    int64_t base = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a8;
    return base + (int64_t)callback((int32_t)a0, (int32_t)a8);
}

static uint8_t beans_test_wide_byte = 200;

uint8_t* beans_test_wide_pointer(void) { return &beans_test_wide_byte; }

unsigned long long beans_test_wide_record_size(void) {
    return sizeof(BeansWideRecord);
}
