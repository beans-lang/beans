fn c_header_identifier(value: string) -> bool {
    if value == "" { return false }
    let first: int = value.byte_at(0)
    if !((first >= 65 && first <= 90) ||
         (first >= 97 && first <= 122) ||
         first == 95) {
        return false
    }
    for index: int in 1..value.len() {
        let byte: int = value.byte_at(index)
        if !((byte >= 48 && byte <= 57) ||
             (byte >= 65 && byte <= 90) ||
             (byte >= 97 && byte <= 122) ||
             byte == 95) {
            return false
        }
    }
    return true
}

fn c_header_guard(value: string) -> string {
    var result: string = "BEANS_"
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        let character: string =
            value.slice(index, index + 1)
        if (byte >= 48 && byte <= 57) ||
           (byte >= 65 && byte <= 90) ||
           (byte >= 97 && byte <= 122) {
            result = "{result}{character.to_upper()}"
        } else {
            result = "{result}_"
        }
    }
    return "{result}_H"
}

class CHeaderRenderer {
    program: HirProgram
    declarations: Map<string, HirDeclaration>
    selected: Map<string, bool>
    selected_order: List<string>
    c_names: Map<string, string>
    collecting: Map<string, bool>
    emitting: Map<string, bool>
    emitted: Map<string, bool>
    error: string

    fn init(program: HirProgram) {
        self.program = program
        self.declarations = {}
        self.selected = {}
        self.selected_order = []
        self.c_names = {}
        self.collecting = {}
        self.emitting = {}
        self.emitted = {}
        self.error = ""
        for declaration: HirDeclaration in
            program.declarations {
            self.declarations[
                declaration.qualified] = declaration
        }
    }

    fn declaration_for(type: HirType) ->
        Option<HirDeclaration> {
        match self.declarations.get(type.name) {
            some(declaration) => {
                return some(declaration)
            }
            none => {}
        }
        return self.declarations.get(
            canonical_hir_name(type.name))
    }

    fn select(declaration: HirDeclaration) -> bool {
        if !declaration.is_c_layout {
            self.error =
                "type '{declaration.name}' in a C export is not declared extern \"C\""
            return false
        }
        match self.c_names.get(declaration.name) {
            some(previous) => {
                if previous != declaration.qualified {
                    self.error =
                        "two exported C records use the name '{declaration.name}'"
                    return false
                }
            }
            none => {
                self.c_names[
                    declaration.name] =
                    declaration.qualified
            }
        }
        if !self.selected.contains(
               declaration.qualified) {
            self.selected[
                declaration.qualified] = true
            self.selected_order.push(
                declaration.qualified)
        }
        return true
    }

    fn collect(type: HirType) -> bool {
        let name: string =
            canonical_hir_name(type.name)
        if name == "array" && type.args.len() == 1 {
            return self.collect(type.args[0])
        }
        if name == "fn" {
            self.error =
                "C exports with callback types cannot produce a header yet"
            return false
        }
        if name == "RawPtr" {
            if type.args.len() == 1 {
                return self.collect(type.args[0])
            }
            return true
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if !self.select(declaration) {
                    return false
                }
                if declaration.is_opaque ||
                   self.collecting.contains(
                       declaration.qualified) {
                    return true
                }
                self.collecting[
                    declaration.qualified] = true
                for field: HirField in
                    declaration.fields {
                    if !self.collect(field.type) {
                        return false
                    }
                }
                self.collecting.remove(
                    declaration.qualified)
            }
            none => {}
        }
        return true
    }

    fn type_text(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        if name == "unit" { return "void" }
        if name == "i8" { return "int8_t" }
        if name == "u8" || name == "byte" {
            return "uint8_t"
        }
        if name == "i16" { return "int16_t" }
        if name == "u16" { return "uint16_t" }
        if name == "i32" { return "int32_t" }
        if name == "u32" { return "uint32_t" }
        if name == "i64" || name == "int" {
            return "int64_t"
        }
        if name == "u64" { return "uint64_t" }
        if name == "f32" { return "float" }
        if name == "f64" || name == "float" {
            return "double"
        }
        if name == "bool" { return "bool" }
        if name == "array" && type.args.len() == 1 {
            return self.type_text(type.args[0])
        }
        if name == "RawPtr" {
            if type.args.len() != 1 ||
               canonical_hir_name(
                   type.args[0].name) == "array" ||
               canonical_hir_name(
                   type.args[0].name) == "fn" {
                return "void*"
            }
            let pointee: string =
                self.type_text(type.args[0])
            if self.error != "" { return "" }
            if pointee == "void" { return "void*" }
            return "{pointee}*"
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if !self.select(declaration) {
                    return ""
                }
                return declaration.name
            }
            none => {}
        }
        self.error =
            "unsupported C header type '{type.name}'"
        return ""
    }

    fn declaration(type: HirType,
                   name: string) -> string {
        var element: HirType = type
        var dimensions: List<int> = []
        for canonical_hir_name(element.name) == "array" &&
            element.args.len() == 1 {
            dimensions.push(element.array_length)
            element = element.args[0]
        }
        let base: string = self.type_text(element)
        if self.error != "" { return "" }
        var result: string = "{base} {name}"
        for dimension: int in dimensions {
            result = "{result}[{dimension}]"
        }
        return result
    }

    fn direct_record(type: HirType) ->
        Option<HirDeclaration> {
        var element: HirType = type
        for canonical_hir_name(element.name) == "array" &&
            element.args.len() == 1 {
            element = element.args[0]
        }
        if canonical_hir_name(
               element.name) == "RawPtr" {
            return none
        }
        return self.declaration_for(element)
    }

    fn emit_record(
        declaration: HirDeclaration) -> string {
        if declaration.is_opaque ||
           self.emitted.contains(
               declaration.qualified) {
            return ""
        }
        if self.emitting.contains(
               declaration.qualified) {
            self.error =
                "recursive C record '{declaration.name}' has no finite definition"
            return ""
        }
        self.emitting[
            declaration.qualified] = true
        var prefix: string = ""
        for field: HirField in declaration.fields {
            match self.direct_record(field.type) {
                some(child) => {
                    prefix =
                        "{prefix}{self.emit_record(child)}"
                    if self.error != "" { return "" }
                }
                none => {}
            }
        }
        let keyword: string =
            if declaration.kind == "union" {
                "union"
            } else {
                "struct"
            }
        var body: string =
            "{keyword} {declaration.name} \{\n"
        for field: HirField in declaration.fields {
            let rendered: string =
                self.declaration(
                    field.type, field.name)
            if self.error != "" { return "" }
            body = "{body}    {rendered}"
            if field.declared_align != 0 {
                body =
                    "{body} __attribute__((aligned({field.declared_align})))"
            }
            body = "{body};\n"
        }
        body = "{body}\}"
        if declaration.is_packed {
            body =
                "{body} __attribute__((packed))"
        }
        if declaration.declared_align != 0 {
            body =
                "{body} __attribute__((aligned({declaration.declared_align})))"
        }
        body = "{body};\n\n"
        self.emitting.remove(
            declaration.qualified)
        self.emitted[
            declaration.qualified] = true
        return "{prefix}{body}"
    }

    fn render(library_name: string) ->
        Result<string, string> {
        var exports: List<HirFunction> = []
        var symbols: Map<string, bool> = {}
        for function: HirFunction in
            self.program.functions {
            if !function.is_c_export { continue }
            if !c_header_identifier(
                   function.extern_name) {
                return err(
                    "C export symbol '{function.extern_name}' cannot be written in a C header")
            }
            if symbols.contains(
                   function.extern_name) {
                return err(
                    "C export symbol '{function.extern_name}' is defined more than once")
            }
            symbols[function.extern_name] = true
            exports.push(function)
            for parameter: HirParameter in
                function.parameters {
                if !self.collect(parameter.type) {
                    return err(self.error)
                }
            }
            if !self.collect(function.result) {
                return err(self.error)
            }
        }
        if exports.len() == 0 {
            return err(
                "--header needs at least one pub extern \"C\" function")
        }

        var definitions: string = ""
        for qualified: string in
            self.selected_order {
            match self.declarations.get(qualified) {
                some(declaration) => {
                    definitions =
                        "{definitions}{self.emit_record(declaration)}"
                    if self.error != "" {
                        return err(self.error)
                    }
                }
                none => {}
            }
        }

        let guard: string =
            c_header_guard(library_name)
        var output: string =
            "/* generated by beansc; do not edit */\n#ifndef {guard}\n#define {guard}\n\n#include <stdbool.h>\n#include <stdint.h>\n\n"
        for qualified: string in
            self.selected_order {
            match self.declarations.get(qualified) {
                some(declaration) => {
                    if !c_header_identifier(
                           declaration.name) {
                        return err(
                            "C record name '{declaration.name}' cannot be written in a C header")
                    }
                    let keyword: string =
                        if declaration.kind == "union" {
                            "union"
                        } else {
                            "struct"
                        }
                    output =
                        "{output}typedef {keyword} {declaration.name} {declaration.name};\n"
                }
                none => {}
            }
        }
        if self.selected_order.len() != 0 {
            output = "{output}\n"
        }
        output =
            "{output}{definitions}#ifdef __cplusplus\nextern \"C\" \{\n#endif\n\n"
        for function: HirFunction in exports {
            let result: string =
                self.type_text(function.result)
            if self.error != "" {
                return err(self.error)
            }
            output =
                "{output}{result} {function.extern_name}("
            if function.parameters.len() == 0 {
                output = "{output}void"
            } else {
                for index: int in
                    0..function.parameters.len() {
                    if index != 0 {
                        output = "{output}, "
                    }
                    let parameter: string =
                        self.declaration(
                            function.parameters[index].type,
                            function.parameters[index].name)
                    if self.error != "" {
                        return err(self.error)
                    }
                    output =
                        "{output}{parameter}"
                }
            }
            output = "{output});\n"
        }
        output =
            "{output}\n#ifdef __cplusplus\n\} /* extern \"C\" */\n#endif\n\n#endif /* {guard} */\n"
        return ok(output)
    }
}

fn render_c_header(program: HirProgram,
                   library_name: string) ->
    Result<string, string> {
    let renderer: CHeaderRenderer =
        new CHeaderRenderer(program)
    return renderer.render(library_name)
}
