// glibc hides siginfo_t, sigaction, sigaltstack and the ucontext family
// behind feature macros under a strict -std. The full runtime includes this
// file after its own headers, but the fiber core gate compiles it alone
// with -std=c11 — so ask for the whole surface here, before any header.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

// The fiber runtime core — see beans_fiber.h and spec/CONCURRENCY.md.
//
// A fiber is a fixed, never-moving stack reservation plus a saved register
// frame. Parking swaps callee-saved registers and the stack pointer with the
// worker's scheduler context; nothing else is saved because a park is a
// cooperative call site — caller-saved state is already dead across it, the
// same contract an ordinary function call has.
//
// State machine. RUNNING fibers park by entering PARKING and switching to
// the scheduler; only the scheduler — running after the switch, when the
// fiber's stack is quiescent — publishes PARKED. A resume that lands in the
// PARKING window sets the pending-wake latch instead, and the scheduler
// turns that latch into an immediate requeue. That order is what makes a
// resume/park race unable to lose a wake or run a fiber on two stacks.
//
// Cross-thread resumes go through the worker's inbox (mutex + condvar): the
// waker moves the fiber to READY, appends it to the inbox, and signals. The
// owning worker is the only thread that ever switches to a fiber.

#include "beans_fiber.h"

// Whether this build carries the controlled unwind (see the unwind section
// below). The build driver defines it to 1 for a program that can contain a
// panic on a target whose unwinder we use; every other build keeps F1's
// abandoned frames. Defaulted here so the file compiles standalone —
// test/fiber_core.c builds it with no driver at all.
#ifndef BEANS_FIBER_UNWIND
#define BEANS_FIBER_UNWIND 0
#endif

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

// The netpoller backend: kqueue on the BSD family, epoll (with an eventfd
// kick) on Linux. Elsewhere — Windows, wasm — there is no poller and
// beans_fiber_wait_io answers "no poller"; net waits block the worker
// thread there exactly as they did before fibers.
#if !defined(_WIN32) && !defined(__wasi__)
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || \
    defined(__OpenBSD__) || defined(__DragonFly__)
#define FIBER_NETPOLL_KQUEUE 1
#include <sys/event.h>
#elif defined(__linux__)
#define FIBER_NETPOLL_EPOLL 1
#include <sys/epoll.h>
#include <sys/eventfd.h>
#endif
#endif
#if defined(FIBER_NETPOLL_KQUEUE) || defined(FIBER_NETPOLL_EPOLL)
#define FIBER_NETPOLL 1
#include <errno.h>
#include <fcntl.h>
#endif

// AddressSanitizer needs to be told about every stack switch, or it keeps
// poisoning the fake frames of whichever stack it believes is current. The
// scheduler's thread-stack bounds are captured by the first fiber entry —
// __sanitizer_finish_switch_fiber hands back the bounds of the stack that
// was switched away from.
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define FIBER_ASAN 1
#endif
#endif
#if defined(FIBER_ASAN)
void __sanitizer_start_switch_fiber(void** fake_stack_save, const void* bottom,
                                    size_t size);
void __sanitizer_finish_switch_fiber(void* fake_stack_save,
                                     const void** bottom_old,
                                     size_t* size_old);
#endif

#define BEANS_FIBER_DEFAULT_STACK ((size_t)512 * 1024)
#define BEANS_FIBER_POOL_MAX 64
#define BEANS_FIBER_MSG_MAX 512

// Fiber states. Only the transitions written in park/resume/finish exist.
enum {
    FIBER_RUNNING = 0,
    FIBER_READY = 1,
    FIBER_PARKING = 2, // switching away; PARKED not yet published
    FIBER_PARKED = 3,
    FIBER_DONE = 4,
};

// What the fiber asked the scheduler to do when it switched away.
enum {
    DISPOSE_NONE = 0,
    DISPOSE_PARK = 1,
    DISPOSE_YIELD = 2,
    DISPOSE_FINISH = 3,
};

typedef struct {
    void* sp;
} BeansFiberCtx;

struct BeansFiber {
    BeansFiberCtx ctx;
    BeansWorker* worker;
    void (*fn)(void*);
    void* arg;
    char name[64];

    _Atomic int state;
    _Atomic int pending_wake;
    _Atomic int cancel_flag;
    int disposition;

    // Stack reservation. base is the mmap start (guard page lives there);
    // reserve is the whole mapping including the guard.
    void* stack_base;
    size_t stack_reserve;

    int status; // BEANS_FIBER_OK / _PANICKED / _CANCELLED once DONE
    char message[BEANS_FIBER_MSG_MAX];

    // Controlled unwind (spec/CONCURRENCY.md). unwind_status is the ending
    // the unwind carries — 0 while the fiber is running normally, so it
    // doubles as "this fiber is unwinding" and a panic raised during one is
    // the double-panic case. unwind_exc is storage for the platform's
    // _Unwind_Exception: it must outlive every frame the unwind pops, so it
    // cannot sit on the stack being unwound, and one per fiber is enough
    // because a fiber unwinds at most once.
    int unwind_status;
    _Alignas(16) unsigned char unwind_exc[64];

    BeansFiber* joiner;    // parked fiber waiting on this one, if any
    int forgotten;         // nobody will join; reclaim on finish
    int joined;            // join already delivered (a second join aborts)
    int is_root;           // the promoted thread itself; never finishes

    // Completion hook: fires in settle() when the fiber ends — return,
    // panic, or cancel alike — on the owner worker, before any joiner is
    // woken. TaskGroup uses it to stamp completion order; a panicking
    // fiber never returns through its entry function, so the entry
    // function is not a place a completion can be observed.
    void (*done_hook)(void*);
    void* done_arg;

    BeansFiber* queue_next; // run-queue / inbox / pool link

    // every live fiber of the worker, for the deadlock report
    BeansFiber* all_next;
    BeansFiber* all_prev;

    // io park record (netpoller): armed while this fiber is registered in
    // its worker's kernel poller, signalled when readiness was delivered.
    // Touched only by the owner worker's thread — registration, delivery,
    // and the waiting fiber itself all run there.
    int io_armed;
    int io_signalled;
    long long io_fd;
    int io_write;
    // kqueue: 1-based slot in the worker's queued changelist while this
    // registration has not reached the kernel yet; 0 once submitted.
    int io_queued;

#if defined(FIBER_ASAN)
    void* asan_save;
#endif
};

// One sleeping fiber: resumed when the monotonic clock passes its
// deadline. Entries live in a per-worker binary min-heap, touched only by
// the worker's own thread — no lock.
typedef struct {
    long long deadline;
    BeansFiber* fiber;
} BeansSleeper;

struct BeansWorker {
    BeansFiberCtx sched_ctx;
    BeansFiber* current;

    BeansFiber* ready_head;
    BeansFiber* ready_tail;

    long long live; // running + ready + parked fibers this worker owns

    BeansSleeper* sleepers; // min-heap by deadline
    int sleeper_count;
    int sleeper_cap;

    BeansFiber* all_head; // every live fiber, for the deadlock report

    // The netpoller: one kernel poller per worker, created at the first io
    // park. io_waiters counts armed fibers; while it is nonzero the idle
    // wait blocks in the poller (kicked by inbox_post) instead of the
    // inbox cond, and the deadlock report stays quiet — the kernel can
    // always wake an io waiter.
    int poll_fd;
    int poll_kick_fd; // epoll: eventfd registered in poll_fd; kqueue: unused
    int io_waiters;
    _Atomic int in_poll; // worker is inside (or committing to) the poller wait
#if defined(FIBER_NETPOLL_KQUEUE)
    // Registrations queued since the last poller wait. The next
    // poller_drain kevent call submits the whole batch as its changelist —
    // one syscall carries every re-arm plus the wait, so a park costs no
    // syscall of its own. Owner-thread only, like the rest of the poller.
    struct kevent* poll_queue;
    int poll_queue_len;
    int poll_queue_cap;
#endif

#if !defined(_WIN32)
    pthread_mutex_t inbox_m;
    pthread_cond_t inbox_c;
#else
    CRITICAL_SECTION inbox_m;
    CONDITION_VARIABLE inbox_c;
#endif
    BeansFiber* inbox_head;
    BeansFiber* inbox_tail;

    BeansFiber* pool; // finished fibers kept for stack reuse
    size_t pool_count;
    size_t page;

    // Bootstrapped workers only: the scheduler runs as a fiber on its own
    // carved stack, and the promoted thread is the root fiber.
    BeansFiber* sched_fiber;
    BeansFiber* root_fiber;

#if defined(FIBER_ASAN)
    void* asan_save;
    const void* sched_stack_bottom;
    size_t sched_stack_size;
#endif
};

#if defined(_WIN32)
static __declspec(thread) BeansWorker* tls_worker = NULL;
#else
static _Thread_local BeansWorker* tls_worker = NULL;
#endif


// ---- context switch --------------------------------------------------------
//
// beans_fiber_ctx_switch(from, to): push callee-saved registers on the
// current stack, store sp into from->sp, load to->sp, pop, return — into
// whatever return address `to` saved when it switched away (or into the
// spawn trampoline the first time). AAPCS64 owes x19–x28, fp, lr and
// d8–d15; SysV x86-64 owes rbx, rbp, r12–r15. Windows x64 has a different
// callee-saved contract (xmm6–15, TIB stack bounds), so that build uses the
// OS fiber API below instead of this asm.

#if !defined(_WIN32)
void beans_fiber_ctx_switch(BeansFiberCtx* from, BeansFiberCtx* to);
void beans_fiber_trampoline(void);
static void fiber_entry(BeansFiber* fiber);

#if defined(__aarch64__) && !defined(FIBER_FORCE_UCONTEXT)
__asm__(
    ".text\n"
    ".align 4\n"
    ".globl _beans_fiber_ctx_switch\n"
    ".globl beans_fiber_ctx_switch\n"
    "_beans_fiber_ctx_switch:\n"
    "beans_fiber_ctx_switch:\n"
    "  sub sp, sp, #0xa0\n"
    "  stp x19, x20, [sp, #0x00]\n"
    "  stp x21, x22, [sp, #0x10]\n"
    "  stp x23, x24, [sp, #0x20]\n"
    "  stp x25, x26, [sp, #0x30]\n"
    "  stp x27, x28, [sp, #0x40]\n"
    "  stp x29, x30, [sp, #0x50]\n"
    "  stp d8,  d9,  [sp, #0x60]\n"
    "  stp d10, d11, [sp, #0x70]\n"
    "  stp d12, d13, [sp, #0x80]\n"
    "  stp d14, d15, [sp, #0x90]\n"
    "  mov x9, sp\n"
    "  str x9, [x0]\n"
    "  ldr x9, [x1]\n"
    "  mov sp, x9\n"
    "  ldp x19, x20, [sp, #0x00]\n"
    "  ldp x21, x22, [sp, #0x10]\n"
    "  ldp x23, x24, [sp, #0x20]\n"
    "  ldp x25, x26, [sp, #0x30]\n"
    "  ldp x27, x28, [sp, #0x40]\n"
    "  ldp x29, x30, [sp, #0x50]\n"
    "  ldp d8,  d9,  [sp, #0x60]\n"
    "  ldp d10, d11, [sp, #0x70]\n"
    "  ldp d12, d13, [sp, #0x80]\n"
    "  ldp d14, d15, [sp, #0x90]\n"
    "  add sp, sp, #0xa0\n"
    "  ret\n"
    // First entry into a fiber: the seeded frame restored x19 = the fiber
    // and x30 = this label. Hand the fiber to C with a zeroed frame chain
    // so a debugger's walk ends here instead of in another fiber's frames.
    ".align 4\n"
    ".globl _beans_fiber_trampoline\n"
    ".globl beans_fiber_trampoline\n"
    "_beans_fiber_trampoline:\n"
    "beans_fiber_trampoline:\n"
    "  mov x29, #0\n"
    "  mov x30, #0\n"
    "  mov x0, x19\n"
    "  bl _fiber_entry_shim\n"
    "  brk #0\n");
#define CTX_FRAME_BYTES 0xa0

#elif defined(__x86_64__) && !defined(FIBER_FORCE_UCONTEXT)
__asm__(
    ".text\n"
    ".align 16\n"
    ".globl _beans_fiber_ctx_switch\n"
    ".globl beans_fiber_ctx_switch\n"
    "_beans_fiber_ctx_switch:\n"
    "beans_fiber_ctx_switch:\n"
    "  pushq %rbp\n"
    "  pushq %rbx\n"
    "  pushq %r12\n"
    "  pushq %r13\n"
    "  pushq %r14\n"
    "  pushq %r15\n"
    "  movq %rsp, (%rdi)\n"
    "  movq (%rsi), %rsp\n"
    "  popq %r15\n"
    "  popq %r14\n"
    "  popq %r13\n"
    "  popq %r12\n"
    "  popq %rbx\n"
    "  popq %rbp\n"
    "  retq\n"
    ".align 16\n"
    ".globl _beans_fiber_trampoline\n"
    ".globl beans_fiber_trampoline\n"
    "_beans_fiber_trampoline:\n"
    "beans_fiber_trampoline:\n"
    "  xorl %ebp, %ebp\n"
    "  movq %r12, %rdi\n"
    "  callq _fiber_entry_shim\n"
    "  ud2\n");
#define CTX_FRAME_BYTES (7 * 8) // return address + six saved registers

#else
// No hand-written switch for this architecture yet: ride the POSIX
// ucontext family instead. A swapcontext also saves the signal mask (a
// syscall on most libcs), so this tier is slower — correctness first;
// an arch earns its asm when someone needs it fast. glibc keeps these
// functions on every hosted tier CI runs (musl lacks them, but the musl
// lane is x86-64 and takes the asm above).
#define FIBER_CTX_UCONTEXT 1
#include <ucontext.h>
#endif

// The trampoline calls this by asm name. Never returns.
__attribute__((used, noreturn)) void fiber_entry_shim(BeansFiber* fiber)
    __asm__("_fiber_entry_shim");
__attribute__((used, noreturn)) void fiber_entry_shim(BeansFiber* fiber) {
#if defined(FIBER_ASAN)
    const void* from_bottom = NULL;
    size_t from_size = 0;
    __sanitizer_finish_switch_fiber(NULL, &from_bottom, &from_size);
    // In test mode the scheduler is the plain thread stack, learned from the
    // first switch in; a bootstrapped worker preset its carved bounds.
    if (!fiber->worker->sched_stack_bottom) {
        fiber->worker->sched_stack_bottom = from_bottom;
        fiber->worker->sched_stack_size = from_size;
    }
#endif
    fiber_entry(fiber);
    __builtin_unreachable();
}

#if defined(FIBER_CTX_UCONTEXT)
// ctx->sp holds a heap ucontext_t for this variant. Both sides of a swap
// need storage, and the very first switch away from a plain thread has
// nowhere prepared — so storage appears on first touch and lives as long
// as the record that owns the ctx.
static ucontext_t* ctx_storage(BeansFiberCtx* ctx) {
    if (!ctx->sp) {
        ctx->sp = calloc(1, sizeof(ucontext_t));
        if (!ctx->sp) {
            fprintf(stderr, "beans_fiber: out of memory for a context\n");
            abort();
        }
    }
    return (ucontext_t*)ctx->sp;
}

void beans_fiber_ctx_switch(BeansFiberCtx* from, BeansFiberCtx* to) {
    swapcontext(ctx_storage(from), ctx_storage(to));
}

// makecontext passes ints, so the carrier pointer rides as two halves —
// the double shift keeps the high half defined on 32-bit pointers.
static void ctx_ucontext_entry(unsigned int hi, unsigned int lo) {
    uintptr_t bits = ((uintptr_t)hi << 16 << 16) | (uintptr_t)lo;
    fiber_entry_shim((BeansFiber*)bits);
}

// Seeds the context so the first switch into `ctx` enters the trampoline
// with `carrier`. The usable stack sits above the guard page.
static void ctx_seed_into(BeansFiberCtx* ctx, BeansFiber* carrier, void* top) {
    ucontext_t* uc = ctx_storage(ctx);
    getcontext(uc);
    uc->uc_link = NULL;
    unsigned char* usable =
        (unsigned char*)carrier->stack_base + carrier->worker->page;
    uc->uc_stack.ss_sp = usable;
    uc->uc_stack.ss_size = (size_t)((unsigned char*)top - usable);
    uintptr_t bits = (uintptr_t)carrier;
    makecontext(uc, (void (*)(void))ctx_ucontext_entry, 2,
                (unsigned int)(bits >> 16 >> 16),
                (unsigned int)(bits & 0xffffffffu));
}
#else
// Seeds a stack so the first switch into `ctx` lands in the trampoline
// with `carrier` in the seeded callee-saved register. `top` is 16-aligned.
static void ctx_seed_into(BeansFiberCtx* ctx, BeansFiber* carrier, void* top) {
    unsigned char* sp = (unsigned char*)top - CTX_FRAME_BYTES;
    memset(sp, 0, CTX_FRAME_BYTES);
#if defined(__aarch64__)
    // x19 at +0x00, x30 (the "return" the switch lands in) at +0x58.
    *(void**)(sp + 0x00) = carrier;
    *(void**)(sp + 0x58) = (void*)beans_fiber_trampoline;
#elif defined(__x86_64__)
    // Pop order r15,r14,r13,r12,rbx,rbp then ret. r12 sits at +0x18 from
    // the seeded sp; the return slot is the last 8 bytes before `top`.
    *(void**)(sp + 0x18) = carrier;
    *(void**)((unsigned char*)top - 8) = (void*)beans_fiber_trampoline;
#endif
    ctx->sp = sp;
}
#endif // FIBER_CTX_UCONTEXT

static void ctx_seed(BeansFiber* fiber, void* top) {
    ctx_seed_into(&fiber->ctx, fiber, top);
}
#endif // !_WIN32

// ---- stacks ----------------------------------------------------------------

#if !defined(_WIN32)
// One reservation: [guard page][usable stack ... top]. Pages commit lazily
// as the fiber touches them, so 10k idle connection fibers cost virtual
// space, not resident memory.
static int stack_map(BeansFiber* fiber, size_t reserve, size_t page) {
    size_t whole = (reserve + page - 1) & ~(page - 1);
    if (whole < page * 4) whole = page * 4;
    void* base = mmap(NULL, whole, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS
#ifdef MAP_NORESERVE
                          | MAP_NORESERVE
#endif
                      ,
                      -1, 0);
    if (base == MAP_FAILED) return 0;
    if (mprotect(base, page, PROT_NONE) != 0) {
        munmap(base, whole);
        return 0;
    }
    fiber->stack_base = base;
    fiber->stack_reserve = whole;
    return 1;
}

static void stack_release(BeansFiber* fiber) {
    if (fiber->stack_base) munmap(fiber->stack_base, fiber->stack_reserve);
    fiber->stack_base = NULL;
}

static void* stack_top(BeansFiber* fiber) {
    return (unsigned char*)fiber->stack_base + fiber->stack_reserve;
}

// ---- guard-page report -----------------------------------------------------
//
// A fault inside the running fiber's guard page is a stack overflow. The
// report is async-signal-safe and the process aborts: an overflowed frame
// cannot be resumed, and F2's unwind machinery is not in the picture yet.

static void fiber_fault(int sig, siginfo_t* info, void* context) {
    (void)context;
    BeansWorker* worker = tls_worker;
    BeansFiber* fiber = worker ? worker->current : NULL;
    if (fiber && fiber->stack_base) {
        unsigned char* at = (unsigned char*)info->si_addr;
        unsigned char* guard = (unsigned char*)fiber->stack_base;
        if (at >= guard && at < guard + worker->page) {
            const char* head = "fiber stack overflow: ";
            ssize_t ignored;
            ignored = write(2, head, strlen(head));
            ignored = write(2, fiber->name, strlen(fiber->name));
            ignored = write(2, "\n", 1);
            (void)ignored;
            _exit(134);
        }
    }
    // Not ours: restore the default action and refault.
    signal(sig, SIG_DFL);
}

static void guard_report_install(void) {
    static _Atomic int installed = 0;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&installed, &expected, 1)) return;
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = fiber_fault;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
}

// The handler must not run on the overflowed fiber stack itself. One
// alternate stack per thread, installed at the thread's first worker and
// kept for the thread's life — a replaced stack could still be under a
// live signal frame, so it is never swapped or freed, and the
// thread-local keeps the one allocation reachable for leak checkers.
static _Thread_local void* guard_altstack = NULL;
static void guard_altstack_install(void) {
    if (guard_altstack) return;
    stack_t alt;
    memset(&alt, 0, sizeof alt);
    alt.ss_size = SIGSTKSZ < 64 * 1024 ? 64 * 1024 : (size_t)SIGSTKSZ;
    alt.ss_sp = malloc(alt.ss_size);
    if (!alt.ss_sp) return;
    if (sigaltstack(&alt, NULL) != 0) {
        free(alt.ss_sp);
        return;
    }
    guard_altstack = alt.ss_sp;
}
#endif // !_WIN32

// ---- worker ----------------------------------------------------------------

BeansWorker* beans_worker_new(void) {
    BeansWorker* worker = (BeansWorker*)calloc(1, sizeof *worker);
    if (!worker) return NULL;
#if defined(_WIN32)
    InitializeCriticalSection(&worker->inbox_m);
    InitializeConditionVariable(&worker->inbox_c);
    worker->page = 4096;
    // The scheduler itself becomes a fiber so SwitchToFiber can reach it.
    ConvertThreadToFiber(NULL);
#else
    pthread_mutex_init(&worker->inbox_m, NULL);
#if defined(__APPLE__)
    // macOS has no condattr clock; timed idle waits use the relative wait.
    pthread_cond_init(&worker->inbox_c, NULL);
#else
    // Timed idle waits (sleeping fibers) measure against CLOCK_MONOTONIC,
    // so the cond must too — a realtime-clock wait would drift with ntp.
    {
        pthread_condattr_t attr;
        pthread_condattr_init(&attr);
        pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
        pthread_cond_init(&worker->inbox_c, &attr);
        pthread_condattr_destroy(&attr);
    }
#endif
    worker->page = (size_t)sysconf(_SC_PAGESIZE);
    guard_report_install();
    guard_altstack_install();
#endif
    worker->poll_fd = -1;
    worker->poll_kick_fd = -1;
    tls_worker = worker;
    return worker;
}

BeansWorker* beans_worker_current(void) { return tls_worker; }

BeansFiber* beans_fiber_current(void) {
    return tls_worker ? tls_worker->current : NULL;
}

long long beans_worker_live(BeansWorker* worker) { return worker->live; }

static void ready_push(BeansWorker* worker, BeansFiber* fiber) {
    fiber->queue_next = NULL;
    if (worker->ready_tail) worker->ready_tail->queue_next = fiber;
    else worker->ready_head = fiber;
    worker->ready_tail = fiber;
}

static BeansFiber* ready_pop(BeansWorker* worker) {
    BeansFiber* fiber = worker->ready_head;
    if (!fiber) return NULL;
    worker->ready_head = fiber->queue_next;
    if (!worker->ready_head) worker->ready_tail = NULL;
    fiber->queue_next = NULL;
    return fiber;
}

static void all_add(BeansWorker* worker, BeansFiber* fiber) {
    fiber->all_prev = NULL;
    fiber->all_next = worker->all_head;
    if (worker->all_head) worker->all_head->all_prev = fiber;
    worker->all_head = fiber;
}

static void all_remove(BeansWorker* worker, BeansFiber* fiber) {
    if (fiber->all_prev) fiber->all_prev->all_next = fiber->all_next;
    else worker->all_head = fiber->all_next;
    if (fiber->all_next) fiber->all_next->all_prev = fiber->all_prev;
    fiber->all_next = fiber->all_prev = NULL;
}

// Installed by the hosting runtime: answers whether anything outside this
// worker — another live thread — could still resume a parked fiber. NULL
// (the standalone default) means "assume yes" and the idle wait blocks as
// before; the compiled runtime installs a check over its thread count.
static int (*fiber_may_wake)(void) = NULL;

void beans_fiber_set_may_wake(int (*may_wake)(void)) {
    fiber_may_wake = may_wake;
}

// Every fiber is parked, no timer is armed, and no other thread exists to
// resume anyone: pending with no possible wake is a deadlock, not a wait.
// Report the fiber table and end the process the way a panic would.
static void fiber_deadlock_report(BeansWorker* worker) {
    fprintf(stderr,
            "deadlock: every fiber is parked and nothing can wake them\n");
    for (BeansFiber* fiber = worker->all_head; fiber;
         fiber = fiber->all_next) {
        if (fiber->io_armed)
            fprintf(stderr, "  fiber '%s' parked waiting on fd %lld\n",
                    fiber->name[0] ? fiber->name : "(unnamed)",
                    fiber->io_fd);
        else
            fprintf(stderr, "  fiber '%s' parked\n",
                    fiber->name[0] ? fiber->name : "(unnamed)");
    }
    fflush(stderr);
    _exit(3);
}

#if defined(FIBER_NETPOLL)
static void poller_kick(BeansWorker* worker); // defined with the netpoller
#endif

// Moves cross-thread wakes into the run queue. With `block`, sleeps until
// one arrives — the caller checked that parked fibers still exist, so a
// wake is the only thing that can happen next.
static void inbox_drain(BeansWorker* worker, int block) {
#if defined(_WIN32)
    EnterCriticalSection(&worker->inbox_m);
    while (block && !worker->inbox_head)
        SleepConditionVariableCS(&worker->inbox_c, &worker->inbox_m, INFINITE);
    BeansFiber* head = worker->inbox_head;
    worker->inbox_head = worker->inbox_tail = NULL;
    LeaveCriticalSection(&worker->inbox_m);
#else
    pthread_mutex_lock(&worker->inbox_m);
    while (block && !worker->inbox_head)
        pthread_cond_wait(&worker->inbox_c, &worker->inbox_m);
    BeansFiber* head = worker->inbox_head;
    worker->inbox_head = worker->inbox_tail = NULL;
    pthread_mutex_unlock(&worker->inbox_m);
#endif
    while (head) {
        BeansFiber* next = head->queue_next;
        ready_push(worker, head);
        head = next;
    }
}

static void inbox_post(BeansWorker* worker, BeansFiber* fiber) {
#if defined(_WIN32)
    EnterCriticalSection(&worker->inbox_m);
    fiber->queue_next = NULL;
    if (worker->inbox_tail) worker->inbox_tail->queue_next = fiber;
    else worker->inbox_head = fiber;
    worker->inbox_tail = fiber;
    WakeConditionVariable(&worker->inbox_c);
    LeaveCriticalSection(&worker->inbox_m);
#else
    pthread_mutex_lock(&worker->inbox_m);
    fiber->queue_next = NULL;
    if (worker->inbox_tail) worker->inbox_tail->queue_next = fiber;
    else worker->inbox_head = fiber;
    worker->inbox_tail = fiber;
    pthread_cond_signal(&worker->inbox_c);
    pthread_mutex_unlock(&worker->inbox_m);
#if defined(FIBER_NETPOLL)
    // A worker blocked in its kernel poller hears nothing from the cond.
    // The post above happened before this read; the worker raises in_poll
    // before its final inbox recheck — so either that recheck sees the
    // fiber, or this read sees the flag and the kick wakes the poller.
    if (atomic_load(&worker->in_poll)) poller_kick(worker);
#endif
#endif
}

// ---- sleep -----------------------------------------------------------------
// A sleeping fiber parks with a deadline in its worker's min-heap. The
// heap is worker-local and only its own thread touches it, so no lock; the
// idle wait below turns the nearest deadline into a timed inbox wait.

static long long fiber_now(void) {
#if defined(_WIN32)
    return (long long)GetTickCount64() * 1000000LL;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}

static void sleeper_push(BeansWorker* worker, long long deadline,
                         BeansFiber* fiber) {
    if (worker->sleeper_count == worker->sleeper_cap) {
        int cap = worker->sleeper_cap ? worker->sleeper_cap * 2 : 16;
        BeansSleeper* grown = (BeansSleeper*)realloc(
            worker->sleepers, (size_t)cap * sizeof(BeansSleeper));
        if (!grown) {
            fprintf(stderr, "beans_fiber_sleep: out of memory\n");
            abort();
        }
        worker->sleepers = grown;
        worker->sleeper_cap = cap;
    }
    int at = worker->sleeper_count++;
    while (at > 0) {
        int parent = (at - 1) / 2;
        if (worker->sleepers[parent].deadline <= deadline) break;
        worker->sleepers[at] = worker->sleepers[parent];
        at = parent;
    }
    worker->sleepers[at].deadline = deadline;
    worker->sleepers[at].fiber = fiber;
}

static void sleeper_pop_min(BeansWorker* worker) {
    BeansSleeper last = worker->sleepers[--worker->sleeper_count];
    int at = 0;
    for (;;) {
        int child = 2 * at + 1;
        if (child >= worker->sleeper_count) break;
        if (child + 1 < worker->sleeper_count &&
            worker->sleepers[child + 1].deadline <
                worker->sleepers[child].deadline)
            child += 1;
        if (worker->sleepers[child].deadline >= last.deadline) break;
        worker->sleepers[at] = worker->sleepers[child];
        at = child;
    }
    if (worker->sleeper_count) worker->sleepers[at] = last;
}

// Resumes every sleeper whose deadline has passed. A fiber that stopped
// sleeping early (some other resume) may get one extra wake out of this —
// park sites loop, so a stale fire is just a spurious wake.
static void sleeper_fire_due(BeansWorker* worker, long long now) {
    while (worker->sleeper_count &&
           worker->sleepers[0].deadline <= now) {
        BeansFiber* fiber = worker->sleepers[0].fiber;
        sleeper_pop_min(worker);
        beans_fiber_resume(fiber);
    }
}

static void sleeper_remove(BeansWorker* worker, BeansFiber* fiber);

void beans_fiber_sleep(long long nanos) {
    BeansWorker* worker = tls_worker;
    if (nanos <= 0) return; // non-positive completes now (the timer rule)
    long long deadline = fiber_now() + nanos;
    sleeper_push(worker, deadline, worker->current);
    // The heap entry fires exactly once; every earlier wake is spurious
    // and re-parks with the entry still armed.
    while (fiber_now() < deadline) {
        if (beans_fiber_park() == BEANS_FIBER_PARK_CANCELLED) {
            // The cancel is the answer to this park: drop the timer entry so
            // nothing fires at a retired fiber, and end here. Until the frame
            // unwind lands the frame is abandoned, the same as a contained
            // panic — a cancel that returns beats one that never does.
            sleeper_remove(worker, worker->current);
            beans_fiber_exit_cancelled();
        }
    }
}

// Removes a fiber's heap entry without firing it — the readiness half of
// an io wait with a deadline won, and the timer must not resume the fiber
// later, when it may be parked somewhere unrelated (or gone). Absence is
// fine: a due entry may already have been popped by sleeper_fire_due.
static void sleeper_remove(BeansWorker* worker, BeansFiber* fiber) {
    for (int i = 0; i < worker->sleeper_count; i++) {
        if (worker->sleepers[i].fiber != fiber) continue;
        BeansSleeper last = worker->sleepers[--worker->sleeper_count];
        if (i == worker->sleeper_count) return;
        // sift the replacement to wherever it belongs, up or down
        int at = i;
        while (at > 0) {
            int parent = (at - 1) / 2;
            if (worker->sleepers[parent].deadline <= last.deadline) break;
            worker->sleepers[at] = worker->sleepers[parent];
            at = parent;
        }
        if (at == i) {
            for (;;) {
                int child = 2 * at + 1;
                if (child >= worker->sleeper_count) break;
                if (child + 1 < worker->sleeper_count &&
                    worker->sleepers[child + 1].deadline <
                        worker->sleepers[child].deadline)
                    child += 1;
                if (worker->sleepers[child].deadline >= last.deadline) break;
                worker->sleepers[at] = worker->sleepers[child];
                at = child;
            }
        }
        worker->sleepers[at] = last;
        return;
    }
}

// ---- the netpoller ---------------------------------------------------------
// One kernel poller per worker, created at the first io park. A fiber that
// must wait for a descriptor arms a one-shot registration carrying the
// fiber pointer and parks; the worker's idle wait pulls kernel events and
// resumes the fibers they name. Cross-thread resumes keep using the inbox
// — inbox_post kicks the poller (a user event on kqueue, an eventfd on
// epoll) when the worker is blocked inside it. Everything except the kick
// runs on the owner worker's thread, which is what keeps the arm/deliver/
// disarm bookkeeping lock-free.

#if defined(FIBER_NETPOLL)

static int poller_init(BeansWorker* worker) {
#if defined(FIBER_NETPOLL_KQUEUE)
    worker->poll_fd = kqueue();
    if (worker->poll_fd < 0) return 0;
    fcntl(worker->poll_fd, F_SETFD, FD_CLOEXEC);
    struct kevent kick;
    EV_SET(&kick, 0, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(worker->poll_fd, &kick, 1, NULL, 0, NULL) < 0) {
        close(worker->poll_fd);
        worker->poll_fd = -1;
        return 0;
    }
#else
    worker->poll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (worker->poll_fd < 0) return 0;
    worker->poll_kick_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    struct epoll_event kick = { .events = EPOLLIN, .data = { .ptr = NULL } };
    if (worker->poll_kick_fd < 0 ||
        epoll_ctl(worker->poll_fd, EPOLL_CTL_ADD, worker->poll_kick_fd,
                  &kick) < 0) {
        if (worker->poll_kick_fd >= 0) close(worker->poll_kick_fd);
        close(worker->poll_fd);
        worker->poll_fd = -1;
        worker->poll_kick_fd = -1;
        return 0;
    }
#endif
    return 1;
}

static int poller_arm(BeansWorker* worker, BeansFiber* fiber, long long fd,
                      int write) {
    if (worker->poll_fd < 0 && !poller_init(worker)) return 0;
#if defined(FIBER_NETPOLL_KQUEUE)
    // Queued, not submitted: the batch rides the next poller wait's
    // changelist. Registering late is safe — kqueue evaluates readiness
    // when it scans, so an fd that became ready in the meantime is
    // reported by the very call that registers it.
    if (worker->poll_queue_len == worker->poll_queue_cap) {
        int cap = worker->poll_queue_cap ? worker->poll_queue_cap * 2 : 64;
        struct kevent* grown = (struct kevent*)realloc(
            worker->poll_queue, (size_t)cap * sizeof *grown);
        if (!grown) return 0;
        worker->poll_queue = grown;
        worker->poll_queue_cap = cap;
    }
    EV_SET(&worker->poll_queue[worker->poll_queue_len], (uintptr_t)fd,
           write ? EVFILT_WRITE : EVFILT_READ, EV_ADD | EV_ONESHOT, 0, 0,
           fiber);
    worker->poll_queue_len += 1;
    fiber->io_queued = worker->poll_queue_len; // 1-based slot
#else
    struct epoll_event ev = {
        .events = (write ? EPOLLOUT : EPOLLIN) | EPOLLONESHOT,
        .data = { .ptr = fiber },
    };
    if (epoll_ctl(worker->poll_fd, EPOLL_CTL_ADD, (int)fd, &ev) < 0) {
        // a one-shot that already fired leaves a disabled registration
        if (errno != EEXIST ||
            epoll_ctl(worker->poll_fd, EPOLL_CTL_MOD, (int)fd, &ev) < 0)
            return 0;
    }
#endif
    return 1;
}

// Drops the armed registration without a delivery — the deadline won.
// Removing the event also removes anything pending for it in the kernel
// queue, so no stale delivery can name this fiber afterwards.
static void poller_disarm(BeansWorker* worker, BeansFiber* fiber) {
#if defined(FIBER_NETPOLL_KQUEUE)
    if (fiber->io_queued) {
        // Never reached the kernel: drop the queued slot (tail swapped
        // down) so the batch cannot register a fiber that gave up waiting.
        int slot = fiber->io_queued - 1;
        int last = worker->poll_queue_len - 1;
        if (slot != last) {
            worker->poll_queue[slot] = worker->poll_queue[last];
            BeansFiber* moved = (BeansFiber*)worker->poll_queue[slot].udata;
            moved->io_queued = slot + 1;
        }
        worker->poll_queue_len = last;
        fiber->io_queued = 0;
    } else {
        struct kevent ev;
        EV_SET(&ev, (uintptr_t)fiber->io_fd,
               fiber->io_write ? EVFILT_WRITE : EVFILT_READ, EV_DELETE, 0, 0,
               NULL);
        kevent(worker->poll_fd, &ev, 1, NULL, 0, NULL); // ENOENT: already fired
    }
#else
    epoll_ctl(worker->poll_fd, EPOLL_CTL_DEL, (int)fiber->io_fd, NULL);
#endif
    fiber->io_armed = 0;
    worker->io_waiters -= 1;
}

// Pulls delivered events and resumes the fibers they name. timeout_ns < 0
// blocks until something arrives (the kick included); 0 just polls.
static void poller_drain(BeansWorker* worker, long long timeout_ns) {
#if defined(FIBER_NETPOLL_KQUEUE)
    struct kevent events[64];
    struct timespec ts, *tp = NULL;
    if (timeout_ns >= 0) {
        ts.tv_sec = timeout_ns / 1000000000LL;
        ts.tv_nsec = timeout_ns % 1000000000LL;
        tp = &ts;
    }
    // Submit everything queued since the last wait in the same call. The
    // slots are released before the syscall: fibers this call resumes may
    // park again, and their fresh registrations must land in a clean queue.
    int nchanges = worker->poll_queue_len;
    for (int i = 0; i < nchanges; i++) {
        BeansFiber* queued = (BeansFiber*)worker->poll_queue[i].udata;
        queued->io_queued = 0;
    }
    worker->poll_queue_len = 0;
    int n = kevent(worker->poll_fd, worker->poll_queue, nchanges, events, 64,
                   tp);
    for (int i = 0; i < n; i++) {
        if (events[i].filter == EVFILT_USER) continue; // the kick itself
        BeansFiber* fiber = (BeansFiber*)events[i].udata;
        // EV_ERROR names a batched registration the kernel refused (the fd
        // died between park and submit, say). The fiber still wakes: its
        // retried io call reports the real error, where staying parked
        // would hang it to the deadline. The io_armed check drops errors
        // for a fiber that already gave up the wait.
        if (!fiber || !fiber->io_armed) continue;
        fiber->io_signalled = 1;
        fiber->io_armed = 0;
        worker->io_waiters -= 1;
        beans_fiber_resume(fiber);
    }
#else
    struct epoll_event events[64];
    int ms = -1;
    if (timeout_ns >= 0) {
        long long clamp = (timeout_ns + 999999LL) / 1000000LL;
        ms = clamp > 0x7fffffffLL ? 0x7fffffff : (int)clamp;
    }
    int n = epoll_wait(worker->poll_fd, events, 64, ms);
    for (int i = 0; i < n; i++) {
        if (!events[i].data.ptr) { // the kick: drain the eventfd
            unsigned long long word;
            while (read(worker->poll_kick_fd, &word, sizeof word) > 0) {}
            continue;
        }
        BeansFiber* fiber = (BeansFiber*)events[i].data.ptr;
        fiber->io_signalled = 1;
        fiber->io_armed = 0;
        worker->io_waiters -= 1;
        beans_fiber_resume(fiber);
    }
#endif
}

// Wakes a worker blocked inside poller_drain from another thread.
static void poller_kick(BeansWorker* worker) {
#if defined(FIBER_NETPOLL_KQUEUE)
    struct kevent ev;
    EV_SET(&ev, 0, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(worker->poll_fd, &ev, 1, NULL, 0, NULL);
#else
    unsigned long long one = 1;
    ssize_t ignored = write(worker->poll_kick_fd, &one, sizeof one);
    (void)ignored;
#endif
}

// The idle wait while io waiters exist: block in the kernel poller with
// the nearest sleeper deadline as the timeout. The in_poll flag and the
// one extra inbox check before blocking are the handshake with
// inbox_post's kick — a poster either sees the flag and kicks, or posted
// before it was raised and the recheck finds the fiber.
static void io_idle_wait(BeansWorker* worker) {
    long long timeout_ns = -1;
    if (worker->sleeper_count) {
        long long now = fiber_now();
        sleeper_fire_due(worker, now);
        if (worker->ready_head) return;
        if (worker->sleeper_count) {
            timeout_ns = worker->sleepers[0].deadline - now;
            if (timeout_ns < 0) timeout_ns = 0;
        }
    }
    atomic_store(&worker->in_poll, 1);
    pthread_mutex_lock(&worker->inbox_m);
    int posted = worker->inbox_head != NULL;
    pthread_mutex_unlock(&worker->inbox_m);
    if (posted) {
        atomic_store(&worker->in_poll, 0);
        inbox_drain(worker, 0);
        return;
    }
    poller_drain(worker, timeout_ns);
    atomic_store(&worker->in_poll, 0);
    inbox_drain(worker, 0);
    if (worker->sleeper_count) sleeper_fire_due(worker, fiber_now());
}

#endif // FIBER_NETPOLL

// Whether this build has a kernel poller — the gate for making a socket
// nonblocking on a fiber's behalf. Without one, sockets stay blocking and
// net waits block the worker thread exactly as they did before fibers.
long long beans_fiber_netpoll(void) {
#if defined(FIBER_NETPOLL)
    return 1;
#else
    return 0;
#endif
}

// Parks the calling fiber until `fd` is ready for reading (write == 0) or
// writing, or until timeout_ms passes (timeout_ms < 0 waits forever).
// Answers 0 for ready, 1 for timeout, -2 when there is no poller here or
// no current fiber — the caller then waits the thread-blocking way.
long long beans_fiber_wait_io(long long fd, long long write,
                              long long timeout_ms) {
#if !defined(FIBER_NETPOLL)
    (void)fd; (void)write; (void)timeout_ms;
    return -2;
#else
    BeansWorker* worker = tls_worker;
    BeansFiber* fiber = worker ? worker->current : NULL;
    if (!fiber) return -2;
    if (!poller_arm(worker, fiber, fd, write ? 1 : 0)) return -2;
    if (!fiber->io_armed) {
        fiber->io_armed = 1;
        worker->io_waiters += 1;
    }
    fiber->io_signalled = 0;
    fiber->io_fd = fd;
    fiber->io_write = write ? 1 : 0;
    long long deadline =
        timeout_ms >= 0 ? fiber_now() + timeout_ms * 1000000LL : -1;
    if (deadline >= 0) sleeper_push(worker, deadline, fiber);
    long long result = 0;
    for (;;) {
        if (fiber->io_signalled) break;
        if (deadline >= 0 && fiber_now() >= deadline) {
            poller_disarm(worker, fiber);
            result = 1;
            break;
        }
        if (beans_fiber_park() == BEANS_FIBER_PARK_CANCELLED) {
            // Same answer as every other park: disarm what was armed for this
            // wait, then end the fiber with the cancelled outcome.
            poller_disarm(worker, fiber);
            if (deadline >= 0) sleeper_remove(worker, fiber);
            beans_fiber_exit_cancelled();
        }
    }
    if (deadline >= 0) sleeper_remove(worker, fiber);
    return result;
#endif
}

// The idle wait, deadline-aware: drains the inbox, blocking until either a
// cross-thread resume arrives or the nearest sleeper is due. With no
// sleepers this is the plain blocking inbox wait.
static void idle_wait(BeansWorker* worker) {
#if defined(FIBER_NETPOLL)
    // io waiters change the wait entirely: block in the kernel poller
    // (kicked by inbox_post) so fd readiness, timers, and cross-thread
    // resumes all land. The kernel can always wake an io waiter, so this
    // path never reports a deadlock.
    if (worker->io_waiters > 0) {
        io_idle_wait(worker);
        return;
    }
#endif
    if (!worker->sleeper_count) {
        if (fiber_may_wake && !fiber_may_wake()) {
            // No timers and no other thread: drain the inbox once for a
            // wake a since-finished thread left behind, then report.
            inbox_drain(worker, 0);
            if (worker->ready_head) return;
            fiber_deadlock_report(worker);
        }
        inbox_drain(worker, 1);
        return;
    }
    long long now = fiber_now();
    sleeper_fire_due(worker, now);
    if (worker->ready_head || !worker->sleeper_count) return;
    long long nearest = worker->sleepers[0].deadline;
    long long remaining = nearest - now;
    if (remaining < 0) remaining = 0;
#if defined(_WIN32)
    EnterCriticalSection(&worker->inbox_m);
    if (!worker->inbox_head)
        SleepConditionVariableCS(&worker->inbox_c, &worker->inbox_m,
                                 (DWORD)(remaining / 1000000LL + 1));
    BeansFiber* head = worker->inbox_head;
    worker->inbox_head = worker->inbox_tail = NULL;
    LeaveCriticalSection(&worker->inbox_m);
#else
    pthread_mutex_lock(&worker->inbox_m);
    if (!worker->inbox_head) {
#if defined(__APPLE__)
        struct timespec rel = { remaining / 1000000000LL,
                                remaining % 1000000000LL };
        pthread_cond_timedwait_relative_np(&worker->inbox_c,
                                           &worker->inbox_m, &rel);
#else
        // the inbox cond runs on CLOCK_MONOTONIC (see beans_worker_new)
        struct timespec until = { nearest / 1000000000LL,
                                  nearest % 1000000000LL };
        pthread_cond_timedwait(&worker->inbox_c, &worker->inbox_m, &until);
#endif
    }
    BeansFiber* head = worker->inbox_head;
    worker->inbox_head = worker->inbox_tail = NULL;
    pthread_mutex_unlock(&worker->inbox_m);
#endif
    while (head) {
        BeansFiber* next = head->queue_next;
        ready_push(worker, head);
        head = next;
    }
    sleeper_fire_due(worker, fiber_now());
}

// ---- fiber lifecycle -------------------------------------------------------

static void fiber_record_free(BeansFiber* fiber) {
#if defined(_WIN32)
    if (fiber->ctx.sp) DeleteFiber(fiber->ctx.sp);
#else
    stack_release(fiber);
#if defined(FIBER_CTX_UCONTEXT)
    free(fiber->ctx.sp);
    fiber->ctx.sp = NULL;
#endif
#endif
    free(fiber);
}

// Reclaims or pools a finished fiber once its result has been delivered
// (or nobody wants it). Pooled fibers keep their stack reservation.
static void fiber_retire(BeansWorker* worker, BeansFiber* fiber) {
    if (worker->pool_count < BEANS_FIBER_POOL_MAX
#if defined(_WIN32)
        && 0 // the Windows build recreates OS fibers instead of pooling
#endif
    ) {
        fiber->queue_next = worker->pool;
        worker->pool = fiber;
        worker->pool_count += 1;
        return;
    }
    fiber_record_free(fiber);
}

static void fiber_finish(int status) __attribute__((noreturn));

static void fiber_entry(BeansFiber* fiber) {
    fiber->fn(fiber->arg);
    fiber_finish(BEANS_FIBER_OK);
}

#if defined(_WIN32)
static void CALLBACK fiber_entry_win(void* raw) { fiber_entry((BeansFiber*)raw); }
#endif

BeansFiber* beans_fiber_spawn(BeansWorker* worker, void (*fn)(void*),
                              void* arg, const char* name,
                              size_t stack_reserve) {
    if (stack_reserve == 0) stack_reserve = BEANS_FIBER_DEFAULT_STACK;

    BeansFiber* fiber = NULL;
    // Reuse a pooled record when its reservation is big enough; the pool
    // holds the common case — every fiber on the default size.
    BeansFiber** link = &worker->pool;
    while (*link) {
        if ((*link)->stack_reserve >= stack_reserve) {
            fiber = *link;
            *link = fiber->queue_next;
            worker->pool_count -= 1;
            break;
        }
        link = &(*link)->queue_next;
    }
    if (!fiber) {
        fiber = (BeansFiber*)calloc(1, sizeof *fiber);
        if (!fiber) return NULL;
#if !defined(_WIN32)
        if (!stack_map(fiber, stack_reserve, worker->page)) {
            free(fiber);
            return NULL;
        }
#endif
    } else {
        void* base = fiber->stack_base;
        size_t reserve = fiber->stack_reserve;
#if defined(FIBER_CTX_UCONTEXT)
        void* ctx_keep = fiber->ctx.sp; // heap ucontext_t, reused by reseed
#endif
        memset(fiber, 0, sizeof *fiber);
        fiber->stack_base = base;
        fiber->stack_reserve = reserve;
#if defined(FIBER_CTX_UCONTEXT)
        fiber->ctx.sp = ctx_keep;
#endif
    }

    fiber->worker = worker;
    fiber->fn = fn;
    fiber->arg = arg;
    if (name) {
        strncpy(fiber->name, name, sizeof fiber->name - 1);
    } else {
        fiber->name[0] = '\0';
    }
    atomic_store(&fiber->state, FIBER_READY);
    atomic_store(&fiber->pending_wake, 0);
    atomic_store(&fiber->cancel_flag, 0);

#if defined(_WIN32)
    fiber->ctx.sp = CreateFiberEx(worker->page * 4, stack_reserve, 0,
                                  fiber_entry_win, fiber);
    if (!fiber->ctx.sp) {
        free(fiber);
        return NULL;
    }
#else
    ctx_seed(fiber, stack_top(fiber));
#endif

    worker->live += 1;
    all_add(worker, fiber);
    ready_push(worker, fiber);
    return fiber;
}

// Switches from the running fiber to the scheduler with a disposition the
// scheduler completes once the fiber's stack is quiescent.
static void fiber_to_scheduler(int disposition) {
    BeansWorker* worker = tls_worker;
    BeansFiber* fiber = worker->current;
    fiber->disposition = disposition;
#if defined(FIBER_ASAN)
    // A finishing fiber's fake frames are freed (NULL save); a parking
    // fiber's are kept and restored when it resumes.
    __sanitizer_start_switch_fiber(
        disposition == DISPOSE_FINISH ? NULL : &fiber->asan_save,
        worker->sched_stack_bottom, worker->sched_stack_size);
#endif
#if defined(_WIN32)
    SwitchToFiber(worker->sched_ctx.sp);
#else
    beans_fiber_ctx_switch(&fiber->ctx, &worker->sched_ctx);
#endif
#if defined(FIBER_ASAN)
    __sanitizer_finish_switch_fiber(fiber->asan_save, NULL, NULL);
#endif
}

static void fiber_finish(int status) {
    BeansFiber* fiber = tls_worker->current;
    fiber->status = status;
    atomic_store(&fiber->state, FIBER_PARKING); // no resume may queue us now
    fiber_to_scheduler(DISPOSE_FINISH);
    __builtin_unreachable();
}

// ---- controlled unwind -----------------------------------------------------
//
// A contained failure does not abandon the fiber's stack: it runs every
// frame's cleanup on the way out, so defers fire newest-first and owned
// values drop exactly as a return would drop them. The mechanism is the
// platform's forced unwind — the compiler emits `invoke`/`landingpad`
// cleanup pads and marks each frame with __gcc_personality_v0, and this
// walks them. Nothing is executed on the non-failing path: the pads are
// side tables, reached only from here.
//
// BEANS_FIBER_UNWIND is defined by the build driver for a program that can
// actually contain a panic (it brews) on a target whose unwinder we use. A
// build without it keeps F1's behaviour, and says so rather than pretending.

int beans_fiber_unwinding(BeansFiber* fiber) {
    return fiber && fiber->unwind_status != 0;
}

const char* beans_fiber_message(BeansFiber* fiber) {
    return fiber ? fiber->message : "";
}

#if BEANS_FIBER_UNWIND
#include <unwind.h>

// The unwind is one-phase and forced, because there is no handler to search
// for: every Beans frame carries cleanup only. The stop function is the
// backstop, not the exit — the emitted pad on the fiber's entry frame calls
// beans_fiber_unwind_finish and never resumes, so END_OF_STACK is reached
// only when the frames above carry no cleanup at all (a fiber entered from
// something the compiler did not emit). Ending the fiber there is exactly
// F1's answer, which beats letting the unwinder abort the process.
static _Unwind_Reason_Code fiber_unwind_stop(
    int version, _Unwind_Action actions, _Unwind_Exception_Class cls,
    struct _Unwind_Exception* exception, struct _Unwind_Context* context,
    void* argument) {
    (void)version;
    (void)cls;
    (void)exception;
    (void)context;
    (void)argument;
    if (actions & _UA_END_OF_STACK) {
        BeansFiber* fiber = tls_worker->current;
        fiber_finish(fiber->unwind_status);
    }
    return _URC_NO_REASON;
}

void beans_fiber_begin_unwind(int status) {
    BeansFiber* fiber = tls_worker->current;
    fiber->unwind_status = status;
    struct _Unwind_Exception* exception =
        (struct _Unwind_Exception*)(void*)fiber->unwind_exc;
    _Static_assert(sizeof(struct _Unwind_Exception) <= 64,
                   "fiber unwind scratch is too small for _Unwind_Exception");
    memset(exception, 0, sizeof *exception);
    exception->exception_class = 0x4245414e53554e57ULL; // "BEANSUNW"
    _Unwind_ForcedUnwind(exception, fiber_unwind_stop, NULL);
    // The unwinder only returns here when it could not start; the fiber
    // still has to end, so end it the way F1 did.
    fiber_finish(status);
    __builtin_unreachable();
}
#else
void beans_fiber_begin_unwind(int status) {
    BeansFiber* fiber = tls_worker->current;
    fiber->unwind_status = status;
    fiber_finish(status);
    __builtin_unreachable();
}
#endif

void beans_fiber_unwind_finish(void) {
    fiber_finish(tls_worker->current->unwind_status);
    __builtin_unreachable();
}

void beans_fiber_panic(const char* message) {
    BeansFiber* fiber = tls_worker->current;
    strncpy(fiber->message, message ? message : "",
            sizeof fiber->message - 1);
    beans_fiber_begin_unwind(BEANS_FIBER_PANICKED);
    __builtin_unreachable();
}

void beans_fiber_exit_cancelled(void) {
    beans_fiber_begin_unwind(BEANS_FIBER_CANCELLED);
    __builtin_unreachable();
}

// Wakes may be spurious: a racer that latches while the scheduler is
// publishing PARKED can wake a fiber one extra time. Every park site loops
// on its condition, the same discipline a condvar wait demands.
int beans_fiber_park(void) {
    BeansFiber* fiber = tls_worker->current;
    if (atomic_load(&fiber->cancel_flag)) return BEANS_FIBER_PARK_CANCELLED;
    if (atomic_exchange(&fiber->pending_wake, 0)) return BEANS_FIBER_WOKEN;
    atomic_store(&fiber->state, FIBER_PARKING);
    fiber_to_scheduler(DISPOSE_PARK);
    // Resumed. A cancel that raced the wake still reads as cancelled — the
    // contract is "observed at the next park", and this is that park.
    if (atomic_load(&fiber->cancel_flag)) return BEANS_FIBER_PARK_CANCELLED;
    return BEANS_FIBER_WOKEN;
}

int beans_fiber_yield(void) {
    BeansFiber* fiber = tls_worker->current;
    if (atomic_load(&fiber->cancel_flag)) return BEANS_FIBER_PARK_CANCELLED;
    atomic_store(&fiber->state, FIBER_PARKING);
    fiber_to_scheduler(DISPOSE_YIELD);
    if (atomic_load(&fiber->cancel_flag)) return BEANS_FIBER_PARK_CANCELLED;
    return BEANS_FIBER_WOKEN;
}

void beans_fiber_resume(BeansFiber* fiber) {
    for (;;) {
        int state = atomic_load(&fiber->state);
        if (state == FIBER_PARKED) {
            if (!atomic_compare_exchange_strong(&fiber->state, &state,
                                                FIBER_READY))
                continue;
            BeansWorker* owner = fiber->worker;
            if (tls_worker == owner) ready_push(owner, fiber);
            else inbox_post(owner, fiber);
            return;
        }
        if (state == FIBER_DONE) return;
        // RUNNING, READY, or PARKING: latch the wake; the park (or the
        // scheduler finishing a PARKING transition) consumes it.
        atomic_store(&fiber->pending_wake, 1);
        if (atomic_load(&fiber->state) == FIBER_PARKED) continue;
        return;
    }
}

void beans_fiber_cancel(BeansFiber* fiber) {
    atomic_store(&fiber->cancel_flag, 1);
    beans_fiber_resume(fiber);
}

int beans_fiber_cancelled(BeansFiber* fiber) {
    return atomic_load(&fiber->cancel_flag);
}

int beans_fiber_is_root(BeansFiber* fiber) { return fiber->is_root; }

void beans_fiber_forget(BeansFiber* fiber) { fiber->forgotten = 1; }

// Owner-worker only, and only before the fiber could have finished — in
// practice right after the spawn, while the child still sits in the ready
// queue (spawning never yields, so the child has not run).
void beans_fiber_set_done_hook(BeansFiber* fiber, void (*hook)(void*),
                               void* arg) {
    fiber->done_hook = hook;
    fiber->done_arg = arg;
}

int beans_fiber_join(BeansFiber* fiber, char* message_out,
                     size_t message_cap) {
    BeansWorker* worker = tls_worker;
    if (fiber->joined) {
        fprintf(stderr, "beans_fiber_join: second join on '%s'\n",
                fiber->name);
        abort();
    }
    while (atomic_load(&fiber->state) != FIBER_DONE) {
        fiber->joiner = worker->current;
        int outcome = beans_fiber_park();
        fiber->joiner = NULL;
        // A joiner cancelled mid-wait stops waiting. The child keeps running
        // and nobody reaps it — abandoned, like every other frame a cancel
        // leaves behind until the unwind lands.
        if (outcome == BEANS_FIBER_PARK_CANCELLED &&
            atomic_load(&fiber->state) != FIBER_DONE)
            beans_fiber_exit_cancelled();
    }
    fiber->joined = 1;
    int status = fiber->status;
    if (message_out && message_cap) {
        strncpy(message_out, fiber->message, message_cap - 1);
        message_out[message_cap - 1] = '\0';
    }
    fiber_retire(worker, fiber);
    return status;
}

// ---- scheduler -------------------------------------------------------------

// Completes what the switched-away fiber asked for. Runs on the scheduler
// context, so the fiber's stack is quiescent.
static void settle(BeansWorker* worker, BeansFiber* fiber) {
    switch (fiber->disposition) {
    case DISPOSE_PARK:
        if (atomic_exchange(&fiber->pending_wake, 0)) {
            atomic_store(&fiber->state, FIBER_READY);
            ready_push(worker, fiber);
            return;
        }
        {
            int expected = FIBER_PARKING;
            if (atomic_compare_exchange_strong(&fiber->state, &expected,
                                               FIBER_PARKED))
                return;
        }
        // A wake latched between the exchange and the store: requeue.
        atomic_store(&fiber->state, FIBER_READY);
        ready_push(worker, fiber);
        return;
    case DISPOSE_YIELD:
        // The pending-wake latch survives a yield on purpose: a wake that
        // landed while the fiber was running belongs to its next park.
        atomic_store(&fiber->state, FIBER_READY);
        ready_push(worker, fiber);
        return;
    case DISPOSE_FINISH: {
        atomic_store(&fiber->state, FIBER_DONE);
        worker->live -= 1;
        all_remove(worker, fiber);
        // Completion hook before the joiner: a group waiter woken here must
        // find the stamp already written when it runs.
        if (fiber->done_hook) fiber->done_hook(fiber->done_arg);
        BeansFiber* joiner = fiber->joiner;
        if (joiner) beans_fiber_resume(joiner);
        else if (fiber->forgotten) fiber_retire(worker, fiber);
        return;
    }
    default:
        fprintf(stderr, "beans_fiber: fiber '%s' switched with no verdict\n",
                fiber->name);
        abort();
    }
}

// Runs one ready fiber to its next park and settles what it asked for.
static void run_one(BeansWorker* worker, BeansFiber* fiber) {
    atomic_store(&fiber->state, FIBER_RUNNING);
    fiber->disposition = DISPOSE_NONE;
    worker->current = fiber;
#if defined(FIBER_ASAN)
    // The root fiber lives on the plain thread stack; its bounds are not
    // ours to name, and ASan tracks that stack natively anyway.
    if (fiber->stack_base)
        __sanitizer_start_switch_fiber(
            &worker->asan_save,
            (const unsigned char*)fiber->stack_base + worker->page,
            fiber->stack_reserve - worker->page);
    else
        __sanitizer_start_switch_fiber(&worker->asan_save, NULL, 0);
#endif
#if defined(_WIN32)
    SwitchToFiber(fiber->ctx.sp);
#else
    beans_fiber_ctx_switch(&worker->sched_ctx, &fiber->ctx);
#endif
#if defined(FIBER_ASAN)
    __sanitizer_finish_switch_fiber(worker->asan_save, NULL, NULL);
#endif
    worker->current = NULL;
    settle(worker, fiber);
}

void beans_worker_run(BeansWorker* worker) {
    while (worker->live > 0) {
        inbox_drain(worker, 0);
        if (worker->sleeper_count) sleeper_fire_due(worker, fiber_now());
        BeansFiber* fiber = ready_pop(worker);
        if (!fiber) {
            if (worker->live == 0) break;
            // Every live fiber is parked: wait for a cross-thread resume
            // or the nearest sleeper's deadline, whichever lands first.
            idle_wait(worker);
            continue;
        }
        run_one(worker, fiber);
    }
}

// The bootstrap scheduler: same loop, no exit — the root fiber ending the
// program is the only way out, and it ends the process, not this loop.
static void sched_main(void* raw) {
    BeansWorker* worker = (BeansWorker*)raw;
    // The switch that started this loop came from the root fiber's first
    // park. Every later park returns into a run_one frame below, which
    // settles its fiber — but this first one has no frame waiting, so the
    // root would stay PARKING forever unless it is settled here.
    if (worker->current) {
        BeansFiber* from = worker->current;
        worker->current = NULL;
        settle(worker, from);
    }
    for (;;) {
        inbox_drain(worker, 0);
        if (worker->sleeper_count) sleeper_fire_due(worker, fiber_now());
        BeansFiber* fiber = ready_pop(worker);
        if (!fiber) {
            idle_wait(worker);
            continue;
        }
        run_one(worker, fiber);
    }
}

#if !defined(_WIN32)
BeansWorker* beans_worker_bootstrap(void) {
    if (tls_worker) return tls_worker;
    BeansWorker* worker = beans_worker_new();
    if (!worker) return NULL;

    BeansFiber* root = (BeansFiber*)calloc(1, sizeof *root);
    if (!root) return NULL;
    root->worker = worker;
    root->is_root = 1;
    strncpy(root->name, "main", sizeof root->name - 1);
    atomic_store(&root->state, FIBER_RUNNING);
    worker->root_fiber = root;
    worker->current = root;
    worker->live = 1;
    all_add(worker, root);

    BeansFiber* sched = (BeansFiber*)calloc(1, sizeof *sched);
    if (!sched) return NULL;
    sched->worker = worker;
    sched->fn = sched_main;
    sched->arg = worker;
    strncpy(sched->name, "scheduler", sizeof sched->name - 1);
    if (!stack_map(sched, 256 * 1024, worker->page)) return NULL;
    ctx_seed_into(&worker->sched_ctx, sched, stack_top(sched));
    worker->sched_fiber = sched;
#if defined(FIBER_ASAN)
    worker->sched_stack_bottom =
        (const unsigned char*)sched->stack_base + worker->page;
    worker->sched_stack_size = sched->stack_reserve - worker->page;
#endif
    return worker;
}
#else // _WIN32
// The Windows bootstrap: beans_worker_new converted the calling thread to
// an OS fiber, and that fiber is the root; the scheduler loop runs on an
// OS fiber of its own — the CreateFiber mirror of the POSIX build's
// carved-stack scheduler.
static void CALLBACK sched_main_win(void* raw) { sched_main(raw); }

BeansWorker* beans_worker_bootstrap(void) {
    if (tls_worker) return tls_worker;
    BeansWorker* worker = beans_worker_new();
    if (!worker) return NULL;

    BeansFiber* root = (BeansFiber*)calloc(1, sizeof *root);
    if (!root) return NULL;
    root->worker = worker;
    root->is_root = 1;
    strncpy(root->name, "main", sizeof root->name - 1);
    atomic_store(&root->state, FIBER_RUNNING);
    root->ctx.sp = GetCurrentFiber();
    worker->root_fiber = root;
    worker->current = root;
    worker->live = 1;
    all_add(worker, root);

    BeansFiber* sched = (BeansFiber*)calloc(1, sizeof *sched);
    if (!sched) return NULL;
    sched->worker = worker;
    sched->fn = sched_main;
    sched->arg = worker;
    strncpy(sched->name, "scheduler", sizeof sched->name - 1);
    worker->sched_ctx.sp = CreateFiberEx(worker->page * 4, 256 * 1024, 0,
                                         sched_main_win, worker);
    if (!worker->sched_ctx.sp) return NULL;
    worker->sched_fiber = sched; // its context lives in sched_ctx
    return worker;
}
#endif // !_WIN32

void beans_worker_free(BeansWorker* worker) {
    while (worker->pool) {
        BeansFiber* fiber = worker->pool;
        worker->pool = fiber->queue_next;
        fiber_record_free(fiber);
    }
    free(worker->sleepers);
#if defined(FIBER_NETPOLL)
    if (worker->poll_fd >= 0) close(worker->poll_fd);
    if (worker->poll_kick_fd >= 0) close(worker->poll_kick_fd);
#endif
#if defined(FIBER_NETPOLL_KQUEUE)
    free(worker->poll_queue);
#endif
#if defined(FIBER_CTX_UCONTEXT)
    free(worker->sched_ctx.sp); // the thread's own swap target, if it ever parked
#endif
#if defined(_WIN32)
    DeleteCriticalSection(&worker->inbox_m);
#else
    pthread_mutex_destroy(&worker->inbox_m);
    pthread_cond_destroy(&worker->inbox_c);
#endif
    if (tls_worker == worker) tls_worker = NULL;
    free(worker);
}
