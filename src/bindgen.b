package main

import std.fs
import std.io
import std.path
import std.process

class BindgenGenerator {
    facts: BindgenTargetFacts
    only: Map<string, bool>
    allow_unsupported: bool
    emit_public: bool
    records: Map<string, BindgenRecord>
    typedefs: Map<string, string>
    enums: Map<string, BindgenJson>
    needed_records: Map<string, bool>
    needed_enums: Map<string, bool>
    resolving_typedefs: Map<string, bool>
    errors: List<string>

    fn init(facts: BindgenTargetFacts,
            only: Map<string, bool>,
            allow_unsupported: bool,
            emit_public: bool) {
        self.facts = facts
        self.only = {}
        for name: string in only.keys() {
            self.only[name] = true
        }
        self.allow_unsupported =
            allow_unsupported
        self.emit_public = emit_public
        self.records = {}
        self.typedefs = {}
        self.enums = {}
        self.needed_records = {}
        self.needed_enums = {}
        self.resolving_typedefs = {}
        self.errors = []
    }

    fn selected(name: string) -> bool {
        return self.only.keys().len() == 0 ||
               self.only.contains_key(name)
    }

    // A C integer of a width Clang reported, or "" when Beans has no type of
    // exactly that size. Returning "" rather than the nearest width is the
    // point: a binding that is one byte off is worse than no binding.
    fn integer_of(bytes: int,
                  is_signed: bool) -> string {
        if bytes == 1 {
            return if is_signed { "i8" } else { "u8" }
        }
        if bytes == 2 {
            return if is_signed { "i16" } else { "u16" }
        }
        if bytes == 4 {
            return if is_signed { "i32" } else { "u32" }
        }
        if bytes == 8 {
            return if is_signed { "i64" } else { "u64" }
        }
        return ""
    }

    fn sized(type: string, bytes: int,
             is_signed: bool) -> string {
        let result: string =
            self.integer_of(bytes, is_signed)
        if result != "" { return result }
        self.errors.push(
            "C type '{type}' is {bytes} bytes on this target, which Beans has no integer for")
        return "unit"
    }

    fn scalar(written: string) -> string {
        var type: string =
            written.replace("const ", "")
        type = type.replace("volatile ", "")
        type = type.replace("restrict ", "").trim()
        // `_Atomic` changes how a field may be accessed, not just its layout,
        // and Beans has no way to say that about a C record member. Reading
        // through the qualifier as if it were not there would hand back a
        // binding that silently drops the atomicity.
        if type.starts_with("_Atomic") &&
           (type.len() == 7 ||
            !bindgen_identifier_byte(
                type.byte_at(7))) {
            self.errors.push(
                "_Atomic type '{type}' is unsupported")
            return "unit"
        }
        if type == "int8_t" { return "i8" }
        if type == "uint8_t" { return "u8" }
        if type == "int16_t" { return "i16" }
        if type == "uint16_t" { return "u16" }
        if type == "int32_t" { return "i32" }
        if type == "uint32_t" { return "u32" }
        if type == "int64_t" { return "i64" }
        if type == "uint64_t" { return "u64" }
        if type == "void" { return "unit" }
        if type == "_Bool" || type == "bool" {
            return "bool"
        }
        // Plain `char` is its own type, and whether it is signed is the
        // target's choice — Clang says so with __CHAR_UNSIGNED__.
        if type == "char" {
            return self.sized(
                type, self.facts.char_bytes,
                !self.facts.char_unsigned)
        }
        if type == "signed char" {
            return self.sized(
                type, self.facts.char_bytes, true)
        }
        if type == "unsigned char" {
            return self.sized(
                type, self.facts.char_bytes, false)
        }
        if type == "short" || type == "short int" ||
           type == "signed short" ||
           type == "signed short int" {
            return self.sized(
                type, self.facts.short_bytes, true)
        }
        if type == "unsigned short" ||
           type == "unsigned short int" {
            return self.sized(
                type, self.facts.short_bytes, false)
        }
        if type == "int" || type == "signed" ||
           type == "signed int" {
            return self.sized(
                type, self.facts.int_bytes, true)
        }
        if type == "unsigned" ||
           type == "unsigned int" {
            return self.sized(
                type, self.facts.int_bytes, false)
        }
        if type == "long" || type == "long int" ||
           type == "signed long" ||
           type == "signed long int" {
            return self.sized(
                type, self.facts.long_bytes, true)
        }
        if type == "unsigned long" ||
           type == "unsigned long int" {
            return self.sized(
                type, self.facts.long_bytes, false)
        }
        if type == "long long" ||
           type == "long long int" ||
           type == "signed long long" ||
           type == "signed long long int" {
            return self.sized(
                type, self.facts.long_long_bytes,
                true)
        }
        if type == "unsigned long long" ||
           type == "unsigned long long int" {
            return self.sized(
                type, self.facts.long_long_bytes,
                false)
        }
        // The pointer-width typedefs are mapped by name rather than through
        // their C spelling, because the spelling differs by platform while
        // the meaning does not.
        if type == "size_t" || type == "rsize_t" {
            return self.sized(
                type, self.facts.size_bytes, false)
        }
        if type == "ssize_t" ||
           type == "ptrdiff_t" {
            return self.sized(
                type, self.facts.ptrdiff_bytes, true)
        }
        if type == "uintptr_t" {
            return self.sized(
                type, self.facts.pointer_bytes, false)
        }
        if type == "intptr_t" {
            return self.sized(
                type, self.facts.pointer_bytes, true)
        }
        if type == "float" {
            if self.facts.float_bytes == 4 {
                return "f32"
            }
            if self.facts.float_bytes == 8 {
                return "f64"
            }
            self.errors.push(
                "C 'float' is not 4 or 8 bytes on this target")
            return "unit"
        }
        if type == "double" {
            if self.facts.double_bytes == 8 {
                return "f64"
            }
            if self.facts.double_bytes == 4 {
                return "f32"
            }
            self.errors.push(
                "C 'double' is not 4 or 8 bytes on this target")
            return "unit"
        }
        if type.starts_with("enum ") {
            let name: string =
                type.slice(5, type.len()).trim()
            self.needed_enums[name] = true
            return "i32"
        }
        if type.starts_with("struct ") ||
           type.starts_with("union ") {
            let space: int =
                bindgen_find(type, " ")
            let name: string =
                type.slice(
                    space + 1, type.len()).trim()
            self.needed_records[name] = true
            match self.records.get(name) {
                some(record) => {
                    return record.beans
                }
                none => {
                    return bindgen_name(
                        name, true)
                }
            }
        }
        match self.records.get(type) {
            some(record) => {
                self.needed_records[type] = true
                return record.beans
            }
            none => {}
        }
        self.errors.push(
            "unsupported C type '{type}'")
        return "unit"
    }

    fn parse_type(written: string) -> BindgenCType {
        let type: string =
            bindgen_strip_nullability(written).trim()
        if type.contains("__attribute__((") {
            self.errors.push(
                "C type carries an ABI attribute bindgen does not model: {type}")
            let result: BindgenCType =
                new BindgenCType("base")
            result.text = "void"
            return result
        }
        let parser: BindgenCTypeParser =
            new BindgenCTypeParser(type)
        let result: BindgenCType = parser.parse()
        for error: string in parser.errors {
            self.errors.push(error)
        }
        return result
    }

    fn render_function(type: BindgenCType) -> string {
        if type.children.len() > 7 {
            self.errors.push(
                "C callback has more than 6 parameters, which is unsupported")
            return "fn()"
        }
        // A variadic *callback* has no spelling: `fn(...)` would have to
        // name the tail, and only a call site can. Imports carry `...`
        // through the declaration path instead; this is the stored or
        // borrowed callback case, and it stays out of reach.
        for index: int in 1..type.children.len() {
            if type.children[index].kind == "variadic" {
                self.errors.push(
                    "variadic C callback type is unsupported")
                return "fn()"
            }
        }
        var output: string = "fn("
        for index: int in 1..type.children.len() {
            if index != 1 { output = "{output}, " }
            // A callback passed through another callback is a stored C
            // address, not a callback borrowed by the outer Beans import.
            output =
                "{output}{self.render_type(type.children[index], false)}"
        }
        output = "{output})"
        let result: string =
            if type.children.len() == 0 {
                "unit"
            } else {
                self.render_type(type.children[0], false)
            }
        if result != "unit" {
            output = "{output} -> {result}"
        }
        return output
    }

    fn render_type(type: BindgenCType,
                   borrowed_callback: bool) -> string {
        if type.kind == "variadic" {
            // Only a function declarator may hold one, and the two places
            // that may render it handle it themselves.
            self.errors.push(
                "'...' is not a C type")
            return "unit"
        }
        if type.kind == "pointer" {
            if type.children.len() == 0 {
                self.errors.push(
                    "C pointer has no pointee type")
                return "RawPtr<u8>"
            }
            let inner: BindgenCType = type.children[0]
            if inner.kind == "function" {
                let function: string =
                    self.render_function(inner)
                return if borrowed_callback {
                    function
                } else {
                    bindgen_function_pointer_to(function)
                }
            }
            var pointee: string =
                self.render_type(inner, false)
            if pointee == "unit" { pointee = "u8" }
            return bindgen_pointer_to(pointee)
        }
        if type.kind == "array" {
            if type.text == "" {
                self.errors.push(
                    "flexible arrays are unsupported")
                return "[u8; 0]"
            }
            if type.children.len() == 0 {
                self.errors.push(
                    "C array has no element type")
                return "[u8; 0]"
            }
            return "[{self.render_type(type.children[0], false)}; {type.text}]"
        }
        if type.kind == "function" {
            return self.render_function(type)
        }
        var name: string =
            type.text.replace("const ", "")
        name = name.replace("volatile ", "")
        name = name.replace("restrict ", "").trim()
        if !self.records.contains_key(name) {
            match self.typedefs.get(name) {
                some(alias) => {
                    if alias != name {
                        if self.resolving_typedefs.contains_key(
                               name) {
                            self.errors.push(
                                "cyclic C typedef involving '{name}'")
                            return "unit"
                        }
                        self.resolving_typedefs[name] = true
                        let result: string =
                            self.render_type(
                                self.parse_type(alias),
                                borrowed_callback)
                        self.resolving_typedefs.remove(name)
                        return result
                    }
                }
                none => {}
            }
        }
        return self.scalar(name)
    }

    fn c_type(written: string) -> string {
        return self.render_type(
            self.parse_type(written), true)
    }

    fn function_result(written: string) -> string {
        let type: BindgenCType = self.parse_type(written)
        if type.kind != "function" ||
           type.children.len() == 0 {
            self.errors.push(
                "unsupported C function type '{written}'")
            return "unit"
        }
        return self.render_type(type.children[0], false)
    }

    // A callback parameter is borrowed for one call and keeps the plain `fn`
    // spelling. Stored C function addresses use a distinct pointer type.
    fn field_type(written: string) -> string {
        return self.render_type(
            self.parse_type(written), false)
    }

    fn stored_type(written: string) -> string {
        return self.render_type(
            self.parse_type(written), false)
    }

    fn need(node: BindgenJson) {
        self.c_type(bindgen_type_text(node))
    }

    fn close_dependencies() {
        var changed: bool = true
        for changed {
            changed = false
            let before: int =
                self.needed_records.keys().len()
            let names: List<string> =
                self.needed_records.keys()
            for name: string in names {
                match self.records.get(name) {
                    some(record) => {
                        match record.node.get("inner") {
                            some(inner) => {
                                let clean: int =
                                    self.errors.len()
                                for field:
                                        BindgenJson in
                                    inner.items {
                                    if field.string(
                                           "kind") ==
                                       "FieldDecl" {
                                        self.need(field)
                                    }
                                }
                                bindgen_name_errors(
                                    self, clean,
                                    "record '{record.c_name}'")
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
            }
            changed =
                self.needed_records.keys().len() !=
                    before
        }
    }

    // Attributes that move a record's fields around. Beans has no way to say
    // any of them on an `extern "C" struct`, so a binding that ignored one
    // would describe a layout the C side does not use.
    fn check_record_attributes(
        record: BindgenRecord) {
        match record.node.get("inner") {
            some(inner) => {
                for child: BindgenJson in
                    inner.items {
                    let kind: string =
                        child.string("kind")
                    var what: string = ""
                    if kind == "PackedAttr" {
                        what = "is packed"
                    } else if kind == "AlignedAttr" {
                        what =
                            "sets an explicit alignment"
                    } else if kind ==
                              "MaxFieldAlignmentAttr" {
                        what =
                            "is under #pragma pack"
                    }
                    if what != "" {
                        self.errors.push(
                            "record '{record.c_name}' {what}, which bindgen cannot reproduce exactly")
                    }
                    if kind == "FieldDecl" {
                        match child.get("inner") {
                            some(attributes) => {
                                for attribute: BindgenJson in
                                    attributes.items {
                                    let attribute_kind: string =
                                        attribute.string("kind")
                                    if attribute_kind == "AlignedAttr" ||
                                       attribute_kind == "PackedAttr" ||
                                       attribute_kind == "MaxFieldAlignmentAttr" {
                                        self.errors.push(
                                            "field '{child.string("name")}' in record '{record.c_name}' carries a layout attribute bindgen cannot reproduce exactly")
                                    }
                                }
                            }
                            none => {}
                        }
                    }
                }
            }
            none => {}
        }
    }

    // A C enum binds only when Clang gave it the plain signed-int
    // representation this compiler emits. Anything else — a fixed underlying
    // type, or a value that pushed the whole enum to unsigned — would change
    // what the constants mean.
    fn enum_is_supported(
        name: string,
        node: BindgenJson) -> bool {
        match node.get("fixedUnderlyingType") {
            some(fixed) => {
                self.errors.push(
                    "enum '{name}' has a fixed underlying type, which is unsupported")
                return false
            }
            none => {}
        }
        match node.get("inner") {
            some(values) => {
                for value: BindgenJson in
                    values.items {
                    if value.string("kind") !=
                       "EnumConstantDecl" {
                        continue
                    }
                    var written: string = ""
                    match value.get("type") {
                        some(type) => {
                            written =
                                type.string("qualType")
                        }
                        none => {}
                    }
                    if written != "int" {
                        self.errors.push(
                            "enum '{name}' is represented as '{written}' rather than int, which is unsupported")
                        return false
                    }
                }
            }
            none => {}
        }
        return true
    }

    fn record_text(record: BindgenRecord) ->
        string {
        self.check_record_attributes(record)
        var output: string =
            if self.emit_public {
                "pub extern \"C\" "
            } else {
                "extern \"C\" "
            }
        if !record.complete {
            return "{output}opaque struct {record.beans}\n\n"
        }
        let kind: string =
            if record.is_union {
                "union"
            } else {
                "struct"
            }
        output =
            "{output}{kind} {record.beans} \{\n"
        var index: int = 0
        match record.node.get("inner") {
            some(inner) => {
                for field: BindgenJson in
                    inner.items {
                    if field.string("kind") !=
                       "FieldDecl" {
                        continue
                    }
                    if field.boolean("isBitfield") {
                        self.errors.push(
                            "bitfield '{field.string("name")}' is unsupported")
                        continue
                    }
                    let written: string =
                        bindgen_type_text(field)
                    // An unnamed inner record has no name to refer to, so the
                    // field would point at a type the output never defines.
                    if bindgen_find(
                           written, "(unnamed") >= 0 ||
                       bindgen_find(
                           written, "(anonymous") >= 0 {
                        self.errors.push(
                            "anonymous record in '{record.c_name}' is unsupported")
                        continue
                    }
                    var name: string =
                        field.string("name")
                    if name == "" {
                        name = "field_{index}"
                    }
                    // A public record needs public fields: C has no
                    // private struct members, and a by-value API (Color.r,
                    // Image.width) is unusable from a consumer package
                    // when the record is pub but its rows are not.
                    let row_visibility: string =
                        if self.emit_public { "pub " } else { "" }
                    output =
                        "{output}    {row_visibility}{bindgen_name(name, false)}: {self.field_type(written)}\n"
                    index += 1
                }
            }
            none => {}
        }
        return "{output}\}\n\n"
    }
}

fn run_self_bindgen(
    args: List<string>) -> int {
    var headers: List<string> = []
    var output_path: string = ""
    var target_name: string = ""
    var cpu_name: string = "generic"
    var sysroot: string = ""
    var clang: string = "clang"
    var system_package: string = ""
    var feature_lists: List<string> = []
    var clang_options: List<string> = []
    var only: Map<string, bool> = {}
    // The package clause to write above the bindings. Empty means none, which
    // is only loadable as a lone file — a generated file dropped into a real
    // package directory has to declare that package like every other file.
    var package_name: string = ""
    var allow_unsupported: bool = false
    var emit_public: bool = false
    var passthrough: bool = false
    var index: int = 1
    for index < args.len() {
        let argument: string = args[index]
        if passthrough {
            clang_options.push(argument)
        } else if argument == "--" {
            passthrough = true
        } else if argument == "-o" ||
                  argument == "--target" ||
                  argument == "--cpu" ||
                  argument == "--features" ||
                  argument == "--sysroot" ||
                  argument == "--cc" ||
                  argument == "--package" ||
                  argument == "--system" ||
                  argument == "--only" {
            index += 1
            if index >= args.len() {
                io.eprintln(
                    "bindgen: {argument} needs a value")
                return 2
            }
            if argument == "-o" {
                output_path = args[index]
            } else if argument == "--target" {
                target_name = args[index]
            } else if argument == "--cpu" {
                cpu_name = args[index]
            } else if argument == "--features" {
                feature_lists.push(args[index])
            } else if argument == "--sysroot" {
                sysroot = args[index]
            } else if argument == "--cc" {
                clang = args[index]
            } else if argument == "--package" {
                package_name = args[index]
            } else if argument == "--system" {
                system_package = args[index]
                if !safe_system_package(system_package) {
                    io.eprintln(
                        "error: invalid pkg-config package name '{system_package}'")
                    return 2
                }
            } else {
                only[args[index]] = true
            }
        } else if argument ==
                  "--allow-unsupported" {
            allow_unsupported = true
        } else if argument == "--pub" {
            emit_public = true
        } else {
            headers.push(argument)
        }
        index += 1
    }
    if headers.len() == 0 || output_path == "" {
        io.eprintln(
            "usage: beansc bindgen header.h... -o bindings.b [--package name] [--system pkg-config-name] [--pub]")
        return 2
    }
    let public_prefix: string =
        if emit_public { "pub " } else { "" }
    var target: TargetDescription =
        supported_targets()[0]
    match configured_target(
            target_name, cpu_name,
            feature_lists) {
        ok(selected) => { target = selected }
        err(message) => {
            io.eprintln("bindgen: {message}")
            return 2
        }
    }
    if system_package != "" {
        var cflags: List<string> = []
        match pkg_config_flags(system_package, "--cflags") {
            ok(values) => {
                for value: string in values { cflags.push(value) }
            }
            err(message) => {
                io.eprintln("bindgen: {message}")
                return 1
            }
        }
        match pkg_config_flags(
                system_package, "--variable=includedir") {
            ok(directories) => {
                for directory: string in directories {
                    if directory != "" {
                        cflags.push("-I{directory}")
                    }
                }
            }
            err(message) => {
                io.eprintln("bindgen: {message}")
                return 1
            }
        }
        var include_paths: List<string> = []
        var flag_index: int = 0
        for flag_index < cflags.len() {
            let flag: string = cflags[flag_index]
            if flag == "-I" || flag == "-isystem" {
                flag_index += 1
                if flag_index < cflags.len() {
                    include_paths.push(cflags[flag_index])
                }
            } else if flag.starts_with("-I") && flag.len() > 2 {
                include_paths.push(flag.slice(2, flag.len()))
            } else if flag.starts_with("-isystem") && flag.len() > 8 {
                include_paths.push(flag.slice(8, flag.len()))
            }
            flag_index += 1
        }
        var resolved_headers: List<string> = []
        for header: string in headers {
            var resolved: string =
                if File.exists(header) { header } else { "" }
            if resolved == "" {
                for directory: string in include_paths {
                    let candidate: string = path.join(directory, header)
                    if resolved == "" && File.exists(candidate) {
                        resolved = candidate
                    }
                }
            }
            if resolved == "" {
                io.eprintln(
                    "bindgen: cannot find {header} in pkg-config package '{system_package}'")
                return 1
            }
            resolved_headers.push(resolved)
        }
        headers = move resolved_headers
        for flag: string in cflags { clang_options.push(flag) }
    }
    let command: process.Command =
        new process.Command(clang)
    command.arg("--target={target.llvm_triple()}")
    command.arg("-x")
    command.arg("c-header")
    command.arg("-Xclang")
    command.arg("-ast-dump=json")
    command.arg("-fsyntax-only")
    if sysroot != "" {
        command.arg("--sysroot={sysroot}")
    }
    if cpu_name != "generic" {
        command.arg("-mcpu={cpu_name}")
    }
    for option: string in clang_options {
        command.arg(option)
    }
    if headers.len() > 1 {
        for header_index: int in 0..headers.len() - 1 {
            command.arg("-include")
            command.arg(headers[header_index])
        }
    }
    command.arg(headers[headers.len() - 1])
    var ast: string = ""
    match command.run() {
        ok(result) => {
            if !result.succeeded() {
                let detail: string = result.stderr_text()
                if detail != "" { io.eprint(detail) }
                io.eprintln(
                    "bindgen: clang could not parse {headers.join(", ")}")
                return 1
            }
            ast = result.stdout_text()
        }
        err(error) => {
            io.eprintln(
                "bindgen: cannot start Clang: {error.msg}")
            return 1
        }
    }
    // How wide the C types are is the selected target's business, not this
    // machine's, so it is asked of the same Clang with the same flags rather
    // than assumed from the pointer width.
    let probe: process.Command =
        new process.Command(clang)
    probe.arg("--target={target.llvm_triple()}")
    probe.arg("-dM")
    probe.arg("-E")
    probe.arg("-x")
    probe.arg("c-header")
    if sysroot != "" {
        probe.arg("--sysroot={sysroot}")
    }
    if cpu_name != "generic" {
        probe.arg("-mcpu={cpu_name}")
    }
    for option: string in clang_options {
        probe.arg(option)
    }
    if headers.len() > 1 {
        for header_index: int in 0..headers.len() - 1 {
            probe.arg("-include")
            probe.arg(headers[header_index])
        }
    }
    probe.arg(headers[headers.len() - 1])
    var macros: string = ""
    match probe.run() {
        ok(result) => {
            if !result.succeeded() {
                let detail: string = result.stderr_text()
                if detail != "" { io.eprint(detail) }
                io.eprintln(
                    "bindgen: clang could not describe {target.triple}")
                return 1
            }
            macros = result.stdout_text()
        }
        err(error) => {
            io.eprintln(
                "bindgen: cannot start Clang: {error.msg}")
            return 1
        }
    }
    let facts: BindgenTargetFacts =
        bindgen_read_target_facts(macros)
    let parser: BindgenJsonParser =
        new BindgenJsonParser(ast)
    let root: BindgenJson = parser.value()
    if !parser.ok || root.kind != "object" {
        io.eprintln(
            "bindgen: clang returned an invalid JSON AST")
        return 1
    }
    var type_nodes: List<BindgenJson> = []
    var nodes: List<BindgenJson> = []
    var in_header: bool = false
    match root.get("inner") {
        some(inner) => {
            for node: BindgenJson in inner.items {
                bindgen_collect_type_nodes(
                    node, inout type_nodes)
                let file: string =
                    bindgen_declaration_file(node)
                if file != "" {
                    in_header =
                        bindgen_requested_file(
                            file, headers)
                }
                if in_header { nodes.push(node) }
            }
        }
        none => {}
    }
    let generator: BindgenGenerator =
        new BindgenGenerator(
            facts, only, allow_unsupported,
            emit_public)
    // Type names form one translation-unit-wide environment. Public symbols
    // still come only from the requested header, but their types may have been
    // declared by any header it includes. Records and enums come first so a
    // later typedef can safely give a tag its public alias.
    var anonymous_records: Map<string, BindgenJson> = {}
    var anonymous_enums: Map<string, BindgenJson> = {}
    for node: BindgenJson in type_nodes {
        let kind: string = node.string("kind")
        let name: string = node.string("name")
        if kind == "RecordDecl" && name == "" {
            anonymous_records[node.string("id")] = node
        } else if kind == "RecordDecl" {
            let record: BindgenRecord =
                new BindgenRecord(
                    name,
                    bindgen_name(name, true),
                    node.string("tagUsed") ==
                        "union",
                    node.boolean(
                        "completeDefinition"),
                    node)
            match generator.records.get(name) {
                some(existing) => {
                    if !existing.complete &&
                       record.complete {
                        generator.records[name] =
                            record
                    }
                }
                none => {
                    generator.records[name] = record
                }
            }
        } else if kind == "EnumDecl" {
            if name == "" {
                anonymous_enums[node.string("id")] = node
            } else {
                generator.enums[name] = node
            }
        }
    }
    for node: BindgenJson in type_nodes {
        let kind: string = node.string("kind")
        let name: string = node.string("name")
        if kind == "TypedefDecl" && name != "" {
            let type: string =
                bindgen_type_text(node)
            generator.typedefs[name] = type
            if type.starts_with("struct ") ||
               type.starts_with("union ") {
                let space: int =
                    bindgen_find(type, " ")
                let tag: string =
                    type.slice(
                        space + 1,
                        type.len()).trim()
                if !generator.records.contains_key(tag) {
                    let owned: string =
                        bindgen_owned_tag_id(node)
                    match anonymous_records.get(owned) {
                        some(anonymous) => {
                            generator.records[tag] =
                                new BindgenRecord(
                                    name,
                                    bindgen_name(name, true),
                                    anonymous.string("tagUsed") ==
                                        "union",
                                    anonymous.boolean(
                                        "completeDefinition"),
                                    anonymous)
                        }
                        none => {}
                    }
                }
                match generator.records.get(tag) {
                    some(record) => {
                        let renamed: string =
                            bindgen_name(name, true)
                        generator.records[name] =
                            new BindgenRecord(
                                record.c_name,
                                renamed,
                                record.is_union,
                                record.complete,
                                record.node)
                        record.beans = renamed
                    }
                    none => {}
                }
            } else if type.starts_with("enum ") {
                let tag: string =
                    type.slice(5, type.len()).trim()
                if !generator.enums.contains_key(tag) {
                    let owned: string =
                        bindgen_owned_tag_id(node)
                    match anonymous_enums.get(owned) {
                        some(anonymous) => {
                            generator.enums[tag] = anonymous
                        }
                        none => {}
                    }
                }
            }
        }
    }
    var header_type_declarations: int = 0
    if only.keys().len() == 0 {
        for node: BindgenJson in nodes {
            let kind: string = node.string("kind")
            let name: string = node.string("name")
            if kind == "TypedefDecl" {
                let type: string = bindgen_type_text(node)
                if type.starts_with("struct ") ||
                   type.starts_with("union ") {
                    let space: int = bindgen_find(type, " ")
                    let tag: string =
                        type.slice(space + 1, type.len()).trim()
                    if generator.records.contains_key(tag) {
                        generator.needed_records[tag] = true
                        header_type_declarations += 1
                    }
                } else if type.starts_with("enum ") {
                    let tag: string =
                        type.slice(5, type.len()).trim()
                    if generator.enums.contains_key(tag) {
                        generator.needed_enums[tag] = true
                        header_type_declarations += 1
                    }
                }
                continue
            }
            if name == "" { continue }
            if kind == "RecordDecl" {
                generator.needed_records[name] = true
                header_type_declarations += 1
            } else if kind == "EnumDecl" {
                generator.needed_enums[name] = true
                header_type_declarations += 1
            }
        }
    }
    var selected: List<BindgenJson> = []
    var bindable: int = 0
    var matched: Map<string, bool> = {}
    for node: BindgenJson in nodes {
        let kind: string = node.string("kind")
        let name: string = node.string("name")
        if kind != "FunctionDecl" &&
           kind != "VarDecl" {
            continue
        }
        bindable += 1
        if !generator.selected(name) { continue }
        matched[name] = true
        // An import can only name a symbol the linker will find. A `static`
        // declaration has none, and a C `inline` definition is not required
        // to emit one either, so neither becomes an extern binding.
        let storage: string =
            node.string("storageClass")
        // GNU extern-inline normally suppresses an out-of-line symbol. C99
        // extern-inline may be linkable, so only keep it when GNU semantics
        // are not attached to the declaration.
        let inlined: bool =
            node.boolean("inline") &&
            (storage != "extern" ||
             bindgen_has_kind(node, "GNUInlineAttr"))
        if storage == "static" || inlined {
            let why: string =
                if storage == "static" {
                    "has internal linkage"
                } else {
                    "is C inline with no external definition"
                }
            // Skipping is right for a sweep, but if the user asked for this
            // name by hand, silence would look like it had been bound.
            if only.keys().len() != 0 {
                generator.errors.push(
                    "--only names '{name}', which {why} and is not externally linkable")
            }
            continue
        }
        // A variadic import binds as `fn name(fixed..., ...)`; each call
        // site writes its own tail. C gives `...` no meaning without a
        // named parameter in front of it, so a prototype that has none is
        // still out of reach.
        if kind == "FunctionDecl" &&
           node.boolean("variadic") &&
           bindgen_parameter_count(node) == 0 {
            generator.errors.push(
                "variadic function '{name}' has no fixed parameter, so it cannot be written as `fn {name}(..., ...)`")
            continue
        }
        // Clang writes a non-default convention into the function's type.
        // Calling one with the platform default would corrupt the stack.
        let written: string =
            bindgen_type_text(node)
        if bindgen_find(
               written, "__attribute__((") >= 0 {
            generator.errors.push(
                "declaration '{name}' carries an ABI attribute bindgen does not model: {written}")
            continue
        }
        selected.push(node)
        let clean: int = generator.errors.len()
        if kind == "VarDecl" {
            generator.need(node)
        } else {
            generator.function_result(
                bindgen_type_text(node))
        }
        match node.get("inner") {
            some(parameters) => {
                for parameter: BindgenJson in
                    parameters.items {
                    if parameter.string("kind") ==
                       "ParmVarDecl" {
                        generator.need(parameter)
                    }
                }
            }
            none => {}
        }
        bindgen_name_errors(
            generator, clean, "declaration '{name}'")
    }
    generator.close_dependencies()
    // Dependency discovery calls the same type parser as rendering. Keep its
    // diagnostics for the final report, then render from a clean checkpoint so
    // each declaration can be accepted or rejected as one unit.
    var preflight_errors: List<string> = []
    if allow_unsupported {
        for error: string in generator.errors {
            preflight_errors.push(error)
        }
        generator.errors = []
    }
    var output: string =
        "// Generated by beansc bindgen for {target.triple}.\n\n"
    if package_name != "" {
        output = "{output}package {package_name}\n\n"
    }
    // Records and enums come out in name order. A map hands its keys back in
    // whatever order it stored them, and the two bindgen implementations do not
    // store them the same way — sorting is what makes their output identical.
    var record_names: List<string> =
        generator.needed_records.keys()
    record_names.sort()
    var enum_names: List<string> =
        generator.needed_enums.keys()
    enum_names.sort()
    var emitted: Map<string, bool> = {}
    var record_output: Map<string, string> = {}
    var record_order: List<string> = []
    var unsupported_records: Map<string, bool> = {}
    for name: string in record_names {
        match generator.records.get(name) {
            some(record) => {
                if !emitted.contains_key(record.beans) {
                    emitted[record.beans] = true
                    record_order.push(record.beans)
                    let before: int = generator.errors.len()
                    let rendered: string =
                        generator.record_text(record)
                    if generator.errors.len() != before {
                        bindgen_name_errors(
                            generator, before,
                            "record '{record.c_name}'")
                        unsupported_records[record.beans] = true
                    } else {
                        record_output[record.beans] = rendered
                    }
                }
            }
            none => {}
        }
    }
    // A record that stores an unsupported record inline is unsafe too. Close
    // that dependency transitively before any usable-looking text is emitted.
    var changed_records: bool = true
    for changed_records {
        changed_records = false
        for beans: string in record_order {
            if unsupported_records.contains_key(beans) {
                continue
            }
            match record_output.get(beans) {
                some(rendered) => {
                    var unsupported_names: List<string> =
                        unsupported_records.keys()
                    unsupported_names.sort()
                    for unsupported: string in
                        unsupported_names {
                        if bindgen_contains_identifier(
                               rendered, unsupported) {
                            unsupported_records[beans] = true
                            generator.errors.push(
                                "record '{beans}' depends on unsupported record '{unsupported}'")
                            changed_records = true
                            break
                        }
                    }
                }
                none => {}
            }
        }
    }
    var emitted_records: int = 0
    for beans: string in record_order {
        if unsupported_records.contains_key(beans) {
            continue
        }
        match record_output.get(beans) {
            some(rendered) => {
                output = "{output}{rendered}"
                emitted_records += 1
            }
            none => {}
        }
    }
    var emitted_enums: int = 0
    for name: string in enum_names {
        match generator.enums.get(name) {
            some(declaration) => {
                if !generator.enum_is_supported(
                        name, declaration) {
                    continue
                }
                var next: int = 0
                var body: string = ""
                var usable: bool = true
                match declaration.get("inner") {
                    some(values) => {
                        for value: BindgenJson in
                            values.items {
                            if !usable { continue }
                            if value.string("kind") !=
                               "EnumConstantDecl" {
                                continue
                            }
                            match value.get("inner") {
                                some(children) => {
                                    if children.items.len() !=
                                           0 {
                                        let first:
                                            BindgenJson =
                                            children.items[0]
                                        let stated: string =
                                            first.string("value")
                                        if stated != "" {
                                            // Emitting a wrong constant is
                                            // worse than emitting none, so a
                                            // value this compiler cannot read
                                            // exactly is an error rather than
                                            // a silent zero.
                                            match stated.to_int() {
                                                ok(number) => {
                                                    next = number
                                                }
                                                err(error) => {
                                                    generator.errors.push(
                                                        "enum '{name}' value '{value.string("name")}' = {stated} cannot be represented")
                                                    usable = false
                                                }
                                            }
                                        }
                                    }
                                }
                                none => {}
                            }
                            if !usable { continue }
                            if next < -2147483648 ||
                               next > 2147483647 {
                                generator.errors.push(
                                    "enum '{name}' value '{value.string("name")}' does not fit in a signed 32-bit integer")
                                usable = false
                                continue
                            }
                            body =
                                "{body}{public_prefix}fn {bindgen_name(value.string("name"), false)}() -> i32 \{ return {next} \}\n"
                            next += 1
                        }
                    }
                    none => {}
                }
                if usable {
                    output = "{output}{body}\n"
                    emitted_enums += 1
                }
            }
            none => {}
        }
    }
    var emitted_declarations: int = 0
    for node: BindgenJson in selected {
        let kind: string = node.string("kind")
        let c_name: string = node.string("name")
        let local: string =
            bindgen_name(c_name, false)
        let before: int = generator.errors.len()
        var declaration_output: string = ""
        if kind == "VarDecl" {
            var qualified: string = ""
            match node.get("type") {
                some(type) => {
                    qualified =
                        type.string("qualType")
                }
                none => {}
            }
            declaration_output =
                if emit_public {
                    "pub extern \"C\" "
                } else {
                    "extern \"C\" "
                }
            if node.string("tls") != "" {
                declaration_output =
                    "{declaration_output}thread_local "
            }
            let binding: string =
                if qualified.contains("const ") {
                    "let"
                } else {
                    "var"
                }
            declaration_output =
                "{declaration_output}{binding} {local}: {generator.stored_type(bindgen_type_text(node))}"
            if local != c_name {
                declaration_output =
                    "{declaration_output} as \"{c_name}\""
            }
            declaration_output =
                "{declaration_output}\n"
        } else {
            declaration_output =
                "{public_prefix}extern \"C\" fn {local}("
            var count: int = 0
            match node.get("inner") {
                some(parameters) => {
                    for parameter: BindgenJson in
                        parameters.items {
                        if parameter.string("kind") !=
                           "ParmVarDecl" {
                            continue
                        }
                        if count != 0 {
                            declaration_output =
                                "{declaration_output}, "
                        }
                        var parameter_name: string =
                            parameter.string("name")
                        if parameter_name == "" {
                            parameter_name =
                                "arg{count}"
                        }
                        declaration_output =
                            "{declaration_output}{bindgen_name(parameter_name, false)}: {generator.c_type(bindgen_type_text(parameter))}"
                        count += 1
                    }
                }
                none => {}
            }
            if node.boolean("variadic") && count != 0 {
                declaration_output =
                    "{declaration_output}, ..."
            }
            declaration_output =
                "{declaration_output})"
            let result: string =
                generator.function_result(
                    bindgen_type_text(node))
            if result != "unit" {
                declaration_output =
                    "{declaration_output} -> {result}"
            }
            if local != c_name {
                declaration_output =
                    "{declaration_output} as \"{c_name}\""
            }
            declaration_output =
                "{declaration_output}\n"
        }
        if generator.errors.len() != before {
            bindgen_name_errors(
                generator, before, "declaration '{c_name}'")
        }
        var unsafe_dependency: string = ""
        for unsupported: string in
            unsupported_records.keys() {
            if bindgen_contains_identifier(
                   declaration_output, unsupported) {
                unsafe_dependency = unsupported
            }
        }
        if unsafe_dependency != "" {
            generator.errors.push(
                "declaration '{c_name}' depends on unsupported record '{unsafe_dependency}'")
        }
        if generator.errors.len() == before &&
           unsafe_dependency == "" {
            output = "{output}{declaration_output}"
            emitted_declarations += 1
        }
    }
    // A name the user asked for by hand that no declaration carries is a
    // mistake worth reporting, not an empty file.
    for wanted: string in only.keys() {
        if !matched.contains_key(wanted) {
            generator.errors.push(
                "--only names '{wanted}', which the header does not declare")
        }
    }

    // Reporting success after writing nothing but the header comment is how
    // the macro-location bug stayed hidden. An empty header may legitimately
    // produce an empty binding; a header full of declarations may not.
    let produced: int =
        emitted_records + emitted_enums +
        emitted_declarations
    if produced == 0 &&
       (bindable != 0 ||
        header_type_declarations != 0) &&
       only.keys().len() == 0 {
        generator.errors.push(
            "no declaration of {headers.join(", ")} could be bound, so the output would hold nothing")
    }

    if generator.errors.len() != 0 &&
       !allow_unsupported {
        for error: string in generator.errors {
            io.eprintln("bindgen: {error}")
        }
        return 1
    }
    if allow_unsupported {
        var reported: Map<string, bool> = {}
        for error: string in preflight_errors {
            if !reported.contains_key(error) {
                reported[error] = true
                output =
                    "{output}\n// skipped: {error}\n"
            }
        }
        for error: string in generator.errors {
            if !reported.contains_key(error) {
                reported[error] = true
                output =
                    "{output}\n// skipped: {error}\n"
            }
        }
    }
    match fs.write(output_path, output) {
        ok(_) => {
            io.println("wrote {output_path}")
            return 0
        }
        err(error) => {
            io.eprintln(
                "bindgen: cannot write {output_path}: {error.msg}")
            return 1
        }
    }
}
