#!/usr/bin/env bash
# Native musl host gate. CI runs this inside one Alpine container per CPU, with
# qemu-user supplying the machine when the runner is not already that CPU.
set -euo pipefail

cd "$(dirname "$0")/.."

arch=${1:-$(uname -m)}
require=${BEANS_MUSL_REQUIRE:-0}
skip_or_fail() {
    if [[ "$require" == 1 ]]; then
        echo "musl hosted gate: FAIL — $1" >&2
        exit 1
    fi
    echo "musl hosted gate: skip — $1"
    exit 0
}

ls /lib/ld-musl-*.so.1 >/dev/null 2>&1 || skip_or_fail "this is not a musl host"

case "$arch" in
    x86_64 | amd64) triple=x86_64-unknown-linux-musl ;;
    aarch64 | arm64) triple=aarch64-unknown-linux-musl ;;
    riscv64) triple=riscv64-unknown-linux-musl ;;
    loongarch64) triple=loongarch64-unknown-linux-musl ;;
    ppc64le | powerpc64le) triple=powerpc64le-unknown-linux-musl ;;
    *) skip_or_fail "unsupported musl host architecture '$arch'" ;;
esac

echo "building Beans from source on $triple"
# The source tree mounted by CI can contain host build artifacts. Force every
# target so a binary from another host can never make this gate pass early.
make -B -j2

for compiler in ./build/beansc; do
    "$compiler" target "$triple" | grep -q '^env musl$'
done

# No --target: this proves the running compiler selects musl rather than
# silently falling back to GNU libc.
./build/beansc build --emit ir examples/hello.b -o build/musl-self.ll >/dev/null
grep -q "target triple = \"$triple\"" build/musl-self.ll

make test-fixpoint
bash test/differential.sh

./build/beansc build examples/hello.b -o build/musl-hello
[[ $(./build/musl-hello) == "hello from beans" ]]

echo "ok musl host: self-hosted build, compiler fixed point and differential loop ($triple)"
