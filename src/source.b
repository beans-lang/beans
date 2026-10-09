package main

struct SourceFile {
    id: int
    path: string
    text: string
}

// Where each line of one retained source starts, as byte offsets. Built the
// first time a diagnostic excerpt or an editor range asks for a line of that
// file, so a clean check never pays for it and a file with thousands of
// diagnostics is scanned once rather than once per diagnostic.
class SourceLines {
    starts: List<int>

    fn init(text: string) {
        self.starts = [0]
        var index: int = 0
        let length: int = text.len()
        for index < length {
            if text.byte_at(index) == 10 { self.starts.push(index + 1) }
            index += 1
        }
    }
}

class SourceManager {
    files: List<SourceFile>
    ids: Map<string, int>
    lines: Map<int, SourceLines>

    fn init() {
        self.files = []
        self.ids = {}
        self.lines = {}
    }

    fn add(path: string, text: string) -> int {
        let id: int = self.files.len()
        self.files.push(SourceFile { id: id, path: path, text: text })
        // The first source registered under a path is the one `find` has
        // always answered with.
        if !self.ids.contains_key(path) { self.ids[path] = id }
        return id
    }

    fn get(id: int) -> SourceFile {
        return self.files[id]
    }

    fn find(path: string) -> Option<SourceFile> {
        match self.ids.get(path) {
            some(id) => { return some(self.files[id]) }
            none => { return none }
        }
    }

    // One zero-based line of a retained source, as `lsp_line` cuts it: no
    // newline, no carriage return, and "" past the end. none when no source
    // was retained under `path`. The text is the snapshot the phases read,
    // so an editor's unsaved buffer is excerpted, never the disk copy.
    fn line_text(path: string, line: int) -> Option<string> {
        match self.ids.get(path) {
            some(id) => {
                let text: string = self.files[id].text
                if !self.lines.contains_key(id) {
                    self.lines[id] = new SourceLines(text)
                }
                let index: SourceLines = self.lines[id]
                if line < 0 || line >= index.starts.len() { return some("") }
                let start: int = index.starts[line]
                var end: int = text.len()
                if line + 1 < index.starts.len() {
                    end = index.starts[line + 1] - 1
                }
                if end > start && text.byte_at(end - 1) == 13 { end -= 1 }
                return some(text.slice(start, end))
            }
            none => { return none }
        }
    }
}
