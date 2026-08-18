#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${BEANSC:-"$PWD/build/beansc"}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-deps.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/source" "$tmp/remotes/acme" "$tmp/app"
git -C "$tmp/source" init -q
git -C "$tmp/source" config user.name "Beans Test"
git -C "$tmp/source" config user.email "beans@example.test"
printf 'module dep\n' >"$tmp/source/beans.pot"
printf 'package dep\n\npub fn answer() -> int { return 42 }\n' >"$tmp/source/dep.b"
git -C "$tmp/source" add beans.pot dep.b
git -C "$tmp/source" commit -qm v1
git -C "$tmp/source" tag v1
git init -q --bare "$tmp/remotes/acme/dep.git"
git -C "$tmp/remotes/acme/dep.git" symbolic-ref HEAD refs/heads/main
git -C "$tmp/source" remote add origin "$tmp/remotes/acme/dep.git"
git -C "$tmp/source" push -q origin HEAD:refs/heads/main --tags

cat >"$tmp/app/beans.pot" <<'EOF'
module app
EOF
cat >"$tmp/app/main.b" <<'EOF'
package main

import std.io
import example.test/acme/dep

fn main() {
    io.println("{dep.answer()}")
}
EOF

export BEANS_HOME="$tmp/home"
export GIT_ALLOW_PROTOCOL=file
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://$tmp/remotes/.insteadOf"
export GIT_CONFIG_VALUE_0="https://example.test/"
export GIT_CONFIG_KEY_1="url.file://$tmp/remotes/.insteadOf"
export GIT_CONFIG_VALUE_1="https://github.com/"

cd "$tmp/app"
"$compiler" pot add https://example.test/acme/dep.git v1 \
    >"$tmp/add.out"
grep -q '^added example.test/acme/dep v1$' "$tmp/add.out"
grep -q '^wrote beans.lock$' "$tmp/add.out"
grep -qx 'require example.test/acme/dep v1' beans.pot
test -f beans.lock
grep -Eq '^version 1$' beans.lock
grep -Eq '^module example[.]test/acme/dep v1 [0-9a-f]+ [0-9a-f]+$' beans.lock
cp beans.lock "$tmp/first.lock"
"$compiler" pot tidy
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

printf 'package dep\n\npub fn answer() -> int { return 43 }\n' >"$tmp/source/dep.b"
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
"$compiler" pot update https://example.test/acme/dep.git
grep -Eq '^module example[.]test/acme/dep v2 [0-9a-f]+ [0-9a-f]+$' beans.lock
test "$("$compiler" run --locked --offline main.b)" = "43"

v2_commit=$(git -C "$tmp/source" rev-parse HEAD)
sed "s/ v2$/ $v2_commit/" beans.pot >"$tmp/beans.pot.commit"
mv "$tmp/beans.pot.commit" beans.pot
"$compiler" pot update example.test/acme/dep
grep -Eq "^module example[.]test/acme/dep $v2_commit $v2_commit [0-9a-f]+$" \
    beans.lock
test "$("$compiler" run --locked --offline main.b)" = "43"

cp beans.pot "$tmp/before-remove.pot"
if "$compiler" pot remove https://example.test/acme/dep.git \
    >"$tmp/remove-used.out" 2>&1; then
    echo "removed a dependency that is still imported" >&2
    exit 1
fi
grep -q "dependency example.test/acme/dep is not in beans.pot" \
    "$tmp/remove-used.out"
cmp "$tmp/before-remove.pot" beans.pot

cat >main.b <<'EOF'
package main

fn main() {}
EOF
"$compiler" pot remove example.test/acme/dep >"$tmp/remove.out"
grep -q '^removed example.test/acme/dep$' "$tmp/remove.out"
grep -q '^wrote beans.lock$' "$tmp/remove.out"
if grep -q '^require example.test/acme/dep ' beans.pot; then
    echo "pot remove left the dependency in beans.pot" >&2
    exit 1
fi
if grep -q '^module example.test/acme/dep ' beans.lock; then
    echo "pot remove left the dependency in beans.lock" >&2
    exit 1
fi

mkdir -p "$tmp/shorthand"
printf 'module shorthand\n' >"$tmp/shorthand/beans.pot"
printf 'package main\n\nfn main() {}\n' >"$tmp/shorthand/main.b"
cd "$tmp/shorthand"
"$compiler" pot add acme/dep v1 >"$tmp/shorthand-add.out"
grep -q '^added github.com/acme/dep v1$' "$tmp/shorthand-add.out"
grep -qx 'require github.com/acme/dep v1' beans.pot
grep -Eq '^module github[.]com/acme/dep v1 [0-9a-f]+ [0-9a-f]+$' beans.lock
sed 's|^require github.com/acme/dep v1$|& # keep this note|' beans.pot \
    >"$tmp/shorthand.pot"
mv "$tmp/shorthand.pot" beans.pot
"$compiler" pot add acme/dep HEAD >"$tmp/shorthand-update.out"
grep -q '^updated github.com/acme/dep HEAD$' "$tmp/shorthand-update.out"
grep -qx 'require github.com/acme/dep HEAD # keep this note' beans.pot
"$compiler" pot remove acme/dep >/dev/null
test "$(cat beans.lock)" = "version 1"

# Local modules use their declared module name in source while their path stays
# a manifest-only development detail. Exercise both loaders, including a path
# with spaces and a comment marker.
mkdir -p "$tmp/local/app" "$tmp/local/local # dep" "$tmp/local/shared"
cat >"$tmp/local/shared/beans.pot" <<'EOF'
# a local library may annotate its manifest
module shared # trailing comments work too
kind library
EOF
cat >"$tmp/local/shared/shared.b" <<'EOF'
package shared

pub fn base() -> int { return 40 }
EOF
cat >"$tmp/local/local # dep/beans.pot" <<'EOF'
module local_dep
kind library
require path "../shared" // resolved from this manifest
EOF
cat >"$tmp/local/local # dep/dep.b" <<'EOF'
package local_dep

import shared

pub fn answer() -> int { return shared.base() + 2 }
EOF
cat >"$tmp/local/app/beans.pot" <<'EOF'
# local paths do not enter beans.lock
module local_app
require path "../local # dep" # the hash inside quotes is data
link none search "native # ignored" // quotes keep the hash
EOF
cat >"$tmp/local/app/main.b" <<'EOF'
package main

import std.io
import local_dep

fn main() { io.println(local_dep.answer()) }
EOF

for local_compiler in "$compiler"; do
    test "$(cd "$tmp/local/app" &&
        "$local_compiler" run --locked --offline main.b)" = "42"
    (cd "$tmp/local/app" &&
        "$local_compiler" check --locked --offline main.b) |
        grep -F 'main.b: ok' >/dev/null
    (cd "$tmp/local/app" &&
        "$local_compiler" build --locked --offline --emit ir main.b) >/dev/null
done
test ! -e "$tmp/local/app/beans.lock"

mkdir -p "$tmp/local/dup-one" "$tmp/local/dup-two" "$tmp/local/bad"
printf 'module twin\nkind library\n' >"$tmp/local/dup-one/beans.pot"
printf 'module twin\nkind library\n' >"$tmp/local/dup-two/beans.pot"
cat >"$tmp/local/bad/beans.pot" <<'EOF'
module bad
require path "../dup-one"
require path "../dup-two"
EOF
printf 'package main\nfn main() {}\n' >"$tmp/local/bad/main.b"
for local_compiler in "$compiler"; do
    cat >"$tmp/local/bad/beans.pot" <<'EOF'
module bad
require path "../dup-one"
require path "../dup-two"
EOF
    if "$local_compiler" check "$tmp/local/bad/main.b" \
        >"$tmp/local/duplicate.out" 2>&1; then
        echo "duplicate local module names were accepted" >&2
        exit 1
    fi
    grep -F "local module 'twin' refers to both" \
        "$tmp/local/duplicate.out" >/dev/null

    printf 'module bad\nrequire path "../missing"\n' \
        >"$tmp/local/bad/beans.pot"
    if "$local_compiler" check "$tmp/local/bad/main.b" \
        >"$tmp/local/missing.out" 2>&1; then
        echo "missing local module was accepted" >&2
        exit 1
    fi
    grep -F 'local dependency directory does not exist' \
        "$tmp/local/missing.out" >/dev/null

    printf 'module bad\nrequire path "../shared\n' \
        >"$tmp/local/bad/beans.pot"
    if "$local_compiler" check "$tmp/local/bad/main.b" \
        >"$tmp/local/quote.out" 2>&1; then
        echo "unterminated manifest quote was accepted" >&2
        exit 1
    fi
    grep -F 'unterminated quoted string' "$tmp/local/quote.out" >/dev/null
done

echo "ok locked git and local path dependencies"
