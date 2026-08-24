// The fiber runtime core — F1 of the fiber plan (spec/CONCURRENCY.md).
//
// Pinned fibers: a fiber is a real stack that parks and resumes on the one
// OS worker that spawned it, forever. No migration, no stack copying, no
// preemption. A context switch is a callee-saved register swap; everything
// the compiler will later lower `brew`, parks, and joins onto lives here,
// testable from plain C without the compiler (test/fiber_core.c).
//
// Threading contract: every function here except beans_fiber_resume and
// beans_worker_post must be called on the fiber's own worker thread.
// beans_fiber_resume may be called from any thread — a cross-thread call
// lands the wake in the worker's inbox and wakes a sleeping worker.

#ifndef BEANS_FIBER_H
#define BEANS_FIBER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BeansFiber BeansFiber;
typedef struct BeansWorker BeansWorker;

// How a fiber ended. Delivered exactly once at the join.
enum {
    BEANS_FIBER_OK = 0,        // ran to completion
    BEANS_FIBER_PANICKED = 1,  // beans_fiber_panic — message at the join
    BEANS_FIBER_CANCELLED = 2, // cancel observed at a park
};

// Park verdicts. A parked fiber that is resumed sees WOKEN; a parked fiber
// whose cancel flag was set (before or during the park) sees CANCELLED and
// must proceed to unwind — the compiler owns that part; C callers exit.
enum {
    BEANS_FIBER_WOKEN = 0,
    BEANS_FIBER_PARK_CANCELLED = 1,
};

// ---- worker ----------------------------------------------------------------

// One worker per OS thread. Created on the thread that will run it.
BeansWorker* beans_worker_new(void);

// The compiled runtime's entry: promotes the calling thread to a worker
// whose ROOT FIBER is the code that is already running, on the thread's own
// stack, and gives the scheduler a small carved stack of its own. The first
// call creates the worker; later calls return it. A program that never
// brews never calls this and pays nothing. The root fiber parks and resumes
// like any other; it is never joined and its panic keeps the process-ending
// behaviour plain programs have today.
BeansWorker* beans_worker_bootstrap(void);

// Runs ready fibers until every fiber this worker owns has finished. When
// the run queue is empty but fibers are parked, blocks waiting for
// cross-thread resumes. This is the F1 test driver; the compiled runtime
// will fuse this loop with the reactor in F3.
void beans_worker_run(BeansWorker* worker);

// Frees the worker and its recycled stacks. Every fiber must have finished.
void beans_worker_free(BeansWorker* worker);

// The calling thread's worker (NULL off-worker). The running fiber, or NULL
// when the scheduler itself is executing.
BeansWorker* beans_worker_current(void);
BeansFiber* beans_fiber_current(void);

// ---- fibers ----------------------------------------------------------------

// Starts `fn(arg)` on a new fiber of this worker and queues it ready. The
// name is borrowed for reports (may be NULL); stack_reserve of 0 takes the
// default (512KB). The lowest page is a guard: overflow reports the fiber's
// name and aborts. Returns NULL only when the stack cannot be reserved.
BeansFiber* beans_fiber_spawn(BeansWorker* worker, void (*fn)(void*),
                              void* arg, const char* name,
                              size_t stack_reserve);

// Parks the running fiber until someone resumes it. Returns a park verdict.
int beans_fiber_park(void);

// Parks to the tail of the run queue: every fiber already ready runs before
// the yielder runs again. Returns a park verdict, like beans_fiber_park.
int beans_fiber_yield(void);

// Makes a parked fiber ready. Safe from any thread; from the owning worker
// it is a plain queue push. A resume that arrives while the fiber is still
// running is remembered, so a resume/park race never loses the wake.
// Resuming a finished fiber is a no-op.
void beans_fiber_resume(BeansFiber* fiber);

// Requests cancellation: sets the flag and wakes the fiber if it is parked.
// The fiber observes it at its next park (or the park it is in now).
void beans_fiber_cancel(BeansFiber* fiber);

// True when this fiber's cancel flag is set. The compiler's park sites use
// the park verdict instead; this is for tests and cooperative checks.
int beans_fiber_cancelled(BeansFiber* fiber);

// True for a worker's root fiber — the promoted thread itself. The runtime's
// panic path asks this to decide between containment (a brewed fiber ends
// alone, failure delivered at its join) and the process-ending report a
// plain program keeps.
int beans_fiber_is_root(BeansFiber* fiber);

// Ends the running fiber with a contained failure. The message is copied.
// Control never returns; the failure is delivered at the join. In F1 the
// fiber's C frames are abandoned, not unwound — running defers on the way
// out is compiler-emitted unwind code and lands with F2.
void beans_fiber_panic(const char* message) __attribute__((noreturn));

// Ends the running fiber as cancelled: the terminal step of a cancellation
// unwind. F2's emitted unwind code lands here after the defers have run;
// F1 tests call it directly after seeing a cancelled park verdict.
void beans_fiber_exit_cancelled(void) __attribute__((noreturn));

// Parks until `fiber` finishes and delivers how it ended: BEANS_FIBER_OK,
// _PANICKED, or _CANCELLED. The panic message (or "") is copied into
// message_out (message_cap bytes) when it is non-NULL. Exactly one join per
// fiber; a second join aborts — the compiler's Brew handle is single-use.
// Joining a finished fiber answers without parking. Same worker only.
int beans_fiber_join(BeansFiber* fiber, char* message_out, size_t message_cap);

// A fiber nobody joins is detached from the scheduler's point of view: its
// record is reclaimed when it finishes. The compiler's scope exit always
// joins, so this exists for the runtime's own roots, not for `brew`.
void beans_fiber_forget(BeansFiber* fiber);

// ---- introspection (tests, deadlock report) --------------------------------

// Fibers this worker still owns (running + ready + parked).
long long beans_worker_live(BeansWorker* worker);

#ifdef __cplusplus
}
#endif

#endif // BEANS_FIBER_H
