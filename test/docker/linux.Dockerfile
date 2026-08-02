# A reproducible Linux environment for the Beans correctness gate.
#
# Built for whatever platform Docker is asked for. On an Apple-silicon host,
# linux/arm64 runs natively and linux/amd64 runs under emulation — correctness
# only, never a performance number. test/linux_docker.sh says which is which.
#
# Why the cross toolchains are here: `beansc build --target` can always compile
# to an object without target libraries, but a cross *link* needs a libc. The
# gcc-*-linux-gnu packages supply exactly that — for aarch64, x86-64, riscv64,
# powerpc64le, i686 and armv7 — and qemu-user-static then runs the result so a
# cross build can be proven to execute, not just to link. test/linux_arch.sh
# drives that per architecture, and test/linux_hosted.sh drives the stronger
# hosted gate (beansc itself running as that architecture's binary).
#
# The embedded targets need the *system* emulators instead. A bare-metal Cortex-M
# or RISC-V image has no OS and makes no syscalls, so qemu-user cannot run it —
# it needs a machine with a UART, which is what qemu-system-arm and
# qemu-system-misc (riscv32) provide.
#
# The two bare-metal GCCs are here for one file each: libgcc.a. Ubuntu's
# compiler-rt package covers the host architecture only, and `int` is 64 bits and
# `float` is a double in Beans, so a 32-bit target needs the soft-float and
# 64-bit-integer helpers from somewhere. Hand-writing IEEE-754 soft float would be
# reimplementing — worse — what every embedded toolchain already ships. Only the
# library is used; Clang stays the compiler and ld.lld the linker.
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
        gcc-powerpc64-linux-gnu \
        g++-powerpc64-linux-gnu \
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
    && powerpc64-linux-gnu-g++ --version >/dev/null \
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
