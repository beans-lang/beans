import std.io

struct Style {
    size: int = 12
    scale: f32 = 1.5
    name: string = "plain"
    flag: bool = false
}

struct Mixed {
    required: int
    padding: int = 4
}

fn main() {
    let all: Style = Style {}
    io.println("all: {all.size} {all.scale} {all.name} {all.flag}")
    let some: Style = Style { size: 20, flag: true }
    io.println("some: {some.size} {some.scale} {some.name} {some.flag}")
    let mixed: Mixed = Mixed { required: 7 }
    io.println("mixed: {mixed.required} {mixed.padding}")
}
