#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]] || [[ $# -ne 1 ]]; then
    echo "usage on Linux: $0 <empty-output-directory>" >&2
    exit 2
fi

dest=$1
if [[ -e "$dest" ]]; then
    echo "sysroot destination already exists: $dest" >&2
    exit 2
fi
mkdir -p "$dest"

packages=(libc6 libc6-dev linux-libc-dev)
for file in "$(cc -print-file-name=crtbeginS.o)" \
            "$(cc -print-file-name=libgcc_s.so.1)"; do
    canonical=$(readlink -f "$file")
    package=$(
        dpkg-query -S "$canonical" 2>/dev/null |
            sed -n '1s/:.*//p' || true
    )
    if [[ -n "$package" ]]; then packages+=("$package"); fi
done

manifest=$(mktemp "${TMPDIR:-/tmp}/beans-sysroot.XXXXXX")
trap 'rm -f "$manifest"' EXIT
for package in "${packages[@]}"; do
    dpkg-query -L "$package"
done | LC_ALL=C sort -u >"$manifest"

while IFS= read -r path; do
    if [[ -f "$path" || -L "$path" ]]; then
        cp -a --parents "$path" "$dest"
    fi
done <"$manifest"

# Ubuntu uses merged-/usr: its linker scripts still name /lib paths while the
# package manifests contain /usr/lib files. A sysroot must carry the same
# compatibility links or LLD cannot resolve libc and libm.
ln -s usr/lib "$dest/lib"
if [[ -d "$dest/usr/lib64" ]]; then
    ln -s usr/lib64 "$dest/lib64"
fi

printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u |
while IFS= read -r package; do
    dpkg-query -W -f='${Package}=${Version}\n' "$package"
done >"$dest/BEANS-SYSROOT-PACKAGES"
