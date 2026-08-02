import std.io

enum SeverityLike {
    error
    warning
    note
}

struct Message {
    severity: SeverityLike
    text: string
}

fn severity_name(value: SeverityLike) -> string {
    match value {
        error => { return "error" },
        warning => { return "warning" },
        note => { return "note" },
    }
}

fn main() {
    let first: Message = Message {
        severity: SeverityLike.warning,
        text: "watch",
    }
    io.println("{severity_name(first.severity)}:{first.text}")
    io.println(SeverityLike.error == SeverityLike.error)
    io.println(SeverityLike.error != SeverityLike.note)
    var values: List<SeverityLike> = []
    values.push(SeverityLike.note)
    io.println("{severity_name(values[0])}:{values.len()}")
}
