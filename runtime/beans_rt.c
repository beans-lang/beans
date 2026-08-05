// beans native runtime — reference-counted heap + cycle collector.
// Every heap value has a 16-byte header just before its payload:
//   { long long rc, long long meta }   (rc ops turn atomic at first spawn)
// meta bits 0-2 = kind, bits 3-60 = per-kind shape payload:
//   0 leaf | 1 fixed (bitmask of pointer slots) | 2 list (elem_ptr)
//   3 map (key_ptr | val_ptr<<1) | 4 chan (elem_ptr) | 5 mutex (inner_ptr)
//   6 OS resource (shape bit 0: 0 = file — drop closes the fd,
//                               1 = mmap — drop unmaps)
//   7 arena (elem_ptr)
// meta bits 61-62 = collector color, bit 63 = in the root buffer.
// String constants carry an immortal header emitted by the compiler.
//
// Cycles: plain RC can't free A<->B. The collector is Bacon-Rajan trial
// deletion (Nim's ORC family): a decrement that doesn't reach zero parks the
// object as a possible cycle root; a collection trial-deletes each root's
// subgraph, restores whatever still has external counts, frees the rest.
// It only runs when no worker threads are live (checked in beans_alloc and
// at exit), so the mutator is exactly one thread: ourselves, between
// statements. Everything is iterative — a million-node ring must not
// overflow the C stack.
// ---- runtime profile -------------------------------------------------------
//
// BEANS_RT_PROFILE decides how much of this file exists. The levels and the
// capability table live in compiler/bootstrap/runtime_profile.h, which the compiler reads too:
// it refuses at *check* time to use anything a profile compiles out, so a
// mismatch is a clear message about a capability rather than an undefined
// symbol.
//
//   3 full          everything (the default)
//   2 minimal       libc, but no filesystem, sockets, processes, poller,
//                   signals, shared memory or dynamic libraries
//   1 freestanding  no operating system at all: memory and output come from
//                   hooks, and threads are gone with the rest
//
// The core — reference counting, the cycle collector, strings, lists, maps and
// bytes — is in every profile, because none of it needs an OS.
#ifndef BEANS_RT_PROFILE
#define BEANS_RT_PROFILE 3
#endif

#define BEANS_RT_FREESTANDING 1
#define BEANS_RT_MINIMAL 2
#define BEANS_RT_FULL 3

#if BEANS_RT_PROFILE >= BEANS_RT_FULL
// Defined with the readiness reactor far below; every runtime path that
// closes a descriptor reports it here so a parked await on that number
// finishes false instead of attaching itself to whatever resource the
// OS hands the number to next.
void beans_reactor_note_close(long long fd);
#endif

// ---- portable decimal ------------------------------------------------------
//
// Decimal carries a signed 128-bit coefficient as two u64 limbs. It therefore
// compiles on 32-bit Clang and MSVC without a source-level 128-bit integer.
// Runtime profiles which omit decimal still refuse the type through
// TargetSpec::has_decimal.
//
// Deliberately not defaulted from a host `#ifdef`: the driver passes it from
// the selected TargetSpec, so a cross build cannot inherit the compiler host's
// answer.
#ifndef BEANS_RT_DECIMAL
#define BEANS_RT_DECIMAL 1
#endif

#ifndef BEANS_RT_WASI
#define BEANS_RT_WASI 0
#endif

// Windows is grouped with wasm here on purpose: preserve_most interacts with
// Win64 SEH unwind tables, and nothing has proven that pairing yet. Deinit
// call sites pay a few register saves until it is. Generated IR never names
// the convention, so dropping it here cannot mismatch a caller.
//
// 32-bit x86 (`__i386__`, a clang *target* predefine — this reads the target
// being compiled for, not the host) is here for a harder reason: LLVM's i686
// backend segfaults in the CFI-insertion pass on a `preserve_most` function
// (it crashes lowering `beans_do_deinit`). PowerPC is excluded too: the
// convention is not a supported PowerPC ABI, and using it on ppc32 corrupts
// registers when a deinit runs after a worker thread. ARM32 and LoongArch
// Clang also report the convention unsupported. The attribute is only an
// optimization, so dropping it keeps those targets building at the cost of a
// few register saves per deinit, exactly like wasm and Windows.
#if defined(__wasm__) || defined(_WIN32) || defined(__i386__) || \
    defined(__powerpc__) || defined(__arm__) || defined(__loongarch__) || \
    defined(__loongarch64)
#define BEANS_DEINIT_ATTR __attribute__((noinline, cold))
#else
#define BEANS_DEINIT_ATTR __attribute__((noinline, cold, preserve_most))
#endif

// The container structs (BList, BArena, BMap) keep a `{ptr data; i64 len, cap;
// ...}` prefix that generated code reads by *hardcoded byte offset* — len at 8,
// cap at 16 — because `list.len()`/`map.len()` are direct field loads in the IR.
// That is only right when the i64 fields sit at 8-byte offsets, which holds on
// every target except 32-bit x86: there a pointer is 4 bytes and `long long`
// aligns to 4, so `len` would land at offset 4 and every direct load would read
// garbage (it did — a bogus length then drove out-of-bounds loops into SIGSEGV).
// Forcing the i64 fields to 8-byte alignment pads the pointer to 8 on i686 and
// makes the prefix layout identical on every target, so the IR's fixed offsets
// stay correct without the compiler ever emitting a target-specific offset. It
// is a no-op wherever `long long` is already 8-aligned (all 64-bit targets, and
// wasm/ARM/RISC-V 32-bit, whose ABIs align it to 8).
#define RT_LEN8 __attribute__((aligned(8)))

// Ask glibc for POSIX 2008 before anything is included. Without it, compiling with
// `-std=c11` rather than `-std=gnu11` sets __STRICT_ANSI__, and glibc then declares only
// ISO C — `strdup` and `lstat` disappear and the filesystem section stops compiling.
// macOS hides this: Darwin's headers expose POSIX regardless, so a Linux-only failure sat
// unnoticed until the container gate was re-run. Defining _DEFAULT_SOURCE alone is
// deliberate; adding _POSIX_C_SOURCE would *suppress* the BSD extras it implies.
#define _DEFAULT_SOURCE 1

// Large-file support on 32-bit Linux, which has the same must-precede-every-
// include rule. The default `off_t` there is 32-bit and `readdir` returns a
// 32-bit `struct dirent`, so an inode number past 2^32 — routine on overlayfs
// and tmpfs, i.e. most container filesystems — overflows the conversion and
// `readdir` returns NULL. `Dir.list` then came back empty and file offsets
// truncated. LFS makes `readdir` resolve to `readdir64`, `off_t` 64-bit and
// `stat` to `stat64`. 64-bit Linux already has all of this, so scope it to
// ILP32 to keep those builds byte-identical.
#if defined(__linux__) && !defined(__LP64__)
#define _FILE_OFFSET_BITS 64
#endif

// The MSVCRT knobs have the same must-precede-every-include rule as
// _DEFAULT_SOURCE: rand_s exists only under _CRT_RAND_S, and it is the one
// CSPRNG reachable from MinGW without linking another library.
#if defined(_WIN32)
#define _CRT_RAND_S 1
#endif

#if (BEANS_RT_PROFILE >= BEANS_RT_FULL || BEANS_RT_WASI) && !defined(_WIN32)
#include <dirent.h>
#endif
// The POSIX service headers. Windows compiles the full profile too: its
// filesystem tier rides on the CRT plus a Win32 shim in the fs section, and
// sockets, the poller and dynamic libraries ride Winsock/Win32 includes in
// their own sections. Signals and process spawn stay refused per-capability
// there.
#if BEANS_RT_PROFILE >= BEANS_RT_FULL && !defined(_WIN32)
#include <dlfcn.h>
#include <netdb.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#if defined(__linux__)
#include <sys/epoll.h>
#include <sys/signalfd.h>
#else
#include <sys/event.h>
#endif
#endif
// stdarg, stdint, stddef and limits are *freestanding* headers: the compiler provides
// them with no sysroot at all. Everything else here is libc, and a real freestanding
// target — wasm32 without a sysroot, a bare-metal board — does not have the files, let
// alone the functions. Removing the calls was not enough; the includes had to go too.
#include <limits.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL || BEANS_RT_WASI
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <wchar.h>
#if !defined(_WIN32)
#include <unistd.h>
#endif

#endif
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
#include <math.h>
#if !defined(_WIN32)
#include <pthread.h>
#endif
#include <signal.h>
#if defined(__linux__)
// getrandom is reached through the syscall directly: glibc only grew a wrapper in
// 2.25, and this runtime is meant to build against whatever libc is present.
#include <sys/syscall.h>
#endif
#if defined(_WIN32)
// _setmode/_fileno live here. The CRT otherwise opens the standard streams in
// text mode and rewrites \n to \r\n, which no POSIX platform does — it would
// break byte-identical differential testing, and worse, silently corrupt
// binary output a program writes to stdout.
#include <io.h>
// Every hosted Windows profile needs Win32, not just the full one: the minimal
// tier already sleeps through Sleep() and reads the environment through
// GetEnvironmentVariable. This used to be included with the filesystem shim far
// below, which compiled on the full profile and nowhere else — `--runtime
// minimal` for Windows failed on undeclared Sleep and DWORD.
// WIN32_LEAN_AND_MEAN must stay attached to it: without it windows.h drags in
// the original winsock.h, which collides with the winsock2.h the sockets
// section needs.
#define WIN32_LEAN_AND_MEAN 1
#include <windows.h>
#endif
#include <time.h>
#else
// The memory and string primitives every freestanding toolchain is expected to
// provide, declared here because <string.h> does not exist. These are the only
// external functions the freestanding core needs beyond the five hooks.
void* memcpy(void* dst, const void* src, size_t n);
void* memmove(void* dst, const void* src, size_t n);
void* memset(void* dst, int c, size_t n);
int memcmp(const void* a, const void* b, size_t n);
void* memchr(const void* p, int c, size_t n);
size_t strlen(const char* s);
#endif

// Keep the runtime's signed byte-count type private. Recent LLVM-MinGW CRTs
// already declare `ssize_t` (as `int` on i686), while older Windows SDKs only
// provide `SSIZE_T`. Defining the POSIX name ourselves therefore either
// collides with the CRT or depends on its version.
#if (BEANS_RT_PROFILE >= BEANS_RT_MINIMAL || BEANS_RT_WASI) && !defined(_WIN32)
typedef ssize_t rt_ssize_t;
#endif

// MSVC's <sys/stat.h> exposes the mode bits under their underscored names but
// omits the POSIX predicates MinGW and Unix provide. Keep the filesystem code
// on one spelling without depending on which Windows CRT supplied the header.
#if defined(_WIN32)
#ifndef S_ISREG
#define S_ISREG(mode) (((mode) & _S_IFMT) == _S_IFREG)
#endif
#ifndef S_ISDIR
#define S_ISDIR(mode) (((mode) & _S_IFMT) == _S_IFDIR)
#endif
#endif

// Public Bytes/MMap words and the small buffers exchanged with Beans stdlib
// code are always little-endian. Do not memcpy an integer into those buffers:
// that silently reverses their format on PowerPC and s390x.
static unsigned long long rt_load_le(const void* source, size_t width) {
    const unsigned char* bytes = (const unsigned char*)source;
    unsigned long long value = 0;
    size_t i;
    for (i = 0; i < width; i++) value |= (unsigned long long)bytes[i] << (i * 8);
    return value;
}

static void rt_store_le(void* destination, unsigned long long value, size_t width) {
    unsigned char* bytes = (unsigned char*)destination;
    size_t i;
    for (i = 0; i < width; i++) bytes[i] = (unsigned char)(value >> (i * 8));
}

#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL && defined(_WIN32)
// ---- Win32 threading compatibility ----------------------------------------
//
// The runtime used pthread names internally even on Windows, forcing every PE
// binary to carry winpthreads and making the MSVC ABI impossible. These small
// adapters preserve the runtime's existing lock/thread logic while using only
// Windows 10 primitives. They are internal C helpers, not a public ABI.
typedef SRWLOCK pthread_mutex_t;
typedef CONDITION_VARIABLE pthread_cond_t;
typedef HANDLE pthread_t;
typedef struct {
    INIT_ONCE once;
    void (*routine)(void);
} pthread_once_t;

#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#define PTHREAD_ONCE_INIT {INIT_ONCE_STATIC_INIT, NULL}

typedef SSIZE_T rt_ssize_t;
#define read _read
#define write _write
#define close _close
#define strdup _strdup

static int pthread_mutex_init(pthread_mutex_t* mutex, const void* unused) {
    (void)unused;
    InitializeSRWLock(mutex);
    return 0;
}
static int pthread_mutex_destroy(pthread_mutex_t* mutex) {
    (void)mutex;
    return 0;
}
static int pthread_mutex_lock(pthread_mutex_t* mutex) {
    AcquireSRWLockExclusive(mutex);
    return 0;
}
static int pthread_mutex_unlock(pthread_mutex_t* mutex) {
    ReleaseSRWLockExclusive(mutex);
    return 0;
}
static int pthread_cond_init(pthread_cond_t* condition, const void* unused) {
    (void)unused;
    InitializeConditionVariable(condition);
    return 0;
}
static int pthread_cond_destroy(pthread_cond_t* condition) {
    (void)condition;
    return 0;
}
static int pthread_cond_wait(pthread_cond_t* condition,
                             pthread_mutex_t* mutex) {
    return SleepConditionVariableSRW(condition, mutex, INFINITE, 0) ? 0 : EINVAL;
}
static int pthread_cond_signal(pthread_cond_t* condition) {
    WakeConditionVariable(condition);
    return 0;
}
static int pthread_cond_broadcast(pthread_cond_t* condition) {
    WakeAllConditionVariable(condition);
    return 0;
}

static unsigned long long win_unix_time_ms(void) {
    FILETIME file_time;
    ULARGE_INTEGER ticks;
    GetSystemTimeAsFileTime(&file_time);
    ticks.LowPart = file_time.dwLowDateTime;
    ticks.HighPart = file_time.dwHighDateTime;
    return (ticks.QuadPart - 116444736000000000ULL) / 10000ULL;
}
static int pthread_cond_timedwait(pthread_cond_t* condition,
                                  pthread_mutex_t* mutex,
                                  const struct timespec* deadline) {
    unsigned long long wanted =
        (unsigned long long)deadline->tv_sec * 1000ULL +
        ((unsigned long long)deadline->tv_nsec + 999999ULL) / 1000000ULL;
    unsigned long long now = win_unix_time_ms();
    unsigned long long remaining = wanted > now ? wanted - now : 0;
    DWORD timeout = remaining >= (unsigned long long)(INFINITE - 1)
                        ? INFINITE - 1
                        : (DWORD)remaining;
    if (SleepConditionVariableSRW(condition, mutex, timeout, 0)) return 0;
    return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
}

typedef struct {
    void* (*routine)(void*);
    void* argument;
} WinThreadStart;

static DWORD WINAPI win_thread_start(void* raw) {
    WinThreadStart start = *(WinThreadStart*)raw;
    free(raw);
    start.routine(start.argument);
    return 0;
}
static int pthread_create(pthread_t* thread, const void* unused,
                          void* (*routine)(void*), void* argument) {
    (void)unused;
    WinThreadStart* start = (WinThreadStart*)malloc(sizeof(WinThreadStart));
    if (!start) return ENOMEM;
    start->routine = routine;
    start->argument = argument;
    *thread = CreateThread(NULL, 0, win_thread_start, start, 0, NULL);
    if (!*thread) {
        free(start);
        return EAGAIN;
    }
    return 0;
}
static int pthread_join(pthread_t thread, void** result) {
    DWORD waited = WaitForSingleObject(thread, INFINITE);
    if (result) *result = NULL;
    CloseHandle(thread);
    return waited == WAIT_OBJECT_0 ? 0 : EINVAL;
}

static BOOL CALLBACK win_once_start(PINIT_ONCE raw, PVOID parameter,
                                    PVOID* context) {
    (void)raw;
    (void)context;
    pthread_once_t* once = (pthread_once_t*)parameter;
    once->routine();
    return TRUE;
}
static int pthread_once(pthread_once_t* once, void (*routine)(void)) {
    union { void* pointer; void (*function)(void); } wanted, empty;
    wanted.function = routine;
    empty.pointer = NULL;
    InterlockedCompareExchangePointer((void* volatile*)&once->routine,
                                      wanted.pointer, empty.pointer);
    return InitOnceExecuteOnce(&once->once, win_once_start, once, NULL) ? 0 : EINVAL;
}
#endif

#if BEANS_RT_PROFILE >= BEANS_RT_FULL && !defined(_WIN32)
extern char** environ;
#endif

// ---- host hooks -------------------------------------------------------------
//
// The freestanding profile has no libc, so everything it cannot compute itself
// comes through these. The ABI is fixed and documented, because someone else has
// to implement it:
//
//   void* beans_host_alloc(unsigned long long size, unsigned long long align)
//       Returns `size` bytes, **zeroed**, aligned to at least `align` — always a
//       power of two, never less than 16 (the reference-count header's own
//       alignment, so the payload after it lands where the compiler expects).
//       `size` is never 0. NULL means out of memory and the runtime panics.
//
//   void* beans_host_realloc(void* block, unsigned long long size)
//       Grows or shrinks, moving if it must, preserving the bytes that fit.
//       Bytes beyond the old size are **not** required to be zero — the runtime
//       writes them before reading. NULL means out of memory.
//
//   void beans_host_free(void* block)
//       `block` always came from alloc or realloc, and is never NULL.
//
//   void beans_host_write(int stream, const char* bytes, unsigned long long len)
//       1 is standard output, 2 is standard error. Partial writes are the
//       implementer's problem to retry; the runtime treats the call as complete.
//
//   void beans_host_exit(int code)
//       Must not return. Called for a normal end and after a panic.
//
//   long long beans_host_format_f64(char* out, unsigned long long cap,
//                                   double value, int places, int mode)
//   int beans_host_parse_f64(const char* text, double* out, const char** end)
//       Floating-point text, which cannot be done in a few lines correctly.
//       mode 'g' asks for `places` significant digits, 'f' for `places` decimals.
//       A program that never prints or parses a float never calls these, so the
//       weak defaults below panic rather than being absent — a missing symbol
//       would fail the link for programs that do not need it.
//
// Three rules for every implementer:
//
//   **A hook must not call back into any beans_ function.** The allocator runs
//   inside allocation; re-entering it is unbounded recursion, not a deadlock you
//   can debug.
//
//   **The panic path must not allocate.** beans_panic formats into a fixed stack
//   buffer and calls write then exit, so a panic still works when memory is what
//   ran out.
//
//   **Hooks are supplied by linking a definition**, never by editing the emitted
//   IR. They are weak in the hosted profiles, so overriding one is a matter of
//   defining it.
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
// Hosted: the hooks exist and are weak, so a program can replace any of them,
// but the runtime itself uses libc directly. That keeps the generated code for
// the default profile exactly what it was — a hook on the allocation hot path
// would cost every program to serve the one that overrides it.
#define rt_zalloc(n) calloc(1, (size_t)(n))
#define rt_realloc(p, n) realloc((p), (size_t)(n))
#define rt_free(p) free(p)

__attribute__((weak)) void* beans_host_alloc(unsigned long long size,
                                             unsigned long long align) {
#if defined(_WIN32)
    // MSVCRT has no posix_memalign, and _aligned_malloc's blocks may not be
    // handed to plain free(), which this hook's contract requires. The runtime
    // itself never asks this hook for more than 16 on Windows — beans_raw_alloc
    // carries its own wrapped representation there — so anything stricter is
    // honestly refused rather than quietly under-aligned.
    if (align <= 16) return calloc(1, (size_t)size);
    return NULL;
#else
    void* out = NULL;
    if (align <= 16) return calloc(1, (size_t)size);
    if (posix_memalign(&out, (size_t)align, (size_t)size) != 0) return NULL;
    memset(out, 0, (size_t)size);
    return out;
#endif
}
__attribute__((weak)) void* beans_host_realloc(void* block,
                                               unsigned long long size) {
    return realloc(block, (size_t)size);
}
__attribute__((weak)) void beans_host_free(void* block) { free(block); }
__attribute__((weak)) void beans_host_write(int stream, const char* bytes,
                                            unsigned long long len) {
    fwrite(bytes, 1, (size_t)len, stream == 2 ? stderr : stdout);
}
__attribute__((weak)) void beans_host_exit(int code) { exit(code); }
__attribute__((weak)) long long beans_host_format_f64(char* out,
                                                      unsigned long long cap,
                                                      double value, int places,
                                                      int mode) {
    if (mode == 'f') return snprintf(out, (size_t)cap, "%.*f", places, value);
    return snprintf(out, (size_t)cap, "%.*g", places, value);
}
__attribute__((weak)) int beans_host_parse_f64(const char* text, double* out,
                                               const char** end) {
    char* stop = NULL;
    *out = strtod(text, &stop);
    if (end) *end = stop;
    return stop != text;
}
#else
// Freestanding: no defaults for memory, output or exit. A program must define
// them, and a missing one is a link error naming exactly what is absent.
void* beans_host_alloc(unsigned long long size, unsigned long long align);
void* beans_host_realloc(void* block, unsigned long long size);
void beans_host_free(void* block);
void beans_host_write(int stream, const char* bytes, unsigned long long len);
void beans_host_exit(int code);

static void* rt_zalloc(unsigned long long n) { return beans_host_alloc(n, 16); }
static void* rt_realloc(void* p, unsigned long long n) {
    return p ? beans_host_realloc(p, n) : beans_host_alloc(n, 16);
}
static void rt_free(void* p) {
    if (p) beans_host_free(p);
}

// Weak, and they fail loudly: a program that never touches float text never
// calls them, and one that does gets a message rather than a missing symbol.
long long beans_rt_no_float(void);
__attribute__((weak)) long long beans_host_format_f64(char* out,
                                                      unsigned long long cap,
                                                      double value, int places,
                                                      int mode) {
    (void)out; (void)cap; (void)value; (void)places; (void)mode;
    return beans_rt_no_float();
}
__attribute__((weak)) int beans_host_parse_f64(const char* text, double* out,
                                               const char** end) {
    (void)text; (void)out; (void)end;
    return (int)beans_rt_no_float();
}
#endif

#if defined(_WIN32) && BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
// The runtime owns stdout buffering on Windows. Differential testing diffs
// the two streams merged, and glibc's discipline — a redirected stdout is
// fully buffered, so a mid-run stderr line lands before stdout's exit-time
// flush — is part of what "byte-identical" means. MSVCRT's setvbuf would be
// the natural spelling, but Wine's msvcrt does not reliably honour it, so
// the buffer lives here where no CRT can reinterpret it. A console stays
// write-through: buffering an interactive prompt would be correctness for
// the test harness at the price of a broken user experience.
// The buffer is process-wide, so every thread that prints shares it. An SRWLOCK
// rather than a pthread mutex: it is statically initializable, needs no
// teardown, and an uncontended acquire costs a few instructions — which matters
// because this is on the path of every println. Threads print concurrently in
// examples/threads.b; without the lock two of them race in realloc and memcpy
// and the result is lost output or a corrupted heap.
static SRWLOCK win_out_lock = SRWLOCK_INIT;
static char* win_out_buf;
static unsigned long long win_out_len, win_out_cap;
static int win_out_tty = -1;
// Callers of the _locked form already hold the lock; SRWLOCK is not recursive.
static void win_out_flush_locked(void) {
    if (win_out_len) {
        fwrite(win_out_buf, 1, (size_t)win_out_len, stdout);
        fflush(stdout);
        win_out_len = 0;
    }
}
static void win_out_flush(void) {
    AcquireSRWLockExclusive(&win_out_lock);
    win_out_flush_locked();
    ReleaseSRWLockExclusive(&win_out_lock);
}
#endif

#if defined(_WIN32) && BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
// Beans strings are UTF-8. The A-suffixed Windows functions decode their
// arguments with the process ANSI code page, which is almost never UTF-8 — so a
// path, argument or environment value outside ASCII either turns to mojibake or
// fails outright. Every Windows call that takes text converts here, once, at the
// boundary, and uses the W form. Both return malloc'd memory the caller frees;
// both return NULL on a bad conversion or on no memory, which callers treat the
// same way because there is nothing useful to do differently.
static wchar_t* win_widen(const char* utf8) {
    if (!utf8) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* out = malloc((size_t)n * sizeof(wchar_t));
    if (!out) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, n) != n) {
        free(out);
        return NULL;
    }
    return out;
}
static char* win_narrow(const wchar_t* wide) {
    if (!wide) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char* out = malloc((size_t)n);
    if (!out) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, n, NULL, NULL) != n) {
        free(out);
        return NULL;
    }
    return out;
}
#endif

// One byte sink, so the core never names stdout or stderr.
static void rt_write(int stream, const char* bytes, unsigned long long len) {
#if defined(_WIN32) && BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
    if (stream == 2) {
        fwrite(bytes, 1, (size_t)len, stderr);
        fflush(stderr);
        return;
    }
    AcquireSRWLockExclusive(&win_out_lock);
    if (win_out_tty < 0) win_out_tty = _isatty(_fileno(stdout));
    if (win_out_tty) {
        fwrite(bytes, 1, (size_t)len, stdout);
        ReleaseSRWLockExclusive(&win_out_lock);
        return;
    }
    if (win_out_len + len > win_out_cap) {
        unsigned long long next = win_out_cap ? win_out_cap * 2 : 1 << 16;
        while (next < win_out_len + len) next *= 2;
        // Into a temporary: assigning realloc's result straight to win_out_buf
        // loses the old pointer when it returns NULL, which leaks the buffer
        // and then dereferences NULL in the memcpy below.
        char* grown = realloc(win_out_buf, (size_t)next);
        if (!grown) {
            // No room to buffer this piece. Drain what is already held and
            // write it straight through rather than dropping it — output that
            // vanishes under memory pressure is worse than output that
            // interleaves differently.
            win_out_flush_locked();
            fwrite(bytes, 1, (size_t)len, stdout);
            ReleaseSRWLockExclusive(&win_out_lock);
            return;
        }
        win_out_buf = grown;
        win_out_cap = next;
    }
    memcpy(win_out_buf + win_out_len, bytes, (size_t)len);
    win_out_len += len;
    if (win_out_len >= (1u << 20)) win_out_flush_locked();
    ReleaseSRWLockExclusive(&win_out_lock);
#elif BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
    fwrite(bytes, 1, (size_t)len, stream == 2 ? stderr : stdout);
#else
    beans_host_write(stream, bytes, len);
#endif
}

// The one flush anything outside this file should call. On Windows the pending
// stdout bytes are in the buffer above, not in stdio's, so a bare fflush(NULL)
// drains nothing — which is exactly how the interpreter's panic line ended up
// ahead of the program's own output on real Windows and nowhere else.
void beans_out_flush(void) {
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
#if defined(_WIN32)
    win_out_flush();
#endif
    fflush(stdout);
#endif
}

// Unzeroed allocation, for buffers the caller fills immediately. Separate from
// rt_zalloc so the hosted profiles keep using malloc where they always did — a
// blanket calloc would zero every list growth for the benefit of nobody.
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
#define rt_alloc(n) malloc((size_t)(n))
#else
static void* rt_alloc(unsigned long long n) { return beans_host_alloc(n, 16); }
#endif

// ---- formatting without libc ------------------------------------------------
//
// The core builds messages — panic text, `show` output, error strings — and every
// one of them uses only %lld, %llu, %s, %c and %%. Writing those out is a page of
// code and removes snprintf from the freestanding profile entirely.
//
// Floats are not here on purpose: correct decimal output for a double is not a
// page of code, so it stays a host hook.
static unsigned long long rt_utoa(unsigned long long v, char* out) {
    char tmp[24];
    unsigned long long n = 0;
    do { tmp[n++] = (char)('0' + (v % 10)); v /= 10; } while (v);
    for (unsigned long long i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

static unsigned long long rt_itoa(long long v, char* out) {
    if (v < 0) {
        out[0] = '-';
        // Negate in unsigned space: -LLONG_MIN overflows a long long.
        return 1 + rt_utoa((unsigned long long)0 - (unsigned long long)v, out + 1);
    }
    return rt_utoa((unsigned long long)v, out);
}

// snprintf's contract for the subset the core uses: writes at most cap-1 bytes
// plus a terminator, and returns the length it *would* have written.
static long long rt_vformat(char* out, unsigned long long cap, const char* fmt,
                            va_list ap) {
    unsigned long long at = 0;
    char scratch[24];
    for (const char* p = fmt; *p; p++) {
        const char* piece = NULL;
        unsigned long long len = 0;
        char one = 0;
        if (*p != '%') {
            one = *p;
            piece = &one;
            len = 1;
        } else {
            p++;
            if (p[0] == 'l' && p[1] == 'l' && (p[2] == 'd' || p[2] == 'u')) {
                len = p[2] == 'd' ? rt_itoa(va_arg(ap, long long), scratch)
                                  : rt_utoa(va_arg(ap, unsigned long long), scratch);
                piece = scratch;
                p += 2;
            } else if (*p == 'd') {
                len = rt_itoa((long long)va_arg(ap, int), scratch);
                piece = scratch;
            } else if (*p == 's') {
                const char* text = va_arg(ap, const char*);
                if (!text) text = "(null)";
                piece = text;
                while (text[len]) len++;
            } else if (*p == 'c') {
                one = (char)va_arg(ap, int);
                piece = &one;
                len = 1;
            } else { // %% and anything unrecognised: emit it literally
                one = *p;
                piece = &one;
                len = 1;
            }
        }
        for (unsigned long long i = 0; i < len; i++) {
            if (at + 1 < cap) out[at] = piece[i];
            at++;
        }
    }
    if (cap) out[at + 1 < cap ? at : cap - 1] = 0;
    return (long long)at;
}

#ifdef BEANS_RT_FORMAT_CHECK
// Exposed only for test/freestanding.sh, which compares the hand-written integer
// formatting against snprintf across the edges — zero, the sign boundary, and
// LLONG_MIN, whose positive counterpart does not exist.
long long beans_rt_check_format(char* out, unsigned long long cap, long long value,
                                int as_unsigned);
#endif

static long long rt_format(char* out, unsigned long long cap, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    long long n = rt_vformat(out, cap, fmt, ap);
    va_end(ap);
    return n;
}

#ifdef BEANS_RT_FORMAT_CHECK
long long beans_rt_check_format(char* out, unsigned long long cap, long long value,
                                int as_unsigned) {
    if (as_unsigned)
        return rt_format(out, cap, "%llu", (unsigned long long)value);
    return rt_format(out, cap, "%lld", value);
}
#endif


// ---- the object ABI, shared with codegen ------------------------------------
//
// compiler/bootstrap/object_abi.h states these for the compiler; here they come from the target's
// own pointer size, so the two agree by derivation rather than by coincidence.
// They used to agree by coincidence: codegen wrote a pointer slot as `offset / 8`
// and this file read it as `slot * 8`, which is right on both 64-bit targets and
// wrong together on any 32-bit one. test/object_abi.sh checks them against each
// other.
//
// The header stays 16 bytes everywhere: the count needs its size-class bits and
// meta needs its shape mask plus three collector bits, and neither fits in 32.
#define RT_HEADER_SIZE 16
#define RT_MASK_SLOTS 58
#define RT_SLOT_STRIDE ((long long)sizeof(void*))
#define RT_EXTENDED_MASK ((1LL << RT_MASK_SLOTS) - 1)
// Byte offset of a mask slot. The one place the stride is applied, so a walker
// cannot use a different one by accident.
#define RT_SLOT_AT(base, slot) ((char*)(base) + (long long)(slot) * RT_SLOT_STRIDE)
// A class descriptor is {i64 class_id, ptr extended_shape, [N x ptr] methods}.
// The shape is null unless the class is too wide for the inline header mask.
#define RT_DESC_ID_SIZE 8
#define RT_DESC_SHAPE_OFFSET RT_DESC_ID_SIZE
#define RT_DESC_METHODS_OFFSET (RT_DESC_ID_SIZE + (long long)sizeof(void*))

// A generic scalar slot is always an i64. Pointer values enter it through
// ptrtoint, so on big-endian ILP32 the pointer bytes occupy the second four
// bytes. Fixed-layout objects and typed aggregates contain real pointer fields
// and do not use this adjustment.
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define RT_I64_PTR_OFFSET ((long long)(8 - sizeof(void*)))
#else
#define RT_I64_PTR_OFFSET 0LL
#endif
#define RT_I64_SLOT_MASK_AT(offset) \
    (1LL << (((long long)(offset) + RT_I64_PTR_OFFSET) / RT_SLOT_STRIDE))

static void* rt_i64_slot_child(const void* slot) {
    unsigned long long raw = 0;
    memcpy(&raw, slot, sizeof(raw));
    return (void*)(uintptr_t)raw;
}

static void* rt_masked_child(void* value, int slot, int i64_encoded) {
    if (i64_encoded) return rt_i64_slot_child(value);
    void* child = NULL;
    memcpy(&child, RT_SLOT_AT(value, slot), sizeof(child));
    return child;
}

#define BEANS_IMMORTAL (1LL << 62)

// rc layout: bits 0-47 the count, bits 48-59 the allocation size class
// (0 = plain malloc), bit 62 immortal. Retain/release preserve the class
// bits by adding/subtracting 1; every test of the COUNT must mask with
// RC_COUNT, and class 4095 * 16 bytes stays far under the immortal bit.
#define RC_CLS_SHIFT 48
#define RC_CLS_MAX 4095LL
#define RC_COUNT(v) ((v) & ((1LL << RC_CLS_SHIFT) - 1))
// rc bit 61: this object's class chain has a deinit — user code runs when the
// count hits zero. Lives in the rc word (not meta) so pointer-mask walkers and
// shell frees never see it; retain/release arithmetic can't carry into it.
#define RC_FIN (1LL << 61)

// meta layout
#define CC_SHAPE ((1LL << 61) - 1)
#define CC_COLOR (3LL << 61)
#define CC_BLACK 0LL
#define CC_GRAY (1LL << 61)
#define CC_WHITE (2LL << 61)
#define CC_PURPLE (3LL << 61)
#define CC_BUF ((long long)(1ULL << 63))

// 8-byte aligned so the 64-bit atomics on `rc`/`meta` stay lock-free on ILP32
// targets. On a 64-bit target i64 is already 8-aligned and this is a no-op; on
// i686, `long long` defaults to 4-byte alignment, so without this Clang lowers
// every `__atomic_*` on the count to a `__atomic_*_8` libcall (an undefined
// symbol at link time — i686 has CMPXCHG8B and needs no libatomic). The size
// stays 16, so object_abi.h's header layout is unchanged on every target.
typedef struct {
    long long rc;
    long long meta;
} __attribute__((aligned(8))) BHead;

static BHead* head_of(void* p) { return (BHead*)((char*)p - 16); }

typedef struct {
    long long count;
    long long offsets[];
} BExtendedShape;

static BExtendedShape* rt_extended_shape(void* p) {
    char* descriptor = NULL;
    BExtendedShape* shape = NULL;
    // Packed classes may leave the descriptor slot unaligned. memcpy keeps the
    // walker valid there too instead of making an unaligned void** access UB.
    memcpy(&descriptor, p, sizeof(descriptor));
    if (!descriptor) return NULL;
    memcpy(&shape, descriptor + RT_DESC_SHAPE_OFFSET, sizeof(shape));
    return shape;
}

static void* rt_extended_child(void* p, long long offset) {
    void* child = NULL;
    memcpy(&child, (char*)p + offset, sizeof(child));
    return child;
}

// counts are plain until the first thread spawns (cc_mt flips before
// pthread_create, so no object is ever touched by two threads while the
// flag is 0); after that retain/release use atomic ops. The collector
// keeps plain ops either way — it only runs with zero workers live.
// Below the minimal profile there are no threads at all, so the multi-threaded
// half of every count operation is unreachable — and on a 32-bit target it is
// worse than unreachable. `rc` is eight bytes, ARMv7-M and RV32 have no 8-byte
// atomic instruction, and Clang turns each one into a __atomic_*_8 libcall that
// a freestanding link cannot satisfy. Folding the flag to a constant deletes
// the branch outright.
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
static int cc_mt;
static int cc_is_mt(void) {
    return __atomic_load_n(&cc_mt, __ATOMIC_RELAXED);
}
static void cc_enable_mt(void) {
    __atomic_store_n(&cc_mt, 1, __ATOMIC_RELAXED);
}
#else
static int cc_is_mt(void) { return 0; }
#endif
static long long cc_color(BHead* h) { return h->meta & CC_COLOR; }
static void cc_set_color(BHead* h, long long c) { h->meta = (h->meta & ~CC_COLOR) | c; }
// `meta` is written atomically wherever the color or in-buffer bit moves, because
// two threads can release references to the same object at the same time. Reads on
// that path have to match, or the read is a data race: TSan caught exactly this
// once two worker threads shared one closure environment. Relaxed is enough — the
// bits are advisory, the object is kept alive by the count — and a relaxed load is
// the same instruction as a plain one, so this costs nothing.
//
// Whether these are really atomic is decided in one place, here. Threads exist
// only at minimal and above; below that there is a single mutator and the plain
// operation is already correct. That is not just a saving — on a 32-bit
// embedded target it is the only option, because ARMv7-M and RV32 have no
// 8-byte atomic instruction and Clang turns each of these into a __atomic_*_8
// libcall that a freestanding link cannot satisfy.
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
static long long rt_w_load(long long* p) {
    return __atomic_load_n(p, __ATOMIC_RELAXED);
}
static long long rt_w_fetch_or(long long* p, long long bits) {
    return __atomic_fetch_or(p, bits, __ATOMIC_RELAXED);
}
static void rt_w_and(long long* p, long long mask) {
    __atomic_and_fetch(p, mask, __ATOMIC_RELAXED);
}
// The shared-pointer control block keeps its acquire/release ordering: the last
// release of a strong count has to happen-before the free.
static void rt_ctrl_add(long long* p) {
    __atomic_add_fetch(p, 1, __ATOMIC_RELAXED);
}
static long long rt_ctrl_fetch_sub(long long* p) {
    return __atomic_fetch_sub(p, 1, __ATOMIC_ACQ_REL);
}
static long long rt_ctrl_load(long long* p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}
static int rt_ctrl_cas(long long* p, long long* expected, long long desired) {
    return __atomic_compare_exchange_n(p, expected, desired, 1, __ATOMIC_ACQ_REL,
                                       __ATOMIC_ACQUIRE);
}
#else
static long long rt_w_load(long long* p) { return *p; }
static long long rt_w_fetch_or(long long* p, long long bits) {
    long long old = *p;
    *p = old | bits;
    return old;
}
static void rt_w_and(long long* p, long long mask) { *p &= mask; }
static void rt_ctrl_add(long long* p) { *p += 1; }
static long long rt_ctrl_fetch_sub(long long* p) {
    long long old = *p;
    *p = old - 1;
    return old;
}
static long long rt_ctrl_load(long long* p) { return *p; }
static int rt_ctrl_cas(long long* p, long long* expected, long long desired) {
    if (*p != *expected) {
        *expected = *p;
        return 0;
    }
    *p = desired;
    return 1;
}
#endif

static long long cc_meta(BHead* h) { return rt_w_load(&h->meta); }

// The count word is conditional twice over: on the profile, because threads
// exist only at minimal and above, and there on cc_mt. Routing every count
// operation through these four keeps the 8-byte atomics out of a freestanding
// build at *preprocessing* time rather than trusting the optimizer to fold a
// constant branch — at -O0 an unfolded one is an undefined __atomic_*_8.
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
static long long rt_rc_load(BHead* h) {
    return cc_is_mt() ? __atomic_load_n(&h->rc, __ATOMIC_RELAXED) : h->rc;
}
static void rt_rc_store(BHead* h, long long v) {
    if (cc_is_mt()) __atomic_store_n(&h->rc, v, __ATOMIC_RELAXED);
    else h->rc = v;
}
static void rt_rc_inc(BHead* h) {
    if (cc_is_mt()) __atomic_add_fetch(&h->rc, 1, __ATOMIC_RELAXED);
    else h->rc += 1;
}
static long long rt_rc_dec(BHead* h) {
    return cc_is_mt() ? __atomic_sub_fetch(&h->rc, 1, __ATOMIC_ACQ_REL)
                      : (h->rc -= 1);
}
#else
static long long rt_rc_load(BHead* h) { return h->rc; }
static void rt_rc_store(BHead* h, long long v) { h->rc = v; }
static void rt_rc_inc(BHead* h) { h->rc += 1; }
static long long rt_rc_dec(BHead* h) { return h->rc -= 1; }
#endif

#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
static _Atomic long long cc_threads;  // live worker threads; collect only at 0
#else
// Same reason: nothing can raise it, and reading an 8-byte _Atomic on a 32-bit
// target is a libcall.
static const long long cc_threads = 0;
#endif
static _Atomic int cc_pending;
static int cc_collecting;
static void cc_collect(int force);

// vtable slot of deinit, emitted by codegen (-1 when no class has one).
// Deinit runs inside a release cascade, where allocation used to be
// impossible — beans_in_deinit keeps the collector out of that window,
// because a mid-destroy object must never be walked.
extern long long beans_deinit_sel;
// NOT thread-local: a TLS read compiles to a _tlv_get_addr call. A shared
// flag is exactly as correct — the collector only runs with zero worker
// threads, so "any thread is mid-deinit" is the right gate anyway. Plain
// int + __atomic builtins (an _Atomic type rejects __atomic_add_fetch).
static int beans_in_deinit;

// Profile builds recompile the emitted runtime with -DBEANS_ARC_STATS.
// Normal benchmark binaries do not contain these counters, so measuring
// ownership traffic cannot change the timed result.
#ifdef BEANS_ARC_STATS
static unsigned long long arc_allocations;
static unsigned long long arc_allocated_bytes;
static unsigned long long arc_retain_calls;
static unsigned long long arc_release_calls;
static unsigned long long arc_release_nodes;
static unsigned long long arc_freed_shells;
static unsigned long long arc_possible_roots;
static unsigned long long arc_collections;
static unsigned long long arc_cycle_objects;
#define ARC_ADD(name, value) \
    __atomic_add_fetch(&(name), (unsigned long long)(value), __ATOMIC_RELAXED)
static void arc_report(void) {
#if BEANS_RT_PROFILE < BEANS_RT_MINIMAL
    return; // no stderr to report to, and no atexit to report from
#else
    fprintf(stderr,
            "beans arc stats: allocations=%llu allocated_bytes=%llu "
            "retains=%llu releases=%llu release_nodes=%llu frees=%llu "
            "possible_roots=%llu collections=%llu cycle_objects=%llu\n",
            (unsigned long long)arc_allocations,
            (unsigned long long)arc_allocated_bytes,
            (unsigned long long)arc_retain_calls,
            (unsigned long long)arc_release_calls,
            (unsigned long long)arc_release_nodes,
            (unsigned long long)arc_freed_shells,
            (unsigned long long)arc_possible_roots,
            (unsigned long long)arc_collections,
            (unsigned long long)arc_cycle_objects);
#endif
}
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
__attribute__((constructor)) static void arc_setup(void) { atexit(arc_report); }
#endif
#else
#define ARC_ADD(name, value) ((void)0)
#endif

// deinit, before the children go — outlined and cold: the indirect call must
// stay out of beans_release's hot loop or the optimizer treats every
// iteration as clobbered (that cost 50% on the churn bench). Count up to 1
// and FIN off first: user code in there may retain and release self without
// re-entering death, and death can't run twice (husk and collector paths see
// FIN already gone). Count back to 0 after: the husk filter frees a parked
// shell only when RC_COUNT is 0, so the bump must not outlive the call (it
// leaked a buffered object's shell once).
BEANS_DEINIT_ATTR static void beans_do_deinit(
    void* p, BHead* h, long long nrc) {
    rt_rc_store(h, (nrc + 1) & ~RC_FIN);
    // The method array follows the i64 id and optional-shape pointer. See
    // RT_DESC_METHODS_OFFSET and compiler/bootstrap/object_abi.h.
    char* descriptor = *(char**)p;
    void (**methods)(void*) =
        (void (**)(void*))(descriptor + RT_DESC_METHODS_OFFSET);
    __atomic_add_fetch(&beans_in_deinit, 1, __ATOMIC_RELAXED);
    methods[beans_deinit_sel](p);
    __atomic_sub_fetch(&beans_in_deinit, 1, __ATOMIC_RELAXED);
    rt_rc_store(h, nrc & ~RC_FIN);
}

// segregated per-thread freelists over 64KB slabs: one calloc per slab,
// then carve; a free pushes the block on the freeing thread's list. Slabs
// are registered globally so the leaks tool sees every allocation as
// reachable; blocks stranded on a dead worker's freelist sit inside a
// registered slab (wasted until exit, never a leak). BEANS_NO_POOL=1
// routes everything through plain calloc/free so `leaks` can see
// individual beans objects again when hunting a real leak.
#define POOL_CLASSES 64 // pooled sizes 16..1008 bytes; bigger goes to malloc
#define POOL_SLAB (64 << 10)
// Per-thread in the hosted profiles; plain statics in freestanding, which has one
// thread by construction — thread-local storage is a platform service and there is
// nothing for it to separate.
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
#define POOL_LOCAL _Thread_local
#else
#define POOL_LOCAL
#endif
static POOL_LOCAL void* pool_free[POOL_CLASSES];
static POOL_LOCAL char* pool_cur;
static POOL_LOCAL char* pool_end;
static void** pool_slabs;
static long long pool_slab_len, pool_slab_cap;
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
static pthread_mutex_t pool_mu = PTHREAD_MUTEX_INITIALIZER;
#define POOL_LOCK() pthread_mutex_lock(&pool_mu)
#define POOL_UNLOCK() pthread_mutex_unlock(&pool_mu)
#else
// One thread, so the slab registry needs no lock.
#define POOL_LOCK() ((void)0)
#define POOL_UNLOCK() ((void)0)
#endif
static int pool_off;
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
__attribute__((constructor)) static void pool_setup(void) {
    pool_off = getenv("BEANS_NO_POOL") != NULL;
}
#endif

void beans_panic(const char* msg, long long line, long long col);
void* beans_alloc(long long size, long long meta) {
    ARC_ADD(arc_allocations, 1);
    ARC_ADD(arc_allocated_bytes, size);
    // allocation is the one safe point: never inside a release cascade,
    // and every stored reference is already counted (a deinit body is the
    // exception — cc_collect itself bails while one runs, so this exact
    // condition stays byte-identical to keep clang's fast-path layout)
    if (cc_pending && !cc_collecting && cc_threads == 0) cc_collect(0);
    size_t total = (16 + (size_t)size + 15) & ~(size_t)15;
    long long cls = (long long)(total >> 4);
    BHead* h;
    if (cls < POOL_CLASSES && !pool_off) {
        if (pool_free[cls]) {
            h = pool_free[cls];
            pool_free[cls] = *(void**)h;
            memset(h, 0, total); // recycled block; callers expect zeroed slots
        } else {
            if (!pool_cur || pool_cur + total > pool_end) {
                pool_cur = rt_zalloc(POOL_SLAB);
                if (!pool_cur) beans_panic("out of memory", 0, 0);
                pool_end = pool_cur + POOL_SLAB;
                POOL_LOCK();
                if (pool_slab_len == pool_slab_cap) {
                    pool_slab_cap = pool_slab_cap ? pool_slab_cap * 2 : 64;
                    pool_slabs = rt_realloc(pool_slabs,
                                         (size_t)pool_slab_cap * sizeof(void*));
                }
                pool_slabs[pool_slab_len++] = pool_cur;
                POOL_UNLOCK();
            }
            h = (BHead*)pool_cur; // virgin slab memory, already zero
            pool_cur += total;
        }
        h->rc = 1 | (cls << RC_CLS_SHIFT);
    } else {
        h = rt_zalloc(total);
        if (!h) beans_panic("out of memory", 0, 0);
        h->rc = 1;
    }
    h->meta = meta;
    return (char*)h + 16;
}

void beans_retain(void* p) {
    if (!p) return;
    ARC_ADD(arc_retain_calls, 1);
    BHead* h = head_of(p);
    if (rt_rc_load(h) >= BEANS_IMMORTAL) return;
    rt_rc_inc(h);
}

void beans_release(void* p);

typedef struct {
    long long* data;
    RT_LEN8 long long len, cap;
    // Generic lists keep the original data/len/cap prefix because generated
    // code reads those hot fields directly. Wide inline elements use stride
    // bytes and ptr_mask marks owned ARC pointers inside each element.
    // A negative stride marks the generic i64-slot representation. Its
    // magnitude is the byte stride. Typed inline values always use a positive
    // stride, so their pointer masks describe their real in-memory fields.
    long long stride, ptr_mask;
} BList;
typedef struct {
    long long* data;
    RT_LEN8 long long len, cap;
    long long stride, ptr_mask, cycle_mask;
} BArena;
typedef struct {
    long long* data; // key,value interleaved — len stays at
    RT_LEN8 long long len, cap; // offset 8: map.len() is a direct field load in IR
    // open-addressed index over data: (hash hi32 << 32) | (pos+2), 0 empty,
    // 1 tombstone. NULL until the map outgrows a linear scan.
    unsigned long long* idx;
    long long icap, tombs;
    // OrderedMap removal leaves stable holes. Plain Map swap-removes and keeps
    // used == len. deadbits NULL means there are no holes.
    long long used;
    unsigned long long* deadbits;
    long long ordered;
    // Wide values live in a parallel flat buffer. Keeping data interleaved for
    // the common one-slot case preserves its hot lookup/update layout.
    void* wide_values;
    long long value_stride;
    long long value_ptr_mask;
    long long value_cycle_mask;
} BMap;
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t can_send, can_recv;
    long long* q;
    long long head, count, cap;
    int closed;
    long long stride, ptr_mask;
} BChan;
typedef struct {
    pthread_mutex_t m;
    long long inner;
} BMutex;
#endif // BEANS_RT_PROFILE >= BEANS_RT_MINIMAL

// one shape-walker for destruction and all collector phases
static void cc_walk(void* p, long long meta, void (*fn)(void*, void*), void* ctx) {
    long long kind = meta & 7;
    long long extra = (meta & CC_SHAPE) >> 3;
    if (kind == 1 && extra == RT_EXTENDED_MASK) {
        BExtendedShape* shape = rt_extended_shape(p);
        if (!shape) return;
        for (long long i = 0; i < shape->count; ++i) {
            void* child = rt_extended_child(p, shape->offsets[i]);
            if (child) fn(child, ctx);
        }
    } else if (kind == 1) { // fixed: marked pointer-width slots
        for (int i = 0; i < RT_MASK_SLOTS && (extra >> i); i++) {
            if ((extra >> i) & 1) {
                void* c = *(void**)RT_SLOT_AT(p, i);
                if (c) fn(c, ctx);
            }
        }
    } else if (kind == 2) {
        BList* l = p;
        if (extra & 1) {
            int i64_encoded = l->stride < 0;
            long long stride = i64_encoded ? -l->stride
                                           : (l->stride ? l->stride : 8);
            for (long long i = 0; i < l->len; i++) {
                char* element = (char*)l->data + i * stride;
                for (int slot = 0; slot < RT_MASK_SLOTS && (l->ptr_mask >> slot); slot++) {
                    if (!((l->ptr_mask >> slot) & 1)) continue;
                    void* child = rt_masked_child(element, slot, i64_encoded);
                    if (child) fn(child, ctx);
                }
            }
        }
    } else if (kind == 3) {
        BMap* m = p;
        for (long long i = 0; i < m->used; i++) { // holes are zeroed: null-skip
            if ((extra & 1) && m->data[i * 2]) fn((void*)m->data[i * 2], ctx);
            if (!(extra & 2)) continue;
            if (!m->wide_values) {
                if (m->data[i * 2 + 1]) fn((void*)m->data[i * 2 + 1], ctx);
                continue;
            }
            char* value = (char*)m->wide_values + i * m->value_stride;
            for (int slot = 0; slot < RT_MASK_SLOTS && (m->value_ptr_mask >> slot); slot++) {
                if (!((m->value_ptr_mask >> slot) & 1)) continue;
                void* child = *(void**)RT_SLOT_AT(value, slot);
                if (child) fn(child, ctx);
            }
        }
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
    } else if (kind == 4) {
        BChan* c = p;
        if (extra & 1) {
            int i64_encoded = c->stride < 0;
            long long stride = i64_encoded ? -c->stride : c->stride;
            for (long long i = 0; i < c->count; i++) {
                char* value = (char*)c->q +
                              ((c->head + i) % c->cap) * stride;
                for (int slot = 0; slot < RT_MASK_SLOTS && (c->ptr_mask >> slot); slot++) {
                    if (!((c->ptr_mask >> slot) & 1)) continue;
                    void* child = rt_masked_child(value, slot, i64_encoded);
                    if (child) fn(child, ctx);
                }
            }
        }
    } else if (kind == 5) {
        BMutex* mu = p;
        if ((extra & 1) && mu->inner) fn((void*)mu->inner, ctx);
#endif
    } else if (kind == 7) {
        BArena* arena = p;
        if (extra & 1) {
            int i64_encoded = arena->stride < 0;
            long long stride = i64_encoded ? -arena->stride
                                           : (arena->stride ? arena->stride : 8);
            for (long long i = 0; i < arena->len; i++) {
                char* value = (char*)arena->data + i * stride;
                for (int slot = 0; slot < RT_MASK_SLOTS && (arena->ptr_mask >> slot); slot++) {
                    if (!((arena->ptr_mask >> slot) & 1)) continue;
                    void* child = rt_masked_child(value, slot, i64_encoded);
                    if (child) fn(child, ctx);
                }
            }
        }
    }
}

typedef struct {
    long long fd;
    long long closed;
} BFile;
typedef struct {
    char* p;
    long long len;
    long long fd;
    long long writable;
    long long closed;
} BMMap;

typedef struct {
    long long strong;
    long long weak;
    long long value;
    long long value_ptr;
} BSharedCtrl;
typedef struct { BSharedCtrl* ctrl; } BSharedHandle;

// kind 6, extra 2 = strong handle, extra 3 = weak handle. The control block
// owns exactly one payload reference while any strong handle exists. Return
// that child when the final strong shell dies so beans_release can keep its
// existing iterative cascade.
static void* shared_shell_drop(void* p, long long extra) {
    BSharedCtrl* ctrl = ((BSharedHandle*)p)->ctrl;
    if (extra & 1) {
        if (rt_ctrl_fetch_sub(&ctrl->weak) == 1) rt_free(ctrl);
        return NULL;
    }
    void* child = NULL;
    if (rt_ctrl_fetch_sub(&ctrl->strong) == 1) {
        if (ctrl->value_ptr) child = (void*)ctrl->value;
        ctrl->value = 0;
        if (rt_ctrl_fetch_sub(&ctrl->weak) == 1) rt_free(ctrl);
    }
    return child;
}

// free the box and its side allocations WITHOUT touching child refs
static void* cc_free_shell(void* p, long long meta) {
    ARC_ADD(arc_freed_shells, 1);
    long long kind = meta & 7;
    long long extra = (meta & CC_SHAPE) >> 3;
    void* deferred_child = NULL;
    if (kind == 2) rt_free(((BList*)p)->data);
    else if (kind == 7) rt_free(((BArena*)p)->data);
    else if (kind == 3) {
        rt_free(((BMap*)p)->data);
        rt_free(((BMap*)p)->wide_values);
        rt_free(((BMap*)p)->idx);
        rt_free(((BMap*)p)->deadbits);
    } else if (kind == 4) {
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
        BChan* c = p;
        pthread_cond_destroy(&c->can_send);
        pthread_cond_destroy(&c->can_recv);
        pthread_mutex_destroy(&c->m);
        rt_free(c->q);
#endif
    } else if (kind == 5) {
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
        pthread_mutex_destroy(&((BMutex*)p)->m);
#endif
    } else if (kind == 6 && (extra & 2)) {
        deferred_child = shared_shell_drop(p, extra);
    } else if (kind == 6) { // OS resource — dropping the last ref is the safety
#if BEANS_RT_PROFILE >= BEANS_RT_FULL || BEANS_RT_WASI
        // close whatever is still open at the OS level, whether the handle was
        // never closed or its close was deferred while threads ran (fd/p left
        // valid, the logical `closed` flag already set). The last ref is gone,
        // so no thread can be mid-op here — releasing now is safe.
        if ((meta & CC_SHAPE) >> 3 & 1) { // shape bit 0: 0 = file, 1 = mmap
#if BEANS_RT_PROFILE >= BEANS_RT_FULL
            BMMap* m = p;
#if defined(_WIN32)
            {
                // windows.h enters this file only with the fs section far
                // below (see the fs shim); one hand prototype here beats
                // hoisting the SDK above the allocator. x64 has a single
                // calling convention, so the plain declaration matches.
                extern int UnmapViewOfFile(const void* address);
                if (m->p) UnmapViewOfFile(m->p);
            }
#else
            if (m->p) munmap(m->p, (size_t)m->len);
#endif
            if (m->fd >= 0) close((int)m->fd);
#endif
        } else {
            BFile* f = p; // net; close() / f.close() is the real API
            if (f->fd >= 0) {
#if BEANS_RT_PROFILE >= BEANS_RT_FULL
                beans_reactor_note_close(f->fd);
#endif
                close((int)f->fd);
            }
        }
#endif
    }
    BHead* h = head_of(p);
    long long cls = (h->rc >> RC_CLS_SHIFT) & RC_CLS_MAX;
    if (cls) {
        *(void**)h = pool_free[cls];
        pool_free[cls] = h;
    } else {
        rt_free(h);
    }
    return deferred_child;
}

// explicit work stack, shared by release cascades and all collector phases
typedef struct {
    void** v;
    long long len, cap;
    void** local;
} CCStack;
static void cc_push(CCStack* s, void* p) {
    if (s->len == s->cap) {
        long long next = s->cap ? s->cap * 2 : 4096;
        void** grown = rt_alloc((size_t)next * sizeof(void*));
        if (s->len) memcpy(grown, s->v, (size_t)s->len * sizeof(void*));
        if (s->v != s->local) rt_free(s->v);
        s->v = grown;
        s->cap = next;
    }
    s->v[s->len++] = p;
}
static void cc_visit_push(void* c, void* ctx) {
    BHead* h = head_of(c);
    long long rc = rt_rc_load(h);
    if (rc >= BEANS_IMMORTAL) return;
    cc_push(ctx, c);
}

// Release cascades overwhelmingly walk fixed class objects. Keep this path
// direct: the collector still uses the generic callback walker, but ordinary
// ARC death should not pay an indirect call for every child.
static inline void cc_release_children(void* p, long long meta, CCStack* st) {
    long long kind = meta & 7;
    long long extra = (meta & CC_SHAPE) >> 3;
    if (kind != 1) {
        cc_walk(p, meta, cc_visit_push, st);
        return;
    }
    if (extra == RT_EXTENDED_MASK) {
        BExtendedShape* shape = rt_extended_shape(p);
        if (!shape) return;
        for (long long i = 0; i < shape->count; ++i) {
            void* child = rt_extended_child(p, shape->offsets[i]);
            if (!child) continue;
            BHead* h = head_of(child);
            if (rt_rc_load(h) < BEANS_IMMORTAL) cc_push(st, child);
        }
        return;
    }
    for (int i = 0; i < RT_MASK_SLOTS && (extra >> i); i++) {
        if (!((extra >> i) & 1)) continue;
        void* child = *(void**)RT_SLOT_AT(p, i);
        if (!child) continue;
        BHead* h = head_of(child);
        if (rt_rc_load(h) < BEANS_IMMORTAL) cc_push(st, child);
    }
}

// ---- possible-root buffer ----
static void** cc_roots;
static long long cc_len, cc_cap;
static long long cc_threshold = 256;
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
static pthread_mutex_t cc_mu = PTHREAD_MUTEX_INITIALIZER;
#define CC_LOCK() do { if (cc_is_mt()) pthread_mutex_lock(&cc_mu); } while (0)
#define CC_UNLOCK() do { if (cc_is_mt()) pthread_mutex_unlock(&cc_mu); } while (0)
#else
// One thread by construction, so cc_is_mt() can never become true and the lock
// would be dead weight — and a referenced pthread symbol in a profile that has no
// pthreads.
#define CC_LOCK() ((void)0)
#define CC_UNLOCK() ((void)0)
#endif

static void cc_possible_root(void* p) {
    BHead* h = head_of(p);
    long long old = rt_w_fetch_or(&h->meta, CC_PURPLE | CC_BUF);
    if (old & CC_BUF) return; // already parked
    ARC_ADD(arc_possible_roots, 1);
    // like the counts, the buffer goes unlocked until the first spawn: one
    // thread exists, and after cc_mt flips every park takes the mutex
    CC_LOCK();
    if (cc_len == cc_cap) {
        cc_cap = cc_cap ? cc_cap * 2 : 1024;
        cc_roots = rt_realloc(cc_roots, (size_t)cc_cap * sizeof(void*));
    }
    cc_roots[cc_len++] = p;
    if (cc_len >= cc_threshold) cc_pending = 1;
    CC_UNLOCK();
}

// iterative: a dropped million-node chain pushes children on an explicit
// stack instead of recursing the C stack. The stack stays empty (no malloc)
// unless a death actually cascades.
void beans_release(void* p) {
    if (!p) return;
    ARC_ADD(arc_release_calls, 1);
    void* local[64];
    CCStack st = {local, 0, 64, local};
    void* cur = p;
    for (;;) {
        ARC_ADD(arc_release_nodes, 1);
        BHead* h = head_of(cur);
        long long rc0 = rt_rc_load(h);
        if (rc0 < BEANS_IMMORTAL) {
            // Once this thread decrements its reference, another thread may
            // perform the final decrement and free the shell. Anything needed
            // for the non-zero path must therefore be read, and a possible
            // cycle root parked, while this thread still owns its reference.
            //
            // A count of one is also safe: this thread owns the only reference,
            // so the decrement and immediate free cannot race. With multiple
            // references, parking first may briefly keep an acyclic shell, but
            // it makes the object stay alive until the collector removes it.
            long long meta_before = cc_meta(h);
            long long kind_before = meta_before & 7;
            int cyclic =
                (kind_before == 1 &&
                 ((meta_before & CC_SHAPE) >> 3) != 0) ||
                (kind_before == 3 && (meta_before & (3LL << 3))) ||
                ((kind_before == 2 || kind_before == 4 ||
                 kind_before == 5 || kind_before == 7) &&
                 (meta_before & (1LL << 3)));
            int mt = cc_is_mt();
            if (mt && cyclic && RC_COUNT(rc0) > 1) cc_possible_root(cur);
            long long nrc = rt_rc_dec(h);
            if (RC_COUNT(nrc) == 0) {
                long long meta = cc_meta(h);
                // FIN is only ever set on class objects, so it alone decides
                // `!= 0` is load-bearing, not style. __builtin_expect takes
                // `long`, which is 32 bits on a 32-bit target, so passing the
                // raw `nrc & RC_FIN` truncated bit 61 away and made this branch
                // dead: every deinit was silently skipped on RV32 and thumb.
                // Comparing first hands it a 0 or a 1, which no width can lose.
                if (__builtin_expect((nrc & RC_FIN) != 0, 0)) {
                    beans_do_deinit(cur, h, nrc);
                    meta = cc_meta(h); // colors can move while user code runs
                }
                cc_release_children(cur, meta, &st);
                if (meta & CC_BUF) {
                    // parked — the buffer still points here, so the collector
                    // frees the shell later; mark black: this is a dead husk
                    rt_w_and(&h->meta, ~CC_COLOR);
                } else {
                    void* child = cc_free_shell(cur, meta);
                    if (child) cc_push(&st, child);
                }
            } else {
                // could this shape sit on a cycle? leaves, pointer-free
                // containers, and objects with an empty pointer mask never can
                // — a cycle member needs an outgoing edge — which keeps
                // int-field churn off the buffer
                if (!mt && cyclic) cc_possible_root(cur);
            }
        }
        if (!st.len) break;
        cur = st.v[--st.len];
    }
    if (st.v != local) rt_free(st.v);
}

// Checked Beans treats Box/Arena handles as move-only. Wide values keep their
// real byte layout; pointer masks let the common collector walk their nested
// ARC fields without a type-specific destructor.
static void release_masked_value(void* value, long long ptr_mask) {
    for (int slot = 58; slot-- > 0;) {
        if (!((ptr_mask >> slot) & 1)) continue;
        void* child = *(void**)RT_SLOT_AT(value, slot);
        if (child) beans_release(child);
    }
}
// malloc and calloc only promise enough alignment for any ordinary scalar —
// 16 bytes on both supported targets. An `align(64)` record asked for more than
// that, so anything stricter has to be requested explicitly or align_of would be
// promising an alignment the allocation does not have.
#define BEANS_MALLOC_ALIGN 16
void* beans_raw_alloc(long long count, long long size, long long align,
                      long long min_align, long long line, long long col) {
    if (count < 0) beans_panic("negative raw allocation count", line, col);
    if (size <= 0 || count > (1LL << 58) / size)
        beans_panic("raw allocation too large", line, col);
    if (align <= 0 || (align & (align - 1)) != 0)
        beans_panic("raw allocation alignment must be a power of two", line, col);
    // Upgrading silently would hide the caller's mistake and hand back memory the
    // element type cannot legally live in.
    if (align < min_align)
        beans_panic("raw allocation alignment is below the element's own alignment",
                    line, col);
    size_t bytes = (size_t)count * (size_t)size;
#if defined(_WIN32)
    // MSVCRT gives neither posix_memalign nor an aligned block that plain
    // free() accepts, so on Windows every raw block — whatever its alignment —
    // uses one wrapped representation: the calloc base rides in the pointer
    // slot just below the aligned payload, and beans_raw_free unwraps it.
    // Wrapping the small-alignment case too is the point: raw_free sees only
    // the pointer, so there must be exactly one representation to undo.
    size_t payload_align =
        (size_t)(align > BEANS_MALLOC_ALIGN ? align : BEANS_MALLOC_ALIGN);
    char* base = rt_zalloc(bytes + payload_align + sizeof(void*));
    if (!base) {
        if (count) beans_panic("out of memory", line, col);
        return NULL;
    }
    uintptr_t payload =
        ((uintptr_t)base + sizeof(void*) + payload_align - 1) &
        ~((uintptr_t)payload_align - 1);
    ((void**)payload)[-1] = base;
    return (void*)payload;
#else
    if (align <= BEANS_MALLOC_ALIGN || bytes == 0) {
        void* p = rt_zalloc((unsigned long long)((size_t)count) * (size_t)size);
        if (!p && count) beans_panic("out of memory", line, col);
        return p;
    }
    // posix_memalign rather than C11 aligned_alloc: it is present on both
    // supported platforms without a feature dance, it does not require the size
    // to be a multiple of the alignment, and its result is still plain rt_free()-able
    // so beans_raw_free stays one function.
    // beans_host_alloc takes the alignment and promises zeroed memory, so both
    // profiles reach the same contract: hosted uses posix_memalign inside the weak
    // default, freestanding uses whatever the program supplied.
    void* p = beans_host_alloc((unsigned long long)bytes, (unsigned long long)align);
    if (!p) beans_panic("out of memory", line, col);
    return p;
#endif
}
#if defined(_WIN32)
void beans_raw_free(void* p) {
    if (p) rt_free(((void**)p)[-1]);
}
#else
void beans_raw_free(void* p) { rt_free(p); }
#endif
void beans_raw_copy(void* destination, void* source, long long count, long long size,
                    long long line, long long col) {
    if (count < 0) beans_panic("negative raw copy count", line, col);
    if (size <= 0 || count > (1LL << 58) / size)
        beans_panic("raw copy too large", line, col);
    if (count && (!destination || !source))
        beans_panic("null raw pointer copy", line, col);
    memmove(destination, source, (size_t)count * (size_t)size);
}
void beans_raw_zero(void* destination, long long count, long long size,
                    long long line, long long col) {
    if (count < 0) beans_panic("negative raw zero count", line, col);
    if (size <= 0 || count > (1LL << 58) / size)
        beans_panic("raw zero too large", line, col);
    if (count && !destination) beans_panic("null raw pointer zero", line, col);
    memset(destination, 0, (size_t)count * (size_t)size);
}

void* beans_box_new(long long value, long long value_ptr) {
    long long mask = value_ptr ? RT_I64_SLOT_MASK_AT(0) : 0;
    long long* box = beans_alloc(8, 1 | (mask << 3));
    box[0] = value;
    return box;
}
long long beans_box_get(void* p) { return ((long long*)p)[0]; }
void beans_box_set(void* p, long long value) {
    long long* box = p;
    if (((head_of(p)->meta & CC_SHAPE) >> 3) & 1) {
        void* old = (void*)box[0];
        if (old) beans_release(old);
    }
    box[0] = value;
}
void* beans_box_new_typed(void* value, long long size, long long ptr_mask,
                          long long cycle_mask) {
    if (size <= 0 || size > (1LL << 30))
        beans_panic("invalid box value size", 0, 0);
    void* box = beans_alloc(size, 1 | (ptr_mask << 3));
    memcpy(box, value, (size_t)size);
    if (cycle_mask) cc_possible_root(box);
    return box;
}
void beans_box_get_typed(void* box, void* out, long long size) {
    memcpy(out, box, (size_t)size);
}
void beans_box_set_typed(void* box, void* value, long long size,
                         long long ptr_mask, long long cycle_mask) {
    release_masked_value(box, ptr_mask);
    memcpy(box, value, (size_t)size);
    if (cycle_mask) cc_possible_root(box);
}

void* beans_shared_new(long long value, long long value_ptr) {
    BSharedCtrl* ctrl = rt_zalloc(sizeof(BSharedCtrl));
    if (!ctrl) beans_panic("out of memory", 0, 0);
    ctrl->strong = 1;
    ctrl->weak = 1; // implicit weak held until strong reaches zero
    ctrl->value = value;
    ctrl->value_ptr = value_ptr;
    BSharedHandle* handle = beans_alloc(sizeof(BSharedHandle), 6 | (2LL << 3));
    handle->ctrl = ctrl;
    return handle;
}
long long beans_shared_get(void* p) {
    return ((BSharedHandle*)p)->ctrl->value;
}
void* beans_shared_new_typed(void* value, long long size, long long ptr_mask) {
    if (size <= 0 || size > (1LL << 30))
        beans_panic("invalid shared value size", 0, 0);
    void* payload = beans_alloc(size, 1 | (ptr_mask << 3));
    memcpy(payload, value, (size_t)size);
    return beans_shared_new((long long)payload, 1);
}
void beans_shared_get_typed(void* p, void* out, long long size) {
    void* payload = (void*)((BSharedHandle*)p)->ctrl->value;
    memcpy(out, payload, (size_t)size);
}
void* beans_shared_downgrade(void* p) {
    BSharedCtrl* ctrl = ((BSharedHandle*)p)->ctrl;
    rt_ctrl_add(&ctrl->weak);
    BSharedHandle* weak = beans_alloc(sizeof(BSharedHandle), 6 | (3LL << 3));
    weak->ctrl = ctrl;
    return weak;
}
void* beans_weak_upgrade(void* p) {
    BSharedCtrl* ctrl = ((BSharedHandle*)p)->ctrl;
    long long strong = rt_ctrl_load(&ctrl->strong);
    while (strong > 0) {
        if (rt_ctrl_cas(&ctrl->strong, &strong, strong + 1)) {
            BSharedHandle* handle =
                beans_alloc(sizeof(BSharedHandle), 6 | (2LL << 3));
            handle->ctrl = ctrl;
            return handle;
        }
    }
    return NULL;
}
long long beans_weak_expired(void* p) {
    BSharedCtrl* ctrl = ((BSharedHandle*)p)->ctrl;
    return rt_ctrl_load(&ctrl->strong) == 0;
}

void* beans_arena_new(long long capacity, long long elem_ptr,
                      long long line, long long col) {
    if (capacity < 0) {
        char msg[96];
        rt_format(msg, sizeof msg, "negative arena capacity %lld", capacity);
        beans_panic(msg, line, col);
    }
    if (capacity > (1LL << 58)) beans_panic("arena capacity too large", line, col);
    BArena* arena = beans_alloc(sizeof(BArena), 7 | (elem_ptr << 3));
    arena->stride = -8; // generic i64 slot; see the object-ABI walker
    arena->ptr_mask = elem_ptr;
    if (capacity) {
        arena->data = rt_zalloc((unsigned long long)((size_t)capacity) * (sizeof(long long)));
        if (!arena->data) beans_panic("out of memory", line, col);
    }
    arena->cap = capacity;
    return arena;
}
void* beans_arena_new_typed(long long capacity, long long stride,
                            long long ptr_mask, long long cycle_mask,
                            long long line, long long col) {
    if (capacity < 0) {
        char msg[96];
        rt_format(msg, sizeof msg, "negative arena capacity %lld", capacity);
        beans_panic(msg, line, col);
    }
    if (stride <= 0 || stride > (1LL << 30))
        beans_panic("invalid arena element size", line, col);
    if (capacity > (1LL << 58) / stride)
        beans_panic("arena capacity too large", line, col);
    BArena* arena = beans_alloc(sizeof(BArena), 7 | ((ptr_mask != 0) << 3));
    arena->stride = stride;
    arena->ptr_mask = ptr_mask;
    arena->cycle_mask = cycle_mask;
    if (capacity) {
        arena->data = rt_zalloc((unsigned long long)((size_t)capacity) * (size_t)stride);
        if (!arena->data) beans_panic("out of memory", line, col);
    }
    arena->cap = capacity;
    return arena;
}
long long beans_arena_put(void* p, long long value) {
    BArena* arena = p;
    if (arena->len == arena->cap) {
        long long next = arena->cap ? arena->cap * 2 : 8;
        long long* data = rt_realloc(arena->data, (size_t)next * sizeof(long long));
        if (!data) beans_panic("out of memory", 0, 0);
        arena->data = data;
        arena->cap = next;
    }
    long long handle = arena->len++;
    arena->data[handle] = value;
    return handle;
}
long long beans_arena_put_typed(void* p, void* value) {
    BArena* arena = p;
    if (arena->len == arena->cap) {
        long long next = arena->cap ? arena->cap * 2 : 8;
        if (next > (1LL << 58) / arena->stride)
            beans_panic("arena capacity too large", 0, 0);
        void* data = rt_realloc(arena->data, (size_t)next * (size_t)arena->stride);
        if (!data) beans_panic("out of memory", 0, 0);
        arena->data = data;
        arena->cap = next;
    }
    long long handle = arena->len++;
    memcpy((char*)arena->data + handle * arena->stride, value,
           (size_t)arena->stride);
    if (arena->cycle_mask) cc_possible_root(arena);
    return handle;
}
long long beans_arena_get(void* p, long long handle, long long* ok) {
    BArena* arena = p;
    if (handle < 0 || handle >= arena->len) {
        *ok = 0;
        return 0;
    }
    *ok = 1;
    return arena->data[handle];
}
long long beans_arena_get_typed(void* p, long long handle, void* out) {
    BArena* arena = p;
    if (handle < 0 || handle >= arena->len) return 0;
    memcpy(out, (char*)arena->data + handle * arena->stride,
           (size_t)arena->stride);
    return 1;
}
long long beans_arena_at(void* p, long long handle, long long line, long long col) {
    BArena* arena = p;
    if (handle < 0 || handle >= arena->len) {
        char msg[112];
        rt_format(msg, sizeof msg, "arena handle %lld out of range (len %lld)",
                 handle, arena->len);
        beans_panic(msg, line, col);
    }
    return arena->data[handle];
}
void beans_arena_at_typed(void* p, long long handle, void* out,
                          long long line, long long col) {
    BArena* arena = p;
    if (handle < 0 || handle >= arena->len) {
        char msg[112];
        rt_format(msg, sizeof msg, "arena handle %lld out of range (len %lld)",
                 handle, arena->len);
        beans_panic(msg, line, col);
    }
    memcpy(out, (char*)arena->data + handle * arena->stride,
           (size_t)arena->stride);
}
long long beans_arena_len(void* p) { return ((BArena*)p)->len; }
void beans_arena_clear(void* p) {
    BArena* arena = p;
    if (arena->ptr_mask) {
        int i64_encoded = arena->stride < 0;
        long long stride = i64_encoded ? -arena->stride
                                       : (arena->stride ? arena->stride : 8);
        for (long long i = arena->len; i-- > 0;) {
            char* value = (char*)arena->data + i * stride;
            if (i64_encoded) {
                void* child = rt_i64_slot_child(value);
                if (child) beans_release(child);
            } else {
                release_masked_value(value, arena->ptr_mask);
            }
        }
    }
    arena->len = 0;
}

// ---- the collector (single mutator: us) ----

static void cc_visit_dec_push(void* c, void* ctx) {
    BHead* h = head_of(c);
    if (h->rc >= BEANS_IMMORTAL) return;
    h->rc -= 1; // trial deletion: one decrement per internal edge
    cc_push(ctx, c);
}
static void cc_mark_gray(void* root, CCStack* st) {
    cc_push(st, root);
    while (st->len) {
        void* p = st->v[--st->len];
        BHead* h = head_of(p);
        if (cc_color(h) == CC_GRAY) continue;
        cc_set_color(h, CC_GRAY);
        cc_walk(p, h->meta, cc_visit_dec_push, st);
    }
}

static void cc_visit_inc_push(void* c, void* ctx) {
    BHead* h = head_of(c);
    if (h->rc >= BEANS_IMMORTAL) return;
    h->rc += 1; // undo the trial deletion along this edge
    if (cc_color(h) != CC_BLACK) {
        cc_set_color(h, CC_BLACK);
        cc_push(ctx, c);
    }
}
static void cc_scan_black(void* root, CCStack* st) {
    cc_set_color(head_of(root), CC_BLACK);
    cc_push(st, root);
    while (st->len) {
        void* p = st->v[--st->len];
        cc_walk(p, head_of(p)->meta, cc_visit_inc_push, st);
    }
}

static void cc_scan(void* root, CCStack* st, CCStack* aux) {
    cc_push(st, root);
    while (st->len) {
        void* p = st->v[--st->len];
        BHead* h = head_of(p);
        if (cc_color(h) != CC_GRAY) continue;
        if (RC_COUNT(h->rc) > 0) {
            cc_scan_black(p, aux); // externally referenced — restore it all
        } else {
            cc_set_color(h, CC_WHITE);
            cc_walk(p, h->meta, cc_visit_push, st);
        }
    }
}

static void cc_collect_white(void* root, CCStack* st, CCStack* dead) {
    cc_push(st, root);
    while (st->len) {
        void* p = st->v[--st->len];
        BHead* h = head_of(p);
        if (cc_color(h) != CC_WHITE || (h->meta & CC_BUF)) continue;
        cc_set_color(h, CC_BLACK); // visited; prevents duplicate frees
        cc_walk(p, h->meta, cc_visit_push, st);
        cc_push(dead, p);
    }
}

static long long cc_walk_min = 256; // adaptive gate for trial deletion

static void cc_collect(int force) {
    if (cc_collecting) return;
    // a deinit body is user code running mid-cascade: its allocations must
    // not start a collection — a mid-destroy object must never be walked.
    // cc_pending stays set, so the next allocation after the cascade retries.
    if (__atomic_load_n(&beans_in_deinit, __ATOMIC_RELAXED)) return;
    ARC_ADD(arc_collections, 1);
    cc_collecting = 1;
    CC_LOCK();

    // keep only live purple candidates; zombies (released while parked)
    // just need their shells freed, everything else drops out
    long long n = 0;
    for (long long i = 0; i < cc_len; i++) {
        void* p = cc_roots[i];
        BHead* h = head_of(p);
        if (cc_color(h) == CC_PURPLE && RC_COUNT(h->rc) > 0) {
            cc_roots[n++] = p;
        } else {
            rt_w_and(&h->meta, ~CC_BUF);
            if (RC_COUNT(h->rc) == 0) {
                void* child = cc_free_shell(p, h->meta);
                if (child) beans_release(child);
            }
        }
    }
    cc_len = n;

    // The filter above is the cheap half and just ran: husk shells free at
    // a steady cadence, so they can never pile past survivors + 256. Trial
    // deletion is the expensive half — it walks everything reachable from
    // the survivors — so it only runs once enough purple candidates pile
    // up, and it backs off hard when a walk frees nothing: a live tree
    // that gets borrow-pinned on every visit must not be re-walked every
    // few hundred allocations (that made binary-trees 10x slower than Go).
    if (cc_len && (force || cc_len >= cc_walk_min)) {
        CCStack st = {0, 0, 0}, aux = {0, 0, 0}, dead = {0, 0, 0};
        for (long long i = 0; i < cc_len; i++) cc_mark_gray(cc_roots[i], &st);
        for (long long i = 0; i < cc_len; i++) cc_scan(cc_roots[i], &st, &aux);
        for (long long i = 0; i < cc_len; i++) {
            BHead* h = head_of(cc_roots[i]);
            rt_w_and(&h->meta, ~CC_BUF);
            cc_collect_white(cc_roots[i], &st, &dead);
        }
        cc_len = 0;
        ARC_ADD(arc_cycle_objects, dead.len);
        // nothing was freed while walking, so no stale pointer was ever
        // read; now the whole white set goes at once
        for (long long i = 0; i < dead.len; i++) {
            void* child = cc_free_shell(dead.v[i], head_of(dead.v[i])->meta);
            if (child) beans_release(child);
        }
        cc_walk_min = dead.len ? 256
                               : (cc_walk_min * 4 > (1LL << 18) ? (1LL << 18)
                                                                : cc_walk_min * 4);
        rt_free(st.v);
        rt_free(aux.v);
        rt_free(dead.v);
    }
    // geometric re-arm: survivors stay parked, so the next filter may scan
    // them again — amortized O(1) per park only if the buffer must grow by
    // its own size first. Husk shells thus wait at most 2·survivors + 256
    // parks, which keeps RSS flat in practice (husk-heavy programs have few
    // long-lived survivors)
    cc_threshold = cc_len * 2 + 256;
    cc_pending = 0;
    CC_UNLOCK();
    cc_collecting = 0;
}

static void cc_at_exit(void) {
    if (cc_threads == 0) cc_collect(1); // forced: leaks must see 0 at exit
}
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
__attribute__((constructor)) static void cc_setup(void) { atexit(cc_at_exit); }
#else
// No atexit, so a freestanding program that wants the final cycle sweep calls
// beans_collect_cycles() before it stops. Documented rather than silently skipped:
// without it, a cycle still holding a deinit never runs it.
void beans_collect_cycles(void) { cc_at_exit(); }
#endif

// A panic must work when memory is exactly what ran out, so the message is built in
// a fixed stack buffer and goes out through the byte sink. No allocation, and no
// stdio in the freestanding profile.
void beans_panic(const char* msg, long long line, long long col) {
    beans_out_flush(); // ordered output: buffered stdout before the stderr panic
    char text[512];
    long long n = rt_format(text, sizeof text, "runtime panic at %lld:%lld: %s\n",
                            line, col, msg);
    if (n > (long long)sizeof text - 1) n = (long long)sizeof text - 1;
    rt_write(2, text, (unsigned long long)n);
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
    exit(3);
#else
    beans_host_exit(3);
    for (;;) {} // beans_host_exit must not return; this is here so the compiler knows
#endif
}

#if BEANS_RT_PROFILE < BEANS_RT_MINIMAL
// Reached only if a program formats or parses a float without supplying the hook.
long long beans_rt_no_float(void) {
    beans_panic("this program formats or parses a float, which needs "
                "beans_host_format_f64 / beans_host_parse_f64 in the freestanding "
                "profile", 0, 0);
    return 0;
}
#endif
// list bounds — message matches the interpreter's, index and length included
void beans_panic_index(long long i, long long len, long long has_len,
                       long long line, long long col) {
    char b[96];
    if (has_len) rt_format(b, sizeof b, "list index %lld out of range (len %lld)", i, len);
    else rt_format(b, sizeof b, "list index %lld out of range", i);
    beans_panic(b, line, col);
}
void beans_panic_array_index(long long i, long long len,
                             long long line, long long col) {
    char b[96];
    rt_format(b, sizeof b, "array index %lld out of range (len %lld)", i, len);
    beans_panic(b, line, col);
}
void beans_panic_slice_index(long long i, long long len,
                             long long line, long long col) {
    char b[96];
    rt_format(b, sizeof b, "slice index %lld out of range (len %lld)", i, len);
    beans_panic(b, line, col);
}

// ---- strings (leaf allocations) ----
// a string's byte length lives in its meta shape bits (kind 0 uses none of
// bits 3-60), so len is O(1) and never strlen. Read through beans_slen —
// masking with CC_SHAPE is mandatory, colors share the word.
static long long beans_slen(char* s) { return (head_of(s)->meta & CC_SHAPE) >> 3; }
static char* str_make(const char* p, long long n);
static char* rc_strdup(const char* s) {
    size_t n = strlen(s);
    char* r = beans_alloc((long long)n + 1, (long long)n << 3);
    memcpy(r, s, n + 1);
    return r;
}
// hand-rolled digits: rt_format("%lld") was ~1/3 of the string-build loop in
// the strings bench (vfprintf machinery per call); this matches its output
// byte for byte
static long long uint_digits(unsigned long long v) {
    long long n = 1;
    while (v >= 10) { v /= 10; n += 1; }
    return n;
}
static char* write_uint(char* out, unsigned long long v) {
    long long n = uint_digits(v);
    char* end = out + n;
    char* p = end;
    do {
        *--p = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    return end;
}
static long long int_digits(long long v) {
    unsigned long long u =
        v < 0 ? (unsigned long long)-(v + 1) + 1 : (unsigned long long)v;
    return uint_digits(u) + (v < 0);
}
static char* write_int(char* out, long long v) {
    unsigned long long u =
        v < 0 ? (unsigned long long)-(v + 1) + 1 : (unsigned long long)v;
    if (v < 0) *out++ = '-';
    return write_uint(out, u);
}
char* beans_from_int(long long v) {
    char b[24];
    char* e = b + sizeof b;
    char* p = e;
    unsigned long long u =
        v < 0 ? (unsigned long long)-(v + 1) + 1 : (unsigned long long)v;
    do {
        *--p = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    if (v < 0) *--p = '-';
    return str_make(p, e - p);
}
char* beans_from_uint(unsigned long long v) {
    char b[24];
    char* e = b + sizeof b;
    char* p = e;
    do {
        *--p = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    return str_make(p, e - p);
}
char* beans_from_float(double v) {
    char b[48];
    beans_host_format_f64(b, sizeof b, v, 10, 'g');
    return rc_strdup(b);
}
char* beans_from_bool(int v) { return rc_strdup(v ? "true" : "false"); }
char* beans_concat(char* a, char* b) {
    size_t la = (size_t)beans_slen(a), lb = (size_t)beans_slen(b);
    char* r = beans_alloc((long long)(la + lb + 1), (long long)(la + lb) << 3);
    memcpy(r, a, la);
    memcpy(r + la, b, lb + 1);
    return r;
}
char* beans_interpolate(long long n, ...) {
    va_list ap;
    va_start(ap, n);
    long long total = 0;
    for (long long i = 0; i < n; i++) {
        long long kind = va_arg(ap, long long);
        if (kind == 0) {
            total += beans_slen(va_arg(ap, char*));
        } else if (kind == 1) {
            total += int_digits(va_arg(ap, long long));
        } else if (kind == 2) {
            total += uint_digits(va_arg(ap, unsigned long long));
        } else if (kind == 3) {
            char b[48];
            total += beans_host_format_f64(b, sizeof b,
                                           va_arg(ap, double), 10, 'g');
        } else {
            total += va_arg(ap, int) ? 4 : 5;
        }
    }
    va_end(ap);
    char* r = beans_alloc(total + 1, total << 3);
    char* w = r;
    va_start(ap, n);
    for (long long i = 0; i < n; i++) {
        long long kind = va_arg(ap, long long);
        if (kind == 0) {
            char* part = va_arg(ap, char*);
            long long len = beans_slen(part);
            memcpy(w, part, (size_t)len);
            w += len;
        } else if (kind == 1) {
            w = write_int(w, va_arg(ap, long long));
        } else if (kind == 2) {
            w = write_uint(w, va_arg(ap, unsigned long long));
        } else if (kind == 3) {
            char b[48];
            int len = (int)beans_host_format_f64(b, sizeof b,
                                                 va_arg(ap, double), 10, 'g');
            memcpy(w, b, (size_t)len);
            w += len;
        } else {
            int value = va_arg(ap, int);
            const char* text = value ? "true" : "false";
            long long len = value ? 4 : 5;
            memcpy(w, text, (size_t)len);
            w += len;
        }
    }
    va_end(ap);
    return r;
}
// strings carry their byte length and may legally hold NUL (\0 escapes,
// File.read) — every consumer here is length-based; C-string fns like fputs,
// strcmp, and strstr would silently stop at the first NUL and diverge from
// the interpreter
static char* str_make(const char* p, long long n);
void beans_println(char* s) {
    rt_write(1, s, (size_t)beans_slen(s));
    rt_write(1, "\n", 1);
}
void beans_print(char* s) { rt_write(1, s, (size_t)beans_slen(s)); }
void beans_eprintln(char* s) {
    rt_write(2, s, (size_t)beans_slen(s));
    rt_write(2, "\n", 1);
}
void beans_eprint(char* s) { rt_write(2, s, (size_t)beans_slen(s)); }
// std::string semantics: bytes compare unsigned over the shorter length,
// ties break on length
int beans_str_cmp(char* a, char* b) {
    long long la = beans_slen(a), lb = beans_slen(b);
    long long n = la < lb ? la : lb;
    int c = n ? memcmp(a, b, (size_t)n) : 0;
    if (c) return c;
    return la < lb ? -1 : la > lb ? 1 : 0;
}
long long beans_str_len(char* s) { return beans_slen(s); }
char* beans_str_last(char* s, long long n) {
    long long len = beans_slen(s);
    if (n < 0) n = 0;
    if (n > len) n = len;
    return str_make(s + (len - n), n);
}
// leftmost match: memchr for the first byte (SIMD in libc), memcmp for the
// tail. memcmp-at-every-offset made contains/replace/split the hot spot of
// the strings bench, 2x behind Go's bytealg search.
static long long str_search(const char* s, long long n, const char* sub,
                            long long m, long long from) {
    if (m > n - from) return -1;
    if (m == 0) return from;
    const char* end = s + n;
    const char* p = s + from;
    for (;;) {
        long long room = (end - p) - (m - 1);
        if (room <= 0) return -1;
        const char* hit = memchr(p, sub[0], (size_t)room);
        if (!hit) return -1;
        if (m == 1 || memcmp(hit + 1, sub + 1, (size_t)(m - 1)) == 0) {
            return hit - s;
        }
        p = hit + 1;
    }
}
long long beans_str_contains(char* s, char* sub) {
    long long n = beans_slen(s), m = beans_slen(sub);
    if (m == 0) return 1;
    return str_search(s, n, sub, m, 0) >= 0;
}

// A ready-made Error uses the same target layout as codegen's ErrorLayout:
// [show pointer][-1 i64][msg pointer][kind pointer]. On ILP32 the last two
// fields are slots 4 and 5, not the 64-bit layout's slots 2 and 3. Derive the
// mask from C's own offsets so runtime-created errors cannot mark type_id=-1
// as a pointer on wasm32.
typedef struct {
    void* show;
    long long type_id;
    void* msg;
    void* kind;
} BError;

static long long error_meta(void) {
    long long msg_slot = (long long)offsetof(BError, msg) / RT_SLOT_STRIDE;
    long long kind_slot = (long long)offsetof(BError, kind) / RT_SLOT_STRIDE;
    return 1 | ((1LL << msg_slot | 1LL << kind_slot) << 3);
}

static void* mk_error(const char* msg, const char* kind) {
    BError* e = beans_alloc(sizeof(BError), error_meta());
    e->type_id = -1;
    e->msg = rc_strdup(msg);
    e->kind = rc_strdup(kind);
    return e;
}
// like mk_error, but msg is already an rc string carrying its exact byte
// length — user text can hold NUL and must not pass through strlen
static void* mk_error_own(char* msg_rc, const char* kind) {
    BError* e = beans_alloc(sizeof(BError), error_meta());
    e->type_id = -1;
    e->msg = msg_rc;
    e->kind = rc_strdup(kind);
    return e;
}

// C-to-C result shape. Generated LLVM calls the scalar `_out` wrappers below,
// so no target-dependent aggregate return crosses that boundary.
// err null = ok(val); err set = a ready Error object the caller boxes.
typedef struct {
    long long val;
    void* err;
} BRes;

static BRes parse_fail(const char* s, const char* what) {
    // s is the beans receiver string — splice it by its stored length so an
    // embedded NUL keeps the message byte-identical to the interpreter's
    const char* p1 = "can't read '";
    const char* p2 = "' as ";
    long long ls = beans_slen((char*)s);
    size_t l1 = strlen(p1), l2 = strlen(p2), lw = strlen(what);
    long long total = (long long)l1 + ls + (long long)l2 + (long long)lw;
    char* m = beans_alloc(total + 1, total << 3);
    char* w = m;
    memcpy(w, p1, l1);
    w += l1;
    memcpy(w, s, (size_t)ls);
    w += ls;
    memcpy(w, p2, l2);
    w += l2;
    memcpy(w, what, lw);
    return (BRes){0, mk_error_own(m, "")};
}

// A base-10 signed parse, so the core does not need strtoll. Rejects anything the
// old strtoll(…, 10) path rejected, and saturates the same way on overflow.
static int rt_parse_i64(const char* text, long long* out, const char** end) {
    const char* p = text;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    int negative = 0;
    if (*p == '+' || *p == '-') negative = *p++ == '-';
    if (*p < '0' || *p > '9') {
        if (end) *end = text;
        return 0;
    }
    unsigned long long value = 0;
    // The limit is asymmetric: -9223372036854775808 is valid and its positive
    // counterpart is not.
    const unsigned long long cap = negative ? 9223372036854775808ULL
                                            : 9223372036854775807ULL;
    int overflowed = 0;
    while (*p >= '0' && *p <= '9') {
        unsigned long long digit = (unsigned long long)(*p++ - '0');
        if (value > (cap - digit) / 10) overflowed = 1;
        else value = value * 10 + digit;
    }
    if (end) *end = p;
    if (overflowed) value = cap;
    *out = negative ? -(long long)value : (long long)value;
    return 1;
}

BRes beans_str_to_int(char* s) {
    const char* end = NULL;
    long long v = 0;
    if (!rt_parse_i64(s, &v, &end) || end == s || *end != '\0')
        return parse_fail(s, "int");
    return (BRes){v, NULL};
}
long long beans_str_to_int_out(char* s, void** e_out) { BRes r = beans_str_to_int(s); *e_out = r.err; return r.val; }

BRes beans_str_to_float(char* s) {
    const char* end = NULL;
    double d = 0;
    if (!beans_host_parse_f64(s, &d, &end) || end == s || *end != '\0')
        return parse_fail(s, "float");
    BRes r;
    r.err = NULL;
    memcpy(&r.val, &d, 8);
    return r;
}
long long beans_str_to_float_out(char* s, void** e_out) { BRes r = beans_str_to_float(s); *e_out = r.err; return r.val; }

// Option-shaped ABI: has 0 = none
typedef struct {
    long long val;
    long long has;
} BOpt;

// ---- portable fallible-builtin ABI ----
// Generated LLVM must not take a BRes/BOpt back through a struct return: whether
// a 16-byte aggregate rides in registers or an sret pointer is a per-target C-ABI
// fact (SysV register-pair, Win64 sret, ARM64-Windows register-pair, ...), and the
// compiler must not encode it. So every fallible/optional runtime symbol `foo` has a
// thin `foo_out` wrapper co-located with it (same #if guards): it returns the raw
// i64 value normally and writes the second word — the error object for BRes, the
// presence/found flag for BOpt — through an output pointer that is always the LAST
// argument and is always written. C-to-C calls keep using BRes/BOpt directly.

// explicit-length string maker; the terminator byte is already zero
// because every allocation path hands back zeroed memory
static char* str_make(const char* p, long long n) {
    char* r = beans_alloc(n + 1, n << 3);
    memcpy(r, p, (size_t)n);
    return r;
}

long long beans_str_is_empty(char* s) { return beans_slen(s) == 0; }
char* beans_str_first(char* s, long long n) {
    long long len = beans_slen(s);
    if (n < 0) n = 0;
    if (n > len) n = len;
    return str_make(s, n);
}
long long beans_str_starts_with(char* s, char* p) {
    long long pl = beans_slen(p);
    return pl <= beans_slen(s) && memcmp(s, p, (size_t)pl) == 0;
}
long long beans_str_ends_with(char* s, char* p) {
    long long n = beans_slen(s), pl = beans_slen(p);
    return pl <= n && memcmp(s + n - pl, p, (size_t)pl) == 0;
}
// empty needle: find says 0, rfind says len — the C++ side agrees
BOpt beans_str_find(char* s, char* sub) {
    long long n = beans_slen(s), m = beans_slen(sub);
    if (m == 0) return (BOpt){0, 1};
    long long i = str_search(s, n, sub, m, 0);
    if (i >= 0) return (BOpt){i, 1};
    return (BOpt){0, 0};
}
long long beans_str_find_out(char* s, char* sub, long long* has_out) { BOpt o = beans_str_find(s, sub); *has_out = o.has; return o.val; }
BOpt beans_str_rfind(char* s, char* sub) {
    long long n = beans_slen(s), m = beans_slen(sub);
    if (m == 0) return (BOpt){n, 1};
    for (long long i = n - m; i >= 0; i--) {
        if (memcmp(s + i, sub, (size_t)m) == 0) return (BOpt){i, 1};
    }
    return (BOpt){0, 0};
}
long long beans_str_rfind_out(char* s, char* sub, long long* has_out) { BOpt o = beans_str_rfind(s, sub); *has_out = o.has; return o.val; }
char* beans_str_slice(char* s, long long from, long long to, long long line,
                      long long col) {
    long long n = beans_slen(s);
    if (from < 0 || to < from || to > n) {
        char m[96];
        rt_format(m, sizeof m, "slice %lld..%lld out of range (len %lld)", from, to, n);
        beans_panic(m, line, col);
    }
    return str_make(s + from, to - from);
}
long long beans_str_byte_at(char* s, long long i, long long line, long long col) {
    long long n = beans_slen(s);
    if (i < 0 || i >= n) {
        char m[80];
        rt_format(m, sizeof m, "byte index %lld out of range (len %lld)", i, n);
        beans_panic(m, line, col);
    }
    return (long long)(unsigned char)s[i];
}
long long beans_str_find_byte(char* s, long long byte, long long from,
                              long long line, long long col) {
    long long n = beans_slen(s);
    if (byte < 0 || byte > 255) {
        char m[64];
        rt_format(m, sizeof m, "byte %lld out of range", byte);
        beans_panic(m, line, col);
    }
    if (from < 0 || from > n) {
        char m[96];
        rt_format(m, sizeof m, "find start %lld out of range (len %lld)", from, n);
        beans_panic(m, line, col);
    }
    void* found = memchr(s + from, (unsigned char)byte, (size_t)(n - from));
    return found ? (long long)((char*)found - s) : -1;
}
long long beans_str_range_equals(char* s, long long from, long long to,
                                  char* other, long long line, long long col) {
    long long n = beans_slen(s);
    if (from < 0 || to < from || to > n) {
        char m[96];
        rt_format(m, sizeof m, "range %lld..%lld out of range (len %lld)",
                 from, to, n);
        beans_panic(m, line, col);
    }
    long long length = to - from;
    return length == beans_slen(other) &&
           memcmp(s + from, other, (size_t)length) == 0;
}
long long beans_str_parse_int_range_or(char* s, long long from, long long to,
                                        long long fallback, long long line,
                                        long long col) {
    long long n = beans_slen(s);
    if (from < 0 || to < from || to > n) {
        char m[96];
        rt_format(m, sizeof m, "range %lld..%lld out of range (len %lld)",
                 from, to, n);
        beans_panic(m, line, col);
    }
    long long at = from;
    int negative = 0;
    if (at < to && (s[at] == '+' || s[at] == '-')) {
        negative = s[at] == '-';
        at += 1;
    }
    if (at == to) return fallback;
    unsigned long long value = 0;
    for (; at < to; at++) {
        unsigned char c = (unsigned char)s[at];
        if (c < '0' || c > '9') return fallback;
        value = value * 10 + (unsigned long long)(c - '0');
    }
    if (negative) value = 0 - value;
    return (long long)value;
}
static int str_is_ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}
char* beans_str_trim(char* s) {
    long long b = 0, e = beans_slen(s);
    while (b < e && str_is_ws(s[b])) b++;
    while (e > b && str_is_ws(s[e - 1])) e--;
    return str_make(s + b, e - b);
}
char* beans_str_trim_start(char* s) {
    long long b = 0, e = beans_slen(s);
    while (b < e && str_is_ws(s[b])) b++;
    return str_make(s + b, e - b);
}
char* beans_str_trim_end(char* s) {
    long long e = beans_slen(s);
    while (e > 0 && str_is_ws(s[e - 1])) e--;
    return str_make(s, e);
}
char* beans_str_to_upper(char* s) {
    long long n = beans_slen(s);
    char* r = str_make(s, n);
    for (long long i = 0; i < n; i++) {
        if (r[i] >= 'a' && r[i] <= 'z') r[i] = (char)(r[i] - 'a' + 'A');
    }
    return r;
}
char* beans_str_to_lower(char* s) {
    long long n = beans_slen(s);
    char* r = str_make(s, n);
    for (long long i = 0; i < n; i++) {
        if (r[i] >= 'A' && r[i] <= 'Z') r[i] = (char)(r[i] - 'A' + 'a');
    }
    return r;
}
char* beans_str_replace(char* s, char* old, char* nw) {
    long long n = beans_slen(s), m = beans_slen(old), rl = beans_slen(nw);
    if (m == 0) return str_make(s, n); // replacing nothing changes nothing
    long long count = 0;
    for (long long i = str_search(s, n, old, m, 0); i >= 0;
         i = str_search(s, n, old, m, i + m)) {
        count++;
    }
    if (count == 0) return str_make(s, n);
    long long outn = n + count * (rl - m);
    char* out = beans_alloc(outn + 1, outn << 3);
    char* w = out;
    long long i = 0;
    for (;;) {
        long long j = str_search(s, n, old, m, i);
        if (j < 0) break;
        memcpy(w, s + i, (size_t)(j - i));
        w += j - i;
        memcpy(w, nw, (size_t)rl);
        w += rl;
        i = j + m;
    }
    memcpy(w, s + i, (size_t)(n - i));
    return out;
}
char* beans_str_repeat(char* s, long long n, long long line, long long col) {
    if (n < 0) {
        char m[64];
        rt_format(m, sizeof m, "negative repeat count %lld", n);
        beans_panic(m, line, col);
    }
    long long len = beans_slen(s);
    long long outn = len * n;
    char* out = beans_alloc(outn + 1, outn << 3);
    for (long long i = 0; i < n; i++) memcpy(out + i * len, s, (size_t)len);
    return out;
}
// Half away from zero, which is what llround does for every value a program can
// meaningfully round. Written out rather than pulled from libm, which the
// freestanding profile does not have.
long long beans_f64_round(double v) {
    return v < 0 ? -(long long)(-v + 0.5) : (long long)(v + 0.5);
}

// ---- lists ----
static long long list_stride(BList* l) {
    return l->stride < 0 ? -l->stride : (l->stride ? l->stride : 8);
}
static void list_retain_element(BList* l, void* element) {
    int i64_encoded = l->stride < 0;
    for (int slot = 0; slot < RT_MASK_SLOTS && (l->ptr_mask >> slot); slot++) {
        if (!((l->ptr_mask >> slot) & 1)) continue;
        void* child = rt_masked_child(element, slot, i64_encoded);
        if (child) beans_retain(child);
    }
}
static void list_release_element(BList* l, void* element) {
    int i64_encoded = l->stride < 0;
    for (int slot = 0; slot < RT_MASK_SLOTS && (l->ptr_mask >> slot); slot++) {
        if (!((l->ptr_mask >> slot) & 1)) continue;
        void* child = rt_masked_child(element, slot, i64_encoded);
        if (child) beans_release(child);
    }
}
BList* beans_list_new_typed(long long stride, long long ptr_mask) {
    if (stride <= 0 || stride > (1LL << 30))
        beans_panic("invalid list element size", 0, 0);
    BList* l = beans_alloc(sizeof(BList), 2 | ((ptr_mask != 0) << 3));
    l->cap = 4;
    l->stride = stride;
    l->ptr_mask = ptr_mask;
    l->data = rt_zalloc((unsigned long long)(4) * (size_t)stride);
    if (!l->data) beans_panic("out of memory", 0, 0);
    return l;
}
// Exact-capacity construction for results whose whole live range is written
// right after. The plain constructor always callocs four slots, so slice and
// clone used to allocate, free, and allocate again for every result — 400k
// wasted calloc/free pairs in bench/slices.b alone, against a std::vector
// range constructor that allocates once. Callers must fill [0, len).
static BList* list_new_capacity(long long stride, long long ptr_mask,
                                long long capacity, long long line,
                                long long col) {
    long long byte_stride = stride < 0 ? -stride : stride;
    if (byte_stride <= 0 || byte_stride > (1LL << 30))
        beans_panic("invalid list element size", line, col);
    BList* l = beans_alloc(sizeof(BList), 2 | ((ptr_mask != 0) << 3));
    l->cap = capacity > 4 ? capacity : 4;
    l->stride = stride;
    l->ptr_mask = ptr_mask;
    l->data = rt_alloc((size_t)l->cap * (size_t)byte_stride);
    if (!l->data) beans_panic("out of memory", line, col);
    return l;
}
BList* beans_list_new(long long elem_ptr) {
    BList* l = beans_list_new_typed(8, elem_ptr);
    l->stride = -8; // generic i64 slot; see the object-ABI walker
    return l;
}
void beans_list_push(BList* l, long long v) {
    if (l->len == l->cap) {
        l->cap *= 2;
        l->data = rt_realloc(l->data, (size_t)l->cap * (size_t)list_stride(l));
        if (!l->data) beans_panic("out of memory", 0, 0);
    }
    l->data[l->len++] = v;
}
void beans_list_push_typed(BList* l, const void* value) {
    long long stride = list_stride(l);
    if (l->len == l->cap) {
        l->cap *= 2;
        l->data = rt_realloc(l->data, (size_t)l->cap * (size_t)stride);
        if (!l->data) beans_panic("out of memory", 0, 0);
    }
    memcpy((char*)l->data + l->len * stride, value, (size_t)stride);
    l->len += 1;
}
void beans_list_reserve(BList* l, long long capacity, long long line, long long col) {
    if (capacity < 0) {
        char b[64];
        rt_format(b, sizeof b, "negative reserve capacity %lld", capacity);
        beans_panic(b, line, col);
    }
    if (capacity > (1LL << 58)) beans_panic("reserve capacity too large", line, col);
    if (capacity <= l->cap) return;
    long long cap = l->cap;
    while (cap < capacity && cap <= (1LL << 60)) cap *= 2;
    if (cap < capacity) cap = capacity;
    l->data = rt_realloc(l->data, (size_t)cap * (size_t)list_stride(l));
    if (!l->data) beans_panic("out of memory", line, col);
    l->cap = cap;
}

// ---- class hierarchy (table emitted by the compiler) ----
extern long long beans_class_parents[];
long long beans_is_a(long long id, long long target) {
    while (id >= 0) {
        if (id == target) return 1;
        id = beans_class_parents[id];
    }
    return 0;
}

// ---- list search helpers (kind: 0 int-ish, 1 f64, 2 string, 3 decimal,
// 4 unordered — everything compares equal, so sort keeps the original order
// and min/max return the first element, like the interpreter's value_less
// returning false) ----
#if BEANS_RT_DECIMAL
struct BDec;
int beans_dec_cmp(struct BDec* a, struct BDec* b);
#endif
static int slot_cmp(long long a, long long b, long long kind) {
    if (kind == 1) {
        double x, y;
        memcpy(&x, &a, 8);
        memcpy(&y, &b, 8);
        return x < y ? -1 : x > y ? 1 : 0;
    }
    if (kind == 2) return beans_str_cmp((char*)a, (char*)b);
#if BEANS_RT_DECIMAL
    if (kind == 3) return beans_dec_cmp((struct BDec*)a, (struct BDec*)b);
#endif
    if (kind == 4) return 0;
    if (kind == 5) {
        unsigned long long x = (unsigned long long)a;
        unsigned long long y = (unsigned long long)b;
        return x < y ? -1 : x > y ? 1 : 0;
    }
    if (kind == 6) {
        unsigned aa = (unsigned)a, bb = (unsigned)b;
        float x, y;
        memcpy(&x, &aa, 4);
        memcpy(&y, &bb, 4);
        return x < y ? -1 : x > y ? 1 : 0;
    }
    return a < b ? -1 : a > b ? 1 : 0;
}
// content equality for strings — length header first, bytes second; strcmp
// would stop at an embedded NUL and lie
long long beans_str_eq(char* a, char* b) {
    long long n = beans_slen(a);
    return n == beans_slen(b) && memcmp(a, b, (size_t)n) == 0;
}
// equality kinds (separate lattice from the ordering kinds above), matching
// the interpreter's value_eq arm for arm: 0 raw slot (ints, bools, pointer
// identity), 1 f64 by IEEE value (NaN equals nothing), 2 string content,
// 3 decimal value, 4 caller-supplied structural eq (enums, Bytes), 5 never
// equal (maps and resource handles — value_eq's default arm)
static long long slot_eq(long long a, long long b, long long kind,
                         long long (*eq)(long long, long long)) {
    if (kind == 0) return a == b;
    if (kind == 1) {
        double x, y;
        memcpy(&x, &a, 8);
        memcpy(&y, &b, 8);
        return x == y;
    }
    if (kind == 2) return beans_str_eq((char*)a, (char*)b);
#if BEANS_RT_DECIMAL
    if (kind == 3) return beans_dec_cmp((struct BDec*)a, (struct BDec*)b) == 0;
#endif
    if (kind == 4) return eq(a, b) != 0;
    if (kind == 6) {
        unsigned aa = (unsigned)a, bb = (unsigned)b;
        float x, y;
        memcpy(&x, &aa, 4);
        memcpy(&y, &bb, 4);
        return x == y;
    }
    return 0;
}
// hashes for the map index, one per equality kind. The contract is only that
// slot_eq-equal keys hash equal; the interpreter hashes differently and that
// is fine — nothing observable depends on hash values, iteration walks data.
static unsigned long long beans_mix64(unsigned long long x) {
    // One multiply is enough for an in-process table: unlike a persisted
    // cryptographic hash, this only needs to spread sequential integers and
    // aligned pointers across a power-of-two index. The old Murmur finalizer
    // used two multiplies and six dependent operations on every lookup.
    x ^= x >> 32;
    x *= 0xd6e8feb86659fd93ULL;
    x ^= x >> 32;
    return x;
}
long long beans_slot_mix(long long v) { return (long long)beans_mix64((unsigned long long)v); }
long long beans_f64_hash(long long v) {
    double x;
    memcpy(&x, &v, 8);
    if (x == 0.0) return (long long)beans_mix64(0); // -0.0 == 0.0
    return (long long)beans_mix64((unsigned long long)v);
}
long long beans_f32_hash(long long v) {
    unsigned bits = (unsigned)v;
    float x;
    memcpy(&x, &bits, 4);
    if (x == 0.0f) return (long long)beans_mix64(0);
    return (long long)beans_mix64(bits);
}
long long beans_str_hash(char* s) {
    long long n = beans_slen(s);
    unsigned long long h = 1469598103934665603ULL;
    for (long long i = 0; i < n; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return (long long)beans_mix64(h);
}
#if BEANS_RT_DECIMAL
long long beans_dec_hash(struct BDec* d);
#endif
long long beans_bytes_hash(BList* b) {
    unsigned long long h = 1469598103934665603ULL;
    for (long long i = 0; i < b->len; i++) {
        h ^= ((unsigned char*)b->data)[i];
        h *= 1099511628211ULL;
    }
    return (long long)beans_mix64(h);
}
static unsigned long long slot_hash(long long v, long long kind,
                                    long long (*hf)(long long)) {
    if (kind == 1) return (unsigned long long)beans_f64_hash(v);
    if (kind == 2) return (unsigned long long)beans_str_hash((char*)v);
#if BEANS_RT_DECIMAL
    if (kind == 3) return (unsigned long long)beans_dec_hash((struct BDec*)v);
#endif
    if (kind == 4) return (unsigned long long)hf(v);
    if (kind == 6) return (unsigned long long)beans_f32_hash(v);
    return beans_mix64((unsigned long long)v); // raw, and never-equal keys
}
long long beans_list_max(BList* l, long long kind, long long* ok) {
    *ok = l->len > 0;
    if (!*ok) return 0;
    long long best = l->data[0];
    for (long long i = 1; i < l->len; i++) {
        if (slot_cmp(l->data[i], best, kind) > 0) best = l->data[i];
    }
    return best;
}
long long beans_list_contains(BList* l, long long v, long long kind, void* eq) {
    for (long long i = 0; i < l->len; i++) {
        if (slot_eq(l->data[i], v, kind, (long long (*)(long long, long long))eq)) return 1;
    }
    return 0;
}
long long beans_list_min(BList* l, long long kind, long long* ok) {
    *ok = l->len > 0;
    if (!*ok) return 0;
    long long best = l->data[0];
    for (long long i = 1; i < l->len; i++) {
        if (slot_cmp(l->data[i], best, kind) < 0) best = l->data[i];
    }
    return best;
}
long long beans_list_index(BList* l, long long v, long long kind, long long* ok,
                           void* eq) {
    for (long long i = 0; i < l->len; i++) {
        if (slot_eq(l->data[i], v, kind, (long long (*)(long long, long long))eq)) {
            *ok = 1;
            return i;
        }
    }
    *ok = 0;
    return 0;
}
void beans_list_insert(BList* l, long long i, long long v, long long line,
                       long long col) {
    if (i < 0 || i > l->len) {
        char b[96];
        rt_format(b, sizeof b, "insert at %lld out of range (len %lld)", i, l->len);
        beans_panic(b, line, col);
    }
    if (l->len == l->cap) {
        l->cap *= 2;
        l->data = rt_realloc(l->data, (size_t)l->cap * 8);
    }
    memmove(l->data + i + 1, l->data + i, (size_t)(l->len - i) * 8);
    l->data[i] = v;
    l->len += 1;
}
void beans_list_insert_typed(BList* l, long long i, const void* value,
                             long long line, long long col) {
    if (i < 0 || i > l->len) {
        char b[96];
        rt_format(b, sizeof b, "insert at %lld out of range (len %lld)", i, l->len);
        beans_panic(b, line, col);
    }
    long long stride = list_stride(l);
    if (l->len == l->cap) {
        l->cap *= 2;
        l->data = rt_realloc(l->data, (size_t)l->cap * (size_t)stride);
        if (!l->data) beans_panic("out of memory", line, col);
    }
    char* at = (char*)l->data + i * stride;
    memmove(at + stride, at, (size_t)(l->len - i) * (size_t)stride);
    memcpy(at, value, (size_t)stride);
    l->len += 1;
}
long long beans_list_remove(BList* l, long long i, long long line, long long col) {
    if (i < 0 || i >= l->len) {
        char b[96];
        rt_format(b, sizeof b, "list index %lld out of range (len %lld)", i, l->len);
        beans_panic(b, line, col);
    }
    long long v = l->data[i];
    memmove(l->data + i, l->data + i + 1, (size_t)(l->len - i - 1) * 8);
    l->len -= 1;
    return v; // the caller now owns the moved-out ref
}
void beans_list_remove_typed(BList* l, long long i, void* out, long long line,
                             long long col) {
    if (i < 0 || i >= l->len) {
        char b[96];
        rt_format(b, sizeof b, "list index %lld out of range (len %lld)", i, l->len);
        beans_panic(b, line, col);
    }
    long long stride = list_stride(l);
    char* at = (char*)l->data + i * stride;
    memcpy(out, at, (size_t)stride);
    memmove(at, at + stride, (size_t)(l->len - i - 1) * (size_t)stride);
    l->len -= 1;
}
void beans_list_reverse(BList* l) {
    long long stride = list_stride(l);
    if (stride != 8) {
        void* tmp = rt_alloc((size_t)stride);
        if (!tmp) beans_panic("out of memory", 0, 0);
        for (long long i = 0, j = l->len - 1; i < j; i++, j--) {
            char* a = (char*)l->data + i * stride;
            char* b = (char*)l->data + j * stride;
            memcpy(tmp, a, (size_t)stride);
            memcpy(a, b, (size_t)stride);
            memcpy(b, tmp, (size_t)stride);
        }
        rt_free(tmp);
        return;
    }
    for (long long i = 0, j = l->len - 1; i < j; i++, j--) {
        long long t = l->data[i];
        l->data[i] = l->data[j];
        l->data[j] = t;
    }
}
void beans_list_clear(BList* l) {
    // last element first — deinit made death order observable, and the
    // interpreter's vector teardown destroys back to front
    if (l->ptr_mask) {
        long long stride = list_stride(l);
        for (long long i = l->len; i-- > 0;) {
            list_release_element(l, (char*)l->data + i * stride);
        }
    }
    l->len = 0;
}
BList* beans_list_slice(BList* l, long long from, long long to, long long line,
                        long long col) {
    if (from < 0 || to < from || to > l->len) {
        char b[96];
        rt_format(b, sizeof b, "slice %lld..%lld out of range (len %lld)", from, to,
                 l->len);
        beans_panic(b, line, col);
    }
    long long n = to - from;
    long long stride = list_stride(l);
    BList* r = list_new_capacity(l->stride ? l->stride : 8,
                                 l->ptr_mask, n, line, col);
    r->len = n;
    memcpy(r->data, (char*)l->data + from * stride, (size_t)n * (size_t)stride);
    if (r->ptr_mask)
        for (long long i = 0; i < n; i++)
            list_retain_element(r, (char*)r->data + i * stride);
    return r;
}
BList* beans_list_clone(BList* l) {
    long long stride = list_stride(l);
    BList* r = list_new_capacity(l->stride ? l->stride : 8,
                                 l->ptr_mask, l->len, 0, 0);
    r->len = l->len;
    memcpy(r->data, l->data, (size_t)l->len * (size_t)stride);
    if (r->ptr_mask)
        for (long long i = 0; i < r->len; i++)
            list_retain_element(r, (char*)r->data + i * stride);
    return r;
}

// bottom-up stable merge — structurally identical to the interpreter's
// stable_merge, so both backends produce the same order for ANY predicate,
// even one that is not a strict weak ordering
static long long sort_less(long long x, long long y, long long kind, void* thunk,
                           void* box) {
    if (thunk) return ((long long (*)(void*, long long, long long))thunk)(box, x, y);
    return slot_cmp(x, y, kind) < 0;
}
static void list_merge_sort(long long* a, long long n, long long kind, void* thunk,
                            void* box) {
    if (n < 2) return;
    long long* buf = rt_alloc((size_t)n * 8);
    for (long long w = 1; w < n; w *= 2) {
        for (long long lo = 0; lo < n; lo += 2 * w) {
            long long mid = lo + w < n ? lo + w : n;
            long long hi = lo + 2 * w < n ? lo + 2 * w : n;
            if (mid >= hi) continue;
            long long i = lo, j = mid, o = lo;
            while (i < mid && j < hi) {
                if (!sort_less(a[j], a[i], kind, thunk, box)) buf[o++] = a[i++];
                else buf[o++] = a[j++];
            }
            while (i < mid) buf[o++] = a[i++];
            while (j < hi) buf[o++] = a[j++];
            memcpy(a + lo, buf + lo, (size_t)(hi - lo) * 8);
        }
    }
    rt_free(buf);
}
// Signed integer slots have a cheaper stable path: one to four 16-bit passes
// after subtracting the observed minimum. Narrow real-world ranges therefore
// do one pass while the full signed range still takes four.
// This avoids a comparator branch for every merge comparison and keeps equal
// values in input order. bool uses the same path (its slots are 0/1).
static void list_radix_sort_int(long long* a, long long n) {
    if (n < 2) return;
    long long minimum = a[0], maximum = a[0];
    for (long long i = 1; i < n; i++) {
        if (a[i] < minimum) minimum = a[i];
        if (a[i] > maximum) maximum = a[i];
    }
    unsigned long long span =
        (unsigned long long)maximum - (unsigned long long)minimum;
    int passes = span <= 0xffffULL ? 1 : span <= 0xffffffffULL ? 2 : 4;
    long long* buf = rt_alloc((size_t)n * 8);
    long long* src = a;
    long long* dst = buf;
    size_t* count = rt_alloc(65536 * sizeof(size_t));
    size_t* at = rt_alloc(65536 * sizeof(size_t));
    for (int pass = 0; pass < passes; pass++) {
        memset(count, 0, 65536 * sizeof(size_t));
        int shift = pass * 16;
        for (long long i = 0; i < n; i++) {
            unsigned long long key =
                (unsigned long long)src[i] - (unsigned long long)minimum;
            count[(key >> shift) & 65535]++;
        }
        size_t sum = 0;
        for (int word = 0; word < 65536; word++) {
            at[word] = sum;
            sum += count[word];
        }
        for (long long i = 0; i < n; i++) {
            unsigned long long key =
                (unsigned long long)src[i] - (unsigned long long)minimum;
            dst[at[(key >> shift) & 65535]++] = src[i];
        }
        long long* swap = src;
        src = dst;
        dst = swap;
    }
    if (src != a) memcpy(a, src, (size_t)n * 8);
    rt_free(count);
    rt_free(at);
    rt_free(buf);
}
void beans_list_sort(BList* l, long long kind) {
    if (kind == 0) list_radix_sort_int(l->data, l->len);
    else list_merge_sort(l->data, l->len, kind, NULL, NULL);
}
void beans_list_sort_by(BList* l, void* thunk, void* box) {
    list_merge_sort(l->data, l->len, 0, thunk, box);
}
void beans_list_sort_by_key(BList* l, void* thunk, void* box) {
    long long n = l->len;
    if (n < 2) return;
    long long* keys = rt_alloc((size_t)n * 8);
    long long* val_buf = rt_alloc((size_t)n * 8);
    size_t* count = rt_alloc(65536 * sizeof(size_t));
    size_t* at = rt_alloc(65536 * sizeof(size_t));
    long long (*key_fn)(void*, long long) =
        (long long (*)(void*, long long))thunk;
    long long minimum = 0, maximum = 0;
    for (long long i = 0; i < n; i++) {
        keys[i] = key_fn(box, l->data[i]);
        if (i == 0 || keys[i] < minimum) minimum = keys[i];
        if (i == 0 || keys[i] > maximum) maximum = keys[i];
    }
    unsigned long long span =
        (unsigned long long)maximum - (unsigned long long)minimum;
    int passes = span <= 0xffffULL ? 1 : span <= 0xffffffffULL ? 2 : 4;
    long long* key_buf = passes > 1 ? rt_alloc((size_t)n * 8) : NULL;
    long long* key_src = keys;
    long long* key_dst = key_buf;
    long long* val_src = l->data;
    long long* val_dst = val_buf;
    for (int pass = 0; pass < passes; pass++) {
        memset(count, 0, 65536 * sizeof(size_t));
        int shift = pass * 16;
        for (long long i = 0; i < n; i++) {
            unsigned long long key =
                (unsigned long long)key_src[i] - (unsigned long long)minimum;
            count[(key >> shift) & 65535]++;
        }
        size_t sum = 0;
        for (int word = 0; word < 65536; word++) {
            at[word] = sum;
            sum += count[word];
        }
        for (long long i = 0; i < n; i++) {
            unsigned long long key =
                (unsigned long long)key_src[i] - (unsigned long long)minimum;
            size_t out = at[(key >> shift) & 65535]++;
            if (passes > 1) key_dst[out] = key_src[i];
            val_dst[out] = val_src[i];
        }
        long long* swap;
        if (passes > 1) {
            swap = key_src; key_src = key_dst; key_dst = swap;
        }
        swap = val_src; val_src = val_dst; val_dst = swap;
    }
    if (val_src != l->data) memcpy(l->data, val_src, (size_t)n * 8);
    rt_free(keys);
    rt_free(key_buf);
    rt_free(val_buf);
    rt_free(count);
    rt_free(at);
}

// ---- maps ----
// A flat key/value array plus an open-addressed index. OrderedMap leaves stable
// removal holes. Map swap-removes. Small maps have no index and scan linearly.
#define MAP_LINEAR_MAX 8
#define IDX_POS 0xffffffffULL /* low 32: pos+2, 1 = tombstone */
#define IDX_FRAG 0xffffffff00000000ULL /* high 32: hash fragment */
#define MAP_DEAD(m, p) ((m)->deadbits && (m)->deadbits[(p) >> 6] >> ((p)&63) & 1)
static void* map_wide_value(BMap* m, long long index) {
    return (char*)m->wide_values + index * m->value_stride;
}
static void map_retain_wide_value(BMap* m, void* value) {
    for (int slot = 0; slot < RT_MASK_SLOTS && (m->value_ptr_mask >> slot); slot++) {
        if (!((m->value_ptr_mask >> slot) & 1)) continue;
        void* child = *(void**)RT_SLOT_AT(value, slot);
        if (child) beans_retain(child);
    }
}
static void map_release_wide_value(BMap* m, void* value) {
    // Aggregate teardown is last-field-first, matching generated structs.
    for (int slot = 58; slot-- > 0;) {
        if (!((m->value_ptr_mask >> slot) & 1)) continue;
        void* child = *(void**)RT_SLOT_AT(value, slot);
        if (child) beans_release(child);
    }
}
BMap* beans_map_new(long long key_ptr, long long val_ptr, long long ordered) {
    BMap* m = beans_alloc(sizeof(BMap), 3 | (key_ptr << 3) | (val_ptr << 4));
    m->cap = 4;
    m->data = rt_zalloc((unsigned long long)(8) * (8)); // idx/tombs/used/deadbits start zero: beans_alloc zeroes
    m->ordered = ordered;
    return m;
}
BMap* beans_map_new_typed_value(long long key_ptr, long long value_stride,
                                long long value_ptr_mask,
                                long long value_cycle_mask, long long ordered) {
    if (value_stride <= 0 || value_stride > (1LL << 30))
        beans_panic("invalid map value size", 0, 0);
    BMap* m = beans_map_new(key_ptr, value_ptr_mask != 0, ordered);
    m->value_stride = value_stride;
    m->value_ptr_mask = value_ptr_mask;
    m->value_cycle_mask = value_cycle_mask;
    m->wide_values = rt_zalloc((unsigned long long)(4) * (size_t)value_stride);
    if (!m->wide_values) beans_panic("out of memory", 0, 0);
    return m;
}
// (re)build the index sized for the current entry count, dropping tombstones
// and compacting holes. Only moves slots and writes index words — never
// retains or releases.
static void map_reindex_to(BMap* m, long long kind, long long (*hf)(long long),
                           long long reserve) {
    if (m->deadbits) {
        long long w = 0;
        for (long long p = 0; p < m->used; p++) {
            if (MAP_DEAD(m, p)) continue;
            if (w != p) {
                m->data[w * 2] = m->data[p * 2];
                m->data[w * 2 + 1] = m->data[p * 2 + 1];
                if (m->wide_values)
                    memcpy(map_wide_value(m, w), map_wide_value(m, p),
                           (size_t)m->value_stride);
            }
            w += 1;
        }
        rt_free(m->deadbits);
        m->deadbits = NULL;
        m->used = w; // == m->len
    }
    long long wanted = m->len > reserve ? m->len : reserve;
    long long cap = 16;
    while (wanted * 3 >= cap * 2) cap <<= 1;
    rt_free(m->idx);
    m->idx = rt_zalloc((unsigned long long)((size_t)cap) * (8));
    m->icap = cap;
    m->tombs = 0;
    unsigned long long mask = (unsigned long long)cap - 1;
    for (long long p = 0; p < m->len; p++) {
        unsigned long long h = slot_hash(m->data[p * 2], kind, hf);
        unsigned long long i = h & mask;
        while (m->idx[i] & IDX_POS) i = (i + 1) & mask;
        m->idx[i] = (h & IDX_FRAG) | (unsigned long long)(p + 2);
    }
}
static void map_reindex(BMap* m, long long kind, long long (*hf)(long long)) {
    map_reindex_to(m, kind, hf, 0);
}
void beans_map_reserve(BMap* m, long long capacity, long long kind, void* hash,
                       long long line, long long col) {
    if (capacity < 0) {
        char b[64];
        rt_format(b, sizeof b, "negative reserve capacity %lld", capacity);
        beans_panic(b, line, col);
    }
    if (capacity > (1LL << 58)) beans_panic("reserve capacity too large", line, col);
    if (capacity > m->cap) {
        long long cap = m->cap;
        while (cap < capacity && cap <= (1LL << 59)) cap *= 2;
        if (cap < capacity) cap = capacity;
        m->data = rt_realloc(m->data, (size_t)cap * 16);
        if (!m->data) beans_panic("out of memory", line, col);
        if (m->wide_values) {
            m->wide_values = rt_realloc(m->wide_values,
                                     (size_t)cap * (size_t)m->value_stride);
            if (!m->wide_values) beans_panic("out of memory", line, col);
        }
        if (m->deadbits) {
            long long old_words = (m->cap + 63) >> 6;
            long long new_words = (cap + 63) >> 6;
            m->deadbits = rt_realloc(m->deadbits, (size_t)new_words * 8);
            memset(m->deadbits + old_words, 0,
                   (size_t)(new_words - old_words) * 8);
        }
        m->cap = cap;
    }
    map_reindex_to(m, kind, (long long (*)(long long))hash, capacity);
}
// keys compare with the same equality lattice as list search (slot_eq): raw,
// f64 value, string content, decimal value, structural thunk, never-equal.
// *hout is filled iff the index is active, so set can reuse it; *slot_out
// (may be NULL) gets the hit's index slot so remove can tombstone it O(1).
static long long map_find(BMap* m, long long key, long long kind, void* eq,
                          long long (*hf)(long long), unsigned long long* hout,
                          unsigned long long* slot_out) {
    if (!m->idx) {
        for (long long i = 0; i < m->len; i++) {
            if (slot_eq(m->data[i * 2], key, kind,
                        (long long (*)(long long, long long))eq)) return i;
        }
        return -1;
    }
    unsigned long long h = slot_hash(key, kind, hf);
    *hout = h;
    unsigned long long mask = (unsigned long long)m->icap - 1;
    unsigned long long frag = h & IDX_FRAG;
    unsigned long long first_tomb = ~0ULL;
    for (unsigned long long i = h & mask;; i = (i + 1) & mask) {
        unsigned long long w = m->idx[i];
        unsigned long long st = w & IDX_POS;
        if (st == 0) {
            if (slot_out) *slot_out = first_tomb != ~0ULL ? first_tomb : i;
            return -1;
        }
        if (st == 1 && first_tomb == ~0ULL) first_tomb = i;
        if (st >= 2 && (w & IDX_FRAG) == frag) {
            long long p = (long long)st - 2;
            if (slot_eq(m->data[p * 2], key, kind,
                        (long long (*)(long long, long long))eq)) {
                if (slot_out) *slot_out = i;
                return p;
            }
        }
    }
}
// Raw-slot keys (integers, bools, and identity keys) are the common map case.
// Keep their probe loop separate so every occupied bucket does not branch
// through the full equality/hash kind lattice.
static long long map_find_raw(BMap* m, long long key, unsigned long long* hout,
                              unsigned long long* slot_out) {
    if (!m->idx) {
        for (long long i = 0; i < m->len; i++) {
            if (m->data[i * 2] == key) return i;
        }
        return -1;
    }
    unsigned long long h = beans_mix64((unsigned long long)key);
    *hout = h;
    unsigned long long mask = (unsigned long long)m->icap - 1;
    unsigned long long frag = h & IDX_FRAG;
    unsigned long long first_tomb = ~0ULL;
    for (unsigned long long i = h & mask;; i = (i + 1) & mask) {
        unsigned long long w = m->idx[i];
        unsigned long long st = w & IDX_POS;
        if (st == 0) {
            if (slot_out) *slot_out = first_tomb != ~0ULL ? first_tomb : i;
            return -1;
        }
        if (st == 1 && first_tomb == ~0ULL) first_tomb = i;
        if (st >= 2 && (w & IDX_FRAG) == frag) {
            long long p = (long long)st - 2;
            if (m->data[p * 2] == key) {
                if (slot_out) *slot_out = i;
                return p;
            }
        }
    }
}

static void map_insert_miss(BMap* m, long long key, long long val,
                            unsigned long long h, long long kind,
                            long long (*hf)(long long),
                            unsigned long long insert_slot) {
    if (m->used == m->cap) {
        long long ow = (m->cap + 63) >> 6;
        m->cap *= 2;
        m->data = rt_realloc(m->data, (size_t)m->cap * 16);
        if (m->deadbits) {
            long long nw = (m->cap + 63) >> 6;
            m->deadbits = rt_realloc(m->deadbits, (size_t)nw * 8);
            memset(m->deadbits + ow, 0, (size_t)(nw - ow) * 8);
        }
    }
    m->data[m->used * 2] = key;
    m->data[m->used * 2 + 1] = val;
    m->used += 1;
    m->len += 1;
    if (!m->idx) {
        if (m->len > MAP_LINEAR_MAX) map_reindex(m, kind, hf);
    } else if ((m->used + m->tombs) * 3 >= m->icap * 2) {
        map_reindex(m, kind, hf);
    } else { // the miss probe already found the insertion slot
        if ((m->idx[insert_slot] & IDX_POS) == 1) m->tombs -= 1;
        m->idx[insert_slot] =
            (h & IDX_FRAG) | (unsigned long long)(m->used + 1);
    }
}

static void map_insert_miss_typed(BMap* m, long long key, void* value,
                                  unsigned long long h, long long kind,
                                  long long (*hf)(long long),
                                  unsigned long long insert_slot) {
    if (m->used == m->cap) {
        long long ow = (m->cap + 63) >> 6;
        m->cap *= 2;
        m->data = rt_realloc(m->data, (size_t)m->cap * 16);
        m->wide_values = rt_realloc(m->wide_values,
                                 (size_t)m->cap * (size_t)m->value_stride);
        if (!m->data || !m->wide_values) beans_panic("out of memory", 0, 0);
        if (m->deadbits) {
            long long nw = (m->cap + 63) >> 6;
            m->deadbits = rt_realloc(m->deadbits, (size_t)nw * 8);
            memset(m->deadbits + ow, 0, (size_t)(nw - ow) * 8);
        }
    }
    m->data[m->used * 2] = key;
    m->data[m->used * 2 + 1] = 0;
    memcpy(map_wide_value(m, m->used), value, (size_t)m->value_stride);
    m->used += 1;
    m->len += 1;
    if (!m->idx) {
        if (m->len > MAP_LINEAR_MAX) map_reindex(m, kind, hf);
    } else if ((m->used + m->tombs) * 3 >= m->icap * 2) {
        map_reindex(m, kind, hf);
    } else {
        if ((m->idx[insert_slot] & IDX_POS) == 1) m->tombs -= 1;
        m->idx[insert_slot] =
            (h & IDX_FRAG) | (unsigned long long)(m->used + 1);
    }
}

// note: the map owns key and value refs; the caller retains before calling
void beans_map_set(BMap* m, long long key, long long val, long long kind, void* eq,
                   void* hash) {
    long long (*hf)(long long) = (long long (*)(long long))hash;
    unsigned long long h = 0, slot = 0;
    long long i = map_find(m, key, kind, eq, hf, &h, &slot);
    if (i >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key); // duplicate key not stored
        if (flags & 2) beans_release((void*)m->data[i * 2 + 1]);
        m->data[i * 2 + 1] = val;
        if (kind == 4 && (flags & 1)) cc_possible_root(m);
        return;
    }
    map_insert_miss(m, key, val, h, kind, hf, slot);
    if (kind == 4) cc_possible_root(m);
}

__attribute__((always_inline)) void beans_map_set_raw(BMap* m, long long key,
                                                       long long val) {
    unsigned long long h = 0, slot = 0;
    long long i = map_find_raw(m, key, &h, &slot);
    if (i >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        if (flags & 2) beans_release((void*)m->data[i * 2 + 1]);
        m->data[i * 2 + 1] = val;
        return;
    }
    map_insert_miss(m, key, val, h, 0, NULL, slot);
}

void beans_map_set_typed(BMap* m, long long key, void* value, long long kind,
                         void* eq, void* hash) {
    long long (*hf)(long long) = (long long (*)(long long))hash;
    unsigned long long h = 0, slot = 0;
    long long i = map_find(m, key, kind, eq, hf, &h, &slot);
    if (i >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        map_release_wide_value(m, map_wide_value(m, i));
        memcpy(map_wide_value(m, i), value, (size_t)m->value_stride);
        if (m->value_cycle_mask || kind == 4) cc_possible_root(m);
        return;
    }
    map_insert_miss_typed(m, key, value, h, kind, hf, slot);
    if (m->value_cycle_mask || kind == 4) cc_possible_root(m);
}

__attribute__((always_inline)) void beans_map_set_typed_raw(BMap* m,
                                                             long long key,
                                                             void* value) {
    unsigned long long h = 0, slot = 0;
    long long i = map_find_raw(m, key, &h, &slot);
    if (i >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        map_release_wide_value(m, map_wide_value(m, i));
        memcpy(map_wide_value(m, i), value, (size_t)m->value_stride);
        if (m->value_cycle_mask) cc_possible_root(m);
        return;
    }
    map_insert_miss_typed(m, key, value, h, 0, NULL, slot);
    if (m->value_cycle_mask) cc_possible_root(m);
}

// One-probe lowering for `m[k] = m.get(k).or(0) + delta`. The incoming key
// carries an owned reference, just like map_set: a hit drops the duplicate and
// a miss transfers it into the map. Unsigned addition gives Beans' wrapping
// int behavior without signed-overflow UB in the C runtime.
void beans_map_add(BMap* m, long long key, long long delta, long long kind,
                   void* eq, void* hash) {
    long long (*hf)(long long) = (long long (*)(long long))hash;
    unsigned long long h = 0, slot = 0;
    long long i = map_find(m, key, kind, eq, hf, &h, &slot);
    if (i >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        m->data[i * 2 + 1] =
            (long long)((unsigned long long)m->data[i * 2 + 1] +
                        (unsigned long long)delta);
        return;
    }
    map_insert_miss(m, key, delta, h, kind, hf, slot);
}

__attribute__((always_inline)) void beans_map_add_raw(BMap* m, long long key,
                                                       long long delta) {
    unsigned long long h = 0, slot = 0;
    long long i = map_find_raw(m, key, &h, &slot);
    if (i >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        m->data[i * 2 + 1] =
            (long long)((unsigned long long)m->data[i * 2 + 1] +
                        (unsigned long long)delta);
        return;
    }
    map_insert_miss(m, key, delta, h, 0, NULL, slot);
}

long long beans_map_insert(BMap* m, long long key, long long val, long long kind,
                           void* eq, void* hash) {
    long long (*hf)(long long) = (long long (*)(long long))hash;
    unsigned long long h = 0, slot = 0;
    if (map_find(m, key, kind, eq, hf, &h, &slot) >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        if (flags & 2) beans_release((void*)val);
        return 0;
    }
    map_insert_miss(m, key, val, h, kind, hf, slot);
    if (kind == 4) cc_possible_root(m);
    return 1;
}

long long beans_map_insert_raw(BMap* m, long long key, long long val) {
    unsigned long long h = 0, slot = 0;
    if (map_find_raw(m, key, &h, &slot) >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        if (flags & 2) beans_release((void*)val);
        return 0;
    }
    map_insert_miss(m, key, val, h, 0, NULL, slot);
    return 1;
}

long long beans_map_insert_typed(BMap* m, long long key, void* value,
                                 long long kind, void* eq, void* hash) {
    long long (*hf)(long long) = (long long (*)(long long))hash;
    unsigned long long h = 0, slot = 0;
    if (map_find(m, key, kind, eq, hf, &h, &slot) >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        map_release_wide_value(m, value);
        return 0;
    }
    map_insert_miss_typed(m, key, value, h, kind, hf, slot);
    if (m->value_cycle_mask || kind == 4) cc_possible_root(m);
    return 1;
}

long long beans_map_insert_typed_raw(BMap* m, long long key, void* value) {
    unsigned long long h = 0, slot = 0;
    if (map_find_raw(m, key, &h, &slot) >= 0) {
        long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
        if (flags & 1) beans_release((void*)key);
        map_release_wide_value(m, value);
        return 0;
    }
    map_insert_miss_typed(m, key, value, h, 0, NULL, slot);
    if (m->value_cycle_mask) cc_possible_root(m);
    return 1;
}

__attribute__((always_inline)) BOpt beans_map_get_raw(BMap* m, long long key) {
    unsigned long long h = 0;
    long long i = map_find_raw(m, key, &h, NULL);
    return i >= 0 ? (BOpt){m->data[i * 2 + 1], 1} : (BOpt){0, 0};
}
long long beans_map_get_raw_out(BMap* m, long long key, long long* has_out) { BOpt o = beans_map_get_raw(m, key); *has_out = o.has; return o.val; }

long long beans_map_contains_raw(BMap* m, long long key) {
    unsigned long long h = 0;
    return map_find_raw(m, key, &h, NULL) >= 0;
}

long long beans_map_get(BMap* m, long long key, long long kind, long long* ok,
                        void* eq, void* hash) {
    unsigned long long h = 0;
    long long i = map_find(m, key, kind, eq, (long long (*)(long long))hash, &h, 0);
    *ok = i >= 0;
    return i >= 0 ? m->data[i * 2 + 1] : 0;
}
long long beans_map_get_typed(BMap* m, long long key, long long kind, void* out,
                              void* eq, void* hash) {
    unsigned long long h = 0;
    long long i = map_find(m, key, kind, eq, (long long (*)(long long))hash, &h, 0);
    if (i < 0) return 0;
    memcpy(out, map_wide_value(m, i), (size_t)m->value_stride);
    return 1;
}
long long beans_map_get_typed_raw(BMap* m, long long key, void* out) {
    unsigned long long h = 0;
    long long i = map_find_raw(m, key, &h, NULL);
    if (i < 0) return 0;
    memcpy(out, map_wide_value(m, i), (size_t)m->value_stride);
    return 1;
}
static long long map_remove_found(BMap* m, long long i,
                                  unsigned long long slot, long long kind,
                                  long long (*hf)(long long)) {
    long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
    if ((flags & 1) && m->data[i * 2]) beans_release((void*)m->data[i * 2]);
    if (m->wide_values) map_release_wide_value(m, map_wide_value(m, i));
    else if ((flags & 2) && m->data[i * 2 + 1])
        beans_release((void*)m->data[i * 2 + 1]);
    if (!m->idx) {
        if (m->ordered) {
            memmove(m->data + i * 2, m->data + (i + 1) * 2,
                    (size_t)(m->used - i - 1) * 16);
            if (m->wide_values)
                memmove(map_wide_value(m, i), map_wide_value(m, i + 1),
                        (size_t)(m->used - i - 1) * (size_t)m->value_stride);
        } else if (i != m->used - 1) {
            m->data[i * 2] = m->data[(m->used - 1) * 2];
            m->data[i * 2 + 1] = m->data[(m->used - 1) * 2 + 1];
            if (m->wide_values)
                memcpy(map_wide_value(m, i), map_wide_value(m, m->used - 1),
                       (size_t)m->value_stride);
        }
        if (m->wide_values)
            memset(map_wide_value(m, m->used - 1), 0, (size_t)m->value_stride);
        m->len -= 1;
        m->used -= 1;
        return 1;
    }
    if (!m->ordered) {
        long long last = m->used - 1;
        m->idx[slot] = 1;
        m->tombs += 1;
        if (i != last) {
            long long moved_key = m->data[last * 2];
            unsigned long long h = slot_hash(moved_key, kind, hf);
            unsigned long long mask = (unsigned long long)m->icap - 1;
            for (unsigned long long at = h & mask;; at = (at + 1) & mask) {
                unsigned long long state = m->idx[at] & IDX_POS;
                if (state == (unsigned long long)(last + 2)) {
                    m->idx[at] = (m->idx[at] & IDX_FRAG) |
                                 (unsigned long long)(i + 2);
                    break;
                }
            }
            m->data[i * 2] = m->data[last * 2];
            m->data[i * 2 + 1] = m->data[last * 2 + 1];
            if (m->wide_values)
                memcpy(map_wide_value(m, i), map_wide_value(m, last),
                       (size_t)m->value_stride);
        }
        m->data[last * 2] = 0;
        m->data[last * 2 + 1] = 0;
        if (m->wide_values)
            memset(map_wide_value(m, last), 0, (size_t)m->value_stride);
        m->len -= 1;
        m->used -= 1;
        if (m->tombs > m->len) map_reindex(m, kind, hf);
        return 1;
    }
    // indexed: zero the pair into a hole — no entry moves, so no index
    // position needs fixing and delete is O(1). Reindex compacts once
    // holes outnumber live entries, so the cost is amortized.
    m->data[i * 2] = 0;
    m->data[i * 2 + 1] = 0;
    if (m->wide_values)
        memset(map_wide_value(m, i), 0, (size_t)m->value_stride);
    if (!m->deadbits) m->deadbits = rt_zalloc((unsigned long long)((size_t)((m->cap + 63) >> 6)) * (8));
    m->deadbits[i >> 6] |= 1ULL << (i & 63);
    m->len -= 1;
    m->idx[slot] = 1; // map_find landed on the hit's slot
    m->tombs += 1;
    if (m->used > m->len * 2) map_reindex(m, kind, hf);
    return 1;
}
long long beans_map_remove(BMap* m, long long key, long long kind, void* eq,
                           void* hash) {
    long long (*hf)(long long) = (long long (*)(long long))hash;
    unsigned long long h = 0, slot = 0;
    long long i = map_find(m, key, kind, eq, hf, &h, &slot);
    return i < 0 ? 0 : map_remove_found(m, i, slot, kind, hf);
}
long long beans_map_remove_raw(BMap* m, long long key) {
    unsigned long long h = 0, slot = 0;
    long long i = map_find_raw(m, key, &h, &slot);
    return i < 0 ? 0 : map_remove_found(m, i, slot, 0, NULL);
}
BMap* beans_map_clone(BMap* m, long long kind, void* hash) {
    long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
    BMap* copy = m->wide_values
        ? beans_map_new_typed_value(flags & 1, m->value_stride,
                                    m->value_ptr_mask, m->value_cycle_mask,
                                    m->ordered)
        : beans_map_new(flags & 1, (flags >> 1) & 1, m->ordered);
    if (m->len > copy->cap) {
        copy->cap = m->len;
        copy->data = rt_realloc(copy->data, (size_t)copy->cap * 16);
        if (!copy->data) beans_panic("out of memory", 0, 0);
        if (copy->wide_values) {
            copy->wide_values = rt_realloc(copy->wide_values,
                                        (size_t)copy->cap *
                                            (size_t)copy->value_stride);
            if (!copy->wide_values) beans_panic("out of memory", 0, 0);
        }
    }
    for (long long i = 0; i < m->used; i++) {
        if (MAP_DEAD(m, i)) continue;
        long long key = m->data[i * 2];
        long long value = m->data[i * 2 + 1];
        if ((flags & 1) && key) beans_retain((void*)key);
        copy->data[copy->used * 2] = key;
        if (m->wide_values) {
            copy->data[copy->used * 2 + 1] = 0;
            memcpy(map_wide_value(copy, copy->used), map_wide_value(m, i),
                   (size_t)m->value_stride);
            map_retain_wide_value(copy, map_wide_value(copy, copy->used));
        } else {
            if ((flags & 2) && value) beans_retain((void*)value);
            copy->data[copy->used * 2 + 1] = value;
        }
        copy->used += 1;
        copy->len += 1;
    }
    if (copy->len > MAP_LINEAR_MAX)
        map_reindex(copy, kind, (long long (*)(long long))hash);
    return copy;
}
BList* beans_map_keys(BMap* m) {
    long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
    BList* l = beans_list_new(flags & 1);
    for (long long i = 0; i < m->used; i++) {
        if (MAP_DEAD(m, i)) continue;
        long long k = m->data[i * 2];
        if ((flags & 1) && k) beans_retain((void*)k);
        beans_list_push(l, k);
    }
    return l;
}
BList* beans_map_keys_typed(BMap* m, long long stride, long long ptr_mask) {
    if (stride <= 0 || stride > (1LL << 30))
        beans_panic("invalid map key size", 0, 0);
    BList* l = beans_list_new_typed(stride, ptr_mask);
    for (long long i = 0; i < m->used; i++) {
        if (MAP_DEAD(m, i)) continue;
        void* key = (void*)m->data[i * 2];
        for (int slot = 0; slot < RT_MASK_SLOTS && (ptr_mask >> slot); slot++) {
            if (!((ptr_mask >> slot) & 1)) continue;
            void* child = *(void**)RT_SLOT_AT(key, slot);
            if (child) beans_retain(child);
        }
        beans_list_push_typed(l, key);
    }
    return l;
}
BList* beans_map_values(BMap* m) {
    long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
    BList* l = m->wide_values
        ? beans_list_new_typed(m->value_stride, m->value_ptr_mask)
        : beans_list_new((flags >> 1) & 1);
    for (long long i = 0; i < m->used; i++) {
        if (MAP_DEAD(m, i)) continue;
        if (m->wide_values) {
            void* value = map_wide_value(m, i);
            map_retain_wide_value(m, value);
            beans_list_push_typed(l, value);
            continue;
        }
        long long v = m->data[i * 2 + 1];
        if ((flags & 2) && v) beans_retain((void*)v);
        beans_list_push(l, v);
    }
    return l;
}
void beans_map_clear(BMap* m) {
    long long flags = (head_of(m)->meta & CC_SHAPE) >> 3;
    // reverse, value before key: the interpreter's pair teardown runs members
    // last-first, entries back to front — observable once a deinit prints
    for (long long i = m->used; i-- > 0;) { // holes are zeroed: null-skip
        if (m->wide_values) map_release_wide_value(m, map_wide_value(m, i));
        else if ((flags & 2) && m->data[i * 2 + 1])
            beans_release((void*)m->data[i * 2 + 1]);
        if ((flags & 1) && m->data[i * 2]) beans_release((void*)m->data[i * 2]);
    }
    m->len = 0;
    m->used = 0;
    rt_free(m->deadbits);
    m->deadbits = NULL;
    rt_free(m->idx);
    m->idx = NULL;
    m->icap = 0;
    m->tombs = 0;
}

// element rendering matches the interpreter's display(): the kind code says
// how each slot turns into text (0 int, 1 f64, 2 str, 3 dec, 4 bool)
#if BEANS_RT_DECIMAL
char* beans_dec_str(struct BDec* a);
#endif
char* beans_list_join(BList* l, char* sep, long long kind) {
    long long sl = beans_slen(sep);
    char** parts = rt_alloc((size_t)(l->len ? l->len : 1) * sizeof(char*));
    long long total = 0;
    for (long long i = 0; i < l->len; i++) {
        long long v = l->data[i];
        char* s;
        if (kind == 2) {
            s = (char*)v;
        } else if (kind == 0) {
            s = beans_from_int(v);
        } else if (kind == 1) {
            double d;
            memcpy(&d, &v, 8);
            s = beans_from_float(d);
#if BEANS_RT_DECIMAL
        } else if (kind == 3) {
            s = beans_dec_str((struct BDec*)v);
#endif
        } else {
            s = beans_from_bool((int)v);
        }
        parts[i] = s;
        total += beans_slen(s);
        if (i) total += sl;
    }
    char* out = beans_alloc(total + 1, total << 3);
    char* w = out;
    for (long long i = 0; i < l->len; i++) {
        if (i) {
            memcpy(w, sep, (size_t)sl);
            w += sl;
        }
        long long n = beans_slen(parts[i]);
        memcpy(w, parts[i], (size_t)n);
        w += n;
        if (kind != 2) beans_release(parts[i]); // rendered copies are ours
    }
    rt_free(parts);
    return out;
}

// UTF-8 sequences, one string per character; a malformed lead or truncated
// tail comes through one byte at a time — byte slicing, no validation
BList* beans_str_chars(char* s) {
    long long len = beans_slen(s);
    BList* l = beans_list_new(1);
    long long i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)s[i];
        long long n = c < 0x80          ? 1
                      : (c >> 5) == 0x6 ? 2
                      : (c >> 4) == 0xE ? 3
                      : (c >> 3) == 0x1E ? 4
                                         : 1;
        if (i + n > len) {
            n = 1;
        } else {
            for (long long k = 1; k < n; k++) {
                if (((unsigned char)s[i + k] >> 6) != 0x2) {
                    n = 1;
                    break;
                }
            }
        }
        beans_list_push(l, (long long)str_make(s + i, n));
        i += n;
    }
    return l;
}
__attribute__((always_inline)) long long beans_str_count_chars(
    char* s, long long from, long long to, long long line, long long col) {
    long long len = beans_slen(s);
    if (from < 0 || to < from || to > len) {
        char m[112];
        rt_format(m, sizeof m, "character range %lld..%lld out of range (len %lld)",
                 from, to, len);
        beans_panic(m, line, col);
    }
    long long count = 0;
    for (long long i = from; i < to; count++) {
        unsigned char c = (unsigned char)s[i];
        long long n = c < 0x80           ? 1
                      : (c >> 5) == 0x6  ? 2
                      : (c >> 4) == 0xE  ? 3
                      : (c >> 3) == 0x1E ? 4
                                         : 1;
        if (i + n > to) {
            n = 1;
        } else {
            for (long long k = 1; k < n; k++) {
                if (((unsigned char)s[i + k] >> 6) != 0x2) {
                    n = 1;
                    break;
                }
            }
        }
        i += n;
    }
    return count;
}

// ---- display through per-type show fns (emitted by the compiler) ----
// show(slot) returns an owned string; we copy and release it per element
static char* show_join(BList* l, const char* sep, long long sl,
                       char* (*show)(long long), int brackets) {
    long long cap = 16, len = 0;
    char* buf = rt_alloc((size_t)cap);
    if (brackets) buf[len++] = '[';
    for (long long i = 0; i < l->len; i++) {
        char* s = show(l->data[i]);
        long long n = beans_slen(s);
        long long need = len + n + sl + 2;
        if (need > cap) {
            while (cap < need) cap *= 2;
            buf = rt_realloc(buf, (size_t)cap);
        }
        if (i) {
            memcpy(buf + len, sep, (size_t)sl);
            len += sl;
        }
        memcpy(buf + len, s, (size_t)n);
        len += n;
        beans_release(s);
    }
    if (brackets) buf[len++] = ']';
    char* out = str_make(buf, len);
    rt_free(buf);
    return out;
}
// ---- iterative show driver ----
// printing recursed on data depth (a 400k-link enum chain smashed the C
// stack); generated @bstep fns append their own text and PUSH child work
// instead of calling each other, and this driver drains the stack. Text
// items are borrowed (interned constants or C literals); scalar steps
// append their temporary and release it.
typedef struct {
    void* fn; // step fn, or null for a text item
    long long v;
    const char* text;
    long long tlen;
} BShowItem;
typedef struct BShowCtx {
    BShowItem* items;
    long long len, cap;
    char* out;
    long long olen, ocap;
} BShowCtx;
static void show_out(BShowCtx* c, const char* p, long long n) {
    if (c->olen + n + 1 > c->ocap) {
        c->ocap = (c->olen + n + 1) * 2 + 16;
        c->out = rt_realloc(c->out, (size_t)c->ocap);
    }
    memcpy(c->out + c->olen, p, (size_t)n);
    c->olen += n;
}
void beans_show_append(BShowCtx* c, char* s) { show_out(c, s, beans_slen(s)); }
static void show_push(BShowCtx* c, void* fn, long long v, const char* t, long long tn) {
    if (c->len == c->cap) {
        c->cap = c->cap ? c->cap * 2 : 32;
        c->items = rt_realloc(c->items, (size_t)c->cap * sizeof(BShowItem));
    }
    BShowItem it = {fn, v, t, tn};
    c->items[c->len++] = it;
}
void beans_show_push_val(BShowCtx* c, void* fn, long long v) {
    show_push(c, fn, v, NULL, 0);
}
void beans_show_push_lit(BShowCtx* c, char* s) {
    show_push(c, NULL, 0, s, beans_slen(s));
}
void beans_show_list_iter(BShowCtx* c, BList* l, void* elem_step) {
    show_out(c, "[", 1);
    show_push(c, NULL, 0, "]", 1);
    for (long long i = l->len; i-- > 1;) {
        show_push(c, elem_step, l->data[i], NULL, 0);
        show_push(c, NULL, 0, ", ", 2);
    }
    if (l->len > 0) show_push(c, elem_step, l->data[0], NULL, 0);
}
char* beans_show_run(void* fn, long long v) {
    BShowCtx c = {0, 0, 0, 0, 0, 0};
    show_push(&c, fn, v, NULL, 0);
    while (c.len > 0) {
        BShowItem it = c.items[--c.len];
        if (it.fn) ((void (*)(BShowCtx*, long long))it.fn)(&c, it.v);
        else show_out(&c, it.text, it.tlen);
    }
    char* r = str_make(c.out ? c.out : "", c.olen);
    rt_free(c.out);
    rt_free(c.items);
    return r;
}

char* beans_show_list(BList* l, char* (*show)(long long)) {
    return show_join(l, ", ", 2, show, 1);
}
char* beans_list_join_show(BList* l, char* sep, char* (*show)(long long)) {
    return show_join(l, sep, beans_slen(sep), show, 0);
}

// ---- string ops that build lists ----
BList* beans_str_split(char* s, char* sep) {
    BList* l = beans_list_new(1);
    long long n = beans_slen(s), m = beans_slen(sep);
    if (m == 0) { // no separator: the whole string, one piece
        beans_list_push(l, (long long)str_make(s, n));
        return l;
    }
    long long i = 0;
    for (long long j = str_search(s, n, sep, m, 0); j >= 0;
         j = str_search(s, n, sep, m, i)) {
        beans_list_push(l, (long long)str_make(s + i, j - i));
        i = j + m;
    }
    beans_list_push(l, (long long)str_make(s + i, n - i));
    return l;
}
BList* beans_str_lines(char* s) {
    BList* l = beans_list_new(1);
    long long n = beans_slen(s), i = 0;
    for (long long j = 0; j < n; j++) {
        if (s[j] == '\n') {
            beans_list_push(l, (long long)str_make(s + i, j - i));
            i = j + 1;
        }
    }
    // a trailing newline doesn't make an empty final line
    if (i < n) beans_list_push(l, (long long)str_make(s + i, n - i));
    return l;
}

// ---- Bytes: kind 2 with no element pointers — data freed, never walked ----
static BList* bytes_mk(long long n) {
    BList* b = beans_alloc(sizeof(BList), 2);
    long long cap = n < 8 ? 8 : n;
    b->data = rt_zalloc((unsigned long long)((size_t)cap) * (1));
    if (!b->data) beans_panic("out of memory", 0, 0);
    b->len = n;
    b->cap = cap;
    return b;
}
BList* beans_bytes_new(long long n, long long line, long long col) {
    if (n < 0) {
        char m[48];
        rt_format(m, sizeof m, "negative size %lld", n);
        beans_panic(m, line, col);
    }
    return bytes_mk(n);
}
BList* beans_bytes_from(char* s) {
    long long n = beans_slen(s);
    BList* b = bytes_mk(n);
    memcpy(b->data, s, (size_t)n);
    return b;
}
__attribute__((always_inline)) long long beans_bytes_len(BList* b) {
    return b->len;
}
long long beans_bytes_eq(BList* a, BList* b) {
    return a->len == b->len && memcmp(a->data, b->data, (size_t)a->len) == 0;
}

// unsigned LEB128 over the 64-bit two's-complement pattern (negatives take
// 10 bytes); crc32 is the IEEE polynomial, table-driven — builtins.cpp
// computes the identical table
static void bytes_grow(BList* b, long long need);
void beans_bytes_append_varint(BList* b, long long x) {
    unsigned long long v = (unsigned long long)x;
    while (v >= 0x80) {
        bytes_grow(b, b->len + 1);
        ((unsigned char*)b->data)[b->len++] = (unsigned char)(v | 0x80);
        v >>= 7;
    }
    bytes_grow(b, b->len + 1);
    ((unsigned char*)b->data)[b->len++] = (unsigned char)v;
}
long long beans_bytes_get_varint(BList* b, long long pos, long long line,
                                 long long col) {
    unsigned long long v = 0;
    long long shift = 0;
    long long i = pos < 0 ? b->len : pos;
    while (1) {
        if (pos < 0 || i >= b->len) {
            char m[96];
            rt_format(m, sizeof m, "varint read at %lld out of range (len %lld)", pos,
                     b->len);
            beans_panic(m, line, col);
        }
        if (shift >= 64) {
            char m[96];
            rt_format(m, sizeof m, "varint too long at %lld", pos);
            beans_panic(m, line, col);
        }
        unsigned char byte = ((unsigned char*)b->data)[i++];
        v |= (unsigned long long)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) break;
        shift += 7;
    }
    return (long long)v;
}
long long beans_bytes_varint_size(long long x) {
    unsigned long long v = (unsigned long long)x;
    long long n = 1;
    while (v >= 0x80) {
        v >>= 7;
        n++;
    }
    return n;
}
static unsigned int crc_table[256];
static int crc_ready = 0;
long long beans_bytes_crc32(BList* b, long long from, long long to, long long line,
                            long long col) {
    if (from < 0 || to < from || to > b->len) {
        char m[96];
        rt_format(m, sizeof m, "crc32 %lld..%lld out of range (len %lld)", from, to,
                 b->len);
        beans_panic(m, line, col);
    }
    if (!crc_ready) {
        for (unsigned int i = 0; i < 256; i++) {
            unsigned int c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            crc_table[i] = c;
        }
        crc_ready = 1;
    }
    unsigned int c = 0xFFFFFFFFu;
    for (long long i = from; i < to; i++) {
        c = crc_table[(c ^ ((unsigned char*)b->data)[i]) & 0xFF] ^ (c >> 8);
    }
    return (long long)(c ^ 0xFFFFFFFFu);
}
static void bytes_grow(BList* b, long long need) {
    if (need <= b->cap) return;
    long long cap = b->cap;
    while (cap < need) cap *= 2;
    b->data = rt_realloc(b->data, (size_t)cap);
    b->cap = cap;
}
void beans_bytes_resize(BList* b, long long n, long long line, long long col) {
    if (n < 0) {
        char m[48];
        rt_format(m, sizeof m, "negative size %lld", n);
        beans_panic(m, line, col);
    }
    bytes_grow(b, n);
    // regrown range reads as zero, like the interpreter's vector resize
    if (n > b->len) memset((char*)b->data + b->len, 0, (size_t)(n - b->len));
    b->len = n;
}
void beans_bytes_reserve(BList* b, long long n, long long line, long long col) {
    if (n < 0) {
        char m[64];
        rt_format(m, sizeof m, "negative reserve capacity %lld", n);
        beans_panic(m, line, col);
    }
    if (n > (1LL << 58)) beans_panic("reserve capacity too large", line, col);
    bytes_grow(b, n);
}
void beans_bytes_fill(BList* b, long long v) {
    memset(b->data, (int)(v & 255), (size_t)b->len);
}
static void bytes_oob(long long i, long long len, long long line, long long col) {
    char m[80];
    rt_format(m, sizeof m, "byte index %lld out of range (len %lld)", i, len);
    beans_panic(m, line, col);
}
__attribute__((always_inline)) long long beans_bytes_get(
    BList* b, long long i, long long line, long long col) {
    if (i < 0 || i >= b->len) bytes_oob(i, b->len, line, col);
    return (long long)((unsigned char*)b->data)[i];
}
void beans_bytes_set(BList* b, long long i, long long v, long long line, long long col) {
    if (i < 0 || i >= b->len) bytes_oob(i, b->len, line, col);
    ((unsigned char*)b->data)[i] = (unsigned char)(v & 255);
}
__attribute__((always_inline)) void beans_bytes_push(BList* b, long long v) {
    bytes_grow(b, b->len + 1);
    ((unsigned char*)b->data)[b->len++] = (unsigned char)v;
}
static void bytes_woob(const char* what, const char* op, long long pos, long long len,
                       long long line, long long col) {
    char m[96];
    rt_format(m, sizeof m, "%s %s at %lld out of range (len %lld)", what, op, pos, len);
    beans_panic(m, line, col);
}
static long long bytes_getw(BList* b, long long pos, long long w, const char* what,
                            long long line, long long col) {
    // pos > len - w, never pos + w > len: signed overflow on huge pos slips the
    // wrapped sum past the guard and the memcpy goes wild
    if (pos < 0 || w > b->len || pos > b->len - w) bytes_woob(what, "read", pos, b->len, line, col);
    return (long long)rt_load_le((char*)b->data + pos, (size_t)w);
}
static void bytes_putw(BList* b, long long pos, long long w, long long val,
                       const char* what, long long line, long long col) {
    if (pos < 0 || w > b->len || pos > b->len - w) bytes_woob(what, "write", pos, b->len, line, col);
    rt_store_le((char*)b->data + pos, (unsigned long long)val, (size_t)w);
}
long long beans_bytes_get_u8(BList* b, long long p, long long l, long long c) { return bytes_getw(b, p, 1, "u8", l, c); }
long long beans_bytes_get_u16(BList* b, long long p, long long l, long long c) { return bytes_getw(b, p, 2, "u16", l, c); }
long long beans_bytes_get_u32(BList* b, long long p, long long l, long long c) { return bytes_getw(b, p, 4, "u32", l, c); }
long long beans_bytes_get_u64(BList* b, long long p, long long l, long long c) { return bytes_getw(b, p, 8, "u64", l, c); }
__attribute__((always_inline)) long long beans_bytes_get_i64(
    BList* b, long long p, long long l, long long c) {
    return bytes_getw(b, p, 8, "i64", l, c);
}
void beans_bytes_put_u8(BList* b, long long p, long long v, long long l, long long c) { bytes_putw(b, p, 1, v, "u8", l, c); }
void beans_bytes_put_u16(BList* b, long long p, long long v, long long l, long long c) { bytes_putw(b, p, 2, v, "u16", l, c); }
void beans_bytes_put_u32(BList* b, long long p, long long v, long long l, long long c) { bytes_putw(b, p, 4, v, "u32", l, c); }
void beans_bytes_put_u64(BList* b, long long p, long long v, long long l, long long c) { bytes_putw(b, p, 8, v, "u64", l, c); }
void beans_bytes_put_i64(BList* b, long long p, long long v, long long l, long long c) { bytes_putw(b, p, 8, v, "i64", l, c); }
BList* beans_bytes_slice(BList* b, long long from, long long to, long long line,
                         long long col) {
    if (from < 0 || to < from || to > b->len) {
        char m[96];
        rt_format(m, sizeof m, "slice %lld..%lld out of range (len %lld)", from, to,
                 b->len);
        beans_panic(m, line, col);
    }
    BList* r = bytes_mk(to - from);
    memcpy(r->data, (char*)b->data + from, (size_t)(to - from));
    return r;
}
void beans_bytes_copy_from(BList* b, BList* src, long long at, long long line,
                           long long col) {
    if (at < 0 || src->len > b->len || at > b->len - src->len) {
        char m[96];
        rt_format(m, sizeof m, "copy of %lld bytes at %lld out of range (len %lld)",
                 src->len, at, b->len);
        beans_panic(m, line, col);
    }
    memcpy((char*)b->data + at, src->data, (size_t)src->len);
}
void beans_bytes_append(BList* b, BList* o) {
    bytes_grow(b, b->len + o->len);
    memcpy((char*)b->data + b->len, o->data, (size_t)o->len);
    b->len += o->len;
}
void beans_bytes_append_str(BList* b, char* s) {
    long long n = beans_slen(s);
    bytes_grow(b, b->len + n);
    memcpy((char*)b->data + b->len, s, (size_t)n);
    b->len += n;
}
__attribute__((always_inline)) void beans_bytes_append_i64(BList* b,
                                                            long long value) {
    bytes_grow(b, b->len + 8);
    // The byte format is fixed even when the compiler runs on a big-endian CPU.
    rt_store_le((char*)b->data + b->len, (unsigned long long)value, 8);
    b->len += 8;
}
__attribute__((always_inline)) void beans_bytes_append_range(
    BList* b, BList* source, long long from, long long to,
    long long line, long long col) {
    if (from < 0 || to < from || to > source->len) {
        char m[96];
        rt_format(m, sizeof m, "slice %lld..%lld out of range (len %lld)", from, to,
                 source->len);
        beans_panic(m, line, col);
    }
    long long count = to - from;
    long long at = b->len;
    bytes_grow(b, at + count);
    memmove((char*)b->data + at, (char*)source->data + from, (size_t)count);
    b->len += count;
}
char* beans_bytes_to_string(BList* b) {
    long long n = 0;
    while (n < b->len && ((char*)b->data)[n] != 0) n++; // strings are text
    return str_make((char*)b->data, n);
}
char* beans_bytes_to_string_full(BList* b) {
    return str_make((char*)b->data, b->len);
}

#if BEANS_RT_PROFILE >= BEANS_RT_FULL || BEANS_RT_WASI
// files, mmap, processes, shared memory and the directory walk: every one of
// these is an operating system service, and none of them exists below the full
// profile.

#if defined(_WIN32)
// MinGW's CRT speaks most of POSIX, but with systematic gaps this shim closes
// so the code below stays one story: 64-bit file offsets (plain off_t, lseek
// and stat are 32-bit there), positional IO (no pread/pwrite), advisory
// whole-file locks (no flock), and mapping (no sys/mman). Win32 handles come
// from _get_osfhandle; the CRT descriptor still owns the file. windows.h comes
// in with the hosted includes at the top of this file — the minimal profile
// needs it too — so only the filesystem's own header is added here.
#include <direct.h>
typedef struct _stati64 fs_stat_t;
#define fs_fstat(fd, st) _fstati64((fd), (st))
#define fs_lseek(fd, off, whence) _lseeki64((fd), (off), (whence))
// Every path below arrives as UTF-8 and leaves through a W function; the narrow
// CRT and Win32 entry points would decode it with the ANSI code page instead.
static int fs_stat(const char* path, fs_stat_t* st) {
    wchar_t* w = win_widen(path);
    if (!w) return (errno = ENOMEM, -1);
    int rc = _wstati64(w, st);
    free(w);
    return rc;
}
static int fs_mkdir_utf8(const char* path) {
    wchar_t* w = win_widen(path);
    if (!w) return (errno = ENOMEM, -1);
    int rc = _wmkdir(w);
    free(w);
    return rc;
}
#define fs_mkdir(p, mode) fs_mkdir_utf8(p)
#ifndef O_CLOEXEC
// same meaning on the other side of a spawn: the child does not inherit it
#define O_CLOEXEC _O_NOINHERIT
#endif
// Every file the runtime opens is binary: the CRT's text mode rewrites \n to
// \r\n on the way out and back on the way in, which changes what File.size
// reports versus what was written — the one-byte-per-line lie differential
// testing exists to catch.
#define FS_O_BINARY _O_BINARY
static int fs_win_errno(DWORD code) {
    switch (code) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND: return ENOENT;
        case ERROR_ACCESS_DENIED: return EACCES;
        case ERROR_ALREADY_EXISTS:
        case ERROR_FILE_EXISTS: return EEXIST;
        case ERROR_DIR_NOT_EMPTY: return ENOTEMPTY;
        case ERROR_LOCK_VIOLATION: return EWOULDBLOCK;
        default: return EIO;
    }
}
// POSIX pread/pwrite leave the file position alone. A synchronous Win32
// handle moves its position even when the OVERLAPPED offset names one, so
// both shims save and restore it — without this, a positional read is
// observable through tell().
static rt_ssize_t fs_pread(int fd, void* buf, size_t n, long long pos) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    LARGE_INTEGER zero, before;
    zero.QuadPart = 0;
    int have_pos = SetFilePointerEx(h, zero, &before, FILE_CURRENT);
    OVERLAPPED o;
    memset(&o, 0, sizeof o);
    o.Offset = (DWORD)(pos & 0xffffffffu);
    o.OffsetHigh = (DWORD)((unsigned long long)pos >> 32);
    DWORD got = 0;
    BOOL ok = ReadFile(h, buf, (DWORD)n, &got, &o);
    DWORD e = ok ? 0 : GetLastError();
    if (have_pos) SetFilePointerEx(h, before, NULL, FILE_BEGIN);
    if (!ok) {
        if (e == ERROR_HANDLE_EOF) return 0;
        errno = fs_win_errno(e);
        return -1;
    }
    return (rt_ssize_t)got;
}
static rt_ssize_t fs_pwrite(int fd, const void* buf, size_t n, long long pos) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    LARGE_INTEGER zero, before;
    zero.QuadPart = 0;
    int have_pos = SetFilePointerEx(h, zero, &before, FILE_CURRENT);
    OVERLAPPED o;
    memset(&o, 0, sizeof o);
    o.Offset = (DWORD)(pos & 0xffffffffu);
    o.OffsetHigh = (DWORD)((unsigned long long)pos >> 32);
    DWORD put = 0;
    BOOL ok = WriteFile(h, buf, (DWORD)n, &put, &o);
    DWORD e = ok ? 0 : GetLastError();
    if (have_pos) SetFilePointerEx(h, before, NULL, FILE_BEGIN);
    if (!ok) {
        errno = fs_win_errno(e);
        return -1;
    }
    return (rt_ssize_t)put;
}
static int fs_fsync(int fd) {
    if (!FlushFileBuffers((HANDLE)_get_osfhandle(fd))) {
        errno = fs_win_errno(GetLastError());
        return -1;
    }
    return 0;
}
static int fs_ftruncate(int fd, long long n) {
    // POSIX ftruncate never moves the file position, even when it now points
    // past the end; _chsize_s clamps it to the new size. Save and restore.
    long long before = _lseeki64(fd, 0, SEEK_CUR);
    int e = _chsize_s(fd, n);
    if (e != 0) {
        errno = e;
        return -1;
    }
    if (before >= 0) _lseeki64(fd, before, SEEK_SET);
    return 0;
}
// The CRT's open() never grants FILE_SHARE_DELETE, which makes every open
// file undeletable — and removing a file that is still open (or mapped) is
// something POSIX programs do as a matter of course. Open through Win32 with
// the full sharing mask and wrap the handle in a CRT descriptor; every CRT
// operation (read, write, lseek, chsize) works on it unchanged.
static int fs_open(const char* path, int flags, int mode) {
    (void)mode; // Windows has no POSIX permission bits at creation
    DWORD access = 0;
    switch (flags & (_O_RDONLY | _O_WRONLY | _O_RDWR)) {
        case _O_RDONLY: access = GENERIC_READ; break;
        case _O_WRONLY: access = GENERIC_WRITE; break;
        default: access = GENERIC_READ | GENERIC_WRITE; break;
    }
    DWORD disposition = (flags & _O_CREAT) ? OPEN_ALWAYS : OPEN_EXISTING;
    wchar_t* wpath = win_widen(path);
    if (!wpath) return (errno = ENOMEM, -1);
    HANDLE h = CreateFileW(wpath, access,
                           FILE_SHARE_READ | FILE_SHARE_WRITE |
                               FILE_SHARE_DELETE,
                           NULL, disposition, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) {
        errno = fs_win_errno(GetLastError());
        return -1;
    }
    // _O_APPEND rides on the descriptor so the CRT keeps seeking to the end
    // before each write; the binary/noinherit flags are properties the handle
    // already has, but the CRT tracks them here too.
    int fd = _open_osfhandle((intptr_t)h,
                             (flags & (_O_APPEND | _O_RDONLY)) | _O_BINARY |
                                 _O_NOINHERIT);
    if (fd < 0) {
        CloseHandle(h);
        errno = EIO;
        return -1;
    }
    return fd;
}
#define fs_open_file(path, flags, mode) fs_open((path), (flags), (mode))
// POSIX unlink removes the name even while the file is open or mapped;
// DeleteFile leaves a delete-pending ghost whose name still answers
// exists(). The POSIX_SEMANTICS disposition (Windows 10 1607+, NTFS, and
// implemented by Wine) removes the name immediately; plain unlink stays the
// fallback for filesystems without it, with the ghost as its documented cost.
static int fs_unlink_posix(const char* path) {
    wchar_t* wpath = win_widen(path);
    if (!wpath) return (errno = ENOMEM, -1);
    HANDLE h = CreateFileW(wpath, DELETE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE |
                               FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        errno = fs_win_errno(GetLastError());
        free(wpath);
        return -1;
    }
    // Ubuntu's mingw-w64 headers predate the Ex disposition class, so the
    // ABI facts are stated here: information class 21, one DWORD of flags,
    // DELETE = 0x1, POSIX_SEMANTICS = 0x2. These are contractual Win32
    // values, not guesses.
    struct {
        DWORD Flags;
    } dx;
    dx.Flags = 0x1 | 0x2;
    BOOL ok = SetFileInformationByHandle(h, (FILE_INFO_BY_HANDLE_CLASS)21,
                                         &dx, sizeof dx);
    CloseHandle(h);
    if (ok) {
        free(wpath);
        return 0;
    }
    // Wine and pre-1607 Windows lack that class. Renaming an open file is
    // allowed under FILE_SHARE_DELETE, so the caller's name disappears right
    // now — the observable POSIX fact — and the ghost, marked delete-pending
    // under its side name, vanishes when the last handle closes.
    size_t wlen = wcslen(wpath);
    wchar_t* side = malloc((wlen + 48) * sizeof(wchar_t));
    if (side) {
        static volatile long fs_del_counter;
        _snwprintf(side, wlen + 48, L"%ls.beans_del_%lu_%ld", wpath,
                   (unsigned long)GetCurrentProcessId(),
                   (long)InterlockedIncrement(&fs_del_counter));
        if (MoveFileExW(wpath, side, 0)) {
            DeleteFileW(side); // best-effort; the pending delete rides the handles
            free(side);
            free(wpath);
            return 0;
        }
        free(side);
    }
    int rc = _wunlink(wpath);
    free(wpath);
    return rc;
}
// No lstat in the CRT, and stat follows reparse points. The attributes tell
// the link itself apart, which is the only lstat semantic the walk and remove
// rely on: a link is its own entry and is never descended.
static int fs_link_kind(const char* path, int* is_dir, int* is_link) {
    wchar_t* w = win_widen(path);
    if (!w) return (errno = ENOMEM, -1);
    DWORD a = GetFileAttributesW(w);
    free(w);
    if (a == INVALID_FILE_ATTRIBUTES) {
        errno = fs_win_errno(GetLastError());
        return -1;
    }
    *is_link = (a & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
    *is_dir = (a & FILE_ATTRIBUTE_DIRECTORY) != 0;
    return 0;
}
static int fs_flock_ex(int fd, int nonblock) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    OVERLAPPED o;
    memset(&o, 0, sizeof o);
    DWORD flags = LOCKFILE_EXCLUSIVE_LOCK |
                  (nonblock ? LOCKFILE_FAIL_IMMEDIATELY : 0);
    if (!LockFileEx(h, flags, 0, MAXDWORD, MAXDWORD, &o)) {
        errno = fs_win_errno(GetLastError());
        return -1;
    }
    return 0;
}
static int fs_flock_un(int fd) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    OVERLAPPED o;
    memset(&o, 0, sizeof o);
    if (!UnlockFileEx(h, 0, MAXDWORD, MAXDWORD, &o)) {
        errno = fs_win_errno(GetLastError());
        return -1;
    }
    return 0;
}
// Where the file-backed shared-memory emulation keeps its objects: the temp
// directory, named beans_shm_<name>. Both open and unlink build the path the
// same way, which is what makes unlink-then-reopen behave like POSIX.
static int fs_shm_path(char* out, size_t cap, const char* name) {
    wchar_t wtmp[MAX_PATH];
    DWORD n = GetTempPathW((DWORD)(sizeof wtmp / sizeof wtmp[0]), wtmp);
    if (n == 0 || n >= sizeof wtmp / sizeof wtmp[0]) return -1;
    // The rest of the runtime speaks UTF-8 paths, so it comes straight back.
    char* tmp = win_narrow(wtmp);
    if (!tmp) return -1;
    // GetTempPath ends with a separator already.
    int wrote = snprintf(out, cap, "%sbeans_shm_%s", tmp,
                         name[0] == '/' ? name + 1 : name);
    free(tmp);
    return wrote > 0 && (size_t)wrote < cap ? 0 : -1;
}
// A direct wide Win32 directory iterator works with both LLVM-MinGW and MSVC.
// It also avoids dirent's ANSI-code-page wrappers, which cannot name every file.
typedef struct {
    HANDLE handle;
    WIN32_FIND_DATAW data;
    int first;
    char* name;
} fs_dir_t;
static fs_dir_t* fs_dir_open(const char* path) {
    wchar_t* w = win_widen(path);
    if (!w) {
        errno = ENOMEM;
        return NULL;
    }
    size_t n = wcslen(w);
    wchar_t* pattern = malloc((n + 3) * sizeof(wchar_t));
    if (!pattern) {
        free(w);
        errno = ENOMEM;
        return NULL;
    }
    memcpy(pattern, w, n * sizeof(wchar_t));
    if (n && w[n - 1] != L'/' && w[n - 1] != L'\\') pattern[n++] = L'\\';
    pattern[n++] = L'*';
    pattern[n] = 0;
    free(w);
    fs_dir_t* it = calloc(1, sizeof *it);
    if (!it) {
        free(pattern);
        errno = ENOMEM;
        return NULL;
    }
    it->handle = FindFirstFileW(pattern, &it->data);
    free(pattern);
    if (it->handle == INVALID_HANDLE_VALUE) {
        errno = fs_win_errno(GetLastError());
        free(it);
        return NULL;
    }
    it->first = 1;
    return it;
}
static const char* fs_dir_next(fs_dir_t* it) {
    if (it->first) {
        it->first = 0;
    } else if (!FindNextFileW(it->handle, &it->data)) {
        return NULL;
    }
    free(it->name);
    it->name = win_narrow(it->data.cFileName);
    return it->name;
}
static void fs_dir_close(fs_dir_t* it) {
    if (!it) return;
    FindClose(it->handle);
    free(it->name);
    free(it);
}

// A view keeps its file mapping alive, so the mapping handle closes right
// after MapViewOfFile and BMMap stays the same struct on every platform.
static void* fs_map_fd(int fd, long long len, int writable) {
    HANDLE h = (HANDLE)_get_osfhandle(fd);
    HANDLE m = CreateFileMappingW(
        h, NULL, writable ? PAGE_READWRITE : PAGE_READONLY, 0, 0, NULL);
    if (!m) {
        errno = fs_win_errno(GetLastError());
        return NULL;
    }
    void* p = MapViewOfFile(m, writable ? FILE_MAP_WRITE : FILE_MAP_READ, 0,
                            0, (SIZE_T)len);
    CloseHandle(m);
    if (!p) {
        errno = fs_win_errno(GetLastError());
        return NULL;
    }
    return p;
}
#else
typedef struct stat fs_stat_t;
#define fs_stat(p, st) stat((p), (st))
#define fs_fstat(fd, st) fstat((fd), (st))
#define fs_lseek(fd, off, whence) lseek((fd), (off), (whence))
#define fs_mkdir(p, mode) mkdir((p), (mode))
#define fs_pread(fd, buf, n, pos) pread((fd), (buf), (n), (off_t)(pos))
#define fs_pwrite(fd, buf, n, pos) pwrite((fd), (buf), (n), (off_t)(pos))
#define fs_fsync(fd) fsync(fd)
#define fs_ftruncate(fd, n) ftruncate((fd), (off_t)(n))
#define FS_O_BINARY 0
#define fs_open_file(path, flags, mode) open((path), (flags), (mode))
// The same three-call directory walk the Windows shim above provides; here it
// is readdir with its own buffer, so the name's lifetime already matches.
typedef DIR fs_dir_t;
static fs_dir_t* fs_dir_open(const char* path) { return opendir(path); }
static const char* fs_dir_next(fs_dir_t* it) {
    struct dirent* en = readdir(it);
    return en ? en->d_name : NULL;
}
static void fs_dir_close(fs_dir_t* it) {
    if (it) closedir(it);
}
#endif

// ---- files (kind 6 resources) -----------------------------------------------
// errno -> Error.kind slug; the interpreter builds the identical pair
static const char* fs_kind_of(int err) {
    switch (err) {
        case ENOENT: return "not_found";
        case EACCES:
        case EPERM: return "permission";
        case EEXIST: return "exists";
        case ENOTDIR: return "not_dir";
        case EISDIR: return "is_dir";
        case ENOTEMPTY: return "not_empty";
        default: return "io";
    }
}
static void* fs_err_obj(const char* path, int err) {
    size_t n = strlen(path) + 96;
    char* b = malloc(n);
    snprintf(b, n, "%s: %s", path, strerror(err));
    void* e = mk_error(b, fs_kind_of(err));
    free(b);
    return e;
}
// for paths that are beans strings: splice by stored length so a path with
// an embedded NUL reports the same bytes the interpreter does (the plain
// fs_err_obj above stays for internal C-built paths, which never hold NUL)
static void* fs_err_obj_rc(char* path, int err) {
    const char* es = strerror(err);
    long long lp = beans_slen(path);
    size_t le = strlen(es);
    long long total = lp + 2 + (long long)le;
    char* m = beans_alloc(total + 1, total << 3);
    memcpy(m, path, (size_t)lp);
    m[lp] = ':';
    m[lp + 1] = ' ';
    memcpy(m + lp + 2, es, le);
    return mk_error_own(m, fs_kind_of(err));
}
static void* op_err_obj(const char* op, int err) {
    char b[96];
    snprintf(b, sizeof b, "%s: %s", op, strerror(err));
    return mk_error(b, fs_kind_of(err));
}
static void* closed_err(void) { return mk_error("file is closed", "closed"); }

BRes beans_file_read_at(BFile* f, long long pos, long long n) {
    if (f->closed) return (BRes){0, closed_err()};
    if (pos < 0 || n < 0) return (BRes){0, mk_error("negative read", "io")};
    // clamp to what the file can actually give: a corrupted length field must
    // not become a giant allocation — the read comes back short anyway
    fs_stat_t rst;
    if (fs_fstat((int)f->fd, &rst) == 0 && S_ISREG(rst.st_mode)) {
        long long rem = rst.st_size > pos ? rst.st_size - pos : 0;
        if (n > rem) n = rem;
    }
    BList* buf = bytes_mk(n);
    long long got = 0;
    while (got < n) {
        rt_ssize_t r = fs_pread((int)f->fd, (char*)buf->data + got,
                             (size_t)(n - got), pos + got);
        if (r < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            beans_release(buf); // the error path must not leak the buffer
            return (BRes){0, op_err_obj("read", e)};
        }
        if (r == 0) break; // eof: a short read returns what's there
        got += r;
    }
    buf->len = got;
    return (BRes){(long long)buf, NULL};
}
long long beans_file_read_at_out(BFile* f, long long pos, long long n, void** e_out) { BRes r = beans_file_read_at(f, pos, n); *e_out = r.err; return r.val; }
BRes beans_file_write_at(BFile* f, long long pos, BList* d) {
    if (f->closed) return (BRes){0, closed_err()};
    if (pos < 0) return (BRes){0, mk_error("negative write", "io")};
    long long done = 0;
    while (done < d->len) {
        rt_ssize_t r = fs_pwrite((int)f->fd, (char*)d->data + done,
                              (size_t)(d->len - done), pos + done);
        if (r < 0) {
            if (errno == EINTR) continue;
            return (BRes){0, op_err_obj("write", errno)};
        }
        done += r;
    }
    return (BRes){done, NULL};
}
long long beans_file_write_at_out(BFile* f, long long pos, BList* d, void** e_out) { BRes r = beans_file_write_at(f, pos, d); *e_out = r.err; return r.val; }
BRes beans_file_read(BFile* f, long long n) {
    if (f->closed) return (BRes){0, closed_err()};
    if (n < 0) return (BRes){0, mk_error("negative read", "io")};
    fs_stat_t rst;
    if (fs_fstat((int)f->fd, &rst) == 0 && S_ISREG(rst.st_mode)) {
        long long at = (long long)fs_lseek((int)f->fd, 0, SEEK_CUR);
        long long rem = at >= 0 && rst.st_size > at ? rst.st_size - at : 0;
        if (n > rem) n = rem;
    }
    BList* buf = bytes_mk(n);
    long long got = 0;
    while (got < n) {
        rt_ssize_t r = read((int)f->fd, (char*)buf->data + got, (size_t)(n - got));
        if (r < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            beans_release(buf); // the error path must not leak the buffer
            return (BRes){0, op_err_obj("read", e)};
        }
        if (r == 0) break;
        got += r;
    }
    buf->len = got;
    return (BRes){(long long)buf, NULL};
}
long long beans_file_read_out(BFile* f, long long n, void** e_out) { BRes r = beans_file_read(f, n); *e_out = r.err; return r.val; }
BRes beans_file_write(BFile* f, BList* d) {
    if (f->closed) return (BRes){0, closed_err()};
    long long done = 0;
    while (done < d->len) {
        rt_ssize_t r = write((int)f->fd, (char*)d->data + done, (size_t)(d->len - done));
        if (r < 0) {
            if (errno == EINTR) continue;
            return (BRes){0, op_err_obj("write", errno)};
        }
        done += r;
    }
    return (BRes){done, NULL};
}
long long beans_file_write_out(BFile* f, BList* d, void** e_out) { BRes r = beans_file_write(f, d); *e_out = r.err; return r.val; }
long long beans_file_seek(BFile* f, long long pos, long long line, long long col) {
    if (f->closed) beans_panic("file is closed", line, col);
    long long r = (long long)fs_lseek((int)f->fd, pos, SEEK_SET);
    if (r < 0) {
        char m[96];
        snprintf(m, sizeof m, "seek to %lld: %s", pos, strerror(errno));
        beans_panic(m, line, col);
    }
    return (long long)r;
}
long long beans_file_seek_end(BFile* f, long long off, long long line, long long col) {
    if (f->closed) beans_panic("file is closed", line, col);
    long long r = (long long)fs_lseek((int)f->fd, off, SEEK_END);
    if (r < 0) {
        char m[96];
        snprintf(m, sizeof m, "seek to %lld: %s", off, strerror(errno));
        beans_panic(m, line, col);
    }
    return (long long)r;
}
long long beans_file_tell(BFile* f, long long line, long long col) {
    if (f->closed) beans_panic("file is closed", line, col);
    return (long long)fs_lseek((int)f->fd, 0, SEEK_CUR);
}
BRes beans_file_size(BFile* f) {
    if (f->closed) return (BRes){0, closed_err()};
    fs_stat_t st;
    if (fs_fstat((int)f->fd, &st) != 0) return (BRes){0, op_err_obj("size", errno)};
    return (BRes){(long long)st.st_size, NULL};
}
long long beans_file_size_out(BFile* f, void** e_out) { BRes r = beans_file_size(f); *e_out = r.err; return r.val; }
BRes beans_file_truncate(BFile* f, long long n) {
    if (f->closed) return (BRes){0, closed_err()};
    if (fs_ftruncate((int)f->fd, n) != 0) {
        return (BRes){0, op_err_obj("truncate", errno)};
    }
    return (BRes){1, NULL};
}
long long beans_file_truncate_out(BFile* f, long long n, void** e_out) { BRes r = beans_file_truncate(f, n); *e_out = r.err; return r.val; }
BRes beans_file_sync(BFile* f) {
    if (f->closed) return (BRes){0, closed_err()};
    if (fs_fsync((int)f->fd) != 0) return (BRes){0, op_err_obj("sync", errno)};
    return (BRes){1, NULL};
}
long long beans_file_sync_out(BFile* f, void** e_out) { BRes r = beans_file_sync(f); *e_out = r.err; return r.val; }
BRes beans_file_close(BFile* f) {
    if (f->closed) return (BRes){0, mk_error("file already closed", "closed")};
    f->closed = 1;
    // While worker threads are live, defer the real close(): a racing op on
    // another thread could still be mid-syscall on this fd, and reusing the
    // number for a freshly-opened file would silently corrupt it. The fd stays
    // open (harmless — same file) until the handle's last ref drops in
    // cc_free_shell, when no thread can hold it. This mirrors the collector's
    // own "don't touch shared resources while mutators run" gate. Zero cost
    // single-threaded, where cc_threads is 0 and the fd closes now.
#if BEANS_RT_PROFILE >= BEANS_RT_FULL
    beans_reactor_note_close(f->fd);
#endif
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
    if (cc_threads > 0) return (BRes){1, NULL};
#endif
    long long fd = f->fd;
    f->fd = -1;
    if (close((int)fd) != 0) return (BRes){0, op_err_obj("close", errno)};
    return (BRes){1, NULL};
}
long long beans_file_close_out(BFile* f, void** e_out) { BRes r = beans_file_close(f); *e_out = r.err; return r.val; }

// advisory flock — single-writer databases; try_lock's ok(false) means "held
// by someone else", every other failure is a real error
BRes beans_file_lock(BFile* f) {
    if (f->closed) return (BRes){0, closed_err()};
#if BEANS_RT_WASI
    return (BRes){0, mk_error("file locks are not available in WASIp1",
                              "unsupported")};
#elif defined(_WIN32)
    if (fs_flock_ex((int)f->fd, 0) != 0)
        return (BRes){0, op_err_obj("lock", errno)};
    return (BRes){1, NULL};
#else
    // a blocking lock is the classic EINTR victim — retry rather than fail
    while (flock((int)f->fd, LOCK_EX) != 0) {
        if (errno == EINTR) continue;
        return (BRes){0, op_err_obj("lock", errno)};
    }
    return (BRes){1, NULL};
#endif
}
long long beans_file_lock_out(BFile* f, void** e_out) { BRes r = beans_file_lock(f); *e_out = r.err; return r.val; }
BRes beans_file_try_lock(BFile* f) {
    if (f->closed) return (BRes){0, closed_err()};
#if BEANS_RT_WASI
    return (BRes){0, mk_error("file locks are not available in WASIp1",
                              "unsupported")};
#elif defined(_WIN32)
    if (fs_flock_ex((int)f->fd, 1) != 0) {
        if (errno == EWOULDBLOCK) return (BRes){0, NULL};
        return (BRes){0, op_err_obj("try_lock", errno)};
    }
    return (BRes){1, NULL};
#else
    if (flock((int)f->fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) return (BRes){0, NULL};
        return (BRes){0, op_err_obj("try_lock", errno)};
    }
    return (BRes){1, NULL};
#endif
}
long long beans_file_try_lock_out(BFile* f, void** e_out) { BRes r = beans_file_try_lock(f); *e_out = r.err; return r.val; }
BRes beans_file_unlock(BFile* f) {
    if (f->closed) return (BRes){0, closed_err()};
#if BEANS_RT_WASI
    return (BRes){0, mk_error("file locks are not available in WASIp1",
                              "unsupported")};
#elif defined(_WIN32)
    if (fs_flock_un((int)f->fd) != 0)
        return (BRes){0, op_err_obj("unlock", errno)};
    return (BRes){1, NULL};
#else
    if (flock((int)f->fd, LOCK_UN) != 0) return (BRes){0, op_err_obj("unlock", errno)};
    return (BRes){1, NULL};
#endif
}
long long beans_file_unlock_out(BFile* f, void** e_out) { BRes r = beans_file_unlock(f); *e_out = r.err; return r.val; }

#if !BEANS_RT_WASI
// ---- mmap (kind 6, shape bit 0 = 1) ----
// whole-file shared mapping; the fd is kept open so resize() can ftruncate +
// remap. get/put/read/write panic on a closed or short map, flush/close
// report errors as Results like File does.
static void* mmap_closed_err(void) { return mk_error("mmap is closed", "closed"); }
// ---- running a program ------------------------------------------------------
//
// One primitive that spawns, feeds stdin, drains both output streams, waits and reaps.
// Doing all of it in one place is what makes the deadlock impossible: the classic bug
// is a parent that reads stdout to EOF while the child blocks writing stderr, and the
// only fix is to watch every descriptor at once. POSIX watches them with `poll`;
// Windows cannot poll an anonymous pipe, so its branch gets the same property from
// one drain thread per output stream.
//
// No shell, on either platform. POSIX argv reaches execvp untouched. Windows has no
// argv — CreateProcess takes one command line — so proc_win_cmdline rebuilds it under
// exactly the rules the child's CRT uses to split it again, and the round trip is
// byte-for-byte. Either way a filename containing a space, a quote or a semicolon is
// just a filename.
//
// Layout of argv/env: NUL-separated strings inside a Bytes, terminated by the end of
// the buffer. Chosen over a List<string> parameter because a NUL can never appear in a
// path or an environment entry, so the encoding cannot be ambiguous.
//
// The result is one Bytes because the fallible-builtin ABI returns a single value:
//   [i64 status][i64 out_len][i64 err_len][stdout bytes][stderr bytes]
// The Beans side decodes it. `status` is the exit code, or -(signal) when the child was
// killed by a signal, which keeps the two distinguishable without a second field.
// Windows has no signal to negate: beans_proc_signal terminates the child with exit
// code (unsigned)-(number) and status sign-extends what GetExitCodeProcess returns, so
// a child stopped from Beans still reports -(number), a crash's NTSTATUS (0xC…) lands
// negative too, and "negative means it did not choose to exit" survives the port.

// Splits a NUL-separated Bytes into a NULL-terminated argv array. The strings point
// into the buffer, so it must outlive the call.
static char** proc_split(BList* packed, int* count_out) {
    long long len = packed ? packed->len : 0;
    const char* data = packed ? (const char*)packed->data : "";
    int count = 0;
    for (long long i = 0; i < len; i++)
        if (data[i] == 0) count++;
    char** out = calloc((size_t)count + 1, sizeof(char*));
    if (!out) return 0;
    int at = 0;
    long long start = 0;
    for (long long i = 0; i < len && at < count; i++) {
        if (data[i] != 0) continue;
        out[at++] = (char*)data + start;
        start = i + 1;
    }
    out[at] = 0;
    if (count_out) *count_out = at;
    return out;
}

#if !defined(_WIN32)
// Writes as much as the pipe will take without blocking. Returns bytes written, or -1
// on a real error; EAGAIN is not an error, it means "come back when poll says so".
static long long proc_push(int fd, const char* data, long long len, long long* done) {
    while (*done < len) {
        rt_ssize_t wrote = write(fd, data + *done, (size_t)(len - *done));
        if (wrote > 0) {
            *done += wrote;
            continue;
        }
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        return -1;
    }
    return 0;
}

BRes beans_proc_run(BList* argv_packed, BList* env_packed, char* cwd,
                    BList* input, long long max_output) {
    BRes bad;
    bad.val = 0;
    int argc = 0;
    char** argv = proc_split(argv_packed, &argc);
    if (!argv || argc == 0) {
        free(argv);
        bad.err = mk_error("a command needs at least a program name", "invalid");
        return bad;
    }
    int envc = 0;
    char** envp = env_packed && env_packed->len > 0 ? proc_split(env_packed, &envc) : 0;

    // Three pipes for the child's streams, plus a fourth that exists only to report an
    // exec failure. The exec pipe is the standard trick: it is close-on-exec, so a
    // successful exec closes it and the parent reads EOF, while a failed exec writes
    // errno into it. Without it a failed exec is indistinguishable from a program that
    // ran and exited non-zero.
    int in_fd[2] = {-1, -1}, out_fd[2] = {-1, -1}, err_fd[2] = {-1, -1}, exec_fd[2] = {-1, -1};
    if (pipe(in_fd) != 0 || pipe(out_fd) != 0 || pipe(err_fd) != 0 || pipe(exec_fd) != 0) {
        int e = errno;
        for (int i = 0; i < 2; i++) {
            if (in_fd[i] >= 0) close(in_fd[i]);
            if (out_fd[i] >= 0) close(out_fd[i]);
            if (err_fd[i] >= 0) close(err_fd[i]);
            if (exec_fd[i] >= 0) close(exec_fd[i]);
        }
        free(argv);
        free(envp);
        bad.err = fs_err_obj(argv_packed ? (const char*)argv_packed->data : "", e);
        return bad;
    }
    fcntl(exec_fd[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        for (int i = 0; i < 2; i++) {
            close(in_fd[i]); close(out_fd[i]); close(err_fd[i]); close(exec_fd[i]);
        }
        const char* program = argv[0];
        void* built = fs_err_obj(program, e);
        free(argv);
        free(envp);
        bad.err = built;
        return bad;
    }
    if (pid == 0) {
        // Child. Only async-signal-safe work here, and every failure is reported
        // through the exec pipe rather than by printing anything.
        dup2(in_fd[0], 0);
        dup2(out_fd[1], 1);
        dup2(err_fd[1], 2);
        close(in_fd[0]); close(in_fd[1]);
        close(out_fd[0]); close(out_fd[1]);
        close(err_fd[0]); close(err_fd[1]);
        close(exec_fd[0]);
        // Signal sources block what they watch, and that mask survives exec.
        // Clear it here just as beans_proc_start does, or a run child may start
        // with SIGTERM blocked and be impossible to stop.
        sigset_t none;
        sigemptyset(&none);
        pthread_sigmask(SIG_SETMASK, &none, NULL);
        if (cwd && cwd[0] && chdir(cwd) != 0) {
            int e = errno;
            rt_ssize_t ignored = write(exec_fd[1], &e, sizeof e);
            (void)ignored;
            _exit(127);
        }
        // Keep execvp's PATH search when the caller requested a fresh environment.
        // This assignment is in the forked child, so it cannot change the parent.
        if (envp) environ = envp;
        execvp(argv[0], argv);
        int e = errno;
        rt_ssize_t ignored = write(exec_fd[1], &e, sizeof e);
        (void)ignored;
        _exit(127);
    }

    // Parent.
    close(in_fd[0]);
    close(out_fd[1]);
    close(err_fd[1]);
    close(exec_fd[1]);

    // Did exec fail? The pipe is close-on-exec, so EOF means the program started.
    int child_errno = 0;
    rt_ssize_t got_errno = 0;
    do {
        got_errno = read(exec_fd[0], &child_errno, sizeof child_errno);
    } while (got_errno < 0 && errno == EINTR);
    close(exec_fd[0]);
    if (got_errno == (rt_ssize_t)sizeof child_errno) {
        // Reap before returning: a child that never ran still has to be collected.
        int discard = 0;
        while (waitpid(pid, &discard, 0) < 0 && errno == EINTR) {}
        close(in_fd[1]);
        close(out_fd[0]);
        close(err_fd[0]);
        // argv[0] points into the packed Bytes, so it is a plain C string, not a
        // beans rc string — fs_err_obj_rc would read a length from before it. ASan
        // caught exactly that.
        void* built = fs_err_obj(argv[0], child_errno);
        free(argv);
        free(envp);
        bad.err = built;
        return bad;
    }

    for (int fd = 0; fd < 3; fd++) {
        int target = fd == 0 ? in_fd[1] : fd == 1 ? out_fd[0] : err_fd[0];
        int flags = fcntl(target, F_GETFL, 0);
        if (flags >= 0) fcntl(target, F_SETFL, flags | O_NONBLOCK);
    }

    BList* out = bytes_mk(0);
    BList* err = bytes_mk(0);
    long long pushed = 0;
    long long input_len = input ? input->len : 0;
    const char* input_data = input ? (const char*)input->data : "";
    int in_open = 1, out_open = 1, err_open = 1;
    if (input_len == 0) { close(in_fd[1]); in_open = 0; }

    while (out_open || err_open || in_open) {
        struct pollfd watch[3];
        int n = 0;
        int in_slot = -1, out_slot = -1, err_slot = -1;
        if (in_open) { watch[n].fd = in_fd[1]; watch[n].events = POLLOUT; in_slot = n++; }
        if (out_open) { watch[n].fd = out_fd[0]; watch[n].events = POLLIN; out_slot = n++; }
        if (err_open) { watch[n].fd = err_fd[0]; watch[n].events = POLLIN; err_slot = n++; }
        int ready = poll(watch, (nfds_t)n, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (in_slot >= 0 && watch[in_slot].revents) {
            if (proc_push(in_fd[1], input_data, input_len, &pushed) < 0 ||
                pushed >= input_len || (watch[in_slot].revents & (POLLERR | POLLHUP))) {
                // Written out, or the child closed its stdin. Closing ours is what
                // lets a program that reads to EOF finish.
                close(in_fd[1]);
                in_open = 0;
            }
        }
        for (int which = 0; which < 2; which++) {
            int slot = which == 0 ? out_slot : err_slot;
            if (slot < 0 || !watch[slot].revents) continue;
            int fd = which == 0 ? out_fd[0] : err_fd[0];
            BList** into = which == 0 ? &out : &err;
            char buffer[8192];
            for (;;) {
                rt_ssize_t got = read(fd, buffer, sizeof buffer);
                if (got > 0) {
                    long long room = max_output > (*into)->len
                                         ? max_output - (*into)->len
                                         : 0;
                    rt_ssize_t keep = got < room ? got : (rt_ssize_t)room;
                    if (keep > 0) {
                        bytes_grow(*into, (*into)->len + keep);
                        memcpy((char*)(*into)->data + (*into)->len, buffer,
                               (size_t)keep);
                        (*into)->len += keep;
                    }
                    // Read past the cap and discard. Closing early would deliver
                    // SIGPIPE/EPIPE and let a capture setting change child behaviour.
                    continue;
                }
                if (got < 0 && errno == EINTR) continue;
                if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                // 0 = EOF, or a real error: either way this stream is finished.
                close(fd);
                if (which == 0) out_open = 0; else err_open = 0;
                break;
            }
        }
    }
    if (in_open) close(in_fd[1]);
    if (out_open) close(out_fd[0]);
    if (err_open) close(err_fd[0]);

    // Every child is reaped, always. A zombie per run would be a slow leak of the one
    // resource a process cannot get more of.
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    long long code = WIFSIGNALED(status) ? -(long long)WTERMSIG(status)
                                         : (long long)WEXITSTATUS(status);

    BList* packed = bytes_mk(24 + out->len + err->len);
    char* into = (char*)packed->data;
    rt_store_le(into, (unsigned long long)code, 8);
    rt_store_le(into + 8, (unsigned long long)out->len, 8);
    rt_store_le(into + 16, (unsigned long long)err->len, 8);
    if (out->len) memcpy(into + 24, out->data, (size_t)out->len);
    if (err->len) memcpy(into + 24 + out->len, err->data, (size_t)err->len);
    beans_release(out);
    beans_release(err);
    free(argv);
    free(envp);
    return (BRes){(long long)(intptr_t)packed, 0};
}
long long beans_proc_run_out(BList* argv_packed, BList* env_packed, char* cwd, BList* input, long long max_output, void** e_out) { BRes r = beans_proc_run(argv_packed, env_packed, cwd, input, max_output); *e_out = r.err; return r.val; }

#else // _WIN32 — CreateProcess, pipe handles, one drain thread per stream

// CreateProcess reports a spawn failure synchronously — the one place this port is
// simpler than POSIX, which needs the exec pipe to learn the same thing. These are
// the codes it speaks that the fs shim never sees; the rest reuse fs_win_errno.
static int proc_win_errno(DWORD code) {
    if (code == ERROR_BAD_EXE_FORMAT) return ENOEXEC; // "io", as execvp would say
    if (code == ERROR_DIRECTORY) return ENOTDIR;      // a bad cwd, as chdir would say
    return fs_win_errno(code);
}

// argv -> the one command line CreateProcess carries, quoted so the child's CRT
// splits it back into exactly the caller's argv. The rules are the MSVCRT parser's,
// per Colascione's "Everyone quotes command line arguments the wrong way": leave an
// argument bare unless it is empty or holds space/tab/newline/vtab/quote; inside
// quotes, N backslashes before a '"' become 2N+1 and N trailing backslashes before
// the closing quote double. No shell ever sees this string.
static char* proc_win_cmdline(char** argv) {
    size_t need = 1;
    for (int i = 0; argv[i]; i++) need += strlen(argv[i]) * 2 + 4; // all-quoted worst case
    char* line = malloc(need);
    if (!line) return NULL;
    char* at = line;
    for (int i = 0; argv[i]; i++) {
        if (i) *at++ = ' ';
        const char* arg = argv[i];
        if (arg[0] && !strpbrk(arg, " \t\n\v\"")) {
            size_t n = strlen(arg);
            memcpy(at, arg, n);
            at += n;
            continue;
        }
        *at++ = '"';
        for (const char* p = arg;; p++) {
            size_t slashes = 0;
            while (*p == '\\') {
                slashes++;
                p++;
            }
            if (*p == 0) {
                memset(at, '\\', slashes * 2); // doubled: the closing quote follows
                at += slashes * 2;
                break;
            }
            if (*p == '"') {
                memset(at, '\\', slashes * 2 + 1);
                at += slashes * 2 + 1;
                *at++ = '"';
                continue;
            }
            memset(at, '\\', slashes);
            at += slashes;
            *at++ = *p;
        }
        *at++ = '"';
    }
    *at = 0;
    return line;
}

// Windows wants the environment block sorted by name, case-insensitively, and
// the packed form arrives in whatever order the caller set things. Sorting is
// not cosmetic: an unsorted block is documented as undefined, and the CRT's own
// lookup in the child binary-searches it.
static int proc_env_cmp(const void* a, const void* b) {
    const wchar_t* x = *(const wchar_t* const*)a;
    const wchar_t* y = *(const wchar_t* const*)b;
    // CompareStringOrdinal with bIgnoreCase is the exact rule — _wcsicmp folds
    // by the C locale, which is not the same thing outside ASCII.
    int rc = CompareStringOrdinal(x, -1, y, -1, TRUE);
    return rc == CSTR_LESS_THAN ? -1 : rc == CSTR_GREATER_THAN ? 1 : 0;
}

// Packed entries ("K=V\0K=V\0") to a sorted, double-NUL-terminated UTF-16 block.
// NULL out means "inherit", which is what a caller who never set a variable gets.
static wchar_t* proc_win_env_block(BList* packed) {
    if (!packed || packed->len <= 0) return NULL;
    long long count = 0;
    for (long long i = 0; i < packed->len; i++)
        if (((char*)packed->data)[i] == 0) count++;
    if (count == 0) return NULL;
    wchar_t** entries = calloc((size_t)count, sizeof(wchar_t*));
    if (!entries) return NULL;
    long long n = 0, start = 0;
    for (long long i = 0; i < packed->len && n < count; i++) {
        if (((char*)packed->data)[i] != 0) continue;
        entries[n] = win_widen((char*)packed->data + start);
        if (!entries[n]) goto fail;
        n++;
        start = i + 1;
    }
    qsort(entries, (size_t)n, sizeof(wchar_t*), proc_env_cmp);
    size_t total = 1; // the block's own terminating NUL
    for (long long i = 0; i < n; i++) total += wcslen(entries[i]) + 1;
    wchar_t* block = malloc(total * sizeof(wchar_t));
    if (!block) goto fail;
    wchar_t* at = block;
    for (long long i = 0; i < n; i++) {
        size_t len = wcslen(entries[i]) + 1;
        memcpy(at, entries[i], len * sizeof(wchar_t));
        at += len;
        free(entries[i]);
    }
    *at = 0;
    free(entries);
    return block;
fail:
    for (long long i = 0; i < n; i++) free(entries[i]);
    free(entries);
    return NULL;
}

// One variable out of a block, by name, case-insensitively — the block is the
// child's environment, so this is how PATH and PATHEXT are read from it rather
// than from the parent's.
static const wchar_t* proc_env_lookup(const wchar_t* block, const wchar_t* name) {
    if (!block) return NULL;
    size_t len = wcslen(name);
    for (const wchar_t* e = block; *e; e += wcslen(e) + 1) {
        if (CompareStringOrdinal(e, (int)len, name, (int)len, TRUE) != CSTR_EQUAL)
            continue;
        if (e[len] == L'=') return e + len + 1;
    }
    return NULL;
}

static int proc_win_is_file(const wchar_t* path) {
    DWORD at = GetFileAttributesW(path);
    return at != INVALID_FILE_ATTRIBUTES && !(at & FILE_ATTRIBUTE_DIRECTORY);
}

// Resolves a program name the way execvp does, but against the environment the
// *child* will get. spec/SYNTAX.md is explicit that a fresh environment's PATH is the
// one used for the lookup, and CreateProcess cannot do that on its own: its
// lpEnvironment feeds the child and never the search, which always runs against
// the parent's PATH. So the search happens here and the answer is handed over as
// lpApplicationName. Returns malloc'd UTF-16, or NULL when nothing matched.
static wchar_t* proc_win_resolve(const wchar_t* program, const wchar_t* path,
                                 const wchar_t* pathext) {
    static const wchar_t* const fallback_ext = L".COM;.EXE;.BAT;.CMD";
    if (!pathext || !*pathext) pathext = fallback_ext;

    // A name carrying a separator is a path, not something to search for —
    // exactly the rule execvp follows.
    int is_path = 0;
    for (const wchar_t* p = program; *p; p++)
        if (*p == L'\\' || *p == L'/' || *p == L':') { is_path = 1; break; }

    size_t prog_len = wcslen(program);
    size_t ext_len = wcslen(pathext);
    size_t dir_max = path ? wcslen(path) : 0;
    wchar_t* candidate = malloc((dir_max + prog_len + ext_len + 8) * sizeof(wchar_t));
    if (!candidate) return NULL;

    const wchar_t* dir = path;
    for (;;) {
        size_t dir_len = 0;
        if (!is_path) {
            if (!dir) break;
            const wchar_t* end = wcschr(dir, L';');
            dir_len = end ? (size_t)(end - dir) : wcslen(dir);
            // An empty PATH entry means the current directory, as on Windows.
            if (dir_len) {
                memcpy(candidate, dir, dir_len * sizeof(wchar_t));
                if (candidate[dir_len - 1] != L'\\' && candidate[dir_len - 1] != L'/')
                    candidate[dir_len++] = L'\\';
            }
            dir = end ? end + 1 : NULL;
        }
        wcscpy(candidate + dir_len, program);
        if (proc_win_is_file(candidate)) return candidate;
        // Then the same stem with each PATHEXT extension, which is how Windows
        // finds "cmd" and "where" without the caller spelling ".exe".
        for (const wchar_t* e = pathext; *e;) {
            const wchar_t* end = wcschr(e, L';');
            size_t len = end ? (size_t)(end - e) : wcslen(e);
            if (len) {
                memcpy(candidate + dir_len + prog_len, e, len * sizeof(wchar_t));
                candidate[dir_len + prog_len + len] = 0;
                if (proc_win_is_file(candidate)) return candidate;
            }
            if (!end) break;
            e = end + 1;
        }
        if (is_path) break;
    }
    free(candidate);
    return NULL;
}

// The shared front half of run and start: three pipes, inheritance, CreateProcess.
// Only the child's ends are made inheritable — a child holding the parent's copy of
// its own stdin writer would never read EOF there, and a concurrently spawned
// sibling holding our read ends would keep them from ever reporting one.
//
// "Only" needs machinery to be true. bInheritHandles is all-or-nothing: it hands
// the child *every* inheritable handle in the process, so two threads spawning at
// once each inherit the other's pipes and neither child's reader ever sees EOF.
// PROC_THREAD_ATTRIBUTE_HANDLE_LIST names the three handles that may cross, and
// the mutex closes the remaining window — the handles are only marked inheritable
// between SetHandleInformation and CreateProcess, so no other spawn can be inside
// that window at the same time. Either mechanism alone would do; together the
// guarantee does not depend on the attribute list being honoured.
static pthread_mutex_t proc_spawn_lock = PTHREAD_MUTEX_INITIALIZER;
typedef struct {
    HANDLE proc;               // the child — Windows hands a waiter a handle, not a pid
    HANDLE in_w, out_r, err_r; // the parent's ends
} ProcWin;
static int proc_win_spawn(char** argv, BList* env_packed, char* cwd, ProcWin* got,
                          int* err_out) {
    char* line = NULL;
    wchar_t* wline = NULL;
    wchar_t* wcwd = NULL;
    wchar_t* wprog = NULL;
    wchar_t* app = NULL;
    wchar_t* env = NULL;
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = NULL;
    int locked = 0;
    HANDLE in_r = NULL, in_w = NULL, out_r = NULL, out_w = NULL, err_r = NULL,
           err_w = NULL;

    line = proc_win_cmdline(argv);
    wline = line ? win_widen(line) : NULL;
    wprog = win_widen(argv[0]);
    if (!line || !wline || !wprog) {
        *err_out = ENOMEM;
        goto fail;
    }
    if (env_packed && env_packed->len > 0) {
        env = proc_win_env_block(env_packed);
        if (!env) {
            *err_out = ENOMEM;
            goto fail;
        }
        // A fresh environment owns the program search too, so resolve here and
        // name the result. Without a fresh block the parent's PATH *is* the
        // right answer, and CreateProcess's own search gives it.
        app = proc_win_resolve(wprog, proc_env_lookup(env, L"PATH"),
                               proc_env_lookup(env, L"PATHEXT"));
        if (!app) {
            *err_out = ENOENT; // what execvp reports for the same miss
            goto fail;
        }
    }
    if (cwd && cwd[0]) {
        wcwd = win_widen(cwd);
        if (!wcwd) {
            *err_out = ENOMEM;
            goto fail;
        }
    }

    SIZE_T attr_bytes = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_bytes);
    attrs = attr_bytes ? malloc(attr_bytes) : NULL;
    if (attrs && !InitializeProcThreadAttributeList(attrs, 1, 0, &attr_bytes)) {
        free(attrs);
        attrs = NULL;
    }

    // Everything from here to CreateProcess runs under the spawn lock: the three
    // handles are inheritable only inside it, so no sibling spawn can pick them up.
    pthread_mutex_lock(&proc_spawn_lock);
    locked = 1;
    if (!CreatePipe(&in_r, &in_w, NULL, 0) || !CreatePipe(&out_r, &out_w, NULL, 0) ||
        !CreatePipe(&err_r, &err_w, NULL, 0)) {
        *err_out = proc_win_errno(GetLastError());
        goto fail;
    }
    SetHandleInformation(in_r, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    SetHandleInformation(out_w, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    SetHandleInformation(err_w, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

    STARTUPINFOEXW si;
    memset(&si, 0, sizeof si);
    si.StartupInfo.cb = sizeof si;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_r;
    si.StartupInfo.hStdOutput = out_w;
    si.StartupInfo.hStdError = err_w;
    DWORD flags = CREATE_UNICODE_ENVIRONMENT;
    HANDLE inherit[3] = {in_r, out_w, err_w};
    if (attrs && UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                           inherit, sizeof inherit, NULL, NULL)) {
        si.lpAttributeList = attrs;
        flags |= EXTENDED_STARTUPINFO_PRESENT;
    }
    PROCESS_INFORMATION pi;
    memset(&pi, 0, sizeof pi);
    if (!CreateProcessW(app, wline, NULL, NULL, TRUE, flags, env, wcwd,
                        &si.StartupInfo, &pi)) {
        *err_out = proc_win_errno(GetLastError());
        goto fail;
    }
    CloseHandle(in_r);
    CloseHandle(out_w);
    CloseHandle(err_w);
    pthread_mutex_unlock(&proc_spawn_lock);
    if (attrs) {
        DeleteProcThreadAttributeList(attrs);
        free(attrs);
    }
    free(line);
    free(wline);
    free(wprog);
    free(wcwd);
    free(app);
    free(env);
    CloseHandle(pi.hThread);
    got->proc = pi.hProcess;
    got->in_w = in_w;
    got->out_r = out_r;
    got->err_r = err_r;
    return 0;
fail:
    if (in_r) CloseHandle(in_r);
    if (in_w) CloseHandle(in_w);
    if (out_r) CloseHandle(out_r);
    if (out_w) CloseHandle(out_w);
    if (err_r) CloseHandle(err_r);
    if (err_w) CloseHandle(err_w);
    if (locked) pthread_mutex_unlock(&proc_spawn_lock);
    if (attrs) {
        DeleteProcThreadAttributeList(attrs);
        free(attrs);
    }
    free(line);
    free(wline);
    free(wprog);
    free(wcwd);
    free(app);
    free(env);
    return -1;
}

// One output stream, drained to EOF on its own thread. The sink grows with plain
// malloc on purpose: a drain thread is not a registered beans thread, and beans_alloc
// may start a cycle collection the moment it believes no such thread is running —
// touching the beans heap from here would race the collector. A broken pipe is how a
// pipe spells EOF; any other failure also ends the stream, exactly as the POSIX loop
// treats read errors.
typedef struct {
    HANDLE from;
    char* data;
    long long len, cap, max;
} ProcSink;
static void* proc_drain(void* arg) {
    ProcSink* sink = arg;
    char buffer[8192];
    for (;;) {
        DWORD got = 0;
        if (!ReadFile(sink->from, buffer, sizeof buffer, &got, NULL) || got == 0)
            return NULL;
        long long room = sink->max > sink->len ? sink->max - sink->len : 0;
        long long keep = (long long)got < room ? (long long)got : room;
        if (keep > 0) {
            if (sink->len + keep > sink->cap) {
                long long cap = sink->cap ? sink->cap : 8192;
                while (cap < sink->len + keep) cap *= 2;
                char* grown = realloc(sink->data, (size_t)cap);
                if (!grown) { // out of memory: keep draining, stop keeping
                    sink->max = sink->len;
                    continue;
                }
                sink->data = grown;
                sink->cap = cap;
            }
            memcpy(sink->data + sink->len, buffer, (size_t)keep);
            sink->len += keep;
        }
        // Past the cap this still reads and discards. Closing early would hand the
        // child a broken pipe and let a capture setting change its behaviour.
    }
}

BRes beans_proc_run(BList* argv_packed, BList* env_packed, char* cwd,
                    BList* input, long long max_output) {
    BRes bad;
    bad.val = 0;
    int argc = 0;
    char** argv = proc_split(argv_packed, &argc);
    if (!argv || argc == 0) {
        free(argv);
        bad.err = mk_error("a command needs at least a program name", "invalid");
        return bad;
    }
    ProcWin child;
    int e = 0;
    if (proc_win_spawn(argv, env_packed, cwd, &child, &e) != 0) {
        // The same shape the POSIX exec pipe produces, so "no such file" and
        // "exited 127" stay distinguishable.
        void* built = fs_err_obj(argv[0], e);
        free(argv);
        bad.err = built;
        return bad;
    }

    ProcSink out = {child.out_r, NULL, 0, 0, max_output};
    ProcSink err = {child.err_r, NULL, 0, 0, max_output};
    pthread_t out_t, err_t;
    int out_up = pthread_create(&out_t, NULL, proc_drain, &out) == 0;
    int err_up = out_up && pthread_create(&err_t, NULL, proc_drain, &err) == 0;
    if (!err_up) {
        // Without both drains the deadlock-freedom argument is gone. Stop the child
        // rather than risk hanging on it; nobody observes this exit code.
        TerminateProcess(child.proc, 1);
        CloseHandle(child.in_w);
        if (out_up) pthread_join(out_t, NULL);
        CloseHandle(child.out_r);
        CloseHandle(child.err_r);
        WaitForSingleObject(child.proc, INFINITE);
        CloseHandle(child.proc);
        void* built = fs_err_obj(argv[0], EAGAIN);
        free(argv);
        free(out.data);
        bad.err = built;
        return bad;
    }

    // Feed stdin here on the calling thread while the two drains keep both outputs
    // moving — the same watch-everything-at-once property poll gives POSIX. A child
    // that closed its stdin fails the write; stopping is the same give-up the POSIX
    // loop reads out of POLLERR, and there is no SIGPIPE to dodge.
    long long input_len = input ? input->len : 0;
    const char* input_data = input ? (const char*)input->data : "";
    long long pushed = 0;
    while (pushed < input_len) {
        long long left = input_len - pushed;
        DWORD ask = left > (1 << 30) ? (DWORD)(1 << 30) : (DWORD)left;
        DWORD put = 0;
        if (!WriteFile(child.in_w, input_data + pushed, ask, &put, NULL)) break;
        pushed += put;
    }
    // Written out, or the child closed its stdin. Closing ours is what lets a
    // program that reads to EOF finish.
    CloseHandle(child.in_w);
    pthread_join(out_t, NULL);
    pthread_join(err_t, NULL);
    CloseHandle(child.out_r);
    CloseHandle(child.err_r);

    // Every child is reaped, always: the wait is unbounded and the handle is closed.
    WaitForSingleObject(child.proc, INFINITE);
    DWORD raw = 0;
    GetExitCodeProcess(child.proc, &raw);
    CloseHandle(child.proc);
    long long code = (long long)(int)raw; // sign-extend — see the section comment

    BList* packed = bytes_mk(24 + out.len + err.len);
    char* into = (char*)packed->data;
    rt_store_le(into, (unsigned long long)code, 8);
    rt_store_le(into + 8, (unsigned long long)out.len, 8);
    rt_store_le(into + 16, (unsigned long long)err.len, 8);
    if (out.len) memcpy(into + 24, out.data, (size_t)out.len);
    if (err.len) memcpy(into + 24 + out.len, err.data, (size_t)err.len);
    free(out.data);
    free(err.data);
    free(argv);
    return (BRes){(long long)(intptr_t)packed, 0};
}
long long beans_proc_run_out(BList* argv_packed, BList* env_packed, char* cwd, BList* input, long long max_output, void** e_out) { BRes r = beans_proc_run(argv_packed, env_packed, cwd, input, max_output); *e_out = r.err; return r.val; }
#endif // !defined(_WIN32) — beans_proc_run

// ---- a running child --------------------------------------------------------
//
// beans_proc_run does the whole job in one call, which is right when a program's output is
// all you want. It cannot help when the child outlives the call: a server to talk to, a
// process to watch, something to kill after a deadline.
//
// So this is the same spawn with the pieces left separate. The invariant that matters is
// unchanged: **every child is reaped.** A zombie per spawn is a slow leak of the one
// resource a process cannot get more of, and the Beans handle's `deinit` kills and reaps
// rather than letting one escape.

// [pid][stdin fd][stdout fd][stderr fd]. All three pipes, always — a child with inherited
// stdio cannot be talked to, and choosing per stream would multiply the API for no gain
// while `run` already covers the simple case. On Windows the first slot carries the
// process HANDLE as an i64, not a pid — waiting and terminating need the handle, and
// closing it is that port's reap — while the fd slots are CRT descriptors on both.

#if !defined(_WIN32)
// Declared here because the clock section is further down the file and a bounded wait
// needs both.
long long beans_time_monotonic_nanos(void);
void beans_time_sleep_nanos(long long nanos);

BRes beans_proc_start(BList* argv_packed, BList* env_packed, char* cwd) {
    int argc = 0;
    char** argv = proc_split(argv_packed, &argc);
    if (!argv || argc == 0) {
        free(argv);
        return (BRes){0, mk_error("a command needs at least a program name", "invalid")};
    }
    int envc = 0;
    char** envp = env_packed && env_packed->len > 0 ? proc_split(env_packed, &envc) : 0;

    int in_fd[2] = {-1, -1}, out_fd[2] = {-1, -1}, err_fd[2] = {-1, -1},
        exec_fd[2] = {-1, -1};
    if (pipe(in_fd) != 0 || pipe(out_fd) != 0 || pipe(err_fd) != 0 ||
        pipe(exec_fd) != 0) {
        int e = errno;
        for (int i = 0; i < 2; i++) {
            if (in_fd[i] >= 0) close(in_fd[i]);
            if (out_fd[i] >= 0) close(out_fd[i]);
            if (err_fd[i] >= 0) close(err_fd[i]);
            if (exec_fd[i] >= 0) close(exec_fd[i]);
        }
        free(argv);
        free(envp);
        return (BRes){0, op_err_obj("start", e)};
    }
    fcntl(exec_fd[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        for (int i = 0; i < 2; i++) {
            close(in_fd[i]); close(out_fd[i]); close(err_fd[i]); close(exec_fd[i]);
        }
        free(argv);
        free(envp);
        return (BRes){0, op_err_obj("start", e)};
    }
    if (pid == 0) {
        dup2(in_fd[0], 0);
        dup2(out_fd[1], 1);
        dup2(err_fd[1], 2);
        close(in_fd[0]); close(in_fd[1]);
        close(out_fd[0]); close(out_fd[1]);
        close(err_fd[0]); close(err_fd[1]);
        close(exec_fd[0]);
        // The parent may be watching signals, which means they are blocked — and a mask
        // is inherited across exec. A child that starts with SIGTERM blocked cannot be
        // stopped by anyone, so the mask is cleared here. This is the one place the
        // signal design reaches into process spawning.
        sigset_t none;
        sigemptyset(&none);
        pthread_sigmask(SIG_SETMASK, &none, NULL);
        if (cwd && cwd[0] && chdir(cwd) != 0) {
            int e = errno;
            rt_ssize_t ignored = write(exec_fd[1], &e, sizeof e);
            (void)ignored;
            _exit(127);
        }
        if (envp) environ = envp;
        execvp(argv[0], argv);
        int e = errno;
        rt_ssize_t ignored = write(exec_fd[1], &e, sizeof e);
        (void)ignored;
        _exit(127);
    }

    close(in_fd[0]);
    close(out_fd[1]);
    close(err_fd[1]);
    close(exec_fd[1]);

    int child_errno = 0;
    rt_ssize_t got_errno = 0;
    do {
        got_errno = read(exec_fd[0], &child_errno, sizeof child_errno);
    } while (got_errno < 0 && errno == EINTR);
    close(exec_fd[0]);
    if (got_errno == (rt_ssize_t)sizeof child_errno) {
        int discard = 0;
        while (waitpid(pid, &discard, 0) < 0 && errno == EINTR) {}
        close(in_fd[1]);
        close(out_fd[0]);
        close(err_fd[0]);
        void* built = fs_err_obj(argv[0], child_errno);
        free(argv);
        free(envp);
        return (BRes){0, built};
    }
    free(argv);
    free(envp);

    BList* packed = bytes_mk(32);
    rt_store_le(packed->data, (unsigned long long)pid, 8);
    rt_store_le((char*)packed->data + 8, (unsigned long long)in_fd[1], 8);
    rt_store_le((char*)packed->data + 16, (unsigned long long)out_fd[0], 8);
    rt_store_le((char*)packed->data + 24, (unsigned long long)err_fd[0], 8);
    return (BRes){(long long)packed, NULL};
}
long long beans_proc_start_out(BList* argv_packed, BList* env_packed, char* cwd, void** e_out) { BRes r = beans_proc_start(argv_packed, env_packed, cwd); *e_out = r.err; return r.val; }

// [finished 0/1][status]. Status is the exit code, or the negative signal number, matching
// what `run` reports.
//
// waitpid has no timeout, so a bounded wait is WNOHANG against a monotonic deadline with a
// short sleep between tries. The sleep grows to 20ms so a long wait costs almost no CPU —
// this is not a spin. A timeout of 0 is one non-blocking check; a negative one blocks in
// waitpid with no polling at all.
BRes beans_proc_status(long long pid, long long timeout_ms) {
    if (pid <= 0) return (BRes){0, mk_error("no such child", "invalid")};
    long long deadline = timeout_ms <= 0 ? 0
                                         : beans_time_monotonic_nanos() / 1000000LL
                                               + timeout_ms;
    long long nap_ns = 1000000; // 1ms, doubling to 20ms
    for (;;) {
        int status = 0;
        pid_t got = waitpid((pid_t)pid, &status, timeout_ms < 0 ? 0 : WNOHANG);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) return (BRes){0, op_err_obj("wait", errno)};
        if (got == (pid_t)pid) {
            long long code = WIFSIGNALED(status) ? -(long long)WTERMSIG(status)
                                                 : (long long)WEXITSTATUS(status);
            BList* out = bytes_mk(16);
            rt_store_le(out->data, 1, 8);
            rt_store_le((char*)out->data + 8, (unsigned long long)code, 8);
            return (BRes){(long long)out, NULL};
        }
        // Still running.
        if (timeout_ms == 0 ||
            beans_time_monotonic_nanos() / 1000000LL >= deadline) {
            BList* out = bytes_mk(16);
            rt_store_le(out->data, 0, 8);
            rt_store_le((char*)out->data + 8, 0, 8);
            return (BRes){(long long)out, NULL};
        }
        beans_time_sleep_nanos(nap_ns);
        if (nap_ns < 20000000) nap_ns *= 2;
    }
}
long long beans_proc_status_out(long long pid, long long timeout_ms, void** e_out) { BRes r = beans_proc_status(pid, timeout_ms); *e_out = r.err; return r.val; }

BRes beans_proc_signal(long long pid, long long number) {
    if (pid <= 0) return (BRes){0, mk_error("no such child", "invalid")};
    // Any signal may be *sent* — including kill and stop, which is the point of being
    // able to stop a child that ignores politeness. The watchable table restricts what a
    // program can *receive*, which is a different question.
    if (number <= 0 || number >= 64)
        return (BRes){0, mk_error("signal number out of range", "invalid")};
    if (kill((pid_t)pid, (int)number) != 0) {
        // ESRCH means it is already gone, which is the state the caller wanted.
        if (errno == ESRCH) return (BRes){1, NULL};
        return (BRes){0, op_err_obj("signal", errno)};
    }
    return (BRes){1, NULL};
}
long long beans_proc_signal_out(long long pid, long long number, void** e_out) { BRes r = beans_proc_signal(pid, number); *e_out = r.err; return r.val; }

#else // _WIN32 — the handle in `pid` does what waitpid and kill do elsewhere

BRes beans_proc_start(BList* argv_packed, BList* env_packed, char* cwd) {
    int argc = 0;
    char** argv = proc_split(argv_packed, &argc);
    if (!argv || argc == 0) {
        free(argv);
        return (BRes){0, mk_error("a command needs at least a program name", "invalid")};
    }
    ProcWin child;
    int e = 0;
    if (proc_win_spawn(argv, env_packed, cwd, &child, &e) != 0) {
        void* built = fs_err_obj(argv[0], e);
        free(argv);
        return (BRes){0, built};
    }
    free(argv);
    // CRT descriptors over the parent ends, so proc read/write/close below stay one
    // story on both platforms. The descriptor owns the handle from here; _close is
    // the CloseHandle these streams get.
    int in_fd = _open_osfhandle((intptr_t)child.in_w, _O_BINARY);
    int out_fd = _open_osfhandle((intptr_t)child.out_r, _O_RDONLY | _O_BINARY);
    int err_fd = _open_osfhandle((intptr_t)child.err_r, _O_RDONLY | _O_BINARY);
    if (in_fd < 0 || out_fd < 0 || err_fd < 0) {
        // CRT descriptor table exhausted. The child is already alive, and stopping
        // it is the only way "start failed" can stay true; nobody observes the code.
        TerminateProcess(child.proc, 1);
        WaitForSingleObject(child.proc, INFINITE);
        CloseHandle(child.proc);
        if (in_fd >= 0) _close(in_fd); else CloseHandle(child.in_w);
        if (out_fd >= 0) _close(out_fd); else CloseHandle(child.out_r);
        if (err_fd >= 0) _close(err_fd); else CloseHandle(child.err_r);
        return (BRes){0, op_err_obj("start", EMFILE)};
    }
    BList* packed = bytes_mk(32);
    rt_store_le(packed->data, (unsigned long long)(intptr_t)child.proc, 8);
    rt_store_le((char*)packed->data + 8, (unsigned long long)in_fd, 8);
    rt_store_le((char*)packed->data + 16, (unsigned long long)out_fd, 8);
    rt_store_le((char*)packed->data + 24, (unsigned long long)err_fd, 8);
    return (BRes){(long long)packed, NULL};
}
long long beans_proc_start_out(BList* argv_packed, BList* env_packed, char* cwd, void** e_out) { BRes r = beans_proc_start(argv_packed, env_packed, cwd); *e_out = r.err; return r.val; }

// [finished 0/1][status], matching what `run` reports. WaitForSingleObject carries
// the whole timeout natively — none of the WNOHANG-plus-nap loop POSIX needs — and
// closing the handle on the finished path is this port's reap: after it the value in
// `pid` is dead exactly as a waited-for pid is, and std.process's `reaped` flag keeps
// every later call away, just as it must on POSIX once a pid can be recycled.
BRes beans_proc_status(long long pid, long long timeout_ms) {
    if (pid <= 0) return (BRes){0, mk_error("no such child", "invalid")};
    HANDLE h = (HANDLE)(intptr_t)pid;
    DWORD span = timeout_ms < 0 ? INFINITE
                 : timeout_ms > 0xFFFFFFFELL ? (DWORD)0xFFFFFFFEu // just short of INFINITE
                                             : (DWORD)timeout_ms;
    DWORD waited = WaitForSingleObject(h, span);
    if (waited == WAIT_TIMEOUT) {
        BList* out = bytes_mk(16);
        rt_store_le(out->data, 0, 8);
        rt_store_le((char*)out->data + 8, 0, 8);
        return (BRes){(long long)out, NULL};
    }
    if (waited != WAIT_OBJECT_0)
        return (BRes){0, op_err_obj("wait", fs_win_errno(GetLastError()))};
    DWORD raw = 0;
    if (!GetExitCodeProcess(h, &raw))
        return (BRes){0, op_err_obj("wait", fs_win_errno(GetLastError()))};
    CloseHandle(h);
    BList* out = bytes_mk(16);
    rt_store_le(out->data, 1, 8);
    rt_store_le((char*)out->data + 8,
                (unsigned long long)(long long)(int)raw, 8);
    return (BRes){(long long)out, NULL};
}
long long beans_proc_status_out(long long pid, long long timeout_ms, void** e_out) { BRes r = beans_proc_status(pid, timeout_ms); *e_out = r.err; return r.val; }

// No signal is deliverable on Windows, so every number is a hard TerminateProcess —
// std.process's terminate-then-kill degrades to kill-then-kill, which still keeps
// stop()'s promise that it returns. The exit code carries -(number) so status
// reports the same negative the POSIX child would show.
BRes beans_proc_signal(long long pid, long long number) {
    if (pid <= 0) return (BRes){0, mk_error("no such child", "invalid")};
    if (number <= 0 || number >= 64)
        return (BRes){0, mk_error("signal number out of range", "invalid")};
    HANDLE h = (HANDLE)(intptr_t)pid;
    // Already exited is the state the caller wanted — the same ruling POSIX gives
    // ESRCH, and kill on a not-yet-reaped zombie succeeds there too.
    if (WaitForSingleObject(h, 0) == WAIT_OBJECT_0) return (BRes){1, NULL};
    if (!TerminateProcess(h, (UINT)(-(int)number))) {
        // It may have exited between the check and the shot; that is still "gone".
        if (WaitForSingleObject(h, 0) == WAIT_OBJECT_0) return (BRes){1, NULL};
        return (BRes){0, op_err_obj("signal", fs_win_errno(GetLastError()))};
    }
    return (BRes){1, NULL};
}
long long beans_proc_signal_out(long long pid, long long number, void** e_out) { BRes r = beans_proc_signal(pid, number); *e_out = r.err; return r.val; }
#endif // !defined(_WIN32) — start/status/signal

// Plain descriptor I/O, for the child's pipes. Separate from the socket calls because
// send/recv fail with ENOTSOCK on a pipe. Shared with the Windows port: its fds wrap
// pipe handles via _open_osfhandle, the CRT reads a broken pipe as EOF and writes it
// as EPIPE, and its errno is simply never EINTR, so the retry loops cost nothing.
BRes beans_proc_write(long long fd, BList* data, long long from) {
    if (fd < 0) return (BRes){0, mk_error("stream is closed", "closed")};
    if (!data) return (BRes){0, mk_error("write: no data", "invalid")};
    if (from < 0 || from > data->len)
        return (BRes){0, mk_error("write: offset is outside the data", "invalid")};
    long long want = data->len - from;
    if (want == 0) return (BRes){0, NULL};
    rt_ssize_t wrote;
    do {
        wrote = write((int)fd, (const char*)data->data + from, (size_t)want);
    } while (wrote < 0 && errno == EINTR);
    if (wrote < 0) return (BRes){0, op_err_obj("write", errno)};
    return (BRes){(long long)wrote, NULL};
}
long long beans_proc_write_out(long long fd, BList* data, long long from, void** e_out) { BRes r = beans_proc_write(fd, data, from); *e_out = r.err; return r.val; }

BRes beans_proc_read(long long fd, long long max) {
    if (fd < 0) return (BRes){0, mk_error("stream is closed", "closed")};
    if (max <= 0)
        return (BRes){0, mk_error("read: the byte count must be positive — an empty "
                                  "result already means end of stream", "invalid")};
    BList* buf = bytes_mk(max);
    rt_ssize_t got;
    do { got = read((int)fd, buf->data, (size_t)max); } while (got < 0 && errno == EINTR);
    if (got < 0) {
        int e = errno;
        beans_release(buf);
        return (BRes){0, op_err_obj("read", e)};
    }
    buf->len = got; // 0 = the writer closed
    return (BRes){(long long)buf, NULL};
}
long long beans_proc_read_out(long long fd, long long max, void** e_out) { BRes r = beans_proc_read(fd, max); *e_out = r.err; return r.val; }

BRes beans_proc_close(long long fd) {
    if (fd < 0) return (BRes){0, mk_error("stream is closed", "closed")};
#if BEANS_RT_PROFILE >= BEANS_RT_FULL
    beans_reactor_note_close(fd);
#endif
    if (close((int)fd) != 0 && errno != EINTR)
        return (BRes){0, op_err_obj("close", errno)};
    return (BRes){1, NULL};
}
long long beans_proc_close_out(long long fd, void** e_out) { BRes r = beans_proc_close(fd); *e_out = r.err; return r.val; }

// ---- shared memory ----------------------------------------------------------
//
// A POSIX shared-memory object, mapped MAP_SHARED so writes are visible to every
// process that has it open. It comes back as an ordinary MMap, which already has the
// accessors and the deterministic close — shared memory is a *source* of a mapping,
// not a new kind of thing.
//
// The fd is closed as soon as the mapping exists: the mapping keeps the object alive,
// and holding the descriptor open would leak one per map. The name outlives every
// process until someone unlinks it, which is why unlink is a separate call.
BRes beans_shm_open(char* name, long long size, long long create) {
    if (size <= 0) return (BRes){0, mk_error("shared memory size must be positive",
                                             "invalid")};
#if defined(_WIN32)
    // POSIX shared memory is a file in a well-known place — /dev/shm on
    // Linux — and the Windows emulation is exactly that: a real file in the
    // temp directory, mapped shared. The native alternative, a pagefile-backed
    // *named* mapping, dies with its last handle; the POSIX object outlives
    // every process until unlink, and a file is how Windows spells that.
    char shm_path[MAX_PATH + 64];
    if (fs_shm_path(shm_path, sizeof shm_path, name) != 0)
        return (BRes){0, mk_error("no temp directory for shared memory", "io")};
    int flags = (create ? (O_RDWR | O_CREAT) : O_RDWR) | O_CLOEXEC | FS_O_BINARY;
    int fd = fs_open_file(shm_path, flags, 0600);
    if (fd < 0) return (BRes){0, fs_err_obj_rc(name, errno)};
#else
    int flags = create ? (O_RDWR | O_CREAT) : O_RDWR;
    int fd = shm_open(name, flags, 0600);
    if (fd < 0) return (BRes){0, fs_err_obj_rc(name, errno)};
    int fd_flags = fcntl(fd, F_GETFD, 0);
    if (fd_flags >= 0) fcntl(fd, F_SETFD, fd_flags | FD_CLOEXEC);
#endif
    if (create && fs_ftruncate(fd, size) != 0) {
        int e = errno;
        close(fd);
        return (BRes){0, fs_err_obj_rc(name, e)};
    }
    fs_stat_t st;
    if (fs_fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return (BRes){0, fs_err_obj_rc(name, e)};
    }
    // The caller always states the size, in both modes. fstat on a shared-memory
    // object reports a page-rounded size — 16384 for a 64-byte object on macOS — so
    // trusting it would hand a reader a length its writer never agreed to. The
    // rounded size is still useful as a bound: mapping past the real end gives SIGBUS
    // on first touch, so a request that does not fit is refused here instead.
    long long length = size;
    if (length <= 0) {
        close(fd);
        return (BRes){0, mk_error("shared memory size must be positive", "invalid")};
    }
    if (length > (long long)st.st_size) {
        close(fd);
        return (BRes){0, mk_error("shared memory object is smaller than the "
                                  "requested size", "invalid")};
    }
#if defined(_WIN32)
    void* address = fs_map_fd(fd, length, 1);
    if (!address) {
        int e = errno;
        close(fd);
        return (BRes){0, fs_err_obj_rc(name, e)};
    }
#else
    void* address = mmap(0, (size_t)length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (address == MAP_FAILED) {
        int e = errno;
        close(fd);
        return (BRes){0, fs_err_obj_rc(name, e)};
    }
#endif
    // Same shape beans_mmap_open builds: kind 6 with shape bit 1 = a mapping, so the
    // generic destructor unmaps it. fd -1 because the mapping owns the memory now and
    // there is nothing left to ftruncate.
    BMMap* m = beans_alloc(sizeof(BMMap), 6 | (1 << 3));
    m->p = (char*)address;
    m->len = length;
    m->fd = -1;
    m->writable = 1;
    close(fd);
    return (BRes){(long long)m, NULL};
}
long long beans_shm_open_out(char* name, long long size, long long create, void** e_out) { BRes r = beans_shm_open(name, size, create); *e_out = r.err; return r.val; }

// Removes the name. Existing mappings keep working until their last user unmaps, the
// same as unlinking an open file.
BRes beans_shm_unlink(char* name) {
#if defined(_WIN32)
    // The file-backed emulation makes unlink a real unlink, with the same
    // observable behaviour as POSIX: a missing name reports not_found, and
    // existing mappings keep working because the view holds the file mapping
    // open even after the file's directory entry is gone.
    char shm_path[MAX_PATH + 64];
    if (fs_shm_path(shm_path, sizeof shm_path, name) != 0)
        return (BRes){0, mk_error("no temp directory for shared memory", "io")};
    if (unlink(shm_path) != 0) return (BRes){0, fs_err_obj_rc(name, errno)};
    return (BRes){1, 0};
#else
    if (shm_unlink(name) != 0) return (BRes){0, fs_err_obj_rc(name, errno)};
    return (BRes){1, 0}; // ok(true) — the row is typed Result<bool>
#endif
}
long long beans_shm_unlink_out(char* name, void** e_out) { BRes r = beans_shm_unlink(name); *e_out = r.err; return r.val; }

BRes beans_mmap_open(char* path, long long writable) {
    int fd = fs_open_file(path,
                          (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | FS_O_BINARY,
                          0644);
    if (fd < 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    fs_stat_t st;
    if (fs_fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        return (BRes){0, fs_err_obj_rc(path, e)};
    }
    char* p = NULL;
    if (st.st_size > 0) {
#if defined(_WIN32)
        p = fs_map_fd(fd, (long long)st.st_size, (int)writable);
        if (!p) {
            int e = errno;
            close(fd);
            return (BRes){0, fs_err_obj_rc(path, e)};
        }
#else
        p = mmap(NULL, (size_t)st.st_size,
                 writable ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) {
            int e = errno;
            close(fd);
            return (BRes){0, fs_err_obj_rc(path, e)};
        }
#endif
    }
    BMMap* m = beans_alloc(sizeof(BMMap), 6 | (1 << 3));
    m->p = p;
    m->len = (long long)st.st_size;
    m->fd = fd; // kept: resize() needs it to ftruncate + remap
    m->writable = writable;
    return (BRes){(long long)m, NULL};
}
long long beans_mmap_open_out(char* path, long long writable, void** e_out) { BRes r = beans_mmap_open(path, writable); *e_out = r.err; return r.val; }
long long beans_mmap_len(BMMap* m) { return m->len; }
static void mmap_guard(BMMap* m, long long line, long long col) {
    if (m->closed) beans_panic("mmap is closed", line, col);
}
static long long mmap_word(BMMap* m, const char* what, long long pos, long long w,
                           long long line, long long col) {
    mmap_guard(m, line, col);
    // pos > len - w, never pos + w > len — the sum overflows for huge pos
    if (pos < 0 || w > m->len || pos > m->len - w) {
        char b[96];
        snprintf(b, sizeof b, "%s read at %lld out of range (len %lld)", what, pos,
                 m->len);
        beans_panic(b, line, col);
    }
    return (long long)rt_load_le(m->p + pos, (size_t)w);
}
static void mmap_put_word(BMMap* m, const char* what, long long pos, long long v,
                          long long w, long long line, long long col) {
    mmap_guard(m, line, col);
    if (!m->writable) beans_panic("mmap is read-only", line, col);
    if (pos < 0 || w > m->len || pos > m->len - w) {
        char b[96];
        snprintf(b, sizeof b, "%s write at %lld out of range (len %lld)", what, pos,
                 m->len);
        beans_panic(b, line, col);
    }
    rt_store_le(m->p + pos, (unsigned long long)v, (size_t)w);
}
long long beans_mmap_get_u8(BMMap* m, long long p, long long l, long long c) { return mmap_word(m, "u8", p, 1, l, c); }
long long beans_mmap_get_u16(BMMap* m, long long p, long long l, long long c) { return mmap_word(m, "u16", p, 2, l, c); }
long long beans_mmap_get_u32(BMMap* m, long long p, long long l, long long c) { return mmap_word(m, "u32", p, 4, l, c); }
long long beans_mmap_get_u64(BMMap* m, long long p, long long l, long long c) { return mmap_word(m, "u64", p, 8, l, c); }
long long beans_mmap_get_i64(BMMap* m, long long p, long long l, long long c) { return mmap_word(m, "i64", p, 8, l, c); }
void beans_mmap_put_u8(BMMap* m, long long p, long long v, long long l, long long c) { mmap_put_word(m, "u8", p, v, 1, l, c); }
void beans_mmap_put_u16(BMMap* m, long long p, long long v, long long l, long long c) { mmap_put_word(m, "u16", p, v, 2, l, c); }
void beans_mmap_put_u32(BMMap* m, long long p, long long v, long long l, long long c) { mmap_put_word(m, "u32", p, v, 4, l, c); }
void beans_mmap_put_u64(BMMap* m, long long p, long long v, long long l, long long c) { mmap_put_word(m, "u64", p, v, 8, l, c); }
void beans_mmap_put_i64(BMMap* m, long long p, long long v, long long l, long long c) { mmap_put_word(m, "i64", p, v, 8, l, c); }
BList* beans_mmap_read(BMMap* m, long long pos, long long n, long long line,
                       long long col) {
    mmap_guard(m, line, col);
    if (pos < 0 || n < 0 || n > m->len || pos > m->len - n) {
        char b[96];
        snprintf(b, sizeof b, "read %lld at %lld out of range (len %lld)", n, pos,
                 m->len);
        beans_panic(b, line, col);
    }
    BList* r = bytes_mk(n);
    memcpy(r->data, m->p + pos, (size_t)n);
    return r;
}
void beans_mmap_write(BMMap* m, long long pos, BList* d, long long line,
                      long long col) {
    mmap_guard(m, line, col);
    if (!m->writable) beans_panic("mmap is read-only", line, col);
    if (pos < 0 || d->len > m->len || pos > m->len - d->len) {
        char b[96];
        snprintf(b, sizeof b, "write %lld at %lld out of range (len %lld)", d->len,
                 pos, m->len);
        beans_panic(b, line, col);
    }
    memcpy(m->p + pos, d->data, (size_t)d->len);
}
// One unmap and one durable-flush spelling per platform, so close/resize/flush
// read the same on both.
#if defined(_WIN32)
static int fs_unmap(char* p, long long len) {
    (void)len;
    return UnmapViewOfFile(p) ? 0 : (errno = EIO, -1);
}
static int fs_msync(char* base, long long pos, long long n, long long fd, int writable) {
    // FlushViewOfFile hands the dirty pages to the file system; page alignment
    // is not required. It stops there, though — Microsoft is explicit that it
    // does not flush the hardware cache — and this call is what spec/SYNTAX.md calls
    // the durability operation, the same promise msync(MS_SYNC) keeps below.
    // So a writable file mapping follows it with FlushFileBuffers on the
    // backing handle. An anonymous mapping has no handle and a read-only one
    // has nothing to make durable; FlushFileBuffers would fail on either.
    if (!FlushViewOfFile(base + pos, (SIZE_T)n)) {
        errno = EIO;
        return -1;
    }
    if (!writable || fd < 0) return 0;
    HANDLE h = (HANDLE)_get_osfhandle((int)fd);
    if (h == INVALID_HANDLE_VALUE) {
        errno = EBADF;
        return -1;
    }
    if (!FlushFileBuffers(h)) {
        errno = EIO;
        return -1;
    }
    return 0;
}
#else
static int fs_unmap(char* p, long long len) { return munmap(p, (size_t)len); }
static int fs_msync(char* base, long long pos, long long n, long long fd, int writable) {
    (void)fd;
    (void)writable; // msync(MS_SYNC) is already the durable form
    long long page = (long long)getpagesize();
    long long start = pos - pos % page; // msync wants a page-aligned base
    return msync(base + start, (size_t)(pos + n - start), MS_SYNC);
}
#endif
BRes beans_mmap_flush(BMMap* m) {
    if (m->closed) return (BRes){0, mmap_closed_err()};
    if (m->len > 0 && fs_msync(m->p, 0, m->len, m->fd, m->writable != 0) != 0) {
        return (BRes){0, op_err_obj("flush", errno)};
    }
    return (BRes){1, NULL};
}
long long beans_mmap_flush_out(BMMap* m, void** e_out) { BRes r = beans_mmap_flush(m); *e_out = r.err; return r.val; }
BRes beans_mmap_flush_range(BMMap* m, long long pos, long long n) {
    if (m->closed) return (BRes){0, mmap_closed_err()};
    if (pos < 0 || n < 0 || n > m->len || pos > m->len - n) {
        char b[96];
        snprintf(b, sizeof b, "flush %lld at %lld out of range (len %lld)", n, pos,
                 m->len);
        return (BRes){0, mk_error(b, "io")};
    }
    if (n > 0) {
        if (fs_msync(m->p, pos, n, m->fd, m->writable != 0) != 0) {
            return (BRes){0, op_err_obj("flush", errno)};
        }
    }
    return (BRes){1, NULL};
}
long long beans_mmap_flush_range_out(BMMap* m, long long pos, long long n, void** e_out) { BRes r = beans_mmap_flush_range(m, pos, n); *e_out = r.err; return r.val; }
BRes beans_mmap_close(BMMap* m) {
    if (m->closed) return (BRes){0, mk_error("mmap already closed", "closed")};
    m->closed = 1;
#if BEANS_RT_PROFILE >= BEANS_RT_FULL
    if (m->fd >= 0) beans_reactor_note_close(m->fd);
#endif
    // defer munmap+close while workers run (see beans_file_close): a racing op
    // reading through the mapping must not have it pulled out from under it
    if (cc_threads > 0) return (BRes){1, NULL};
    int bad = m->p && fs_unmap(m->p, m->len) != 0;
    int e = errno;
    m->p = NULL;
    if (m->fd >= 0) close((int)m->fd);
    m->fd = -1;
    if (bad) return (BRes){0, op_err_obj("close", e)};
    return (BRes){1, NULL};
}
long long beans_mmap_close_out(BMMap* m, void** e_out) { BRes r = beans_mmap_close(m); *e_out = r.err; return r.val; }

// grow or shrink in place: truncate the file, drop the old mapping, map
// fresh. On a mapping failure the handle stays open but empty (len 0).
BRes beans_mmap_resize(BMMap* m, long long n) {
    if (m->closed) return (BRes){0, mmap_closed_err()};
    if (!m->writable) return (BRes){0, mk_error("mmap is read-only", "permission")};
    if (n < 0) return (BRes){0, mk_error("negative resize", "io")};
#if defined(_WIN32)
    // Windows refuses to shrink a file that still has a mapped view, so the
    // unmap comes first there. POSIX keeps the truncate-first order: if the
    // truncate fails, the old mapping stays intact instead of degrading to
    // the documented empty state.
    if (m->p) fs_unmap(m->p, m->len);
    m->p = NULL;
    m->len = 0;
    if (fs_ftruncate((int)m->fd, n) != 0) {
        return (BRes){0, op_err_obj("resize", errno)};
    }
#else
    if (fs_ftruncate((int)m->fd, n) != 0) {
        return (BRes){0, op_err_obj("resize", errno)};
    }
    if (m->p) fs_unmap(m->p, m->len);
    m->p = NULL;
    m->len = 0;
#endif
    if (n > 0) {
#if defined(_WIN32)
        char* p = fs_map_fd((int)m->fd, n, 1);
        if (!p) return (BRes){0, op_err_obj("resize", errno)};
#else
        char* p = mmap(NULL, (size_t)n, PROT_READ | PROT_WRITE, MAP_SHARED,
                       (int)m->fd, 0);
        if (p == MAP_FAILED) return (BRes){0, op_err_obj("resize", errno)};
#endif
        m->p = p;
        m->len = n;
    }
    return (BRes){1, NULL};
}
long long beans_mmap_resize_out(BMMap* m, long long n, void** e_out) { BRes r = beans_mmap_resize(m, n); *e_out = r.err; return r.val; }
#endif

// ---- Dir.walk: files and symlinks under root (lstat — never follows a
// link), paths relative to root, "/"-joined, sorted at the end ----
typedef struct {
    char** v;
    long long len, cap;
} StrVec;
static void sv_push(StrVec* s, char* p) {
    if (s->len == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 16;
        s->v = realloc(s->v, (size_t)s->cap * sizeof(char*));
    }
    s->v[s->len++] = p;
}
static char* path_cat(const char* a, const char* b) {
    size_t la = strlen(a), lb = strlen(b);
    char* r = malloc(la + lb + 2);
    memcpy(r, a, la);
    r[la] = '/';
    memcpy(r + la + 1, b, lb);
    r[la + 1 + lb] = 0;
    return r;
}
static void sv_free(StrVec* s) {
    for (long long i = 0; i < s->len; i++) free(s->v[i]);
    free(s->v);
}
// Iterative walk: an explicit stack of relative dir paths, one DIR open at a
// time. Recursion held one fd per depth level and ran out at ~250 deep; this
// caps open fds at one. Output is sorted afterward, so traversal order is
// free.
static int walk_dir(const char* root, StrVec* out, char** epath, int* eno) {
    StrVec stack = {0, 0, 0};
    sv_push(&stack, strdup("")); // "" = root itself
    int ok = 1;
    while (stack.len > 0) {
        char* rel = stack.v[--stack.len];
        char* full = rel[0] ? path_cat(root, rel) : strdup(root);
        fs_dir_t* d = fs_dir_open(full);
        if (!d) {
            *epath = full;
            *eno = errno;
            free(rel);
            ok = 0;
            break;
        }
        free(full);
        const char* name;
        while ((name = fs_dir_next(d))) {
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
            char* r2 = rel[0] ? path_cat(rel, name) : strdup(name);
            char* abs = path_cat(root, r2);
#if defined(_WIN32)
            // fs_link_kind is the lstat here: a reparse point is its own
            // entry and is never descended, which is also what keeps a
            // symlink cycle from walking forever.
            int is_dir = 0, is_link = 0;
            if (fs_link_kind(abs, &is_dir, &is_link) != 0) {
                *epath = abs;
                *eno = errno;
                free(r2);
                ok = 0;
                break;
            }
            free(abs);
            if (is_dir && !is_link) sv_push(&stack, r2); // descend later
            else sv_push(out, r2);
#else
            struct stat st;
            if (lstat(abs, &st) != 0) {
                *epath = abs;
                *eno = errno;
                free(r2);
                ok = 0;
                break;
            }
            free(abs);
            if (S_ISDIR(st.st_mode)) sv_push(&stack, r2); // descend later
            else sv_push(out, r2);
#endif
        }
        fs_dir_close(d);
        free(rel);
        if (!ok) break;
    }
    for (long long i = 0; i < stack.len; i++) free(stack.v[i]);
    free(stack.v);
    return ok;
}
static int walk_cmp(const void* a, const void* b) {
    return strcmp(*(char* const*)a, *(char* const*)b);
}
BRes beans_dir_walk(char* path) {
    StrVec out = {0, 0, 0};
    char* epath = NULL;
    int eno = 0;
    if (!walk_dir(path, &out, &epath, &eno)) {
        void* e = fs_err_obj(epath, eno);
        free(epath);
        for (long long i = 0; i < out.len; i++) free(out.v[i]);
        free(out.v);
        return (BRes){0, e};
    }
    qsort(out.v, (size_t)out.len, sizeof(char*), walk_cmp);
    BList* l = beans_list_new(1);
    for (long long i = 0; i < out.len; i++) {
        beans_list_push(l, (long long)rc_strdup(out.v[i]));
        free(out.v[i]);
    }
    free(out.v);
    return (BRes){(long long)l, NULL};
}
long long beans_dir_walk_out(char* path, void** e_out) { BRes r = beans_dir_walk(path); *e_out = r.err; return r.val; }

BRes beans_file_open(char* path, char* mode) {
    int flags;
    if (strcmp(mode, "r") == 0) flags = O_RDONLY | O_CLOEXEC | FS_O_BINARY;
    else if (strcmp(mode, "rw") == 0) flags = O_RDWR | O_CLOEXEC | FS_O_BINARY;
    else if (strcmp(mode, "create") == 0)
        flags = O_RDWR | O_CREAT | O_CLOEXEC | FS_O_BINARY;
    else if (strcmp(mode, "append") == 0)
        flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | FS_O_BINARY;
    else {
        // mode is a beans string of any length — heap-build so a long bad
        // mode reports its full text like the interpreter, not a truncation
        size_t n = strlen(mode) + 24;
        char* m = malloc(n);
        snprintf(m, n, "bad open mode '%s'", mode);
        void* e = mk_error(m, "io");
        free(m);
        return (BRes){0, e};
    }
    int fd = fs_open_file(path, flags, 0644);
    if (fd < 0) return (BRes){0, fs_err_obj_rc(path, errno)};
#if defined(_WIN32)
    // The MSVCRT seeks an _O_APPEND descriptor to the end at open time;
    // POSIX leaves the position at 0 and only forces the end per write. The
    // per-write behaviour is the one appends rely on and both give it, so
    // matching POSIX here is one seek back.
    if (strcmp(mode, "append") == 0) fs_lseek(fd, 0, SEEK_SET);
#endif
    BFile* f = beans_alloc(sizeof(BFile), 6);
    f->fd = fd;
    f->closed = 0;
    return (BRes){(long long)f, NULL};
}
long long beans_file_open_out(char* path, char* mode, void** e_out) { BRes r = beans_file_open(path, mode); *e_out = r.err; return r.val; }

long long beans_file_exists(char* path) {
    fs_stat_t st;
    return fs_stat(path, &st) == 0 && !S_ISDIR(st.st_mode);
}
BRes beans_file_size_p(char* path) {
#if defined(_WIN32)
    // Path-based stat reads the directory entry, which NTFS updates lazily
    // while a writable section holds the file — a just-resized mapping
    // reports its old size there. A handle-based query sees the truth, and
    // real Windows is where the difference shows; Wine's Unix underlay hid it.
    wchar_t* wpath = win_widen(path);
    if (!wpath) return (BRes){0, fs_err_obj_rc(path, ENOMEM)};
    HANDLE h = CreateFileW(wpath, FILE_READ_ATTRIBUTES,
                           FILE_SHARE_READ | FILE_SHARE_WRITE |
                               FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) {
        errno = fs_win_errno(GetLastError());
        return (BRes){0, fs_err_obj_rc(path, errno)};
    }
    LARGE_INTEGER size;
    BOOL ok = GetFileSizeEx(h, &size);
    CloseHandle(h);
    if (!ok) {
        errno = EIO;
        return (BRes){0, fs_err_obj_rc(path, errno)};
    }
    return (BRes){(long long)size.QuadPart, NULL};
#else
    fs_stat_t st;
    if (fs_stat(path, &st) != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    return (BRes){(long long)st.st_size, NULL};
#endif
}
long long beans_file_size_p_out(char* path, void** e_out) { BRes r = beans_file_size_p(path); *e_out = r.err; return r.val; }
BRes beans_file_remove(char* path) {
#if defined(_WIN32)
    // fs_link_kind is the lstat: remove the link itself, and let a dangling
    // one be removed. A link to a directory is itself a directory entry on
    // Windows, so rmdir is the right verb for it too.
    int is_dir = 0, is_link = 0;
    if (fs_link_kind(path, &is_dir, &is_link) != 0)
        return (BRes){0, fs_err_obj_rc(path, errno)};
    int r = is_dir ? rmdir(path) : fs_unlink_posix(path);
    if (r != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    return (BRes){1, NULL};
#else
    struct stat st;
    // lstat: remove the link itself, and let a dangling symlink be removed
    if (lstat(path, &st) != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    int r = S_ISDIR(st.st_mode) ? rmdir(path) : unlink(path);
    if (r != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    return (BRes){1, NULL};
#endif
}
long long beans_file_remove_out(char* path, void** e_out) { BRes r = beans_file_remove(path); *e_out = r.err; return r.val; }
BRes beans_file_rename(char* from, char* to) {
#if defined(_WIN32)
    // POSIX rename atomically replaces an existing target; the CRT's rename
    // refuses it. MoveFileEx with REPLACE_EXISTING is the Windows spelling
    // of the POSIX contract — kv.b's compact-then-rename commit depends on it.
    wchar_t* wfrom = win_widen(from);
    wchar_t* wto = win_widen(to);
    // Capture whether both widenings succeeded before the free()s below: reading
    // wfrom/wto after they are freed is undefined even without a dereference, so
    // the error path cannot ask again.
    int converted = wfrom && wto;
    BOOL moved = converted && MoveFileExW(wfrom, wto, MOVEFILE_REPLACE_EXISTING);
    DWORD why = moved ? 0 : GetLastError();
    free(wfrom);
    free(wto);
    if (!moved) {
        errno = converted ? fs_win_errno(why) : ENOMEM;
        return (BRes){0, fs_err_obj_rc(from, errno)};
    }
    return (BRes){1, NULL};
#else
    if (rename(from, to) != 0) return (BRes){0, fs_err_obj_rc(from, errno)};
    return (BRes){1, NULL};
#endif
}
long long beans_file_rename_out(char* from, char* to, void** e_out) { BRes r = beans_file_rename(from, to); *e_out = r.err; return r.val; }
BRes beans_dir_make(char* path) {
    if (fs_mkdir(path, 0755) != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    return (BRes){1, NULL};
}
long long beans_dir_make_out(char* path, void** e_out) { BRes r = beans_dir_make(path); *e_out = r.err; return r.val; }
BRes beans_dir_make_all(char* path) {
    long long n = beans_slen(path);
    char* cur = malloc((size_t)n + 1);
    long long i = 0;
    while (i < n) {
        long long j = i;
        while (j < n && path[j] != '/') j++;
        memcpy(cur, path, (size_t)j);
        cur[j] = 0;
        i = j + 1;
        if (cur[0] == 0) continue;
#if defined(_WIN32)
        // "C:" and friends: creating a bare drive prefix is not a step of
        // make_all, and the CRT would refuse it with a confusing error.
        // Windows-only — "a:" is a perfectly legal directory name on POSIX.
        if (cur[1] == ':' && cur[2] == 0) continue;
#endif
        if (fs_mkdir(cur, 0755) != 0) {
            int me = errno;
            // EEXIST is only ok if the existing entry is a directory
            fs_stat_t st;
            if (me != EEXIST || fs_stat(cur, &st) != 0 || !S_ISDIR(st.st_mode)) {
                BRes r = {0, fs_err_obj(cur, me == EEXIST ? ENOTDIR : me)};
                free(cur);
                return r;
            }
        }
    }
    free(cur);
    return (BRes){1, NULL};
}
long long beans_dir_make_all_out(char* path, void** e_out) { BRes r = beans_dir_make_all(path); *e_out = r.err; return r.val; }
static int name_cmp(const void* a, const void* b) {
    return strcmp(*(const char* const*)a, *(const char* const*)b);
}
BRes beans_dir_list(char* path) {
    fs_dir_t* d = fs_dir_open(path);
    if (!d) return (BRes){0, fs_err_obj_rc(path, errno)};
    char** names = NULL;
    long long cnt = 0, cap = 0;
    const char* name;
    while ((name = fs_dir_next(d)) != NULL) {
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        if (cnt == cap) {
            cap = cap ? cap * 2 : 16;
            names = realloc(names, (size_t)cap * sizeof(char*));
        }
        names[cnt++] = strdup(name);
    }
    fs_dir_close(d);
    qsort(names, (size_t)cnt, sizeof(char*), name_cmp); // deterministic
    BList* l = beans_list_new(1);
    for (long long i = 0; i < cnt; i++) {
        beans_list_push(l, (long long)rc_strdup(names[i]));
        free(names[i]);
    }
    free(names);
    return (BRes){(long long)l, NULL};
}
long long beans_dir_list_out(char* path, void** e_out) { BRes r = beans_dir_list(path); *e_out = r.err; return r.val; }
BRes beans_dir_remove(char* path) {
    if (rmdir(path) != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    return (BRes){1, NULL};
}
long long beans_dir_remove_out(char* path, void** e_out) { BRes r = beans_dir_remove(path); *e_out = r.err; return r.val; }
// Iterative delete: gather the tree pre-order (parent before child) with one
// DIR open at a time, then remove in reverse (deepest first). Recursion held
// one fd per level and a fixed 1024-byte path buffer that silently truncated
// deep paths; this heap-builds every path and caps open fds at one.
static int rm_tree(const char* p) {
#if defined(_WIN32)
    // fs_link_kind is the lstat: a link is unlinked, never walked into.
    int is_dir = 0, is_link = 0;
    if (fs_link_kind(p, &is_dir, &is_link) != 0) return -1;
    if (!is_dir) return unlink(p);
    if (is_link) return rmdir(p); // a link to a directory is a directory entry
#else
    struct stat st;
    if (lstat(p, &st) != 0) return -1;
    if (!S_ISDIR(st.st_mode)) return unlink(p);
#endif
    StrVec dirs = {0, 0, 0}; // dirs to rmdir, in discovery (pre) order
    StrVec stack = {0, 0, 0}; // dirs still to scan
    sv_push(&stack, strdup(p));
    int ok = 1;
    while (stack.len > 0) {
        char* dir = stack.v[--stack.len];
        fs_dir_t* d = fs_dir_open(dir);
        if (!d) {
            free(dir);
            ok = 0;
            break;
        }
        const char* name;
        while ((name = fs_dir_next(d)) != NULL) {
            if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
            char* sub = path_cat(dir, name);
#if defined(_WIN32)
            int sub_dir = 0, sub_link = 0;
            if (fs_link_kind(sub, &sub_dir, &sub_link) != 0) {
                free(sub);
                ok = 0;
                break;
            }
            if (sub_dir && !sub_link) sv_push(&stack, sub); // scan later
            else {
                if ((sub_dir ? rmdir(sub) : unlink(sub)) != 0) ok = 0;
                free(sub);
                if (!ok) break;
            }
#else
            struct stat cst;
            if (lstat(sub, &cst) != 0) {
                free(sub);
                ok = 0;
                break;
            }
            if (S_ISDIR(cst.st_mode)) sv_push(&stack, sub); // scan later
            else {
                if (unlink(sub) != 0) ok = 0;
                free(sub);
                if (!ok) break;
            }
#endif
        }
        fs_dir_close(d);
        sv_push(&dirs, dir); // remove this dir after its children
        if (!ok) break;
    }
    for (long long i = 0; i < stack.len; i++) free(stack.v[i]);
    free(stack.v);
    // deepest first: dirs were collected parent-before-child, so reverse
    for (long long i = dirs.len; ok && i-- > 0;) {
        if (rmdir(dirs.v[i]) != 0) ok = 0;
    }
    sv_free(&dirs);
    return ok ? 0 : -1;
}
BRes beans_dir_remove_all(char* path) {
#if defined(_WIN32)
    int is_dir = 0, is_link = 0;
    if (fs_link_kind(path, &is_dir, &is_link) != 0)
        return (BRes){0, fs_err_obj_rc(path, errno)};
#else
    struct stat st;
    if (lstat(path, &st) != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
#endif
    if (rm_tree(path) != 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    return (BRes){1, NULL};
}
long long beans_dir_remove_all_out(char* path, void** e_out) { BRes r = beans_dir_remove_all(path); *e_out = r.err; return r.val; }
long long beans_dir_exists(char* path) {
    fs_stat_t st;
    return fs_stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}
char* beans_dir_temp(void) {
#if BEANS_RT_WASI
    const char* beans_wasi_env(const char* name);
    const char* t = beans_wasi_env("TMPDIR");
#elif defined(_WIN32)
    // TMP is what the CRT itself consults; TMPDIR is honored first so a test
    // can pin the location with one spelling on every platform.
    const char* t = getenv("TMPDIR");
    if (!t || !*t) t = getenv("TMP");
    if (!t || !*t) t = getenv("TEMP");
#else
    const char* t = getenv("TMPDIR");
#endif
    const char* src = t && *t ? t : "/tmp";
    long long n = (long long)strlen(src);
    while (n > 1 && src[n - 1] == '/') n--; // trim trailing slashes
    return str_make(src, n);
}
BRes beans_dir_sync(char* path) {
#if defined(_WIN32)
    // The CRT cannot open a directory; a Win32 handle with backup semantics
    // can, and FlushFileBuffers on it is the directory-fsync of the database
    // commit pattern.
    wchar_t* wpath = win_widen(path);
    if (!wpath) return (BRes){0, fs_err_obj_rc(path, ENOMEM)};
    HANDLE h = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) {
        errno = fs_win_errno(GetLastError());
        return (BRes){0, fs_err_obj_rc(path, errno)};
    }
    // Directory metadata flushing is best-effort on Windows: NTFS journals
    // metadata itself, and FlushFileBuffers on a directory handle fails on
    // some filesystems. The open proving the directory exists is the part
    // the interpreter's answer also depends on.
    FlushFileBuffers(h);
    CloseHandle(h);
    return (BRes){1, NULL};
#else
    // the database commit pattern: fsync the directory after a rename
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return (BRes){0, fs_err_obj_rc(path, errno)};
    if (fsync(fd) != 0) {
        int e = errno;
        close(fd);
        return (BRes){0, fs_err_obj_rc(path, e)};
    }
    close(fd);
    return (BRes){1, NULL};
#endif
}
long long beans_dir_sync_out(char* path, void** e_out) { BRes r = beans_dir_sync(path); *e_out = r.err; return r.val; }


#endif // BEANS_RT_PROFILE >= BEANS_RT_FULL || BEANS_RT_WASI
#if BEANS_RT_PROFILE < BEANS_RT_MINIMAL
// Borrowed C callbacks are core: the generated C wrapper calls this probe to
// tell an ordinary closure from a StoredCallback. Freestanding targets cannot
// create the thread-safe stored form, so every callback is the synchronous
// wrapper and the probe always returns null.
void* beans_stored_callback_function(void* value) {
    (void)value;
    return NULL;
}
#endif
#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
// A stored callback is not an ARC object. Its owner is move-only Beans source
// and closes it explicitly after native code unregisters the function/context
// pair. The mutex is also the hand-off that makes close wait for calls already
// running on foreign threads.
#define BEANS_STORED_CALLBACK_MAGIC UINT64_C(0x4245414e53434231)
typedef struct {
    uint64_t magic;
    pthread_mutex_t mutex;
    pthread_cond_t idle;
    void* closure;
    void* function;
    unsigned active;
    int closing;
} BStoredCallback;

void* beans_stored_callback_new(void* closure, void* function) {
    BStoredCallback* callback =
        (BStoredCallback*)calloc(1, sizeof(BStoredCallback));
    if (!callback) beans_panic("out of memory", 0, 0);
    callback->magic = BEANS_STORED_CALLBACK_MAGIC;
    pthread_mutex_init(&callback->mutex, NULL);
    pthread_cond_init(&callback->idle, NULL);
    callback->closure = closure;
    callback->function = function;
    beans_retain(closure);
    return callback;
}

void* beans_stored_callback_function(void* value) {
    if (!value) return NULL;
    BStoredCallback* callback = (BStoredCallback*)value;
    return callback->magic == BEANS_STORED_CALLBACK_MAGIC
               ? callback->function
               : NULL;
}

void* beans_stored_callback_enter(void* value) {
    if (!value) return NULL;
    BStoredCallback* callback = (BStoredCallback*)value;
    if (callback->magic != BEANS_STORED_CALLBACK_MAGIC) return NULL;
    pthread_mutex_lock(&callback->mutex);
    void* closure = NULL;
    if (!callback->closing) {
        callback->active += 1;
        closure = callback->closure;
    }
    pthread_mutex_unlock(&callback->mutex);
    return closure;
}

void beans_stored_callback_leave(void* value) {
    BStoredCallback* callback = (BStoredCallback*)value;
    pthread_mutex_lock(&callback->mutex);
    if (callback->active) callback->active -= 1;
    if (callback->closing && callback->active == 0)
        pthread_cond_broadcast(&callback->idle);
    pthread_mutex_unlock(&callback->mutex);
}

void beans_stored_callback_close(void* value) {
    if (!value) return;
    BStoredCallback* callback = (BStoredCallback*)value;
    if (callback->magic != BEANS_STORED_CALLBACK_MAGIC) return;
    pthread_mutex_lock(&callback->mutex);
    callback->closing = 1;
    while (callback->active != 0)
        pthread_cond_wait(&callback->idle, &callback->mutex);
    void* closure = callback->closure;
    callback->closure = NULL;
    callback->magic = 0;
    pthread_mutex_unlock(&callback->mutex);
    beans_release(closure);
    pthread_cond_destroy(&callback->idle);
    pthread_mutex_destroy(&callback->mutex);
    free(callback);
}

void beans_tree_stored_close(void* value) {
    beans_stored_callback_close(value);
}

// The program's own arguments, its environment, exit, standard input, the clocks
// and the OS random source. Printing is *not* here — it is in the core beside the
// string code, because a freestanding program still has somewhere to put bytes.
// ---- std.os / std.io --------------------------------------------------------
static int os_argc;
static char** os_argv;
#if defined(_WIN32)
// Two things stage here and both are Windows-only. The arguments come from the
// CRT's wide argv so no text is lost through the active code page. The CRT also
// opens the standard streams in text mode, where
// every \n becomes \r\n on the way out; binary mode is what every POSIX
// platform does, and what byte-identical differential testing requires.
void beans_os_init(int argc, char** argv) {
    (void)argc;
    (void)argv;
    os_argc = __argc;
    // __argv is the ANSI copy: the CRT builds it by folding the real command
    // line through the process code page, so an argument outside it arrives as
    // '?' — the one place a Beans program cannot recover the text later.
    // __wargv holds the original, and the runtime speaks UTF-8 everywhere else.
    // If the conversion fails there is nothing better to fall back to than the
    // CRT's own answer, which is at least the same length.
    os_argv = __argv;
    if (__wargv) {
        char** wide = calloc((size_t)(__argc > 0 ? __argc : 1), sizeof(char*));
        if (wide) {
            int ok = 1;
            for (int i = 0; i < __argc && ok; i++) {
                wide[i] = win_narrow(__wargv[i]);
                if (!wide[i]) ok = 0;
            }
            if (ok) {
                os_argv = wide;
            } else {
                for (int i = 0; i < __argc; i++) free(wide[i]);
                free(wide);
            }
        }
    }
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
    // The runtime buffers redirected stdout itself (see rt_write); the flush
    // rides atexit so it runs after any panic message has hit stderr —
    // glibc's exit-time ordering, which merged-stream diffs depend on.
    atexit(win_out_flush);
}
#else
void beans_os_init(int argc, char** argv) {
    os_argc = argc;
    os_argv = argv;
}
#endif
BList* beans_os_args(void) {
    BList* l = beans_list_new(1);
    for (int i = 1; i < os_argc; i++) {
        beans_list_push(l, (long long)rc_strdup(os_argv[i]));
    }
    return l;
}
BOpt beans_os_env(char* name) {
#if defined(_WIN32)
    // Windows environment names are case-insensitive and the canonical
    // spelling is "Path", not "PATH"; getenv's case behaviour varies by CRT
    // (Wine's msvcrt misses the fold entirely), so the Win32 call is the truth.
    //
    // A zero return means two different things — the name is absent, or the
    // value exists and is empty — and only GetLastError tells them apart.
    // getenv("") on POSIX returns a pointer to "", which is some(""), so
    // folding both into none would make the same program answer differently on
    // the two platforms.
    wchar_t* wname = win_widen(name);
    if (!wname) return (BOpt){0, 0};
    wchar_t small[512];
    SetLastError(ERROR_SUCCESS);
    unsigned long n =
        GetEnvironmentVariableW(wname, small, sizeof small / sizeof small[0]);
    wchar_t* wide = small;
    wchar_t* big = NULL;
    if (n == 0) {
        DWORD why = GetLastError();
        free(wname);
        if (why == ERROR_ENVVAR_NOT_FOUND) return (BOpt){0, 0};
        return (BOpt){(long long)rc_strdup(""), 1};
    }
    if (n >= sizeof small / sizeof small[0]) {
        big = malloc(((size_t)n + 1) * sizeof(wchar_t));
        if (!big) {
            free(wname);
            return (BOpt){0, 0};
        }
        unsigned long got = GetEnvironmentVariableW(wname, big, n + 1);
        if (got == 0 || got > n) {
            free(big);
            free(wname);
            return (BOpt){0, 0};
        }
        wide = big;
    }
    free(wname);
    char* utf8 = win_narrow(wide);
    free(big);
    if (!utf8) return (BOpt){0, 0};
    BOpt out = (BOpt){(long long)rc_strdup(utf8), 1};
    free(utf8);
    return out;
#else
    const char* v = getenv(name);
    if (!v) return (BOpt){0, 0};
    return (BOpt){(long long)rc_strdup(v), 1};
#endif
}
long long beans_os_env_out(char* name, long long* has_out) { BOpt o = beans_os_env(name); *has_out = o.has; return o.val; }
void beans_os_exit(long long code) { exit((int)code); }
int32_t beans_c_errno(void) { return (int32_t)errno; }
void beans_c_set_errno(int32_t value) { errno = (int)value; }
// ---- clocks -----------------------------------------------------------------
//
// Two clocks, and which one a caller wants is never ambiguous:
//
//   monotonic — for measuring how long something took. Never goes backwards and is
//     unaffected by the administrator or NTP setting the date. It has no meaning as
//     a date; only differences between readings mean anything.
//   wall — for saying when something happened. Can jump forwards or backwards, so
//     measuring a duration with it is a bug, which is why it is a separate name
//     rather than a flag.
long long beans_time_monotonic_nanos(void) {
#if defined(_WIN32)
    LARGE_INTEGER count, frequency;
    QueryPerformanceCounter(&count);
    QueryPerformanceFrequency(&frequency);
    return (long long)(count.QuadPart / frequency.QuadPart) * 1000000000LL +
           (long long)((count.QuadPart % frequency.QuadPart) * 1000000000LL /
                       frequency.QuadPart);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}
long long beans_time_wall_nanos(void) {
#if defined(_WIN32)
    FILETIME file_time;
    ULARGE_INTEGER ticks;
    GetSystemTimeAsFileTime(&file_time);
    ticks.LowPart = file_time.dwLowDateTime;
    ticks.HighPart = file_time.dwHighDateTime;
    return (long long)((ticks.QuadPart - 116444736000000000ULL) * 100ULL);
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}
static void beans_wall_timespec(struct timespec* out) {
    long long nanos = beans_time_wall_nanos();
    out->tv_sec = (time_t)(nanos / 1000000000LL);
    out->tv_nsec = (long)(nanos % 1000000000LL);
}
// Sleeps at least this long. A signal can cut nanosleep short, so the remaining time
// is retried rather than returned early — a "sleep 10ms" that sometimes sleeps 2ms
// is a race waiting to be blamed on something else.
#if defined(_WIN32)
// Windows counts a sleep in whole timer ticks, and the tick already in progress
// when the call is made counts as one of them — so at the default 15.6ms
// resolution Sleep(3) can return after a fraction of a millisecond. That is the
// opposite failure from the POSIX one above (a signal cutting the sleep short),
// but it breaks the same promise, and it broke it silently: the sleep floor held
// under Wine, which sleeps through the host's nanosleep, and only a real Windows
// machine showed a 3ms sleep measuring under 3ms. The deadline decides here, not
// the OS call.
void beans_time_sleep_nanos(long long nanos) {
    if (nanos <= 0) return;
    long long deadline = beans_time_monotonic_nanos() + nanos;
    for (;;) {
        long long left = deadline - beans_time_monotonic_nanos();
        if (left <= 0) return;
        // Round the millisecond conversion up: truncating would ask for 0ms on
        // the last fractional millisecond and spin.
        Sleep((DWORD)((left + 999999LL) / 1000000LL));
    }
}
#else
void beans_time_sleep_nanos(long long nanos) {
    if (nanos <= 0) return;
    struct timespec want;
    want.tv_sec = (time_t)(nanos / 1000000000LL);
    want.tv_nsec = (long)(nanos % 1000000000LL);
    struct timespec left;
    while (nanosleep(&want, &left) != 0 && errno == EINTR) want = left;
}
#endif

// ---- secure random ----------------------------------------------------------
//
// The OS CSPRNG, and nothing else. There is deliberately no fallback to a
// pseudo-random generator: a caller asking for random bytes is usually generating a
// key, a token or a nonce, and silently giving them a predictable sequence when the
// real source is unavailable is worse than failing. Every entry point here returns a
// Result.
static int beans_random_fill(unsigned char* out, size_t count) {
#if defined(__APPLE__)
    arc4random_buf(out, count);
    return 1;
#elif defined(__linux__)
    size_t done = 0;
    while (done < count) {
        // getrandom can return a short read and can be interrupted, so it loops.
        long got = syscall(SYS_getrandom, out + done, count - done, 0);
        if (got < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        if (got == 0) return 0;
        done += (size_t)got;
    }
    return 1;
#elif defined(_WIN32)
    // rand_s is the CRT's front door to the OS CSPRNG (RtlGenRandom), and the
    // one entropy source reachable without linking bcrypt. It fills a fixed
    // 4 bytes per call, so the tail copy handles counts that are not a
    // multiple of four.
    size_t done = 0;
    while (done < count) {
        unsigned int word = 0;
        if (rand_s(&word) != 0) return 0;
        size_t take = count - done < sizeof word ? count - done : sizeof word;
        memcpy(out + done, &word, take);
        done += take;
    }
    return 1;
#else
    (void)out;
    (void)count;
    return 0;
#endif
}

BRes beans_random_bytes(long long count) {
    BRes result;
    result.err = 0;
    result.val = 0;
    if (count < 0) {
        result.err = mk_error("random byte count must not be negative", "invalid");
        return result;
    }
    BList* out = bytes_mk(count);
    if (count > 0 &&
        !beans_random_fill((unsigned char*)out->data, (size_t)count)) {
        beans_release(out);
        result.err = mk_error("no OS random source available", "io");
        return result;
    }
    result.val = (long long)(intptr_t)out;
    return result;
}
long long beans_random_bytes_out(long long count, void** e_out) { BRes r = beans_random_bytes(count); *e_out = r.err; return r.val; }

BRes beans_random_u64(void) {
    BRes result;
    result.err = 0;
    result.val = 0;
    unsigned long long bits = 0;
    if (!beans_random_fill((unsigned char*)&bits, sizeof bits)) {
        result.err = mk_error("no OS random source available", "io");
        return result;
    }
    result.val = (long long)bits;
    return result;
}
long long beans_random_u64_out(void** e_out) { BRes r = beans_random_u64(); *e_out = r.err; return r.val; }

// Uniform in 0..limit-1, by rejection rather than by modulo. `% limit` is biased
// unless limit divides 2^64, and for a shuffle or a token that bias is the whole
// problem.
BRes beans_random_below(long long limit) {
    BRes result;
    result.err = 0;
    result.val = 0;
    if (limit <= 0) {
        result.err = mk_error("random bound must be positive", "invalid");
        return result;
    }
    unsigned long long bound = (unsigned long long)limit;
    // The largest multiple of bound that fits; anything at or above it is rejected.
    unsigned long long ceiling = (~0ULL / bound) * bound;
    for (;;) {
        unsigned long long bits = 0;
        if (!beans_random_fill((unsigned char*)&bits, sizeof bits)) {
            result.err = mk_error("no OS random source available", "io");
            return result;
        }
        if (bits < ceiling) {
            result.val = (long long)(bits % bound);
            return result;
        }
    }
}
long long beans_random_below_out(long long limit, void** e_out) { BRes r = beans_random_below(limit); *e_out = r.err; return r.val; }

long long beans_os_now_ms(void) {
    return beans_time_wall_nanos() / 1000000LL;
}
long long beans_os_ticks_ms(void) {
    return beans_time_monotonic_nanos() / 1000000LL;
}
// One sleep floor for the whole runtime: the bounded waits in waitpid and the
// poller back off through this, and a sleep that can return early turns those
// budgets into busy loops on Windows.
void beans_os_sleep_ms(long long ms) {
    if (ms > 0) beans_time_sleep_nanos(ms * 1000000LL);
}
BOpt beans_io_read_line(void) {
    char* out = NULL;
    long long len = 0, cap = 0;
    int c;
    int any = 0;
    while ((c = fgetc(stdin)) != EOF) {
        any = 1;
        if (c == '\n') break;
        if (len == cap) {
            cap = cap ? cap * 2 : 128;
            out = realloc(out, (size_t)cap);
        }
        out[len++] = (char)c;
    }
    if (!any) {
        free(out);
        return (BOpt){0, 0};
    }
    char* s = str_make(out ? out : "", len);
    free(out);
    return (BOpt){(long long)s, 1};
}
long long beans_io_read_line_out(long long* has_out) { BOpt o = beans_io_read_line(); *has_out = o.has; return o.val; }
char* beans_io_read_all(void) {
    char* out = NULL;
    long long len = 0, cap = 0;
    char chunk[65536];
    size_t r;
    while ((r = fread(chunk, 1, sizeof chunk, stdin)) > 0) {
        if (len + (long long)r > cap) {
            cap = cap ? cap * 2 : 65536;
            while (cap < len + (long long)r) cap *= 2;
            out = realloc(out, (size_t)cap);
        }
        memcpy(out + len, chunk, r);
        len += r;
    }
    char* s = str_make(out ? out : "", len);
    free(out);
    return s;
}

#endif // BEANS_RT_PROFILE >= BEANS_RT_MINIMAL

#if BEANS_RT_PROFILE < BEANS_RT_MINIMAL
// Freestanding and WASI programs do not use the C process argv. WASI obtains
// arguments from its host calls below; a true freestanding program has none.
void beans_os_init(int argc, char** argv) {
    (void)argc;
    (void)argv;
}
#endif

#if BEANS_RT_PROFILE < BEANS_RT_MINIMAL && BEANS_RT_WASI
// WASIp1 supplies a small hosted surface without turning on the POSIX runtime.
// The host owns the raw WASI ABI and these functions build ordinary Beans
// values, so the rest of codegen keeps the same symbols on every target.
const char* beans_wasi_arg(long long index);
const char* beans_wasi_env(const char* name);
long long beans_wasi_clock_monotonic(void);
long long beans_wasi_clock_wall(void);
void beans_wasi_sleep(long long nanos);
int beans_wasi_random_fill(void* out, unsigned long long count);
long long beans_wasi_read_stdin(void* out, unsigned long long count);

BList* beans_os_args(void) {
    BList* list = beans_list_new(1);
    for (long long index = 0;; index++) {
        const char* argument = beans_wasi_arg(index);
        if (!argument) break;
        beans_list_push(list, (long long)(intptr_t)rc_strdup(argument));
    }
    return list;
}

BOpt beans_os_env(char* name) {
    const char* value = beans_wasi_env(name);
    if (!value) return (BOpt){0, 0};
    return (BOpt){(long long)(intptr_t)rc_strdup(value), 1};
}
long long beans_os_env_out(char* name, long long* has_out) { BOpt o = beans_os_env(name); *has_out = o.has; return o.val; }

void beans_os_exit(long long code) { beans_host_exit((int)code); }
int32_t beans_c_errno(void);
void beans_c_set_errno(int32_t value);

long long beans_time_monotonic_nanos(void) {
    return beans_wasi_clock_monotonic();
}
long long beans_time_wall_nanos(void) { return beans_wasi_clock_wall(); }
void beans_time_sleep_nanos(long long nanos) {
    if (nanos > 0) beans_wasi_sleep(nanos);
}

long long beans_os_now_ms(void) {
    return beans_time_wall_nanos() / 1000000LL;
}
long long beans_os_ticks_ms(void) {
    return beans_time_monotonic_nanos() / 1000000LL;
}
void beans_os_sleep_ms(long long ms) {
    if (ms > 0) beans_time_sleep_nanos(ms * 1000000LL);
}

static int beans_wasi_random_bytes(unsigned char* out, size_t count) {
    return beans_wasi_random_fill(out, (unsigned long long)count);
}

BRes beans_random_bytes(long long count) {
    if (count < 0)
        return (BRes){0, mk_error("random byte count must not be negative",
                                  "invalid")};
    BList* out = bytes_mk(count);
    if (count > 0 &&
        !beans_wasi_random_bytes((unsigned char*)out->data, (size_t)count)) {
        beans_release(out);
        return (BRes){0, mk_error("no OS random source available", "io")};
    }
    return (BRes){(long long)(intptr_t)out, NULL};
}
long long beans_random_bytes_out(long long count, void** e_out) { BRes r = beans_random_bytes(count); *e_out = r.err; return r.val; }

BRes beans_random_u64(void) {
    unsigned long long bits = 0;
    if (!beans_wasi_random_bytes((unsigned char*)&bits, sizeof bits))
        return (BRes){0, mk_error("no OS random source available", "io")};
    return (BRes){(long long)bits, NULL};
}
long long beans_random_u64_out(void** e_out) { BRes r = beans_random_u64(); *e_out = r.err; return r.val; }

BRes beans_random_below(long long limit) {
    if (limit <= 0)
        return (BRes){0, mk_error("random bound must be positive", "invalid")};
    unsigned long long bound = (unsigned long long)limit;
    unsigned long long ceiling = (~0ULL / bound) * bound;
    for (;;) {
        unsigned long long bits = 0;
        if (!beans_wasi_random_bytes((unsigned char*)&bits, sizeof bits))
            return (BRes){0, mk_error("no OS random source available", "io")};
        if (bits < ceiling) return (BRes){(long long)(bits % bound), NULL};
    }
}
long long beans_random_below_out(long long limit, void** e_out) { BRes r = beans_random_below(limit); *e_out = r.err; return r.val; }

BOpt beans_io_read_line(void) {
    char* bytes = NULL;
    long long length = 0;
    long long capacity = 0;
    int any = 0;
    for (;;) {
        unsigned char byte = 0;
        long long read = beans_wasi_read_stdin(&byte, 1);
        if (read <= 0) break;
        any = 1;
        if (byte == '\n') break;
        if (length == capacity) {
            capacity = capacity ? capacity * 2 : 128;
            bytes = rt_realloc(bytes, (unsigned long long)capacity);
        }
        bytes[length++] = (char)byte;
    }
    if (!any) return (BOpt){0, 0};
    char* result = str_make(bytes ? bytes : "", length);
    rt_free(bytes);
    return (BOpt){(long long)(intptr_t)result, 1};
}
long long beans_io_read_line_out(long long* has_out) { BOpt o = beans_io_read_line(); *has_out = o.has; return o.val; }

char* beans_io_read_all(void) {
    char* bytes = NULL;
    long long length = 0;
    long long capacity = 0;
    char chunk[4096];
    for (;;) {
        long long read = beans_wasi_read_stdin(chunk, sizeof chunk);
        if (read <= 0) break;
        if (length + read > capacity) {
            capacity = capacity ? capacity * 2 : 4096;
            while (capacity < length + read) capacity *= 2;
            bytes = rt_realloc(bytes, (unsigned long long)capacity);
        }
        memcpy(bytes + length, chunk, (size_t)read);
        length += read;
    }
    char* result = str_make(bytes ? bytes : "", length);
    rt_free(bytes);
    return result;
}
#endif

#if BEANS_RT_PROFILE >= BEANS_RT_FULL
// sockets, the readiness poller and dynamic libraries — POSIX and Windows
// both, with the Win32 branches inline where the platforms differ. The real
// signals section further down stays POSIX-only; Windows gets refusing stubs
// for its symbols, so the compiler's own interpreter still links there.
// ---- sockets ----------------------------------------------------------------
//
// Plain descriptors. The owning move-only handles (TcpListener, TcpStream, UdpSocket)
// are written in Beans in stdlib/std/net; this layer is only the syscalls, and every
// message and kind slug it builds is mirrored byte for byte in builtins.cpp.
//
// Three rules hold everywhere below:
//
//   The address family is never chosen by the caller. Every entry point resolves the
//   host through getaddrinfo and tries the candidates in order, so "localhost",
//   "127.0.0.1" and "::1" all work and there is no flag to get wrong.
//
//   Every blocking call retries EINTR. A signal must never turn into a short read or
//   a spurious failure.
//
//   Every descriptor is close-on-exec, and writing to a dead peer never raises
//   SIGPIPE. Both are set per socket, so no global process state changes.

#if defined(_WIN32)
// Winsock, not the CRT: sockets are kernel handles with their own error
// channel and close call. windows.h came in with the fs shim — lean-and-mean,
// so the ancient winsock.h never got there first.
#include <winsock2.h>
#include <ws2tcpip.h>

// Winsock refuses every call until WSAStartup, so every entry point latches it
// on the way in. A second thread spins for the first rather than racing past a
// startup still in flight. Never torn down — process exit releases it.
static void net_init(void) {
    static volatile LONG begun = 0, ready = 0;
    if (ready) return;
    if (InterlockedExchange((LONG*)&begun, 1) == 0) {
        WSADATA wsadata;
        WSAStartup(MAKEWORD(2, 2), &wsadata);
        InterlockedExchange((LONG*)&ready, 1);
    } else {
        while (!ready) Sleep(0);
    }
}

// Winsock errors do not land in errno. Map them onto the POSIX names the
// shared code below already tests, so one switch of kind slugs serves both
// platforms. Callable on a value too: SO_ERROR hands back WSA codes as well.
static int net_errno_map(int e) {
    switch (e) {
        case WSAEWOULDBLOCK: return EWOULDBLOCK;
        case WSAEINTR: return EINTR;
        case WSAECONNREFUSED: return ECONNREFUSED;
        case WSAECONNRESET: return ECONNRESET;
        case WSAECONNABORTED: return ECONNABORTED;
        case WSAEADDRINUSE: return EADDRINUSE;
        case WSAEADDRNOTAVAIL: return EADDRNOTAVAIL;
        case WSAETIMEDOUT: return ETIMEDOUT;
        case WSAEHOSTUNREACH: return EHOSTUNREACH;
        case WSAENETUNREACH: return ENETUNREACH;
        case WSAENETDOWN: return ENETDOWN;
        case WSAEACCES: return EACCES;
        case WSAEAFNOSUPPORT: return EAFNOSUPPORT;
        case WSAEBADF:
        case WSAENOTSOCK: return EBADF;
        case WSAENOTCONN: return ENOTCONN;
        case WSAEINVAL: return EINVAL;
        case WSAEMFILE: return EMFILE;
        default: return EIO;
    }
}
static int net_errno(void) { return net_errno_map((int)WSAGetLastError()); }
#define net_close(fd) closesocket((SOCKET)(fd))
// shutdown's three modes: same values, Winsock spelling.
#define SHUT_RD SD_RECEIVE
#define SHUT_WR SD_SEND
#define SHUT_RDWR SD_BOTH
#else
#define net_init() ((void)0)
#define net_errno() errno
#define net_close(fd) close(fd)
#endif

// One descriptor type for the whole section. A Windows SOCKET is a pointer-sized
// kernel handle and Microsoft is explicit that it must not be narrowed to int or
// tested with `< 0` — handle values happen to fit in 32 bits today for 32/64-bit
// interop, but nothing in the contract says a valid one cannot set the sign bit,
// and truncating is the kind of bug that works on every machine until it does
// not.
//
// The Beans ABI carries a descriptor as a signed 64-bit word, which holds either
// shape whole: INVALID_SOCKET converts to -1 there, so the "negative means
// closed" test the entry points already make stays exactly true, and no valid
// handle loses a bit crossing the boundary. Only the conversions are named; the
// word representation is unchanged.
#if defined(_WIN32)
typedef SOCKET net_fd_t;
#define NET_FD_NONE INVALID_SOCKET
#define net_fd_ok(fd) ((fd) != INVALID_SOCKET)
#define net_fd_word(fd) ((long long)(SOCKET)(fd))
#define net_fd_of(word) ((net_fd_t)(SOCKET)(word))
#else
typedef int net_fd_t;
#define NET_FD_NONE (-1)
#define net_fd_ok(fd) ((fd) >= 0)
#define net_fd_word(fd) ((long long)(fd))
#define net_fd_of(word) ((net_fd_t)(word))
#endif

// MSG_NOSIGNAL on Linux, SO_NOSIGPIPE at socket creation on macOS. Without one of
// them a write to a closed peer kills the process, and which one exists differs by
// platform — so both are set and the behaviour is identical. On Windows the 0 it
// degrades to is already right: there is no SIGPIPE at all, which is exactly the
// state the POSIX side arranges.
#ifdef MSG_NOSIGNAL
#define NET_NOSIGNAL MSG_NOSIGNAL
#else
#define NET_NOSIGNAL 0
#endif

// errno -> Error.kind slug. builtins.cpp holds the identical switch.
static const char* net_kind_of(int err) {
    switch (err) {
        case ECONNREFUSED: return "refused";
        case EADDRINUSE:
        case EADDRNOTAVAIL: return "in_use";
        case EAGAIN:
#if defined(EWOULDBLOCK) && EWOULDBLOCK != EAGAIN
        case EWOULDBLOCK:
#endif
        case ETIMEDOUT: return "timeout";
        case ECONNRESET:
        case ECONNABORTED:
        case EPIPE: return "reset";
        case EHOSTUNREACH:
        case ENETUNREACH:
        case ENETDOWN: return "unreachable";
        case EACCES:
        case EPERM: return "permission";
        case EAFNOSUPPORT:
        case EPROTONOSUPPORT: return "unsupported";
        case EBADF:
        case ENOTCONN: return "closed";
        default: return "io";
    }
}

// "<op> <host>:<port>: <strerror>" — the address is in the message because
// "Connection refused" alone never says what was refused.
static void* net_err_at(const char* op, const char* host, long long port, int err) {
    char b[320];
    snprintf(b, sizeof b, "%s %s:%lld: %s", op, host ? host : "", port, strerror(err));
    return mk_error(b, net_kind_of(err));
}
static void* net_err_op(const char* op, int err) {
    char b[160];
    snprintf(b, sizeof b, "%s: %s", op, strerror(err));
    return mk_error(b, net_kind_of(err));
}
static void* net_closed_err(const char* op) {
    char b[64];
    snprintf(b, sizeof b, "%s: socket is closed", op);
    return mk_error(b, "closed");
}
// getaddrinfo has its own error space, and EAI_SYSTEM defers to errno.
// Windows has no EAI_SYSTEM — its EAI_* values are WSA errors already.
static void* net_gai_err(const char* host, int rc) {
#ifdef EAI_SYSTEM
    if (rc == EAI_SYSTEM) return net_err_op("resolve", errno);
#endif
    const char* kind = "io";
    if (rc == EAI_NONAME
#ifdef EAI_NODATA
        || rc == EAI_NODATA
#endif
    ) kind = "not_found";
    if (rc == EAI_FAMILY || rc == EAI_SOCKTYPE) kind = "unsupported";
    char b[320];
    snprintf(b, sizeof b, "resolve %s: %s", host ? host : "", gai_strerror(rc));
    return mk_error(b, kind);
}

static long long net_millis(void) { return beans_time_monotonic_nanos() / 1000000LL; }

static struct addrinfo* net_lookup(const char* host, long long port, int socktype,
                                   int passive, int* rc_out) {
    char service[16];
    snprintf(service, sizeof service, "%lld", port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = socktype;
    hints.ai_flags = AI_NUMERICSERV | (passive ? AI_PASSIVE : 0);
    struct addrinfo* list = NULL;
    int rc = getaddrinfo(host, service, &hints, &list);
    *rc_out = rc;
    return rc == 0 ? list : NULL;
}

static void net_set_cloexec(net_fd_t fd) {
#if defined(_WIN32)
    // Nothing to clear: a Win32 handle is only inherited when a spawn asks for
    // it, which is the state FD_CLOEXEC exists to arrange.
    (void)fd;
#else
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
#endif
}

static net_fd_t net_socket(struct addrinfo* ai) {
    net_fd_t fd = NET_FD_NONE;
#ifdef SOCK_CLOEXEC
    // One call, no window in which a fork could inherit the descriptor.
    fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
    if (!net_fd_ok(fd) && net_errno() != EINVAL && net_errno() != EPROTONOSUPPORT)
        return NET_FD_NONE;
#endif
    if (!net_fd_ok(fd)) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (!net_fd_ok(fd)) return NET_FD_NONE;
        net_set_cloexec(fd);
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    return fd;
}

// Waits for one readiness event with a deadline that survives EINTR: the budget is
// recomputed from the monotonic clock, so a stream of signals cannot extend a 100ms
// wait indefinitely. timeout_ms < 0 waits forever. Returns 1 ready, 0 timed out,
// -1 error (errno set).
static int net_wait(net_fd_t fd, short events, long long timeout_ms) {
    long long deadline = timeout_ms < 0 ? 0 : net_millis() + timeout_ms;
    for (;;) {
#if defined(_WIN32)
        WSAPOLLFD pfd; // same fields as pollfd, which Windows does not declare
#else
        struct pollfd pfd;
#endif
        pfd.fd = fd;
        pfd.events = events;
        pfd.revents = 0;
        int budget = -1;
        if (timeout_ms >= 0) {
            long long left = deadline - net_millis();
            if (left < 0) left = 0;
            budget = left > 0x7fffffffLL ? 0x7fffffff : (int)left;
        }
#if defined(_WIN32)
        int ready = WSAPoll(&pfd, 1, budget);
#else
        int ready = poll(&pfd, 1, budget);
#endif
        if (ready > 0) return 1;
        if (ready == 0) return 0;
        if (net_errno() == EINTR) continue;
        return -1;
    }
}

static int net_check_port(long long port) { return port >= 0 && port <= 65535; }

BRes beans_net_listen(char* host, long long port, long long backlog) {
    net_init();
    if (!host || beans_slen(host) == 0)
        return (BRes){0, mk_error("a host is required — write \"127.0.0.1\" or "
                                  "\"0.0.0.0\" rather than leaving it empty",
                                  "invalid")};
    if (!net_check_port(port))
        return (BRes){0, mk_error("port must be 0..65535", "invalid")};
    if (backlog < 1) backlog = 1;
    if (backlog > 1024) backlog = 1024;
    int rc = 0;
    struct addrinfo* list = net_lookup(host, port, SOCK_STREAM, 1, &rc);
    if (!list) return (BRes){0, net_gai_err(host, rc)};
    int last = 0;
    for (struct addrinfo* ai = list; ai; ai = ai->ai_next) {
        net_fd_t fd = net_socket(ai);
        if (!net_fd_ok(fd)) { last = net_errno(); continue; }
        // SO_REUSEADDR so a restart is not blocked by TIME_WAIT. Deliberately not
        // SO_REUSEPORT: that lets two live listeners share a port, which hides a
        // genuine "already running" mistake instead of reporting it. Winsock's
        // SO_REUSEADDR *is* that mistake — it lets a second listener steal the
        // port — and a TIME_WAIT rebind already works there without it, so the
        // exclusive flag states the same intent instead.
        int one = 1;
#if defined(_WIN32)
        setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&one,
                   sizeof one);
#else
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#endif
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 &&
            listen(fd, (int)backlog) == 0) {
            freeaddrinfo(list);
            return (BRes){net_fd_word(fd), NULL};
        }
        last = net_errno();
        net_close(fd);
    }
    freeaddrinfo(list);
    return (BRes){0, net_err_at("listen", host, port,
                                last ? last : EADDRNOTAVAIL)};
}
long long beans_net_listen_out(char* host, long long port, long long backlog, void** e_out) { BRes r = beans_net_listen(host, port, backlog); *e_out = r.err; return r.val; }

static net_fd_t net_connect_one(struct addrinfo* ai, long long timeout_ms,
                                int* err_out) {
    net_fd_t fd = net_socket(ai);
    if (!net_fd_ok(fd)) { *err_out = net_errno(); return NET_FD_NONE; }
#if defined(_WIN32)
    u_long nb = 1;
    ioctlsocket(fd, FIONBIO, &nb);
#else
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
    int rc;
    do { rc = connect(fd, ai->ai_addr, ai->ai_addrlen); }
    while (rc < 0 && net_errno() == EINTR);
    if (rc != 0) {
        int started = net_errno();
#if defined(_WIN32)
        // Winsock reports a nonblocking connect in flight as WSAEWOULDBLOCK,
        // never EINPROGRESS.
        int in_flight = started == EWOULDBLOCK;
#else
        int in_flight = started == EINPROGRESS;
#endif
        if (!in_flight) {
            *err_out = started;
            net_close(fd);
            return NET_FD_NONE;
        }
        // The handshake is in flight. Waiting on the descriptor is the only correct
        // wait: connect() cannot be restarted after EINTR — a second call reports
        // EALREADY — so the deadline is enforced by poll, not by retrying connect.
        // (WSAPoll before Windows 10 2004 never reports a *failed* connect, so a
        // refusal there is seen at the deadline rather than at once.)
        int ready = net_wait(fd, POLLOUT, timeout_ms);
        if (ready <= 0) {
            *err_out = ready == 0 ? ETIMEDOUT : net_errno();
            net_close(fd);
            return NET_FD_NONE;
        }
        int soerr = 0;
        socklen_t len = sizeof soerr;
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&soerr, &len) != 0)
            soerr = net_errno();
#if defined(_WIN32)
        // SO_ERROR hands back a WSA code, same as the thread state.
        else soerr = soerr ? net_errno_map(soerr) : 0;
#endif
        if (soerr != 0) {
            *err_out = soerr;
            net_close(fd);
            return NET_FD_NONE;
        }
    }
    // Back to blocking: the caller asked for a stream, not a poller registration.
#if defined(_WIN32)
    nb = 0;
    ioctlsocket(fd, FIONBIO, &nb);
#else
    if (flags >= 0) fcntl(fd, F_SETFL, flags);
#endif
    return fd;
}

BRes beans_net_connect(char* host, long long port, long long timeout_ms) {
    net_init();
    if (!host || beans_slen(host) == 0)
        return (BRes){0, mk_error("a host is required", "invalid")};
    if (!net_check_port(port))
        return (BRes){0, mk_error("port must be 0..65535", "invalid")};
    int rc = 0;
    struct addrinfo* list = net_lookup(host, port, SOCK_STREAM, 0, &rc);
    if (!list) return (BRes){0, net_gai_err(host, rc)};
    int last = 0;
    for (struct addrinfo* ai = list; ai; ai = ai->ai_next) {
        net_fd_t fd = net_connect_one(ai, timeout_ms, &last);
        if (net_fd_ok(fd)) {
            freeaddrinfo(list);
            return (BRes){net_fd_word(fd), NULL};
        }
    }
    freeaddrinfo(list);
    return (BRes){0, net_err_at("connect", host, port,
                                last ? last : ECONNREFUSED)};
}
long long beans_net_connect_out(char* host, long long port, long long timeout_ms, void** e_out) { BRes r = beans_net_connect(host, port, timeout_ms); *e_out = r.err; return r.val; }

BRes beans_net_udp_bind(char* host, long long port) {
    net_init();
    if (!host || beans_slen(host) == 0)
        return (BRes){0, mk_error("a host is required", "invalid")};
    if (!net_check_port(port))
        return (BRes){0, mk_error("port must be 0..65535", "invalid")};
    int rc = 0;
    struct addrinfo* list = net_lookup(host, port, SOCK_DGRAM, 1, &rc);
    if (!list) return (BRes){0, net_gai_err(host, rc)};
    int last = 0;
    for (struct addrinfo* ai = list; ai; ai = ai->ai_next) {
        net_fd_t fd = net_socket(ai);
        if (!net_fd_ok(fd)) { last = net_errno(); continue; }
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            freeaddrinfo(list);
            return (BRes){net_fd_word(fd), NULL};
        }
        last = net_errno();
        net_close(fd);
    }
    freeaddrinfo(list);
    return (BRes){0, net_err_at("bind", host, port, last ? last : EADDRNOTAVAIL)};
}
long long beans_net_udp_bind_out(char* host, long long port, void** e_out) { BRes r = beans_net_udp_bind(host, port); *e_out = r.err; return r.val; }

BRes beans_net_accept(long long fd, long long timeout_ms) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("accept")};
    long long deadline = timeout_ms < 0 ? 0 : net_millis() + timeout_ms;
    for (;;) {
        long long budget = timeout_ms;
        if (timeout_ms >= 0) {
            budget = deadline - net_millis();
            if (budget < 0) budget = 0;
        }
        int ready = net_wait(net_fd_of(fd), POLLIN, budget);
        if (ready == 0) return (BRes){0, net_err_op("accept", ETIMEDOUT)};
        if (ready < 0) return (BRes){0, net_err_op("accept", net_errno())};
        net_fd_t got;
        do { got = accept(net_fd_of(fd), NULL, NULL); }
        while (!net_fd_ok(got) && net_errno() == EINTR);
        if (net_fd_ok(got)) {
            net_set_cloexec(got);
#ifdef SO_NOSIGPIPE
            int one = 1;
            setsockopt(got, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
            return (BRes){net_fd_word(got), NULL};
        }
        // Readiness is a hint, not a promise: a peer that connected and aborted
        // before accept leaves the listener readable with nothing to take. Waiting
        // again is correct — but only when a deadline is bounding the loop, and
        // timeout_ms < 0 means the caller asked to block until a real connection.
        int e = net_errno();
        if (e == EAGAIN || e == EWOULDBLOCK || e == ECONNABORTED) continue;
        return (BRes){0, net_err_op("accept", e)};
    }
}
long long beans_net_accept_out(long long fd, long long timeout_ms, void** e_out) { BRes r = beans_net_accept(fd, timeout_ms); *e_out = r.err; return r.val; }

BRes beans_net_send(long long fd, BList* data, long long from) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("send")};
    if (!data) return (BRes){0, mk_error("send: no data", "invalid")};
    if (from < 0 || from > data->len)
        return (BRes){0, mk_error("send: offset is outside the data", "invalid")};
    long long want = data->len - from;
    if (want == 0) return (BRes){0, NULL}; // nothing to do, and not an error
#if defined(_WIN32)
    // Winsock counts in int; a short write is already in the contract.
    if (want > 0x7fffffff) want = 0x7fffffff;
#endif
    rt_ssize_t wrote;
    do {
        wrote = send(net_fd_of(fd), (const char*)data->data + from, (size_t)want,
                     NET_NOSIGNAL);
    } while (wrote < 0 && net_errno() == EINTR);
    if (wrote < 0) return (BRes){0, net_err_op("send", net_errno())};
    return (BRes){(long long)wrote, NULL};
}
long long beans_net_send_out(long long fd, BList* data, long long from, void** e_out) { BRes r = beans_net_send(fd, data, from); *e_out = r.err; return r.val; }

BRes beans_net_recv(long long fd, long long max) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("recv")};
    if (max <= 0)
        return (BRes){0, mk_error("recv: the byte count must be positive — an empty "
                                  "result already means end of stream", "invalid")};
#if defined(_WIN32)
    if (max > 0x7fffffff) max = 0x7fffffff; // Winsock counts in int
#endif
    BList* buf = bytes_mk(max);
    rt_ssize_t got;
    do { got = recv(net_fd_of(fd), (char*)buf->data, (size_t)max, 0); }
    while (got < 0 && net_errno() == EINTR);
#if defined(_WIN32)
    // A datagram larger than the buffer still fills it; POSIX truncates
    // silently, so the WSAEMSGSIZE dressing is stripped to match.
    if (got < 0 && WSAGetLastError() == WSAEMSGSIZE) got = (rt_ssize_t)max;
#endif
    if (got < 0) {
        int e = net_errno();
        beans_release(buf);
        return (BRes){0, net_err_op("recv", e)};
    }
    buf->len = got; // 0 = the peer closed; capacity stays, len is the truth
    return (BRes){(long long)buf, NULL};
}
long long beans_net_recv_out(long long fd, long long max, void** e_out) { BRes r = beans_net_recv(fd, max); *e_out = r.err; return r.val; }

// [i64 port][i64 host_len][host][payload] — one layout for every call that has to
// return an address, because the fallible-builtin ABI carries a single value.
static BList* net_pack(const char* host, long long port, const char* payload,
                       long long payload_len) {
    long long host_len = (long long)strlen(host);
    BList* packed = bytes_mk(16 + host_len + payload_len);
    char* into = (char*)packed->data;
    rt_store_le(into, (unsigned long long)port, 8);
    rt_store_le(into + 8, (unsigned long long)host_len, 8);
    memcpy(into + 16, host, (size_t)host_len);
    if (payload_len > 0) memcpy(into + 16 + host_len, payload, (size_t)payload_len);
    return packed;
}

static int net_name_of(const struct sockaddr* sa, socklen_t len, char* host,
                       size_t host_size, long long* port) {
    char service[NI_MAXSERV];
    int rc = getnameinfo(sa, len, host, (socklen_t)host_size, service, sizeof service,
                         NI_NUMERICHOST | NI_NUMERICSERV);
    if (rc != 0) return rc;
    *port = strtoll(service, NULL, 10);
    return 0;
}

BRes beans_net_address(long long fd, long long peer) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err(peer ? "peer" : "local")};
    struct sockaddr_storage sa;
    socklen_t len = sizeof sa;
    int rc = peer ? getpeername(net_fd_of(fd), (struct sockaddr*)&sa, &len)
                  : getsockname(net_fd_of(fd), (struct sockaddr*)&sa, &len);
    if (rc != 0) return (BRes){0, net_err_op(peer ? "peer" : "local", net_errno())};
    char host[NI_MAXHOST];
    long long port = 0;
    int gai = net_name_of((struct sockaddr*)&sa, len, host, sizeof host, &port);
    if (gai != 0) return (BRes){0, net_gai_err("", gai)};
    return (BRes){(long long)net_pack(host, port, NULL, 0), NULL};
}
long long beans_net_address_out(long long fd, long long peer, void** e_out) { BRes r = beans_net_address(fd, peer); *e_out = r.err; return r.val; }

BRes beans_net_send_to(long long fd, BList* data, char* host, long long port) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("send_to")};
    if (!data) return (BRes){0, mk_error("send_to: no data", "invalid")};
    if (!host || beans_slen(host) == 0)
        return (BRes){0, mk_error("a host is required", "invalid")};
    if (!net_check_port(port))
        return (BRes){0, mk_error("port must be 0..65535", "invalid")};
    int rc = 0;
    struct addrinfo* list = net_lookup(host, port, SOCK_DGRAM, 0, &rc);
    if (!list) return (BRes){0, net_gai_err(host, rc)};
    // Only an address of the socket's own family can be sent to, so a resolver that
    // answered with both v4 and v6 is filtered by trying each in turn.
    int last = 0;
    for (struct addrinfo* ai = list; ai; ai = ai->ai_next) {
        rt_ssize_t wrote;
        do {
            wrote = sendto(net_fd_of(fd), (const char*)data->data, (size_t)data->len,
                           NET_NOSIGNAL, ai->ai_addr, ai->ai_addrlen);
        } while (wrote < 0 && net_errno() == EINTR);
        if (wrote >= 0) {
            freeaddrinfo(list);
            return (BRes){(long long)wrote, NULL};
        }
        last = net_errno();
    }
    freeaddrinfo(list);
    return (BRes){0, net_err_at("send_to", host, port, last ? last : EINVAL)};
}
long long beans_net_send_to_out(long long fd, BList* data, char* host, long long port, void** e_out) { BRes r = beans_net_send_to(fd, data, host, port); *e_out = r.err; return r.val; }

BRes beans_net_recv_from(long long fd, long long max) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("recv_from")};
    if (max <= 0)
        return (BRes){0, mk_error("recv_from: the byte count must be positive",
                                  "invalid")};
#if defined(_WIN32)
    if (max > 0x7fffffff) max = 0x7fffffff; // Winsock counts in int
#endif
    char* buffer = malloc((size_t)max);
    if (!buffer) return (BRes){0, mk_error("recv_from: out of memory", "io")};
    struct sockaddr_storage sa;
    socklen_t len = sizeof sa;
    rt_ssize_t got;
    do {
        len = sizeof sa;
        got = recvfrom(net_fd_of(fd), buffer, (size_t)max, 0, (struct sockaddr*)&sa, &len);
    } while (got < 0 && net_errno() == EINTR);
#if defined(_WIN32)
    // Same WSAEMSGSIZE story as recv: the buffer holds the truncated datagram.
    if (got < 0 && WSAGetLastError() == WSAEMSGSIZE) got = (rt_ssize_t)max;
#endif
    if (got < 0) {
        int e = net_errno();
        free(buffer);
        return (BRes){0, net_err_op("recv_from", e)};
    }
    char host[NI_MAXHOST];
    long long port = 0;
    int gai = net_name_of((struct sockaddr*)&sa, len, host, sizeof host, &port);
    if (gai != 0) {
        free(buffer);
        return (BRes){0, net_gai_err("", gai)};
    }
    BList* packed = net_pack(host, port, buffer, got);
    free(buffer);
    return (BRes){(long long)packed, NULL};
}
long long beans_net_recv_from_out(long long fd, long long max, void** e_out) { BRes r = beans_net_recv_from(fd, max); *e_out = r.err; return r.val; }

BRes beans_net_shutdown(long long fd, long long how) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("shutdown")};
    int which = how == 0 ? SHUT_RD : how == 1 ? SHUT_WR : SHUT_RDWR;
    if (shutdown(net_fd_of(fd), which) != 0) {
        // Already shut down or already gone is the state the caller asked for.
        if (net_errno() == ENOTCONN) return (BRes){1, NULL};
        return (BRes){0, net_err_op("shutdown", net_errno())};
    }
    return (BRes){1, NULL};
}
long long beans_net_shutdown_out(long long fd, long long how, void** e_out) { BRes r = beans_net_shutdown(fd, how); *e_out = r.err; return r.val; }

BRes beans_net_set_timeouts(long long fd, long long read_ms, long long write_ms) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("set_timeouts")};
    if (read_ms < 0 || write_ms < 0)
        return (BRes){0, mk_error("a timeout cannot be negative — use 0 for no "
                                  "timeout", "invalid")};
#if defined(_WIN32)
    // Winsock's SO_*TIMEO is a DWORD of milliseconds, not a timeval.
    DWORD rt = (DWORD)read_ms, wt = (DWORD)write_ms;
#else
    struct timeval rt, wt;
    rt.tv_sec = (time_t)(read_ms / 1000);
    rt.tv_usec = (suseconds_t)((read_ms % 1000) * 1000);
    wt.tv_sec = (time_t)(write_ms / 1000);
    wt.tv_usec = (suseconds_t)((write_ms % 1000) * 1000);
#endif
    if (setsockopt(net_fd_of(fd), SOL_SOCKET, SO_RCVTIMEO, (const char*)&rt,
                   sizeof rt) != 0 ||
        setsockopt(net_fd_of(fd), SOL_SOCKET, SO_SNDTIMEO, (const char*)&wt,
                   sizeof wt) != 0)
        return (BRes){0, net_err_op("set_timeouts", net_errno())};
    return (BRes){1, NULL};
}
long long beans_net_set_timeouts_out(long long fd, long long read_ms, long long write_ms, void** e_out) { BRes r = beans_net_set_timeouts(fd, read_ms, write_ms); *e_out = r.err; return r.val; }

BRes beans_net_set_nonblocking(long long fd, long long on) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("set_nonblocking")};
#if defined(_WIN32)
    u_long want = on ? 1 : 0;
    if (ioctlsocket(net_fd_of(fd), FIONBIO, &want) != 0)
        return (BRes){0, net_err_op("set_nonblocking", net_errno())};
#else
    int flags = fcntl(net_fd_of(fd), F_GETFL, 0);
    if (flags < 0) return (BRes){0, net_err_op("set_nonblocking", net_errno())};
    int want = on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
    if (fcntl(net_fd_of(fd), F_SETFL, want) != 0)
        return (BRes){0, net_err_op("set_nonblocking", net_errno())};
#endif
    return (BRes){1, NULL};
}
long long beans_net_set_nonblocking_out(long long fd, long long on, void** e_out) { BRes r = beans_net_set_nonblocking(fd, on); *e_out = r.err; return r.val; }

BRes beans_net_close(long long fd) {
    net_init();
    if (fd < 0) return (BRes){0, net_closed_err("close")};
    // A parked await on this number must finish false off its dead flag,
    // never off whatever resource the number is reused for. Marked before
    // the close so no window exists where the number is free but the
    // entry still looks live.
    beans_reactor_note_close(fd);
    // EINTR from close must not be retried: on Linux the descriptor is already gone,
    // so a retry would close whatever number was handed out next.
    if (net_close(net_fd_of(fd)) != 0 && net_errno() != EINTR)
        return (BRes){0, net_err_op("close", net_errno())};
    return (BRes){1, NULL};
}
long long beans_net_close_out(long long fd, void** e_out) { BRes r = beans_net_close(fd); *e_out = r.err; return r.val; }

BRes beans_net_resolve(char* host, long long port) {
    net_init();
    if (!host || beans_slen(host) == 0)
        return (BRes){0, mk_error("a host is required", "invalid")};
    if (!net_check_port(port))
        return (BRes){0, mk_error("port must be 0..65535", "invalid")};
    int rc = 0;
    struct addrinfo* list = net_lookup(host, port, SOCK_STREAM, 0, &rc);
    if (!list) return (BRes){0, net_gai_err(host, rc)};
    BList* out = beans_list_new(1);
    for (struct addrinfo* ai = list; ai; ai = ai->ai_next) {
        char text[NI_MAXHOST];
        long long got_port = 0;
        if (net_name_of(ai->ai_addr, ai->ai_addrlen, text, sizeof text,
                        &got_port) != 0)
            continue;
        // getaddrinfo reports one entry per (family, socktype, protocol), so the same
        // address arrives more than once. Callers want distinct addresses.
        int seen = 0;
        for (long long i = 0; i < out->len && !seen; i++)
            if (strcmp((const char*)(intptr_t)out->data[i], text) == 0) seen = 1;
        if (!seen) beans_list_push(out, (long long)rc_strdup(text));
    }
    freeaddrinfo(list);
    if (out->len == 0) {
        beans_release(out);
        return (BRes){0, net_gai_err(host, EAI_NONAME)};
    }
    return (BRes){(long long)out, NULL};
}
long long beans_net_resolve_out(char* host, long long port, void** e_out) { BRes r = beans_net_resolve(host, port); *e_out = r.err; return r.val; }

// ---- readiness poller -------------------------------------------------------
//
// One API over epoll (Linux), kqueue (macOS/BSD) and WSAPoll (Windows). The owning
// handle is written in Beans in stdlib/std/poll; this layer is the syscalls, mirrored
// in builtins.cpp.
//
// **Level-triggered.** While a descriptor has data, every wait reports it. That is the
// default on both backends and it is the mode a caller can use imprecisely and still be
// correct — edge-triggered demands reading until EAGAIN every single time or the
// connection silently stalls, which is a bug that only shows up under load.
//
// The caller's own token comes back in each event, never an fd: a descriptor number is
// reused the moment it is closed, so keying on it means a queued event can name
// something else by the time it is handled.
//
// A poller carries an internal pipe (a connected loopback pair on Windows, where
// WSAPoll can only wait on sockets) so wake() works from any thread. Its read end is
// registered with a reserved token, filtered out of every result, and drained on each
// wait, so repeated wakes collapse into one.

// Reserved for the wake pipe. Rejected as a user token, so an event can never be
// confused with a wake.
#define POLL_WAKE_TOKEN (-9223372036854775807LL - 1)

#define POLL_READABLE 1
#define POLL_WRITABLE 2
#define POLL_HANGUP 4
#define POLL_ERROR 8

// A wake has to be callable from another thread, and the only Beans values that cross a
// thread boundary are scalars — every class is a local ARC reference. So a wake target
// is one `int`.
//
// Handing out the raw descriptor would be unsafe: after the poller closes, that number
// belongs to something else, and a late wake would write a stray byte into an unrelated
// file. Instead a wake target is a slot index plus a generation. Closing clears the slot
// and bumps the generation under the same lock that a wake takes, so a stale handle is
// *reported* rather than acted on. The lock is touched on open, close and wake only —
// never on the wait path.
#define POLL_WAKERS_MAX 4096
static struct {
    net_fd_t fd;
    long long gen;
    int live; // a SOCKET is unsigned, so an empty slot cannot be a sign test
} poll_wakers[POLL_WAKERS_MAX];
static pthread_mutex_t poll_wakers_lock = PTHREAD_MUTEX_INITIALIZER;

// handle = (slot + 1) * 2^32 + generation, so 0 is never a valid handle and a decoded
// slot is always in range.
static long long poll_waker_add(net_fd_t fd) {
    pthread_mutex_lock(&poll_wakers_lock);
    for (int i = 0; i < POLL_WAKERS_MAX; i++) {
        if (poll_wakers[i].live) continue;
        poll_wakers[i].fd = fd;
        poll_wakers[i].live = 1;
        if (poll_wakers[i].gen == 0) poll_wakers[i].gen = 1;
        long long handle = ((long long)(i + 1) << 32) | poll_wakers[i].gen;
        pthread_mutex_unlock(&poll_wakers_lock);
        return handle;
    }
    pthread_mutex_unlock(&poll_wakers_lock);
    return 0; // table full: the caller reports it rather than silently going unwakeable
}

// Returns the descriptor to write to, or -1 when the handle is stale. The fd is only
// valid while the lock is held, which is why the write happens inside it.
static net_fd_t poll_waker_fd(long long handle) {
    long long slot = (handle >> 32) - 1;
    long long gen = handle & 0xffffffffLL;
    if (slot < 0 || slot >= POLL_WAKERS_MAX) return NET_FD_NONE;
    if (!poll_wakers[slot].live || poll_wakers[slot].gen != gen) return NET_FD_NONE;
    return poll_wakers[slot].fd;
}

// Clears the slot and returns the descriptor the caller must close. Done under the lock
// so a concurrent wake either happens fully before, or sees the slot gone.
static net_fd_t poll_waker_drop(long long handle) {
    long long slot = (handle >> 32) - 1;
    if (slot < 0 || slot >= POLL_WAKERS_MAX) return NET_FD_NONE;
    pthread_mutex_lock(&poll_wakers_lock);
    net_fd_t fd = poll_wakers[slot].live ? poll_wakers[slot].fd : NET_FD_NONE;
    poll_wakers[slot].live = 0;
    poll_wakers[slot].fd = NET_FD_NONE;
    // Bump so every handle naming this slot is stale, including one already in flight
    // on another thread.
    poll_wakers[slot].gen++;
    if (poll_wakers[slot].gen == 0) poll_wakers[slot].gen = 1;
    pthread_mutex_unlock(&poll_wakers_lock);
    return fd;
}

static const char* poll_kind_of(int err) {
    switch (err) {
        case ENOENT: return "not_found";
        case EEXIST: return "exists";
        case EBADF: return "closed";
        case EINVAL: return "invalid";
        case EPERM:
        case EACCES: return "permission";
        case EMFILE:
        case ENFILE: return "limit";
        default: return "io";
    }
}
static void* poll_err(const char* op, int err) {
    char b[160];
    snprintf(b, sizeof b, "%s: %s", op, strerror(err));
    return mk_error(b, poll_kind_of(err));
}

static void poll_cloexec_nonblock(net_fd_t fd) {
#if defined(_WIN32)
    // Inheritance is opt-in on Windows; only the nonblocking half exists here.
    u_long one = 1;
    ioctlsocket(net_fd_of(fd), FIONBIO, &one);
#else
    int fl = fcntl(fd, F_GETFD, 0);
    if (fl >= 0) fcntl(fd, F_SETFD, fl | FD_CLOEXEC);
    int st = fcntl(fd, F_GETFL, 0);
    if (st >= 0) fcntl(fd, F_SETFL, st | O_NONBLOCK);
#endif
}

#if defined(_WIN32)
// No kernel object holds the interest set — WSAPoll takes the whole set on
// every call. So the poller *is* a registry: a slot in this table holding a
// growable {fd, wanted events, token} set, and the "poller descriptor" the
// caller carries is the slot's index. Add/remove edit the set under the table
// lock; wait snapshots it and hands the copy to WSAPoll, so the lock is held
// for a memcpy, never across the kernel wait.
typedef struct {
    WSAPOLLFD* fds; // fds[i].events holds the wanted interest
    long long* tokens;
    long long count, cap;
    int live;
} PollSet;
#define POLL_SETS_MAX 1024
static PollSet poll_sets[POLL_SETS_MAX];
static pthread_mutex_t poll_sets_lock = PTHREAD_MUTEX_INITIALIZER;

static int poll_set_grab(void) {
    pthread_mutex_lock(&poll_sets_lock);
    for (int i = 0; i < POLL_SETS_MAX; i++) {
        if (poll_sets[i].live) continue;
        poll_sets[i].live = 1;
        pthread_mutex_unlock(&poll_sets_lock);
        return i;
    }
    pthread_mutex_unlock(&poll_sets_lock);
    WSASetLastError(WSAEMFILE); // net_errno maps it to EMFILE — kind "limit"
    return -1;
}

// The Windows spelling of close(poller): give the slot back. Cannot fail.
static void poll_set_drop(int poller) {
    if (poller < 0 || poller >= POLL_SETS_MAX) return;
    pthread_mutex_lock(&poll_sets_lock);
    free(poll_sets[poller].fds);
    free(poll_sets[poller].tokens);
    poll_sets[poller].fds = NULL;
    poll_sets[poller].tokens = NULL;
    poll_sets[poller].count = poll_sets[poller].cap = 0;
    poll_sets[poller].live = 0;
    pthread_mutex_unlock(&poll_sets_lock);
}

// Forget one descriptor, as epoll does by itself when the fd is closed.
static void poll_set_forget(int poller, net_fd_t fd) {
    pthread_mutex_lock(&poll_sets_lock);
    PollSet* set = &poll_sets[poller];
    if (set->live) {
        for (long long i = 0; i < set->count; i++) {
            if (set->fds[i].fd != fd) continue;
            set->count--;
            set->fds[i] = set->fds[set->count];
            set->tokens[i] = set->tokens[set->count];
            break;
        }
    }
    pthread_mutex_unlock(&poll_sets_lock);
}

// The wake channel. WSAPoll waits on sockets only — a pipe is invisible to it —
// so the self-pipe is a connected TCP pair: listen on 127.0.0.1:0, connect,
// accept, and the listener is gone before this returns. out[0] reads, out[1]
// writes, matching pipe().
static int net_loopback_pair(net_fd_t out[2]) {
    SOCKET lis = socket(AF_INET, SOCK_STREAM, 0);
    SOCKET a = INVALID_SOCKET, b = INVALID_SOCKET;
    if (lis == INVALID_SOCKET) return -1;
    struct sockaddr_in at;
    memset(&at, 0, sizeof at);
    at.sin_family = AF_INET;
    at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int len = sizeof at;
    if (bind(lis, (struct sockaddr*)&at, sizeof at) == 0 && listen(lis, 1) == 0 &&
        getsockname(lis, (struct sockaddr*)&at, &len) == 0) {
        a = socket(AF_INET, SOCK_STREAM, 0);
        if (a != INVALID_SOCKET &&
            connect(a, (struct sockaddr*)&at, sizeof at) == 0)
            b = accept(lis, NULL, NULL);
    }
    if (b == INVALID_SOCKET) {
        int e = (int)WSAGetLastError();
        if (a != INVALID_SOCKET) closesocket(a);
        closesocket(lis);
        WSASetLastError(e);
        return -1;
    }
    closesocket(lis);
    out[0] = b;
    out[1] = a;
    return 0;
}
#else
#define poll_set_drop(poller) close(poller)
#endif

// Registers one descriptor with the wanted interest. want_read/want_write false for
// both means "not interested", which on every backend is a delete.
static int poll_apply(int poller, net_fd_t fd, long long token, int want_read,
                      int want_write, int adding) {
#if defined(__linux__)
    struct epoll_event ev;
    memset(&ev, 0, sizeof ev);
    ev.events = (want_read ? EPOLLIN : 0) | (want_write ? EPOLLOUT : 0) | EPOLLRDHUP;
    ev.data.u64 = (unsigned long long)token;
    if (!want_read && !want_write)
        return epoll_ctl(poller, EPOLL_CTL_DEL, fd, &ev);
    if (epoll_ctl(poller, adding ? EPOLL_CTL_ADD : EPOLL_CTL_MOD, fd, &ev) == 0)
        return 0;
    // ADD on an already-registered fd, or MOD on one that is not: either way the
    // caller's intent is "make it exactly this", so try the other operation once.
    if (net_errno() == EEXIST || net_errno() == ENOENT)
        return epoll_ctl(poller, adding ? EPOLL_CTL_MOD : EPOLL_CTL_ADD, fd, &ev);
    return -1;
#elif defined(_WIN32)
    // The registry backend has the epoll intent built in: present means update,
    // absent means append, and deleting an absent registration is the state the
    // caller asked for — exactly how the kqueue branch treats ENOENT.
    (void)adding;
    pthread_mutex_lock(&poll_sets_lock);
    PollSet* set = poller >= 0 && poller < POLL_SETS_MAX ? &poll_sets[poller] : NULL;
    if (!set || !set->live) {
        pthread_mutex_unlock(&poll_sets_lock);
        WSASetLastError(WSAENOTSOCK); // net_errno maps it to EBADF — kind "closed"
        return -1;
    }
    long long at = -1;
    for (long long i = 0; i < set->count; i++)
        if (set->fds[i].fd == fd) { at = i; break; }
    if (!want_read && !want_write) {
        if (at >= 0) {
            set->count--;
            set->fds[at] = set->fds[set->count];
            set->tokens[at] = set->tokens[set->count];
        }
        pthread_mutex_unlock(&poll_sets_lock);
        return 0;
    }
    if (at < 0) {
        if (set->count == set->cap) {
            long long cap = set->cap ? set->cap * 2 : 16;
            WSAPOLLFD* fds = realloc(set->fds, (size_t)cap * sizeof *fds);
            if (fds) set->fds = fds;
            long long* tokens = realloc(set->tokens, (size_t)cap * sizeof *tokens);
            if (tokens) set->tokens = tokens;
            if (!fds || !tokens) {
                pthread_mutex_unlock(&poll_sets_lock);
                WSASetLastError(WSAENOBUFS); // EIO/"io", as POSIX ENOMEM lands
                return -1;
            }
            set->cap = cap;
        }
        at = set->count++;
        set->fds[at].fd = fd;
    }
    set->fds[at].events =
        (short)((want_read ? POLLIN : 0) | (want_write ? POLLOUT : 0));
    set->fds[at].revents = 0;
    set->tokens[at] = token;
    pthread_mutex_unlock(&poll_sets_lock);
    return 0;
#else
    // kqueue keeps read and write as separate filters, so each is added or deleted on
    // its own. Deleting a filter that was never registered gives ENOENT, which is the
    // state the caller asked for rather than a failure.
    (void)adding;
    struct kevent changes[2];
    int n = 0;
    EV_SET(&changes[n++], (uintptr_t)fd, EVFILT_READ,
           want_read ? (EV_ADD | EV_ENABLE) : EV_DELETE, 0, 0,
           (void*)(intptr_t)token);
    EV_SET(&changes[n++], (uintptr_t)fd, EVFILT_WRITE,
           want_write ? (EV_ADD | EV_ENABLE) : EV_DELETE, 0, 0,
           (void*)(intptr_t)token);
    // Errors come back in the changelist, so ask for them explicitly instead of
    // trusting the return value.
    for (int i = 0; i < n; i++) changes[i].flags |= EV_RECEIPT;
    struct kevent results[2];
    int got = kevent(poller, changes, n, results, n, NULL);
    if (got < 0) return -1;
    for (int i = 0; i < got; i++) {
        if (!(results[i].flags & EV_ERROR)) continue;
        int e = (int)results[i].data;
        if (e == 0 || e == ENOENT) continue; // nothing to delete is fine
        errno = e;
        return -1;
    }
    return 0;
#endif
}

// [poller fd][wake read fd][wake write fd] — the caller holds all three so this layer
// keeps no state of its own, and closing is explicit rather than a hidden side table.
BRes beans_poll_open(void) {
    int poller;
#if defined(__linux__)
    poller = epoll_create1(EPOLL_CLOEXEC);
#elif defined(_WIN32)
    net_init();
    poller = poll_set_grab();
#else
    poller = kqueue();
    if (poller >= 0) {
        int fl = fcntl(poller, F_GETFD, 0);
        if (fl >= 0) fcntl(poller, F_SETFD, fl | FD_CLOEXEC);
    }
#endif
    if (poller < 0) return (BRes){0, poll_err("poller open", net_errno())};
    net_fd_t wake[2] = {NET_FD_NONE, NET_FD_NONE};
#if defined(_WIN32)
    if (net_loopback_pair(wake) != 0) {
#else
    if (pipe(wake) != 0) {
#endif
        int e = net_errno();
        poll_set_drop(poller);
        return (BRes){0, poll_err("poller open", e)};
    }
    // Non-blocking on both ends: a wake must never block the waker, and draining must
    // never block the waiter.
    poll_cloexec_nonblock(wake[0]);
    poll_cloexec_nonblock(wake[1]);
    if (poll_apply(poller, wake[0], POLL_WAKE_TOKEN, 1, 0, 1) != 0) {
        int e = net_errno();
        poll_set_drop(poller);
        net_close(wake[0]);
        net_close(wake[1]);
        return (BRes){0, poll_err("poller open", e)};
    }
    // The write end goes into the waker table; the caller gets a generation-checked
    // handle rather than the descriptor, so a wake after close is reported, not acted on.
    long long handle = poll_waker_add(wake[1]);
    if (handle == 0) {
        poll_set_drop(poller);
        net_close(wake[0]);
        net_close(wake[1]);
        return (BRes){0, mk_error("too many pollers are open to register another wake",
                                  "limit")};
    }
    BList* packed = bytes_mk(24);
    rt_store_le(packed->data, (unsigned long long)poller, 8);
    rt_store_le((char*)packed->data + 8,
                (unsigned long long)net_fd_word(wake[0]), 8);
    rt_store_le((char*)packed->data + 16, (unsigned long long)handle, 8);
    return (BRes){(long long)packed, NULL};
}
long long beans_poll_open_out(void** e_out) { BRes r = beans_poll_open(); *e_out = r.err; return r.val; }

BRes beans_poll_add(long long poller, long long fd, long long token,
                    long long want_read, long long want_write, long long adding) {
    if (poller < 0 || fd < 0) return (BRes){0, mk_error("poller: closed", "closed")};
    if (token == POLL_WAKE_TOKEN)
        return (BRes){0, mk_error("that token is reserved for the poller's own wake",
                                  "invalid")};
    if (!want_read && !want_write)
        return (BRes){0, mk_error("a registration must want reads, writes or both — "
                                  "use remove to stop watching", "invalid")};
    if (poll_apply((int)poller, net_fd_of(fd), token, want_read != 0, want_write != 0,
                   adding != 0) != 0)
        return (BRes){0,
                      poll_err(adding ? "poller add" : "poller modify", net_errno())};
    return (BRes){1, NULL};
}
long long beans_poll_add_out(long long poller, long long fd, long long token, long long want_read, long long want_write, long long adding, void** e_out) { BRes r = beans_poll_add(poller, fd, token, want_read, want_write, adding); *e_out = r.err; return r.val; }

BRes beans_poll_remove(long long poller, long long fd) {
    if (poller < 0 || fd < 0) return (BRes){0, mk_error("poller: closed", "closed")};
    if (poll_apply((int)poller, net_fd_of(fd), 0, 0, 0, 0) != 0) {
        // Already gone is the state the caller wanted. A descriptor that was closed
        // while registered drops out of the set by itself.
        int e = net_errno();
        if (e == ENOENT || e == EBADF) return (BRes){1, NULL};
        return (BRes){0, poll_err("poller remove", e)};
    }
    return (BRes){1, NULL};
}
long long beans_poll_remove_out(long long poller, long long fd, void** e_out) { BRes r = beans_poll_remove(poller, fd); *e_out = r.err; return r.val; }

// [i64 count][i64 token, i64 flags] * count
BRes beans_poll_wait(long long poller, long long wake_read, long long max_events,
                     long long timeout_ms) {
    if (poller < 0) return (BRes){0, mk_error("poller: closed", "closed")};
    if (max_events <= 0)
        return (BRes){0, mk_error("the event limit must be positive", "invalid")};
    if (max_events > 4096) max_events = 4096;
    // kqueue can spend two kernel slots on one logical read+write event. Keep room
    // for both filters plus the private wake without weakening max_events.
    long long room = max_events * 2 + 1;
    long long deadline = timeout_ms < 0 ? 0
                                        : beans_time_monotonic_nanos() / 1000000LL
                                              + timeout_ms;
    // Heap, not stack: 4096 events would be 64KB of locals, and a poller can be waited
    // on from a worker thread whose stack is 512KB on macOS.
    long long* tokens = calloc((size_t)max_events, sizeof(long long));
    long long* flags = calloc((size_t)max_events, sizeof(long long));
#if !defined(__linux__) && !defined(_WIN32)
    uintptr_t* idents = calloc((size_t)max_events, sizeof(uintptr_t));
#endif
    if (!tokens || !flags
#if !defined(__linux__) && !defined(_WIN32)
        || !idents
#endif
    ) {
        free(tokens);
        free(flags);
#if !defined(__linux__) && !defined(_WIN32)
        free(idents);
#endif
        return (BRes){0, mk_error("poller wait: out of memory", "io")};
    }
    long long found = 0;

    for (;;) {
        int budget = -1;
        if (timeout_ms >= 0) {
            long long left = deadline - beans_time_monotonic_nanos() / 1000000LL;
            if (left < 0) left = 0;
            budget = left > 0x7fffffffLL ? 0x7fffffff : (int)left;
        }
        int woken = 0;
#if defined(__linux__)
        struct epoll_event* got = calloc((size_t)room, sizeof(struct epoll_event));
        if (!got) {
            free(tokens);
            free(flags);
            return (BRes){0, mk_error("poller wait: out of memory", "io")};
        }
        int n = epoll_wait((int)poller, got, (int)room, budget);
        if (n < 0) {
            int e = net_errno();
            free(got);
            if (e == EINTR) continue; // deadline recomputed above, never extended
            free(tokens);
            free(flags);
            return (BRes){0, poll_err("poller wait", e)};
        }
        for (int i = 0; i < n && found < max_events; i++) {
            long long token = (long long)got[i].data.u64;
            if (token == POLL_WAKE_TOKEN) { woken = 1; continue; }
            long long f = 0;
            if (got[i].events & EPOLLIN) f |= POLL_READABLE;
            if (got[i].events & EPOLLOUT) f |= POLL_WRITABLE;
            if (got[i].events & (EPOLLHUP | EPOLLRDHUP)) f |= POLL_HANGUP;
            if (got[i].events & EPOLLERR) f |= POLL_ERROR;
            tokens[found] = token;
            flags[found] = f;
            found++;
        }
        free(got);
#elif defined(_WIN32)
        // Snapshot the registry under the lock, wait outside it: WSAPoll takes
        // the whole interest set each call, and holding the lock across the
        // kernel wait would block add, remove and wake from other threads. A
        // registration made mid-wait is seen at the next call — the same lag a
        // wake already covers.
        (void)room; // kernel-slot headroom is an epoll/kqueue concern
        pthread_mutex_lock(&poll_sets_lock);
        PollSet* set =
            poller < POLL_SETS_MAX ? &poll_sets[(int)poller] : NULL;
        if (!set || !set->live) {
            pthread_mutex_unlock(&poll_sets_lock);
            free(tokens);
            free(flags);
            return (BRes){0, mk_error("poller: closed", "closed")};
        }
        long long nfds = set->count;
        WSAPOLLFD* got = calloc((size_t)(nfds ? nfds : 1), sizeof(WSAPOLLFD));
        long long* toks = calloc((size_t)(nfds ? nfds : 1), sizeof(long long));
        if (!got || !toks) {
            pthread_mutex_unlock(&poll_sets_lock);
            free(got);
            free(toks);
            free(tokens);
            free(flags);
            return (BRes){0, mk_error("poller wait: out of memory", "io")};
        }
        memcpy(got, set->fds, (size_t)nfds * sizeof(WSAPOLLFD));
        memcpy(toks, set->tokens, (size_t)nfds * sizeof(long long));
        pthread_mutex_unlock(&poll_sets_lock);
        int n = 0;
        if (nfds == 0) {
            // Nothing registered, not even the wake: sleep out the budget the
            // way an empty epoll set would (WSAPoll refuses zero entries).
            Sleep(budget < 0 ? INFINITE : (DWORD)budget);
        } else {
            n = WSAPoll(got, (ULONG)nfds, budget);
        }
        if (n < 0) {
            int e = net_errno();
            free(got);
            free(toks);
            if (e == EINTR) continue;
            free(tokens);
            free(flags);
            return (BRes){0, poll_err("poller wait", e)};
        }
        for (long long i = 0; i < nfds && found < max_events; i++) {
            short re = got[i].revents;
            if (re == 0) continue;
            if (re & POLLNVAL) {
                // The registered descriptor was closed. epoll silently forgets
                // it, so the registry does too — reporting it instead would
                // wedge every later wait on a permanently "invalid" entry.
                poll_set_forget((int)poller, got[i].fd);
                continue;
            }
            long long token = toks[i];
            if (token == POLL_WAKE_TOKEN) { woken = 1; continue; }
            long long f = 0;
            if (re & POLLIN) f |= POLL_READABLE;
            if (re & POLLOUT) f |= POLL_WRITABLE;
            if (re & POLLHUP) f |= POLL_HANGUP;
            if (re & POLLERR) f |= POLL_ERROR;
            // WSAPoll reports a graceful FIN as plain readability; epoll's
            // RDHUP and kqueue's EV_EOF both surface it as a hangup. A
            // zero-byte MSG_PEEK on a readable socket is the FIN test, and
            // it consumes nothing.
            if ((f & POLL_READABLE) && !(f & POLL_HANGUP)) {
                char probe;
                int got_peek =
                    recv(got[i].fd, &probe, 1, MSG_PEEK);
                if (got_peek == 0) f |= POLL_HANGUP;
            }
            tokens[found] = token;
            flags[found] = f;
            found++;
        }
        free(got);
        free(toks);
#else
        struct kevent* got = calloc((size_t)room, sizeof(struct kevent));
        if (!got) {
            free(tokens);
            free(flags);
            return (BRes){0, mk_error("poller wait: out of memory", "io")};
        }
        struct timespec ts, *wait_for = NULL;
        if (budget >= 0) {
            ts.tv_sec = budget / 1000;
            ts.tv_nsec = (long)(budget % 1000) * 1000000L;
            wait_for = &ts;
        }
        int n = kevent((int)poller, NULL, 0, got, (int)room, wait_for);
        if (n < 0) {
            int e = net_errno();
            free(got);
            if (e == EINTR) continue;
            free(tokens);
            free(flags);
            free(idents);
            return (BRes){0, poll_err("poller wait", e)};
        }
        for (int i = 0; i < n; i++) {
            long long token = (long long)(intptr_t)got[i].udata;
            if (token == POLL_WAKE_TOKEN) { woken = 1; continue; }
            long long f = 0;
            if (got[i].filter == EVFILT_READ) f |= POLL_READABLE;
            if (got[i].filter == EVFILT_WRITE) f |= POLL_WRITABLE;
            if (got[i].flags & EV_EOF) f |= POLL_HANGUP;
            if (got[i].flags & EV_ERROR) f |= POLL_ERROR;
            // kqueue reports read and write as separate events for one descriptor.
            // epoll reports one with both bits, so they are merged here — otherwise the
            // same program would see a different number of events per platform.
            long long at = -1;
            for (long long j = 0; j < found; j++)
                if (idents[j] == got[i].ident) { at = j; break; }
            if (at >= 0) {
                flags[at] |= f;
                continue;
            }
            if (found >= max_events) continue;
            idents[found] = got[i].ident;
            tokens[found] = token;
            flags[found] = f;
            found++;
        }
        free(got);
#endif
        if (woken && wake_read >= 0) {
            // Drain it: level-triggered means an undrained byte would make every
            // later wait return at once, which is the busy loop this must not have.
            char sink[64];
#if defined(_WIN32)
            while (recv(net_fd_of(wake_read), sink, sizeof sink, 0) > 0) {}
#else
            while (read((int)wake_read, sink, sizeof sink) > 0) {}
#endif
        }
        // A wake with nothing else ready still returns, so a blocked thread can be
        // told to stop. An empty list is not an error.
        if (found > 0 || woken) break;
        if (timeout_ms >= 0 &&
            beans_time_monotonic_nanos() / 1000000LL >= deadline)
            break;
        if (timeout_ms == 0) break;
    }

    BList* packed = bytes_mk(8 + found * 16);
    char* into = (char*)packed->data;
    rt_store_le(into, (unsigned long long)found, 8);
    for (long long i = 0; i < found; i++) {
        rt_store_le(into + 8 + i * 16, (unsigned long long)tokens[i], 8);
        rt_store_le(into + 8 + i * 16 + 8, (unsigned long long)flags[i], 8);
    }
    free(tokens);
    free(flags);
#if !defined(__linux__) && !defined(_WIN32)
    free(idents);
#endif
    return (BRes){(long long)packed, NULL};
}
long long beans_poll_wait_out(long long poller, long long wake_read, long long max_events, long long timeout_ms, void** e_out) { BRes r = beans_poll_wait(poller, wake_read, max_events, timeout_ms); *e_out = r.err; return r.val; }

// Safe from any thread. One byte into a pipe, written while holding the table lock so
// the descriptor cannot be closed underneath it. EAGAIN means a wake is already pending,
// which is exactly as good as writing another.
BRes beans_poll_wake(long long handle) {
    pthread_mutex_lock(&poll_wakers_lock);
    net_fd_t fd = poll_waker_fd(handle);
    if (!net_fd_ok(fd)) {
        pthread_mutex_unlock(&poll_wakers_lock);
        return (BRes){0, mk_error("poller wake: that poller is closed", "closed")};
    }
    char one = 1;
    for (;;) {
#if defined(_WIN32)
        rt_ssize_t wrote = send(fd, &one, 1, 0);
#else
        rt_ssize_t wrote = write(fd, &one, 1);
#endif
        if (wrote == 1) {
            pthread_mutex_unlock(&poll_wakers_lock);
            return (BRes){1, NULL};
        }
        if (wrote < 0 && net_errno() == EINTR) continue;
        int e = net_errno();
        pthread_mutex_unlock(&poll_wakers_lock);
        if (wrote < 0 && (e == EAGAIN || e == EWOULDBLOCK))
            return (BRes){1, NULL}; // already awake, and one byte is enough
        return (BRes){0, poll_err("poller wake", e)};
    }
}
long long beans_poll_wake_out(long long handle, void** e_out) { BRes r = beans_poll_wake(handle); *e_out = r.err; return r.val; }

BRes beans_poll_close(long long poller, long long wake_read, long long handle) {
    if (poller < 0) return (BRes){0, mk_error("poller: closed", "closed")};
    int failed = 0, e = 0;
    // Clear the table slot first: after this every handle naming it is stale, so no
    // other thread can be inside a write to the descriptor about to be closed.
    net_fd_t wake_write = poll_waker_drop(handle);
    // All three, always: stopping at the first failure would leak the rest.
    if (net_fd_ok(wake_write) && net_close(wake_write) != 0 && net_errno() != EINTR) {
        failed = 1;
        e = net_errno();
    }
    if (wake_read >= 0 && net_close(net_fd_of(wake_read)) != 0 && net_errno() != EINTR &&
        !failed) {
        failed = 1;
        e = net_errno();
    }
#if defined(_WIN32)
    poll_set_drop((int)poller); // a registry slot, not a descriptor; cannot fail
#else
    if (close((int)poller) != 0 && net_errno() != EINTR && !failed) {
        failed = 1;
        e = net_errno();
    }
#endif
    if (failed) return (BRes){0, poll_err("poller close", e)};
    return (BRes){1, NULL};
}
long long beans_poll_close_out(long long poller, long long wake_read, long long handle, void** e_out) { BRes r = beans_poll_close(poller, wake_read, handle); *e_out = r.err; return r.val; }

// ---- hidden async executor state --------------------------------------------
//
// Four thread-local slots the async runtime package threads its reactor
// through: [0..2] the shared poller triple from ready.open, [3] the number of
// parked readiness awaits. State lives here because Beans has no globals and
// the park tasks, the driver, and cancellation all need the same poller.
// Thread-local, so each thread that drives async work gets its own executor.
static _Thread_local long long beans_task_slots[4];

long long beans_task_slot(long long index) {
    return beans_task_slots[index & 3];
}

long long beans_set_task_slot(long long index, long long value) {
    beans_task_slots[index & 3] = value;
    return 1;
}

// The reactor's parked-await table. Poller registration is keyed by
// descriptor ("make it exactly this"), so two awaits parked on one
// descriptor would silently cancel each other's interest; the table lets
// the runtime refuse that clearly instead. It also remembers what is
// parked so the driver can notice a descriptor closed while an await
// still waits on it — the OS quietly drops such registrations and would
// leave the driver blocked forever.
//
// An entry is identified by a token, not the descriptor: the moment a
// parked descriptor is closed its number can be handed to a brand-new
// resource, and a descriptor-keyed table could not tell the dead await
// from a fresh one on the reused number. The runtime's own close paths
// call beans_reactor_note_close, which marks the entry dead in place —
// the await finishes false off the flag, without ever touching the
// number again, and the number is immediately free for a new park.
#define BEANS_PARKED_MAX 64
typedef struct {
    long long fd;
    long long token;
    int dead;
} BeansParked;
static _Thread_local BeansParked beans_parked[BEANS_PARKED_MAX];
static _Thread_local long long beans_parked_len;
static _Thread_local long long beans_parked_token_next;

// token (> 0) = noted, 0 = that descriptor already has a live parked
// await, -1 = full. A dead entry on the same number does not block a
// new park: the number belongs to the new resource now.
long long beans_reactor_note_park(long long fd) {
    for (long long i = 0; i < beans_parked_len; i++)
        if (!beans_parked[i].dead && beans_parked[i].fd == fd) return 0;
    if (beans_parked_len == BEANS_PARKED_MAX) return -1;
    long long token = ++beans_parked_token_next;
    beans_parked[beans_parked_len].fd = fd;
    beans_parked[beans_parked_len].token = token;
    beans_parked[beans_parked_len].dead = 0;
    beans_parked_len++;
    return token;
}

// 1 = removed, 0 = no entry carries that token.
long long beans_reactor_forget_park(long long token) {
    for (long long i = 0; i < beans_parked_len; i++) {
        if (beans_parked[i].token != token) continue;
        beans_parked_len--;
        beans_parked[i] = beans_parked[beans_parked_len];
        return 1;
    }
    return 0;
}

// 1 = the parked descriptor was closed under the await, 0 = still live,
// -1 = no entry carries that token.
long long beans_reactor_park_dead(long long token) {
    for (long long i = 0; i < beans_parked_len; i++)
        if (beans_parked[i].token == token)
            return beans_parked[i].dead ? 1 : 0;
    return -1;
}

// Every runtime path that closes a descriptor reports it here. Marking
// instead of removing keeps the await the only writer of its own entry,
// and works on every platform — including Windows, where descriptors
// have no cheap liveness probe.
void beans_reactor_note_close(long long fd) {
    for (long long i = 0; i < beans_parked_len; i++)
        if (!beans_parked[i].dead && beans_parked[i].fd == fd)
            beans_parked[i].dead = 1;
}

// 1 when some parked await can never fire, else -1. Dead flags are the
// portable signal; the descriptor probe is a POSIX fallback for a close
// that bypassed the runtime — it marks what it finds so the await
// finishes off the flag, but it cannot tell a bypassed close whose
// number was already reused from a live descriptor. Closes through the
// runtime never depend on the fallback.
long long beans_reactor_stale_park(void) {
    for (long long i = 0; i < beans_parked_len; i++)
        if (beans_parked[i].dead) return 1;
#if !defined(_WIN32)
    for (long long i = 0; i < beans_parked_len; i++)
        if (fcntl((int)beans_parked[i].fd, F_GETFD, 0) < 0) {
            beans_parked[i].dead = 1;
            return 1;
        }
#endif
    return -1;
}

#endif // BEANS_RT_PROFILE >= BEANS_RT_FULL — sockets + readiness poller

#if BEANS_RT_PROFILE >= BEANS_RT_FULL && !defined(_WIN32)
// Signals stay POSIX-only: Windows has no signalfd-shaped watching to build
// on, and the capability table refuses std.signal there, so nothing links in.
// ---- signals ----------------------------------------------------------------
//
// **No Beans code ever runs in a signal handler.** There is no handler at all. A watched
// signal is *blocked* and then read as data from a descriptor, so handling it is ordinary
// code at an ordinary moment.
//
// That rules out the entire class of async-handler bugs by construction: no reentrancy,
// no async-signal-safety rules to obey, no allocation-inside-a-handler deadlock, and no
// interaction with the reference counting or the cycle collector.
//
// The descriptor is registerable with the poller, so signals and sockets are waited on
// together:
//
//   Linux — signalfd, which is a readable descriptor by design.
//   macOS — a private kqueue with EVFILT_SIGNAL registrations. A kqueue descriptor is
//     itself readable when it has events pending, so it nests inside the outer poller.

// Only asynchronous signals a program can sensibly defer.
//
// SIGKILL and SIGSTOP are absent because they cannot be caught or blocked at all.
// The fault signals — SIGSEGV, SIGBUS, SIGFPE, SIGILL — are absent for a better reason:
// they are *synchronous*, naming an instruction that has already failed. Blocking one and
// reading it later means resuming the faulting instruction, which faults again forever.
// Offering them would be offering a hang.
static const struct {
    const char* name;
    int number;
} sig_table[] = {
    {"interrupt", SIGINT},    {"terminate", SIGTERM}, {"hangup", SIGHUP},
    {"quit", SIGQUIT},        {"user1", SIGUSR1},     {"user2", SIGUSR2},
    {"child", SIGCHLD},       {"pipe", SIGPIPE},      {"alarm", SIGALRM},
    {"window_change", SIGWINCH},
};
#define SIG_TABLE_LEN ((int)(sizeof sig_table / sizeof sig_table[0]))
static _Thread_local unsigned sig_watch_counts[NSIG];

static int sig_known(long long number) {
    for (int i = 0; i < SIG_TABLE_LEN; i++)
        if (sig_table[i].number == (int)number) return 1;
    return 0;
}

static void* sig_bad_number(long long number) {
    char b[192];
    snprintf(b, sizeof b,
             "signal %lld cannot be watched — only signals that can be blocked and "
             "deferred are, which excludes kill/stop and the fault signals",
             number);
    return mk_error(b, "invalid");
}

// Reads the packed numbers into a sigset, rejecting anything not in the table.
static int sig_build_set(BList* packed, sigset_t* into, void** error) {
    sigemptyset(into);
    long long count = packed ? packed->len / 8 : 0;
    if (count == 0) {
        *error = mk_error("watch at least one signal", "invalid");
        return 0;
    }
    for (long long i = 0; i < count; i++) {
        long long number =
            (long long)rt_load_le((char*)packed->data + i * 8, 8);
        if (!sig_known(number)) {
            *error = sig_bad_number(number);
            return 0;
        }
        sigaddset(into, (int)number);
    }
    return 1;
}

// Dequeues any of these signals that are pending, so they cannot be delivered later.
//
// This is where the two platforms genuinely differ. Reading a signalfd *consumes* the
// signal; a kqueue EVFILT_SIGNAL event is only a notification and the signal stays
// pending in the process. Without this, taking a signal on macOS and then unblocking —
// which is what close does — delivers it, and the default action for most of these is to
// terminate. A program would die at teardown from a signal it had already handled.
//
// sigpending is checked first because sigwait on a signal that is *not* pending blocks
// forever. Only the intersection is dequeued, so this can never hang.
static void sig_drain(const sigset_t* watched) {
    sigset_t pending;
    if (sigpending(&pending) != 0) return;
    for (int i = 0; i < SIG_TABLE_LEN; i++) {
        int number = sig_table[i].number;
        if (!sigismember(watched, number) || !sigismember(&pending, number)) continue;
        sigset_t one;
        sigemptyset(&one);
        sigaddset(&one, number);
        int got = 0;
        sigwait(&one, &got); // known pending, so it returns at once
    }
}

// Signal masks are per-thread. Overlapping signal sources share ownership of each
// blocked number, so closing one cannot restore the default action under another.
static sigset_t sig_unowned(const sigset_t* watched) {
    sigset_t out;
    sigemptyset(&out);
    for (int i = 0; i < SIG_TABLE_LEN; i++) {
        int number = sig_table[i].number;
        if (sigismember(watched, number) && sig_watch_counts[number] == 0)
            sigaddset(&out, number);
    }
    return out;
}

static void sig_add_owners(const sigset_t* watched) {
    for (int i = 0; i < SIG_TABLE_LEN; i++) {
        int number = sig_table[i].number;
        if (sigismember(watched, number)) sig_watch_counts[number]++;
    }
}

static sigset_t sig_drop_owners(const sigset_t* watched) {
    sigset_t released;
    sigemptyset(&released);
    for (int i = 0; i < SIG_TABLE_LEN; i++) {
        int number = sig_table[i].number;
        if (!sigismember(watched, number) || sig_watch_counts[number] == 0) continue;
        if (--sig_watch_counts[number] == 0) sigaddset(&released, number);
    }
    return released;
}

BRes beans_signal_watch(BList* packed) {
    sigset_t want;
    void* error = NULL;
    if (!sig_build_set(packed, &want, &error)) return (BRes){0, error};
    sigset_t newly_blocked = sig_unowned(&want);
    // Blocked on this thread, and threads created later inherit the mask. Threads that
    // already exist do not, which is why watching belongs before any spawn — stated in
    // the API docs rather than silently hoped for.
    if (pthread_sigmask(SIG_BLOCK, &want, NULL) != 0)
        return (BRes){0, op_err_obj("signal watch", errno)};
#if defined(__linux__)
    int fd = signalfd(-1, &want, SFD_NONBLOCK | SFD_CLOEXEC);
    if (fd < 0) {
        int e = errno;
        pthread_sigmask(SIG_UNBLOCK, &newly_blocked, NULL);
        return (BRes){0, op_err_obj("signal watch", e)};
    }
#else
    int fd = kqueue();
    if (fd < 0) {
        int e = errno;
        pthread_sigmask(SIG_UNBLOCK, &newly_blocked, NULL);
        return (BRes){0, op_err_obj("signal watch", e)};
    }
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    long long count = packed->len / 8;
    for (long long i = 0; i < count; i++) {
        long long number =
            (long long)rt_load_le((char*)packed->data + i * 8, 8);
        struct kevent reg;
        EV_SET(&reg, (uintptr_t)number, EVFILT_SIGNAL, EV_ADD | EV_ENABLE | EV_RECEIPT,
               0, 0, NULL);
        struct kevent got;
        if (kevent(fd, &reg, 1, &got, 1, NULL) < 0 ||
            ((got.flags & EV_ERROR) && got.data != 0)) {
            int e = (got.flags & EV_ERROR) ? (int)got.data : errno;
            close(fd);
            pthread_sigmask(SIG_UNBLOCK, &newly_blocked, NULL);
            return (BRes){0, op_err_obj("signal watch", e)};
        }
    }
#endif
    sig_add_owners(&want);
    return (BRes){(long long)fd, NULL};
}
long long beans_signal_watch_out(BList* packed, void** e_out) { BRes r = beans_signal_watch(packed); *e_out = r.err; return r.val; }

// [i64 count][i64 number] * count. Never blocks: a signal that has not arrived is
// simply not in the list.
//
// Each signal appears **at most once per call**, however many times it was delivered.
// That is what signalfd does for standard signals — pending is a bitmask, so repeats
// collapse — and kqueue's per-signal counter is deliberately ignored to match. "SIGINT
// arrived" is the useful fact; "SIGINT arrived four times" is not something one platform
// can promise and the other cannot.
BRes beans_signal_take(long long fd, long long max) {
    if (fd < 0) return (BRes){0, mk_error("signal source is closed", "closed")};
    if (max <= 0) return (BRes){0, mk_error("the signal limit must be positive",
                                           "invalid")};
    if (max > SIG_TABLE_LEN) max = SIG_TABLE_LEN;
    long long numbers[SIG_TABLE_LEN];
    long long found = 0;
#if defined(__linux__)
    for (;;) {
        struct signalfd_siginfo info;
        rt_ssize_t got = read((int)fd, &info, sizeof info);
        if (got < 0 && errno == EINTR) continue;
        if (got != (rt_ssize_t)sizeof info) break; // EAGAIN, or nothing more
        long long number = (long long)info.ssi_signo;
        int seen = 0;
        for (long long i = 0; i < found; i++)
            if (numbers[i] == number) seen = 1;
        if (!seen && found < max) numbers[found++] = number;
    }
#else
    struct kevent events[SIG_TABLE_LEN];
    struct timespec zero = {0, 0};
    int n = kevent((int)fd, NULL, 0, events, SIG_TABLE_LEN, &zero);
    if (n < 0 && errno != EINTR)
        return (BRes){0, op_err_obj("signal take", errno)};
    sigset_t taken;
    sigemptyset(&taken);
    for (int i = 0; i < n && found < max; i++) {
        long long number = (long long)events[i].ident;
        int seen = 0;
        for (long long j = 0; j < found; j++)
            if (numbers[j] == number) seen = 1;
        if (!seen) {
            numbers[found++] = number;
            sigaddset(&taken, (int)number);
        }
    }
    // kqueue notified us; the signal is still pending in the process. Dequeue it so
    // `take` consumes, exactly as a signalfd read does.
    if (found > 0) sig_drain(&taken);
#endif
    BList* out = bytes_mk(8 + found * 8);
    char* into = (char*)out->data;
    rt_store_le(into, (unsigned long long)found, 8);
    for (long long i = 0; i < found; i++)
        rt_store_le(into + 8 + i * 8, (unsigned long long)numbers[i], 8);
    return (BRes){(long long)out, NULL};
}
long long beans_signal_take_out(long long fd, long long max, void** e_out) { BRes r = beans_signal_take(fd, max); *e_out = r.err; return r.val; }

BRes beans_signal_close(long long fd, BList* packed) {
    if (fd < 0) return (BRes){0, mk_error("signal source is closed", "closed")};
    sigset_t want;
    void* error = NULL;
    if (sig_build_set(packed, &want, &error)) {
        sigset_t released = sig_drop_owners(&want);
        // Drop anything that arrived and was never read. Unblocking with a signal still
        // pending delivers it immediately, and the default action for most of these is to
        // terminate — so a program that stopped watching would be killed by a signal it
        // had chosen to handle. Discarding is the lesser surprise, and it makes both
        // platforms behave the same.
        sig_drain(&released);
        // Unblock, so the default disposition is restored and a later Ctrl-C works the
        // way the user expects rather than being silently swallowed.
        pthread_sigmask(SIG_UNBLOCK, &released, NULL);
    } else if (error) {
        beans_release(error);
    }
    beans_reactor_note_close(fd);
    if (close((int)fd) != 0 && errno != EINTR)
        return (BRes){0, op_err_obj("signal close", errno)};
    return (BRes){1, NULL};
}
long long beans_signal_close_out(long long fd, BList* packed, void** e_out) { BRes r = beans_signal_close(fd, packed); *e_out = r.err; return r.val; }

// Sends a signal to this process. Exists so signal handling is testable without a second
// process, and it goes through the same table, so it cannot deliver something unwatchable.
BRes beans_signal_raise(long long number) {
    if (!sig_known(number)) return (BRes){0, sig_bad_number(number)};
    if (kill(getpid(), (int)number) != 0)
        return (BRes){0, op_err_obj("signal raise", errno)};
    return (BRes){1, NULL};
}
long long beans_signal_raise_out(long long number, void** e_out) { BRes r = beans_signal_raise(number); *e_out = r.err; return r.val; }

// Signal numbers differ by platform — SIGUSR1 is 10 on Linux and 30 on macOS — so the
// names are the portable part and the numbers come from the C library.
BRes beans_signal_number(char* name) {
    for (int i = 0; i < SIG_TABLE_LEN; i++)
        if (strcmp(sig_table[i].name, name) == 0)
            return (BRes){(long long)sig_table[i].number, NULL};
    char b[192];
    snprintf(b, sizeof b, "no watchable signal called '%s'", name);
    return (BRes){0, mk_error(b, "not_found")};
}
long long beans_signal_number_out(char* name, void** e_out) { BRes r = beans_signal_number(name); *e_out = r.err; return r.val; }

BRes beans_signal_name(long long number) {
    for (int i = 0; i < SIG_TABLE_LEN; i++)
        if (sig_table[i].number == (int)number)
            return (BRes){(long long)rc_strdup(sig_table[i].name), NULL};
    return (BRes){0, sig_bad_number(number)};
}
long long beans_signal_name_out(long long number, void** e_out) { BRes r = beans_signal_name(number); *e_out = r.err; return r.val; }

#endif // BEANS_RT_PROFILE >= BEANS_RT_FULL && !defined(_WIN32) — signals

#if BEANS_RT_PROFILE >= BEANS_RT_FULL && defined(_WIN32)
// Windows has nothing signalfd-shaped to build the watching contract on, but
// the *symbols* must exist there anyway: the self-hosted compiler's
// interpreter imports std.sig so it can interpret programs that use signals,
// and refusing the import at check time would refuse the compiler itself.
// This is the file-locks-on-WASIp1 pattern — the capability is present, and
// every operation reports the gap in a sentence. All six refuse, the lookups
// included: signal numbers are per-OS facts, and inventing a numbering for an
// OS that has none would be a lie with a table.
static void* sig_win_unsupported(void) {
    return mk_error("signal watching is not available on Windows",
                    "unsupported");
}
BRes beans_signal_watch(BList* packed) {
    (void)packed;
    return (BRes){0, sig_win_unsupported()};
}
long long beans_signal_watch_out(BList* packed, void** e_out) { BRes r = beans_signal_watch(packed); *e_out = r.err; return r.val; }
BRes beans_signal_take(long long fd, long long max) {
    (void)fd;
    (void)max;
    return (BRes){0, sig_win_unsupported()};
}
long long beans_signal_take_out(long long fd, long long max, void** e_out) { BRes r = beans_signal_take(fd, max); *e_out = r.err; return r.val; }
BRes beans_signal_close(long long fd, BList* packed) {
    (void)fd;
    (void)packed;
    return (BRes){0, sig_win_unsupported()};
}
long long beans_signal_close_out(long long fd, BList* packed, void** e_out) { BRes r = beans_signal_close(fd, packed); *e_out = r.err; return r.val; }
BRes beans_signal_raise(long long number) {
    (void)number;
    return (BRes){0, sig_win_unsupported()};
}
long long beans_signal_raise_out(long long number, void** e_out) { BRes r = beans_signal_raise(number); *e_out = r.err; return r.val; }
BRes beans_signal_number(char* name) {
    (void)name;
    return (BRes){0, sig_win_unsupported()};
}
long long beans_signal_number_out(char* name, void** e_out) { BRes r = beans_signal_number(name); *e_out = r.err; return r.val; }
BRes beans_signal_name(long long number) {
    (void)number;
    return (BRes){0, sig_win_unsupported()};
}
long long beans_signal_name_out(long long number, void** e_out) { BRes r = beans_signal_name(number); *e_out = r.err; return r.val; }
#endif // BEANS_RT_PROFILE >= BEANS_RT_FULL && defined(_WIN32) — signal stubs

#if BEANS_RT_PROFILE >= BEANS_RT_FULL
// ---- dynamic libraries ------------------------------------------------------
//
// dlopen/dlsym/dlclose behind a move-only handle. On Windows the same three
// verbs are LoadLibraryA/GetProcAddress/FreeLibrary; there is no dlerror text,
// so messages carry the GetLastError number instead.
//
// **RTLD_LOCAL, deliberately.** RTLD_GLOBAL would publish the library's symbols into the
// global namespace, where an `extern "C" fn` would then resolve to them — in the
// interpreter, which looks symbols up with dlsym(RTLD_DEFAULT), but not in a native
// build, where extern names are bound by the linker. The two backends would disagree
// about whether a program links, which is exactly the failure this project tests against.
// (LoadLibrary is local by construction — Windows has no global namespace to pollute.)
//
// Calling a resolved address is `unsafe` and cannot be otherwise: the signature is the
// caller's guess, and a wrong guess corrupts the stack rather than raising an error.


BRes beans_dl_open(char* path) {
    if (!path || beans_slen(path) == 0)
        return (BRes){0, mk_error("a library path is required", "invalid")};
#if defined(_WIN32)
    wchar_t* wpath = win_widen(path);
    HMODULE handle = wpath ? LoadLibraryW(wpath) : NULL;
    free(wpath);
    if (!handle) {
        char b[512];
        snprintf(b, sizeof b, "cannot load %s: error %lu", path,
                 (unsigned long)GetLastError());
        return (BRes){0, mk_error(b, "not_found")};
    }
#else
    dlerror(); // clear any stale message before the call that matters
    void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char* why = dlerror();
        char b[512];
        snprintf(b, sizeof b, "%s", why ? why : "could not open the library");
        return (BRes){0, mk_error(b, "not_found")};
    }
#endif
    return (BRes){(long long)(intptr_t)handle, NULL};
}
long long beans_dl_open_out(char* path, void** e_out) { BRes r = beans_dl_open(path); *e_out = r.err; return r.val; }

BRes beans_dl_symbol(long long handle, char* name) {
    if (handle == 0) return (BRes){0, mk_error("library is closed", "closed")};
    if (!name || beans_slen(name) == 0)
        return (BRes){0, mk_error("a symbol name is required", "invalid")};
#if defined(_WIN32)
    // No PE symbol can live at address 0, so NULL is a reliable failure signal
    // here — the dlerror dance below exists because dlsym's cannot be.
    void* address = (void*)GetProcAddress((HMODULE)(intptr_t)handle, name);
    if (!address) {
        char b[512];
        snprintf(b, sizeof b, "no symbol '%s': error %lu", name,
                 (unsigned long)GetLastError());
        return (BRes){0, mk_error(b, "not_found")};
    }
#else
    dlerror();
    void* address = dlsym((void*)(intptr_t)handle, name);
    const char* why = dlerror();
    // A symbol can legitimately resolve to address 0, so dlerror is the only reliable
    // test — checking the address alone would report a false failure.
    if (why) {
        char b[512];
        snprintf(b, sizeof b, "%s", why);
        return (BRes){0, mk_error(b, "not_found")};
    }
#endif
    return (BRes){(long long)(intptr_t)address, NULL};
}
long long beans_dl_symbol_out(long long handle, char* name, void** e_out) { BRes r = beans_dl_symbol(handle, name); *e_out = r.err; return r.val; }

#if defined(_WIN32)
__declspec(dllimport) int __stdcall K32EnumProcessModules(void* process, HMODULE* out,
                                                          unsigned long bytes,
                                                          unsigned long* needed);

// UCRT provides these to linked code but does not publish them with the same
// names on every Windows ABI. Keep callable functions inside the Beans image
// so the tree interpreter gets honest C function pointers on x86 too.
static long long beans_host_llabs(long long value) { return llabs(value); }
static double beans_host_fabs(double value) { return fabs(value); }
static float beans_host_fabsf(float value) { return fabsf(value); }
static double beans_host_ldexp(double value, int exponent) {
    return ldexp(value, exponent);
}
static float beans_host_ldexpf(float value, int exponent) {
    return ldexpf(value, exponent);
}
#endif

BRes beans_dl_global_symbol(char* name) {
    if (!name || beans_slen(name) == 0)
        return (BRes){0, mk_error("a symbol name is required", "invalid")};
#if defined(_WIN32)
    // dlsym(RTLD_DEFAULT, ...) searches every image loaded into the process, and
    // Windows has no single call that does the same — GetProcAddress needs one
    // module. Walking the loader's module list is the honest equivalent: same
    // set, same order (the executable first), so a symbol the CRT provides
    // resolves the way it does on POSIX. This is not a nicety — extern "C" in
    // an *interpreted* program goes through here, so without it half the
    // differential contract could not call C at all on Windows.
    //
    // K32EnumProcessModules is exported straight from kernel32, so this needs
    // no import library of its own; it is declared above by hand because
    // psapi.h reaches this file through nothing else and its
    // EnumProcessModules macro depends on a PSAPI_VERSION the sysroot may or
    // may not default to.
    void* address = NULL;
    HMODULE loaded[192];
    unsigned long needed = 0;
    if (K32EnumProcessModules(GetCurrentProcess(), loaded, (unsigned long)sizeof loaded,
                              &needed)) {
        unsigned long count = needed / (unsigned long)sizeof(HMODULE);
        if (count > sizeof loaded / sizeof loaded[0])
            count = sizeof loaded / sizeof loaded[0];
        for (unsigned long i = 0; i < count && !address; i++)
            address = (void*)GetProcAddress(loaded[i], name);
    } else {
        // The walk is the whole search, so a failure here is not silent: fall
        // back to what the old code did rather than reporting nothing at all.
        address = (void*)GetProcAddress(GetModuleHandleW(NULL), name);
    }
    if (!address && strcmp(name, "llabs") == 0)
        address = (void*)(uintptr_t)&beans_host_llabs;
    else if (!address && strcmp(name, "fabs") == 0)
        address = (void*)(uintptr_t)&beans_host_fabs;
    else if (!address && strcmp(name, "fabsf") == 0)
        address = (void*)(uintptr_t)&beans_host_fabsf;
    else if (!address && strcmp(name, "ldexp") == 0)
        address = (void*)(uintptr_t)&beans_host_ldexp;
    else if (!address && strcmp(name, "ldexpf") == 0)
        address = (void*)(uintptr_t)&beans_host_ldexpf;
    if (!address) {
        char b[512];
        snprintf(b, sizeof b, "no symbol '%s': error %lu", name,
                 (unsigned long)GetLastError());
        return (BRes){0, mk_error(b, "not_found")};
    }
#else
    dlerror();
    void* address = dlsym(RTLD_DEFAULT, name);
    const char* why = dlerror();
    if (why) {
        char b[512];
        snprintf(b, sizeof b, "%s", why);
        return (BRes){0, mk_error(b, "not_found")};
    }
#endif
    return (BRes){(long long)(intptr_t)address, NULL};
}
long long beans_dl_global_symbol_out(char* name, void** e_out) { BRes r = beans_dl_global_symbol(name); *e_out = r.err; return r.val; }

BRes beans_dl_close(long long handle) {
    if (handle == 0) return (BRes){0, mk_error("library is closed", "closed")};
#if defined(_WIN32)
    if (!FreeLibrary((HMODULE)(intptr_t)handle)) {
        char b[512];
        snprintf(b, sizeof b, "could not close the library: error %lu",
                 (unsigned long)GetLastError());
        return (BRes){0, mk_error(b, "io")};
    }
#else
    if (dlclose((void*)(intptr_t)handle) != 0) {
        const char* why = dlerror();
        char b[512];
        snprintf(b, sizeof b, "%s", why ? why : "could not close the library");
        return (BRes){0, mk_error(b, "io")};
    }
#endif
    return (BRes){1, NULL};
}
long long beans_dl_close_out(long long handle, void** e_out) { BRes r = beans_dl_close(handle); *e_out = r.err; return r.val; }

// call0..call3 are integer/pointer words. The typed float rows below exist for the
// self-hosted interpreter's checked extern declarations; by-value records and callbacks
// still take a Clang-classified bridge rather than guessing the platform ABI here.
long long beans_dl_call0(long long fn) {
    return ((long long (*)(void))(intptr_t)fn)();
}
long long beans_dl_call1(long long fn, long long a) {
    return ((long long (*)(long long))(intptr_t)fn)(a);
}
long long beans_dl_call2(long long fn, long long a, long long b) {
    return ((long long (*)(long long, long long))(intptr_t)fn)(a, b);
}
long long beans_dl_call3(long long fn, long long a, long long b, long long c) {
    return ((long long (*)(long long, long long, long long))(intptr_t)fn)(a, b, c);
}
void beans_dl_call_void0(long long fn) {
    ((void (*)(void))(intptr_t)fn)();
}
void beans_dl_call_void1(long long fn, long long a) {
    ((void (*)(long long))(intptr_t)fn)(a);
}
void beans_dl_call_void2(long long fn, long long a, long long b) {
    ((void (*)(long long, long long))(intptr_t)fn)(a, b);
}
void beans_dl_call_void3(long long fn, long long a, long long b, long long c) {
    ((void (*)(long long, long long, long long))(intptr_t)fn)(a, b, c);
}
double beans_dl_call_f64_1(long long fn, double value) {
    return ((double (*)(double))(intptr_t)fn)(value);
}
double beans_dl_call_f64_i32(long long fn, double value, long long exponent) {
    return ((double (*)(double, int32_t))(intptr_t)fn)(value, (int32_t)exponent);
}
double beans_dl_call_f32_1(long long fn, double value) {
    return (double)((float (*)(float))(intptr_t)fn)((float)value);
}
double beans_dl_call_f32_i32(long long fn, double value, long long exponent) {
    return (double)((float (*)(float, int32_t))(intptr_t)fn)(
        (float)value, (int32_t)exponent);
}

#endif // BEANS_RT_PROFILE >= BEANS_RT_FULL — dynamic libraries

#if BEANS_RT_PROFILE >= BEANS_RT_FULL
// The self-hosted interpreter compiles a Clang ABI bridge for a checked extern
// signature. Its dispatch closure is a normal Beans C callback, so this fixed
// helper is the one statically linked point where the dynamic bridge and the
// generated callback trampoline meet. Portable on purpose: it is a plain
// function-pointer trampoline, and the compiler's own interpreter links it on
// every hosted platform — the platform-specific parts (compiling the bridge,
// loading it) ride the process and dynamic-library capabilities.
typedef void (*BeansTreeFfiDispatch)(void*, void*, void**);
typedef void (*BeansTreeFfiBridge)(void*, void*, void**, BeansTreeFfiDispatch,
                                   void**);
void beans_tree_ffi_invoke_bridge(void* bridge, void* symbol, void* result,
                                  void** arguments,
                                  BeansTreeFfiDispatch dispatch,
                                  void** contexts) {
    ((BeansTreeFfiBridge)bridge)(symbol, result, arguments, dispatch, contexts);
}

#endif // BEANS_RT_PROFILE >= BEANS_RT_FULL — tree-FFI bridge

#if BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
// threads, CPU detection and futex-backed wait/notify need a hosted platform:
// pthreads, sysctl or getauxval, and a futex. A freestanding program has one
// thread by construction.
// ---- threads ----
typedef struct {
    void* payload;
    long long result;
    pthread_t th;
    long long (*thunk)(void*);
    void (*typed_thunk)(void*, void*);
    void* env;
    long long result_size;
    int joined;
} BThread;
void beans_thread_release_env(void* env);
static void* thread_main(void* arg) {
    BThread* t = arg;
    if (t->typed_thunk) t->typed_thunk(t->env, t->payload);
    else t->result = t->thunk(t->env);
    beans_release(t->env);
    beans_release(t); // the running thread's own ref on the handle
    // last heap touch is done — the cycle collector may run again
    cc_threads -= 1;
    return NULL;
}
BThread* beans_thread_spawn(void* thunk, void* env, long long result_ptr) {
    long long result_mask =
        result_ptr ? RT_I64_SLOT_MASK_AT(offsetof(BThread, result)) : 0;
    BThread* t = beans_alloc(sizeof(BThread), 1 | (result_mask << 3));
    t->thunk = (long long (*)(void*))thunk;
    t->env = env; // ownership of the closure box moves to the thread
    cc_enable_mt(); // from here every count op is atomic, in every thread
    beans_retain(t); // one ref for the handle, one for the running thread
    cc_threads += 1;
    pthread_create(&t->th, NULL, thread_main, t);
    return t;
}
BThread* beans_thread_spawn_typed(void* thunk, void* env, long long size,
                                  long long ptr_mask) {
    if (size <= 0 || size > (1LL << 30))
        beans_panic("invalid thread result size", 0, 0);
    BThread* t = beans_alloc(sizeof(BThread), 1 | (1LL << 3));
    t->payload = beans_alloc(size, 1 | (ptr_mask << 3));
    t->result_size = size;
    t->typed_thunk = (void (*)(void*, void*))thunk;
    t->env = env;
    cc_enable_mt();
    beans_retain(t);
    cc_threads += 1;
    pthread_create(&t->th, NULL, thread_main, t);
    return t;
}
long long beans_thread_join(BThread* t) {
    if (t->joined) beans_panic("thread already joined", 0, 0);
    t->joined = 1;
    pthread_join(t->th, NULL);
    long long result = t->result;
    t->result = 0; // ownership of a pointer result moves to the caller
    return result;
}
void beans_thread_join_typed(BThread* t, void* out, long long size) {
    if (t->joined) beans_panic("thread already joined", 0, 0);
    t->joined = 1;
    pthread_join(t->th, NULL);
    if (size != t->result_size) beans_panic("thread result size mismatch", 0, 0);
    void* payload = t->payload;
    memcpy(out, payload, (size_t)size);
    memset(payload, 0, (size_t)size); // move nested refs out of the payload box
    t->payload = NULL;
    beans_release(payload);
}

BMutex* beans_mutex_new(long long inner, long long inner_ptr) {
    BMutex* mu = beans_alloc(sizeof(BMutex), 5 | (inner_ptr << 3));
    pthread_mutex_init(&mu->m, NULL);
    mu->inner = inner;
    return mu;
}
long long beans_mutex_lock(BMutex* mu) {
    pthread_mutex_lock(&mu->m);
    return mu->inner;
}
BMutex* beans_mutex_new_typed(void* value, long long size, long long ptr_mask) {
    if (size <= 0 || size > (1LL << 30))
        beans_panic("invalid mutex value size", 0, 0);
    void* payload = beans_alloc(size, 1 | (ptr_mask << 3));
    memcpy(payload, value, (size_t)size);
    return beans_mutex_new((long long)payload, 1);
}
void beans_mutex_lock_typed(BMutex* mu, void* out, long long size) {
    pthread_mutex_lock(&mu->m);
    memcpy(out, (void*)mu->inner, (size_t)size);
}
void beans_mutex_unlock(BMutex* mu) { pthread_mutex_unlock(&mu->m); }

BChan* beans_chan_new(long long cap, long long elem_ptr) {
    BChan* c = beans_alloc(sizeof(BChan), 4 | (elem_ptr << 3));
    c->cap = cap > 0 ? cap : 1;
    c->stride = -8; // generic i64 slot; see the object-ABI walker
    c->ptr_mask = elem_ptr;
    c->q = calloc((size_t)c->cap, 8);
    if (!c->q) beans_panic("out of memory", 0, 0);
    pthread_mutex_init(&c->m, NULL);
    pthread_cond_init(&c->can_send, NULL);
    pthread_cond_init(&c->can_recv, NULL);
    return c;
}
BChan* beans_chan_new_typed(long long cap, long long stride, long long ptr_mask) {
    if (stride <= 0 || stride > (1LL << 30))
        beans_panic("invalid channel element size", 0, 0);
    long long capacity = cap > 0 ? cap : 1;
    if (capacity > (1LL << 58) / stride)
        beans_panic("channel capacity too large", 0, 0);
    BChan* c = beans_alloc(sizeof(BChan), 4 | ((ptr_mask != 0) << 3));
    c->cap = capacity;
    c->stride = stride;
    c->ptr_mask = ptr_mask;
    c->q = calloc((size_t)capacity, (size_t)stride);
    if (!c->q) beans_panic("out of memory", 0, 0);
    pthread_mutex_init(&c->m, NULL);
    pthread_cond_init(&c->can_send, NULL);
    pthread_cond_init(&c->can_recv, NULL);
    return c;
}
long long beans_chan_send(BChan* c, long long v) {
    pthread_mutex_lock(&c->m);
    while (c->count == c->cap && !c->closed) pthread_cond_wait(&c->can_send, &c->m);
    if (c->closed) {
        pthread_mutex_unlock(&c->m);
        return 0; // caller panics; caller also still owns v
    }
    c->q[(c->head + c->count) % c->cap] = v;
    c->count += 1;
    pthread_cond_signal(&c->can_recv);
    pthread_mutex_unlock(&c->m);
    return 1;
}
long long beans_chan_send_typed(BChan* c, void* value) {
    pthread_mutex_lock(&c->m);
    while (c->count == c->cap && !c->closed) pthread_cond_wait(&c->can_send, &c->m);
    if (c->closed) {
        pthread_mutex_unlock(&c->m);
        return 0;
    }
    void* destination =
        (char*)c->q + ((c->head + c->count) % c->cap) * c->stride;
    memcpy(destination, value, (size_t)c->stride);
    c->count += 1;
    pthread_cond_signal(&c->can_recv);
    pthread_mutex_unlock(&c->m);
    return 1;
}
long long beans_chan_recv(BChan* c, long long* ok) {
    pthread_mutex_lock(&c->m);
    while (c->count == 0 && !c->closed) pthread_cond_wait(&c->can_recv, &c->m);
    if (c->count == 0) {
        *ok = 0;
        pthread_mutex_unlock(&c->m);
        return 0;
    }
    long long v = c->q[c->head];
    c->head = (c->head + 1) % c->cap;
    c->count -= 1;
    *ok = 1;
    pthread_cond_signal(&c->can_send);
    pthread_mutex_unlock(&c->m);
    return v;
}
long long beans_chan_recv_typed(BChan* c, void* out) {
    pthread_mutex_lock(&c->m);
    while (c->count == 0 && !c->closed) pthread_cond_wait(&c->can_recv, &c->m);
    if (c->count == 0) {
        pthread_mutex_unlock(&c->m);
        return 0;
    }
    void* source = (char*)c->q + c->head * c->stride;
    memcpy(out, source, (size_t)c->stride);
    memset(source, 0, (size_t)c->stride);
    c->head = (c->head + 1) % c->cap;
    c->count -= 1;
    pthread_cond_signal(&c->can_send);
    pthread_mutex_unlock(&c->m);
    return 1;
}
void beans_chan_close(BChan* c) {
    pthread_mutex_lock(&c->m);
    c->closed = 1;
    pthread_cond_broadcast(&c->can_send);
    pthread_cond_broadcast(&c->can_recv);
    pthread_mutex_unlock(&c->m);
}

typedef struct { _Atomic long long v; } BAtomic;
BAtomic* beans_atomic_new(long long init) {
    BAtomic* a = beans_alloc(sizeof(BAtomic), 0);
    __atomic_store_n((long long*)&a->v, init, __ATOMIC_SEQ_CST);
    return a;
}
long long beans_atomic_add(BAtomic* a, long long d) {
    return __atomic_add_fetch((long long*)&a->v, d, __ATOMIC_SEQ_CST);
}
long long beans_atomic_get(BAtomic* a) {
    return __atomic_load_n((long long*)&a->v, __ATOMIC_SEQ_CST);
}
void beans_atomic_set(BAtomic* a, long long v) {
    __atomic_store_n((long long*)&a->v, v, __ATOMIC_SEQ_CST);
}

// ---- CPU feature detection --------------------------------------------------
//
// Asked about the machine the program is *running* on, not the one it was compiled
// for. The first call fills a cached table; after that a query is a name compare
// against a short list.
//
// BEANS_CPU_FEATURES can only mask features *down*: a test may pretend a feature is
// absent to force the generic path, but it can never claim hardware the machine
// does not have. Letting it add features would make a test pass on a CPU that would
// trap on the instruction.

// CPUID, XGETBV and PAUSE are x86 *family* instructions, not 64-bit ones, and
// 32-bit Windows is a supported target. Gating them on __x86_64__ alone left an
// i686 binary detecting no features whatsoever — not even the sse2 that is its
// own registered baseline — so `cpu.has` answered false for hardware the target
// is compiled to assume.
#if defined(__x86_64__) || defined(__i386__)
#define BEANS_X86 1
#endif

#if defined(BEANS_X86)
#include <cpuid.h>
#elif defined(__linux__) && defined(__aarch64__)
#include <sys/auxv.h>
#elif defined(__APPLE__) && defined(__aarch64__)
#include <sys/sysctl.h>
#elif defined(_WIN32) && defined(__aarch64__)
// Windows on ARM has neither getauxval nor sysctl. IsProcessorFeaturePresent
// is the documented API and the only reliable one, so it is what gets asked;
// anything it cannot answer is reported absent rather than guessed at.
#include <windows.h>
#endif

#define BEANS_MAX_CPU_FEATURES 32
static const char* beans_cpu_names[BEANS_MAX_CPU_FEATURES];
static int beans_cpu_count;
static int beans_cpu_ready;
static pthread_once_t beans_cpu_once = PTHREAD_ONCE_INIT;

static void beans_cpu_add(const char* name, int present) {
    if (!present || beans_cpu_count >= BEANS_MAX_CPU_FEATURES) return;
    beans_cpu_names[beans_cpu_count++] = name;
}

#if defined(__APPLE__) && defined(__aarch64__)
static int beans_sysctl_flag(const char* key) {
    int value = 0;
    size_t size = sizeof value;
    if (sysctlbyname(key, &value, &size, 0, 0) != 0) return 0;
    return value != 0;
}
#endif

#if defined(BEANS_X86)
static unsigned long long beans_xgetbv0(void) {
    unsigned lo = 0, hi = 0;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    return ((unsigned long long)hi << 32) | lo;
}
#endif

static void beans_cpu_detect(void) {
#if defined(BEANS_X86)
    unsigned a = 0, b = 0, c = 0, d = 0;
    int avx_state = 0;
    int avx512_state = 0;
    if (__get_cpuid(1, &a, &b, &c, &d)) {
        // CPUID says what the CPU can do; XCR0 says which register state the
        // OS will preserve. Reporting AVX without both would let it trap.
        if ((c >> 27) & 1) {
            unsigned long long xcr0 = beans_xgetbv0();
            avx_state = (xcr0 & 0x6) == 0x6;
            avx512_state = (xcr0 & 0xe6) == 0xe6;
        }
        beans_cpu_add("sse2", (d >> 26) & 1);
        beans_cpu_add("sse3", c & 1);
        beans_cpu_add("ssse3", (c >> 9) & 1);
        beans_cpu_add("sse4.1", (c >> 19) & 1);
        beans_cpu_add("sse4.2", (c >> 20) & 1);
        beans_cpu_add("popcnt", (c >> 23) & 1);
        beans_cpu_add("aes", (c >> 25) & 1);
        beans_cpu_add("avx", ((c >> 28) & 1) && avx_state);
        beans_cpu_add("f16c", ((c >> 29) & 1) && avx_state);
        beans_cpu_add("pclmul", (c >> 1) & 1);
        beans_cpu_add("fma", ((c >> 12) & 1) && avx_state);
    }
    // The AVX2 family lives in leaf 7, sub-leaf 0.
    a = b = c = d = 0;
    if (__get_cpuid_count(7, 0, &a, &b, &c, &d)) {
        beans_cpu_add("avx2", ((b >> 5) & 1) && avx_state);
        beans_cpu_add("bmi", (b >> 3) & 1);
        beans_cpu_add("bmi2", (b >> 8) & 1);
        beans_cpu_add("avx512f", ((b >> 16) & 1) && avx512_state);
    }
#elif defined(__aarch64__)
#if defined(__APPLE__)
    // NEON is part of the base architecture on arm64, so it is not optional.
    beans_cpu_add("neon", 1);
    beans_cpu_add("fp16", beans_sysctl_flag("hw.optional.arm.FEAT_FP16"));
    beans_cpu_add("dotprod", beans_sysctl_flag("hw.optional.arm.FEAT_DotProd"));
    beans_cpu_add("crc", beans_sysctl_flag("hw.optional.armv8_crc32"));
    beans_cpu_add("aes", beans_sysctl_flag("hw.optional.arm.FEAT_AES"));
    beans_cpu_add("sha2", beans_sysctl_flag("hw.optional.arm.FEAT_SHA256"));
    beans_cpu_add("sha3", beans_sysctl_flag("hw.optional.arm.FEAT_SHA3"));
    beans_cpu_add("lse", beans_sysctl_flag("hw.optional.arm.FEAT_LSE"));
#elif defined(__linux__)
    unsigned long caps = getauxval(AT_HWCAP);
    beans_cpu_add("neon", (caps & (1UL << 1)) != 0);   /* HWCAP_ASIMD */
    beans_cpu_add("fp16", (caps & (1UL << 9)) != 0);   /* HWCAP_FPHP  */
    beans_cpu_add("dotprod", (caps & (1UL << 20)) != 0);
    beans_cpu_add("crc", (caps & (1UL << 7)) != 0);
    beans_cpu_add("aes", (caps & (1UL << 3)) != 0);
    beans_cpu_add("sha2", (caps & (1UL << 6)) != 0);
    beans_cpu_add("sha3", (caps & (1UL << 17)) != 0);
    beans_cpu_add("lse", (caps & (1UL << 8)) != 0);
#elif defined(_WIN32)
    // Windows on ARM. IsProcessorFeaturePresent is the documented API and the
    // only reliable one here, so every answer below comes from it. NEON is part
    // of the base arm64 architecture and is not optional, exactly as on the two
    // POSIX branches above.
    //
    // sha3 is deliberately absent rather than guessed: Windows exposes no
    // processor-feature flag for it, and claiming a feature the OS will not
    // confirm is how a program ends up trapping on an instruction the machine
    // does not have. Reporting it absent only costs the generic path. fp16 does
    // have a flag (PF_ARM_V82_FP16_INSTRUCTIONS_AVAILABLE), so it is detected
    // like the rest. aes and sha2 share one flag because Windows reports the v8
    // crypto extension as a unit.
    beans_cpu_add("neon", 1);
    beans_cpu_add("fp16",
                  IsProcessorFeaturePresent(PF_ARM_V82_FP16_INSTRUCTIONS_AVAILABLE));
    beans_cpu_add("crc",
                  IsProcessorFeaturePresent(PF_ARM_V8_CRC32_INSTRUCTIONS_AVAILABLE));
    beans_cpu_add("aes",
                  IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE));
    beans_cpu_add("sha2",
                  IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE));
    beans_cpu_add("lse",
                  IsProcessorFeaturePresent(PF_ARM_V81_ATOMIC_INSTRUCTIONS_AVAILABLE));
    beans_cpu_add("dotprod",
                  IsProcessorFeaturePresent(PF_ARM_V82_DP_INSTRUCTIONS_AVAILABLE));
#else
    beans_cpu_add("neon", 1);
#endif
#elif defined(__riscv)
    // The compiler macros name the ISA this binary requires. A machine missing
    // one cannot run it, so they are the exact baseline answer without an OS
    // feature API. The environment mask below can still hide any of them.
#if defined(__riscv_mul)
    beans_cpu_add("m", 1);
#endif
#if defined(__riscv_atomic)
    beans_cpu_add("a", 1);
#endif
#if defined(__riscv_compressed)
    beans_cpu_add("c", 1);
#endif
#if defined(__riscv_flen) && __riscv_flen >= 32
    beans_cpu_add("f", 1);
#endif
#if defined(__riscv_flen) && __riscv_flen >= 64
    beans_cpu_add("d", 1);
#endif
#elif defined(__loongarch__)
    // Rust's LoongArch64 Linux host baseline requires LSX. A binary compiled
    // for this target cannot start on a machine without it.
#if defined(__loongarch_sx)
    beans_cpu_add("lsx", 1);
#endif
#endif
    beans_cpu_ready = 1;
}

// A comma- or space-separated allowlist. Present in the list *and* detected is what
// counts, so this can only ever remove.
static int beans_cpu_masked_out(const char* name) {
    const char* mask = getenv("BEANS_CPU_FEATURES");
    if (!mask) return 0;
    size_t want = strlen(name);
    for (const char* at = mask; *at;) {
        while (*at == ',' || *at == ' ') at++;
        const char* start = at;
        while (*at && *at != ',' && *at != ' ') at++;
        if ((size_t)(at - start) == want && strncmp(start, name, want) == 0) return 0;
    }
    return 1;
}

// One instruction, spelled differently per architecture and with no portable LLVM
// intrinsic, so it lives here instead of being written twice in codegen.
void beans_spin_hint(void) {
#if defined(BEANS_X86)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield" ::: "memory");
#else
    /* Nothing to hint with; a spin loop still makes progress. */
#endif
}

long long beans_cpu_has(const char* name) {
    pthread_once(&beans_cpu_once, beans_cpu_detect);
    if (!name) return 0;
    for (int i = 0; i < beans_cpu_count; i++) {
        if (strcmp(beans_cpu_names[i], name) == 0) return !beans_cpu_masked_out(name);
    }
    return 0;
}

// ---- atomic wait / notify ---------------------------------------------------
//
// wait blocks while the cell still holds `expected`; notify wakes waiters on that
// address. Spurious wakeups are allowed and every caller re-reads the value, which
// is what makes the two implementations below interchangeable:
//
//   * Linux, 32-bit cell: a real futex. That is what the syscall takes, and it
//     needs no bookkeeping of our own.
//   * everything else: an address-keyed parking lot over pthread mutex+condvar.
//     macOS has no public futex, and futex only handles 32-bit words anyway.
//
// The choice is a function of the element width alone, so wait and notify on one
// cell always pick the same path. Waiter records live on the waiting thread's own
// stack and are linked under the bucket lock, so notify counts waiters exactly and
// nothing is allocated on either path.

// MemoryOrder's stable enum tags: relaxed=0, acquire=1, seq_cst=4. The checker
// rejects release/acq_rel for a wait, but defaulting unknown values to seq_cst keeps
// the runtime safe if malformed IR calls it directly.
static int beans_atomic_load_order(long long order) {
    if (order == 0) return __ATOMIC_RELAXED;
    if (order == 1) return __ATOMIC_ACQUIRE;
    return __ATOMIC_SEQ_CST;
}

static unsigned long long beans_ordered_load(const void* address, long long width,
                                             long long order) {
    int host_order = beans_atomic_load_order(order);
    switch (width) {
        case 8: return __atomic_load_n((const unsigned char*)address, host_order);
        case 16: return __atomic_load_n((const unsigned short*)address, host_order);
        case 32: return __atomic_load_n((const unsigned int*)address, host_order);
        default:
            return __atomic_load_n((const unsigned long long*)address, host_order);
    }
}

#if defined(__linux__)
// Linux's futex uapi numbers are stable, but <linux/futex.h> is a kernel
// development header and is absent from a normal Alpine/musl toolchain. Beans
// only needs WAIT and WAKE with the PRIVATE flag (128), so keep those two
// values local and leave every other futex operation out.
#define BEANS_FUTEX_WAIT_PRIVATE 128
#define BEANS_FUTEX_WAKE_PRIVATE 129

static long long beans_futex_wait(void* address, unsigned int expected,
                                  long long timeout_ns, int has_timeout) {
    struct timespec budget;
    struct timespec* deadline = 0;
    if (has_timeout) {
        budget.tv_sec = (time_t)(timeout_ns / 1000000000LL);
        budget.tv_nsec = (long)(timeout_ns % 1000000000LL);
        deadline = &budget;
    }
    for (;;) {
        long rc = syscall(SYS_futex, address, BEANS_FUTEX_WAIT_PRIVATE, expected, deadline,
                          0, 0);
        if (rc == 0) return 1;         // woken; the caller re-checks
        if (errno == EAGAIN) return 1; // already changed before we parked
        if (errno == ETIMEDOUT) return 0;
        if (errno == EINTR) {
            // A signal, not a wakeup. Retrying with the same relative budget can
            // over-wait, so report it as a wakeup and let the caller's own loop
            // decide — it re-reads the value either way.
            return 1;
        }
        return 1; // unknown failure: never block forever on it
    }
}

static long long beans_futex_wake(void* address, int all) {
    long rc = syscall(SYS_futex, address, BEANS_FUTEX_WAKE_PRIVATE,
                      all ? INT_MAX : 1, 0, 0, 0);
    return rc < 0 ? 0 : (long long)rc;
}
#endif

#define BEANS_PARK_BUCKETS 64
typedef struct BParkNode {
    struct BParkNode* next;
    const void* address;
    int signalled;
} BParkNode;
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t c;
    BParkNode* head;
} BParkBucket;
static BParkBucket beans_park[BEANS_PARK_BUCKETS];
static pthread_once_t beans_park_once = PTHREAD_ONCE_INIT;
static void beans_park_init(void) {
    for (int i = 0; i < BEANS_PARK_BUCKETS; i++) {
        pthread_mutex_init(&beans_park[i].m, 0);
        pthread_cond_init(&beans_park[i].c, 0);
        beans_park[i].head = 0;
    }
}
static BParkBucket* beans_park_bucket(const void* address) {
    pthread_once(&beans_park_once, beans_park_init);
    // Heap addresses are aligned, so the low bits carry no information. Mix before
    // masking or every cell in one allocation lands in the same bucket.
    unsigned long long bits = (unsigned long long)(uintptr_t)address;
    bits ^= bits >> 33;
    bits *= 0xff51afd7ed558ccdULL;
    bits ^= bits >> 33;
    return &beans_park[bits & (BEANS_PARK_BUCKETS - 1)];
}

// 1 = woken or the value already moved, 0 = the timeout ran out.
long long beans_atomic_wait(void* address, long long width,
                            unsigned long long expected, long long timeout_ns,
                            long long has_timeout, long long order) {
    if (has_timeout && timeout_ns <= 0)
        return beans_ordered_load(address, width, order) != expected;
    if (beans_ordered_load(address, width, order) != expected) return 1;
#if defined(__linux__)
    if (width == 32) {
        long long result = beans_futex_wait(address, (unsigned int)expected, timeout_ns,
                                            (int)has_timeout);
        // The kernel compares atomically but does not express a C memory order.
        // Re-read after either a wake or a timeout so acquire/seq_cst has the
        // ordering the call site requested.
        (void)beans_ordered_load(address, width, order);
        return result;
    }
#endif
    BParkBucket* bucket = beans_park_bucket(address);
    struct timespec deadline;
    if (has_timeout) {
        // pthread_cond_timedwait takes an absolute CLOCK_REALTIME point. macOS has
        // no monotonic condvar, and a bounded wait does not need one.
        beans_wall_timespec(&deadline);
        long long nanos = deadline.tv_nsec + timeout_ns % 1000000000LL;
        deadline.tv_sec += (time_t)(timeout_ns / 1000000000LL + nanos / 1000000000LL);
        deadline.tv_nsec = (long)(nanos % 1000000000LL);
    }
    pthread_mutex_lock(&bucket->m);
    if (beans_ordered_load(address, width, order) != expected) {
        pthread_mutex_unlock(&bucket->m);
        return 1;
    }
    BParkNode node;
    node.next = bucket->head;
    node.address = address;
    node.signalled = 0;
    bucket->head = &node;
    long long timed_out = 0;
    while (!node.signalled &&
           beans_ordered_load(address, width, order) == expected) {
        if (has_timeout) {
            if (pthread_cond_timedwait(&bucket->c, &bucket->m, &deadline) == ETIMEDOUT) {
                timed_out = 1;
                break;
            }
        } else {
            pthread_cond_wait(&bucket->c, &bucket->m);
        }
    }
    for (BParkNode** link = &bucket->head; *link; link = &(*link)->next) {
        if (*link == &node) {
            *link = node.next;
            break;
        }
    }
    // A notifier sets `signalled` before the loop reaches its value check. Keep
    // the ordered re-read unconditional so an acquire is never skipped.
    (void)beans_ordered_load(address, width, order);
    pthread_mutex_unlock(&bucket->m);
    return timed_out ? 0 : 1;
}

// Number of waiters woken. `all` picks every waiter on the address, not just one.
long long beans_atomic_notify(void* address, long long width, long long all) {
#if defined(__linux__)
    if (width == 32) return beans_futex_wake(address, (int)all);
#else
    (void)width;
#endif
    BParkBucket* bucket = beans_park_bucket(address);
    pthread_mutex_lock(&bucket->m);
    long long woken = 0;
    for (BParkNode* node = bucket->head; node; node = node->next) {
        if (node->address != address || node->signalled) continue;
        node->signalled = 1;
        woken++;
        if (!all) break;
    }
    // One condvar serves the whole bucket, so this also wakes waiters on other
    // addresses. They re-check and park again: over-waking is safe, under-waking
    // hangs. It is also what C++20's notify_one permits — "at least one".
    if (woken) pthread_cond_broadcast(&bucket->c);
    pthread_mutex_unlock(&bucket->m);
    return woken;
}


#endif // BEANS_RT_PROFILE >= BEANS_RT_MINIMAL
#if BEANS_RT_DECIMAL
// ---- decimal: checked 38-digit coefficient + scale --------------------------
typedef struct BDec {
    // Signed 128-bit coefficient in two's-complement limbs. LLVM's i128 memory
    // order follows the target endian, so the C fields must do the same: the
    // numerical low limb is first on little-endian machines and second on
    // big-endian ones. The spare word keeps the language's established 32-byte
    // decimal layout while no C source type wider than 64 bits is required.
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    unsigned long long hi;
    unsigned long long lo;
#else
    unsigned long long lo;
    unsigned long long hi;
#endif
    long long s;
    unsigned long long pad;
} BDec;
#define BDEC_PRECISION 38
#define BDEC_MAX_SCALE 65535
#define BDEC_WIDE_LIMBS 8
typedef struct BDecWide {
    unsigned long long limb[BDEC_WIDE_LIMBS];
} BDecWide;

typedef struct BU128 {
    unsigned long long lo;
    unsigned long long hi;
} BU128;

static int bu_zero(BU128 value) { return value.lo == 0 && value.hi == 0; }
static int bu_cmp(BU128 a, BU128 b) {
    if (a.hi != b.hi) return a.hi < b.hi ? -1 : 1;
    if (a.lo != b.lo) return a.lo < b.lo ? -1 : 1;
    return 0;
}
static BU128 bu_sub(BU128 a, BU128 b) {
    BU128 out;
    out.lo = a.lo - b.lo;
    out.hi = a.hi - b.hi - (a.lo < b.lo);
    return out;
}
static BU128 bu_twos(BU128 value) {
    BU128 out = {~value.lo + 1, ~value.hi};
    if (out.lo == 0) out.hi++;
    return out;
}
static BU128 bu_mul64(unsigned long long a, unsigned long long b) {
    const unsigned long long mask = 0xffffffffULL;
    unsigned long long a0 = a & mask, a1 = a >> 32;
    unsigned long long b0 = b & mask, b1 = b >> 32;
    unsigned long long p00 = a0 * b0;
    unsigned long long p01 = a0 * b1;
    unsigned long long p10 = a1 * b0;
    unsigned long long p11 = a1 * b1;
    unsigned long long middle =
        (p00 >> 32) + (p01 & mask) + (p10 & mask);
    BU128 out = {
        (p00 & mask) | (middle << 32),
        p11 + (p01 >> 32) + (p10 >> 32) + (middle >> 32)};
    return out;
}
static int bu_mul_small(BU128 value, unsigned factor, BU128* out) {
    BU128 low = bu_mul64(value.lo, factor);
    BU128 high = bu_mul64(value.hi, factor);
    out->lo = low.lo;
    out->hi = high.lo + low.hi;
    return high.hi == 0 && out->hi >= high.lo;
}
static int bu_add_small(BU128 value, unsigned addend, BU128* out) {
    out->lo = value.lo + addend;
    unsigned long long carry = out->lo < value.lo;
    out->hi = value.hi + carry;
    return !carry || out->hi != 0;
}
static int bu_div_small(BU128 value, unsigned divisor, BU128* quotient,
                        unsigned* remainder) {
    if (!divisor) return 0;
    unsigned words[4] = {
        (unsigned)(value.hi >> 32), (unsigned)value.hi,
        (unsigned)(value.lo >> 32), (unsigned)value.lo};
    unsigned result[4] = {0};
    unsigned long long rem = 0;
    for (int i = 0; i < 4; i++) {
        unsigned long long current = (rem << 32) | words[i];
        result[i] = (unsigned)(current / divisor);
        rem = current % divisor;
    }
    quotient->hi = ((unsigned long long)result[0] << 32) | result[1];
    quotient->lo = ((unsigned long long)result[2] << 32) | result[3];
    *remainder = (unsigned)rem;
    return 1;
}
static int bu_bit(BU128 value, unsigned bit) {
    return bit < 64 ? (int)((value.lo >> bit) & 1)
                    : (int)((value.hi >> (bit - 64)) & 1);
}
static void bu_set_bit(BU128* value, unsigned bit) {
    if (bit < 64) value->lo |= 1ULL << bit;
    else value->hi |= 1ULL << (bit - 64);
}
static int bu_shift_left_one(BU128* value) {
    int overflow = (int)(value->hi >> 63);
    value->hi = (value->hi << 1) | (value->lo >> 63);
    value->lo <<= 1;
    return !overflow;
}
static int bu_divmod(BU128 value, BU128 divisor, BU128* quotient,
                     BU128* remainder) {
    if (bu_zero(divisor)) return 0;
    *quotient = (BU128){0, 0};
    *remainder = (BU128){0, 0};
    if (bu_cmp(value, divisor) < 0) {
        *remainder = value;
        return 1;
    }
    if (divisor.hi >> 63) {
        quotient->lo = 1;
        *remainder = bu_sub(value, divisor);
        return 1;
    }
    for (unsigned bit = 128; bit-- > 0;) {
        if (!bu_shift_left_one(remainder)) return 0;
        if (bu_bit(value, bit)) remainder->lo |= 1;
        if (bu_cmp(*remainder, divisor) >= 0) {
            *remainder = bu_sub(*remainder, divisor);
            bu_set_bit(quotient, bit);
        }
    }
    return 1;
}
static int dec_negative(const BDec* value) { return (int)(value->hi >> 63); }
static int dec_zero(const BDec* value) { return value->lo == 0 && value->hi == 0; }
static BU128 dec_mag(const BDec* value) {
    BU128 bits = {value->lo, value->hi};
    return dec_negative(value) ? bu_twos(bits) : bits;
}
static void dec_set(BDec* out, BU128 magnitude, int negative, long long scale) {
    BU128 bits = negative && !bu_zero(magnitude) ? bu_twos(magnitude) : magnitude;
    out->lo = bits.lo;
    out->hi = bits.hi;
    out->s = scale;
    out->pad = 0;
}
static BU128 dec_coeff_limit(void) {
    BU128 value = {1, 0};
    for (int i = 0; i < BDEC_PRECISION; i++) {
        BU128 next;
        if (!bu_mul_small(value, 10, &next)) return (BU128){0, 0};
        value = next;
    }
    return bu_sub(value, (BU128){1, 0});
}
static int dec_digits128(BU128 value) {
    int digits = 1;
    while (value.hi || value.lo >= 10) {
        BU128 quotient;
        unsigned remainder;
        bu_div_small(value, 10, &quotient, &remainder);
        value = quotient;
        digits++;
    }
    return digits;
}
static BDecWide decw_from128(BU128 value) {
    BDecWide out = {{0}};
    out.limb[0] = value.lo;
    out.limb[1] = value.hi;
    return out;
}
static int decw_zero(const BDecWide* value) {
    for (int i = 0; i < BDEC_WIDE_LIMBS; i++)
        if (value->limb[i]) return 0;
    return 1;
}
static int decw_cmp(const BDecWide* a, const BDecWide* b) {
    for (int i = BDEC_WIDE_LIMBS - 1; i >= 0; i--) {
        if (a->limb[i] != b->limb[i])
            return a->limb[i] < b->limb[i] ? -1 : 1;
    }
    return 0;
}
static void dec_overflow(long long line, long long col) {
    beans_panic("decimal overflow", line, col);
}
static void decw_add(BDecWide* value, const BDecWide* other,
                     long long line, long long col) {
    unsigned long long carry = 0;
    for (int i = 0; i < BDEC_WIDE_LIMBS; i++) {
        unsigned long long first = value->limb[i] + other->limb[i];
        int carry_first = first < value->limb[i];
        unsigned long long second = first + carry;
        int carry_second = second < first;
        value->limb[i] = second;
        carry = carry_first || carry_second;
    }
    if (carry) dec_overflow(line, col);
}
// Requires value >= other.
static void decw_sub(BDecWide* value, const BDecWide* other) {
    unsigned long long borrow = 0;
    for (int i = 0; i < BDEC_WIDE_LIMBS; i++) {
        unsigned long long before = value->limb[i];
        unsigned long long rhs = other->limb[i] + borrow;
        unsigned long long wrapped = rhs < other->limb[i];
        value->limb[i] = before - rhs;
        borrow = wrapped || before < rhs;
    }
}
static void decw_increment(BDecWide* value, long long line, long long col) {
    for (int i = 0; i < BDEC_WIDE_LIMBS; i++) {
        value->limb[i]++;
        if (value->limb[i]) return;
    }
    dec_overflow(line, col);
}
static void decw_mul10(BDecWide* value, long long line, long long col) {
    unsigned long long carry = 0;
    for (int i = 0; i < BDEC_WIDE_LIMBS; i++) {
        BU128 product = bu_mul64(value->limb[i], 10);
        unsigned long long low = product.lo + carry;
        product.hi += low < product.lo;
        value->limb[i] = low;
        carry = product.hi;
    }
    if (carry) dec_overflow(line, col);
}
static void decw_mul_pow10(BDecWide* value, long long power,
                           long long line, long long col) {
    if (power < 0 || power > 150) dec_overflow(line, col);
    for (long long i = 0; i < power; i++) decw_mul10(value, line, col);
}
static unsigned decw_div10(BDecWide* value) {
    unsigned long long remainder = 0;
    for (int i = BDEC_WIDE_LIMBS - 1; i >= 0; i--) {
        unsigned long long high =
            (remainder << 32) | (value->limb[i] >> 32);
        unsigned quotient_high = (unsigned)(high / 10);
        remainder = high % 10;
        unsigned long long low =
            (remainder << 32) | (unsigned)value->limb[i];
        unsigned quotient_low = (unsigned)(low / 10);
        remainder = low % 10;
        value->limb[i] =
            ((unsigned long long)quotient_high << 32) | quotient_low;
    }
    return (unsigned)remainder;
}
static unsigned decw_mod10(const BDecWide* value) {
    BDecWide copy = *value;
    return decw_div10(&copy);
}
static int decw_digits(const BDecWide* value) {
    if (decw_zero(value)) return 1;
    BDecWide copy = *value;
    int digits = 0;
    while (!decw_zero(&copy)) {
        decw_div10(&copy);
        digits++;
    }
    return digits;
}
static BU128 decw_to128(const BDecWide* value,
                        long long line, long long col) {
    for (int i = 2; i < BDEC_WIDE_LIMBS; i++)
        if (value->limb[i]) dec_overflow(line, col);
    return (BU128){value->limb[0], value->limb[1]};
}
static void decw_add_at(BDecWide* out, int at, unsigned long long word,
                        long long line, long long col) {
    while (word) {
        if (at == BDEC_WIDE_LIMBS) dec_overflow(line, col);
        unsigned long long before = out->limb[at];
        out->limb[at] += word;
        word = out->limb[at] < before;
        at++;
    }
}
static BDecWide decw_multiply(BU128 left, BU128 right,
                              long long line, long long col) {
    unsigned long long a[2] = {left.lo, left.hi};
    unsigned long long b[2] = {right.lo, right.hi};
    BDecWide out = {{0}};
    for (int i = 0; i < 2; i++) {
        for (int j = 0; j < 2; j++) {
            int at = i + j;
            BU128 product = bu_mul64(a[i], b[j]);
            decw_add_at(&out, at, product.lo, line, col);
            decw_add_at(&out, at + 1, product.hi, line, col);
        }
    }
    return out;
}
#define BROUND_HALF_EVEN 0
#define BROUND_HALF_AWAY 1
#define BROUND_TOWARD_ZERO 2
#define BROUND_FLOOR 3
#define BROUND_CEIL 4
static int dec_should_increment(unsigned guard, int sticky,
                                const BDecWide* kept, int negative,
                                long long mode) {
    switch (mode) {
        case BROUND_HALF_EVEN:
            return guard > 5 ||
                   (guard == 5 && (sticky || decw_mod10(kept) % 2 != 0));
        case BROUND_HALF_AWAY:
            return guard >= 5;
        case BROUND_TOWARD_ZERO:
            return 0;
        case BROUND_FLOOR:
            return negative && (guard != 0 || sticky);
        case BROUND_CEIL:
            return !negative && (guard != 0 || sticky);
        default:
            beans_panic("unknown decimal rounding mode", 0, 0);
    }
    return 0;
}
static void dec_finish(BDec* out, BDecWide value, int negative, long long scale,
                       long long mode, long long line, long long col) {
    if (decw_zero(&value)) {
        if (scale < 0) scale = 0;
        if (scale > BDEC_MAX_SCALE) dec_overflow(line, col);
        dec_set(out, (BU128){0, 0}, 0, scale);
        return;
    }
    if (scale < 0) {
        long long expand = -scale;
        if (expand > BDEC_PRECISION ||
            decw_digits(&value) + expand > BDEC_PRECISION)
            dec_overflow(line, col);
        decw_mul_pow10(&value, expand, line, col);
        scale = 0;
    }
    while (scale > BDEC_MAX_SCALE && decw_mod10(&value) == 0) {
        decw_div10(&value);
        scale--;
    }
    if (scale > BDEC_MAX_SCALE) dec_overflow(line, col);
    int digits = decw_digits(&value);
    if (digits > BDEC_PRECISION) {
        int drop = digits - BDEC_PRECISION;
        if (drop > scale) dec_overflow(line, col);
        int sticky = 0;
        unsigned guard = 0;
        for (int i = 0; i < drop; i++) {
            unsigned removed = decw_div10(&value);
            if (i + 1 == drop) guard = removed;
            else if (removed) sticky = 1;
        }
        scale -= drop;
        if (dec_should_increment(guard, sticky, &value, negative, mode))
            decw_increment(&value, line, col);
        if (decw_digits(&value) > BDEC_PRECISION) {
            if (scale == 0 || decw_mod10(&value) != 0)
                dec_overflow(line, col);
            decw_div10(&value);
            scale--;
        }
    }
    BU128 coefficient = decw_to128(&value, line, col);
    if (bu_cmp(coefficient, dec_coeff_limit()) > 0) dec_overflow(line, col);
    dec_set(out, coefficient, negative, scale);
}
static BDec* dec_box(const BDec* value) {
    BDec* out = beans_alloc(sizeof(BDec), 0);
    *out = *value;
    return out;
}
BDec* beans_dec_new(unsigned long long lo, unsigned long long hi, long long s) {
    BDec value;
    value.lo = lo;
    value.hi = hi;
    value.s = s;
    value.pad = 0;
    dec_finish(&value, decw_from128(dec_mag(&value)), dec_negative(&value), s,
               BROUND_HALF_EVEN, 0, 0);
    return dec_box(&value);
}
BDec* beans_dec_from_int(long long value) {
    BDec decimal;
    unsigned long long bits = (unsigned long long)value;
    BU128 magnitude = {value < 0 ? 0ULL - bits : bits, 0};
    dec_set(&decimal, magnitude, value < 0, 0);
    return dec_box(&decimal);
}
BDec* beans_decv_box(const BDec* value) { return dec_box(value); }
void beans_decv_from_int(BDec* out, long long value) {
    unsigned long long bits = (unsigned long long)value;
    BU128 magnitude = {value < 0 ? 0ULL - bits : bits, 0};
    dec_set(out, magnitude, value < 0, 0);
}
void beans_decv_add(BDec* out, const BDec* a, const BDec* b,
                    long long line, long long col) {
    if (dec_zero(a)) { *out = *b; return; }
    if (dec_zero(b)) { *out = *a; return; }
    BU128 am = dec_mag(a), bm = dec_mag(b);
    int ae = dec_digits128(am) - 1 - (int)a->s;
    int be = dec_digits128(bm) - 1 - (int)b->s;
    if (ae - be > BDEC_PRECISION) { *out = *a; return; }
    if (be - ae > BDEC_PRECISION) { *out = *b; return; }
    long long scale = a->s > b->s ? a->s : b->s;
    BDecWide aw = decw_from128(am), bw = decw_from128(bm);
    decw_mul_pow10(&aw, scale - a->s, line, col);
    decw_mul_pow10(&bw, scale - b->s, line, col);
    int an = dec_negative(a), bn = dec_negative(b);
    if (an == bn) {
        decw_add(&aw, &bw, line, col);
        dec_finish(out, aw, an, scale, BROUND_HALF_EVEN, line, col);
        return;
    }
    int order = decw_cmp(&aw, &bw);
    if (order == 0) {
        dec_set(out, (BU128){0, 0}, 0, scale);
    } else if (order > 0) {
        decw_sub(&aw, &bw);
        dec_finish(out, aw, an, scale, BROUND_HALF_EVEN, line, col);
    } else {
        decw_sub(&bw, &aw);
        dec_finish(out, bw, bn, scale, BROUND_HALF_EVEN, line, col);
    }
}
void beans_decv_neg(BDec* out, const BDec* value,
                    long long line, long long col) {
    (void)line; (void)col;
    dec_set(out, dec_mag(value), !dec_negative(value), value->s);
}
void beans_decv_sub(BDec* out, const BDec* a, const BDec* b,
                    long long line, long long col) {
    BDec negative;
    beans_decv_neg(&negative, b, line, col);
    beans_decv_add(out, a, &negative, line, col);
}
void beans_decv_mul(BDec* out, const BDec* a, const BDec* b,
                    long long line, long long col) {
    BDecWide product =
        decw_multiply(dec_mag(a), dec_mag(b), line, col);
    dec_finish(out, product, dec_negative(a) != dec_negative(b), a->s + b->s,
               BROUND_HALF_EVEN, line, col);
}
void beans_decv_div(BDec* out, const BDec* a, const BDec* b,
                    long long line, long long col) {
    if (dec_zero(b)) beans_panic("divide by zero", line, col);
    if (dec_zero(a)) { dec_set(out, (BU128){0, 0}, 0, a->s); return; }
    BU128 numerator = dec_mag(a);
    BU128 denominator = dec_mag(b);
    BU128 integer, remainder;
    bu_divmod(numerator, denominator, &integer, &remainder);
    char significant[BDEC_PRECISION + 1];
    int count = 0, ratio_exp = 0;
    if (!bu_zero(integer)) {
        char reversed[40];
        int n = 0;
        while (!bu_zero(integer)) {
            BU128 quotient;
            unsigned digit;
            bu_div_small(integer, 10, &quotient, &digit);
            reversed[n++] = (char)('0' + digit);
            integer = quotient;
        }
        ratio_exp = n - 1;
        while (n) significant[count++] = reversed[--n];
    } else {
        ratio_exp = -1;
    }
    BDecWide divisor = decw_from128(denominator);
    while (count < BDEC_PRECISION + 1 && !bu_zero(remainder)) {
        BDecWide next = decw_from128(remainder);
        decw_mul10(&next, line, col);
        unsigned digit = 0;
        while (decw_cmp(&next, &divisor) >= 0) {
            decw_sub(&next, &divisor);
            digit++;
        }
        remainder = decw_to128(&next, line, col);
        if (count == 0 && digit == 0) {
            ratio_exp--;
            continue;
        }
        significant[count++] = (char)('0' + digit);
    }
    if (count == 0) { dec_set(out, (BU128){0, 0}, 0, 0); return; }
    int kept_count = count < BDEC_PRECISION ? count : BDEC_PRECISION;
    BDecWide kept = {{0}};
    for (int i = 0; i < kept_count; i++) {
        decw_mul10(&kept, line, col);
        BDecWide digit = decw_from128(
            (BU128){(unsigned)(significant[i] - '0'), 0});
        decw_add(&kept, &digit, line, col);
    }
    int negative = dec_negative(a) != dec_negative(b);
    if (count > BDEC_PRECISION) {
        unsigned guard = (unsigned)(significant[BDEC_PRECISION] - '0');
        if (dec_should_increment(guard, !bu_zero(remainder), &kept, negative,
                                 BROUND_HALF_EVEN))
            decw_increment(&kept, line, col);
    }
    long long result_exp = (long long)ratio_exp + b->s - a->s;
    long long result_scale = (long long)kept_count - 1 - result_exp;
    dec_finish(out, kept, negative, result_scale, BROUND_HALF_EVEN, line, col);
}
void beans_decv_abs(BDec* out, const BDec* value,
                    long long line, long long col) {
    (void)line; (void)col;
    dec_set(out, dec_mag(value), 0, value->s);
}
void beans_decv_round(BDec* out, const BDec* value, long long places,
                      long long mode, long long line, long long col) {
    if (places >= value->s) { *out = *value; return; }
    if (places < -BDEC_PRECISION) {
        int away = (mode == BROUND_FLOOR && dec_negative(value)) ||
                   (mode == BROUND_CEIL &&
                    !dec_negative(value) && !dec_zero(value));
        if (away) dec_overflow(line, col);
        dec_set(out, (BU128){0, 0}, 0, 0);
        return;
    }
    BDecWide wide = decw_from128(dec_mag(value));
    long long drop = value->s - places;
    int digits = decw_digits(&wide);
    int negative = dec_negative(value);
    if (drop > digits) {
        int away = (mode == BROUND_FLOOR && negative) ||
                   (mode == BROUND_CEIL && !negative);
        if (!away) {
            dec_set(out, (BU128){0, 0}, 0, places < 0 ? 0 : places);
            return;
        }
        wide = decw_from128((BU128){1, 0});
    } else {
        int sticky = 0;
        unsigned guard = 0;
        for (long long i = 0; i < drop; i++) {
            unsigned removed = decw_div10(&wide);
            if (i + 1 == drop) guard = removed;
            else if (removed) sticky = 1;
        }
        if (dec_should_increment(guard, sticky, &wide, negative, mode))
            decw_increment(&wide, line, col);
    }
    if (places < 0) {
        decw_mul_pow10(&wide, -places, line, col);
        dec_finish(out, wide, negative, 0, mode, line, col);
    } else {
        dec_finish(out, wide, negative, places, mode, line, col);
    }
}
int beans_dec_cmp(BDec* a, BDec* b) {
    if (dec_negative(a) && !dec_negative(b)) return -1;
    if (!dec_negative(a) && dec_negative(b)) return 1;
    if (dec_zero(a)) return dec_zero(b) ? 0 : -1;
    if (dec_zero(b)) return 1;
    int negative = dec_negative(a);
    BU128 am = dec_mag(a), bm = dec_mag(b);
    int ae = dec_digits128(am) - 1 - (int)a->s;
    int be = dec_digits128(bm) - 1 - (int)b->s;
    int order;
    if (ae != be) {
        order = ae < be ? -1 : 1;
    } else {
        long long scale = a->s > b->s ? a->s : b->s;
        BDecWide aw = decw_from128(am), bw = decw_from128(bm);
        decw_mul_pow10(&aw, scale - a->s, 0, 0);
        decw_mul_pow10(&bw, scale - b->s, 0, 0);
        order = decw_cmp(&aw, &bw);
    }
    return negative ? -order : order;
}
// dec_cmp aligns scales, so 2.50 == 2.5 — hash the canonical trailing-zero-free
// form so equal decimals land in the same map index slot
long long beans_dec_hash(BDec* d) {
    BU128 magnitude = dec_mag(d);
    long long s = d->s;
    while (s > 0) {
        BU128 quotient;
        unsigned remainder;
        bu_div_small(magnitude, 10, &quotient, &remainder);
        if (remainder != 0) break;
        magnitude = quotient;
        s -= 1;
    }
    BU128 bits = dec_negative(d) ? bu_twos(magnitude) : magnitude;
    return (long long)beans_mix64(
        bits.lo ^ beans_mix64(bits.hi ^ (unsigned long long)s));
}
BDec* beans_dec_add(BDec* a, BDec* b) {
    BDec value;
    beans_decv_add(&value, a, b, 0, 0);
    return dec_box(&value);
}
BDec* beans_dec_sub(BDec* a, BDec* b) {
    BDec value;
    beans_decv_sub(&value, a, b, 0, 0);
    return dec_box(&value);
}
BDec* beans_dec_mul(BDec* a, BDec* b) {
    BDec value;
    beans_decv_mul(&value, a, b, 0, 0);
    return dec_box(&value);
}
BDec* beans_dec_div(BDec* a, BDec* b, long long line, long long col) {
    BDec value;
    beans_decv_div(&value, a, b, line, col);
    return dec_box(&value);
}
BDec* beans_dec_neg(BDec* value) {
    BDec result;
    beans_decv_neg(&result, value, 0, 0);
    return dec_box(&result);
}
BDec* beans_dec_abs(BDec* value) {
    BDec result;
    beans_decv_abs(&result, value, 0, 0);
    return dec_box(&result);
}
BDec* beans_dec_round(BDec* value, long long places, long long mode) {
    BDec result;
    beans_decv_round(&result, value, places, mode, 0, 0);
    return dec_box(&result);
}
// same acceptance rule as the interpreter's dec_valid: [+-]? digits with '_',
// one optional '.', one optional e/E exponent with its own sign and a digit
static int dec_valid_c(const char* s) {
    size_t i = 0;
    if (s[i] == '+' || s[i] == '-') i++;
    int digits = 0, dot = 0;
    for (; s[i]; i++) {
        char c = s[i];
        if (c >= '0' && c <= '9') { digits++; continue; }
        if (c == '_') continue;
        if (c == '.' && !dot) { dot = 1; continue; }
        if ((c == 'e' || c == 'E') && digits) {
            i++;
            if (s[i] == '+' || s[i] == '-') i++;
            if (!(s[i] >= '0' && s[i] <= '9')) return 0;
            // capped at 4096 exactly like the interpreter's dec_valid
            long long ev = 0;
            while (s[i] >= '0' && s[i] <= '9') {
                ev = ev * 10 + (s[i] - '0');
                if (ev > 4096) return 0;
                i++;
            }
            return s[i] == '\0';
        }
        return 0;
    }
    return digits > 0;
}
// Mirror of Decimal::parse. Literal/string digits are exact: a 39th
// significant digit is an error, not an implicit rounding point.
static int dec_parse_text(BDec* out, const char* s) {
    if (!dec_valid_c(s)) return 0;
    BU128 coeff = {0, 0};
    long long fractional = 0, exponent = 0;
    int neg = 0, after_dot = 0, seen_nonzero = 0;
    int significant = 0;
    size_t i = 0;
    if (s[i] == '-' || s[i] == '+') {
        neg = s[i] == '-';
        i++;
    }
    for (; s[i]; i++) {
        char c = s[i];
        if (c == '_') continue;
        if (c == '.') { after_dot = 1; continue; }
        if (c == 'e' || c == 'E') {
            if (!rt_parse_i64(s + i + 1, &exponent, NULL)) return 0;
            break;
        }
        if (after_dot) fractional++;
        if (!seen_nonzero && c == '0') continue;
        seen_nonzero = 1;
        significant++;
        if (significant > BDEC_PRECISION) return 0;
        BU128 multiplied;
        if (!bu_mul_small(coeff, 10, &multiplied) ||
            !bu_add_small(multiplied, (unsigned)(c - '0'), &coeff))
            return 0;
    }
    long long scale = fractional - exponent;
    if (!seen_nonzero) {
        if (scale < 0) scale = 0;
        if (scale > BDEC_MAX_SCALE) return 0;
        dec_set(out, (BU128){0, 0}, 0, scale);
        return 1;
    }
    if (scale < 0) {
        long long append = -scale;
        if (append > BDEC_PRECISION ||
            significant + append > BDEC_PRECISION)
            return 0;
        for (long long n = 0; n < append; n++) {
            BU128 multiplied;
            if (!bu_mul_small(coeff, 10, &multiplied)) return 0;
            coeff = multiplied;
        }
        scale = 0;
    }
    if (scale > BDEC_MAX_SCALE || bu_cmp(coeff, dec_coeff_limit()) > 0)
        return 0;
    dec_set(out, coeff, neg, scale);
    return 1;
}
BRes beans_str_to_decimal(char* s) {
    BDec value;
    if (!dec_parse_text(&value, s)) return parse_fail(s, "decimal");
    return (BRes){(long long)dec_box(&value), NULL};
}
long long beans_str_to_decimal_out(char* s, void** e_out) { BRes r = beans_str_to_decimal(s); *e_out = r.err; return r.val; }
long long beans_dec_to_int(BDec* value) {
    BU128 magnitude = dec_mag(value);
    for (long long i = 0; i < value->s && !bu_zero(magnitude); i++) {
        BU128 quotient;
        unsigned remainder;
        bu_div_small(magnitude, 10, &quotient, &remainder);
        magnitude = quotient;
    }
    unsigned long long bits = magnitude.lo;
    if (dec_negative(value)) bits = 0ULL - bits;
    return (long long)bits;
}
long long beans_decv_to_int(BDec* value) {
    return beans_dec_to_int(value);
}
double beans_dec_to_f64(BDec* value) {
    BU128 magnitude = dec_mag(value);
    double out = (double)magnitude.hi * 18446744073709551616.0 +
                 (double)magnitude.lo;
    if (dec_negative(value)) out = -out;
    long long scale = value->s;
    while (scale >= 18) {
        out /= 1000000000000000000.0;
        scale -= 18;
    }
    while (scale-- > 0) out /= 10.0;
    return out;
}
double beans_decv_to_f64(BDec* value) {
    return beans_dec_to_f64(value);
}
void beans_decv_from_f64(BDec* out, double value,
                         long long line, long long col) {
    char buf[64];
    beans_host_format_f64(buf, sizeof buf, value, 17, 'g');
    if (!dec_parse_text(out, buf)) dec_overflow(line, col);
}
BDec* beans_dec_from_f64(double value) {
    BDec out;
    beans_decv_from_f64(&out, value, 0, 0);
    return dec_box(&out);
}
char* beans_dec_str(BDec* a) {
    BU128 magnitude = dec_mag(a);
    int neg = dec_negative(a);
    // Scratch is sized from the scale: the coefficient holds at most 38
    // digits, but
    // the zero-fill below runs to scale+1 — "1e-100".to_decimal() legitimately
    // carries scale 100, and the old fixed 64/80-byte stack buffers smashed
    // the stack. Small values keep the stack fast path.
    long long cap = (a->s > 38 ? a->s : 38) + 2;
    char dsmall[64], osmall[80];
    char* digits = cap <= 63 ? dsmall : rt_alloc((size_t)cap + 1);
    char* out = cap + 2 <= 79 ? osmall : rt_alloc((size_t)cap + 3);
    if (!digits || !out) beans_panic("decimal too large to print", 0, 0);
    long long n = 0;
    if (bu_zero(magnitude)) digits[n++] = '0';
    while (!bu_zero(magnitude)) {
        BU128 quotient;
        unsigned remainder;
        bu_div_small(magnitude, 10, &quotient, &remainder);
        digits[n++] = (char)('0' + (int)remainder);
        magnitude = quotient;
    }
    while (n <= a->s) digits[n++] = '0';
    long long o = 0;
    if (neg) out[o++] = '-';
    for (long long i = n - 1; i >= 0; i--) {
        out[o++] = digits[i];
        if (i == a->s && i != 0) out[o++] = '.';
    }
    out[o] = '\0';
    char* r = rc_strdup(out);
    if (digits != dsmall) rt_free(digits);
    if (out != osmall) rt_free(out);
    return r;
}
char* beans_decv_str(BDec* value) {
    return beans_dec_str(value);
}

// Decimal List values stay as their native wide representation. The old
// generic slot ABI boxed each element solely to fit a pointer in i64.
void beans_list_decv_max(BList* list, BDec* out, long long* ok) {
    *ok = list->len > 0;
    dec_set(out, (BU128){0, 0}, 0, 0);
    if (!*ok) return;
    BDec* values = (BDec*)list->data;
    *out = values[0];
    for (long long i = 1; i < list->len; i++)
        if (beans_dec_cmp(&values[i], out) > 0) *out = values[i];
}
void beans_list_decv_min(BList* list, BDec* out, long long* ok) {
    *ok = list->len > 0;
    dec_set(out, (BU128){0, 0}, 0, 0);
    if (!*ok) return;
    BDec* values = (BDec*)list->data;
    *out = values[0];
    for (long long i = 1; i < list->len; i++)
        if (beans_dec_cmp(&values[i], out) < 0) *out = values[i];
}
long long beans_list_decv_contains(BList* list, BDec* value) {
    BDec* values = (BDec*)list->data;
    for (long long i = 0; i < list->len; i++)
        if (beans_dec_cmp(&values[i], value) == 0) return 1;
    return 0;
}
long long beans_list_decv_index(BList* list, BDec* value, long long* ok) {
    BDec* values = (BDec*)list->data;
    for (long long i = 0; i < list->len; i++) {
        if (beans_dec_cmp(&values[i], value) == 0) {
            *ok = 1;
            return i;
        }
    }
    *ok = 0;
    return 0;
}
static long long decv_less(BDec* a, BDec* b, void* thunk, void* box) {
    if (thunk)
        return ((long long (*)(void*, BDec*, BDec*))thunk)(box, a, b);
    return beans_dec_cmp(a, b) < 0;
}
static void list_decv_merge_sort(BList* list, void* thunk, void* box) {
    long long n = list->len;
    if (n < 2) return;
    BDec* values = (BDec*)list->data;
    BDec* buffer = rt_alloc((size_t)n * sizeof(BDec));
    if (!buffer) beans_panic("out of memory", 0, 0);
    for (long long width = 1; width < n; width *= 2) {
        for (long long lo = 0; lo < n; lo += 2 * width) {
            long long mid = lo + width < n ? lo + width : n;
            long long hi = lo + 2 * width < n ? lo + 2 * width : n;
            long long left = lo, right = mid, out = lo;
            while (left < mid && right < hi) {
                if (!decv_less(&values[right], &values[left], thunk, box))
                    buffer[out++] = values[left++];
                else
                    buffer[out++] = values[right++];
            }
            while (left < mid) buffer[out++] = values[left++];
            while (right < hi) buffer[out++] = values[right++];
            memcpy(values + lo, buffer + lo, (size_t)(hi - lo) * sizeof(BDec));
        }
    }
    rt_free(buffer);
}
void beans_list_decv_sort(BList* list) { list_decv_merge_sort(list, NULL, NULL); }
void beans_list_decv_sort_by(BList* list, void* thunk, void* box) {
    list_decv_merge_sort(list, thunk, box);
}
void beans_list_decv_sort_by_key(BList* list, void* thunk, void* box) {
    long long n = list->len;
    if (n < 2) return;
    BDec* values = (BDec*)list->data;
    long long (*key_fn)(void*, BDec*) = (long long (*)(void*, BDec*))thunk;
    long long* keys = rt_alloc((size_t)n * sizeof(long long));
    long long* key_buffer = rt_alloc((size_t)n * sizeof(long long));
    BDec* value_buffer = rt_alloc((size_t)n * sizeof(BDec));
    if (!keys || !key_buffer || !value_buffer) beans_panic("out of memory", 0, 0);
    for (long long i = 0; i < n; i++) keys[i] = key_fn(box, &values[i]);
    for (long long width = 1; width < n; width *= 2) {
        for (long long lo = 0; lo < n; lo += 2 * width) {
            long long mid = lo + width < n ? lo + width : n;
            long long hi = lo + 2 * width < n ? lo + 2 * width : n;
            long long left = lo, right = mid, out = lo;
            while (left < mid && right < hi) {
                long long take = keys[right] < keys[left] ? right++ : left++;
                key_buffer[out] = keys[take];
                value_buffer[out++] = values[take];
            }
            while (left < mid) {
                key_buffer[out] = keys[left];
                value_buffer[out++] = values[left++];
            }
            while (right < hi) {
                key_buffer[out] = keys[right];
                value_buffer[out++] = values[right++];
            }
            memcpy(keys + lo, key_buffer + lo,
                   (size_t)(hi - lo) * sizeof(long long));
            memcpy(values + lo, value_buffer + lo,
                   (size_t)(hi - lo) * sizeof(BDec));
        }
    }
    rt_free(keys);
    rt_free(key_buffer);
    rt_free(value_buffer);
}
char* beans_list_decv_join(BList* list, char* separator) {
    long long separator_len = beans_slen(separator);
    char** parts = rt_alloc((size_t)(list->len ? list->len : 1) * sizeof(char*));
    if (!parts) beans_panic("out of memory", 0, 0);
    BDec* values = (BDec*)list->data;
    long long total = 0;
    for (long long i = 0; i < list->len; i++) {
        parts[i] = beans_dec_str(&values[i]);
        total += beans_slen(parts[i]);
        if (i) total += separator_len;
    }
    char* result = beans_alloc(total + 1, total << 3);
    char* write = result;
    for (long long i = 0; i < list->len; i++) {
        if (i) {
            memcpy(write, separator, (size_t)separator_len);
            write += separator_len;
        }
        long long length = beans_slen(parts[i]);
        memcpy(write, parts[i], (size_t)length);
        write += length;
        beans_release(parts[i]);
    }
    *write = 0;
    rt_free(parts);
    return result;
}
char* beans_show_list_decv(BList* list) {
    char* separator = rc_strdup(", ");
    char* middle = beans_list_decv_join(list, separator);
    beans_release(separator);
    long long length = beans_slen(middle);
    char* result = beans_alloc(length + 3, (length + 2) << 3);
    result[0] = '[';
    memcpy(result + 1, middle, (size_t)length);
    result[length + 1] = ']';
    result[length + 2] = 0;
    beans_release(middle);
    return result;
}
#endif // BEANS_RT_DECIMAL

// ---- std.fmt (mirrors builtins.cpp byte for byte) ----
// same 1e6 width ceiling the interpolation spec enforces at compile time — a
// pad is a fill, not an allocation primitive; past the cap it is a panic on
// both backends, not a 1TB alloc the OOM killer reaps
#define FMT_PAD_MAX 1000000
char* beans_fmt_pad_left(char* s, long long w, long long line, long long col) {
    if (w > FMT_PAD_MAX) beans_panic("pad width too large", line, col);
    long long n = beans_slen(s);
    if (w <= n) return str_make(s, n);
    char* out = beans_alloc(w + 1, w << 3);
    memset(out, ' ', (size_t)(w - n));
    memcpy(out + (w - n), s, (size_t)n);
    return out;
}
char* beans_fmt_pad_right(char* s, long long w, long long line, long long col) {
    if (w > FMT_PAD_MAX) beans_panic("pad width too large", line, col);
    long long n = beans_slen(s);
    if (w <= n) return str_make(s, n);
    char* out = beans_alloc(w + 1, w << 3);
    memcpy(out, s, (size_t)n);
    memset(out + n, ' ', (size_t)(w - n));
    return out;
}
char* beans_fmt_float(double x, long long p) {
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    char buf[512];
    beans_host_format_f64(buf, sizeof buf, x, (int)p, 'f');
    return rc_strdup(buf);
}
#if BEANS_RT_DECIMAL
char* beans_fmt_dec(BDec* d, long long p) {
    if (p < 0) p = 0;
    if (p > 60) p = 60;
    BDec t = *d;
    if (p < t.s) { // beans_dec_round, on the stack
        beans_decv_round(&t, d, p, BROUND_HALF_EVEN, 0, 0);
    }
    char* base = beans_dec_str(&t);
    long long frac = t.s;
    if (p <= frac) return base;
    long long bn = beans_slen(base);
    long long extra = (frac == 0 ? 1 : 0) + (p - frac);
    char* out = beans_alloc(bn + extra + 1, (bn + extra) << 3);
    memcpy(out, base, (size_t)bn);
    long long o = bn;
    if (frac == 0) out[o++] = '.';
    for (long long i = 0; i < p - frac; i++) out[o++] = '0';
    beans_release(base);
    return out;
}
char* beans_decv_fmt(BDec* value, long long p) {
    return beans_fmt_dec(value, p);
}
#endif // BEANS_RT_DECIMAL
