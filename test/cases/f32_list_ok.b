import std.io

struct Column {
    values: List<f32>
}

fn main() {
    // every list operation over the 4-byte typed representation
    var xs: List<f32> = [1.5, -2.25, 3.75]
    xs.push(0.5)
    xs[1] = 9.5
    let picked: f32 = xs[2]
    xs.insert(1, 4.5)
    let removed: f32 = xs.remove(0)
    let popped: f32 = xs.pop().or(0.0)
    var total: f32 = 0.0
    for value: f32 in xs {
        total += value
    }
    io.println("len={xs.len()} picked={picked} removed={removed} popped={popped} total={total}")
    io.println("contains={xs.contains(9.5)} index={xs.index_of(9.5)}")
    io.println("first={xs.first().or(0.0)} last={xs.last().or(0.0)}")

    // ordering helpers see real f32 order, negatives included
    var order: List<f32> = [1.5, -2.25, 3.75, -0.5]
    io.println("min={order.min().or(99.0)} max={order.max().or(99.0)}")
    order.sort()
    io.println("sorted={order[0]} {order[1]} {order[2]} {order[3]}")

    // clones, slices, and display walk the typed buffer
    let copied: List<f32> = xs.clone()
    io.println("clone={copied.len()} {copied[0]}")
    io.println("show={xs}")
    let cut: List<f32> = xs.slice(0, 2)
    io.println("slice={cut.len()} {cut[0]} {cut[1]}")
    order.reverse()
    io.println("reversed={order[0]} {order[3]}")

    // a struct-held column mutates in place
    var column: Column = Column { values: [9.5] }
    column.values.push(8.5)
    column.values[0] = 7.5
    io.println("column: {column.values[0]} {column.values[1]}")
}
