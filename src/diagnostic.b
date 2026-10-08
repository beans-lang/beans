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

// The context a terminal reader needs under the unchanged first line: the
// source line, a caret under the primary column, then each related note in
// the order its producer recorded it. Notes start with `note:` and name
// their location after ` at `, so a consumer matching
// `file:line:col: error: message` lines still finds one per diagnostic.
fn render_source_diagnostic(value: Diagnostic,
                            sources: SourceManager) -> string {
    var lines: List<string> = [render_diagnostic(value)]
    if value.line > 0 && value.col > 0 {
        match sources.line_text(value.file, value.line - 1) {
            some(text) => {
                let excerpt: DiagnosticExcerpt =
                    diagnostic_excerpt(text, value.col)
                lines.push(excerpt.text)
                lines.push(diagnostic_caret(excerpt.text, excerpt.col))
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

struct DiagnosticExcerpt {
    text: string
    col: int
}

// The part of a source line an excerpt shows, and the column within it. A
// line up to 240 bytes is shown whole. A longer one (minified or generated
// source) is cut to about 160 bytes around the column, never inside a UTF-8
// sequence, with `...` where text was left out, so a long line is not
// printed in full once per diagnostic on it.
fn diagnostic_excerpt(text: string, col: int) -> DiagnosticExcerpt {
    if text.len() <= 240 {
        return DiagnosticExcerpt { text: text, col: col }
    }
    var start: int = col - 1 - 80
    if start > text.len() { start = text.len() }
    if start < 0 { start = 0 }
    for start > 0 && start < text.len() &&
        text.byte_at(start) >= 128 && text.byte_at(start) < 192 {
        start -= 1
    }
    var end: int = start + 160
    if end > text.len() { end = text.len() }
    for end < text.len() &&
        text.byte_at(end) >= 128 && text.byte_at(end) < 192 {
        end += 1
    }
    var shown: string = text.slice(start, end)
    var column: int = col - start
    if start > 0 {
        shown = "...{shown}"
        column += 3
    }
    if end < text.len() { shown = "{shown}..." }
    return DiagnosticExcerpt { text: shown, col: column }
}

// The caret line for a one-based byte column of `text`. Tabs are copied so
// the terminal applies the same tab stops to both lines; everything else is
// measured in terminal columns with the runtime's width table, so a wide
// CJK or emoji character takes two cells and a combining mark none. A
// column past the end of the line (a token missing at the end of a line or
// of the file) sits that many cells after the text.
fn diagnostic_caret(text: string, col: int) -> string {
    var parts: List<string> = []
    let wanted: int = col - 1
    let limit: int = if wanted < text.len() { wanted } else { text.len() }
    var start: int = 0
    var index: int = 0
    for index < limit {
        if text.byte_at(index) == 9 {
            if index > start {
                parts.push(" ".repeat(
                    tree_display_width(text.slice(start, index))))
            }
            parts.push("\t")
            start = index + 1
        }
        index += 1
    }
    if limit > start {
        parts.push(" ".repeat(tree_display_width(text.slice(start, limit))))
    }
    if wanted > limit { parts.push(" ".repeat(wanted - limit)) }
    parts.push("^")
    return parts.join("")
}

fn render_loaded_diagnostic(value: Diagnostic,
                            loader: ModuleLoader) -> string {
    return render_source_diagnostic(
        loader.contextual_diagnostic(value), loader.sources)
}
