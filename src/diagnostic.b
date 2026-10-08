package main

enum Severity {
    error
    warning
    note
}

struct Diagnostic {
    severity: Severity
    file: string
    line: int
    col: int
    message: string
    // Source coordinates are one-based byte positions; the end is exclusive.
    // Older producers can keep emitting a point until they own a real span.
    end_line: int = 0
    end_col: int = 0
    related: DiagnosticNotes = new DiagnosticNotes()
}

struct DiagnosticNote {
    file: string
    line: int
    col: int
    message: string
    end_line: int = 0
    end_col: int = 0
}

// Keep the long-standing copyable Diagnostic contract: a direct List field
// would make every diagnostic a move-only value, including phase transport.
// Each producer gets its own ordered list; composers allocate a fresh list.
class DiagnosticNotes {
    items: List<DiagnosticNote>

    fn init() { self.items = [] }
}

// A lexer/parser does not know its file. Attach it once without discarding
// the span or notes that the owning phase recorded.
fn diagnostic_in_file(value: Diagnostic, file: string) -> Diagnostic {
    var result: Diagnostic = value
    result.file = file
    let notes: DiagnosticNotes = new DiagnosticNotes()
    for note: DiagnosticNote in value.related.items {
        var located: DiagnosticNote = note
        if located.file == "" { located.file = file }
        notes.items.push(located)
    }
    result.related = notes
    return result
}

fn severity_name(value: Severity) -> string {
    match value {
        error => { return "error" },
        warning => { return "warning" },
        note => { return "note" },
    }
}

fn render_diagnostic(value: Diagnostic) -> string {
    return "{value.file}:{value.line}:{value.col}: {severity_name(value.severity)}: {value.message}"
}

fn render_source_diagnostic(value: Diagnostic,
                            sources: SourceManager) -> string {
    var lines: List<string> = [render_diagnostic(value)]
    if value.line > 0 && value.col > 0 {
        match sources.find(value.file) {
            some(source) => {
                let text: string = lsp_line(source.text, value.line - 1)
                lines.push(text)
                var caret: List<string> = []
                var at: int = 0
                let limit: int = value.col - 1
                for at < limit {
                    // Tabs retain the source's tab stops. A UTF-8 code point
                    // occupies one displayed column rather than one per byte.
                    if at < text.len() && text.byte_at(at) == 9 {
                        caret.push("\t")
                        at += 1
                    } else if at < text.len() {
                        caret.push(" ")
                        at += lsp_utf8_width(text.byte_at(at))
                    } else {
                        caret.push(" ")
                        at += 1
                    }
                }
                caret.push("^")
                lines.push(caret.join(""))
            }
            none => {}
        }
    }
    for note: DiagnosticNote in value.related.items {
        lines.push(
            "note: {note.message} at {note.file}:{note.line}:{note.col}")
    }
    return lines.join("\n")
}

fn render_loaded_diagnostic(value: Diagnostic,
                            loader: ModuleLoader) -> string {
    return render_source_diagnostic(
        loader.contextual_diagnostic(value), loader.sources)
}
