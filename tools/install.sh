#!/usr/bin/env bash
# Install the self-hosted compiler from a source checkout.
#
# Only `beansc` is installed. build/beansc0 is the C++ stage-0 bootstrap: it is
# internal, it exists so a clean machine can build the compiler at all, and it
# stays in the build directory where bootstrap work needs it. Installing it
# would put a second, older compiler on a user's PATH for no reason.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
prefix=${PREFIX:-/usr/local}
destdir=${DESTDIR:-}
if [[ "$prefix" != /* || "$prefix" == "/" ]]; then
    echo "PREFIX must be an absolute directory below /" >&2
    exit 2
fi
bin_dir="$destdir$prefix/bin"
lib_dir="$destdir$prefix/lib/beans"
share_dir="$destdir$prefix/share/beans"

test -x "$root/build/beansc"

mkdir -p "$bin_dir" "$lib_dir" "$share_dir/lib"
install -m 0755 "$root/build/beansc" "$lib_dir/beansc"
install -m 0644 "$root/runtime/beans_rt.c" "$lib_dir/beans_rt.c"
install -m 0644 "$root/runtime/wasm_host.c" "$lib_dir/wasm_host.c"
# The std.encoding bridge and vendored sources: `beansc build` compiles them
# per target and `beansc run` builds its cached bridge library from them, so
# an installation works offline like a checkout does.
rm -rf "$lib_dir/encoding"
cp -R "$root/runtime/encoding" "$lib_dir/encoding"
# The networking bridges and their pinned vendored sources, for the same
# reason: std.http, std.websocket, std.compress, std.crypto and std.tls all
# compile a bridge per target, and an installation has to work offline.
rm -rf "$lib_dir/net"
cp -R "$root/runtime/net" "$lib_dir/net"
rm -rf "$share_dir/lib/std"
cp -R "$root/stdlib/std" "$share_dir/lib/std"
install -m 0644 "$root/LICENSE" "$share_dir/LICENSE"

# An older install may have left the stage-0 compiler here. Remove it rather
# than leave a stale beansc0 on PATH after an upgrade.
rm -f "$bin_dir/beansc0" "$lib_dir/beansc0"

cat >"$bin_dir/beansc" <<EOF
#!/bin/sh
set -eu
BEANS_RUNTIME="\${BEANS_RUNTIME:-$prefix/lib/beans/beans_rt.c}"
BEANS_WASM_HOST="\${BEANS_WASM_HOST:-$prefix/lib/beans/wasm_host.c}"
BEANS_STDLIB="\${BEANS_STDLIB:-$prefix/share/beans/lib/std}"
BEANS_ENCODING="\${BEANS_ENCODING:-$prefix/lib/beans/encoding}"
BEANS_NET="\${BEANS_NET:-$prefix/lib/beans/net}"
export BEANS_RUNTIME BEANS_WASM_HOST BEANS_STDLIB BEANS_ENCODING BEANS_NET
exec "$prefix/lib/beans/beansc" "\$@"
EOF
chmod 0755 "$bin_dir/beansc"
