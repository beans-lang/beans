package main

import std.io
import std.c as host_c
import std.cpu as host_cpu
import std.dl as host_dl
import std.fmt as host_fmt
import std.fs as host_fs
import std.intrinsic as host_intrinsic
import std.os as host_os
import std.path
import std.proc as host_proc
import std.random as host_random
import std.ready as host_ready
import std.sig as host_sig
import std.sock as host_sock
import std.thread as host_thread
import std.time as host_time

extern "C" fn beans_tree_ffi_invoke_bridge(
    bridge: RawPtr<u8>,
    symbol: RawPtr<u8>,
    result: RawPtr<u8>,
    arguments: RawPtr<RawPtr<u8> >,
    dispatch: fn(RawPtr<u8>, RawPtr<u8>,
                 RawPtr<RawPtr<u8> >),
    contexts: RawPtr<RawPtr<u8> >)
extern "C" fn beans_tree_stored_close(
    value: RawPtr<u8>)
// The fiber core (spec/CONCURRENCY.md): the interpreter hosts each brewed
// fiber on a real fiber stack and re-enters the tree walker inside it —
// one scheduler, the same queues as native. The join parks the walker's
// own fiber, which is what lets the child run.
extern "C" fn beans_worker_bootstrap() -> RawPtr<u8>
extern "C" fn beans_worker_current() -> RawPtr<u8>
// Runtime-side externs (the fiber-parking socket calls) live inside this
// very process, where the dynamic loader cannot always see them — an ELF
// executable exports nothing without --export-dynamic, a PE one nothing at
// all. The runtime answers their addresses itself.
extern "C" fn beans_rt_host_symbol(name: RawPtr<u8>) -> RawPtr<u8>
extern "C" fn beans_fiber_spawn(
    worker: RawPtr<u8>,
    entry: fn(RawPtr<u8>),
    argument: RawPtr<u8>,
    name: RawPtr<u8>,
    stack_reserve: int) -> RawPtr<u8>
extern "C" fn beans_fiber_join(
    fiber: RawPtr<u8>,
    message_out: RawPtr<u8>,
    message_cap: int) -> i32
extern "C" fn beans_fiber_cancel(fiber: RawPtr<u8>)
// TaskGroup delivery: next()/wait_all park the walker's fiber directly,
// and each finishing child's entry tail wakes it — the tree mirror of
// the native group's done hook and waiter field.
extern "C" fn beans_fiber_current() -> RawPtr<u8>
extern "C" fn beans_fiber_park() -> i32
extern "C" fn beans_fiber_resume(fiber: RawPtr<u8>)
extern "C" fn beans_stored_callback_close(
    value: RawPtr<u8>)
// Tree Gates are host Gates: wait must park the walker's own fiber, and
// open must wake fibers parked inside other interpreter threads — exactly
// what the host object already does. The handle leaks by design: a gate
// is a handful of bytes, its copies alias freely across tree threads, and
// the walker has no last-copy hook to release it from.
extern "C" fn beans_gate_new() -> RawPtr<u8>
extern "C" fn beans_gate_wait(gate: RawPtr<u8>)
extern "C" fn beans_gate_open(gate: RawPtr<u8>)
extern "C" fn beans_gate_is_open(
    gate: RawPtr<u8>) -> int

class TreeInterpreter {
    program: HirProgram
    arguments: List<string>
    failed: bool
    panic_text: string
    next_object_id: int
    // Zeroing weak fields: the registry maps a weakly referenced object's
    // id to an inner TreeValue sharing the same fields map, and the
    // wrapper count says how many host-level wrappers stand for that one
    // interpreted object (weak loads revive extra wrappers). The LAST
    // wrapper's host deinit is the object's death: it runs the interpreted
    // deinit chain and drops the registry entry, after which every weak
    // slot reads none — the same order the native runtime keeps.
    weak_track: bool
    weak_registry: Map<int, TreeValue>
    weak_wrappers: Map<int, int>
    singletons: TreeSingletonState
    memories: List<TreeMemory>
    next_memory_address: u64
    ffi_bridge_addresses: Map<string, int>
    ffi_bridge_handles: List<int>
    ffi_bridge_sequence: int
    manifest_handles: List<int>
    encoding_handles: Map<string, int>
    encoding_error: string
    log_handle: int
    log_error: string
    net_handles: Map<string, int>
    net_error: string
    stored_callbacks: Map<int, TreeStoredCallback>
    reflect_values: Map<int, TreeValue>
    reflect_value_types: Map<int, string>
    next_reflect_value: int
    reflect_error_code: int
    reflect_error_message: string
    reflect_annotations: Map<int, HirAnnotation>
    reflect_annotation_values: Map<int, TreeReflectAnnotationValue>
    next_reflect_annotation: int
    // Resolved reflection handles: parallel lists, handle = index + 1.
    // Kind 0 is a method (owner is the declaring type), 1 an initializer,
    // 2 a free function (owner holds the qualified name).
    reflect_handle_kinds: List<int>
    reflect_handle_owners: List<string>
    reflect_handle_names: List<string>
    runtime_hook_active: bool
    // Active concrete arguments for the generic function or class method
    // being interpreted. Native code specializes these bodies; the tree
    // interpreter keeps the equivalent bindings on a call stack.
    generic_type_bindings: List<Map<string, HirType>>
    // Set only by `beansc debug-adapter`. When present, every statement asks
    // it whether to stop, every call tells it about the frame, and the
    // program's own output is forwarded to the client instead of being
    // written to the protocol stream.
    debugger: Option<DebugSession>
    active_functions: List<string>
    // Name lookups used to walk `program.functions` and
    // `program.declarations` on every call, twice each — exact qualified
    // name, then a short-name fallback. That is linear in the size of the
    // whole program, so a call cost what the imports cost: measured at
    // 7.5 microseconds with none, 47.5 with eight packages loaded, on the
    // same loop. Neither list is added to once interpretation starts, so
    // both are indexed once on first use.
    lookup_index_built: bool
    function_by_qualified: Map<string, HirFunction>
    free_function_by_name: Map<string, HirFunction>
    declaration_by_qualified: Map<string, HirDeclaration>
    declaration_by_name: Map<string, HirDeclaration>

    fn init(program: HirProgram,
            move arguments: List<string>) {
        self.program = program
        self.lookup_index_built = false
        self.function_by_qualified = {}
        self.free_function_by_name = {}
        self.declaration_by_qualified = {}
        self.declaration_by_name = {}
        self.arguments = move arguments
        self.failed = false
        self.panic_text = ""
        self.next_object_id = 0
        self.weak_track = false
        self.weak_registry = {}
        self.weak_wrappers = {}
        for declaration: HirDeclaration in program.declarations {
            for weak_probe: HirField in declaration.fields {
                if weak_probe.is_weak {
                    self.weak_track = true
                }
            }
        }
        self.singletons = new TreeSingletonState()
        self.memories = []
        self.next_memory_address = 1048576
        self.ffi_bridge_addresses = {}
        self.ffi_bridge_handles = []
        self.ffi_bridge_sequence = 0
        self.manifest_handles = []
        self.encoding_handles = {}
        self.encoding_error = ""
        self.log_handle = -1
        self.log_error = ""
        self.net_handles = {}
        self.net_error = ""
        self.stored_callbacks = {}
        self.reflect_values = {}
        self.reflect_value_types = {}
        self.next_reflect_value = 1
        self.reflect_error_code = 0
        self.reflect_error_message = ""
        self.reflect_annotations = {}
        self.reflect_annotation_values = {}
        self.next_reflect_annotation = 1
        self.reflect_handle_kinds = []
        self.reflect_handle_owners = []
        self.reflect_handle_names = []
        self.runtime_hook_active = false
        self.generic_type_bindings = []
        self.debugger = none
        self.active_functions = []
        self.load_manifest_links()
    }

    fn current_type_bindings() -> Map<string, HirType> {
        if self.generic_type_bindings.len() == 0 {
            return {}
        }
        return copy_type_map(self.generic_type_bindings[
            self.generic_type_bindings.len() - 1])
    }

    fn runtime_type(type: HirType,
                    bindings: Map<string, HirType>) -> HirType {
        match bindings.get(type.name) {
            some(actual) => { return actual }
            none => {}
        }
        let result: HirType =
            new HirType(canonical_hir_name(type.name))
        result.array_length = type.array_length
        result.fn_parameter_count = type.fn_parameter_count
        result.fn_sendable = type.fn_sendable
        for argument: HirType in type.args {
            result.args.push(self.runtime_type(argument, bindings))
        }
        return result
    }

    fn runtime_generic_named(name: string,
                             generics: List<string>) -> bool {
        for generic: string in generics {
            if generic == name { return true }
        }
        return false
    }

    fn bind_runtime_type(formal: HirType,
                         actual: HirType,
                         generics: List<string>,
                         bindings: Map<string, HirType>) {
        if self.runtime_generic_named(formal.name, generics) {
            bindings[formal.name] = actual
            return
        }
        if canonical_hir_name(formal.name) !=
               canonical_hir_name(actual.name) ||
           formal.args.len() != actual.args.len() {
            return
        }
        for index: int in 0..formal.args.len() {
            self.bind_runtime_type(
                formal.args[index], actual.args[index],
                generics, bindings)
        }
    }

    fn bind_owner_type(function: HirFunction,
                       receiver: HirType,
                       bindings: Map<string, HirType>) {
        if function.owner == "" { return }
        match self.declaration(function.owner) {
            some(owner) => {
                if owner.generics.len() != receiver.args.len() ||
                   (receiver.name != owner.name &&
                    receiver.name != owner.qualified) {
                    return
                }
                for index: int in 0..owner.generics.len() {
                    bindings[owner.generics[index]] =
                        receiver.args[index]
                }
            }
            none => {}
        }
    }

    fn call_type_bindings(node: HirNode,
                          function: HirFunction) -> Map<string, HirType> {
        let inherited: Map<string, HirType> =
            self.current_type_bindings()
        let bindings: Map<string, HirType> =
            copy_type_map(inherited)
        // Explicit type arguments seed the bindings first; they may name
        // the caller's own generics, which resolve through the inherited
        // frame. This is what binds a generic the signature never
        // mentions.
        for index: int in 0..node.type_argument_names.len() {
            bindings[node.type_argument_names[index]] =
                self.runtime_type(
                    node.type_arguments[index], inherited)
        }
        var argument_offset: int = 0
        if node.kind == "method_call" && node.children.len() != 0 {
            self.bind_owner_type(
                function,
                self.runtime_type(node.children[0].type, inherited),
                bindings)
            argument_offset = 1
        } else if node.kind == "new" {
            self.bind_owner_type(
                function, self.runtime_type(node.type, inherited),
                bindings)
        }
        for index: int in 0..function.parameters.len() {
            let child_index: int = index + argument_offset
            if child_index >= node.children.len() { break }
            self.bind_runtime_type(
                function.parameters[index].type,
                self.runtime_type(
                    node.children[child_index].type, inherited),
                function.generics, bindings)
        }
        self.bind_runtime_type(
            function.result,
            self.runtime_type(node.type, inherited),
            function.generics, bindings)
        return move bindings
    }

    fn manifest_link_applies(link: ModuleLink) -> bool {
        return link.selector == "all" ||
               link.selector == self.program.target.os ||
               link.selector == self.program.target.triple
    }

    fn load_manifest_links() {
        // csrc rows compile once into a cached host library, opened like
        // any manifest library so extern symbols resolve through it.
        let csrc_sources: List<string> =
            csrc_selected(
                self.program.csrc_rows,
                self.program.target)
        if csrc_sources.len() != 0 {
            let link_arguments: List<string> =
                manifest_link_arguments(
                    self.program.links,
                    self.program.target)
            match csrc_run_library(
                csrc_sources,
                link_arguments,
                self.program.target.os,
                self.program.target.triple) {
                ok(library) => {
                    match host_dl.open(library) {
                        ok(handle) => {
                            self.manifest_handles.push(handle)
                        }
                        err(error) => {
                            self.failed = true
                            self.panic_text =
                                "error: cannot load csrc library: {error.msg}"
                            return
                        }
                    }
                }
                err(error) => {
                    self.failed = true
                    self.panic_text =
                        "error: {error.msg}"
                    return
                }
            }
        }
        var search_paths: List<string> = []
        for link: ModuleLink in self.program.links {
            if self.manifest_link_applies(link) &&
               link.kind == "search" {
                search_paths.push(
                    path.join(link.root, link.value))
            }
        }
        var opened: Map<string, bool> = {}
        for link: ModuleLink in self.program.links {
            if !self.manifest_link_applies(link) ||
               link.kind == "search" {
                continue
            }
            var candidates: List<string> = []
            if link.kind == "framework" {
                if self.program.target.os != "macos" {
                    self.failed = true
                    self.panic_text =
                        "error: framework '{link.value}' cannot be loaded on {self.program.target.os}"
                    return
                }
                for directory: string in search_paths {
                    candidates.push(
                        path.join(
                            path.join(
                                directory,
                                "{link.value}.framework"),
                            link.value))
                }
                candidates.push(
                    "/Library/Frameworks/{link.value}.framework/{link.value}")
                candidates.push(
                    "/System/Library/Frameworks/{link.value}.framework/{link.value}")
            } else {
                var names: List<string> = []
                if self.program.target.os == "windows" {
                    names = [link.value,
                             "{link.value}.dll",
                             "lib{link.value}.dll"]
                } else if self.program.target.os == "macos" {
                    names = ["lib{link.value}.dylib",
                             "lib{link.value}.so",
                             link.value]
                } else {
                    names = ["lib{link.value}.so",
                             link.value]
                    // glibc 2.34+ ships lib<name>.so as a linker script
                    // (GROUP ( lib<name>.so.6 ... )), which the dynamic
                    // loader refuses to open, and a bare runtime package
                    // carries only the versioned object. The loadable file
                    // is lib<name>.so.<n>, so those spellings are
                    // candidates too — libm.so.6, libX11.so.6, libGL.so.1
                    // all land inside this range.
                    for suffix: int in 0..10 {
                        names.push(
                            "lib{link.value}.so.{suffix}")
                    }
                }
                for directory: string in search_paths {
                    for name: string in names {
                        candidates.push(
                            path.join(directory, name))
                    }
                }
                for name: string in names {
                    candidates.push(name)
                }
            }
            var handle: int = 0
            var last_error: string = "dynamic loader error"
            for candidate: string in candidates {
                if opened.contains_key(candidate) {
                    handle = 1
                    break
                }
                match host_dl.open(candidate) {
                    ok(value) => {
                        handle = value
                        self.manifest_handles.push(value)
                        opened[candidate] = true
                    }
                    err(error) => {
                        last_error = error.msg
                    }
                }
                if handle != 0 { break }
            }
            if handle == 0 {
                self.failed = true
                let kind: string =
                    if link.kind == "framework" {
                        "framework"
                    } else {
                        "library"
                    }
                self.panic_text =
                    "error: cannot load manifest {kind} '{link.value}': {last_error}"
                return
            }
        }
    }

    fn manifest_symbol_address(name: string) -> int {
        for handle: int in self.manifest_handles {
            match host_dl.symbol(handle, name) {
                ok(address) => { return address }
                err(_) => {}
            }
        }
        return 0
    }

    fn fail(node: HirNode, message: string) -> TreeValue {
        return self.fail_at(
            node, node.col, message)
    }

    fn fail_at(node: HirNode, col: int,
               message: string) -> TreeValue {
        if !self.failed {
            self.failed = true
            self.panic_text =
                "runtime panic at {node.line}:{col}: {message}"
            // Stop with the frames still standing, so a person can see what
            // the program was doing when it failed.
            match self.debugger {
                some(session) => {
                    session.at_panic(self.panic_text)
                }
                none => {}
            }
        }
        return TreeValue.unit()
    }

    fn floating_value(type: HirType,
                      value: float) -> TreeValue {
        if canonical_hir_name(type.name) == "f32" {
            let narrow: f32 = value as f32
            return TreeValue.floating(
                narrow as float)
        }
        return TreeValue.floating(value)
    }

    fn decimal_binary_value(
        node: HirNode, operation: string,
        left: decimal, right: decimal) -> TreeValue {
        let zero: decimal = 0.0
        let one: decimal = 1.0
        let maximum: decimal =
            99999999999999999999999999999999999999
        let minimum: decimal = -maximum
        if operation == "+" {
            if (right > zero &&
                left > maximum - right) ||
               (right < zero &&
                left < minimum - right) {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left + right)
        }
        if operation == "-" {
            if (right > zero &&
                left < minimum + right) ||
               (right < zero &&
                left > maximum + right) {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left - right)
        }
        if operation == "*" {
            let left_magnitude: decimal = left.abs()
            let right_magnitude: decimal = right.abs()
            var product_limit: decimal = maximum
            if right_magnitude >= one {
                product_limit =
                    maximum / right_magnitude
            }
            if right_magnitude >= one &&
               left_magnitude > product_limit {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left * right)
        }
        if operation == "/" {
            let right_magnitude: decimal = right.abs()
            if right_magnitude == zero {
                return self.fail(
                    node, "divide by zero")
            }
            var quotient_limit: decimal = maximum
            if right_magnitude < one {
                quotient_limit =
                    maximum * right_magnitude
            }
            if right_magnitude < one &&
               left.abs() > quotient_limit {
                return self.fail(
                    node, "decimal overflow")
            }
            return TreeValue.decimal_value(
                left / right)
        }
        return self.fail(
            node,
            "decimal operator '{operation}' is not in the Beans interpreter yet")
    }

    // Built once, on first lookup. Each map keeps the FIRST entry under a
    // name, which is what the scans it replaces returned.
    fn build_lookup_index() {
        self.lookup_index_built = true
        for function: HirFunction in self.program.functions {
            if !self.function_by_qualified.contains_key(
                   function.qualified) {
                self.function_by_qualified[
                    function.qualified] = function
            }
            if function.owner == "" &&
               !self.free_function_by_name.contains_key(
                   function.name) {
                self.free_function_by_name[
                    function.name] = function
            }
        }
        for declaration: HirDeclaration in
            self.program.declarations {
            if !self.declaration_by_qualified.contains_key(
                   declaration.qualified) {
                self.declaration_by_qualified[
                    declaration.qualified] = declaration
            }
            if !self.declaration_by_name.contains_key(
                   declaration.name) {
                self.declaration_by_name[
                    declaration.name] = declaration
            }
        }
    }

    fn find_function(name: string) -> Option<HirFunction> {
        if !self.lookup_index_built {
            self.build_lookup_index()
        }
        match self.function_by_qualified.get(name) {
            some(found) => { return some(found) }
            none => {}
        }
        return self.free_function_by_name.get(name)
    }

    fn declaration(name: string) ->
        Option<HirDeclaration> {
        // Exact qualified matches first: a dependency's class may share its
        // short name with one from the root package, and the short-name
        // fallback must not let whichever loaded first shadow the other.
        if !self.lookup_index_built {
            self.build_lookup_index()
        }
        match self.declaration_by_qualified.get(name) {
            some(found) => { return some(found) }
            none => {}
        }
        return self.declaration_by_name.get(name)
    }

    fn tree_json_annotation(
        annotations: List<HirAnnotation>, short_name: string
    ) -> Option<HirAnnotation> {
        let wanted: string =
            package_symbol("std.encoding.json", short_name)
        for annotation: HirAnnotation in annotations {
            if annotation.name == wanted { return some(annotation) }
        }
        return none
    }

    fn tree_json_annotation_value(
        annotation: HirAnnotation) -> Option<AstNode> {
        for argument: HirAnnotationArgument in annotation.arguments {
            if argument.name == "value" { return some(argument.syntax) }
        }
        return none
    }

    fn tree_json_field_name(
        declaration: HirDeclaration, field: HirField) -> string {
        match self.tree_json_annotation(field.annotations, "name") {
            some(annotation) => {
                match self.tree_json_annotation_value(annotation) {
                    some(syntax) => { return llvm_unquote(syntax.value) }
                    none => {}
                }
            }
            none => {}
        }
        var naming: string = "exact"
        match self.tree_json_annotation(
                declaration.annotations, "naming") {
            some(annotation) => {
                match self.tree_json_annotation_value(annotation) {
                    some(syntax) => {
                        if syntax.kind == "field" { naming = syntax.value }
                    }
                    none => {}
                }
            }
            none => {}
        }
        let source: Bytes = Bytes.from(field.name)
        var output: Bytes = new Bytes(0)
        if naming == "camel_case" {
            var upper: bool = false
            for index: int in 0..source.len() {
                let byte: int = source.get(index)
                if byte == 95 {
                    upper = true
                } else if upper && byte >= 97 && byte <= 122 {
                    output.push(byte - 32)
                    upper = false
                } else {
                    output.push(byte)
                    upper = false
                }
            }
            return output.to_string()
        }
        if naming == "snake_case" {
            for index: int in 0..source.len() {
                let byte: int = source.get(index)
                if byte >= 65 && byte <= 90 {
                    if index != 0 { output.push(95) }
                    output.push(byte + 32)
                } else {
                    output.push(byte)
                }
            }
            return output.to_string()
        }
        return field.name
    }

    fn tree_json_string(value: string) -> string {
        let source: Bytes = Bytes.from(value)
        let hex: string = "0123456789ABCDEF"
        var output: Bytes = new Bytes(0)
        output.push(34)
        for index: int in 0..source.len() {
            let byte: int = source.get(index)
            if byte == 34 {
                output.push(92)
                output.push(34)
            } else if byte == 92 {
                output.push(92)
                output.push(92)
            } else if byte == 8 {
                output.push(92)
                output.push(98)
            } else if byte == 12 {
                output.push(92)
                output.push(102)
            } else if byte == 10 {
                output.push(92)
                output.push(110)
            } else if byte == 13 {
                output.push(92)
                output.push(114)
            } else if byte == 9 {
                output.push(92)
                output.push(116)
            } else if byte < 32 {
                output.push(92)
                output.push(117)
                output.push(48)
                output.push(48)
                output.push(hex.byte_at(byte / 16))
                output.push(hex.byte_at(byte % 16))
            } else {
                output.push(byte)
            }
        }
        output.push(34)
        return output.to_string()
    }

    fn tree_json_padding(depth: int, indent: int) -> string {
        var output: string = "\n"
        for index: int in 0..(depth * indent) {
            output = "{output} "
        }
        return output
    }

    fn tree_json_value(
        value: TreeValue, depth: int, indent: int
    ) -> Option<string> {
        if value.kind == "bool" {
            return some(if value.bool_data { "true" } else { "false" })
        }
        if value.kind == "int" {
            return some(if value.int_unsigned {
                "{value.uint_data}"
            } else {
                "{value.int_data}"
            })
        }
        if value.kind == "float" {
            let shown: string = "{value.float_data}"
            if shown == "nan" || shown == "inf" || shown == "-inf" ||
               shown == "NaN" || shown == "Infinity" ||
               shown == "-Infinity" {
                return none
            }
            return some(shown)
        }
        if value.kind == "string" {
            return some(self.tree_json_string(value.text))
        }
        if value.kind == "none" {
            return some("null")
        }
        if value.kind == "some" && value.items.len() == 1 {
            return self.tree_json_value(value.items[0], depth, indent)
        }
        if value.kind == "list" {
            var output: string = "["
            for index: int in 0..value.items.len() {
                if index != 0 { output = "{output}," }
                if indent != 0 {
                    output =
                        "{output}{self.tree_json_padding(depth + 1, indent)}"
                }
                match self.tree_json_value(
                        value.items[index], depth + 1, indent) {
                    some(encoded) => { output = "{output}{encoded}" }
                    none => { return none }
                }
            }
            if indent != 0 && value.items.len() != 0 {
                output =
                    "{output}{self.tree_json_padding(depth, indent)}"
            }
            return some("{output}]")
        }
        if value.kind == "record" {
            match self.declaration(value.text) {
                some(declaration) => {
                    var output: string = "\{"
                    var written: int = 0
                    for field: HirField in declaration.fields {
                        if self.tree_json_annotation(
                               field.annotations, "ignore").is_some() {
                            continue
                        }
                        match value.fields.entries.get(field.name) {
                            some(field_value) => {
                                if written != 0 { output = "{output}," }
                                if indent != 0 {
                                    output =
                                        "{output}{self.tree_json_padding(depth + 1, indent)}"
                                }
                                let name: string =
                                    self.tree_json_field_name(
                                        declaration, field)
                                output =
                                    "{output}{self.tree_json_string(name)}:{if indent != 0 { " " } else { "" }}"
                                match self.tree_json_value(
                                        field_value, depth + 1, indent) {
                                    some(encoded) => {
                                        output = "{output}{encoded}"
                                    }
                                    none => { return none }
                                }
                                written += 1
                            }
                            none => { return none }
                        }
                    }
                    if indent != 0 && written != 0 {
                        output =
                            "{output}{self.tree_json_padding(depth, indent)}"
                    }
                    return some("{output}\}")
                }
                none => {}
            }
        }
        return none
    }

    fn tree_json_encode(
        value: TreeValue, indent_text: Option<string>
    ) -> TreeValue {
        var indent: int = 0
        match indent_text {
            some(text) => {
                if text == "  " { indent = 2 } else if text == "    " {
                    indent = 4
                } else {
                    return TreeValue.result_err(
                        TreeValue.error(
                            "pretty indent must be two or four spaces",
                            "invalid"))
                }
            }
            none => {}
        }
        match self.tree_json_value(value, 0, indent) {
            some(encoded) => {
                return TreeValue.result_ok(TreeValue.string(encoded))
            }
            none => {
                return TreeValue.result_err(
                    TreeValue.error(
                        "cannot encode value as JSON", "invalid"))
            }
        }
    }

    fn reflect_base_name(name: string) -> string {
        match name.find("<") {
            some(cut) => { return name.slice(0, cut) }
            none => { return name }
        }
    }

    fn reflect_declaration(name: string) ->
        Option<HirDeclaration> {
        let base: string = self.reflect_base_name(name)
        for declaration: HirDeclaration in
            self.program.declarations {
            if display_symbol(declaration.qualified) == base ||
               declaration.name == base {
                return some(declaration)
            }
        }
        return none
    }

    fn reflect_type_arguments(name: string) -> List<string> {
        var result: List<string> = []
        match name.find("<") {
            some(start) => {
                if !name.ends_with(">") { return move result }
                var depth: int = 0
                var from: int = start + 1
                var index: int = from
                for index < name.len() - 1 {
                    let byte: int = name.byte_at(index)
                    if byte == 60 { depth += 1 }
                    if byte == 62 { depth -= 1 }
                    if byte == 44 && depth == 0 {
                        result.push(
                            name.slice(from, index).trim())
                        from = index + 1
                    }
                    index += 1
                }
                if from < name.len() - 1 {
                    result.push(
                        name.slice(from, name.len() - 1).trim())
                }
            }
            none => {}
        }
        return move result
    }

    fn reflect_collect_fields(
        declaration: HirDeclaration,
        inherited: bool,
        result: List<TreeReflectField>) {
        if inherited {
            for index: int in 0..declaration.relations.len() {
                if index >= declaration.relation_kinds.len() ||
                   declaration.relation_kinds[index] != "extends" {
                    continue
                }
                match self.declaration(
                          declaration.relations[index].name) {
                    some(parent) => {
                        self.reflect_collect_fields(
                            parent, true, result)
                    }
                    none => {}
                }
            }
        }
        for field: HirField in declaration.fields {
            // weak slots are invisible to reflection on both backends
            if field.is_weak { continue }
            var replaced: int = -1
            for index: int in 0..result.len() {
                if result[index].field.name == field.name {
                    replaced = index
                }
            }
            let item: TreeReflectField =
                new TreeReflectField(
                    field, declaration.qualified)
            if inherited && replaced >= 0 {
                result[replaced] = item
            } else {
                result.push(item)
            }
        }
    }

    fn reflect_fields(name: string,
                      inherited: bool) ->
        List<TreeReflectField> {
        var result: List<TreeReflectField> = []
        match self.reflect_declaration(name) {
            some(declaration) => {
                self.reflect_collect_fields(
                    declaration, inherited, result)
            }
            none => {}
        }
        return move result
    }

    fn reflect_collect_methods(
        declaration: HirDeclaration,
        inherited: bool,
        result: List<TreeReflectMethod>) {
        if inherited {
            for index: int in 0..declaration.relations.len() {
                if index >= declaration.relation_kinds.len() ||
                   declaration.relation_kinds[index] != "extends" {
                    continue
                }
                match self.declaration(
                          declaration.relations[index].name) {
                    some(parent) => {
                        self.reflect_collect_methods(
                            parent, true, result)
                    }
                    none => {}
                }
            }
        }
        for function: HirFunction in self.program.functions {
            if function.owner != declaration.qualified ||
               function.name == "init" ||
               function.name == "deinit" {
                continue
            }
            var replaced: int = -1
            for index: int in 0..result.len() {
                if result[index].callable.name == function.name {
                    replaced = index
                }
            }
            let item: TreeReflectMethod =
                new TreeReflectMethod(
                    function, declaration.qualified)
            if inherited && replaced >= 0 {
                result[replaced] = item
            } else {
                result.push(item)
            }
        }
    }

    fn reflect_methods(name: string,
                       inherited: bool) ->
        List<TreeReflectMethod> {
        var result: List<TreeReflectMethod> = []
        match self.reflect_declaration(name) {
            some(declaration) => {
                self.reflect_collect_methods(
                    declaration, inherited, result)
            }
            none => {}
        }
        return move result
    }

    fn reflect_method(name: string,
                      callable: string) ->
        Option<TreeReflectMethod> {
        match self.reflect_declaration(name) {
            some(declaration) => {
                for function: HirFunction in
                    self.program.functions {
                    if function.owner == declaration.qualified &&
                       function.name == callable {
                        return some(new TreeReflectMethod(
                            function, declaration.qualified))
                    }
                }
                for index: int in 0..declaration.relations.len() {
                    if index < declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] == "extends" {
                        match self.reflect_method(
                                  render_hir_type(
                                      declaration.relations[index]),
                                  callable) {
                            some(item) => { return some(item) }
                            none => {}
                        }
                    }
                }
            }
            none => {}
        }
        return none
    }

    fn reflect_callable_flags(function: HirFunction) -> int {
        var flags: int = 0
        if function.is_public { flags = flags | 1 }
        if function.is_static { flags = flags | 2 }
        if function.generics.len() != 0 { flags = flags | 8 }
        if function.is_extern_c { flags = flags | 16 }
        return flags
    }

    fn reflect_parameter_passing(passing: string) -> int {
        if passing == "move" { return 1 }
        if passing == "inout" { return 2 }
        return 0
    }

    fn reflect_function(name: string) -> Option<HirFunction> {
        for function: HirFunction in self.program.functions {
            if function.owner == "" &&
               display_symbol(function.qualified) == name {
                return some(function)
            }
        }
        return none
    }

    fn reflect_subject_annotations(
        kind: int, owner: string,
        member: string, position: int) -> List<HirAnnotation> {
        var result: List<HirAnnotation> = []
        if kind == 1 || kind == 2 || kind == 5 || kind == 8 {
            match self.reflect_declaration(owner) {
                some(declaration) => {
                    if kind == 1 {
                        for annotation: HirAnnotation in
                            declaration.annotations {
                            result.push(annotation)
                        }
                    }
                    for field: HirField in declaration.fields {
                        if kind == 2 && field.name == member {
                            for annotation: HirAnnotation in field.annotations {
                                result.push(annotation)
                            }
                        }
                    }
                    for variant: HirField in declaration.variants {
                        if variant.name != member { continue }
                        if kind == 5 {
                            for annotation: HirAnnotation in variant.annotations {
                                result.push(annotation)
                            }
                        }
                        if kind == 8 && position >= 0 &&
                           position < variant.parameters.len() {
                            for annotation: HirAnnotation in
                                variant.parameters[position].annotations {
                                result.push(annotation)
                            }
                        }
                    }
                }
                none => {}
            }
        } else if kind == 3 || kind == 6 {
            match self.reflect_method(owner, member) {
                some(item) => {
                    if kind == 3 {
                        for annotation: HirAnnotation in
                            item.callable.annotations {
                            result.push(annotation)
                        }
                    }
                    if kind == 6 && position >= 0 &&
                       position < item.callable.parameters.len() {
                        for annotation: HirAnnotation in
                            item.callable.parameters[position].annotations {
                            result.push(annotation)
                        }
                    }
                }
                none => {}
            }
        } else if kind == 4 || kind == 7 {
            match self.reflect_function(owner) {
                some(function) => {
                    if kind == 4 {
                        for annotation: HirAnnotation in function.annotations {
                            result.push(annotation)
                        }
                    }
                    if kind == 7 && position >= 0 &&
                       position < function.parameters.len() {
                        for annotation: HirAnnotation in
                            function.parameters[position].annotations {
                            result.push(annotation)
                        }
                    }
                }
                none => {}
            }
        } else if kind == 9 {
            for declaration: HirAnnotationDeclaration in
                self.program.annotation_declarations {
                if display_symbol(declaration.qualified) == owner {
                    for annotation: HirAnnotation in
                        declaration.annotations {
                        result.push(annotation)
                    }
                }
            }
        }
        var runtime: List<HirAnnotation> = []
        for annotation: HirAnnotation in result {
            if annotation.retention == "runtime" {
                runtime.push(annotation)
            }
        }
        return move runtime
    }

    fn reflect_annotation_kind(type: HirType) -> int {
        let name: string = canonical_hir_name(type.name)
        if name == "bool" { return 0 }
        if hir_is_integer(type) {
            return if tree_integer_unsigned(name) { 2 } else { 1 }
        }
        if hir_is_float(type) { return 3 }
        if name == "decimal" { return 4 }
        if name == "string" { return 5 }
        if name == "List" { return 7 }
        match self.reflect_declaration(render_hir_type(type)) {
            some(declaration) => {
                if declaration.kind == "enum" { return 6 }
            }
            none => {}
        }
        return 8
    }

    fn reflect_annotation_text(value: HirNode) -> string {
        if value.kind == "literal" {
            if canonical_hir_name(value.type.name) == "string" {
                return tree_unquote(value.value)
            }
            return value.value.replace("_", "")
        }
        if value.kind == "unary" && value.value == "-" &&
           value.children.len() == 1 {
            return "-{self.reflect_annotation_text(value.children[0])}"
        }
        if value.kind == "variant" { return value.value }
        return ""
    }

    fn reflect_assignable(wanted: string,
                          actual: string) -> bool {
        if wanted == actual { return true }
        match self.reflect_declaration(actual) {
            some(declaration) => {
                for relation: HirType in
                    declaration.relations {
                    let name: string =
                        render_hir_type(relation)
                    if wanted == name ||
                       self.reflect_assignable(
                           wanted, name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn reflection_builtin(
        node: HirNode,
        arguments: List<TreeValue>) -> TreeValue {
        return self.reflection_builtin_named(
            node, node.value, arguments)
    }

    // Resolve a reflection handle request, or translate a handle-based
    // call back into its string-keyed form and re-enter. Handles are
    // indexes into the parallel handle lists, offset by one so zero can
    // mean unresolved, mirroring the native registry's contract.
    fn reflection_handle_builtin(
        node: HirNode, name: string,
        arguments: List<TreeValue>) -> TreeValue {
        if name == "method_handle" {
            let owner: string = arguments[0].text
            let method_name: string = arguments[1].text
            if method_name == "init" || method_name == "deinit" {
                return TreeValue.integer(0)
            }
            match self.reflect_method(owner, method_name) {
                some(item) => {
                    self.reflect_handle_kinds.push(0)
                    self.reflect_handle_owners.push(
                        display_symbol(item.owner))
                    self.reflect_handle_names.push(method_name)
                    return TreeValue.integer(
                        self.reflect_handle_kinds.len())
                }
                none => { return TreeValue.integer(0) }
            }
        }
        if name == "initializer_handle" {
            let flags: TreeValue = self.reflection_builtin_named(
                node, "initializer_flags", arguments)
            if flags.int_data < 0 { return TreeValue.integer(0) }
            self.reflect_handle_kinds.push(1)
            self.reflect_handle_owners.push(arguments[0].text)
            self.reflect_handle_names.push("")
            return TreeValue.integer(self.reflect_handle_kinds.len())
        }
        if name == "function_handle" {
            let qualified: string = arguments[0].text
            match self.reflect_function(qualified) {
                some(_) => {
                    self.reflect_handle_kinds.push(2)
                    self.reflect_handle_owners.push(qualified)
                    self.reflect_handle_names.push("")
                    return TreeValue.integer(
                        self.reflect_handle_kinds.len())
                }
                none => { return TreeValue.integer(0) }
            }
        }
        let wanted_kind: int =
            if name == "method_call_handle" { 0 }
            else if name == "initializer_call_handle" { 1 }
            else { 2 }
        let handle: int = arguments[0].int_data
        if handle <= 0 || handle > self.reflect_handle_kinds.len() ||
           self.reflect_handle_kinds[handle - 1] != wanted_kind {
            self.reflect_error_code = 1
            self.reflect_error_message = "missing reflected member"
            return TreeValue.integer(0)
        }
        let owner: string = self.reflect_handle_owners[handle - 1]
        if wanted_kind == 0 {
            var rewritten: List<TreeValue> = [
                TreeValue.string(owner),
                TreeValue.string(self.reflect_handle_names[handle - 1]),
                arguments[1], arguments[2], arguments[3], arguments[4]]
            return self.reflection_builtin_named(
                node, "method_call", rewritten)
        }
        var rewritten: List<TreeValue> = [
            TreeValue.string(owner), arguments[1], arguments[2]]
        return self.reflection_builtin_named(
            node,
            if wanted_kind == 1 { "initializer_call" }
            else { "function_call" },
            rewritten)
    }

    fn reflection_builtin_named(
        node: HirNode, name: string,
        arguments: List<TreeValue>) -> TreeValue {
        if name == "method_handle" ||
           name == "initializer_handle" ||
           name == "function_handle" ||
           name == "method_call_handle" ||
           name == "initializer_call_handle" ||
           name == "function_call_handle" {
            return self.reflection_handle_builtin(
                node, name, arguments)
        }
        let type_name: string =
            if arguments.len() == 0 { "" } else {
                arguments[0].text
            }
        if name.starts_with("annotation_type_") {
            if name == "annotation_type_count" {
                return TreeValue.integer(
                    self.program.annotation_declarations.len())
            }
            if name == "annotation_type_at" {
                let index: int = arguments[0].int_data
                if index < 0 ||
                   index >= self.program.annotation_declarations.len() {
                    return TreeValue.string("")
                }
                return TreeValue.string(display_symbol(
                    self.program.annotation_declarations[index].qualified))
            }
            var found: Option<HirAnnotationDeclaration> = none
            for declaration: HirAnnotationDeclaration in
                self.program.annotation_declarations {
                if display_symbol(declaration.qualified) == type_name ||
                   declaration.name == type_name {
                    found = some(declaration)
                }
            }
            match found {
                some(declaration) => {
                    if name == "annotation_type_flags" {
                        var flags: int = 0
                        if declaration.is_public { flags = flags | 1 }
                        if declaration.repeatable { flags = flags | 2 }
                        return TreeValue.integer(flags)
                    }
                    if name == "annotation_type_retention" {
                        return TreeValue.string(declaration.retention)
                    }
                    var targets: List<string> =
                        declaration.targets.keys()
                    targets.sort()
                    if name == "annotation_type_target_count" {
                        return TreeValue.integer(targets.len())
                    }
                    if name == "annotation_type_field_count" {
                        return TreeValue.integer(declaration.fields.len())
                    }
                    let index: int = arguments[1].int_data
                    if name == "annotation_type_target_at" {
                        return TreeValue.string(
                            if index >= 0 && index < targets.len() {
                                targets[index]
                            } else { "" })
                    }
                    if index < 0 || index >= declaration.fields.len() {
                        return if name == "annotation_type_field_name" ||
                                  name == "annotation_type_field_type" {
                            TreeValue.string("")
                        } else { TreeValue.integer(-1) }
                    }
                    let field: HirAnnotationField =
                        declaration.fields[index]
                    if name == "annotation_type_field_name" {
                        return TreeValue.string(field.name)
                    }
                    if name == "annotation_type_field_type" {
                        return TreeValue.string(render_hir_type(field.type))
                    }
                    if name == "annotation_type_field_flags" {
                        return TreeValue.integer(
                            if field.default_value.is_some() { 1 } else { 0 })
                    }
                    if name == "annotation_type_field_default" {
                        match field.default_value {
                            some(value) => {
                                let id: int = self.next_reflect_annotation
                                self.next_reflect_annotation += 1
                                self.reflect_annotation_values[id] =
                                    new TreeReflectAnnotationValue(
                                        "", field.type, value)
                                return TreeValue.integer(id)
                            }
                            none => { return TreeValue.integer(-1) }
                        }
                    }
                }
                none => {
                    return if name == "annotation_type_retention" ||
                              name == "annotation_type_target_at" ||
                              name == "annotation_type_field_name" ||
                              name == "annotation_type_field_type" {
                        TreeValue.string("")
                    } else { TreeValue.integer(-1) }
                }
            }
        }
        if name.starts_with("annotation_") {
            if name == "annotation_count" || name == "annotation_at" {
                let kind: int = arguments[0].int_data
                let owner: string = arguments[1].text
                let member: string = arguments[2].text
                let position: int = arguments[3].int_data
                let annotations: List<HirAnnotation> =
                    self.reflect_subject_annotations(
                        kind, owner, member, position)
                if name == "annotation_count" {
                    return TreeValue.integer(annotations.len())
                }
                let index: int = arguments[4].int_data
                if index < 0 || index >= annotations.len() {
                    return TreeValue.integer(-1)
                }
                let id: int = self.next_reflect_annotation
                self.next_reflect_annotation += 1
                self.reflect_annotations[id] = annotations[index]
                return TreeValue.integer(id)
            }
            let id: int = arguments[0].int_data
            if name == "annotation_name" {
                match self.reflect_annotations.get(id) {
                    some(annotation) => {
                        return TreeValue.string(
                            display_symbol(annotation.name))
                    }
                    none => { return TreeValue.string("") }
                }
            }
            if name == "annotation_argument_count" ||
               name == "annotation_argument_at" {
                match self.reflect_annotations.get(id) {
                    some(annotation) => {
                        if name == "annotation_argument_count" {
                            return TreeValue.integer(
                                annotation.arguments.len())
                        }
                        let index: int = arguments[1].int_data
                        if index < 0 ||
                           index >= annotation.arguments.len() {
                            return TreeValue.integer(-1)
                        }
                        let argument: HirAnnotationArgument =
                            annotation.arguments[index]
                        match argument.value {
                            some(value) => {
                                let value_id: int =
                                    self.next_reflect_annotation
                                self.next_reflect_annotation += 1
                                self.reflect_annotation_values[value_id] =
                                    new TreeReflectAnnotationValue(
                                        argument.name,
                                        argument.type, value)
                                return TreeValue.integer(value_id)
                            }
                            none => { return TreeValue.integer(-1) }
                        }
                    }
                    none => {
                        return if name == "annotation_argument_count" {
                            TreeValue.integer(0)
                        } else { TreeValue.integer(-1) }
                    }
                }
            }
            match self.reflect_annotation_values.get(id) {
                some(value) => {
                    if name == "annotation_argument_name" {
                        return TreeValue.string(value.name)
                    }
                    if name == "annotation_value_kind" {
                        return TreeValue.integer(
                            self.reflect_annotation_kind(value.type))
                    }
                    if name == "annotation_value_type" {
                        return TreeValue.string(
                            render_hir_type(value.type))
                    }
                    if name == "annotation_value_text" {
                        return TreeValue.string(
                            self.reflect_annotation_text(value.value))
                    }
                    if name == "annotation_value_bool" {
                        return TreeValue.boolean(
                            self.reflect_annotation_text(value.value) == "true")
                    }
                    if name == "annotation_value_item_count" {
                        return TreeValue.integer(
                            if self.reflect_annotation_kind(value.type) == 7 {
                                value.value.children.len()
                            } else { 0 })
                    }
                    if name == "annotation_value_item_at" {
                        let index: int = arguments[1].int_data
                        if self.reflect_annotation_kind(value.type) != 7 ||
                           value.type.args.len() != 1 || index < 0 ||
                           index >= value.value.children.len() {
                            return TreeValue.integer(-1)
                        }
                        let child_id: int = self.next_reflect_annotation
                        self.next_reflect_annotation += 1
                        self.reflect_annotation_values[child_id] =
                            new TreeReflectAnnotationValue(
                                "", value.type.args[0],
                                value.value.children[index])
                        return TreeValue.integer(child_id)
                    }
                }
                none => {}
            }
            if name == "annotation_value_bool" {
                return TreeValue.boolean(false)
            }
            if name == "annotation_argument_name" ||
               name == "annotation_value_type" ||
               name == "annotation_value_text" {
                return TreeValue.string("")
            }
            return TreeValue.integer(
                if name == "annotation_value_kind" { 8 } else { 0 })
        }
        if name == "value_type" {
            let handle: int = arguments[0].int_data
            return TreeValue.string(
                self.reflect_value_types.get(handle).or(""))
        }
        if name == "value_clone" {
            let handle: int = arguments[0].int_data
            match self.reflect_values.get(handle) {
                some(value) => {
                    let copy: int = self.next_reflect_value
                    self.next_reflect_value += 1
                    self.reflect_values[copy] =
                        tree_value_copy(value)
                    self.reflect_value_types[copy] =
                        self.reflect_value_types.get(handle).or("")
                    return TreeValue.integer(copy)
                }
                none => { return TreeValue.integer(0) }
            }
        }
        if name == "value_drop" {
            let handle: int = arguments[0].int_data
            self.reflect_values.remove(handle)
            self.reflect_value_types.remove(handle)
            return TreeValue.unit()
        }
        if name == "value_matches" {
            let handle: int = arguments[0].int_data
            let wanted: string = arguments[1].text
            match self.reflect_value_types.get(handle) {
                some(actual) => {
                    return TreeValue.boolean(
                        actual == wanted ||
                        self.reflect_assignable(wanted, actual))
                }
                none => { return TreeValue.boolean(false) }
            }
        }
        if name == "error_code" {
            return TreeValue.integer(self.reflect_error_code)
        }
        if name == "error_message" {
            return TreeValue.string(self.reflect_error_message)
        }
        if name == "initializer_flags" ||
           name == "initializer_parameter_count" {
            match self.reflect_declaration(type_name) {
                some(declaration) => {
                    if (declaration.kind != "class" &&
                        declaration.kind != "struct") ||
                       declaration.generics.len() != 0 ||
                       declaration.is_abstract ||
                       declaration.is_singleton {
                        return TreeValue.integer(-1)
                    }
                    if declaration.kind == "struct" {
                        if name == "initializer_parameter_count" {
                            return TreeValue.integer(
                                declaration.fields.len())
                        }
                        var is_public: bool = declaration.is_public
                        for field: HirField in declaration.fields {
                            is_public = is_public && field.is_public
                        }
                        return TreeValue.integer(
                            if is_public { 1 } else { 0 })
                    }
                    match self.reflect_method(type_name, "init") {
                        some(initializer) => {
                            if name == "initializer_flags" {
                                return TreeValue.integer(
                                    self.reflect_callable_flags(
                                        initializer.callable))
                            }
                            return TreeValue.integer(
                                initializer.callable.parameters.len())
                        }
                        none => {
                            return TreeValue.integer(
                                if name == "initializer_flags" {
                                    if declaration.is_public { 1 } else { 0 }
                                } else { 0 })
                        }
                    }
                }
                none => { return TreeValue.integer(-1) }
            }
        }
        if name == "initializer_parameter_name" ||
           name == "initializer_parameter_type" ||
           name == "initializer_parameter_passing" {
            let index: int = arguments[1].int_data
            match self.reflect_declaration(type_name) {
                some(declaration) => {
                    if declaration.kind == "struct" &&
                       declaration.generics.len() == 0 &&
                       index >= 0 &&
                       index < declaration.fields.len() {
                        let field: HirField =
                            declaration.fields[index]
                        if name == "initializer_parameter_name" {
                            return TreeValue.string(field.name)
                        }
                        if name == "initializer_parameter_type" {
                            return TreeValue.string(
                                render_hir_type(field.type))
                        }
                        return TreeValue.integer(1)
                    }
                }
                none => {}
            }
            match self.reflect_method(type_name, "init") {
                some(item) => {
                    if index >= 0 &&
                       index < item.callable.parameters.len() {
                        let parameter: HirParameter =
                            item.callable.parameters[index]
                        if name == "initializer_parameter_name" {
                            return TreeValue.string(parameter.name)
                        }
                        if name == "initializer_parameter_type" {
                            return TreeValue.string(
                                render_hir_type(parameter.type))
                        }
                        return TreeValue.integer(
                            self.reflect_parameter_passing(
                                parameter.passing))
                    }
                }
                none => {}
            }
            if name == "initializer_parameter_passing" {
                return TreeValue.integer(-1)
            }
            return TreeValue.string("")
        }
        if name == "field_get" || name == "field_set" {
            self.reflect_error_code = 0
            self.reflect_error_message = ""
            let owner: string = arguments[0].text
            let field_name: string = arguments[1].text
            let receiver_handle: int = arguments[2].int_data
            var found: Option<TreeReflectField> = none
            for item: TreeReflectField in
                self.reflect_fields(owner, true) {
                if item.field.name == field_name {
                    found = some(item)
                }
            }
            match found {
                none => {
                    self.reflect_error_code = 1
                    self.reflect_error_message =
                        "missing reflected member"
                    return if name == "field_set" {
                        TreeValue.boolean(false)
                    } else { TreeValue.integer(0) }
                }
                some(item) => {
                    if !item.field.is_public {
                        self.reflect_error_code = 2
                        self.reflect_error_message =
                            "reflected member is not public"
                        return if name == "field_set" {
                            TreeValue.boolean(false)
                        } else { TreeValue.integer(0) }
                    }
                    match self.reflect_values.get(
                              receiver_handle) {
                        none => {
                            self.reflect_error_code = 3
                            self.reflect_error_message =
                                "receiver type does not match"
                        }
                        some(receiver) => {
                            let actual: string =
                                self.reflect_value_types.get(
                                    receiver_handle).or("")
                            if actual != owner &&
                               !self.reflect_assignable(owner, actual) {
                                self.reflect_error_code = 3
                                self.reflect_error_message =
                                    "receiver type does not match"
                            } else if name == "field_get" {
                                match receiver.fields.entries.get(field_name) {
                                    some(value) => {
                                        let handle: int =
                                            self.next_reflect_value
                                        self.next_reflect_value += 1
                                        self.reflect_values[handle] =
                                            tree_value_copy(value)
                                        self.reflect_value_types[handle] =
                                            render_hir_type(item.field.type)
                                        return TreeValue.integer(handle)
                                    }
                                    none => {
                                        self.reflect_error_code = 5
                                        self.reflect_error_message =
                                            "reflected operation is unsupported"
                                    }
                                }
                            } else {
                                let value_handle: int =
                                    arguments[3].int_data
                                let wanted: string =
                                    render_hir_type(item.field.type)
                                let actual_value: string =
                                    self.reflect_value_types.get(
                                        value_handle).or("")
                                if wanted != actual_value &&
                                   !self.reflect_assignable(
                                       wanted, actual_value) {
                                    self.reflect_error_code = 4
                                    self.reflect_error_message =
                                        "reflected value type does not match"
                                } else {
                                    match self.reflect_values.get(
                                              value_handle) {
                                        some(value) => {
                                            receiver.fields.entries[field_name] =
                                                tree_value_copy(value)
                                            return TreeValue.boolean(true)
                                        }
                                        none => {
                                            self.reflect_error_code = 4
                                            self.reflect_error_message =
                                                "reflected value type does not match"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return if name == "field_set" {
                TreeValue.boolean(false)
            } else { TreeValue.integer(0) }
        }
        if name == "initializer_call" || name == "variant_make" {
            self.reflect_error_code = 0
            self.reflect_error_message = ""
            let constructing: bool = name == "initializer_call"
            let owner: string = arguments[0].text
            let variant_name: string =
                if constructing { "" } else { arguments[1].text }
            let address: int =
                if constructing { arguments[1].int_data } else {
                    arguments[2].int_data
                }
            let count: int =
                if constructing { arguments[2].int_data } else {
                    arguments[3].int_data
                }
            match self.reflect_declaration(owner) {
                some(declaration) => {
                    var parameters: List<HirParameter> = []
                    var initializer: Option<HirFunction> = none
                    var selected_variant: Option<HirField> = none
                    if constructing {
                        if (declaration.kind != "class" &&
                            declaration.kind != "struct") ||
                           declaration.generics.len() != 0 ||
                           declaration.is_abstract ||
                           declaration.is_singleton {
                            self.reflect_error_code = 5
                            self.reflect_error_message =
                                "reflected operation is unsupported"
                            return TreeValue.integer(0)
                        }
                        if declaration.kind == "struct" {
                            var is_public: bool = declaration.is_public
                            for field: HirField in declaration.fields {
                                is_public = is_public && field.is_public
                                parameters.push(new HirParameter(
                                    field.name, "move", field.type,
                                    declaration.file,
                                    declaration.line,
                                    declaration.col))
                            }
                            if !is_public {
                                self.reflect_error_code = 2
                                self.reflect_error_message =
                                    "reflected member is not public"
                                return TreeValue.integer(0)
                            }
                        } else {
                            match self.reflect_method(owner, "init") {
                            some(item) => {
                                if !item.callable.is_public {
                                    self.reflect_error_code = 2
                                    self.reflect_error_message =
                                        "reflected member is not public"
                                    return TreeValue.integer(0)
                                }
                                if item.callable.generics.len() != 0 ||
                                   item.callable.is_extern_c ||
                                   !item.callable.has_body {
                                    self.reflect_error_code = 5
                                    self.reflect_error_message =
                                        "reflected operation is unsupported"
                                    return TreeValue.integer(0)
                                }
                                initializer = some(item.callable)
                                for parameter: HirParameter in
                                    item.callable.parameters {
                                    parameters.push(parameter)
                                }
                            }
                            none => {
                                if !declaration.is_public {
                                    self.reflect_error_code = 2
                                    self.reflect_error_message =
                                        "reflected member is not public"
                                    return TreeValue.integer(0)
                                }
                            }
                            }
                        }
                    } else {
                        if declaration.kind != "enum" ||
                           declaration.generics.len() != 0 {
                            self.reflect_error_code = 5
                            self.reflect_error_message =
                                "reflected operation is unsupported"
                            return TreeValue.integer(0)
                        }
                        for variant: HirField in declaration.variants {
                            if variant.name == variant_name {
                                selected_variant = some(variant)
                                for item: HirVariantParameter in
                                    variant.parameters {
                                    parameters.push(new HirParameter(
                                        item.name, "move", item.type,
                                        declaration.file,
                                        declaration.line,
                                        declaration.col))
                                }
                            }
                        }
                        if selected_variant.is_none() {
                            self.reflect_error_code = 1
                            self.reflect_error_message =
                                "missing reflected member"
                            return TreeValue.integer(0)
                        }
                    }
                    if count != parameters.len() {
                        self.reflect_error_code = 6
                        self.reflect_error_message =
                            "wrong reflected argument count"
                        return TreeValue.integer(0)
                    }
                    var handles: List<int> = []
                    if count > 0 {
                        match self.find_memory(address as u64) {
                            some(memory) => {
                                for index: int in 0..count {
                                    handles.push(self.memory_read_value(
                                        node, memory,
                                        (address + index * 8) as u64,
                                        new HirType("int")).int_data)
                                }
                            }
                            none => {
                                self.reflect_error_code = 4
                                self.reflect_error_message =
                                    "reflected value type does not match"
                                return TreeValue.integer(0)
                            }
                        }
                    }
                    var values: List<TreeValue> = []
                    for index: int in 0..count {
                        let handle: int = handles[index]
                        let wanted: string =
                            render_hir_type(parameters[index].type)
                        let actual: string =
                            self.reflect_value_types.get(handle).or("")
                        if actual == "" ||
                           (actual != wanted &&
                            !self.reflect_assignable(wanted, actual)) {
                            self.reflect_error_code = 4
                            self.reflect_error_message =
                                "reflected value type does not match"
                            return TreeValue.integer(0)
                        }
                        match self.reflect_values.get(handle) {
                            some(value) => { values.push(value) }
                            none => {
                                self.reflect_error_code = 4
                                self.reflect_error_message =
                                    "reflected value type does not match"
                                return TreeValue.integer(0)
                            }
                        }
                    }
                    var result: TreeValue = TreeValue.unit()
                    if constructing {
                        if declaration.kind == "struct" {
                            result = new TreeValue("record")
                            result.text = declaration.qualified
                            result.object_id = self.next_object_id
                            self.next_object_id += 1
                            for index: int in 0..declaration.fields.len() {
                                result.fields.entries[
                                    declaration.fields[index].name] =
                                    values[index]
                            }
                        } else {
                            result = self.object_value(declaration.qualified)
                            result.text = declaration.qualified
                            result.object_id = self.next_object_id
                            self.next_object_id += 1
                            self.apply_field_defaults(
                                declaration.qualified, result,
                                new TreeFrame())
                            match initializer {
                                some(function) => {
                                    self.invoke(function, values, some(result))
                                }
                                none => {}
                            }
                        }
                    } else {
                        result = TreeValue.sequence("variant", values)
                        result.text = variant_name
                    }
                    for index: int in 0..count {
                        if !constructing ||
                           parameters[index].passing == "move" {
                            self.reflect_values.remove(handles[index])
                            self.reflect_value_types.remove(handles[index])
                        }
                    }
                    let handle: int = self.next_reflect_value
                    self.next_reflect_value += 1
                    self.reflect_values[handle] = result
                    self.reflect_value_types[handle] = owner
                    return TreeValue.integer(handle)
                }
                none => {
                    self.reflect_error_code = 1
                    self.reflect_error_message =
                        "missing reflected member"
                    return TreeValue.integer(0)
                }
            }
        }
        if name == "function_call" || name == "method_call" {
            self.reflect_error_code = 0
            self.reflect_error_message = ""
            let method_call: bool = name == "method_call"
            let owner: string = if method_call {
                arguments[0].text
            } else { "" }
            let callable_name: string = if method_call {
                arguments[1].text
            } else { arguments[0].text }
            let receiver_handle: int = if method_call {
                arguments[2].int_data
            } else { 0 }
            let address: int = if method_call {
                arguments[3].int_data
            } else { arguments[1].int_data }
            let count: int = if method_call {
                arguments[4].int_data
            } else { arguments[2].int_data }
            let static_call: bool = method_call &&
                arguments[5].bool_data
            var callable: Option<HirFunction> = none
            var receiver: Option<TreeValue> = none
            if method_call {
                match self.reflect_method(owner, callable_name) {
                    some(item) => { callable = some(item.callable) }
                    none => {}
                }
            } else {
                callable = self.reflect_function(callable_name)
            }
            match callable {
                none => {
                    self.reflect_error_code = 1
                    self.reflect_error_message =
                        "missing reflected member"
                    return TreeValue.integer(0)
                }
                some(function) => {
                    if !function.is_public {
                        self.reflect_error_code = 2
                        self.reflect_error_message =
                            "reflected member is not public"
                        return TreeValue.integer(0)
                    }
                    if function.generics.len() != 0 ||
                       function.is_extern_c {
                        self.reflect_error_code = 5
                        self.reflect_error_message =
                            "reflected operation is unsupported"
                        return TreeValue.integer(0)
                    }
                    if method_call &&
                       function.is_static != static_call {
                        self.reflect_error_code = 3
                        self.reflect_error_message =
                            "receiver type does not match"
                        return TreeValue.integer(0)
                    }
                    if count != function.parameters.len() {
                        self.reflect_error_code = 6
                        self.reflect_error_message =
                            "wrong reflected argument count"
                        return TreeValue.integer(0)
                    }
                    if method_call && !static_call {
                        match self.reflect_values.get(receiver_handle) {
                            some(value) => {
                                let actual: string =
                                    self.reflect_value_types.get(
                                        receiver_handle).or("")
                                if actual != owner &&
                                   !self.reflect_assignable(owner, actual) {
                                    self.reflect_error_code = 3
                                    self.reflect_error_message =
                                        "receiver type does not match"
                                    return TreeValue.integer(0)
                                }
                                receiver = some(value)
                                match self.reflect_method(
                                          actual, callable_name) {
                                    some(actual_method) => {
                                        callable = some(
                                            actual_method.callable)
                                    }
                                    none => {}
                                }
                            }
                            none => {
                                self.reflect_error_code = 3
                                self.reflect_error_message =
                                    "receiver type does not match"
                                return TreeValue.integer(0)
                            }
                        }
                    }
                    var handles: List<int> = []
                    if count > 0 {
                        match self.find_memory(address as u64) {
                            some(memory) => {
                                for index: int in 0..count {
                                    handles.push(
                                        self.memory_read_value(
                                            node, memory,
                                            (address + index * 8) as u64,
                                            new HirType("int")).int_data)
                                }
                            }
                            none => {
                                self.reflect_error_code = 4
                                self.reflect_error_message =
                                    "reflected value type does not match"
                                return TreeValue.integer(0)
                            }
                        }
                    }
                    var values: List<TreeValue> = []
                    for index: int in 0..count {
                        let parameter: HirParameter =
                            function.parameters[index]
                        if parameter.passing == "inout" {
                            self.reflect_error_code = 5
                            self.reflect_error_message =
                                "reflected operation is unsupported"
                            return TreeValue.integer(0)
                        }
                        let handle: int = handles[index]
                        let wanted: string =
                            render_hir_type(parameter.type)
                        let actual: string =
                            self.reflect_value_types.get(handle).or("")
                        if actual == "" ||
                           (actual != wanted &&
                            !self.reflect_assignable(wanted, actual)) {
                            self.reflect_error_code = 4
                            self.reflect_error_message =
                                "reflected value type does not match"
                            return TreeValue.integer(0)
                        }
                        match self.reflect_values.get(handle) {
                            some(value) => { values.push(value) }
                            none => {
                                self.reflect_error_code = 4
                                self.reflect_error_message =
                                    "reflected value type does not match"
                                return TreeValue.integer(0)
                            }
                        }
                    }
                    let selected: HirFunction = callable.or(function)
                    let result: TreeValue =
                        self.invoke(selected, values, receiver)
                    if self.failed { return TreeValue.integer(0) }
                    for index: int in 0..count {
                        if selected.parameters[index].passing == "move" {
                            self.reflect_values.remove(handles[index])
                            self.reflect_value_types.remove(handles[index])
                        }
                    }
                    let handle: int = self.next_reflect_value
                    self.next_reflect_value += 1
                    self.reflect_values[handle] = result
                    self.reflect_value_types[handle] =
                        render_hir_type(selected.result)
                    return TreeValue.integer(handle)
                }
            }
        }
        if name == "type_argument_count" {
            return TreeValue.integer(
                self.reflect_type_arguments(type_name).len())
        }
        if name == "type_argument_at" {
            let items: List<string> =
                self.reflect_type_arguments(type_name)
            let index: int = arguments[1].int_data
            return TreeValue.string(
                if index >= 0 && index < items.len() {
                    items[index]
                } else { "" })
        }
        if name == "type_kind" {
            let base: string =
                self.reflect_base_name(type_name)
            if base == "unit" { return TreeValue.integer(0) }
            if base == "bool" { return TreeValue.integer(1) }
            if base == "int" || base == "i8" ||
               base == "i16" || base == "i32" {
                return TreeValue.integer(2)
            }
            if base == "u8" || base == "u16" ||
               base == "u32" || base == "u64" {
                return TreeValue.integer(3)
            }
            if base == "float" || base == "f32" {
                return TreeValue.integer(4)
            }
            if base == "decimal" { return TreeValue.integer(5) }
            if base == "string" { return TreeValue.integer(6) }
            if base == "List" { return TreeValue.integer(12) }
            if base == "Map" || base == "OrderedMap" {
                return TreeValue.integer(13)
            }
            if base == "Option" { return TreeValue.integer(14) }
            if base == "Result" { return TreeValue.integer(15) }
            if base.starts_with("[") { return TreeValue.integer(16) }
            if base == "Slice" { return TreeValue.integer(17) }
            if base == "RawPtr" { return TreeValue.integer(18) }
            if base.starts_with("fn(") { return TreeValue.integer(19) }
            match self.reflect_declaration(type_name) {
                some(declaration) => {
                    if declaration.kind == "class" {
                        return TreeValue.integer(7)
                    }
                    if declaration.kind == "interface" {
                        return TreeValue.integer(8)
                    }
                    if declaration.kind == "struct" {
                        return TreeValue.integer(9)
                    }
                    if declaration.kind == "union" {
                        return TreeValue.integer(10)
                    }
                    if declaration.kind == "enum" {
                        return TreeValue.integer(11)
                    }
                }
                none => {}
            }
            return TreeValue.integer(20)
        }
        if name == "base_type" ||
           name == "interface_count" ||
           name == "interface_at" {
            var bases: List<string> = []
            var interfaces: List<string> = []
            match self.reflect_declaration(type_name) {
                some(declaration) => {
                    for index: int in 0..declaration.relations.len() {
                        let relation: string =
                            render_hir_type(
                                declaration.relations[index])
                        if index < declaration.relation_kinds.len() &&
                           declaration.relation_kinds[index] == "extends" {
                            bases.push(relation)
                        } else {
                            interfaces.push(relation)
                        }
                    }
                }
                none => {}
            }
            if name == "base_type" {
                return TreeValue.string(
                    if bases.len() == 0 { "" } else { bases[0] })
            }
            if name == "interface_count" {
                return TreeValue.integer(interfaces.len())
            }
            let index: int = arguments[1].int_data
            return TreeValue.string(
                if index >= 0 && index < interfaces.len() {
                    interfaces[index]
                } else { "" })
        }
        if name == "is_assignable_from" {
            return TreeValue.boolean(
                self.reflect_assignable(
                    type_name, arguments[1].text))
        }
        if name.starts_with("field_") {
            let inherited: bool =
                arguments.len() > 1 &&
                arguments[1].bool_data
            let fields: List<TreeReflectField> =
                self.reflect_fields(type_name, inherited)
            if name == "field_count" {
                return TreeValue.integer(fields.len())
            }
            let index: int = arguments[2].int_data
            if index < 0 || index >= fields.len() {
                if name == "field_flags" {
                    return TreeValue.integer(0)
                }
                return TreeValue.string("")
            }
            let item: TreeReflectField = fields[index]
            if name == "field_name" {
                return TreeValue.string(item.field.name)
            }
            if name == "field_type" {
                return TreeValue.string(
                    render_hir_type(item.field.type))
            }
            if name == "field_owner" {
                return TreeValue.string(
                    display_symbol(item.owner))
            }
            var flags: int = 0
            if item.field.is_public { flags = flags | 1 }
            if item.field.has_default { flags = flags | 2 }
            return TreeValue.integer(flags)
        }
        if name == "method_count" ||
           name == "method_name" {
            let inherited: bool = arguments[1].bool_data
            let methods: List<TreeReflectMethod> =
                self.reflect_methods(type_name, inherited)
            if name == "method_count" {
                return TreeValue.integer(methods.len())
            }
            let index: int = arguments[2].int_data
            return TreeValue.string(
                if index >= 0 && index < methods.len() {
                    methods[index].callable.name
                } else { "" })
        }
        if name.starts_with("method_") {
            let callable_name: string = arguments[1].text
            match self.reflect_method(type_name, callable_name) {
                some(item) => {
                    if name == "method_flags" {
                        return TreeValue.integer(
                            self.reflect_callable_flags(
                                item.callable))
                    }
                    if name == "method_owner" {
                        return TreeValue.string(
                            display_symbol(item.owner))
                    }
                    if name == "method_result" {
                        return TreeValue.string(
                            render_hir_type(item.callable.result))
                    }
                    if name == "method_parameter_count" {
                        return TreeValue.integer(
                            item.callable.parameters.len())
                    }
                    let index: int = arguments[2].int_data
                    if index < 0 ||
                       index >= item.callable.parameters.len() {
                        if name == "method_parameter_passing" {
                            return TreeValue.integer(-1)
                        }
                        return TreeValue.string("")
                    }
                    let parameter: HirParameter =
                        item.callable.parameters[index]
                    if name == "method_parameter_name" {
                        return TreeValue.string(parameter.name)
                    }
                    if name == "method_parameter_type" {
                        return TreeValue.string(
                            render_hir_type(parameter.type))
                    }
                    return TreeValue.integer(
                        self.reflect_parameter_passing(
                            parameter.passing))
                }
                none => {
                    if name == "method_flags" ||
                       name == "method_parameter_count" ||
                       name == "method_parameter_passing" {
                        return TreeValue.integer(-1)
                    }
                    return TreeValue.string("")
                }
            }
        }
        if name.starts_with("variant_") {
            match self.reflect_declaration(type_name) {
                some(declaration) => {
                    if name == "variant_count" {
                        return TreeValue.integer(
                            declaration.variants.len())
                    }
                    if name == "variant_name" {
                        let index: int = arguments[1].int_data
                        return TreeValue.string(
                            if index >= 0 &&
                               index < declaration.variants.len() {
                                declaration.variants[index].name
                            } else { "" })
                    }
                    let variant_name: string = arguments[1].text
                    for variant: HirField in declaration.variants {
                        if variant.name != variant_name { continue }
                        if name == "variant_parameter_count" {
                            return TreeValue.integer(
                                variant.parameters.len())
                        }
                        let index: int = arguments[2].int_data
                        if index < 0 ||
                           index >= variant.parameters.len() {
                            return TreeValue.string("")
                        }
                        let parameter: HirVariantParameter =
                            variant.parameters[index]
                        if name == "variant_parameter_name" {
                            return TreeValue.string(parameter.name)
                        }
                        return TreeValue.string(
                            render_hir_type(parameter.type))
                    }
                }
                none => {}
            }
            if name == "variant_parameter_count" {
                return TreeValue.integer(-1)
            }
            if name == "variant_count" {
                return TreeValue.integer(0)
            }
            return TreeValue.string("")
        }
        if name.starts_with("function_") {
            match self.reflect_function(type_name) {
                some(item) => {
                    if name == "function_name" {
                        return TreeValue.string(item.name)
                    }
                    if name == "function_result" {
                        return TreeValue.string(
                            render_hir_type(item.result))
                    }
                    if name == "function_flags" {
                        return TreeValue.integer(
                            self.reflect_callable_flags(item))
                    }
                    if name == "function_parameter_count" {
                        return TreeValue.integer(item.parameters.len())
                    }
                    let index: int = arguments[1].int_data
                    if index < 0 || index >= item.parameters.len() {
                        if name == "function_parameter_passing" {
                            return TreeValue.integer(-1)
                        }
                        return TreeValue.string("")
                    }
                    let parameter: HirParameter = item.parameters[index]
                    if name == "function_parameter_name" {
                        return TreeValue.string(parameter.name)
                    }
                    if name == "function_parameter_type" {
                        return TreeValue.string(
                            render_hir_type(parameter.type))
                    }
                    return TreeValue.integer(
                        self.reflect_parameter_passing(
                            parameter.passing))
                }
                none => {
                    if name == "function_flags" ||
                       name == "function_parameter_count" ||
                       name == "function_parameter_passing" {
                        return TreeValue.integer(-1)
                    }
                    return TreeValue.string("")
                }
            }
        }
        if name == "registry_type_count" {
            return TreeValue.integer(
                self.program.declarations.len())
        }
        if name == "registry_type_at" {
            let index: int = arguments[0].int_data
            return TreeValue.string(
                if index >= 0 &&
                   index < self.program.declarations.len() {
                    display_symbol(
                        self.program.declarations[index].qualified)
                } else { "" })
        }
        if name == "registry_function_count" ||
           name == "registry_function_at" {
            var items: List<string> = []
            for item: HirFunction in self.program.functions {
                if item.owner == "" {
                    items.push(display_symbol(item.qualified))
                }
            }
            if name == "registry_function_count" {
                return TreeValue.integer(items.len())
            }
            let index: int = arguments[0].int_data
            return TreeValue.string(
                if index >= 0 && index < items.len() {
                    items[index]
                } else { "" })
        }
        return self.fail(
            node,
            "unknown reflection operation '{name}'")
    }

    fn c_global(name: string) ->
        Option<HirCGlobal> {
        for global: HirCGlobal in
            self.program.c_globals {
            if global.qualified == name ||
               global.name == name {
                return some(global)
            }
        }
        return none
    }

    fn c_global_address(node: HirNode,
                        global: HirCGlobal) -> int {
        if global.is_thread_local {
            var source: string =
                "#include <stdint.h>\n"
            source =
                "{source}extern _Thread_local unsigned char {global.extern_name};\n"
            source =
                "{source}{ffi_export_attribute()}"
            source =
                "{source}void* beans_ffi_bridge(void) \{ return &{global.extern_name}; \}\n"
            let function: HirFunction =
                new HirFunction(
                    global.name, global.qualified, "",
                    false, false,
                    node.file, node.line, node.col)
            let bridge: int =
                self.ffi_bridge(function, source)
            if self.failed { return 0 }
            unsafe {
                return host_dl.call0(bridge)
            }
        }
        match host_dl.global_symbol(
                  global.extern_name) {
            ok(found) => { return found }
            err(error) => {
                let linked: int =
                    self.manifest_symbol_address(
                        global.extern_name)
                if linked != 0 { return linked }
                self.fail(
                    node,
                    "C symbol not found: {global.extern_name}")
                return 0
            }
        }
    }

    fn read_c_global(node: HirNode,
                     global: HirCGlobal) -> TreeValue {
        let address: int =
            self.c_global_address(node, global)
        if self.failed { return TreeValue.unit() }
        let name: string =
            canonical_hir_name(global.type.name)
        unsafe {
            if name == "i8" {
                let pointer: RawPtr<i8> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.signed_integer(
                    pointer.read() as int, 8)
            }
            if name == "i16" {
                let pointer: RawPtr<i16> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.signed_integer(
                    pointer.read() as int, 16)
            }
            if name == "i32" {
                let pointer: RawPtr<i32> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.signed_integer(
                    pointer.read() as int, 32)
            }
            if name == "int" {
                let pointer: RawPtr<i64> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.integer(
                    pointer.read() as int)
            }
            if name == "u8" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read() as u64, 8)
            }
            if name == "u16" {
                let pointer: RawPtr<u16> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read() as u64, 16)
            }
            if name == "u32" {
                let pointer: RawPtr<u32> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read() as u64, 32)
            }
            if name == "u64" {
                let pointer: RawPtr<u64> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.unsigned_integer(
                    pointer.read(), 64)
            }
            if name == "bool" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.boolean(
                    pointer.read() != 0)
            }
            if name == "f32" {
                let pointer: RawPtr<f32> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.floating(
                    pointer.read() as float)
            }
            if name == "float" {
                let pointer: RawPtr<f64> =
                    RawPtr.from_address(
                        address as u64)
                return TreeValue.floating(
                    pointer.read())
            }
            if name == "RawPtr" ||
               name == "CFunctionPtr" {
                let slot: RawPtr<RawPtr<u8> > =
                    RawPtr.from_address(
                        address as u64)
                let pointer: RawPtr<u8> =
                    slot.read()
                let pointer_type: HirType =
                    if name == "CFunctionPtr" &&
                       global.type.args.len() == 1 {
                        global.type.args[0]
                    } else {
                        global.type
                    }
                return TreeValue.host_pointer(
                    pointer.address(), pointer_type)
            }
        }
        return self.fail(
            node,
            "extern C global type {render_hir_type(global.type)} is not in the Beans interpreter yet")
    }

    fn write_c_global(node: HirNode,
                      global: HirCGlobal,
                      value: TreeValue) {
        let address: int =
            self.c_global_address(node, global)
        if self.failed { return }
        let name: string =
            canonical_hir_name(global.type.name)
        unsafe {
            if name == "i8" {
                let pointer: RawPtr<i8> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i8)
                return
            }
            if name == "i16" {
                let pointer: RawPtr<i16> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i16)
                return
            }
            if name == "i32" {
                let pointer: RawPtr<i32> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i32)
                return
            }
            if name == "int" {
                let pointer: RawPtr<i64> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.int_data as i64)
                return
            }
            if name == "u8" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.uint_data as u8)
                return
            }
            if name == "u16" {
                let pointer: RawPtr<u16> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.uint_data as u16)
                return
            }
            if name == "u32" {
                let pointer: RawPtr<u32> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.uint_data as u32)
                return
            }
            if name == "u64" {
                let pointer: RawPtr<u64> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(value.uint_data)
                return
            }
            if name == "bool" {
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    if value.bool_data {
                        1 as u8
                    } else {
                        0 as u8
                    })
                return
            }
            if name == "f32" {
                let pointer: RawPtr<f32> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(
                    value.float_data as f32)
                return
            }
            if name == "float" {
                let pointer: RawPtr<f64> =
                    RawPtr.from_address(
                        address as u64)
                pointer.write(value.float_data)
                return
            }
            if name == "RawPtr" ||
               name == "CFunctionPtr" {
                let slot: RawPtr<RawPtr<u8> > =
                    RawPtr.from_address(
                        address as u64)
                let pointer: RawPtr<u8> =
                    RawPtr.from_address(
                        value.memory_address)
                slot.write(pointer)
                return
            }
        }
        self.fail(
            node,
            "extern C global type {render_hir_type(global.type)} is not in the Beans interpreter yet")
    }

    fn layout(type: HirType) -> LayoutAnswer {
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        return engine.layout_type(type)
    }

    fn find_memory(address: u64) ->
        Option<TreeMemory> {
        for memory: TreeMemory in self.memories {
            let end: u64 =
                memory.base +
                (memory.data.len() as u64)
            if address >= memory.base &&
               address <= end {
                return some(memory)
            }
        }
        return none
    }

    fn allocate_memory(size: int,
                       alignment: int) -> TreeMemory {
        let align: u64 = alignment as u64
        let remainder: u64 =
            self.next_memory_address % align
        if remainder != 0 {
            self.next_memory_address +=
                align - remainder
        }
        let result: TreeMemory =
            new TreeMemory(
                self.next_memory_address,
                size, alignment)
        self.memories.push(result)
        self.next_memory_address +=
            (if size == 0 { 1 } else { size }) as u64
        self.next_memory_address += 64
        return result
    }

    fn memory_contains(memory: TreeMemory,
                       address: u64,
                       width: int) -> bool {
        if memory.freed ||
           address < memory.base {
            return false
        }
        let offset: u64 =
            address - memory.base
        return offset <=
                   (memory.data.len() as u64) &&
               (width as u64) <=
                   (memory.data.len() as u64) -
                   offset
    }

    fn memory_read_uint(memory: TreeMemory,
                        address: u64,
                        width: int) -> u64 {
        let offset: int =
            (address - memory.base) as int
        var result: u64 = 0
        for index: int in 0..width {
            let shift: int =
                if self.program.target.endian ==
                       "little" {
                    index * 8
                } else {
                    (width - index - 1) * 8
                }
            result =
                result |
                ((memory.data.get(offset + index) as u64) <<
                 (shift as u64))
        }
        return result
    }

    fn memory_write_uint(memory: TreeMemory,
                         address: u64,
                         width: int,
                         value: u64) {
        let offset: int =
            (address - memory.base) as int
        for index: int in 0..width {
            let shift: int =
                if self.program.target.endian ==
                       "little" {
                    index * 8
                } else {
                    (width - index - 1) * 8
                }
            memory.data.set(
                offset + index,
                ((value >> (shift as u64)) &
                 (255 as u64)) as int)
        }
    }

    fn memory_write_value(
        node: HirNode, memory: TreeMemory,
        address: u64, type: HirType,
        value: TreeValue) -> bool {
        let answer: LayoutAnswer =
            self.layout(type)
        if !answer.ok ||
           !self.memory_contains(
               memory, address, answer.value.size) {
            self.fail(node, "invalid raw memory write")
            return false
        }
        let name: string =
            canonical_hir_name(type.name)
        if hir_is_integer(type) {
            let bits: int =
                tree_integer_bits(name)
            self.memory_write_uint(
                memory, address, bits / 8,
                if value.int_unsigned {
                    value.uint_data
                } else {
                    value.int_data as u64
                })
            return true
        }
        if name == "bool" {
            self.memory_write_uint(
                memory, address, 1,
                if value.bool_data {
                    1 as u64
                } else {
                    0 as u64
                })
            return true
        }
        if name == "f32" || name == "f64" ||
           name == "float" {
            let bits: int =
                if name == "f32" { 32 } else { 64 }
            self.memory_write_uint(
                memory, address, bits / 8,
                tree_float_bits(
                    value.float_data, bits))
            return true
        }
        if name == "RawPtr" ||
           name == "CFunctionPtr" {
            self.memory_write_uint(
                memory, address,
                self.program.target.pointer_size(),
                value.memory_address)
            return true
        }
        if name == "Slice" ||
           name == "RawSlice" {
            let width: int =
                self.program.target.pointer_size()
            self.memory_write_uint(
                memory, address, width,
                value.memory_address)
            self.memory_write_uint(
                memory,
                address + (width as u64),
                width, value.slice_len as u64)
            return true
        }
        if name == "array" &&
           type.args.len() == 1 {
            let element: LayoutAnswer =
                self.layout(type.args[0])
            if !element.ok { return false }
            for index: int in 0..type.array_length {
                if index < value.items.len() &&
                   !self.memory_write_value(
                       node, memory,
                       address +
                           ((index *
                             element.value.size) as u64),
                       type.args[0],
                       value.items[index]) {
                    return false
                }
            }
            return true
        }
        if name.starts_with("Simd") {
            let element_type: HirType =
                new HirType(
                    tree_simd_element(name))
            let element: LayoutAnswer =
                self.layout(element_type)
            if !element.ok { return false }
            for index: int in 0..value.items.len() {
                if !self.memory_write_value(
                       node, memory,
                       address +
                           ((index *
                             element.value.size) as u64),
                       element_type,
                       value.items[index]) {
                    return false
                }
            }
            return true
        }
        match self.declaration(type.name) {
            some(declaration) => {
                if declaration.kind != "struct" &&
                   declaration.kind != "union" {
                    self.fail(
                        node,
                        "{type.name} cannot be stored in raw memory")
                    return false
                }
                let engine: LayoutEngine =
                    new LayoutEngine(
                        self.program,
                        self.program.target)
                let record: RecordLayoutAnswer =
                    engine.layout_record(declaration)
                if declaration.kind == "union" {
                    match value.bytes_data {
                        some(data) => {
                            let at: int =
                                (address -
                                 memory.base) as int
                            memory.data.copy_from(
                                data, at)
                            return true
                        }
                        none => {}
                    }
                }
                for field: HirField in
                    declaration.fields {
                    match value.fields.entries.get(field.name) {
                        some(field_value) => {
                            match record.offsets.get(
                                    field.name) {
                                some(offset) => {
                                    if !self.memory_write_value(
                                           node, memory,
                                           address +
                                               (offset as u64),
                                           field.type,
                                           field_value) {
                                        return false
                                    }
                                }
                                none => {}
                            }
                        }
                        none => {}
                    }
                }
                return true
            }
            none => {}
        }
        self.fail(
            node,
            "{render_hir_type(type)} cannot be stored in raw memory")
        return false
    }

    fn memory_read_value(
        node: HirNode, memory: TreeMemory,
        address: u64,
        type: HirType) -> TreeValue {
        let answer: LayoutAnswer =
            self.layout(type)
        if !answer.ok ||
           !self.memory_contains(
               memory, address, answer.value.size) {
            return self.fail(
                node, "invalid raw memory read")
        }
        let name: string =
            canonical_hir_name(type.name)
        if hir_is_integer(type) {
            let bits: int =
                tree_integer_bits(name)
            let raw: u64 =
                self.memory_read_uint(
                    memory, address, bits / 8)
            return if tree_integer_unsigned(name) {
                TreeValue.unsigned_integer(
                    raw, bits)
            } else {
                TreeValue.signed_integer(
                    tree_signed_from_bits(raw, bits),
                    bits)
            }
        }
        if name == "bool" {
            return TreeValue.boolean(
                self.memory_read_uint(
                    memory, address, 1) != 0)
        }
        if name == "f32" || name == "f64" ||
           name == "float" {
            let bits: int =
                if name == "f32" { 32 } else { 64 }
            return TreeValue.floating(
                tree_float_from_bits(
                    self.memory_read_uint(
                        memory, address, bits / 8),
                    bits))
        }
        if name == "RawPtr" ||
           name == "CFunctionPtr" {
            let pointer_address: u64 =
                self.memory_read_uint(
                    memory, address,
                    self.program.target.pointer_size())
            let element: HirType =
                if type.args.len() == 1 {
                    type.args[0]
                } else {
                    new HirType("u8")
                }
            if name == "CFunctionPtr" {
                return TreeValue.host_pointer(
                    pointer_address, element)
            }
            match self.find_memory(pointer_address) {
                some(target) => {
                    return TreeValue.raw_pointer(
                        some(target),
                        pointer_address, element)
                }
                none => {
                    return TreeValue.host_pointer(
                        pointer_address, element)
                }
            }
        }
        if name == "Slice" ||
           name == "RawSlice" {
            let width: int =
                self.program.target.pointer_size()
            let pointer_address: u64 =
                self.memory_read_uint(
                    memory, address, width)
            let length: int =
                self.memory_read_uint(
                    memory,
                    address + (width as u64),
                    width) as int
            let element: HirType =
                if type.args.len() == 1 {
                    type.args[0]
                } else {
                    new HirType("u8")
                }
            var pointer: TreeValue =
                TreeValue.host_pointer(
                    pointer_address, element)
            match self.find_memory(pointer_address) {
                some(target) => {
                    pointer = TreeValue.raw_pointer(
                        some(target),
                        pointer_address, element)
                }
                none => {}
            }
            return TreeValue.slice(pointer, length)
        }
        if name == "array" &&
           type.args.len() == 1 {
            let element: LayoutAnswer =
                self.layout(type.args[0])
            var values: List<TreeValue> = []
            for index: int in 0..type.array_length {
                values.push(
                    self.memory_read_value(
                        node, memory,
                        address +
                            ((index *
                              element.value.size) as u64),
                        type.args[0]))
            }
            return TreeValue.sequence(
                "array", move values)
        }
        if name.starts_with("Simd") {
            let element_type: HirType =
                new HirType(
                    tree_simd_element(name))
            let element: LayoutAnswer =
                self.layout(element_type)
            var values: List<TreeValue> = []
            for index: int in
                0..tree_simd_lanes(name) {
                values.push(
                    self.memory_read_value(
                        node, memory,
                        address +
                            ((index *
                              element.value.size) as u64),
                        element_type))
            }
            let result: TreeValue =
                TreeValue.sequence(
                    "simd", move values)
            result.text = name
            return result
        }
        match self.declaration(type.name) {
            some(declaration) => {
                let engine: LayoutEngine =
                    new LayoutEngine(
                        self.program,
                        self.program.target)
                let record: RecordLayoutAnswer =
                    engine.layout_record(declaration)
                let result: TreeValue =
                    new TreeValue("record")
                result.text =
                    declaration.qualified
                if declaration.kind == "union" {
                    let at: int =
                        (address -
                         memory.base) as int
                    result.bytes_data =
                        some(memory.data.slice(
                            at,
                            at +
                                record.answer.value.size))
                }
                for field: HirField in
                    declaration.fields {
                    match record.offsets.get(
                            field.name) {
                        some(offset) => {
                            result.fields.entries[field.name] =
                                self.memory_read_value(
                                    node, memory,
                                    address +
                                        (offset as u64),
                                    field.type)
                        }
                        none => {}
                    }
                }
                return result
            }
            none => {}
        }
        return self.fail(
            node,
            "{render_hir_type(type)} cannot be read from raw memory")
    }

    fn pointer_memory(
        node: HirNode,
        pointer: TreeValue) -> Option<TreeMemory> {
        if pointer.memory_address == 0 {
            self.fail(node, "null raw pointer")
            return none
        }
        match pointer.memory {
            some(memory) => {
                if memory.freed {
                    self.fail(
                        node, "dangling raw pointer")
                    return none
                }
                return some(memory)
            }
            none => {
                match self.find_memory(
                        pointer.memory_address) {
                    some(memory) => {
                        if !memory.freed {
                            return some(memory)
                        }
                    }
                    none => {}
                }
            }
        }
        self.fail(node, "invalid raw pointer")
        return none
    }

    fn host_pointer_read(
        node: HirNode, pointer: TreeValue,
        type: HirType) -> TreeValue {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        unsafe {
            let host: RawPtr<u8> =
                RawPtr.from_address(
                    pointer.memory_address)
            for index: int in 0..answer.value.size {
                temporary.data.set(
                    index,
                    host.offset(index).read() as int)
            }
        }
        return self.memory_read_value(
            node, temporary, 0, type)
    }

    fn host_pointer_write(
        node: HirNode, pointer: TreeValue,
        type: HirType, value: TreeValue) {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        if !self.memory_write_value(
               node, temporary, 0, type, value) {
            return
        }
        unsafe {
            let host: RawPtr<u8> =
                RawPtr.from_address(
                    pointer.memory_address)
            for index: int in 0..answer.value.size {
                host.offset(index).write(
                    temporary.data.get(index) as u8)
            }
        }
    }

    fn write_union_field(
        node: HirNode,
        value: TreeValue,
        declaration: HirDeclaration,
        field_name: string,
        written: TreeValue) {
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        let record: RecordLayoutAnswer =
            engine.layout_record(declaration)
        let memory: TreeMemory =
            new TreeMemory(
                0, record.answer.value.size,
                record.answer.value.align)
        match value.bytes_data {
            some(data) => {
                memory.data.copy_from(data, 0)
            }
            none => {}
        }
        for field: HirField in
            declaration.fields {
            if field.name == field_name {
                self.memory_write_value(
                    node, memory, 0,
                    field.type, written)
                break
            }
        }
        value.bytes_data = some(
            memory.data.slice(0, memory.data.len()))
        for field: HirField in
            declaration.fields {
            value.fields.entries[field.name] =
                self.memory_read_value(
                    node, memory, 0, field.type)
        }
    }

    fn needs_deinit(name: string) -> bool {
        match self.declaration(name) {
            some(declaration) => {
                match self.find_function(
                        "{declaration.qualified}.deinit") {
                    some(function) => {
                        if function.owner ==
                               declaration.qualified {
                            return true
                        }
                    }
                    none => {}
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       self.needs_deinit(
                           declaration.relations[index].name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn is_instance(type_name: string,
                   target_name: string) -> bool {
        if type_name == target_name {
            return true
        }
        match self.declaration(type_name) {
            some(declaration) => {
                if declaration.name == target_name ||
                   declaration.qualified ==
                       target_name {
                    return true
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       self.is_instance(
                           declaration.relations[index].name,
                           target_name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    fn deinit_chain(name: string,
                    object: TreeValue) {
        match self.declaration(name) {
            some(declaration) => {
                match self.find_function(
                        "{declaration.qualified}.deinit") {
                    some(function) => {
                        if function.owner ==
                               declaration.qualified {
                            self.invoke(
                                function, [], some(object))
                            if self.failed { return }
                        }
                    }
                    none => {}
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" {
                        self.deinit_chain(
                            declaration.relations[index].name,
                            object)
                        return
                    }
                }
            }
            none => {}
        }
    }

    // A field whose type is a class or interface reference can hold the
    // last reference to an object with observable teardown, so the order
    // this object releases its fields is program-visible.
    fn chain_frees_objects(name: string) -> bool {
        match self.declaration(name) {
            some(declaration) => {
                for field: HirField in declaration.fields {
                    match self.declaration(field.type.name) {
                        some(field_decl) => {
                            if field_decl.kind == "class" ||
                               field_decl.kind ==
                                   "interface" {
                                return true
                            }
                        }
                        none => {}
                    }
                }
                for index: int in
                    0..declaration.relations.len() {
                    if index <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[index] ==
                           "extends" &&
                       self.chain_frees_objects(
                           declaration.relations[index].name) {
                        return true
                    }
                }
            }
            none => {}
        }
        return false
    }

    // Canonical field release order shared with the stage-0 interpreter
    // and both native backends: the object's own class first, fields in
    // reverse declaration order, then each base class up the chain.
    fn release_fields(name: string,
                      object: TreeValue) {
        match self.declaration(name) {
            some(declaration) => {
                var index: int =
                    declaration.fields.len() - 1
                for index >= 0 {
                    object.fields.entries.remove(
                        declaration.fields[index].name)
                    index -= 1
                }
                for rel: int in
                    0..declaration.relations.len() {
                    if rel <
                           declaration.relation_kinds.len() &&
                       declaration.relation_kinds[rel] ==
                           "extends" {
                        self.release_fields(
                            declaration.relations[rel].name,
                            object)
                        return
                    }
                }
            }
            none => {}
        }
    }

    fn deinit_object(object: TreeValue) {
        if self.failed || object.kind != "object" {
            return
        }
        self.deinit_chain(object.text, object)
        if self.failed {
            return
        }
        self.release_fields(object.text, object)
    }

    fn map_key(map: TreeValue,
               key: TreeValue) -> string {
        for stored: TreeValue in map.map_keys {
            if tree_value_equal(stored, key) {
                return tree_value_key(stored)
            }
        }
        return tree_value_key(key)
    }

    // The body to run for `method` on a value whose runtime type is
    // `type_name`. This walked `extends` only, and only the first one, so a
    // default body an interface supplies was unreachable: a class reaches its
    // interface through `implements`. The call then fell back to whatever the
    // checker had resolved statically, which for a receiver typed as a
    // super-interface is the bodyless declaration — and running that answered
    // a value with no type at all, which failed on the first field read with
    // an empty name in the message. The native backend had always been right
    // here.
    //
    // Breadth-first from the runtime type, so a nearer override wins over the
    // one it overrides, and both relation kinds are followed.
    fn dynamic_method(type_name: string,
                      method: string,
                      dispatch_slot: string) ->
        Option<HirFunction> {
        var pending: List<string> = [type_name]
        var seen: Map<string, bool> = {}
        var cursor: int = 0
        for cursor < pending.len() {
            let current: string = pending[cursor]
            cursor += 1
            if seen.contains_key(current) { continue }
            seen[current] = true
            match self.find_function(
                "{current}.{method}") {
                some(function) => {
                    // a declaration without a body is the interface saying
                    // the method exists, not supplying one to run
                    if function.has_body &&
                       (dispatch_slot == "" ||
                        function.dispatch_slots.contains(
                            dispatch_slot)) {
                        return some(function)
                    }
                }
                none => {}
            }
            match self.declaration(current) {
                some(declaration) => {
                    for relation: HirType in
                        declaration.relations {
                        pending.push(relation.name)
                    }
                }
                none => {}
            }
        }
        return none
    }

    fn local(frame: TreeFrame,
             node: HirNode) -> TreeValue {
        match frame.get(node.binding_id) {
            some(value) => {
                // references can chain — an inout taken on a binding
                // a closure captured reaches the value through the
                // shared cell — so follow them to the end
                var current: TreeValue = value
                for current.kind == "reference" {
                    var advanced: Option<TreeValue> =
                        none
                    match current.reference_frame {
                        some(target) => {
                            advanced = target.get(
                                current.reference_binding)
                        }
                        none => {}
                    }
                    match advanced {
                        some(actual) => {
                            current = actual
                        }
                        none => { return current }
                    }
                }
                return current
            }
            none => {
                return self.fail(
                    node,
                    "unknown name '{node.value}' (binding {node.binding_id})")
            }
        }
    }

    fn interpolation(node: HirNode,
                     frame: TreeFrame) -> string {
        var values: List<TreeValue> = []
        for child: HirNode in node.children {
            values.push(self.expression(child, frame))
            if self.failed { return "" }
        }
        // Walk the raw literal with the escapes still visible, the same
        // way the checker and the LLVM emitter find the pieces. Decoding
        // first would turn \{ into a bare { that looks like a slot.
        let raw: string = node.value
        var start: int = 0
        var end: int = raw.len()
        if raw.len() >= 2 &&
           raw.starts_with("\"") &&
           raw.ends_with("\"") {
            start = 1
            end -= 1
        }
        var result: string = ""
        var index: int = start
        var value_index: int = 0
        for index < end {
            let byte: int = raw.byte_at(index)
            if byte == 92 && index + 1 < end {
                let escaped: int = raw.byte_at(index + 1)
                if escaped == 110 {
                    result = "{result}\n"
                } else if escaped == 114 {
                    result = "{result}\r"
                } else if escaped == 116 {
                    result = "{result}\t"
                } else if escaped == 48 {
                    result = "{result}\0"
                } else {
                    result =
                        "{result}{raw.slice(index + 1, index + 2)}"
                }
                index += 2
                continue
            }
            if byte != 123 {
                result =
                    "{result}{raw.slice(index, index + 1)}"
                index += 1
                continue
            }
            var depth: int = 1
            var in_string: bool = false
            var cursor: int = index + 1
            for cursor < end && depth > 0 {
                let current: int = raw.byte_at(cursor)
                if current == 92 && cursor + 1 < end {
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
            if depth != 0 {
                // The checker stops splitting at an unterminated {,
                // so from here on everything is literal text.
                result =
                    "{result}{tree_unquote(raw.slice(index, end))}"
                index = end
                continue
            }
            if value_index < values.len() {
                let value: TreeValue =
                    values[value_index]
                let segment: string =
                    raw.slice(index + 1, cursor - 1)
                let format: TreeFormatSpec =
                    tree_format_spec(segment)
                var piece: string =
                    tree_value_text(value)
                if format.has &&
                   format.places >= 0 {
                    if value.kind == "float" {
                        piece = host_fmt.float(
                            value.float_data,
                            format.places)
                    } else if value.kind ==
                                  "decimal" {
                        piece = host_fmt.decimal(
                            value.decimal_data,
                            format.places)
                    }
                }
                if format.has &&
                   format.width > 0 {
                    piece =
                        if format.left {
                            host_fmt.pad_right(
                                piece, format.width)
                        } else {
                            host_fmt.pad_left(
                                piece, format.width)
                        }
                }
                result = "{result}{piece}"
                value_index += 1
            }
            index = cursor
        }
        return result
    }

    fn literal(node: HirNode,
               frame: TreeFrame) -> TreeValue {
        let name: string =
            canonical_hir_name(node.type.name)
        if name == "string" {
            if node.children.len() != 0 {
                return TreeValue.string(
                    self.interpolation(node, frame))
            }
            return TreeValue.string(
                tree_unquote(node.value))
        }
        if name == "bool" {
            return TreeValue.boolean(
                node.value == "true")
        }
        if hir_is_integer(node.type) {
            if tree_integer_unsigned(name) {
                return TreeValue.unsigned_integer(
                    tree_parse_unsigned(node.value),
                    tree_integer_bits(name))
            }
            return TreeValue.signed_integer_bits(
                tree_parse_unsigned(node.value),
                tree_integer_bits(name))
        }
        if hir_is_float(node.type) {
            let clean: string =
                node.value.replace("_", "")
            return self.floating_value(
                node.type,
                clean.to_float().or(0.0))
        }
        if name == "decimal" {
            let clean: string =
                node.value.replace("_", "")
            return TreeValue.decimal_value(
                clean.to_decimal().or(0.0))
        }
        return self.fail(
            node,
            "literal type {render_hir_type(node.type)} is not in the Beans interpreter yet")
    }

    fn layout_query(node: HirNode) -> TreeValue {
        if node.children.len() == 0 {
            return self.fail(
                node, "layout query has no type")
        }
        let queried: HirType =
            self.runtime_type(
                node.children[0].type,
                self.current_type_bindings())
        if node.value == "type_of" {
            let result: TreeValue =
                self.object_value(
                    package_symbol("std.reflect", "Type"))
            result.text =
                package_symbol("std.reflect", "Type")
            result.object_id = self.next_object_id
            self.next_object_id += 1
            result.fields.entries["qualified"] =
                TreeValue.string(
                    render_hir_type(queried))
            return result
        }
        let engine: LayoutEngine =
            new LayoutEngine(
                self.program, self.program.target)
        if node.value == "offset_of" {
            match self.declaration(queried.name) {
                some(declaration) => {
                    let record: RecordLayoutAnswer =
                        engine.layout_record(declaration)
                    match record.offsets.get(
                            node.resolved) {
                        some(offset) => {
                            return TreeValue.integer(offset)
                        }
                        none => {
                            return self.fail(
                                node,
                                "{queried.name} has no field '{node.resolved}'")
                        }
                    }
                }
                none => {
                    return self.fail(
                        node,
                        "offset_of needs a struct or union")
                }
            }
        }
        let answer: LayoutAnswer =
            engine.layout_type(queried)
        if !answer.ok {
            return self.fail(node, answer.message)
        }
        return TreeValue.integer(
            if node.value == "size_of" {
                answer.value.size
            } else {
                answer.value.align
            })
    }

    fn truth(node: HirNode,
             value: TreeValue) -> bool {
        if value.kind != "bool" {
            self.fail(node, "condition is not bool")
            return false
        }
        return value.bool_data
    }

    fn integer_binary(node: HirNode,
                      left: TreeValue,
                      right: TreeValue) -> TreeValue {
        if left.int_unsigned ||
           right.int_unsigned {
            let bits: int =
                if left.int_unsigned {
                    left.int_bits
                } else {
                    right.int_bits
                }
            let lhs: u64 = left.uint_data
            let rhs: u64 = right.uint_data
            if node.value == "+" {
                return TreeValue.unsigned_integer(
                    lhs + rhs, bits)
            }
            if node.value == "-" {
                return TreeValue.unsigned_integer(
                    lhs - rhs, bits)
            }
            if node.value == "*" {
                return TreeValue.unsigned_integer(
                    lhs * rhs, bits)
            }
            if node.value == "/" {
                if rhs == 0 {
                    return self.fail(
                        node, "divide by zero")
                }
                return TreeValue.unsigned_integer(
                    lhs / rhs, bits)
            }
            if node.value == "%" {
                if rhs == 0 {
                    return self.fail(
                        node, "modulo by zero")
                }
                return TreeValue.unsigned_integer(
                    lhs % rhs, bits)
            }
            if node.value == "&" {
                return TreeValue.unsigned_integer(
                    lhs & rhs, bits)
            }
            if node.value == "|" {
                return TreeValue.unsigned_integer(
                    lhs | rhs, bits)
            }
            if node.value == "^" {
                return TreeValue.unsigned_integer(
                    lhs ^ rhs, bits)
            }
            if node.value == "<<" {
                // the count is masked by the operand width, not by 64
                return TreeValue.unsigned_integer(
                    lhs << (rhs & ((bits - 1) as u64)), bits)
            }
            if node.value == ">>" {
                return TreeValue.unsigned_integer(
                    lhs >> (rhs & ((bits - 1) as u64)), bits)
            }
            if node.value == "<" {
                return TreeValue.boolean(lhs < rhs)
            }
            if node.value == "<=" {
                return TreeValue.boolean(lhs <= rhs)
            }
            if node.value == ">" {
                return TreeValue.boolean(lhs > rhs)
            }
            if node.value == ">=" {
                return TreeValue.boolean(lhs >= rhs)
            }
            if node.value == ".." ||
               node.value == "..=" {
                let result: TreeValue =
                    TreeValue.sequence(
                        "range",
                        [tree_value_copy(left),
                         tree_value_copy(right)])
                result.bool_data =
                    node.value == "..="
                return result
            }
            return self.fail(
                node,
                "integer operator '{node.value}' is not in the Beans interpreter yet")
        }
        let lhs: int = left.int_data
        let rhs: int = right.int_data
        let bits: int = left.int_bits
        if node.value == "+" {
            return TreeValue.signed_integer(
                lhs + rhs, bits)
        }
        if node.value == "-" {
            return TreeValue.signed_integer(
                lhs - rhs, bits)
        }
        if node.value == "*" {
            return TreeValue.signed_integer(
                lhs * rhs, bits)
        }
        if node.value == "/" {
            if rhs == 0 {
                return self.fail(node, "divide by zero")
            }
            return TreeValue.signed_integer(
                lhs / rhs, bits)
        }
        if node.value == "%" {
            if rhs == 0 {
                return self.fail(node, "modulo by zero")
            }
            return TreeValue.signed_integer(
                lhs % rhs, bits)
        }
        if node.value == "&" {
            return TreeValue.signed_integer(
                lhs & rhs, bits)
        }
        if node.value == "|" {
            return TreeValue.signed_integer(
                lhs | rhs, bits)
        }
        if node.value == "^" {
            return TreeValue.signed_integer(
                lhs ^ rhs, bits)
        }
        if node.value == "<<" {
            // the count is masked by the operand width, not by 64
            return TreeValue.signed_integer(
                lhs << (rhs & (bits - 1)), bits)
        }
        if node.value == ">>" {
            return TreeValue.signed_integer(
                lhs >> (rhs & (bits - 1)), bits)
        }
        if node.value == "==" {
            return TreeValue.boolean(lhs == rhs)
        }
        if node.value == "!=" {
            return TreeValue.boolean(lhs != rhs)
        }
        if node.value == "<" {
            return TreeValue.boolean(lhs < rhs)
        }
        if node.value == "<=" {
            return TreeValue.boolean(lhs <= rhs)
        }
        if node.value == ">" {
            return TreeValue.boolean(lhs > rhs)
        }
        if node.value == ">=" {
            return TreeValue.boolean(lhs >= rhs)
        }
        if node.value == ".." ||
           node.value == "..=" {
            let result: TreeValue =
                TreeValue.sequence(
                "range",
                [tree_value_copy(left),
                 tree_value_copy(right)])
            result.bool_data =
                node.value == "..="
            return result
        }
        return self.fail(
            node,
            "integer operator '{node.value}' is not in the Beans interpreter yet")
    }

    fn binary(node: HirNode,
              frame: TreeFrame) -> TreeValue {
        let left: TreeValue =
            self.expression(node.children[0], frame)
        if left.kind == "propagate" { return left }
        if node.value == "&&" {
            if !self.truth(node, left) {
                return TreeValue.boolean(false)
            }
            return TreeValue.boolean(self.truth(
                node,
                self.expression(node.children[1], frame)))
        }
        if node.value == "||" {
            if self.truth(node, left) {
                return TreeValue.boolean(true)
            }
            return TreeValue.boolean(self.truth(
                node,
                self.expression(node.children[1], frame)))
        }
        let right: TreeValue =
            self.expression(node.children[1], frame)
        if right.kind == "propagate" { return right }
        if node.value == "==" || node.value == "!=" {
            let equal: bool =
                tree_value_equal(left, right)
            return TreeValue.boolean(
                if node.value == "==" {
                    equal
                } else {
                    !equal
                })
        }
        if left.kind == "int" && right.kind == "int" {
            return self.integer_binary(
                node, left, right)
        }
        if left.kind == "simd" &&
           right.kind == "simd" {
            let result: TreeValue =
                tree_value_copy(left)
            for index: int in
                0..left.items.len() {
                result.items[index] =
                    self.simd_scalar(
                        node, node.value,
                        left.items[index],
                        right.items[index])
            }
            return result
        }
        if left.kind == "float" &&
           right.kind == "float" {
            if node.value == "+" {
                return self.floating_value(
                    node.type,
                    left.float_data + right.float_data)
            }
            if node.value == "-" {
                return self.floating_value(
                    node.type,
                    left.float_data - right.float_data)
            }
            if node.value == "*" {
                return self.floating_value(
                    node.type,
                    left.float_data * right.float_data)
            }
            if node.value == "/" {
                return self.floating_value(
                    node.type,
                    left.float_data / right.float_data)
            }
            // the native lowering has had frem all along; without this row
            // the two backends disagreed on a program the checker accepts
            if node.value == "%" {
                return self.floating_value(
                    node.type,
                    tree_float_remainder(
                        left.float_data,
                        right.float_data))
            }
            if node.value == "==" {
                return TreeValue.boolean(
                    left.float_data == right.float_data)
            }
            if node.value == "!=" {
                return TreeValue.boolean(
                    left.float_data != right.float_data)
            }
            if node.value == "<" {
                return TreeValue.boolean(
                    left.float_data < right.float_data)
            }
            if node.value == "<=" {
                return TreeValue.boolean(
                    left.float_data <= right.float_data)
            }
            if node.value == ">" {
                return TreeValue.boolean(
                    left.float_data > right.float_data)
            }
            if node.value == ">=" {
                return TreeValue.boolean(
                    left.float_data >= right.float_data)
            }
        }
        if left.kind == "decimal" &&
           right.kind == "decimal" {
            if node.value == "+" ||
               node.value == "-" ||
               node.value == "*" ||
               node.value == "/" {
                return self.decimal_binary_value(
                    node, node.value,
                    left.decimal_data,
                    right.decimal_data)
            }
            if node.value == "<" {
                return TreeValue.boolean(
                    left.decimal_data <
                    right.decimal_data)
            }
            if node.value == "<=" {
                return TreeValue.boolean(
                    left.decimal_data <=
                    right.decimal_data)
            }
            if node.value == ">" {
                return TreeValue.boolean(
                    left.decimal_data > right.decimal_data)
            }
            if node.value == ">=" {
                return TreeValue.boolean(
                    left.decimal_data >=
                    right.decimal_data)
            }
        }
        if left.kind == "string" &&
           right.kind == "string" {
            if node.value == "+" {
                return TreeValue.string(
                    "{left.text}{right.text}")
            }
            if node.value == "==" {
                return TreeValue.boolean(
                    left.text == right.text)
            }
            if node.value == "!=" {
                return TreeValue.boolean(
                    left.text != right.text)
            }
            if node.value == "<" {
                return TreeValue.boolean(
                    left.text < right.text)
            }
            if node.value == "<=" {
                return TreeValue.boolean(
                    left.text <= right.text)
            }
            if node.value == ">" {
                return TreeValue.boolean(
                    left.text > right.text)
            }
            if node.value == ">=" {
                return TreeValue.boolean(
                    left.text >= right.text)
            }
        }
        if left.kind == "bool" &&
           right.kind == "bool" {
            if node.value == "==" {
                return TreeValue.boolean(
                    left.bool_data == right.bool_data)
            }
            if node.value == "!=" {
                return TreeValue.boolean(
                    left.bool_data != right.bool_data)
            }
        }
        if left.kind == "object" &&
           right.kind == "object" &&
           (node.value == "==" || node.value == "!=") {
            let equal: bool =
                left.object_id == right.object_id
            return TreeValue.boolean(
                if node.value == "==" {
                    equal
                } else {
                    !equal
                })
        }
        return self.fail(
            node,
            "operator '{node.value}' cannot evaluate {left.kind} and {right.kind}")
    }

    fn unary(node: HirNode,
             frame: TreeFrame) -> TreeValue {
        if node.value == "inout" &&
           node.children.len() == 1 &&
           node.children[0].kind == "local" {
            // a binding a closure captured already lives in a shared
            // cell; hand that cell out rather than wrapping the slot
            // again, which would take two dereferences to read
            match frame.get(
                    node.children[0].binding_id) {
                some(current) => {
                    if current.kind == "reference" {
                        return current
                    }
                }
                none => {}
            }
            return TreeValue.reference(
                frame,
                node.children[0].binding_id)
        }
        let value: TreeValue =
            self.expression(node.children[0], frame)
        if value.kind == "propagate" { return value }
        if node.value == "move" || node.value == "+" ||
           node.value == "inout" {
            return value
        }
        if node.value == "!" {
            return TreeValue.boolean(
                !self.truth(node, value))
        }
        if node.value == "-" && value.kind == "int" {
            if value.int_unsigned {
                return TreeValue.unsigned_integer(
                    (0 as u64) - value.uint_data,
                    value.int_bits)
            }
            return TreeValue.signed_integer_bits(
                (0 as u64) - value.uint_data,
                value.int_bits)
        }
        if node.value == "-" && value.kind == "float" {
            return self.floating_value(
                node.type, -value.float_data)
        }
        if node.value == "-" && value.kind == "decimal" {
            return TreeValue.decimal_value(
                -value.decimal_data)
        }
        if node.value == "~" && value.kind == "int" {
            if value.int_unsigned {
                return TreeValue.unsigned_integer(
                    ~value.uint_data,
                    value.int_bits)
            }
            return TreeValue.signed_integer(
                ~value.int_data,
                value.int_bits)
        }
        return self.fail(
            node,
            "unary operator '{node.value}' cannot evaluate {value.kind}")
    }

    fn builtin_call(node: HirNode,
                    arguments: List<TreeValue>) -> TreeValue {
        if node.resolved.starts_with("std.reflection.") {
            return self.reflection_builtin(
                node, arguments)
        }
        if node.resolved == "panic" {
            if arguments.len() != 1 {
                return self.fail(
                    node, "panic needs one string")
            }
            return self.fail(node, arguments[0].text)
        }
        if node.resolved == "std.io.println" ||
           node.resolved == "std.io.print" ||
           node.resolved == "std.io.eprintln" ||
           node.resolved == "std.io.eprint" {
            let shown: string =
                if arguments.len() == 0 {
                    ""
                } else {
                    tree_value_text(arguments[0])
                }
            let to_error: bool =
                node.resolved == "std.io.eprintln" ||
                node.resolved == "std.io.eprint"
            let newline: bool =
                node.resolved == "std.io.println" ||
                node.resolved == "std.io.eprintln"
            match self.debugger {
                some(session) => {
                    // stdout is the protocol stream under the debugger, so
                    // the program's own output travels as an output event.
                    session.program_output(
                        if newline { "{shown}\n" } else { shown },
                        if to_error { "stderr" } else { "stdout" })
                    return TreeValue.unit()
                }
                none => {}
            }
            if node.resolved == "std.io.println" {
                io.println(shown)
            } else if node.resolved ==
                          "std.io.print" {
                io.print(shown)
            } else if node.resolved ==
                          "std.io.eprintln" {
                io.eprintln(shown)
            } else {
                io.eprint(shown)
            }
            return TreeValue.unit()
        }
        if node.resolved == "std.io.read_line" {
            match io.read_line() {
                some(value) => {
                    return TreeValue.option_some(
                        TreeValue.string(value))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if node.resolved == "std.io.read_all" {
            return TreeValue.string(io.read_all())
        }
        if node.resolved == "std.thread.spawn" &&
           arguments.len() == 1 &&
           arguments[0].kind == "closure" {
            let work:
                Mutex<TreeThreadWork> =
                new Mutex(
                    new TreeThreadWork(
                        self.program,
                        tree_spawn_closure(
                            arguments[0]),
                        node,
                        self.singletons))
            let handle: Thread<int> =
                host_thread.spawn(fn() -> int {
                    work.with_lock(
                        fn(state: TreeThreadWork) {
                            state.run()
                        })
                    return 0
                })
            let result: TreeValue =
                new TreeValue("thread")
            result.thread_handle =
                some(handle)
            result.thread_work = some(work)
            return result
        }
        if node.resolved == "std.thread.yield_now" {
            return TreeValue.unit()
        }
        if node.resolved == "std.c.errno" {
            return TreeValue.signed_integer(
                host_c.errno() as int, 32)
        }
        if node.resolved == "std.c.set_errno" &&
           arguments.len() == 1 {
            host_c.set_errno(arguments[0].int_data as i32)
            return TreeValue.unit()
        }
        if node.resolved == "std.os.args" {
            var values: List<TreeValue> = []
            for argument: string in self.arguments {
                values.push(
                    TreeValue.string(argument))
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if node.resolved == "std.os.env" &&
           arguments.len() == 1 {
            match host_os.env(arguments[0].text) {
                some(value) => {
                    return TreeValue.option_some(
                        TreeValue.string(value))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if node.resolved == "std.os.exit" &&
           arguments.len() == 1 {
            host_os.exit(
                arguments[0].int_data)
            return TreeValue.unit()
        }
        if node.resolved ==
               "std.time.monotonic_nanos" {
            return TreeValue.integer(
                host_time.monotonic_nanos())
        }
        if node.resolved == "std.time.wall_nanos" {
            return TreeValue.integer(
                host_time.wall_nanos())
        }
        if node.resolved == "std.time.sleep_nanos" &&
           arguments.len() == 1 {
            host_time.sleep_nanos(
                arguments[0].int_data)
            return TreeValue.unit()
        }
        if node.resolved ==
               "std.time.monotonic_millis" {
            return TreeValue.integer(
                host_time.monotonic_millis())
        }
        if node.resolved == "std.time.wall_millis" {
            return TreeValue.integer(
                host_time.wall_millis())
        }
        if node.resolved == "std.time.sleep_millis" &&
           arguments.len() == 1 {
            host_time.sleep_millis(
                arguments[0].int_data)
            return TreeValue.unit()
        }
        if node.resolved == "std.random.bytes" &&
           arguments.len() == 1 {
            return self.host_bytes_result(
                host_random.bytes(
                    arguments[0].int_data))
        }
        if node.resolved == "std.random.u64" {
            match host_random.u64() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.integer(value))
                }
                err(error) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            error.msg, error.kind))
                }
            }
        }
        if node.resolved == "std.random.below" &&
           arguments.len() == 1 {
            match host_random.below(
                    arguments[0].int_data) {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.integer(value))
                }
                err(error) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            error.msg, error.kind))
                }
            }
        }
        if node.resolved == "std.proc.run" &&
           arguments.len() == 5 {
            match arguments[0].bytes_data {
                some(argv) => {
                    match arguments[1].bytes_data {
                        some(environment) => {
                            match arguments[3].bytes_data {
                                some(stdin_data) => {
                                    return self.host_bytes_list_result(
                                        host_proc.run(
                                            argv, environment,
                                            arguments[2].text,
                                            stdin_data,
                                            arguments[4].int_data))
                                }
                                none => {}
                            }
                        }
                        none => {}
                    }
                }
                none => {}
            }
        }
        if node.resolved == "std.proc.start" &&
           arguments.len() == 3 {
            match arguments[0].bytes_data {
                some(argv) => {
                    match arguments[1].bytes_data {
                        some(environment) => {
                            return self.host_bytes_result(
                                host_proc.start(
                                    argv, environment,
                                    arguments[2].text))
                        }
                        none => {}
                    }
                }
                none => {}
            }
        }
        if node.resolved == "std.proc.status" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_proc.status(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.signal" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_proc.signal(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.write" &&
           arguments.len() == 3 {
            match arguments[1].bytes_data {
                some(data) => {
                    return self.host_int_result(
                        host_proc.write(
                            arguments[0].int_data,
                            data, arguments[2].int_data))
                }
                none => {}
            }
        }
        if node.resolved == "std.proc.write_text" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_proc.write_text(
                    arguments[0].int_data,
                    arguments[1].text,
                    arguments[2].int_data))
        }
        if node.resolved == "std.proc.read" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_proc.read(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.read_to_end" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_proc.read_to_end(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.proc.close" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_proc.close(
                    arguments[0].int_data))
        }
        if node.resolved == "std.sock.listen" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_sock.listen(
                    arguments[0].text,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sock.connect" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_sock.connect(
                    arguments[0].text,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sock.udp_bind" &&
           arguments.len() == 2 {
            return self.host_int_result(
                host_sock.udp_bind(
                    arguments[0].text,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.accept" &&
           arguments.len() == 2 {
            return self.host_int_result(
                host_sock.accept(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.send" &&
           arguments.len() == 3 {
            match arguments[1].bytes_data {
                some(data) => {
                    return self.host_int_result(
                        host_sock.send(
                            arguments[0].int_data,
                            data, arguments[2].int_data))
                }
                none => {}
            }
        }
        if node.resolved == "std.sock.send_text" &&
           arguments.len() == 3 {
            return self.host_int_result(
                host_sock.send_text(
                    arguments[0].int_data,
                    arguments[1].text,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sock.recv" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_sock.recv(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if (node.resolved == "std.sock.recv_exact" ||
            node.resolved == "std.sock.recv_to_end") &&
           arguments.len() == 2 {
            if node.resolved == "std.sock.recv_exact" {
                return self.host_bytes_result(
                    host_sock.recv_exact(
                        arguments[0].int_data,
                        arguments[1].int_data))
            }
            return self.host_bytes_result(
                host_sock.recv_to_end(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.send_to" &&
           arguments.len() == 4 {
            match arguments[1].bytes_data {
                some(data) => {
                    return self.host_int_result(
                        host_sock.send_to(
                            arguments[0].int_data, data,
                            arguments[2].text,
                            arguments[3].int_data))
                }
                none => {}
            }
        }
        if node.resolved == "std.sock.recv_from" &&
           arguments.len() == 2 {
            return self.host_bytes_list_result(
                host_sock.recv_from(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sock.address" &&
           arguments.len() == 2 {
            return self.host_bytes_list_result(
                host_sock.address(
                    arguments[0].int_data,
                    arguments[1].bool_data))
        }
        if node.resolved == "std.sock.shutdown" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_sock.shutdown(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved ==
               "std.sock.set_timeouts" &&
           arguments.len() == 3 {
            return self.host_bool_result(
                host_sock.set_timeouts(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved ==
               "std.sock.set_nonblocking" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_sock.set_nonblocking(
                    arguments[0].int_data,
                    arguments[1].bool_data))
        }
        if node.resolved == "std.sock.close" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_sock.close(
                    arguments[0].int_data))
        }
        if node.resolved == "std.sock.resolve" &&
           arguments.len() == 2 {
            return self.host_strings_result(
                host_sock.resolve(
                    arguments[0].text,
                    arguments[1].int_data))
        }
        if node.resolved == "std.ready.open" {
            return self.host_bytes_result(
                host_ready.open())
        }
        if node.resolved == "std.ready.add" &&
           arguments.len() == 6 {
            return self.host_bool_result(
                host_ready.add(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].bool_data,
                    arguments[4].bool_data,
                    arguments[5].bool_data))
        }
        if node.resolved == "std.ready.remove" &&
           arguments.len() == 2 {
            return self.host_bool_result(
                host_ready.remove(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.ready.wait" &&
           arguments.len() == 4 {
            return self.host_bytes_result(
                host_ready.wait(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].int_data))
        }
        if node.resolved == "std.ready.wait_into" &&
           arguments.len() == 5 {
            match arguments[4].bytes_data {
                some(packed) => {
                    // The compiler that bootstraps this source predates the
                    // wait_into runtime entry point. Keep the interpreter's
                    // behavior correct by copying the old wait result into
                    // the caller's buffer; compiled programs use the new
                    // allocation-free entry point below the ABI.
                    match host_ready.wait(
                            arguments[0].int_data,
                            arguments[1].int_data,
                            arguments[2].int_data,
                            arguments[3].int_data) {
                        ok(source) => {
                            packed.resize(0)
                            packed.append_range(source, 0, source.len())
                            return TreeValue.result_ok(
                                TreeValue.integer(source.get_i64(0)))
                        }
                        err(error) => {
                            return self.host_error(error)
                        }
                    }
                }
                none => {}
            }
        }
        if node.resolved == "std.ready.wake" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_ready.wake(
                    arguments[0].int_data))
        }
        if node.resolved == "std.ready.close" &&
           arguments.len() == 3 {
            return self.host_bool_result(
                host_ready.close(
                    arguments[0].int_data,
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if node.resolved == "std.sig.watch" &&
           arguments.len() == 1 {
            match arguments[0].bytes_data {
                some(signals) => {
                    return self.host_int_result(
                        host_sig.watch(signals))
                }
                none => {}
            }
        }
        if node.resolved == "std.sig.pending" &&
           arguments.len() == 2 {
            return self.host_bytes_result(
                host_sig.pending(
                    arguments[0].int_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.sig.close" &&
           arguments.len() == 2 {
            match arguments[1].bytes_data {
                some(signals) => {
                    return self.host_bool_result(
                        host_sig.close(
                            arguments[0].int_data,
                            signals))
                }
                none => {}
            }
        }
        if node.resolved == "std.sig.raise" &&
           arguments.len() == 1 {
            return self.host_bool_result(
                host_sig.raise(
                    arguments[0].int_data))
        }
        if node.resolved == "std.sig.number" &&
           arguments.len() == 1 {
            return self.host_int_result(
                host_sig.number(
                    arguments[0].text))
        }
        if node.resolved == "std.sig.name" &&
           arguments.len() == 1 {
            return self.host_string_result(
                host_sig.name(
                    arguments[0].int_data))
        }
        if node.resolved.starts_with("std.dl.") {
            unsafe {
                if node.resolved == "std.dl.open" &&
                   arguments.len() == 1 {
                    return self.host_int_result(
                        host_dl.open(
                            arguments[0].text))
                }
                if node.resolved == "std.dl.symbol" &&
                   arguments.len() == 2 {
                    return self.host_int_result(
                        host_dl.symbol(
                            arguments[0].int_data,
                            arguments[1].text))
                }
                if node.resolved ==
                       "std.dl.global_symbol" &&
                   arguments.len() == 1 {
                    return self.host_int_result(
                        host_dl.global_symbol(
                            arguments[0].text))
                }
                if node.resolved == "std.dl.close" &&
                   arguments.len() == 1 {
                    return self.host_bool_result(
                        host_dl.close(
                            arguments[0].int_data))
                }
                if node.resolved == "std.dl.call0" &&
                   arguments.len() == 1 {
                    return TreeValue.integer(
                        host_dl.call0(
                            arguments[0].int_data))
                }
                if node.resolved == "std.dl.call1" &&
                   arguments.len() == 2 {
                    return TreeValue.integer(
                        host_dl.call1(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
                if node.resolved == "std.dl.call2" &&
                   arguments.len() == 3 {
                    return TreeValue.integer(
                        host_dl.call2(
                            arguments[0].int_data,
                            arguments[1].int_data,
                            arguments[2].int_data))
                }
                if node.resolved == "std.dl.call3" &&
                   arguments.len() == 4 {
                    return TreeValue.integer(
                        host_dl.call3(
                            arguments[0].int_data,
                            arguments[1].int_data,
                            arguments[2].int_data,
                            arguments[3].int_data))
                }
                if node.resolved ==
                       "std.dl.call_void0" &&
                   arguments.len() == 1 {
                    host_dl.call_void0(
                        arguments[0].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_void1" &&
                   arguments.len() == 2 {
                    host_dl.call_void1(
                        arguments[0].int_data,
                        arguments[1].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_void2" &&
                   arguments.len() == 3 {
                    host_dl.call_void2(
                        arguments[0].int_data,
                        arguments[1].int_data,
                        arguments[2].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_void3" &&
                   arguments.len() == 4 {
                    host_dl.call_void3(
                        arguments[0].int_data,
                        arguments[1].int_data,
                        arguments[2].int_data,
                        arguments[3].int_data)
                    return TreeValue.unit()
                }
                if node.resolved ==
                       "std.dl.call_f64_1" &&
                   arguments.len() == 2 {
                    return TreeValue.floating(
                        host_dl.call_f64_1(
                            arguments[0].int_data,
                            arguments[1].float_data))
                }
                if node.resolved ==
                       "std.dl.call_f64_i32" &&
                   arguments.len() == 3 {
                    return TreeValue.floating(
                        host_dl.call_f64_i32(
                            arguments[0].int_data,
                            arguments[1].float_data,
                            arguments[2].int_data))
                }
                if node.resolved ==
                       "std.dl.call_f32_1" &&
                   arguments.len() == 2 {
                    return TreeValue.floating(
                        host_dl.call_f32_1(
                            arguments[0].int_data,
                            arguments[1].float_data))
                }
                if node.resolved ==
                       "std.dl.call_f32_i32" &&
                   arguments.len() == 3 {
                    return TreeValue.floating(
                        host_dl.call_f32_i32(
                            arguments[0].int_data,
                            arguments[1].float_data,
                            arguments[2].int_data))
                }
            }
        }
        if node.resolved.starts_with("std.target.") {
            let target: TargetDescription =
                self.program.target
            if node.value == "triple" {
                return TreeValue.string(target.triple)
            }
            if node.value == "arch" {
                return TreeValue.string(target.arch)
            }
            if node.value == "os" {
                return TreeValue.string(target.os)
            }
            if node.value == "env" {
                return TreeValue.string(target.env)
            }
            if node.value == "object_format" {
                return TreeValue.string(
                    target.object_format)
            }
            if node.value == "endian" {
                return TreeValue.string(target.endian)
            }
            if node.value == "pointer_bits" {
                return TreeValue.integer(
                    target.pointer_bits)
            }
            if node.value == "pointer_size" {
                return TreeValue.integer(
                    target.pointer_size())
            }
            if node.value == "stack_align" {
                return TreeValue.integer(
                    target.stack_align)
            }
            if node.value == "max_simd_bits" {
                return TreeValue.integer(
                    target.max_simd_bits())
            }
        }
        if node.resolved == "std.cpu.has" &&
           arguments.len() == 1 {
            return TreeValue.boolean(
                host_cpu.has_name(
                    arguments[0].text))
        }
        if node.resolved == "std.cpu.has_name" &&
           arguments.len() == 1 {
            return TreeValue.boolean(
                host_cpu.has_name(
                    arguments[0].text))
        }
        if node.resolved == "std.asm.value" &&
           arguments.len() == 3 {
            // The checker only accepts templates whose meaning is known.
            // Current value rows are identity moves, so the reference
            // interpreter returns the already-evaluated input.
            return arguments[2]
        }
        if node.resolved == "std.asm.run" &&
           arguments.len() == 2 {
            // Current run rows are ordering barriers. This interpreter
            // executes one step at a time, so that order already holds.
            return TreeValue.unit()
        }
        if (node.resolved == "std.fmt.pad_left" ||
            node.resolved == "std.fmt.pad_right") &&
           arguments.len() == 2 {
            return TreeValue.string(
                if node.value == "pad_left" {
                    host_fmt.pad_left(
                        arguments[0].text,
                        arguments[1].int_data)
                } else {
                    host_fmt.pad_right(
                        arguments[0].text,
                        arguments[1].int_data)
                })
        }
        if node.resolved == "std.fmt.float" &&
           arguments.len() == 2 {
            return TreeValue.string(
                host_fmt.float(
                    arguments[0].float_data,
                    arguments[1].int_data))
        }
        if node.resolved == "std.fmt.decimal" &&
           arguments.len() == 2 {
            return TreeValue.string(
                host_fmt.decimal(
                    arguments[0].decimal_data,
                    arguments[1].int_data))
        }
        if node.resolved.starts_with(
               "std.intrinsic.") {
            unsafe {
                if node.value == "popcount" {
                    return TreeValue.integer(
                        host_intrinsic.popcount(
                            arguments[0].int_data))
                }
                if node.value == "leading_zeros" {
                    return TreeValue.integer(
                        host_intrinsic.leading_zeros(
                            arguments[0].int_data))
                }
                if node.value == "trailing_zeros" {
                    return TreeValue.integer(
                        host_intrinsic.trailing_zeros(
                            arguments[0].int_data))
                }
                if node.value == "bswap16" {
                    return TreeValue.integer(
                        host_intrinsic.bswap16(
                            arguments[0].int_data))
                }
                if node.value == "bswap32" {
                    return TreeValue.integer(
                        host_intrinsic.bswap32(
                            arguments[0].int_data))
                }
                if node.value == "bswap64" {
                    return TreeValue.integer(
                        host_intrinsic.bswap64(
                            arguments[0].int_data))
                }
                if node.value == "rotate_left" {
                    return TreeValue.integer(
                        host_intrinsic.rotate_left(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
                if node.value == "rotate_right" {
                    return TreeValue.integer(
                        host_intrinsic.rotate_right(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
                if node.value == "sqrt" {
                    return TreeValue.floating(
                        host_intrinsic.sqrt(
                            arguments[0].float_data))
                }
                if node.value == "sqrt32" {
                    let wide: float =
                        arguments[0].float_data
                    let input: f32 = wide as f32
                    let value: f32 =
                        host_intrinsic.sqrt32(input)
                    return TreeValue.floating(
                        value as float)
                }
                if node.value == "fma" {
                    return TreeValue.floating(
                        host_intrinsic.fma(
                            arguments[0].float_data,
                            arguments[1].float_data,
                            arguments[2].float_data))
                }
                if node.value == "fma32" {
                    let first_wide: float =
                        arguments[0].float_data
                    let second_wide: float =
                        arguments[1].float_data
                    let third_wide: float =
                        arguments[2].float_data
                    let first: f32 =
                        first_wide as f32
                    let second: f32 =
                        second_wide as f32
                    let third: f32 =
                        third_wide as f32
                    let value: f32 =
                        host_intrinsic.fma32(
                            first, second, third)
                    return TreeValue.floating(
                        value as float)
                }
                if node.value == "crc32c" {
                    return TreeValue.integer(
                        tree_crc32c_step(
                            arguments[0].int_data,
                            arguments[1].int_data))
                }
            }
            if node.value == "prefetch" ||
               node.value == "spin_hint" {
                return TreeValue.unit()
            }
        }
        return self.fail(
            node,
            "builtin call '{node.resolved}' is not in the Beans interpreter yet")
    }

    fn bytes_method(node: HirNode,
                    receiver: TreeValue,
                    arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "bytes" {
            return none
        }
        match receiver.bytes_data {
            some(data) => {
                return self.bytes_method_data(
                    node, receiver, arguments, data)
            }
            none => { return none }
        }
    }

    fn bytes_method_data(node: HirNode,
                         receiver: TreeValue,
                         arguments: List<TreeValue>,
                         data: Bytes) -> Option<TreeValue> {
        if node.value == "as_ptr" {
            var address: u64 = 0
            unsafe {
                address = data.as_ptr().address()
            }
            return some(TreeValue.host_pointer(
                address, new HirType("u8")))
        }
        if node.value == "len" {
            return some(
                TreeValue.integer(data.len()))
        }
        if node.value == "reserve" &&
           arguments.len() == 2 {
            data.reserve(arguments[1].int_data)
            return some(TreeValue.unit())
        }
        if node.value == "resize" &&
           arguments.len() == 2 {
            data.resize(arguments[1].int_data)
            return some(TreeValue.unit())
        }
        if node.value == "fill" &&
           arguments.len() == 2 {
            data.fill(arguments[1].int_data)
            return some(TreeValue.unit())
        }
        if node.value == "append_int_text" &&
           arguments.len() == 2 {
            data.append_string("{arguments[1].int_data}")
            return some(TreeValue.unit())
        }
        if node.value == "push" &&
           arguments.len() == 2 {
            data.push(arguments[1].int_data)
            return some(TreeValue.unit())
        }
        if (node.value == "get" ||
            node.value == "get_u8") &&
           arguments.len() == 2 {
            let offset: int = arguments[1].int_data
            if offset < 0 || offset >= data.len() {
                self.fail_at(
                    node,
                    node.col,
                    "byte index {offset} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            return some(TreeValue.integer(
                if node.value == "get" {
                    data.get(offset)
                } else {
                    data.get_u8(offset)
                }))
        }
        if node.value == "set" &&
           arguments.len() == 3 {
            let offset: int = arguments[1].int_data
            if offset < 0 || offset >= data.len() {
                self.fail_at(
                    node,
                    node.col,
                    "byte index {offset} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            data.set(offset, arguments[2].int_data)
            return some(TreeValue.unit())
        }
        var width: int = 0
        if node.value == "get_u16" ||
           node.value == "put_u16" {
            width = 2
        } else if node.value == "get_u32" ||
                  node.value == "put_u32" {
            width = 4
        } else if node.value == "get_u64" ||
                  node.value == "get_i64" ||
                  node.value == "put_u64" ||
                  node.value == "put_i64" {
            width = 8
        } else if node.value == "put_u8" {
            width = 1
        }
        if width != 0 && arguments.len() >= 2 {
            let offset: int = arguments[1].int_data
            if offset < 0 || width > data.len() ||
               offset > data.len() - width {
                let operation: string =
                    if node.value.starts_with("get") {
                        "read"
                    } else {
                        "write"
                    }
                let word: string =
                    if node.value.ends_with("_u8") {
                        "u8"
                    } else {
                        node.value.slice(
                            node.value.len() - 3,
                            node.value.len())
                    }
                self.fail_at(
                    node,
                    node.col,
                    "{word} {operation} at {offset} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            if node.value == "get_u16" {
                return some(TreeValue.integer(
                    data.get_u16(offset)))
            }
            if node.value == "get_u32" {
                return some(TreeValue.integer(
                    data.get_u32(offset)))
            }
            if node.value == "get_u64" {
                return some(TreeValue.integer(
                    data.get_u64(offset)))
            }
            if node.value == "get_i64" {
                return some(TreeValue.integer(
                    data.get_i64(offset)))
            }
            let value: int = arguments[2].int_data
            if node.value == "put_u8" {
                data.put_u8(offset, value)
            } else if node.value == "put_u16" {
                data.put_u16(offset, value)
            } else if node.value == "put_u32" {
                data.put_u32(offset, value)
            } else if node.value == "put_u64" {
                data.put_u64(offset, value)
            } else {
                data.put_i64(offset, value)
            }
            return some(TreeValue.unit())
        }
        if node.value == "slice" &&
           arguments.len() == 3 {
            let start: int = arguments[1].int_data
            let end: int = arguments[2].int_data
            if start < 0 || end < start ||
               end > data.len() {
                self.fail_at(
                    node,
                    node.col,
                    "byte slice {start}..{end} out of range (len {data.len()})")
                return some(TreeValue.unit())
            }
            return some(TreeValue.bytes(
                data.slice(start, end)))
        }
        if node.value == "copy_from" &&
           arguments.len() == 3 {
            match arguments[1].bytes_data {
                some(source) => {
                    data.copy_from(
                        source, arguments[2].int_data)
                    return some(TreeValue.unit())
                }
                none => {}
            }
        }
        if node.value == "append" &&
           arguments.len() == 2 {
            match arguments[1].bytes_data {
                some(source) => {
                    data.append(source)
                    return some(TreeValue.unit())
                }
                none => {}
            }
        }
        if node.value == "append_string" &&
           arguments.len() == 2 {
            data.append_string(arguments[1].text)
            return some(TreeValue.unit())
        }
        if node.value == "append_i64" &&
           arguments.len() == 2 {
            data.append_i64(arguments[1].int_data)
            return some(TreeValue.unit())
        }
        if node.value == "append_range" &&
           arguments.len() == 4 {
            match arguments[1].bytes_data {
                some(source) => {
                    data.append_range(
                        source,
                        arguments[2].int_data,
                        arguments[3].int_data)
                    return some(TreeValue.unit())
                }
                none => {}
            }
        }
        if node.value == "to_string_until_nul" {
            return some(TreeValue.string(
                data.to_string_until_nul()))
        }
        if node.value == "to_string" {
            return some(TreeValue.string(
                data.to_string()))
        }
        if node.value == "append_uvarint" &&
           arguments.len() == 2 {
            data.append_uvarint(arguments[1].int_data)
            return some(TreeValue.unit())
        }
        if node.value == "get_uvarint" &&
           arguments.len() == 2 {
            return some(TreeValue.integer(
                data.get_uvarint(
                    arguments[1].int_data)))
        }
        if node.value == "crc32" &&
           arguments.len() == 3 {
            return some(TreeValue.integer(
                data.crc32(
                    arguments[1].int_data,
                    arguments[2].int_data) as int))
        }
        return none
    }

    fn simd_scalar(node: HirNode,
                   operation: string,
                   left: TreeValue,
                   right: TreeValue) -> TreeValue {
        if left.kind == "int" &&
           right.kind == "int" {
            if operation == "min" {
                return if tree_value_less(left, right) {
                    left
                } else {
                    right
                }
            }
            if operation == "max" {
                return if tree_value_less(left, right) {
                    right
                } else {
                    left
                }
            }
            let binary: HirNode =
                new HirNode(
                    "binary", operation,
                    node.type, node.file,
                    node.line, node.col)
            return self.integer_binary(
                binary, left, right)
        }
        if left.kind == "float" &&
           right.kind == "float" {
            if operation == "add" ||
               operation == "+" {
                return TreeValue.floating(
                    left.float_data +
                    right.float_data)
            }
            if operation == "sub" ||
               operation == "-" {
                return TreeValue.floating(
                    left.float_data -
                    right.float_data)
            }
            if operation == "mul" ||
               operation == "*" {
                return TreeValue.floating(
                    left.float_data *
                    right.float_data)
            }
            if operation == "div" ||
               operation == "/" {
                return TreeValue.floating(
                    left.float_data /
                    right.float_data)
            }
            if operation == "min" {
                if left.float_data <
                   right.float_data {
                    return TreeValue.floating(
                        left.float_data)
                }
                return TreeValue.floating(
                    right.float_data)
            }
            if operation == "max" {
                if right.float_data <
                   left.float_data {
                    return TreeValue.floating(
                        left.float_data)
                }
                return TreeValue.floating(
                    right.float_data)
            }
            if operation == "gt" ||
               operation == ">" {
                return TreeValue.boolean(
                    right.float_data <
                    left.float_data)
            }
            if operation == "ge" ||
               operation == ">=" {
                return TreeValue.boolean(
                    right.float_data <=
                    left.float_data)
            }
            if operation == "lt" ||
               operation == "<" {
                return TreeValue.boolean(
                    left.float_data <
                    right.float_data)
            }
            if operation == "le" ||
               operation == "<=" {
                return TreeValue.boolean(
                    left.float_data <=
                    right.float_data)
            }
            if operation == "eq" ||
               operation == "==" {
                return TreeValue.boolean(
                    left.float_data ==
                    right.float_data)
            }
        }
        return self.fail(
            node,
            "SIMD scalar operation '{operation}' cannot evaluate {left.kind}")
    }

    fn simd_method(node: HirNode,
                   receiver: TreeValue,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "simd" {
            return none
        }
        if (node.value == "store" ||
            node.value == "store_unaligned") &&
           arguments.len() == 2 {
            let pointer: TreeValue =
                arguments[1]
            if pointer.memory_address == 0 {
                self.fail(
                    node, "null SIMD store")
                return some(TreeValue.unit())
            }
            let vector_type: HirType =
                node.children[0].type
            let vector: LayoutAnswer =
                self.layout(vector_type)
            if node.value == "store" &&
               pointer.memory_address %
                   (vector.value.size as u64) != 0 {
                self.fail(
                    node,
                    "unaligned SIMD store — use store_unaligned")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, pointer) {
                some(memory) => {
                    self.memory_write_value(
                        node, memory,
                        pointer.memory_address,
                        vector_type, receiver)
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "lane_count" {
            return some(TreeValue.integer(
                receiver.items.len()))
        }
        if node.value == "lane" &&
           arguments.len() == 2 {
            let lane: int = arguments[1].int_data
            if lane < 0 ||
               lane >= receiver.items.len() {
                self.fail_at(
                    node,
                    node.col,
                    "SIMD lane out of range (lanes {receiver.items.len()})")
                return some(TreeValue.unit())
            }
            return some(tree_value_copy(
                receiver.items[lane]))
        }
        if node.value == "with_lane" &&
           arguments.len() == 3 {
            let lane: int = arguments[1].int_data
            if lane < 0 ||
               lane >= receiver.items.len() {
                self.fail_at(
                    node,
                    node.col,
                    "SIMD lane out of range (lanes {receiver.items.len()})")
                return some(TreeValue.unit())
            }
            let result: TreeValue =
                tree_value_copy(receiver)
            result.items[lane] =
                tree_value_copy(arguments[2])
            return some(result)
        }
        if node.value == "sum" ||
           node.value == "product" {
            if receiver.items.len() == 0 {
                return some(TreeValue.integer(0))
            }
            var result: TreeValue =
                tree_value_copy(receiver.items[0])
            for index: int in
                1..receiver.items.len() {
                result = self.simd_scalar(
                    node,
                    if node.value == "sum" {
                        "+"
                    } else {
                        "*"
                    },
                    result,
                    receiver.items[index])
            }
            return some(result)
        }
        if node.value == "any_true" ||
           node.value == "all_true" {
            var answer: bool =
                node.value == "all_true"
            for lane: TreeValue in receiver.items {
                let set: bool =
                    if lane.kind == "bool" {
                        lane.bool_data
                    } else if lane.kind == "int" {
                        lane.uint_data != 0
                    } else {
                        lane.float_data != 0.0
                    }
                if node.value == "any_true" &&
                   set {
                    answer = true
                }
                if node.value == "all_true" &&
                   !set {
                    answer = false
                }
            }
            return some(TreeValue.boolean(answer))
        }
        if node.value == "bit_not" {
            let result: TreeValue =
                tree_value_copy(receiver)
            for index: int in
                0..result.items.len() {
                let lane: TreeValue =
                    result.items[index]
                result.items[index] =
                    if lane.int_unsigned {
                        TreeValue.unsigned_integer(
                            ~lane.uint_data,
                            lane.int_bits)
                    } else {
                        TreeValue.signed_integer(
                            ~lane.int_data,
                            lane.int_bits)
                    }
            }
            return some(result)
        }
        if node.value == "select" &&
           arguments.len() == 3 {
            let yes: TreeValue = arguments[1]
            let no: TreeValue = arguments[2]
            let result: TreeValue =
                tree_value_copy(yes)
            for index: int in
                0..receiver.items.len() {
                let mask: TreeValue =
                    receiver.items[index]
                let selected: bool =
                    if mask.kind == "bool" {
                        mask.bool_data
                    } else {
                        mask.uint_data != 0
                    }
                result.items[index] =
                    tree_value_copy(
                        if selected {
                            yes.items[index]
                        } else {
                            no.items[index]
                        })
            }
            return some(result)
        }
        let lane_wise: bool =
            node.value == "add" ||
            node.value == "sub" ||
            node.value == "mul" ||
            node.value == "div" ||
            node.value == "min" ||
            node.value == "max" ||
            node.value == "gt" ||
            node.value == "ge" ||
            node.value == "lt" ||
            node.value == "le" ||
            node.value == "eq" ||
            node.value == "bit_or" ||
            node.value == "bit_and" ||
            node.value == "bit_xor"
        if lane_wise &&
           arguments.len() == 2 {
            let other: TreeValue = arguments[1]
            let result: TreeValue =
                tree_value_copy(receiver)
            var operation: string = node.value
            if operation == "add" { operation = "+" }
            if operation == "sub" { operation = "-" }
            if operation == "mul" { operation = "*" }
            if operation == "div" { operation = "/" }
            if operation == "bit_or" { operation = "|" }
            if operation == "bit_and" { operation = "&" }
            if operation == "bit_xor" { operation = "^" }
            if operation == "gt" { operation = ">" }
            if operation == "ge" { operation = ">=" }
            if operation == "lt" { operation = "<" }
            if operation == "le" { operation = "<=" }
            if operation == "eq" { operation = "==" }
            for index: int in
                0..receiver.items.len() {
                result.items[index] =
                    self.simd_scalar(
                        node, operation,
                        receiver.items[index],
                        other.items[index])
            }
            return some(result)
        }
        if (node.value == "shl" ||
            node.value == "shr") &&
           arguments.len() == 2 {
            let result: TreeValue =
                tree_value_copy(receiver)
            let shift: TreeValue = arguments[1]
            let width: int =
                if receiver.items.len() == 0 {
                    0
                } else {
                    receiver.items[0].int_bits
                }
            if shift.int_data < 0 ||
               shift.int_data >= width {
                self.fail_at(
                    node,
                    node.col,
                    "SIMD shift outside 0..{width - 1}")
                return some(TreeValue.unit())
            }
            for index: int in
                0..receiver.items.len() {
                result.items[index] =
                    self.simd_scalar(
                        node,
                        if node.value == "shl" {
                            "<<"
                        } else {
                            ">>"
                        },
                        receiver.items[index],
                        shift)
            }
            return some(result)
        }
        return none
    }

    fn host_error(error: Error) -> TreeValue {
        return TreeValue.result_err(
            TreeValue.error(
                error.msg, error.kind))
    }

    fn host_bool_result(
        result: Result<bool>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.boolean(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_int_result(
        result: Result<int>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.integer(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_bytes_result(
        move result: Result<Bytes>) -> TreeValue {
        match self.take_host_bytes_result(
                move result) {
            ok(value) => {
                return value
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn take_host_bytes_result(
        move result: Result<Bytes>) -> Result<TreeValue> {
        let value: Bytes = (move result)?
        return ok(TreeValue.result_ok(
            TreeValue.bytes(move value)))
    }

    fn host_bytes_list_result(
        move result: Result<List<Bytes>>) -> TreeValue {
        match self.take_host_bytes_list_result(
                move result) {
            ok(value) => {
                return value
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn take_host_bytes_list_result(
        move result: Result<List<Bytes>>) -> Result<TreeValue> {
        let source: List<Bytes> = (move result)?
        var values: List<TreeValue> = []
        for source.len() > 0 {
            let value: Bytes = source.remove(0)
            values.push(TreeValue.bytes(move value))
        }
        return ok(TreeValue.result_ok(
            TreeValue.sequence("list", move values)))
    }

    fn host_strings_result(
        result: Result<List<string>>) -> TreeValue {
        match result {
            ok(source) => {
                var values: List<TreeValue> = []
                for value: string in source {
                    values.push(
                        TreeValue.string(value))
                }
                return TreeValue.result_ok(
                    TreeValue.sequence(
                        "list", move values))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_string_result(
        result: Result<string>) -> TreeValue {
        match result {
            ok(value) => {
                return TreeValue.result_ok(
                    TreeValue.string(value))
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn host_file_result(
        move result: Result<File>) -> TreeValue {
        match self.take_host_file_result(
                move result) {
            ok(value) => {
                return value
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn take_host_file_result(
        move result: Result<File>) -> Result<TreeValue> {
        let value: File = (move result)?
        return ok(TreeValue.result_ok(
            TreeValue.file(move value)))
    }

    fn host_mmap_result(
        move result: Result<MMap>) -> TreeValue {
        match self.take_host_mmap_result(
                move result) {
            ok(value) => {
                return value
            }
            err(error) => {
                return self.host_error(error)
            }
        }
        return TreeValue.unit()
    }

    fn take_host_mmap_result(
        move result: Result<MMap>) -> Result<TreeValue> {
        let value: MMap = (move result)?
        return ok(TreeValue.result_ok(
            TreeValue.mmap(move value)))
    }

    fn file_static(node: HirNode,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if node.resolved == "File.exists" &&
           arguments.len() == 1 {
            return some(TreeValue.boolean(
                File.exists(arguments[0].text)))
        }
        if node.resolved == "File.size" &&
           arguments.len() == 1 {
            return some(self.host_int_result(
                File.size(arguments[0].text)))
        }
        if node.resolved == "File.remove" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                File.remove(arguments[0].text)))
        }
        if node.resolved == "File.rename" &&
           arguments.len() == 2 {
            return some(self.host_bool_result(
                File.rename(
                    arguments[0].text,
                    arguments[1].text)))
        }
        if node.resolved == "File.copy" &&
           arguments.len() == 2 {
            return some(self.host_int_result(
                host_fs.copy(
                    arguments[0].text,
                    arguments[1].text)))
        }
        if node.resolved == "File.open" &&
           arguments.len() == 2 {
            return some(self.host_file_result(
                File.open(
                    arguments[0].text,
                    arguments[1].text)))
        }
        if node.resolved == "Dir.current" {
            return some(TreeValue.string(
                Dir.current()))
        }
        if node.resolved == "Dir.temp_path" {
            return some(TreeValue.string(
                Dir.temp_path()))
        }
        if node.resolved == "Dir.exists" &&
           arguments.len() == 1 {
            return some(TreeValue.boolean(
                Dir.exists(arguments[0].text)))
        }
        if node.resolved == "Dir.create" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.create(arguments[0].text)))
        }
        if node.resolved == "Dir.create_all" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.create_all(arguments[0].text)))
        }
        if node.resolved == "Dir.list" &&
           arguments.len() == 1 {
            return some(self.host_strings_result(
                Dir.list(arguments[0].text)))
        }
        if node.resolved == "Dir.walk" &&
           arguments.len() == 1 {
            return some(self.host_strings_result(
                Dir.walk(arguments[0].text)))
        }
        if node.resolved == "Dir.remove" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.remove(arguments[0].text)))
        }
        if node.resolved == "Dir.remove_all" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.remove_all(arguments[0].text)))
        }
        if node.resolved == "Dir.sync" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                Dir.sync(arguments[0].text)))
        }
        if node.resolved == "MMap.open" &&
           arguments.len() == 2 {
            return some(self.host_mmap_result(
                MMap.open(
                    arguments[0].text,
                    arguments[1].bool_data)))
        }
        if node.resolved == "MMap.open_shared_memory" &&
           arguments.len() == 3 {
            return some(self.host_mmap_result(
                MMap.open_shared_memory(
                    arguments[0].text,
                    arguments[1].int_data,
                    arguments[2].bool_data)))
        }
        if node.resolved ==
               "MMap.unlink_shared_memory" &&
           arguments.len() == 1 {
            return some(self.host_bool_result(
                MMap.unlink_shared_memory(
                    arguments[0].text)))
        }
        return none
    }

    fn file_method(node: HirNode,
                   receiver: TreeValue,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "file" {
            return none
        }
        match receiver.file_value {
            some(file) => {
                return self.file_method_value(
                    node, receiver, arguments, file)
            }
            none => { return none }
        }
    }

    fn file_method_value(node: HirNode,
                         receiver: TreeValue,
                         arguments: List<TreeValue>,
                         file: File) -> Option<TreeValue> {
        if node.value == "read_at" &&
           arguments.len() == 3 {
            return some(self.host_bytes_result(
                file.read_at(
                    arguments[1].int_data,
                    arguments[2].int_data)))
        }
        if node.value == "read_text_at" &&
           arguments.len() == 3 {
            match file.read_at(
                arguments[1].int_data,
                arguments[2].int_data) {
                ok(value) => {
                    return some(TreeValue.result_ok(
                        TreeValue.string(value.to_string())))
                }
                err(error) => {
                    return some(self.host_error(error))
                }
            }
        }
        if node.value == "write_at" &&
           arguments.len() == 3 {
            match arguments[2].bytes_data {
                some(data) => {
                    return some(self.host_int_result(
                        file.write_at(
                            arguments[1].int_data,
                            data)))
                }
                none => {}
            }
        }
        if node.value == "write_text_at" &&
           arguments.len() == 3 {
            return some(self.host_int_result(
                file.write_at(
                    arguments[1].int_data,
                    Bytes.from(arguments[2].text))))
        }
        if node.value == "read" &&
           arguments.len() == 2 {
            return some(self.host_bytes_result(
                file.read(
                    arguments[1].int_data)))
        }
        if node.value == "read_text" &&
           arguments.len() == 2 {
            match file.read(arguments[1].int_data) {
                ok(value) => {
                    return some(TreeValue.result_ok(
                        TreeValue.string(value.to_string())))
                }
                err(error) => {
                    return some(self.host_error(error))
                }
            }
        }
        if node.value == "write" &&
           arguments.len() == 2 {
            match arguments[1].bytes_data {
                some(data) => {
                    return some(self.host_int_result(
                        file.write(data)))
                }
                none => {}
            }
        }
        if node.value == "write_text" &&
           arguments.len() == 2 {
            return some(self.host_int_result(
                file.write(Bytes.from(arguments[1].text))))
        }
        if node.value == "seek" &&
           arguments.len() == 2 {
            return some(TreeValue.integer(
                file.seek(arguments[1].int_data)))
        }
        if node.value == "seek_from_end" &&
           arguments.len() == 2 {
            return some(TreeValue.integer(
                file.seek_from_end(
                    arguments[1].int_data)))
        }
        if node.value == "tell" {
            return some(TreeValue.integer(
                file.tell()))
        }
        if node.value == "size" {
            return some(self.host_int_result(
                file.size()))
        }
        if node.value == "truncate" &&
           arguments.len() == 2 {
            return some(self.host_bool_result(
                file.truncate(
                    arguments[1].int_data)))
        }
        if node.value == "sync" {
            return some(self.host_bool_result(
                file.sync()))
        }
        if node.value == "close" {
            return some(self.host_bool_result(
                file.close()))
        }
        if node.value == "lock" {
            return some(self.host_bool_result(
                file.lock()))
        }
        if node.value == "try_lock" {
            return some(self.host_bool_result(
                file.try_lock()))
        }
        if node.value == "unlock" {
            return some(self.host_bool_result(
                file.unlock()))
        }
        return none
    }

    fn mmap_method(node: HirNode,
                   receiver: TreeValue,
                   arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "mmap" {
            return none
        }
        match receiver.mmap_value {
            some(mapping) => {
                return self.mmap_method_value(
                    node, receiver, arguments, mapping)
            }
            none => { return none }
        }
    }

    fn mmap_method_value(node: HirNode,
                         receiver: TreeValue,
                         arguments: List<TreeValue>,
                         mapping: MMap) -> Option<TreeValue> {
        if node.value == "len" {
            return some(TreeValue.integer(
                mapping.len()))
        }
        var width: int = 0
        if node.value == "get_u8" ||
           node.value == "put_u8" {
            width = 1
        } else if node.value == "get_u16" ||
                  node.value == "put_u16" {
            width = 2
        } else if node.value == "get_u32" ||
                  node.value == "put_u32" {
            width = 4
        } else if node.value == "get_u64" ||
                  node.value == "get_i64" ||
                  node.value == "put_u64" ||
                  node.value == "put_i64" {
            width = 8
        }
        if width != 0 &&
           arguments.len() >= 2 {
            let offset: int =
                arguments[1].int_data
            if offset < 0 || width > mapping.len() ||
               offset > mapping.len() - width {
                let word: string =
                    if width == 1 {
                        "u8"
                    } else if width == 2 {
                        "u16"
                    } else if width == 4 {
                        "u32"
                    } else if node.value.contains(
                                  "i64") {
                        "i64"
                    } else {
                        "u64"
                    }
                self.fail_at(
                    node,
                    node.col,
                    "{word} {if node.value.starts_with("get") { "read" } else { "write" }} at {offset} out of range (len {mapping.len()})")
                return some(TreeValue.unit())
            }
            if node.value == "get_u8" {
                return some(TreeValue.integer(
                    mapping.get_u8(offset)))
            }
            if node.value == "get_u16" {
                return some(TreeValue.integer(
                    mapping.get_u16(offset)))
            }
            if node.value == "get_u32" {
                return some(TreeValue.integer(
                    mapping.get_u32(offset)))
            }
            if node.value == "get_u64" {
                return some(TreeValue.integer(
                    mapping.get_u64(offset)))
            }
            if node.value == "get_i64" {
                return some(TreeValue.integer(
                    mapping.get_i64(offset)))
            }
            let value: int =
                arguments[2].int_data
            if node.value == "put_u8" {
                mapping.put_u8(offset, value)
            } else if node.value == "put_u16" {
                mapping.put_u16(offset, value)
            } else if node.value == "put_u32" {
                mapping.put_u32(offset, value)
            } else if node.value == "put_u64" {
                mapping.put_u64(offset, value)
            } else {
                mapping.put_i64(offset, value)
            }
            return some(TreeValue.unit())
        }
        if node.value == "read" &&
           arguments.len() == 3 {
            return some(TreeValue.bytes(
                mapping.read(
                    arguments[1].int_data,
                    arguments[2].int_data)))
        }
        if node.value == "write" &&
           arguments.len() == 3 {
            match arguments[2].bytes_data {
                some(data) => {
                    mapping.write(
                        arguments[1].int_data,
                        data)
                    return some(TreeValue.unit())
                }
                none => {}
            }
        }
        if node.value == "flush" {
            return some(self.host_bool_result(
                mapping.flush()))
        }
        if node.value == "flush_range" &&
           arguments.len() == 3 {
            return some(self.host_bool_result(
                mapping.flush_range(
                    arguments[1].int_data,
                    arguments[2].int_data)))
        }
        if node.value == "resize" &&
           arguments.len() == 2 {
            return some(self.host_bool_result(
                mapping.resize(
                    arguments[1].int_data)))
        }
        if node.value == "close" {
            return some(self.host_bool_result(
                mapping.close()))
        }
        return none
    }

    fn stored_callback_dispatch(
        state: TreeStoredState,
        result: RawPtr<u8>,
        arguments: RawPtr<RawPtr<u8> >) {
        var values: List<TreeValue> = []
        unsafe {
            for index: int in
                0..state.parameters.len() {
                let storage: RawPtr<u8> =
                    arguments.offset(index).read()
                values.push(
                    self.ffi_read_host_storage(
                        state.function,
                        state.parameters[index],
                        storage))
            }
        }
        let returned: TreeValue =
            self.invoke_closure(
                new HirNode(
                    "stored_callback",
                    state.function.name,
                    state.result,
                    state.function.file,
                    state.function.line,
                    state.function.col),
                state.callable, move values)
        if self.failed ||
           state.result.name == "unit" {
            return
        }
        unsafe {
            if !result.is_null() {
                var bridges: List<TreeFfiMemory> = []
                self.ffi_write_host_storage(
                    state.function,
                    state.result,
                    returned, result, bridges)
            }
        }
    }

    fn stored_callback_source(
        full: HirType,
        context_index: int,
        same_thread: bool) -> string {
        let builder: CAbiTextBuilder =
            new CAbiTextBuilder(self.program)
        let result_type: HirType =
            if full.fn_parameter_count <
                   full.args.len() {
                full.args[
                    full.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        let c_result: string =
            builder.base(result_type)
        var declarations: List<string> = []
        var addresses: List<string> = []
        for index: int in
            0..full.fn_parameter_count {
            declarations.push(
                "{builder.base(full.args[index])} value{index}")
            if index != context_index {
                addresses.push("&value{index}")
            }
        }
        let parameters: string =
            if declarations.len() == 0 {
                "void"
            } else {
                declarations.join(", ")
            }
        var slots: int = addresses.len()
        if slots == 0 { slots = 1 }
        let address_text: string =
            if addresses.len() == 0 {
                "0"
            } else {
                addresses.join(", ")
            }
        var source: string =
            "#include <stdint.h>\n"
        if same_thread {
            source =
                "{source}#include <stdio.h>\n#include <stdlib.h>\n#include <pthread.h>\n"
        }
        source =
            "{source}typedef void (*BeansFfiDispatch)(void*, void*, void**);\n"
        source =
            "{source}static BeansFfiDispatch stored_dispatch;\n"
        if same_thread {
            // the bridge init runs on the registering thread, so it is
            // the one to record; the entry checks every call after that
            source =
                "{source}static pthread_t stored_owner;\nstatic int stored_owner_set;\n"
        }
        source =
            "{source}{c_result} beans_stored_entry({parameters}) \{\n  void* context = (void*)value{context_index};\n  void* arguments[{slots}] = \{{address_text}\};\n"
        if same_thread {
            // the same words and the same exit code the native runtime's
            // beans_panic produces, so one program means one thing:
            // aborting here gave the interpreter 134 where a built binary
            // exits 3. On this pthread-only path the host buffers stdout
            // through stdio, so fflush orders the panic like beans_panic
            // does without importing a host symbol the dynamic loader
            // may not export on every platform.
            source =
                "{source}  if (stored_owner_set && !pthread_equal(stored_owner, pthread_self())) \{\n    fflush(stdout);\n    fprintf(stderr, \"runtime panic at 0:0: same-thread stored callback invoked from another thread\\n\");\n    exit(3);\n  \}\n"
        }
        if c_result == "void" {
            source =
                "{source}  stored_dispatch(context, 0, arguments);\n\}\n"
        } else {
            source =
                "{source}  {c_result} result = \{0\};\n  stored_dispatch(context, &result, arguments);\n  return result;\n\}\n"
        }
        source =
            "{source}{ffi_export_attribute()}"
        source =
            if same_thread {
                "{source}void beans_ffi_bridge(void* symbol, void* result, void** args, BeansFfiDispatch dispatch, void** contexts) \{\n  (void)symbol; (void)args; (void)contexts;\n  stored_dispatch = dispatch;\n  stored_owner = pthread_self();\n  stored_owner_set = 1;\n  *(void**)result = (void*)(uintptr_t)&beans_stored_entry;\n\}\n"
            } else {
                "{source}void beans_ffi_bridge(void* symbol, void* result, void** args, BeansFfiDispatch dispatch, void** contexts) \{\n  (void)symbol; (void)args; (void)contexts;\n  stored_dispatch = dispatch;\n  *(void**)result = (void*)(uintptr_t)&beans_stored_entry;\n\}\n"
            }
        return source
    }

    fn create_stored_callback(
        node: HirNode,
        arguments: List<TreeValue>) -> TreeValue {
        if arguments.len() != 2 ||
           node.type.args.len() != 1 {
            return self.fail(
                node,
                "StoredCallback.create needs an index and closure")
        }
        let same_thread: bool =
            node.resolved.starts_with(
                "LocalStoredCallback.create:")
        let prefix: string =
            if same_thread {
                "LocalStoredCallback.create:"
            } else {
                "StoredCallback.create:"
            }
        var context_index: int = -1
        if node.resolved.starts_with(prefix) {
            match node.resolved.slice(
                    prefix.len(),
                    node.resolved.len()).to_int() {
                ok(value) => {
                    context_index = value
                }
                err(error) => {}
            }
        }
        let full: HirType = node.type.args[0]
        if context_index < 0 ||
           context_index >=
               full.fn_parameter_count {
            return self.fail(
                node,
                "invalid StoredCallback userdata index")
        }
        var parameters: List<HirType> = []
        for index: int in
            0..full.fn_parameter_count {
            if index != context_index {
                parameters.push(full.args[index])
            }
        }
        let result_type: HirType =
            if full.fn_parameter_count <
                   full.args.len() {
                full.args[
                    full.fn_parameter_count]
            } else {
                new HirType("unit")
            }
        let function: HirFunction =
            new HirFunction(
                "StoredCallback.create", "",
                "", false, false, node.file,
                node.line, node.col)
        function.result = result_type
        let state: Mutex<TreeStoredState> =
            new Mutex(
                new TreeStoredState(
                    self, function,
                    arguments[1],
                    move parameters,
                    result_type))
        let dispatch:
            StoredCallback<
                fn(RawPtr<u8>, RawPtr<u8>,
                   RawPtr<RawPtr<u8> >)> =
            StoredCallback.create(
                0,
                fn(result: RawPtr<u8>,
                   callback_arguments:
                       RawPtr<RawPtr<u8> >) {
                    state.with_lock(
                        fn(value: TreeStoredState) {
                            let owner:
                                TreeInterpreter =
                                value.owner
                            owner.stored_callback_dispatch(
                                value, result,
                                callback_arguments)
                        })
                })
        let source: string =
            self.stored_callback_source(
                full, context_index, same_thread)
        let bridge: int =
            self.ffi_bridge(function, source)
        if self.failed {
            return TreeValue.unit()
        }
        var function_address: int = 0
        let context: RawPtr<u8> =
            dispatch.context()
        unsafe {
            let output:
                RawPtr<RawPtr<u8> > =
                RawPtr.alloc(1)
            beans_tree_ffi_invoke_bridge(
                RawPtr.from_address(
                    bridge as u64),
                RawPtr.null(),
                RawPtr.from_address(
                    output.address()),
                RawPtr.null(),
                dispatch.function(),
                RawPtr.null())
            function_address =
                output.read().address() as int
            output.free()
        }
        let id: int = self.next_object_id
        self.next_object_id += 1
        self.stored_callbacks[id] =
            new TreeStoredCallback(
                context, function_address, state)
        let result: TreeValue =
            new TreeValue("stored_callback")
        result.object_id = id
        return result
    }

    fn stored_callback_method(
        node: HirNode,
        receiver: TreeValue) ->
        Option<TreeValue> {
        if receiver.kind != "stored_callback" &&
           receiver.kind != "stored_function" {
            return none
        }
        match self.stored_callbacks.get(
                  receiver.object_id) {
            some(callback) => {
                if node.value == "function" {
                    let result: TreeValue =
                        new TreeValue(
                            "stored_function")
                    result.object_id =
                        receiver.object_id
                    result.int_data =
                        callback.function
                    return some(result)
                }
                if node.value == "function_pointer" {
                    var callback_type: HirType =
                        new HirType("poison")
                    if node.type.args.len() == 1 {
                        callback_type = node.type.args[0]
                    }
                    return some(TreeValue.host_pointer(
                        callback.function as u64,
                        callback_type))
                }
                if node.value == "context" {
                    unsafe {
                        return some(
                            TreeValue.host_pointer(
                                callback.context.address(),
                                new HirType("u8")))
                    }
                }
                if node.value == "close" {
                    unsafe {
                        beans_tree_stored_close(
                            callback.context)
                    }
                    self.stored_callbacks.remove(
                        receiver.object_id)
                    return some(TreeValue.unit())
                }
            }
            none => {
                self.fail(
                    node,
                    "StoredCallback is already closed")
                return some(TreeValue.unit())
            }
        }
        return none
    }

    fn c_function_pointer_method(
        node: HirNode,
        receiver: TreeValue,
        arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if node.children.len() == 0 ||
           canonical_hir_name(
               node.children[0].type.name) !=
               "CFunctionPtr" {
            return none
        }
        if node.value == "is_null" {
            return some(TreeValue.boolean(
                receiver.memory_address == 0))
        }
        if node.value != "call" {
            return none
        }
        if receiver.memory_address == 0 {
            return some(self.fail(
                node,
                "cannot call a null CFunctionPtr"))
        }
        var callback: HirType =
            new HirType("poison")
        match receiver.memory_type {
            some(type) => { callback = type }
            none => {}
        }
        if callback.name != "fn" {
            return some(self.fail(
                node,
                "CFunctionPtr has no callback signature"))
        }
        let function: HirFunction =
            new HirFunction(
                "CFunctionPtr.call", "", "",
                false, false, node.file,
                node.line, node.col)
        for index: int in 0..callback.fn_parameter_count {
            function.parameters.push(
                new HirParameter(
                    "arg{index}", "",
                    callback.args[index],
                    node.file, node.line, node.col))
        }
        if callback.fn_parameter_count <
               callback.args.len() {
            function.result =
                callback.args[
                    callback.fn_parameter_count]
        }
        var call_arguments: List<TreeValue> = []
        for index: int in 1..arguments.len() {
            call_arguments.push(arguments[index])
        }
        let builder: CAbiTextBuilder =
            new CAbiTextBuilder(self.program)
        return some(self.call_extern_bridge(
            function, call_arguments,
            receiver.memory_address as int,
            builder.describe(function)))
    }

    fn raw_static(node: HirNode,
                  arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if node.resolved == "RawPtr.with_local" &&
           arguments.len() == 2 &&
           node.children.len() == 2 {
            let reference: TreeValue =
                arguments[0]
            if reference.kind != "reference" {
                self.fail(
                    node,
                    "RawPtr.with_local needs an inout local")
                return some(TreeValue.unit())
            }
            match reference.reference_frame {
                some(target) => {
                    match target.get(
                            reference.reference_binding) {
                        some(value) => {
                            let element: HirType =
                                node.children[0].type
                            let answer: LayoutAnswer =
                                self.layout(element)
                            if !answer.ok {
                                self.fail(
                                    node,
                                    "RawPtr.with_local cannot lay out {render_hir_type(element)}")
                                return some(
                                    TreeValue.unit())
                            }
                            let memory: TreeMemory =
                                self.allocate_memory(
                                    answer.value.size,
                                    answer.value.align)
                            if !self.memory_write_value(
                                   node, memory,
                                   memory.base,
                                   element, value) {
                                return some(
                                    TreeValue.unit())
                            }
                            let pointer: TreeValue =
                                TreeValue.raw_pointer(
                                    some(memory),
                                    memory.base, element)
                            self.invoke_closure(
                                node, arguments[1],
                                [pointer])
                            if !self.failed {
                                let changed: TreeValue =
                                    self.memory_read_value(
                                        node, memory,
                                        memory.base,
                                        element)
                                target.assign(
                                    reference.reference_binding,
                                    changed)
                            }
                            memory.freed = true
                            return some(
                                TreeValue.unit())
                        }
                        none => {}
                    }
                }
                none => {}
            }
            self.fail(
                node,
                "RawPtr.with_local local is no longer live")
            return some(TreeValue.unit())
        }
        let name: string =
            canonical_hir_name(node.type.name)
        if name == "Slice" &&
           node.value == "from_raw" &&
           arguments.len() == 2 {
            let length: int =
                arguments[1].int_data
            if length < 0 {
                self.fail_at(
                    node,
                    node.col,
                    "negative slice length")
                return some(TreeValue.unit())
            }
            if length > 0 &&
               arguments[0].memory_address == 0 {
                self.fail_at(
                    node,
                    node.col,
                    "null pointer with non-empty slice")
                return some(TreeValue.unit())
            }
            return some(TreeValue.slice(
                arguments[0], length))
        }
        if name != "RawPtr" ||
           node.type.args.len() != 1 {
            return none
        }
        let element: HirType =
            node.type.args[0]
        if node.value == "null" {
            return some(TreeValue.raw_pointer(
                none, 0, element))
        }
        if node.value == "from_address" &&
           arguments.len() == 1 {
            let address: u64 =
                arguments[0].uint_data
            match self.find_memory(address) {
                some(memory) => {
                    return some(TreeValue.raw_pointer(
                        some(memory), address, element))
                }
                none => {
                    return some(TreeValue.host_pointer(
                        address, element))
                }
            }
        }
        if (node.value == "alloc" ||
            node.value == "alloc_aligned") &&
           arguments.len() >= 1 {
            let count: int =
                arguments[0].int_data
            if count < 0 {
                self.fail_at(
                    node,
                    node.col,
                    "negative raw allocation count")
                return some(TreeValue.unit())
            }
            let piece: LayoutAnswer =
                self.layout(element)
            if !piece.ok ||
               piece.value.size == 0 ||
               count > 288230376151711744 /
                       piece.value.size {
                self.fail_at(
                    node,
                    node.col,
                    "raw allocation too large")
                return some(TreeValue.unit())
            }
            var alignment: int =
                piece.value.align
            if node.value == "alloc_aligned" &&
               arguments.len() >= 2 {
                let requested: int =
                    arguments[1].int_data
                if requested <= 0 ||
                   !layout_power_of_two(requested) {
                    self.fail_at(
                        node,
                        node.col,
                        "raw allocation alignment must be a power of two")
                    return some(TreeValue.unit())
                }
                if requested < alignment {
                    self.fail_at(
                        node,
                        node.col,
                        "raw allocation alignment is below the element's own alignment")
                    return some(TreeValue.unit())
                }
                alignment = requested
            }
            let memory: TreeMemory =
                self.allocate_memory(
                    count * piece.value.size,
                    alignment)
            return some(TreeValue.raw_pointer(
                some(memory), memory.base, element))
        }
        return none
    }

    fn raw_method(node: HirNode,
                  receiver: TreeValue,
                  arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind == "slice" {
            let element: HirType =
                receiver.memory_type.expect(
                    "slice element type")
            let piece: LayoutAnswer =
                self.layout(element)
            if node.value == "len" {
                return some(TreeValue.integer(
                    receiver.slice_len))
            }
            if (node.value == "get" ||
                node.value == "set") &&
               arguments.len() >= 2 {
                let index: int =
                    arguments[1].int_data
                if index < 0 ||
                   index >= receiver.slice_len {
                    self.fail(
                        node,
                        "slice index {index} out of range (len {receiver.slice_len})")
                    return some(TreeValue.unit())
                }
                match self.pointer_memory(
                        node, receiver) {
                    some(memory) => {
                        let address: u64 =
                            receiver.memory_address +
                            ((index *
                              piece.value.size) as u64)
                        if node.value == "get" {
                            return some(
                                self.memory_read_value(
                                    node, memory,
                                    address, element))
                        }
                        self.memory_write_value(
                            node, memory, address,
                            element, arguments[2])
                        return some(TreeValue.unit())
                    }
                    none => {
                        return some(TreeValue.unit())
                    }
                }
            }
            if node.value == "subslice" &&
               arguments.len() == 3 {
                let start: int =
                    arguments[1].int_data
                let end: int =
                    arguments[2].int_data
                if start < 0 || end < start ||
                   end > receiver.slice_len {
                    self.fail(
                        node,
                        "slice range out of bounds")
                    return some(TreeValue.unit())
                }
                let pointer: TreeValue =
                    TreeValue.raw_pointer(
                        receiver.memory,
                        receiver.memory_address +
                            ((start *
                              piece.value.size) as u64),
                        element)
                pointer.memory_host =
                    receiver.memory_host
                return some(TreeValue.slice(
                    pointer, end - start))
            }
            if node.value == "as_ptr" {
                let pointer: TreeValue =
                    TreeValue.raw_pointer(
                        receiver.memory,
                        receiver.memory_address,
                        element)
                pointer.memory_host =
                    receiver.memory_host
                return some(pointer)
            }
            return none
        }
        if receiver.kind != "raw_ptr" {
            return none
        }
        let element: HirType =
            receiver.memory_type.expect(
                "raw pointer element type")
        let piece: LayoutAnswer =
            self.layout(element)
        if node.value == "is_null" {
            return some(TreeValue.boolean(
                receiver.memory_address == 0))
        }
        if node.value == "address" {
            return some(
                TreeValue.unsigned_integer(
                    receiver.memory_address, 64))
        }
        if node.value == "element_size" {
            return some(TreeValue.integer(
                piece.value.size))
        }
        if node.value == "element_align" {
            return some(TreeValue.integer(
                piece.value.align))
        }
        if node.value == "offset" &&
           arguments.len() == 2 {
            let address: int =
                receiver.memory_address as int +
                arguments[1].int_data *
                    piece.value.size
            let result: TreeValue =
                TreeValue.raw_pointer(
                    receiver.memory,
                    address as u64, element)
            result.memory_host =
                receiver.memory_host
            return some(result)
        }
        if node.value == "free" {
            if receiver.memory_host &&
               receiver.memory_address != 0 {
                unsafe {
                    let host: RawPtr<u8> =
                        RawPtr.from_address(
                            receiver.memory_address)
                    host.free()
                }
                return some(TreeValue.unit())
            }
            match receiver.memory {
                some(memory) => {
                    memory.freed = true
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "read" ||
           node.value == "read_volatile" ||
           node.value == "atomic_load" {
            if receiver.memory_address == 0 {
                self.fail_at(
                    node,
                    node.col,
                    if node.value == "atomic_load" {
                        "null raw pointer atomic load"
                    } else {
                        "null raw pointer read"
                    })
                return some(TreeValue.unit())
            }
            if node.value == "atomic_load" &&
               piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            if receiver.memory_host {
                return some(
                    self.host_pointer_read(
                        node, receiver, element))
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    if node.value ==
                           "atomic_load" {
                        var result: TreeValue =
                            TreeValue.unit()
                        memory.atomic_guard.with_lock(
                            fn(locked: bool) {
                                result =
                                    self.memory_read_value(
                                        node, memory,
                                        receiver.memory_address,
                                        element)
                            })
                        return some(result)
                    }
                    return some(
                        self.memory_read_value(
                            node, memory,
                            receiver.memory_address,
                            element))
                }
                none => {
                    return some(TreeValue.unit())
                }
            }
        }
        if node.value == "write" ||
           node.value == "write_volatile" ||
           node.value == "atomic_store" {
            if receiver.memory_address == 0 {
                self.fail_at(
                    node,
                    node.col,
                    if node.value == "atomic_store" {
                        "null raw pointer atomic store"
                    } else {
                        "null raw pointer write"
                    })
                return some(TreeValue.unit())
            }
            if node.value == "atomic_store" &&
               piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            if receiver.memory_host {
                self.host_pointer_write(
                    node, receiver, element,
                    arguments[1])
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    if node.value ==
                           "atomic_store" {
                        memory.atomic_guard.with_lock(
                            fn(locked: bool) {
                                self.memory_write_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element,
                                    arguments[1])
                            })
                        return some(
                            TreeValue.unit())
                    }
                    self.memory_write_value(
                        node, memory,
                        receiver.memory_address,
                        element, arguments[1])
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "copy_from" &&
           arguments.len() == 3 {
            let count: int =
                arguments[2].int_data
            if count < 0 {
                self.fail(
                    node,
                    "negative raw copy count")
                return some(TreeValue.unit())
            }
            let bytes: int =
                count * piece.value.size
            if bytes > 0 &&
               (receiver.memory_address == 0 ||
                arguments[1].memory_address == 0) {
                self.fail(
                    node, "null raw pointer copy")
                return some(TreeValue.unit())
            }
            // A borrowed Bytes pointer is a real host pointer. RawPtr.alloc
            // uses the interpreter's checked memory model, so a bulk copy
            // can have a host pointer on either side. Resolve checked memory
            // to its backing Bytes pointer, then use one memmove.
            if receiver.memory_host ||
               arguments[1].memory_host {
                var target: RawPtr<u8> = RawPtr.null()
                var source: RawPtr<u8> = RawPtr.null()
                if receiver.memory_host {
                    unsafe {
                        target = RawPtr.from_address(
                            receiver.memory_address)
                    }
                } else {
                    match self.pointer_memory(node, receiver) {
                        some(memory) => {
                            if !self.memory_contains(
                                   memory,
                                   receiver.memory_address,
                                   bytes) {
                                self.fail(
                                    node,
                                    "invalid raw pointer copy")
                                return some(TreeValue.unit())
                            }
                            unsafe {
                                target = memory.data.as_ptr().offset(
                                    (receiver.memory_address -
                                     memory.base) as int)
                            }
                        }
                        none => {
                            return some(TreeValue.unit())
                        }
                    }
                }
                if arguments[1].memory_host {
                    unsafe {
                        source = RawPtr.from_address(
                            arguments[1].memory_address)
                    }
                } else {
                    match self.pointer_memory(
                            node, arguments[1]) {
                        some(memory) => {
                            if !self.memory_contains(
                                   memory,
                                   arguments[1].memory_address,
                                   bytes) {
                                self.fail(
                                    node,
                                    "invalid raw pointer copy")
                                return some(TreeValue.unit())
                            }
                            unsafe {
                                source = memory.data.as_ptr().offset(
                                    (arguments[1].memory_address -
                                     memory.base) as int)
                            }
                        }
                        none => {
                            return some(TreeValue.unit())
                        }
                    }
                }
                unsafe { target.copy_from(source, bytes) }
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(destination) => {
                    match self.pointer_memory(
                            node, arguments[1]) {
                        some(source) => {
                            if !self.memory_contains(
                                   destination,
                                   receiver.memory_address,
                                   bytes) ||
                               !self.memory_contains(
                                   source,
                                   arguments[1].memory_address,
                                   bytes) {
                                self.fail(
                                    node,
                                    "invalid raw pointer copy")
                                return some(
                                    TreeValue.unit())
                            }
                            let from: int =
                                (arguments[1].memory_address -
                                 source.base) as int
                            let temporary: Bytes =
                                source.data.slice(
                                    from, from + bytes)
                            let at: int =
                                (receiver.memory_address -
                                 destination.base) as int
                            destination.data.copy_from(
                                temporary, at)
                        }
                        none => {}
                    }
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "fill_zero" &&
           arguments.len() == 2 {
            let count: int =
                arguments[1].int_data
            if count < 0 {
                self.fail(
                    node,
                    "negative raw zero count")
                return some(TreeValue.unit())
            }
            let bytes: int =
                count * piece.value.size
            if bytes > 0 &&
               receiver.memory_address == 0 {
                self.fail(
                    node, "null raw pointer zero")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    let start: int =
                        (receiver.memory_address -
                         memory.base) as int
                    for index: int in 0..bytes {
                        memory.data.set(
                            start + index, 0)
                    }
                }
                none => {}
            }
            return some(TreeValue.unit())
        }
        if node.value == "atomic_fetch_add" &&
           arguments.len() == 2 {
            if receiver.memory_address == 0 {
                self.fail(
                    node,
                    "null raw pointer atomic fetch_add")
                return some(TreeValue.unit())
            }
            if piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    var old: TreeValue =
                        TreeValue.unit()
                    memory.atomic_guard.with_lock(
                        fn(locked: bool) {
                            old =
                                self.memory_read_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element)
                            let updated: TreeValue =
                                if old.int_unsigned {
                                    TreeValue.unsigned_integer(
                                        old.uint_data +
                                            arguments[1].uint_data,
                                        old.int_bits)
                                } else {
                                    TreeValue.signed_integer(
                                        old.int_data +
                                            arguments[1].int_data,
                                        old.int_bits)
                                }
                            self.memory_write_value(
                                node, memory,
                                receiver.memory_address,
                                element, updated)
                        })
                    return some(old)
                }
                none => {
                    return some(TreeValue.unit())
                }
            }
        }
        if node.value ==
               "atomic_compare_exchange" &&
           arguments.len() == 3 {
            if receiver.memory_address == 0 {
                self.fail(
                    node,
                    "null raw pointer atomic_compare_exchange")
                return some(TreeValue.unit())
            }
            if piece.value.align > 1 &&
               receiver.memory_address %
                   (piece.value.align as u64) != 0 {
                self.fail(
                    node,
                    "unaligned raw pointer atomic access")
                return some(TreeValue.unit())
            }
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    var equal: bool = false
                    memory.atomic_guard.with_lock(
                        fn(locked: bool) {
                            let old: TreeValue =
                                self.memory_read_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element)
                            equal =
                                tree_value_equal(
                                    old, arguments[1])
                            if equal {
                                self.memory_write_value(
                                    node, memory,
                                    receiver.memory_address,
                                    element,
                                    arguments[2])
                            }
                        })
                    return some(
                        TreeValue.boolean(equal))
                }
                none => {
                    return some(TreeValue.unit())
                }
            }
        }
        return none
    }

    fn atomic_snapshot(
        receiver: TreeValue) -> TreeValue {
        var result: TreeValue =
            TreeValue.unit()
        match receiver.mutex_cell {
            some(cell) => {
                cell.with_lock(fn(state: TreeMutexCell) {
                    result =
                        tree_value_copy(state.value)
                })
            }
            none => {}
        }
        return result
    }

    fn atomic_replace(
        receiver: TreeValue,
        value: TreeValue) {
        match receiver.mutex_cell {
            some(cell) => {
                cell.with_lock(fn(state: TreeMutexCell) {
                    state.value =
                        tree_value_copy(value)
                })
            }
            none => {}
        }
    }

    fn atomic_method(
        node: HirNode, receiver: TreeValue,
        arguments: List<TreeValue>) ->
        Option<TreeValue> {
        if receiver.kind != "atomic" ||
           receiver.mutex_cell.is_none() {
            return none
        }
        if node.value == "load" {
            return some(
                self.atomic_snapshot(receiver))
        }
        if node.value == "store" &&
           arguments.len() >= 2 {
            self.atomic_replace(
                receiver, arguments[1])
            return some(TreeValue.unit())
        }
        if node.value == "exchange" &&
           arguments.len() >= 2 {
            var previous: TreeValue =
                TreeValue.unit()
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeMutexCell) {
                        previous =
                            tree_value_copy(
                                state.value)
                        state.value =
                            tree_value_copy(
                                arguments[1])
                    })
                }
                none => {}
            }
            return some(previous)
        }
        if node.value == "compare_exchange" &&
           arguments.len() >= 3 {
            var equal: bool = false
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeMutexCell) {
                        equal =
                            tree_value_equal(
                                state.value,
                                arguments[1])
                        if equal {
                            state.value =
                                tree_value_copy(
                                    arguments[2])
                        }
                    })
                }
                none => {}
            }
            return some(TreeValue.boolean(equal))
        }
        if (node.value == "fetch_add" ||
            node.value == "fetch_sub" ||
            node.value == "fetch_and" ||
            node.value == "fetch_or" ||
            node.value == "fetch_xor" ||
            node.value == "add_and_get") &&
           arguments.len() >= 2 {
            var previous: TreeValue =
                TreeValue.unit()
            // AtomicInt.add_and_get is the one op here that hands back the
            // value it wrote; the fetch_* family reports what was there.
            var updated: TreeValue =
                TreeValue.unit()
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeMutexCell) {
                        previous =
                            tree_value_copy(
                                state.value)
                        let left: u64 =
                            previous.uint_data
                        let right: u64 =
                            arguments[1].uint_data
                        var raw: u64 = left
                        if node.value == "fetch_add" ||
                           node.value == "add_and_get" {
                            raw = left + right
                        } else if node.value ==
                                      "fetch_sub" {
                            raw = left - right
                        } else if node.value ==
                                      "fetch_and" {
                            raw = left & right
                        } else if node.value ==
                                      "fetch_or" {
                            raw = left | right
                        } else {
                            raw = left ^ right
                        }
                        state.value =
                            if previous.int_unsigned {
                                TreeValue.unsigned_integer(
                                    raw,
                                    previous.int_bits)
                            } else {
                                TreeValue.signed_integer(
                                    tree_signed_from_bits(
                                        raw,
                                        previous.int_bits),
                                    previous.int_bits)
                            }
                        updated =
                            tree_value_copy(state.value)
                    })
                }
                none => {}
            }
            if node.value == "add_and_get" {
                return some(updated)
            }
            return some(previous)
        }
        if node.value == "wait" &&
           arguments.len() >= 2 {
            var waiting: bool = true
            for waiting {
                var signal:
                    Option<Channel<int>> = none
                match receiver.mutex_cell {
                    some(cell) => {
                        cell.with_lock(
                            fn(state: TreeMutexCell) {
                                if tree_value_equal(
                                       state.value,
                                       arguments[1]) {
                                    let channel:
                                        Channel<int> =
                                        new Channel<int>(1)
                                    state.waiters.push(
                                        channel)
                                    signal =
                                        some(channel)
                                } else {
                                    waiting = false
                                }
                            })
                    }
                    none => {
                        waiting = false
                    }
                }
                match signal {
                    some(channel) => {
                        channel.receive()
                    }
                    none => {}
                }
            }
            return some(TreeValue.unit())
        }
        if node.value == "wait_timeout" &&
           arguments.len() >= 3 {
            if !tree_value_equal(
                   self.atomic_snapshot(receiver),
                   arguments[1]) {
                return some(
                    TreeValue.boolean(true))
            }
            let started: int =
                host_time.monotonic_nanos()
            let budget: int =
                arguments[2].int_data
            for host_time.monotonic_nanos() -
                    started < budget {
                host_time.sleep_nanos(
                    if budget < 100000 {
                        budget
                    } else {
                        100000
                    })
                if !tree_value_equal(
                       self.atomic_snapshot(
                           receiver),
                       arguments[1]) {
                    return some(
                        TreeValue.boolean(true))
                }
            }
            return some(TreeValue.boolean(false))
        }
        if node.value == "notify_all" ||
           node.value == "notify_one" {
            var woke: int = 0
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(
                        fn(state: TreeMutexCell) {
                            if node.value ==
                                   "notify_one" {
                                match state.waiters.pop() {
                                    some(waiter) => {
                                        waiter.send(1)
                                        woke = 1
                                    }
                                    none => {}
                                }
                            } else {
                                woke =
                                    state.waiters.len()
                                for waiter:
                                        Channel<int> in
                                    state.waiters {
                                    waiter.send(1)
                                }
                                state.waiters = []
                            }
                        })
                }
                none => {}
            }
            return some(
                TreeValue.integer(woke))
        }
        return none
    }

    fn tree_channel_send(
        node: HirNode, receiver: TreeValue,
        value: TreeValue) -> bool {
        return self.tree_channel_send_wait(
            node, receiver, value, true)
    }

    fn tree_channel_send_wait(
        node: HirNode, receiver: TreeValue,
        value: TreeValue, blocking: bool) -> bool {
        for {
            var sent: bool = false
            var closed: bool = false
            var signal: Option<Channel<int>> = none
            match receiver.channel_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeChannelState) {
                        closed = state.closed
                        if !closed &&
                           state.values.len() < state.capacity {
                            state.values.push(
                                tree_value_copy(value))
                            sent = true
                            if state.receive_waiters.len() != 0 {
                                let waiter: Channel<int> =
                                    state.receive_waiters.remove(0)
                                waiter.send(1)
                            }
                        } else if !closed && blocking {
                            let waiter: Channel<int> =
                                new Channel<int>(1)
                            state.send_waiters.push(waiter)
                            signal = some(waiter)
                        }
                    })
                }
                none => {
                    self.fail(node, "channel has no host state")
                    return false
                }
            }
            if sent { return true }
            if closed { return false }
            if !blocking { return false }
            match signal {
                some(waiter) => { waiter.receive() }
                none => {}
            }
        }
    }

    fn tree_channel_receive(
        node: HirNode, receiver: TreeValue) -> Option<TreeValue> {
        return self.tree_channel_receive_wait(
            node, receiver, true)
    }

    fn tree_channel_receive_wait(
        node: HirNode, receiver: TreeValue,
        blocking: bool) -> Option<TreeValue> {
        for {
            var value: Option<TreeValue> = none
            var done: bool = false
            var signal: Option<Channel<int>> = none
            match receiver.channel_cell {
                some(cell) => {
                    cell.with_lock(fn(state: TreeChannelState) {
                        if state.values.len() != 0 {
                            value = some(state.values.remove(0))
                            done = true
                            if state.send_waiters.len() != 0 {
                                let waiter: Channel<int> =
                                    state.send_waiters.remove(0)
                                waiter.send(1)
                            }
                        } else if state.closed {
                            done = true
                        } else if blocking {
                            let waiter: Channel<int> =
                                new Channel<int>(1)
                            state.receive_waiters.push(waiter)
                            signal = some(waiter)
                        }
                    })
                }
                none => {
                    self.fail(node, "channel has no host state")
                    return none
                }
            }
            if done { return value }
            if !blocking { return none }
            match signal {
                some(waiter) => { waiter.receive() }
                none => {}
            }
        }
    }

    fn tree_channel_close(receiver: TreeValue) {
        match receiver.channel_cell {
            some(cell) => {
                cell.with_lock(fn(state: TreeChannelState) {
                    state.closed = true
                    for waiter: Channel<int> in state.send_waiters {
                        waiter.send(1)
                    }
                    for waiter: Channel<int> in state.receive_waiters {
                        waiter.send(1)
                    }
                    state.send_waiters = []
                    state.receive_waiters = []
                })
            }
            none => {}
        }
    }

    fn builtin_method(node: HirNode,
                      arguments: List<TreeValue>) -> TreeValue {
        if arguments.len() == 0 {
            return self.fail(node, "method has no receiver")
        }
        let receiver: TreeValue = arguments[0]
        match self.c_function_pointer_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.stored_callback_method(
                node, receiver) {
            some(value) => { return value }
            none => {}
        }
        match self.mmap_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.file_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.raw_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        if receiver.kind == "atomic" {
            match self.atomic_method(
                    node, receiver, arguments) {
                some(value) => { return value }
                none => {}
            }
        }
        match self.bytes_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        match self.simd_method(
                node, receiver, arguments) {
            some(value) => { return value }
            none => {}
        }
        if receiver.kind == "int" &&
           node.value == "abs" {
            if receiver.int_unsigned {
                return receiver
            }
            // narrow to the receiver's width: the wrap at each width's
            // minimum is the wrap the native sub/select produces
            let bits: int =
                tree_integer_bits(
                    canonical_hir_name(node.type.name))
            return TreeValue.signed_integer(
                tree_signed_from_bits(
                    receiver.int_data.abs() as u64,
                    bits),
                bits)
        }
        if receiver.kind == "float" &&
           node.value == "abs" {
            return TreeValue.floating(
                receiver.float_data.abs())
        }
        if receiver.kind == "float" &&
           node.value == "floor" {
            return TreeValue.floating(
                tree_float_floor(receiver.float_data))
        }
        if receiver.kind == "float" &&
           node.value == "ceil" {
            return TreeValue.floating(
                -tree_float_floor(
                    -receiver.float_data))
        }
        if receiver.kind == "float" &&
           node.value == "is_nan" {
            return TreeValue.boolean(
                receiver.float_data !=
                    receiver.float_data)
        }
        if receiver.kind == "float" &&
           node.value == "round" {
            return TreeValue.integer(
                receiver.float_data.round())
        }
        if receiver.kind == "decimal" &&
           node.value == "abs" {
            return TreeValue.decimal_value(
                receiver.decimal_data.abs())
        }
        if receiver.kind == "decimal" &&
           node.value == "round" &&
           arguments.len() >= 2 {
            let places: int =
                arguments[1].int_data
            if arguments.len() < 3 ||
               arguments[2].text == "half_even" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.half_even))
            }
            if arguments[2].text == "half_away" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.half_away))
            }
            if arguments[2].text == "toward_zero" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.toward_zero))
            }
            if arguments[2].text == "floor" {
                return TreeValue.decimal_value(
                    receiver.decimal_data.round(
                        places,
                        RoundingMode.floor))
            }
            return TreeValue.decimal_value(
                receiver.decimal_data.round(
                    places,
                    RoundingMode.ceil))
        }
        if node.value == "len" {
            if receiver.kind == "string" {
                return TreeValue.integer(
                    receiver.text.len())
            }
            if receiver.kind == "list" ||
               receiver.kind == "array" {
                return TreeValue.integer(
                    receiver.items.len())
            }
            if receiver.kind == "map" {
                return TreeValue.integer(
                    receiver.map_values.len())
            }
        }
        if node.value == "is_empty" {
            if receiver.kind == "string" {
                return TreeValue.boolean(
                    receiver.text.len() == 0)
            }
            if receiver.kind == "list" ||
               receiver.kind == "array" {
                return TreeValue.boolean(
                    receiver.items.len() == 0)
            }
            if receiver.kind == "map" {
                return TreeValue.boolean(
                    receiver.map_values.len() == 0)
            }
        }
        if receiver.kind == "string" &&
           (node.value == "last" ||
            node.value == "first" ||
            node.value == "repeat") &&
           arguments.len() == 2 &&
           arguments[1].kind == "int" {
            let count: int =
                arguments[1].int_data
            if node.value == "last" {
                return TreeValue.string(
                    receiver.text.last(count))
            }
            if node.value == "first" {
                return TreeValue.string(
                    receiver.text.first(count))
            }
            return TreeValue.string(
                receiver.text.repeat(count))
        }
        if receiver.kind == "string" &&
           (node.value == "contains" ||
            node.value == "starts_with" ||
            node.value == "ends_with") &&
           arguments.len() == 2 &&
           arguments[1].kind == "string" {
            if node.value == "contains" {
                return TreeValue.boolean(
                    receiver.text.contains(
                        arguments[1].text))
            }
            if node.value == "starts_with" {
                return TreeValue.boolean(
                    receiver.text.starts_with(
                        arguments[1].text))
            }
            return TreeValue.boolean(
                receiver.text.ends_with(
                    arguments[1].text))
        }
        if receiver.kind == "string" &&
           node.value == "slice" &&
           arguments.len() == 3 {
            let start: int = arguments[1].int_data
            let end: int = arguments[2].int_data
            if start < 0 || end < start ||
               end > receiver.text.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "slice {start}..{end} out of range (len {receiver.text.len()})")
            }
            return TreeValue.string(
                receiver.text.slice(
                    start, end))
        }
        if receiver.kind == "string" &&
           node.value == "byte_at" &&
           arguments.len() == 2 {
            return TreeValue.integer(
                receiver.text.byte_at(
                    arguments[1].int_data))
        }
        if receiver.kind == "string" &&
           (node.value == "find" ||
            node.value == "rfind") &&
           arguments.len() == 2 {
            let found: Option<int> =
                if node.value == "find" {
                    receiver.text.find(
                        arguments[1].text)
                } else {
                    receiver.text.rfind(
                        arguments[1].text)
                }
            match found {
                some(index) => {
                    return TreeValue.option_some(
                        TreeValue.integer(index))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if receiver.kind == "string" &&
           (node.value == "lines" ||
            node.value == "chars") {
            let source: List<string> =
                if node.value == "lines" {
                    receiver.text.lines()
                } else {
                    receiver.text.chars()
                }
            var values: List<TreeValue> = []
            for value: string in source {
                values.push(TreeValue.string(value))
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if receiver.kind == "string" &&
           node.value == "count_chars" &&
           arguments.len() == 3 {
            let from: int = arguments[1].int_data
            let to: int = arguments[2].int_data
            // The same range the runtime refuses, refused here first. Left
            // to the runtime, the panic would carry the position of the
            // call below — a line in this compiler — because that is the
            // only source position the runtime can see from inside a
            // `beansc run`.
            if from < 0 || to < from ||
               to > receiver.text.len() {
                return self.fail(
                    node,
                    "character range {from}..{to} out of range (len {receiver.text.len()})")
            }
            return TreeValue.integer(
                receiver.text.count_chars(from, to))
        }
        if receiver.kind == "string" &&
           node.value == "find_byte" &&
           arguments.len() == 3 {
            return TreeValue.integer(
                receiver.text.find_byte(
                    arguments[1].int_data,
                    arguments[2].int_data))
        }
        if receiver.kind == "string" &&
           node.value == "range_equals" &&
           arguments.len() == 4 {
            return TreeValue.boolean(
                receiver.text.range_equals(
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].text))
        }
        if receiver.kind == "string" &&
           node.value == "parse_int_range_or" &&
           arguments.len() == 4 {
            return TreeValue.integer(
                receiver.text.parse_int_range_or(
                    arguments[1].int_data,
                    arguments[2].int_data,
                    arguments[3].int_data))
        }
        if receiver.kind == "string" &&
           (node.value == "trim" ||
            node.value == "trim_start" ||
            node.value == "trim_end" ||
            node.value == "to_upper" ||
            node.value == "to_lower") {
            if node.value == "trim" {
                return TreeValue.string(
                    receiver.text.trim())
            }
            if node.value == "trim_start" {
                return TreeValue.string(
                    receiver.text.trim_start())
            }
            if node.value == "trim_end" {
                return TreeValue.string(
                    receiver.text.trim_end())
            }
            if node.value == "to_upper" {
                return TreeValue.string(
                    receiver.text.to_upper())
            }
            return TreeValue.string(
                receiver.text.to_lower())
        }
        if receiver.kind == "string" &&
           node.value == "replace" &&
           arguments.len() == 3 {
            return TreeValue.string(
                receiver.text.replace(
                    arguments[1].text,
                    arguments[2].text))
        }
        if receiver.kind == "string" &&
           node.value == "split" &&
           arguments.len() == 2 {
            var pieces: List<TreeValue> = []
            for piece: string in receiver.text.split(
                arguments[1].text) {
                pieces.push(TreeValue.string(piece))
            }
            return TreeValue.sequence(
                "list", move pieces)
        }
        if receiver.kind == "list" &&
           node.value == "push" &&
           arguments.len() == 2 {
            receiver.items.push(
                tree_value_copy(arguments[1]))
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "insert" &&
           arguments.len() == 3 {
            receiver.items.insert(
                arguments[1].int_data,
                tree_value_copy(arguments[2]))
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "pop" {
            if receiver.items.len() == 0 {
                return TreeValue.option_none()
            }
            return TreeValue.option_some(
                receiver.items.pop().expect("non-empty list"))
        }
        if receiver.kind == "list" &&
           (node.value == "first" ||
            node.value == "last") {
            if receiver.items.len() == 0 {
                return TreeValue.option_none()
            }
            let index: int =
                if node.value == "first" {
                    0
                } else {
                    receiver.items.len() - 1
                }
            return TreeValue.option_some(
                tree_value_copy(
                    receiver.items[index]))
        }
        if receiver.kind == "list" &&
           (node.value == "contains" ||
            node.value == "index_of") &&
           arguments.len() == 2 {
            for index: int in 0..receiver.items.len() {
                if tree_value_equal(
                       receiver.items[index],
                       arguments[1]) {
                    if node.value == "contains" {
                        return TreeValue.boolean(true)
                    }
                    return TreeValue.option_some(
                        TreeValue.integer(index))
                }
            }
            if node.value == "contains" {
                return TreeValue.boolean(false)
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "list" &&
           node.value == "remove" &&
           arguments.len() == 2 {
            let index: int = arguments[1].int_data
            if index < 0 ||
               index >= receiver.items.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "list index {index} out of range (len {receiver.items.len()})")
            }
            return receiver.items.remove(
                index)
        }
        if receiver.kind == "list" &&
           node.value == "clear" {
            receiver.items = []
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "clone" {
            var copy: List<TreeValue> = []
            for value: TreeValue in receiver.items {
                copy.push(tree_value_copy(value))
            }
            return TreeValue.sequence(
                "list", move copy)
        }
        if receiver.kind == "list" &&
           node.value == "reverse" {
            var left: int = 0
            var right: int =
                receiver.items.len() - 1
            for left < right {
                let saved: TreeValue =
                    receiver.items[left]
                receiver.items[left] =
                    receiver.items[right]
                receiver.items[right] = saved
                left += 1
                right -= 1
            }
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "slice" &&
           arguments.len() == 3 {
            let start: int = arguments[1].int_data
            let end: int = arguments[2].int_data
            if start < 0 || end < start ||
               end > receiver.items.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "list slice {start}..{end} out of range (len {receiver.items.len()})")
            }
            var values: List<TreeValue> = []
            for index: int in start..end {
                values.push(receiver.items[index])
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if receiver.kind == "list" &&
           (node.value == "min" ||
            node.value == "max") {
            if receiver.items.len() == 0 {
                return TreeValue.option_none()
            }
            var best: TreeValue =
                receiver.items[0]
            for index: int in
                1..receiver.items.len() {
                let candidate: TreeValue =
                    receiver.items[index]
                let replace: bool =
                    if node.value == "min" {
                        tree_value_less(
                            candidate, best)
                    } else {
                        tree_value_less(
                            best, candidate)
                    }
                if replace { best = candidate }
            }
            return TreeValue.option_some(best)
        }
        if receiver.kind == "list" &&
           node.value == "join" &&
           arguments.len() == 2 {
            var pieces: List<string> = []
            for value: TreeValue in receiver.items {
                pieces.push(tree_value_text(value))
            }
            return TreeValue.string(
                pieces.join(arguments[1].text))
        }
        if receiver.kind == "list" &&
           (node.value == "sort" ||
            node.value == "sort_by" ||
            node.value == "sort_by_key") {
            var keys: List<TreeValue> = []
            if node.value == "sort_by_key" &&
               arguments.len() == 2 {
                for value: TreeValue in receiver.items {
                    keys.push(
                        self.invoke_closure(
                            node, arguments[1], [value]))
                }
            }
            var index: int = 1
            for index < receiver.items.len() {
                var current: int = index
                for current > 0 {
                    var less: bool = false
                    if node.value == "sort" {
                        less = tree_value_less(
                            receiver.items[current],
                            receiver.items[current - 1])
                    } else if node.value == "sort_by" &&
                              arguments.len() == 2 {
                        let compared: TreeValue =
                            self.invoke_closure(
                                node, arguments[1],
                                [receiver.items[current],
                                 receiver.items[current - 1]])
                        less = self.truth(node, compared)
                    } else if node.value ==
                                  "sort_by_key" {
                        less = tree_value_less(
                            keys[current],
                            keys[current - 1])
                    }
                    if !less { break }
                    let saved: TreeValue =
                        receiver.items[current - 1]
                    receiver.items[current - 1] =
                        receiver.items[current]
                    receiver.items[current] = saved
                    if node.value == "sort_by_key" {
                        let saved_key: TreeValue =
                            keys[current - 1]
                        keys[current - 1] =
                            keys[current]
                        keys[current] = saved_key
                    }
                    current -= 1
                }
                index += 1
            }
            return TreeValue.unit()
        }
        if receiver.kind == "list" &&
           node.value == "get" &&
           arguments.len() == 2 &&
           arguments[1].kind == "int" {
            let index: int = arguments[1].int_data
            if index >= 0 &&
               index < receiver.items.len() {
                return TreeValue.option_some(
                    tree_value_copy(
                        receiver.items[index]))
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "map" &&
           (node.value == "set" ||
            node.value == "insert") &&
           arguments.len() == 3 {
            let encoded: string =
                self.map_key(
                    receiver, arguments[1])
            let inserted: bool =
                !receiver.map_values.contains_key(encoded)
            if node.value == "insert" &&
               !inserted {
                return TreeValue.boolean(false)
            }
            if !receiver.map_values.contains_key(
                   encoded) {
                receiver.map_keys.push(
                    tree_value_copy(arguments[1]))
                receiver.map_version += 1
            }
            receiver.map_values[encoded] =
                tree_value_copy(arguments[2])
            return if node.value == "insert" {
                TreeValue.boolean(inserted)
            } else {
                TreeValue.unit()
            }
        }
        if receiver.kind == "map" &&
           node.value == "get" &&
           arguments.len() == 2 {
            match receiver.map_values.get(
                self.map_key(
                    receiver, arguments[1])) {
                some(value) => {
                    return TreeValue.option_some(
                        tree_value_copy(value))
                }
                none => {
                    return TreeValue.option_none()
                }
            }
        }
        if receiver.kind == "map" &&
           node.value == "contains_key" &&
           arguments.len() == 2 {
            return TreeValue.boolean(
                receiver.map_values.contains_key(
                    self.map_key(
                        receiver, arguments[1])))
        }
        if receiver.kind == "map" &&
           node.value == "remove" &&
           arguments.len() == 2 {
            let encoded: string =
                self.map_key(
                    receiver, arguments[1])
            if !receiver.map_values.contains_key(encoded) {
                return TreeValue.boolean(false)
            }
            receiver.map_values.remove(encoded)
            var kept: List<TreeValue> = []
            for key: TreeValue in receiver.map_keys {
                if tree_value_key(key) != encoded {
                    kept.push(key)
                }
            }
            receiver.map_keys = move kept
            receiver.map_version += 1
            return TreeValue.boolean(true)
        }
        if receiver.kind == "map" &&
           node.value == "keys" {
            var keys: List<TreeValue> = []
            for key: TreeValue in receiver.map_keys {
                keys.push(tree_value_copy(key))
            }
            return TreeValue.sequence(
                "list", move keys)
        }
        if receiver.kind == "map" &&
           node.value == "values" {
            var values: List<TreeValue> = []
            for key: TreeValue in receiver.map_keys {
                match receiver.map_values.get(
                    tree_value_key(key)) {
                    some(value) => {
                        values.push(
                            tree_value_copy(value))
                    }
                    none => {}
                }
            }
            return TreeValue.sequence(
                "list", move values)
        }
        if receiver.kind == "map" &&
           node.value == "clear" {
            if receiver.map_values.len() != 0 {
                receiver.map_version += 1
            }
            receiver.map_keys = []
            receiver.map_values = {}
            return TreeValue.unit()
        }
        if receiver.kind == "map" &&
           node.value == "clone" {
            let result: TreeValue =
                new TreeValue("map")
            for key: TreeValue in receiver.map_keys {
                let encoded: string =
                    tree_value_key(key)
                result.map_keys.push(
                    tree_value_copy(key))
                result.map_values[encoded] =
                    tree_value_copy(
                        receiver.map_values[encoded])
            }
            return result
        }
        if receiver.kind == "atomic" &&
           receiver.items.len() == 1 {
            if node.value == "load" {
                return tree_value_copy(
                    receiver.items[0])
            }
            if node.value == "store" &&
               arguments.len() >= 2 {
                receiver.items[0] =
                    tree_value_copy(arguments[1])
                return TreeValue.unit()
            }
            if node.value == "exchange" &&
               arguments.len() >= 2 {
                let previous: TreeValue =
                    tree_value_copy(
                        receiver.items[0])
                receiver.items[0] =
                    tree_value_copy(arguments[1])
                return previous
            }
            if node.value == "compare_exchange" &&
               arguments.len() >= 3 {
                let equal: bool =
                    tree_value_equal(
                        receiver.items[0],
                        arguments[1])
                if equal {
                    receiver.items[0] =
                        tree_value_copy(
                            arguments[2])
                }
                return TreeValue.boolean(equal)
            }
            if (node.value == "fetch_add" ||
                node.value == "fetch_sub" ||
                node.value == "fetch_and" ||
                node.value == "fetch_or" ||
                node.value == "fetch_xor") &&
               arguments.len() >= 2 {
                let previous: TreeValue =
                    tree_value_copy(
                        receiver.items[0])
                let left: u64 =
                    previous.uint_data
                let right: u64 =
                    arguments[1].uint_data
                var raw: u64 = left
                if node.value == "fetch_add" {
                    raw = left + right
                } else if node.value ==
                              "fetch_sub" {
                    raw = left - right
                } else if node.value ==
                              "fetch_and" {
                    raw = left & right
                } else if node.value ==
                              "fetch_or" {
                    raw = left | right
                } else {
                    raw = left ^ right
                }
                receiver.items[0] =
                    if previous.int_unsigned {
                        TreeValue.unsigned_integer(
                            raw,
                            previous.int_bits)
                    } else {
                        TreeValue.signed_integer(
                            tree_signed_from_bits(
                                raw,
                                previous.int_bits),
                            previous.int_bits)
                    }
                return previous
            }
            if node.value == "wait" {
                return TreeValue.unit()
            }
            if node.value == "wait_timeout" &&
               arguments.len() >= 2 {
                return TreeValue.boolean(
                    !tree_value_equal(
                        receiver.items[0],
                        arguments[1]))
            }
            if node.value == "notify_all" ||
               node.value == "notify_one" {
                return TreeValue.integer(0)
            }
        }
        if (receiver.kind == "box" ||
            receiver.kind == "mutex") &&
           node.value == "get" &&
           receiver.items.len() == 1 {
            return receiver.items[0]
        }
        if receiver.kind == "atomic" &&
           node.value == "load" &&
           receiver.items.len() == 1 {
            return receiver.items[0]
        }
        if receiver.kind == "shared" &&
           node.value == "get" {
            match receiver.shared_value {
                some(value) => {
                    return tree_value_copy(
                        value.get())
                }
                none => {}
            }
        }
        if receiver.kind == "box" &&
           node.value == "set" &&
           arguments.len() == 2 {
            receiver.items[0] = arguments[1]
            return TreeValue.unit()
        }
        if receiver.kind == "atomic" &&
           node.value == "store" &&
           arguments.len() == 2 {
            receiver.items[0] = arguments[1]
            return TreeValue.unit()
        }
        if receiver.kind == "atomic" &&
           node.value == "add_and_get" &&
           arguments.len() == 2 &&
           receiver.items.len() == 1 {
            let next: int =
                receiver.items[0].int_data +
                arguments[1].int_data
            receiver.items[0] =
                TreeValue.integer(next)
            return TreeValue.integer(next)
        }
        if receiver.kind == "shared" &&
           node.value == "downgrade" {
            let result: TreeValue =
                new TreeValue("weak")
            match receiver.shared_value {
                some(value) => {
                    result.weak_value =
                        some(value.downgrade())
                }
                none => {}
            }
            return result
        }
        if receiver.kind == "weak" &&
           node.value == "is_expired" {
            match receiver.weak_value {
                some(value) => {
                    return TreeValue.boolean(
                        value.is_expired())
                }
                none => {}
            }
            return TreeValue.boolean(true)
        }
        if receiver.kind == "weak" &&
           node.value == "upgrade" {
            match receiver.weak_value {
                some(value) => {
                    match value.upgrade() {
                        some(shared) => {
                            let result: TreeValue =
                                new TreeValue("shared")
                            result.shared_value =
                                some(shared)
                            return TreeValue.option_some(
                                result)
                        }
                        none => {}
                    }
                }
                none => {}
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "arena" &&
           node.value == "add" &&
           arguments.len() == 2 {
            let slot: int = receiver.items.len()
            receiver.items.push(
                tree_value_copy(arguments[1]))
            return TreeValue.integer(slot)
        }
        if receiver.kind == "arena" &&
           node.value == "get" &&
           arguments.len() == 2 {
            let slot: int = arguments[1].int_data
            if slot >= 0 &&
               slot < receiver.items.len() {
                return TreeValue.option_some(
                    tree_value_copy(
                        receiver.items[slot]))
            }
            return TreeValue.option_none()
        }
        if receiver.kind == "arena" &&
           node.value == "clear" {
            receiver.items = []
            return TreeValue.unit()
        }
        if receiver.kind == "arena" &&
           node.value == "len" {
            return TreeValue.integer(
                receiver.items.len())
        }
        if receiver.kind == "arena" &&
           node.value == "at" &&
           arguments.len() == 2 {
            let slot: int = arguments[1].int_data
            if slot < 0 ||
               slot >= receiver.items.len() {
                return self.fail_at(
                    node,
                    node.col,
                    "arena handle {slot} out of range (len {receiver.items.len()})")
            }
            return tree_value_copy(
                receiver.items[slot])
        }
        if receiver.kind == "channel" &&
           node.value == "try_send" &&
           arguments.len() == 2 {
            return TreeValue.boolean(
                self.tree_channel_send_wait(
                    node, receiver, arguments[1], false))
        }
        if receiver.kind == "channel" &&
           node.value == "send" &&
           arguments.len() == 2 {
            if !self.tree_channel_send(
                   node, receiver, arguments[1]) {
                if !self.failed {
                    return self.fail(
                        node, "send on closed channel")
                }
            }
            return TreeValue.unit()
        }
        if receiver.kind == "channel" &&
           (node.value == "receive" ||
            node.value == "try_receive") {
            match self.tree_channel_receive_wait(
                node, receiver, node.value == "receive") {
                some(value) => {
                    return TreeValue.option_some(value)
                }
                none => { return TreeValue.option_none() }
            }
        }
        if receiver.kind == "channel" &&
           node.value == "close" {
            receiver.bool_data = true
            self.tree_channel_close(receiver)
            return TreeValue.unit()
        }
        if receiver.kind == "gate" {
            var gate: RawPtr<u8> = RawPtr.null()
            unsafe {
                gate =
                    RawPtr.from_address(
                        receiver.int_data as u64)
            }
            if node.value == "wait" {
                unsafe { beans_gate_wait(gate) }
                return TreeValue.unit()
            }
            if node.value == "open" {
                unsafe { beans_gate_open(gate) }
                return TreeValue.unit()
            }
            if node.value == "is_open" {
                var open: int = 0
                unsafe {
                    open = beans_gate_is_open(gate)
                }
                return TreeValue.boolean(open != 0)
            }
        }
        if receiver.kind == "thread" &&
           node.value == "join" {
            if receiver.items.len() == 1 {
                return tree_value_copy(
                    receiver.items[0])
            }
            match receiver.thread_handle {
                some(handle) => {
                    handle.join()
                }
                none => {
                    return self.fail(
                        node,
                        "thread has no host handle")
                }
            }
            var result: TreeValue =
                TreeValue.unit()
            match receiver.thread_work {
                some(work) => {
                    work.with_lock(
                        fn(state: TreeThreadWork) {
                            if state.failed {
                                self.failed = true
                                self.panic_text =
                                    state.panic_text
                            }
                            match state.result {
                                some(value) => {
                                    result =
                                        tree_value_copy(
                                            value)
                                }
                                none => {}
                            }
                        })
                }
                none => {}
            }
            receiver.items = [
                tree_value_copy(result)]
            return result
        }
        if receiver.kind == "thread" &&
           node.value == "detach" {
            match receiver.thread_handle {
                some(_) => {
                    receiver.thread_handle = none
                    receiver.thread_work = none
                    return TreeValue.unit()
                }
                none => {
                    return self.fail(
                        node,
                        "thread already joined or detached")
                }
            }
        }
        if receiver.kind == "brew" &&
           node.value == "cancel" {
            match receiver.brew_work {
                some(work) => {
                    if !work.reaped && work.fiber != 0 {
                        unsafe {
                            beans_fiber_cancel(
                                RawPtr.from_address(work.fiber))
                        }
                    }
                    return TreeValue.unit()
                }
                none => {
                    return self.fail(
                        node, "brew handle has no fiber")
                }
            }
        }
        if receiver.kind == "brew" &&
           node.value == "join" {
            match receiver.brew_work {
                some(work) => {
                    if work.joined {
                        return TreeValue.result_err(
                            TreeValue.error(
                                "brew handle already joined",
                                "closed"))
                    }
                    self.tree_brew_reap(work)
                    work.joined = true
                    if work.panicked {
                        return TreeValue.result_err(
                            TreeValue.error(
                                work.panic_message, "panic"))
                    }
                    match work.result {
                        some(delivered) => {
                            return TreeValue.result_ok(
                                tree_value_copy(delivered))
                        }
                        none => {
                            return TreeValue.result_ok(
                                TreeValue.unit())
                        }
                    }
                }
                none => {
                    return self.fail(
                        node, "brew handle has no fiber")
                }
            }
        }
        if receiver.kind == "brew" &&
           node.value == "brew_scope_join" {
            match receiver.brew_work {
                some(work) => {
                    if work.joined { return TreeValue.unit() }
                    self.tree_brew_reap(work)
                    work.joined = true
                    if work.panicked {
                        return self.fail(
                            node,
                            "a brewed fiber panicked with no join to catch it: {work.panic_message}")
                    }
                    return TreeValue.unit()
                }
                none => {
                    return self.fail(
                        node, "brew handle has no fiber")
                }
            }
        }
        if receiver.kind == "taskgroup" &&
           (node.value == "next" ||
            node.value == "try_next") {
            match receiver.group_work {
                some(state) => {
                    for true {
                        let found: int =
                            self.tree_group_pick(state)
                        if found >= 0 {
                            return TreeValue.option_some(
                                self.tree_group_claim(
                                    state, found))
                        }
                        var live: bool = false
                        for work: TreeBrewState in
                            state.children {
                            if !work.joined { live = true }
                        }
                        if !live || node.value == "try_next" {
                            return TreeValue.option_none()
                        }
                        self.tree_group_park(state)
                    }
                    return TreeValue.option_none()
                }
                none => {
                    return self.fail(
                        node, "group has no state")
                }
            }
        }
        if receiver.kind == "taskgroup" &&
           node.value == "wait_all" {
            match receiver.group_work {
                some(state) => {
                    for true {
                        var pending: bool = false
                        for work: TreeBrewState in
                            state.children {
                            if !work.joined &&
                               work.done_stamp == 0 {
                                pending = true
                            }
                        }
                        if !pending { break }
                        self.tree_group_park(state)
                    }
                    // Join in spawn order: the first failure is the
                    // fleet's answer, and every other outcome is
                    // dropped once everyone was joined.
                    var failure: Option<TreeValue> = none
                    var collected: List<TreeValue> = []
                    for work: TreeBrewState in
                        state.children {
                        if !work.joined {
                            self.tree_brew_reap(work)
                            work.joined = true
                            if work.panicked {
                                if failure.is_none() {
                                    failure = some(
                                        TreeValue.error(
                                            work.panic_message,
                                            "panic"))
                                }
                            } else {
                                match work.result {
                                    some(value) => {
                                        collected.push(
                                            tree_value_copy(
                                                value))
                                    }
                                    none => {
                                        collected.push(
                                            TreeValue.unit())
                                    }
                                }
                            }
                        }
                    }
                    state.children = []
                    state.delivered = 0
                    match failure {
                        some(error) => {
                            return TreeValue.result_err(
                                error)
                        }
                        none => {
                            return TreeValue.result_ok(
                                TreeValue.sequence(
                                    "list", move collected))
                        }
                    }
                }
                none => {
                    return self.fail(
                        node, "group has no state")
                }
            }
        }
        if receiver.kind == "taskgroup" &&
           node.value == "cancel_all" {
            match receiver.group_work {
                some(state) => {
                    // Newest-first cancels, then join everyone and drop
                    // every outcome — handling by discard, the spec's
                    // cancel_all contract.
                    var index: int = state.children.len()
                    for index > 0 {
                        index -= 1
                        let work: TreeBrewState =
                            state.children[index]
                        if !work.reaped && work.fiber != 0 {
                            unsafe {
                                beans_fiber_cancel(
                                    RawPtr.from_address(
                                        work.fiber))
                            }
                        }
                    }
                    for work: TreeBrewState in
                        state.children {
                        if !work.joined {
                            self.tree_brew_reap(work)
                            work.joined = true
                        }
                    }
                    state.children = []
                    state.delivered = 0
                    return TreeValue.unit()
                }
                none => {
                    return self.fail(
                        node, "group has no state")
                }
            }
        }
        if receiver.kind == "taskgroup" &&
           node.value == "taskgroup_scope_join" {
            match receiver.group_work {
                some(state) => {
                    for work: TreeBrewState in
                        state.children {
                        if !work.joined {
                            self.tree_brew_reap(work)
                            work.joined = true
                            if work.panicked {
                                return self.fail(
                                    node,
                                    "a brewed fiber panicked with no join to catch it: {work.panic_message}")
                            }
                        }
                    }
                    state.children = []
                    state.delivered = 0
                    return TreeValue.unit()
                }
                none => {
                    return self.fail(
                        node, "group has no state")
                }
            }
        }
        if receiver.kind == "mutex" &&
           node.value == "with_lock" &&
           arguments.len() == 2 &&
           (arguments[1].kind == "closure" ||
            arguments[1].kind == "function") {
            var result: TreeValue =
                TreeValue.unit()
            match receiver.mutex_cell {
                some(cell) => {
                    cell.with_lock(
                        fn(state: TreeMutexCell) {
                            let holder: TreeFrame =
                                new TreeFrame()
                            holder.set(
                                -1, state.value)
                            result =
                                self.invoke_closure(
                                    node, arguments[1],
                                    [TreeValue.reference(
                                        holder, -1)])
                            match holder.get(-1) {
                                some(value) => {
                                    state.value = value
                                }
                                none => {}
                            }
                        })
                }
                none => {
                    return self.fail(
                        node,
                        "mutex has no host lock")
                }
            }
            return result
        }
        if (receiver.kind == "map" ||
            receiver.kind == "list") &&
           node.value == "reserve" {
            if receiver.kind == "map" {
                receiver.map_version += 1
            }
            return TreeValue.unit()
        }
        if receiver.kind == "string" &&
           node.value == "to_int" {
            match receiver.text.to_int() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.integer(value))
                }
                err(message) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            message.msg,
                            message.kind))
                }
            }
        }
        if receiver.kind == "string" &&
           node.value == "to_float" {
            match receiver.text.to_float() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.floating(value))
                }
                err(message) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            message.msg,
                            message.kind))
                }
            }
        }
        if receiver.kind == "string" &&
           node.value == "to_decimal" {
            match receiver.text.to_decimal() {
                ok(value) => {
                    return TreeValue.result_ok(
                        TreeValue.decimal_value(value))
                }
                err(message) => {
                    return TreeValue.result_err(
                        TreeValue.error(
                            message.msg,
                            message.kind))
                }
            }
        }
        if (receiver.kind == "some" ||
            receiver.kind == "none" ||
            receiver.kind == "ok" ||
            receiver.kind == "err") &&
           (node.value == "map" ||
            node.value == "and_then" ||
            node.value == "filter" ||
            node.value == "recover") &&
           arguments.len() == 2 &&
           arguments[1].kind == "closure" {
            let active: bool =
                receiver.kind == "some" ||
                receiver.kind == "ok"
            if node.value == "recover" {
                if active && receiver.items.len() == 1 {
                    return tree_value_copy(
                        receiver.items[0])
                }
                if receiver.kind == "err" &&
                   receiver.items.len() == 1 {
                    return self.invoke_closure(
                        node, arguments[1],
                        [receiver.items[0]])
                }
                return TreeValue.unit()
            }
            if !active {
                return if receiver.kind == "none" {
                    TreeValue.option_none()
                } else {
                    receiver
                }
            }
            if receiver.items.len() != 1 {
                return self.fail(
                    node,
                    "{receiver.kind} has no payload")
            }
            if node.value == "filter" {
                let kept: TreeValue =
                    self.invoke_closure(
                        node, arguments[1],
                        [receiver.items[0]])
                if self.truth(node, kept) {
                    return receiver
                }
                return TreeValue.option_none()
            }
            let mapped: TreeValue =
                self.invoke_closure(
                    node, arguments[1],
                    [receiver.items[0]])
            if node.value == "and_then" {
                return mapped
            }
            return if receiver.kind == "some" {
                TreeValue.option_some(mapped)
            } else {
                TreeValue.result_ok(mapped)
            }
        }
        if (receiver.kind == "some" ||
            receiver.kind == "none") &&
           (node.value == "is_some" ||
            node.value == "is_none") {
            return TreeValue.boolean(
                if node.value == "is_some" {
                    receiver.kind == "some"
                } else {
                    receiver.kind == "none"
                })
        }
        if (receiver.kind == "ok" ||
            receiver.kind == "err") &&
           node.value == "is_ok" {
            return TreeValue.boolean(
                receiver.kind == "ok")
        }
            if (receiver.kind == "some" ||
            receiver.kind == "ok") &&
           receiver.items.len() == 1 &&
           (node.value == "or" ||
            node.value == "expect") {
            return tree_value_copy(
                receiver.items[0])
        }
        if (receiver.kind == "none" ||
            receiver.kind == "err") &&
           node.value == "or" &&
           arguments.len() == 2 {
            return arguments[1]
        }
        if (receiver.kind == "none" ||
            receiver.kind == "err") &&
           node.value == "expect" {
            let message: string =
                if arguments.len() > 1 {
                    tree_value_text(arguments[1])
                } else {
                    "expected a value"
                }
            return self.fail(node, message)
        }
        return self.fail(
            node,
            "builtin method '{node.resolved}' is not in the Beans interpreter yet")
    }

    // A closure used to keep its whole creation frame alive. A local in
    // that frame holding the closure back (through an object field) then
    // made a host-level cycle the program never wrote — frame -> object
    // -> closure -> frame — and the frame's deinits never ran, where the
    // native backend runs them at end of scope. Capture only the
    // bindings the body actually names, each promoted to the shared
    // cell TreeFrame.snapshot uses, so mutation stays shared through
    // the cell and nothing else rides along. A closure that names the
    // object holding it still cycles — the same cycle the native
    // reference counts would leak, per the TreeObjectValue note.
    fn closure(node: HirNode,
               frame: TreeFrame) -> TreeValue {
        let result: TreeValue =
            new TreeValue("closure")
        result.closure_node = some(node)
        let captured: TreeFrame = new TreeFrame()
        self.collect_closure_captures(
            node, frame, captured)
        result.closure_frame = some(captured)
        result.generic_types = self.current_type_bindings()
        return result
    }

    fn collect_closure_captures(node: HirNode,
                                frame: TreeFrame,
                                captured: TreeFrame) {
        if node.kind == "local" &&
           node.binding_id >= 0 &&
           !captured.values.contains_key(node.binding_id) {
            match self.capture_cell(
                    frame, node.binding_id) {
                some(cell) => {
                    captured.values[node.binding_id] =
                        cell
                }
                none => {}
            }
        }
        for child: HirNode in node.children {
            self.collect_closure_captures(
                child, frame, captured)
        }
    }

    // The owner's slot is promoted to a reference into a one-slot
    // holder frame, the same shape TreeFrame.snapshot leaves behind,
    // and both sides keep that one cell: assignments follow the
    // reference, so the closure and the enclosing scope stay in sync.
    // A binding the body names but declares itself is not in the
    // enclosing chain yet and comes back none.
    fn capture_cell(frame: TreeFrame,
                    binding: int) -> Option<TreeValue> {
        if frame.values.contains_key(binding) {
            let current: TreeValue =
                frame.values[binding]
            if current.kind == "reference" {
                return some(current)
            }
            let holder: TreeFrame = new TreeFrame()
            holder.values[-1] = current
            let cell: TreeValue =
                TreeValue.reference(holder, -1)
            frame.values[binding] = cell
            return some(cell)
        }
        match frame.parent {
            some(outer) => {
                return self.capture_cell(
                    outer, binding)
            }
            none => { return none }
        }
    }

    // brew — evaluate the hoisted argument bindings, wrap the fabricated
    // closure in a stored callback, and start it on a child fiber of this
    // worker. The tree walker re-enters on the fiber's own stack when the
    // walker's current fiber parks.
    fn tree_brew(node: HirNode,
                 frame: TreeFrame) -> TreeValue {
        var closure_value: TreeValue = TreeValue.unit()
        var seen_closure: bool = false
        for child: HirNode in node.children {
            if child.kind == "closure" {
                closure_value =
                    self.expression(child, frame)
                seen_closure = true
            } else {
                // a hoisted argument let; `?` in an argument propagates
                // from the enclosing function, so the value bubbles out
                let value: TreeValue =
                    if child.children.len() == 0 {
                        TreeValue.unit()
                    } else {
                        self.expression(
                            child.children[0], frame)
                    }
                if value.kind == "propagate" {
                    return value
                }
                frame.set(
                    child.binding_id,
                    tree_value_copy(value))
            }
        }
        if self.failed { return TreeValue.unit() }
        if !seen_closure {
            return self.fail(
                node, "brew has no closure to start")
        }
        // A plain class, aliased by the handle and the entry closure: the
        // fiber is pinned to this thread, so the entry rides the
        // same-thread LocalStoredCallback and nothing needs a lock. (A
        // Mutex here would be held across the child's parks — the first
        // parked child would deadlock its own join.)
        let work: TreeBrewState =
            new TreeBrewState(self, closure_value, node)
        let entry:
            LocalStoredCallback<fn(RawPtr<u8>)> =
            LocalStoredCallback.create(
                0,
                fn() {
                    work.run()
                })
        // The fiber core copies the report name at spawn, so a transient
        // NUL-terminated buffer is enough to match native's fiber names.
        var name_bytes: Bytes = new Bytes(0)
        name_bytes.append_string(
            if node.value != "" { node.value } else { "brew" })
        name_bytes.append(new Bytes(1))
        var address: u64 = 0
        var context: u64 = 0
        unsafe {
            beans_worker_bootstrap()
            context = entry.context().address()
            let fiber: RawPtr<u8> =
                beans_fiber_spawn(
                    beans_worker_current(),
                    entry.function(),
                    entry.context(),
                    name_bytes.as_ptr(),
                    8388608)
            address = fiber.address()
        }
        if address == 0 {
            return self.fail(
                node,
                "brew could not reserve a fiber stack")
        }
        work.fiber = address
        work.entry_context = context
        let result: TreeValue = new TreeValue("brew")
        result.brew_work = some(work)
        return result
    }

    // Parks until the fiber finishes, then retires the C record and closes
    // the entry callback — exactly once.
    fn tree_brew_reap(work: TreeBrewState) {
        if work.reaped { return }
        unsafe {
            beans_fiber_join(
                RawPtr.from_address(work.fiber),
                RawPtr.null(), 0)
            if work.entry_context != 0 {
                beans_stored_callback_close(
                    RawPtr.from_address(work.entry_context))
            }
        }
        work.reaped = true
        work.entry_context = 0
    }

    // group.brew — the fleet flavor of tree_brew (spec/CONCURRENCY.md,
    // F3): the same hoist-and-spawn, but the group keeps the row and the
    // entry's tail stamps completion order and wakes the group's parked
    // waiter. Panics included: an interpreted panic still returns through
    // run(), so a panicked child gets its stamp exactly as native's fiber
    // done hook gives one.
    fn tree_group_brew(node: HirNode,
                       frame: TreeFrame) -> TreeValue {
        if node.children.len() < 2 {
            return self.fail(
                node, "group.brew has no group or closure")
        }
        let receiver: TreeValue =
            self.expression(node.children[0], frame)
        if receiver.kind == "propagate" { return receiver }
        match receiver.group_work {
            some(state) => {
                return self.tree_group_brew_start(
                    node, frame, state)
            }
            none => {
                return self.fail(
                    node,
                    "group.brew needs a TaskGroup receiver")
            }
        }
    }

    fn tree_group_brew_start(
        node: HirNode, frame: TreeFrame,
        state: TreeTaskGroupState) -> TreeValue {
        var closure_value: TreeValue = TreeValue.unit()
        var seen_closure: bool = false
        for index: int in 1..node.children.len() {
            let child: HirNode = node.children[index]
            if child.kind == "closure" {
                closure_value =
                    self.expression(child, frame)
                seen_closure = true
            } else {
                let value: TreeValue =
                    if child.children.len() == 0 {
                        TreeValue.unit()
                    } else {
                        self.expression(
                            child.children[0], frame)
                    }
                if value.kind == "propagate" {
                    return value
                }
                frame.set(
                    child.binding_id,
                    tree_value_copy(value))
            }
        }
        if self.failed { return TreeValue.unit() }
        if !seen_closure {
            return self.fail(
                node, "group.brew has no closure to start")
        }
        let work: TreeBrewState =
            new TreeBrewState(self, closure_value, node)
        let entry:
            LocalStoredCallback<fn(RawPtr<u8>)> =
            LocalStoredCallback.create(
                0,
                fn() {
                    work.run()
                    state.clock = state.clock + 1
                    work.done_stamp = state.clock
                    if state.waiter != 0 {
                        let parked: u64 = state.waiter
                        state.waiter = 0
                        unsafe {
                            beans_fiber_resume(
                                RawPtr.from_address(parked))
                        }
                    }
                })
        var name_bytes: Bytes = new Bytes(0)
        name_bytes.append_string(
            if node.value != "" { node.value } else { "brew" })
        name_bytes.append(new Bytes(1))
        var address: u64 = 0
        var context: u64 = 0
        unsafe {
            beans_worker_bootstrap()
            context = entry.context().address()
            let fiber: RawPtr<u8> =
                beans_fiber_spawn(
                    beans_worker_current(),
                    entry.function(),
                    entry.context(),
                    name_bytes.as_ptr(),
                    8388608)
            address = fiber.address()
        }
        if address == 0 {
            return self.fail(
                node,
                "brew could not reserve a fiber stack")
        }
        work.fiber = address
        work.entry_context = context
        state.children.push(work)
        return TreeValue.unit()
    }

    // The undelivered row with the smallest completion stamp, or -1. A
    // joined row counts as delivered; the clock is strictly increasing,
    // so spawn order only ever breaks the tie of "not finished yet".
    fn tree_group_pick(state: TreeTaskGroupState) -> int {
        var best: int = -1
        var best_stamp: int = 0
        var index: int = 0
        for work: TreeBrewState in state.children {
            if !work.joined && work.done_stamp != 0 &&
               (best < 0 || work.done_stamp < best_stamp) {
                best = index
                best_stamp = work.done_stamp
            }
            index += 1
        }
        return best
    }

    // Joins one finished row and dresses its outcome as Result<T> — the
    // tree mirror of the boxed join arm the native next() builds.
    fn tree_group_claim(state: TreeTaskGroupState,
                        found: int) -> TreeValue {
        let work: TreeBrewState = state.children[found]
        self.tree_brew_reap(work)
        work.joined = true
        state.delivered += 1
        if state.delivered == state.children.len() {
            state.children = []
            state.delivered = 0
        }
        if work.panicked {
            return TreeValue.result_err(
                TreeValue.error(
                    work.panic_message, "panic"))
        }
        match work.result {
            some(delivered) => {
                return TreeValue.result_ok(
                    tree_value_copy(delivered))
            }
            none => {
                return TreeValue.result_ok(
                    TreeValue.unit())
            }
        }
    }

    // Parks the walker's own fiber as the group's one waiter. Wakes can
    // be spurious, and cancellation stays interim-invisible — the caller
    // loops on its condition, the contract every std park holds to.
    fn tree_group_park(state: TreeTaskGroupState) {
        unsafe {
            state.waiter =
                beans_fiber_current().address()
            beans_fiber_park()
            state.waiter = 0
        }
    }

    fn invoke_closure(node: HirNode,
                      closure: TreeValue,
                      arguments: List<TreeValue>) -> TreeValue {
        if closure.kind == "function" {
            match self.find_function(
                    closure.text) {
                some(function) => {
                    return self.invoke(
                        function, arguments,
                        none)
                }
                none => {
                    return self.fail(
                        node,
                        "unknown function '{closure.text}'")
                }
            }
        }
        var syntax: Option<HirNode> =
            closure.closure_node
        var captured: Option<TreeFrame> =
            closure.closure_frame
        match syntax {
            some(function) => {
                match captured {
                    some(outer) => {
                        self.generic_type_bindings.push(
                            copy_type_map(closure.generic_types))
                        let frame: TreeFrame =
                            TreeFrame.captured(outer)
                        var argument: int = 0
                        var body: Option<HirNode> = none
                        for child: HirNode in
                            function.children {
                            if child.kind ==
                                   "closure_parameter" {
                                if argument <
                                       arguments.len() {
                                    frame.set(
                                        child.binding_id,
                                        tree_value_copy(
                                            arguments[argument]))
                                }
                                argument += 1
                            } else if child.kind == "block" {
                                body = some(child)
                            }
                        }
                        var result: TreeValue =
                            TreeValue.unit()
                        match body {
                            some(block) => {
                                let flow: TreeExec =
                                    self.block(block, frame)
                                if flow.kind == "return" {
                                    result = flow.value
                                }
                            }
                            none => {
                                self.generic_type_bindings.remove(
                                    self.generic_type_bindings.len() - 1)
                                return self.fail(
                                    node,
                                    "closure has no body")
                            }
                        }
                        self.run_defers(frame)
                        self.generic_type_bindings.remove(
                            self.generic_type_bindings.len() - 1)
                        return result
                    }
                    none => {}
                }
            }
            none => {}
        }
        return self.fail(
            node, "invalid closure value")
    }

    fn closure_call(node: HirNode,
                    frame: TreeFrame) -> TreeValue {
        if node.children.len() == 0 {
            return self.fail(
                node, "closure call has no callee")
        }
        let callee: TreeValue =
            self.expression(node.children[0], frame)
        if callee.kind == "propagate" {
            return callee
        }
        if callee.kind != "closure" &&
           callee.kind != "function" {
            return self.fail(
                node, "{callee.kind} is not callable")
        }
        var arguments: List<TreeValue> = []
        for index: int in 1..node.children.len() {
            let value: TreeValue =
                self.expression(
                    node.children[index], frame)
            if value.kind == "propagate" {
                return value
            }
            arguments.push(value)
        }
        return self.invoke_closure(
            node, callee, move arguments)
    }

    fn tree_log_level(name: string) -> int {
        let shown: string = display_symbol(name)
        if shown == "std.log.trace" ||
           shown == "std.log.Logger.trace" { return 0 }
        if shown == "std.log.debug" ||
           shown == "std.log.Logger.debug" { return 1 }
        if shown == "std.log.info" ||
           shown == "std.log.Logger.info" { return 2 }
        if shown == "std.log.warn" ||
           shown == "std.log.Logger.warn" { return 3 }
        if shown == "std.log.error" ||
           shown == "std.log.Logger.error" { return 4 }
        if shown == "std.log.fatal" ||
           shown == "std.log.Logger.fatal" { return 5 }
        return -1
    }

    fn active_function_name() -> string {
        if self.active_functions.len() == 0 { return "" }
        return display_symbol(
            self.active_functions[
                self.active_functions.len() - 1])
    }

    fn call(node: HirNode,
            frame: TreeFrame) -> TreeValue {
        if node.kind == "runtime_hook_call" &&
           self.runtime_hook_active {
            return TreeValue.unit()
        }
        let early_log_level: int =
            if node.kind == "call" ||
               node.kind == "method_call" {
                self.tree_log_level(node.resolved)
            } else {
                -1
            }
        if early_log_level >= 0 &&
           node.kind == "call" &&
           node.children.len() == 1 {
            match self.find_function(package_symbol(
                    "std.log", "default_enabled_code")) {
                some(enabled_function) => {
                    let enabled: TreeValue = self.invoke(
                        enabled_function,
                        [TreeValue.integer(early_log_level)],
                        none)
                    if !self.truth(node, enabled) {
                        return TreeValue.boolean(false)
                    }
                }
                none => {}
            }
            let message: TreeValue =
                self.expression(node.children[0], frame)
            if self.failed { return TreeValue.unit() }
            if message.kind == "propagate" { return message }
            match self.find_function(package_symbol(
                    "std.log", "default_write_enabled_at_code")) {
                some(function) => {
                    return self.invoke(
                        function,
                        [TreeValue.integer(early_log_level),
                         message,
                         TreeValue.string(node.file),
                         TreeValue.string(self.active_function_name()),
                         TreeValue.integer(node.line),
                         TreeValue.integer(node.col)],
                        none)
                }
                none => {}
            }
        }
        if early_log_level >= 0 &&
           node.kind == "method_call" &&
           node.children.len() == 2 {
            let receiver: TreeValue =
                self.expression(node.children[0], frame)
            if self.failed { return TreeValue.unit() }
            if receiver.kind == "propagate" { return receiver }
            match self.find_function(package_symbol(
                    "std.log", "logger_enabled_code")) {
                some(enabled_function) => {
                    let enabled: TreeValue = self.invoke(
                        enabled_function,
                        [tree_value_copy(receiver),
                         TreeValue.integer(early_log_level)],
                        none)
                    if !self.truth(node, enabled) {
                        return TreeValue.boolean(false)
                    }
                }
                none => {}
            }
            let message: TreeValue =
                self.expression(node.children[1], frame)
            if self.failed { return TreeValue.unit() }
            if message.kind == "propagate" { return message }
            match self.find_function(package_symbol(
                    "std.log", "Logger.log_at_code")) {
                some(function) => {
                    return self.invoke(
                        function,
                        [TreeValue.integer(early_log_level),
                         message,
                         TreeValue.string(node.file),
                         TreeValue.string(self.active_function_name()),
                         TreeValue.integer(node.line),
                         TreeValue.integer(node.col)],
                        some(receiver))
                }
                none => {}
            }
        }
        var arguments: List<TreeValue> = []
        for child: HirNode in node.children {
            let argument: TreeValue =
                self.expression(child, frame)
            if self.failed {
                return TreeValue.unit()
            }
            if argument.kind == "propagate" {
                return argument
            }
            arguments.push(argument)
        }
        let module_log_level: int =
            if node.kind == "call" {
                self.tree_log_level(node.resolved)
            } else {
                -1
            }
        if module_log_level >= 0 && arguments.len() == 1 {
            match self.find_function(
                    package_symbol(
                        "std.log", "default_write_at_code")) {
                some(function) => {
                    return self.invoke(
                        function,
                        [TreeValue.integer(module_log_level),
                         arguments[0],
                         TreeValue.string(node.file),
                         TreeValue.string(self.active_function_name()),
                         TreeValue.integer(node.line),
                         TreeValue.integer(node.col)],
                        none)
                }
                none => {}
            }
        }
        if node.kind == "call" &&
           display_symbol(node.resolved) ==
               "std.reflect.value" &&
           arguments.len() == 1 &&
           node.children.len() == 1 {
            let handle: int = self.next_reflect_value
            self.next_reflect_value += 1
            self.reflect_values[handle] = arguments[0]
            self.reflect_value_types[handle] =
                render_hir_type(self.runtime_type(
                    node.children[0].type,
                    self.current_type_bindings()))
            let result: TreeValue =
                self.object_value(node.type.name)
            result.text = node.type.name
            result.object_id = self.next_object_id
            self.next_object_id += 1
            result.fields.entries["handle"] =
                TreeValue.integer(handle)
            return result
        }
        if node.kind == "call" &&
           display_symbol(node.resolved) ==
               "std.encoding.json.encode" &&
           arguments.len() == 1 {
            return self.tree_json_encode(arguments[0], none)
        }
        if node.kind == "call" &&
           display_symbol(node.resolved) ==
               "std.encoding.json.encode_pretty" &&
           arguments.len() == 2 {
            return self.tree_json_encode(
                arguments[0], some(arguments[1].text))
        }
        if node.kind == "builtin_call" {
            return self.builtin_call(node, move arguments)
        }
        if node.kind == "builtin_method" {
            return self.builtin_method(
                node, move arguments)
        }
        if node.kind == "static_call" &&
           node.resolved == "Atomic.fence" {
            return TreeValue.unit()
        }
        if node.kind == "static_call" &&
           (node.resolved.starts_with(
                "StoredCallback.create:") ||
            node.resolved.starts_with(
                "LocalStoredCallback.create:")) {
            return self.create_stored_callback(
                node, arguments)
        }
        if node.kind == "static_call" &&
           node.resolved == "CFunctionPtr.null" {
            let callback_type: HirType =
                if node.type.args.len() == 1 {
                    node.type.args[0]
                } else {
                    new HirType("poison")
                }
            return TreeValue.host_pointer(
                0, callback_type)
        }
        if node.kind == "static_call" {
            match self.file_static(
                    node, arguments) {
                some(value) => { return value }
                none => {}
            }
            match self.raw_static(
                    node, arguments) {
                some(value) => { return value }
                none => {}
            }
        }
        if node.kind == "static_call" &&
           (node.resolved == "float.infinity" ||
            node.resolved == "f32.infinity") {
            return TreeValue.floating(
                tree_float_infinity())
        }
        if node.kind == "static_call" &&
           node.resolved == "Bytes.filled" &&
           arguments.len() == 2 {
            let size: int = arguments[0].int_data
            if size < 0 {
                return self.fail_at(
                    node, node.col,
                    "negative size {size}")
            }
            let data: Bytes = new Bytes(size)
            data.fill(arguments[1].int_data)
            return TreeValue.bytes(move data)
        }
        if node.kind == "static_call" &&
           node.resolved == "Bytes.from_raw" &&
           arguments.len() == 2 {
            let pointer: TreeValue = arguments[0]
            let length: int = arguments[1].int_data
            if length < 0 {
                return self.fail_at(
                    node, node.col,
                    "negative raw byte length {length}")
            }
            if pointer.memory_address == 0 {
                if length == 0 {
                    return TreeValue.bytes(new Bytes(0))
                }
                return self.fail_at(
                    node, node.col,
                    "null pointer with non-empty Bytes")
            }
            if pointer.memory_host {
                unsafe {
                    let raw: RawPtr<u8> =
                        RawPtr.from_address(
                            pointer.memory_address)
                    return TreeValue.bytes(
                        Bytes.from_raw(raw, length))
                }
            }
            match self.find_memory(
                    pointer.memory_address) {
                some(memory) => {
                    if !self.memory_contains(
                           memory,
                           pointer.memory_address,
                           length) {
                        return self.fail_at(
                            node, node.col,
                            "raw byte range is outside its allocation")
                    }
                    let start: int =
                        (pointer.memory_address -
                         memory.base) as int
                    return TreeValue.bytes(
                        memory.data.slice(
                            start, start + length))
                }
                none => {
                    return self.fail_at(
                        node, node.col,
                        "invalid raw pointer")
                }
            }
        }
        if node.kind == "static_call" &&
           node.resolved == "Bytes.from" &&
           arguments.len() == 1 {
            return TreeValue.bytes(
                Bytes.from(arguments[0].text))
        }
        if node.kind == "static_call" &&
           node.resolved == "Bytes.uvarint_size" &&
           arguments.len() == 1 {
            return TreeValue.integer(
                Bytes.uvarint_size(
                    arguments[0].int_data))
        }
        if node.kind == "static_call" &&
           node.type.name.starts_with("Simd") &&
           (node.value == "of" ||
            node.value == "splat" ||
            node.value == "load" ||
            node.value == "load_unaligned") {
            if node.value == "load" ||
               node.value == "load_unaligned" {
                let pointer: TreeValue =
                    arguments[0]
                if pointer.memory_address == 0 {
                    return self.fail(
                        node, "null SIMD load")
                }
                let vector: LayoutAnswer =
                    self.layout(node.type)
                if node.value == "load" &&
                   pointer.memory_address %
                       (vector.value.size as u64) != 0 {
                    return self.fail(
                        node,
                        "unaligned SIMD load — use load_unaligned")
                }
                match self.pointer_memory(
                        node, pointer) {
                    some(memory) => {
                        return self.memory_read_value(
                            node, memory,
                            pointer.memory_address,
                            node.type)
                    }
                    none => {
                        return TreeValue.unit()
                    }
                }
            }
            var lanes: List<TreeValue> = []
            if node.value == "of" {
                for argument: TreeValue in arguments {
                    lanes.push(
                        tree_value_copy(argument))
                }
            } else if arguments.len() == 1 {
                for index: int in
                    0..tree_simd_lanes(
                        node.type.name) {
                    lanes.push(
                        tree_value_copy(arguments[0]))
                }
            }
            let result: TreeValue =
                TreeValue.sequence(
                    "simd", move lanes)
            result.text = node.type.name
            return result
        }
        var receiver: Option<TreeValue> = none
        if node.kind == "method_call" &&
           arguments.len() != 0 {
            receiver = some(arguments[0])
            var method_arguments: List<TreeValue> = []
            for index: int in 1..arguments.len() {
                method_arguments.push(arguments[index])
            }
            arguments = move method_arguments
        }
        let method_log_level: int =
            if node.kind == "method_call" {
                self.tree_log_level(node.resolved)
            } else {
                -1
            }
        if method_log_level >= 0 && arguments.len() == 1 {
            match receiver {
                some(value) => {
                    match self.find_function(
                            package_symbol(
                                "std.log", "Logger.log_at_code")) {
                        some(function) => {
                            return self.invoke(
                                function,
                                [TreeValue.integer(method_log_level),
                                 arguments[0],
                                 TreeValue.string(node.file),
                                 TreeValue.string(self.active_function_name()),
                                 TreeValue.integer(node.line),
                                 TreeValue.integer(node.col)],
                                some(value))
                        }
                        none => {}
                    }
                }
                none => {}
            }
        }
        var target: string = node.resolved
        match receiver {
            some(value) => {
                if value.kind == "object" {
                    match self.dynamic_method(
                        value.text, node.value,
                        node.dispatch_slot) {
                        some(function) => {
                            target = function.qualified
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
        match self.find_function(target) {
            some(function) => {
                if node.kind == "runtime_hook_call" {
                    self.runtime_hook_active = true
                    let result: TreeValue = self.invoke_bound(
                        function, move arguments, receiver,
                        self.call_type_bindings(node, function))
                    self.runtime_hook_active = false
                    return result
                }
                return self.invoke_bound(
                    function, move arguments, receiver,
                    self.call_type_bindings(node, function))
            }
            none => {
                return self.fail(
                    node,
                    "unknown function '{node.resolved}'")
            }
        }
    }

    fn builtin_object(name: string,
                      arguments: List<TreeValue>) ->
        Option<TreeValue> {
        var kind: string = ""
        if name == "Box" {
            kind = "box"
        } else if name == "Arena" {
            kind = "arena"
        } else if name == "Shared" {
            kind = "shared"
        } else if name == "Weak" {
            kind = "weak"
        } else if name == "Mutex" {
            kind = "mutex"
        } else if name == "Atomic" ||
                  name == "AtomicInt" {
            kind = "atomic"
        } else if name == "Gate" {
            kind = "gate"
        } else if name == "TaskGroup" {
            kind = "taskgroup"
        } else if name == "Channel" {
            kind = "channel"
        } else if name == "Bytes" {
            kind = "bytes"
        } else {
            return none
        }
        let result: TreeValue =
            new TreeValue(kind)
        if kind == "bytes" {
            let size: int =
                if arguments.len() != 0 {
                    arguments[0].int_data
                } else {
                    0
                }
            result.bytes_data =
                some(new Bytes(size))
        } else if kind == "shared" {
            if arguments.len() != 0 {
                result.shared_value =
                    some(new Shared(
                        tree_value_copy(
                            arguments[0])))
            }
        } else if kind == "arena" ||
                  kind == "channel" {
            if arguments.len() != 0 &&
               arguments[0].kind == "int" {
                result.int_data =
                    arguments[0].int_data
            }
            if kind == "channel" {
                result.channel_cell =
                    some(new Mutex(
                        new TreeChannelState(
                            result.int_data)))
            }
        } else if kind == "mutex" ||
                  kind == "atomic" {
            if arguments.len() != 0 {
                result.mutex_cell =
                    some(new Mutex(
                        new TreeMutexCell(
                            tree_value_copy(
                                arguments[0]))))
            }
        } else if kind == "gate" {
            unsafe {
                result.int_data =
                    beans_gate_new().address() as int
            }
        } else if kind == "taskgroup" {
            result.group_work =
                some(new TreeTaskGroupState())
        } else if arguments.len() != 0 {
            result.items.push(
                tree_value_copy(arguments[0]))
        }
        return some(result)
    }

    fn object_value(name: string) -> TreeValue {
        // with weak fields anywhere in the program, every object needs
        // the host deinit hook: any object may become a weak referent
        if self.weak_track ||
           self.needs_deinit(name) ||
           self.chain_frees_objects(name) {
            return (new TreeObjectValue(self)) as TreeValue
        }
        return new TreeValue("object")
    }

    // The host wrapper died. Without weak tracking that IS the object's
    // death; with it, revived wrappers may still stand for the object.
    fn object_wrapper_died(object: TreeValue) {
        if !self.weak_track {
            self.deinit_object(object)
            return
        }
        match self.weak_wrappers.get(object.object_id) {
            some(count) => {
                if count > 1 {
                    self.weak_wrappers[object.object_id] =
                        count - 1
                    return
                }
                self.weak_wrappers.remove(object.object_id)
                self.weak_registry.remove(object.object_id)
                self.deinit_object(object)
            }
            none => {
                self.deinit_object(object)
            }
        }
    }

    fn weak_field(node: HirNode,
                  frame: TreeFrame) -> TreeValue {
        let receiver: TreeValue =
            self.expression(node.children[0], frame)
        if receiver.kind == "propagate" {
            return receiver
        }
        match receiver.fields.entries.get(node.value) {
            some(stored) => {
                if stored.kind != "weak_ref" {
                    return TreeValue.option_none()
                }
                match self.weak_registry.get(
                    stored.int_data) {
                    some(inner) => {
                        // revive a wrapper over the same fields map
                        // and identity; its own host death folds back
                        // into the wrapper count
                        let revived: TreeValue =
                            (new TreeObjectValue(self)) as TreeValue
                        revived.text = inner.text
                        revived.fields = inner.fields
                        revived.object_id = inner.object_id
                        self.weak_wrappers[inner.object_id] =
                            self.weak_wrappers.get(
                                inner.object_id).or(1) + 1
                        return TreeValue.option_some(revived)
                    }
                    none => {
                        return TreeValue.option_none()
                    }
                }
            }
            none => {
                return TreeValue.option_none()
            }
        }
    }

    fn new_object(node: HirNode,
                  frame: TreeFrame) -> TreeValue {
        var arguments: List<TreeValue> = []
        for child: HirNode in node.children {
            let argument: TreeValue =
                self.expression(child, frame)
            if self.failed {
                return TreeValue.unit()
            }
            if argument.kind == "propagate" {
                return argument
            }
            arguments.push(argument)
        }
        match self.builtin_object(
            node.type.name, arguments) {
            some(value) => { return value }
            none => {}
        }
        let result: TreeValue =
            self.object_value(node.type.name)
        result.text = node.type.name
        result.object_id = self.next_object_id
        self.next_object_id += 1
        let bindings: Map<string, HirType> =
            match self.find_function(node.resolved) {
                some(initializer) =>
                    self.call_type_bindings(node, initializer),
                none => self.current_type_bindings(),
            }
        result.generic_types = copy_type_map(bindings)
        self.apply_field_defaults(
            node.type.name, result, frame)
        match self.find_function(node.resolved) {
            some(initializer) => {
                self.invoke_bound(
                    initializer,
                    move arguments,
                    some(result), move bindings)
            }
            none => {
                if node.children.len() != 0 {
                    self.fail(
                        node,
                        "unknown initializer '{node.resolved}'")
                }
            }
        }
        return result
    }

    fn singleton_object(node: HirNode,
                        frame: TreeFrame) -> TreeValue {
        match self.singletons.values.get(node.type.name) {
            some(value) => { return value }
            none => {}
        }
        let result: TreeValue =
            self.object_value(node.type.name)
        result.text = node.type.name
        result.object_id = self.next_object_id
        self.next_object_id += 1
        // Publish before init so two singleton initializers may refer to
        // each other. Program startup is single-threaded; worker
        // interpreters receive this completed map.
        self.singletons.values[node.type.name] = result
        self.apply_field_defaults(
            node.type.name, result, frame)
        match self.find_function(node.resolved) {
            some(initializer) => {
                self.invoke(initializer, [], some(result))
            }
            none => {}
        }
        return result
    }

    fn initialize_singletons() {
        let frame: TreeFrame = new TreeFrame()
        for declaration: HirDeclaration in
            self.program.declarations {
            if !declaration.is_singleton { continue }
            let node: HirNode =
                new HirNode(
                    "singleton", "instance",
                    new HirType(declaration.qualified),
                    declaration.file,
                    declaration.line,
                    declaration.col)
            node.resolved = declaration.qualified
            match self.reflect_method(
                display_symbol(declaration.qualified), "init") {
                some(initializer) => {
                    node.resolved =
                        initializer.callable.qualified
                }
                none => {}
            }
            self.singleton_object(node, frame)
            if self.failed { return }
        }
    }

    fn initialize_static_fields() {
        let frame: TreeFrame = new TreeFrame()
        for declaration: HirDeclaration in
            self.program.declarations {
            for field: HirField in declaration.static_fields {
                match field.default_value {
                    some(value) => {
                        let initialized: TreeValue =
                            self.expression(value, frame)
                        self.singletons.static_values[
                            "{declaration.qualified}.{field.name}"] =
                            tree_value_copy(initialized)
                    }
                    none => {}
                }
                if self.failed { return }
            }
        }
    }

    fn apply_field_defaults(
        name: string,
        object: TreeValue,
        frame: TreeFrame) {
        // Same two-pass rule as declaration(): an exact qualified name wins
        // before any short-name fallback, so a dependency's class cannot
        // shadow a root-package class that shares its short name.
        match self.declaration(name) {
            some(declaration) => {
                self.apply_declaration_defaults(
                    declaration, object, frame)
            }
            none => {}
        }
    }

    fn apply_declaration_defaults(
        declaration: HirDeclaration,
        object: TreeValue,
        frame: TreeFrame) {
        for field: HirField in declaration.fields {
            match field.default_value {
                some(value) => {
                    object.fields.entries[field.name] =
                        tree_value_copy(
                            self.expression(value, frame))
                }
                none => {}
            }
        }
        for index: int in
            0..declaration.relations.len() {
            if index <
                   declaration.relation_kinds.len() &&
               declaration.relation_kinds[index] ==
                   "extends" {
                self.apply_field_defaults(
                    declaration.relations[index].name,
                    object, frame)
            }
        }
    }

    fn field(node: HirNode,
             frame: TreeFrame) -> TreeValue {
        if node.children.len() != 1 {
            return self.fail(node, "field has no receiver")
        }
        let receiver: TreeValue =
            self.expression(node.children[0], frame)
        if receiver.kind == "propagate" {
            return receiver
        }
        match receiver.fields.entries.get(node.value) {
            some(value) => {
                return tree_value_copy(value)
            }
            none => {
                return self.fail(
                    node,
                    "{tree_type_label(receiver.text)} has no initialized field '{node.value}'")
            }
        }
    }

    fn index(node: HirNode,
             frame: TreeFrame) -> TreeValue {
        let receiver: TreeValue =
            self.expression(node.children[0], frame)
        if receiver.kind == "propagate" {
            return receiver
        }
        let key: TreeValue =
            self.expression(node.children[1], frame)
        if key.kind == "propagate" { return key }
        return self.index_value(
            node, receiver, key, false)
    }

    // One element read used by both the copying read path and the
    // borrowed place walk behind an element assignment: `borrowed`
    // skips the value-semantics copy so a caller can write through.
    fn index_value(node: HirNode,
                   receiver: TreeValue,
                   key: TreeValue,
                   borrowed: bool) -> TreeValue {
        if (receiver.kind == "list" ||
            receiver.kind == "array") &&
           key.kind == "int" {
            if key.int_data < 0 ||
               key.int_data >= receiver.items.len() {
                return self.fail(
                    node,
                    "{if receiver.kind == "array" { "array" } else { "list" }} index {key.int_data} out of range (len {receiver.items.len()})")
            }
            let element: TreeValue =
                receiver.items[key.int_data]
            return if borrowed {
                element
            } else {
                tree_value_copy(element)
            }
        }
        if receiver.kind == "map" {
            match receiver.map_values.get(
                self.map_key(receiver, key)) {
                some(value) => {
                    return if borrowed {
                        value
                    } else {
                        tree_value_copy(value)
                    }
                }
                none => {
                    return self.fail_at(
                        node, node.col,
                        "map key not found: {tree_value_text(key)}")
                }
            }
        }
        if receiver.kind == "slice" &&
           key.kind == "int" {
            if key.int_data < 0 ||
               key.int_data >= receiver.slice_len {
                return self.fail(
                    node,
                    "slice index {key.int_data} out of range (len {receiver.slice_len})")
            }
            let element: HirType =
                receiver.memory_type.expect(
                    "slice element type")
            let piece: LayoutAnswer =
                self.layout(element)
            match self.pointer_memory(
                    node, receiver) {
                some(memory) => {
                    return self.memory_read_value(
                        node, memory,
                        receiver.memory_address +
                            ((key.int_data *
                              piece.value.size) as u64),
                        element)
                }
                none => {
                    return TreeValue.unit()
                }
            }
        }
        return self.fail(
            node,
            "indexing {receiver.kind} is not in the Beans interpreter yet")
    }

    fn pattern_literal(pattern: HirNode,
                       value: TreeValue) -> bool {
        if pattern.value == "true" ||
           pattern.value == "false" {
            return value.kind == "bool" &&
                   value.bool_data ==
                       (pattern.value == "true")
        }
        if pattern.value.starts_with("\"") {
            return value.kind == "string" &&
                   value.text ==
                       tree_unquote(pattern.value)
        }
        if pattern.value.contains(".") ||
           pattern.value.contains("e") ||
           pattern.value.contains("E") {
            return value.kind == "float" &&
                   value.float_data ==
                       pattern.value.to_float().or(0.0)
        }
        return value.kind == "int" &&
               value.int_data ==
                   tree_parse_int(pattern.value)
    }

    fn pattern_matches(pattern: HirNode,
                       value: TreeValue,
                       frame: TreeFrame) -> bool {
        if pattern.kind == "pattern_wildcard" {
            return true
        }
        if pattern.kind == "pattern_literal" {
            return self.pattern_literal(
                pattern, value)
        }
        if pattern.kind == "pattern_alternative" {
            for child: HirNode in pattern.children {
                if self.pattern_matches(
                       child, value, frame) {
                    return true
                }
            }
            return false
        }
        if pattern.kind == "pattern_range" &&
           pattern.children.len() == 2 &&
           value.kind == "int" {
            // The parser keeps the operator here, so '..' excludes its
            // upper bound and '..=' includes it. Treating every range as
            // inclusive would put 32768 inside `0..32768`.
            let inclusive: bool = pattern.value == "..="
            if value.int_unsigned {
                // An unsigned subject compares in u64 space, the way the
                // emitter's uge/ule do. Reading `int_data` instead would
                // sign-extend everything above the signed maximum — 150u8
                // would read as -106 and fall outside 100..=200 — and a
                // u64 bound near 2^64 has no signed form to compare in.
                let subject: u64 = value.uint_data
                let low: u64 =
                    tree_parse_unsigned(
                        pattern.children[0].value)
                let high: u64 =
                    tree_parse_unsigned(
                        pattern.children[1].value)
                return subject >= low &&
                       (subject < high ||
                        (inclusive && subject == high))
            }
            let subject: int = value.int_data
            let low: int =
                tree_parse_int(pattern.children[0].value)
            let high: int =
                tree_parse_int(pattern.children[1].value)
            return subject >= low &&
                   (subject < high ||
                    (inclusive && subject == high))
        }
        if pattern.kind != "pattern_name" {
            return false
        }
        let variant: string =
            if value.kind == "variant" {
                value.text
            } else {
                value.kind
            }
        if variant != pattern.value {
            return false
        }
        for index: int in 0..pattern.children.len() {
            let binding: HirNode =
                pattern.children[index]
            if binding.kind == "pattern_binding" &&
               index < value.items.len() {
                frame.set(
                    binding.binding_id,
                    tree_value_copy(
                        value.items[index]))
            }
        }
        return true
    }

    fn match_expression(node: HirNode,
                        frame: TreeFrame) -> TreeValue {
        if node.children.len() == 0 {
            return self.fail(node, "match has no subject")
        }
        let subject: TreeValue =
            self.expression(node.children[0], frame)
        if subject.kind == "propagate" {
            return subject
        }
        for index: int in 1..node.children.len() {
            let arm: HirNode = node.children[index]
            if arm.children.len() != 2 {
                continue
            }
            let arm_frame: TreeFrame =
                TreeFrame.scope(frame)
            if self.pattern_matches(
                   arm.children[0], subject,
                   arm_frame) {
                return self.expression(
                    arm.children[1], arm_frame)
            }
        }
        return self.fail(node, "non-exhaustive match")
    }

    fn match_statement(node: HirNode,
                       frame: TreeFrame) -> TreeExec {
        if node.children.len() == 0 {
            self.fail(node, "match has no subject")
            return TreeExec.next()
        }
        let subject: TreeValue =
            self.expression(node.children[0], frame)
        if subject.kind == "propagate" &&
           subject.items.len() == 1 {
            return TreeExec.returned(subject.items[0])
        }
        for index: int in 1..node.children.len() {
            let arm: HirNode = node.children[index]
            if arm.children.len() != 2 {
                continue
            }
            let arm_frame: TreeFrame =
                TreeFrame.scope(frame)
            if self.pattern_matches(
                   arm.children[0], subject,
                   arm_frame) {
                if arm.children[1].kind == "block" {
                    return self.block(
                        arm.children[1], arm_frame)
                }
                let value: TreeValue =
                    self.expression(
                        arm.children[1], arm_frame)
                if value.kind == "propagate" &&
                   value.items.len() == 1 {
                    return TreeExec.returned(
                        value.items[0])
                }
                return TreeExec.next()
            }
        }
        self.fail(node, "non-exhaustive match")
        return TreeExec.next()
    }

    fn expression(node: HirNode,
                  frame: TreeFrame) -> TreeValue {
        if self.failed { return TreeValue.unit() }
        if node.kind == "literal" {
            return self.literal(node, frame)
        }
        if node.kind == "layout_query" {
            return self.layout_query(node)
        }
        if node.kind == "selector" {
            let result: TreeValue =
                new TreeValue("selector")
            result.text = node.value
            return result
        }
        if node.kind == "local" {
            return self.local(frame, node)
        }
        if node.kind == "c_global" {
            match self.c_global(node.resolved) {
                some(global) => {
                    return self.read_c_global(
                        node, global)
                }
                none => {
                    return self.fail(
                        node,
                        "unknown extern C global '{node.value}'")
                }
            }
        }
        if node.kind == "static_field" {
            match self.singletons.static_values.get(
                node.resolved) {
                some(value) => { return value }
                none => {
                    return self.fail(
                        node,
                        "static field '{node.resolved}' was read before initialization")
                }
            }
        }
        if node.kind == "unary" {
            return self.unary(node, frame)
        }
        if node.kind == "binary" {
            return self.binary(node, frame)
        }
        if node.kind == "closure" {
            return self.closure(node, frame)
        }
        if node.kind == "brew" {
            return self.tree_brew(node, frame)
        }
        if node.kind == "group_brew" {
            return self.tree_group_brew(node, frame)
        }
        if node.kind == "function" {
            let result: TreeValue =
                new TreeValue("function")
            result.text = node.resolved
            return result
        }
        if node.kind == "closure_call" {
            return self.closure_call(node, frame)
        }
        if node.kind == "weak_field" {
            return self.weak_field(node, frame)
        }
        if node.kind == "match" {
            return self.match_expression(node, frame)
        }
        if node.kind == "call" ||
           node.kind == "runtime_hook_call" ||
           node.kind == "builtin_call" ||
           node.kind == "method_call" ||
           node.kind == "builtin_method" ||
           node.kind == "static_call" {
            return self.call(node, frame)
        }
        if node.kind == "new" {
            return self.new_object(node, frame)
        }
        if node.kind == "singleton" {
            return self.singleton_object(node, frame)
        }
        if node.kind == "super_init" ||
           node.kind == "super_call" {
            var arguments: List<TreeValue> = []
            for child: HirNode in node.children {
                let value: TreeValue =
                    self.expression(child, frame)
                if value.kind == "propagate" {
                    return value
                }
                arguments.push(value)
            }
            match self.find_function(node.resolved) {
                some(initializer) => {
                    match frame.self_value {
                        some(receiver) => {
                            return self.invoke(
                                initializer,
                                move arguments,
                                some(receiver))
                        }
                        none => {
                            return self.fail(
                                node,
                                "super.{node.value} has no self")
                        }
                    }
                }
                none => {
                    return self.fail(
                        node,
                        "unknown parent method '{node.resolved}'")
                }
            }
        }
        if node.kind == "initializer" {
            let result: TreeValue =
                new TreeValue("record")
            result.text = node.type.name
            result.object_id = self.next_object_id
            self.next_object_id += 1
            for field: HirNode in node.children {
                if field.kind == "field_init" &&
                   field.children.len() == 1 {
                    result.fields.entries[field.value] =
                        tree_value_copy(
                            self.expression(
                                field.children[0], frame))
                }
            }
            match self.declaration(node.type.name) {
                some(declaration) => {
                    if declaration.kind == "union" {
                        for field: HirNode in
                            node.children {
                            if field.kind ==
                                   "field_init" {
                                self.write_union_field(
                                    node, result,
                                    declaration,
                                    field.value,
                                    result.fields.entries[
                                        field.value])
                                break
                            }
                        }
                    }
                }
                none => {}
            }
            return result
        }
        if node.kind == "field" {
            return self.field(node, frame)
        }
        if node.kind == "index" {
            return self.index(node, frame)
        }
        if node.kind == "cast" &&
           node.children.len() == 1 {
            let value: TreeValue =
                self.expression(node.children[0], frame)
            if value.kind == "propagate" {
                return value
            }
            if node.value == "as?" {
                if display_symbol(
                       node.children[0].type.name) ==
                       "std.reflect.Value" &&
                   node.type.args.len() == 1 {
                    match value.fields.entries.get("handle") {
                        some(raw_handle) => {
                            let handle: int =
                                raw_handle.int_data
                            match self.reflect_value_types.get(
                                      handle) {
                                some(actual) => {
                                    let wanted: string =
                                        render_hir_type(
                                            self.runtime_type(
                                                node.type.args[0],
                                                self.current_type_bindings()))
                                    if actual == wanted ||
                                       self.reflect_assignable(
                                           wanted, actual) {
                                        match self.reflect_values.get(
                                                  handle) {
                                            some(payload) => {
                                                return TreeValue.option_some(
                                                    tree_value_copy(payload))
                                            }
                                            none => {}
                                        }
                                    }
                                }
                                none => {}
                            }
                        }
                        none => {}
                    }
                    return TreeValue.option_none()
                }
                if value.kind == "object" &&
                   self.is_instance(
                       value.text,
                       self.runtime_type(
                           node.type.args[0],
                           self.current_type_bindings()).name) {
                    return TreeValue.option_some(value)
                }
                return TreeValue.option_none()
            }
            let target: string =
                canonical_hir_name(node.type.name)
            if hir_is_integer(node.type) {
                let bits: int =
                    tree_integer_bits(target)
                let unsigned: bool =
                    tree_integer_unsigned(target)
                if value.kind == "int" {
                    let raw: u64 =
                        if value.int_unsigned {
                            value.uint_data
                        } else {
                            value.int_data as u64
                        }
                    return if unsigned {
                        TreeValue.unsigned_integer(
                            raw, bits)
                    } else {
                        TreeValue.signed_integer(
                            tree_signed_from_bits(
                                raw, bits),
                            bits)
                    }
                }
                if value.kind == "float" {
                    return if unsigned {
                        TreeValue.unsigned_integer(
                            value.float_data as u64,
                            bits)
                    } else {
                        TreeValue.signed_integer(
                            value.float_data as int,
                            bits)
                    }
                }
                if value.kind == "decimal" {
                    return if unsigned {
                        TreeValue.unsigned_integer(
                            value.decimal_data as u64,
                            bits)
                    } else {
                        TreeValue.signed_integer(
                            value.decimal_data as int,
                            bits)
                    }
                }
                return value
            }
            if hir_is_float(node.type) {
                if value.kind == "int" {
                    return self.floating_value(
                        node.type,
                        if value.int_unsigned {
                            value.uint_data as float
                        } else {
                            value.int_data as float
                        })
                }
                if value.kind == "decimal" {
                    return self.floating_value(
                        node.type,
                        value.decimal_data as float)
                }
                if value.kind == "float" {
                    return self.floating_value(
                        node.type, value.float_data)
                }
                return value
            }
            if target == "decimal" {
                if value.kind == "int" {
                    return TreeValue.decimal_value(
                        if value.int_unsigned {
                            value.uint_data as decimal
                        } else {
                            value.int_data as decimal
                        })
                }
                if value.kind == "float" {
                    // validate here so the panic carries the guest
                    // program's location, not this file's: the host
                    // cast would panic at its own line otherwise
                    let source: float = value.float_data
                    if !(source == source) ||
                       source.abs() >=
                           100000000000000000000000000000000000000.0 {
                        return self.fail(
                            node, "decimal overflow")
                    }
                    return TreeValue.decimal_value(
                        source as decimal)
                }
            }
            return value
        }
        if node.kind == "list" {
            var values: List<TreeValue> = []
            for child: HirNode in node.children {
                let value: TreeValue =
                    self.expression(child, frame)
                if value.kind == "propagate" {
                    return value
                }
                values.push(tree_value_copy(value))
            }
            let kind: string =
                if node.type.name == "array" {
                    "array"
                } else {
                    "list"
                }
            return TreeValue.sequence(
                kind, move values)
        }
        if node.kind == "map" {
            let result: TreeValue =
                new TreeValue("map")
            var index: int = 0
            for index + 1 < node.children.len() {
                let key: TreeValue =
                    self.expression(
                        node.children[index], frame)
                if key.kind == "propagate" {
                    return key
                }
                let value: TreeValue =
                    self.expression(
                        node.children[index + 1], frame)
                if value.kind == "propagate" {
                    return value
                }
                let encoded: string =
                    self.map_key(result, key)
                if !result.map_values.contains_key(
                       encoded) {
                    result.map_keys.push(
                        tree_value_copy(key))
                }
                result.map_values[encoded] =
                    tree_value_copy(value)
                index += 2
            }
            return result
        }
        if node.kind == "none" {
            return TreeValue.option_none()
        }
        if node.kind == "variant" {
            var payload: List<TreeValue> = []
            for child: HirNode in node.children {
                let value: TreeValue =
                    self.expression(child, frame)
                if value.kind == "propagate" {
                    return value
                }
                payload.push(tree_value_copy(value))
            }
            let result: TreeValue =
                TreeValue.sequence(
                    "variant", move payload)
            result.text = node.value
            return result
        }
        if node.kind == "some" ||
           node.kind == "ok" ||
           node.kind == "err" {
            let value: TreeValue =
                self.expression(node.children[0], frame)
            if value.kind == "propagate" {
                return value
            }
            if node.kind == "some" {
                return TreeValue.option_some(
                    tree_value_copy(value))
            }
            if node.kind == "ok" {
                return TreeValue.result_ok(
                    tree_value_copy(value))
            }
            if value.kind == "string" &&
               (node.type.args.len() == 1 ||
                (node.type.args.len() > 1 &&
                 canonical_hir_name(
                     node.type.args[1].name) ==
                     "Error")) {
                var kind: string = ""
                if node.children.len() > 1 {
                    let kind_value: TreeValue =
                        self.expression(
                            node.children[1], frame)
                    if kind_value.kind == "string" {
                        kind = kind_value.text
                    }
                }
                return TreeValue.result_err(
                    TreeValue.error(
                        value.text, kind))
            }
            return TreeValue.result_err(
                tree_value_copy(value))
        }
        if node.kind == "try" {
            let result: TreeValue =
                self.expression(node.children[0], frame)
            if (result.kind == "ok" ||
                result.kind == "some") &&
               result.items.len() == 1 {
                return tree_value_copy(
                    result.items[0])
            }
            if result.kind == "err" ||
               result.kind == "none" {
                return TreeValue.propagation(result)
            }
            return self.fail(node, "'?' received a non-result value")
        }
        if node.kind == "if_expression" &&
           node.children.len() == 3 {
            let condition: TreeValue =
                self.expression(
                    node.children[0], frame)
            if condition.kind == "propagate" {
                return condition
            }
            if self.truth(node, condition) {
                return self.expression(
                    node.children[1], frame)
            }
            return self.expression(
                node.children[2], frame)
        }
        if node.kind == "block" {
            let scope: TreeFrame =
                TreeFrame.scope(frame)
            if node.children.len() == 0 {
                return TreeValue.unit()
            }
            for index: int in
                0..node.children.len() - 1 {
                let flow: TreeExec =
                    self.statement(
                        node.children[index], scope)
                if flow.kind == "return" {
                    return TreeValue.propagation(
                        flow.value)
                }
            }
            let tail: HirNode =
                node.children[node.children.len() - 1]
            if tail.kind == "expression" &&
               tail.children.len() == 1 {
                return self.expression(
                    tail.children[0], scope)
            }
            let flow: TreeExec =
                self.statement(tail, scope)
            if flow.kind == "return" {
                return TreeValue.propagation(
                    flow.value)
            }
            return flow.value
        }
        return self.fail(
            node,
            "expression '{node.kind}' is not in the Beans interpreter yet")
    }

    // The storage behind an index-assignment base, without the copy a
    // plain field or element read makes: a chain of struct/class fields
    // and array elements rooted at a local. A plain expression read
    // would hand back an independent record or array wrapper and the
    // element store would land in that copy and vanish.
    fn place_receiver(node: HirNode,
                      frame: TreeFrame) -> TreeValue {
        if node.kind == "field" &&
           node.children.len() == 1 {
            let base: TreeValue =
                self.place_receiver(
                    node.children[0], frame)
            if base.kind == "propagate" { return base }
            if self.failed { return base }
            match base.fields.entries.get(node.value) {
                some(value) => { return value }
                none => {
                    return self.fail(
                        node,
                        "{tree_type_label(base.text)} has no initialized field '{node.value}'")
                }
            }
        }
        if node.kind == "index" &&
           node.children.len() == 2 {
            let base: TreeValue =
                self.place_receiver(
                    node.children[0], frame)
            if base.kind == "propagate" { return base }
            if self.failed { return base }
            let key: TreeValue =
                self.expression(
                    node.children[1], frame)
            if key.kind == "propagate" { return key }
            return self.index_value(
                node, base, key, true)
        }
        return self.expression(node, frame)
    }

    fn assign(node: HirNode,
              frame: TreeFrame) -> TreeExec {
        if node.children.len() != 2 {
            self.fail(node, "assignment has no value")
            return TreeExec.next()
        }
        let target: HirNode = node.children[0]
        let written: TreeValue =
            self.expression(node.children[1], frame)
        if written.kind == "propagate" &&
           written.items.len() == 1 {
            return TreeExec.returned(
                written.items[0])
        }
        var value: TreeValue = written
        if node.value != "=" {
            let current: TreeValue =
                self.expression(target, frame)
            let operation: HirNode =
                new HirNode(
                    "binary",
                    node.value.slice(
                        0, node.value.len() - 1),
                    target.type,
                    node.file, node.line, node.col)
            operation.children.push(target)
            operation.children.push(node.children[1])
            if current.kind == "int" &&
               written.kind == "int" {
                value = self.integer_binary(
                    operation,
                    current,
                    written)
            } else if current.kind == "float" &&
                      written.kind == "float" {
                if operation.value == "+" {
                    value = self.floating_value(
                        target.type,
                        current.float_data +
                        written.float_data)
                } else if operation.value == "-" {
                    value = self.floating_value(
                        target.type,
                        current.float_data -
                        written.float_data)
                } else if operation.value == "*" {
                    value = self.floating_value(
                        target.type,
                        current.float_data *
                        written.float_data)
                } else if operation.value == "/" {
                    value = self.floating_value(
                        target.type,
                        current.float_data /
                        written.float_data)
                }
            } else if current.kind == "decimal" &&
                      written.kind == "decimal" {
                value = self.decimal_binary_value(
                    node, operation.value,
                    current.decimal_data,
                    written.decimal_data)
            } else {
                value = self.fail(
                    node,
                    "compound assignment is not in the Beans interpreter yet for {current.kind}")
            }
        }
        if target.kind == "local" {
            if !frame.assign(
                   target.binding_id,
                   tree_value_copy(value)) {
                frame.set(
                    target.binding_id,
                    tree_value_copy(value))
            }
            return TreeExec.next()
        }
        if target.kind == "c_global" {
            match self.c_global(target.resolved) {
                some(global) => {
                    self.write_c_global(
                        node, global, value)
                }
                none => {
                    self.fail(
                        node,
                        "unknown extern C global '{target.value}'")
                }
            }
            return TreeExec.next()
        }
        if target.kind == "static_field" {
            self.singletons.static_values[
                target.resolved] =
                tree_value_copy(value)
            return TreeExec.next()
        }
        if target.kind == "field" &&
           target.children.len() == 1 {
            let receiver: TreeValue =
                self.expression(
                    target.children[0], frame)
            match self.declaration(receiver.text) {
                some(declaration) => {
                    if declaration.kind == "union" {
                        self.write_union_field(
                            node, receiver,
                            declaration,
                            target.value,
                            tree_value_copy(value))
                        return TreeExec.next()
                    }
                }
                none => {}
            }
            receiver.fields.entries[target.value] =
                tree_value_copy(value)
            return TreeExec.next()
        }
        if target.kind == "weak_field" &&
           target.children.len() != 0 {
            let receiver: TreeValue =
                self.expression(
                    target.children[0], frame)
            if receiver.kind == "propagate" {
                return TreeExec.next()
            }
            let stored: TreeValue = tree_value_copy(value)
            if stored.kind == "some" &&
               stored.items.len() == 1 {
                let referent: TreeValue = stored.items[0]
                if !self.weak_registry.contains_key(
                       referent.object_id) {
                    // first weak reference to this object: snapshot an
                    // inner value over the same fields map, and count
                    // the single wrapper standing today
                    let inner: TreeValue =
                        new TreeValue("object")
                    inner.text = referent.text
                    inner.fields = referent.fields
                    inner.object_id = referent.object_id
                    self.weak_registry[
                        referent.object_id] = inner
                    self.weak_wrappers[
                        referent.object_id] =
                        self.weak_wrappers.get(
                            referent.object_id).or(1)
                }
                let marker: TreeValue =
                    new TreeValue("weak_ref")
                marker.int_data = referent.object_id
                receiver.fields.entries[target.value] = marker
            } else {
                receiver.fields.entries[target.value] = stored
            }
            return TreeExec.next()
        }
        if target.kind == "index" &&
           target.children.len() == 2 {
            let receiver: TreeValue =
                self.place_receiver(
                    target.children[0], frame)
            let key: TreeValue =
                self.expression(
                    target.children[1], frame)
            if (receiver.kind == "list" ||
                receiver.kind == "array") &&
               key.kind == "int" {
                if key.int_data < 0 ||
                   key.int_data >= receiver.items.len() {
                    // The subscript is what is out of range, so the report
                    // anchors there and not on the assignment. Reading the
                    // same element would name that spot, and the native
                    // backend names it for a store too.
                    self.fail(
                        target,
                        "{if receiver.kind == "array" { "array" } else { "list" }} index {key.int_data} out of range (len {receiver.items.len()})")
                    return TreeExec.next()
                }
                receiver.items[key.int_data] =
                    tree_value_copy(value)
                return TreeExec.next()
            }
            if receiver.kind == "map" {
                let encoded: string =
                    self.map_key(receiver, key)
                if !receiver.map_values.contains_key(
                       encoded) {
                    receiver.map_keys.push(
                        tree_value_copy(key))
                    receiver.map_version += 1
                }
                receiver.map_values[encoded] =
                    tree_value_copy(value)
                return TreeExec.next()
            }
            if receiver.kind == "slice" &&
               key.kind == "int" {
                if key.int_data < 0 ||
                   key.int_data >= receiver.slice_len {
                    self.fail(
                        target,
                        "slice index {key.int_data} out of range (len {receiver.slice_len})")
                    return TreeExec.next()
                }
                let element: HirType =
                    receiver.memory_type.expect(
                        "slice element type")
                let piece: LayoutAnswer =
                    self.layout(element)
                match self.pointer_memory(
                        node, receiver) {
                    some(memory) => {
                        self.memory_write_value(
                            node, memory,
                            receiver.memory_address +
                                ((key.int_data *
                                  piece.value.size) as u64),
                            element, value)
                    }
                    none => {}
                }
                return TreeExec.next()
            }
        }
        self.fail(
            node,
            "assignment target '{target.kind}' is not in the Beans interpreter yet")
        return TreeExec.next()
    }

    fn block(node: HirNode,
             frame: TreeFrame) -> TreeExec {
        let scope: TreeFrame =
            TreeFrame.scope(frame)
        for statement: HirNode in node.children {
            let result: TreeExec =
                self.statement(statement, scope)
            if result.kind != "next" {
                return result
            }
        }
        return TreeExec.next()
    }

    fn loop(node: HirNode,
            frame: TreeFrame) -> TreeExec {
        if node.children.len() == 1 {
            for !self.failed {
                let result: TreeExec =
                    self.block(node.children[0], frame)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
            }
            return TreeExec.next()
        }
        if node.children.len() == 2 {
            var running: bool = true
            for running {
                let condition: TreeValue =
                    self.expression(
                        node.children[0], frame)
                if condition.kind == "propagate" &&
                   condition.items.len() == 1 {
                    return TreeExec.returned(
                        condition.items[0])
                }
                if !self.truth(node, condition) {
                    running = false
                    continue
                }
                let result: TreeExec =
                    self.block(node.children[1], frame)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
            }
            return TreeExec.next()
        }
        if node.children.len() == 4 {
            let iterable: TreeValue =
                self.expression(node.children[0], frame)
            if iterable.kind == "propagate" &&
               iterable.items.len() == 1 {
                return TreeExec.returned(
                    iterable.items[0])
            }
            if iterable.kind != "map" {
                self.fail(
                    node,
                    "{iterable.kind} does not support key/value iteration")
                return TreeExec.stopped("panic")
            }
            let version: int = iterable.map_version
            var index: int = 0
            for true {
                if iterable.map_version != version {
                    self.fail(node, "map changed during iteration")
                    return TreeExec.stopped("panic")
                }
                if index >= iterable.map_keys.len() { break }
                let key: TreeValue =
                    tree_value_copy(iterable.map_keys[index])
                let encoded: string = tree_value_key(key)
                var value: TreeValue = TreeValue.unit()
                match iterable.map_values.get(encoded) {
                    some(found) => {
                        value = tree_value_copy(found)
                    }
                    none => {
                        self.fail(
                            node,
                            "map changed during iteration")
                        return TreeExec.stopped("panic")
                    }
                }
                let iteration: TreeFrame =
                    TreeFrame.scope(frame)
                iteration.set(
                    node.children[1].binding_id, key)
                iteration.set(
                    node.children[2].binding_id, value)
                let result: TreeExec =
                    self.block(node.children[3], iteration)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
                index += 1
            }
            return TreeExec.next()
        }
        if node.children.len() == 3 {
            let iterable: TreeValue =
                self.expression(node.children[0], frame)
            if iterable.kind == "propagate" &&
               iterable.items.len() == 1 {
                return TreeExec.returned(
                    iterable.items[0])
            }
            let binding: HirNode = node.children[1]
            var values: List<TreeValue> = []
            if iterable.kind == "range" &&
               iterable.items.len() == 2 &&
               iterable.items[0].int_unsigned {
                // An unsigned range counts in u64 space and hands the body a
                // value of the element's own width and signedness. Counting
                // through `int_data` instead would sign-extend every endpoint
                // above the signed maximum — `for v: u8 in 254..=255` would
                // bind -2 and -1 — and a u64 endpoint near 2^64 has no signed
                // representation to count through at all.
                let bits: int = iterable.items[0].int_bits
                var value: u64 = iterable.items[0].uint_data
                let end: u64 = iterable.items[1].uint_data
                for value < end ||
                    (iterable.bool_data &&
                     value == end) {
                    values.push(
                        TreeValue.unsigned_integer(value, bits))
                    if iterable.bool_data &&
                       value == end {
                        break
                    }
                    value += 1
                }
            } else if iterable.kind == "range" &&
               iterable.items.len() == 2 {
                var value: int =
                    iterable.items[0].int_data
                let end: int =
                    iterable.items[1].int_data
                for value < end ||
                    (iterable.bool_data &&
                     value == end) {
                    values.push(
                        TreeValue.integer(value))
                    if iterable.bool_data &&
                       value == end {
                        break
                    }
                    value += 1
                }
            } else if iterable.kind == "list" ||
                      iterable.kind == "array" {
                for value: TreeValue in iterable.items {
                    values.push(value)
                }
            } else if iterable.kind == "slice" {
                let element: HirType =
                    iterable.memory_type.expect(
                        "slice element type")
                let piece: LayoutAnswer =
                    self.layout(element)
                match self.pointer_memory(
                        node, iterable) {
                    some(memory) => {
                        for index: int in
                            0..iterable.slice_len {
                            values.push(
                                self.memory_read_value(
                                    node, memory,
                                    iterable.memory_address +
                                        ((index *
                                          piece.value.size) as u64),
                                    element))
                        }
                    }
                    none => {}
                }
            } else {
                self.fail(
                    node,
                    "{iterable.kind} is not iterable")
            }
            for value: TreeValue in values {
                let iteration: TreeFrame =
                    TreeFrame.scope(frame)
                iteration.set(
                    binding.binding_id, value)
                let result: TreeExec =
                    self.block(
                        node.children[2], iteration)
                if result.kind == "return" {
                    return result
                }
                if result.kind == "break" {
                    return TreeExec.next()
                }
            }
        }
        return TreeExec.next()
    }

    fn statement(node: HirNode,
                 frame: TreeFrame) -> TreeExec {
        if self.failed {
            return TreeExec.stopped("panic")
        }
        match self.debugger {
            some(session) => {
                session.at_statement(node, frame)
                if session.terminated || session.disconnected {
                    return TreeExec.stopped("panic")
                }
            }
            none => {}
        }
        if node.kind == "block" ||
           node.kind == "unsafe" {
            let block: HirNode =
                if node.kind == "unsafe" {
                    node.children[0]
                } else {
                    node
                }
            return self.block(block, frame)
        }
        if node.kind == "let" || node.kind == "var" {
            let value: TreeValue =
                if node.children.len() == 0 {
                    TreeValue.unit()
                } else {
                    self.expression(
                        node.children[0], frame)
                }
            if value.kind == "propagate" &&
               value.items.len() == 1 {
                return TreeExec.returned(
                    value.items[0])
            }
            frame.set(
                node.binding_id,
                tree_value_copy(value))
            return TreeExec.next()
        }
        if node.kind == "expression" &&
           node.children.len() == 1 &&
           node.children[0].kind == "match" {
            // a statement match runs its arm as statements, so break and
            // continue inside an arm reach the enclosing loop instead of
            // being swallowed by expression evaluation
            return self.match_statement(
                node.children[0], frame)
        }
        if node.kind == "expression" {
            if node.children.len() != 0 {
                let value: TreeValue =
                    self.expression(
                        node.children[0], frame)
                if value.kind == "propagate" &&
                   value.items.len() == 1 {
                    return TreeExec.returned(
                        value.items[0])
                }
            }
            return TreeExec.next()
        }
        if node.kind == "assign" {
            return self.assign(node, frame)
        }
        if node.kind == "return" {
            let value: TreeValue =
                if node.children.len() == 0 {
                    TreeValue.unit()
                } else {
                    self.expression(
                        node.children[0], frame)
                }
            if value.kind == "propagate" &&
               value.items.len() == 1 {
                return TreeExec.returned(
                    value.items[0])
            }
            return TreeExec.returned(value)
        }
        if node.kind == "if" {
            let condition_value: TreeValue =
                self.expression(
                    node.children[0], frame)
            if condition_value.kind == "propagate" &&
               condition_value.items.len() == 1 {
                return TreeExec.returned(
                    condition_value.items[0])
            }
            let condition: bool =
                self.truth(node, condition_value)
            if condition {
                return self.statement(
                    node.children[1], frame)
            }
            if node.children.len() > 2 {
                return self.statement(
                    node.children[2], frame)
            }
            return TreeExec.next()
        }
        if node.kind == "for" {
            return self.loop(node, frame)
        }
        if node.kind == "break" ||
           node.kind == "continue" {
            return TreeExec.stopped(node.kind)
        }
        if node.kind == "defer" &&
           node.children.len() == 1 {
            frame.add_defer(node.children[0], frame)
            return TreeExec.next()
        }
        self.fail(
            node,
            "statement '{node.kind}' is not in the Beans interpreter yet")
        return TreeExec.next()
    }

    fn run_defers(frame: TreeFrame) {
        var index: int = frame.defers.len()
        for index > 0 {
            index -= 1
            let armed: TreeDeferred = frame.defers[index]
            // in the scope it was registered in: a nested block's defer
            // must still see that block's bindings, as native slots do
            self.expression(armed.expression, armed.frame)
        }
        // Drop the records now: each holds its registration frame, and
        // that back-reference is a frame cycle — left in place it would
        // outlive the function and hold every deferred scope's values
        // past their deinit point ("defers first, then the frame
        // releases" is a pinned contract).
        frame.defers = []
    }

    fn fail_extern(function: HirFunction,
                   message: string) -> TreeValue {
        if !self.failed {
            self.failed = true
            self.panic_text =
                "runtime panic at {function.line}:{function.col}: {message}"
        }
        return TreeValue.unit()
    }

    fn ffi_pointer_word(
        function: HirFunction,
        value: TreeValue,
        bridges: List<TreeFfiMemory>) -> int {
        if value.memory_address == 0 { return 0 }
        if value.memory_host {
            return value.memory_address as int
        }
        var memory_value: Option<TreeMemory> =
            value.memory
        if memory_value.is_none() {
            memory_value =
                self.find_memory(value.memory_address)
        }
        match memory_value {
            some(memory) => {
                if memory.freed {
                    self.fail_extern(
                        function,
                        "dangling raw pointer passed to extern C function")
                    return 0
                }
                for bridge: TreeFfiMemory in bridges {
                    if bridge.memory.base == memory.base {
                        unsafe {
                            return (bridge.host.address() +
                                    value.memory_address -
                                    memory.base) as int
                        }
                    }
                }
                unsafe {
                    let host: RawPtr<u8> =
                        RawPtr.alloc_aligned(
                            memory.data.len(),
                            memory.alignment)
                    for index: int in
                        0..memory.data.len() {
                        host.offset(index).write(
                            memory.data.get(index) as u8)
                    }
                    bridges.push(
                        new TreeFfiMemory(
                            memory, host,
                            value.memory_type.expect(
                                "FFI pointer element type")))
                    return (host.address() +
                            value.memory_address -
                            memory.base) as int
                }
            }
            none => {
                self.fail_extern(
                    function,
                    "invalid raw pointer passed to extern C function")
                return 0
            }
        }
        return 0
    }

    fn ffi_sync_and_free(
        bridges: List<TreeFfiMemory>) {
        unsafe {
            for bridge: TreeFfiMemory in bridges {
                for index: int in
                    0..bridge.memory.data.len() {
                    let byte: u8 =
                        bridge.host.offset(index).read()
                    bridge.memory.data.set(
                        index, byte as int)
                }
                bridge.host.free()
            }
        }
    }

    fn ffi_pointer_result(
        type: HirType, raw: int,
        bridges: List<TreeFfiMemory>) -> TreeValue {
        let element: HirType =
            if type.args.len() == 1 {
                type.args[0]
            } else {
                new HirType("u8")
            }
        if raw == 0 {
            return TreeValue.raw_pointer(
                none, 0, element)
        }
        let address: u64 = raw as u64
        for bridge: TreeFfiMemory in bridges {
            var base: u64 = 0
            unsafe {
                base = bridge.host.address()
            }
            let size: u64 =
                bridge.memory.data.len() as u64
            if address >= base &&
               address <= base + size {
                return TreeValue.raw_pointer(
                    some(bridge.memory),
                    bridge.memory.base +
                        address - base,
                    element)
            }
        }
        return TreeValue.host_pointer(
            address, element)
    }

    fn ffi_integer_result(
        type: HirType, raw: int) -> TreeValue {
        let name: string =
            canonical_hir_name(type.name)
        if name == "bool" {
            return TreeValue.boolean(raw != 0)
        }
        let bits: int = tree_integer_bits(name)
        if tree_integer_unsigned(name) {
            return TreeValue.unsigned_integer(
                raw as u64, bits)
        }
        return TreeValue.signed_integer(raw, bits)
    }

    fn ffi_memory_write_value(
        function: HirFunction,
        memory: TreeMemory, address: u64,
        type: HirType, value: TreeValue,
        bridges: List<TreeFfiMemory>) -> bool {
        let name: string =
            canonical_hir_name(type.name)
        if name == "RawPtr" ||
           name == "CFunctionPtr" {
            self.memory_write_uint(
                memory, address,
                self.program.target.pointer_size(),
                self.ffi_pointer_word(
                    function, value, bridges) as u64)
            return !self.failed
        }
        if name == "array" &&
           type.args.len() == 1 {
            let element: LayoutAnswer =
                self.layout(type.args[0])
            for index: int in 0..type.array_length {
                if index >= value.items.len() ||
                   !self.ffi_memory_write_value(
                       function, memory,
                       address +
                           ((index *
                             element.value.size) as u64),
                       type.args[0], value.items[index],
                       bridges) {
                    return false
                }
            }
            return true
        }
        match self.declaration(type.name) {
            some(declaration) => {
                if declaration.is_c_layout &&
                   declaration.kind != "union" {
                    let engine: LayoutEngine =
                        new LayoutEngine(
                            self.program,
                            self.program.target)
                    let record: RecordLayoutAnswer =
                        engine.layout_record(declaration)
                    for field: HirField in
                        declaration.fields {
                        match record.offsets.get(
                                field.name) {
                            some(offset) => {
                                if !self.ffi_memory_write_value(
                                       function, memory,
                                       address +
                                           (offset as u64),
                                       field.type,
                                       value.fields.entries[field.name],
                                       bridges) {
                                    return false
                                }
                            }
                            none => {}
                        }
                    }
                    return true
                }
            }
            none => {}
        }
        return self.memory_write_value(
            new HirNode(
                "ffi", function.name,
                type, function.file,
                function.line, function.col),
            memory, address, type, value)
    }

    fn ffi_host_storage(
        function: HirFunction, type: HirType,
        value: TreeValue,
        bridges: List<TreeFfiMemory>) ->
        RawPtr<u8> {
        let answer: LayoutAnswer = self.layout(type)
        unsafe {
            let host: RawPtr<u8> =
                RawPtr.alloc(answer.value.size)
            let temporary: TreeMemory =
                new TreeMemory(
                    0, answer.value.size,
                    answer.value.align)
            if self.ffi_memory_write_value(
                   function, temporary, 0,
                   type, value, bridges) {
                for index: int in
                    0..answer.value.size {
                    let byte: u8 =
                        temporary.data.get(index) as u8
                    host.offset(index).write(
                        byte)
                }
            }
            return host
        }
    }

    fn ffi_read_host_storage(
        function: HirFunction, type: HirType,
        host: RawPtr<u8>) -> TreeValue {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        unsafe {
            for index: int in 0..answer.value.size {
                let byte: u8 =
                    host.offset(index).read()
                temporary.data.set(
                    index, byte as int)
            }
        }
        return self.memory_read_value(
            new HirNode(
                "ffi", function.name,
                type, function.file,
                function.line, function.col),
            temporary, 0, type)
    }

    fn ffi_write_host_storage(
        function: HirFunction, type: HirType,
        value: TreeValue, host: RawPtr<u8>,
        bridges: List<TreeFfiMemory>) {
        let answer: LayoutAnswer = self.layout(type)
        let temporary: TreeMemory =
            new TreeMemory(
                0, answer.value.size,
                answer.value.align)
        if !self.ffi_memory_write_value(
               function, temporary, 0,
               type, value, bridges) {
            return
        }
        unsafe {
            for index: int in 0..answer.value.size {
                host.offset(index).write(
                    temporary.data.get(index) as u8)
            }
        }
    }

    fn ffi_callback_dispatch(
        function: HirFunction,
        captured_arguments: List<TreeValue>,
        context: RawPtr<u8>,
        result: RawPtr<u8>,
        raw_arguments: RawPtr<RawPtr<u8> >,
        bridges: List<TreeFfiMemory>) {
        var parameter_index: int = -1
        unsafe {
            parameter_index =
                ((context.address() as int - 1) /
                 2) - 1
        }
        if parameter_index < 0 ||
           parameter_index >=
               function.parameters.len() ||
           parameter_index >=
               captured_arguments.len() {
            self.fail_extern(
                function,
                "invalid C callback context")
            return
        }
        let callback_type: HirType =
            function.parameters[
                parameter_index].type
        let count: int =
            callback_type.fn_parameter_count
        var arguments: List<TreeValue> = []
        unsafe {
            for index: int in 0..count {
                let slot: RawPtr<u8> =
                    raw_arguments.offset(index).read()
                arguments.push(
                    self.ffi_read_host_storage(
                        function,
                        callback_type.args[index],
                        slot))
            }
        }
        let node: HirNode =
            new HirNode(
                "ffi_callback", function.name,
                callback_type, function.file,
                function.line, function.col)
        let returned: TreeValue =
            self.invoke_closure(
                node,
                captured_arguments[
                    parameter_index],
                move arguments)
        if self.failed ||
           count >= callback_type.args.len() ||
           callback_type.args[count].name ==
               "unit" {
            return
        }
        unsafe {
            if !result.is_null() {
                self.ffi_write_host_storage(
                    function,
                    callback_type.args[count],
                    returned, result, bridges)
            }
        }
    }

    fn ffi_bridge_source(
        function: HirFunction,
        abi: CAbiDescription) -> string {
        var parameters: string =
            abi.parameter_declarations.join(", ")
        if parameters == "" { parameters = "void" }
        var source: string =
            "#include <stdint.h>\n{abi.definitions}"
        source =
            "{source}typedef void (*BeansFfiDispatch)(void*, void*, void**);\n"
        for callback: CAbiCallbackDescription in
            abi.callbacks {
            let prefix: string =
                "beans_ffi_cb{callback.parameter_index}"
            source =
                "{source}static _Thread_local BeansFfiDispatch {prefix}_dispatch;\n"
            source =
                "{source}static _Thread_local void* {prefix}_context;\n"
            var callback_parameters: string =
                callback.parameter_declarations.join(", ")
            if callback_parameters == "" {
                callback_parameters = "void"
            }
            source =
                "{source}static {callback.return_type} {prefix}({callback_parameters}) \{\n"
            let slot_count: int =
                if callback.parameter_types.len() == 0 {
                    1
                } else {
                    callback.parameter_types.len()
                }
            var callback_arguments: List<string> = []
            for index: int in
                0..callback.parameter_types.len() {
                callback_arguments.push(
                    "&value{index}")
            }
            if callback_arguments.len() == 0 {
                callback_arguments.push("0")
            }
            source =
                "{source}  void* callback_args[{slot_count}] = \{{callback_arguments.join(", ")}\};\n"
            if callback.return_type == "void" {
                source =
                    "{source}  {prefix}_dispatch({prefix}_context, 0, callback_args);\n\}\n"
            } else {
                source =
                    "{source}  {callback.return_type} callback_result = \{0\};\n"
                source =
                    "{source}  {prefix}_dispatch({prefix}_context, &callback_result, callback_args);\n"
                source =
                    "{source}  return callback_result;\n\}\n"
            }
        }
        source =
            "{source}typedef {abi.return_type} (*BeansFfiFn)({parameters});\n"
        source =
            "{source}{ffi_export_attribute()}"
        source =
            "{source}void beans_ffi_bridge(void* symbol, void* result, void** args, BeansFfiDispatch dispatch, void** contexts) \{\n"
        source =
            "{source}  BeansFfiFn fn = (BeansFfiFn)symbol;\n  "
        for callback: CAbiCallbackDescription in
            abi.callbacks {
            let prefix: string =
                "beans_ffi_cb{callback.parameter_index}"
            source =
                "{source}BeansFfiDispatch {prefix}_old_dispatch = {prefix}_dispatch;\n  "
            source =
                "{source}void* {prefix}_old_context = {prefix}_context;\n  "
            source =
                "{source}{prefix}_dispatch = dispatch;\n  "
            source =
                "{source}{prefix}_context = contexts[{callback.parameter_index}];\n  "
            source =
                "{source}void* {prefix}_stored = (((uintptr_t){prefix}_context & 1u) == 0) ? *(void**)args[{callback.parameter_index}] : 0;\n  "
        }
        if function.result.name != "unit" {
            source =
                "{source}{abi.return_type} call_result = "
        }
        source = "{source}fn("
        var calls: List<string> = []
        for index: int in
            0..abi.parameter_types.len() {
            var callback_name: string = ""
            for callback: CAbiCallbackDescription in
                abi.callbacks {
                if callback.parameter_index == index {
                    callback_name =
                        "beans_ffi_cb{index}"
                }
            }
            if callback_name == "" {
                calls.push(
                    "*({abi.parameter_types[index]}*)args[{index}]")
            } else {
                var callback_types: string =
                    "void"
                var callback_result: string =
                    "void"
                for callback:
                        CAbiCallbackDescription in
                    abi.callbacks {
                    if callback.parameter_index ==
                       index {
                        callback_result =
                            callback.return_type
                        if callback.parameter_types.len() !=
                               0 {
                            callback_types =
                                callback.parameter_types.join(
                                    ", ")
                        }
                    }
                }
                calls.push(
                    "({callback_name}_stored ? ({callback_result} (*)({callback_types})){callback_name}_stored : {callback_name})")
            }
        }
        source = "{source}{calls.join(", ")});\n"
        for callback: CAbiCallbackDescription in
            abi.callbacks {
            let prefix: string =
                "beans_ffi_cb{callback.parameter_index}"
            source =
                "{source}  {prefix}_dispatch = {prefix}_old_dispatch;\n"
            source =
                "{source}  {prefix}_context = {prefix}_old_context;\n"
        }
        if function.result.name != "unit" {
            source =
                "{source}  *({abi.return_type}*)result = call_result;\n"
        }
        return "{source}\}\n"
    }

    fn ffi_pack_argument(
        packed: Bytes, value: string) {
        packed.append_string(value)
        packed.push(0)
    }

    // The instruction set and float ABI every bridge this interpreter builds
    // must be compiled for. Clang's own default is not it: on a Raspbian
    // ARMv6 host clang defaults to ARMv7-A with unaligned access, and the
    // bridge is dlopened into this ARMv6 process, so the first vendored
    // `movw` stops the program with SIGILL. `beansc build` never had the
    // problem because the native driver appends exactly these flags to
    // every compile and link. Empty on targets that need no such pinning.
    fn ffi_pack_target_flags(argv: Bytes) {
        for flag: string in
            self.program.target.c_driver_flags() {
            self.ffi_pack_argument(argv, flag)
        }
    }

    // The bridge has to be built by the same C driver `beansc build` would
    // select, so an installation that names its compiler through BEANS_CC
    // cannot build programs and still fail the moment one is interpreted.
    fn ffi_c_driver() -> string {
        match host_os.env("BEANS_CC") {
            some(value) => {
                if value != "" { return value }
            }
            none => {}
        }
        return "clang"
    }

    // Forward one host environment variable into a packed "NAME=value" block,
    // dropping it silently when the host does not set it.
    fn ffi_forward_env(
        environment: Bytes, name: string) {
        match host_os.env(name) {
            some(value) => {
                self.ffi_pack_argument(
                    environment, "{name}={value}")
            }
            none => {}
        }
    }

    fn ffi_bridge(
        function: HirFunction,
        source: string) -> int {
        match self.ffi_bridge_addresses.get(
                source) {
            some(address) => { return address }
            none => {}
        }
        let sequence: int =
            self.ffi_bridge_sequence
        self.ffi_bridge_sequence += 1
        let stem: string =
            "{Dir.temp_path()}/beans-ffi-{host_time.monotonic_nanos()}-{sequence}"
        let c_path: string = "{stem}.c"
        let library_path: string =
            if self.program.target.os == "macos" {
                "{stem}.dylib"
            } else if self.program.target.os == "windows" {
                "{stem}.dll"
            } else {
                "{stem}.so"
            }
        match host_fs.write(c_path, source) {
            ok(_) => {}
            err(error) => {
                return self.fail_extern(
                    function,
                    "cannot write C ABI bridge: {error.msg}").int_data
            }
        }
        let c_driver: string =
            self.ffi_c_driver()
        let argv: Bytes = new Bytes(0)
        self.ffi_pack_argument(argv, c_driver)
        self.ffi_pack_argument(argv, "-O2")
        if self.program.target.os == "macos" {
            self.ffi_pack_argument(
                argv, "-dynamiclib")
            self.ffi_pack_argument(
                argv, "-undefined")
            self.ffi_pack_argument(
                argv, "dynamic_lookup")
        } else {
            self.ffi_pack_argument(argv, "-shared")
            // Windows code is position-independent by construction, so there
            // is nothing for -fPIC to ask for; clang rejects it outright for
            // the MSVC targets rather than ignoring it.
            if self.program.target.os != "windows" {
                self.ffi_pack_argument(argv, "-fPIC")
            }
        }
        let native_musl: bool =
            self.program.target.env == "musl" &&
            self.program.target.triple == host_target_name()
        if !native_musl {
            // The bridge is loaded into this process, so it must match this
            // process's ABI. This is also required when qemu-user runs the
            // target compiler but starts host-native Clang as a child.
            self.ffi_pack_argument(
                argv, "--target={self.program.target.llvm_triple()}")
        }
        let compiler_arch: string = compiler_default_arch(c_driver)
        if self.program.target.os == "linux" &&
           compiler_arch != "" &&
           compiler_arch != self.program.target.arch {
            if self.program.target.triple ==
                   "powerpc64-unknown-linux-gnu" {
                let ppc64_ld: string =
                    doctor_resolve("powerpc64-linux-gnu-ld")
                if ppc64_ld != "" {
                    self.ffi_pack_argument(
                        argv, "-fuse-ld={ppc64_ld}")
                }
            } else {
                self.ffi_pack_argument(argv, "-fuse-ld=lld")
            }
        }
        self.ffi_pack_target_flags(argv)
        self.ffi_pack_argument(argv, c_path)
        self.ffi_pack_argument(argv, "-o")
        self.ffi_pack_argument(argv, library_path)
        let environment: Bytes = new Bytes(0)
        // clang writes its intermediate object to the system temp directory, so a
        // child handed only PATH cannot compile the bridge on Windows: unlike
        // POSIX clang, which falls back to /tmp, Windows clang has no default and
        // dies with "unable to make temporary file". The failure surfaced as a
        // bare "C symbol not found: fabsf" — fabsf reaches the bridge because
        // msvcrt exports no float-suffixed math symbol for the module walk to
        // find, and the swallowed clang error left only the generic message. The
        // stage-0 interpreter hands clang the whole environment for this helper;
        // forward at least PATH and the temp-dir variables it needs.
        self.ffi_forward_env(environment, "PATH")
        self.ffi_forward_env(environment, "TMPDIR")
        self.ffi_forward_env(environment, "TEMP")
        self.ffi_forward_env(environment, "TMP")
        // MSVC's clang and lld find the Windows SDK and CRT through these
        // developer-prompt variables. Without them the fallback shim for a
        // static CRT symbol such as fabsf cannot compile or link.
        self.ffi_forward_env(environment, "INCLUDE")
        self.ffi_forward_env(environment, "LIB")
        self.ffi_forward_env(environment, "LIBPATH")
        var compiled: bool = false
        var compiler_error: string = ""
        match host_proc.run(
                argv, environment, "",
                new Bytes(0), 1048576) {
            ok(output) => {
                let status_bytes: Bytes = output.remove(0)
                let status: int = status_bytes.get_i64(0)
                let error_bytes: Bytes = output.remove(1)
                compiled = status == 0
                if error_bytes.len() != 0 {
                    compiler_error =
                        error_bytes.to_string()
                }
            }
            err(error) => {
                compiler_error = error.msg
            }
        }
        if !compiled {
            File.remove(c_path)
            File.remove(library_path)
            return self.fail_extern(
                function,
                "{c_driver} could not build the C ABI bridge: {compiler_error}").int_data
        }
        var handle: int = 0
        match host_dl.open(library_path) {
            ok(value) => { handle = value }
            err(error) => {
                File.remove(c_path)
                File.remove(library_path)
                return self.fail_extern(
                    function,
                    "cannot load C ABI bridge: {error.msg}").int_data
            }
        }
        var address: int = 0
        match host_dl.symbol(
                handle, "beans_ffi_bridge") {
            ok(value) => { address = value }
            err(error) => {
                host_dl.close(handle)
                File.remove(c_path)
                File.remove(library_path)
                return self.fail_extern(
                    function,
                    "cannot resolve C ABI bridge: {error.msg}").int_data
            }
        }
        File.remove(c_path)
        File.remove(library_path)
        self.ffi_bridge_handles.push(handle)
        self.ffi_bridge_addresses[source] =
            address
        return address
    }

    fn call_extern_bridge(
        function: HirFunction,
        arguments: List<TreeValue>,
        symbol: int,
        abi: CAbiDescription) -> TreeValue {
        let source: string =
            self.ffi_bridge_source(function, abi)
        let bridge: int =
            self.ffi_bridge(function, source)
        if self.failed { return TreeValue.unit() }

        var pointer_bridges: List<TreeFfiMemory> = []
        var storage: List<RawPtr<u8>> = []
        unsafe {
            // The bridge indexes these slots as void**, so each one is a host
            // pointer, not a fixed u64 — on a 32-bit host args[1] would land
            // in the high half of a widened slot and read as null.
            let pointers: RawPtr<RawPtr<u8> > =
                RawPtr.alloc(arguments.len())
            let contexts:
                RawPtr<RawPtr<u8> > =
                RawPtr.alloc(arguments.len())
            for index: int in 0..arguments.len() {
                let parameter_type: HirType =
                    function.parameters[index].type
                if parameter_type.name == "fn" {
                    pointers.offset(index).write(
                        RawPtr.null())
                    if arguments[index].kind ==
                           "stored_function" {
                        let stored_value:
                            TreeValue =
                            arguments[index]
                        match self.stored_callbacks.get(
                                  stored_value.object_id) {
                            some(callback) => {
                                let stored:
                                    RawPtr<u8> =
                                    RawPtr.alloc(
                                        self.program.target.pointer_size())
                                let slot:
                                    RawPtr<RawPtr<u8> > =
                                    RawPtr.from_address(
                                        stored.address())
                                slot.write(
                                    RawPtr.from_address(
                                        stored_value.int_data as u64))
                                storage.push(stored)
                                pointers.offset(
                                    index).write(
                                        stored)
                                contexts.offset(
                                    index).write(
                                        callback.context)
                            }
                            none => {
                                self.fail_extern(
                                    function,
                                    "StoredCallback is already closed")
                            }
                        }
                    } else {
                        contexts.offset(index).write(
                            RawPtr.from_address(
                                (((index + 1) * 2 +
                                  1) as u64)))
                    }
                } else {
                    let argument: RawPtr<u8> =
                        self.ffi_host_storage(
                            function,
                            function.parameters[index].type,
                            arguments[index],
                            pointer_bridges)
                    storage.push(argument)
                    pointers.offset(index).write(
                        argument)
                    contexts.offset(index).write(
                        RawPtr.null())
                }
            }
            var result_storage: RawPtr<u8> =
                RawPtr.null()
            if function.result.name != "unit" {
                let result_layout: LayoutAnswer =
                    self.layout(function.result)
                result_storage =
                    RawPtr.alloc(
                        result_layout.value.size)
            }
            let dispatch:
                fn(RawPtr<u8>, RawPtr<u8>,
                   RawPtr<RawPtr<u8> >) =
                fn(context: RawPtr<u8>,
                   callback_result: RawPtr<u8>,
                   callback_arguments:
                       RawPtr<RawPtr<u8> >) {
                    self.ffi_callback_dispatch(
                        function, arguments,
                        context, callback_result,
                        callback_arguments,
                        pointer_bridges)
                }
            beans_tree_ffi_invoke_bridge(
                RawPtr.from_address(
                    bridge as u64),
                RawPtr.from_address(
                    symbol as u64),
                result_storage,
                RawPtr.from_address(
                    pointers.address()),
                dispatch, contexts)
            var result: TreeValue =
                TreeValue.unit()
            if function.result.name != "unit" {
                if canonical_hir_name(
                       function.result.name) ==
                   "RawPtr" ||
                   canonical_hir_name(
                       function.result.name) ==
                   "CFunctionPtr" {
                    // A returned pointer can land inside one of the host
                    // copies made for the pointer arguments. Map it back to
                    // the interpreter memory the copy mirrors — exactly what
                    // the direct word path does — before ffi_sync_and_free
                    // frees the copy and the address dangles.
                    var raw_address: u64 = 0
                    if self.program.target.pointer_size() ==
                       8 {
                        let slot: RawPtr<u64> =
                            RawPtr.from_address(
                                result_storage.address())
                        raw_address = slot.read()
                    } else {
                        let slot: RawPtr<u32> =
                            RawPtr.from_address(
                                result_storage.address())
                        raw_address =
                            slot.read() as u64
                    }
                    if canonical_hir_name(
                           function.result.name) ==
                       "CFunctionPtr" {
                        let callback_type: HirType =
                            if function.result.args.len() == 1 {
                                function.result.args[0]
                            } else {
                                new HirType("poison")
                            }
                        result = TreeValue.host_pointer(
                            raw_address, callback_type)
                    } else {
                        result =
                            self.ffi_pointer_result(
                                function.result,
                                raw_address as int,
                                pointer_bridges)
                    }
                } else {
                    result =
                        self.ffi_read_host_storage(
                            function, function.result,
                            result_storage)
                }
                result_storage.free()
            }
            for argument: RawPtr<u8> in storage {
                argument.free()
            }
            pointers.free()
            contexts.free()
            self.ffi_sync_and_free(
                pointer_bridges)
            return result
        }
    }

    // dlsym(RTLD_DEFAULT, ...) finds libc's symbols because libc is a shared
    // library and exports them. Windows links the CRT's math and string helpers
    // out of a static archive, so they belong to no module's export table and no
    // walk of the loader's module list can reach them — fabsf resolves nowhere
    // while memset, which msvcrt.dll does export, resolves fine. The C compiler
    // can still name either one, so a symbol the loader cannot find is asked for
    // the same way c_global_address asks for a thread-local: compile a shim that
    // takes its address and hand the pointer back. The bridge is cached by
    // source text, so this costs one compile per symbol per run.
    // Resolves and caches the shared bridge library for one std.encoding
    // feature. The library is compiled once per host from the same vendored
    // sources `beansc build` links, cached content-addressed under
    // BEANS_HOME, and reused across runs — so `beansc run` needs the C
    // driver at most once per checkout or upgrade.
    fn ensure_encoding_bridge(feature: string) -> int {
        match self.encoding_handles.get(feature) {
            some(handle) => { return handle }
            none => {}
        }
        let library: string =
            self.encoding_bridge_library(feature)
        if library == "" {
            self.encoding_handles[feature] = 0
            return 0
        }
        var handle: int = 0
        match host_dl.open(library) {
            ok(value) => { handle = value }
            err(error) => {
                self.encoding_error =
                    "cannot load {library}: {error.msg}"
            }
        }
        self.encoding_handles[feature] = handle
        return handle
    }

    fn encoding_bridge_library(feature: string) -> string {
        let root: string = encoding_source_root()
        let source: string =
            encoding_bridge_translation_unit(root, feature)
        if !File.exists(source) {
            self.encoding_error =
                "cannot find the bridge sources under {root}; set BEANS_ENCODING to the directory holding runtime/encoding"
            return ""
        }
        var blob: string =
            "{self.program.target.triple}|interp|{self.program.target.c_driver_flags().join(" ")}"
        for input: string in
            encoding_bridge_inputs(root, feature) {
            match host_fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => {
                    blob = "{blob}|missing:{input}"
                }
            }
        }
        var hash: int = 0
        for index: int in 0..blob.len() {
            hash =
                (hash * 131 + blob.byte_at(index)) %
                2147483647
        }
        let extension: string =
            if self.program.target.os == "macos" {
                "dylib"
            } else if self.program.target.os == "windows" {
                "dll"
            } else {
                "so"
            }
        let cache_dir: string =
            "{beans_home()}/cache/encoding"
        let library: string =
            "{cache_dir}/beans_enc_{feature}.{self.program.target.triple}.{hash}.{extension}"
        if File.exists(library) { return library }
        match Dir.create_all(cache_dir) {
            ok(_) => {}
            err(error) => {
                self.encoding_error =
                    "cannot create {cache_dir}: {error.msg}"
                return ""
            }
        }
        let staging: string =
            "{library}.{host_time.monotonic_nanos()}"
        let c_driver: string = self.ffi_c_driver()
        let argv: Bytes = new Bytes(0)
        self.ffi_pack_argument(argv, c_driver)
        if encoding_bridge_is_cxx(feature) {
            self.ffi_pack_argument(argv, "-x")
            self.ffi_pack_argument(argv, "c++")
            self.ffi_pack_argument(argv, "-std=c++17")
            self.ffi_pack_argument(argv, "-fno-exceptions")
            self.ffi_pack_argument(argv, "-fno-rtti")
        }
        self.ffi_pack_argument(argv, "-O2")
        self.ffi_pack_argument(argv, "-fvisibility=hidden")
        if self.program.target.os == "macos" {
            self.ffi_pack_argument(argv, "-dynamiclib")
        } else {
            self.ffi_pack_argument(argv, "-shared")
            // See ffi_bridge above: -fPIC is not a thing to ask for on
            // Windows, and clang errors on it for the MSVC targets.
            if self.program.target.os != "windows" {
                self.ffi_pack_argument(argv, "-fPIC")
            }
        }
        if self.program.target.os == "windows" {
            // The bridge is loaded into this process, so it has to match
            // this process's ABI; see ffi_bridge above.
            self.ffi_pack_argument(
                argv,
                "--target={self.program.target.llvm_triple()}")
        }
        self.ffi_pack_target_flags(argv)
        self.ffi_pack_argument(argv, source)
        self.ffi_pack_argument(argv, "-o")
        self.ffi_pack_argument(argv, staging)
        let environment: Bytes = new Bytes(0)
        self.ffi_forward_env(environment, "PATH")
        self.ffi_forward_env(environment, "TMPDIR")
        self.ffi_forward_env(environment, "TEMP")
        self.ffi_forward_env(environment, "TMP")
        self.ffi_forward_env(environment, "INCLUDE")
        self.ffi_forward_env(environment, "LIB")
        self.ffi_forward_env(environment, "LIBPATH")
        var compiled: bool = false
        var compiler_error: string = ""
        match host_proc.run(
                argv, environment, "",
                new Bytes(0), 8388608) {
            ok(output) => {
                let status_bytes: Bytes = output.remove(0)
                let status: int = status_bytes.get_i64(0)
                let error_bytes: Bytes = output.remove(1)
                compiled = status == 0
                if error_bytes.len() != 0 {
                    compiler_error =
                        error_bytes.to_string()
                }
            }
            err(error) => {
                compiler_error = error.msg
            }
        }
        if !compiled {
            File.remove(staging)
            self.encoding_error =
                "building the bridge with {c_driver} failed: {compiler_error.trim()}"
            return ""
        }
        match File.rename(staging, library) {
            ok(_) => {}
            err(_) => {
                // a concurrent run already published the same content
                File.remove(staging)
            }
        }
        if File.exists(library) { return library }
        self.encoding_error =
            "cannot place the bridge library at {library}"
        return ""
    }

    // std.log is one C++ bridge backed by the pinned Quill headers. Like
    // encoding and networking, interpreted programs build it once into the
    // host cache, then resolve all beans_log_* symbols through that local
    // library handle.
    fn ensure_log_bridge() -> int {
        if self.log_handle != -1 { return self.log_handle }
        let library: string = self.log_bridge_library()
        if library == "" {
            self.log_handle = 0
            return 0
        }
        match host_dl.open(library) {
            ok(handle) => { self.log_handle = handle }
            err(error) => {
                self.log_handle = 0
                self.log_error =
                    "cannot load {library}: {error.msg}"
            }
        }
        return self.log_handle
    }

    // One list feeds both the host-library cache key and Clang. Root include
    // paths are normalized in the key below, so an identical installed copy
    // reuses the same content key.
    fn log_bridge_compile_arguments(
        root: string, c_driver: string
    ) -> List<string> {
        var flags: List<string> = [
            "-x", "c++", "-std=c++17", "-fexceptions", "-fno-rtti",
            "-O2", "-fvisibility=hidden", "-DBEANS_RT_PROFILE=3",
            "-I{root}", "-I{path.join(root, "vendor/quill/include")}"]
        if self.program.target.os == "macos" {
            flags.push("-dynamiclib")
        } else {
            flags.push("-shared")
            if self.program.target.os != "windows" { flags.push("-fPIC") }
        }
        // The hosted compiler can run under qemu while child processes still
        // run on the machine that launched qemu. Always tell that host Clang
        // which bridge ABI to build. Keep the native musl exception aligned
        // with the main driver because an explicit target can hide Alpine's
        // native startup files.
        let native_musl: bool =
            self.program.target.env == "musl" &&
            self.program.target.triple == host_target_name()
        if !native_musl {
            flags.push("--target={self.program.target.llvm_triple()}")
        }
        // qemu-user runs this target compiler but lets the child C driver run
        // natively on the launch machine. Its normal GNU ld only understands
        // that launch architecture. LLD handles the cross link, except for
        // big-endian ppc64 ELFv1, which needs the matching GNU cross linker.
        let compiler_arch: string = compiler_default_arch(c_driver)
        if self.program.target.os == "linux" &&
           compiler_arch != "" &&
           compiler_arch != self.program.target.arch {
            if self.program.target.triple ==
                   "powerpc64-unknown-linux-gnu" {
                let ppc64_ld: string =
                    doctor_resolve("powerpc64-linux-gnu-ld")
                if ppc64_ld != "" {
                    flags.push("-fuse-ld={ppc64_ld}")
                }
            } else {
                flags.push("-fuse-ld=lld")
            }
        }
        if self.program.target.os == "windows" {
            // A bridge loaded into a 32-bit hosted compiler must not resolve
            // libc++.dll or libunwind.dll from a 64-bit toolchain on PATH.
            // Keep GNU/LLVM-MinGW cache libraries self-contained. MSVC uses
            // the Windows C++ runtime instead and does not accept these flags.
            if self.program.target.env != "msvc" {
                flags.push("-static-libstdc++")
                flags.push("-static-libgcc")
            }
        }
        for flag: string in self.program.target.c_driver_flags() {
            flags.push(flag)
        }
        for flag: string in log_bridge_link_arguments(
                true, self.program.target.os,
                self.program.target.env) {
            flags.push(flag)
        }
        return move flags
    }

    fn log_bridge_library() -> string {
        let root: string = log_source_root()
        let source: string = path.join(root, "beans_log.cpp")
        if !File.exists(source) {
            self.log_error =
                "cannot find the std.log bridge under {root}; set BEANS_LOG to the directory holding runtime/log"
            return ""
        }
        let c_driver: string = self.ffi_c_driver()
        let compile_arguments: List<string> =
            self.log_bridge_compile_arguments(root, c_driver)
        var blob: string =
            "{self.program.target.triple}|interp|{log_bridge_abi()}"
        blob = "{blob}|{encoding_compiler_identity(c_driver)}"
        let include_root: string =
            path.join(root, "vendor/quill/include")
        for argument: string in compile_arguments {
            if argument == "-I{root}" {
                blob = "{blob}|-I<log-root>"
            } else if argument == "-I{include_root}" {
                blob = "{blob}|-I<quill-include>"
            } else {
                blob = "{blob}|{argument}"
            }
        }
        for input: string in log_bridge_inputs(root) {
            match host_fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => { blob = "{blob}|missing:{input}" }
            }
        }
        var hash: int = 0
        var mixed: int = 0
        for index: int in 0..blob.len() {
            let byte: int = blob.byte_at(index)
            hash = (hash * 131 + byte) % 2147483647
            mixed =
                (mixed * 16777619 + byte + index % 7) %
                2147483629
        }
        let extension: string =
            if self.program.target.os == "macos" {
                "dylib"
            } else if self.program.target.os == "windows" {
                "dll"
            } else {
                "so"
            }
        let cache_dir: string = "{beans_home()}/cache/log"
        let library: string =
            "{cache_dir}/beans_log.{self.program.target.triple}.{hash}x{mixed}.{extension}"
        if File.exists(library) { return library }
        match Dir.create_all(cache_dir) {
            ok(_) => {}
            err(error) => {
                self.log_error =
                    "cannot create {cache_dir}: {error.msg}"
                return ""
            }
        }
        var stamp: string = "{host_time.monotonic_nanos()}"
        match host_random.bytes(8) {
            ok(seed) => { stamp = "{stamp}.{seed.get_u64(0)}" }
            err(_) => { stamp = "{stamp}.{host_time.wall_nanos()}" }
        }
        let staging: string = "{library}.{stamp}"
        let argv: Bytes = new Bytes(0)
        self.ffi_pack_argument(argv, c_driver)
        for argument: string in compile_arguments {
            self.ffi_pack_argument(argv, argument)
        }
        self.ffi_pack_argument(argv, source)
        self.ffi_pack_argument(argv, "-o")
        self.ffi_pack_argument(argv, staging)
        let environment: Bytes = new Bytes(0)
        self.ffi_forward_env(environment, "PATH")
        self.ffi_forward_env(environment, "TMPDIR")
        self.ffi_forward_env(environment, "TEMP")
        self.ffi_forward_env(environment, "TMP")
        self.ffi_forward_env(environment, "INCLUDE")
        self.ffi_forward_env(environment, "LIB")
        self.ffi_forward_env(environment, "LIBPATH")
        var compiled: bool = false
        var compiler_error: string = ""
        match host_proc.run(
                argv, environment, "",
                new Bytes(0), 8388608) {
            ok(output) => {
                let status_bytes: Bytes = output.remove(0)
                let normal_bytes: Bytes = output.remove(0)
                let error_bytes: Bytes = output.remove(0)
                compiled = status_bytes.get_i64(0) == 0
                if normal_bytes.len() != 0 {
                    compiler_error = normal_bytes.to_string()
                }
                if error_bytes.len() != 0 {
                    if compiler_error != "" {
                        compiler_error = "{compiler_error}\n"
                    }
                    compiler_error =
                        "{compiler_error}{error_bytes.to_string()}"
                }
            }
            err(error) => { compiler_error = error.msg }
        }
        if !compiled {
            File.remove(staging)
            self.log_error =
                "building the std.log bridge with {c_driver} failed: {compiler_error.trim()}"
            return ""
        }
        match File.rename(staging, library) {
            ok(_) => {}
            err(_) => { File.remove(staging) }
        }
        if File.exists(library) { return library }
        self.log_error =
            "cannot place the std.log bridge library at {library}"
        return ""
    }

    // Resolves and caches the shared bridge library for one networking
    // feature, exactly the std.encoding mechanism: compiled once per host
    // from the same sources `beansc build` links, cached content-addressed
    // under BEANS_HOME, loaded RTLD_LOCAL.
    fn ensure_net_bridge(feature: string) -> int {
        match self.net_handles.get(feature) {
            some(handle) => { return handle }
            none => {}
        }
        let library: string =
            self.net_bridge_library(feature)
        if library == "" {
            self.net_handles[feature] = 0
            return 0
        }
        var handle: int = 0
        match host_dl.open(library) {
            ok(value) => { handle = value }
            err(error) => {
                self.net_error =
                    "cannot load {library}: {error.msg}"
            }
        }
        self.net_handles[feature] = handle
        return handle
    }

    // Runs the C driver once with the packed argv; reports (status == 0)
    // and captures linker stdout plus compiler stderr on failure.
    fn net_bridge_tool(argv: Bytes, c_driver: string) -> bool {
        let environment: Bytes = new Bytes(0)
        self.ffi_forward_env(environment, "PATH")
        self.ffi_forward_env(environment, "TMPDIR")
        self.ffi_forward_env(environment, "TEMP")
        self.ffi_forward_env(environment, "TMP")
        self.ffi_forward_env(environment, "INCLUDE")
        self.ffi_forward_env(environment, "LIB")
        self.ffi_forward_env(environment, "LIBPATH")
        var compiled: bool = false
        var compiler_error: string = ""
        match host_proc.run(
                argv, environment, "",
                new Bytes(0), 8388608) {
            ok(output) => {
                let status_bytes: Bytes = output.remove(0)
                let normal_bytes: Bytes = output.remove(0)
                let error_bytes: Bytes = output.remove(0)
                let status: int = status_bytes.get_i64(0)
                compiled = status == 0
                if normal_bytes.len() != 0 {
                    compiler_error = normal_bytes.to_string()
                }
                if error_bytes.len() != 0 {
                    if compiler_error != "" {
                        compiler_error = "{compiler_error}\n"
                    }
                    compiler_error = "{compiler_error}{error_bytes.to_string()}"
                }
            }
            err(error) => {
                compiler_error = error.msg
            }
        }
        if !compiled {
            self.net_error =
                "building the networking bridge with {c_driver} failed: {compiler_error.trim()}"
        }
        return compiled
    }

    // A feature's bridge may span several translation units (the shim plus
    // vendored C files that cannot share one), so the library builds in two
    // steps: each unit to its own staged object, then one link. Everything
    // is content-addressed the same way as the encoding bridge.
    fn net_bridge_library(feature: string) -> string {
        let root: string = net_source_root()
        let sources: List<string> =
            net_bridge_translation_units(root, feature)
        for source: string in sources {
            if !File.exists(source) {
                self.net_error =
                    "cannot find the networking bridge sources under {root}; set BEANS_NET to the directory holding runtime/net"
                return ""
            }
        }
        var blob: string =
            "{self.program.target.triple}|interp|{net_bridge_abi()}|{self.program.target.c_driver_flags().join(" ")}"
        for input: string in
            net_bridge_inputs(root, feature) {
            match host_fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => {
                    blob = "{blob}|missing:{input}"
                }
            }
        }
        var hash: int = 0
        for index: int in 0..blob.len() {
            hash =
                (hash * 131 + blob.byte_at(index)) %
                2147483647
        }
        let extension: string =
            if self.program.target.os == "macos" {
                "dylib"
            } else if self.program.target.os == "windows" {
                "dll"
            } else {
                "so"
            }
        let cache_dir: string =
            "{beans_home()}/cache/net"
        let library: string =
            "{cache_dir}/beans_net_{feature}.{self.program.target.triple}.{hash}.{extension}"
        if File.exists(library) { return library }
        match Dir.create_all(cache_dir) {
            ok(_) => {}
            err(error) => {
                self.net_error =
                    "cannot create {cache_dir}: {error.msg}"
                return ""
            }
        }
        // Two interpreted threads can reach the same content cache before
        // either has published the bridge.  Some hosts expose a coarse
        // monotonic clock, so time alone can give both builds the same object
        // names and let one build remove the other's inputs.  Keep the time
        // prefix for diagnostics and add an OS-random nonce for staging.
        var stamp: string = "{host_time.monotonic_nanos()}"
        match host_random.bytes(8) {
            ok(seed) => {
                stamp = "{stamp}.{seed.get_u64(0)}"
            }
            err(_) => {
                stamp = "{stamp}.{host_time.wall_nanos()}"
            }
        }
        let c_driver: string = self.ffi_c_driver()
        var objects: List<string> = []
        var object_index: int = 0
        var failed: bool = false
        for source: string in sources {
            if !failed {
                let object: string =
                    "{library}.{stamp}.{object_index}.o"
                object_index += 1
                let argv: Bytes = new Bytes(0)
                self.ffi_pack_argument(argv, c_driver)
                if net_source_is_cxx(source) {
                    self.ffi_pack_argument(argv, "-x")
                    self.ffi_pack_argument(argv, "c++")
                    self.ffi_pack_argument(argv, "-std=c++17")
                    self.ffi_pack_argument(argv, "-fno-exceptions")
                    self.ffi_pack_argument(argv, "-fno-rtti")
                }
                self.ffi_pack_argument(argv, "-O2")
                self.ffi_pack_argument(argv, "-fvisibility=hidden")
                for flag: string in
                    net_bridge_include_flags(root, feature) {
                    self.ffi_pack_argument(argv, flag)
                }
                for flag: string in
                    net_bridge_platform_flags(
                        feature, self.program.target.os,
                        self.program.target.env) {
                    self.ffi_pack_argument(argv, flag)
                }
                if self.program.target.os != "windows" {
                    // See ffi_bridge above: -fPIC is not a thing to ask
                    // for on Windows, and clang errors on it there.
                    self.ffi_pack_argument(argv, "-fPIC")
                }
                if self.program.target.os == "windows" {
                    // The bridge is loaded into this process, so it has to
                    // match this process's ABI; see ffi_bridge above.
                    self.ffi_pack_argument(
                        argv,
                        "--target={self.program.target.llvm_triple()}")
                }
                self.ffi_pack_target_flags(argv)
                self.ffi_pack_argument(argv, "-c")
                self.ffi_pack_argument(argv, source)
                self.ffi_pack_argument(argv, "-o")
                self.ffi_pack_argument(argv, object)
                if self.net_bridge_tool(argv, c_driver) {
                    objects.push(object)
                } else {
                    failed = true
                }
            }
        }
        var library_path: string = ""
        if !failed {
            let staging: string = "{library}.{stamp}"
            let argv: Bytes = new Bytes(0)
            self.ffi_pack_argument(argv, c_driver)
            if self.program.target.os == "macos" {
                self.ffi_pack_argument(argv, "-dynamiclib")
            } else {
                self.ffi_pack_argument(argv, "-shared")
            }
            if self.program.target.os == "windows" {
                self.ffi_pack_argument(
                    argv,
                    "--target={self.program.target.llvm_triple()}")
                if self.program.target.env == "msvc" {
                    // The compiler's MSVC lane is already linked with lld.
                    // Use it for the interpreter's multi-object bridge DLLs
                    // too; link.exe rejects these staged cache paths.
                    self.ffi_pack_argument(argv, "-fuse-ld=lld")
                }
            }
            self.ffi_pack_target_flags(argv)
            for object: string in objects {
                self.ffi_pack_argument(argv, object)
            }
            // Platform libraries the feature stands on (Security.framework,
            // bcrypt) join the bridge library's own link.
            var only: List<string> = [feature]
            for flag: string in
                net_bridge_link_arguments(
                    only, self.program.target.os) {
                self.ffi_pack_argument(argv, flag)
            }
            self.ffi_pack_argument(argv, "-o")
            self.ffi_pack_argument(argv, staging)
            if self.net_bridge_tool(argv, c_driver) {
                match File.rename(staging, library) {
                    ok(_) => {}
                    err(_) => {
                        // a concurrent run already published the same content
                        File.remove(staging)
                    }
                }
                if File.exists(library) {
                    library_path = library
                } else {
                    self.net_error =
                        "cannot place the networking bridge library at {library}"
                }
            } else {
                File.remove(staging)
            }
        }
        for object: string in objects {
            File.remove(object)
        }
        return library_path
    }

    fn extern_symbol_address(
        function: HirFunction) -> int {
        // Runtime-side externs are answered by this very process first:
        // the same address on every platform, where the loader lookups
        // below depend on what the executable happens to export.
        var host_name: Bytes = new Bytes(0)
        host_name.append_string(function.extern_name)
        host_name.append(new Bytes(1))
        unsafe {
            let hosted: RawPtr<u8> =
                beans_rt_host_symbol(host_name.as_ptr())
            if hosted.address() != 0 {
                return hosted.address() as int
            }
        }
        match host_dl.global_symbol(
                  function.extern_name) {
            ok(address) => { return address }
            err(error) => {}
        }
        let linked: int =
            self.manifest_symbol_address(
                function.extern_name)
        if linked != 0 { return linked }
        // The std.encoding bridges live in RTLD_LOCAL shared libraries the
        // interpreter loads on demand, so their symbols are resolved through
        // the library handle rather than the global namespace.
        if function.extern_name.starts_with("beans_enc_") {
            let feature: string =
                encoding_feature_for_symbol(
                    function.extern_name)
            if feature != "" {
                let handle: int =
                    self.ensure_encoding_bridge(feature)
                if handle != 0 {
                    match host_dl.symbol(
                              handle,
                              function.extern_name) {
                        ok(address) => { return address }
                        err(_) => {}
                    }
                } else {
                    return self.fail_extern(
                        function,
                        "std.encoding.{feature} bridge library is unavailable: {self.encoding_error}").int_data
                }
            }
        }
        if log_symbol(function.extern_name) {
            let handle: int = self.ensure_log_bridge()
            if handle != 0 {
                match host_dl.symbol(
                          handle,
                          function.extern_name) {
                    ok(address) => { return address }
                    err(_) => {}
                }
            } else {
                return self.fail_extern(
                    function,
                    "std.log bridge library is unavailable: {self.log_error}").int_data
            }
        }
        // The networking bridges resolve the same way, through their own
        // RTLD_LOCAL libraries keyed by symbol prefix.
        let net_feature: string =
            net_feature_for_symbol(function.extern_name)
        if net_feature != "" {
            let handle: int =
                self.ensure_net_bridge(net_feature)
            if handle != 0 {
                match host_dl.symbol(
                          handle,
                          function.extern_name) {
                    ok(address) => { return address }
                    err(_) => {}
                }
            } else {
                return self.fail_extern(
                    function,
                    "networking bridge '{net_feature}' is unavailable: {self.net_error}").int_data
            }
        }
        let builder: CAbiTextBuilder =
            new CAbiTextBuilder(self.program)
        let abi: CAbiDescription =
            builder.describe(function)
        var parameters: string =
            abi.parameter_declarations.join(", ")
        if parameters == "" { parameters = "void" }
        // This declaration must carry the real signature. Clang knows the CRT
        // builtins, so spelling fabsf as `extern void fabsf()` conflicts with
        // its `float(float)` declaration before the shim can reach the linker.
        var source: string =
            "#include <stdint.h>\n{abi.definitions}"
        source =
            "{source}extern {abi.return_type} {function.extern_name}({parameters});\n"
        source =
            "{source}{ffi_export_attribute()}"
        source =
            "{source}void* beans_ffi_bridge(void) \{ return (void*)&{function.extern_name}; \}\n"
        let bridge: int =
            self.ffi_bridge(function, source)
        if self.failed {
            // A shim that will not link means the symbol is genuinely absent.
            // Say that, rather than blaming the bridge the caller never asked
            // for — the message has to match what every other platform prints.
            self.panic_text =
                "runtime panic at {function.line}:{function.col}: C symbol not found: {function.extern_name}"
            return 0
        }
        unsafe {
            return host_dl.call0(bridge)
        }
    }

    fn call_extern(
        function: HirFunction,
        arguments: List<TreeValue>) -> TreeValue {
        let symbol: int =
            self.extern_symbol_address(function)
        if self.failed { return TreeValue.unit() }

        let result_name: string =
            canonical_hir_name(function.result.name)
        let first_name: string =
            if function.parameters.len() > 0 {
                canonical_hir_name(
                    function.parameters[0].type.name)
            } else {
                ""
            }
        var result: TreeValue = TreeValue.unit()
        var called: bool = false
        unsafe {
            if arguments.len() == 1 &&
               (first_name == "float" ||
                first_name == "f32") &&
               result_name == first_name {
                result = TreeValue.floating(
                    if first_name == "f32" {
                        host_dl.call_f32_1(
                            symbol,
                            arguments[0].float_data)
                    } else {
                        host_dl.call_f64_1(
                            symbol,
                            arguments[0].float_data)
                    })
                called = true
            } else if arguments.len() == 2 &&
                      (first_name == "float" ||
                       first_name == "f32") &&
                      hir_is_integer(
                          function.parameters[1].type) &&
                      result_name == first_name {
                result = TreeValue.floating(
                    if first_name == "f32" {
                        host_dl.call_f32_i32(
                            symbol,
                            arguments[0].float_data,
                            arguments[1].int_data)
                    } else {
                        host_dl.call_f64_i32(
                            symbol,
                            arguments[0].float_data,
                            arguments[1].int_data)
                    })
                called = true
            }
        }
        if called { return result }

        // host_dl.callN passes every argument as one 8-byte word. A 64-bit
        // host gives each word its own argument slot, so a narrower integer
        // still lands where the callee reads it. A 32-bit host splits the
        // word across two native slots (i386 stack halves, EABI register
        // pairs): a parameter narrower than the word leaves a stray
        // high-half slot that shifts every argument after it, so only the
        // final parameter may be narrow there. Anything else routes to the
        // Clang-classified bridge, which marshals by declared width.
        let host_pointer_bytes: int =
            self.program.target.pointer_size()
        var direct_words: bool =
            arguments.len() <= 3
        for index: int in
            0..function.parameters.len() {
            let parameter_type: HirType =
                function.parameters[index].type
            let name: string =
                canonical_hir_name(
                    parameter_type.name)
            var native_bytes: int = 0
            if name == "RawPtr" ||
               name == "CFunctionPtr" {
                native_bytes = host_pointer_bytes
            } else if hir_is_integer(
                          parameter_type) &&
                      tree_integer_bits(name) >= 32 {
                native_bytes =
                    tree_integer_bits(name) / 8
            } else {
                direct_words = false
            }
            if host_pointer_bytes < 8 &&
               native_bytes < 8 &&
               index + 1 <
                   function.parameters.len() {
                direct_words = false
            }
        }
        if result_name == "bool" {
            direct_words = false
        } else if result_name != "unit" &&
                  result_name != "RawPtr" &&
                  result_name != "CFunctionPtr" &&
                  (!hir_is_integer(function.result) ||
                   tree_integer_bits(
                       result_name) < 32) {
            direct_words = false
        }
        if !direct_words {
            let builder: CAbiTextBuilder =
                new CAbiTextBuilder(self.program)
            return self.call_extern_bridge(
                function, arguments, symbol,
                builder.describe(function))
        }

        var bridges: List<TreeFfiMemory> = []
        var words: List<int> = []
        var word_signature: bool =
            arguments.len() <= 3
        for index: int in 0..arguments.len() {
            let type: HirType =
                function.parameters[index].type
            let name: string =
                canonical_hir_name(type.name)
            if name == "RawPtr" ||
               name == "CFunctionPtr" {
                words.push(
                    self.ffi_pointer_word(
                        function, arguments[index],
                        bridges))
            } else if hir_is_integer(type) {
                words.push(arguments[index].int_data)
            } else if name == "bool" {
                words.push(
                    if arguments[index].bool_data {
                        1
                    } else {
                        0
                    })
            } else {
                word_signature = false
                words.push(0)
            }
        }
        if self.failed {
            self.ffi_sync_and_free(bridges)
            return TreeValue.unit()
        }
        if !word_signature ||
           (result_name != "unit" &&
            result_name != "RawPtr" &&
            result_name != "CFunctionPtr" &&
            result_name != "bool" &&
            !hir_is_integer(function.result)) {
            self.ffi_sync_and_free(bridges)
            return self.fail_extern(
                function,
                "extern C signature is not in the Beans interpreter yet")
        }

        var raw: int = 0
        unsafe {
            if result_name == "unit" {
                if words.len() == 0 {
                    host_dl.call_void0(symbol)
                } else if words.len() == 1 {
                    host_dl.call_void1(
                        symbol, words[0])
                } else if words.len() == 2 {
                    host_dl.call_void2(
                        symbol, words[0], words[1])
                } else {
                    host_dl.call_void3(
                        symbol, words[0], words[1],
                        words[2])
                }
            } else {
                if words.len() == 0 {
                    raw = host_dl.call0(symbol)
                } else if words.len() == 1 {
                    raw = host_dl.call1(
                        symbol, words[0])
                } else if words.len() == 2 {
                    raw = host_dl.call2(
                        symbol, words[0], words[1])
                } else {
                    raw = host_dl.call3(
                        symbol, words[0], words[1],
                        words[2])
                }
            }
        }
        if result_name == "RawPtr" {
            result = self.ffi_pointer_result(
                function.result, raw, bridges)
        } else if result_name == "CFunctionPtr" {
            let callback_type: HirType =
                if function.result.args.len() == 1 {
                    function.result.args[0]
                } else {
                    new HirType("poison")
                }
            result = TreeValue.host_pointer(
                raw as u64, callback_type)
        } else if result_name != "unit" {
            result = self.ffi_integer_result(
                function.result, raw)
        }
        self.ffi_sync_and_free(bridges)
        return result
    }

    fn invoke(function: HirFunction,
              arguments: List<TreeValue>,
              receiver: Option<TreeValue>) -> TreeValue {
        return self.invoke_bound(
            function, arguments, receiver,
            self.current_type_bindings())
    }

    fn invoke_bound(function: HirFunction,
                    arguments: List<TreeValue>,
                    receiver: Option<TreeValue>,
                    move bindings: Map<string, HirType>) -> TreeValue {
        self.generic_type_bindings.push(move bindings)
        if function.is_extern_c && !function.is_c_export {
            let result: TreeValue = self.call_extern(
                function, arguments)
            self.generic_type_bindings.remove(
                self.generic_type_bindings.len() - 1)
            return result
        }
        let frame: TreeFrame = new TreeFrame()
        match receiver {
            some(value) => {
                frame.self_value = some(value)
                if function.self_binding_id >= 0 {
                    frame.set(
                        function.self_binding_id, value)
                }
            }
            none => {}
        }
        for index: int in 0..function.parameters.len() {
            if index < arguments.len() {
                let argument: TreeValue =
                    if function.parameters[index].passing ==
                           "move" ||
                       function.parameters[index].passing ==
                           "inout" {
                        arguments[index]
                    } else {
                        tree_value_copy(
                            arguments[index])
                    }
                frame.set(
                    function.parameters[index].binding_id,
                    argument)
            }
        }
        match self.debugger {
            some(session) => {
                session.push_frame(function, frame)
            }
            none => {}
        }
        self.active_functions.push(function.qualified)
        var result: TreeValue = TreeValue.unit()
        for statement: HirNode in function.body {
            let flow: TreeExec =
                self.statement(statement, frame)
            if flow.kind == "return" {
                result = flow.value
                break
            }
            if flow.kind != "next" { break }
        }
        self.run_defers(frame)
        match self.debugger {
            some(session) => { session.pop_frame() }
            none => {}
        }
        self.active_functions.remove(
            self.active_functions.len() - 1)
        self.generic_type_bindings.remove(
            self.generic_type_bindings.len() - 1)
        return result
    }

    fn run() -> bool {
        if self.failed { return false }
        self.initialize_static_fields()
        if self.failed { return false }
        self.initialize_singletons()
        if self.failed { return false }
        match self.find_function(self.program.entry_symbol) {
            some(entry) => {
                self.invoke(entry, [], none)
            }
            none => {
                self.failed = true
                self.panic_text =
                    "runtime panic: program has no main function"
            }
        }
        return !self.failed
    }
}
