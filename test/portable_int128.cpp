#include "int128.h"

#include <cassert>
#include <cstdint>
#include <string>

using beans::UInt128;
using beans::Int128;

#if defined(__SIZEOF_INT128__)
using Native = unsigned __int128;

static Native native(UInt128 value) {
    return static_cast<Native>(value.lo) |
           (static_cast<Native>(value.hi) << 64);
}

#endif

int main() {
    static_assert(UInt128::multiply_u64(UINT64_MAX, UINT64_MAX) ==
                  UInt128{UINT64_MAX - 1, 1});
    static_assert(UInt128::power_of_two(127) == UInt128{uint64_t{1} << 63, 0});

    UInt128 value;
    assert(UInt128::checked_mul_small(UInt128{UINT64_MAX}, 10, value));
    assert((value == UInt128{9, UINT64_MAX - 9}));
    UInt128 sum;
    assert(UInt128::checked_add(value, UInt128{10}, sum));
    assert((sum == UInt128{10, 0}));
    assert(!UInt128::checked_add(UInt128::max(), UInt128{1}, sum));
    assert(!UInt128::checked_mul_small(UInt128::max(), 2, value));

    UInt128 coefficient;
    for (char digit : std::string("99999999999999999999999999999999999999")) {
        UInt128 next;
        assert(UInt128::checked_mul_small(coefficient, 10, next));
        assert(UInt128::checked_add_small(next, digit - '0', coefficient));
    }
    assert(coefficient.decimal_string() ==
           "99999999999999999999999999999999999999");

    UInt128 quotient, remainder;
    assert(UInt128::max().divmod(UInt128{UINT64_MAX}, quotient, remainder));
    assert((quotient == UInt128{1, 1}));
    assert(remainder.zero());
    assert(UInt128::max().divmod(UInt128{uint64_t{1} << 63, 7},
                                 quotient, remainder));

    Int128 signed_value;
    assert(Int128::checked_add(Int128::from_i64(INT64_MIN),
                               Int128::from_i64(-1), signed_value));
    assert(signed_value.decimal_string() == "-9223372036854775809");
    assert(Int128::checked_subtract(Int128::from_u64(UINT64_MAX),
                                    Int128::from_i64(-1), signed_value));
    assert(signed_value.decimal_string() == "18446744073709551616");
    assert(Int128::checked_multiply(Int128::from_i64(INT64_MIN),
                                    Int128::from_i64(INT64_MIN), signed_value));
    assert(signed_value.decimal_string() ==
           "85070591730234615865843651857942052864");

#if defined(__SIZEOF_INT128__)
    uint64_t state = 0x9e3779b97f4a7c15ULL;
    auto random = [&]() {
        state ^= state << 7;
        state ^= state >> 9;
        return state;
    };
    for (unsigned i = 0; i < 20000; ++i) {
        UInt128 left{random(), random()};
        UInt128 right{random(), random()};
        if (right.zero()) right.lo = 1;

        UInt128 product;
        bool product_ok = UInt128::checked_multiply(left, right, product);
        Native expected_product = native(left) * native(right);
        bool expected_ok = left.zero() || expected_product / native(left) == native(right);
        assert(product_ok == expected_ok);
        if (product_ok) assert(native(product) == expected_product);

        assert(left.divmod(right, quotient, remainder));
        assert(native(quotient) == native(left) / native(right));
        assert(native(remainder) == native(left) % native(right));

        uint32_t small = static_cast<uint32_t>(random()) | 1;
        uint32_t small_remainder = 0;
        assert(left.divmod_small(small, quotient, small_remainder));
        assert(native(quotient) == native(left) / small);
        assert(small_remainder == native(left) % small);

        int64_t signed_left = static_cast<int64_t>(random());
        int64_t signed_right = static_cast<int64_t>(random());
        Int128 portable_result;
        assert(Int128::checked_multiply(Int128::from_i64(signed_left),
                                        Int128::from_i64(signed_right),
                                        portable_result));
        __int128 native_result = static_cast<__int128>(signed_left) *
                                 static_cast<__int128>(signed_right);
        bool native_negative = native_result < 0;
        Native native_magnitude = native_negative
                                      ? Native{0} - static_cast<Native>(native_result)
                                      : static_cast<Native>(native_result);
        assert(portable_result.negative == native_negative);
        assert(native(portable_result.magnitude) == native_magnitude);
    }
#endif
}
