fn doubled(value: i32) -> i32 {
    return value * 2
}

pub extern "C" fn add(a: i32, b: i32) -> i32 as "beans_wasm_add" {
    return doubled(a + b)
}
