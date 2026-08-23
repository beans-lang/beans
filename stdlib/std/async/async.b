package async

extern "C" fn beans_async_event_new() -> int
extern "C" fn beans_async_event_is_set(handle: int) -> int
extern "C" fn beans_async_event_set(handle: int) -> int
extern "C" fn beans_async_event_free(handle: int) -> int

async fn group_turn(status: int) -> unit {}

/// Cooperatively gives every runnable task one turn before this task resumes.
pub async fn yield_now() -> unit {}

/// Sleeps without blocking the executor thread.
pub async fn sleep_millis(duration_ms: int) -> unit {}

/// Sleeps until a std.time.monotonic_nanos() deadline.
pub async fn sleep_until(deadline_nanos: int) -> unit {}

/// A sticky cross-thread signal. Once set, every current and future wait
/// completes; repeated set calls are harmless.
pub class Event implements Send, Sync {
    handle: int

    pub fn init() {
        unsafe { self.handle = beans_async_event_new() }
    }

    pub fn set() {
        var signalled: int = 0
        unsafe { signalled = beans_async_event_set(self.handle) }
    }

    pub fn is_set() -> bool { return self._is_set() }

    fn _is_set() -> bool {
        var set: int = 0
        unsafe { set = beans_async_event_is_set(self.handle) }
        return set == 1
    }

    pub async fn wait() -> unit {}

    fn deinit() {
        var freed: int = 0
        unsafe { freed = beans_async_event_free(self.handle) }
        self.handle = 0
    }
}

/// A scope-bound set of dynamically started children. Task handles stay
/// compiler-internal; the group stores only their poll/take/cancel adapters.
pub unique class TaskGroup<T> {
    pollers: List<Option<fn() -> int>> = []
    takers: List<Option<fn() -> T>> = []
    cancellers: List<Option<fn()>> = []
    states: List<int> = []
    active_positions: List<int> = []
    completion_positions: List<int> = []
    spawn_ids: List<int> = []
    active_indices: List<int> = []
    completions: List<int> = []
    completion_head: int = 0
    next_spawn_id: int = 0
    active: int = 0

    pub fn init() {}

    priv fn _start_parts(poll: fn() -> int,
                         taker: fn() -> T,
                         cancel: fn()) {
        self.pollers.push(some(poll))
        self.takers.push(some(taker))
        self.cancellers.push(some(cancel))
        self.states.push(0)
        self.active_positions.push(self.active_indices.len())
        self.completion_positions.push(0 - 1)
        self.spawn_ids.push(self.next_spawn_id)
        self.next_spawn_id += 1
        self.active_indices.push(self.states.len() - 1)
        self.active += 1
    }

    priv fn _poll_pass() -> int {
        var runnable: bool = false
        var write: int = 0
        let count: int = self.active_indices.len()
        for read: int in 0..count {
            let index: int = self.active_indices[read]
            let poll: fn() -> int =
                self.pollers[index].expect("active TaskGroup row")
            let status: int = poll()
            if status == 1 {
                self.states[index] = 1
                self.active_positions[index] = 0 - 1
                self.completion_positions[index] =
                    self.completions.len()
                self.completions.push(index)
                self.active -= 1
            } else {
                self.active_indices[write] = index
                self.active_positions[index] = write
                write += 1
                if status == 2 { runnable = true }
            }
        }
        for self.active_indices.len() > write {
            self.active_indices.pop()
        }
        return if runnable { 2 } else { 0 }
    }

    priv fn _reset() {
        self.pollers.clear()
        self.takers.clear()
        self.cancellers.clear()
        self.states.clear()
        self.active_positions.clear()
        self.completion_positions.clear()
        self.spawn_ids.clear()
        self.active_indices.clear()
        self.completions.clear()
        self.completion_head = 0
        self.next_spawn_id = 0
        self.active = 0
    }

    // Removes one consumed row in O(1). The last live row fills its slot and
    // both index queues are patched through their recorded positions.
    priv fn _remove_row(index: int) {
        let last: int = self.states.len() - 1
        if index != last {
            self.pollers[index] = self.pollers[last]
            self.takers[index] = self.takers[last]
            self.cancellers[index] = self.cancellers[last]
            self.states[index] = self.states[last]
            self.active_positions[index] =
                self.active_positions[last]
            self.completion_positions[index] =
                self.completion_positions[last]
            self.spawn_ids[index] = self.spawn_ids[last]
            if self.active_positions[index] >= 0 {
                self.active_indices[
                    self.active_positions[index]] = index
            }
            if self.completion_positions[index] >= 0 {
                self.completions[
                    self.completion_positions[index]] = index
            }
        }
        self.pollers.pop()
        self.takers.pop()
        self.cancellers.pop()
        self.states.pop()
        self.active_positions.pop()
        self.completion_positions.pop()
        self.spawn_ids.pop()
        if self.states.len() == 0 { self.next_spawn_id = 0 }
    }

    // Keep the completion queue bounded while retaining O(1) amortized takes.
    priv fn _compact_completions() {
        if self.completion_head == self.completions.len() {
            self.completions.clear()
            self.completion_head = 0
            return
        }
        if self.completion_head * 2 < self.completions.len() { return }
        var write: int = 0
        for read: int in self.completion_head..self.completions.len() {
            let index: int = self.completions[read]
            self.completions[write] = index
            self.completion_positions[index] = write
            write += 1
        }
        for self.completions.len() > write { self.completions.pop() }
        self.completion_head = 0
    }

    priv fn _take_ready() -> Option<T> {
        for self.completion_head < self.completions.len() {
            let index: int = self.completions[self.completion_head]
            self.completion_head += 1
            if self.states[index] == 1 {
                self.completion_positions[index] = 0 - 1
                let taker: fn() -> T =
                    self.takers[index].expect("completed TaskGroup row")
                let value: T = taker()
                self._remove_row(index)
                self._compact_completions()
                return some(move value)
            }
        }
        if self.active == 0 { self._reset() }
        return none
    }

    priv fn _has_ready() -> bool {
        return self.completion_head < self.completions.len()
    }

    priv fn _active_count() -> int {
        return self.active
    }

    priv fn _take_all_ready() -> List<T> {
        var results: List<T> = []
        var order: List<int> = []
        for index: int in 0..self.states.len() { order.push(index) }
        let ids: List<int> = self.spawn_ids.clone()
        order.sort_by(fn(left: int, right: int) -> bool {
            return ids[left] < ids[right]
        })
        for index: int in order {
            let taker: fn() -> T =
                self.takers[index].expect("completed TaskGroup row")
            let value: T = taker()
            results.push(move value)
        }
        self._reset()
        return move results
    }

    /// Starts one exact async call. The compiler evaluates its arguments now
    /// and registers the cold child; the first poll is at the next suspension.
    pub fn start() {}

    /// Returns the next completion, using spawn order to break a tie.
    pub async fn next() -> Option<T> {
        if self._has_ready() { return self._take_ready() }
        if self._active_count() == 0 { return none }
        for {
            let status: int = self._poll_pass()
            if self._has_ready() { return self._take_ready() }
            if self._active_count() == 0 { return none }
            await group_turn(status)
        }
    }

    /// Polls each remaining member once and returns a queued completion.
    pub fn try_next() -> Option<T> {
        if self._has_ready() { return self._take_ready() }
        let status: int = self._poll_pass()
        return self._take_ready()
    }

    /// Waits for every current member and returns remaining values in spawn
    /// order. The group is empty and reusable afterwards.
    pub async fn wait_all() -> List<T> {
        for self._active_count() != 0 {
            let status: int = self._poll_pass()
            if self._active_count() != 0 { await group_turn(status) }
        }
        return self._take_all_ready()
    }

    /// Cancels active members newest-first, drops queued values, and reopens
    /// the empty group for reuse.
    pub fn cancel_all() {
        var index: int = self.states.len() - 1
        for index >= 0 {
            if self.states[index] == 0 {
                let cancel: fn() = self.cancellers[index].expect(
                    "active TaskGroup row")
                cancel()
            }
            index -= 1
        }
        self._reset()
    }

    fn deinit() {
        self.cancel_all()
    }
}
