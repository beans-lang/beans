import std.io
import std.reflect

class User {
    pub name: string

    fn init(name: string) { self.name = name }
}

struct Bundle {
    label: string
    items: List<int>
}

fn main() {
    let number: reflect.Value = reflect.value(42)
    io.println(number.type().qualified_name())
    io.println((number as? int).expect("int"))
    io.println((number as? string).is_none())

    let copied: reflect.Value = number.copy()
    io.println((copied as? int).expect("copied int"))
    io.println(copied.is_type(type_of(int)))

    let user: User = new User("beans")
    let boxed_user: reflect.Value = reflect.value(move user)
    let restored: User = (boxed_user as? User).expect("User")
    io.println(restored.name)
    io.println(boxed_user.type().qualified_name())

    let bundle: Bundle = Bundle { label: "owned", items: [3, 4] }
    let boxed_bundle: reflect.Value = reflect.value(move bundle)
    let copied_bundle: reflect.Value = boxed_bundle.copy()
    let first_bundle: Bundle =
        (move boxed_bundle as? Bundle).expect("first Bundle")
    let second_bundle: Bundle =
        (move copied_bundle as? Bundle).expect("second Bundle")
    io.println("{first_bundle.label}:{first_bundle.items[0]}:{second_bundle.items[1]}")

    let optional: Option<string> = some("present")
    let boxed_optional: reflect.Value = reflect.value(move optional)
    io.println((move boxed_optional as? Option<string>).expect(
        "Option").expect("some"))

    let mapping: Map<string, int> = {"one": 1}
    let boxed_mapping: reflect.Value = reflect.value(move mapping)
    io.println((move boxed_mapping as? Map<string, int>).expect("Map")["one"])
}
