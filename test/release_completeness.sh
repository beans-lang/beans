#!/usr/bin/env bash
# A release is every supported host or it is not a release.
#
#   test/release_completeness.sh <manifest.tsv> <assets-directory>
#
# Run by the publish job before anything is uploaded. It compares the manifest
# that was actually assembled against targets/release_assets.tsv, then proves
# every asset the manifest names exists and hashes to what the manifest claims.
# A missing target, a surprise target, a wrong class or a wrong checksum stops
# the release here rather than half-publishing it.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd -P)
expected=$repo/targets/release_assets.tsv

# --self-test proves this gate itself works, without waiting for a release: it
# synthesises a complete set of assets from targets/release_assets.tsv, checks
# that they pass, then checks that a missing target and a wrong checksum are
# each rejected. A gate nothing exercises is a gate nobody can trust.
if [[ "${1:-}" == --self-test ]]; then
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/beans-release-selftest.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/assets"
    {
        printf '#version\ttarget\tos\tarch\tlibc\tclass\tasset\tsha256\tself_contained\n'
        grep -v '^#' "$expected" | grep -v '^[[:space:]]*$' |
        while IFS=$'\t' read -r target class; do
            case "$target" in
                *windows*) extension=zip ;;
                *)         extension=tar.gz ;;
            esac
            asset="beans-v0.0.0-selftest-$target.$extension"
            printf 'synthetic %s\n' "$target" >"$scratch/assets/$asset"
            if command -v sha256sum >/dev/null 2>&1; then
                sum=$(sha256sum "$scratch/assets/$asset" | cut -d' ' -f1)
            else
                sum=$(shasum -a 256 "$scratch/assets/$asset" | cut -d' ' -f1)
            fi
            contained=no
            [[ "$class" == full ]] && contained=yes
            printf '0.0.0-selftest\t%s\tselftest\tselftest\tselftest\t%s\t%s\t%s\t%s\n' \
                "$target" "$class" "$asset" "$sum" "$contained"
        done
    } >"$scratch/manifest.tsv"

    bash "$0" "$scratch/manifest.tsv" "$scratch/assets" >/dev/null
    echo "  a complete manifest passes"

    dropped=$(grep -v '^#' "$expected" | grep -v '^[[:space:]]*$' |
        head -1 | cut -f1)
    grep -v "	$dropped	" "$scratch/manifest.tsv" >"$scratch/partial.tsv"
    if bash "$0" "$scratch/partial.tsv" "$scratch/assets" >/dev/null 2>&1; then
        echo "the gate accepted a release missing $dropped" >&2
        exit 1
    fi
    echo "  a missing target is refused"

    sed "s/	[0-9a-f]\{64\}	/	$(printf '0%.0s' $(seq 64))	/" \
        "$scratch/manifest.tsv" >"$scratch/badsums.tsv"
    if bash "$0" "$scratch/badsums.tsv" "$scratch/assets" >/dev/null 2>&1; then
        echo "the gate accepted wrong checksums" >&2
        exit 1
    fi
    echo "  a wrong checksum is refused"

    echo "ok the release completeness gate works ($(grep -vc '^#' "$expected") targets expected)"
    exit 0
fi

manifest=${1:?usage: $0 <manifest.tsv> <assets-directory>}
assets=${2:?usage: $0 <manifest.tsv> <assets-directory>}

[[ -f "$manifest" ]] || { echo "no manifest at $manifest" >&2; exit 1; }
[[ -d "$assets" ]] || { echo "no assets directory at $assets" >&2; exit 1; }
[[ -f "$expected" ]] || { echo "no expected list at $expected" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-release-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

grep -v '^#' "$expected" | grep -v '^[[:space:]]*$' |
    awk -F '\t' '{ print $1 "\t" $2 }' | LC_ALL=C sort >"$tmp/expected"
grep -v '^#' "$manifest" | grep -v '^[[:space:]]*$' |
    awk -F '\t' '{ print $2 "\t" $6 }' | LC_ALL=C sort >"$tmp/built"

status=0
if ! diff -u "$tmp/expected" "$tmp/built" >"$tmp/diff"; then
    echo "the release does not match targets/release_assets.tsv:" >&2
    while IFS= read -r line; do
        case "$line" in
            ---*|+++*|@@*) continue ;;
            -*) echo "  missing: ${line#-}" >&2 ;;
            +*) echo "  unexpected: ${line#+}" >&2 ;;
        esac
    done <"$tmp/diff"
    status=1
fi

# The manifest is what the installers read. Every row in it has to name a file
# that is really here and really hashes to the published value, or a user's
# checksum check fails after the release is already public.
rows=0
while IFS=$'\t' read -r version target os arch libc class asset sha self_contained; do
    [[ -z "${version:-}" || "$version" == \#* ]] && continue
    rows=$((rows + 1))
    if [[ ! -f "$assets/$asset" ]]; then
        echo "  manifest names $asset, which is not in $assets" >&2
        status=1
        continue
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$assets/$asset" | cut -d' ' -f1)
    else
        actual=$(shasum -a 256 "$assets/$asset" | cut -d' ' -f1)
    fi
    if [[ "$actual" != "$sha" ]]; then
        echo "  $asset hashes to $actual, manifest says $sha" >&2
        status=1
    fi
    case "$class:$self_contained" in
        full:yes|slim:no) ;;
        *)
            echo "  $target: class '$class' with self_contained '$self_contained'" >&2
            status=1
            ;;
    esac
    # Every published archive must carry the version this release is building.
    if [[ "$asset" != *"v$version-$target."* ]]; then
        echo "  $asset is not named for $version/$target" >&2
        status=1
    fi
done <"$manifest"

# One release, one version.
versions=$(grep -v '^#' "$manifest" | awk -F '\t' 'NF { print $1 }' |
    LC_ALL=C sort -u | wc -l | tr -d ' ')
if [[ "$versions" != 1 ]]; then
    echo "  the manifest mixes $versions compiler versions" >&2
    status=1
fi

# Nothing named after the bootstrap compiler may be published.
if find "$assets" -name '*beansc0*' -print -quit | grep -q .; then
    echo "  an asset is named after beansc0" >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo "refusing to publish a partial or inconsistent release" >&2
    exit 1
fi
echo "ok $rows packages, all expected targets present and verified"
