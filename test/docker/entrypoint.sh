#!/usr/bin/env bash
# Runs inside the Linux container. The repository is bind-mounted read-only at
# /src; this copies the tracked tree to /work first so a Linux build can never
# overwrite the host's build/ directory with foreign objects.
set -euo pipefail

if [[ ! -d /src ]]; then
    echo "expected the repository bind-mounted read-only at /src" >&2
    exit 2
fi

# `toolchains` is excluded for the same reason as `build`: it holds a downloaded
# LLVM-MinGW on a developer's Windows machine, it is gigabytes, and the
# container brings its own toolchain.
mkdir -p /work
tar -cf - -C /src --exclude=./build --exclude=./.git --exclude=./toolchains . |
    tar -xf - -C /work
cd /work

echo "== container: $(uname -m), $(clang --version | head -1)"

if ! command -v beansc >/dev/null 2>&1; then
    echo "== installing released beansc for the self-hosted build"
    curl -fsSL \
        https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh \
        -o /tmp/beans-install.sh
    sh /tmp/beans-install.sh --no-modify-path
    export PATH="${BEANS_HOME:-$HOME/.beans}/bin:$PATH"
fi

case "${1:-gate}" in
    gate)
        make
        make test
        make test-sanitize
        make access-score
        # Keep the compiler reproduction check explicit in the container gate.
        make test-fixpoint
        bash test/cross_link.sh
        # Real cross-execution for the Linux architectures whose sysroot and
        # qemu-user this image carries. REQUIRE=1: a missing tool fails the gate
        # here rather than skipping, because the image is built to have them.
        # Exception: Ubuntu ships the powerpc64 (big-endian) cross toolchain
        # only in the amd64 archive, so the image installs it only there and
        # the ppc64 lanes are required only where the image can carry them.
        if [ "$(dpkg --print-architecture)" = "amd64" ]; then
            ppc64_require=1
        else
            ppc64_require=0
        fi
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh riscv64
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh ppc64le
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh i686
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh armv7
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh armv6
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh loongarch64
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh ppc
        BEANS_LINUX_ARCH_REQUIRE=$ppc64_require bash test/linux_arch.sh ppc64
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_arch.sh s390x
        # Hosted gates: beansc itself, as that architecture's binary under
        # qemu-user, reaches its self-compile fixed point and drives the
        # examples byte-identical — the bar for calling a target a host.
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh ppc64le
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh riscv64
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh i686
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh armv7
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh armv6
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh loongarch64
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh ppc
        BEANS_LINUX_ARCH_REQUIRE=$ppc64_require bash test/linux_hosted.sh ppc64
        BEANS_LINUX_ARCH_REQUIRE=1 bash test/linux_hosted.sh s390x
        ;;
    shell)
        exec /bin/bash
        ;;
    *)
        # Anything else is run verbatim, so a single script can be re-checked
        # without rebuilding the image. The compiler still has to exist first.
        make >/dev/null
        exec "$@"
        ;;
esac
