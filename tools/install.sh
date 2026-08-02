#!/usr/bin/env bash
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
test -x "$root/build/beansc0"

mkdir -p "$bin_dir" "$lib_dir" "$share_dir/lib"
install -m 0755 "$root/build/beansc" "$lib_dir/beansc"
install -m 0755 "$root/build/beansc0" "$lib_dir/beansc0"
install -m 0644 "$root/runtime/beans_rt.c" "$lib_dir/beans_rt.c"
rm -rf "$share_dir/lib/std"
cp -R "$root/stdlib/std" "$share_dir/lib/std"
install -m 0644 "$root/LICENSE" "$share_dir/LICENSE"

cat >"$bin_dir/beansc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export BEANS_RUNTIME="\${BEANS_RUNTIME:-$prefix/lib/beans/beans_rt.c}"
export BEANS_STDLIB="\${BEANS_STDLIB:-$prefix/share/beans/lib/std}"
exec "$prefix/lib/beans/beansc" "\$@"
EOF
cat >"$bin_dir/beansc0" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export BEANS_RUNTIME="\${BEANS_RUNTIME:-$prefix/lib/beans/beans_rt.c}"
exec "$prefix/lib/beans/beansc0" "\$@"
EOF
chmod 0755 "$bin_dir/beansc" "$bin_dir/beansc0"
