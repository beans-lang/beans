@runtime_hook(before: "active_before")
@target(value: ["function"])
annotation active {}

fn active_before(target: string) {}

@runtime_hook(before: "rejected_async_handler")
@target(value: ["function"])
annotation async_provider {}

async fn rejected_async_handler(target: string) {}

@active
async fn rejected_async_target() {}

@runtime_start
async fn rejected_async_start() {}

@runtime_stop
async fn rejected_async_stop() {}

fn main() {}
