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
