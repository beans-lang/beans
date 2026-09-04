// Terminals.
//
// The parts of a terminal whose shape is the platform's — `struct termios`
// (72 bytes on macOS, 60 on Linux), `struct winsize`, the Windows console —
// live in the runtime's C, reached through four calls. Everything with a
// portable shape is here in Beans: the ANSI writers, and the CSI key decoder in
// `keys.b`.
//
// **Raw mode restores itself.** `RawMode.enter` puts the terminal into raw mode
// and the returned guard puts it back — on `restore()`, on going out of scope,
// and, because the runtime registers the restore with `atexit`, on a normal
// exit and on a panic (both reach `exit()` on either backend). What that does
// *not* cover is a crash by `SIGSEGV`/`SIGBUS`: only the runtime's fault
// reporter runs then, and it is fenced to flushing output — installing a second
// disposition is what `test/signals.sh` forbids. A full-screen program should
// watch `terminate` and `hangup` through `std.signal` and restore from its own
// loop, which needs no handler; in raw mode `Ctrl-C` is delivered as the byte
// `0x03`, not as a signal, so the common interrupt is already the program's to
// handle.
//
// **Frames are written whole and unbuffered.** `io.print` goes through stdio,
// where a frame with no trailing newline sits in the buffer; `Frame.flush`
// writes the whole escape-and-text buffer with one `write(2)`, so what you drew
// is on the screen when the call returns.

package term

import std.proc

// The struct-shaped half, in the runtime. Each returns a plain status: 0 on
// success, a negative value on failure (-errno on POSIX, -1000 for a platform
// with no terminal control). Sizes come back through the out buffer, never as
// the return, so a status is never read as a count.
extern "C" fn beans_term_is_tty(fd: int) -> int
extern "C" fn beans_term_size(fd: int, out: RawPtr<u16>) -> int
extern "C" fn beans_term_set_raw(fd: int) -> int
extern "C" fn beans_term_restore(fd: int) -> int

// The status a stub or Windows raw mode returns: this platform has no terminal
// control to offer. Kept in one place so the message and the kind agree.
fn term_unsupported() -> int {
    return 0 - 1000
}

fn term_fail_kind(status: int) -> string {
    if status == term_unsupported() { return "unsupported" }
    return "io"
}

fn term_fail_message(op: string, status: int) -> string {
    if status == term_unsupported() {
        return "{op}: no terminal control on this platform"
    }
    return "{op}: failed with errno {0 - status}"
}

/// Whether a descriptor is a terminal. Never fails: a pipe or a file is simply
/// `false`, which is the whole point of asking.
pub fn is_tty(fd: int) -> bool {
    unsafe {
        return beans_term_is_tty(fd) != 0
    }
}

/// A terminal's size in character cells.
pub class Size {
    pub rows: int = 0
    pub cols: int = 0

    pub fn init(rows: int, cols: int) {
        self.rows = rows
        self.cols = cols
    }
}

/// The terminal's current size, from `ioctl(TIOCGWINSZ)` on POSIX and the
/// console on Windows. `err` when `fd` is not a terminal, or when the terminal
/// cannot report a size yet (a fresh pane can answer 0×0) — a real screen never
/// has zero rows, so that is reported rather than handed back.
pub fn size(fd: int) -> Result<Size> {
    unsafe {
        let out: RawPtr<u16> = RawPtr.alloc(2)
        let status: int = beans_term_size(fd, out)
        if status != 0 {
            out.free()
            return err(term_fail_message("terminal size", status),
                       term_fail_kind(status))
        }
        let rows: int = out.read() as int
        let cols: int = out.offset(1).read() as int
        out.free()
        return ok(new Size(rows, cols))
    }
}

/// A terminal held in raw mode, restored when this guard is dropped.
///
/// Move-only, like every resource: exactly one value owns the mode, so it cannot
/// be restored twice, and a guard that goes out of scope restores whether you
/// remembered to or not. Raw mode here means the full make-up — no echo, no line
/// buffering, no signal generation, no input or output translation — so keys
/// arrive as bytes the moment they are pressed and `Ctrl-C` is the byte `0x03`
/// for the program to interpret.
pub unique class RawMode {
    fd: int
    live: bool = true

    fn init(fd: int) {
        self.fd = fd
    }

    fn deinit() {
        if self.live {
            unsafe {
                let ignored: int = beans_term_restore(self.fd)
            }
            self.live = false
        }
    }

    /// Puts `fd` into raw mode. `err` with kind `invalid` when `fd` is not a
    /// terminal, and kind `unsupported` on a platform without raw mode (Windows,
    /// today). The original mode is saved by the runtime, so `restore` always
    /// returns the terminal to how the program found it.
    pub static fn enter(fd: int) -> Result<RawMode> {
        if !is_tty(fd) {
            return err("raw mode: fd {fd} is not a terminal", "invalid")
        }
        unsafe {
            let status: int = beans_term_set_raw(fd)
            if status != 0 {
                return err(term_fail_message("raw mode", status),
                           term_fail_kind(status))
            }
        }
        return ok(new RawMode(fd))
    }

    /// The descriptor this guard controls.
    pub fn descriptor() -> int {
        return self.fd
    }

    /// Restores cooked mode now and reports any error. `deinit` does the same but
    /// cannot report. Restoring twice is a no-op, not a failure.
    pub fn restore() -> Result<bool> {
        if !self.live { return ok(true) }
        self.live = false
        unsafe {
            let status: int = beans_term_restore(self.fd)
            if status != 0 {
                return err(term_fail_message("restore", status),
                           term_fail_kind(status))
            }
        }
        return ok(true)
    }
}

/// A screen's worth of escape sequences and text, built up and then written
/// whole.
///
/// Beans string literals carry no `\x1b`, so every sequence here is the escape
/// byte pushed on its own followed by ASCII — which is also why this is a
/// builder rather than a pile of string constants. Build a frame, draw into it,
/// `flush` it to a descriptor in one unbuffered write, then `reset` and reuse.
pub class Frame {
    data: Bytes

    pub fn init() {
        self.data = new Bytes(0)
    }

    // The escape byte, then the rest of the sequence as ASCII.
    fn esc(tail: string) {
        self.data.push(27)
        self.data.append_string(tail)
    }

    /// Clears the whole screen.
    pub fn clear() {
        self.esc("[2J")
    }

    /// Clears the line the cursor is on.
    pub fn clear_line() {
        self.esc("[2K")
    }

    /// Moves the cursor to a 1-based row and column.
    pub fn move_to(row: int, col: int) {
        self.esc("[{row};{col}H")
    }

    /// Moves the cursor to the top-left.
    pub fn home() {
        self.esc("[H")
    }

    /// Hides the cursor.
    pub fn hide_cursor() {
        self.esc("[?25l")
    }

    /// Shows the cursor.
    pub fn show_cursor() {
        self.esc("[?25h")
    }

    /// Switches to the alternate screen — a full-screen program draws here and
    /// leaves the user's scrollback untouched.
    pub fn enter_alt_screen() {
        self.esc("[?1049h")
    }

    /// Returns to the normal screen, restoring what was there before.
    pub fn leave_alt_screen() {
        self.esc("[?1049l")
    }

    /// Clears all colour and style back to the terminal's default.
    pub fn reset_style() {
        self.esc("[0m")
    }

    /// Bold weight for the text that follows.
    pub fn bold() {
        self.esc("[1m")
    }

    /// Sets the foreground to a 256-colour index (0–15 are the basic colours).
    pub fn fg(color: int) {
        self.esc("[38;5;{color}m")
    }

    /// Sets the background to a 256-colour index.
    pub fn bg(color: int) {
        self.esc("[48;5;{color}m")
    }

    /// Sets the foreground to a 24-bit colour.
    pub fn fg_rgb(r: int, g: int, b: int) {
        self.esc("[38;2;{r};{g};{b}m")
    }

    /// Sets the background to a 24-bit colour.
    pub fn bg_rgb(r: int, g: int, b: int) {
        self.esc("[48;2;{r};{g};{b}m")
    }

    /// Appends text.
    pub fn text(s: string) {
        self.data.append_string(s)
    }

    /// Appends one raw byte, for a sequence this builder does not name.
    pub fn byte(b: int) {
        self.data.push(b)
    }

    /// How many bytes are queued.
    pub fn len() -> int {
        return self.data.len()
    }

    /// Writes the whole frame to `fd` with one unbuffered `write(2)`, looping
    /// until every byte is out. The frame is left intact; call `reset` to reuse
    /// it for the next draw.
    pub fn flush(fd: int) -> Result<int> {
        return write_all(fd, self.data)
    }

    /// Empties the frame so it can be drawn into again.
    pub fn reset() {
        self.data = new Bytes(0)
    }
}

/// Writes every byte of `data` to `fd`, unbuffered, looping over partial
/// writes. `err` if the descriptor accepts nothing before the data is out.
pub fn write_all(fd: int, data: Bytes) -> Result<int> {
    let total: int = data.len()
    var done: int = 0
    for done < total {
        let wrote: int = proc.write(fd, data, done)?
        if wrote == 0 {
            return err("terminal write: the descriptor accepted nothing", "io")
        }
        done += wrote
    }
    return ok(done)
}
