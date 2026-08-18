#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-private-methods.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

./build/beansc run test/cases/private_methods_ok.b >"$tmp/interp"
./build/beansc build test/cases/private_methods_ok.b -o "$tmp/native" \
    >"$tmp/build" 2>&1
"$tmp/native" >"$tmp/native.out"
diff -u test/cases/private_methods_ok.out "$tmp/interp"
diff -u test/cases/private_methods_ok.out "$tmp/native.out"

./build/beansc parse test/cases/private_methods_ok.b >"$tmp/parse"
grep -Fq "priv fn secret()" "$tmp/parse"
grep -Fq "priv static fn seed()" "$tmp/parse"
grep -Fq "priv inout fn add(amount: int)" "$tmp/parse"

if ./build/beansc check test/cases/private_methods_bad.b \
    >"$tmp/bad" 2>&1; then
    echo "private_methods_bad.b unexpectedly passed" >&2
    exit 1
fi
test "$(grep -Fc "is private to 'main.Vault'" "$tmp/bad")" -eq 4
test "$(grep -Fc "is private to 'main.Token'" "$tmp/bad")" -eq 3

if ./build/beansc check test/cases/private_method_modifiers_bad.b \
    >"$tmp/modifiers" 2>&1; then
    echo "private_method_modifiers_bad.b unexpectedly passed" >&2
    exit 1
fi
grep -Fq "priv methods are supported only on classes and structs" \
    "$tmp/modifiers"
grep -Fq "private method 'hidden' cannot be abstract" "$tmp/modifiers"
grep -Fq "private method 'hidden' cannot be marked override" "$tmp/modifiers"
grep -Fq "method cannot be both pub and priv" "$tmp/modifiers"
test "$(grep -c ': error: ' "$tmp/modifiers")" -eq 4

mkdir -p "$tmp/project/secret"
cat >"$tmp/project/beans.pot" <<'EOF'
module privacy_check
EOF
cat >"$tmp/project/secret/secret.b" <<'EOF'
package secret

pub class Vault {
    priv fn hidden() -> int {
        return 9
    }

    pub fn reveal() -> int {
        return self.hidden()
    }
}
EOF
cat >"$tmp/project/main.b" <<'EOF'
package main

import privacy_check.secret

fn main() {
    let vault: secret.Vault = new secret.Vault()
    let value: int = vault.hidden()
}
EOF
if ./build/beansc check "$tmp/project/main.b" \
    >"$tmp/cross-package" 2>&1; then
    echo "cross-package private method unexpectedly passed" >&2
    exit 1
fi
grep -Fq "is private to 'privacy_check.secret.Vault'" \
    "$tmp/cross-package"

echo "ok priv methods are visible only inside their declaring class or struct"
