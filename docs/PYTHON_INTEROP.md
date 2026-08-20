# Python interoperability — design

Status: **proposal, nothing implemented**. Written against language contract
1.0 and the pot model in
[`spec/SYNTAX.md`](https://github.com/beans-lang/beans/blob/main/spec/SYNTAX.md).

This document describes the complete design. The first release may ship a
smaller package and target set, but it must follow this contract so later work
does not break source or lock files.

## Goal

Beans programs can use CPython modules through:

1. generated, checked Beans packages when useful type information exists, and
2. an explicit `py.Value` API for Python features that cannot be represented by
   a static Beans signature.

The real CPython runtime executes the code. Python source is not translated.
Compiled extension modules, Python's import system, Python threads, callbacks,
coroutines, exceptions, and runtime mutation remain Python behavior.

The target is broad Python package support, not the false promise that every
PyPI project works on every machine. A project still needs a compatible CPython
runtime, a wheel or usable source build, and any external libraries or drivers
required by the package.

There is no new Beans expression syntax. The work does add pot manifest and
lock rows, the reserved `py` import root, runtime hooks, and a few compiler
checks for Python callbacks and async wrappers.

The compiler-owned surface is explicit:

- reserve the `py` import root and load generated packages from the locked
  environment;
- link the Python runtime start/stop hooks only when the core `py` package or a
  generated `py.*` package is reachable;
- recognize the qualified core handle `py.SharedValue` as `Send` and `Sync`;
  and
- check callback captures and emit the closure ABI trampoline requested by a
  generated callback factory.

There is no Python-specific overload selection, keyword-call syntax, implicit
conversion, `py.Value as? T` rule, or hidden async effect in the checker.

## User-facing typed code

```beans
import std.io
import py
import py.numpy as np

fn demo() -> Result<f64, py.PythonError> {
    let a: np.NDArray = np.arange(15)?
    let b: np.NDArray = a.reshape([3, 5])?
    let c: np.NDArray = b.op_mul_f64(2.0)?

    let mean: f64 = c.mean_f64()?
    let flat: List<i64> = a.to_list_i64()?

    io.println("mean = {mean}, first = {flat[0]}")
    return ok(mean)
}
```

Generated names state conversions that may lose information. For example,
`mean_f64` checks that the result converts to `f64`, and `to_list_i64` checks
the element format and range. An overlay may also expose handle-preserving
forms when a package has useful Python-native scalar types.

Python errors use `py.PythonError`; `Error` itself is a reserved Beans type
name. The custom type matches Beans' rule that `?` propagates only the same
error type. A helper converts a whole result when an application wants the
standard error type:

```beans
fn main() -> Result<bool> {
    let mean: f64 = py.to_std(demo())?
    io.println("{mean}")
    return ok(true)
}
```

## Dependency declarations

A Python import name is not a PyPI distribution name. `Pillow` provides `PIL`,
one distribution can provide several import packages, and namespace packages
can be spread across distributions. Beans therefore never guesses a PyPI
project from an import alone.

Direct Python requirements and import mappings live in `beans.pot`:

```text
module image_tool
kind application

python runtime ">=3.13,<3.14"
python target arm64-apple-darwin
python target x86_64-unknown-linux-gnu

python requirement "numpy>=2.1,<3"
python import numpy from numpy

python requirement "Pillow>=11,<12"
python import PIL from Pillow

python requirement "google-cloud-storage[grpc]>=3,<4"
python import google.cloud.storage from google-cloud-storage
```

The CLI edits these rows instead of putting version intent only in the lock:

```bash
beansc pot add --python "numpy>=2.1,<3" --import numpy
beansc pot add --python "Pillow>=11,<12" --import PIL
beansc pot remove --python Pillow
beansc pot update --python numpy
beansc pot tidy
```

Rules:

- `python requirement` accepts a PEP 508 requirement, including extras and
  environment markers. Direct URLs and VCS requirements need an explicit
  security flag and are locked by URL, revision where applicable, and hash.
- `python import <module-prefix> from <distribution>` maps a Python module to a
  direct requirement. The longest prefix wins for submodules.
- A same-name convenience command may add both rows, but only after reading the
  chosen distribution metadata and checking that its wheel actually provides
  the requested import root.
- An unmapped `import py.<name>` is a tidy error. It never starts a network
  install. CPython standard-library modules are the exception and come from the
  pinned runtime.
- Exact `import py` names the toolchain's core dynamic support package and never
  maps to a PyPI distribution.
- Python use requires a `beans.pot` project because the runtime itself must be
  selected and locked. Single-file mode reports the `pot init` command instead
  of creating an unrecorded environment.
- Two distributions claiming the same non-namespace module are an error.
  Namespace contributions are merged only when the packages use Python's
  namespace-package rules.
- Source may dynamically import any module present in the locked environment
  through `py.import_module`. Typed imports still require a direct mapping.
- `pot tidy` reports unused direct requirements and mappings. Transitive
  distributions appear only in the lock.

The default index is PyPI. Extra indexes must be named in `beans.pot`, use
HTTPS, and state their priority. Resolution uses a first-index policy by
default so a public package cannot silently replace a same-named private one.

## Resolution and `beans.lock`

Python resolution is per target and CPython ABI. Platform markers, supported
wheel tags, `Requires-Python`, extras, pre-releases, yanked releases, and
transitive `Requires-Dist` edges all participate.

`beans.lock` moves to version 2 because the current version accepts only Git
module rows. Version 2 keeps the existing `module` rows unchanged and adds
these Python rows at minimum:

```text
version 2
python-index <index-id> <policy> <url>
python-runtime <target> <version> <abi-tag> <artifact-url> <sha256>
python-wheel <target> <normalized-dist> <version> <filename> <artifact-url> <sha256> <index-id>
python-dependency <target> <parent-dist> "<normalized-PEP-508-requirement>"
python-import <module-prefix> <normalized-dist>
```

An sdist build adds rows for the sdist hash, build-system requirements,
toolchain profile, and resulting wheel hash. Exact escaping and ordering become
part of the lock-file specification in Stage 0.

A version 1 lock with no Python rows remains readable. The first successful
Python tidy rewrites it as version 2 without changing its existing Git module
solutions.

Important rules:

- A lock can contain several targets. Universal wheels may share one cached
  artifact, but each target still records that it selected that artifact.
- A build target must have a complete runtime and distribution solution in the
  lock. `--locked` never resolves a missing target.
- `pot tidy` resolves every `python target` in `beans.pot`. Without those rows,
  it resolves only the current canonical host target and records it explicitly.
- Environment markers are evaluated using the locked target and runtime, never
  the machine running `pot tidy`.
- Each row records the exact source index or URL. Resolver output is sorted and
  byte-stable.
- Direct requirements use `@root` as their `python-dependency` parent, so the
  lock contains both the selected artifacts and the full solved graph.
- `--offline` reads only hash-matching artifacts from the content cache.
- Updating one direct distribution may change its transitive solution, but
  does not refresh unrelated direct requirements unless required to solve the
  graph.

A pinned, vendored resolver may use `uv` internally. It is executed directly,
never through a shell, and its version is part of the Beans toolchain version.

## Runtime and target support

The toolchain pins one normal, GIL-enabled CPython runtime per target solution.
The runtime artifact must:

- provide a shared `libpython` or platform equivalent,
- support loading shared extension modules,
- match the wheel tag calculation used by the resolver,
- include the standard library, headers needed by generated glue, and license
  files, and
- state its minimum OS, libc, CPU, and system-library requirements.

`python-build-standalone` is a preferred source, not a promise of support for
every Beans target. Beans publishes a Python support matrix. Targets without a
loadable CPython runtime, such as WASI, freestanding targets, or static musl
builds that cannot load extension modules, reject `py.*` imports early.

Python requires the full Beans runtime profile, OS threads, dynamic-library
loading, and a filesystem. Minimal and freestanding profiles reject it at check
time rather than producing a binary that fails later.

Free-threaded CPython is a separate runtime ABI and lock solution. It is not an
automatic toolchain switch. A project may select it only when the runtime and
all selected extension wheels declare compatible free-threaded support.

Programs with typed or dynamic Python use a runtime-start hook. CPython starts
on the process main thread before Beans `main`, with `PyConfig` filled from the
locked environment. This gives initialization and finalization a stable thread.
Programs with no Python imports or dynamic Python calls do not link the hook,
runtime bridge, or `libpython` loader.

The bridge sets `home`, prefixes, executable information, standard-library
paths, `site-packages`, and platform DLL search paths. Packages see one normal,
internally managed Python environment rather than a list of unrelated wheel
directories.

On POSIX, the loader makes CPython symbols globally visible before importing
extension modules. Windows uses restricted DLL search directories rooted in
the runtime and environment. The bridge validates the loaded runtime's version,
ABI flags, pointer width, and extension suffixes against the lock before
running Python code.

## Artifact cache and installed environments

Downloads are content-addressed:

```text
$BEANS_HOME/py/artifacts/sha256/<sha256>/artifact
$BEANS_HOME/py/runtime/<target>/<runtime-sha256>/
$BEANS_HOME/py/env/<environment-hash>/<target>/site-packages/
$BEANS_HOME/py/bindings/<environment-hash>/<generator-version>/<target>/
```

The environment hash covers the runtime artifact, ordered wheel set, install
policy, import mappings, overlays, typeshed snapshot, and installer/generator
versions. Version and wheel tag alone are not cache keys because wheels can
have build tags and distinct files with the same release version.

Wheels are installed into one immutable environment tree using the wheel
install scheme. Installation handles `purelib`, `platlib`, `.data` relocation,
namespace packages, metadata, generated script wrappers where requested, and
`RECORD` verification. It also rejects unsafe archive paths.

Standard `site` and `.pth` behavior is enabled for compatibility. Executable
`.pth` lines are dependency code and have the same security rights as imported
Python. The environment is built in a temporary directory, verified, and then
renamed atomically into the cache.

### Source distributions

Wheels are preferred. Full package support also allows sdists under an explicit
project policy:

```text
python sdists allow
```

An sdist is built in an isolated environment with pinned build requirements,
network disabled after those requirements are fetched, and a declared native
toolchain profile. Build backend code still executes with the user's rights;
the CLI warns on the first such build. The produced wheel is hashed and locked.

An sdist build is not assumed reproducible merely because its inputs are
pinned. Strict reproducible projects use `python sdists deny`, the default, or
publish and lock their own wheel. Cross-target sdist builds require a supported
cross toolchain or build service; otherwise resolution fails with a clear
target error.

## Binding generation

Bindings are generated from these inputs, in priority order:

1. versioned curated overlays shipped with Beans,
2. stubs shipped by the distribution,
3. separately locked stub distributions,
4. the runtime-matched typeshed snapshot, and
5. the explicit dynamic API when no safe static mapping exists.

Stubs are claims, not runtime proof. Every return value is checked at the
boundary before it becomes a Beans scalar, struct, collection, or generated
handle. A bad or stale stub therefore produces `err(py.PythonError)` instead of
memory corruption.

Generated packages are normal Beans source plus calls to a fixed native bridge.
The compiler does not treat generated package names as magic. Generator output
is deterministic for its full input hash.

### Names and modules

- Python module `numpy.linalg` becomes Beans package `py.numpy.linalg`.
- A distribution may generate several Beans packages.
- Python names that are not valid Beans identifiers get a stable escaped name.
  A recorded name table keeps the original Python spelling.
- Keyword escaping and dunder lowering cannot collide silently. A collision
  gets a stable descriptive suffix, with the original name shown in generated
  documentation.
- Dynamic modules and module `__getattr__` remain available through
  `py.Value.get_attr`.

### Functions and call shapes

- A typed function returns `Result<T, py.PythonError>`.
- Positional-only parameters stay positional.
- Required keyword-only parameters become required fields in an options
  struct.
- Parameters with Python defaults become `py.Arg<T>` fields whose default is
  `unset`. `py.Arg.value(none)` is different from `unset`, so explicit Python
  `None` is not confused with omission or a sentinel default.
- A function with optional arguments gets a short form and a `_with` form:

  ```beans
  let basic: np.NDArray = np.linspace(0.0, 1.0)?
  let options: np.LinspaceOptions = np.LinspaceOptions {
      num: py.arg(50),
  }
  let chosen: np.NDArray = np.linspace_with(0.0, 1.0, options)?
  ```

  The core package defines `py.Arg<T>` as the ordinary enum `unset | value(T)`
  and `py.arg<T>(value)` as a short constructor for the `value` variant.

- Typed `*args` become a trailing `List<T>` when one safe element type exists;
  otherwise they become `List<py.Value>`.
- Typed `**kwargs` become `Map<string, T>`; otherwise they become
  `Map<string, py.Value>`.
- Overloads are merged only when the result is one honest signature. Other
  overloads get stable suffixed names and all remain available through the raw
  callable API. Beans does not pick overloads through inference.
- Python `async def` gets a blocking `run` form for synchronous Beans code and
  an async wrapper that must be called with `await`.
- Generators, iterators, context managers, async iterators, descriptors, and
  properties get explicit wrapper methods. Writable properties use `get_` and
  `set_` methods.
- Python constructors return handles through generated factory functions.
  Beans `new` is never used for a Python-owned object.

### Classes and Python typing

Generated class types are handle wrappers, not a copy of Python's object model.
They do not reproduce Python multiple inheritance with Beans inheritance.
Instead, `from_value`, generated upcast helpers, and runtime `isinstance`
checks preserve the real Python class rules. This also handles virtual base
classes, metaclasses, and classes changed at runtime.

Typing constructs lower as follows:

- `Optional[T]` becomes `Option<T>`.
- A closed union of safely distinguishable types becomes a generated Beans
  enum. Overlapping or open unions become `py.Value`.
- A fixed heterogeneous tuple becomes a generated struct. A homogeneous
  variable tuple becomes `List<T>`. Other tuple shapes stay Python handles.
- `Literal` becomes a checked scalar or generated enum when all values fit.
- `TypeVar` becomes a Beans generic only when its bounds and variance have an
  honest Beans meaning. Otherwise the affected position becomes `py.Value`.
- Python protocols remain runtime-checked handle capabilities; they do not
  become false nominal Beans inheritance.
- `Callable` becomes a generated callable handle for Python functions and a
  generated callback factory for Beans functions.
- `Awaitable`, `Coroutine`, generators, and async generators become their
  matching core Python handle types.
- `Any`, an unknown forward reference, or an unsupported annotation becomes
  `py.Value` at that exact position, not for the whole package.
- `Annotated`, `NewType`, array dtype/shape types, and package-specific typing
  plugins use overlays when their metadata changes runtime checks.

Constants are emitted as getter functions unless an overlay proves that a
copied compile-time scalar is the package contract. This keeps module mutation
visible.

Python protocols use `op_` names so they do not collide with real methods:

```text
__add__      -> op_add
__mul__      -> op_mul
__getitem__  -> op_get_item
__setitem__  -> op_set_item
__len__      -> op_len
__call__     -> op_call
__str__      -> op_to_string
__iter__     -> op_iter
```

Overlays may add type-specific names such as `op_mul_f64` where that makes a
conversion clear.

`op_` wrappers use CPython's number, sequence, mapping, call, and iterator
protocol APIs. They do not call a cached dunder object directly, because Python
special-method lookup has its own type-level rules.

Typed calls honor Python runtime mutation. Normal module functions and methods
are looked up when called, so monkey patching remains visible. An overlay may
opt into a frozen callable fast path only when its contract states that the
package treats the symbol as immutable.

## Dynamic API

`py.Value` is the owned handle for any Python object. It does not use Beans
`as?`; that syntax is compiler-specialized for `std.reflect.Value`. Python
conversion is explicit and fallible:

```beans
import py

fn dynamic_demo() -> Result<i64, py.PythonError> {
    let module: py.Value = py.import_module("operator")?
    let add: py.Value = module.get_attr("add")?
    let args: List<py.Value> = [py.value_i64(20)?, py.value_i64(22)?]
    let kwargs: Map<string, py.Value> = {}
    let answer: py.Value = add.call(move args, move kwargs)?
    return answer.to_i64()
}
```

The dynamic package includes:

- import by string;
- get, set, and delete attribute;
- get, set, and delete item;
- positional and keyword calls;
- type name, identity, truth, comparison, hashing, and string rendering;
- iteration and async iteration;
- context-manager enter and exit;
- checked scalar and collection conversions;
- buffer inspection and copy;
- conversion between `py.Value` and generated handle classes; and
- callable and awaitable wrappers.

Generated handles expose `to_value()` and a checked `from_value()` factory.
No cast can reinterpret a `PyObject*` as the wrong generated class.

## Type mapping and copies

All mappings are checked. A conversion failure is `py.PythonError`.

| Beans | Python | behavior |
|---|---|---|
| `i64` and sized integers | `int` | value copy; Python-to-Beans checks range |
| `py.Int` | `int` | handle form for arbitrary-size integers |
| `f64` | `float` | value copy |
| `bool` | `bool` | value copy; never treated as an integer by accident |
| `string` | `str` | UTF-8 copy |
| `Bytes` | `bytes` / buffer | owned copy |
| `List<T>` | `list` / sequence | per-element checked conversion |
| numeric `List<T>` | exact compatible contiguous buffer | one bulk copy |
| numeric `List<T>` | strided or differently typed buffer | checked strided copy or numeric conversion |
| `Map<K, V>` | `dict` / mapping | per-entry checked conversion |
| `Option<T>` | value or `None` | checked payload conversion |
| successful `bool` payload | function returning `None` | `true` on success, matching Beans stdlib style |
| `py.Arg<T>` | omitted or supplied value | controls argument presence; not a Python value itself |
| generated handle | compatible Python object | owned reference, no payload copy |
| `py.Value` | any Python object | owned reference, no payload copy |
| generated callback | Python callable | runtime-owned callback object |
| `py.Awaitable<T>` | awaitable | scheduled through the Python event loop |

A Python `list` is not a numeric buffer and therefore never takes the bulk
copy path. An ndarray reaches memcpy speed only when dtype, byte order,
contiguity, and item size exactly match the requested Beans element type.
Benchmarks must state those conditions.

Beans-owned data is never exposed to Python past its safe lifetime. APIs that
need long-lived writable memory make a Python-owned copy or return an explicit
owner object that keeps the backing storage alive.

## Errors and process failures

`py.PythonError` is a public, non-`Send` Beans class with read-only methods for:

- the qualified Python exception type;
- the message;
- the rendered traceback, including chained exceptions and exception groups;
- the Python thread name, when available; and
- an owned `py.Value` for the normalized exception object, so dynamic code can
  inspect custom fields or re-raise the same exception.

Its fields and initializer stay package-private so user code cannot build an
invalid error. `py.error(message)` creates a Python `BeansError` when Beans code
needs to start a Python error chain.

`py.to_std<T>` converts `Result<T, py.PythonError>` to `Result<T>` by rendering
the Python error into the built-in `Error` with kind `python`. No implicit error
conversion is added to the language.

The bridge normalizes and fetches the exception while holding the GIL. Failure
to render a traceback still returns the original type and message.

Python exceptions become `Result`. Native extension faults do not. A C or C++
extension can still abort, corrupt memory, call `_exit`, or crash the process.
The documentation always describes Python packages as native dependencies with
full process rights.

## Calls, the GIL, and Beans threads

There is no single Python-call executor. The GIL does not mean one call may
exist at a time: CPython and native extensions release it during blocking I/O
and long native work.

The runtime uses these paths:

- **Synchronous Beans call:** the calling OS thread attaches a CPython thread
  state, acquires the GIL, performs the call, and releases it. Several Beans
  threads may have calls in progress; CPython decides when they run.
- **Async Beans wrapper:** a bounded worker pool performs a blocking Python
  call only when the signature is `Send` or an overlay marks its handle policy
  worker-safe. The Beans task awaits a completion event, so the cooperative
  Beans scheduler does not block.
- **Python coroutine:** one managed asyncio loop schedules the awaitable. Its
  completion wakes the Beans task.
- **Main-thread-only API:** curated overlays mark calls that Python or the OS
  requires on the process main thread. Calling one from another thread returns
  a clear error or posts it to the main-thread dispatcher when that is safe.

Generated bindings provide distinct synchronous and async names where an async
path is safe. Python `async def` uses the managed event loop. A synchronous
Python API gets a worker-backed async form only when an overlay approves it or
all values already satisfy the core shared-handle policy. A user can make the
same explicit choice through `py.SharedValue` and the dynamic offload API.
There is no hidden effect that makes a synchronous call suspend. Async wrappers
are ordinary `async fn` declarations and obey the existing `await` and `Send`
rules.

Cancelling a Beans task cannot safely kill arbitrary synchronous Python or
native extension code. Cancellation stops waiting and discards the result, but
the worker finishes in the background. Python coroutine cancellation uses
`asyncio.Task.cancel` and remains cooperative.

One CPython runtime and one resolved Python environment exist per Beans
process. Incompatible Python dependency graphs must be split into processes.

## Handles and shutdown

`py.Value`, `py.Int`, awaitables, callables, and generated classes own one
Python reference. Copying a handle increments its reference; dropping it
releases that reference.

Drops outside the GIL enqueue a DECREF and immediately wake a maintenance path
that acquires the GIL. Cleanup never waits for another user Python call. Queue
storage remains valid until interpreter shutdown.

Shutdown order is fixed:

1. reject new Python calls;
2. cancel and drain Beans async wrappers;
3. stop the asyncio loop and Python worker pool;
4. drain every pending DECREF and callback release;
5. run Python `atexit`, flush standard streams, and finalize CPython on the
   thread that initialized it; and
6. keep `libpython` loaded until process exit; the runtime never calls
   `dlclose` on an embedded interpreter.

Leaked Python background threads can make clean finalization impossible. The
runtime reports this and follows CPython's safe shutdown rules. It never unloads
`libpython` underneath a live thread.

Generated handles and `py.PythonError` are non-`Send` by default. An
explicit `py.SharedValue` core runtime handle is `Send` and `Sync`; every
operation still goes through CPython synchronization. The checker knows this
one qualified core type, like its other built-in thread-safe handles. Generated
package classes get no such special case. This prevents an accidental raw
`PyObject*` move from bypassing Beans thread checks.

`py.SharedValue` promises memory-safe access, not that a library accepts an
object on every thread. Event-loop objects, UI objects, and other thread-bound
package types still enforce their Python or overlay thread-affinity rules.

## Python-to-Beans callbacks

Full support includes callbacks. The generator emits a callback factory for
each typed callable signature. The dynamic API also provides one callback form
using `List<py.Value>` and `Map<string, py.Value>`.

The callback runtime:

- stores the Beans closure in a stable registry and gives Python only a registry
  ID, never a borrowed Beans pointer;
- creates a real Python callable object with vectorcall support;
- checks that retained callbacks capture only values safe for the callback's
  thread policy;
- runs a reentrant callback directly when Python calls back on the originating
  Beans thread;
- otherwise uses the Beans callback dispatcher or a `Send` callback trampoline;
- re-raises the retained Python exception from `err(py.PythonError)`, while an
  error made by `py.error` appears as Python `BeansError`;
- converts Python arguments and the Beans return value with the same checked
  mapping as normal calls; and
- releases the registry entry when the Python callable is destroyed, waking the
  maintenance path if the Beans value must be dropped elsewhere.

A callback documented by Python as synchronous blocks the Python caller until
Beans returns. Async Beans callbacks become Python awaitables instead of
blocking an asyncio loop.

Callback creation needs a compiler check for captured `Send` and `Sync` values
and generated ABI trampolines. This is deliberate compiler work; it is not
described as ordinary FFI-free source generation.

## Packaging and deployment

Developer builds use the global content cache. A copied executable must not
depend on the developer's `$BEANS_HOME`, so release packaging has a separate
mode:

```bash
beansc bundle app.b
```

The bundle is a relocatable directory containing the Beans executable,
CPython runtime, installed environment, native extension libraries, lock
manifest, and required licenses. Runtime paths are relative to the executable.
Linux loader paths, macOS signing layout, and Windows DLL directories are
handled per target.

A normal development executable embeds its target and environment hash, then
looks up that exact environment in `$BEANS_HOME`. If it is moved to a machine
without the cache it fails with a message to build a bundle; it never resolves
or downloads packages at application startup.

Native Python extensions generally prevent a true one-file executable. A
future self-extracting container may be added, but the supported artifact is a
directory bundle. Packages may still require host facilities such as GPU
drivers, system certificates, shared libraries allowed by a platform wheel
policy, or external programs. The bundler reports known external dependencies
but cannot invent them.

## Security contract

- Import names never select PyPI projects by guess.
- Every downloaded runtime, wheel, sdist, and build requirement is locked by
  cryptographic hash.
- Index URLs and origin information are kept in the lock.
- Archive extraction rejects path traversal and unsafe file types.
- Wheel installation does not run package setup code. Import-time code and
  executable `.pth` files still run with full process rights.
- Allowing sdists permits build backend code to execute. This is explicit and
  separately documented.
- Python code and compiled extensions are trusted native dependencies, not a
  sandbox. A future process-isolated mode would be a separate feature with a
  serialization boundary.

## Performance gates

Performance claims are measured after correctness tests pass:

1. A program with no Python use has no Python-linked size or startup delta.
2. A direct typed call benchmark records attribute lookup, argument conversion,
   vectorcall, result checking, and `Result` construction separately.
3. Frozen-callable overlays have their own fast-path benchmark and may not
   change normal monkey-patching behavior.
4. Exact contiguous numeric buffer conversion runs within 10% of the matching
   `memcpy` baseline for large inputs.
5. Python list and strided-buffer conversions have linear-time and allocation
   regression gates; they are not called memcpy paths.
6. Two long NumPy calls that release the GIL can overlap from two Beans threads.
7. An async Python call does not block unrelated Beans async tasks.
8. Callback and coroutine round trips have separate latency and cancellation
   benchmarks.

Absolute call-overhead targets are set from the first working prototype, not
guessed in this proposal.

## Failure modes

- Missing direct import mapping → tidy error naming the import and suggested
  `pot add --python` command.
- No compatible runtime for a Beans target → target support error before
  package resolution.
- No compatible wheel under a wheels-only policy → resolution error listing
  available artifacts and the sdist policy.
- Version or marker conflict → requirement chain for the affected target.
- Missing target rows under `--locked` → lock error; no host fallback.
- Cache miss under `--offline` → exact missing artifact and hash.
- Wheel install failure → distribution, wheel filename, install-scheme path,
  and cause.
- Missing or stale type information → affected declarations use `py.Value`;
  typed return mismatches become `py.PythonError`.
- Python exception → `err(py.PythonError)`.
- Native extension crash → process failure; never reported as safely caught.
- Cancelled synchronous native call → waiter cancels, worker continues until
  the call returns.
- Interpreter shutdown blocked by live Python threads → explicit runtime error
  and safe non-unload behavior.

## Verification matrix

Every supported target runs focused tests for:

- pure Python, `abi3`, exact-CPython-ABI, and platform wheels;
- `.data` relocation, namespace packages, metadata discovery, resources, and
  executable `.pth` behavior;
- different import and distribution names, multiple import roots, private
  indexes, extras, markers, and resolver conflicts;
- multi-target lock generation, locked/offline builds, hash mismatch, and cache
  coexistence of different wheel builds;
- scalar overflow, invalid Unicode, `None`, unions, wrong stub returns, Python
  lists, exact buffers, strided buffers, endian mismatch, and non-contiguous
  ndarrays;
- Python exception chains, exception groups, traceback fallback, and native
  crash fixture isolation;
- last-handle drop with no later Python call, cycles, finalizers, `atexit`, and
  interpreter shutdown;
- two-thread blocking coordination, GIL-releasing native work, main-thread-only
  calls, async cancellation, asyncio, and worker saturation;
- retained, reentrant, cross-thread, failing, and async callbacks; and
- development-cache execution and a clean-machine relocatable bundle.

Pilot packages cover different shapes: NumPy for extension modules and buffers,
Pillow for import/distribution mapping and binary data, requests for pure
Python dependencies, pandas for wide stubs and optional arguments, and one
async package for asyncio and callbacks.

## Work plan

Each stage passes focused tests and both compiler implementations before the
next stage. The dynamic bridge comes before broad binding generation so no
package is blocked solely by incomplete stubs.

- [ ] Stage 0 — language and file contracts
  - [ ] Reserve `py` and specify supported dynamic-import behavior.
  - [ ] Specify `beans.pot` Python rows and `beans.lock` version 2.
  - [ ] Specify `py.PythonError`, `py.Arg`, handle ownership, callback capture checks,
        sync/async naming, and target rejection rules.
- [ ] Stage 1 — resolver, runtime, and environment store
  - [ ] Resolve every declared target with markers, extras, indexes, and hashes.
  - [ ] Fetch a loadable CPython artifact and compatible wheels.
  - [ ] Install complete immutable environments and implement locked/offline
        verification.
- [ ] Stage 2 — complete dynamic bridge
  - [ ] Startup/shutdown, per-thread CPython states, GIL-safe handles, immediate
        DECREF maintenance, exceptions, attributes, items, calls, iteration,
        context managers, and checked conversions.
  - [ ] Add asyncio loop, blocking worker pool, cancellation behavior, and
        `py.SharedValue`.
- [ ] Stage 3 — binding generator
  - [ ] Parse modules, classes, protocols, overloads, generics, unions,
        literals, defaults, `*args`, `**kwargs`, properties, generators,
        callables, and awaitables.
  - [ ] Add deterministic name mapping, runtime result checks, overlays, stub
        packages, typeshed, and binding cache.
- [ ] Stage 4 — callbacks and Python async
  - [ ] Generate typed callback objects and dynamic callbacks.
  - [ ] Verify retained, reentrant, cross-thread, failing, and async cases.
- [ ] Stage 5 — package coverage and data paths
  - [ ] NumPy, Pillow, requests, pandas, and asyncio pilots.
  - [ ] Exact buffer fast paths, strided conversion, and conversion benchmarks.
- [ ] Stage 6 — sdists and release bundles
  - [ ] Isolated, pinned sdist builds with locked output wheels.
  - [ ] Relocatable target bundles, platform loader handling, licenses, and
        clean-machine tests.
- [ ] Stage 7 — support matrix and hardening
  - [ ] Publish runtime, wheel-tag, OS, libc, CPU, and external dependency
        support.
  - [ ] Run the full correctness, performance, offline, security, and shutdown
        gates.

## Decisions fixed by this design

1. Version intent lives in `beans.pot`; exact artifacts live in `beans.lock`.
2. Import names and distribution names are separate and explicitly mapped.
3. Locks are target- and ABI-specific.
4. Wheels are installed using their real install scheme into one environment.
5. `py.Value` uses methods, not compiler-special `as?` casting.
6. Generated calls return `Result<T, py.PythonError>`.
7. Sync calls run on the calling thread; async wrappers use workers or asyncio.
8. Python calls are not serialized through one executor.
9. DECREF queues wake immediately and shutdown order is specified.
10. Normal typed calls preserve runtime monkey patching.
11. Callbacks and coroutines are part of the complete design.
12. Free-threaded CPython is a separate compatibility solution.
13. Native extension crashes are outside exception-to-`Result` conversion.
14. Release output is a relocatable directory bundle, not a cache-dependent or
    falsely single-file executable.
