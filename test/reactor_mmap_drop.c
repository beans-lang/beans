long long beans_class_parents[1] = {-1};
long long beans_deinit_sel = -1;

#include "../runtime/beans_rt.c"
#include <sys/resource.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int fd;
    int ready;
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
    long long token = beans_reactor_note_park(shared->fd);
    pthread_mutex_lock(&shared->lock);
    shared->ready++;
    pthread_cond_broadcast(&shared->changed);
    while (!shared->go)
        pthread_cond_wait(&shared->changed, &shared->lock);
    pthread_mutex_unlock(&shared->lock);
    shared->result[arg->index] =
        token > 0 && beans_reactor_park_state(token) == 2 &&
        beans_reactor_finish_park(token) == 1 &&
        beans_reactor_shutdown_parks() == 1;
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
        if (beans_reactor_arm_park(dying, poller, wake, 0) != 0 ||
            beans_reactor_park_state(dying) != 2 ||
            beans_reactor_finish_park(dying) != 1)
            return 44;
        beans_reactor_close_end(old_fd);
        close(current[1]);
        long long live = beans_reactor_note_park(next[0]);
        if (live <= 0 ||
            beans_reactor_arm_park(live, poller, wake, 0) != 1 ||
            write(next[1], "x", 1) != 1)
            return 45;
        BRes one = beans_poll_wait(poller, wake_read, 1, 1000);
        if (one.err) return 46;
        BList* event = (BList*)one.val;
        if (rt_load_le((char*)event->data, 8) != 1) return 47;
        long long event_token = (long long)rt_load_le(
            (char*)event->data + 8, 8);
        if (event_token != live || beans_reactor_mark_ready(event_token) != 1 ||
            beans_reactor_finish_park(live) != 1)
            return 48;
        beans_release(event);
        char byte;
        if (read(next[0], &byte, 1) != 1) return 49;
        current[0] = next[0];
        current[1] = next[1];
    }
    beans_reactor_close_begin(current[0]);
    close(current[0]);
    beans_reactor_close_end(current[0]);
    close(current[1]);
    poll_closed = beans_poll_close(poller, wake_read, wake);
    if (poll_closed.err) return 50;
    beans_release(triple);

    // A queued token from A cannot ready B after the fd and slot are reused.
    int a = dup(ends[1]);
    if (a < 0) return 18;
    long long old = beans_reactor_note_park(a);
    if (old <= 0 || beans_reactor_finish_park(old) != 1) return 19;
    close(a);
    int b = dup(ends[1]);
    if (b < 0) return 20;
    long long fresh = beans_reactor_note_park(b);
    if (fresh <= 0 || fresh == old) return 21;
    if (beans_reactor_mark_ready(old) != 0 ||
        beans_reactor_park_state(fresh) != 0)
        return 22;
    if (beans_reactor_mark_ready(fresh) != 1 ||
        beans_reactor_park_state(fresh) != 1)
        return 23;
    if (beans_reactor_finish_park(fresh) != 1) return 24;
    close(b);

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
    pthread_mutex_unlock(&shared.lock);
    beans_reactor_close_begin(shared_ends[0]);
    close(shared_ends[0]);
    beans_reactor_close_end(shared_ends[0]);
    pthread_mutex_lock(&shared.lock);
    shared.go = 1;
    pthread_cond_broadcast(&shared.changed);
    pthread_mutex_unlock(&shared.lock);
    pthread_join(workers[0], NULL);
    pthread_join(workers[1], NULL);
    if (!shared.result[0] || !shared.result[1]) return 32;
    pthread_cond_destroy(&shared.changed);
    pthread_mutex_destroy(&shared.lock);
    close(shared_ends[1]);

    close(ends[1]);
    return 0;
}
