// The Beans WASIp1 host for wasm32.
//
// This is the whole substrate a 32-bit target needs, and it is deliberately small enough
// to read in one sitting:
//
//   1. the five hooks from the object-ABI contract in beans_rt.c
//   2. the memory and string primitives used by the freestanding Beans core
//   3. the 128-bit integer helpers clang calls for `decimal`, which normally come from
//      compiler-rt's wasm32 build — absent here, so they are written out
//   4. the WASIp1 imports used for I/O and hosted services, plus `_start`
//
// This is linked automatically by `beansc build --target wasm32-wasip1`. Keeping the
// substrate in runtime/ rather than under test/ is what makes a direct build a real
// product path instead of a worked example assembled only by the test script.

#include <errno.h>

typedef unsigned long size_t32;
typedef unsigned long long u64;
typedef unsigned int u32;
typedef long long i64;
typedef __int128 i128;
typedef unsigned __int128 u128;

// WASIp1 libc supplies the two hard text conversions. Keeping them behind the
// runtime's host hooks means the Beans core remains freestanding and bare WASM
// hosts can choose a different implementation.
extern int snprintf(char* out, size_t32 cap, const char* format, ...);
extern double strtod(const char* text, char** end);
extern void* calloc(size_t32 count, size_t32 size);
extern void* realloc(void* block, size_t32 size);
extern void free(void* block);
extern int posix_memalign(void** out, size_t32 align, size_t32 size);

// ---- WASI, declared without a sysroot ---------------------------------------
//
// A wasm import is a name and a signature. Keeping these small interfaces here
// makes the Beans-to-host boundary visible; wasi-libc supplies the C filesystem
// calls used by the full runtime profile.

struct wasi_iovec {
    const void* buf;
    u32 len;
};

__attribute__((import_module("wasi_snapshot_preview1"), import_name("fd_write")))
extern u32 wasi_fd_write(u32 fd, const struct wasi_iovec* iovs, u32 iovs_len,
                         u32* written);

__attribute__((import_module("wasi_snapshot_preview1"), import_name("proc_exit")))
extern void wasi_proc_exit(u32 code) __attribute__((noreturn));

__attribute__((import_module("wasi_snapshot_preview1"), import_name("fd_read")))
extern u32 wasi_fd_read(u32 fd, struct wasi_iovec* iovs, u32 iovs_len,
                        u32* read);

__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("args_sizes_get")))
extern u32 wasi_args_sizes_get(u32* count, u32* bytes);

__attribute__((import_module("wasi_snapshot_preview1"), import_name("args_get")))
extern u32 wasi_args_get(char** values, char* bytes);

__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("environ_sizes_get")))
extern u32 wasi_environ_sizes_get(u32* count, u32* bytes);

__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("environ_get")))
extern u32 wasi_environ_get(char** values, char* bytes);

__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("clock_time_get")))
extern u32 wasi_clock_time_get(u32 clock, u64 precision, u64* nanos);

__attribute__((import_module("wasi_snapshot_preview1"), import_name("random_get")))
extern u32 wasi_random_get(void* out, u32 count);

typedef struct {
    u32 id;
    u32 padding0;
    u64 timeout;
    u64 precision;
    unsigned short flags;
    unsigned char padding1[6];
} wasi_subscription_clock;

typedef struct {
    u64 userdata;
    unsigned char tag;
    unsigned char padding0[7];
    wasi_subscription_clock clock;
} wasi_subscription;

typedef struct {
    u64 userdata;
    unsigned short error;
    unsigned char type;
    unsigned char padding0[5];
    u64 available;
    unsigned short flags;
    unsigned char padding1[6];
} wasi_event;

_Static_assert(sizeof(wasi_subscription_clock) == 32,
               "WASIp1 clock subscription ABI");
_Static_assert(sizeof(wasi_subscription) == 48,
               "WASIp1 subscription ABI");
_Static_assert(sizeof(wasi_event) == 32, "WASIp1 event ABI");

__attribute__((import_module("wasi_snapshot_preview1"),
               import_name("poll_oneoff")))
extern u32 wasi_poll_oneoff(const wasi_subscription* subscriptions,
                            wasi_event* events, u32 count, u32* occurred);

// ---- memory and string primitives -------------------------------------------
//
// Byte-at-a-time and unashamed: correctness is what matters here, and clang turns the
// obvious loops into `memory.copy` and `memory.fill` on any wasm engine that has bulk
// memory anyway.

void* memcpy(void* dst, const void* src, size_t32 n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    for (size_t32 i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void* memmove(void* dst, const void* src, size_t32 n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    if (d == s || n == 0) return dst;
    // Overlap direction matters, which is the entire difference from memcpy.
    if (d < s) {
        for (size_t32 i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (size_t32 i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

void* memset(void* dst, int c, size_t32 n) {
    unsigned char* d = dst;
    for (size_t32 i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

int memcmp(const void* a, const void* b, size_t32 n) {
    const unsigned char* x = a;
    const unsigned char* y = b;
    for (size_t32 i = 0; i < n; i++) {
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

void* memchr(const void* p, int c, size_t32 n) {
    const unsigned char* s = p;
    for (size_t32 i = 0; i < n; i++) {
        if (s[i] == (unsigned char)c) return (void*)(s + i);
    }
    return 0;
}

size_t32 strlen(const char* s) {
    size_t32 n = 0;
    while (s[n]) n++;
    return n;
}

void bzero(void* dst, size_t32 n) { memset(dst, 0, n); }

// ---- 128-bit integer helpers ------------------------------------------------
//
// `decimal` is a 128-bit coefficient, so clang emits calls to these. compiler-rt has
// them for every hosted target; there is no wasm32 build of it here, so they are
// written out.
//
// The catch that shapes all of it: writing `v >> 64` on a `u128` makes clang call
// `__lshrti3`, which is one of the functions being defined. So everything below works on
// an explicit pair of 64-bit halves through a union — no 128-bit shift appears anywhere,
// and the bootstrap loop cannot happen.

typedef union {
    u128 whole;
    struct {
        u64 lo, hi; // wasm is little-endian, so low half first
    } half;
} Split;

static Split split_of(u128 v) {
    Split s;
    s.whole = v;
    return s;
}

static u128 joined(u64 hi, u64 lo) {
    Split s;
    s.half.hi = hi;
    s.half.lo = lo;
    return s.whole;
}

u128 __ashlti3(u128 v, int n) {
    Split in = split_of(v);
    if (n <= 0) return v;
    if (n >= 128) return 0;
    if (n >= 64) return joined(in.half.lo << (n - 64), 0);
    return joined((in.half.hi << n) | (in.half.lo >> (64 - n)), in.half.lo << n);
}

u128 __lshrti3(u128 v, int n) {
    Split in = split_of(v);
    if (n <= 0) return v;
    if (n >= 128) return 0;
    if (n >= 64) return joined(0, in.half.hi >> (n - 64));
    return joined(in.half.hi >> n, (in.half.lo >> n) | (in.half.hi << (64 - n)));
}

u128 __ashrti3(u128 v, int n) {
    Split in = split_of(v);
    i64 signed_hi = (i64)in.half.hi;
    if (n <= 0) return v;
    // An arithmetic shift keeps the sign, so an over-long shift saturates to all-ones
    // or all-zeros rather than to zero.
    if (n >= 128) return joined((u64)(signed_hi >> 63), (u64)(signed_hi >> 63));
    if (n >= 64)
        return joined((u64)(signed_hi >> 63), (u64)(signed_hi >> (n - 64)));
    return joined((u64)(signed_hi >> n),
                  (in.half.lo >> n) | (in.half.hi << (64 - n)));
}

u128 __multi3(i128 a, i128 b) {
    Split x = split_of((u128)a), y = split_of((u128)b);
    // Four 32-bit pieces of the low halves, so every carry is visible.
    u64 al = x.half.lo & 0xffffffffu, ah = x.half.lo >> 32;
    u64 bl = y.half.lo & 0xffffffffu, bh = y.half.lo >> 32;
    u64 p0 = al * bl;
    u64 p1 = al * bh;
    u64 p2 = ah * bl;
    u64 p3 = ah * bh;
    u64 middle = (p0 >> 32) + (p1 & 0xffffffffu) + (p2 & 0xffffffffu);
    u64 low = (p0 & 0xffffffffu) | (middle << 32);
    u64 high = p3 + (p1 >> 32) + (p2 >> 32) + (middle >> 32);
    // The cross terms reach only the high half; their own overflow is discarded, which
    // is what a 128-bit product's definition allows.
    high += x.half.lo * y.half.hi + x.half.hi * y.half.lo;
    return joined(high, low);
}

// Shift-subtract division on the halves: slow, obviously correct, and only reached by
// decimal arithmetic.
static u128 udivmod128(u128 numerator, u128 denominator, u128* remainder) {
    if (denominator == 0) {
        // beans checks for this before it gets here, so reaching it means the runtime
        // is wrong. Trapping beats returning a made-up quotient.
        wasi_proc_exit(72);
    }
    u128 quotient = 0;
    u128 rest = 0;
    for (int bit = 127; bit >= 0; bit--) {
        // rest = rest * 2 + bit `bit` of the numerator
        rest = __ashlti3(rest, 1);
        Split n = split_of(numerator);
        u64 word = bit >= 64 ? n.half.hi : n.half.lo;
        int within = bit >= 64 ? bit - 64 : bit;
        rest |= (u128)((word >> within) & 1);
        if (rest >= denominator) {
            rest -= denominator;
            quotient |= __ashlti3(1, bit);
        }
    }
    if (remainder) *remainder = rest;
    return quotient;
}

u128 __udivti3(u128 a, u128 b) { return udivmod128(a, b, 0); }

u128 __umodti3(u128 a, u128 b) {
    u128 rest = 0;
    udivmod128(a, b, &rest);
    return rest;
}

i128 __divti3(i128 a, i128 b) {
    int negative = 0;
    u128 ua, ub;
    if (a < 0) { ua = (u128)0 - (u128)a; negative ^= 1; } else { ua = (u128)a; }
    if (b < 0) { ub = (u128)0 - (u128)b; negative ^= 1; } else { ub = (u128)b; }
    u128 q = udivmod128(ua, ub, 0);
    return negative ? -(i128)q : (i128)q;
}

i128 __modti3(i128 a, i128 b) {
    int negative = a < 0;
    u128 ua = negative ? (u128)0 - (u128)a : (u128)a;
    u128 ub = b < 0 ? (u128)0 - (u128)b : (u128)b;
    u128 rest = 0;
    udivmod128(ua, ub, &rest);
    // C's remainder takes the sign of the dividend.
    return negative ? -(i128)rest : (i128)rest;
}

double __floatuntidf(u128 v) {
    // High half first, so the double's 53 bits of mantissa see the significant end
    // before rounding. Exact for anything that fits.
    Split s = split_of(v);
    return (double)s.half.hi * 18446744073709551616.0 + (double)s.half.lo;
}

double __floattidf(i128 v) {
    if (v < 0) return -__floatuntidf((u128)0 - (u128)v);
    return __floatuntidf((u128)v);
}

// ---- the allocator ----------------------------------------------------------
//
// WASIp1 libc owns the process heap. The first host used a second bump pointer over
// the same linear memory; as soon as snprintf allocated, the two heaps overlapped and
// a later release trapped. One allocator must own __heap_base, and libc already provides
// the reusable, aligned implementation the WASI services need.

void* beans_host_alloc(u64 size, u64 align) {
    if (align <= 16) return calloc(1, (size_t32)size);
    void* out = 0;
    if (posix_memalign(&out, (size_t32)align, (size_t32)size) != 0)
        return 0;
    memset(out, 0, (size_t32)size);
    return out;
}

void* beans_host_realloc(void* block, u64 size) {
    return realloc(block, (size_t32)size);
}

void beans_host_free(void* block) { free(block); }

u64 beans_wasm_memory_pages(void) {
    return (u64)__builtin_wasm_memory_size(0);
}

// ---- output and exit --------------------------------------------------------

void beans_host_write(int stream, const char* bytes, u64 len) {
    struct wasi_iovec iov;
    iov.buf = bytes;
    iov.len = (u32)len;
    u32 written = 0;
    // 1 is stdout, 2 is stderr, exactly as the hook contract says.
    wasi_fd_write(stream == 2 ? 2u : 1u, &iov, 1, &written);
}

void beans_host_exit(int code) { wasi_proc_exit((u32)code); }

static u32 beans_wasi_arg_count;
static char** beans_wasi_args;
static u32 beans_wasi_env_count;
static char** beans_wasi_envs;

static void beans_wasi_initialize(void) {
    u32 argument_bytes = 0;
    u32 environment_bytes = 0;
    if (wasi_args_sizes_get(&beans_wasi_arg_count, &argument_bytes) != 0)
        wasi_proc_exit(74);
    if (beans_wasi_arg_count) {
        beans_wasi_args = calloc(beans_wasi_arg_count, sizeof(char*));
        char* storage = calloc(argument_bytes ? argument_bytes : 1, 1);
        if (!beans_wasi_args || !storage ||
            wasi_args_get(beans_wasi_args, storage) != 0)
            wasi_proc_exit(74);
    }
    if (wasi_environ_sizes_get(&beans_wasi_env_count, &environment_bytes) != 0)
        wasi_proc_exit(74);
    if (beans_wasi_env_count) {
        beans_wasi_envs = calloc(beans_wasi_env_count, sizeof(char*));
        char* storage = calloc(environment_bytes ? environment_bytes : 1, 1);
        if (!beans_wasi_envs || !storage ||
            wasi_environ_get(beans_wasi_envs, storage) != 0)
            wasi_proc_exit(74);
    }
}

const char* beans_wasi_arg(long long index) {
    // Match hosted Beans: os.args() contains user arguments, not argv[0].
    u64 actual = (u64)index + 1;
    if (index < 0 || actual >= beans_wasi_arg_count) return 0;
    return beans_wasi_args[actual];
}

const char* beans_wasi_env(const char* name) {
    size_t32 length = strlen(name);
    for (u32 i = 0; i < beans_wasi_env_count; i++) {
        const char* entry = beans_wasi_envs[i];
        if (memcmp(entry, name, length) == 0 && entry[length] == '=')
            return entry + length + 1;
    }
    return 0;
}

long long beans_wasi_clock_monotonic(void) {
    u64 nanos = 0;
    if (wasi_clock_time_get(1, 1, &nanos) != 0) wasi_proc_exit(74);
    return (long long)nanos;
}

long long beans_wasi_clock_wall(void) {
    u64 nanos = 0;
    if (wasi_clock_time_get(0, 1, &nanos) != 0) wasi_proc_exit(74);
    return (long long)nanos;
}

void beans_wasi_sleep(long long nanos) {
    if (nanos <= 0) return;
    wasi_subscription subscription;
    wasi_event event;
    memset(&subscription, 0, sizeof subscription);
    memset(&event, 0, sizeof event);
    subscription.tag = 0;
    subscription.clock.id = 1;
    subscription.clock.timeout = (u64)nanos;
    subscription.clock.precision = 1;
    u32 occurred = 0;
    if (wasi_poll_oneoff(&subscription, &event, 1, &occurred) != 0 ||
        occurred != 1 || event.error != 0)
        wasi_proc_exit(74);
}

int beans_wasi_random_fill(void* out, u64 count) {
    unsigned char* bytes = out;
    while (count) {
        u32 part = count > 0xffffffffULL ? 0xffffffffu : (u32)count;
        if (wasi_random_get(bytes, part) != 0) return 0;
        bytes += part;
        count -= part;
    }
    return 1;
}

long long beans_wasi_read_stdin(void* out, u64 count) {
    if (count > 0xffffffffULL) count = 0xffffffffULL;
    struct wasi_iovec iov;
    iov.buf = out;
    iov.len = (u32)count;
    u32 read = 0;
    if (wasi_fd_read(0, &iov, 1, &read) != 0) return -1;
    return (long long)read;
}

int beans_c_errno(void) { return errno; }
void beans_c_set_errno(int value) { errno = value; }

long long beans_host_format_f64(char* out, u64 cap, double value,
                                int places, int mode) {
    if (mode == 'f')
        return (long long)snprintf(out, (size_t32)cap, "%.*f", places, value);
    return (long long)snprintf(out, (size_t32)cap, "%.*g", places, value);
}

int beans_host_parse_f64(const char* text, double* out, const char** end) {
    char* stop = 0;
    *out = strtod(text, &stop);
    if (end) *end = stop;
    return stop != text;
}

// ---- entry ------------------------------------------------------------------
//
// The compiler emits `main`, as it does on every target, plus this plainly named
// wrapper for the C host. Clang's WASI frontend reserves the C spelling `main` and
// rewrites references to `__original_main`, even with -nostdlib, so the host must not
// name that symbol directly.

#if !defined(BEANS_WASM_LIBRARY)
extern int beans_program_main(int argc, char** argv);
__attribute__((export_name("_start"))) void _start(void) {
    beans_wasi_initialize();
    // WASI arguments are read through args_get by beans_os_args, not through C argv.
    int code = beans_program_main(0, 0);
    // A module that returns from _start is fine, but exiting explicitly makes the status
    // visible to wasmtime.
    wasi_proc_exit((u32)code);
}
#endif

// beans_class_parents and beans_deinit_sel are *not* here: the compiler emits both for
// every program, and defining them would be a duplicate symbol at link time.
