// The whole environment a Beans program gets on a microcontroller.
//
// `--runtime freestanding` produces a runtime that calls no libc and asks the surrounding
// program for five things. This file supplies those five, the handful of memory and string
// primitives the runtime declares for itself, the 64-bit integer helpers a 32-bit machine
// cannot do in one instruction, and a reset path that brings the CPU up and hands control
// to main. It is deliberately one file with no headers: there is no sysroot here, and a
// `#include <stdint.h>` would be reaching for a toolchain that is not installed.
//
// Two boards, both under QEMU:
//
//   BEANS_BOARD_MPS2    ARM MPS2-AN386, a Cortex-M4. Boots from a vector table at address
//                       0: word 0 is the initial stack pointer, word 1 the reset handler.
//                       Output goes to the CMSDK APB UART at 0x40004000.
//
//   BEANS_BOARD_VIRT    RISC-V `virt`, loaded at 0x80000000 with no bootloader, so the
//                       first instruction of _start is the first instruction executed.
//                       Output goes to a 16550 UART at 0x10000000, and the SiFive test
//                       finisher at 0x100000 powers the machine off.
//
// What is *not* here, deliberately: the soft-float and 64-bit-integer helpers. `int` in
// Beans is 64 bits and `float` is a double, so on a 32-bit machine a single `a / b` or
// `x + y` becomes a call to `__divdi3` or `__adddf3`. Those come from the bare-metal GCC's
// libgcc.a, which test/embedded.sh links. Hand-writing IEEE-754 soft float would be
// reimplementing — and less carefully — what every embedded toolchain already ships. This
// file has only what is genuinely specific to running Beans on these two boards.

typedef unsigned long long u64;
typedef long long i64;
typedef unsigned int u32;
typedef unsigned long usize; // 32-bit on both boards; the runtime's size_t

#if !defined(BEANS_BOARD_MPS2) && !defined(BEANS_BOARD_VIRT)
#error "define BEANS_BOARD_MPS2 or BEANS_BOARD_VIRT"
#endif

// ---- memory and string primitives -----------------------------------------
//
// The freestanding runtime declares these itself rather than including <string.h>, so it
// needs real definitions. Clang also lowers struct copies and array zeroing to memcpy and
// memset regardless of -ffreestanding, which is why they cannot simply be omitted.

void* memcpy(void* dst, const void* src, usize n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    for (usize i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void* memmove(void* dst, const void* src, usize n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    if (d == s || n == 0) return dst;
    if (d < s) {
        for (usize i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (usize i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

void* memset(void* dst, int value, usize n) {
    unsigned char* d = dst;
    for (usize i = 0; i < n; i++) d[i] = (unsigned char)value;
    return dst;
}

int memcmp(const void* a, const void* b, usize n) {
    const unsigned char* x = a;
    const unsigned char* y = b;
    for (usize i = 0; i < n; i++) {
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

void* memchr(const void* p, int c, usize n) {
    const unsigned char* s = p;
    for (usize i = 0; i < n; i++) {
        if (s[i] == (unsigned char)c) return (void*)(s + i);
    }
    return 0;
}

usize strlen(const char* s) {
    usize n = 0;
    while (s[n]) n++;
    return n;
}

// ARM's EABI names two of the above differently, and Clang emits the EABI spelling for
// zeroing. They take (dest, byte count) with no value — the value is always zero.
#if defined(BEANS_BOARD_MPS2)
void __aeabi_memclr(void* dst, usize n) { memset(dst, 0, n); }
void __aeabi_memclr4(void* dst, usize n) { memset(dst, 0, n); }
void __aeabi_memclr8(void* dst, usize n) { memset(dst, 0, n); }
void __aeabi_memcpy(void* dst, const void* src, usize n) { memcpy(dst, src, n); }
void __aeabi_memcpy4(void* dst, const void* src, usize n) { memcpy(dst, src, n); }
void __aeabi_memcpy8(void* dst, const void* src, usize n) { memcpy(dst, src, n); }
void __aeabi_memmove(void* dst, const void* src, usize n) { memmove(dst, src, n); }
void __aeabi_memset(void* dst, usize n, int value) { memset(dst, value, n); }
#endif

// ---- ARM unwind personality ------------------------------------------------
//
// LLVM gives every ARM function an EHABI unwind entry and names the personality routine
// in it, even for C with no exceptions anywhere. The routine can never run — Beans has no
// exceptions, a panic calls beans_host_exit, and mps2.ld discards .ARM.exidx outright —
// but the *reference* still has to resolve, and resolving it against libgcc's real
// unwinder drags in the whole unwinder, which then wants abort() and an exception index
// table that a bare-metal image does not have. Stubbing it is the standard answer, and an
// honest one: reaching one of these would mean an exception existed.
#if defined(BEANS_BOARD_MPS2)
void __aeabi_unwind_cpp_pr0(void) { }
void __aeabi_unwind_cpp_pr1(void) { }
void __aeabi_unwind_cpp_pr2(void) { }
#endif

// ---- the board -------------------------------------------------------------

#if defined(BEANS_BOARD_MPS2)
// CMSDK APB UART: DATA at +0x00, STATE at +0x04 (bit 0 = transmit buffer full),
// CTRL at +0x08 (bit 0 = transmit enable).
#define UART_BASE 0x40004000u
static void board_init(void) { *(volatile u32*)(UART_BASE + 0x08) = 1; }
static void board_putc(char c) {
    volatile u32* state = (volatile u32*)(UART_BASE + 0x04);
    while (*state & 1) { }
    *(volatile u32*)(UART_BASE + 0x00) = (u32)(unsigned char)c;
}
// No power-off device on this board. ARM semihosting is the supported way to stop it:
// `bkpt #0xAB` with the operation in r0 is a request to the debugger, and
// `-semihosting-config enable=on` in test/embedded.sh is what makes QEMU answer it rather
// than take a breakpoint fault. SYS_EXIT_EXTENDED (0x20) is the variant that can carry a
// status, which is what lets a panicking program be told apart from a clean one.
static void board_exit(int code) {
    static volatile u32 block[2];
    block[0] = 0x20026; // ADP_Stopped_ApplicationExit
    block[1] = (u32)code;
    __asm__ __volatile__(
        "mov r0, #0x20\n"
        "mov r1, %0\n"
        "bkpt #0xAB\n"
        :
        : "r"(block)
        : "r0", "r1", "memory");
    for (;;) { }
}
#else
// 16550 UART: THR at +0, LSR at +5 (bit 5 = transmit holding register empty).
#define UART_BASE 0x10000000u
#define FINISHER 0x100000u
static void board_init(void) { }
static void board_putc(char c) {
    volatile unsigned char* lsr = (volatile unsigned char*)(UART_BASE + 5);
    while (!(*lsr & 0x20)) { }
    *(volatile unsigned char*)UART_BASE = (unsigned char)c;
}
// The SiFive test finisher: 0x5555 powers off, and the exit status rides in the high
// half-word so a failing program is distinguishable from a passing one.
static void board_exit(int code) {
    *(volatile u32*)FINISHER = code ? (((u32)code << 16) | 0x3333u) : 0x5555u;
    for (;;) { }
}
#endif

// ---- the five hooks --------------------------------------------------------
//
// A bump allocator over a fixed arena. There is no MMU and no OS to grow a heap, so the
// arena is the machine's memory budget: exhausting it returns null, which the runtime
// already treats as an allocation failure and reports as a panic. free() is a no-op, which
// is a legitimate allocator — the contract only requires that a freed block is never
// handed out again while live.

#define ARENA_BYTES (1u << 20)
static unsigned char arena[ARENA_BYTES] __attribute__((aligned(16)));
static usize arena_used;

static void* bump(u64 size, u64 align) {
    if (align < 8) align = 8;
    usize base = (arena_used + (usize)align - 1) & ~((usize)align - 1);
    if (size > ARENA_BYTES || base > ARENA_BYTES - (usize)size) return 0;
    arena_used = base + (usize)size;
    return arena + base;
}

void* beans_host_alloc(u64 size, u64 align) {
    void* block = bump(size, align);
    if (block) memset(block, 0, (usize)size);
    return block;
}

// Sizes are not recorded, so a growing block is copied in full. That over-copies the tail,
// which is harmless: the arena is zeroed and every byte read past the old length belongs to
// the new block anyway.
void* beans_host_realloc(void* block, u64 size) {
    if (!block) return beans_host_alloc(size, 16);
    void* grown = beans_host_alloc(size, 16);
    if (!grown) return 0;
    usize copy = (usize)size;
    usize room = (usize)(arena + ARENA_BYTES - (unsigned char*)block);
    if (copy > room) copy = room;
    memcpy(grown, block, copy);
    return grown;
}

void beans_host_free(void* block) { (void)block; }

void beans_host_write(int stream, const char* bytes, u64 len) {
    (void)stream; // one UART, so stdout and stderr are the same wire
    for (u64 i = 0; i < len; i++) {
        if (bytes[i] == '\n') board_putc('\r');
        board_putc(bytes[i]);
    }
}

void beans_host_exit(int code) { board_exit(code); }

// ---- float formatting ------------------------------------------------------
//
// The runtime routes every float through these two rather than snprintf/strtod. The
// program prints one division, so the fixed-point conversion below is enough — and being
// explicit about that is better than a half-written dtoa that looks general.

static int digits_of(u64 value, char* out) {
    int n = 0;
    if (value == 0) { out[n++] = '0'; return n; }
    char reversed[24];
    int r = 0;
    while (value) {
        reversed[r++] = (char)('0' + (value % 10));
        value /= 10;
    }
    while (r) out[n++] = reversed[--r];
    return n;
}

int beans_host_format_f64(char* out, u64 cap, double value, int precision, char kind) {
    (void)kind;
    if (precision < 0) precision = 0;
    if (precision > 17) precision = 17;
    int n = 0;
    if (value < 0) { if ((u64)n < cap - 1) out[n++] = '-'; value = -value; }
    u64 whole = (u64)value;
    double fraction = value - (double)whole;
    char buf[24];
    int digits = digits_of(whole, buf);
    for (int i = 0; i < digits && (u64)n < cap - 1; i++) out[n++] = buf[i];
    if (precision > 0 && (u64)n < cap - 1) {
        out[n++] = '.';
        for (int i = 0; i < precision && (u64)n < cap - 1; i++) {
            fraction *= 10.0;
            int digit = (int)fraction;
            out[n++] = (char)('0' + digit);
            fraction -= (double)digit;
        }
    }
    out[n] = 0;
    return n;
}

// Only reached by string-to-float conversion, which examples/embedded.b never does. A
// wrong answer here would be worse than an obvious one, so it reports failure.
int beans_host_parse_f64(const char* text, double* out) {
    (void)text;
    (void)out;
    return 0;
}

// ---- startup ---------------------------------------------------------------

int main(void);

// Both boards run from ROM with .data still in flash, so the image's initialized data has
// to be copied into RAM and .bss zeroed before any C runs. The symbols come from the
// linker script.
extern unsigned char __data_start__, __data_end__, __data_load__, __bss_start__,
    __bss_end__;

static void start_c(void) {
    unsigned char* dst = &__data_start__;
    unsigned char* src = &__data_load__;
    while (dst < &__data_end__) *dst++ = *src++;
    for (unsigned char* p = &__bss_start__; p < &__bss_end__; p++) *p = 0;
    board_init();
    int code = main();
    board_exit(code);
}

#if defined(BEANS_BOARD_MPS2)
extern unsigned char __stack_top__;
static void fault(void) { board_exit(2); }
// The vector table, which is the entry point on Cortex-M: the CPU loads word 0 into the
// stack pointer and jumps to word 1 out of reset. The three fault handlers exist so that a
// bad access stops the machine with a status instead of looping forever inside QEMU.
__attribute__((used, section(".vectors"))) void (*const vectors[])(void) = {
    (void (*)(void)) & __stack_top__,
    start_c, // reset
    fault,   // NMI
    fault,   // hard fault
    fault,   // memory management fault
};
#else
// RISC-V has no vector table to boot from: QEMU jumps straight to the ELF entry point,
// so the first job is to have a stack at all.
extern unsigned char __stack_top__;
__attribute__((used, naked, section(".text.start"))) void _start(void) {
    __asm__ __volatile__(
        "la sp, __stack_top__\n"
        "call start_c_trampoline\n"
        "1: j 1b\n");
}
__attribute__((used)) void start_c_trampoline(void) { start_c(); }
#endif
