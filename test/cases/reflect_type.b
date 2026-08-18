import std.io
import std.reflect

struct User {
    name: string
    age: int
}

class Entity {
    pub id: int = 1
}

class Person extends Entity {
    pub name: string = "guest"
    active: bool = true
}

fn main() {
    let user: reflect.Type = type_of(User)
    let integer: reflect.Type = type_of(int)
    let users: reflect.Type = type_of(List<User>)
    io.println(user.qualified_name())
    io.println(user.name())
    io.println(integer.qualified_name())
    io.println(users.qualified_name())
    io.println(user.kind())
    io.println(users.kind())
    io.println(users.type_arguments()[0].qualified_name())
    let person: reflect.Type = type_of(Person)
    io.println(person.base_type().expect("base").qualified_name())
    for field: reflect.Field in person.fields() {
        io.println("{field.declaring_type().name()}.{field.name()}:{field.type().qualified_name()}:{field.is_public()}:{field.has_default()}")
    }
    io.println(person.field("name").expect("name").name())
    io.println(person.field("missing").is_none())
}
