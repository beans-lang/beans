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

    BeansFiber* joiner;    // parked fiber waiting on this one, if any
    int forgotten;         // nobody will join; reclaim on finish
    int joined;            // join already delivered (a second join aborts)
    int is_root;           // the promoted thread itself; never finishes

    BeansFiber* queue_next; // run-queue / inbox / pool link

    // every live fiber of the worker, for the deadlock report
    BeansFiber* all_next;
    BeansFiber* all_prev;

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

#if defined(__aarch64__)
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

#elif defined(__x86_64__)
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
#error "beans_fiber: no context switch for this architecture yet"
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

// The handler must not run on the overflowed fiber stack itself.
static void guard_altstack_install(void) {
    stack_t alt;
    memset(&alt, 0, sizeof alt);
    alt.ss_size = SIGSTKSZ < 64 * 1024 ? 64 * 1024 : (size_t)SIGSTKSZ;
    alt.ss_sp = malloc(alt.ss_size);
    if (!alt.ss_sp) return;
    if (sigaltstack(&alt, NULL) != 0) free(alt.ss_sp);
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
        fprintf(stderr, "  fiber '%s' parked\n",
                fiber->name[0] ? fiber->name : "(unnamed)");
    }
    fflush(stderr);
    _exit(3);
}

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

void beans_fiber_sleep(long long nanos) {
    BeansWorker* worker = tls_worker;
    if (nanos <= 0) return; // non-positive completes now (the timer rule)
    long long deadline = fiber_now() + nanos;
    sleeper_push(worker, deadline, worker->current);
    // The heap entry fires exactly once; every earlier wake is spurious
    // and re-parks with the entry still armed.
    while (fiber_now() < deadline) {
        if (beans_fiber_park() == BEANS_FIBER_PARK_CANCELLED) {
            // Interim: cancellation unwinds land with the F2 unwind work;
            // until then a cancelled sleeper just finishes its sleep.
            continue;
        }
    }
}

// The idle wait, deadline-aware: drains the inbox, blocking until either a
// cross-thread resume arrives or the nearest sleeper is due. With no
// sleepers this is the plain blocking inbox wait.
static void idle_wait(BeansWorker* worker) {
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

#if defined(_WIN32)
static void CALLBACK fiber_entry_win(void* raw) { fiber_entry((BeansFiber*)raw); }
#endif

static void fiber_finish(int status) __attribute__((noreturn));

static void fiber_entry(BeansFiber* fiber) {
    fiber->fn(fiber->arg);
    fiber_finish(BEANS_FIBER_OK);
}

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
        memset(fiber, 0, sizeof *fiber);
        fiber->stack_base = base;
        fiber->stack_reserve = reserve;
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

void beans_fiber_panic(const char* message) {
    BeansFiber* fiber = tls_worker->current;
    strncpy(fiber->message, message ? message : "",
            sizeof fiber->message - 1);
    fiber_finish(BEANS_FIBER_PANICKED);
    __builtin_unreachable();
}

void beans_fiber_exit_cancelled(void) {
    fiber_finish(BEANS_FIBER_CANCELLED);
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
        beans_fiber_park();
        fiber->joiner = NULL;
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

#if !defined(_WIN32)
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
#endif // !_WIN32

void beans_worker_free(BeansWorker* worker) {
    while (worker->pool) {
        BeansFiber* fiber = worker->pool;
        worker->pool = fiber->queue_next;
        fiber_record_free(fiber);
    }
    free(worker->sleepers);
#if defined(_WIN32)
    DeleteCriticalSection(&worker->inbox_m);
#else
    pthread_mutex_destroy(&worker->inbox_m);
    pthread_cond_destroy(&worker->inbox_c);
#endif
    if (tls_worker == worker) tls_worker = NULL;
    free(worker);
}
