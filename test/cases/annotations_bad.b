@target(value: ["function"])
annotation route {
    path: string
    methods: List<string> = []
}

annotation single {}

@route(path: runtime_path())
@route(path: "/again", unknown: true)
@single
@single
class WrongTarget {}

@route(methods: [])
fn missing_required() {}

@route(path: true)
fn wrong_type() {}

@route(path: "/one", path: "/two")
fn duplicate_argument() {}

fn runtime_path() -> string {
    return "/runtime"
}

fn main() {}
