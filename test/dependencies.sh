#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler="$PWD/build/beansc"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-deps.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/source" "$tmp/remotes/acme" "$tmp/app"
git -C "$tmp/source" init -q
git -C "$tmp/source" config user.name "Beans Test"
git -C "$tmp/source" config user.email "beans@example.test"
printf 'module dep\n' >"$tmp/source/beans.pot"
printf 'pub fn answer() -> int { return 42 }\n' >"$tmp/source/dep.b"
git -C "$tmp/source" add beans.pot dep.b
git -C "$tmp/source" commit -qm v1
git -C "$tmp/source" tag v1
git init -q --bare "$tmp/remotes/acme/dep.git"
git -C "$tmp/remotes/acme/dep.git" symbolic-ref HEAD refs/heads/main
git -C "$tmp/source" remote add origin "$tmp/remotes/acme/dep.git"
git -C "$tmp/source" push -q origin HEAD:refs/heads/main --tags

cat >"$tmp/app/beans.pot" <<'EOF'
module app
require example.test/acme/dep v1
EOF
cat >"$tmp/app/main.b" <<'EOF'
import std.io
import example.test/acme/dep

fn main() {
    io.println("{dep.answer()}")
}
EOF

export BEANS_HOME="$tmp/home"
export GIT_ALLOW_PROTOCOL=file
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.file://$tmp/remotes/.insteadOf"
export GIT_CONFIG_VALUE_0="https://example.test/"

cd "$tmp/app"
"$compiler" mod tidy
test -f beans.lock
grep -Eq '^version 1$' beans.lock
grep -Eq '^module example[.]test/acme/dep v1 [0-9a-f]+ [0-9a-f]+$' beans.lock
cp beans.lock "$tmp/first.lock"
"$compiler" mod tidy
cmp "$tmp/first.lock" beans.lock

test "$("$compiler" run --locked --offline main.b)" = "42"
test "$("$compiler" check --locked --offline main.b)" = "main.b: ok"
"$compiler" build --locked --offline --emit ir main.b >/dev/null

cp beans.lock "$tmp/exact.lock"
printf 'module example.test/acme/unused HEAD 0000000 0000000\n' \
    >>beans.lock
if "$compiler" check --locked --offline main.b >"$tmp/unused" 2>&1; then
    echo "unused locked dependency was accepted" >&2
    exit 1
fi
grep -q 'beans.lock contains unused dependency' "$tmp/unused"
cp "$tmp/exact.lock" beans.lock

commit=$(awk '$1 == "module" { print $4 }' beans.lock)
cache="$BEANS_HOME/pkg/example.test/acme/dep/$commit"
printf '\n// changed\n' >>"$cache/dep.b"
if "$compiler" check --locked --offline main.b >"$tmp/tampered" 2>&1; then
    echo "tampered dependency cache was accepted" >&2
    exit 1
fi
grep -q 'cached checkout has local content changes' "$tmp/tampered"
git -C "$cache" checkout -q -- dep.b

printf 'pub fn answer() -> int { return 43 }\n' >"$tmp/source/dep.b"
git -C "$tmp/source" add dep.b
git -C "$tmp/source" commit -qm v2
git -C "$tmp/source" tag v2
git -C "$tmp/source" push -q origin HEAD:refs/heads/main --tags
sed 's/ v1$/ v2/' beans.pot >"$tmp/beans.pot.v2"
mv "$tmp/beans.pot.v2" beans.pot

if "$compiler" check --locked main.b >"$tmp/stale" 2>&1; then
    echo "stale lockfile was accepted" >&2
    exit 1
fi
grep -q 'now requests v2 but beans.lock records v1' "$tmp/stale"
"$compiler" mod update example.test/acme/dep
grep -Eq '^module example[.]test/acme/dep v2 [0-9a-f]+ [0-9a-f]+$' beans.lock
test "$("$compiler" run --locked --offline main.b)" = "43"

v2_commit=$(git -C "$tmp/source" rev-parse HEAD)
sed "s/ v2$/ $v2_commit/" beans.pot >"$tmp/beans.pot.commit"
mv "$tmp/beans.pot.commit" beans.pot
"$compiler" mod update example.test/acme/dep
grep -Eq "^module example[.]test/acme/dep $v2_commit $v2_commit [0-9a-f]+$" \
    beans.lock
test "$("$compiler" run --locked --offline main.b)" = "43"

if rg -n 'std::system|popen[(]' "$OLDPWD/compiler/bootstrap/loader.cpp" >"$tmp/shell"; then
    echo "dependency loader still invokes a shell" >&2
    cat "$tmp/shell" >&2
    exit 1
fi

echo "ok locked, hashed, offline, direct-git dependencies"
