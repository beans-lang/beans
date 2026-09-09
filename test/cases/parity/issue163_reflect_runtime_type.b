// #163: a reflective box records the type the value IS, not the type of the
// binding it was handed. Boxing a subclass through a base-class binding used
// to produce a Value that reported the base and could not be downcast back —
// the runtime type was lost, not hidden, and virtual dispatch on the very
// same binding already answered with the leaf.
//
// This is a parity case because the two backends reach the answer by
// different routes and have to arrive at the same one. The native emitter
// reads the class descriptor at the object's first word — the same word `as?`
// reads — and turns its class id into a name through @beans_class_names. The
// tree interpreter reads the class name the object records for itself and
// rebuilds a generic instantiation from the bindings it captured. Neither is
// checkable against the other except here.
//
// Four routes reach a box and all four are here, because they are four
// different pieces of emitted code: `reflect.value`, a reflective field read,
// a reflective call's result, and a reflective construction. Three bindings
// in a three-link chain plus an interface cover the shapes a class value can
// arrive through, and a middle-class instance boxed at the base is the
// negative: it must report the middle and refuse the leaf, so "always answer
// the deepest class" would fail here.
//
// What must NOT change is the other half. A struct, an enum, a primitive, a
// List, a Map and an Option are at runtime exactly the type their binding
// declares, so their boxes still record the static type — including
// `Option<Component>` holding a leaf, whose stored value really is an option
// of the base. And a closed generic has to keep its arguments: an
// instantiation is its own runtime class, so `Grid<int>` may never come back
// as the open `Grid`.
//
// The markers cover ownership: `reflect.value` takes the payload, `as?`
// copies it back out, and a Value releases what it holds when it dies.
//
// Every Value here is bound to a name on purpose. `reflect.value(move local)`
// is a named local moved into a moved-in parameter, and that shape is #155,
// where the two backends released the payload at different points. Binding
// gives the value an owner that outlives the statement on both backends, so
// this case measures its own rule and nothing else. Keep the bindings: they
// are what makes an ownership disagreement elsewhere unable to fail this
// case, and #155's markers balanced either way, so check_effects would not
// have caught it — only the answer diff would.
package main

import std.io
import std.reflect

interface Drawable {
    fn draw() -> string
}

class Component {
    pub label: string

    pub fn init(label: string) {
        self.label = label
        io.println("arc+{label}")
    }

    fn deinit() { io.println("arc-{self.label}") }

    pub fn tag() -> string { return "component" }
}

class Hint extends Component {
    pub fn init(label: string) { super.init(label) }

    pub override fn tag() -> string { return "hint" }
}

class Tip extends Hint implements Drawable {
    pub fn init(label: string) { super.init(label) }

    pub override fn tag() -> string { return "tip" }

    pub fn draw() -> string { return "draw:{self.label}" }
}

// A field and a method both declared at the base and both holding a leaf:
// the field read and the call result are boxed by their own emitted thunks,
// not by the `reflect.value` path.
class Holder {
    pub slot: Component

    pub fn init(slot: Component) { self.slot = slot }

    pub fn peek() -> Component { return self.slot }
}

// A closed generic is its own runtime class, so its box has to carry the
// arguments. IntGrid is a plain class under a generic base — the leaf a
// generic-base binding holds.
class Grid<T> {
    pub title: string
    pub cell: T

    pub fn init(title: string, cell: T) {
        self.title = title
        self.cell = cell
    }
}

class IntGrid extends Grid<int> {
    pub fn init(title: string) { super.init(title, 7) }
}

struct Point {
    pub x: int
    pub y: int
}

enum Colour {
    red
    green
    blue
}

fn nm(value: reflect.Value) -> string {
    return value.type().qualified_name()
}

fn main() {
    let tip: Tip = new Tip("tip")
    let at_hint: Hint = tip
    let at_component: Component = tip
    let at_interface: Drawable = tip

    // one object, four bindings, one answer
    let box_leaf: reflect.Value = reflect.value(tip)
    let box_middle: reflect.Value = reflect.value(at_hint)
    let box_base: reflect.Value = reflect.value(at_component)
    let box_interface: reflect.Value = reflect.value(at_interface)
    io.println("leaf binding:      {nm(box_leaf)}")
    io.println("middle binding:    {nm(box_middle)}")
    io.println("base binding:      {nm(box_base)}")
    io.println("interface binding: {nm(box_interface)}")

    // the base-typed box goes back down every step of the chain
    io.println("base box as? Tip:       {(box_base as? Tip).is_some()}")
    io.println("base box as? Hint:      {(box_base as? Hint).is_some()}")
    io.println("base box as? Component: {(box_base as? Component).is_some()}")
    let recovered: Tip = (box_base as? Tip).expect("Tip from a base binding")
    io.println("recovered draw:    {recovered.draw()}")

    // the negative: a middle instance at the base reports the middle and
    // refuses the leaf, so this is not "always answer the deepest class"
    let middle: Hint = new Hint("middle")
    let middle_at_base: Component = middle
    let box_middle_only: reflect.Value = reflect.value(middle_at_base)
    io.println("middle only:       {nm(box_middle_only)}")
    io.println("middle as? Tip:    {(box_middle_only as? Tip).is_some()}")
    io.println("middle as? Hint:   {(box_middle_only as? Hint).is_some()}")

    // a base instance stays the base
    let plain: Component = new Component("plain")
    let box_plain: reflect.Value = reflect.value(plain)
    io.println("base instance:     {nm(box_plain)}")
    io.println("base as? Hint:     {(box_plain as? Hint).is_some()}")

    // the relations the recorded name feeds
    io.println("is_type(Tip):       {box_base.is_type(type_of(Tip))}")
    io.println("is_type(Component): {box_base.is_type(type_of(Component))}")
    io.println("is_type(Drawable):  {box_base.is_type(type_of(Drawable))}")
    io.println("middle is_type(Tip):{box_middle_only.is_type(type_of(Tip))}")
    io.println("Component <- box:  {type_of(Component).is_assignable_from(box_base.type())}")
    io.println("Tip <- box:        {type_of(Tip).is_assignable_from(box_base.type())}")
    io.println("Tip <- middle box: {type_of(Tip).is_assignable_from(box_middle_only.type())}")

    // route two: a reflective field read, boxed by the field thunk
    let holder: Holder = new Holder(at_component)
    let box_holder: reflect.Value = reflect.value(holder)
    let slot: reflect.Field =
        type_of(Holder).field("slot").expect("slot")
    let from_field: reflect.Value =
        slot.get(box_holder).expect("read slot")
    io.println("field read:        {nm(from_field)}")
    io.println("field as? Tip:     {(from_field as? Tip).is_some()}")

    // route three: a reflective call's result, boxed by the callable thunk
    let peek: reflect.Method =
        type_of(Holder).method("peek").expect("peek")
    let from_call: reflect.Value =
        peek.call(box_holder, []).expect("call peek")
    io.println("call result:       {nm(from_call)}")
    io.println("result as? Tip:    {(from_call as? Tip).is_some()}")

    // route four: a reflective construction, which already named the exact
    // class it built and still must
    let maker: reflect.Initializer =
        type_of(Tip).initializer().expect("Tip initializer")
    let constructed: reflect.Value =
        maker.call([reflect.value("made")]).expect("construct Tip")
    io.println("constructed:       {nm(constructed)}")

    // a receiver boxed at the base dispatches to the class it really is,
    // the same answer the direct call gives
    let tag: reflect.Method =
        type_of(Component).method("tag").expect("tag")
    let dispatched: reflect.Value =
        tag.call(box_base, []).expect("call tag")
    io.println("virtual via base:  {(dispatched as? string).expect("string")}")
    io.println("direct virtual:    {at_component.tag()}")
    let dispatched_middle: reflect.Value =
        tag.call(box_middle_only, []).expect("call tag on middle")
    io.println("virtual middle:    {(dispatched_middle as? string).expect("string")}")

    // closed generics keep their arguments, at every binding
    let ints: Grid<int> = new Grid<int>("ints", 5)
    let words: Grid<string> = new Grid<string>("words", "five")
    let leaf_grid: IntGrid = new IntGrid("leaf")
    let leaf_at_base: Grid<int> = leaf_grid
    let box_ints: reflect.Value = reflect.value(ints)
    let box_words: reflect.Value = reflect.value(words)
    let box_leaf_grid: reflect.Value = reflect.value(leaf_grid)
    let box_leaf_at_base: reflect.Value = reflect.value(leaf_at_base)
    io.println("Grid<int>:         {nm(box_ints)}")
    io.println("Grid<string>:      {nm(box_words)}")
    io.println("IntGrid:           {nm(box_leaf_grid)}")
    io.println("IntGrid at base:   {nm(box_leaf_at_base)}")
    io.println("grid as? IntGrid:  {(box_leaf_at_base as? IntGrid).is_some()}")
    io.println("ints as? IntGrid:  {(box_ints as? IntGrid).is_some()}")

    // and everything that is already its own type stays exactly as it was
    let number: reflect.Value = reflect.value(7)
    let text: reflect.Value = reflect.value("seven")
    let flag: reflect.Value = reflect.value(false)
    let ratio: reflect.Value = reflect.value(0.5)
    let point: Point = Point { x: 3, y: 4 }
    let record: reflect.Value = reflect.value(move point)
    let shade: reflect.Value = reflect.value(Colour.blue)
    var numbers: List<int> = [1, 2, 3]
    let listed: reflect.Value = reflect.value(move numbers)
    var table: Map<string, int> = {"a": 1, "b": 2}
    let mapped: reflect.Value = reflect.value(move table)
    let maybe: Option<string> = some("here")
    let optional: reflect.Value = reflect.value(move maybe)
    io.println("int:               {nm(number)}")
    io.println("string:            {nm(text)}")
    io.println("bool:              {nm(flag)}")
    io.println("float:             {nm(ratio)}")
    io.println("struct:            {nm(record)}")
    io.println("enum:              {nm(shade)}")
    io.println("list:              {nm(listed)}")
    io.println("map:               {nm(mapped)}")
    io.println("option of string:  {nm(optional)}")
    io.println("struct back:       {(record as? Point).expect("Point").y}")
    io.println("enum back:         {(shade as? Colour).expect("Colour") == Colour.blue}")

    // an option and a list of the base type hold leaves, and both are still
    // an option and a list OF THE BASE: that is what the stored value is
    let maybe_base: Option<Component> = some(at_component)
    let box_maybe_base: reflect.Value = reflect.value(move maybe_base)
    var children: List<Component> = [at_component, middle_at_base, plain]
    let box_children: reflect.Value = reflect.value(move children)
    io.println("option of base:    {nm(box_maybe_base)}")
    io.println("list of base:      {nm(box_children)}")
    io.println("option back:       {(box_maybe_base as? Option<Component>).expect("option").is_some()}")
    io.println("list back:         {(move box_children as? List<Component>).expect("list").len()}")

    // a Value boxed inside a Value is a Value
    let renested: reflect.Value = reflect.value(box_plain)
    io.println("nested:            {nm(renested)}")

    // boxes held in a collection keep the type each one recorded
    var shelf: List<reflect.Value> = []
    shelf.push(reflect.value(at_component))
    shelf.push(reflect.value(middle_at_base))
    shelf.push(reflect.value(9))
    io.println("shelf:             {nm(shelf[0])} {nm(shelf[1])} {nm(shelf[2])}")
}
