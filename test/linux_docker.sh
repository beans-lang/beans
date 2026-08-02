#!/usr/bin/env bash
# Run the Beans correctness gate inside a reproducible Linux container.
#
#   test/linux_docker.sh                     # host architecture, full gate
#   test/linux_docker.sh --platform linux/amd64
#   test/linux_docker.sh -- bash test/targets.sh      # one script
#   test/linux_docker.sh -- shell                     # interactive
#
# The repository is bind-mounted read-only and copied inside the container, so a
# Linux build can never overwrite the host's build/ directory.
set -euo pipefail

cd "$(dirname "$0")/.."

image=beans-linux-test
platform=""
build_only=0
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            platform="$2"
            shift 2
            ;;
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
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed; skipping the Linux container gate" >&2
    exit 0
fi
# Respects DOCKER_HOST and the active docker context, so the socket path is
# never hardcoded (Docker Desktop does not use /var/run/docker.sock).
if ! docker info >/dev/null 2>&1; then
    echo "docker is installed but not reachable; skipping the Linux container gate" >&2
    exit 0
fi

host_arch=$(uname -m)
case "$host_arch" in
    arm64 | aarch64) native_platform=linux/arm64 ;;
    x86_64 | amd64) native_platform=linux/amd64 ;;
    *) native_platform="" ;;
esac
if [[ -z "$platform" ]]; then
    platform="$native_platform"
fi

if [[ -n "$platform" && "$platform" != "$native_platform" ]]; then
    cat >&2 <<BANNER
=====================================================================
 $platform on a $host_arch host is EMULATED.
 Correctness only. Timings from this run are meaningless and must
 never be reported as a performance result.
=====================================================================
BANNER
fi

platform_args=()
if [[ -n "$platform" ]]; then platform_args=(--platform "$platform"); fi

# The image tag carries the platform so the two never overwrite each other.
tag="${image}:${platform//\//-}"

echo "building $tag"
docker build "${platform_args[@]}" \
    -f test/docker/linux.Dockerfile \
    -t "$tag" .

if [[ "$build_only" == 1 ]]; then
    echo "ok built $tag"
    exit 0
fi

if [[ ${#args[@]} -eq 0 ]]; then args=(gate); fi

echo "running ${args[*]} in $tag"
# Git Bash rewrites arguments that look like absolute paths on the way to a
# native .exe, so `-v /c/beans:/src:ro` reaches docker.exe as a mangled Windows
# path and the mount silently does not happen — the container then reports
# "expected the repository bind-mounted read-only at /src". cygpath gives
# docker.exe the Windows spelling it wants and MSYS_NO_PATHCONV stops the
# rewrite; on Linux and macOS there is no cygpath and $PWD is used unchanged.
mount_src=$PWD
if command -v cygpath >/dev/null 2>&1; then
    mount_src=$(cygpath -w "$PWD")
    export MSYS_NO_PATHCONV=1
fi

docker run --rm "${platform_args[@]}" \
    -v "$mount_src:/src:ro" \
    "$tag" "${args[@]}"

echo "ok Linux container gate on $platform"
