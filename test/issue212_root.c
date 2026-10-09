// Compiler roots must return to their caller after nested entry and child waits.
#include "../runtime/beans_fiber.h"
#include <assert.h>
#include <stdio.h>
#if defined(_WIN32)
#include <windows.h>
#endif

static void child(void* context) {
    int* steps = context;
    assert((*steps)++ == 0);
    beans_fiber_yield();
    assert((*steps)++ == 1);
}

static void nested(void* context) {
    assert(beans_fiber_is_root(beans_fiber_current()));
    assert((*(int*)context)++ == 2);
}

static void root(void* context) {
    assert(beans_fiber_is_root(beans_fiber_current()));
    BeansFiber* task = beans_fiber_spawn(beans_worker_current(), child,
                                        context, "child", 0);
    assert(task);
    assert(beans_fiber_join(task, NULL, 0) == BEANS_FIBER_OK);
    assert(beans_fiber_run_root(nested, context, 0) == 0);
}

static void check_root(void) {
    for (int attempt = 0; attempt < 2; attempt++) {
        int steps = 0;
        assert(beans_fiber_run_root(root, &steps, 8 * 1024 * 1024) == 0);
        assert(steps == 3);
        assert(beans_worker_current() == NULL);
    }
}

int main(void) {
    check_root();
#if defined(_WIN32)
    assert(!IsThreadAFiber());
    assert(ConvertThreadToFiber(NULL));
    check_root();
    assert(IsThreadAFiber());
    assert(ConvertFiberToThread());
#endif
    puts("ok compiler root returns and preserves its caller");
    return 0;
}
