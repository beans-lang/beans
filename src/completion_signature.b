package main

// The call a cursor sits inside, and which argument it is on.
class SemanticCallSite {
    id: string
    argument: int

    fn init() {
        self.id = ""
        self.argument = 0
    }
}

fn semantic_call_nodes(node: AstNode, line: int, col: int,
                       found: List<AstNode>) {
    if node.kind == "call" || node.kind == "new" {
        // Strictly inside the parentheses: on the `(` itself the cursor is
        // still on the callee.
        if sem_before(node.line, node.col, line, col) &&
           !sem_before(node.end_line, node.end_col, line, col) {
            found.push(node)
        }
    }
    for child: AstNode in node.children {
        semantic_call_nodes(child, line, col, found)
    }
    for piece: AstNode in node.interpolations {
        semantic_call_nodes(piece, line, col, found)
    }
}

fn semantic_call_at(snapshot: SemanticSnapshot, path: string,
                    line: int, col: int) -> SemanticCallSite {
    let site: SemanticCallSite = new SemanticCallSite()
    for package: LoadedPackage in snapshot.loader.packages {
        for parsed: ParsedModuleFile in package.files {
            if parsed.path != path { continue }
            var hits: List<AstNode> = []
            semantic_call_nodes(parsed.ast, line, col, hits)
            if hits.len() == 0 { return site }
            // The innermost open call wins.
            var chosen: AstNode = hits[0]
            for candidate: AstNode in hits {
                if sem_before(chosen.line, chosen.col,
                              candidate.line, candidate.col) {
                    chosen = candidate
                }
            }
            match chosen.checked {
                some(lowered) => {
                    if lowered.resolved != "" {
                        site.id =
                            sem_function_id(lowered.resolved)
                    }
                }
                none => {}
            }
            if site.id == "" && chosen.children.len() != 0 {
                // A call whose own lowering failed can still name its
                // callee: the callee node was indexed on its own.
                let callee: AstNode = chosen.children[0]
                match snapshot.symbol_at(
                          path, callee.name_line,
                          callee.name_col) {
                    some(reference) => {
                        if sem_id_kind(reference.id) == "fn" {
                            site.id = reference.id
                        }
                    }
                    none => {}
                }
            }
            // The argument the cursor is on: the last one that starts at or
            // before it. `new T(...)` keeps its type as child 0.
            let first: int = if chosen.kind == "new" { 1 } else { 1 }
            var index: int = -1
            for at: int in first..chosen.children.len() {
                let argument: AstNode = chosen.children[at]
                if sem_before(line, col, argument.line,
                              argument.col) {
                    break
                }
                index = at - first
            }
            if index < 0 { index = 0 }
            site.argument = index
            return site
        }
    }
    return site
}

fn semantic_parameter_labels(snapshot: SemanticSnapshot,
                             id: string) -> List<string> {
    var labels: List<string> = []
    match snapshot.program {
        some(program) => {
            let qualified: string = sem_id_key(id)
            for function: HirFunction in program.functions {
                if function.qualified != qualified { continue }
                for parameter: HirParameter in function.parameters {
                    let passing: string =
                        if parameter.passing == "" {
                            ""
                        } else {
                            "{parameter.passing} "
                        }
                    labels.push(
                        "{passing}{parameter.name}: {render_hir_type(parameter.type)}")
                }
                break
            }
        }
        none => {}
    }
    return move labels
}
