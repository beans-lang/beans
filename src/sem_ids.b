package main

fn sem_package_id(import_path: string) -> string {
    return "package:{import_path}"
}

fn sem_type_id(qualified: string) -> string {
    return "type:{qualified}"
}

fn sem_function_id(qualified: string) -> string {
    return "fn:{qualified}"
}

fn sem_field_id(owner: string, name: string) -> string {
    return "field:{owner}.{name}"
}

fn sem_variant_id(owner: string, name: string) -> string {
    return "variant:{owner}.{name}"
}

fn sem_c_global_id(qualified: string) -> string {
    return "cglobal:{qualified}"
}

fn sem_const_id(qualified: string) -> string {
    return "const:{qualified}"
}

fn sem_annotation_id(qualified: string) -> string {
    return "annotation:{qualified}"
}

// A local or parameter is named by the binding id the checker allocated,
// which is unique for the whole program and distinct for every shadow. The
// owning function rides along so an id reads and sorts sensibly.
fn sem_local_id(owner: string, binding: int) -> string {
    return "local:{owner}#{binding}"
}

// An import binding belongs to the file that wrote it, never to its package:
// two files of one package may bind the same short name to different targets.
fn sem_import_id(file: string, binding: string) -> string {
    return "import:{file}#{binding}"
}

// Built-in types and their members have no source declaration. They still get
// exact identity so completion, hover and references can talk about them; only
// go-to-definition has nothing to point at.
fn sem_builtin_type_id(name: string) -> string {
    return "builtin:{name}"
}

fn sem_builtin_member_id(receiver: string, name: string) -> string {
    return "builtin:{receiver}.{name}"
}

fn sem_id_kind(id: string) -> string {
    match id.find(":") {
        some(cut) => { return id.slice(0, cut) }
        none => { return "" }
    }
}

fn sem_id_key(id: string) -> string {
    match id.find(":") {
        some(cut) => { return id.slice(cut + 1, id.len()) }
        none => { return id }
    }
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

fn sem_generic_id(owner: string, name: string) -> string {
    return "generic:{owner}.{name}"
}
