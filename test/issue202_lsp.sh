#!/usr/bin/env bash
# Hostile unsaved input must leave the same LSP process usable after repair.
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
    scenarios = [(shape, depth, True) for shape, depth in
                 (("parentheses", 32768), ("calls", 8192),
                  ("flat_members", 16384), ("flat_operators", 32768))]
    scenarios += [("flat_operators", 20000, False), ("flat_operators", 24400, False),
                  ("flat_members", 700, False)]
    for shape, depth, refused in scenarios:
        for text, want_error in ((nested_case(shape, depth)["files"]["main.b"], refused),
                                 (repaired, False)):
            version += 1
            if version == 1:
                method = "textDocument/didOpen"
                params = {"textDocument": {"uri": uri, "languageId": "beans",
                                            "version": version, "text": text}}
            else:
                method = "textDocument/didChange"
                params = {"textDocument": {"uri": uri, "version": version},
                          "contentChanges": [{"text": text}]}
            messages += [{"jsonrpc": "2.0", "method": method, "params": params},
                         {"jsonrpc": "2.0", "id": rid, "method": "textDocument/documentSymbol",
                          "params": {"textDocument": {"uri": uri}}}]
            expectations.append((rid, version, want_error))
            rid += 1
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
        assert request in replies and "error" not in replies[request], (request, replies)
        if refused:
            diagnostics = notes.get(version, [])
            assert len(diagnostics) == 1, (version, diagnostics)
            assert re.search(r"nesting|complexity", diagnostics[0]["message"]), diagnostics
        else:
            assert not notes.get(version, []), (version, notes.get(version))
            assert any(symbol["name"] == "main" for symbol in replies[request]["result"]), replies[request]
    print("ok one LSP process survives hostile nesting/chains, publishes one error, and handles repair/accepted long input")
PY
