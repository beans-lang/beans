long long beans_class_parents[1] = {-1};
long long beans_deinit_sel = -1;

#include "../runtime/beans_rt.c"

int main(void) {
    int ends[2];
    if (pipe(ends) != 0) return 1;

    // The four park outcomes stay distinct: invalid, valid token, duplicate,
    // and this executor's 64-entry limit.
    if (beans_reactor_note_park(-1) != -2) return 2;

    BMMap* mapping = beans_alloc(sizeof *mapping, 6 | (1LL << 3));
    memset(mapping, 0, sizeof *mapping);
    mapping->fd = ends[0];

    long long token = beans_reactor_note_park(mapping->fd);
    if (token <= 0) return 3;
    if (beans_reactor_note_park(mapping->fd) != 0) return 4;

    // Last-reference cleanup must tell the reactor before it closes the fd.
    beans_release(mapping);
    if (beans_reactor_park_dead(token) != 1) return 5;
    if (beans_reactor_forget_park(token) != 1) return 6;

    int fds[65];
    long long tokens[64];
    for (int i = 0; i < 65; i++) {
        fds[i] = dup(ends[1]);
        if (fds[i] < 0) return 7;
        if (i < 64) {
            tokens[i] = beans_reactor_note_park(fds[i]);
            if (tokens[i] <= 0) return 8;
        }
    }
    if (beans_reactor_note_park(fds[64]) != -1) return 9;
    for (int i = 0; i < 64; i++) {
        if (beans_reactor_forget_park(tokens[i]) != 1) return 10;
        close(fds[i]);
    }
    close(fds[64]);

    close(ends[1]);
    beans_reactor_shutdown_parks();
    return 0;
}
