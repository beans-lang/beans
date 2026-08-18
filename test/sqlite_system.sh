#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
compiler=${BEANSC:-"$root/build/beansc"}

if ! command -v pkg-config >/dev/null 2>&1 || \
   ! pkg-config --exists sqlite3; then
    if [[ ${BEANS_SQLITE_REQUIRE:-0} == 1 ]]; then
        echo "sqlite3 pkg-config metadata is required" >&2
        exit 1
    fi
    echo "skipping sqlite3 system package smoke: pkg-config sqlite3 is unavailable"
    exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-sqlite.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/beans.pot" <<'POT'
module sqlite_system_smoke
POT
cat >"$tmp/main.b" <<'BEANS'
package main

import std.io

fn main() {
    unsafe {
        let filename: Bytes = Bytes.from(":memory:")
        filename.push(0)
        let db_slot: RawPtr<RawPtr<Sqlite3>> = RawPtr.alloc(1)
        let open_status: i32 = sqlite3_open(
            RawPtr.from_address(filename.as_ptr().address()), db_slot)
        let db: RawPtr<Sqlite3> = db_slot.read()
        io.println("open {open_status}")

        let sql: Bytes = Bytes.from(
            "create table notes (id integer primary key, body text);")
        sql.push(0)
        let stmt_slot: RawPtr<RawPtr<Sqlite3Stmt>> = RawPtr.alloc(1)
        let prepare_status: i32 = sqlite3_prepare_v2(
            db,
            RawPtr.from_address(sql.as_ptr().address()),
            -1,
            stmt_slot,
            RawPtr.null())
        io.println("prepare {prepare_status}")
        let stmt: RawPtr<Sqlite3Stmt> = stmt_slot.read()
        io.println("step {sqlite3_step(stmt)}")
        io.println("finalize {sqlite3_finalize(stmt)}")
        stmt_slot.free()
        io.println("close {sqlite3_close(db)}")
        db_slot.free()
    }
}
BEANS

(
    cd "$tmp"
    "$compiler" pot add --system sqlite3
    "$compiler" bindgen --system sqlite3 sqlite3.h \
        --package main \
        --only sqlite3_open \
        --only sqlite3_close \
        --only sqlite3_prepare_v2 \
        --only sqlite3_step \
        --only sqlite3_finalize \
        -o sqlite3_bindings.b
)

expected=$'open 0\nprepare 0\nstep 101\nfinalize 0\nclose 0'
run_output=$("$compiler" run "$tmp/main.b")
test "$run_output" = "$expected"

BEANS_RUNTIME="$root/runtime/beans_rt.c" \
    "$compiler" build "$tmp/main.b" -o "$tmp/sqlite-smoke"
native_output=$("$tmp/sqlite-smoke")
test "$native_output" = "$expected"

echo "ok sqlite3 pkg-config, bindgen, interpreter, and native build"
