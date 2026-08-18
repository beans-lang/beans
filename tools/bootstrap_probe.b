// The smallest program that only a compiler supporting `partial class` can
// check. The Makefile runs this against BEANSC_BOOT before building, so a
// compiler too old to build these sources says so in one line instead of
// failing with a page of parse errors from src/llvm.b.
partial class Probe {
    value: int
}

partial class Probe {
    fn get() -> int { return self.value }
}

fn main() {
    let probe: Probe = new Probe()
    probe.value = 1
}
