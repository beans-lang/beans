# Windows cross-compile image: MinGW builds PE binaries and Wine tests them on linux/amd64.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        lld \
        llvm \
        make \
        git \
        file \
        binutils \
        curl \
        ca-certificates \
        python3 \
        mingw-w64 \
        wine64 \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu's wine64 package installs the loader at /usr/lib/wine/wine64 and puts
# nothing on PATH; the `wine` command normally comes from the wrapper package
# this image deliberately skips. A wrapper *script*, not a symlink: wine
# locates its own support files through argv[0], and through a symlink named
# `wine` that resolution breaks with "could not exec the wine loader". No
# `|| true` anywhere: an unrunnable wine must fail the image build here, not
# surface three layers later.
ENV WINEPREFIX=/wine WINEDEBUG=-all
RUN printf '#!/bin/sh\nexec /usr/lib/wine/wine64 "$@"\n' > /usr/local/bin/wine \
    && chmod +x /usr/local/bin/wine \
    && mkdir -p /wine \
    && wine --version

# Fail the image build rather than a test run if the toolchain cannot produce a
# PE binary that Wine executes, including a real thread through winpthreads,
# since that is the library the Beans runtime's pthread code will land on.
# `-pthread -static` is load-bearing twice over: unlike MinGW's posix-flavour
# gcc, clang does not link winpthreads on its own, and without -static the .exe
# depends on libwinpthread-1.dll, which exists on this build machine and
# nowhere the binary would actually run. The Beans driver passes both.
# This first wine run also initializes the /wine prefix baked into the image.
RUN printf '#include <pthread.h>\n#include <stdio.h>\nvoid* f(void* a){(void)a;return a;}\nint main(void){pthread_t t;pthread_create(&t,0,f,0);pthread_join(t,0);puts("pe ok");return 0;}\n' > /tmp/probe.c \
    && clang --target=x86_64-w64-mingw32 -pthread -static -fuse-ld=lld /tmp/probe.c -o /tmp/probe.exe \
    && file /tmp/probe.exe | grep -q 'PE32+' \
    && wine /tmp/probe.exe | grep -q 'pe ok' \
    && rm -f /tmp/probe.c /tmp/probe.exe

WORKDIR /work
COPY test/docker/entrypoint.sh /usr/local/bin/beans-entrypoint
RUN chmod +x /usr/local/bin/beans-entrypoint
ENTRYPOINT ["/usr/local/bin/beans-entrypoint"]
CMD ["bash", "test/windows.sh"]
