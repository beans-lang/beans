// Static fields initialise eagerly, before main, in declaration order — which
// follows file order within a package. A constant table built this way costs
// nothing at the point of use, and that is worth holding: it is what lets a
// ramp of generated methods collapse into a table.
//
// The hazard is the other direction. A static read before its initialiser has
// run used to hand back the zero it was born with in a native build, in
// silence, while the interpreter panicked. Both report it now.
package main

class Base {
    static unit: int = 4
}
