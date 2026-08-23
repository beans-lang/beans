package async_rt

pub fn thread_join_unit_task(
    thread: Thread<unit>) -> Task<Result<unit>> {
    var status: List<int> = []
    return new Task<Result<unit>>(
        fn() -> int {
            let polled: int = thread._async_join_poll()
            if polled == 0 {
                var noted: int = 0
                unsafe { noted = beans_async_note_waiter() }
                return 0
            }
            status.push(polled)
            return 1
        },
        fn() -> Result<unit> {
            if status[0] < 0 {
                return err("thread was already joined or unusable", "closed")
            }
            if !thread._async_join_claim() {
                return err("thread join failed or the handle is unusable", "closed")
            }
            return ok(thread._async_join_take())
        },
        fn() {})
}
