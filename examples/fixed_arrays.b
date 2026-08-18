import std.io

fn bumped(values: [i32; 4]) -> [i32; 4] {
    var result: [i32; 4] = values
    result[0] += 10
    return result
}

fn main() {
    var values: [i32; 4] = [1, 2, 3, 4]
    values[1] += 5
    let copy: [i32; 4] = values
    values[0] = 9
    let changed: [i32; 4] = bumped(copy)
    var total: i32 = 0
    for value: i32 in copy {
        total += value
    }
    // This loop changes its source. It keeps the old snapshot behavior while
    // the read-only loop above walks `copy` in place.
    var changing: [i32; 2] = [1, 2]
    var snapshot: i32 = 0
    for value: i32 in changing {
        changing[1] = 9
        snapshot = snapshot * 10 + value
    }
    let same: bool = copy == [1, 7, 3, 4]
    io.println("array {values[0]} {copy[0]} {changed[0]} {changed[3]}")
    io.println("array meta {copy.len()} sum {total} same {same}")
    io.println("array snapshot {snapshot} current {changing[1]}")
}
