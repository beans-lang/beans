#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"

make
make test
make test-sanitize
make access-score
make test-c-abi-tier1
bash test/wasm.sh
bash test/embedded.sh
make test-release-package
bash test/install.sh
make test-clean-self-host

echo "ok full self-hosted promotion gate"
