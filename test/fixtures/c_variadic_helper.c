#include <stdarg.h>
#include <stdint.h>

// The reference for what a caller must produce for a C `...` tail. Clang
// compiles this file, so every `va_arg` below reads exactly what the target's
// variadic rules say is there — and the rules differ: Apple's arm64 ABI puts
// the whole tail on the stack with each argument at its natural size while the
// fixed head stays in registers, generic AAPCS64 keeps filling the register
// banks, and SysV x86-64 counts vector registers through `al`. A caller that
// guesses one 8-byte slot per argument passes all three of these tests only by
// accident, and fails the alternating one on purpose.
//
// C's default argument promotions apply to every variadic argument: anything
// narrower than `int` arrives as `int`, and `float` arrives as `double`. The
// reads below are written to that rule, not to the width the caller wrote.

// A tail of integers that were all narrower than `int` at the call site.
int64_t beans_test_va_narrow(int64_t count, ...) {
    va_list ap;
    va_start(ap, count);
    int64_t sum = 0;
    for (int64_t index = 0; index < count; index++) {
        sum = sum * 31 + (int64_t)va_arg(ap, int);
    }
    va_end(ap);
    return sum;
}

// A tail of `unsigned int`. uint32_t is not promoted — it is already as wide
// as `int` — so this is the one unsigned width that must be read unsigned.
uint64_t beans_test_va_unsigned(int64_t count, ...) {
    va_list ap;
    va_start(ap, count);
    uint64_t sum = 0;
    for (int64_t index = 0; index < count; index++) {
        sum = sum * 131u + (uint64_t)va_arg(ap, unsigned int);
    }
    va_end(ap);
    return sum;
}

// A tail of `float`, which C promotes to `double` on the way in.
double beans_test_va_floats(int64_t count, ...) {
    va_list ap;
    va_start(ap, count);
    double sum = 0.0;
    for (int64_t index = 0; index < count; index++) {
        sum = sum * 2.0 + va_arg(ap, double);
    }
    va_end(ap);
    return sum;
}

// A tail whose element widths alternate: int, long long, int, long long...
// This is where a caller that pushes one word per argument goes wrong on a
// stack-passing ABI, because a 4-byte slot followed by an 8-byte one needs
// padding that only the real rules insert.
int64_t beans_test_va_alternating(int64_t pairs, ...) {
    va_list ap;
    va_start(ap, pairs);
    int64_t sum = 0;
    for (int64_t index = 0; index < pairs; index++) {
        int narrow = va_arg(ap, int);
        long long wide = va_arg(ap, long long);
        sum += (int64_t)narrow * (index + 1) + wide * 1000;
    }
    va_end(ap);
    return sum;
}

// A fixed head that fills every integer and vector register bank, so the tail
// begins past all of them.
int64_t beans_test_va_wide(int64_t i0, int64_t i1, int64_t i2, int64_t i3,
                           int64_t i4, int64_t i5, int64_t i6, int64_t i7,
                           double f0, double f1, double f2, double f3,
                           double f4, double f5, double f6, double f7,
                           int64_t count, ...) {
    va_list ap;
    va_start(ap, count);
    int64_t sum = i0 + i1 * 2 + i2 * 3 + i3 * 4 + i4 * 5 + i5 * 6 + i6 * 7 +
                  i7 * 8;
    double scaled = f0 + f1 * 2.0 + f2 * 3.0 + f3 * 4.0 + f4 * 5.0 +
                    f5 * 6.0 + f6 * 7.0 + f7 * 8.0;
    sum += (int64_t)(scaled * 4.0);
    for (int64_t index = 0; index < count; index++) {
        int narrow = va_arg(ap, int);
        double wide = va_arg(ap, double);
        sum += (int64_t)narrow * 100 + (int64_t)(wide * 8.0);
    }
    va_end(ap);
    return sum;
}

// The `ioctl` shape: a selector chooses what the tail means, and one of the
// tail arguments is a pointer the callee writes through.
int32_t beans_test_va_fill(int32_t selector, ...) {
    va_list ap;
    va_start(ap, selector);
    int32_t status = -1;
    if (selector == 1) {
        uint16_t* out = va_arg(ap, uint16_t*);
        out[0] = 24;
        out[1] = 80;
        status = 0;
    } else if (selector == 2) {
        int64_t* out = va_arg(ap, int64_t*);
        long long value = va_arg(ap, long long);
        *out = (int64_t)value * 3;
        status = 1;
    } else if (selector == 3) {
        uint8_t* text = va_arg(ap, uint8_t*);
        int64_t length = 0;
        while (text[length] != 0) length++;
        status = (int32_t)length;
    }
    va_end(ap);
    return status;
}

static int32_t beans_test_va_triple(int32_t value) { return value * 3; }

typedef int32_t (*BeansVaFunction)(int32_t);

BeansVaFunction beans_test_va_function(void) { return beans_test_va_triple; }

// Function pointers in the tail: one pointer width, no promotion.
int64_t beans_test_va_callbacks(int64_t count, ...) {
    va_list ap;
    va_start(ap, count);
    int64_t total = 0;
    for (int64_t index = 0; index < count; index++) {
        BeansVaFunction fn = va_arg(ap, BeansVaFunction);
        total += (int64_t)fn((int32_t)(index + 1));
    }
    va_end(ap);
    return total;
}

// A tail of `_Bool`, which promotes to `int` like every other narrow type.
int64_t beans_test_va_bools(int64_t count, ...) {
    va_list ap;
    va_start(ap, count);
    int64_t bits = 0;
    for (int64_t index = 0; index < count; index++) {
        bits = bits * 2 + (va_arg(ap, int) ? 1 : 0);
    }
    va_end(ap);
    return bits;
}

uint8_t* beans_test_va_text(void) {
    static uint8_t text[] = {'b', 'e', 'a', 'n', 's', '!', 0};
    return text;
}
