const fs = require("fs");

const bytes = fs.readFileSync(process.argv[2]);
const module_ = new WebAssembly.Module(bytes);
const imports = WebAssembly.Module.imports(module_);
if (imports.length !== 0) {
    throw new Error(`plain scalar module unexpectedly imports ${JSON.stringify(imports)}`);
}
const instance = new WebAssembly.Instance(module_);
if (!(instance.exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("module did not export linear memory");
}
if (instance.exports.beans_wasm_add(20, 1) !== 42) {
    throw new Error("beans_wasm_add returned the wrong value");
}
