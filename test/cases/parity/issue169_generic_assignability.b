// Issue #169: `std.reflect` answered two different, and opposite, wrong things
// about whether one type name stands for another, and the two backends did not
// even agree on which.
//
// Rows are filed under the declaring declaration's own name, and every lookup
// strips the type arguments to reach them -- that is how `main.Grid<int>` finds
// what `main.Grid` declares. Assignability is not a lookup, and comparing the
// two names that way is wrong in both directions:
//
//   * the native runtime compared base names in the chain, so an `IntGrid` --
//     which is a `Grid<int>` -- was assignable to `Grid<string>`. A wrong
//     answer, not a refusal, on the type of a value.
//   * the native runtime compared exact strings at the top, so a `Grid<int>`
//     was NOT assignable to `Grid`, the very declaration its members are filed
//     under. That is what made a reflective call refuse a receiver that
//     `Value.is_type` and `Type.is_assignable_from` had both just accepted.
//   * the interpreter compared exact strings in both positions, so it was
//     wrong on the first pair the safe way and wrong on the second the same
//     way native was.
//
// One rule now: two names stand for each other when they are equal, or when
// the wanted one carries no type arguments and the two share a base. Two
// different argument lists never match.
//
// This case is in the parity gate because the claim is that both backends
// answer alike -- but "alike" is not enough here, since before the fix the
// interpreter was wrong in the safe direction on rows the native backend got
// wrong in the unsafe one, and a case that only diffed the two legs would go
// green the moment they agreed on a wrong answer. So every row carries the
// answer it must have and the program panics if any row misses, which fails
// the run on whichever leg is wrong. The receivers carry arc markers as well,
// so the reflect value boxes are held and dropped the same number of times on
// both backends.
package main

import std.io
import std.reflect

pub interface Shape<T> { fn area() -> int }

pub class Node {
    tag: string
    pub label: string = ""
    fn init(tag: string) {
        self.tag = tag
        io.println("arc+{tag}")
    }
    fn deinit() { io.println("arc-{self.tag}") }
}

pub class Grid<T> extends Node {
    pub title: string = ""
    fn init(tag: string) { super.init(tag) }
}

pub class IntGrid extends Grid<int> {
    fn init(tag: string) { super.init(tag) }
}

pub class DeepGrid extends IntGrid {
    fn init(tag: string) { super.init(tag) }
}

pub class StrGrid extends Grid<string> {
    fn init(tag: string) { super.init(tag) }
}

pub class Hint extends Node {
    pub title: string = ""
    fn init(tag: string) { super.init(tag) }
}

pub class Plain {
    pub title: string = ""
    fn init() {}
}

pub class Pair<A, B> {
    fn init() {}
}

pub class Tile implements Shape<int> {
    fn init() {}
    pub fn area() -> int { return 1 }
}

pub class SubTile extends Tile {
    fn init() { super.init() }
}

class Checks {
    bad: int = 0
    fn init() {}
    fn flag(label: string, got: bool, want: bool) {
        io.println("{label} = {got}")
        if got != want {
            io.println("  WRONG: wanted {want}")
            self.bad += 1
        }
    }
    fn done() {
        if self.bad != 0 {
            panic("{self.bad} reflection answers were wrong")
        }
    }
}

// The open, argument-free name of a generic declaration. `type_of` cannot
// spell it -- a generic type has to be written closed -- so it comes out of
// the registry, which files every row under exactly this name.
fn open(name: string) -> reflect.Type {
    match reflect.find_type(name) {
        some(found) => { return found }
        none => { panic("no registered type {name}") }
    }
}

fn assignability(checks: Checks) {
    let grid_open: reflect.Type = open("main.Grid")
    let grid_int: reflect.Type = type_of(Grid<int>)
    let grid_str: reflect.Type = type_of(Grid<string>)
    let int_grid: reflect.Type = type_of(IntGrid)
    let deep_grid: reflect.Type = type_of(DeepGrid)
    let str_grid: reflect.Type = type_of(StrGrid)
    let node: reflect.Type = type_of(Node)
    let hint: reflect.Type = type_of(Hint)
    let plain: reflect.Type = type_of(Plain)

    // an argument-free name is the declaration itself: every instantiation of
    // it, and everything below any of them, is one
    checks.flag("Grid       <- Grid<int>",
                grid_open.is_assignable_from(grid_int), true)
    checks.flag("Grid       <- Grid<string>",
                grid_open.is_assignable_from(grid_str), true)
    checks.flag("Grid       <- IntGrid",
                grid_open.is_assignable_from(int_grid), true)
    checks.flag("Grid       <- DeepGrid",
                grid_open.is_assignable_from(deep_grid), true)
    checks.flag("Grid       <- StrGrid",
                grid_open.is_assignable_from(str_grid), true)

    // one instantiation accepts itself and everything below it
    checks.flag("Grid<int>  <- Grid<int>",
                grid_int.is_assignable_from(grid_int), true)
    checks.flag("Grid<int>  <- IntGrid",
                grid_int.is_assignable_from(int_grid), true)
    checks.flag("Grid<int>  <- DeepGrid",
                grid_int.is_assignable_from(deep_grid), true)
    checks.flag("Grid<str>  <- StrGrid",
                grid_str.is_assignable_from(str_grid), true)

    // and nothing under a different argument list -- the rows native answered
    // `true` for, one link down and two
    checks.flag("Grid<str>  <- IntGrid",
                grid_str.is_assignable_from(int_grid), false)
    checks.flag("Grid<str>  <- DeepGrid",
                grid_str.is_assignable_from(deep_grid), false)
    checks.flag("Grid<int>  <- StrGrid",
                grid_int.is_assignable_from(str_grid), false)
    checks.flag("Grid<int>  <- Grid<string>",
                grid_int.is_assignable_from(grid_str), false)
    checks.flag("Grid<str>  <- Grid<int>",
                grid_str.is_assignable_from(grid_int), false)

    // a plain base above a generic one still answers for everything below it
    checks.flag("Node       <- Grid<int>",
                node.is_assignable_from(grid_int), true)
    checks.flag("Node       <- DeepGrid",
                node.is_assignable_from(deep_grid), true)
    checks.flag("Node       <- Hint",
                node.is_assignable_from(hint), true)

    // unrelated types stay unrelated in both directions
    checks.flag("Hint       <- Grid<int>",
                hint.is_assignable_from(grid_int), false)
    checks.flag("Grid<int>  <- Hint",
                grid_int.is_assignable_from(hint), false)
    checks.flag("Plain      <- Grid<int>",
                plain.is_assignable_from(grid_int), false)

    // two parameters, so the rule cannot be passing by only ever comparing one
    let pair_open: reflect.Type = open("main.Pair")
    let pair_is: reflect.Type = type_of(Pair<int, string>)
    let pair_si: reflect.Type = type_of(Pair<string, int>)
    checks.flag("Pair       <- Pair<int,string>",
                pair_open.is_assignable_from(pair_is), true)
    checks.flag("Pair       <- Pair<string,int>",
                pair_open.is_assignable_from(pair_si), true)
    checks.flag("Pair<i,s>  <- Pair<int,string>",
                pair_is.is_assignable_from(pair_is), true)
    checks.flag("Pair<i,s>  <- Pair<string,int>",
                pair_is.is_assignable_from(pair_si), false)

    // the same rule on the interface edge, reached directly and through a base
    let shape_open: reflect.Type = open("main.Shape")
    let tile: reflect.Type = type_of(Tile)
    let sub_tile: reflect.Type = type_of(SubTile)
    checks.flag("Shape      <- Tile",
                shape_open.is_assignable_from(tile), true)
    checks.flag("Shape<int> <- Tile",
                type_of(Shape<int>).is_assignable_from(tile), true)
    checks.flag("Shape<str> <- Tile",
                type_of(Shape<string>).is_assignable_from(tile), false)
    checks.flag("Shape      <- SubTile",
                shape_open.is_assignable_from(sub_tile), true)
    checks.flag("Shape<int> <- SubTile",
                type_of(Shape<int>).is_assignable_from(sub_tile), true)
    checks.flag("Shape<str> <- SubTile",
                type_of(Shape<string>).is_assignable_from(sub_tile), false)
}

// The same rule seen from a value rather than from two descriptors. Every
// receiver here is boxed at its own runtime type, so the rows say the same
// thing whether the box carries the static type or the runtime one.
fn value_rows(checks: Checks) {
    let grid_open: reflect.Type = open("main.Grid")
    let grid_int: reflect.Type = type_of(Grid<int>)
    let grid_str: reflect.Type = type_of(Grid<string>)

    let one: Grid<int> = new Grid<int>("one")
    let boxed_grid: reflect.Value = reflect.value(move one)
    checks.flag("value(Grid<int>) is Grid<int>",
                boxed_grid.is_type(grid_int), true)
    checks.flag("value(Grid<int>) is Grid<string>",
                boxed_grid.is_type(grid_str), false)
    checks.flag("value(Grid<int>) is Grid",
                boxed_grid.is_type(grid_open), true)
    checks.flag("value(Grid<int>) is Node",
                boxed_grid.is_type(type_of(Node)), true)

    let two: DeepGrid = new DeepGrid("two")
    let boxed_deep: reflect.Value = reflect.value(move two)
    checks.flag("value(DeepGrid) is Grid<int>",
                boxed_deep.is_type(grid_int), true)
    checks.flag("value(DeepGrid) is Grid<string>",
                boxed_deep.is_type(grid_str), false)
    checks.flag("value(DeepGrid) is Grid",
                boxed_deep.is_type(grid_open), true)

    let three: StrGrid = new StrGrid("three")
    let boxed_str: reflect.Value = reflect.value(move three)
    checks.flag("value(StrGrid) is Grid<string>",
                boxed_str.is_type(grid_str), true)
    checks.flag("value(StrGrid) is Grid<int>",
                boxed_str.is_type(grid_int), false)
}

fn main() {
    let checks: Checks = new Checks()
    assignability(checks)
    value_rows(checks)
    checks.done()
    io.println("all rows answered as declared")
}
