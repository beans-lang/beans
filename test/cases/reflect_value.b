import std.io
import std.reflect

class User {
    pub name: string

    fn init(name: string) { self.name = name }
}

// #163: a box records the class the value IS. Three links so a downcast has
// to walk more than one step, an interface on the leaf, and a middle instance
// so "always answer the deepest class" would fail here.
interface Paints { fn paint() -> string }

class Widget {
    pub name: string

    fn init(name: string) { self.name = name }

    pub fn describe() -> string { return "widget" }
}

class Button extends Widget {
    fn init(name: string) { super.init(name) }

    pub override fn describe() -> string { return "button" }
}

class IconButton extends Button implements Paints {
    fn init(name: string) { super.init(name) }

    pub override fn describe() -> string { return "icon" }

    pub fn paint() -> string { return "paint:{self.name}" }
}

// The field and the method are declared at the base and hold the leaf, so the
// field thunk and the callable thunk each box a value whose declared type is
// not the type it holds.
class Panel {
    pub child: Widget

    pub fn init(child: Widget) { self.child = child }

    pub fn first() -> Widget { return self.child }
}

class Cell<T> {
    pub title: string
    pub held: T

    pub fn init(title: string, held: T) {
        self.title = title
        self.held = held
    }
}

class IntCell extends Cell<int> {
    pub fn init(title: string) { super.init(title, 3) }
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

    // #163: every binding in the chain boxes the same runtime class, and the
    // box goes back down every step.
    let icon: IconButton = new IconButton("save")
    let as_button: Button = icon
    let as_widget: Widget = icon
    let as_paints: Paints = icon
    io.println(reflect.value(icon).type().qualified_name())
    io.println(reflect.value(as_button).type().qualified_name())
    io.println(reflect.value(as_widget).type().qualified_name())
    io.println(reflect.value(as_paints).type().qualified_name())

    let widened: reflect.Value = reflect.value(as_widget)
    io.println((widened as? IconButton).expect("IconButton").paint())
    io.println((widened as? Button).is_some())
    io.println((widened as? Widget).is_some())
    io.println(widened.is_type(type_of(IconButton)))
    io.println(widened.is_type(type_of(Paints)))

    // a middle instance reports the middle and refuses the leaf
    let plain_button: Button = new Button("ok")
    let narrowed: reflect.Value = reflect.value(plain_button as Widget)
    io.println(narrowed.type().qualified_name())
    io.println((narrowed as? IconButton).is_none())
    io.println((narrowed as? Button).is_some())

    // a reflective field read and a reflective call result box the value they
    // carry, not the type they were declared with
    let panel: Panel = new Panel(as_widget)
    let boxed_panel: reflect.Value = reflect.value(panel)
    let child: reflect.Field = type_of(Panel).field("child").expect("child")
    let read: reflect.Value = child.get(boxed_panel).expect("read child")
    io.println(read.type().qualified_name())
    let first: reflect.Method = type_of(Panel).method("first").expect("first")
    let called: reflect.Value = first.call(boxed_panel, []).expect("call first")
    io.println(called.type().qualified_name())
    io.println((called as? IconButton).expect("leaf back").describe())

    // a receiver boxed at the base dispatches to the class it really is
    let describe: reflect.Method =
        type_of(Widget).method("describe").expect("describe")
    let answered: reflect.Value =
        describe.call(widened, []).expect("call describe")
    io.println((answered as? string).expect("string"))

    // a closed generic keeps its arguments, and a plain leaf under a generic
    // base still names itself
    let numbers: Cell<int> = new Cell<int>("numbers", 4)
    let letters: Cell<string> = new Cell<string>("letters", "four")
    let leaf_cell: IntCell = new IntCell("leaf")
    let leaf_at_base: Cell<int> = leaf_cell
    io.println(reflect.value(numbers).type().qualified_name())
    io.println(reflect.value(letters).type().qualified_name())
    io.println(reflect.value(leaf_cell).type().qualified_name())
    io.println(reflect.value(leaf_at_base).type().qualified_name())
}
