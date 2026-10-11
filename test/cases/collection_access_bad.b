fn optional_values(buffer: Bytes, view: Slice<i32>) {
    let values: [int; 2] = [1, 2]
    let array_value: int = values.get(0)
    let byte_value: int = buffer.get(0)
    let string_value: int = "x".get_byte(0)
    unsafe {
        let slice_value: i32 = view.get(0)
    }
    buffer[0] += 1
}

fn unsafe_get(view: Slice<i32>) -> Option<i32> {
    return view.get(0)
}

fn main() {}
