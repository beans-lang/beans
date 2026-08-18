extern "C" fn host_offset(value: i32) -> i32

pub extern "C" fn apply_offset(value: i32) -> i32 as "beans_apply_offset" {
    unsafe {
        return host_offset(value)
    }
}
