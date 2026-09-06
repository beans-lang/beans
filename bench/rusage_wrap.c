// rusage_wrap.c — run a command and report its CPU time and peak memory, even
// when it is killed rather than allowed to finish.
//
// `/usr/bin/time -l` prints nothing but `real` when its child is terminated by
// a signal:
//
//     time: command terminated abnormally
//             3.41 real
//
// A benchmark server is always terminated by a signal — it serves until it is
// told to stop — so `time -l` can never report the one number the ledger is
// built on. wait4() carries the same rusage out whichever way the child died,
// so this wrapper reads it there instead.
//
//   rusage_wrap <statsfile> <command> [args...]
//
// SIGTERM and SIGINT are forwarded to the child, so stopping the wrapper stops
// the server and still produces the stats. The file is written with one
// key-value pair per line, and only after the child is reaped, so a reader that
// finds the file complete knows the numbers are final.
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

static volatile sig_atomic_t child_pid = 0;

static void forward(int sig) {
    if (child_pid > 0) kill(child_pid, sig);
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: rusage_wrap <statsfile> <command> [args...]\n");
        return 2;
    }
    const char* stats_path = argv[1];

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }
    if (pid == 0) {
        execvp(argv[2], &argv[2]);
        fprintf(stderr, "rusage_wrap: cannot run %s: %s\n", argv[2], strerror(errno));
        _exit(127);
    }
    child_pid = pid;

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = forward;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    int status = 0;
    struct rusage ru;
    memset(&ru, 0, sizeof ru);
    pid_t got;
    // EINTR is expected: the signal that stops the server interrupts this wait.
    do { got = wait4(pid, &status, 0, &ru); } while (got < 0 && errno == EINTR);
    if (got < 0) { perror("wait4"); return 2; }

    FILE* f = fopen(stats_path, "w");
    if (!f) { perror(stats_path); return 2; }
    fprintf(f, "user_sec %.6f\n",
            ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6);
    fprintf(f, "sys_sec %.6f\n",
            ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6);
    // ru_maxrss is bytes on macOS and kilobytes on Linux. Both are recorded
    // rather than converted, so a reader is never guessing which it has.
#if defined(__APPLE__)
    fprintf(f, "maxrss_bytes %ld\n", (long)ru.ru_maxrss);
#else
    fprintf(f, "maxrss_bytes %ld\n", (long)ru.ru_maxrss * 1024);
#endif
    fprintf(f, "minor_faults %ld\n", (long)ru.ru_minflt);
    fprintf(f, "major_faults %ld\n", (long)ru.ru_majflt);
    fprintf(f, "vol_ctx %ld\n", (long)ru.ru_nvcsw);
    fprintf(f, "invol_ctx %ld\n", (long)ru.ru_nivcsw);
    if (WIFSIGNALED(status)) fprintf(f, "signal %d\n", WTERMSIG(status));
    fprintf(f, "exit %d\n", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    fclose(f);
    return 0;
}
