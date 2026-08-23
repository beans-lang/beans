extern "C" struct CallbackSlot {
    callback: CFunctionPtr<async fn(i32) -> i32>
}

extern "C" struct NestedSlot {
    slot: CallbackSlot
}

extern "C" fn take_direct(callback: async fn() -> int)
extern "C" fn take_pointer(
    callback: CFunctionPtr<async fn() -> int>)
extern "C" fn take_nested(value: NestedSlot)
extern "C" fn return_direct() -> async fn() -> int
extern "C" var callback_global:
    CFunctionPtr<async fn() -> int>

pub extern "C" fn export_direct(
    callback: async fn() -> int) -> int as "beans_async_export" {
    return 0
}

fn stored_callback(
    value: StoredCallback<async fn(RawPtr<u8>) -> int>) {}

fn local_stored_callback(
    value: LocalStoredCallback<async fn(RawPtr<u8>) -> int>) {}

fn main() {}
