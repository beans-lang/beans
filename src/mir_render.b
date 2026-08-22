package main

fn render_mir_operands(operands: List<int>) -> string {
    var shown: List<string> = []
    for operand: int in operands {
        shown.push("v{operand}")
    }
    return shown.join(",")
}

fn render_mir(program: MirProgram) -> string {
    var lines: List<string> = []
    lines.push("target {program.target.triple}")
    for function: MirFunction in program.functions {
        let form: string =
            if function.closure_id >= 0 {
                "closure"
            } else if function.cleanup_id >= 0 {
                "cleanup"
            } else if function.external {
                "extern"
            } else if function.declaration {
                "declare"
            } else {
                "fn"
            }
        lines.push(
            "{form} {function.name} -> {render_hir_type(function.result)}")
        for capture: MirCapture in function.captures {
            lines.push(
                "  capture {capture.name} binding={capture.binding_id} l{capture.source}->l{capture.target}: {render_hir_type(capture.type)}")
        }
        for local: MirLocal in function.locals {
            var flags: List<string> = [local.ownership]
            if local.parameter { flags.push("parameter") }
            if local.mutable { flags.push("mutable") }
            if local.passing != "" {
                flags.push(local.passing)
            }
            if local.needs_live_flag {
                flags.push("live-flag")
            }
            if local.borrows_from >= 0 {
                flags.push(
                    "borrows=l{local.borrows_from}")
            }
            if local.ownership_sink {
                flags.push("ownership-sink")
            }
            if local.scalar_replaced {
                flags.push("scalar-replaced")
            }
            if local.scalar_replaced_owner >= 0 &&
               local.scalar_replaced_owner != local.id {
                flags.push(
                    "scalar-owner=l{local.scalar_replaced_owner}")
            }
            if local.stack_closure_id >= 0 {
                flags.push(
                    "stack-closure={local.stack_closure_id}")
            }
            lines.push(
                "  local l{local.id} {local.name}: {render_hir_type(local.type)} {flags.join(",")} binding={local.binding_id}")
        }
        for block: MirBlock in function.blocks {
            let reach: string =
                if block.reachable { "" } else { " unreachable" }
            lines.push("  bb{block.id}:{reach}")
            for instruction: MirInstruction in
                block.instructions {
                if instruction.removed { continue }
                var prefix: string = "    "
                if instruction.result >= 0 {
                    prefix =
                        "{prefix}v{instruction.result} = "
                }
                var detail: string = instruction.op
                if instruction.text != "" {
                    detail =
                        "{detail} {instruction.text}"
                }
                if instruction.resolved != "" {
                    detail =
                        "{detail} resolved={instruction.resolved}"
                }
                if instruction.devirtualized_receiver != "" {
                    detail =
                        "{detail} devirtualized={instruction.devirtualized_receiver}"
                }
                if instruction.local >= 0 {
                    detail =
                        "{detail} local=l{instruction.local}"
                }
                if instruction.closure_id >= 0 {
                    detail =
                        "{detail} closure={instruction.closure_id}"
                }
                if instruction.cleanup_id >= 0 {
                    detail =
                        "{detail} cleanup={instruction.cleanup_id}"
                }
                if instruction.capture_locals.len() != 0 {
                    var captures: List<string> = []
                    for capture: int in
                        instruction.capture_locals {
                        captures.push("l{capture}")
                    }
                    detail =
                        "{detail} captures=({captures.join(",")})"
                }
                if instruction.operands.len() != 0 {
                    detail =
                        "{detail} ({render_mir_operands(instruction.operands)})"
                }
                if instruction.consumes.contains(true) {
                    var consumes: List<string> = []
                    for consumed: bool in
                        instruction.consumes {
                        consumes.push(
                            if consumed { "1" } else { "0" })
                    }
                    detail =
                        "{detail} consumes=({consumes.join(",")})"
                }
                if instruction.argument_passing.len() != 0 {
                    var passing: List<string> = []
                    for mode: string in
                        instruction.argument_passing {
                        passing.push(
                            if mode == "" {
                                "borrow"
                            } else {
                                mode
                            })
                    }
                    detail =
                        "{detail} passing=({passing.join(",")})"
                }
                if instruction.releases.len() != 0 {
                    detail =
                        "{detail} releases=({render_mir_operands(instruction.releases)})"
                }
                if instruction.incoming_blocks.len() != 0 {
                    var incoming: List<string> = []
                    for source: int in
                        instruction.incoming_blocks {
                        incoming.push("bb{source}")
                    }
                    detail =
                        "{detail} from=({incoming.join(",")})"
                }
                if instruction.result >= 0 {
                    detail =
                        "{detail} : {render_hir_type(instruction.type)} {instruction.ownership} effects={instruction.effects}"
                    let alias: int =
                        function.value_alias[
                            instruction.result]
                    if alias >= 0 {
                        detail =
                            "{detail} alias=v{alias}"
                    }
                }
                if instruction.last_use {
                    detail = "{detail} last-use"
                }
                if instruction.op == "retain" &&
                   instruction.local >= 0 {
                    detail =
                        "{detail} transfer=l{instruction.local}"
                }
                if instruction.borrow_elided {
                    detail = "{detail} borrow-elided"
                }
                if instruction.stack_closure {
                    detail = "{detail} stack-closure"
                }
                if instruction.bounds_elided {
                    detail = "{detail} bounds-elided"
                }
                if instruction.scalar_materialize {
                    detail =
                        "{detail} scalar-materialize"
                }
                lines.push("{prefix}{detail}")
            }
            let terminator: MirTerminator = block.terminator
            var tail: string =
                "    {terminator.kind}"
            if terminator.value >= 0 {
                tail =
                    "{tail} v{terminator.value}"
                if terminator.consumes_value {
                    tail = "{tail} consumes"
                }
            }
            if terminator.targets.len() != 0 {
                var targets: List<string> = []
                for target: int in terminator.targets {
                    targets.push("bb{target}")
                }
                tail =
                    "{tail} -> {targets.join(",")}"
            }
            if terminator.patterns.len() != 0 {
                tail =
                    "{tail} patterns=({terminator.patterns.join("|")})"
            }
            if terminator.releases.len() != 0 {
                tail =
                    "{tail} releases=({render_mir_operands(terminator.releases)})"
            }
            lines.push(tail)
            for edge: MirEdgeRelease in
                block.edge_releases {
                if edge.values.len() != 0 {
                    lines.push(
                        "    edge_drop -> bb{edge.target} releases=({render_mir_operands(edge.values)})")
                }
            }
        }
    }
    return lines.join("\n")
}
