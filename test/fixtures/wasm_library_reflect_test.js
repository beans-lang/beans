// A library module's own startup.
//
// The module has no `main`. Its reflection registry, its static field
// initializers and its singleton constructors live in `beans_module_start`,
// and a host has to call it once after instantiating. Before that function
// existed all three were emitted into `main`'s entry block, so a `--emit
// shared` module carried them and ran none — every reflective lookup answered
// "no such type" and nothing reported a failure, because nothing had failed.
//
// This checks both halves: that the export is there, and that skipping it
// really does leave the registry empty. The second is what keeps the test
// honest — without it a module that registered its types some other way would
// pass and the gate would be measuring nothing.
const fs = require("fs");

const bytes = fs.readFileSync(process.argv[2]);
const module_ = new WebAssembly.Module(bytes);

// The freestanding profile has no libc, so the module imports the five host
// hooks and whatever memory builtins Clang emitted calls to. A real embedder
// supplies these in C beside the module; a test needs only enough of them to
// let the registry allocate, so here they are in JavaScript over the module's
// own memory.
function hostFor(instance) {
    let memory = null;
    let top = 0;
    const view = () => new Uint8Array(memory.buffer);
    // `alloc` is a local rather than a method, because realloc calls it and an
    // import object's functions are called with no receiver.
    const alloc = (size, align) => {
        const step = Number(align) > 16 ? Number(align) : 16;
        top = (top + step - 1) & ~(step - 1);
        const at = top;
        top += Number(size);
        while (top > memory.buffer.byteLength) memory.grow(16);
        view().fill(0, at, at + Number(size));
        return at;
    };
    return {
        bind(m) {
            memory = m;
            // Start well clear of static data. A bump allocator never frees,
            // which is right for a test that instantiates, asks and exits.
            top = 1 << 20;
        },
        env: {
            beans_host_alloc: alloc,
            beans_host_realloc(block, size) {
                // A bump allocator never knows the old size, so it copies the
                // new one — which reads past the old block into memory this
                // host zeroed. Right for a test, wrong for anything else.
                const moved = alloc(size, 16);
                view().copyWithin(moved, block, block + Number(size));
                return moved;
            },
            beans_host_free() {},
            beans_host_write(stream, pointer, length) {
                const text = Buffer.from(view().subarray(pointer, pointer + Number(length))).toString();
                process.stderr.write(text);
            },
            beans_host_exit(code) { throw new Error(`the module exited with ${code}`); },
            memset(out, value, count) { view().fill(value, out, out + Number(count)); return out; },
            memcpy(out, from, count) { view().copyWithin(out, from, from + Number(count)); return out; },
            memmove(out, from, count) { view().copyWithin(out, from, from + Number(count)); return out; },
            memcmp(a, b, count) {
                const bytes_ = view();
                for (let i = 0; i < Number(count); i++) {
                    if (bytes_[a + i] !== bytes_[b + i]) return bytes_[a + i] - bytes_[b + i];
                }
                return 0;
            },
            memchr(block, value, count) {
                const bytes_ = view();
                for (let i = 0; i < Number(count); i++) {
                    if (bytes_[block + i] === value) return block + i;
                }
                return 0;
            },
            strlen(text) {
                const bytes_ = view();
                let at = text;
                while (bytes_[at] !== 0) at++;
                return at - text;
            },
            fmod(x, y) { return x % y; },
            fmodf(x, y) { return Math.fround(Math.fround(x) % Math.fround(y)); },
        },
    };
}

/// Instantiates with a host wired to the instance's own memory.
function instantiate() {
    const host = hostFor();
    const instance = new WebAssembly.Instance(module_, { env: host.env });
    host.bind(instance.exports.memory);
    return instance;
}

const exports_ = WebAssembly.Module.exports(module_).map((e) => e.name);
if (!exports_.includes("beans_module_start")) {
    throw new Error(`the module does not export beans_module_start: ${exports_.join(", ")}`);
}

// Without the call: no reflection.
//
// **Not nothing.** A static field and a singleton each carry their own guard —
// the first read of either runs its initializer — so 8 and 16 are set here and
// were before this function existed. Reflection has no such guard and could
// not have one: nothing reads "the registry", it is read by name and a name
// that was never registered is indistinguishable from a name that does not
// exist. That is the whole bug, and this is the line that says so.
const cold = instantiate();
const before = cold.exports.beans_library_reflect();
const lazy = 8 | 16;
if (before !== lazy) {
    throw new Error(`a module whose startup never ran answered ${before}, expected ${lazy} — the static field and the singleton initialize on first read, and nothing else should be there`);
}

// With it: all five.
const warm = instantiate();
warm.exports.beans_module_start();
const after = warm.exports.beans_library_reflect();
const wanted = 1 | 2 | 4 | 8 | 16;
if (after !== wanted) {
    const missing = [];
    if (!(after & 1)) missing.push("the class is not in the reflection registry");
    if (!(after & 2)) missing.push("its initializer cannot be called");
    if (!(after & 4)) missing.push("its annotation is absent");
    if (!(after & 8)) missing.push("the singleton never ran its initializer");
    if (!(after & 16)) missing.push("the static field has no value");
    throw new Error(`beans_module_start answered ${after}, expected ${wanted}: ${missing.join("; ")}`);
}

// And twice is the same as once. A host that calls it defensively must not
// register every type a second time.
warm.exports.beans_module_start();
if (warm.exports.beans_library_reflect() !== wanted) {
    throw new Error("calling beans_module_start twice changed the answer");
}
