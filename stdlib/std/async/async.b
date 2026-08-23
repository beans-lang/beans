package async

/// Cooperatively gives every runnable task one turn before this task resumes.
pub async fn yield_now() {}

/// A scope-bound set of dynamically started children. Task handles stay
/// compiler-internal; the group stores only their poll/take/cancel adapters.
pub unique class TaskGroup<T> {
    pollers: List<fn() -> int> = []
    takers: List<fn() -> T> = []
    cancellers: List<fn()> = []
    states: List<int> = []
    active_indices: List<int> = []
    completions: List<int> = []
    completion_head: int = 0
    active: int = 0

    pub fn init() {}

    priv fn _start_parts(poll: fn() -> int,
                         taker: fn() -> T,
                         cancel: fn()) {
        self.pollers.push(poll)
        self.takers.push(taker)
        self.cancellers.push(cancel)
        self.states.push(0)
        self.active_indices.push(self.states.len() - 1)
        self.active += 1
    }

    priv fn _poll_pass() -> int {
        var runnable: bool = false
        var write: int = 0
        let count: int = self.active_indices.len()
        for read: int in 0..count {
            let index: int = self.active_indices[read]
            let poll: fn() -> int = self.pollers[index]
            let status: int = poll()
            if status == 1 {
                self.states[index] = 1
                self.completions.push(index)
                self.active -= 1
            } else {
                self.active_indices[write] = index
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
        self.active_indices.clear()
        self.completions.clear()
        self.completion_head = 0
        self.active = 0
    }

    priv fn _take_ready() -> Option<T> {
        for self.completion_head < self.completions.len() {
            let index: int = self.completions[self.completion_head]
            self.completion_head += 1
            if self.states[index] == 1 {
                self.states[index] = 2
                let taker: fn() -> T = self.takers[index]
                let value: T = taker()
                if self.active == 0 &&
                   self.completion_head == self.completions.len() {
                    self._reset()
                }
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
        for index: int in 0..self.states.len() {
            if self.states[index] == 1 {
                let taker: fn() -> T = self.takers[index]
                let value: T = taker()
                results.push(move value)
            }
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
            await yield_now()
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
            if self._active_count() != 0 { await yield_now() }
        }
        return self._take_all_ready()
    }

    /// Cancels active members newest-first, drops queued values, and reopens
    /// the empty group for reuse.
    pub fn cancel_all() {
        var index: int = self.states.len() - 1
        for index >= 0 {
            if self.states[index] == 0 {
                let cancel: fn() = self.cancellers[index]
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
