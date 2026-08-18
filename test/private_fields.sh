#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-private-fields.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/private_fields_ok.b >"$tmp/interp"
./build/beansc build test/cases/private_fields_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/private_fields_ok.out "$tmp/interp"
diff -u test/cases/private_fields_ok.out "$tmp/native.out"

if ./build/beansc check test/cases/private_fields_bad.b >"$tmp/bad" 2>&1; then
    echo "private_fields_bad.b unexpectedly passed" >&2
    exit 1
fi

test "$(grep -Fc "is private to 'main.Vault'" "$tmp/bad")" -eq 3
test "$(grep -Fc "is private to 'main.Token'" "$tmp/bad")" -eq 2

mkdir -p "$tmp/project/secret"
cat >"$tmp/project/beans.pot" <<'EOF'
module privacy_check
EOF
cat >"$tmp/project/secret/secret.b" <<'EOF'
package secret

pub class Vault {
    priv value: int = 9
}
EOF
cat >"$tmp/project/main.b" <<'EOF'
package main

import privacy_check.secret

fn main() {
    let vault: secret.Vault = new secret.Vault()
    let value: int = vault.value
}
EOF
if ./build/beansc check "$tmp/project/main.b" \
    >"$tmp/cross-package" 2>&1; then
    echo "cross-package private field unexpectedly passed" >&2
    exit 1
fi
grep -Fq "is private to 'privacy_check.secret.Vault'" \
    "$tmp/cross-package"

echo "ok priv fields are visible only inside their declaring class or struct"
