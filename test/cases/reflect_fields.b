import std.io
import std.reflect

class Account {
    pub name: string
    secret: int

    fn init(name: string, secret: int) {
        self.name = name
        self.secret = secret
    }
}

struct Point {
    pub x: int
    pub y: int
}

fn main() {
    let account: Account = new Account("old", 7)
    let boxed: reflect.Value = reflect.value(move account)
    let account_type: reflect.Type = type_of(Account)
    let name: reflect.Field = account_type.field("name").expect("name")
    let old: reflect.Value = name.get(boxed).expect("read name")
    io.println((old as? string).expect("string"))
    name.set(boxed, reflect.value("new")).expect("write name")
    io.println((name.get(boxed).expect("read new") as? string).expect("string"))

    let secret: reflect.Field = account_type.field("secret").expect("secret")
    match secret.get(boxed) {
        ok(_) => io.println("bad private read"),
        err(problem) => io.println("{problem.kind()}:{problem.message()}"),
    }
    match name.set(boxed, reflect.value(9)) {
        ok(_) => io.println("bad wrong type"),
        err(problem) => io.println(problem.kind()),
    }

    let point: Point = Point { x: 3, y: 4 }
    let boxed_point: reflect.Value = reflect.value(move point)
    let x: reflect.Field = type_of(Point).field("x").expect("x")
    io.println((x.get(boxed_point).expect("read x") as? int).expect("int"))
    x.set(boxed_point, reflect.value(8)).expect("write x")
    let changed: Point = (boxed_point as? Point).expect("Point")
    io.println("{changed.x},{changed.y}")
}
