#!/usr/bin/env bash
# Native ARMv6 hard-float host gate. CI runs this inside a Raspbian ARMv6
# container because Ubuntu's armhf sysroot is ARMv7 and crashes on ARM1176.
set -euo pipefail

cd "$(dirname "$0")/.."

require=${BEANS_ARMV6HF_REQUIRE:-0}
skip_or_fail() {
    if [[ "$require" == 1 ]]; then
        echo "armv6hf hosted gate: FAIL — $1" >&2
        exit 1
    fi
    echo "armv6hf hosted gate: skip — $1"
    exit 0
}

[[ $(uname -m) == armv6l ]] || skip_or_fail "host is not ARMv6"
[[ $(dpkg --print-architecture 2>/dev/null) == armhf ]] \
    || skip_or_fail "userspace is not ARM hard-float"
command -v g++ >/dev/null || skip_or_fail "g++ is missing"
cc=${BEANS_ARMV6HF_CC:-clang-16}
command -v "$cc" >/dev/null || skip_or_fail "$cc is missing"
export BEANS_CC="$cc"

triple=arm-unknown-linux-gnueabihf
echo "building Beans from source on $triple"
# The mounted source may carry another host's build directory. Force every
# target so no foreign artifact can satisfy this gate.
make -B -j2

for compiler in ./build/beansc; do
    "$compiler" target "$triple" | grep -q '^env gnueabihf$'
done

# No --target proves the running compiler selects ARMv6 hard-float.
./build/beansc build --emit ir examples/hello.b -o build/armv6hf-self.ll >/dev/null
grep -q "target triple = \"$triple\"" build/armv6hf-self.ll

make test-fixpoint
BEANS_DIFFERENTIAL_ENCODING_GOLDENS=1 bash test/differential.sh

./build/beansc build examples/hello.b -o build/armv6hf-hello
[[ $(./build/armv6hf-hello) == "hello from beans" ]]

echo "ok ARMv6 hard-float host: self-hosted build, fixed point and differential loop"
