// A type name inside a string's `{}` piece is looked up, not composed
// (#164). Every line here names something that is not a type this file can
// reach, and every refusal has to be about the program: the name as
// written, or the package the type really lives in — never a package the
// lookup invented by gluing the asking package onto the simple name.
package main
import std.io
import std.reflect
import interp164bad.kit
import {helper, SIZE} from interp164bad.kit

fn main() {
    io.println("a = {type_of(Nope).qualified_name()}")
    io.println("b = {type_of(helper).qualified_name()}")
    io.println("c = {type_of(SIZE).qualified_name()}")
    io.println("d = {type_of(kit.Hidden).qualified_name()}")
    io.println("e = {type_of(Self).qualified_name()}")
    io.println("f = {new Nope().label()}")
    io.println("g = {(fn(x: Nope) -> int { return 1 })(3)}")
    io.println("h = {size_of(Nope)}")
}
