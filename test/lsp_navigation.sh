#!/usr/bin/env bash
# Navigation, refactoring and hierarchy over the real LSP wire.
#
# Everything here goes through `beansc lsp` exactly as an editor would, with
# LSP's own coordinates: 0-based lines and UTF-16 columns.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "checking lsp navigation, rename and hierarchies"

python3 - "${BEANSC:-$PWD/build/beansc}" <<'PY'
import json, pathlib, re, shutil, subprocess, sys, tempfile, os

BIN = sys.argv[1]
ROOT = pathlib.Path.cwd()
FIXTURE = ROOT / "test/cases/semantic/main.b"
ALPHA = ROOT / "test/cases/semantic/alpha/alpha.b"
BETA = ROOT / "test/cases/semantic/beta/beta.b"


def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: %d\r\n\r\n%b" % (len(b), b)


def run(msgs, timeout=120):
    p = subprocess.run([BIN, "lsp"], input=b"".join(msgs),
                       capture_output=True, timeout=timeout)
    out = p.stdout.decode(errors="replace")
    objs = [json.loads(b) for b in
            re.findall(r"\r\n\r\n(\{.*?\})(?=Content-Length|\Z)", out, re.S)]
    return p.returncode, objs


def fail(m):
    print("FAIL:", m, file=sys.stderr)
    sys.exit(1)


class Session:
    """A scripted LSP conversation. Positions are written 1-based, the way an
    editor shows them, and converted on the way out."""

    def __init__(self, *docs):
        self.msgs = [frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                            "params": {"capabilities": {}}}),
                     frame({"jsonrpc": "2.0", "method": "initialized",
                            "params": {}})]
        self.next_id = 100
        for path in docs:
            self.open(path)

    def open(self, path, text=None):
        p = pathlib.Path(path)
        self.msgs.append(frame({
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {
                "uri": p.as_uri(), "languageId": "beans", "version": 1,
                "text": p.read_text() if text is None else text}}}))

    def change(self, path, text, version=2):
        self.msgs.append(frame({
            "jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": pathlib.Path(path).as_uri(),
                                        "version": version},
                       "contentChanges": [{"text": text}]}}))

    def edit(self, path, line, col, end_line, end_col, text, version=2):
        """An incremental change, in LSP's own 0-based coordinates."""
        self.msgs.append(frame({
            "jsonrpc": "2.0", "method": "textDocument/didChange",
            "params": {"textDocument": {"uri": pathlib.Path(path).as_uri(),
                                        "version": version},
                       "contentChanges": [{
                           "range": {"start": {"line": line, "character": col},
                                     "end": {"line": end_line,
                                             "character": end_col}},
                           "text": text}]}}))

    def ask(self, method, path, line=None, col=None, **extra):
        rid = self.next_id
        self.next_id += 1
        params = {"textDocument": {"uri": pathlib.Path(path).as_uri()}}
        if line is not None:
            params["position"] = {"line": line - 1, "character": col - 1}
        params.update(extra)
        self.msgs.append(frame({"jsonrpc": "2.0", "id": rid,
                                "method": method, "params": params}))
        return rid

    def raw(self, method, params):
        rid = self.next_id
        self.next_id += 1
        self.msgs.append(frame({"jsonrpc": "2.0", "id": rid,
                                "method": method, "params": params}))
        return rid

    def notify(self, method, params):
        self.msgs.append(frame({"jsonrpc": "2.0", "method": method,
                                "params": params}))

    def finish(self):
        self.msgs.append(frame({"jsonrpc": "2.0", "id": 2,
                                "method": "shutdown"}))
        self.msgs.append(frame({"jsonrpc": "2.0", "method": "exit"}))
        rc, objs = run(self.msgs)
        if rc != 0:
            fail(f"server exited {rc}")
        self.replies = {o["id"]: o for o in objs if "id" in o}
        self.notes = [o for o in objs if "method" in o]
        return self

    def result(self, rid):
        if rid not in self.replies:
            fail(f"no reply for request {rid}")
        if "error" in self.replies[rid]:
            fail(f"request {rid} failed: {self.replies[rid]['error']}")
        return self.replies[rid]["result"]

    def error(self, rid):
        if rid not in self.replies:
            fail(f"no reply for request {rid}")
        return self.replies[rid].get("error")


def at(result):
    """(path, 1-based line, 0-based utf-16 column) of a Location."""
    if result is None:
        return None
    r = result[0] if isinstance(result, list) else result
    uri = r["uri"]
    path = pathlib.Path(uri.replace("file://", "")).name
    return (path, r["range"]["start"]["line"] + 1,
            r["range"]["start"]["character"])


# ---------------------------------------------------------------------------
# Capabilities
# ---------------------------------------------------------------------------
s = Session()
s.finish()
caps = s.result(1)["capabilities"]
for want in ["hoverProvider", "definitionProvider", "declarationProvider",
             "typeDefinitionProvider", "implementationProvider",
             "referencesProvider", "documentHighlightProvider",
             "documentSymbolProvider", "workspaceSymbolProvider",
             "callHierarchyProvider", "typeHierarchyProvider",
             "renameProvider", "semanticTokensProvider",
             "completionProvider", "signatureHelpProvider"]:
    if want not in caps:
        fail(f"the server does not advertise {want}: {sorted(caps)}")
if caps["textDocumentSync"]["change"] != 2:
    fail("the server should ask for incremental sync")
print("ok capabilities: every navigation and hierarchy provider advertised")

# ---------------------------------------------------------------------------
# Definition, declaration, implementation, type definition
# ---------------------------------------------------------------------------
s = Session(FIXTURE)
# Circle.draw (line 24) is an override.
d_def = s.ask("textDocument/definition", FIXTURE, 24, 17)
d_decl = s.ask("textDocument/declaration", FIXTURE, 24, 17)
# The interface method lists every concrete body.
d_impl = s.ask("textDocument/implementation", FIXTURE, 10, 8)
# The interface type lists every implementing type.
t_impl = s.ask("textDocument/implementation", FIXTURE, 8, 11)
# A local's type definition reaches across packages.
t_def = s.ask("textDocument/typeDefinition", FIXTURE, 72, 9)
# A call through an interface: `item.draw()` inside draw_all.
i_call_decl = s.ask("textDocument/declaration", FIXTURE, 66, 27)
i_call_impl = s.ask("textDocument/implementation", FIXTURE, 66, 27)
# A built-in type has no declaration to point at.
builtin = s.ask("textDocument/typeDefinition", FIXTURE, 48, 9)
# Cross-package definition: alpha's `size`, not beta's.
x_def = s.ask("textDocument/definition", FIXTURE, 74, 20)
y_def = s.ask("textDocument/definition", FIXTURE, 74, 31)
s.finish()

if at(s.result(d_def)) != ("main.b", 24, 16):
    fail(f"definition of Circle.draw should be its own body: {s.result(d_def)}")
if at(s.result(d_decl)) != ("main.b", 10, 7):
    fail(f"declaration of Circle.draw should be Drawable.draw: "
         f"{s.result(d_decl)}")
impls = {at([r]) for r in s.result(d_impl)}
if impls != {("main.b", 24, 16), ("main.b", 36, 16), ("main.b", 42, 16)}:
    fail(f"Drawable.draw should list all three bodies: {impls}")
types = {at([r])[1] for r in s.result(t_impl)}
# Circle, Square, Rounded (through Circle) and Framed (through Circle too).
if types != {17, 29, 41, 88}:
    fail(f"Drawable should list every implementer, however deep: {types}")
if at(s.result(t_def)) != ("alpha.b", 6, 10):
    fail(f"typeDefinition of `a` should reach alpha.Shape: {s.result(t_def)}")
if at(s.result(i_call_decl)) != ("main.b", 10, 7):
    fail(f"a call through an interface should declare at the interface: "
         f"{s.result(i_call_decl)}")
if len(s.result(i_call_impl)) != 3:
    fail(f"a call through an interface should list every body: "
         f"{s.result(i_call_impl)}")
if s.result(builtin) is not None:
    fail(f"a built-in type has no location, got {s.result(builtin)}")
if at(s.result(x_def)) != ("alpha.b", 15, 11):
    fail(f"a.size() should reach alpha: {s.result(x_def)}")
if at(s.result(y_def)) != ("beta.b", 11, 11):
    fail(f"s.size() should reach beta: {s.result(y_def)}")
print("ok navigation: definition, declaration, implementation, typeDefinition")

# ---------------------------------------------------------------------------
# References, highlights and rename never touch same-named strangers
# ---------------------------------------------------------------------------
s = Session(FIXTURE)
refs_with = s.ask("textDocument/references", FIXTURE, 74, 20,
                  context={"includeDeclaration": True})
refs_without = s.ask("textDocument/references", FIXTURE, 74, 20,
                     context={"includeDeclaration": False})
highlight = s.ask("textDocument/documentHighlight", FIXTURE, 48, 9)
ren = s.ask("textDocument/rename", FIXTURE, 74, 20, newName="extent")
ren_local = s.ask("textDocument/rename", FIXTURE, 51, 13, newName="renamed")
ren_bad = s.ask("textDocument/rename", FIXTURE, 74, 20, newName="class")
ren_builtin = s.ask("textDocument/rename", FIXTURE, 48, 16, newName="nope")
prep = s.ask("textDocument/prepareRename", FIXTURE, 74, 20)
s.finish()

got = s.result(refs_with)
if len(got) != 2:
    fail(f"alpha's size has a declaration and one use: {got}")
files = {at([r])[0] for r in got}
if files != {"alpha.b", "main.b"}:
    fail(f"references crossed into the wrong package: {files}")
if len(s.result(refs_without)) != 1:
    fail(f"includeDeclaration=false should drop the declaration: "
         f"{s.result(refs_without)}")

hl = s.result(highlight)
if len(hl) != 2:
    fail(f"the outer `value` is written twice: {hl}")
if hl[0]["kind"] != 3 or hl[1]["kind"] != 2:
    fail(f"a declaration is a write and its use is a read: {hl}")

changes = s.result(ren)["changes"]
edits = sum(len(v) for v in changes.values())
if edits != 2:
    fail(f"renaming alpha's size should touch 2 sites, got {edits}: {changes}")
if any("beta" in uri for uri in changes):
    fail(f"renaming alpha's size touched beta: {list(changes)}")
if any(e["newText"] != "extent" for v in changes.values() for e in v):
    fail("rename produced the wrong text")

local_changes = s.result(ren_local)["changes"]
local_edits = [e for v in local_changes.values() for e in v]
if len(local_edits) != 2:
    fail(f"renaming a shadowed local touches only its own two sites: "
         f"{local_edits}")
lines = sorted(e["range"]["start"]["line"] + 1 for e in local_edits)
if lines != [51, 52]:
    fail(f"renaming the shadow must not touch the outer binding: {lines}")

if s.error(ren_bad) is None:
    fail("renaming to a keyword should be refused")
if s.error(ren_builtin) is None:
    fail("renaming a built-in type should be refused")
if s.result(prep)["placeholder"] != "size":
    fail(f"prepareRename should offer the current name: {s.result(prep)}")
print("ok references, highlights and rename: exact symbols only")

# ---------------------------------------------------------------------------
# A rename that would change what the code means is refused
# ---------------------------------------------------------------------------
# Every one of these still compiles after the edit. That is exactly why the
# server has to refuse them: the program would keep building and quietly mean
# something else.
s = Session(FIXTURE)
cases = {
    # the inner `value` would shadow the `total` every later line reads
    "shadowing a binding already in scope":
        (s.ask("textDocument/rename", FIXTURE, 51, 13, newName="total"), True),
    # the outer `value` would collide with a local declared further down
    "colliding with a local declared later":
        (s.ask("textDocument/rename", FIXTURE, 48, 9, newName="inner_only"),
         True),
    # a free name in the same function is fine
    "a name nothing else uses":
        (s.ask("textDocument/rename", FIXTURE, 51, 13, newName="fresh"), False),
    # two types cannot share a name in one package
    "a type the package already declares":
        (s.ask("textDocument/rename", FIXTURE, 17, 7, newName="Square"), True),
    "a type name that is free":
        (s.ask("textDocument/rename", FIXTURE, 17, 7, newName="Round"), False),
    # a method cannot take the name of one it inherits
    "a member the type already has":
        (s.ask("textDocument/rename", FIXTURE, 24, 17, newName="twice"), True),
    "a function the package already declares":
        (s.ask("textDocument/rename", FIXTURE, 47, 4, newName="draw_all"),
         True),
    # --- and the same has to hold looking *down* the hierarchy -------------
    # base -> child, method: Framed extends Circle and declares `corners`, so
    # Circle.draw cannot become `corners` — Framed would start hiding it.
    "a method name a subtype already declares":
        (s.ask("textDocument/rename", FIXTURE, 24, 17, newName="corners"),
         True),
    # base -> child, field: same collision from a field on the base.
    "a field renamed onto a subtype's method":
        (s.ask("textDocument/rename", FIXTURE, 18, 5, newName="corners"),
         True),
    # interface -> implementing type, two levels down: Framed reaches
    # Drawable through Circle, so the walk has to be recursive.
    "an interface method renamed onto a distant implementer's method":
        (s.ask("textDocument/rename", FIXTURE, 12, 8, newName="corners"),
         True),
    # interface -> implementing type, field: Circle implements Drawable and
    # has `radius`; Square has `side`. Both would collapse into one slot.
    "an interface method renamed onto an implementer's field":
        (s.ask("textDocument/rename", FIXTURE, 12, 8, newName="radius"),
         True),
    "an interface method renamed onto another implementer's field":
        (s.ask("textDocument/rename", FIXTURE, 12, 8, newName="side"), True),
    # a sibling counts too: renaming Circle.draw renames Square.draw with it,
    # so a name Square already uses is a collision even though Circle is
    # clear of it.
    "a name a sibling implementation already uses":
        (s.ask("textDocument/rename", FIXTURE, 24, 17, newName="side"), True),
    # and a name free in the whole hierarchy, above and below, is fine
    "a member name free in the whole hierarchy":
        (s.ask("textDocument/rename", FIXTURE, 12, 8, newName="outline"),
         False),
    "a field name free in the whole hierarchy":
        (s.ask("textDocument/rename", FIXTURE, 18, 5, newName="extent"),
         False),
}
s.finish()
for label, (rid, must_refuse) in cases.items():
    refused = s.error(rid) is not None
    if must_refuse and not refused:
        fail(f"rename should be refused — {label}: {s.replies[rid]}")
    if not must_refuse and refused:
        fail(f"rename should be allowed — {label}: {s.error(rid)['message']}")
    if must_refuse and not s.error(rid)["message"]:
        fail(f"a refusal should say why — {label}")
print("ok rename refuses a name that would rebind something else")

# ---------------------------------------------------------------------------
# A virtual name is renamed as a whole family, and the result still builds
# ---------------------------------------------------------------------------
# The proof that a rename is correct is not the shape of the edits, it is that
# the program still compiles and still does the same thing. So: apply the
# edits and run it.
PROJECT = FIXTURE.parent


def apply_edits(changes, into):
    """Write an LSP workspace edit onto a copy of the fixture project."""
    for uri, edits in changes.items():
        name = pathlib.Path(uri.split("/")[-1]).name
        target = next(p for p in into.rglob("*.b") if p.name == name)
        lines = target.read_text().split("\n")
        # Back to front, so earlier edits keep their columns.
        for e in sorted(edits, key=lambda e: (-e["range"]["start"]["line"],
                                              -e["range"]["start"]["character"])):
            row = e["range"]["start"]["line"]
            start = e["range"]["start"]["character"]
            end = e["range"]["end"]["character"]
            lines[row] = lines[row][:start] + e["newText"] + lines[row][end:]
        target.write_text("\n".join(lines))


def run_project(main):
    p = subprocess.run([BIN, "run", str(main)], capture_output=True,
                       text=True, timeout=300)
    return p.returncode, p.stdout, p.stderr


rc, expected, err = run_project(FIXTURE)
if rc != 0:
    fail(f"the fixture should run before anything is renamed: {err}")

# `draw` is declared on the interface and overridden by Circle, Square and
# Rounded. Renaming it anywhere in that family must rename all of it —
# from the interface, and from a leaf.
for label, (line, col) in {
    "from the interface declaration": (10, 8),
    "from a leaf override": (42, 17),
}.items():
    s = Session(FIXTURE)
    ren = s.ask("textDocument/rename", FIXTURE, line, col, newName="render")
    s.finish()
    if s.error(ren) is not None:
        fail(f"renaming a virtual method {label} was refused: "
             f"{s.error(ren)['message']}")
    changes = s.result(ren)["changes"]
    edited = sorted(e["range"]["start"]["line"] + 1
                    for v in changes.values() for e in v)
    # every `override fn draw` has to be in there, or the edit breaks the code
    for override_line in (24, 36, 42):
        if override_line not in edited:
            fail(f"renaming {label} skipped the override on line "
                 f"{override_line}: {edited}")
    if 10 not in edited:
        fail(f"renaming {label} skipped the interface declaration: {edited}")
    # Gathering references from several symbols must not hand the editor two
    # edits for one place — a workspace edit with overlapping ranges is
    # rejected outright.
    for uri, v in changes.items():
        starts = [(e["range"]["start"]["line"], e["range"]["start"]["character"])
                  for e in v]
        if len(starts) != len(set(starts)):
            fail(f"renaming {label} produced overlapping edits: {starts}")
    with tempfile.TemporaryDirectory() as tmp:
        copy = pathlib.Path(tmp) / "proj"
        shutil.copytree(PROJECT, copy)
        apply_edits(changes, copy)
        rc, out, err = run_project(copy / "main.b")
        if rc != 0:
            first = (err or out).strip().split("\n")[0]
            fail(f"the program stopped compiling after renaming {label}: "
                 f"{first}")
        if out != expected:
            fail(f"renaming {label} changed what the program prints:\n"
                 f"  before: {expected!r}\n  after:  {out!r}")
print("ok a virtual method renames as one family, and the code still builds")

# ---------------------------------------------------------------------------
# Workspace symbols and hierarchies
# ---------------------------------------------------------------------------
s = Session(FIXTURE)
ws = s.raw("workspace/symbol", {"query": "Shape"})
ws_fuzzy = s.raw("workspace/symbol", {"query": "dral"})
ws_none = s.raw("workspace/symbol", {"query": "zzqq"})
th = s.ask("textDocument/prepareTypeHierarchy", FIXTURE, 41, 7)
ch = s.ask("textDocument/prepareCallHierarchy", FIXTURE, 47, 4)
s.finish()

shapes = s.result(ws)
containers = sorted(x["containerName"] for x in shapes if x["name"] == "Shape")
if containers != ["semfix.alpha", "semfix.beta"]:
    fail(f"both Shapes should be listed, kept apart by package: {containers}")
names = [x["name"] for x in s.result(ws_fuzzy)]
if "draw_all" not in names:
    fail(f"a fuzzy query should find draw_all: {names}")
if s.result(ws_none):
    fail(f"a query that matches nothing returns nothing: {s.result(ws_none)}")

item = s.result(th)[0]
call_item = s.result(ch)[0]
s2 = Session(FIXTURE)
supers = s2.raw("typeHierarchy/supertypes", {"item": item})
subs = s2.raw("typeHierarchy/subtypes", {"item": item})
top = s2.ask("textDocument/prepareTypeHierarchy", FIXTURE, 8, 11)
incoming = s2.raw("callHierarchy/incomingCalls", {"item": call_item})
outgoing = s2.raw("callHierarchy/outgoingCalls",
                  {"item": dict(call_item, data="fn:semfix::main",
                                name="main")})
s2.finish()

if [x["name"] for x in s2.result(supers)] != ["Circle"]:
    fail(f"Rounded extends Circle: {s2.result(supers)}")
if s2.result(subs):
    fail(f"Rounded has no subtypes: {s2.result(subs)}")
drawable = s2.result(top)[0]
s3 = Session(FIXTURE)
d_subs = s3.raw("typeHierarchy/subtypes", {"item": drawable})
s3.finish()
if sorted(x["name"] for x in s3.result(d_subs)) != ["Circle", "Square"]:
    fail(f"Drawable's direct subtypes are Circle and Square: "
         f"{s3.result(d_subs)}")

callers = [x["from"]["name"] for x in s2.result(incoming)]
if callers != ["main"]:
    fail(f"shadowing() is called from main only: {callers}")
callees = sorted(x["to"]["name"] for x in s2.result(outgoing))
for want in ["shadowing", "other_function", "draw_all"]:
    if want not in callees:
        fail(f"main should call {want}: {callees}")
print("ok workspace symbols, type hierarchy and call hierarchy")

# ---------------------------------------------------------------------------
# Editing: unsaved buffers, incremental changes, versions, cancellation
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    # A directory whose name has a space and a non-ASCII character. Package
    # names stay ASCII because the language requires it; the *path* is what
    # has to survive the round trip through a file URI.
    proj = tmp / "a project" / "ünïcode"
    (proj / "helpers").mkdir(parents=True)
    (proj / "beans.pot").write_text("module spacey\n")
    (proj / "helpers" / "helpers.b").write_text(
        "package helpers\n\npub fn twice(n: int) -> int {\n"
        "    return n * 2\n}\n")
    main = proj / "main.b"
    main.write_text(
        "package main\n\nimport std.io\nimport spacey.helpers\n\n"
        "fn main() {\n    io.println(\"{helpers.twice(21)}\")\n}\n")

    s = Session(main)
    # `helpers.twice` sits at line 7; `twice` starts at column 26.
    d = s.ask("textDocument/definition", main, 7, 27)
    # An unsaved edit in another buffer is what this file sees.
    s.open(proj / "helpers" / "helpers.b")
    s.change(proj / "helpers" / "helpers.b",
             "package helpers\n\npub fn twice(n: int) -> int {\n"
             "    return n * 2\n}\n\npub fn thrice(n: int) -> int {\n"
             "    return n * 3\n}\n")
    later = s.raw("workspace/symbol", {"query": "thrice"})
    s.finish()

    if s.result(d) is None:
        fail("definition through a path with spaces and Unicode failed")
    if at(s.result(d)) != ("helpers.b", 3, 7):
        fail(f"definition should reach helpers.twice: {s.result(d)}")
    uri = s.result(d)["uri"]
    if " " in uri or "ü" in uri:
        fail(f"a file URI must percent-encode spaces and Unicode: {uri}")
    if "%20" not in uri:
        fail(f"the space in the path should be percent-encoded: {uri}")
    if not s.result(later):
        fail("a symbol added in an unsaved buffer should be findable")

    # Incremental sync: replace `21` with `7` and keep the buffer working.
    s = Session(main)
    s.edit(main, 6, 30, 6, 32, "7")
    hover = s.ask("textDocument/hover", main, 7, 27)
    s.finish()
    if s.result(hover) is None:
        fail("an incremental edit broke the buffer")
    if "twice" not in s.result(hover)["contents"]["value"]:
        fail(f"hover after an incremental edit: {s.result(hover)}")

    # UTF-16 columns: a line with an emoji before the symbol.
    wide = proj / "wide.b"
    wide.write_text(
        "package main\n\nimport std.io\n\n"
        "fn main() {\n    let noodles: int = 1\n"
        "    io.println(\"🍜 {noodles}\")\n}\n")
    s = Session(wide)
    # `🍜` is two UTF-16 units, so `noodles` starts at character 20 of
    # line 7 — a server counting bytes would land two columns short.
    kind = s.ask("textDocument/hover", wide, 7, 22)
    s.finish()
    got = s.result(kind)
    if got is None or "noodles" not in got["contents"]["value"]:
        fail(f"a UTF-16 column after an emoji did not land on `noodles`: {got}")

print("ok editing: unsaved buffers, incremental sync, URIs, UTF-16 columns")

# ---------------------------------------------------------------------------
# Cancellation, and the exact-span rule
# ---------------------------------------------------------------------------
# The server reads and answers strictly in order, so a `$/cancelRequest` is
# always read after the request it names has been answered. It is accepted and
# ignored, which LSP permits. What must hold is that the notification changes
# nothing: the request is answered normally, and the stream keeps working.
s = Session(FIXTURE)
target = s.ask("textDocument/definition", FIXTURE, 24, 17)
s.notify("$/cancelRequest", {"id": target})
following = s.ask("textDocument/documentSymbol", FIXTURE)
s.finish()

if s.error(target) is not None:
    fail(f"a cancellation cannot arrive before its request here, so the "
         f"request must be answered normally: {s.replies[target]}")
if at(s.result(target)) != ("main.b", 24, 16):
    fail(f"the answer should be the usual one: {s.result(target)}")
if s.error(following) is not None or not s.result(following):
    fail("a cancellation must not disturb the requests that follow it")
print("ok cancellation: accepted, ignored, and harmless to the stream")

# A name owns exactly its own columns. The character after it belongs to
# whatever is written there, so clicking the `(` of `draw(` is not clicking
# `draw`, and the space before a name is not the name either.
s = Session(FIXTURE)
inside = s.ask("textDocument/definition", FIXTURE, 24, 17)
last = s.ask("textDocument/definition", FIXTURE, 24, 20)
after = s.ask("textDocument/definition", FIXTURE, 24, 21)
before = s.ask("textDocument/definition", FIXTURE, 24, 16)
s.finish()

if at(s.result(inside)) != ("main.b", 24, 16):
    fail(f"the first character of a name resolves it: {s.result(inside)}")
if at(s.result(last)) != ("main.b", 24, 16):
    fail(f"the last character of a name resolves it: {s.result(last)}")
if s.result(after) is not None:
    fail(f"the `(` after `draw` is not `draw`: {s.result(after)}")
if s.result(before) is not None:
    fail(f"the space before `draw` is not `draw`: {s.result(before)}")
print("ok symbol spans are half-open: a name owns its own columns and no more")

# ---------------------------------------------------------------------------
# workspace/symbol covers the workspace, not only what is open
# ---------------------------------------------------------------------------
ROOT = ROOT / "test/cases/semantic"
s = Session()
s.msgs[0] = frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"rootUri": ROOT.as_uri(), "capabilities": {}}})
closed = s.raw("workspace/symbol", {"query": "Shape"})
s.finish()
found = s.result(closed)
if len(found) != 2:
    fail(f"with a workspace root and no file open, both Shapes should still "
         f"be found: {found}")
if sorted(x["containerName"] for x in found) != ["semfix.alpha", "semfix.beta"]:
    fail(f"package identity should survive a closed-workspace search: {found}")

# The same, through `workspaceFolders` rather than the older `rootUri`.
s = Session()
s.msgs[0] = frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"workspaceFolders": [
                       {"uri": ROOT.as_uri(), "name": "semantic"}],
                       "capabilities": {}}})
folders = s.raw("workspace/symbol", {"query": "draw_all"})
s.finish()
if not any(x["name"] == "draw_all" for x in s.result(folders)):
    fail(f"workspaceFolders should be searched too: {s.result(folders)}")
print("ok workspace symbols search the workspace, with no file open")
PY
