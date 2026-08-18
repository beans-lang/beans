package main

fn atomic_element_bits(type: HirType) -> int {
    if type.name == "bool" { return 8 }
    if hir_is_integer(type) {
        return integer_literal_bits(type.name)
    }
    return 0
}

fn memory_order_value(name: string) -> int {
    if name == "relaxed" { return 0 }
    if name == "acquire" { return 1 }
    if name == "release" { return 2 }
    if name == "acq_rel" { return 3 }
    if name == "seq_cst" { return 4 }
    return -1
}

fn memory_order_strength(order: int) -> int {
    if order == 0 { return 0 }
    if order == 1 || order == 2 { return 1 }
    if order == 3 { return 2 }
    if order == 4 { return 3 }
    return -1
}
