@runtime_hook
@target(value: ["function"])
annotation no_phase {}

@runtime_hook(before: "missing_handler")
@target(value: ["function"])
annotation missing {}

@runtime_hook(before: "wrong_signature")
@target(value: ["function"])
annotation wrong {
    value: int
}

fn wrong_signature(target: int, value: string) -> int {
    return 1
}

@runtime_hook(before: "wrong_parameters")
@target(value: ["function"])
annotation wrong_parameters_schema {
    value: int
}

fn wrong_parameters(target: int, value: string) {}

@runtime_hook(before: "source_handler")
@target(value: ["function"])
@retention(value: "source")
annotation source_hook {}

fn source_handler(target: string) {}

@runtime_hook(before: "target_handler")
@target(value: ["type"])
annotation wrong_target {}

fn target_handler(target: string) {}

@runtime_hook(before: "active_provider")
@target(value: ["function"])
annotation active {}

@active
fn active_provider(target: string) {}

@active
fn generic_target<T>() {}

@runtime_start
@runtime_stop
fn invalid_lifecycle(value: int) -> int {
    return value
}

fn main() {}
