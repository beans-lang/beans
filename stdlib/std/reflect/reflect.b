// Safe runtime reflection for Beans.
//
// Descriptor storage is private. Programs obtain descriptors through
// type_of(T), Value.type(), registry queries, or another descriptor.

package reflect

import std.reflection as rt

/// The broad runtime shape of a Beans type.
pub enum Kind {
    unit
    boolean
    signed_integer
    unsigned_integer
    floating
    decimal
    string
    class_type
    interface_type
    struct_type
    union_type
    enum_type
    list
    map
    option
    result
    fixed_array
    slice
    raw_pointer
    function_type
    other
}

pub enum Passing {
    borrowed
    taken
    mutable
}

pub enum AnnotationValueKind {
    boolean
    signed_integer
    unsigned_integer
    floating
    decimal
    string
    enum_value
    list
    other
}

pub enum ErrorKind {
    missing
    inaccessible
    receiver_type
    value_type
    unsupported
    argument_count
    failed
}

pub class ReflectError {
    error_kind: ErrorKind
    error_message: string

    fn init(error_kind: ErrorKind, error_message: string) {
        self.error_kind = error_kind
        self.error_message = error_message
    }

    pub fn kind() -> ErrorKind { return self.error_kind }
    pub fn message() -> string { return self.error_message }
}

fn runtime_error() -> ReflectError {
    let kind: ErrorKind = match rt.error_code() {
        1 => ErrorKind.missing,
        2 => ErrorKind.inaccessible,
        3 => ErrorKind.receiver_type,
        4 => ErrorKind.value_type,
        5 => ErrorKind.unsupported,
        6 => ErrorKind.argument_count,
        _ => ErrorKind.failed,
    }
    return new ReflectError(kind, rt.error_message())
}

// The async expander replaces this marker with the compiler-private task
// that owns and drives one low-level reflected call.
async fn await_call(handle: int) -> int { return 0 }

/// One checked constant stored in a runtime annotation.
pub class AnnotationValue {
    id: int

    fn init(id: int) { self.id = id }

    pub fn kind() -> AnnotationValueKind {
        return match rt.annotation_value_kind(self.id) {
            0 => AnnotationValueKind.boolean,
            1 => AnnotationValueKind.signed_integer,
            2 => AnnotationValueKind.unsigned_integer,
            3 => AnnotationValueKind.floating,
            4 => AnnotationValueKind.decimal,
            5 => AnnotationValueKind.string,
            6 => AnnotationValueKind.enum_value,
            7 => AnnotationValueKind.list,
            _ => AnnotationValueKind.other,
        }
    }

    pub fn type() -> Type {
        return new Type(rt.annotation_value_type(self.id))
    }

    /// Canonical source text. Strings and enum values omit quotes/type names.
    pub fn text() -> string {
        return rt.annotation_value_text(self.id)
    }

    pub fn as_bool() -> Option<bool> {
        if self.kind() != AnnotationValueKind.boolean { return none }
        return some(rt.annotation_value_bool(self.id))
    }

    pub fn as_int() -> Option<int> {
        let value_kind: AnnotationValueKind = self.kind()
        if value_kind != AnnotationValueKind.signed_integer &&
           value_kind != AnnotationValueKind.unsigned_integer {
            return none
        }
        return match self.text().to_int() {
            ok(value) => some(value),
            err(_) => none,
        }
    }

    pub fn as_string() -> Option<string> {
        if self.kind() != AnnotationValueKind.string { return none }
        return some(self.text())
    }

    pub fn items() -> List<AnnotationValue> {
        var result: List<AnnotationValue> = []
        for index: int in 0..rt.annotation_value_item_count(self.id) {
            result.push(new AnnotationValue(
                rt.annotation_value_item_at(self.id, index)))
        }
        return move result
    }
}

pub class AnnotationArgument {
    id: int

    fn init(id: int) { self.id = id }
    pub fn name() -> string { return rt.annotation_argument_name(self.id) }
    pub fn type() -> Type {
        return new Type(rt.annotation_value_type(self.id))
    }
    pub fn value() -> AnnotationValue {
        return new AnnotationValue(self.id)
    }
}

/// One field in an annotation declaration's checked schema.
pub class AnnotationField {
    owner: string
    index: int

    fn init(owner: string, index: int) {
        self.owner = owner
        self.index = index
    }

    pub fn name() -> string {
        return rt.annotation_type_field_name(self.owner, self.index)
    }

    pub fn type() -> Type {
        return new Type(
            rt.annotation_type_field_type(self.owner, self.index))
    }

    pub fn has_default() -> bool {
        return (rt.annotation_type_field_flags(
            self.owner, self.index) & 1) != 0
    }

    pub fn default_value() -> Option<AnnotationValue> {
        let id: int =
            rt.annotation_type_field_default(self.owner, self.index)
        if id < 0 { return none }
        return some(new AnnotationValue(id))
    }
}

/// The declaration and checked schema of one annotation type.
pub class AnnotationType {
    qualified: string

    fn init(qualified: string) { self.qualified = qualified }

    pub fn qualified_name() -> string { return self.qualified }

    pub fn name() -> string {
        match self.qualified.rfind(".") {
            some(cut) => {
                return self.qualified.slice(cut + 1, self.qualified.len())
            }
            none => { return self.qualified }
        }
    }

    pub fn is_public() -> bool {
        return (rt.annotation_type_flags(self.qualified) & 1) != 0
    }

    pub fn is_repeatable() -> bool {
        return (rt.annotation_type_flags(self.qualified) & 2) != 0
    }

    pub fn retention() -> string {
        return rt.annotation_type_retention(self.qualified)
    }

    pub fn targets() -> List<string> {
        var result: List<string> = []
        for index: int in 0..rt.annotation_type_target_count(
                self.qualified) {
            result.push(rt.annotation_type_target_at(
                self.qualified, index))
        }
        return move result
    }

    pub fn fields() -> List<AnnotationField> {
        var result: List<AnnotationField> = []
        for index: int in 0..rt.annotation_type_field_count(
                self.qualified) {
            result.push(new AnnotationField(self.qualified, index))
        }
        return move result
    }

    pub fn field(name: string) -> Option<AnnotationField> {
        for field: AnnotationField in self.fields() {
            if field.name() == name { return some(field) }
        }
        return none
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(9, self.qualified, "", -1)
    }
}

pub class Annotation {
    id: int

    fn init(id: int) { self.id = id }
    pub fn qualified_name() -> string {
        return rt.annotation_name(self.id)
    }
    pub fn name() -> string {
        let qualified: string = self.qualified_name()
        match qualified.rfind(".") {
            some(cut) => {
                return qualified.slice(cut + 1, qualified.len())
            }
            none => { return qualified }
        }
    }
    pub fn type() -> AnnotationType {
        return new AnnotationType(self.qualified_name())
    }
    pub fn arguments() -> List<AnnotationArgument> {
        var result: List<AnnotationArgument> = []
        for index: int in 0..rt.annotation_argument_count(self.id) {
            result.push(new AnnotationArgument(
                rt.annotation_argument_at(self.id, index)))
        }
        return move result
    }
    pub fn argument(name: string) -> Option<AnnotationArgument> {
        for argument: AnnotationArgument in self.arguments() {
            if argument.name() == name { return some(argument) }
        }
        return none
    }
}

fn annotation_list(kind: int, owner: string,
                   member: string, position: int) -> List<Annotation> {
    var result: List<Annotation> = []
    let count: int = rt.annotation_count(
        kind, owner, member, position)
    for index: int in 0..count {
        result.push(new Annotation(rt.annotation_at(
            kind, owner, member, position, index)))
    }
    return move result
}

class PackedArguments {
    raw: int
    count: int

    fn init(values: List<Value>) {
        self.count = values.len()
        self.raw = 0
        unsafe {
            let handles: RawPtr<int> =
                RawPtr.alloc(if self.count == 0 { 1 } else { self.count })
            self.raw = handles.address() as int
            for index: int in 0..self.count {
                handles.offset(index).write(values[index].handle)
            }
        }
    }

    fn deinit() {
        if self.raw == 0 { return }
        unsafe {
            let handles: RawPtr<int> =
                RawPtr.from_address(self.raw as u64)
            handles.free()
        }
    }
}

/// An owned value at a dynamic reflection boundary.
pub class Value {
    handle: int

    fn init(handle: int) { self.handle = handle }

    fn deinit() {
        if self.handle != 0 { rt.value_drop(self.handle) }
    }

    pub fn type() -> Type {
        return new Type(rt.value_type(self.handle))
    }

    /// Make another box that owns a copy of this value.
    pub fn copy() -> Value {
        return new Value(rt.value_clone(self.handle))
    }

    pub fn is_type(wanted: Type) -> bool {
        return rt.value_matches(
            self.handle, wanted.qualified_name())
    }
}

/// Move a statically typed value into an owned dynamic box.
/// The compiler replaces this generic body with a checked boxing operation.
pub fn value<T>(move item: T) -> Value {
    return new Value(0)
}

/// A concrete Beans type in this executable.
pub class Type {
    qualified: string

    fn init(qualified: string) {
        self.qualified = qualified
    }

    /// The package-qualified, generic-aware type name.
    pub fn qualified_name() -> string {
        return self.qualified
    }

    /// The declared short name. Builtins return their normal source name.
    pub fn name() -> string {
        var base: string = self.qualified
        match base.find("<") {
            some(cut) => { base = base.slice(0, cut) }
            none => {}
        }
        match base.rfind(".") {
            some(cut) => { return base.slice(cut + 1, base.len()) }
            none => { return base }
        }
    }

    /// The broad shape of this type.
    pub fn kind() -> Kind {
        return match rt.type_kind(self.qualified) {
            0 => Kind.unit,
            1 => Kind.boolean,
            2 => Kind.signed_integer,
            3 => Kind.unsigned_integer,
            4 => Kind.floating,
            5 => Kind.decimal,
            6 => Kind.string,
            7 => Kind.class_type,
            8 => Kind.interface_type,
            9 => Kind.struct_type,
            10 => Kind.union_type,
            11 => Kind.enum_type,
            12 => Kind.list,
            13 => Kind.map,
            14 => Kind.option,
            15 => Kind.result,
            16 => Kind.fixed_array,
            17 => Kind.slice,
            18 => Kind.raw_pointer,
            19 => Kind.function_type,
            _ => Kind.other,
        }
    }

    /// Concrete generic arguments, in source order.
    pub fn type_arguments() -> List<Type> {
        var result: List<Type> = []
        let count: int = rt.type_argument_count(self.qualified)
        for index: int in 0..count {
            result.push(new Type(
                rt.type_argument_at(self.qualified, index)))
        }
        return move result
    }

    /// The direct base class, when this is a derived class.
    pub fn base_type() -> Option<Type> {
        let name: string = rt.base_type(self.qualified)
        if name == "" { return none }
        return some(new Type(name))
    }

    /// Directly implemented interfaces, in declaration order.
    pub fn interfaces() -> List<Type> {
        var result: List<Type> = []
        let count: int = rt.interface_count(self.qualified)
        for index: int in 0..count {
            result.push(new Type(
                rt.interface_at(self.qualified, index)))
        }
        return move result
    }

    /// True when a value of other can be used where this type is expected.
    pub fn is_assignable_from(other: Type) -> bool {
        return rt.is_assignable_from(
            self.qualified, other.qualified)
    }

    fn field_list(inherited: bool) -> List<Field> {
        var result: List<Field> = []
        let count: int =
            rt.field_count(self.qualified, inherited)
        for index: int in 0..count {
            result.push(new Field(
                self, inherited, index))
        }
        return move result
    }

    /// Fields declared directly on this type.
    pub fn declared_fields() -> List<Field> {
        return self.field_list(false)
    }

    /// Visible fields, base fields first and overridden names once.
    pub fn fields() -> List<Field> {
        return self.field_list(true)
    }

    /// Find one visible field by its runtime name.
    pub fn field(name: string) -> Option<Field> {
        let count: int = rt.field_count(self.qualified, true)
        for index: int in 0..count {
            if rt.field_name(
                   self.qualified, true, index) == name {
                return some(new Field(self, true, index))
            }
        }
        return none
    }

    fn method_list(inherited: bool) -> List<Method> {
        var result: List<Method> = []
        let count: int =
            rt.method_count(self.qualified, inherited)
        for index: int in 0..count {
            result.push(new Method(
                self,
                rt.method_name(
                    self.qualified, inherited, index)))
        }
        return move result
    }

    pub fn declared_methods() -> List<Method> {
        return self.method_list(false)
    }

    pub fn methods() -> List<Method> {
        return self.method_list(true)
    }

    pub fn method(name: string) -> Option<Method> {
        if rt.method_flags(self.qualified, name) < 0 {
            return none
        }
        return some(new Method(self, name))
    }

    pub fn initializer() -> Option<Initializer> {
        if rt.initializer_flags(self.qualified) < 0 {
            return none
        }
        return some(new Initializer(self))
    }

    pub fn variants() -> List<Variant> {
        var result: List<Variant> = []
        let count: int = rt.variant_count(self.qualified)
        for index: int in 0..count {
            result.push(new Variant(
                self, rt.variant_name(self.qualified, index)))
        }
        return move result
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(1, self.qualified, "", -1)
    }

    pub fn variant(name: string) -> Option<Variant> {
        if rt.variant_parameter_count(self.qualified, name) < 0 {
            return none
        }
        return some(new Variant(self, name))
    }
}

/// One class or struct field.
pub class Field {
    owner: Type
    inherited: bool
    index: int

    fn init(owner: Type, inherited: bool, index: int) {
        self.owner = owner
        self.inherited = inherited
        self.index = index
    }

    pub fn name() -> string {
        return rt.field_name(
            self.owner.qualified, self.inherited, self.index)
    }

    pub fn type() -> Type {
        return new Type(rt.field_type(
            self.owner.qualified, self.inherited, self.index))
    }

    pub fn declaring_type() -> Type {
        return new Type(rt.field_owner(
            self.owner.qualified, self.inherited, self.index))
    }

    pub fn is_public() -> bool {
        return (rt.field_flags(
            self.owner.qualified, self.inherited, self.index) & 1) != 0
    }

    pub fn has_default() -> bool {
        return (rt.field_flags(
            self.owner.qualified, self.inherited, self.index) & 2) != 0
    }

    pub fn get(receiver: Value) -> Result<Value, ReflectError> {
        let handle: int = rt.field_get(
            self.owner.qualified, self.name(), receiver.handle)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(handle))
    }

    pub fn set(receiver: Value, move value: Value) ->
        Result<bool, ReflectError> {
        if !rt.field_set(
               self.owner.qualified, self.name(),
               receiver.handle, value.handle) {
            return err(runtime_error())
        }
        return ok(true)
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(
            2, self.declaring_type().qualified_name(), self.name(), -1)
    }
}

pub class Parameter {
    owner: string
    callable: string
    function_item: bool
    variant: bool
    index: int

    fn init(owner: string, callable: string,
            function_item: bool, variant: bool, index: int) {
        self.owner = owner
        self.callable = callable
        self.function_item = function_item
        self.variant = variant
        self.index = index
    }

    pub fn name() -> string {
        if self.variant {
            return rt.variant_parameter_name(
                self.owner, self.callable, self.index)
        }
        if self.function_item {
            return rt.function_parameter_name(
                self.callable, self.index)
        }
        if self.callable == "init" {
            return rt.initializer_parameter_name(
                self.owner, self.index)
        }
        return rt.method_parameter_name(
            self.owner, self.callable, self.index)
    }

    pub fn type() -> Type {
        let name: string =
            if self.variant {
                rt.variant_parameter_type(
                    self.owner, self.callable, self.index)
            } else if self.function_item {
                rt.function_parameter_type(
                    self.callable, self.index)
            } else if self.callable == "init" {
                rt.initializer_parameter_type(
                    self.owner, self.index)
            } else {
                rt.method_parameter_type(
                    self.owner, self.callable, self.index)
            }
        return new Type(name)
    }

    pub fn passing() -> Passing {
        if self.variant { return Passing.taken }
        let raw: int =
            if self.function_item {
                rt.function_parameter_passing(
                    self.callable, self.index)
            } else if self.callable == "init" {
                rt.initializer_parameter_passing(
                    self.owner, self.index)
            } else {
                rt.method_parameter_passing(
                    self.owner, self.callable, self.index)
            }
        if raw == 1 { return Passing.taken }
        if raw == 2 { return Passing.mutable }
        return Passing.borrowed
    }

    pub fn annotations() -> List<Annotation> {
        if self.variant {
            return annotation_list(
                8, self.owner, self.callable, self.index)
        }
        if self.function_item {
            return annotation_list(
                7, self.callable, "", self.index)
        }
        return annotation_list(
            6, self.owner, self.callable, self.index)
    }
}

pub class Method {
    receiver: Type
    method_name: string
    // Resolved once here, so a cached descriptor never re-resolves its
    // strings on a call. Zero when the method does not exist; calls then
    // fail with the same missing error the lookup would have produced.
    handle: int

    fn init(receiver: Type, method_name: string) {
        self.receiver = receiver
        self.method_name = method_name
        self.handle = rt.method_handle(
            receiver.qualified_name(), method_name)
    }

    pub fn name() -> string { return self.method_name }

    pub fn declaring_type() -> Type {
        return new Type(rt.method_owner(
            self.receiver.qualified, self.method_name))
    }

    pub fn result_type() -> Type {
        return new Type(rt.method_result(
            self.receiver.qualified, self.method_name))
    }

    pub fn is_public() -> bool {
        return (rt.method_flags(
            self.receiver.qualified, self.method_name) & 1) != 0
    }

    pub fn is_static() -> bool {
        return (rt.method_flags(
            self.receiver.qualified, self.method_name) & 2) != 0
    }

    pub fn is_async() -> bool {
        return (rt.method_flags(
            self.receiver.qualified, self.method_name) & 4) != 0
    }

    pub fn is_generic() -> bool {
        return (rt.method_flags(
            self.receiver.qualified, self.method_name) & 8) != 0
    }

    pub fn parameters() -> List<Parameter> {
        var result: List<Parameter> = []
        let owner: string = self.receiver.qualified
        let count: int =
            rt.method_parameter_count(owner, self.method_name)
        for index: int in 0..count {
            result.push(new Parameter(
                owner, self.method_name, false, false, index))
        }
        return move result
    }

    pub fn call(receiver: Value, move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments =
            new PackedArguments(arguments)
        let handle: int = rt.method_call_handle(
            self.handle, receiver.handle,
            packed.raw, packed.count, false)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(handle))
    }

    pub async fn call_async(receiver: Value,
                            move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments =
            new PackedArguments(arguments)
        let handle: int = rt.method_call_async_handle(
            self.handle, receiver.handle,
            packed.raw, packed.count, false)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(await await_call(handle)))
    }

    pub fn call_static(move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments =
            new PackedArguments(arguments)
        let handle: int = rt.method_call_handle(
            self.handle, 0, packed.raw, packed.count, true)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(handle))
    }

    pub async fn call_static_async(move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments =
            new PackedArguments(arguments)
        let handle: int = rt.method_call_async_handle(
            self.handle, 0, packed.raw, packed.count, true)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(await await_call(handle)))
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(
            3, self.declaring_type().qualified_name(),
            self.method_name, -1)
    }
}

pub class Initializer {
    owner: Type
    // Resolved once, exactly as Method.handle.
    handle: int

    fn init(owner: Type) {
        self.owner = owner
        self.handle = rt.initializer_handle(owner.qualified_name())
    }

    pub fn declaring_type() -> Type {
        let declared: string =
            rt.method_owner(self.owner.qualified, "init")
        if declared == "" { return self.owner }
        return new Type(declared)
    }

    pub fn is_public() -> bool {
        return (rt.initializer_flags(self.owner.qualified) & 1) != 0
    }

    pub fn is_async() -> bool {
        return (rt.initializer_flags(self.owner.qualified) & 4) != 0
    }

    pub fn is_generic() -> bool {
        return (rt.initializer_flags(self.owner.qualified) & 8) != 0
    }

    pub fn parameters() -> List<Parameter> {
        var result: List<Parameter> = []
        for index: int in 0..rt.initializer_parameter_count(
                self.owner.qualified) {
            result.push(new Parameter(
                self.owner.qualified, "init", false, false, index))
        }
        return move result
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(
            3, self.declaring_type().qualified_name(), "init", -1)
    }

    pub fn call(move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments = new PackedArguments(arguments)
        let handle: int = rt.initializer_call_handle(
            self.handle, packed.raw, packed.count)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(handle))
    }
}

pub class Variant {
    owner: Type
    variant_name: string

    fn init(owner: Type, variant_name: string) {
        self.owner = owner
        self.variant_name = variant_name
    }

    pub fn name() -> string { return self.variant_name }
    pub fn declaring_type() -> Type { return self.owner }

    pub fn parameters() -> List<Parameter> {
        var result: List<Parameter> = []
        let count: int = rt.variant_parameter_count(
            self.owner.qualified, self.variant_name)
        for index: int in 0..count {
            result.push(new Parameter(
                self.owner.qualified, self.variant_name,
                false, true, index))
        }
        return move result
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(
            5, self.owner.qualified, self.variant_name, -1)
    }

    pub fn make(move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments = new PackedArguments(arguments)
        let handle: int = rt.variant_make(
            self.owner.qualified, self.variant_name,
            packed.raw, packed.count)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(handle))
    }
}

pub class Function {
    qualified: string
    // Resolved once, exactly as Method.handle.
    handle: int

    fn init(qualified: string) {
        self.qualified = qualified
        self.handle = rt.function_handle(qualified)
    }

    pub fn qualified_name() -> string { return self.qualified }
    pub fn name() -> string { return rt.function_name(self.qualified) }
    pub fn result_type() -> Type {
        return new Type(rt.function_result(self.qualified))
    }
    pub fn is_public() -> bool {
        return (rt.function_flags(self.qualified) & 1) != 0
    }
    pub fn is_async() -> bool {
        return (rt.function_flags(self.qualified) & 4) != 0
    }
    pub fn is_generic() -> bool {
        return (rt.function_flags(self.qualified) & 8) != 0
    }
    pub fn parameters() -> List<Parameter> {
        var result: List<Parameter> = []
        let count: int =
            rt.function_parameter_count(self.qualified)
        for index: int in 0..count {
            result.push(new Parameter(
                "", self.qualified, true, false, index))
        }
        return move result
    }

    pub fn call(move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments =
            new PackedArguments(arguments)
        let handle: int = rt.function_call_handle(
            self.handle, packed.raw, packed.count)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(handle))
    }

    pub async fn call_async(move arguments: List<Value>) ->
        Result<Value, ReflectError> {
        let packed: PackedArguments =
            new PackedArguments(arguments)
        let handle: int = rt.function_call_async_handle(
            self.handle, packed.raw, packed.count)
        if handle == 0 { return err(runtime_error()) }
        return ok(new Value(await await_call(handle)))
    }

    pub fn annotations() -> List<Annotation> {
        return annotation_list(4, self.qualified, "", -1)
    }
}

/// All types linked into this executable, in deterministic declaration order.
pub fn types() -> List<Type> {
    var result: List<Type> = []
    for index: int in 0..rt.registry_type_count() {
        result.push(new Type(rt.registry_type_at(index)))
    }
    return move result
}

pub fn find_type(qualified_name: string) -> Option<Type> {
    for item: Type in types() {
        if item.qualified_name() == qualified_name {
            return some(item)
        }
    }
    return none
}

pub fn functions() -> List<Function> {
    var result: List<Function> = []
    for index: int in 0..rt.registry_function_count() {
        result.push(new Function(
            rt.registry_function_at(index)))
    }
    return move result
}

pub fn find_function(qualified_name: string) -> Option<Function> {
    for item: Function in functions() {
        if item.qualified_name() == qualified_name {
            return some(item)
        }
    }
    return none
}

/// All annotation declarations linked into this executable.
pub fn annotation_types() -> List<AnnotationType> {
    var result: List<AnnotationType> = []
    for index: int in 0..rt.annotation_type_count() {
        result.push(new AnnotationType(
            rt.annotation_type_at(index)))
    }
    return move result
}

pub fn find_annotation_type(
    qualified_name: string) -> Option<AnnotationType> {
    for item: AnnotationType in annotation_types() {
        if item.qualified_name() == qualified_name {
            return some(item)
        }
    }
    return none
}
