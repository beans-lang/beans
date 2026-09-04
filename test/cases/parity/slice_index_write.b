// #61: writing through a Slice<T> by index. The checker accepts `view[i] = v`
// and `view[i] += v`, the tree interpreter runs both, and the native backend
// refused them at build time with a message about the emitter — one backend
// could not emit what the other ran. A Slice<T> is the borrowed-view type, so
// an indexed write is the ordinary use, not an exotic one; it lowers to the
// same address arithmetic the read already does, plus a store.
//
// Every shape that reaches the index-store path is here, and the interpreter,
// a debug build and a release build have to answer the same bytes:
//
//   * a plain store `view[i] = v`, at a constant index and a computed one
//   * every compound the language spells: += -= *= /= %=, on ints and floats
//   * n = 1, n = 2 and n = many (a loop over 128 elements)
//   * scalar widths i32, i64, u8 (the u8 write wraps, both backends alike)
//   * a struct element (an extern "C" struct copied in whole)
//   * a subslice, whose write lands in the parent's memory
//
// Slice elements are held to the raw-pointee set by the checker, so they are
// always POD: no ARC, hence no arc+/arc- markers — the answers carry the proof.
package main

import std.io

extern "C" struct Packet {
    tag: u8
    count: u32
}

fn main() {
    unsafe {
        // n = 1: a one-element view, written and read back.
        let one: RawPtr<i32> = RawPtr.alloc(1)
        let ov: Slice<i32> = Slice.from_raw(one, 1)
        ov[0] = 42
        ov[0] += 8
        io.println("n1 {ov[0]}")
        one.free()

        // n = 2: two elements, each touched once.
        let two: RawPtr<i32> = RawPtr.alloc(2)
        let tv: Slice<i32> = Slice.from_raw(two, 2)
        tv[0] = 3
        tv[1] = 4
        tv[0] *= tv[1]
        io.println("n2 {tv[0]} {tv[1]}")
        two.free()

        // n = many: 128 elements, written with a computed index in a loop,
        // then summed by reading each back. This is the case one or two
        // literals never prove.
        let big: RawPtr<i64> = RawPtr.alloc(128)
        let bv: Slice<i64> = Slice.from_raw(big, 128)
        var i: int = 0
        for i < 128 {
            bv[i] = ((i * 2) as i64)
            i += 1
        }
        i = 0
        for i < 128 {
            bv[i] += 1
            i += 1
        }
        var sum: i64 = 0
        i = 0
        for i < 128 {
            sum += bv[i]
            i += 1
        }
        io.println("nmany sum {sum} first {bv[0]} last {bv[127]}")
        big.free()

        // every compound the parser accepts, on one scalar cell.
        let c: RawPtr<i32> = RawPtr.alloc(1)
        let cv: Slice<i32> = Slice.from_raw(c, 1)
        cv[0] = 100
        cv[0] += 5
        cv[0] -= 3
        cv[0] *= 2
        cv[0] /= 4
        cv[0] %= 7
        io.println("compound {cv[0]}")
        c.free()

        // floats: compound arithmetic through the view.
        let fp: RawPtr<f64> = RawPtr.alloc(2)
        let fv: Slice<f64> = Slice.from_raw(fp, 2)
        fv[0] = 1.5
        fv[1] = 4.0
        fv[0] += fv[1]
        fv[1] /= 2.0
        io.println("float {fv[0]} {fv[1]}")
        fp.free()

        // u8: a store that overflows the byte wraps the same way on both.
        let up: RawPtr<u8> = RawPtr.alloc(1)
        let uv: Slice<u8> = Slice.from_raw(up, 1)
        uv[0] = 250
        uv[0] += 10
        io.println("u8 {uv[0]}")
        up.free()

        // a struct element: the whole record is copied into the cell.
        let sp: RawPtr<Packet> = RawPtr.alloc(2)
        let sv: Slice<Packet> = Slice.from_raw(sp, 2)
        sv[0] = Packet { tag: 7, count: 999 }
        sv[1] = sv[0]
        io.println("struct {sv[1].tag} {sv[1].count}")
        sp.free()

        // a subslice is a view of the same memory; a write through it is
        // visible in the parent.
        let q: RawPtr<i32> = RawPtr.alloc(6)
        var j: int = 0
        for j < 6 {
            q.offset(j).write((j as i32))
            j += 1
        }
        let full: Slice<i32> = Slice.from_raw(q, 6)
        let sub: Slice<i32> = full.subslice(2, 5)
        sub[0] = 777
        sub[2] += 100
        io.println("subslice {full[2]} {full[4]} sub {sub[0]} {sub[2]}")
        q.free()
    }
}
