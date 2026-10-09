# Linux correctness image for cross-target, hosted, and embedded gates.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        lld \
        llvm \
        libclang-rt-18-dev \
        make \
        git \
        file \
        binutils \
        ripgrep \
        ca-certificates \
        curl \
        python3 \
        gcc-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        gcc-x86-64-linux-gnu \
        libc6-dev-amd64-cross \
        gcc-riscv64-linux-gnu \
        g++-riscv64-linux-gnu \
        libc6-dev-riscv64-cross \
        gcc-powerpc64le-linux-gnu \
        g++-powerpc64le-linux-gnu \
        libc6-dev-ppc64el-cross \
        gcc-powerpc-linux-gnu \
        g++-powerpc-linux-gnu \
        libc6-dev-powerpc-cross \
        libc6-dev-ppc64-cross \
        gcc-s390x-linux-gnu \
        g++-s390x-linux-gnu \
        libc6-dev-s390x-cross \
        gcc-i686-linux-gnu \
        g++-i686-linux-gnu \
        libc6-dev-i386-cross \
        gcc-arm-linux-gnueabihf \
        g++-arm-linux-gnueabihf \
        libc6-dev-armhf-cross \
        gcc-arm-linux-gnueabi \
        g++-arm-linux-gnueabi \
        libc6-dev-armel-cross \
        gcc-14-loongarch64-linux-gnu \
        g++-14-loongarch64-linux-gnu \
        libc6-dev-loong64-cross \
        qemu-user-static \
        qemu-system-arm \
        qemu-system-misc \
        gcc-arm-none-eabi \
        gcc-riscv64-unknown-elf \
    # The big-endian PowerPC64 cross compiler only exists in Ubuntu's
    # amd64 archive; the arm64 ports archive has never carried it. The
    # default gate never uses it. Only the explicit ppc64 arch/hosted gates
    # require it, and those fail by name if the tool is absent, so an
    # arm64 host still runs the full default gate.
    && if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
        apt-get install -y --no-install-recommends \
            gcc-powerpc64-linux-gnu \
            g++-powerpc64-linux-gnu; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# Fail the image build rather than a test run if the toolchain is not what the
# suite needs.
RUN clang --version \
    && clang++ --version \
    && ld.lld --version \
    && clang --print-targets | grep -qw aarch64 \
    && clang --print-targets | grep -qw x86-64 \
    && clang --print-targets | grep -qw wasm32 \
    && clang --print-targets | grep -qw thumb \
    && clang --print-targets | grep -qw riscv32 \
    && clang --print-targets | grep -qw riscv64 \
    && clang --print-targets | grep -qw ppc64le \
    && clang --print-targets | grep -qw ppc32 \
    && clang --print-targets | grep -qw ppc64 \
    && clang --print-targets | grep -qw systemz \
    && clang --print-targets | grep -qw x86 \
    && clang --print-targets | grep -qw arm \
    && qemu-system-arm --version >/dev/null \
    && qemu-system-riscv32 --version >/dev/null \
    && qemu-riscv64-static --version >/dev/null \
    && qemu-ppc64le-static --version >/dev/null \
    && qemu-ppc-static --version >/dev/null \
    && qemu-ppc64-static --version >/dev/null \
    && qemu-s390x-static --version >/dev/null \
    && qemu-i386-static --version >/dev/null \
    && qemu-arm-static --version >/dev/null \
    && qemu-loongarch64-static --version >/dev/null \
    && riscv64-linux-gnu-gcc --version >/dev/null \
    && riscv64-linux-gnu-g++ --version >/dev/null \
    && powerpc64le-linux-gnu-gcc --version >/dev/null \
    && powerpc64le-linux-gnu-g++ --version >/dev/null \
    && powerpc-linux-gnu-g++ --version >/dev/null \
    && { [ "$(dpkg --print-architecture)" != "amd64" ] || \
         powerpc64-linux-gnu-g++ --version >/dev/null; } \
    && s390x-linux-gnu-g++ --version >/dev/null \
    && i686-linux-gnu-gcc --version >/dev/null \
    && i686-linux-gnu-g++ --version >/dev/null \
    && arm-linux-gnueabihf-gcc --version >/dev/null \
    && arm-linux-gnueabihf-g++ --version >/dev/null \
    && arm-linux-gnueabi-gcc --version >/dev/null \
    && arm-linux-gnueabi-g++ --version >/dev/null \
    && loongarch64-linux-gnu-g++-14 --version >/dev/null \
    && test -f "$(arm-none-eabi-gcc -mcpu=cortex-m4 -mfloat-abi=soft \
                  -print-libgcc-file-name)" \
    && test -f "$(riscv64-unknown-elf-gcc -march=rv32imac -mabi=ilp32 \
                  -print-libgcc-file-name)" \
    && echo 'int main(void){return 0;}' > /tmp/probe.c \
    && clang -fsanitize=address -o /tmp/probe.asan /tmp/probe.c \
    && clang -fsanitize=thread -o /tmp/probe.tsan /tmp/probe.c \
    && rm -f /tmp/probe.c /tmp/probe.asan /tmp/probe.tsan

WORKDIR /work
COPY test/docker/entrypoint.sh /usr/local/bin/beans-entrypoint
RUN chmod +x /usr/local/bin/beans-entrypoint
ENTRYPOINT ["/usr/local/bin/beans-entrypoint"]
CMD ["gate"]
