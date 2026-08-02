struct SourceFile {
    id: int
    path: string
    text: string
}

class SourceManager {
    files: List<SourceFile>

    fn init() {
        self.files = []
    }

    fn add(path: string, text: string) -> int {
        let id: int = self.files.len()
        self.files.push(SourceFile { id: id, path: path, text: text })
        return id
    }

    fn get(id: int) -> SourceFile {
        return self.files[id]
    }
}
