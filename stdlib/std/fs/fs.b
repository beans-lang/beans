// High-level file helpers in Beans. File.open and positional/cursor I/O stay
// native because they are the syscall boundary.
//
// This package names a file by its path, and it covers the whole life of one:
// where to put it (`temp_dir`), whether it is there (`exists`), how big it is
// (`size`), its bytes (`read`/`write`/`append` and their `_bytes` twins), and
// moving or ending it (`copy`, `rename`, `remove`). A program that can create a
// file it cannot release is worse than one that cannot create it at all, so the
// end of a file's life belongs here beside the start of it.
//
// Directories keep their own surface on the `Dir` builtin — `create`,
// `create_all`, `list`, `walk`, `remove`, `remove_all`, `exists`, `sync`.

package fs

pub fn read_bytes(path: string) -> Result<Bytes> {
    let file: File = File.open(path, "r")?
    defer file.close()
    let size: int = file.size()?
    return file.read_at(0, size)
}

pub fn read(path: string) -> Result<string> {
    let file: File = File.open(path, "r")?
    defer file.close()
    let size: int = file.size()?
    return file.read_text_at(0, size)
}

pub fn write_bytes(path: string, data: Bytes) -> Result<int> {
    let file: File = File.open(path, "create")?
    defer file.close()
    file.truncate(0)?
    return file.write_at(0, data)
}

pub fn append_bytes(path: string, data: Bytes) -> Result<int> {
    let file: File = File.open(path, "append")?
    defer file.close()
    return file.write(data)
}

pub fn write(path: string, data: string) -> Result<int> {
    let file: File = File.open(path, "create")?
    defer file.close()
    file.truncate(0)?
    return file.write_text_at(0, data)
}

pub fn append(path: string, data: string) -> Result<int> {
    let file: File = File.open(path, "append")?
    defer file.close()
    return file.write_text(data)
}

pub fn copy(from: string, to: string) -> Result<int> {
    return File.copy(from, to)
}

/// True when a file exists at `path`.
///
/// Symlinks are followed, so a link to a file answers true and a dangling one
/// answers false. A **directory answers false** — this asks about a file, and
/// `Dir.exists(path)` is the question about a directory.
///
/// Answering false is not a promise the next call will succeed: another process
/// can create or remove the path in between. Code that must not race should
/// act and read the error, the way `remove` does below.
pub fn exists(path: string) -> bool {
    return File.exists(path)
}

/// How many bytes the file at `path` holds, without opening it.
///
/// `not_found` when nothing is there.
pub fn size(path: string) -> Result<int> {
    return File.size(path)
}

/// Moves the file at `from` to `to`, replacing `to` if it already exists.
///
/// Within one filesystem this is the atomic rename a commit is built on: write
/// the new bytes to a temporary name, then rename over the real one, so a
/// reader sees either the whole old file or the whole new one. `Dir.sync` on
/// the containing directory is the durability half of that pattern. Across
/// filesystems the OS refuses, and `copy` then `remove` is the answer.
pub fn rename(from: string, to: string) -> Result<bool> {
    return File.rename(from, to)
}

/// Removes the entry at `path`. `ok(true)` when it was there and is gone,
/// `ok(false)` when nothing was there.
///
/// A missing path is not a failure, because for the callers that need this most
/// it is the ordinary case: a `deinit` releasing a spooled temp file cannot
/// propagate a result, and "already gone" is exactly the state it wanted. Every
/// other failure — no permission, a non-empty directory, a path through a
/// non-directory — is still `err`, carrying the `Error.kind` slug.
///
/// The answer comes from the removal itself, never from asking `exists` first:
/// a check-then-act pair would call a file that vanished in between a failure,
/// and one that appeared in between a success.
///
/// This is the POSIX `remove` verb, the same one `File.remove` is: it unlinks a
/// file or a symlink (the link itself, never its target, so a dangling link can
/// be removed), and it removes an **empty** directory. A non-empty directory is
/// `err` with kind `not_empty`; `Dir.remove_all` is the recursive one.
pub fn remove(path: string) -> Result<bool> {
    match File.remove(path) {
        ok(_) => { return ok(true) }
        err(e) => {
            if e.kind == "not_found" { return ok(false) }
            return err(e)
        }
    }
}

/// The directory this system hands out for temporary files.
///
/// `TMPDIR` when the environment sets it, then `TMP` and `TEMP` on Windows,
/// then the platform default. No trailing separator, so `path.join` produces
/// one. The directory is shared with every other program on the machine and is
/// not private: a file placed here needs a name nothing else will pick, and
/// nothing here survives a reboot.
pub fn temp_dir() -> string {
    return Dir.temp_path()
}
