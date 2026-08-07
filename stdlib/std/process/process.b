// Running another program.
//
// `std.process` is the readable layer over one runtime primitive. The primitive does
// the whole job in one call — spawn, feed stdin, drain both output streams, wait, reap —
// because that is the only way the classic deadlock is impossible: a parent that reads
// stdout to EOF while the child blocks writing stderr hangs forever, and the fix is to
// watch every descriptor at once.
//
// **There is no shell.** A command is a program name and a list of arguments, and they
// reach `execvp` untouched. A filename containing a space, a quote or a semicolon is
// just a filename, so there is nothing to escape and nothing to get wrong.

package process

import std.proc

/// What a finished program left behind.
pub class Output {
    /// Exit code, or the negative of the signal number if it was killed.
    pub status: int = 0
    /// Everything the program wrote to stdout, as bytes — output is not always text.
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
    /// Bytes to keep from each stream. A program that prints forever must not be able
    /// to exhaust memory here, so there is always a limit.
    limit: int = 8388608

    pub fn init(program: string) {
        self.program = program
    }

    /// Adds one argument. Never parsed, never split, never passed through a shell.
    pub fn arg(value: string) -> Command {
        self.args.push(value)
        return self
    }

    /// Runs in this directory instead of the current one.
    pub fn cwd(path: string) -> Command {
        self.dir = path
        return self
    }

    /// Sets one environment variable. The first call switches from inheriting the
    /// parent's environment to a fresh one holding only what is set here, because a
    /// half-inherited environment is the kind of thing that works until it does not.
    pub fn env(name: string, value: string) -> Command {
        self.env_pairs.push("{name}={value}")
        return self
    }

    /// Bytes to write to the program's stdin. Its stdin closes once they are written,
    /// so a program that reads to EOF finishes.
    pub fn stdin_bytes(data: Bytes) -> Command {
        self.stdin_data = data
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

    /// Runs it, waits for it, and collects what it produced.
    ///
    /// A program that could not be started — not found, not executable, a bad working
    /// directory — is an `err`, separately from a program that started and failed.
    /// That distinction is the whole reason the runtime carries a close-on-exec pipe:
    /// without it "no such file" and "exited 127" look identical.
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
        let packed: Bytes = proc.run(argv, envp, self.dir, self.stdin_data,
                                     self.limit)?
        return ok(decode(packed))
    }

    /// Starts it and comes straight back, giving a `Child` to watch, talk to and stop.
    ///
    /// `stdin_bytes`/`stdin_text` and `capture_limit` do not apply — the whole point is
    /// that the streams stay open for you to use. Everything else does.
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

// [i64 status][i64 out_len][i64 err_len][stdout][stderr] — the runtime returns one
// Bytes because the fallible-builtin ABI carries a single value.
fn decode(packed: Bytes) -> Output {
    var done: Output = new Output()
    done.status = packed.get_i64(0)
    let out_len: int = packed.get_i64(8)
    let err_len: int = packed.get_i64(16)
    done.out = packed.slice(24, 24 + out_len)
    done.err = packed.slice(24 + out_len, 24 + out_len + err_len)
    return done
}

// There is deliberately no module-level `run(program)` here. Running a program produces
// an object, and construction that can fail is a named static on the class — but a
// static `run` beside the instance `run` would read as two different things with one
// name, and `new Command(program).run()` is already the short form.

// ---- a child that outlives the call -----------------------------------------
//
// `Command.run()` is right when the program's output is all you want. It cannot help when
// the child keeps running: a server to talk to, a process to watch, something to stop
// after a deadline. `Command.start()` gives a `Child` instead.

/// One of a child's three streams.
///
/// Not a `unique class`, because a `Child` owns all three and handing out three move-only
/// values would mean the child could not be waited on until every stream was accounted
/// for. Closing one twice is an error rather than a crash, and the child closes whatever
/// is left.
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
        return self.write_all(Bytes.from(text))
    }

    /// Reads up to `max` bytes. **An empty result means the other end closed** — for a
    /// child's stdout, that it has stopped writing.
    pub fn read(max: int) -> Result<Bytes> {
        if !self.live { return err("{self.name} is closed", "closed") }
        return proc.read(self.fd, max)
    }

    /// Reads until the writer closes, up to `limit` bytes.
    pub fn read_to_end(limit: int) -> Result<Bytes> {
        if !self.live { return err("{self.name} is closed", "closed") }
        var got: Bytes = new Bytes(0)
        for got.len() < limit {
            let chunk: Bytes = proc.read(self.fd, limit - got.len())?
            if chunk.len() == 0 { return ok(got) }
            got.append(chunk)
        }
        return ok(got)
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

    /// The raw descriptor, borrowed — for a poller.
    pub fn poll_handle() -> int {
        return self.fd
    }
}

/// A running child process.
///
/// **A dropped `Child` is killed and reaped.** Not left running, and not left as a zombie:
/// a zombie per spawn leaks the one resource a process cannot get more of, and an orphan
/// outliving the program that started it is worse. Call `wait()` if you want it to finish
/// on its own terms.
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

    /// The process id, for logging. Signalling goes through the methods here, which know
    /// whether the child has already been reaped.
    pub fn process_id() -> int {
        return self.pid
    }

    /// True when it has finished. Reaps it if so, so this is safe to call in a loop
    /// without leaving a zombie.
    pub fn is_finished() -> Result<bool> {
        if self.reaped { return ok(true) }
        let state: Bytes = proc.status(self.pid, 0)?
        if state.get_i64(0) == 1 {
            self.reaped = true
            return ok(true)
        }
        return ok(false)
    }

    /// Waits for it to finish and gives its status: the exit code, or the **negative**
    /// signal number if a signal ended it.
    pub fn wait() -> Result<int> {
        if self.reaped { return err("this child was already waited for", "closed") }
        let state: Bytes = proc.status(self.pid, -1)?
        self.reaped = true
        return ok(state.get_i64(8))
    }

    /// Waits at most `ms` milliseconds. `none` means it is still running — which is not an
    /// error, so a caller can escalate rather than having to catch one.
    pub fn wait_timeout(ms: int) -> Result<Option<int>> {
        if self.reaped { return err("this child was already waited for", "closed") }
        if ms < 0 { return err("a timeout cannot be negative", "invalid") }
        let state: Bytes = proc.status(self.pid, ms)?
        if state.get_i64(0) == 0 { return ok(none) }
        self.reaped = true
        return ok(some(state.get_i64(8)))
    }

    /// Asks it to stop (`SIGTERM`). A well-behaved program cleans up and exits; one that
    /// ignores it keeps running, which is what `kill` is for.
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

    /// Asks it to stop, waits `grace_ms`, then kills it if it is still there. Returns its
    /// status. This is the shape almost every caller actually wants.
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
