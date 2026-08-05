class HirNode {
    kind: string
    value: string
    resolved: string
    type: HirType
    file: string
    line: int
    col: int
    children: List<HirNode>
    binding_id: int
    argument_passing: List<string>
    dispatch_slot: string

    fn init(kind: string, value: string, type: HirType,
            file: string, line: int, col: int) {
        self.kind = kind
        self.value = value
        self.resolved = ""
        self.type = type
        self.file = file
        self.line = line
        self.col = col
        self.children = []
        self.binding_id = -1
        self.argument_passing = []
        self.dispatch_slot = ""
    }
}

class LocalBinding {
    id: int
    name: string
    type: HirType
    mutable: bool
    borrowed: bool
    inout_parameter: bool
    move_state: string

    fn init(id: int, name: string, type: HirType, mutable: bool,
            borrowed: bool, inout_parameter: bool) {
        self.id = id
        self.name = name
        self.type = type
        self.mutable = mutable
        self.borrowed = borrowed
        self.inout_parameter = inout_parameter
        self.move_state = "available"
    }
}

class LocalScope {
    bindings: Map<string, LocalBinding>

    fn init() {
        self.bindings = {}
    }
}

class BuiltinSignature {
    parameters: List<HirType>
    result: HirType

    fn init(parameters: List<HirType>, result: HirType) {
        self.parameters = []
        for parameter: HirType in parameters {
            self.parameters.push(parameter)
        }
        self.result = result
    }
}

class ResolvedField {
    owner: HirDeclaration
    field: HirField
    type: HirType

    fn init(owner: HirDeclaration, field: HirField,
            type: HirType) {
        self.owner = owner
        self.field = field
        self.type = type
    }
}

class ResolvedSuperMethod {
    owner: HirType
    function: HirFunction

    fn init(owner: HirType, function: HirFunction) {
        self.owner = owner
        self.function = function
    }
}

class SimdDescription {
    lanes: int
    element: HirType
    element_bits: int
    is_float: bool

    fn init(lanes: int, element: HirType,
            element_bits: int, is_float: bool) {
        self.lanes = lanes
        self.element = element
        self.element_bits = element_bits
        self.is_float = is_float
    }
}

fn no_hir_type() -> HirType {
    return new HirType("")
}

fn poison_hir_type() -> HirType {
    return new HirType("poison")
}

fn canonical_hir_name(name: string) -> string {
    if name == "i64" { return "int" }
    if name == "byte" { return "u8" }
    if name == "f64" { return "float" }
    return name
}

fn hir_type_key(type: HirType) -> string {
    if type.name == "array" {
        return "[{hir_type_key(type.args[0])};{type.array_length}]"
    }
    if type.name == "fn" {
        var parameters: List<string> = []
        for index: int in 0..type.fn_parameter_count {
            parameters.push(hir_type_key(type.args[index]))
        }
        var result: string = "unit"
        if type.fn_parameter_count < type.args.len() {
            result =
                hir_type_key(type.args[type.fn_parameter_count])
        }
        return "fn({parameters.join(",")})->{result}"
    }
    let name: string = canonical_hir_name(type.name)
    if name == "Result" && type.args.len() == 1 {
        return "Result<{hir_type_key(type.args[0])},Error>"
    }
    if type.args.len() == 0 { return name }
    var arguments: List<string> = []
    for argument: HirType in type.args {
        arguments.push(hir_type_key(argument))
    }
    return "{name}<{arguments.join(",")}>"
}

fn hir_types_equal(left: HirType, right: HirType) -> bool {
    if left.name == "poison" || right.name == "poison" {
        return true
    }
    return hir_type_key(left) == hir_type_key(right)
}

fn hir_is_integer(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "int" || name == "i8" || name == "i16" ||
           name == "i32" || name == "u8" || name == "u16" ||
           name == "u32" || name == "u64"
}

fn hir_is_float(type: HirType) -> bool {
    let name: string = canonical_hir_name(type.name)
    return name == "float" || name == "f32"
}

fn hir_is_numeric(type: HirType) -> bool {
    return hir_is_integer(type) || hir_is_float(type) ||
           type.name == "decimal"
}

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

fn integer_literal_bits(name: string) -> int {
    let canonical: string = canonical_hir_name(name)
    if canonical == "i8" || canonical == "u8" { return 8 }
    if canonical == "i16" || canonical == "u16" { return 16 }
    if canonical == "i32" || canonical == "u32" { return 32 }
    if canonical == "int" || canonical == "u64" { return 64 }
    return 0
}

fn integer_literal_signed(name: string) -> bool {
    let canonical: string = canonical_hir_name(name)
    return canonical == "int" || canonical == "i8" ||
           canonical == "i16" || canonical == "i32"
}

fn without_leading_zeroes(value: string) -> string {
    var first: int = 0
    for first < value.len() && value.byte_at(first) == 48 {
        first += 1
    }
    return value.slice(first, value.len())
}

fn decimal_magnitude_at_most(value: string,
                             limit: string) -> bool {
    let magnitude: string =
        without_leading_zeroes(value)
    if magnitude.len() != limit.len() {
        return magnitude.len() < limit.len()
    }
    for index: int in 0..magnitude.len() {
        let digit: int = magnitude.byte_at(index)
        let edge: int = limit.byte_at(index)
        if digit != edge { return digit < edge }
    }
    return true
}

fn hex_digit_value(value: int) -> int {
    if value >= 48 && value <= 57 { return value - 48 }
    if value >= 65 && value <= 70 { return value - 65 + 10 }
    if value >= 97 && value <= 102 { return value - 97 + 10 }
    return 16
}

fn power_of_two_edge(value: string, edge: int) -> bool {
    if value.len() == 0 ||
       hex_digit_value(value.byte_at(0)) != edge {
        return false
    }
    for index: int in 1..value.len() {
        if hex_digit_value(value.byte_at(index)) != 0 {
            return false
        }
    }
    return true
}

fn integer_decimal_limit(bits: int,
                         signed: bool,
                         negative: bool) -> string {
    if bits == 8 {
        if signed {
            return if negative { "128" } else { "127" }
        }
        return "255"
    }
    if bits == 16 {
        if signed {
            return if negative { "32768" } else { "32767" }
        }
        return "65535"
    }
    if bits == 32 {
        if signed {
            return if negative { "2147483648" } else { "2147483647" }
        }
        return "4294967295"
    }
    if signed {
        return if negative {
            "9223372036854775808"
        } else {
            "9223372036854775807"
        }
    }
    return "18446744073709551615"
}

fn integer_literal_fits(text: string,
                        type_name: string,
                        negative: bool) -> bool {
    let bits: int = integer_literal_bits(type_name)
    let signed: bool = integer_literal_signed(type_name)
    if bits == 0 { return true }

    var base: int = 10
    var digits: string = text.replace("_", "")
    if digits.starts_with("0x") || digits.starts_with("0X") {
        base = 16
        digits = digits.slice(2, digits.len())
    } else if digits.starts_with("0b") ||
              digits.starts_with("0B") {
        base = 2
        digits = digits.slice(2, digits.len())
    }
    digits = without_leading_zeroes(digits)
    if digits.len() == 0 { return true }
    if negative && !signed { return false }

    if base == 10 {
        return decimal_magnitude_at_most(
            digits,
            integer_decimal_limit(bits, signed, negative))
    }
    if base == 2 {
        if !signed { return digits.len() <= bits }
        if digits.len() < bits { return true }
        if digits.len() > bits || !negative { return false }
        return power_of_two_edge(digits, 1)
    }

    let width: int = bits / 4
    if digits.len() < width { return true }
    if digits.len() > width { return false }
    if !signed { return true }
    let first: int = hex_digit_value(digits.byte_at(0))
    if !negative { return first <= 7 }
    if first < 8 { return true }
    return first == 8 && power_of_two_edge(digits, 8)
}

fn integer_literal_range(type_name: string) -> string {
    let bits: int = integer_literal_bits(type_name)
    let signed: bool = integer_literal_signed(type_name)
    if signed {
        return "-{integer_decimal_limit(bits, true, true)}..{integer_decimal_limit(bits, true, false)}"
    }
    return "0..{integer_decimal_limit(bits, false, false)}"
}

fn integer_literal_syntax(node: AstNode) -> bool {
    if node.kind == "literal" && node.note == "int" {
        return true
    }
    return node.kind == "unary" && node.value == "-" &&
           node.children.len() == 1 &&
           integer_literal_syntax(node.children[0])
}

fn decimal_exponent_fits(value: string,
                         negative: bool) -> bool {
    return decimal_magnitude_at_most(
        value,
        if negative {
            "9223372036854775808"
        } else {
            "9223372036854775807"
        })
}

fn decimal_literal_fits(text: string) -> bool {
    let source: string = text.replace("_", "")
    var fractional: int = 0
    var after_dot: bool = false
    var significant: int = 0
    var saw_nonzero: bool = false
    var exponent_at: int = source.len()
    for index: int in 0..source.len() {
        let byte: int = source.byte_at(index)
        if byte == 101 || byte == 69 {
            exponent_at = index
            break
        }
        if byte == 46 {
            after_dot = true
            continue
        }
        if after_dot { fractional += 1 }
        if byte != 48 { saw_nonzero = true }
        if saw_nonzero { significant += 1 }
    }

    var exponent_negative: bool = false
    var exponent_digits: string = ""
    if exponent_at < source.len() {
        var start: int = exponent_at + 1
        if start < source.len() &&
           (source.byte_at(start) == 43 ||
            source.byte_at(start) == 45) {
            exponent_negative =
                source.byte_at(start) == 45
            start += 1
        }
        exponent_digits = without_leading_zeroes(
            source.slice(start, source.len()))
        if exponent_digits.len() > 0 &&
           !decimal_exponent_fits(
               exponent_digits, exponent_negative) {
            return false
        }
    }

    if exponent_digits.len() > 7 {
        return !saw_nonzero && !exponent_negative
    }
    var exponent: int = 0
    for index: int in 0..exponent_digits.len() {
        exponent =
            exponent * 10 +
            exponent_digits.byte_at(index) - 48
    }
    if exponent_negative { exponent = -exponent }

    let scale: int = fractional - exponent
    if !saw_nonzero {
        return scale <= 65535
    }
    if significant > 38 { return false }
    if scale < 0 {
        let append: int = -scale
        return append <= 38 &&
               significant + append <= 38
    }
    return scale <= 65535
}

fn interpolation_expression_source(segment: string) -> string {
    var depth: int = 0
    var in_string: bool = false
    var index: int = 0
    for index < segment.len() {
        let byte: int = segment.byte_at(index)
        if byte == 92 {
            index += 2
            continue
        }
        if in_string {
            if byte == 34 { in_string = false }
            index += 1
            continue
        }
        if byte == 34 {
            in_string = true
        } else if byte == 40 || byte == 91 ||
                  byte == 123 {
            depth += 1
        } else if byte == 41 || byte == 93 ||
                  byte == 125 {
            depth -= 1
        } else if byte == 58 && depth == 0 {
            return segment.slice(0, index)
        }
        index += 1
    }
    return segment
}

fn hir_named(name: string, arguments: List<HirType>) -> HirType {
    let result: HirType = new HirType(name)
    for argument: HirType in arguments {
        result.args.push(argument)
    }
    return result
}

fn hir_list(element: HirType) -> HirType {
    return hir_named("List", [element])
}

fn hir_option(element: HirType) -> HirType {
    return hir_named("Option", [element])
}

fn hir_result(value: HirType) -> HirType {
    return hir_named(
        "Result", [value, new HirType("Error")])
}

fn hir_function(parameters: List<HirType>,
                result_type: HirType) -> HirType {
    let result: HirType = new HirType("fn")
    for parameter: HirType in parameters {
        result.args.push(parameter)
    }
    result.fn_parameter_count = parameters.len()
    result.args.push(result_type)
    return result
}

fn simd_description(name: string) -> Option<SimdDescription> {
    if !name.starts_with("Simd") { return none }
    let suffixes: List<string> =
        ["i8", "u8", "i16", "u16", "i32",
         "u32", "i64", "u64", "f32", "f64"]
    let widths: List<int> =
        [8, 8, 16, 16, 32, 32, 64, 64, 32, 64]
    for index: int in 0..suffixes.len() {
        let suffix: string = suffixes[index]
        if !name.ends_with(suffix) { continue }
        let lane_text: string =
            name.slice(4, name.len() - suffix.len())
        let lanes: int = lane_text.to_int().or(0)
        let bits: int = widths[index]
        if lanes <= 0 ||
           (lanes & (lanes - 1)) != 0 ||
           (lanes * bits != 128 &&
            lanes * bits != 256) {
            return none
        }
        return some(new SimdDescription(
            lanes,
            new HirType(
                canonical_hir_name(suffix)),
            bits, suffix.starts_with("f")))
    }
    return none
}

// Arity of the builtin generic containers, -1 for everything else. The HIR
// lowering validates signature and field types; statement annotations reach
// validate_target_type instead, and both have to refuse a builtin generic
// spelled without its type arguments.
fn builtin_generic_arity(name: string) -> int {
    if name == "Map" || name == "OrderedMap" { return 2 }
    if name == "List" || name == "Thread" || name == "Mutex" ||
       name == "Channel" || name == "Box" || name == "Arena" ||
       name == "Shared" || name == "Weak" || name == "RawPtr" ||
       name == "Slice" || name == "Atomic" ||
       name == "StoredCallback" {
        return 1
    }
    return -1
}

fn builtin_class_name(name: string) -> bool {
    return name == "Bytes" || name == "File" ||
           name == "Dir" || name == "MMap" ||
           name == "RawPtr" || name == "Slice" ||
           name == "List" || name == "Map" ||
           name == "OrderedMap" || name == "Box" ||
           name == "Arena" || name == "Shared" ||
           name == "Weak" || name == "Mutex" ||
           name == "Atomic" || name == "Channel" ||
           name == "Thread" || name == "AtomicInt" ||
           name == "StoredCallback" ||
           simd_description(name).is_some()
}

fn hir_type_from_ast(node: AstNode) -> HirType {
    if node.kind == "array_type" {
        let result: HirType = new HirType("array")
        result.array_length =
            node.value.to_int().expect("array length")
        match type_child(node) {
            some(element) => {
                result.args.push(hir_type_from_ast(element))
            }
            none => {}
        }
        return result
    }
    if node.kind == "fn_type" {
        let result: HirType = new HirType("fn")
        for child: AstNode in node.children {
            result.args.push(hir_type_from_ast(child))
        }
        result.fn_parameter_count = result.args.len()
        if node.note == "has_result" {
            result.fn_parameter_count -= 1
        }
        return result
    }
    let name: string =
        if node.resolved != "" { node.resolved } else { node.value }
    let result: HirType =
        new HirType(canonical_hir_name(name))
    for child: AstNode in node.children {
        result.args.push(hir_type_from_ast(child))
    }
    return result
}

class ExpressionChecker {
    signature: SignatureChecker
    program: HirProgram
    functions: Map<string, HirFunction>
    methods: Map<string, HirFunction>
    declarations: Map<string, HirDeclaration>
    c_globals: Map<string, HirCGlobal>
    imports: Map<string, string>
    errors: List<Diagnostic>
    scopes: List<LocalScope>
    current: HirFunction
    current_constraints: List<HirGeneric>
    loop_depth: int
    literal_sign: int
    unsafe_depth: int
    defer_depth: int
    feature_guards: List<string>
    take_floor_depth: int
    capture_floor_depth: int
    require_send_captures: bool
    require_sync_captures: bool
    allow_inout_expression: bool
    bad_inout_captures: Map<string, bool>
    bad_send_captures: Map<string, bool>
    bad_sync_captures: Map<string, bool>
    next_binding_id: int
    // Counts enclosing borrowed bindings of move-only values: a for-in
    // element or a match payload. An await inside such a scope would have
    // to keep the borrow alive across a suspension, which the task frame
    // cannot do, so check_await refuses while this is nonzero.
    move_only_borrow_depth: int

    fn init(signature: SignatureChecker) {
        self.signature = signature
        self.program = signature.hir
        self.functions = {}
        self.methods = {}
        self.declarations = {}
        self.c_globals = {}
        self.imports = {}
        self.errors = []
        self.scopes = []
        self.current = new HirFunction(
            "", "", "", false, "", 0, 0)
        self.current_constraints = []
        self.loop_depth = 0
        self.literal_sign = 1
        self.unsafe_depth = 0
        self.defer_depth = 0
        self.feature_guards = []
        self.take_floor_depth = -1
        self.capture_floor_depth = -1
        self.require_send_captures = false
        self.require_sync_captures = false
        self.allow_inout_expression = false
        self.bad_inout_captures = {}
        self.bad_send_captures = {}
        self.bad_sync_captures = {}
        self.next_binding_id = 0
        self.move_only_borrow_depth = 0
        for function: HirFunction in self.program.functions {
            if function.owner != "" {
                self.methods["{function.owner}.{function.name}"] =
                    function
                continue
            }
            self.functions[function.qualified] = function
        }
        for declaration: HirDeclaration in self.program.declarations {
            self.declarations[declaration.qualified] = declaration
        }
        for global: HirCGlobal in
            self.program.c_globals {
            self.c_globals[
                global.qualified] = global
        }
        for package: LoadedPackage in
            signature.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                for declaration: AstNode in file.ast.children {
                    if declaration.kind != "import" { continue }
                    var import_path: string = declaration.value
                    if import_path.starts_with("pub ") {
                        import_path =
                            import_path.slice(4, import_path.len())
                    }
                    var alias: string =
                        package_prefix(import_path)
                    for child: AstNode in declaration.children {
                        if child.kind == "alias" {
                            alias = child.value
                        }
                    }
                    self.imports["{file.path}|{alias}"] =
                        import_path
                }
            }
        }
    }

    fn fail(node: AstNode, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: self.current.file,
            line: node.line,
            col: node.col,
            message: message,
        })
    }

    fn require_unsafe(node: AstNode, operation: string) {
        if self.unsafe_depth == 0 {
            self.fail(
                node,
                "{operation} requires unsafe \{ \}")
        }
    }

    fn is_opaque_c_type(type: HirType) -> bool {
        match self.declarations.get(type.name) {
            some(declaration) => {
                return declaration.is_c_layout &&
                       declaration.is_opaque
            }
            none => { return false }
        }
    }

    fn is_inline_c_storage(type: HirType) -> bool {
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           (type.name == "RawPtr" &&
            type.args.len() == 1) {
            return true
        }
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.is_inline_c_storage(
                type.args[0])
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

    fn is_raw_pointee(type: HirType) -> bool {
        if self.is_inline_c_storage(type) {
            return true
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return declaration.is_c_layout &&
                       declaration.is_opaque
            }
            none => { return false }
        }
    }

    fn is_fixed_array_element(type: HirType) -> bool {
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           type.name == "RawPtr" {
            return true
        }
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.is_fixed_array_element(
                type.args[0])
        }
        match self.declarations.get(type.name) {
            some(declaration) => {
                return declaration.kind == "struct"
            }
            none => { return false }
        }
    }

    fn is_stored_callback_scalar(
        type: HirType, allow_unit: bool) -> bool {
        return (allow_unit &&
                type.name == "unit") ||
               hir_is_numeric(type) ||
               type.name == "bool" ||
               (type.name == "RawPtr" &&
                type.args.len() == 1)
    }

    fn feature_is_available(feature: string) -> bool {
        return self.program.target.has_feature(feature) ||
               self.feature_guards.contains(feature) ||
               self.current.required_feature == feature
    }

    fn require_named_feature(node: AstNode, shown: string,
                             feature: string, use: string) {
        if feature == "" ||
           self.feature_is_available(feature) {
            return
        }
        let spelling: string =
            self.program.target.feature_spelling(feature)
        self.fail(
            node,
            "{shown} needs the {feature} CPU feature, so {use} has to be guarded: if cpu.has(CpuFeature.{spelling}) \{ ... \}, or made from a feature \"{feature}\" fn, or the whole build given --features +{feature}")
    }

    fn require_function_feature(node: AstNode,
                                function: HirFunction,
                                use: string) {
        self.require_named_feature(
            node,
            "'{function.name}'",
            function.required_feature,
            use)
    }

    fn collect_feature_guards(node: AstNode) {
        if node.kind == "binary" && node.value == "&&" {
            self.collect_feature_guards(node.children[0])
            self.collect_feature_guards(node.children[1])
            return
        }
        if node.kind != "call" ||
           node.children.len() != 2 {
            return
        }
        let callee: AstNode = node.children[0]
        let argument: AstNode = node.children[1]
        if callee.kind != "field" ||
           callee.value != "has" ||
           callee.children.len() != 1 ||
           callee.children[0].kind != "name" ||
           self.imported_path(
               callee.children[0].value) != "std.cpu" ||
           argument.kind != "field" ||
           argument.children.len() != 1 ||
           argument.children[0].kind != "name" ||
           argument.children[0].value != "CpuFeature" {
            return
        }
        let feature: string =
            self.program.target.normalize_feature(
                argument.value)
        if self.program.target.is_known_feature(feature) &&
           !self.feature_guards.contains(feature) {
            self.feature_guards.push(feature)
        }
    }

    fn push_scope() {
        self.scopes.push(new LocalScope())
    }

    fn pop_scope() {
        self.scopes.pop()
    }

    fn declare(node: AstNode, type: HirType, mutable: bool,
               borrowed: bool, inout_parameter: bool) -> int {
        let at: int = self.scopes.len() - 1
        if self.scopes[at].bindings.contains(node.value) {
            self.fail(
                node, "'{node.value}' is already defined in this scope")
            return -1
        }
        let id: int = self.next_binding_id
        self.next_binding_id += 1
        self.scopes[at].bindings[node.value] =
            new LocalBinding(
                id, node.value, type, mutable,
                borrowed, inout_parameter)
        return id
    }

    fn find_local(name: string) -> Option<LocalBinding> {
        var found: Option<LocalBinding> = none
        for scope: LocalScope in self.scopes {
            match scope.bindings.get(name) {
                some(binding) => { found = some(binding) }
                none => {}
            }
        }
        return found
    }

    fn local_scope_index(name: string) -> int {
        var found: int = -1
        for index: int in 0..self.scopes.len() {
            if self.scopes[index].bindings.contains(name) {
                found = index
            }
        }
        return found
    }

    fn copy_scopes(source: List<LocalScope>) -> List<LocalScope> {
        var result: List<LocalScope> = []
        for scope: LocalScope in source {
            let copied: LocalScope = new LocalScope()
            for name: string in scope.bindings.keys() {
                let binding: LocalBinding =
                    scope.bindings[name]
                let item: LocalBinding =
                    new LocalBinding(
                        binding.id, binding.name, binding.type,
                        binding.mutable, binding.borrowed,
                        binding.inout_parameter)
                item.move_state = binding.move_state
                copied.bindings[name] = item
            }
            result.push(copied)
        }
        return move result
    }

    fn merge_move_states(left: List<LocalScope>,
                         right: List<LocalScope>) {
        for scope_index: int in 0..self.scopes.len() {
            if scope_index >= left.len() ||
               scope_index >= right.len() {
                continue
            }
            for name: string in
                self.scopes[scope_index].bindings.keys() {
                match left[scope_index].bindings.get(name) {
                    some(left_binding) => {
                        match right[scope_index].bindings.get(name) {
                            some(right_binding) => {
                                let merged_scope: LocalScope =
                                    self.scopes[scope_index]
                                let merged: LocalBinding =
                                    merged_scope.bindings[name]
                                merged.move_state =
                                    if left_binding.move_state ==
                                       right_binding.move_state {
                                        left_binding.move_state
                                    } else {
                                        "maybe_moved"
                                    }
                                merged.borrowed =
                                    left_binding.borrowed ||
                                    right_binding.borrowed
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
            }
        }
    }

    fn function_type(function: HirFunction) -> HirType {
        let type: HirType = new HirType("fn")
        type.fn_parameter_count = function.parameters.len()
        for parameter: HirParameter in function.parameters {
            type.args.push(parameter.type)
        }
        type.args.push(function.result)
        return type
    }

    fn substitute_owner_type(type: HirType,
                             declaration: HirDeclaration,
                             receiver: HirType) -> HirType {
        for index: int in 0..declaration.generics.len() {
            if type.name == declaration.generics[index] &&
               index < receiver.args.len() {
                return receiver.args[index]
            }
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count = type.fn_parameter_count
        for argument: HirType in type.args {
            result.args.push(self.substitute_owner_type(
                argument, declaration, receiver))
        }
        return result
    }

    fn generic_name_in(name: string,
                       generics: List<string>) -> bool {
        for generic: string in generics {
            if generic == name { return true }
        }
        return false
    }

    fn substitute_generic_type(
        type: HirType, generics: List<string>,
        inference: Map<string, HirType>) -> HirType {
        if self.generic_name_in(type.name, generics) {
            match inference.get(type.name) {
                some(actual) => { return actual }
                none => { return type }
            }
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count = type.fn_parameter_count
        for argument: HirType in type.args {
            result.args.push(self.substitute_generic_type(
                argument, generics, inference))
        }
        return result
    }

    fn has_unbound_generic(
        type: HirType, generics: List<string>,
        inference: Map<string, HirType>) -> bool {
        if self.generic_name_in(type.name, generics) {
            return !inference.contains(type.name)
        }
        for argument: HirType in type.args {
            if self.has_unbound_generic(
                argument, generics, inference) {
                return true
            }
        }
        return false
    }

    fn infer_generic_type(
        pattern: HirType, actual: HirType,
        generics: List<string>,
        inout inference: Map<string, HirType>,
        at: AstNode) {
        if self.generic_name_in(pattern.name, generics) {
            match inference.get(pattern.name) {
                some(previous) => {
                    if !hir_types_equal(previous, actual) {
                        self.fail(
                            at,
                            "generic {pattern.name} was {render_hir_type(previous)}, then {render_hir_type(actual)}")
                    }
                }
                none => {
                    inference[pattern.name] = actual
                }
            }
            return
        }
        if pattern.name != actual.name ||
           pattern.args.len() != actual.args.len() {
            return
        }
        for index: int in 0..pattern.args.len() {
            self.infer_generic_type(
                pattern.args[index], actual.args[index],
                generics, inout inference, at)
        }
    }

    fn trait_satisfied(type: HirType, trait: string) -> bool {
        if type.name == "poison" { return true }
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name != type.name { continue }
            for bound: HirType in constraint.bounds {
                if bound.name == trait ||
                   (trait == "Eq" &&
                    bound.name == "Order") {
                    return true
                }
                match self.declarations.get(bound.name) {
                    some(declaration) => {
                        if declaration.kind == "interface" &&
                           self.is_subtype(
                               bound,
                               new HirType(trait)) {
                            return true
                        }
                    }
                    none => {}
                }
            }
            return false
        }
        if trait == "Eq" &&
           self.trait_satisfied(type, "Order") {
            return true
        }
        if hir_is_numeric(type) ||
           type.name == "bool" ||
           type.name == "string" ||
           type.name == "unit" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash" || trait == "Order" ||
                   trait == "Send" || trait == "Sync"
        }
        if type.name == "array" && type.args.len() == 1 {
            return (trait == "Clone" || trait == "Eq" ||
                    trait == "Hash" || trait == "Send" ||
                    trait == "Sync") &&
                   self.trait_satisfied(type.args[0], trait)
        }
        if type.name == "fn" {
            return trait == "Clone"
        }
        if simd_description(type.name).is_some() {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Send" || trait == "Sync"
        }
        if type.name == "RawPtr" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash" || trait == "Send" ||
                   trait == "Sync"
        }
        if type.name == "Slice" {
            return trait == "Clone" || trait == "Send" ||
                   trait == "Sync"
        }
        if type.name == "Bytes" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash"
        }
        if type.name == "Error" {
            return trait == "Clone" || trait == "Eq" ||
                   trait == "Hash"
        }
        if (type.name == "Option" ||
            type.name == "Result") &&
           type.args.len() >= 1 {
            if trait != "Clone" && trait != "Eq" &&
               trait != "Hash" && trait != "Send" &&
               trait != "Sync" {
                return false
            }
            for argument: HirType in type.args {
                if !self.trait_satisfied(argument, trait) {
                    return false
                }
            }
            if type.name == "Result" &&
               type.args.len() == 1 &&
               !self.trait_satisfied(
                   new HirType("Error"), trait) {
                return false
            }
            return true
        }
        if type.name == "Shared" || type.name == "Weak" {
            if trait == "Clone" { return true }
            return (trait == "Send" || trait == "Sync") &&
                   type.args.len() == 1 &&
                   self.trait_satisfied(
                       type.args[0], "Send") &&
                   self.trait_satisfied(
                       type.args[0], "Sync")
        }
        if type.name == "Mutex" ||
           type.name == "Atomic" ||
           type.name == "AtomicInt" {
            return trait == "Clone" || trait == "Send" ||
                   trait == "Sync"
        }
        if type.name == "Channel" && type.args.len() == 1 {
            if trait == "Clone" { return true }
            return (trait == "Send" || trait == "Sync") &&
                   self.trait_satisfied(
                       type.args[0], "Send")
        }
        if type.name == "Thread" && type.args.len() == 1 {
            if trait == "Clone" { return true }
            return trait == "Send" &&
                   self.trait_satisfied(
                       type.args[0], "Send")
        }
        if type.name == "List" && type.args.len() == 1 {
            if trait == "Eq" || trait == "Hash" {
                return true
            }
            return trait == "Clone" &&
                   !self.is_move_only(type.args[0]) &&
                   self.trait_satisfied(
                       type.args[0], "Clone")
        }
        if (type.name == "Map" ||
            type.name == "OrderedMap") &&
           type.args.len() == 2 {
            return trait == "Clone" &&
                   !self.is_move_only(type.args[0]) &&
                   !self.is_move_only(type.args[1]) &&
                   self.trait_satisfied(
                       type.args[0], "Clone") &&
                   self.trait_satisfied(
                       type.args[1], "Clone")
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind == "interface" {
                    return self.is_subtype(
                        type, new HirType(trait))
                }
                match self.declarations.get(trait) {
                    some(bound) => {
                        if bound.kind == "interface" {
                            return self.is_subtype(
                                type,
                                new HirType(bound.qualified))
                        }
                    }
                    none => {}
                }
                if declaration.kind == "struct" {
                    if trait != "Clone" &&
                       trait != "Eq" &&
                       trait != "Hash" &&
                       trait != "Send" &&
                       trait != "Sync" {
                        return false
                    }
                    for field: HirField in declaration.fields {
                        let field_type: HirType =
                            self.substitute_owner_type(
                                field.type,
                                declaration, type)
                        if !self.trait_satisfied(
                            field_type, trait) {
                            return false
                        }
                    }
                    return true
                }
                if declaration.kind == "union" {
                    return trait == "Clone"
                }
                if declaration.kind == "enum" {
                    if trait != "Clone" &&
                       trait != "Eq" &&
                       trait != "Hash" &&
                       trait != "Send" &&
                       trait != "Sync" {
                        return false
                    }
                    for variant: HirField in
                        declaration.variants {
                        for payload: HirType in
                            variant.type.args {
                            let item: HirType =
                                self.substitute_owner_type(
                                    payload,
                                    declaration, type)
                            if !self.trait_satisfied(
                                item, trait) {
                                return false
                            }
                        }
                    }
                    return true
                }
                if declaration.kind == "class" {
                    return (trait == "Clone" &&
                            !self.is_move_only(type)) ||
                           trait == "Eq" ||
                           trait == "Hash"
                }
            }
            none => {}
        }
        return false
    }

    fn declaration_for(type: HirType) -> Option<HirDeclaration> {
        match self.declarations.get(type.name) {
            some(declaration) => { return some(declaration) }
            none => {}
        }
        // a re-parsed interpolation segment never went through the
        // resolver, so a bare package-local name or an import alias can
        // survive here; qualify it the way resolved code would be
        if !type.name.contains(".") {
            return self.declarations.get(
                self.current_qualified(type.name))
        }
        let parts: List<string> = type.name.split(".")
        if parts.len() == 2 {
            let import_path: string =
                self.imported_path(parts[0])
            if import_path != "" {
                let prefix: string =
                    self.signature.resolver.package_prefix_for(
                        import_path)
                if prefix != "" {
                    return self.declarations.get(
                        "{prefix}.{parts[1]}")
                }
            }
        }
        return none
    }

    fn declaration_instance(
        declaration: HirDeclaration) -> HirType {
        let type: HirType =
            new HirType(declaration.qualified)
        for generic: string in declaration.generics {
            type.args.push(new HirType(generic))
        }
        return type
    }

    fn parent_class_type(type: HirType) -> Option<HirType> {
        match self.declaration_for(type) {
            some(declaration) => {
                for relation: HirType in declaration.relations {
                    let resolved: HirType =
                        self.substitute_owner_type(
                            relation, declaration, type)
                    match self.declaration_for(resolved) {
                        some(parent) => {
                            if parent.kind == "class" {
                                return some(resolved)
                            }
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        return none
    }

    fn super_method(name: string) -> Option<ResolvedSuperMethod> {
        match self.declarations.get(self.current.owner) {
            some(declaration) => {
                var parent: Option<HirType> =
                    self.parent_class_type(
                        self.declaration_instance(declaration))
                for parent.is_some() {
                    let owner: HirType =
                        parent.expect("parent class")
                    match self.methods.get(
                        "{owner.name}.{name}") {
                        some(function) => {
                            if !function.is_static &&
                               function.has_body {
                                return some(
                                    new ResolvedSuperMethod(
                                        owner, function))
                            }
                        }
                        none => {}
                    }
                    parent = self.parent_class_type(owner)
                }
            }
            none => {}
        }
        return none
    }

    fn package_prefix_for_file(file_path: string) -> string {
        for package: LoadedPackage in
            self.signature.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                if file.path == file_path {
                    return package.prefix
                }
            }
        }
        return ""
    }

    fn current_qualified(name: string) -> string {
        let prefix: string =
            self.package_prefix_for_file(self.current.file)
        if prefix == "" { return name }
        return "{prefix}.{name}"
    }

    fn current_declaration(name: string) -> Option<HirDeclaration> {
        return self.declarations.get(
            self.current_qualified(name))
    }

    fn current_function(name: string) -> Option<HirFunction> {
        return self.functions.get(
            self.current_qualified(name))
    }

    fn current_c_global(name: string) -> Option<HirCGlobal> {
        return self.c_globals.get(
            self.current_qualified(name))
    }

    fn is_move_only_seen(
        type: HirType,
        inout seen: Map<string, bool>) -> bool {
        let key: string = hir_type_key(type)
        if seen.contains(key) { return false }
        seen[key] = true
        if type.name == "array" &&
           type.args.len() == 1 {
            return self.is_move_only_seen(
                type.args[0], inout seen)
        }
        if type.name == "Box" ||
           type.name == "Arena" ||
           type.name == "List" ||
           type.name == "Map" ||
           type.name == "OrderedMap" ||
           type.name == "StoredCallback" {
            return true
        }
        if (type.name == "Option" ||
            type.name == "Result") {
            for argument: HirType in type.args {
                if self.is_move_only_seen(
                    argument, inout seen) {
                    return true
                }
            }
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.is_unique { return true }
                if declaration.kind == "class" {
                    for relation: HirType in
                        declaration.relations {
                        if self.is_move_only_seen(
                            relation, inout seen) {
                            return true
                        }
                    }
                } else if declaration.kind == "struct" {
                    for field: HirField in declaration.fields {
                        let field_type: HirType =
                            self.substitute_owner_type(
                                field.type,
                                declaration, type)
                        if self.is_move_only_seen(
                            field_type, inout seen) {
                            return true
                        }
                    }
                } else if declaration.kind == "enum" {
                    for argument: HirType in type.args {
                        if self.is_move_only_seen(
                            argument, inout seen) {
                            return true
                        }
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn is_move_only(type: HirType) -> bool {
        var seen: Map<string, bool> = {}
        return self.is_move_only_seen(type, inout seen)
    }

    fn is_subtype(child: HirType, parent: HirType) -> bool {
        if hir_types_equal(child, parent) { return true }
        var pending: List<HirType> = [child]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType = pending.pop().expect("pending type")
            let key: string = hir_type_key(current)
            if seen.contains(key) { continue }
            seen[key] = true
            match self.declaration_for(current) {
                some(declaration) => {
                    for relation: HirType in declaration.relations {
                        if hir_types_equal(relation, parent) {
                            return true
                        }
                        pending.push(relation)
                    }
                }
                none => {}
            }
        }
        return false
    }

    fn is_plain_class(type: HirType) -> bool {
        if type.args.len() != 0 { return false }
        match self.declaration_for(type) {
            some(declaration) => {
                return declaration.kind == "class" ||
                       declaration.kind == "interface"
            }
            none => { return false }
        }
    }

    fn field_for(receiver: HirType,
                 name: string) -> Option<ResolvedField> {
        var pending: List<HirType> = [receiver]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirType =
                pending.remove(0)
            let key: string = hir_type_key(current)
            if seen.contains(key) { continue }
            seen[key] = true
            match self.declaration_for(current) {
                some(declaration) => {
                    for field: HirField in declaration.fields {
                        if field.name == name {
                            return some(new ResolvedField(
                                declaration, field,
                                self.substitute_owner_type(
                                    field.type, declaration,
                                    current)))
                        }
                    }
                    for relation: HirType in declaration.relations {
                        pending.push(
                            self.substitute_owner_type(
                                relation, declaration, current))
                    }
                }
                none => {}
            }
        }
        return none
    }

    fn field_type(receiver: HirType, name: string) -> Option<HirType> {
        match self.field_for(receiver, name) {
            some(field) => { return some(field.type) }
            none => { return none }
        }
    }

    fn variant_for(declaration: HirDeclaration,
                   name: string) -> Option<HirField> {
        for variant: HirField in declaration.variants {
            if variant.name == name { return some(variant) }
        }
        return none
    }

    fn method_for(receiver: HirType, name: string) -> Option<HirFunction> {
        var pending: List<HirDeclaration> = []
        match self.declaration_for(receiver) {
            some(declaration) => {
                pending.push(declaration)
            }
            none => {}
        }
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name != receiver.name { continue }
            for bound: HirType in constraint.bounds {
                match self.declaration_for(bound) {
                    some(declaration) => {
                        pending.push(declaration)
                    }
                    none => {}
                }
            }
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let declaration: HirDeclaration =
                pending.remove(0)
            if seen.contains(declaration.qualified) {
                continue
            }
            seen[declaration.qualified] = true
            match self.methods.get(
                "{declaration.qualified}.{name}") {
                some(method) => {
                    return some(method)
                }
                none => {}
            }
            for relation: HirType in
                declaration.relations {
                match self.declaration_for(relation) {
                    some(parent) => {
                        pending.push(parent)
                    }
                    none => {}
                }
            }
        }
        return none
    }

    fn inherited_method(
        owner: string, name: string) -> Option<HirFunction> {
        var pending: List<HirType> = []
        match self.declarations.get(owner) {
            some(declaration) => {
                for relation: HirType in
                    declaration.relations {
                    pending.push(relation)
                }
            }
            none => {}
        }
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let relation: HirType =
                pending.remove(0)
            if seen.contains(relation.name) { continue }
            seen[relation.name] = true
            match self.declaration_for(relation) {
                some(declaration) => {
                    match self.methods.get(
                        "{declaration.qualified}.{name}") {
                        some(function) => {
                            let caller_package: string =
                                self.package_path_for_file(
                                    self.current.file)
                            let owner_package: string =
                                self.package_path_for_file(
                                    function.file)
                            if !function.is_static &&
                               (function.is_public ||
                                caller_package == owner_package) {
                                return some(function)
                            }
                        }
                        none => {}
                    }
                    for parent: HirType in
                        declaration.relations {
                        pending.push(parent)
                    }
                }
                none => {}
            }
        }
        return none
    }

    fn add_dispatch_slots(function: HirFunction,
                          parent: HirFunction) {
        for slot: string in parent.dispatch_slots {
            if !function.dispatch_slots.contains(slot) {
                function.dispatch_slots.push(slot)
            }
        }
    }

    fn same_method_signature(left: HirFunction,
                             right: HirFunction) -> bool {
        if left.parameters.len() != right.parameters.len() ||
           !hir_types_equal(left.result, right.result) {
            return false
        }
        for index: int in 0..left.parameters.len() {
            if !hir_types_equal(
                   left.parameters[index].type,
                   right.parameters[index].type) {
                return false
            }
        }
        return true
    }

    fn method_signature(function: HirFunction) -> string {
        var parameters: List<string> = []
        for parameter: HirParameter in function.parameters {
            parameters.push(render_hir_type(parameter.type))
        }
        return "fn({parameters.join(", ")}) -> {render_hir_type(function.result)}"
    }

    fn validate_override(function: HirFunction) {
        if function.owner == "" || function.is_static {
            return
        }
        if function.name == "init" ||
           function.name == "deinit" {
            if function.is_override {
                self.fail(
                    function.syntax,
                    if function.name == "init" {
                        "init can't be marked override"
                    } else {
                        "deinit chains to the parent automatically — drop the override"
                    })
            }
            return
        }
        match self.inherited_method(
            function.owner, function.name) {
            some(parent) => {
                if function.is_async != parent.is_async {
                    self.fail(
                        function.syntax,
                        if parent.is_async {
                            "'{function.name}' must be async to match the parent declaration"
                        } else {
                            "'{function.name}' cannot be async — the parent declaration is synchronous"
                        })
                }
                let shared: int =
                    if function.parameters.len() <
                       parent.parameters.len() {
                        function.parameters.len()
                    } else {
                        parent.parameters.len()
                    }
                for index: int in 0..shared {
                    if function.parameters[index].passing !=
                       parent.parameters[index].passing {
                        self.fail(
                            function.syntax,
                            "override of '{function.name}' changes ownership mode of argument {index + 1}")
                    }
                }
                if parent.has_body {
                    if !function.is_override {
                        self.fail(
                            function.syntax,
                            "'{function.name}' hides an inherited method — mark it override")
                    } else {
                        self.add_dispatch_slots(
                            function, parent)
                        if !self.same_method_signature(
                               function, parent) {
                            self.fail(
                                function.syntax,
                                "override of '{function.name}' changes the signature: parent has {self.method_signature(parent)}, this is {self.method_signature(function)}")
                        }
                    }
                } else {
                    self.add_dispatch_slots(
                        function, parent)
                    if !self.same_method_signature(
                           function, parent) {
                        self.fail(
                            function.syntax,
                            "'{function.name}' doesn't match the interface: expected {self.method_signature(parent)}, this is {self.method_signature(function)}")
                    }
                }
            }
            none => {
                if function.is_override {
                    self.fail(
                        function.syntax,
                        "'{function.name}' is marked override but no parent has it")
                }
            }
        }
    }

    fn initializer_for(
        declaration: HirDeclaration) -> Option<HirFunction> {
        var pending: List<HirDeclaration> = [declaration]
        var seen: Map<string, bool> = {}
        for pending.len() != 0 {
            let current: HirDeclaration =
                pending.pop().expect("pending class")
            if seen.contains(current.qualified) { continue }
            seen[current.qualified] = true
            match self.methods.get(
                "{current.qualified}.init") {
                some(initializer) => {
                    return some(initializer)
                }
                none => {}
            }
            for relation: HirType in current.relations {
                match self.declaration_for(relation) {
                    some(parent) => {
                        if parent.kind == "class" {
                            pending.push(parent)
                        }
                    }
                    none => {}
                }
            }
        }
        return none
    }

    fn imported_path(name: string) -> string {
        return self.imports.get(
            "{self.current.file}|{name}").or("")
    }

    fn package_path_for_file(file_path: string) -> string {
        for package: LoadedPackage in
            self.signature.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                if file.path == file_path {
                    return package.import_path
                }
            }
        }
        return ""
    }

    fn package_label_for_file(file_path: string) -> string {
        for package: LoadedPackage in
            self.signature.resolver.loader.packages {
            for file: ParsedModuleFile in package.files {
                if file.path == file_path {
                    if package.prefix != "" {
                        return package.prefix
                    }
                    return package.import_path
                }
            }
        }
        return ""
    }

    fn require_visible(node: AstNode, is_public: bool,
                       owner_file: string, what: string,
                       shown: string) -> bool {
        let caller_package: string =
            self.package_path_for_file(self.current.file)
        let owner_package: string =
            self.package_path_for_file(owner_file)
        if caller_package == owner_package || is_public {
            return true
        }
        let owner_label: string =
            self.package_label_for_file(owner_file)
        self.fail(
            node,
            "{what} '{shown}' isn't pub in package '{owner_label}'")
        return false
    }

    fn check_initializer_visibility(
        node: AstNode, declaration: HirDeclaration,
        initializer: HirFunction) {
        self.require_visible(
            node, initializer.is_public,
            initializer.file, "init of",
            declaration.qualified)
    }

    fn static_syntax_name(syntax: AstNode) -> string {
        if syntax.kind == "field" &&
           syntax.children.len() == 1 {
            return "{syntax.children[0].value}.{syntax.value}"
        }
        return syntax.value
    }

    fn static_declaration(
        syntax: AstNode) -> Option<HirDeclaration> {
        if syntax.kind == "name" {
            return self.current_declaration(syntax.value)
        }
        if syntax.kind == "field" &&
           syntax.children.len() == 1 &&
           syntax.children[0].kind == "name" {
            let import_path: string =
                self.imported_path(
                    syntax.children[0].value)
            if import_path == "" { return none }
            let prefix: string =
                self.signature.resolver.package_prefix_for(
                    import_path)
            if prefix == "" { return none }
            match self.declarations.get(
                "{prefix}.{syntax.value}") {
                some(declaration) => {
                    self.require_visible(
                        syntax, declaration.is_public,
                        declaration.file, "type",
                        self.static_syntax_name(syntax))
                    return some(declaration)
                }
                none => { return none }
            }
        }
        return none
    }

    fn builtin_method(receiver: HirType, name: string) -> Option<BuiltinSignature> {
        let integer: HirType = new HirType("int")
        let boolean: HirType = new HirType("bool")
        let string: HirType = new HirType("string")
        let unit: HirType = new HirType("unit")
        if hir_is_integer(receiver) {
            if name == "abs" {
                return some(new BuiltinSignature(
                    [], receiver))
            }
        }
        if hir_is_float(receiver) {
            if name == "abs" {
                return some(new BuiltinSignature(
                    [], receiver))
            }
            if name == "round" {
                return some(new BuiltinSignature(
                    [], integer))
            }
        }
        if receiver.name == "decimal" &&
           name == "abs" {
            return some(new BuiltinSignature(
                [], receiver))
        }
        if receiver.name == "string" {
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "is_empty" {
                return some(new BuiltinSignature([], boolean))
            }
            if name == "last" || name == "first" ||
               name == "repeat" {
                return some(new BuiltinSignature(
                    [integer], string))
            }
            if name == "contains" || name == "starts_with" ||
               name == "ends_with" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
            if name == "find" || name == "rfind" {
                return some(new BuiltinSignature(
                    [string], hir_option(integer)))
            }
            if name == "slice" {
                return some(new BuiltinSignature(
                    [integer, integer], string))
            }
            if name == "byte_at" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "find_byte" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "range_equals" {
                return some(new BuiltinSignature(
                    [integer, integer, string], boolean))
            }
            if name == "parse_int_range_or" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], integer))
            }
            if name == "trim" || name == "trim_start" ||
               name == "trim_end" || name == "to_upper" ||
               name == "to_lower" {
                return some(new BuiltinSignature([], string))
            }
            if name == "replace" {
                return some(new BuiltinSignature(
                    [string, string], string))
            }
            if name == "split" {
                return some(new BuiltinSignature(
                    [string], hir_list(string)))
            }
            if name == "lines" || name == "chars" {
                return some(new BuiltinSignature(
                    [], hir_list(string)))
            }
            if name == "to_int" {
                return some(new BuiltinSignature(
                    [], hir_result(integer)))
            }
            if name == "to_float" {
                return some(new BuiltinSignature(
                    [], hir_result(new HirType("float"))))
            }
            if name == "to_decimal" {
                return some(new BuiltinSignature(
                    [], hir_result(new HirType("decimal"))))
            }
            if name == "count_chars" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
        }
        if receiver.name == "array" {
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if receiver.name == "List" && receiver.args.len() == 1 {
            let element: HirType = receiver.args[0]
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "is_empty" {
                return some(new BuiltinSignature([], boolean))
            }
            if name == "push" {
                return some(new BuiltinSignature([element], unit))
            }
            if name == "pop" {
                return some(new BuiltinSignature(
                    [], hir_option(element)))
            }
            if (name == "max" || name == "min") &&
               self.trait_satisfied(element, "Order") {
                return some(new BuiltinSignature(
                    [], hir_option(element)))
            }
            if name == "get" || name == "first" ||
               name == "last" {
                let parameters: List<HirType> =
                    if name == "get" { [integer] } else { [] }
                return some(new BuiltinSignature(
                    parameters, hir_option(element)))
            }
            if name == "contains" &&
               self.trait_satisfied(element, "Eq") {
                return some(new BuiltinSignature(
                    [element], boolean))
            }
            if name == "index_of" &&
               self.trait_satisfied(element, "Eq") {
                return some(new BuiltinSignature(
                    [element], hir_option(integer)))
            }
            if name == "join" {
                return some(new BuiltinSignature(
                    [string], string))
            }
            if name == "clear" ||
               name == "reverse" {
                return some(new BuiltinSignature([], unit))
            }
            if name == "sort" &&
               self.trait_satisfied(element, "Order") {
                return some(new BuiltinSignature([], unit))
            }
            if name == "reserve" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "insert" {
                return some(new BuiltinSignature(
                    [integer, element], unit))
            }
            if name == "clone" &&
               !self.is_move_only(element) &&
               self.trait_satisfied(element, "Clone") {
                return some(new BuiltinSignature([], receiver))
            }
            if name == "sort_by" {
                return some(new BuiltinSignature(
                    [hir_function(
                        [element, element], boolean)], unit))
            }
            if name == "sort_by_key" {
                return some(new BuiltinSignature(
                    [hir_function([element], integer)], unit))
            }
            if name == "slice" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "remove" {
                return some(new BuiltinSignature(
                    [integer], element))
            }
        }
        if (receiver.name == "Map" ||
            receiver.name == "OrderedMap") &&
           receiver.args.len() == 2 {
            let key: HirType = receiver.args[0]
            let value: HirType = receiver.args[1]
            if name == "get" {
                return some(new BuiltinSignature(
                    [key], hir_option(value)))
            }
            if name == "set" {
                return some(new BuiltinSignature(
                    [key, value], unit))
            }
            if name == "insert" {
                return some(new BuiltinSignature(
                    [key, value], boolean))
            }
            if name == "remove" || name == "contains" {
                return some(new BuiltinSignature(
                    [key], boolean))
            }
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "keys" {
                return some(new BuiltinSignature(
                    [], hir_list(key)))
            }
            if name == "values" {
                return some(new BuiltinSignature(
                    [], hir_list(value)))
            }
            if name == "clear" {
                return some(new BuiltinSignature([], unit))
            }
            if name == "reserve" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "clone" &&
               !self.is_move_only(key) &&
               !self.is_move_only(value) &&
               self.trait_satisfied(key, "Clone") &&
               self.trait_satisfied(value, "Clone") {
                return some(new BuiltinSignature([], receiver))
            }
        }
        if receiver.name == "Box" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "get" {
                return some(new BuiltinSignature([], value))
            }
            if name == "set" {
                return some(new BuiltinSignature([value], unit))
            }
        }
        if receiver.name == "Arena" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "put" {
                return some(new BuiltinSignature(
                    [value], integer))
            }
            if name == "get" {
                return some(new BuiltinSignature(
                    [integer], hir_option(value)))
            }
            if name == "at" {
                return some(new BuiltinSignature(
                    [integer], value))
            }
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "clear" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "Shared" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "get" {
                return some(new BuiltinSignature([], value))
            }
            if name == "downgrade" {
                return some(new BuiltinSignature(
                    [], hir_named("Weak", [value])))
            }
        }
        if receiver.name == "Weak" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "upgrade" {
                return some(new BuiltinSignature(
                    [], hir_option(hir_named(
                        "Shared", [value]))))
            }
            if name == "expired" {
                return some(new BuiltinSignature([], boolean))
            }
        }
        if receiver.name == "Thread" &&
           receiver.args.len() == 1 {
            if name == "join" {
                return some(new BuiltinSignature(
                    [], receiver.args[0]))
            }
        }
        if receiver.name == "Mutex" &&
           receiver.args.len() == 1 {
            if name == "with" {
                return some(new BuiltinSignature(
                    [hir_function(
                        [receiver.args[0]], unit)], unit))
            }
        }
        if receiver.name == "Channel" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "send" {
                return some(new BuiltinSignature([value], unit))
            }
            if name == "recv" {
                return some(new BuiltinSignature(
                    [], hir_option(value)))
            }
            if name == "close" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if receiver.name == "AtomicInt" {
            if name == "add" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "get" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "set" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
        }
        if receiver.name == "Atomic" &&
           receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            let order: HirType =
                new HirType("MemoryOrder")
            if name == "load" {
                return some(new BuiltinSignature(
                    [order], value))
            }
            if name == "store" {
                return some(new BuiltinSignature(
                    [value, order], unit))
            }
            if name == "exchange" ||
               name == "fetch_add" ||
               name == "fetch_sub" ||
               name == "fetch_and" ||
               name == "fetch_or" ||
               name == "fetch_xor" {
                return some(new BuiltinSignature(
                    [value, order], value))
            }
            if name == "compare_exchange" {
                return some(new BuiltinSignature(
                    [value, value, order, order], boolean))
            }
            if name == "wait" {
                return some(new BuiltinSignature(
                    [value, order], unit))
            }
            if name == "wait_timeout" {
                return some(new BuiltinSignature(
                    [value, integer, order], boolean))
            }
            if name == "notify_one" ||
               name == "notify_all" {
                return some(new BuiltinSignature([], integer))
            }
        }
        match simd_description(receiver.name) {
            some(simd) => {
                if name == "lane" {
                    return some(new BuiltinSignature(
                        [integer], simd.element))
                }
                if name == "with_lane" {
                    return some(new BuiltinSignature(
                        [integer, simd.element], receiver))
                }
                if name == "store" ||
                   name == "store_unaligned" {
                    return some(new BuiltinSignature(
                        [hir_named(
                            "RawPtr", [simd.element])],
                        unit))
                }
                if name == "lane_count" {
                    return some(new BuiltinSignature(
                        [], integer))
                }
                if name == "any_true" ||
                   name == "all_true" {
                    return some(new BuiltinSignature(
                        [], boolean))
                }
                if name == "sum" ||
                   name == "product" {
                    return some(new BuiltinSignature(
                        [], simd.element))
                }
                if name == "bit_not" &&
                   !simd.is_float {
                    return some(new BuiltinSignature(
                        [], receiver))
                }
                if (name == "shl" || name == "shr") &&
                   !simd.is_float {
                    return some(new BuiltinSignature(
                        [integer], receiver))
                }
                if name == "select" {
                    return some(new BuiltinSignature(
                        [receiver, receiver], receiver))
                }
                let vector_operation: bool =
                    name == "add" || name == "sub" ||
                    name == "mul" || name == "div" ||
                    name == "min" || name == "max" ||
                    name == "eq" || name == "ne" ||
                    name == "lt" || name == "le" ||
                    name == "gt" || name == "ge" ||
                    ((!simd.is_float) &&
                     (name == "bit_and" ||
                      name == "bit_or" ||
                      name == "bit_xor"))
                if vector_operation {
                    return some(new BuiltinSignature(
                        [receiver], receiver))
                }
            }
            none => {}
        }
        if receiver.name == "Option" && receiver.args.len() == 1 {
            let value: HirType = receiver.args[0]
            if name == "or" {
                return some(new BuiltinSignature([value], value))
            }
            if name == "expect" {
                return some(new BuiltinSignature([string], value))
            }
            if name == "is_some" || name == "is_none" {
                return some(new BuiltinSignature([], boolean))
            }
        }
        if receiver.name == "Result" && receiver.args.len() >= 1 {
            let value: HirType = receiver.args[0]
            if name == "or" {
                return some(new BuiltinSignature([value], value))
            }
            if name == "expect" {
                return some(new BuiltinSignature([string], value))
            }
            if name == "is_ok" {
                return some(new BuiltinSignature([], boolean))
            }
        }
        if receiver.name == "Bytes" {
            if name == "len" || name == "get" ||
               name == "get_u8" || name == "get_u16" ||
               name == "get_u32" || name == "get_u64" ||
               name == "get_i64" || name == "get_varint" {
                let parameters: List<HirType> =
                    if name == "len" { [] } else { [integer] }
                return some(new BuiltinSignature(
                    parameters, integer))
            }
            if name == "to_string" ||
               name == "to_string_full" {
                return some(new BuiltinSignature([], string))
            }
            if name == "slice" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "append_str" {
                return some(new BuiltinSignature(
                    [string], receiver))
            }
            if name == "push" || name == "reserve" ||
               name == "resize" || name == "fill" ||
               name == "append_i64" ||
               name == "append_varint" {
                return some(new BuiltinSignature(
                    [integer], receiver))
            }
            if name == "append" {
                return some(new BuiltinSignature(
                    [receiver], receiver))
            }
            if name == "set" ||
               name == "put_u8" ||
               name == "put_u16" ||
               name == "put_u32" ||
               name == "put_u64" ||
               name == "put_i64" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "copy_from" {
                return some(new BuiltinSignature(
                    [receiver, integer], receiver))
            }
            if name == "append_range" {
                return some(new BuiltinSignature(
                    [receiver, integer, integer], receiver))
            }
            if name == "crc32" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
        }
        if receiver.name == "File" {
            if name == "size" {
                return some(new BuiltinSignature(
                    [], hir_result(integer)))
            }
            if name == "read_at" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(new HirType("Bytes"))))
            }
            if name == "write_at" {
                return some(new BuiltinSignature(
                    [integer, new HirType("Bytes")],
                    hir_result(integer)))
            }
            if name == "read" {
                return some(new BuiltinSignature(
                    [integer], hir_result(new HirType("Bytes"))))
            }
            if name == "write" {
                return some(new BuiltinSignature(
                    [new HirType("Bytes")], hir_result(integer)))
            }
            if name == "close" || name == "sync" ||
               name == "truncate" || name == "lock" ||
               name == "try_lock" || name == "unlock" {
                let parameters: List<HirType> =
                    if name == "truncate" { [integer] } else { [] }
                return some(new BuiltinSignature(
                    parameters, hir_result(boolean)))
            }
            if name == "seek" ||
               name == "seek_end" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "tell" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if receiver.name == "MMap" {
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "get_u8" ||
               name == "get_u16" ||
               name == "get_u32" ||
               name == "get_u64" ||
               name == "get_i64" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "put_u8" ||
               name == "put_u16" ||
               name == "put_u32" ||
               name == "put_u64" ||
               name == "put_i64" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "read" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    new HirType("Bytes")))
            }
            if name == "write" {
                return some(new BuiltinSignature(
                    [integer, new HirType("Bytes")],
                    receiver))
            }
            if name == "flush" || name == "close" {
                return some(new BuiltinSignature(
                    [], hir_result(boolean)))
            }
            if name == "flush_range" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(boolean)))
            }
            if name == "resize" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
        }
        if receiver.name == "RawPtr" && receiver.args.len() == 1 {
            let element: HirType = receiver.args[0]
            if name == "read" { return some(
                new BuiltinSignature([], element)) }
            if name == "write" { return some(
                new BuiltinSignature([element], unit)) }
            if name == "read_volatile" { return some(
                new BuiltinSignature([], element)) }
            if name == "write_volatile" { return some(
                new BuiltinSignature([element], unit)) }
            if name == "offset" { return some(
                new BuiltinSignature([integer], receiver)) }
            if name == "address" { return some(
                new BuiltinSignature([], new HirType("u64"))) }
            if name == "is_null" { return some(
                new BuiltinSignature([], boolean)) }
            if name == "element_size" ||
               name == "element_align" { return some(
                new BuiltinSignature([], integer)) }
            if name == "copy_from" { return some(
                new BuiltinSignature(
                    [receiver, integer], unit)) }
            if name == "fill_zero" { return some(
                new BuiltinSignature([integer], unit)) }
            if name == "free" { return some(
                new BuiltinSignature([], unit)) }
            if name == "atomic_load" { return some(
                new BuiltinSignature([], element)) }
            if name == "atomic_store" { return some(
                new BuiltinSignature([element], unit)) }
            if name == "atomic_compare_exchange" {
                return some(new BuiltinSignature(
                    [element, element], boolean))
            }
            if name == "atomic_fetch_add" {
                return some(new BuiltinSignature(
                    [element], element))
            }
        }
        if receiver.name == "StoredCallback" &&
           receiver.args.len() == 1 &&
           receiver.args[0].name == "fn" {
            if name == "function" {
                return some(new BuiltinSignature(
                    [], receiver.args[0]))
            }
            if name == "context" {
                return some(new BuiltinSignature(
                    [], hir_named(
                        "RawPtr",
                        [new HirType("u8")])))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [], unit))
            }
        }
        if receiver.name == "Slice" &&
           receiver.args.len() == 1 {
            let element: HirType = receiver.args[0]
            if name == "len" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "get" {
                return some(new BuiltinSignature(
                    [integer], element))
            }
            if name == "set" {
                return some(new BuiltinSignature(
                    [integer, element], unit))
            }
            if name == "subslice" {
                return some(new BuiltinSignature(
                    [integer, integer], receiver))
            }
            if name == "as_ptr" {
                return some(new BuiltinSignature(
                    [], hir_named("RawPtr", [element])))
            }
        }
        return none
    }

    fn builtin_static(type_name: string, name: string) -> Option<BuiltinSignature> {
        let integer: HirType = new HirType("int")
        let boolean: HirType = new HirType("bool")
        let string: HirType = new HirType("string")
        if type_name == "Bytes" && name == "from" {
            return some(new BuiltinSignature(
                [string], new HirType("Bytes")))
        }
        if type_name == "File" {
            if name == "exists" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
            if name == "size" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "open" {
                return some(new BuiltinSignature(
                    [string, string],
                    hir_result(new HirType("File"))))
            }
            if name == "remove" {
                return some(new BuiltinSignature(
                    [string], hir_result(boolean)))
            }
            if name == "rename" {
                return some(new BuiltinSignature(
                    [string, string], hir_result(boolean)))
            }
        }
        if type_name == "Dir" {
            if name == "exists" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
            if name == "list" || name == "walk" {
                return some(new BuiltinSignature(
                    [string], hir_result(hir_list(string))))
            }
            if name == "make" || name == "make_all" ||
               name == "remove" || name == "remove_all" ||
               name == "sync" {
                return some(new BuiltinSignature(
                    [string], hir_result(boolean)))
            }
            if name == "temp" {
                return some(new BuiltinSignature([], string))
            }
        }
        if type_name == "Bytes" && name == "varint_size" {
            return some(new BuiltinSignature([integer], integer))
        }
        if type_name == "MMap" {
            if name == "open" {
                return some(new BuiltinSignature(
                    [string, boolean],
                    hir_result(new HirType("MMap"))))
            }
            if name == "open_shared" {
                return some(new BuiltinSignature(
                    [string, integer, boolean],
                    hir_result(new HirType("MMap"))))
            }
            if name == "unlink_shared" {
                return some(new BuiltinSignature(
                    [string], hir_result(boolean)))
            }
        }
        if type_name == "Atomic" && name == "fence" {
            return some(new BuiltinSignature(
                [new HirType("MemoryOrder")],
                new HirType("unit")))
        }
        return none
    }

    fn builtin_module(import_path: string, name: string) -> Option<BuiltinSignature> {
        let integer: HirType = new HirType("int")
        let boolean: HirType = new HirType("bool")
        let string: HirType = new HirType("string")
        let bytes: HirType = new HirType("Bytes")
        let unit: HirType = new HirType("unit")
        if import_path == "std.io" {
            if name == "println" || name == "eprintln" ||
               name == "print" || name == "eprint" {
                return some(new BuiltinSignature(
                    [new HirType("any")], unit))
            }
            if name == "read_line" {
                return some(new BuiltinSignature(
                    [], hir_option(string)))
            }
            if name == "read_all" {
                return some(new BuiltinSignature([], string))
            }
        }
        if import_path == "std.c" {
            if name == "errno" {
                return some(new BuiltinSignature(
                    [], new HirType("i32")))
            }
            if name == "set_errno" {
                return some(new BuiltinSignature(
                    [new HirType("i32")], unit))
            }
        }
        if import_path == "std.os" {
            if name == "args" {
                return some(new BuiltinSignature(
                    [], hir_list(string)))
            }
            if name == "env" {
                return some(new BuiltinSignature(
                    [string], hir_option(string)))
            }
            if name == "exit" || name == "sleep_ms" {
                return some(new BuiltinSignature([integer], unit))
            }
            if name == "now_ms" || name == "ticks_ms" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if import_path == "std.target" {
            if name == "triple" || name == "arch" ||
               name == "os" || name == "env" ||
               name == "object_format" || name == "endian" {
                return some(new BuiltinSignature([], string))
            }
            if name == "pointer_bits" ||
               name == "pointer_size" ||
               name == "stack_align" ||
               name == "max_simd_bits" {
                return some(new BuiltinSignature([], integer))
            }
        }
        if import_path == "std.random" {
            if name == "bytes" {
                return some(new BuiltinSignature(
                    [integer], hir_result(bytes)))
            }
            if name == "u64" {
                return some(new BuiltinSignature(
                    [], hir_result(integer)))
            }
            if name == "below" {
                return some(new BuiltinSignature(
                    [integer], hir_result(integer)))
            }
        }
        if import_path == "std.time" {
            if name == "monotonic_nanos" ||
               name == "wall_nanos" {
                return some(new BuiltinSignature([], integer))
            }
            if name == "sleep_nanos" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
        }
        if import_path == "std.fmt" {
            if name == "pad_left" ||
               name == "pad_right" {
                return some(new BuiltinSignature(
                    [string, integer], string))
            }
            if name == "float" {
                return some(new BuiltinSignature(
                    [new HirType("float"), integer],
                    string))
            }
            if name == "dec" {
                return some(new BuiltinSignature(
                    [new HirType("decimal"), integer],
                    string))
            }
        }
        if import_path == "std.asm" {
            if name == "value" {
                return some(new BuiltinSignature(
                    [string, string, integer], integer))
            }
            if name == "run" {
                return some(new BuiltinSignature(
                    [string, string], unit))
            }
        }
        if import_path == "std.intrinsic" {
            if name == "popcount" ||
               name == "leading_zeros" ||
               name == "trailing_zeros" ||
               name == "bswap16" ||
               name == "bswap32" ||
               name == "bswap64" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "rotate_left" ||
               name == "rotate_right" ||
               name == "crc32c" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "sqrt" {
                return some(new BuiltinSignature(
                    [new HirType("float")],
                    new HirType("float")))
            }
            if name == "sqrt32" {
                return some(new BuiltinSignature(
                    [new HirType("f32")],
                    new HirType("f32")))
            }
            if name == "fma" {
                let floating: HirType =
                    new HirType("float")
                return some(new BuiltinSignature(
                    [floating, floating, floating],
                    floating))
            }
            if name == "fma32" {
                let floating: HirType =
                    new HirType("f32")
                return some(new BuiltinSignature(
                    [floating, floating, floating],
                    floating))
            }
            if name == "prefetch" {
                return some(new BuiltinSignature(
                    [hir_named(
                        "RawPtr", [new HirType("u8")])],
                    unit))
            }
            if name == "spin_hint" {
                return some(new BuiltinSignature([], unit))
            }
        }
        if import_path == "std.cpu" {
            if name == "has" {
                return some(new BuiltinSignature(
                    [new HirType("CpuFeature")], boolean))
            }
            if name == "has_name" {
                return some(new BuiltinSignature(
                    [string], boolean))
            }
        }
        if import_path == "std.proc" {
            if name == "run" {
                return some(new BuiltinSignature(
                    [bytes, bytes, string, bytes, integer],
                    hir_result(bytes)))
            }
            if name == "start" {
                return some(new BuiltinSignature(
                    [bytes, bytes, string], hir_result(bytes)))
            }
            if name == "status" {
                return some(new BuiltinSignature(
                    [integer, integer], hir_result(bytes)))
            }
            if name == "signal" || name == "close" {
                let parameters: List<HirType> =
                    if name == "signal" {
                        [integer, integer]
                    } else {
                        [integer]
                    }
                return some(new BuiltinSignature(
                    parameters, hir_result(boolean)))
            }
            if name == "write" {
                return some(new BuiltinSignature(
                    [integer, bytes, integer], hir_result(integer)))
            }
            if name == "read" {
                return some(new BuiltinSignature(
                    [integer, integer], hir_result(bytes)))
            }
        }
        if import_path == "std.sock" {
            if name == "listen" ||
               name == "connect" {
                return some(new BuiltinSignature(
                    [string, integer, integer],
                    hir_result(integer)))
            }
            if name == "udp_bind" {
                return some(new BuiltinSignature(
                    [string, integer],
                    hir_result(integer)))
            }
            if name == "accept" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(integer)))
            }
            if name == "send" {
                return some(new BuiltinSignature(
                    [integer, bytes, integer],
                    hir_result(integer)))
            }
            if name == "recv" ||
               name == "recv_from" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(bytes)))
            }
            if name == "send_to" {
                return some(new BuiltinSignature(
                    [integer, bytes, string, integer],
                    hir_result(integer)))
            }
            if name == "address" {
                return some(new BuiltinSignature(
                    [integer, boolean],
                    hir_result(bytes)))
            }
            if name == "shutdown" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(boolean)))
            }
            if name == "set_timeouts" {
                return some(new BuiltinSignature(
                    [integer, integer, integer],
                    hir_result(boolean)))
            }
            if name == "set_nonblocking" {
                return some(new BuiltinSignature(
                    [integer, boolean],
                    hir_result(boolean)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "resolve" {
                return some(new BuiltinSignature(
                    [string, integer],
                    hir_result(hir_list(string))))
            }
        }
        if import_path == "std.sig" {
            if name == "watch" {
                return some(new BuiltinSignature(
                    [bytes], hir_result(integer)))
            }
            if name == "pending" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(bytes)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer, bytes],
                    hir_result(boolean)))
            }
            if name == "raise" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "number" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "name" {
                return some(new BuiltinSignature(
                    [integer], hir_result(string)))
            }
        }
        if import_path == "std.dl" {
            if name == "open" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "symbol" {
                return some(new BuiltinSignature(
                    [integer, string],
                    hir_result(integer)))
            }
            if name == "global_symbol" {
                return some(new BuiltinSignature(
                    [string], hir_result(integer)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "call0" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "call1" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
            if name == "call2" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], integer))
            }
            if name == "call3" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer],
                    integer))
            }
            if name == "call_void0" {
                return some(new BuiltinSignature(
                    [integer], unit))
            }
            if name == "call_void1" {
                return some(new BuiltinSignature(
                    [integer, integer], unit))
            }
            if name == "call_void2" {
                return some(new BuiltinSignature(
                    [integer, integer, integer], unit))
            }
            if name == "call_void3" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer],
                    unit))
            }
            if name == "call_f64_1" ||
               name == "call_f32_1" {
                return some(new BuiltinSignature(
                    [integer, new HirType("float")],
                    new HirType("float")))
            }
            if name == "call_f64_i32" ||
               name == "call_f32_i32" {
                return some(new BuiltinSignature(
                    [integer, new HirType("float"),
                     integer],
                    new HirType("float")))
            }
        }
        if import_path == "std.ready" {
            if name == "open" {
                return some(new BuiltinSignature(
                    [], hir_result(bytes)))
            }
            if name == "add" {
                return some(new BuiltinSignature(
                    [integer, integer, integer,
                     boolean, boolean, boolean],
                    hir_result(boolean)))
            }
            if name == "remove" {
                return some(new BuiltinSignature(
                    [integer, integer],
                    hir_result(boolean)))
            }
            if name == "wait" {
                return some(new BuiltinSignature(
                    [integer, integer, integer, integer],
                    hir_result(bytes)))
            }
            if name == "wake" {
                return some(new BuiltinSignature(
                    [integer], hir_result(boolean)))
            }
            if name == "close" {
                return some(new BuiltinSignature(
                    [integer, integer, integer],
                    hir_result(boolean)))
            }
            // The hidden async executor's thread-local state: the shared
            // reactor poller triple and the parked-await count. Internal —
            // only std.async$rt calls these.
            if name == "task_slot" {
                return some(new BuiltinSignature(
                    [integer], integer))
            }
            if name == "set_task_slot" {
                return some(new BuiltinSignature(
                    [integer, integer], integer))
            }
        }
        return none
    }

    fn make_node(node: AstNode, kind: string,
                 value: string, type: HirType) -> HirNode {
        let result: HirNode = new HirNode(
            kind, value, type, self.current.file,
            node.line, node.col)
        // The async expander reads types and argument modes from the AST,
        // so every checked node keeps a handle to its lowering. Later
        // make_node calls for the same AST node overwrite earlier ones;
        // the final one is the node's real meaning.
        node.checked = some(result)
        return result
    }

    fn expect_type(node: AstNode, actual: HirType,
                   expected: HirType) {
        if expected.name != "" &&
           !hir_types_equal(actual, expected) &&
           !self.is_subtype(actual, expected) {
            self.fail(
                node,
                "expected {render_hir_type(expected)}, got {render_hir_type(actual)}")
        }
    }

    // Statement annotations never reach the HIR lowering's validate_arity,
    // so a builtin generic spelled without its type arguments has to be
    // refused here; new-expressions stay exempt because `new Box(7)` may
    // take its type argument from the declared result type. False means the
    // caller must poison the annotation, so one arity mistake reports once
    // instead of cascading into mismatch and missing-method errors.
    fn validate_annotation_arity(node: AstNode, type: HirType) -> bool {
        var ok: bool = true
        let generic_arity: int =
            builtin_generic_arity(type.name)
        if generic_arity >= 0 &&
           type.args.len() != generic_arity {
            self.fail(
                node,
                "{type.name} needs {generic_arity} type argument(s), got {type.args.len()}")
            ok = false
        }
        for argument: HirType in type.args {
            if !self.validate_annotation_arity(node, argument) {
                ok = false
            }
        }
        return ok
    }

    fn validate_target_type(node: AstNode, type: HirType) {
        if type.name == "StoredCallback" &&
           type.args.len() == 1 &&
           type.args[0].name != "fn" {
            self.fail(
                node,
                "StoredCallback needs a C callback function type")
        }
        if (type.name == "RawPtr" ||
            type.name == "Slice") &&
           type.args.len() == 1 &&
           !self.is_raw_pointee(type.args[0]) {
            self.fail(
                node,
                "{type.name} only supports inline scalars, RawPtr, fixed arrays, and extern \"C\" struct/union values, got {render_hir_type(type.args[0])}")
        }
        if type.name == "array" {
            if type.array_length < 1 ||
               type.array_length > 4096 {
                self.fail(
                    node,
                    "fixed array length must be between 1 and 4096")
            }
            if type.args.len() == 1 &&
               !self.is_fixed_array_element(
                   type.args[0]) {
                self.fail(
                    node,
                    "fixed arrays need inline scalar, RawPtr, fixed-array, or struct elements, got {render_hir_type(type.args[0])}")
            }
        }
        if type.name == "decimal" &&
           !self.program.target.has_decimal {
            self.fail(
                node,
                "decimal is not available in the runtime for {self.program.target.triple}")
        }
        match simd_description(type.name) {
            some(simd) => {
                let width: int =
                    simd.lanes * simd.element_bits
                if width > self.program.target.max_simd_bits() {
                    self.fail(
                        node,
                        "{type.name} is {width} bits, and {self.program.target.triple} with the selected features supports at most {self.program.target.max_simd_bits()}")
                }
            }
            none => {
                // A digit after Simd is almost always a typo for a real
                // vector shape — but only when the name belongs to no
                // registered user declaration; a class by a non-vector
                // name is an ordinary type.
                if self.declaration_for(type).is_none() &&
                   type.name.len() > 4 &&
                   type.name.starts_with("Simd") &&
                   type.name.byte_at(4) >= 48 &&
                   type.name.byte_at(4) <= 57 {
                    self.fail(
                        node,
                        "unknown type '{type.name}'")
                }
            }
        }
        if type.name == "CpuFeature" {
            self.fail(
                node,
                "CpuFeature is not a type you can declare — a feature is named where it is asked about, like cpu.has(CpuFeature.avx2)")
        }
        if type.name == "MemoryOrder" {
            self.fail(
                node,
                "MemoryOrder is not a type you can declare — an order is written at the atomic call site, like a.load(MemoryOrder.acquire)")
        }
        if type.name == "Atomic" &&
           type.args.len() == 1 {
            let bits: int =
                atomic_element_bits(type.args[0])
            if bits == 0 {
                self.fail(
                    node,
                    "Atomic only supports integers and bool, got {render_hir_type(type.args[0])}")
            } else if !self.program.target.supports_atomic(
                bits) {
                self.fail(
                    node,
                    "Atomic<{render_hir_type(type.args[0])}> needs {bits}-bit atomics, which {self.program.target.triple} does not support")
            }
        }
        if (type.name == "Map" ||
            type.name == "OrderedMap") &&
           type.args.len() == 2 {
            if !self.trait_satisfied(type.args[0], "Eq") {
                self.fail(
                    node,
                    "{type.name} key needs Eq, got {render_hir_type(type.args[0])}")
            }
            if !self.trait_satisfied(type.args[0], "Hash") {
                self.fail(
                    node,
                    "{type.name} key needs Hash, got {render_hir_type(type.args[0])}")
            }
        }
        for argument: HirType in type.args {
            self.validate_target_type(node, argument)
        }
    }

    fn check_interpolations(node: AstNode) -> List<HirNode> {
        var lowered: List<HirNode> = []
        let raw: string = node.value
        if raw.len() < 2 { return move lowered }
        var index: int = 1
        let end: int = raw.len() - 1
        for index < end {
            let byte: int = raw.byte_at(index)
            if byte == 92 {
                index += 2
                continue
            }
            if byte != 123 {
                index += 1
                continue
            }
            let start: int = index + 1
            var cursor: int = start
            var depth: int = 1
            var in_string: bool = false
            for cursor < end && depth > 0 {
                let current: int = raw.byte_at(cursor)
                if current == 92 {
                    cursor += 2
                    continue
                }
                if in_string {
                    if current == 34 {
                        in_string = false
                    }
                } else if current == 34 {
                    in_string = true
                } else if current == 123 {
                    depth += 1
                } else if current == 125 {
                    depth -= 1
                }
                cursor += 1
            }
            if depth != 0 { break }
            let segment: string =
                raw.slice(start, cursor - 1)
            index = cursor
            if segment == "" {
                self.fail(
                    node,
                    "empty \{\} in string")
                continue
            }
            let expression_source: string =
                interpolation_expression_source(segment)
            let lexer: Lexer =
                new Lexer(expression_source)
            let tokens: List<Token> = lexer.scan()
            for diagnostic: Diagnostic in lexer.errors {
                self.fail(
                    node,
                    "in string piece \{{segment}\}: {diagnostic.message}")
            }
            let parser: Parser =
                new Parser(move tokens)
            // An interpolation piece is parsed with the surrounding body's
            // async context so the refusal below can name the real
            // problem instead of reporting a confused parse.
            parser.in_async = self.current.is_async
            let expression: AstNode =
                parser.parse_standalone_expression()
            if ast_contains_await(expression) {
                self.fail(
                    node,
                    "await is not allowed inside string interpolation — bind the awaited value to a local first")
            }
            for diagnostic: Diagnostic in parser.errors {
                self.fail(
                    node,
                    "in string piece \{{segment}\}: {diagnostic.message}")
            }
            if lexer.errors.len() == 0 &&
               parser.errors.len() == 0 {
                lowered.push(self.check_expression(
                    expression, no_hir_type()))
            }
        }
        return move lowered
    }

    fn check_literal(node: AstNode,
                     expected: HirType) -> HirNode {
        var type: HirType = new HirType("int")
        if node.note == "string" {
            type = new HirType("string")
        } else if node.note == "true" || node.note == "false" {
            type = new HirType("bool")
        } else if node.note == "float" {
            if expected.name == "decimal" ||
               canonical_hir_name(expected.name) == "float" ||
               expected.name == "f32" {
                type = expected
            } else {
                type = new HirType("float")
            }
        } else if node.note == "int" &&
                  expected.name != "" &&
                  hir_is_numeric(expected) {
            type = expected
        }
        if node.note == "int" && hir_is_integer(type) &&
           !integer_literal_fits(
               node.value, type.name, self.literal_sign < 0) {
            let sign: string =
                if self.literal_sign < 0 { "-" } else { "" }
            self.fail(
                node,
                "integer literal {sign}{node.value} does not fit {render_hir_type(type)} ({integer_literal_range(type.name)})")
        }
        if type.name == "decimal" &&
           !decimal_literal_fits(node.value) {
            self.fail(
                node,
                "decimal literal exceeds 38-digit precision or scale")
        }
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(
                node, "literal", node.value, type)
        if node.note == "string" {
            for expression: HirNode in
                self.check_interpolations(node) {
                result.children.push(expression)
            }
        }
        return result
    }

    fn check_name(node: AstNode,
                  expected: HirType) -> HirNode {
        if node.value == "none" &&
           expected.name == "Option" {
            return self.make_node(
                node, "none", "none", expected)
        }
        match self.find_local(node.value) {
            some(binding) => {
                let captured: bool =
                    self.capture_floor_depth >= 0 &&
                    self.local_scope_index(node.value) <
                        self.capture_floor_depth
                if captured {
                    binding.borrowed = true
                    if binding.inout_parameter &&
                       !self.bad_inout_captures.contains(
                           node.value) {
                        self.bad_inout_captures[node.value] = true
                        self.fail(
                            node,
                            "closure cannot capture inout parameter '{node.value}'")
                    }
                    if self.require_send_captures &&
                       !self.trait_satisfied(
                           binding.type, "Send") &&
                       !self.bad_send_captures.contains(
                           node.value) {
                        self.bad_send_captures[node.value] = true
                        self.fail(
                            node,
                            "thread closure cannot capture '{node.value}' of non-Send type {render_hir_type(binding.type)}")
                    }
                    if self.require_sync_captures &&
                       !self.trait_satisfied(
                           binding.type, "Sync") &&
                       !self.bad_sync_captures.contains(
                           node.value) {
                        self.bad_sync_captures[node.value] = true
                        self.fail(
                            node,
                            "stored callback cannot capture '{node.value}' of non-Sync type {render_hir_type(binding.type)}")
                    }
                }
                if binding.move_state == "async_pending" {
                    // the hidden handle never escapes: awaiting the
                    // binding is its only read
                    self.fail(
                        node,
                        "async let binding '{node.value}' must be awaited")
                } else if binding.move_state == "async_done" {
                    self.fail(
                        node,
                        "async let binding '{node.value}' was already awaited")
                } else if binding.move_state == "moved" {
                    self.fail(
                        node,
                        "use of moved value '{node.value}'")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        node,
                        "value '{node.value}' may have been moved")
                }
                self.expect_type(node, binding.type, expected)
                let result: HirNode = self.make_node(
                    node, "local", node.value, binding.type)
                result.binding_id = binding.id
                return result
            }
            none => {}
        }
        match self.current_c_global(node.value) {
            some(global) => {
                self.require_unsafe(
                    node,
                    "reading extern C global '{node.value}'")
                self.expect_type(
                    node, global.type, expected)
                let result: HirNode =
                    self.make_node(
                        node, "c_global",
                        node.value, global.type)
                result.resolved =
                    global.qualified
                return result
            }
            none => {}
        }
        match self.current_function(node.value) {
            some(function) => {
                if function.is_extern_c {
                    self.fail(
                        node,
                        "extern C function '{function.name}' cannot be stored as a Beans function value yet")
                }
                if function.is_async {
                    self.fail(
                        node,
                        "'{function.name}' is async and cannot be stored as a function value — call it with await or 'async let'")
                }
                self.require_function_feature(
                    node, function,
                    "storing it as a function value")
                for parameter: HirParameter in
                    function.parameters {
                    if parameter.passing != "" {
                        self.fail(
                            node,
                            "function '{function.name}' has ownership parameters and cannot be stored as a value yet")
                        break
                    }
                }
                let type: HirType = self.function_type(function)
                self.expect_type(node, type, expected)
                let result: HirNode =
                    self.make_node(node, "function", node.value, type)
                result.resolved = function.qualified
                return result
            }
            none => {}
        }
        if node.value == "self" {
            self.fail(node, "self isn't available here")
            return self.make_node(
                node, "error", node.value, poison_hir_type())
        }
        self.fail(node, "unknown name '{node.value}'")
        return self.make_node(
            node, "error", node.value, poison_hir_type())
    }

    fn require_move_source(node: AstNode,
                           type: HirType,
                           where: string) {
        if !self.is_move_only(type) { return }
        if node.kind == "unary" &&
           node.value == "move" {
            return
        }
        if node.kind == "name" {
            self.fail(
                node,
                "{where} needs 'move {node.value}' because {render_hir_type(type)} is move-only")
        } else if node.kind == "field" ||
                  node.kind == "index" {
            self.fail(
                node,
                "{where} cannot move a field or index yet — move it through a local")
        }
    }

    fn check_move(node: AstNode,
                  expected: HirType) -> HirNode {
        if node.children.len() != 1 ||
           node.children[0].kind != "name" {
            self.fail(node, "move needs a local name")
            return self.make_node(
                node, "error", "move", poison_hir_type())
        }
        let source: AstNode = node.children[0]
        match self.find_local(source.value) {
            some(binding) => {
                let operand: HirNode =
                    self.make_node(
                        source, "local",
                        source.value, binding.type)
                operand.binding_id = binding.id
                let result: HirNode =
                    self.make_node(
                        node, "unary", "move", binding.type)
                result.children.push(operand)
                if binding.move_state == "moved" {
                    self.fail(
                        node,
                        "value '{source.value}' was already moved")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        node,
                        "value '{source.value}' may already have been moved")
                } else if binding.borrowed {
                    self.fail(
                        node,
                        "can't move borrowed binding '{source.value}'")
                } else if self.take_floor_depth >= 0 &&
                          self.local_scope_index(
                              source.value) <
                              self.take_floor_depth {
                    self.fail(
                        node,
                        "can't move outer value '{source.value}' from a loop or escaping closure")
                } else if self.defer_depth > 0 {
                    self.fail(
                        node,
                        "move is not allowed inside defer")
                } else {
                    binding.move_state = "moved"
                }
                self.expect_type(
                    node, binding.type, expected)
                return result
            }
            none => {
                self.fail(
                    source,
                    "unknown local '{source.value}'")
                return self.make_node(
                    node, "error", "move",
                    poison_hir_type())
            }
        }
    }

    fn check_inout(node: AstNode,
                   expected: HirType) -> HirNode {
        if !self.allow_inout_expression {
            self.fail(
                node,
                "inout is only valid for an inout call argument")
        }
        if node.children.len() != 1 ||
           node.children[0].kind != "name" {
            self.fail(
                node,
                "inout needs a mutable local name")
            return self.make_node(
                node, "error", "inout",
                poison_hir_type())
        }
        let source: AstNode = node.children[0]
        match self.find_local(source.value) {
            some(binding) => {
                if !binding.mutable {
                    self.fail(
                        node,
                        "inout needs var, but '{source.value}' is a let")
                }
                if binding.move_state == "moved" {
                    self.fail(
                        node,
                        "use of moved value '{source.value}'")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        node,
                        "value '{source.value}' may have been moved")
                }
                let result: HirNode =
                    self.make_node(
                        node, "unary", "inout",
                        binding.type)
                result.children.push(
                    self.make_node(
                        source, "local",
                        source.value, binding.type))
                result.children[0].binding_id = binding.id
                self.expect_type(
                    node, binding.type, expected)
                return result
            }
            none => {
                self.fail(
                    source,
                    "unknown local '{source.value}'")
                return self.make_node(
                    node, "error", "inout",
                    poison_hir_type())
            }
        }
    }

    fn check_unary(node: AstNode,
                   expected: HirType) -> HirNode {
        if node.value == "move" {
            return self.check_move(node, expected)
        }
        if node.value == "inout" {
            return self.check_inout(node, expected)
        }
        let signed_literal: bool =
            node.value == "-" &&
            integer_literal_syntax(node.children[0])
        if signed_literal {
            self.literal_sign = -self.literal_sign
        }
        let operand: HirNode =
            self.check_expression(node.children[0], expected)
        if signed_literal {
            self.literal_sign = -self.literal_sign
        }
        let result: HirNode =
            self.make_node(node, "unary", node.value, operand.type)
        result.children.push(operand)
        if node.value == "-" {
            if !hir_is_numeric(operand.type) {
                self.fail(
                    node,
                    "unary '-' needs a number, got {render_hir_type(operand.type)}")
            }
        } else if node.value == "!" {
            if operand.type.name != "bool" {
                self.fail(
                    node,
                    "unary '!' needs bool, got {render_hir_type(operand.type)}")
            }
            result.type = new HirType("bool")
        } else if node.value == "~" {
            if !hir_is_integer(operand.type) {
                self.fail(
                    node,
                    "unary '~' needs an integer, got {render_hir_type(operand.type)}")
            }
        } else if node.value != "move" &&
                  node.value != "take" &&
                  node.value != "inout" {
            self.fail(node, "unknown unary operator '{node.value}'")
        }
        self.expect_type(node, result.type, expected)
        return result
    }

    fn check_binary(node: AstNode,
                    expected: HirType) -> HirNode {
        let operation: string = node.value
        var operand_expected: HirType = no_hir_type()
        if operation == "&&" || operation == "||" {
            operand_expected = new HirType("bool")
        } else if operation == "+" || operation == "-" ||
                  operation == "*" || operation == "/" ||
                  operation == "%" || operation == "&" ||
                  operation == "|" || operation == "^" ||
                  operation == "<<" || operation == ">>" {
            operand_expected = expected
        }
        let left: HirNode =
            self.check_expression(
                node.children[0], operand_expected)
        let right: HirNode =
            self.check_expression(node.children[1], left.type)
        var type: HirType = left.type
        if simd_description(left.type.name).is_some() ||
           simd_description(right.type.name).is_some() {
            let shown: string =
                if simd_description(left.type.name).is_some() {
                    left.type.name
                } else {
                    right.type.name
                }
            self.require_unsafe(
                node,
                "{shown} arithmetic")
        }
        if operation == "&&" || operation == "||" {
            if left.type.name != "bool" ||
               right.type.name != "bool" {
                self.fail(node, "'{operation}' needs bool operands")
            }
            type = new HirType("bool")
        } else if operation == "==" || operation == "!=" {
            if !hir_types_equal(left.type, right.type) {
                self.fail(node, "comparison operands have different types")
            }
            type = new HirType("bool")
        } else if operation == "<" || operation == "<=" ||
                  operation == ">" || operation == ">=" {
            if !hir_types_equal(left.type, right.type) ||
               (!hir_is_numeric(left.type) &&
                left.type.name != "string") {
                self.fail(
                    node,
                    "'{operation}' needs matching ordered operands")
            }
            type = new HirType("bool")
        } else if operation == ".." || operation == "..=" {
            if !hir_types_equal(left.type, right.type) ||
               !hir_is_integer(left.type) {
                self.fail(node, "range bounds need matching integers")
            }
            type = new HirType("range")
            type.args.push(left.type)
        } else if (operation == "+" || operation == "-" ||
                   operation == "*" || operation == "/") &&
                  simd_description(
                      left.type.name).is_some() {
            if !hir_types_equal(
                left.type, right.type) {
                self.fail(
                    node,
                    "'{operation}' needs matching SIMD vectors")
            }
        } else if operation == "+" && left.type.name == "string" {
            if right.type.name != "string" {
                self.fail(node, "string '+' needs another string")
            }
        } else if operation == "+" || operation == "-" ||
                  operation == "*" || operation == "/" ||
                  operation == "%" {
            if !hir_types_equal(left.type, right.type) ||
               !hir_is_numeric(left.type) {
                self.fail(
                    node,
                    "'{operation}' needs matching numbers")
            }
        } else if operation == "&" || operation == "|" ||
                  operation == "^" || operation == "<<" ||
                  operation == ">>" {
            if !hir_types_equal(left.type, right.type) ||
               !hir_is_integer(left.type) {
                self.fail(
                    node,
                    "'{operation}' needs matching integers")
            }
        } else {
            self.fail(node, "operator '{operation}' is not checked yet")
        }
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(node, "binary", operation, type)
        result.children.push(left)
        result.children.push(right)
        return result
    }

    fn check_field(node: AstNode,
                   expected: HirType) -> HirNode {
        let receiver_syntax: AstNode = node.children[0]
        match self.static_declaration(
            receiver_syntax) {
            some(declaration) => {
                if declaration.kind == "enum" {
                    match self.variant_for(
                        declaration, node.value) {
                        some(variant) => {
                            if variant.type.args.len() != 0 {
                                self.fail(
                                    node,
                                    "enum variant '{node.value}' needs payload values")
                            }
                            let type: HirType =
                                new HirType(
                                    declaration.qualified)
                            self.expect_type(
                                node, type, expected)
                            let result: HirNode =
                                self.make_node(
                                    node, "variant",
                                    node.value, type)
                            result.resolved =
                                "{declaration.qualified}.{node.value}"
                            return result
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        if receiver_syntax.kind == "name" {
            if receiver_syntax.value == "MemoryOrder" {
                self.fail(
                    node,
                    "MemoryOrder.{node.value} names an atomic instruction order, not a value — write it directly at the atomic call site")
                let result: HirNode = self.make_node(
                    node, "error", node.value,
                    poison_hir_type())
                return result
            }
            if receiver_syntax.value == "RoundingMode" {
                if node.value != "half_even" &&
                   node.value != "half_away" &&
                   node.value != "toward_zero" &&
                   node.value != "floor" &&
                   node.value != "ceil" {
                    self.fail(
                        node,
                        "unknown rounding mode '{node.value}'; the modes are half_even, half_away, toward_zero, floor, ceil")
                }
                let type: HirType =
                    new HirType("RoundingMode")
                self.expect_type(node, type, expected)
                let result: HirNode =
                    self.make_node(
                        node, "variant", node.value, type)
                result.resolved =
                    "RoundingMode.{node.value}"
                return result
            }
            if receiver_syntax.value == "CpuFeature" {
                self.fail(
                    node,
                    "CpuFeature.{node.value} names a CPU feature to ask about, not a value — use it directly, like cpu.has(CpuFeature.{node.value})")
                let result: HirNode = self.make_node(
                    node, "error", node.value,
                    poison_hir_type())
                return result
            }
            match self.current_declaration(receiver_syntax.value) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        match self.variant_for(
                            declaration, node.value) {
                            some(variant) => {
                                if variant.type.args.len() != 0 {
                                    self.fail(
                                        node,
                                        "enum variant '{node.value}' needs payload values")
                                }
                                let type: HirType =
                                    new HirType(
                                        declaration.qualified)
                                self.expect_type(
                                    node, type, expected)
                                let result: HirNode =
                                    self.make_node(
                                        node, "variant",
                                        node.value, type)
                                result.resolved =
                                    "{declaration.qualified}.{node.value}"
                                return result
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
        }
        let receiver: HirNode =
            self.check_expression(node.children[0], no_hir_type())
        if receiver.type.name == "Error" &&
           (node.value == "msg" ||
            node.value == "kind") {
            let type: HirType =
                new HirType("string")
            self.expect_type(node, type, expected)
            let result: HirNode =
                self.make_node(
                    node, "field", node.value, type)
            result.children.push(receiver)
            return result
        }
        match self.field_for(receiver.type, node.value) {
            some(field) => {
                self.require_visible(
                    node, field.field.is_public,
                    field.field.file, "field",
                    "{render_hir_type(receiver.type)}.{node.value}")
                match self.declaration_for(receiver.type) {
                    some(declaration) => {
                        if declaration.kind == "union" {
                            self.require_unsafe(
                                node,
                                "union field access")
                        }
                    }
                    none => {}
                }
                self.expect_type(node, field.type, expected)
                let result: HirNode =
                    self.make_node(
                        node, "field", node.value, field.type)
                result.children.push(receiver)
                return result
            }
            none => {
                if receiver.type.name != "poison" {
                    self.fail(
                        node,
                        "{render_hir_type(receiver.type)} has no field '{node.value}'")
                }
                return self.make_node(
                    node, "error", node.value, poison_hir_type())
            }
        }
    }

    fn atomic_argument_is_order(operation: string,
                                index: int) -> bool {
        if operation == "fence" ||
           operation == "load" {
            return index == 0
        }
        if operation == "store" ||
           operation == "exchange" ||
           operation == "fetch_add" ||
           operation == "fetch_sub" ||
           operation == "fetch_and" ||
           operation == "fetch_or" ||
           operation == "fetch_xor" ||
           operation == "wait" {
            return index == 1
        }
        if operation == "wait_timeout" {
            return index == 2
        }
        if operation == "compare_exchange" {
            return index == 2 || index == 3
        }
        return false
    }

    fn check_memory_order(node: AstNode) -> HirNode {
        if node.kind != "field" ||
           node.children.len() != 1 ||
           node.children[0].kind != "name" ||
           node.children[0].value != "MemoryOrder" {
            self.fail(
                node,
                "a memory order must be written out at the call site, like MemoryOrder.acquire — the order becomes part of the instruction, so it cannot be decided at run time")
            return self.make_node(
                node, "error", "order",
                poison_hir_type())
        }
        if memory_order_value(node.value) < 0 {
            self.fail(
                node,
                "unknown memory order '{node.value}'; the orders are relaxed, acquire, release, acq_rel, seq_cst")
        }
        let result: HirNode =
            self.make_node(
                node, "selector", node.value,
                new HirType("MemoryOrder"))
        result.resolved =
            "MemoryOrder.{node.value}"
        return result
    }

    fn check_atomic_arguments(
        node: AstNode, first: int,
        signature: BuiltinSignature,
        operation: string, result: HirNode) {
        let count: int = node.children.len() - first
        if count != signature.parameters.len() {
            // A builtin constructor reads as the new-expression it came
            // from; every other builtin keeps its qualified spelling.
            let shown: string =
                if result.kind == "new" {
                    "new {result.value}"
                } else if result.resolved == "" {
                    "builtin"
                } else {
                    "'{result.resolved}'"
                }
            self.fail(
                node,
                "{shown} takes {signature.parameters.len()} argument(s), got {count}")
        }
        let shared: int =
            if count < signature.parameters.len() {
                count
            } else {
                signature.parameters.len()
            }
        var primary: int = -1
        var failure: int = -1
        var primary_node: Option<AstNode> = none
        var failure_node: Option<AstNode> = none
        for index: int in 0..shared {
            let argument: AstNode =
                node.children[index + first]
            if self.atomic_argument_is_order(
                operation, index) {
                result.children.push(
                    self.check_memory_order(argument))
                let order: int =
                    if argument.kind == "field" {
                        memory_order_value(
                            argument.value)
                    } else {
                        -1
                    }
                if operation == "compare_exchange" &&
                   index == 3 {
                    failure = order
                    failure_node = some(argument)
                } else {
                    primary = order
                    primary_node = some(argument)
                }
            } else {
                result.children.push(
                    self.check_expression(
                        argument,
                        signature.parameters[index]))
            }
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first],
                no_hir_type()))
        }

        let load_like: bool =
            operation == "load" ||
            operation == "wait" ||
            operation == "wait_timeout"
        if load_like &&
           (primary == 2 || primary == 3) {
            match primary_node {
                some(order_node) => {
                    self.fail(
                        order_node,
                        "an atomic load cannot use MemoryOrder.{order_node.value}; use relaxed, acquire or seq_cst")
                }
                none => {}
            }
        }
        if operation == "store" &&
           (primary == 1 || primary == 3) {
            match primary_node {
                some(order_node) => {
                    self.fail(
                        order_node,
                        "an atomic store cannot use MemoryOrder.{order_node.value}; use relaxed, release or seq_cst")
                }
                none => {}
            }
        }
        if operation == "compare_exchange" &&
           failure >= 0 {
            match failure_node {
                some(order_node) => {
                    if failure == 2 || failure == 3 {
                        self.fail(
                            order_node,
                            "the failure order cannot be MemoryOrder.{order_node.value} — a failed compare_exchange performs no write")
                    } else if primary >= 0 &&
                              memory_order_strength(failure) > memory_order_strength(primary) {
                        match primary_node {
                            some(success_node) => {
                                self.fail(
                                    order_node,
                                    "the failure order MemoryOrder.{order_node.value} is stronger than the success order MemoryOrder.{success_node.value} — the path that did nothing cannot promise more than the path that wrote")
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
        }
    }

    fn check_argument(
        syntax: AstNode, expected: HirType,
        passing: string, what: string, index: int,
        inout inout_names: Map<string, bool>) -> HirNode {
        let saved_inout: bool =
            self.allow_inout_expression
        self.allow_inout_expression =
            passing == "inout"
        let result: HirNode =
            self.check_expression(syntax, expected)
        self.allow_inout_expression = saved_inout
        if passing == "move" {
            self.require_move_source(
                syntax, result.type,
                "{what} move argument {index + 1}")
        } else if passing == "inout" {
            if syntax.kind != "unary" ||
               syntax.value != "inout" ||
               syntax.children.len() != 1 ||
               syntax.children[0].kind != "name" {
                self.fail(
                    syntax,
                    "{what} inout argument {index + 1} must be 'inout var_name'")
            } else {
                let name: string =
                    syntax.children[0].value
                if inout_names.contains(name) {
                    self.fail(
                        syntax,
                        "overlapping inout arguments for '{name}'")
                }
                inout_names[name] = true
            }
        }
        return result
    }

    fn check_arguments(node: AstNode, first: int,
                       function: HirFunction,
                       owner: HirType,
                       shown: string,
                       result: HirNode) {
        let count: int = node.children.len() - first
        if count != function.parameters.len() {
            self.fail(
                node,
                "{shown} takes {function.parameters.len()} argument(s), got {count}")
        }
        let shared: int =
            if count < function.parameters.len() {
                count
            } else {
                function.parameters.len()
            }
        var owner_declaration: Option<HirDeclaration> = none
        if owner.name != "" {
            owner_declaration = self.declaration_for(owner)
        }
        var inout_names: Map<string, bool> = {}
        for result.argument_passing.len() <
            result.children.len() {
            result.argument_passing.push("")
        }
        for index: int in 0..shared {
            var parameter_type: HirType =
                function.parameters[index].type
            match owner_declaration {
                some(declaration) => {
                    parameter_type = self.substitute_owner_type(
                        parameter_type, declaration, owner)
                }
                none => {}
            }
            result.children.push(self.check_argument(
                node.children[index + first],
                parameter_type,
                function.parameters[index].passing,
                "'{function.name}'", index,
                inout inout_names))
            result.argument_passing.push(
                function.parameters[index].passing)
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first], no_hir_type()))
            result.argument_passing.push("")
        }
    }

    fn check_generic_arguments(
        node: AstNode, first: int,
        function: HirFunction, expected: HirType,
        shown: string,
        result: HirNode) {
        var inference: Map<string, HirType> = {}
        if expected.name != "" {
            self.infer_generic_type(
                function.result, expected,
                function.generics, inout inference, node)
        }
        let count: int = node.children.len() - first
        if count != function.parameters.len() {
            self.fail(
                node,
                "{shown} takes {function.parameters.len()} argument(s), got {count}")
        }
        let shared: int =
            if count < function.parameters.len() {
                count
            } else {
                function.parameters.len()
            }
        var inout_names: Map<string, bool> = {}
        for result.argument_passing.len() <
            result.children.len() {
            result.argument_passing.push("")
        }
        for index: int in 0..shared {
            let pattern: HirType =
                function.parameters[index].type
            let before: HirType =
                self.substitute_generic_type(
                    pattern, function.generics,
                    inference)
            let actual: HirNode =
                self.check_argument(
                    node.children[index + first],
                    if self.has_unbound_generic(
                        pattern, function.generics,
                        inference) {
                        no_hir_type()
                    } else {
                        before
                    },
                    function.parameters[index].passing,
                    "'{function.name}'", index,
                    inout inout_names)
            self.infer_generic_type(
                pattern, actual.type,
                function.generics,
                inout inference,
                node.children[index + first])
            let wanted: HirType =
                self.substitute_generic_type(
                    pattern, function.generics,
                    inference)
            self.expect_type(
                node.children[index + first],
                actual.type, wanted)
            result.children.push(actual)
            result.argument_passing.push(
                function.parameters[index].passing)
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first],
                no_hir_type()))
            result.argument_passing.push("")
        }
        for generic: string in function.generics {
            if !inference.contains(generic) {
                self.fail(
                    node,
                    "can't infer generic type '{generic}' for '{function.name}'")
                inference[generic] = poison_hir_type()
            }
        }
        for constraint: HirGeneric in
            function.generic_constraints {
            match inference.get(constraint.name) {
                some(actual) => {
                    for bound: HirType in constraint.bounds {
                        if !self.trait_satisfied(
                            actual, bound.name) {
                            self.fail(
                                node,
                                "'{function.name}' needs {constraint.name} implements {render_hir_type(bound)}, got {render_hir_type(actual)}")
                        }
                    }
                }
                none => {}
            }
        }
        result.type =
            self.substitute_generic_type(
                function.result,
                function.generics, inference)
    }

    fn check_builtin_arguments(node: AstNode, first: int,
                               signature: BuiltinSignature,
                               result: HirNode) {
        let count: int = node.children.len() - first
        if count != signature.parameters.len() {
            // A builtin constructor reads as the new-expression it came
            // from; every other builtin keeps its qualified spelling.
            let shown: string =
                if result.kind == "new" {
                    "new {result.value}"
                } else if result.resolved == "" {
                    "builtin"
                } else {
                    "'{result.resolved}'"
                }
            self.fail(
                node,
                "{shown} takes {signature.parameters.len()} argument(s), got {count}")
        }
        let shared: int =
            if count < signature.parameters.len() {
                count
            } else {
                signature.parameters.len()
            }
        for index: int in 0..shared {
            let expected: HirType =
                signature.parameters[index]
            let intrinsic: bool =
                result.resolved.starts_with(
                    "std.intrinsic.")
            let numeric_literal: bool =
                node.children[index + first].kind ==
                    "literal" &&
                (node.children[index + first].note ==
                     "int" ||
                 node.children[index + first].note ==
                     "float")
            let checked: HirNode =
                self.check_expression(
                node.children[index + first],
                if expected.name == "any" ||
                   (intrinsic &&
                    !numeric_literal) {
                    no_hir_type()
                } else {
                    expected
                })
            if intrinsic &&
               !hir_types_equal(
                   checked.type, expected) &&
               !self.is_subtype(
                   checked.type, expected) {
                self.fail(
                    node.children[index + first],
                    "argument {index + 1} is {render_hir_type(expected)}, got {render_hir_type(checked.type)}")
            }
            result.children.push(checked)
        }
        for index: int in shared..count {
            result.children.push(self.check_expression(
                node.children[index + first], no_hir_type()))
        }
    }

    fn asm_template_known(template: string) -> bool {
        return template == "mov $0, $1" ||
               template == "dmb ish" ||
               template == "dmb ishst" ||
               template == "isb" ||
               template == "mfence" ||
               template == "lfence" ||
               template == "sfence" ||
               template == "dmb sy" ||
               template == "cpsid i" ||
               template == "cpsie i" ||
               template == "wfi" ||
               template == "fence rw, rw" ||
               template == "csrci mstatus, 8" ||
               template == "csrsi mstatus, 8"
    }

    fn asm_template_allowed(template: string) -> bool {
        let arch: string = self.program.target.arch
        if arch == "arm64" {
            return template == "mov $0, $1" ||
                   template == "dmb ish" ||
                   template == "dmb ishst" ||
                   template == "isb"
        }
        if arch == "x86_64" {
            return template == "mov $0, $1" ||
                   template == "mfence" ||
                   template == "lfence" ||
                   template == "sfence"
        }
        if arch == "arm32" {
            return template == "dmb sy" ||
                   template == "cpsid i" ||
                   template == "cpsie i" ||
                   template == "wfi"
        }
        if arch == "riscv32" {
            return template == "fence rw, rw" ||
                   template == "csrci mstatus, 8" ||
                   template == "csrsi mstatus, 8" ||
                   template == "wfi"
        }
        return false
    }

    fn asm_templates_for_target() -> string {
        let arch: string = self.program.target.arch
        if arch == "arm64" {
            return "\"mov $0, $1\", \"dmb ish\", \"dmb ishst\", \"isb\""
        }
        if arch == "x86_64" {
            return "\"mov $0, $1\", \"mfence\", \"lfence\", \"sfence\""
        }
        if arch == "arm32" {
            return "\"dmb sy\", \"cpsid i\", \"cpsie i\", \"wfi\""
        }
        if arch == "riscv32" {
            return "\"fence rw, rw\", \"csrci mstatus, 8\", \"csrsi mstatus, 8\", \"wfi\""
        }
        return "none"
    }

    fn check_asm_call(node: AstNode, callee: AstNode,
                      expected: HirType) -> HirNode {
        let wants_value: bool = callee.value == "value"
        if !wants_value && callee.value != "run" {
            self.fail(
                node,
                "std.asm has only 'value' and 'run'; call them as asm.value(template, constraints, x) or asm.run(template, constraints)")
            for index: int in 1..node.children.len() {
                self.check_expression(
                    node.children[index], no_hir_type())
            }
            return self.make_node(
                node, "error", "asm",
                poison_hir_type())
        }

        let result_type: HirType =
            if wants_value {
                new HirType("int")
            } else {
                new HirType("unit")
            }
        let result: HirNode =
            self.make_node(
                node, "builtin_call",
                callee.value, result_type)
        let parameters: List<HirType> =
            if wants_value {
                [new HirType("string"),
                 new HirType("string"),
                 new HirType("int")]
            } else {
                [new HirType("string"),
                 new HirType("string")]
            }
        let count: int = node.children.len() - 1
        if count != parameters.len() {
            self.fail(
                node,
                "asm.{callee.value} takes {parameters.len()} arguments: a template, a constraint string{if wants_value { " and one int" } else { "" }}")
        }
        for index: int in 0..count {
            result.children.push(
                self.check_expression(
                    node.children[index + 1],
                    if index < parameters.len() {
                        parameters[index]
                    } else {
                        no_hir_type()
                    }))
        }
        self.expect_type(node, result_type, expected)
        if count != parameters.len() {
            return result
        }

        let template_node: AstNode = node.children[1]
        let constraint_node: AstNode = node.children[2]
        var literals_ok: bool = true
        if template_node.kind != "literal" ||
           template_node.note != "string" {
            self.fail(
                template_node,
                "the assembly template must be a plain string literal, so the compiler can check it before it reaches the assembler")
            literals_ok = false
        }
        if constraint_node.kind != "literal" ||
           constraint_node.note != "string" {
            self.fail(
                constraint_node,
                "the constraint string must be a plain string literal, so the compiler can check it before it reaches the assembler")
            literals_ok = false
        }
        if !literals_ok { return result }

        if template_node.value.contains("\{") ||
           template_node.value.contains("\\") {
            self.fail(
                template_node,
                "the assembly template must be a plain string literal: no interpolation and no escapes")
            literals_ok = false
        }
        if constraint_node.value.contains("\{") ||
           constraint_node.value.contains("\\") {
            self.fail(
                constraint_node,
                "the constraint string must be a plain string literal: no interpolation and no escapes")
            literals_ok = false
        }
        if !literals_ok { return result }

        let template: string =
            template_node.value.slice(
                1, template_node.value.len() - 1)
        let constraints: string =
            constraint_node.value.slice(
                1, constraint_node.value.len() - 1)
        if !self.asm_template_allowed(template) {
            if self.asm_template_known(template) {
                self.fail(
                    node,
                    "\"{template}\" is not {self.program.target.arch} assembly; this target allows {self.asm_templates_for_target()}")
            } else {
                self.fail(
                    node,
                    "\"{template}\" is not an allowed assembly template; {self.program.target.arch} allows {self.asm_templates_for_target()}")
            }
            return result
        }

        let row_wants_value: bool =
            template == "mov $0, $1"
        let row_constraints: string =
            if row_wants_value { "=r,r" } else { "memory" }
        if constraints != row_constraints {
            self.fail(
                node,
                "\"{template}\" takes the constraints \"{row_constraints}\", not \"{constraints}\"")
            return result
        }
        if row_wants_value != wants_value {
            self.fail(
                node,
                "\"{template}\" {if row_wants_value { "produces a value, so it is asm.value" } else { "produces no value, so it is asm.run" }}")
            return result
        }
        result.resolved = "std.asm.{callee.value}"
        return result
    }

    fn check_package_call(node: AstNode, callee: AstNode,
                          import_path: string,
                          expected: HirType) -> Option<HirNode> {
        if import_path == "std.asm" {
            return some(
                self.check_asm_call(
                    node, callee, expected))
        }
        if import_path == "std.cpu" &&
           callee.value == "has" {
            let result: HirNode =
                self.make_node(
                    node, "builtin_call", "has",
                    new HirType("bool"))
            result.resolved = "std.cpu.has"
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "cpu.has takes one CPU feature")
                for index: int in 1..node.children.len() {
                    result.children.push(
                        self.check_expression(
                            node.children[index],
                            no_hir_type()))
                }
            } else {
                let argument: AstNode = node.children[1]
                if argument.kind != "field" ||
                   argument.children.len() != 1 ||
                   argument.children[0].kind != "name" ||
                   argument.children[0].value != "CpuFeature" {
                    self.fail(
                        argument,
                        "name the feature at the call site, like cpu.has(CpuFeature.avx2)")
                } else {
                    let feature: string =
                        self.program.target.normalize_feature(
                            argument.value)
                    if !self.program.target.is_known_feature(
                        feature) {
                        var known: List<string> = []
                        for item: string in
                            self.program.target.known_features() {
                            known.push(
                                self.program.target.feature_spelling(
                                    item))
                        }
                        self.fail(
                            argument,
                            "'{argument.value}' is not a feature {self.program.target.triple} has; its features are {known.join(", ")}")
                    }
                    let selector: HirNode =
                        self.make_node(
                            argument, "selector",
                            feature,
                            new HirType("CpuFeature"))
                    selector.resolved =
                        "CpuFeature.{feature}"
                    result.children.push(selector)
                }
            }
            self.expect_type(
                node, result.type, expected)
            return some(result)
        }
        if import_path == "std.intrinsic" &&
           callee.value == "crc32c" {
            // crc32c takes a 64-bit accumulator, and the instruction that
            // consumes one is 64-bit-only. LLVM has llvm.x86.sse42.crc32.32.*
            // on 32-bit x86 but no .64.64, so this row has no lowering there.
            // Refuse it by name; SSE4.2 being present changes nothing.
            if self.program.target.arch == "x86" {
                self.fail(
                    node,
                    "intrinsic.crc32c needs a 64-bit accumulator and {self.program.target.arch} has no instruction for one")
            }
            let feature: string =
                if self.program.target.arch == "arm64" {
                    "crc"
                } else {
                    "sse4.2"
                }
            self.require_named_feature(
                node,
                "intrinsic.crc32c",
                feature,
                "the call")
        }
        if import_path == "std.intrinsic" {
            let names: List<string> = [
                "popcount", "leading_zeros",
                "trailing_zeros", "bswap16",
                "bswap32", "bswap64", "rotate_left",
                "rotate_right", "sqrt", "sqrt32",
                "fma", "fma32", "prefetch",
                "spin_hint", "crc32c",
            ]
            if !names.contains(callee.value) {
                self.fail(
                    node,
                    "no intrinsic '{callee.value}'; the intrinsics are {names.join(", ")}")
                for index: int in
                    1..node.children.len() {
                    self.check_expression(
                        node.children[index],
                        no_hir_type())
                }
                return some(self.make_node(
                    node, "error", callee.value,
                    poison_hir_type()))
            }
        }
        if import_path == "std.thread" &&
           callee.value == "spawn" {
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "thread.spawn takes 1 closure, got {count}")
                return some(self.make_node(
                    node, "error", "spawn",
                    poison_hir_type()))
            }
            let saved_send: bool =
                self.require_send_captures
            self.require_send_captures = true
            let closure: HirNode =
                self.check_expression(
                    node.children[1], no_hir_type())
            self.require_send_captures = saved_send
            if closure.type.name != "fn" ||
               closure.type.fn_parameter_count != 0 ||
               closure.type.fn_parameter_count >=
                   closure.type.args.len() {
                self.fail(
                    node,
                    "thread.spawn needs a closure with no parameters")
                return some(self.make_node(
                    node, "error", "spawn",
                    poison_hir_type()))
            }
            let result_type: HirType =
                hir_named("Thread", [
                    closure.type.args[
                        closure.type.fn_parameter_count]])
            let closure_result: HirType =
                closure.type.args[
                    closure.type.fn_parameter_count]
            if !self.trait_satisfied(
                closure_result, "Send") {
                self.fail(
                    node.children[1],
                    "thread.spawn closure returns non-Send type {render_hir_type(closure_result)}")
            }
            self.expect_type(
                node, result_type, expected)
            let result: HirNode =
                self.make_node(
                    node, "builtin_call",
                    "spawn", result_type)
            result.resolved = "std.thread.spawn"
            result.children.push(closure)
            return some(result)
        }
        let prefix: string =
            self.signature.resolver.package_prefix_for(import_path)
        if prefix != "" {
            match self.functions.get("{prefix}.{callee.value}") {
                some(function) => {
                    self.require_visible(
                        node, function.is_public,
                        function.file, "function",
                        "{node.children[0].children[0].value}.{callee.value}")
                    self.require_function_feature(
                        node, function, "the call")
                    if function.is_extern_c &&
                       !function.is_c_export {
                        self.require_unsafe(
                            node,
                            "extern C call '{function.name}'")
                    }
                    let result: HirNode =
                        self.make_node(
                            node, "call", function.name,
                            function.result)
                    self.validate_async_call(node, function)
                    result.resolved = function.qualified
                    if function.generics.len() != 0 {
                        self.check_generic_arguments(
                            node, 1, function,
                            expected,
                            "'{function.name}'", result)
                    } else {
                        self.check_arguments(
                            node, 1, function,
                            no_hir_type(),
                            "'{function.name}'", result)
                    }
                    self.expect_type(node, result.type, expected)
                    return some(result)
                }
                none => {}
            }
        }
        match self.builtin_module(import_path, callee.value) {
            some(signature) => {
                self.validate_target_type(
                    node, signature.result)
                let result: HirNode =
                    self.make_node(
                        node, "builtin_call",
                        callee.value, signature.result)
                result.resolved = "{import_path}.{callee.value}"
                self.check_builtin_arguments(
                    node, 1, signature, result)
                self.expect_type(node, result.type, expected)
                return some(result)
            }
            none => {}
        }
        return none
    }

    fn check_special_call(node: AstNode, callee: AstNode,
                          expected: HirType) -> Option<HirNode> {
        if callee.value == "size_of" ||
           callee.value == "align_of" ||
           callee.value == "offset_of" {
            let wanted: int =
                if callee.value == "offset_of" { 2 } else { 1 }
            let count: int = node.children.len() - 1
            if count != wanted {
                self.fail(
                    node,
                    "{callee.value} takes {wanted} argument(s), got {count}")
            }
            var layout_type: HirType =
                poison_hir_type()
            if count >= 1 {
                let written: AstNode = node.children[1]
                if written.kind == "name" {
                    match self.declarations.get(
                        written.value) {
                        some(declaration) => {
                            layout_type = new HirType(
                                declaration.qualified)
                        }
                        none => {
                            let scalar: bool =
                                hir_is_numeric(
                                    new HirType(
                                        written.value)) ||
                                written.value == "bool" ||
                                written.value == "unit" ||
                                written.value == "RawPtr" ||
                                written.value == "Slice" ||
                                simd_description(
                                    written.value).is_some()
                            if scalar {
                                layout_type =
                                    new HirType(
                                        canonical_hir_name(
                                            written.value))
                            } else {
                                self.fail(
                                    written,
                                    "unknown layout type '{written.value}'")
                            }
                        }
                    }
                } else {
                    match self.static_declaration(written) {
                        some(declaration) => {
                            layout_type =
                                new HirType(
                                    declaration.qualified)
                        }
                        none => {
                            self.fail(
                                written,
                                "{callee.value} needs a type name")
                        }
                    }
                }
            }
            if callee.value == "offset_of" &&
               count >= 2 {
                let field: AstNode = node.children[2]
                var found: bool = false
                match self.declaration_for(layout_type) {
                    some(declaration) => {
                        for declared: HirField in
                            declaration.fields {
                            if declared.name == field.value {
                                found = true
                            }
                        }
                    }
                    none => {}
                }
                if field.kind != "name" || !found {
                    self.fail(
                        field,
                        "offset_of needs a field of {render_hir_type(layout_type)}")
                }
            }
            let type: HirType = new HirType("int")
            self.expect_type(node, type, expected)
            let result: HirNode =
                self.make_node(
                    node, "layout_query",
                    callee.value, type)
            let type_source: AstNode =
                if count >= 1 {
                    node.children[1]
                } else {
                    callee
                }
            let type_node: HirNode =
                self.make_node(
                    type_source,
                    "type", hir_type_key(layout_type),
                    layout_type)
            result.children.push(type_node)
            return some(result)
        }
        if callee.value == "some" {
            if node.children.len() != 2 {
                self.fail(node, "some takes 1 argument")
                return some(self.make_node(
                    node, "error", "some", poison_hir_type()))
            }
            var element_expected: HirType = no_hir_type()
            if expected.name == "Option" &&
               expected.args.len() == 1 {
                element_expected = expected.args[0]
            }
            let value: HirNode = self.check_expression(
                node.children[1], element_expected)
            self.require_move_source(
                node.children[1], value.type, "some")
            let type: HirType =
                if element_expected.name == "" {
                    hir_option(value.type)
                } else {
                    expected
                }
            let result: HirNode =
                self.make_node(node, "some", "some", type)
            result.children.push(value)
            return some(result)
        }
        if callee.value == "ok" {
            if node.children.len() != 2 {
                self.fail(node, "ok takes 1 argument")
                return some(self.make_node(
                    node, "error", "ok", poison_hir_type()))
            }
            var value_expected: HirType = no_hir_type()
            if expected.name == "Result" &&
               expected.args.len() >= 1 {
                value_expected = expected.args[0]
            }
            let value: HirNode = self.check_expression(
                node.children[1], value_expected)
            self.require_move_source(
                node.children[1], value.type, "ok")
            let type: HirType =
                if expected.name == "Result" {
                    expected
                } else {
                    hir_result(value.type)
                }
            let result: HirNode =
                self.make_node(node, "ok", "ok", type)
            result.children.push(value)
            return some(result)
        }
        if callee.value == "err" {
            if expected.name != "Result" {
                self.fail(
                    node,
                    "can't tell the ok-type of this err(...) — the spot needs a declared Result type")
            }
            var error_type: HirType =
                new HirType("Error")
            if expected.name == "Result" &&
               expected.args.len() >= 2 {
                error_type = expected.args[1]
            }
            let custom_error: bool =
                error_type.name != "Error"
            let count: int =
                node.children.len() - 1
            if custom_error && count == 2 {
                self.fail(
                    node,
                    "err(message, kind) builds an Error, not {render_hir_type(error_type)}")
                return some(self.make_node(
                    node, "error", "err",
                    poison_hir_type()))
            }
            if (custom_error && count != 1) ||
               (!custom_error &&
                count != 1 && count != 2) {
                self.fail(
                    node,
                    if custom_error {
                        "err takes one {render_hir_type(error_type)} value"
                    } else {
                        "err takes a message, or a message and a kind"
                    })
                return some(self.make_node(
                    node, "error", "err",
                    poison_hir_type()))
            }
            let result: HirNode =
                self.make_node(
                    node, "err", "err",
                    if expected.name == "Result" {
                        expected
                    } else {
                        hir_result(poison_hir_type())
                    })
            if !custom_error && count == 2 {
                let message: HirNode =
                    self.check_expression(
                        node.children[1],
                        no_hir_type())
                let kind: HirNode =
                    self.check_expression(
                        node.children[2],
                        no_hir_type())
                if canonical_hir_name(
                       message.type.name) != "string" ||
                   canonical_hir_name(
                       kind.type.name) != "string" {
                    self.fail(
                        node,
                        "err(message, kind) takes two strings, got {render_hir_type(message.type)} and {render_hir_type(kind.type)}")
                }
                result.children.push(message)
                result.children.push(kind)
            } else if custom_error {
                result.children.push(
                    self.check_expression(
                        node.children[1], error_type))
            } else {
                // For the built-in Error, err(message) constructs one and
                // err(existing_error) re-raises one — the shape ?
                // propagation needs when the failure came out of another
                // Result.
                let argument: HirNode =
                    self.check_expression(
                        node.children[1], no_hir_type())
                if canonical_hir_name(argument.type.name) !=
                       "string" &&
                   !hir_types_equal(argument.type, error_type) &&
                   argument.type.name != "poison" {
                    self.fail(
                        node,
                        "err takes a message string or an Error value, got {render_hir_type(argument.type)}")
                }
                result.children.push(argument)
            }
            return some(result)
        }
        return none
    }

    fn check_layout_query(node: AstNode,
                          expected: HirType) -> HirNode {
        var queried: HirType =
            hir_type_from_ast(node.children[0])
        match self.declaration_for(queried) {
            some(declaration) => {
                queried.name = declaration.qualified
            }
            none => {}
        }
        self.validate_target_type(
            node.children[0], queried)
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        var generic_layout: bool = false
        for constraint: HirGeneric in
            self.current_constraints {
            if constraint.name == queried.name {
                generic_layout = true
            }
        }
        if generic_layout &&
           node.value != "offset_of" {
            self.fail(
                node,
                "{node.value}: type parameter {queried.name} has no layout at this point")
        } else if node.value == "offset_of" {
            match self.declaration_for(queried) {
                some(declaration) => {
                    if declaration.kind != "struct" &&
                       declaration.kind != "union" {
                        self.fail(
                            node,
                            "offset_of: offset_of needs a struct or union, got {render_hir_type(queried)}")
                    } else if node.children.len() >= 2 {
                        let field_name: string =
                            node.children[1].value
                        var found: bool = false
                        var fields: List<string> = []
                        for field: HirField in
                            declaration.fields {
                            fields.push(field.name)
                            if field.name == field_name {
                                found = true
                            }
                        }
                        if !found {
                            self.fail(
                                node,
                                "offset_of: {render_hir_type(queried)} has no field '{field_name}'; its fields are {fields.join(", ")}")
                        }
                    }
                }
                none => {
                    self.fail(
                        node,
                        "offset_of: offset_of needs a struct or union, got {render_hir_type(queried)}")
                }
            }
        } else {
            let answer: LayoutAnswer =
                engine.layout_type(queried)
            if !answer.ok {
                self.fail(
                    node,
                    "{node.value}: {answer.message}")
            }
        }
        let type: HirType = new HirType("int")
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(
                node, "layout_query",
                node.value, type)
        if node.value == "offset_of" &&
           node.children.len() >= 2 {
            result.resolved =
                node.children[1].value
        }
        result.children.push(
            self.make_node(
                node.children[0], "type",
                render_hir_type(queried), queried))
        return result
    }

    fn check_higher_order_method(
        node: AstNode, callee: AstNode,
        receiver: HirNode,
        expected: HirType) -> Option<HirNode> {
        let option_method: bool =
            receiver.type.name == "Option" &&
            (callee.value == "map" ||
             callee.value == "and_then" ||
             callee.value == "filter")
        let result_method: bool =
            receiver.type.name == "Result" &&
            (callee.value == "map" ||
             callee.value == "and_then" ||
             callee.value == "recover")
        if !option_method && !result_method {
            return none
        }
        let count: int = node.children.len() - 1
        if count != 1 {
            self.fail(
                node,
                "{receiver.type.name}.{callee.value} takes one closure")
            return some(self.make_node(
                node, "error", callee.value,
                poison_hir_type()))
        }
        let value_type: HirType =
            receiver.type.args[0]
        var error_type: HirType =
            new HirType("Error")
        if receiver.type.name == "Result" &&
           receiver.type.args.len() >= 2 {
            error_type = receiver.type.args[1]
        }
        var callback_expected: HirType =
            no_hir_type()
        if callee.value == "filter" {
            callback_expected = hir_function(
                [value_type], new HirType("bool"))
        } else if callee.value == "recover" {
            callback_expected = hir_function(
                [error_type], value_type)
        } else if expected.name ==
                  receiver.type.name &&
                  expected.args.len() >= 1 {
            let callback_result: HirType =
                if callee.value == "and_then" {
                    expected
                } else {
                    expected.args[0]
                }
            callback_expected = hir_function(
                [value_type], callback_result)
        }
        let callback: HirNode =
            self.check_expression(
                node.children[1], callback_expected)
        var result_type: HirType =
            poison_hir_type()
        if callback.type.name != "fn" ||
           callback.type.fn_parameter_count != 1 ||
           callback.type.fn_parameter_count >=
               callback.type.args.len() {
            self.fail(
                node,
                "{receiver.type.name}.{callee.value} needs a one-parameter closure")
        } else {
            self.expect_type(
                node.children[1],
                callback.type.args[0],
                if callee.value == "recover" {
                    error_type
                } else {
                    value_type
                })
            let callback_result: HirType =
                callback.type.args[
                    callback.type.fn_parameter_count]
            if callee.value == "filter" {
                self.expect_type(
                    node.children[1],
                    callback_result,
                    new HirType("bool"))
                result_type = receiver.type
            } else if callee.value == "recover" {
                self.expect_type(
                    node.children[1],
                    callback_result, value_type)
                result_type = value_type
            } else if callee.value == "and_then" {
                if callback_result.name !=
                   receiver.type.name {
                    self.fail(
                        node,
                        "{callee.value} closure must return {receiver.type.name}")
                }
                result_type = callback_result
            } else if receiver.type.name == "Option" {
                result_type =
                    hir_option(callback_result)
            } else {
                result_type =
                    hir_named(
                        "Result",
                        [callback_result, error_type])
            }
        }
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(
                node, "builtin_method",
                callee.value, result_type)
        result.resolved =
            "{receiver.type.name}.{callee.value}"
        result.children.push(receiver)
        result.children.push(callback)
        return some(result)
    }

    // Asyncness is an effect on the callable. A call to an async function
    // is legal only directly under await (or as an async let initializer);
    // anywhere else it is a bare call, and a synchronous function has no
    // way to wait at all.
    fn validate_async_call(node: AstNode,
                           function: HirFunction) {
        if !function.is_async { return }
        // After expansion the "async" function is really a synchronous
        // task maker; the re-check of expanded bodies calls it bare.
        if function.expanded { return }
        // The allowance lives on the exact call node the await marked, so
        // calls in receivers or arguments never inherit it.
        let allowed: bool = node.await_allowed
        node.await_allowed = false
        if !self.current.is_async {
            self.fail(
                node,
                "'{function.name}' is async and can only be called from an async function")
            return
        }
        if !allowed {
            self.fail(
                node,
                "async call must be awaited or started with 'async let'")
        }
    }

    fn check_call(node: AstNode,
                  expected: HirType) -> HirNode {
        let callee: AstNode = node.children[0]
        // The async expander pins its generated calls to a qualified name
        // (the internal runtime package is not importable), so a pre-
        // resolved callee looks up directly, skipping scope resolution.
        if callee.kind == "name" &&
           callee.resolved.starts_with("async$rt.") {
            match self.functions.get(callee.resolved) {
                some(function) => {
                    let result: HirNode =
                        self.make_node(
                            node, "call", function.name,
                            function.result)
                    result.resolved = function.qualified
                    self.check_arguments(
                        node, 1, function, no_hir_type(),
                        "'{function.name}'", result)
                    self.expect_type(node, result.type, expected)
                    return result
                }
                none => {}
            }
        }
        if callee.kind == "field" {
            let receiver_syntax: AstNode = callee.children[0]
            if receiver_syntax.kind == "name" &&
               receiver_syntax.value == "super" {
                if callee.value == "init" {
                    let result: HirNode =
                        self.make_node(
                            node, "super_init", "init",
                            new HirType("unit"))
                    if self.current.name != "init" ||
                       self.current.owner == "" {
                        self.fail(
                            node,
                            "super.init can only be called from init")
                        return result
                    }
                    match self.super_method("init") {
                        some(target) => {
                            self.require_visible(
                                node,
                                target.function.is_public,
                                target.function.file,
                                "init of", target.owner.name)
                            result.resolved =
                                target.function.qualified
                            self.check_arguments(
                                node, 1, target.function,
                                target.owner,
                                "super.init", result)
                        }
                        none => {
                            self.fail(
                                node,
                                "no parent constructor to call")
                        }
                    }
                    return result
                }

                if self.current.owner == "" ||
                   self.current.is_static {
                    self.fail(
                        node,
                        "super.{callee.value} can only be called from an instance method")
                    return self.make_node(
                        node, "error", callee.value,
                        poison_hir_type())
                }
                if callee.value == "deinit" {
                    self.fail(
                        node,
                        "deinit is automatic and cannot be called with super")
                    return self.make_node(
                        node, "error", callee.value,
                        poison_hir_type())
                }
                var has_parent: bool = false
                match self.declarations.get(
                    self.current.owner) {
                    some(owner) => {
                        has_parent =
                            self.parent_class_type(
                                self.declaration_instance(owner)).is_some()
                    }
                    none => {}
                }
                if !has_parent {
                    self.fail(
                        node,
                        "super.{callee.value} needs a parent class")
                    return self.make_node(
                        node, "error", callee.value,
                        poison_hir_type())
                }
                match self.super_method(callee.value) {
                    some(target) => {
                        self.require_visible(
                            node, target.function.is_public,
                            target.function.file, "method",
                            "{target.owner.name}.{callee.value}")
                        let owner: HirDeclaration =
                            self.declaration_for(target.owner).expect(
                                "super method owner")
                        let result_type: HirType =
                            self.substitute_owner_type(
                                target.function.result,
                                owner, target.owner)
                        let result: HirNode =
                            self.make_node(
                                node, "super_call",
                                callee.value, result_type)
                        self.validate_async_call(
                            node, target.function)
                        result.resolved =
                            target.function.qualified
                        self.check_arguments(
                            node, 1, target.function,
                            target.owner,
                            "super.{callee.value}", result)
                        self.expect_type(
                            node, result.type, expected)
                        return result
                    }
                    none => {
                        self.fail(
                            node,
                            "no parent implementation of '{callee.value}'")
                        return self.make_node(
                            node, "error", callee.value,
                            poison_hir_type())
                    }
                }
            }
            match self.static_declaration(
                receiver_syntax) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        match self.variant_for(
                            declaration, callee.value) {
                            some(variant) => {
                                var type: HirType =
                                    new HirType(
                                        declaration.qualified)
                                if expected.name ==
                                   declaration.qualified ||
                                   expected.name ==
                                   declaration.name {
                                    type = expected
                                }
                                var parameters: List<HirType> = []
                                for payload: HirType in
                                    variant.type.args {
                                    parameters.push(
                                        self.substitute_owner_type(
                                            payload,
                                            declaration, type))
                                }
                                let result: HirNode =
                                    self.make_node(
                                        node, "variant",
                                        callee.value, type)
                                result.resolved =
                                    "{declaration.qualified}.{callee.value}"
                                self.check_builtin_arguments(
                                    node, 1,
                                    new BuiltinSignature(
                                        parameters, type),
                                    result)
                                let stored: int =
                                    if parameters.len() <
                                       result.children.len() {
                                        parameters.len()
                                    } else {
                                        result.children.len()
                                    }
                                for index: int in 0..stored {
                                    self.require_move_source(
                                        node.children[index + 1],
                                        result.children[index].type,
                                        "enum variant '{callee.value}'")
                                }
                                self.expect_type(
                                    node, type, expected)
                                return result
                            }
                            none => {}
                        }
                    }
                    match self.methods.get(
                        "{declaration.qualified}.{callee.value}") {
                        some(function) => {
                            if function.is_static {
                                self.require_visible(
                                    node, function.is_public,
                                    function.file, "static",
                                    "{self.static_syntax_name(receiver_syntax)}.{callee.value}")
                                let result: HirNode =
                                    self.make_node(
                                        node, "static_call",
                                        function.name,
                                        function.result)
                                self.validate_async_call(
                                    node, function)
                                result.resolved =
                                    function.qualified
                                if function.generics.len() != 0 {
                                    self.check_generic_arguments(
                                        node, 1, function,
                                        expected,
                                        "'{self.static_syntax_name(receiver_syntax)}.{callee.value}'",
                                        result)
                                } else {
                                    self.check_arguments(
                                        node, 1, function,
                                        no_hir_type(),
                                        "'{self.static_syntax_name(receiver_syntax)}.{callee.value}'",
                                        result)
                                }
                                self.expect_type(
                                    node, result.type, expected)
                                return result
                            }
                            self.fail(
                                node,
                                "'{callee.value}' is an instance method — declare 'static fn {callee.value}' or call it on a {declaration.name} value")
                            return self.make_node(
                                node, "error",
                                callee.value,
                                poison_hir_type())
                        }
                        none => {
                            if declaration.kind != "enum" {
                                self.fail(
                                    node,
                                    "{declaration.name} has no static '{callee.value}'")
                                return self.make_node(
                                    node, "error",
                                    callee.value,
                                    poison_hir_type())
                            }
                        }
                    }
                }
                none => {}
            }
            if receiver_syntax.kind == "name" {
                match self.current_declaration(
                    receiver_syntax.value) {
                    some(declaration) => {
                        if declaration.kind == "enum" {
                            match self.variant_for(
                                declaration, callee.value) {
                                some(variant) => {
                                    let type: HirType =
                                        new HirType(
                                            declaration.qualified)
                                    let result: HirNode =
                                        self.make_node(
                                            node, "variant",
                                            callee.value, type)
                                    result.resolved =
                                        "{declaration.qualified}.{callee.value}"
                                    let signature: BuiltinSignature =
                                        new BuiltinSignature(
                                            variant.type.args, type)
                                    self.check_builtin_arguments(
                                        node, 1, signature, result)
                                    self.expect_type(
                                        node, type, expected)
                                    return result
                                }
                                none => {}
                            }
                        }
                    }
                    none => {}
                }
                let import_path: string =
                    self.imported_path(receiver_syntax.value)
                if import_path != "" {
                    let unsafe_module_call: bool =
                        import_path == "std.asm" ||
                        import_path == "std.intrinsic" ||
                        (import_path == "std.dl" &&
                         (callee.value == "call0" ||
                          callee.value == "call1" ||
                          callee.value == "call2" ||
                          callee.value == "call3" ||
                          callee.value ==
                              "call_void0" ||
                          callee.value ==
                              "call_void1" ||
                          callee.value ==
                              "call_void2" ||
                          callee.value ==
                              "call_void3" ||
                          callee.value ==
                              "call_f64_1" ||
                          callee.value ==
                              "call_f64_i32" ||
                          callee.value ==
                              "call_f32_1" ||
                          callee.value ==
                              "call_f32_i32"))
                    if unsafe_module_call {
                        self.require_unsafe(
                            node,
                            "{receiver_syntax.value}.{callee.value}")
                    }
                    match self.check_package_call(
                        node, callee, import_path, expected) {
                        some(result) => { return result }
                        none => {
                            self.fail(
                                node,
                                "package '{receiver_syntax.value}' ({import_path}) has no function '{callee.value}'")
                            return self.make_node(
                                node, "error", "call",
                                poison_hir_type())
                        }
                    }
                }
                if builtin_class_name(receiver_syntax.value) {
                    if receiver_syntax.value ==
                           "StoredCallback" {
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                callee.value, expected)
                        if callee.value != "create" {
                            self.fail(
                                node,
                                "StoredCallback has no static '{callee.value}'")
                            return result
                        }
                        if self.program.target.os == "none" {
                            self.fail(
                                node,
                                "StoredCallback needs a hosted target")
                        }
                        if expected.name !=
                               "StoredCallback" ||
                           expected.args.len() != 1 ||
                           expected.args[0].name != "fn" {
                            self.fail(
                                node,
                                "declare the stored callback type, for example let callback: StoredCallback<fn(RawPtr<u8>, i32)> = StoredCallback.create(0, fn(value: i32) \{ \})")
                            for index: int in
                                1..node.children.len() {
                                result.children.push(
                                    self.check_expression(
                                        node.children[index],
                                        no_hir_type()))
                            }
                            result.type =
                                poison_hir_type()
                            return result
                        }
                        let count: int =
                            node.children.len() - 1
                        if count != 2 {
                            self.fail(
                                node,
                                "StoredCallback.create takes a userdata index and a function")
                            for index: int in
                                1..node.children.len() {
                                result.children.push(
                                    self.check_expression(
                                        node.children[index],
                                        no_hir_type()))
                            }
                            return result
                        }
                        let full: HirType =
                            expected.args[0]
                        var context_index: int = -1
                        let index_syntax: AstNode =
                            node.children[1]
                        if index_syntax.kind == "literal" &&
                           index_syntax.note == "int" {
                            match index_syntax.value.to_int() {
                                ok(value) => {
                                    context_index = value
                                }
                                err(error) => {}
                            }
                        }
                        if context_index < 0 ||
                           context_index >=
                               full.fn_parameter_count {
                            self.fail(
                                index_syntax,
                                "StoredCallback userdata index must be a literal parameter index")
                            context_index = 0
                        }
                        if context_index <
                               full.fn_parameter_count &&
                           (full.args[context_index].name !=
                                "RawPtr" ||
                            full.args[
                                context_index].args.len() !=
                                1) {
                            self.fail(
                                index_syntax,
                                "StoredCallback userdata parameter must be RawPtr")
                        }
                        var callback_parameters:
                            List<HirType> = []
                        for index: int in
                            0..full.fn_parameter_count {
                            if index != context_index {
                                let parameter: HirType =
                                    full.args[index]
                                callback_parameters.push(
                                    parameter)
                                if !self.is_stored_callback_scalar(
                                       parameter, false) {
                                    self.fail(
                                        node,
                                        "StoredCallback currently supports scalar and RawPtr callback values, got {render_hir_type(parameter)}")
                                }
                            }
                        }
                        let callback_result: HirType =
                            if full.fn_parameter_count <
                                   full.args.len() {
                                full.args[
                                    full.fn_parameter_count]
                            } else {
                                new HirType("unit")
                            }
                        if !self.is_stored_callback_scalar(
                               callback_result, true) {
                            self.fail(
                                node,
                                "StoredCallback currently supports scalar and RawPtr callback results, got {render_hir_type(callback_result)}")
                        }
                        let callback_type: HirType =
                            hir_function(
                                callback_parameters,
                                callback_result)
                        let checked_index: HirNode =
                            self.check_expression(
                                index_syntax,
                                new HirType("int"))
                        let saved_send: bool =
                            self.require_send_captures
                        let saved_sync: bool =
                            self.require_sync_captures
                        self.require_send_captures = true
                        self.require_sync_captures = true
                        let callback: HirNode =
                            self.check_expression(
                                node.children[2],
                                callback_type)
                        self.require_send_captures =
                            saved_send
                        self.require_sync_captures =
                            saved_sync
                        self.expect_type(
                            node.children[2],
                            callback.type,
                            callback_type)
                        result.resolved =
                            "StoredCallback.create:{context_index}"
                        result.children.push(
                            checked_index)
                        result.children.push(callback)
                        return result
                    }
                    if receiver_syntax.value == "RawPtr" &&
                       callee.value == "with_local" {
                        self.require_unsafe(
                            node, "RawPtr.with_local")
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                "with_local",
                                new HirType("unit"))
                        result.resolved =
                            "RawPtr.with_local"
                        let count: int =
                            node.children.len() - 1
                        if count != 2 {
                            self.fail(
                                node,
                                "RawPtr.with_local takes an inout local and a one-parameter function")
                            for index: int in
                                1..node.children.len() {
                                result.children.push(
                                    self.check_expression(
                                        node.children[index],
                                        no_hir_type()))
                            }
                            return result
                        }
                        let saved_inout: bool =
                            self.allow_inout_expression
                        self.allow_inout_expression = true
                        let local: HirNode =
                            self.check_expression(
                                node.children[1],
                                no_hir_type())
                        self.allow_inout_expression =
                            saved_inout
                        if !self.is_inline_c_storage(
                               local.type) &&
                           local.type.name != "poison" {
                            self.fail(
                                node.children[1],
                                "RawPtr.with_local needs a raw-memory-safe inline value, got {render_hir_type(local.type)}")
                        }
                        let callback_type: HirType =
                            hir_function(
                                [hir_named(
                                    "RawPtr",
                                    [local.type])],
                                new HirType("unit"))
                        let callback: HirNode =
                            self.check_expression(
                                node.children[2],
                                callback_type)
                        self.expect_type(
                            node.children[2],
                            callback.type,
                            callback_type)
                        result.children.push(local)
                        result.children.push(callback)
                        result.argument_passing.push(
                            "inout")
                        result.argument_passing.push("")
                        return result
                    }
                    if receiver_syntax.value == "RawPtr" &&
                       (callee.value == "null" ||
                        callee.value == "alloc" ||
                        callee.value == "alloc_aligned" ||
                        callee.value == "from_address") {
                        self.require_unsafe(
                            node,
                            "RawPtr.{callee.value}")
                        var type: HirType = expected
                        if type.name != "RawPtr" ||
                           type.args.len() != 1 {
                            self.fail(
                                node,
                                "can't tell RawPtr's element type from this call")
                            type = hir_named(
                                "RawPtr",
                                [poison_hir_type()])
                        }
                        if (callee.value == "alloc" ||
                            callee.value == "alloc_aligned") &&
                           type.args.len() == 1 &&
                           self.is_opaque_c_type(type.args[0]) {
                            self.fail(
                                node,
                                "cannot allocate opaque C type {render_hir_type(type.args[0])}")
                        }
                        var parameters: List<HirType> = []
                        if callee.value == "alloc" {
                            parameters.push(
                                new HirType("int"))
                        } else if callee.value ==
                                  "alloc_aligned" {
                            parameters.push(
                                new HirType("int"))
                            parameters.push(
                                new HirType("int"))
                        } else if callee.value ==
                                  "from_address" {
                            parameters.push(
                                new HirType("u64"))
                        }
                        let signature: BuiltinSignature =
                            new BuiltinSignature(
                                parameters, type)
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                callee.value, type)
                        result.resolved =
                            "RawPtr.{callee.value}"
                        self.check_builtin_arguments(
                            node, 1, signature, result)
                        return result
                    }
                    if receiver_syntax.value == "Slice" &&
                       callee.value == "from_raw" {
                        self.require_unsafe(
                            node,
                            "Slice.from_raw")
                        var type: HirType = expected
                        if type.name != "Slice" ||
                           type.args.len() != 1 {
                            self.fail(
                                node,
                                "can't tell Slice's element type from this call")
                            type = hir_named(
                                "Slice",
                                [poison_hir_type()])
                        }
                        let pointer: HirType =
                            hir_named(
                                "RawPtr", [type.args[0]])
                        let signature: BuiltinSignature =
                            new BuiltinSignature(
                                [pointer,
                                 new HirType("int")],
                                type)
                        let result: HirNode =
                            self.make_node(
                                node, "static_call",
                                "from_raw", type)
                        result.resolved =
                            "Slice.from_raw"
                        self.check_builtin_arguments(
                            node, 1, signature, result)
                        return result
                    }
                    match simd_description(
                        receiver_syntax.value) {
                        some(simd) => {
                            let width: int =
                                simd.lanes * simd.element_bits
                            if width > self.program.target.max_simd_bits() {
                                self.fail(
                                    receiver_syntax,
                                    "{receiver_syntax.value} is {width} bits, and {self.program.target.triple} with the selected features supports at most {self.program.target.max_simd_bits()}")
                            }
                            var parameters: List<HirType> = []
                            var known: bool = true
                            if callee.value == "splat" {
                                parameters.push(simd.element)
                            } else if callee.value == "of" {
                                for lane: int in 0..simd.lanes {
                                    parameters.push(simd.element)
                                }
                            } else if callee.value == "load" ||
                                      callee.value ==
                                          "load_unaligned" {
                                parameters.push(hir_named(
                                    "RawPtr", [simd.element]))
                            } else {
                                known = false
                            }
                            if known {
                                self.require_unsafe(
                                    node,
                                    "{receiver_syntax.value}.{callee.value}")
                                let type: HirType =
                                    new HirType(
                                        receiver_syntax.value)
                                let signature: BuiltinSignature =
                                    new BuiltinSignature(
                                        parameters, type)
                                let result: HirNode =
                                    self.make_node(
                                        node, "static_call",
                                        callee.value, type)
                                result.resolved =
                                    "{receiver_syntax.value}.{callee.value}"
                                self.check_builtin_arguments(
                                    node, 1,
                                    signature, result)
                                self.expect_type(
                                    node, type, expected)
                                return result
                            }
                        }
                        none => {}
                    }
                    match self.builtin_static(
                        receiver_syntax.value, callee.value) {
                        some(signature) => {
                            if receiver_syntax.value == "MMap" &&
                               self.program.target.os == "wasi" {
                                self.fail(
                                    node,
                                    "MMap is not available on target {self.program.target.triple}")
                            }
                            // File, Dir and MMap are OS handles reached
                            // without any import, so the import-time
                            // capability refusal never sees them. Refusing
                            // the static here keeps a minimal-profile
                            // program from surfacing the gap as a link
                            // error naming beans_shm_unlink. WASI is
                            // exempt: its filesystem rides at minimal by
                            // design, and its MMap refusal fired above.
                            if (receiver_syntax.value == "File" ||
                                receiver_syntax.value == "Dir" ||
                                receiver_syntax.value == "MMap") &&
                               self.program.target.os != "wasi" &&
                               self.signature.runtime_profile != "full" &&
                               !self.signature.refused_capabilities.contains("the filesystem") {
                                self.signature.refused_capabilities["the filesystem"] = true
                                self.fail(
                                    node,
                                    "'{receiver_syntax.value}' needs the filesystem, which the {self.signature.runtime_profile} runtime does not have — it needs at least the full runtime")
                            }
                            let result: HirNode =
                                self.make_node(
                                    node, "static_call",
                                    callee.value, signature.result)
                            result.resolved =
                                "{receiver_syntax.value}.{callee.value}"
                            if receiver_syntax.value == "Atomic" &&
                               callee.value == "fence" {
                                self.check_atomic_arguments(
                                    node, 1, signature,
                                    "fence", result)
                            } else {
                                self.check_builtin_arguments(
                                    node, 1, signature, result)
                            }
                            self.expect_type(
                                node, result.type, expected)
                            return result
                        }
                        none => {}
                    }
                }
            }
            let receiver: HirNode = self.check_expression(
                callee.children[0], no_hir_type())
            if receiver.type.name == "decimal" &&
               callee.value == "round" {
                let count: int =
                    node.children.len() - 1
                if count != 1 && count != 2 {
                    self.fail(
                        node,
                        "decimal.round takes places and an optional RoundingMode")
                }
                let result: HirNode =
                    self.make_node(
                        node, "builtin_method",
                        "round", receiver.type)
                result.resolved = "decimal.round"
                result.children.push(receiver)
                if count >= 1 {
                    result.children.push(
                        self.check_expression(
                            node.children[1],
                            new HirType("int")))
                }
                if count >= 2 {
                    result.children.push(
                        self.check_expression(
                            node.children[2],
                            new HirType("RoundingMode")))
                }
                for index: int in 3..node.children.len() {
                    result.children.push(
                        self.check_expression(
                            node.children[index],
                            no_hir_type()))
                }
                self.expect_type(
                    node, result.type, expected)
                return result
            }
            match self.check_higher_order_method(
                node, callee, receiver, expected) {
                some(result) => { return result }
                none => {}
            }
            match self.builtin_method(receiver.type, callee.value) {
                some(signature) => {
                    self.validate_target_type(
                        node, signature.result)
                    if receiver.type.name == "MMap" &&
                       self.program.target.os == "wasi" {
                        self.fail(
                            node,
                            "MMap is not available on target {self.program.target.triple}")
                    }
                    // Same per-profile gate as the static path: a File or
                    // MMap value can also arrive through a parameter, with
                    // no import for the capability refusal to catch.
                    if (receiver.type.name == "File" ||
                        receiver.type.name == "MMap") &&
                       self.program.target.os != "wasi" &&
                       self.signature.runtime_profile != "full" &&
                       !self.signature.refused_capabilities.contains("the filesystem") {
                        self.signature.refused_capabilities["the filesystem"] = true
                        self.fail(
                            node,
                            "'{receiver.type.name}' needs the filesystem, which the {self.signature.runtime_profile} runtime does not have — it needs at least the full runtime")
                    }
                    if receiver.type.name ==
                           "StoredCallback" &&
                       callee.value == "close" {
                        if callee.children[0].kind != "name" {
                            self.fail(
                                callee.children[0],
                                "StoredCallback.close needs a named local")
                        } else {
                            match self.find_local(
                                      callee.children[0].value) {
                                some(binding) => {
                                    if binding.borrowed {
                                        self.fail(
                                            callee.children[0],
                                            "cannot close borrowed StoredCallback '{callee.children[0].value}'")
                                    } else {
                                        binding.move_state =
                                            "moved"
                                    }
                                }
                                none => {}
                            }
                        }
                    }
                    if receiver.type.name == "RawPtr" ||
                       receiver.type.name == "Slice" ||
                       simd_description(
                           receiver.type.name).is_some() {
                        self.require_unsafe(
                            node,
                            "{receiver.type.name}.{callee.value}")
                    }
                    if receiver.type.name == "RawPtr" &&
                       receiver.type.args.len() == 1 &&
                       callee.value.starts_with("atomic_") {
                        let bits: int =
                            atomic_element_bits(
                                receiver.type.args[0])
                        if bits > 0 &&
                           !self.program.target.supports_atomic(
                               bits) {
                            self.fail(
                                node,
                                "RawPtr<{render_hir_type(receiver.type.args[0])}>.{callee.value} needs {bits}-bit atomics, which {self.program.target.triple} does not support")
                        }
                    }
                    if receiver.type.name == "RawPtr" &&
                       receiver.type.args.len() == 1 &&
                       self.is_opaque_c_type(
                           receiver.type.args[0]) &&
                       callee.value != "is_null" &&
                       callee.value != "address" &&
                       callee.value != "free" {
                        self.fail(
                            node,
                            "opaque C type {render_hir_type(receiver.type.args[0])} cannot be read, written, or sized")
                    }
                    let result: HirNode =
                        self.make_node(
                            node, "builtin_method",
                            callee.value, signature.result)
                    result.resolved =
                        "{hir_type_key(receiver.type)}.{callee.value}"
                    result.children.push(receiver)
                    if receiver.type.name == "Atomic" {
                        self.check_atomic_arguments(
                            node, 1, signature,
                            callee.value, result)
                    } else {
                        self.check_builtin_arguments(
                            node, 1, signature, result)
                    }
                    if node.children.len() >= 2 {
                        if receiver.type.name == "List" &&
                           callee.value == "push" {
                            self.require_move_source(
                                node.children[1],
                                result.children[
                                    result.children.len() - 1].type,
                                "List.push")
                        } else if receiver.type.name == "List" &&
                                  callee.value == "insert" &&
                                  node.children.len() >= 3 {
                            self.require_move_source(
                                node.children[2],
                                result.children[
                                    result.children.len() - 1].type,
                                "List.insert")
                        } else if (receiver.type.name == "Box" &&
                                   callee.value == "set") ||
                                  (receiver.type.name == "Arena" &&
                                   callee.value == "put") {
                            self.require_move_source(
                                node.children[1],
                                result.children[
                                    result.children.len() - 1].type,
                                "{receiver.type.name}.{callee.value}")
                        } else if (receiver.type.name == "Map" ||
                                   receiver.type.name == "OrderedMap") &&
                                  (callee.value == "set" ||
                                   callee.value == "insert") {
                            for argument_index: int in
                                1..node.children.len() {
                                self.require_move_source(
                                    node.children[argument_index],
                                    result.children[
                                        argument_index].type,
                                    "{receiver.type.name}.{callee.value}")
                            }
                        }
                    }
                    self.expect_type(node, result.type, expected)
                    return result
                }
                none => {}
            }
            match self.method_for(receiver.type, callee.value) {
                some(function) => {
                    self.require_visible(
                        node, function.is_public,
                        function.file, "method",
                        "{render_hir_type(receiver.type)}.{callee.value}")
                    var owner: Option<HirDeclaration> =
                        self.declaration_for(receiver.type)
                    if function.owner != "" {
                        match owner {
                            some(declaration) => {}
                            none => {
                                owner = self.declarations.get(
                                    function.owner)
                            }
                        }
                    }
                    match owner {
                        some(declaration) => {
                            let result_type: HirType =
                                self.substitute_owner_type(
                                    function.result,
                                    declaration, receiver.type)
                            let result: HirNode =
                                self.make_node(
                                    node, "method_call",
                                    function.name, result_type)
                            self.validate_async_call(
                                node, function)
                            result.resolved = function.qualified
                            result.dispatch_slot =
                                hir_method_slot(
                                    function.owner,
                                    function.name,
                                    function.is_public)
                            result.children.push(receiver)
                            self.check_arguments(
                                node, 1, function,
                                receiver.type,
                                "{declaration.name}.{function.name}",
                                result)
                            self.expect_type(
                                node, result.type, expected)
                            return result
                        }
                        none => {}
                    }
                }
                none => {}
            }
            // A poison receiver already reported its own error; a second
            // "poison has no method" line would only bury it.
            if receiver.type.name == "poison" {
                return self.make_node(
                    node, "error", "call", poison_hir_type())
            }
            self.fail(
                callee,
                "{render_hir_type(receiver.type)} has no method '{callee.value}'")
            return self.make_node(
                node, "error", "call", poison_hir_type())
        }
        if callee.kind != "name" {
            let callable: HirNode =
                self.check_expression(
                    callee, no_hir_type())
            if callable.type.name == "fn" &&
               callable.type.fn_parameter_count >= 0 &&
               callable.type.fn_parameter_count <=
                   callable.type.args.len() {
                // no result entry in the args means the fn returns unit
                let result_type: HirType =
                    if callable.type.fn_parameter_count <
                       callable.type.args.len() {
                        callable.type.args[
                            callable.type.fn_parameter_count]
                    } else {
                        new HirType("unit")
                    }
                var parameters: List<HirType> = []
                for index: int in
                    0..callable.type.fn_parameter_count {
                    parameters.push(
                        callable.type.args[index])
                }
                let result: HirNode =
                    self.make_node(
                        node, "closure_call", "", result_type)
                result.children.push(callable)
                self.check_builtin_arguments(
                    node, 1,
                    new BuiltinSignature(
                        parameters, result_type),
                    result)
                self.expect_type(
                    node, result.type, expected)
                return result
            }
            self.fail(
                node,
                "{render_hir_type(callable.type)} is not callable")
            return self.make_node(
                node, "error", "call",
                poison_hir_type())
        }
        match self.check_special_call(
            node, callee, expected) {
            some(result) => { return result }
            none => {}
        }
        match self.find_local(callee.value) {
            some(binding) => {
                if binding.type.name == "fn" &&
                   binding.type.fn_parameter_count >= 0 &&
                   binding.type.fn_parameter_count <=
                       binding.type.args.len() {
                    // no result entry in the args means the fn returns unit
                    let result_type: HirType =
                        if binding.type.fn_parameter_count <
                           binding.type.args.len() {
                            binding.type.args[
                                binding.type.fn_parameter_count]
                        } else {
                            new HirType("unit")
                        }
                    var parameters: List<HirType> = []
                    for index: int in
                        0..binding.type.fn_parameter_count {
                        parameters.push(
                            binding.type.args[index])
                    }
                    let signature: BuiltinSignature =
                        new BuiltinSignature(
                            parameters, result_type)
                    let result: HirNode =
                        self.make_node(
                            node, "closure_call",
                            callee.value, result_type)
                    result.children.push(
                        self.check_name(
                            callee, binding.type))
                    self.check_builtin_arguments(
                        node, 1, signature, result)
                    self.expect_type(
                        node, result.type, expected)
                    return result
                }
                self.fail(
                    callee,
                    "{render_hir_type(binding.type)} is not callable")
                return self.make_node(
                    node, "error", "call",
                    poison_hir_type())
            }
            none => {}
        }
        if callee.value == "panic" {
            let type: HirType = new HirType("unit")
            let result: HirNode =
                self.make_node(
                    node, "builtin_call", "panic", type)
            result.resolved = "panic"
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "panic takes 1 argument, got {count}")
            }
            for index: int in 1..node.children.len() {
                result.children.push(
                    self.check_expression(
                        node.children[index],
                        if index == 1 {
                            new HirType("string")
                        } else {
                            no_hir_type()
                        }))
            }
            self.expect_type(node, type, expected)
            return result
        }
        match self.current_function(callee.value) {
            some(function) => {
                self.require_function_feature(
                    node, function, "the call")
                if function.is_extern_c &&
                   !function.is_c_export {
                    self.require_unsafe(
                        node,
                        "extern C call '{function.name}'")
                }
                let result: HirNode =
                    self.make_node(
                        node, "call", function.name,
                        function.result)
                self.validate_async_call(node, function)
                result.resolved = function.qualified
                if function.generics.len() != 0 {
                    self.check_generic_arguments(
                        node, 1, function,
                        expected,
                        "'{function.name}'", result)
                } else {
                    self.check_arguments(
                        node, 1, function,
                        no_hir_type(),
                        "'{function.name}'", result)
                }
                self.expect_type(node, result.type, expected)
                return result
            }
            none => {
                match self.current_declaration(callee.value) {
                    some(declaration) => {
                        if declaration.kind == "class" {
                            self.fail(
                                node,
                                "classes are built with 'new {declaration.name}(...)'")
                            return self.make_node(
                                node, "error", "call",
                                poison_hir_type())
                        }
                    }
                    none => {}
                }
                self.fail(
                    callee, "unknown function '{callee.value}'")
                return self.make_node(
                    node, "error", "call", poison_hir_type())
            }
        }
    }

    fn check_new(node: AstNode,
                 expected: HirType) -> HirNode {
        var type: HirType = hir_type_from_ast(node.children[0])
        self.validate_target_type(
            node.children[0], type)
        if type.args.len() == 0 &&
           expected.name == type.name &&
           expected.args.len() == 1 {
            type = expected
        }
        if type.name == "Bytes" {
            let signature: BuiltinSignature =
                new BuiltinSignature(
                    [new HirType("int")], type)
            let result: HirNode =
                self.make_node(node, "new", "Bytes", type)
            result.resolved = "Bytes.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "AtomicInt" {
            let signature: BuiltinSignature =
                new BuiltinSignature(
                    [new HirType("int")], type)
            let result: HirNode =
                self.make_node(node, "new", "AtomicInt", type)
            result.resolved = "AtomicInt.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "Arena" ||
           type.name == "Channel" {
            if type.args.len() != 1 {
                self.fail(
                    node,
                    "new {type.name} needs one type argument or a declared result type")
                type.args.push(poison_hir_type())
            }
            let signature: BuiltinSignature =
                new BuiltinSignature(
                    [new HirType("int")], type)
            let result: HirNode =
                self.make_node(node, "new", type.name, type)
            result.resolved = "{type.name}.init"
            self.check_builtin_arguments(
                node, 1, signature, result)
            self.expect_type(node, type, expected)
            return result
        }
        if type.name == "Box" ||
           type.name == "Shared" ||
           type.name == "Mutex" ||
           type.name == "Atomic" {
            let result: HirNode =
                self.make_node(node, "new", type.name, type)
            result.resolved = "{type.name}.init"
            if type.args.len() > 1 {
                self.fail(
                    node,
                    "{type.name} takes one type argument")
                type.args = [type.args[0]]
                result.type = type
            }
            let count: int = node.children.len() - 1
            if count != 1 {
                self.fail(
                    node,
                    "new {type.name} takes 1 argument(s), got {count}")
            }
            if type.args.len() == 1 && count == 1 {
                let signature: BuiltinSignature =
                    new BuiltinSignature([type.args[0]], type)
                self.check_builtin_arguments(
                    node, 1, signature, result)
            } else {
                if count == 1 {
                    let value: HirNode =
                        self.check_expression(
                            node.children[1], no_hir_type())
                    type.args.push(value.type)
                    result.type = type
                    result.children.push(value)
                } else {
                    type.args.push(poison_hir_type())
                    result.type = type
                }
            }
            if type.name != "Atomic" &&
               count == 1 &&
               result.children.len() != 0 {
                self.require_move_source(
                    node.children[1],
                    result.children[
                        result.children.len() - 1].type,
                    "new {type.name}")
            }
            self.expect_type(node, type, expected)
            return result
        }
        match self.declaration_for(type) {
            some(declaration) => {
                if declaration.kind != "class" {
                    self.fail(
                        node,
                        "new needs a class, got {render_hir_type(type)}")
                }
                // a segment-parsed type may still spell an import
                // alias; the constructed value's type uses the
                // declaration's canonical name, like resolved code
                if declaration.generics.len() == 0 {
                    type.name = declaration.qualified
                }
                let result: HirNode =
                    self.make_node(node, "new", declaration.name, type)
                result.resolved = declaration.qualified
                match self.initializer_for(declaration) {
                    some(initializer) => {
                        self.check_initializer_visibility(
                            node, declaration, initializer)
                        let initializer_owner: HirType =
                            if initializer.owner ==
                               declaration.qualified {
                                type
                            } else {
                                new HirType(
                                    initializer.owner)
                            }
                        self.check_arguments(
                            node, 1, initializer,
                            initializer_owner,
                            "'{node.children[0].value}' init",
                            result)
                        result.resolved =
                            initializer.qualified
                    }
                    none => {
                        let count: int = node.children.len() - 1
                        if count != 0 {
                            self.fail(
                                node,
                                "{declaration.name} has no initializer")
                        }
                    }
                }
                self.expect_type(node, type, expected)
                return result
            }
            none => {
                self.fail(
                    node,
                    "unknown class '{render_hir_type(type)}'")
                return self.make_node(
                    node, "error", "new", poison_hir_type())
            }
        }
    }

    fn check_initializer(node: AstNode,
                         expected: HirType) -> HirNode {
        let written: AstNode = node.children[0]
        var declared: Option<HirDeclaration> =
            self.static_declaration(written)
        var type: HirType = expected
        if type.name == "" {
            match declared {
                some(declaration) => {
                    type = new HirType(declaration.qualified)
                }
                none => {
                    self.fail(
                        node,
                        "initializer needs a struct or enum name")
                    return self.make_node(
                        node, "error", "initializer",
                        poison_hir_type())
                }
            }
        }
        if declared.is_none() {
            declared = self.declaration_for(type)
        }
        match declared {
            some(declaration) => {
                if declaration.kind != "struct" &&
                   declaration.kind != "union" {
                    if declaration.kind == "class" {
                        self.fail(
                            node,
                            "classes are built with 'new {declaration.name}(...)'; field literals are only for structs")
                    } else {
                        self.fail(
                            node,
                            "field initializer needs a struct or union, got {declaration.kind} {declaration.name}")
                    }
                }
                let result: HirNode =
                    self.make_node(
                        node, "initializer",
                        declaration.name, type)
                result.resolved = declaration.qualified
                if declaration.kind != "union" {
                    for field: HirField in declaration.fields {
                        match field.default_value {
                            some(value) => {
                                let initialized: HirNode =
                                    self.make_node(
                                        node, "field_init",
                                        field.name, field.type)
                                initialized.children.push(value)
                                result.children.push(initialized)
                            }
                            none => {}
                        }
                    }
                }
                var seen: Map<string, bool> = {}
                for index: int in 1..node.children.len() {
                    let entry: AstNode = node.children[index]
                    if seen.contains(entry.value) {
                        self.fail(
                            entry,
                            "field '{entry.value}' is initialized twice")
                    }
                    seen[entry.value] = true
                    match self.field_for(type, entry.value) {
                        some(field) => {
                            self.require_visible(
                                entry, field.field.is_public,
                                field.field.file, "field",
                                "{declaration.qualified}.{entry.value}")
                            let value: HirNode =
                                self.check_expression(
                                    entry.children[0], field.type)
                            self.require_move_source(
                                entry.children[0], value.type,
                                "field '{entry.value}'")
                            let field: HirNode =
                                self.make_node(
                                    entry, "field_init",
                                    entry.value, field.type)
                            field.children.push(value)
                            result.children.push(field)
                        }
                        none => {
                            self.fail(
                                entry,
                                "{declaration.name} has no field '{entry.value}'")
                        }
                    }
                }
                if declaration.kind == "union" {
                    self.require_unsafe(
                        node,
                        "union initialization")
                    if seen.len() != 1 {
                        self.fail(
                            node,
                            "union initializer sets exactly one field, got {seen.len()}")
                    }
                } else {
                    for field: HirField in declaration.fields {
                        if seen.contains(field.name) {
                            continue
                        }
                        if !field.has_default {
                            self.fail(
                                node,
                                "initializer for {declaration.name} is missing field '{field.name}'")
                        }
                    }
                }
                self.expect_type(node, type, expected)
                return result
            }
            none => {
                self.fail(
                    node,
                    "unknown struct '{self.static_syntax_name(written)}'")
                return self.make_node(
                    node, "error", "initializer", poison_hir_type())
            }
        }
    }

    fn check_list(node: AstNode,
                  expected: HirType) -> HirNode {
        var element: HirType = no_hir_type()
        if expected.name == "List" &&
           expected.args.len() == 1 {
            element = expected.args[0]
        } else if expected.name == "array" &&
                  expected.args.len() == 1 {
            element = expected.args[0]
        }
        let result: HirNode =
            self.make_node(node, "list", "", expected)
        for child: AstNode in node.children {
            let value: HirNode =
                self.check_expression(child, element)
            self.require_move_source(
                child, value.type, "list element")
            result.children.push(value)
            if element.name == "" { element = value.type }
        }
        if element.name == "" {
            self.fail(
                node,
                "can't tell the element type of an empty list")
            result.type = poison_hir_type()
            return result
        }
        if expected.name == "array" {
            if expected.array_length != node.children.len() {
                self.fail(
                    node,
                    "fixed array literal needs {expected.array_length} element(s), got {node.children.len()}")
            }
            result.type = expected
        } else {
            result.type = hir_list(element)
            self.expect_type(node, result.type, expected)
        }
        return result
    }

    fn check_map(node: AstNode,
                 expected: HirType) -> HirNode {
        var key: HirType = no_hir_type()
        var value_type: HirType = no_hir_type()
        if (expected.name == "Map" ||
            expected.name == "OrderedMap") &&
           expected.args.len() == 2 {
            key = expected.args[0]
            value_type = expected.args[1]
        }
        let result: HirNode =
            self.make_node(node, "map", "", expected)
        for child: AstNode in node.children {
            let checked_key: HirNode =
                self.check_expression(child.children[0], key)
            let checked_value: HirNode =
                self.check_expression(
                    child.children[1], value_type)
            self.require_move_source(
                child.children[0],
                checked_key.type, "map key")
            self.require_move_source(
                child.children[1],
                checked_value.type, "map value")
            result.children.push(checked_key)
            result.children.push(checked_value)
            if key.name == "" { key = checked_key.type }
            if value_type.name == "" {
                value_type = checked_value.type
            }
        }
        if key.name == "" || value_type.name == "" {
            self.fail(
                node,
                "can't tell the key and value types of an empty map")
            result.type = poison_hir_type()
            return result
        }
        result.type =
            if expected.name == "OrderedMap" {
                hir_named("OrderedMap", [key, value_type])
            } else {
                hir_named("Map", [key, value_type])
            }
        self.expect_type(node, result.type, expected)
        return result
    }

    fn check_index(node: AstNode,
                   expected: HirType) -> HirNode {
        let receiver: HirNode =
            self.check_expression(node.children[0], no_hir_type())
        var index_type: HirType = new HirType("int")
        var result_type: HirType = poison_hir_type()
        if (receiver.type.name == "List" ||
            receiver.type.name == "Slice") &&
           receiver.type.args.len() == 1 {
            result_type = receiver.type.args[0]
            if receiver.type.name == "Slice" {
                self.require_unsafe(
                    node,
                    "Slice indexing")
            }
        } else if receiver.type.name == "array" &&
                  receiver.type.args.len() == 1 {
            result_type = receiver.type.args[0]
        } else if (receiver.type.name == "Map" ||
                   receiver.type.name == "OrderedMap") &&
                  receiver.type.args.len() == 2 {
            index_type = receiver.type.args[0]
            result_type = receiver.type.args[1]
        } else if receiver.type.name == "Bytes" {
            result_type = new HirType("int")
        } else {
            self.fail(
                node,
                "{render_hir_type(receiver.type)} cannot be indexed")
        }
        let index: HirNode =
            self.check_expression(node.children[1], index_type)
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(node, "index", "", result_type)
        result.children.push(receiver)
        result.children.push(index)
        return result
    }

    fn check_try(node: AstNode,
                 expected: HirType) -> HirNode {
        if self.defer_depth > 0 {
            self.fail(
                node,
                "? is not allowed inside defer because function exit is already in progress")
        }
        let operand: HirNode =
            self.check_expression(
                node.children[0], no_hir_type())
        var result_type: HirType = poison_hir_type()
        if operand.type.name == "Result" &&
           operand.type.args.len() >= 1 {
            result_type = operand.type.args[0]
            if self.current.body_result.name != "Result" {
                self.fail(
                    node,
                    "'?' needs a function returning Result")
            }
        } else if operand.type.name == "Option" &&
                  operand.type.args.len() == 1 {
            result_type = operand.type.args[0]
            if self.current.body_result.name != "Option" {
                self.fail(
                    node,
                    "'?' needs a function returning Option")
            }
        } else {
            self.fail(
                node,
                "'?' needs Result or Option, got {render_hir_type(operand.type)}")
        }
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(node, "try", "", result_type)
        result.children.push(operand)
        return result
    }

    fn check_await(node: AstNode,
                   expected: HirType) -> HirNode {
        if !self.current.is_async {
            self.fail(
                node,
                "await is only valid inside an async function")
        } else if self.capture_floor_depth >= 0 {
            self.fail(
                node,
                "await cannot be used inside a closure — only directly in the async function body")
        } else if self.defer_depth > 0 {
            self.fail(
                node,
                "await is not allowed inside defer")
        } else if self.move_only_borrow_depth > 0 {
            self.fail(
                node,
                "await cannot suspend while a loop or match borrows a move-only value — copy or move what you need first")
        }
        // Awaiting an async let binding produces its declared result,
        // exactly once; the state flip is what rejects a second await.
        if node.children[0].kind == "name" {
            match self.find_local(node.children[0].value) {
                some(binding) => {
                    if binding.move_state == "async_pending" ||
                       binding.move_state == "async_done" {
                        if binding.move_state == "async_done" {
                            self.fail(
                                node,
                                "async let binding '{node.children[0].value}' was already awaited")
                        }
                        binding.move_state = "async_done"
                        let operand: HirNode = self.make_node(
                            node.children[0], "local",
                            node.children[0].value, binding.type)
                        operand.binding_id = binding.id
                        self.expect_type(
                            node, binding.type, expected)
                        let result: HirNode = self.make_node(
                            node, "await", "child", binding.type)
                        result.children.push(operand)
                        return result
                    }
                }
                none => {}
            }
        }
        // The operand must be a direct call to an async function; the
        // call's own checking consumes the allowance, so if it is still
        // set afterwards nothing async was called.
        if node.children[0].kind != "call" {
            self.fail(
                node,
                "await needs a direct call to an async function")
            let ignored: HirNode =
                self.check_expression(
                    node.children[0], no_hir_type())
            let poisoned: HirNode = self.make_node(
                node, "error", "await", poison_hir_type())
            poisoned.children.push(ignored)
            return poisoned
        }
        node.children[0].await_allowed = true
        let operand: HirNode =
            self.check_expression(
                node.children[0], no_hir_type())
        if node.children[0].await_allowed {
            node.children[0].await_allowed = false
            if operand.type.name != "poison" {
                self.fail(
                    node,
                    "await needs a call to an async function — this call is synchronous")
            }
            let poisoned: HirNode = self.make_node(
                node, "error", "await", poison_hir_type())
            poisoned.children.push(operand)
            return poisoned
        }
        if operand.type.name == "poison" {
            return self.make_node(
                node, "error", "await", poison_hir_type())
        }
        let result_type: HirType = operand.type
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(node, "await", "", result_type)
        result.children.push(operand)
        return result
    }

    fn check_cast(node: AstNode,
                  expected: HirType) -> HirNode {
        let value: HirNode =
            self.check_expression(
                node.children[0], no_hir_type())
        let target: HirType =
            hir_type_from_ast(node.children[1])
        var result_type: HirType = target
        if node.value == "as?" {
            result_type = hir_option(target)
            if !self.is_plain_class(value.type) ||
               !self.is_plain_class(target) ||
               hir_types_equal(value.type, target) ||
               !self.is_subtype(target, value.type) {
                self.fail(
                    node,
                    "as? goes from a parent to a child class — {render_hir_type(value.type)} as? {render_hir_type(target)} doesn't")
            }
        } else if !(hir_is_numeric(value.type) &&
                    hir_is_numeric(target)) &&
                  !self.is_subtype(value.type, target) {
            self.fail(
                node,
                "can't cast {render_hir_type(value.type)} as {render_hir_type(target)}")
        }
        self.expect_type(node, result_type, expected)
        let result: HirNode =
            self.make_node(
                node, "cast", node.value, result_type)
        result.children.push(value)
        return result
    }

    fn check_closure(node: AstNode,
                     expected: HirType) -> HirNode {
        var parameters: List<HirType> = []
        var parameter_nodes: List<AstNode> = []
        var result_type: HirType = new HirType("unit")
        var body_syntax: Option<AstNode> = none
        for child: AstNode in node.children {
            if child.kind == "params" {
                for parameter: AstNode in child.children {
                    for part: AstNode in parameter.children {
                        if part.kind == "passing" {
                            self.fail(
                                part,
                                "{part.value} parameters are not supported on closure values yet")
                        }
                    }
                    match type_child(parameter) {
                        some(type_node) => {
                            parameters.push(
                                hir_type_from_ast(type_node))
                            parameter_nodes.push(parameter)
                        }
                        none => {
                            self.fail(
                                parameter,
                                "closure parameter needs a type")
                            parameters.push(poison_hir_type())
                            parameter_nodes.push(parameter)
                        }
                    }
                }
            } else if child.kind == "result" {
                match type_child(child) {
                    some(type_node) => {
                        result_type =
                            hir_type_from_ast(type_node)
                    }
                    none => {
                        self.fail(
                            child,
                            "closure result needs a type")
                        result_type = poison_hir_type()
                    }
                }
            } else if child.kind == "block" {
                body_syntax = some(child)
            }
        }

        let type: HirType =
            hir_function(parameters, result_type)
        self.expect_type(node, type, expected)
        let result: HirNode =
            self.make_node(node, "closure", "", type)
        let saved_result: HirType = self.current.result
        let saved_body_result: HirType =
            self.current.body_result
        let saved_capture_floor: int =
            self.capture_floor_depth
        let saved_take_floor: int =
            self.take_floor_depth
        let capture_floor: int = self.scopes.len()
        self.capture_floor_depth = capture_floor
        if self.take_floor_depth < capture_floor {
            self.take_floor_depth = capture_floor
        }
        self.current.result = result_type
        self.current.body_result = result_type
        self.push_scope()
        for index: int in 0..parameter_nodes.len() {
            let binding_id: int = self.declare(
                parameter_nodes[index],
                parameters[index], false, true, false)
            let lowered: HirNode = self.make_node(
                parameter_nodes[index], "closure_parameter",
                parameter_nodes[index].value,
                parameters[index])
            lowered.binding_id = binding_id
            result.children.push(lowered)
        }
        match body_syntax {
            some(block) => {
                let body: HirNode =
                    self.make_node(
                        block, "block", "",
                        new HirType("unit"))
                for statement: AstNode in block.children {
                    body.children.push(
                        self.check_statement(statement))
                }
                result.children.push(body)
                if result_type.name != "unit" &&
                   result_type.name != "poison" &&
                   !self.block_always_returns(block) {
                    self.fail(
                        node,
                        "this closure must return {render_hir_type(result_type)} — the body can finish without a return")
                }
            }
            none => {
                self.fail(node, "closure needs a body")
            }
        }
        self.pop_scope()
        self.current.result = saved_result
        self.current.body_result = saved_body_result
        self.capture_floor_depth = saved_capture_floor
        self.take_floor_depth = saved_take_floor
        return result
    }

    fn check_expression_block(block: AstNode,
                              expected: HirType) -> HirNode {
        let result: HirNode =
            self.make_node(
                block, "block", "", new HirType("unit"))
        self.push_scope()
        // in a discarded block (a statement match's arm) a trailing
        // expression is an ordinary statement: only a trailing match
        // keeps the discard demand, so its own arms stay statements too
        let discard_block: bool = expected.name == "discard"
        for index: int in 0..block.children.len() {
            let statement: AstNode = block.children[index]
            if index + 1 == block.children.len() &&
               statement.kind == "expression" {
                let value: HirNode =
                    self.check_expression(
                        statement.children[0],
                        if discard_block &&
                           statement.children[0].kind != "match" {
                            no_hir_type()
                        } else {
                            expected
                        })
                let wrapped: HirNode =
                    self.make_node(
                        statement, "expression", "",
                        new HirType("unit"))
                wrapped.children.push(value)
                result.children.push(wrapped)
                result.type =
                    if discard_block {
                        new HirType("unit")
                    } else {
                        value.type
                    }
            } else if index + 1 == block.children.len() &&
                      statement.kind == "if" &&
                      expected.name != "" &&
                      expected.name != "unit" &&
                      expected.name != "discard" &&
                      self.if_chain_has_else(statement) {
                // a value is demanded, so a trailing if whose chain
                // ends in an else is the value, the same as a
                // trailing match
                let value: HirNode =
                    self.check_if_expression(statement, expected)
                let wrapped: HirNode =
                    self.make_node(
                        statement, "expression", "",
                        new HirType("unit"))
                wrapped.children.push(value)
                result.children.push(wrapped)
                result.type = value.type
            } else {
                result.children.push(
                    self.check_statement(statement))
            }
        }
        self.pop_scope()
        return result
    }

    fn if_chain_has_else(node: AstNode) -> bool {
        if node.children.len() < 3 { return false }
        if node.children[2].kind == "block" { return true }
        return self.if_chain_has_else(node.children[2])
    }

    fn check_if_expression(node: AstNode,
                           expected: HirType) -> HirNode {
        let result: HirNode =
            self.make_node(
                node, "if_expression", "", expected)
        if node.children.len() < 3 {
            self.fail(
                node, "if in value position needs an else branch")
            return result
        }
        result.children.push(self.check_expression(
            node.children[0], new HirType("bool")))
        let guard_mark: int =
            self.feature_guards.len()
        self.collect_feature_guards(node.children[0])
        let base: List<LocalScope> =
            self.copy_scopes(self.scopes)
        let then_branch: HirNode =
            self.check_expression_block(
                node.children[1], expected)
        let yes: List<LocalScope> =
            self.copy_scopes(self.scopes)
        result.children.push(then_branch)
        for self.feature_guards.len() > guard_mark {
            self.feature_guards.pop()
        }
        let branch_expected: HirType =
            if expected.name == "" {
                then_branch.type
            } else {
                expected
            }
        self.scopes = self.copy_scopes(base)
        let else_branch: HirNode =
            if node.children[2].kind == "block" {
                self.check_expression_block(
                    node.children[2], branch_expected)
            } else {
                self.check_if_expression(
                    node.children[2], branch_expected)
            }
        let no: List<LocalScope> =
            self.copy_scopes(self.scopes)
        self.scopes = self.copy_scopes(base)
        self.merge_move_states(yes, no)
        result.children.push(else_branch)
        if !hir_types_equal(
            then_branch.type, else_branch.type) {
            self.fail(
                node,
                "if branches have different types: {render_hir_type(then_branch.type)} and {render_hir_type(else_branch.type)}")
        }
        result.type =
            if expected.name == "" {
                then_branch.type
            } else {
                expected
            }
        return result
    }

    fn pattern_payload(subject: HirType,
                       pattern: AstNode) -> List<HirType> {
        if subject.name == "Option" &&
           subject.args.len() == 1 {
            if pattern.value == "some" {
                return [subject.args[0]]
            }
            if pattern.value == "none" { return [] }
        }
        if subject.name == "Result" &&
           subject.args.len() >= 1 {
            if pattern.value == "ok" {
                return [subject.args[0]]
            }
            if pattern.value == "err" {
                return [
                    if subject.args.len() >= 2 {
                        subject.args[1]
                    } else {
                        new HirType("Error")
                    }
                ]
            }
        }
        match self.declarations.get(subject.name) {
            some(declaration) => {
                if declaration.kind == "enum" {
                    match self.variant_for(
                        declaration, pattern.value) {
                        some(variant) => {
                            var payload: List<HirType> = []
                            for item: HirType in variant.type.args {
                                payload.push(
                                    self.substitute_owner_type(
                                        item, declaration, subject))
                            }
                            return move payload
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        return []
    }

    fn check_pattern(pattern: AstNode,
                     subject: HirType) -> HirNode {
        let result: HirNode =
            self.make_node(
                pattern, pattern.kind, pattern.value, subject)
        if pattern.kind == "pattern_alternative" {
            for child: AstNode in pattern.children {
                result.children.push(
                    self.check_pattern(child, subject))
            }
            return result
        }
        if pattern.kind == "pattern_literal" {
            var literal_type: HirType =
                new HirType("int")
            var is_float_literal: bool = false
            if pattern.value == "true" ||
               pattern.value == "false" {
                literal_type = new HirType("bool")
            } else if pattern.value.starts_with("\"") {
                literal_type = new HirType("string")
            } else if pattern.value.contains(".") ||
                      (!pattern.value.starts_with("0x") &&
                       !pattern.value.starts_with("0X") &&
                       !pattern.value.starts_with("0b") &&
                       !pattern.value.starts_with("0B") &&
                       !pattern.value.starts_with("-0x") &&
                       !pattern.value.starts_with("-0X") &&
                       !pattern.value.starts_with("-0b") &&
                       !pattern.value.starts_with("-0B") &&
                       (pattern.value.contains("e") ||
                        pattern.value.contains("E"))) {
                literal_type = new HirType("float")
                is_float_literal = true
            }
            if is_float_literal &&
               (hir_is_float(subject) ||
                subject.name == "decimal") {
                literal_type = subject
            } else if !is_float_literal &&
                      hir_is_numeric(subject) {
                literal_type = subject
            }
            if !hir_types_equal(literal_type, subject) {
                self.fail(
                    pattern,
                    "pattern is {render_hir_type(literal_type)} but the match subject is {render_hir_type(subject)}")
            }
            return result
        }
        if pattern.kind == "pattern_range" {
            for bound: AstNode in pattern.children {
                result.children.push(
                    self.check_pattern(bound, subject))
            }
            return result
        }
        if pattern.kind == "pattern_wildcard" {
            return result
        }
        if pattern.kind != "pattern_name" {
            self.fail(pattern, "invalid match pattern")
            return result
        }
        var enum_subject: bool = false
        var known_variant: bool = false
        if subject.name == "Option" {
            enum_subject = true
            known_variant =
                pattern.value == "some" ||
                pattern.value == "none"
        } else if subject.name == "Result" {
            enum_subject = true
            known_variant =
                pattern.value == "ok" ||
                pattern.value == "err"
        } else {
            match self.declaration_for(subject) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        enum_subject = true
                        known_variant =
                            self.variant_for(
                                declaration,
                                pattern.value).is_some()
                    }
                }
                none => {}
            }
        }
        if !enum_subject {
            self.fail(
                pattern,
                "'{pattern.value}' pattern needs an enum subject, this is {render_hir_type(subject)}")
            return result
        }
        if !known_variant {
            self.fail(
                pattern,
                "{render_hir_type(subject)} has no variant '{pattern.value}'")
            return result
        }
        let payload: List<HirType> =
            self.pattern_payload(subject, pattern)
        if payload.len() != pattern.children.len() {
            self.fail(
                pattern,
                "pattern '{pattern.value}' needs {payload.len()} binding(s), got {pattern.children.len()}")
        }
        let shared: int =
            if payload.len() < pattern.children.len() {
                payload.len()
            } else {
                pattern.children.len()
            }
        for index: int in 0..shared {
            let binding: AstNode = pattern.children[index]
            var binding_type: HirType = payload[index]
            match type_child(binding) {
                some(type_node) => {
                    let written: HirType =
                        hir_type_from_ast(type_node)
                    self.expect_type(
                        binding, binding_type, written)
                    binding_type = written
                }
                none => {}
            }
            let binding_id: int = self.declare(
                binding, binding_type, false, true, false)
            let lowered: HirNode = self.make_node(
                binding, "pattern_binding",
                binding.value, binding_type)
            lowered.binding_id = binding_id
            result.children.push(lowered)
        }
        return result
    }

    fn collect_pattern_coverage(
        pattern: AstNode,
        inout covered: Map<string, bool>,
        inout has_wildcard: bool,
        inout saw_true: bool,
        inout saw_false: bool) {
        if pattern.kind == "pattern_alternative" {
            for child: AstNode in pattern.children {
                self.collect_pattern_coverage(
                    child, inout covered,
                    inout has_wildcard,
                    inout saw_true, inout saw_false)
            }
            return
        }
        if pattern.kind == "pattern_wildcard" {
            has_wildcard = true
        } else if pattern.kind == "pattern_name" {
            covered[pattern.value] = true
        } else if pattern.kind == "pattern_literal" {
            if pattern.value == "true" {
                saw_true = true
            } else if pattern.value == "false" {
                saw_false = true
            }
        }
    }

    fn check_match_exhaustive(
        node: AstNode, subject: HirType,
        covered: Map<string, bool>,
        has_wildcard: bool,
        saw_true: bool, saw_false: bool) {
        if has_wildcard || subject.name == "poison" {
            return
        }
        var variants: List<string> = []
        if subject.name == "Option" {
            variants = ["some", "none"]
        } else if subject.name == "Result" {
            variants = ["ok", "err"]
        } else {
            match self.declaration_for(subject) {
                some(declaration) => {
                    if declaration.kind == "enum" {
                        for variant: HirField in
                            declaration.variants {
                            variants.push(variant.name)
                        }
                    }
                }
                none => {}
            }
        }
        if variants.len() != 0 {
            var missing: List<string> = []
            for variant: string in variants {
                if !covered.contains(variant) {
                    missing.push(variant)
                }
            }
            if missing.len() != 0 {
                self.fail(
                    node,
                    "match doesn't cover: {missing.join(", ")} — add them or a _ arm")
            }
            return
        }
        if subject.name == "bool" {
            if !saw_true || !saw_false {
                self.fail(
                    node,
                    "match on bool needs true and false (or _)")
            }
            return
        }
        self.fail(
            node,
            "match on {render_hir_type(subject)} needs a _ arm")
    }

    fn check_match(node: AstNode,
                   expected: HirType) -> HirNode {
        let discard: bool = expected.name == "discard"
        let subject: HirNode =
            self.check_expression(
                node.children[0], no_hir_type())
        let result: HirNode =
            self.make_node(
                node, "match", "",
                if discard {
                    new HirType("unit")
                } else {
                    expected
                })
        result.children.push(subject)
        let move_base: List<LocalScope> =
            self.copy_scopes(self.scopes)
        var merged: List<LocalScope> =
            self.copy_scopes(move_base)
        var has_continuing_arm: bool = false
        var covered: Map<string, bool> = {}
        var has_wildcard: bool = false
        var saw_true: bool = false
        var saw_false: bool = false
        var arm_type: HirType =
            if discard {
                no_hir_type()
            } else {
                expected
            }
        for index: int in 1..node.children.len() {
            let arm: AstNode = node.children[index]
            self.scopes = self.copy_scopes(move_base)
            let lowered: HirNode =
                self.make_node(
                    arm, "arm", "", new HirType("unit"))
            self.push_scope()
            self.collect_pattern_coverage(
                arm.children[0], inout covered,
                inout has_wildcard,
                inout saw_true, inout saw_false)
            lowered.children.push(
                self.check_pattern(
                    arm.children[0], subject.type))
            var arm_borrows_move_only: bool = false
            let arm_scope: LocalScope =
                self.scopes[self.scopes.len() - 1]
            for bound_name: string in
                arm_scope.bindings.keys() {
                let bound: LocalBinding =
                    arm_scope.bindings[bound_name]
                if bound.borrowed &&
                   self.is_move_only(bound.type) {
                    arm_borrows_move_only = true
                }
            }
            if arm_borrows_move_only {
                self.move_only_borrow_depth += 1
            }
            if !discard && expected.name != "" &&
               expected.name != "unit" &&
               arm.children[1].kind == "block" {
                // a demanded value cannot come out of a block arm; the
                // trailing-statement case (expected "") stays a statement
                self.fail(
                    arm,
                    "a block arm doesn't produce a value — this match is used as one. use `pattern => expression` arms here")
            }
            // a statement match discards arm values, and its block arms
            // must keep discarding: a trailing call or nested match in
            // the block is a statement, never the arm's value
            let value: HirNode =
                if arm.children[1].kind == "block" {
                    self.check_expression_block(
                        arm.children[1],
                        if discard {
                            new HirType("discard")
                        } else {
                            arm_type
                        })
                } else {
                    self.check_expression(
                        arm.children[1], arm_type)
                }
            lowered.children.push(value)
            if arm_borrows_move_only {
                self.move_only_borrow_depth -= 1
            }
            self.pop_scope()
            let arm_returns: bool =
                arm.children[1].kind == "block" &&
                self.block_always_returns(
                    arm.children[1])
            if !arm_returns {
                let arm_state: List<LocalScope> =
                    self.copy_scopes(self.scopes)
                if !has_continuing_arm {
                    merged = move arm_state
                    has_continuing_arm = true
                } else {
                    self.scopes =
                        self.copy_scopes(move_base)
                    self.merge_move_states(
                        merged, arm_state)
                    merged = self.copy_scopes(self.scopes)
                }
            }
            if !discard {
                if arm_type.name == "" {
                    arm_type = value.type
                }
                if !hir_types_equal(value.type, arm_type) {
                    self.fail(
                        arm,
                        "match arms have different types: {render_hir_type(arm_type)} and {render_hir_type(value.type)}")
                }
            }
            lowered.type = value.type
            result.children.push(lowered)
        }
        self.scopes =
            if has_continuing_arm {
                move merged
            } else {
                move move_base
            }
        self.check_match_exhaustive(
            node, subject.type, covered,
            has_wildcard, saw_true, saw_false)
        result.type =
            if discard || arm_type.name == "" {
                new HirType("unit")
            } else {
                arm_type
            }
        if !discard {
            self.expect_type(node, result.type, expected)
        }
        return result
    }

    fn check_expression(node: AstNode,
                        expected: HirType) -> HirNode {
        if node.kind == "literal" {
            return self.check_literal(node, expected)
        }
        if node.kind == "name" {
            return self.check_name(node, expected)
        }
        if node.kind == "unary" {
            return self.check_unary(node, expected)
        }
        if node.kind == "binary" {
            return self.check_binary(node, expected)
        }
        if node.kind == "call" {
            return self.check_call(node, expected)
        }
        if node.kind == "layout_query" {
            return self.check_layout_query(node, expected)
        }
        if node.kind == "field" {
            return self.check_field(node, expected)
        }
        if node.kind == "new" {
            return self.check_new(node, expected)
        }
        if node.kind == "initializer" {
            return self.check_initializer(node, expected)
        }
        if node.kind == "list" {
            return self.check_list(node, expected)
        }
        if node.kind == "map" {
            return self.check_map(node, expected)
        }
        if node.kind == "index" {
            return self.check_index(node, expected)
        }
        if node.kind == "try" {
            return self.check_try(node, expected)
        }
        if node.kind == "await" {
            return self.check_await(node, expected)
        }
        if node.kind == "cast" {
            return self.check_cast(node, expected)
        }
        if node.kind == "closure" {
            return self.check_closure(node, expected)
        }
        if node.kind == "if_expression" {
            return self.check_if_expression(node, expected)
        }
        if node.kind == "match" {
            return self.check_match(node, expected)
        }
        self.fail(
            node,
            "expression '{node.kind}' is not in the Beans checker yet")
        return self.make_node(
            node, "error", node.kind, poison_hir_type())
    }

    fn expression_child(node: AstNode) -> Option<AstNode> {
        for child: AstNode in node.children {
            if child.kind != "type" &&
               child.kind != "array_type" &&
               child.kind != "fn_type" {
                return some(child)
            }
        }
        return none
    }

    fn check_local(node: AstNode) -> HirNode {
        var declared: HirType = no_hir_type()
        match type_child(node) {
            some(type_node) => {
                declared = hir_type_from_ast(type_node)
                if !self.validate_annotation_arity(
                        type_node, declared) {
                    declared = poison_hir_type()
                }
                self.validate_target_type(
                    type_node, declared)
            }
            none => {}
        }
        var initializer: Option<AstNode> = self.expression_child(node)
        var actual: HirType = declared
        var result: HirNode =
            self.make_node(node, node.kind, node.value, actual)
        // `async let` starts a structured child: the initializer must be a
        // direct async call, and the written type is the eventual result.
        let starts_child: bool = node.note == "async"
        if starts_child && !self.current.is_async {
            self.fail(
                node,
                "'async let' is only valid inside an async function")
        }
        match initializer {
            some(expression) => {
                if starts_child {
                    if expression.kind != "call" {
                        self.fail(
                            node,
                            "'async let' needs a direct call to an async function")
                    } else {
                        expression.await_allowed = true
                    }
                }
                let value: HirNode =
                    self.check_expression(expression, declared)
                if starts_child && expression.await_allowed {
                    expression.await_allowed = false
                    if value.type.name != "poison" {
                        self.fail(
                            node,
                            "'async let' needs a call to an async function — this call is synchronous")
                    }
                }
                result.children.push(value)
                if declared.name == "" { actual = value.type }
                self.require_move_source(
                    expression, value.type,
                    "binding '{node.value}'")
            }
            none => {
                if starts_child {
                    self.fail(
                        node,
                        "'async let' needs a call to an async function as its initializer")
                } else if declared.name == "" {
                    self.fail(
                        node,
                        "local '{node.value}' needs a type or initializer")
                    actual = poison_hir_type()
                }
            }
        }
        result.type = actual
        result.binding_id = self.declare(
            node, actual, node.kind == "var", false, false)
        if starts_child {
            match self.find_local(node.value) {
                some(binding) => {
                    binding.move_state = "async_pending"
                }
                none => {}
            }
        }
        return result
    }

    fn check_assignment(node: AstNode) -> HirNode {
        let target: AstNode = node.children[0]
        let result: HirNode =
            self.make_node(
                node, "assign", node.value,
                new HirType("unit"))
        if target.kind == "field" || target.kind == "index" {
            let place: HirNode =
                if target.kind == "field" {
                    self.check_field(target, no_hir_type())
                } else {
                    self.check_index(target, no_hir_type())
                }
            let value: HirNode = self.check_expression(
                node.children[1], place.type)
            if target.kind == "field" &&
               target.children.len() != 0 {
                match self.declaration_for(
                    place.children[0].type) {
                    some(declaration) => {
                        if declaration.kind == "struct" ||
                           declaration.kind == "union" {
                            if declaration.kind == "union" &&
                               node.value != "=" {
                                self.fail(
                                    target,
                                    "union fields only support direct assignment for now")
                            }
                            if target.children[0].kind != "name" {
                                // no backend stores through a nested
                                // record place yet; stage 0 rejects this
                                // at check time and so does this checker
                                self.fail(
                                    target,
                                    "struct field assignment needs a local variable for now")
                            } else {
                                match self.find_local(
                                    target.children[0].value) {
                                    some(binding) => {
                                        if !binding.mutable {
                                            self.fail(
                                                target,
                                                "'{binding.name}' is a let — its fields can't be reassigned. use var")
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
            if target.kind == "index" &&
               place.children.len() != 0 &&
               place.children[0].type.name == "array" &&
               target.children[0].kind == "name" {
                match self.find_local(
                    target.children[0].value) {
                    some(binding) => {
                        if !binding.mutable {
                            self.fail(
                                target,
                                "'{binding.name}' is a let — its elements can't be reassigned. use var")
                        }
                    }
                    none => {}
                }
            }
            if node.value == "=" {
                self.require_move_source(
                    node.children[1], value.type,
                    "assignment")
            }
            if target.kind == "index" && node.value != "=" &&
               place.children.len() != 0 &&
               (place.children[0].type.name == "List" ||
                place.children[0].type.name == "Map" ||
                place.children[0].type.name == "OrderedMap") {
                let collection: HirType =
                    place.children[0].type
                let kind: string =
                    if collection.name == "Map" ||
                       collection.name == "OrderedMap" {
                        "map"
                    } else {
                        "list"
                    }
                self.fail(
                    node,
                    "{kind} index assignment only supports '='")
            } else if node.value != "=" &&
                      !hir_is_numeric(place.type) {
                self.fail(
                    node,
                    "compound assignment needs a numeric field")
            }
            result.children.push(place)
            result.children.push(value)
            return result
        }
        if target.kind != "name" {
            self.fail(node, "expression is not assignable")
            return result
        }
        match self.find_local(target.value) {
            some(binding) => {
                if !binding.mutable {
                    self.fail(
                        target, "cannot assign to immutable '{target.value}'")
                }
                let place: HirNode =
                    self.make_node(
                        target, "local", target.value, binding.type)
                place.binding_id = binding.id
                let value: HirNode = self.check_expression(
                    node.children[1], binding.type)
                if node.value == "=" {
                    self.require_move_source(
                        node.children[1], value.type,
                        "assignment")
                    if binding.mutable {
                        binding.move_state = "available"
                    }
                } else if binding.move_state == "moved" {
                    self.fail(
                        target,
                        "use of moved value '{target.value}'")
                } else if binding.move_state ==
                          "maybe_moved" {
                    self.fail(
                        target,
                        "value '{target.value}' may have been moved")
                }
                if node.value != "=" &&
                   !hir_is_numeric(binding.type) {
                    self.fail(
                        node,
                        "compound assignment needs a numeric local")
                }
                result.children.push(place)
                result.children.push(value)
            }
            none => {
                match self.current_c_global(
                    target.value) {
                    some(global) => {
                        if !global.is_var {
                            self.fail(
                                target,
                                "'{target.value}' is an extern let and cannot be assigned")
                        }
                        if node.value != "=" {
                            self.fail(
                                target,
                                "extern C globals only support direct assignment")
                        }
                        self.require_unsafe(
                            target,
                            "writing extern C global '{target.value}'")
                        let place: HirNode =
                            self.make_node(
                                target, "c_global",
                                target.value,
                                global.type)
                        place.resolved =
                            global.qualified
                        let value: HirNode =
                            self.check_expression(
                                node.children[1],
                                global.type)
                        result.children.push(place)
                        result.children.push(value)
                    }
                    none => {
                        self.fail(
                            target,
                            "unknown name '{target.value}'")
                    }
                }
            }
        }
        return result
    }

    fn check_for(node: AstNode) -> HirNode {
        let result: HirNode =
            self.make_node(
                node, "for", "", new HirType("unit"))
        self.loop_depth += 1
        if node.children.len() == 1 &&
           node.children[0].kind == "block" {
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            let saved_floor: int =
                self.take_floor_depth
            self.take_floor_depth = self.scopes.len()
            result.children.push(
                self.check_nested_block(node.children[0]))
            self.take_floor_depth = saved_floor
            self.scopes = move base
            self.loop_depth -= 1
            return result
        }
        if node.children.len() >= 3 &&
           node.children[0].kind == "binding" {
            let binding: AstNode = node.children[0]
            let iterable: HirNode = self.check_expression(
                node.children[1], no_hir_type())
            result.children.push(iterable)
            var element: HirType = poison_hir_type()
            if (iterable.type.name == "List" ||
                iterable.type.name == "range" ||
                iterable.type.name == "Slice") &&
               iterable.type.args.len() == 1 {
                element = iterable.type.args[0]
                if iterable.type.name == "Slice" {
                    self.require_unsafe(
                        node.children[1],
                        "looping over Slice")
                }
            } else if iterable.type.name == "array" &&
                      iterable.type.args.len() == 1 {
                element = iterable.type.args[0]
            } else {
                self.fail(
                    node.children[1],
                    "{render_hir_type(iterable.type)} is not iterable")
            }
            match type_child(binding) {
                some(type_node) => {
                    let written: HirType =
                        hir_type_from_ast(type_node)
                    self.expect_type(binding, element, written)
                    element = written
                }
                none => {}
            }
            result.value = binding.value
            let lowered_binding: HirNode = self.make_node(
                binding, "loop_binding",
                binding.value, element)
            result.children.push(lowered_binding)
            let block: AstNode = node.children[2]
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            let saved_floor: int =
                self.take_floor_depth
            self.take_floor_depth = self.scopes.len()
            let body: HirNode =
                self.make_node(
                    block, "block", "", new HirType("unit"))
            self.push_scope()
            lowered_binding.binding_id = self.declare(
                binding, element, false, true, false)
            let element_borrows_move_only: bool =
                self.is_move_only(element)
            if element_borrows_move_only {
                self.move_only_borrow_depth += 1
            }
            for statement: AstNode in block.children {
                body.children.push(
                    self.check_statement(statement))
            }
            if element_borrows_move_only {
                self.move_only_borrow_depth -= 1
            }
            self.pop_scope()
            self.take_floor_depth = saved_floor
            self.scopes = move base
            result.children.push(body)
            self.loop_depth -= 1
            return result
        }
        if node.children.len() >= 2 {
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            let saved_floor: int =
                self.take_floor_depth
            self.take_floor_depth = self.scopes.len()
            result.children.push(self.check_expression(
                node.children[0], new HirType("bool")))
            result.children.push(
                self.check_nested_block(node.children[1]))
            self.take_floor_depth = saved_floor
            self.scopes = move base
        } else {
            self.fail(node, "invalid for statement")
        }
        self.loop_depth -= 1
        return result
    }

    // beans has no implicit tail return — a `-> T` body must say
    // `return` on every path (spec/SYNTAX.md, "Functions"), so a
    // body that can run off the end has no value to hand back. The
    // walk is deliberately conservative: unsure means "does not
    // return", which at worst asks for a `return` the reader can
    // already see is needed.
    fn block_always_returns(block: AstNode) -> bool {
        for statement: AstNode in block.children {
            if self.statement_always_returns(statement) {
                return true
            }
        }
        return false
    }

    fn statement_always_returns(node: AstNode) -> bool {
        if node.kind == "return" { return true }
        if node.kind == "if" &&
           node.children.len() > 2 {
            let yes: bool =
                self.block_always_returns(node.children[1])
            let no: bool =
                if node.children[2].kind == "block" {
                    self.block_always_returns(
                        node.children[2])
                } else {
                    self.statement_always_returns(
                        node.children[2])
                }
            return yes && no
        }
        if node.kind == "for" &&
           node.children.len() == 1 &&
           node.children[0].kind == "block" {
            // `for { }` with no break never finishes, so nothing
            // follows it
            return !self.block_has_break(node.children[0])
        }
        if node.kind == "unsafe" &&
           node.children.len() == 1 {
            return self.block_always_returns(
                node.children[0])
        }
        if node.kind == "expression" &&
           node.children[0].kind == "match" &&
           node.children[0].children.len() > 1 {
            // a statement-position match counts when every arm
            // returns — check_match already proved the arms cover
            // the subject
            let match_node: AstNode = node.children[0]
            for index: int in 1..match_node.children.len() {
                let arm: AstNode = match_node.children[index]
                if arm.children[1].kind != "block" ||
                   !self.block_always_returns(arm.children[1]) {
                    return false
                }
            }
            return true
        }
        return false
    }

    // a `break` binds to the innermost loop, so this stops at a
    // nested loop instead of counting its breaks as this loop's
    fn block_has_break(block: AstNode) -> bool {
        for statement: AstNode in block.children {
            if self.statement_has_break(statement) {
                return true
            }
        }
        return false
    }

    fn statement_has_break(node: AstNode) -> bool {
        if node.kind == "break" { return true }
        if node.kind == "if" {
            if self.block_has_break(node.children[1]) {
                return true
            }
            if node.children.len() > 2 {
                if node.children[2].kind == "block" {
                    return self.block_has_break(
                        node.children[2])
                }
                return self.statement_has_break(
                    node.children[2])
            }
            return false
        }
        if node.kind == "unsafe" &&
           node.children.len() == 1 {
            return self.block_has_break(node.children[0])
        }
        if node.kind == "expression" &&
           node.children[0].kind == "match" {
            let match_node: AstNode = node.children[0]
            for index: int in 1..match_node.children.len() {
                let arm: AstNode = match_node.children[index]
                if arm.children[1].kind == "block" &&
                   self.block_has_break(arm.children[1]) {
                    return true
                }
            }
        }
        return false
    }

    fn check_statement(node: AstNode) -> HirNode {
        if node.kind == "let" || node.kind == "var" {
            return self.check_local(node)
        }
        if node.kind == "return" {
            let result: HirNode =
                self.make_node(
                    node, "return", "", new HirType("unit"))
            if node.children.len() == 0 {
                if self.current.body_result.name != "unit" {
                    self.fail(
                        node,
                        "return needs {render_hir_type(self.current.body_result)}")
                }
            } else {
                let value: HirNode =
                    self.check_expression(
                        node.children[0],
                        self.current.body_result)
                result.children.push(value)
                self.require_move_source(
                    node.children[0], value.type,
                    "return")
            }
            return result
        }
        if node.kind == "expression" {
            let result: HirNode =
                self.make_node(
                    node, "expression", "", new HirType("unit"))
            result.children.push(self.check_expression(
                node.children[0],
                if node.children[0].kind == "match" {
                    new HirType("discard")
                } else {
                    no_hir_type()
                }))
            return result
        }
        if node.kind == "assign" {
            return self.check_assignment(node)
        }
        if node.kind == "if" {
            let result: HirNode =
                self.make_node(
                    node, "if", "", new HirType("unit"))
            result.children.push(self.check_expression(
                node.children[0], new HirType("bool")))
            let guard_mark: int =
                self.feature_guards.len()
            self.collect_feature_guards(
                node.children[0])
            let base: List<LocalScope> =
                self.copy_scopes(self.scopes)
            result.children.push(self.check_nested_block(
                node.children[1]))
            let yes: List<LocalScope> =
                self.copy_scopes(self.scopes)
            for self.feature_guards.len() > guard_mark {
                self.feature_guards.pop()
            }
            self.scopes = self.copy_scopes(base)
            if node.children.len() > 2 {
                if node.children[2].kind == "block" {
                    result.children.push(self.check_nested_block(
                        node.children[2]))
                } else {
                    result.children.push(
                        self.check_statement(node.children[2]))
                }
            }
            let no: List<LocalScope> =
                self.copy_scopes(self.scopes)
            self.scopes = self.copy_scopes(base)
            let yes_returns: bool =
                self.block_always_returns(
                    node.children[1])
            let no_returns: bool =
                node.children.len() > 2 &&
                if node.children[2].kind == "block" {
                    self.block_always_returns(
                        node.children[2])
                } else {
                    self.statement_always_returns(
                        node.children[2])
                }
            if yes_returns && !no_returns {
                self.scopes = move no
            } else if !yes_returns && no_returns {
                self.scopes = move yes
            } else if !yes_returns && !no_returns {
                self.merge_move_states(yes, no)
            }
            return result
        }
        if node.kind == "for" {
            return self.check_for(node)
        }
        if node.kind == "break" || node.kind == "continue" {
            if self.loop_depth == 0 {
                self.fail(
                    node,
                    "'{node.kind}' is only valid inside a loop")
            }
            return self.make_node(
                node, node.kind, "", new HirType("unit"))
        }
        if node.kind == "defer" {
            let result: HirNode =
                self.make_node(
                    node, "defer", "", new HirType("unit"))
            self.defer_depth += 1
            result.children.push(self.check_expression(
                node.children[0], no_hir_type()))
            self.defer_depth -= 1
            return result
        }
        if node.kind == "unsafe" {
            let result: HirNode =
                self.make_node(
                    node, "unsafe", "", new HirType("unit"))
            self.unsafe_depth += 1
            result.children.push(
                self.check_nested_block(node.children[0]))
            self.unsafe_depth -= 1
            return result
        }
        self.fail(
            node,
            "statement '{node.kind}' is not in the Beans checker yet")
        return self.make_node(
            node, "error", node.kind, poison_hir_type())
    }

    fn check_nested_block(block: AstNode) -> HirNode {
        let result: HirNode =
            self.make_node(
                block, "block", "", new HirType("unit"))
        self.push_scope()
        for statement: AstNode in block.children {
            result.children.push(self.check_statement(statement))
        }
        self.pop_scope()
        return result
    }

    fn check_function(function: HirFunction) {
        self.current = function
        self.validate_override(function)
        self.unsafe_depth = 0
        self.defer_depth = 0
        self.feature_guards = []
        self.take_floor_depth = -1
        self.capture_floor_depth = -1
        self.require_send_captures = false
        self.require_sync_captures = false
        self.allow_inout_expression = false
        self.bad_inout_captures = {}
        self.bad_send_captures = {}
        self.bad_sync_captures = {}
        self.move_only_borrow_depth = 0
        self.current_constraints = []
        for constraint: HirGeneric in
            function.generic_constraints {
            self.current_constraints.push(constraint)
        }
        if function.is_async && function.owner != "" &&
           !function.is_static {
            match self.declarations.get(function.owner) {
                some(owner) => {
                    if owner.is_unique {
                        self.fail(
                            function.syntax,
                            "async instance methods are not available on a unique class — the task frame cannot borrow the receiver; use a static async fn")
                    }
                }
                none => {}
            }
        }
        if function.owner != "" {
            match self.declarations.get(function.owner) {
                some(owner) => {
                    for constraint: HirGeneric in
                        owner.generic_constraints {
                        self.current_constraints.push(
                            constraint)
                    }
                }
                none => {}
            }
        }
        self.scopes = []
        self.push_scope()
        if function.owner != "" && !function.is_static {
            let self_node: AstNode =
                new AstNode("name", "self",
                            function.line, function.col)
            function.self_binding_id = self.declare(
                self_node, new HirType(function.owner),
                false, true, false)
        }
        for parameter: HirParameter in function.parameters {
            let parameter_node: AstNode =
                new AstNode(
                    "param", parameter.name,
                    parameter.line, parameter.col)
            parameter.binding_id = self.declare(
                parameter_node, parameter.type,
                parameter.passing == "inout",
                parameter.passing != "move",
                parameter.passing == "inout")
        }
        for child: AstNode in function.syntax.children {
            if child.kind != "block" { continue }
            for statement: AstNode in child.children {
                function.body.push(self.check_statement(statement))
            }
            if function.result.name != "unit" &&
               function.result.name != "poison" &&
               !self.block_always_returns(child) {
                self.fail(
                    function.syntax,
                    "'{function.name}' must return {render_hir_type(function.result)} — the body can finish without a return")
            }
        }
        self.pop_scope()
    }

    fn check_field_defaults() {
        for declaration: HirDeclaration in
            self.program.declarations {
            self.current = new HirFunction(
                "$defaults",
                "{declaration.qualified}.$defaults",
                declaration.qualified,
                false,
                declaration.file,
                declaration.line,
                declaration.col)
            self.current_constraints = []
            for constraint: HirGeneric in
                declaration.generic_constraints {
                self.current_constraints.push(constraint)
            }
            self.scopes = []
            self.push_scope()
            for field: HirField in declaration.fields {
                match field.default_syntax {
                    some(syntax) => {
                        field.default_value =
                            some(self.check_expression(
                                syntax, field.type))
                    }
                    none => {}
                }
            }
            self.pop_scope()
        }
    }

    fn run() -> bool {
        self.check_field_defaults()
        for function: HirFunction in self.program.functions {
            if (function.is_extern_c &&
                !function.is_c_export) ||
               !function.has_body {
                continue
            }
            self.check_function(function)
        }
        return self.errors.len() == 0
    }
}
