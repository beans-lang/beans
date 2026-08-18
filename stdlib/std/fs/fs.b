// High-level file helpers in Beans. File.open and positional/cursor I/O stay
// native because they are the syscall boundary.

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
