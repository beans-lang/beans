long long beans_class_parents[1] = {-1};
long long beans_deinit_sel = -1;

#include "../runtime/beans_rt.c"
#include <sys/resource.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int fd;
    int ready;
    int waiting;
    int go;
    int result[2];
} SharedClose;

typedef struct {
    SharedClose* shared;
    int index;
} SharedCloseArg;

static void* same_fd_owner(void* raw) {
    SharedCloseArg* arg = raw;
    SharedClose* shared = arg->shared;
    BRes opened = beans_poll_open();
    if (opened.err) return NULL;
    BList* triple = (BList*)opened.val;
    long long poller = (long long)rt_load_le((char*)triple->data, 8);
    long long wake_read =
        (long long)rt_load_le((char*)triple->data + 8, 8);
    long long wake =
        (long long)rt_load_le((char*)triple->data + 16, 8);
    long long token = beans_reactor_note_park(shared->fd);
    int armed = token > 0 &&
        beans_reactor_arm_park(token, poller, wake, 0) == 1;
    pthread_mutex_lock(&shared->lock);
    shared->ready++;
    pthread_cond_broadcast(&shared->changed);
    while (!shared->go)
        pthread_cond_wait(&shared->changed, &shared->lock);
    shared->waiting++;
    pthread_cond_broadcast(&shared->changed);
    pthread_mutex_unlock(&shared->lock);
    BRes waited = beans_poll_wait(poller, wake_read, 1, 1000);
    int woke = !waited.err;
    if (woke) beans_release((BList*)waited.val);
    shared->result[arg->index] =
        armed && woke && beans_reactor_park_state(token) == 2 &&
        beans_reactor_finish_park(token) == 1 &&
        beans_reactor_shutdown_parks() == 1;
    BRes closed = beans_poll_close(poller, wake_read, wake);
    if (closed.err) shared->result[arg->index] = 0;
    beans_release(triple);
    return NULL;
}

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int fd;
    long long token;
    long long poller;
    long long wake;
    int inside;
    int close_started;
} ArmBarrier;

static ArmBarrier* active_arm_barrier;

static void arm_barrier_hook(long long fd) {
    ArmBarrier* barrier = active_arm_barrier;
    if (!barrier || barrier->fd != fd) return;
    pthread_mutex_lock(&barrier->lock);
    barrier->inside = 1;
    pthread_cond_broadcast(&barrier->changed);
    while (!barrier->close_started)
        pthread_cond_wait(&barrier->changed, &barrier->lock);
    pthread_mutex_unlock(&barrier->lock);
}

static void* arm_barrier_close(void* raw) {
    ArmBarrier* barrier = raw;
    pthread_mutex_lock(&barrier->lock);
    while (!barrier->inside)
        pthread_cond_wait(&barrier->changed, &barrier->lock);
    barrier->close_started = 1;
    pthread_cond_broadcast(&barrier->changed);
    pthread_mutex_unlock(&barrier->lock);
    beans_reactor_close_begin(barrier->fd);
    close(barrier->fd);
    beans_reactor_close_end(barrier->fd);
    return NULL;
}

static int allocation_failure_case(void) {
    int ends[2];
    if (pipe(ends) != 0) return 90;
    long long token = beans_reactor_note_park(ends[0]);
    close(ends[0]);
    close(ends[1]);
    // Failure at owner, slot, or either initial hash allocation must publish
    // no half-row and must report the recoverable reservation failure.
    if (token != -1) return 91;
    beans_reactor_shutdown_parks();
    return 0;
}

int main(void) {
    if (getenv("BEANS_TEST_PARK_ALLOC_FAIL_AT"))
        return allocation_failure_case();

    int ends[2];
    if (pipe(ends) != 0) return 1;
    if (beans_reactor_note_park(-1) != -2) return 2;

    BMMap* mapping = beans_alloc(sizeof *mapping, 6 | (1LL << 3));
    memset(mapping, 0, sizeof *mapping);
    mapping->fd = ends[0];

    long long token = beans_reactor_note_park(mapping->fd);
    if (token <= 0) return 3;
    if (beans_reactor_note_park(mapping->fd) != 0) return 4;

    // Last-reference cleanup brackets its physical close. The exact token is
    // DEAD and finish never touches a later user of the descriptor number.
    beans_release(mapping);
    if (beans_reactor_park_state(token) != 2) return 5;
    if (beans_reactor_finish_park(token) != 1) return 6;

    // Growth failures are transactional even with live rows. Fail the slot
    // expansion, then each half of the hash rehash, and prove every earlier
    // token remains live before a retry succeeds and the set drains.
    enum { OOM_ROWS = 24 };
    int oom_fds[OOM_ROWS][2];
    long long oom_tokens[OOM_ROWS];
    for (int i = 0; i < OOM_ROWS; i++) {
        if (pipe(oom_fds[i]) != 0) return 60;
        oom_tokens[i] = 0;
    }
    for (int i = 0; i < 16; i++) {
        oom_tokens[i] = beans_reactor_note_park(oom_fds[i][0]);
        if (oom_tokens[i] <= 0) return 61;
    }
    beans_reactor_test_fail_allocation(1);
    if (beans_reactor_note_park(oom_fds[16][0]) != -1) return 62;
    for (int i = 0; i < 16; i++)
        if (beans_reactor_park_state(oom_tokens[i]) != 0) return 63;
    beans_reactor_test_fail_allocation(0);
    oom_tokens[16] = beans_reactor_note_park(oom_fds[16][0]);
    if (oom_tokens[16] <= 0) return 64;
    for (int i = 17; i < 23; i++) {
        oom_tokens[i] = beans_reactor_note_park(oom_fds[i][0]);
        if (oom_tokens[i] <= 0) return 65;
    }
    beans_reactor_test_fail_allocation(1);
    if (beans_reactor_note_park(oom_fds[23][0]) != -1) return 66;
    beans_reactor_test_fail_allocation(2);
    if (beans_reactor_note_park(oom_fds[23][0]) != -1) return 67;
    for (int i = 0; i < 23; i++)
        if (beans_reactor_park_state(oom_tokens[i]) != 0) return 68;
    beans_reactor_test_fail_allocation(0);
    oom_tokens[23] = beans_reactor_note_park(oom_fds[23][0]);
    if (oom_tokens[23] <= 0) return 69;
    for (int i = 0; i < OOM_ROWS; i++) {
        if (beans_reactor_finish_park(oom_tokens[i]) != 1) return 70;
        close(oom_fds[i][0]);
        close(oom_fds[i][1]);
    }

    enum { SCALE = 10000 };
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < 25000) {
        rlim_t wanted = limit.rlim_max < 25000 ? limit.rlim_max : 25000;
        limit.rlim_cur = wanted;
        (void)setrlimit(RLIMIT_NOFILE, &limit);
    }
    BRes opened = beans_poll_open();
    if (opened.err) return 7;
    BList* triple = (BList*)opened.val;
    long long poller = (long long)rt_load_le((char*)triple->data, 8);
    long long wake_read =
        (long long)rt_load_le((char*)triple->data + 8, 8);
    long long wake =
        (long long)rt_load_le((char*)triple->data + 16, 8);
    int* fds = calloc(SCALE * 2, sizeof *fds);
    long long* tokens = calloc(SCALE, sizeof *tokens);
    if (!fds || !tokens) return 8;
    for (int i = 0; i < SCALE; i++) {
        if (pipe(&fds[i * 2]) != 0) return 9;
        tokens[i] = beans_reactor_note_park(fds[i * 2]);
        if (tokens[i] <= 0 ||
            beans_reactor_arm_park(tokens[i], poller, wake, 0) != 1)
            return 10;
    }
    // Cross every requested scale point while all 10k rows are armed in the
    // real kernel poller, then make all of them ready together.
    if (beans_reactor_park_state(tokens[64]) != 0 ||
        beans_reactor_park_state(tokens[255]) != 0 ||
        beans_reactor_park_state(tokens[1023]) != 0 ||
        beans_reactor_park_state(tokens[9999]) != 0)
        return 11;
    for (int i = 0; i < SCALE; i++) {
        if (write(fds[i * 2 + 1], "x", 1) != 1) return 12;
    }
    int drained = 0;
    while (drained < SCALE) {
        BRes waited = beans_poll_wait(poller, wake_read, 64, 1000);
        if (waited.err) return 13;
        BList* events = (BList*)waited.val;
        long long count =
            (long long)rt_load_le((char*)events->data, 8);
        if (count <= 0 || count > 64) return 14;
        for (long long i = 0; i < count; i++) {
            long long ready = (long long)rt_load_le(
                (char*)events->data + 8 + i * 16, 8);
            if (beans_reactor_mark_ready(ready) != 1 ||
                beans_reactor_park_state(ready) != 1 ||
                beans_reactor_finish_park(ready) != 1)
                return 15;
            drained++;
        }
        beans_release(events);
    }
    if (drained != SCALE) return 16;
    for (int i = 0; i < SCALE; i++) {
        close(fds[i * 2]);
        close(fds[i * 2 + 1]);
    }
    free(fds);
    free(tokens);
    BRes poll_closed = beans_poll_close(poller, wake_read, wake);
    if (poll_closed.err) return 17;
    beans_release(triple);

    // Deterministically hit the old note -> close -> fd reuse -> arm window.
    // The tombstone rejects A's arm while the reused number already names B;
    // B then arms and wakes normally. Repeat to churn slots and fd reuse.
    opened = beans_poll_open();
    if (opened.err) return 40;
    triple = (BList*)opened.val;
    poller = (long long)rt_load_le((char*)triple->data, 8);
    wake_read = (long long)rt_load_le((char*)triple->data + 8, 8);
    wake = (long long)rt_load_le((char*)triple->data + 16, 8);
    int current[2];
    if (pipe(current) != 0) return 41;
    for (int round = 0; round < 1024; round++) {
        long long dying = beans_reactor_note_park(current[0]);
        if (dying <= 0) return 42;
        int old_fd = current[0];
        beans_reactor_close_begin(old_fd);
        close(old_fd);
        int next[2];
        if (pipe(next) != 0 || next[0] != old_fd) return 43;
        if (beans_reactor_note_park(next[0]) != -2) return 44;
        if (beans_reactor_arm_park(dying, poller, wake, 0) != 0 ||
            beans_reactor_park_state(dying) != 2 ||
            beans_reactor_finish_park(dying) != 1)
            return 45;
        beans_reactor_close_end(old_fd);
        close(current[1]);
        long long live = beans_reactor_note_park(next[0]);
        if (live <= 0 ||
            beans_reactor_arm_park(live, poller, wake, 0) != 1 ||
            write(next[1], "x", 1) != 1)
            return 46;
        BRes one = beans_poll_wait(poller, wake_read, 1, 1000);
        if (one.err) return 47;
        BList* event = (BList*)one.val;
        if (rt_load_le((char*)event->data, 8) != 1) return 48;
        long long event_token = (long long)rt_load_le(
            (char*)event->data + 8, 8);
        if (event_token != live || beans_reactor_mark_ready(event_token) != 1 ||
            beans_reactor_finish_park(live) != 1)
            return 49;
        beans_release(event);
        char byte;
        if (read(next[0], &byte, 1) != 1) return 50;
        current[0] = next[0];
        current[1] = next[1];
    }
    beans_reactor_close_begin(current[0]);
    close(current[0]);
    beans_reactor_close_end(current[0]);
    close(current[1]);

    // Hold arm inside the registry lock while another thread begins close.
    // Arm must finish installing the stable token first; close then acquires
    // that same lock, tombstones the exact row, and wakes it DEAD.
    int barrier_fds[2];
    if (pipe(barrier_fds) != 0) return 52;
    ArmBarrier barrier;
    memset(&barrier, 0, sizeof barrier);
    pthread_mutex_init(&barrier.lock, NULL);
    pthread_cond_init(&barrier.changed, NULL);
    barrier.fd = barrier_fds[0];
    barrier.poller = poller;
    barrier.wake = wake;
    barrier.token = beans_reactor_note_park(barrier.fd);
    if (barrier.token <= 0) return 53;
    active_arm_barrier = &barrier;
    beans_reactor_test_set_arm_hook(arm_barrier_hook);
    pthread_t closer;
    if (pthread_create(&closer, NULL, arm_barrier_close, &barrier) != 0)
        return 54;
    int armed = beans_reactor_arm_park(
        barrier.token, poller, wake, 0);
    beans_reactor_test_set_arm_hook(NULL);
    active_arm_barrier = NULL;
    pthread_join(closer, NULL);
    if (armed != 1 || beans_reactor_park_state(barrier.token) != 2 ||
        beans_reactor_finish_park(barrier.token) != 1)
        return 55;
    pthread_cond_destroy(&barrier.changed);
    pthread_mutex_destroy(&barrier.lock);
    close(barrier_fds[1]);

    poll_closed = beans_poll_close(poller, wake_read, wake);
    if (poll_closed.err) return 56;
    beans_release(triple);

    // Keep a real kernel event for A unconsumed while its fd and token slot
    // are reused by B. The copied old token is ignored; only B's later event
    // can make B ready.
    opened = beans_poll_open();
    if (opened.err) return 71;
    triple = (BList*)opened.val;
    poller = (long long)rt_load_le((char*)triple->data, 8);
    wake_read = (long long)rt_load_le((char*)triple->data + 8, 8);
    wake = (long long)rt_load_le((char*)triple->data + 16, 8);
    int queued_a[2];
    if (pipe(queued_a) != 0) return 72;
    long long old = beans_reactor_note_park(queued_a[0]);
    if (old <= 0 ||
        beans_reactor_arm_park(old, poller, wake, 0) != 1 ||
        write(queued_a[1], "a", 1) != 1)
        return 73;
    BRes queued = beans_poll_wait(poller, wake_read, 1, 1000);
    if (queued.err) return 74;
    BList* queued_events = (BList*)queued.val;
    if (rt_load_le((char*)queued_events->data, 8) != 1) return 75;
    long long queued_token = (long long)rt_load_le(
        (char*)queued_events->data + 8, 8);
    if (queued_token != old || beans_reactor_finish_park(old) != 1)
        return 76;
    int reused_fd = queued_a[0];
    beans_reactor_close_begin(reused_fd);
    close(reused_fd);
    int queued_b[2];
    if (pipe(queued_b) != 0 || queued_b[0] != reused_fd) return 77;
    beans_reactor_close_end(reused_fd);
    close(queued_a[1]);
    long long fresh = beans_reactor_note_park(queued_b[0]);
    if (fresh <= 0 || fresh == old ||
        beans_reactor_arm_park(fresh, poller, wake, 0) != 1)
        return 78;
    if (beans_reactor_mark_ready(queued_token) != 0 ||
        beans_reactor_park_state(fresh) != 0)
        return 79;
    beans_release(queued_events);
    if (write(queued_b[1], "b", 1) != 1) return 80;
    BRes fresh_wait = beans_poll_wait(poller, wake_read, 1, 1000);
    if (fresh_wait.err) return 81;
    BList* fresh_events = (BList*)fresh_wait.val;
    if (rt_load_le((char*)fresh_events->data, 8) != 1) return 82;
    long long fresh_event = (long long)rt_load_le(
        (char*)fresh_events->data + 8, 8);
    if (fresh_event != fresh ||
        beans_reactor_mark_ready(fresh_event) != 1 ||
        beans_reactor_finish_park(fresh) != 1)
        return 83;
    beans_release(fresh_events);
    beans_reactor_close_begin(queued_b[0]);
    close(queued_b[0]);
    beans_reactor_close_end(queued_b[0]);
    close(queued_b[1]);
    poll_closed = beans_poll_close(poller, wake_read, wake);
    if (poll_closed.err) return 84;
    beans_release(triple);

    // A slot at generation wrap is retired forever instead of aliasing an old
    // token. The next reservation must come from another slot.
    int wrap_fd = dup(ends[1]);
    if (wrap_fd < 0) return 19;
    long long before_wrap = beans_reactor_note_park(wrap_fd);
    if (before_wrap <= 0 || beans_reactor_finish_park(before_wrap) != 1)
        return 20;
    long long wrap_slot =
        (long long)(((unsigned long long)before_wrap >> 32) - 1);
    if (beans_reactor_test_set_generation(wrap_slot, UINT32_MAX) != 1)
        return 21;
    long long wrapping = beans_reactor_note_park(wrap_fd);
    if (wrapping <= 0 || beans_reactor_finish_park(wrapping) != 1)
        return 22;
    long long after_wrap = beans_reactor_note_park(wrap_fd);
    if (after_wrap <= 0 ||
        (long long)(((unsigned long long)after_wrap >> 32) - 1) == wrap_slot)
        return 23;
    if (beans_reactor_finish_park(after_wrap) != 1) return 24;
    close(wrap_fd);

    // Shutdown removes every row and the stable owner. A fresh executor gets
    // a new owner shell and old tokens remain stale.
    int shutdown_fd = dup(ends[1]);
    if (shutdown_fd < 0) return 25;
    long long abandoned = beans_reactor_note_park(shutdown_fd);
    if (abandoned <= 0 || beans_reactor_shutdown_parks() != 1) return 26;
    if (beans_reactor_park_state(abandoned) != -1) return 27;
    long long next_owner = beans_reactor_note_park(shutdown_fd);
    if (next_owner <= 0 || beans_reactor_mark_ready(abandoned) != 0)
        return 28;
    if (beans_reactor_finish_park(next_owner) != 1 ||
        beans_reactor_shutdown_parks() != 1)
        return 29;
    close(shutdown_fd);

    // Two executor owners may watch one fd. One close marks both exact rows
    // DEAD; neither owner is confused with the other.
    int shared_ends[2];
    if (pipe(shared_ends) != 0) return 30;
    SharedClose shared;
    memset(&shared, 0, sizeof shared);
    pthread_mutex_init(&shared.lock, NULL);
    pthread_cond_init(&shared.changed, NULL);
    shared.fd = shared_ends[0];
    SharedCloseArg args[2] = {{&shared, 0}, {&shared, 1}};
    pthread_t workers[2];
    if (pthread_create(&workers[0], NULL, same_fd_owner, &args[0]) != 0 ||
        pthread_create(&workers[1], NULL, same_fd_owner, &args[1]) != 0)
        return 31;
    pthread_mutex_lock(&shared.lock);
    while (shared.ready != 2)
        pthread_cond_wait(&shared.changed, &shared.lock);
    shared.go = 1;
    pthread_cond_broadcast(&shared.changed);
    while (shared.waiting != 2)
        pthread_cond_wait(&shared.changed, &shared.lock);
    pthread_mutex_unlock(&shared.lock);
    beans_reactor_close_begin(shared_ends[0]);
    close(shared_ends[0]);
    beans_reactor_close_end(shared_ends[0]);
    pthread_join(workers[0], NULL);
    pthread_join(workers[1], NULL);
    if (!shared.result[0] || !shared.result[1]) return 32;
    pthread_cond_destroy(&shared.changed);
    pthread_mutex_destroy(&shared.lock);
    close(shared_ends[1]);

    close(ends[1]);
    return 0;
}
