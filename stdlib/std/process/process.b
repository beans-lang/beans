// Running another program.
//
// The runtime runner spawns the child, writes stdin, drains both output streams, waits, and reaps it together so a full stderr pipe cannot deadlock a stdout read.
//
// Arguments pass to `execvp` directly; shell metacharacters are ordinary filename text.

package process

import std.proc

// Internal scoped deadline for the existing deadlock-free runtime runner.
extern "C" fn beans_proc_timeout_scope(ms: int) -> int

/// What a finished program left behind.
pub class Output {
    /// Exit code, or the negative of the signal number if it was killed.
    pub status: int = 0
    /// Captured stdout bytes; output may not be text.
    pub out: Bytes = new Bytes(0)
    /// Everything it wrote to stderr.
    pub err: Bytes = new Bytes(0)

    /// True when the program exited 0. Anything else, including a signal, is a failure.
    pub fn succeeded() -> bool {
        return self.status == 0
    }

    /// True when a signal ended it rather than a return from main.
    pub fn terminated_by_signal() -> bool {
        return self.status < 0
    }

    /// stdout as text. Stops at an embedded NUL, like any other Beans string.
    pub fn stdout_text() -> string {
        return self.out.to_string_until_nul()
    }

    /// stderr as text.
    pub fn stderr_text() -> string {
        return self.err.to_string_until_nul()
    }
}

/// A command to run: a program, its arguments, and how to start it.
///
/// Built up and then run, so the same command can be described once and run twice:
///
///     var cmd: Command = new Command("/bin/echo")
///     cmd.arg("hello")
///     match cmd.run() { ok(done) => ..., err(e) => ... }
pub class Command {
    program: string
    args: List<string> = []
    /// Empty means inherit this process's environment.
    env_pairs: List<string> = []
    /// Empty means stay in this process's directory.
    dir: string = ""
    stdin_data: Bytes = new Bytes(0)
    /// Maximum bytes retained from each output stream.
    limit: int = 8388608

    pub fn init(program: string) {
        self.program = program
    }

    /// Adds one argument without shell parsing.
    pub fn arg(value: string) -> Command {
        self.args.push(value)
        return self
    }

    /// Runs in this directory instead of the current one.
    pub fn cwd(path: string) -> Command {
        self.dir = path
        return self
    }

    /// Sets an environment variable; supplied variables replace the inherited environment.
    pub fn env(name: string, value: string) -> Command {
        self.env_pairs.push("{name}={value}")
        return self
    }

    /// Bytes to write to the program's stdin. Its stdin closes once they are written,
    /// so a program that reads to EOF finishes.
    pub fn stdin_bytes(move data: Bytes) -> Command {
        self.stdin_data = move data
        return self
    }

    /// Text to write to the program's stdin.
    pub fn stdin_text(data: string) -> Command {
        self.stdin_data = Bytes.from(data)
        return self
    }

    /// Caps how much of each stream is kept.
    pub fn capture_limit(bytes: int) -> Command {
        self.limit = bytes
        return self
    }

    /// Returns an error if execution cannot start or output cannot be collected; otherwise the child's exit code or signal is stored in `Output.status`.
    pub fn run() -> Result<Output> {
        self.validate()?
        var argv: Bytes = new Bytes(0)
        argv.append_string(self.program)
        argv.push(0)
        for a: string in self.args {
            argv.append_string(a)
            argv.push(0)
        }
        var envp: Bytes = new Bytes(0)
        for pair: string in self.env_pairs {
            envp.append_string(pair)
            envp.push(0)
        }
        let parts: List<Bytes> = proc.run(argv, envp, self.dir, self.stdin_data,
                                          self.limit)?
        return ok(decode(parts))
    }

    /// Runs with one deadline covering stdin, both output streams and exit.
    /// Timeout stops the child process group, reaps the child and returns kind
    /// `timeout`. Output capture limits and ordinary run errors are unchanged.
    pub fn run_timeout(ms: int) -> Result<Output> {
        if ms < 0 { return err("a timeout cannot be negative", "invalid") }
        let previous: int = self.timeout_scope(ms)
        defer self.timeout_scope(previous)
        return self.run()
    }

    fn timeout_scope(ms: int) -> int {
        unsafe { return beans_proc_timeout_scope(ms) }
    }

    /// Starts the child with open streams; configured stdin bytes and capture limit are ignored.
    pub fn start() -> Result<Child> {
        self.validate()?
        var argv: Bytes = new Bytes(0)
        argv.append_string(self.program)
        argv.push(0)
        for a: string in self.args {
            argv.append_string(a)
            argv.push(0)
        }
        var envp: Bytes = new Bytes(0)
        for pair: string in self.env_pairs {
            envp.append_string(pair)
            envp.push(0)
        }
        let four: Bytes = proc.start(argv, envp, self.dir)?
        return ok(new Child(four.get_i64(0),
                            new Stream(four.get_i64(8), "stdin"),
                            new Stream(four.get_i64(16), "stdout"),
                            new Stream(four.get_i64(24), "stderr")))
    }

    fn validate() -> Result<bool> {
        if has_nul(self.program) {
            return err("command program contains a NUL byte", "invalid")
        }
        for value: string in self.args {
            if has_nul(value) {
                return err("command argument contains a NUL byte", "invalid")
            }
        }
        for pair: string in self.env_pairs {
            if has_nul(pair) {
                return err("command environment contains a NUL byte", "invalid")
            }
        }
        if has_nul(self.dir) {
            return err("command working directory contains a NUL byte", "invalid")
        }
        return ok(true)
    }
}

fn has_nul(value: string) -> bool {
    var index: int = 0
    for index < value.len() {
        if value.byte_at(index) == 0 { return true }
        index += 1
    }
    return false
}

// The private runtime result keeps status, stdout and stderr as separate owned
// buffers. Taking their references out of this short list does not copy payload data.
fn decode(parts: List<Bytes>) -> Output {
    var done: Output = new Output()
    let status: Bytes = parts.remove(0)
    let out: Bytes = parts.remove(0)
    let err: Bytes = parts.remove(0)
    done.status = status.get_i64(0)
    done.out = move out
    done.err = move err
    return done
}

// Use `Child` when the caller needs to interact with or supervise a running process.

/// A stream owned by `Child`; closing is one-shot, and `Child` closes any open streams on drop.
pub class Stream {
    fd: int
    pub name: string = ""
    live: bool = true

    fn init(fd: int, name: string) {
        self.fd = fd
        self.name = name
    }

    /// Writes some of `data`, reporting how much went. Short writes are normal.
    pub fn write(data: Bytes) -> Result<int> {
        if !self.live { return err("{self.name} is closed", "closed") }
        return proc.write(self.fd, data, 0)
    }

    /// Writes all of it, looping over short writes.
    pub fn write_all(data: Bytes) -> Result<int> {
        if !self.live { return err("{self.name} is closed", "closed") }
        var done: int = 0
        for done < data.len() {
            let wrote: int = proc.write(self.fd, data, done)?
            if wrote <= 0 { return err("{self.name} accepted nothing", "reset") }
            done += wrote
        }
        return ok(done)
    }

    /// Writes text.
    pub fn write_text(text: string) -> Result<int> {
        if !self.live { return err("{self.name} is closed", "closed") }
        var done: int = 0
        for done < text.len() {
            let wrote: int = proc.write_text(self.fd, text, done)?
            if wrote <= 0 { return err("{self.name} accepted nothing", "reset") }
            done += wrote
        }
        return ok(done)
    }

    /// Reads up to `max` bytes; an empty result means the stream reached EOF.
    pub fn read(max: int) -> Result<Bytes> {
        if !self.live { return err("{self.name} is closed", "closed") }
        return proc.read(self.fd, max)
    }

    /// Reads until the writer closes, up to `limit` bytes.
    pub fn read_to_end(limit: int) -> Result<Bytes> {
        if !self.live { return err("{self.name} is closed", "closed") }
        return proc.read_to_end(self.fd, limit)
    }

    /// Closes it. For a child's stdin this is how a program that reads to EOF is told to
    /// finish.
    pub fn close() -> Result<bool> {
        if !self.live { return err("{self.name} is closed", "closed") }
        self.live = false
        return proc.close(self.fd)
    }

    /// True while the stream is open. `Child` uses this to skip closing twice.
    pub fn is_open() -> bool {
        return self.live
    }

    /// Returns the borrowed descriptor for poll registration.
    pub fn poll_handle() -> int {
        return self.fd
    }
}

/// A running child process.
///
/// Dropping an unreaped child terminates and reaps it; call `wait()` to let it exit normally.
pub unique class Child {
    pid: int
    pub stdin: Stream
    pub stdout: Stream
    pub stderr: Stream
    reaped: bool = false

    fn init(pid: int, stdin: Stream, stdout: Stream, stderr: Stream) {
        self.pid = pid
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    fn deinit() {
        if !self.reaped {
            // Politeness first, then force. Terminate gives a well-behaved program the
            // chance to clean up; kill is what guarantees this returns.
            let asked: Result<bool> = proc.signal(self.pid, 15)
            match proc.status(self.pid, 200) {
                ok(state) => {
                    if state.get_i64(0) == 0 {
                        let forced: Result<bool> = proc.signal(self.pid, 9)
                        let final_state: Result<Bytes> = proc.status(self.pid, -1)
                    }
                }
                err(e) => {}
            }
            self.reaped = true
        }
        // Whatever the caller did not close.
        if self.stdin.is_open() { let a: Result<bool> = self.stdin.close() }
        if self.stdout.is_open() { let b: Result<bool> = self.stdout.close() }
        if self.stderr.is_open() { let c: Result<bool> = self.stderr.close() }
    }

    /// Returns the process ID.
    pub fn process_id() -> int {
        return self.pid
    }

    /// Reports whether the child exited and reaps it when it has.
    pub fn is_finished() -> Result<bool> {
        if self.reaped { return ok(true) }
        let state: Bytes = proc.status(self.pid, 0)?
        if state.get_i64(0) == 1 {
            self.reaped = true
            return ok(true)
        }
        return ok(false)
    }

    /// Waits for exit and returns the exit code or negative signal number.
    pub fn wait() -> Result<int> {
        if self.reaped { return err("this child was already waited for", "closed") }
        let state: Bytes = proc.status(self.pid, -1)?
        self.reaped = true
        return ok(state.get_i64(8))
    }

    /// Waits up to `ms` milliseconds and returns `none` if the child is still running.
    pub fn wait_timeout(ms: int) -> Result<Option<int>> {
        if self.reaped { return err("this child was already waited for", "closed") }
        if ms < 0 { return err("a timeout cannot be negative", "invalid") }
        let state: Bytes = proc.status(self.pid, ms)?
        if state.get_i64(0) == 0 { return ok(none) }
        self.reaped = true
        return ok(some(state.get_i64(8)))
    }

    /// Sends `SIGTERM`; the child may clean up or continue running.
    pub fn terminate() -> Result<bool> {
        if self.reaped { return err("this child has already finished", "closed") }
        return proc.signal(self.pid, 15)
    }

    /// Stops it now (`SIGKILL`). Cannot be ignored, and gives it no chance to clean up.
    pub fn kill() -> Result<bool> {
        if self.reaped { return err("this child has already finished", "closed") }
        return proc.signal(self.pid, 9)
    }

    /// Sends any signal by number.
    pub fn send_signal(number: int) -> Result<bool> {
        if self.reaped { return err("this child has already finished", "closed") }
        return proc.signal(self.pid, number)
    }

    /// Sends `SIGTERM`, waits up to `grace_ms`, then sends `SIGKILL` and returns the status.
    pub fn stop(grace_ms: int) -> Result<int> {
        if self.reaped { return err("this child has already finished", "closed") }
        let asked: bool = proc.signal(self.pid, 15)?
        match self.wait_timeout(grace_ms)? {
            some(status) => { return ok(status) }
            none => {
                let forced: bool = proc.signal(self.pid, 9)?
                return self.wait()
            }
        }
    }
}
