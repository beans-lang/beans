#!/usr/bin/env bash
# Issue #202: hostile unsaved input must give one located diagnostic and leave
# the same LSP process usable after repair; input inside the limits must stay
# clean. One server process receives every document in turn.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "${BEANSC:-$PWD/build/beansc}" <<'PY'
import json, pathlib, re, subprocess, sys, tempfile

sys.path.insert(0, "tools")
from syntax_fuzz import limit_stack, nested_case

BIN = str(pathlib.Path(sys.argv[1]).resolve())
def frame(message):
    payload = json.dumps(message).encode()
    return b"Content-Length: %d\r\n\r\n" % len(payload) + payload

stack_limit = limit_stack()

with tempfile.TemporaryDirectory(prefix="beans-issue202-lsp-") as directory:
    path = pathlib.Path(directory) / "main.b"
    repaired = "fn main() {\n    let repaired: int = 7\n}\n"
    path.write_text(repaired)
    uri = path.as_uri()
    messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}]
    expectations = []
    version = 0
    rid = 10
    def else_if(n):
        arms = "".join(" else if x == %d { return %d }" % (i, i) for i in range(1, n))
        return ("fn pick(x: int) -> int {\n    if x == 0 { return 0 }" + arms +
                " else { return -1 }\n}\nfn main() {\n    let r: int = pick(3)\n}\n")
    hostile = [nested_case(shape, depth)["files"]["main.b"] for shape, depth in
               (("parentheses", 32768), ("calls", 8192), ("blocks", 32768),
                ("flat_members", 16384), ("flat_operators", 32768))] + [else_if(5000)]
    inside = [nested_case(shape, depth)["files"]["main.b"] for shape, depth in
              (("parentheses", 256), ("calls", 256), ("flat_operators", 4000),
               ("flat_members", 2000))] + [else_if(300)]
    scenarios = [(text, True) for text in hostile] + [(text, False) for text in inside]
    texts = {}
    for document, refused in scenarios:
        for text, want_error in ((document, refused), (repaired, False)):
            version += 1
            if version == 1:
                method = "textDocument/didOpen"
                params = {"textDocument": {"uri": uri, "languageId": "beans",
                                            "version": version, "text": text}}
            else:
                method = "textDocument/didChange"
                params = {"textDocument": {"uri": uri, "version": version},
                          "contentChanges": [{"text": text}]}
            texts[version] = text
            messages += [{"jsonrpc": "2.0", "method": method, "params": params},
                         {"jsonrpc": "2.0", "id": rid, "method": "textDocument/documentSymbol",
                          "params": {"textDocument": {"uri": uri}}},
                         {"jsonrpc": "2.0", "id": rid + 1, "method": "textDocument/hover",
                          "params": {"textDocument": {"uri": uri},
                                     "position": {"line": 1, "character": 18}}}]
            expectations.append((rid, version, want_error))
            rid += 2
    messages += [{"jsonrpc": "2.0", "id": 2, "method": "shutdown"},
                 {"jsonrpc": "2.0", "method": "exit"}]
    result = subprocess.run([BIN, "lsp"], input=b"".join(map(frame, messages)),
                            capture_output=True, timeout=60, preexec_fn=stack_limit)
    assert result.returncode == 0, (result.returncode, result.stderr.decode()[-1000:])
    objects = []
    remaining = result.stdout
    while remaining:
        header, remaining = remaining.split(b"\r\n\r\n", 1)
        length = int(re.search(rb"Content-Length: (\d+)", header).group(1))
        objects.append(json.loads(remaining[:length]))
        remaining = remaining[length:]
    replies = {obj["id"]: obj for obj in objects if "id" in obj}
    notes = {obj["params"]["version"]: obj["params"]["diagnostics"]
             for obj in objects if obj.get("method") == "textDocument/publishDiagnostics"}
    for request, version, refused in expectations:
        for answer in (request, request + 1):
            assert answer in replies and "error" not in replies[answer], (answer, replies.get(answer))
        if refused:
            diagnostics = notes.get(version, [])
            assert len(diagnostics) == 1, (version, diagnostics)
            assert re.fullmatch(r"nesting deeper than 256 levels|syntax chain deeper than 4096 levels",
                                diagnostics[0]["message"]), diagnostics
            start = diagnostics[0]["range"]["start"]
            lines = texts[version].split("\n")
            assert 0 <= start["line"] < len(lines) and 0 <= start["character"] <= len(lines[start["line"]]), start
        else:
            assert not notes.get(version, []), (version, notes.get(version))
            assert any(symbol["name"] == "main" for symbol in replies[request]["result"]), replies[request]
    print("ok one LSP process survives hostile nesting and chains with one located error each, "
          "recovers after repair, and keeps input inside the limits clean")
PY
