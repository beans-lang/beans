// Exercise the fatal reporter on mapped roots and unrelated memory faults.
#include "../runtime/beans_rt.c"

long long beans_class_parents[1] = {-1};
long long beans_deinit_sel = -1;

#if defined(BEANS_RT_FAULT_REPORT)
__attribute__((noinline)) static int exhaust_stack(int depth) {
    volatile unsigned char frame[1024];
    frame[0] = (unsigned char)depth;
    if (!depth) return frame[0];
    return frame[0] + exhaust_stack(depth - 1);
}

static void root_overflow(void* context) {
    (void)context;
    volatile int result = exhaust_stack(1000000);
    (void)result;
}

static void* foreign_fault(void* context) {
    *(volatile unsigned char*)context = 1;
    return NULL;
}
#endif

int main(int argc, char** argv) {
#if defined(BEANS_RT_FAULT_REPORT)
    if (argc != 2) return 2;
    if (strcmp(argv[1], "mapped") == 0)
        return beans_fiber_run_root(root_overflow, NULL, 64 * 1024);
    void* address = NULL;
    if (strcmp(argv[1], "protected") == 0) {
        address = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (address == MAP_FAILED) return 2;
    }
    if (strcmp(argv[1], "foreign") == 0) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, foreign_fault, address) != 0) return 2;
        pthread_join(thread, NULL);
    } else {
        *(volatile unsigned char*)address = 1;
    }
    return 2;
#else
    (void)argc;
    (void)argv;
    return 77;
#endif
}
