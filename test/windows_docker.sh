#!/usr/bin/env bash
# Run the Beans Windows gate inside a reproducible Linux container: cross-compile
# to x86-64 PE with MinGW-w64, execute under Wine, diff against the interpreter.
#
#   test/windows_docker.sh                   # full gate (test/windows.sh)
#   test/windows_docker.sh --build-only      # just build the image
#   test/windows_docker.sh -- bash test/windows.sh --stage0   # quick loop
#   test/windows_docker.sh -- shell          # interactive
#
# The platform is always linux/amd64: Wine is not an emulator, so it can only
# run x86-64 PE code on an x86-64 Linux. On an Apple-silicon host that means
# the whole container is emulated (Rosetta/qemu) — correctness only, never a
# performance number.
#
# The repository is bind-mounted read-only and copied inside the container, so
# a container build can never overwrite the host's build/ directory.
set -euo pipefail

cd "$(dirname "$0")/.."

image=beans-windows-test
build_only=0
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            image="$2"
            shift 2
            ;;
        --build-only)
            build_only=1
            shift
            ;;
        --)
            shift
            args=("$@")
            break
            ;;
        -h | --help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed; skipping the Windows container gate" >&2
    exit 0
fi
# Respects DOCKER_HOST and the active docker context, so the socket path is
# never hardcoded (Docker Desktop does not use /var/run/docker.sock).
if ! docker info >/dev/null 2>&1; then
    echo "docker is installed but not reachable; skipping the Windows container gate" >&2
    exit 0
fi

platform=linux/amd64
host_arch=$(uname -m)
if [[ "$host_arch" != "x86_64" && "$host_arch" != "amd64" ]]; then
    cat >&2 <<BANNER
=====================================================================
 $platform on a $host_arch host is EMULATED.
 Correctness only. Timings from this run are meaningless and must
 never be reported as a performance result.
=====================================================================
BANNER
fi

tag="${image}:amd64"

echo "building $tag"
docker build --platform "$platform" \
    -f test/docker/windows.Dockerfile \
    -t "$tag" .

if [[ "$build_only" == 1 ]]; then
    echo "ok built $tag"
    exit 0
fi

if [[ ${#args[@]} -eq 0 ]]; then args=(bash test/windows.sh); fi

echo "running ${args[*]} in $tag"
# See test/linux_docker.sh: Git Bash rewrites the -v argument on the way to
# docker.exe and the mount silently does not happen. This gate is the one a
# Windows developer is most likely to reach for, so it is exactly where the
# mangling must not bite.
mount_src=$PWD
if command -v cygpath >/dev/null 2>&1; then
    mount_src=$(cygpath -w "$PWD")
    export MSYS_NO_PATHCONV=1
fi

docker run --rm --platform "$platform" \
    -v "$mount_src:/src:ro" \
    "$tag" "${args[@]}"

echo "ok Windows container gate (MinGW + Wine)"
