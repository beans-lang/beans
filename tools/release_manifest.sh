#!/usr/bin/env bash
# The machine-readable index of one release.
#
#   tools/release_manifest.sh row   <archive>              one TSV line
#   tools/release_manifest.sh merge <rows-dir> <out.tsv>   the whole manifest
#
# Every field is read out of the package's own VERSION file, so the manifest can
# never disagree with what was actually built. The installers read this file and
# nothing else: there is no second list of targets to keep in step.
#
# Columns: version target os arch libc class asset sha256 self_contained
set -euo pipefail

mode=${1:-}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# VERSION lives at <package-root>/VERSION inside the archive. tar can stream it;
# a zip needs Python, which every runner that builds a zip already has.
read_version_file() {
    case "$1" in
        *.tar.gz)
            tar xzf "$1" -O --wildcards '*/VERSION' 2>/dev/null ||
                tar xzf "$1" -O "$(tar tzf "$1" | grep -m1 '/VERSION$')"
            ;;
        *.zip)
            # Windows runners spell it either way; the packaging step already
            # required one of them to build the zip in the first place.
            if command -v python3 >/dev/null 2>&1; then
                zip_python=python3
            elif command -v python >/dev/null 2>&1; then
                zip_python=python
            else
                echo "reading a zip manifest needs Python 3" >&2
                exit 2
            fi
            "$zip_python" - "$1" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in archive.namelist():
        if name.endswith("/VERSION"):
            sys.stdout.write(archive.read(name).decode())
            break
PY
            ;;
        *)
            echo "unknown archive kind: $1" >&2
            exit 2
            ;;
    esac
}

case "$mode" in
    row)
        archive=${2:?usage: $0 row <archive>}
        [[ -f "$archive" ]] || { echo "no such archive: $archive" >&2; exit 2; }
        fields=$(read_version_file "$archive")
        value() { printf '%s\n' "$fields" | sed -n "s/^$1=//p" | head -1; }
        version=$(value compiler)
        target=$(value target)
        os=$(value os)
        arch=$(value arch)
        libc=$(value libc)
        class=$(value package)
        native=$(value native_build)
        for required in "$version" "$target" "$os" "$arch" "$libc" "$class"; do
            [[ -n "$required" ]] ||
                { echo "$archive has an incomplete VERSION file" >&2; exit 1; }
        done
        self_contained=no
        [[ "$native" == self-contained ]] && self_contained=yes
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$version" "$target" "$os" "$arch" "$libc" "$class" \
            "$(basename "$archive")" "$(sha256_of "$archive")" "$self_contained"
        ;;
    merge)
        rows=${2:?usage: $0 merge <rows-dir> <out.tsv>}
        out=${3:?usage: $0 merge <rows-dir> <out.tsv>}
        printf '#version\ttarget\tos\tarch\tlibc\tclass\tasset\tsha256\tself_contained\n' \
            >"$out"
        find "$rows" -name '*.tsv' -type f -exec cat {} + |
            grep -v '^#' | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u >>"$out"
        # One target may ship a full and a slim package, but never two of the
        # same class: that would mean two jobs published the same asset name.
        duplicates=$(awk -F '\t' '!/^#/ { print $2 "\t" $6 }' "$out" |
            LC_ALL=C sort | uniq -d)
        if [[ -n "$duplicates" ]]; then
            echo "the manifest has duplicate target/class rows:" >&2
            printf '%s\n' "$duplicates" >&2
            exit 1
        fi
        rows_written=$(grep -vc '^#' "$out" || true)
        [[ "$rows_written" -gt 0 ]] ||
            { echo "the manifest would be empty" >&2; exit 1; }
        printf 'wrote %s (%s targets)\n' "$out" "$rows_written"
        ;;
    *)
        echo "usage: $0 <row|merge> ..." >&2
        exit 2
        ;;
esac
