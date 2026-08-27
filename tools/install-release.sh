#!/bin/sh
# Install Beans for the current user.
#
#   curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh
#
# POSIX sh on purpose: this is the first Beans code a machine ever runs, so it
# may not assume bash, and it may not assume jq, python, node or git either. It
# needs curl or wget, tar, and one of sha256sum, shasum or openssl — all of
# which ship with the systems Beans supports.
#
# Nothing is installed until the download has been checksummed and unpacked into
# a staging directory and the compiler in it has answered `--version`. A failure
# at any step leaves an existing installation exactly as it was.
set -eu

REPO=${BEANS_INSTALL_REPO:-beans-lang/beans}
MANIFEST_NAME=beans-release-manifest.tsv

say() { printf '%s\n' "$*"; }
note() { printf 'beans: %s\n' "$*"; }
die() { printf 'beans: error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: beans-install.sh [options]

  --version <v>      install this release instead of the latest (e.g. 0.9.0)
  --prefix <dir>     install here instead of $HOME/.beans
  --target <triple>  force a Beans target instead of detecting one
  --force            reinstall even when this version is already installed
  --no-modify-path   do not touch shell startup files
  --help             show this message

environment:
  BEANS_HOME         same as --prefix
  BEANS_VERSION      same as --version
  BEANS_TARGET       same as --target
EOF
}

version=${BEANS_VERSION:-}
prefix=${BEANS_HOME:-}
target=${BEANS_TARGET:-}
force=0
modify_path=1

while [ $# -gt 0 ]; do
    case $1 in
        --version) [ $# -ge 2 ] || die "--version needs a value"; version=$2; shift 2 ;;
        --version=*) version=${1#*=}; shift ;;
        --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
        --prefix=*) prefix=${1#*=}; shift ;;
        --target) [ $# -ge 2 ] || die "--target needs a value"; target=$2; shift 2 ;;
        --target=*) target=${1#*=}; shift ;;
        --force) force=1; shift ;;
        --no-modify-path) modify_path=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ -n "$prefix" ] || prefix=$HOME/.beans
case $prefix in
    /*) ;;
    *) die "--prefix must be an absolute path, not '$prefix'" ;;
esac

# ---------------------------------------------------------------- temporaries
work=
# The trailing `:` matters. An EXIT trap whose last command fails replaces the
# script's exit status with that failure, so a cleanup that finds nothing to
# clean must not be the thing that decides what the installer returned.
cleanup() { [ -n "$work" ] && rm -rf "$work"; :; }
trap cleanup EXIT HUP INT TERM
work=$(mktemp -d "${TMPDIR:-/tmp}/beans-install.XXXXXX") ||
    die "cannot create a temporary directory"

# ------------------------------------------------------------------- fetching
if command -v curl >/dev/null 2>&1; then
    downloader=curl
elif command -v wget >/dev/null 2>&1; then
    downloader=wget
else
    die "neither curl nor wget is installed; install one and run this again"
fi

# A local BEANS_INSTALL_BASE_URL is how CI exercises this script end to end
# without a published release. Anything that is not a bare path still goes over
# HTTPS with the same checks, so the tested code path is the shipped one.
# A stalled transfer is the failure this has to survive, not a refused one.
# `--retry` alone does not: curl counts only its own transient errors, and a
# connection that opens and then goes quiet is error 56, which it will not
# retry. With no timeout either, such a transfer sits until the kernel gives
# up on the socket — nine minutes on a GitHub macOS runner, and then a failed
# install for a user whose network hiccuped once.
#
# So the retry is a loop here rather than a curl flag, which also means it
# works the same for wget and needs no version of either newer than what a
# supported distribution already ships. `--speed-limit`/`--speed-time` turn a
# stall into an abort after 30 seconds, and the loop then tries again.
fetch_attempts=${BEANS_INSTALL_ATTEMPTS:-3}

fetch_once() {
    if [ "$downloader" = curl ]; then
        curl -fsSL --proto '=https' --tlsv1.2 \
             --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
             -o "$2" "$1"
    else
        wget -q --https-only --timeout=30 --tries=1 -O "$2" "$1"
    fi
}

fetch() {
    from=$1 to=$2
    case $from in
        http://*|https://*)
            attempt=1
            while :; do
                fetch_once "$from" "$to" && return 0
                [ "$attempt" -ge "$fetch_attempts" ] && return 1
                # A stalled mirror rarely recovers instantly; back off a
                # little rather than spending all three tries in one second.
                sleep $((attempt * 2))
                attempt=$((attempt + 1))
            done
            ;;
        *)
            [ -f "$from" ] || return 1
            cp "$from" "$to" || return 1
            ;;
    esac
    return 0
}

# ------------------------------------------------------------------ platform
kernel=$(uname -s 2>/dev/null || echo unknown)
machine=$(uname -m 2>/dev/null || echo unknown)
libc=none
if [ "$kernel" = Linux ]; then
    # musl has no predefined macro to ask for; its loader name is the fact that
    # can be checked without compiling or running anything.
    libc=gnu
    for loader in /lib/ld-musl-*.so.1 /lib/libc.musl-*.so.1; do
        [ -e "$loader" ] && libc=musl && break
    done
    if [ "$libc" = gnu ] && command -v ldd >/dev/null 2>&1; then
        ldd --version 2>&1 | head -1 | grep -qi musl && libc=musl
    fi
fi

if [ -z "$target" ]; then
    case $kernel in
        Linux)
            case $machine in
                x86_64|amd64) target="x86_64-unknown-linux-$libc" ;;
                aarch64|arm64) target="aarch64-unknown-linux-$libc" ;;
                riscv64) target="riscv64-unknown-linux-$libc" ;;
                ppc64le) target="powerpc64le-unknown-linux-$libc" ;;
                ppc64) target="powerpc64-unknown-linux-$libc" ;;
                ppc|powerpc) target="powerpc-unknown-linux-gnu" ;;
                s390x) target="s390x-unknown-linux-gnu" ;;
                loongarch64) target="loongarch64-unknown-linux-$libc" ;;
                i386|i486|i586|i686) target="i686-unknown-linux-gnu" ;;
                armv7l) target="armv7-unknown-linux-gnueabihf" ;;
                armv6l) target="arm-unknown-linux-gnueabihf" ;;
            esac
            ;;
        Darwin)
            case $machine in
                arm64|aarch64) target="arm64-apple-darwin" ;;
            esac
            ;;
    esac
fi

# -------------------------------------------------------------- the manifest
base=${BEANS_INSTALL_BASE_URL:-}
if [ -z "$base" ]; then
    if [ -n "$version" ]; then
        base="https://github.com/$REPO/releases/download/v$version"
    else
        base="https://github.com/$REPO/releases/latest/download"
    fi
fi
manifest=${BEANS_INSTALL_MANIFEST:-$base/$MANIFEST_NAME}

fetch "$manifest" "$work/manifest.tsv" ||
    die "cannot download the release manifest from $manifest"

# version  target  os  arch  libc  class  asset  sha256  self_contained
lookup() {
    awk -F '\t' -v want="$1" '
        /^#/ || NF < 9 { next }
        $2 == want { print; found = 1 }
        END { exit found ? 0 : 1 }
    ' "$work/manifest.tsv"
}

# A target can be published as both a full and a slim package. Prefer full: it
# is the one that needs nothing else installed.
choose() {
    lookup "$1" | awk -F '\t' '
        $6 == "full" { print; exit }
        { slim = $0 }
        END { if (slim != "") print slim }
    '
}

row=
if [ -n "$target" ]; then
    row=$(choose "$target" || true)
fi

if [ -z "$row" ]; then
    say "beans: no released package matches this machine." >&2
    say "" >&2
    say "  operating system: $kernel" >&2
    say "  architecture:     $machine" >&2
    say "  libc:             $libc" >&2
    if [ -n "$target" ]; then
        say "  beans target:     $target" >&2
    else
        say "  beans target:     could not be determined" >&2
    fi
    say "" >&2
    say "Published targets:" >&2
    awk -F '\t' '!/^#/ && NF >= 9 { printf "  %s (%s)\n", $2, $6 }' \
        "$work/manifest.tsv" >&2
    say "" >&2
    say "Pick one explicitly with BEANS_TARGET=<triple>, or build from source:" >&2
    say "  https://github.com/$REPO#install" >&2
    exit 1
fi

release_version=$(printf '%s' "$row" | cut -f1)
package_class=$(printf '%s' "$row" | cut -f6)
asset=$(printf '%s' "$row" | cut -f7)
expected_sha=$(printf '%s' "$row" | cut -f8)
self_contained=$(printf '%s' "$row" | cut -f9)

if [ -n "$version" ] && [ "$version" != "$release_version" ]; then
    die "the manifest at $manifest publishes $release_version, not $version"
fi

# ---------------------------------------------------------- already installed
if [ "$force" -eq 0 ] && [ -x "$prefix/bin/beansc" ]; then
    installed=$("$prefix/bin/beansc" --version 2>/dev/null || true)
    case $installed in
        *"$release_version"*)
            note "beans $release_version is already installed in $prefix"
            note "re-run with --force to reinstall"
            exit 0
            ;;
    esac
fi

# ------------------------------------------------------------------ download
note "downloading $asset ($package_class package for $target)"
fetch "$base/$asset" "$work/$asset" ||
    die "cannot download $base/$asset"

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha=$(sha256sum "$work/$asset" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    actual_sha=$(shasum -a 256 "$work/$asset" | cut -d' ' -f1)
elif command -v openssl >/dev/null 2>&1; then
    actual_sha=$(openssl dgst -sha256 "$work/$asset" | awk '{print $NF}')
else
    die "no sha256 tool found; install coreutils, perl-shasum or openssl"
fi
if [ "$actual_sha" != "$expected_sha" ]; then
    die "checksum mismatch for $asset
  expected $expected_sha
  actual   $actual_sha
Nothing was installed."
fi
note "checksum verified"

# ------------------------------------------------------- unpack and validate
# Windows packages are .zip; everywhere else ships .tar.gz. GNU tar (Git
# Bash's tar) does not read zip archives, so each format gets its own tool.
mkdir "$work/stage"
case $asset in
    *.zip)
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$work/$asset" -d "$work/stage" ||
                die "cannot unpack $asset; nothing was installed"
        else
            # bsdtar reads zip; plain GNU tar does not and says so.
            tar xf "$work/$asset" -C "$work/stage" ||
                die "cannot unpack $asset (no unzip, and this tar does not read zip); nothing was installed"
        fi
        ;;
    *)
        tar xzf "$work/$asset" -C "$work/stage" ||
            die "cannot unpack $asset; nothing was installed"
        ;;
esac
unpacked=$(find "$work/stage" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$unpacked" ] || die "$asset does not contain a package directory"
# A Windows package launches through bin/beansc.cmd; everywhere else the
# launcher is bin/beansc. Git Bash and MSYS run a .cmd directly.
launcher=
if [ -x "$unpacked/bin/beansc" ]; then
    launcher="$unpacked/bin/beansc"
elif [ -f "$unpacked/bin/beansc.cmd" ]; then
    launcher="$unpacked/bin/beansc.cmd"
else
    die "$asset has no bin/beansc; nothing was installed"
fi

# The staged compiler has to answer before anything is moved into place, so a
# corrupt or wrong-architecture download can never replace a working install.
staged_version=$("$launcher" --version 2>/dev/null) ||
    die "the downloaded compiler does not run on this machine ($machine); nothing was installed"
note "staged $staged_version"

# ------------------------------------------------------------------- install
parent=$(dirname "$prefix")
mkdir -p "$parent" || die "cannot create $parent"
previous=
if [ -e "$prefix" ]; then
    previous="$prefix.old-$$"
    mv "$prefix" "$previous" || die "cannot move the existing $prefix aside"
fi
if ! mv "$unpacked" "$prefix"; then
    [ -n "$previous" ] && mv "$previous" "$prefix"
    die "cannot install into $prefix"
fi
[ -n "$previous" ] && rm -rf "$previous"

# ---------------------------------------------------------------------- PATH
bin_dir="$prefix/bin"
line="export PATH=\"$bin_dir:\$PATH\""
updated=
already=
if [ "$modify_path" -eq 1 ]; then
    for profile in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$profile" ] || continue
        # Idempotent: an installation that has already added this entry must
        # never add a second copy of it.
        if grep -Fq "$bin_dir" "$profile" 2>/dev/null; then
            already="${already:+$already }$profile"
            continue
        fi
        {
            printf '\n# added by the Beans installer\n'
            printf '%s\n' "$line"
        } >>"$profile" && updated="${updated:+$updated }$profile"
    done
    # A fresh machine may have no shell profile at all. Without one there is
    # nowhere for the PATH entry to survive a reboot, so make the file every
    # POSIX login shell reads.
    if [ -z "$updated" ] && [ -z "$already" ]; then
        {
            printf '\n# added by the Beans installer\n'
            printf '%s\n' "$line"
        } >>"$HOME/.profile" && updated="$HOME/.profile"
    fi
fi

# ----------------------------------------------------------------- report
say ""
note "installed beans $release_version into $prefix"
if [ "$self_contained" = yes ]; then
    note "this is a full package: native builds work with nothing else installed"
else
    note "this is a $package_class package: a native build needs clang on your PATH"
fi
if [ -n "$updated" ]; then
    note "PATH updated in: $updated"
elif [ -n "$already" ]; then
    note "PATH already set in: $already"
fi
if [ -n "$updated" ] || [ -n "$already" ]; then
    note "a new terminal picks this up automatically; to enable Beans in this"
    note "shell right now, run:"
else
    note "add Beans to your PATH with:"
fi
say ""
say "    $line"
say ""

launcher_name=$(basename "$launcher")
PATH="$bin_dir:$PATH" "$prefix/bin/$launcher_name" --version ||
    die "the installed compiler did not run"
note "run 'beansc doctor' to see what this installation can build"
