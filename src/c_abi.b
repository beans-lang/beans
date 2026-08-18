package main

class CAbiChecker {
    program: HirProgram
    declarations: Map<string, HirDeclaration>
    errors: List<Diagnostic>

    fn init(program: HirProgram) {
        self.program = program
        self.declarations = {}
        self.errors = []
        for declaration: HirDeclaration in program.declarations {
            self.declarations[declaration.qualified] = declaration
        }
    }

    fn fail_function(function: HirFunction, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: function.file,
            line: function.line,
            col: function.col,
            message: message,
        })
    }

    fn fail_parameter(parameter: HirParameter, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: parameter.file,
            line: parameter.line,
            col: parameter.col,
            message: message,
        })
    }

    fn fail_field(field: HirField, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: field.file,
            line: field.line,
            col: field.col,
            message: message,
        })
    }

    fn fail_global(global: HirCGlobal,
                   message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: global.file,
            line: global.line,
            col: global.col,
            message: message,
        })
    }

    fn is_scalar(type: HirType) -> bool {
        return type.name == "bool" || type.name == "int" ||
               type.name == "i8" || type.name == "i16" ||
               type.name == "i32" || type.name == "i64" ||
               type.name == "uint" || type.name == "byte" ||
               type.name == "u8" || type.name == "u16" ||
               type.name == "u32" || type.name == "u64" ||
               type.name == "float" || type.name == "f32" ||
               type.name == "f64"
    }

    fn is_c_record(type: HirType) -> bool {
        match self.declarations.get(type.name) {
            some(declaration) => {
                return (declaration.kind == "struct" ||
                        declaration.kind == "union") &&
                       declaration.is_c_layout &&
                       !declaration.is_opaque &&
                       declaration.generics.len() == 0
            }
            none => { return false }
        }
    }

    fn is_c_abi_type(type: HirType, allow_unit: bool) -> bool {
        if allow_unit && type.name == "unit" { return true }
        if self.is_scalar(type) { return true }
        if (type.name == "RawPtr" ||
            type.name == "CFunctionPtr") &&
           type.args.len() == 1 {
            if type.name == "CFunctionPtr" {
                return self.is_c_callback(type.args[0])
            }
            return true
        }
        return self.is_c_record(type)
    }

    fn callback_result(type: HirType) -> HirType {
        if type.fn_parameter_count >= 0 &&
           type.fn_parameter_count < type.args.len() {
            return type.args[type.fn_parameter_count]
        }
        return new HirType("unit")
    }

    fn is_c_callback(type: HirType) -> bool {
        if type.name != "fn" || type.fn_parameter_count < 0 ||
           type.fn_parameter_count > 6 {
            return false
        }
        for index: int in 0..type.fn_parameter_count {
            if !self.is_c_abi_type(type.args[index], false) {
                return false
            }
        }
        return self.is_c_abi_type(
            self.callback_result(type), true)
    }

    fn is_inline_c_storage(type: HirType) -> bool {
        if self.is_scalar(type) { return true }
        if (type.name == "RawPtr" ||
            type.name == "CFunctionPtr") &&
           type.args.len() == 1 {
            return true
        }
        if type.name == "array" && type.args.len() == 1 {
            return self.is_inline_c_storage(type.args[0])
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return (declaration.kind == "struct" ||
                        declaration.kind == "union") &&
                       declaration.is_c_layout &&
                       !declaration.is_opaque
            }
            none => { return false }
        }
    }

    fn check_records() {
        for declaration: HirDeclaration in self.program.declarations {
            if !declaration.is_c_layout { continue }
            for field: HirField in declaration.fields {
                if !self.is_inline_c_storage(field.type) {
                    self.fail_field(
                        field,
                        "struct/union fields need inline scalar, RawPtr, fixed-array, or nested struct storage, got {render_hir_type(field.type)}")
                }
            }
        }
    }

    fn check_functions() {
        // The ABI name is written by hand and never carries the package, so
        // two exports can claim one C symbol. That is a real collision, and
        // clang's late redefinition error says nothing about which Beans
        // code caused it.
        var exported: Map<string, string> = {}
        for function: HirFunction in self.program.functions {
            if !function.is_extern_c { continue }
            if function.is_c_export && function.extern_name != "" {
                let claimed: string =
                    exported.get(function.extern_name).or("")
                if claimed != "" {
                    self.fail_function(
                        function,
                        "C symbol '{function.extern_name}' is already exported by {display_symbol(claimed)}")
                } else {
                    exported[function.extern_name] = function.qualified
                }
            }
            // Already rejected outright; a second complaint about the
            // wrapped task return would only bury that error.
            if function.is_async { continue }
            if function.name == "main" {
                self.fail_function(
                    function,
                    "extern function cannot use the reserved name 'main'")
            }
            if function.generics.len() != 0 {
                self.fail_function(
                    function,
                    "extern functions cannot be generic")
            }
            if function.has_body && !function.is_public {
                self.fail_function(
                    function,
                    "an extern function body must be pub so its C export is explicit")
            }
            if function.extern_name == "" {
                self.fail_function(
                    function,
                    "extern C symbol name cannot be empty")
            }
            for parameter: HirParameter in function.parameters {
                if parameter.passing != "" {
                    self.fail_parameter(
                        parameter,
                        "extern parameters cannot use move or inout")
                }
                if !self.is_c_abi_type(parameter.type, false) &&
                   !self.is_c_callback(parameter.type) {
                    self.fail_parameter(
                        parameter,
                        "extern parameter needs an integer, float, bool, RawPtr, extern \"C\" struct/union, or C callback type, got {render_hir_type(parameter.type)}")
                }
                if function.is_c_export &&
                   self.is_c_callback(parameter.type) {
                    self.fail_parameter(
                        parameter,
                        "exported C functions cannot take callbacks yet; pass a RawPtr function address")
                }
            }
            if !self.is_c_abi_type(function.result, true) {
                self.fail_function(
                    function,
                    "extern return needs an integer, float, bool, RawPtr, extern \"C\" struct/union, or no value, got {render_hir_type(function.result)}")
            }
        }
    }

    fn check_globals() {
        for global: HirCGlobal in
            self.program.c_globals {
            if !self.is_c_abi_type(
                    global.type, false) {
                self.fail_global(
                    global,
                    "extern global needs an integer, float, bool, RawPtr, or extern \"C\" struct/union, got {render_hir_type(global.type)}")
            }
            if global.is_thread_local &&
               self.program.target.os == "none" {
                self.fail_global(
                    global,
                    "thread_local C globals need a hosted target")
            }
            if global.extern_name == "" {
                self.fail_global(
                    global,
                    "extern C global symbol name cannot be empty")
            }
        }
    }

    fn run() -> bool {
        self.check_records()
        self.check_globals()
        self.check_functions()
        return self.errors.len() == 0
    }
}

class CAbiCallbackDescription {
    parameter_index: int
    return_type: string
    parameter_types: List<string>
    parameter_declarations: List<string>

    fn init(parameter_index: int) {
        self.parameter_index = parameter_index
        self.return_type = "void"
        self.parameter_types = []
        self.parameter_declarations = []
    }
}

class CAbiDescription {
    definitions: string
    return_type: string
    parameter_types: List<string>
    parameter_declarations: List<string>
    callbacks: List<CAbiCallbackDescription>
    has_callback: bool

    fn init() {
        self.definitions = ""
        self.return_type = "void"
        self.parameter_types = []
        self.parameter_declarations = []
        self.callbacks = []
        self.has_callback = false
    }
}

// Recreate checked C declarations as text so Clang, rather than the
// interpreter, decides how records and stack-passed arguments cross the host
// ABI. This is the Beans copy of the bootstrap compiler's CTextBuilder.
class CAbiTextBuilder {
    program: HirProgram
    names: Map<string, string>
    emitted: Map<string, bool>
    active: Map<string, bool>
    function_names: Map<string, string>
    function_emitted: Map<string, bool>
    definitions: string

    fn init(program: HirProgram) {
        self.program = program
        self.names = {}
        self.emitted = {}
        self.active = {}
        self.function_names = {}
        self.function_emitted = {}
        self.definitions = ""
    }

    fn function_pointer(type: HirType) -> string {
        if type.args.len() != 1 ||
           type.args[0].name != "fn" {
            return "void*"
        }
        let callback: HirType = type.args[0]
        let key: string = render_hir_type(callback)
        var generated: string = ""
        match self.function_names.get(key) {
            some(name) => { generated = name }
            none => {
                generated =
                    "BeansFfiFunction{self.function_names.len()}"
                self.function_names[key] = generated
            }
        }
        if self.function_emitted.contains_key(key) {
            return generated
        }
        self.function_emitted[key] = true
        var result_type: string = "void"
        if callback.fn_parameter_count >= 0 &&
           callback.fn_parameter_count < callback.args.len() {
            result_type = self.base(
                callback.args[callback.fn_parameter_count])
        }
        var parameters: List<string> = []
        for index: int in 0..callback.fn_parameter_count {
            parameters.push(self.declaration(
                callback.args[index], "value{index}"))
        }
        let parameter_text: string =
            if parameters.len() == 0 {
                "void"
            } else {
                parameters.join(", ")
            }
        self.definitions =
            "{self.definitions}typedef {result_type} (*{generated})({parameter_text});\n"
        return generated
    }

    fn record_declaration(type: HirType) ->
        Option<HirDeclaration> {
        for declaration: HirDeclaration in
            self.program.declarations {
            if (declaration.qualified == type.name ||
                declaration.name == type.name) &&
               (declaration.kind == "struct" ||
                declaration.kind == "union") &&
               declaration.is_c_layout {
                return some(declaration)
            }
        }
        return none
    }

    fn record(type: HirType) -> string {
        match self.record_declaration(type) {
            some(declaration) => {
                var generated: string = ""
                match self.names.get(
                        declaration.qualified) {
                    some(name) => {
                        generated = name
                    }
                    none => {
                        generated =
                            "BeansFfiRecord{self.names.len()}"
                        self.names[
                            declaration.qualified] =
                            generated
                    }
                }
                if self.emitted.contains_key(
                       declaration.qualified) {
                    return generated
                }
                if self.active.contains_key(
                       declaration.qualified) {
                    return generated
                }
                self.active[declaration.qualified] = true
                var fields: string = ""
                for index: int in
                    0..declaration.fields.len() {
                    let field: HirField =
                        declaration.fields[index]
                    let field_name: string =
                        field.name
                    fields =
                        "{fields}  {self.declaration(field.type, field_name)}"
                    if field.declared_align != 0 {
                        fields =
                            "{fields} __attribute__((aligned({field.declared_align})))"
                    }
                    fields = "{fields};\n"
                }
                self.active.remove(
                    declaration.qualified)
                var attributes: string = ""
                if declaration.is_packed {
                    attributes =
                        "{attributes} __attribute__((packed))"
                }
                if declaration.declared_align != 0 {
                    attributes =
                        "{attributes} __attribute__((aligned({declaration.declared_align})))"
                }
                let tag: string =
                    if declaration.kind == "union" {
                        "union"
                    } else {
                        "struct"
                    }
                self.definitions =
                    "{self.definitions}typedef {tag} {declaration.name} \{\n{fields}\}{attributes} {generated};\n"
                self.emitted[
                    declaration.qualified] = true
                return generated
            }
            none => { return "void" }
        }
        return "void"
    }

    fn base(type: HirType) -> string {
        let name: string =
            canonical_hir_name(type.name)
        if name == "i8" { return "int8_t" }
        if name == "u8" { return "uint8_t" }
        if name == "i16" { return "int16_t" }
        if name == "u16" { return "uint16_t" }
        if name == "i32" { return "int32_t" }
        if name == "u32" { return "uint32_t" }
        if name == "int" { return "int64_t" }
        if name == "u64" { return "uint64_t" }
        if name == "f32" { return "float" }
        if name == "float" { return "double" }
        if name == "bool" { return "_Bool" }
        if name == "RawPtr" { return "void*" }
        if name == "CFunctionPtr" {
            return self.function_pointer(type)
        }
        if name == "unit" { return "void" }
        return self.record(type)
    }

    fn declaration(type: HirType,
                   name: string) -> string {
        var element: HirType = type
        var dimensions: List<int> = []
        for element.name == "array" &&
            element.args.len() == 1 {
            dimensions.push(element.array_length)
            element = element.args[0]
        }
        var result: string =
            "{self.base(element)} {name}"
        for dimension: int in dimensions {
            result = "{result}[{dimension}]"
        }
        return result
    }

    fn describe(function: HirFunction) ->
        CAbiDescription {
        let result: CAbiDescription =
            new CAbiDescription()
        result.return_type =
            self.base(function.result)
        for index: int in
            0..function.parameters.len() {
            let parameter: HirParameter =
                function.parameters[index]
            if parameter.type.name == "fn" {
                let callback: CAbiCallbackDescription =
                    new CAbiCallbackDescription(index)
                let count: int =
                    parameter.type.fn_parameter_count
                if count >= 0 &&
                   count < parameter.type.args.len() {
                    callback.return_type =
                        self.base(
                            parameter.type.args[count])
                }
                var declaration: string =
                    "{callback.return_type} (*arg{index})("
                for argument: int in 0..count {
                    let argument_name: string =
                        "value{argument}"
                    let argument_type: HirType =
                        parameter.type.args[argument]
                    callback.parameter_types.push(
                        self.base(argument_type))
                    callback.parameter_declarations.push(
                        self.declaration(
                            argument_type,
                            argument_name))
                }
                if callback.parameter_declarations.len() ==
                       0 {
                    declaration =
                        "{declaration}void"
                } else {
                    declaration =
                        "{declaration}{callback.parameter_declarations.join(", ")}"
                }
                declaration = "{declaration})"
                result.has_callback = true
                result.parameter_types.push("void*")
                result.parameter_declarations.push(
                    declaration)
                result.callbacks.push(callback)
            } else {
                result.parameter_types.push(
                    self.base(parameter.type))
                result.parameter_declarations.push(
                    self.declaration(
                        parameter.type,
                        "arg{index}"))
            }
        }
        result.definitions = self.definitions
        return result
    }
}
