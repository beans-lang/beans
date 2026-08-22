// A bare cross-package annotation use: every default fills from the
// declaring scope. Before the fix this failed with "unknown name
// 'Level'", because defaults were re-checked against this file's
// imports.
package main
import std.io
import std.reflect
import app.marks

@marks.mark
pub class Bare {
    pub fn init() {}
}

@marks.mark(level: marks.Level.low)
pub class Half {
    pub fn init() {}
}

@marks.mark(level: marks.Level.low, label: "named")
pub class Full {
    pub fn init() {}
}

fn read(type: reflect.Type) {
    for annotation: reflect.Annotation in type.annotations() {
        let level: string = match annotation.argument("level") {
            some(argument) => argument.value().text(),
            none => "?",
        }
        let label: string = match annotation.argument("label") {
            some(argument) => argument.value().text(),
            none => "?",
        }
        io.println("{type.name()} level={level} label={label}")
    }
}

fn main() {
    for type: reflect.Type in reflect.types() {
        let name: string = type.name()
        if name == "Bare" || name == "Half" || name == "Full" {
            read(type)
        }
    }
}
