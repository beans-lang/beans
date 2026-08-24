// Direct C tests for the fiber runtime core (runtime/beans_fiber.c) — the
// F1 gate of spec/CONCURRENCY.md. No compiler involved: every property the
// compiler will later lean on is pinned here first.
//
//   fiber_core            run every in-process test
//   fiber_core bench      print and gate the context-switch cost
//   fiber_core overflow   recurse off the stack (the script expects the
//                         guard report and exit 134)

#include "../runtime/beans_fiber.h"

#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int failures = 0;

#define CHECK(cond, what)                                                    \
    do {                                                                     \
        if (!(cond)) {                                                       \
            fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, what);    \
            failures += 1;                                                   \
        }                                                                    \
    } while (0)

// ---- basic completion and FIFO fairness ------------------------------------

static char order_log[64];
static void log_step(char mark) {
    size_t at = strlen(order_log);
    if (at + 1 < sizeof order_log) order_log[at] = mark;
}

static void fifo_fiber(void* arg) {
    char mark = (char)(size_t)arg;
    log_step(mark);
    beans_fiber_yield();
    log_step(mark);
    beans_fiber_yield();
    log_step(mark);
}

static void test_fifo(void) {
    order_log[0] = '\0';
    memset(order_log, 0, sizeof order_log);
    BeansWorker* worker = beans_worker_new();
    BeansFiber* a = beans_fiber_spawn(worker, fifo_fiber, (void*)'a', "a", 0);
    BeansFiber* b = beans_fiber_spawn(worker, fifo_fiber, (void*)'b', "b", 0);
    BeansFiber* c = beans_fiber_spawn(worker, fifo_fiber, (void*)'c', "c", 0);
    beans_fiber_forget(a);
    beans_fiber_forget(b);
    beans_fiber_forget(c);
    beans_worker_run(worker);
    // FIFO with yield-to-tail: perfect round robin, no starvation.
    CHECK(strcmp(order_log, "abcabcabc") == 0, order_log);
    CHECK(beans_worker_live(worker) == 0, "live after run");
    beans_worker_free(worker);
}

// ---- park / resume on one worker -------------------------------------------

static BeansFiber* parked_one = NULL;

static void parker(void* arg) {
    (void)arg;
    log_step('p');
    int verdict = beans_fiber_park();
    CHECK(verdict == BEANS_FIBER_WOKEN, "parker woken");
    log_step('P');
}

static void waker(void* arg) {
    (void)arg;
    log_step('w');
    beans_fiber_resume(parked_one);
    log_step('W');
}

static void test_park_resume(void) {
    memset(order_log, 0, sizeof order_log);
    BeansWorker* worker = beans_worker_new();
    parked_one = beans_fiber_spawn(worker, parker, NULL, "parker", 0);
    BeansFiber* w = beans_fiber_spawn(worker, waker, NULL, "waker", 0);
    beans_fiber_forget(parked_one);
    beans_fiber_forget(w);
    beans_worker_run(worker);
    CHECK(strcmp(order_log, "pwWP") == 0, order_log);
    beans_worker_free(worker);
}

// A resume that lands while the fiber is READY — before it ever parks — is
// latched, and the next park consumes it instead of sleeping.
static void early_wake_target(void* arg) {
    (void)arg;
    beans_fiber_yield(); // step aside so the source wakes us while READY
    int verdict = beans_fiber_park();
    CHECK(verdict == BEANS_FIBER_WOKEN, "latched wake consumed");
    log_step('t');
}

static void early_wake_source(void* arg) {
    beans_fiber_resume((BeansFiber*)arg); // target is READY, not parked
    log_step('s');
}

static void test_pending_wake(void) {
    memset(order_log, 0, sizeof order_log);
    BeansWorker* worker = beans_worker_new();
    BeansFiber* target =
        beans_fiber_spawn(worker, early_wake_target, NULL, "target", 0);
    BeansFiber* source =
        beans_fiber_spawn(worker, early_wake_source, target, "source", 0);
    beans_fiber_forget(target);
    beans_fiber_forget(source);
    beans_worker_run(worker);
    // Had the latch been lost, the target would sleep forever and the run
    // above would hang on its parked fiber.
    CHECK(strcmp(order_log, "st") == 0, order_log);
    beans_worker_free(worker);
}

// ---- join, panic containment, cancellation ---------------------------------

static void quiet_child(void* arg) { *(int*)arg += 1; }

static void loud_child(void* arg) {
    (void)arg;
    beans_fiber_panic("kettle burst");
}

static struct {
    BeansFiber* quiet;
    BeansFiber* loud;
    int touched;
    int checked;
} joinery;

static void join_parent(void* arg) {
    (void)arg;
    char message[128];
    int loud = beans_fiber_join(joinery.loud, message, sizeof message);
    CHECK(loud == BEANS_FIBER_PANICKED, "loud child panicked");
    CHECK(strcmp(message, "kettle burst") == 0, message);
    int quiet = beans_fiber_join(joinery.quiet, message, sizeof message);
    CHECK(quiet == BEANS_FIBER_OK, "quiet child fine");
    CHECK(message[0] == '\0', "no message from a clean child");
    CHECK(joinery.touched == 1, "quiet child really ran");
    joinery.checked = 1;
}

static void test_join_and_panic(void) {
    BeansWorker* worker = beans_worker_new();
    memset(&joinery, 0, sizeof joinery);
    BeansFiber* parent =
        beans_fiber_spawn(worker, join_parent, NULL, "parent", 0);
    joinery.quiet = beans_fiber_spawn(worker, quiet_child, &joinery.touched,
                                      "quiet", 0);
    joinery.loud = beans_fiber_spawn(worker, loud_child, NULL, "loud", 0);
    beans_fiber_forget(parent);
    beans_worker_run(worker);
    CHECK(joinery.checked == 1, "parent finished its checks");
    CHECK(beans_worker_live(worker) == 0, "no fiber leaked");
    beans_worker_free(worker);
}

static void cancellable(void* arg) {
    (void)arg;
    int verdict = beans_fiber_park();
    CHECK(verdict == BEANS_FIBER_PARK_CANCELLED, "park saw the cancel");
    beans_fiber_exit_cancelled();
}

static void cancel_parent(void* arg) {
    BeansFiber* child = (BeansFiber*)arg;
    beans_fiber_yield(); // let the child park first
    beans_fiber_cancel(child);
    int status = beans_fiber_join(child, NULL, 0);
    CHECK(status == BEANS_FIBER_CANCELLED, "join reports cancelled");
}

static void test_cancel(void) {
    BeansWorker* worker = beans_worker_new();
    BeansFiber* child =
        beans_fiber_spawn(worker, cancellable, NULL, "cancellable", 0);
    BeansFiber* parent =
        beans_fiber_spawn(worker, cancel_parent, child, "canceller", 0);
    beans_fiber_forget(parent);
    beans_worker_run(worker);
    beans_worker_free(worker);
}

// ---- churn: 10k fibers through spawn/yield/park/finish ---------------------

#define CHURN 10000

static _Atomic long long churn_done = 0;
static BeansFiber* churn_ring[CHURN];

static void churn_fiber(void* arg) {
    size_t index = (size_t)arg;
    beans_fiber_yield();
    // Ring wake: each fiber parks once and is resumed by its left neighbor
    // (the first never parks; it starts the wave after everyone parked).
    if (index != 0) {
        int verdict = beans_fiber_park();
        CHECK(verdict == BEANS_FIBER_WOKEN, "ring wake");
    } else {
        beans_fiber_yield();
    }
    if (index + 1 < CHURN) beans_fiber_resume(churn_ring[index + 1]);
    beans_fiber_yield();
    churn_done += 1;
}

static void test_churn(void) {
    BeansWorker* worker = beans_worker_new();
    for (size_t i = 0; i < CHURN; i++) {
        churn_ring[i] = beans_fiber_spawn(worker, churn_fiber, (void*)i,
                                          "churn", 64 * 1024);
        CHECK(churn_ring[i] != NULL, "spawn under churn");
        beans_fiber_forget(churn_ring[i]);
    }
    beans_worker_run(worker);
    CHECK(churn_done == CHURN, "every churn fiber finished");
    CHECK(beans_worker_live(worker) == 0, "churn drained");
    beans_worker_free(worker);
}

// ---- panic under load: some fibers die, the rest never notice --------------

#define STORM 1000

static struct {
    BeansFiber* fibers[STORM];
    int survived;
    int died;
    int done;
} storm;

static void storm_fiber(void* arg) {
    size_t index = (size_t)arg;
    beans_fiber_yield();
    if (index % 7 == 3) beans_fiber_panic("storm casualty");
    beans_fiber_yield();
}

static void storm_judge(void* arg) {
    (void)arg;
    char message[64];
    for (size_t i = 0; i < STORM; i++) {
        int status = beans_fiber_join(storm.fibers[i], message, sizeof message);
        if (i % 7 == 3) {
            CHECK(status == BEANS_FIBER_PANICKED, "casualty seen at join");
            CHECK(strcmp(message, "storm casualty") == 0, message);
            storm.died += 1;
        } else {
            CHECK(status == BEANS_FIBER_OK, "bystander survived");
            storm.survived += 1;
        }
    }
    storm.done = 1;
}

static void test_panic_storm(void) {
    BeansWorker* worker = beans_worker_new();
    memset(&storm, 0, sizeof storm);
    BeansFiber* judge = beans_fiber_spawn(worker, storm_judge, NULL, "judge", 0);
    for (size_t i = 0; i < STORM; i++)
        storm.fibers[i] =
            beans_fiber_spawn(worker, storm_fiber, (void*)i, "storm", 64 * 1024);
    beans_fiber_forget(judge);
    beans_worker_run(worker);
    CHECK(storm.done == 1, "judge finished");
    CHECK(storm.died == STORM / 7 + (STORM % 7 > 3 ? 1 : 0), "died count");
    CHECK(storm.survived + storm.died == STORM, "everyone accounted for");
    beans_worker_free(worker);
}

// ---- cross-thread resume ----------------------------------------------------

#define REMOTE 64

static struct {
    BeansFiber* fibers[REMOTE];
    _Atomic int parked;
    _Atomic int woken;
} remote;

static void remote_fiber(void* arg) {
    (void)arg;
    remote.parked += 1;
    int verdict = beans_fiber_park();
    CHECK(verdict == BEANS_FIBER_WOKEN, "remote wake");
    remote.woken += 1;
}

static void* remote_waker(void* arg) {
    (void)arg;
    // Wait until every fiber has at least entered its park attempt, then
    // wake them all from this foreign thread. The pending-wake latch makes
    // "not quite parked yet" safe, which is exactly what this test pins.
    while (remote.parked < REMOTE) sched_yield();
    for (int i = 0; i < REMOTE; i++) beans_fiber_resume(remote.fibers[i]);
    return NULL;
}

static void test_cross_thread(void) {
    BeansWorker* worker = beans_worker_new();
    memset((void*)&remote, 0, sizeof remote);
    for (int i = 0; i < REMOTE; i++) {
        remote.fibers[i] =
            beans_fiber_spawn(worker, remote_fiber, NULL, "remote", 0);
        beans_fiber_forget(remote.fibers[i]);
    }
    pthread_t thread;
    pthread_create(&thread, NULL, remote_waker, NULL);
    beans_worker_run(worker);
    pthread_join(thread, NULL);
    CHECK(remote.woken == REMOTE, "every remote fiber woke");
    beans_worker_free(worker);
}

// ---- bench: the < 50ns switch gate -----------------------------------------

#define PONG_ROUNDS 2000000LL

static BeansFiber* ping_fiber;
static BeansFiber* pong_fiber;

static void ping(void* arg) {
    (void)arg;
    for (long long i = 0; i < PONG_ROUNDS; i++) {
        beans_fiber_resume(pong_fiber);
        beans_fiber_park();
    }
    beans_fiber_resume(pong_fiber); // let the peer leave its last park
}

static void pong(void* arg) {
    (void)arg;
    for (long long i = 0; i < PONG_ROUNDS; i++) {
        beans_fiber_park();
        beans_fiber_resume(ping_fiber);
    }
    beans_fiber_park();
}

static void run_bench(void) {
    BeansWorker* worker = beans_worker_new();
    ping_fiber = beans_fiber_spawn(worker, ping, NULL, "ping", 0);
    pong_fiber = beans_fiber_spawn(worker, pong, NULL, "pong", 0);
    beans_fiber_forget(ping_fiber);
    beans_fiber_forget(pong_fiber);
    struct timespec begin, end;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    beans_worker_run(worker);
    clock_gettime(CLOCK_MONOTONIC, &end);
    double nanos = (double)(end.tv_sec - begin.tv_sec) * 1e9 +
                   (double)(end.tv_nsec - begin.tv_nsec);
    // Each round is one park and one resume on each side: four context
    // switches (two out, two in) per round pair — count the switches the
    // scheduler actually made: every park is a switch out and a switch in.
    double switches = (double)PONG_ROUNDS * 4.0;
    double each = nanos / switches;
    printf("switch %.1f ns (%lld rounds)\n", each, PONG_ROUNDS);
    beans_worker_free(worker);
}

// ---- guard-page overflow (script runs this in a child process) -------------

static long long deep(volatile long long n) {
    volatile long long pad[32];
    pad[0] = n;
    if (n <= 0) return pad[0];
    return deep(n - 1) + pad[0];
}

static void overflow_fiber(void* arg) {
    (void)arg;
    printf("%lld\n", deep(1 << 28));
}

static void run_overflow(void) {
    BeansWorker* worker = beans_worker_new();
    BeansFiber* f = beans_fiber_spawn(worker, overflow_fiber, NULL, "deep", 0);
    beans_fiber_forget(f);
    beans_worker_run(worker);
    printf("unreachable: the overflow never faulted\n");
}

// ---- bootstrap: the promoted thread is the root fiber ----------------------
//
// This is the shape a compiled Beans program has: main() is already running
// on the thread stack, promotes itself on the first brew, and parks in
// joins while the scheduler — on its own carved stack — runs the children.

static void boot_child(void* arg) {
    *(int*)arg += 1;
    beans_fiber_yield();
    *(int*)arg += 1;
}

// ---- sleep: deadline order and the timed idle wait -------------------------

static void nap_fiber(void* arg) {
    // arg packs {mark, nanos}: low byte the log mark, the rest the nap
    size_t packed = (size_t)arg;
    beans_fiber_sleep((long long)(packed >> 8));
    log_step((char)(packed & 0xff));
}

static void early_woken_sleeper(void* arg) {
    long long deadline_ns = *(long long*)arg;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long long before = (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    beans_fiber_sleep(deadline_ns);
    clock_gettime(CLOCK_MONOTONIC, &ts);
    long long after = (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    // a stray resume must not cut the sleep short
    CHECK(after - before >= deadline_ns, "sleep held through a stray wake");
    log_step('e');
}

static void stray_waker(void* arg) {
    beans_fiber_resume((BeansFiber*)arg); // sleeper re-parks: spurious
    log_step('k');
}

static void test_sleep(void) {
    memset(order_log, 0, sizeof order_log);
    BeansWorker* worker = beans_worker_new();
    // spawn slow first: completion must follow deadlines, not spawn order
    BeansFiber* slow = beans_fiber_spawn(
        worker, nap_fiber, (void*)(size_t)(('s') | (30000000ULL << 8)),
        "slow", 0);
    BeansFiber* fast = beans_fiber_spawn(
        worker, nap_fiber, (void*)(size_t)(('f') | (10000000ULL << 8)),
        "fast", 0);
    beans_fiber_forget(slow);
    beans_fiber_forget(fast);
    beans_worker_run(worker);
    CHECK(strcmp(order_log, "fs") == 0, order_log);

    // a resume landing mid-sleep is spurious: the fiber re-parks and the
    // full duration still holds
    memset(order_log, 0, sizeof order_log);
    long long nap = 15000000LL;
    BeansFiber* sleeper = beans_fiber_spawn(
        worker, early_woken_sleeper, &nap, "sleeper", 0);
    BeansFiber* stray = beans_fiber_spawn(
        worker, stray_waker, sleeper, "stray", 0);
    beans_fiber_forget(sleeper);
    beans_fiber_forget(stray);
    beans_worker_run(worker);
    CHECK(strcmp(order_log, "ke") == 0, order_log);
    beans_worker_free(worker);
}

// ---- the netpoller ---------------------------------------------------------
// A fiber that must wait for a descriptor parks in its worker's kernel
// poller. Pinned here: the park-until-readable handoff between two fibers
// of one worker, the deadline answering on a silent fd, the deadlock
// report staying quiet while an io waiter exists (the kernel can wake
// it), and the inbox kick reaching a worker blocked inside the poller.

static long long np_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

typedef struct {
    int rfd;
    int wfd;
    long long got;
} NetpollProbe;

static void np_reader(void* arg) {
    NetpollProbe* probe = (NetpollProbe*)arg;
    long long verdict = beans_fiber_wait_io(probe->rfd, 0, -1);
    if (verdict != 0) {
        probe->got = -100 - verdict;
        return;
    }
    char byte = 0;
    if (read(probe->rfd, &byte, 1) == 1) probe->got = byte;
    log_step('r');
}

static void np_late_writer(void* arg) {
    NetpollProbe* probe = (NetpollProbe*)arg;
    beans_fiber_sleep(10000000LL); // the reader parks first
    char byte = 42;
    if (write(probe->wfd, &byte, 1) != 1) probe->got = -1;
    log_step('w');
}

static void np_timeout_prober(void* arg) {
    NetpollProbe* probe = (NetpollProbe*)arg;
    probe->got = beans_fiber_wait_io(probe->rfd, 0, 25);
}

static void np_kick_helper(void* arg) {
    NetpollProbe* probe = (NetpollProbe*)arg;
    beans_fiber_park(); // until the cross-thread resume below
    char byte = 9;
    if (write(probe->wfd, &byte, 1) != 1) probe->got = -1;
    log_step('k');
}

static void* np_cross_resume(void* arg) {
    struct timespec pause = { 0, 20000000L };
    nanosleep(&pause, NULL);
    beans_fiber_resume((BeansFiber*)arg);
    return NULL;
}

static int np_no_wake(void) { return 0; }

static void test_netpoll(void) {
    if (!beans_fiber_netpoll()) {
        fprintf(stderr, "netpoll unavailable here; skipped\n");
        return;
    }
    int fds[2];
    CHECK(pipe(fds) == 0, "pipe");
    NetpollProbe probe = { fds[0], fds[1], 0 };
    BeansWorker* worker = beans_worker_new();

    // park-until-readable between two fibers of one worker — with the
    // hopeless-idle check armed: an io waiter must keep the report quiet
    memset(order_log, 0, sizeof order_log);
    beans_fiber_set_may_wake(np_no_wake);
    BeansFiber* reader =
        beans_fiber_spawn(worker, np_reader, &probe, "reader", 0);
    BeansFiber* writer =
        beans_fiber_spawn(worker, np_late_writer, &probe, "writer", 0);
    beans_fiber_forget(reader);
    beans_fiber_forget(writer);
    beans_worker_run(worker);
    beans_fiber_set_may_wake(NULL);
    CHECK(probe.got == 42, "the reader woke with the written byte");
    CHECK(strcmp(order_log, "wr") == 0, order_log);

    // a deadline on a silent fd answers timeout, promptly and not early
    probe.got = 0;
    long long start = np_now();
    BeansFiber* prober =
        beans_fiber_spawn(worker, np_timeout_prober, &probe, "prober", 0);
    beans_fiber_forget(prober);
    beans_worker_run(worker);
    long long took = np_now() - start;
    CHECK(probe.got == 1, "the silent wait answered timeout");
    CHECK(took >= 20000000LL, "the timeout came no earlier than asked");
    CHECK(took < 2000000000LL, "the timeout did not hang");

    // the kick: the worker blocks in the poller (an io waiter exists), a
    // plain thread resumes an ordinarily-parked fiber — the inbox post
    // must reach through the poller wait
    memset(order_log, 0, sizeof order_log);
    probe.got = 0;
    BeansFiber* io_waiter =
        beans_fiber_spawn(worker, np_reader, &probe, "io-waiter", 0);
    BeansFiber* helper =
        beans_fiber_spawn(worker, np_kick_helper, &probe, "helper", 0);
    beans_fiber_forget(io_waiter);
    beans_fiber_forget(helper);
    pthread_t outsider;
    pthread_create(&outsider, NULL, np_cross_resume, helper);
    beans_worker_run(worker);
    pthread_join(outsider, NULL);
    CHECK(probe.got == 9, "the kicked worker ran the helper, freeing the reader");
    CHECK(strcmp(order_log, "kr") == 0, order_log);

    close(fds[0]);
    close(fds[1]);
    beans_worker_free(worker);
}

static void test_bootstrap(void) {
    BeansWorker* worker = beans_worker_bootstrap();
    CHECK(worker != NULL, "bootstrap");
    CHECK(beans_fiber_current() != NULL, "the caller became the root fiber");
    CHECK(beans_worker_bootstrap() == worker, "bootstrap is idempotent");

    int hits = 0;
    BeansFiber* a = beans_fiber_spawn(worker, boot_child, &hits, "boot-a", 0);
    int status = beans_fiber_join(a, NULL, 0);
    CHECK(status == BEANS_FIBER_OK, "root joined a child");
    CHECK(hits == 2, "child ran across its yield");

    BeansFiber* b = beans_fiber_spawn(worker, boot_child, &hits, "boot-b", 0);
    beans_fiber_forget(b);
    while (beans_worker_live(worker) > 1) {
        int verdict = beans_fiber_yield();
        CHECK(verdict == BEANS_FIBER_WOKEN, "root yield");
    }
    CHECK(hits == 4, "forgotten child still ran to completion");
}

// ---- deadlock report (subprocess mode) -------------------------------------

static void forever_parker(void* arg) {
    (void)arg;
    beans_fiber_park(); // nobody will ever resume this
}

static int hopeless(void) { return 0; }

static void run_deadlock(void) {
    beans_fiber_set_may_wake(hopeless);
    BeansWorker* worker = beans_worker_new();
    BeansFiber* fiber =
        beans_fiber_spawn(worker, forever_parker, NULL, "hopeless", 0);
    beans_fiber_forget(fiber);
    beans_worker_run(worker); // must report and _exit(3), never return
    fprintf(stderr, "worker returned from a hopeless park\n");
}

int main(int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "bench") == 0) {
        run_bench();
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "overflow") == 0) {
        run_overflow();
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "deadlock") == 0) {
        run_deadlock();
        return 1;
    }
    test_fifo();
    test_park_resume();
    test_pending_wake();
    test_join_and_panic();
    test_cancel();
    test_churn();
    test_panic_storm();
    test_cross_thread();
    test_sleep();
    test_netpoll();
    // Last: it permanently promotes this thread, the way a real program is.
    test_bootstrap();
    if (failures == 0) printf("ok fiber core\n");
    else printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
