#!/usr/bin/env bash
# The Windows correctness gate: cross-compile with MinGW-w64, execute under
# Wine, and hold the result to the same differential standard as every other
# backend — interpreter output and native output byte-identical, exit codes
# included.
#
# Designed to run inside the container test/docker/windows.Dockerfile builds
# (see test/windows_docker.sh for the host wrapper), but runs anywhere a
# mingw-capable clang and wine both exist.
#
# The example set is discovered, not hardcoded: every examples/*.b that CHECKS
# clean for the Windows target must then build, run under Wine and match the
# interpreter. A check failure is only acceptable when it is the capability
# system refusing a POSIX-only import — anything else fails the gate. That
# split is the point: a new example can never be silently skipped, and the
# refusal list can never rot into a vacuous pass.
set -uo pipefail

cd "$(dirname "$0")/.."

TRIPLE=x86_64-pc-windows-gnu
BEANSC=${BEANSC:-./build/beansc}
WINE=${WINE:-}

# ---- preamble: do we have the pieces? ---------------------------------------

if [[ -z "$WINE" ]]; then
    if command -v wine >/dev/null 2>&1; then WINE=wine
    elif command -v wine64 >/dev/null 2>&1; then WINE=wine64
    fi
fi
if [[ -z "$WINE" ]]; then
    echo "skipping: wine is not installed (run under test/windows_docker.sh)" >&2
    exit 0
fi
probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
echo 'int main(void){return 42;}' > "$probe_dir/probe.c"
if ! clang --target=$TRIPLE -fuse-ld=lld "$probe_dir/probe.c" -o "$probe_dir/probe.exe" 2>"$probe_dir/probe.err"; then
    echo "skipping: clang cannot link $TRIPLE (no MinGW sysroot?)" >&2
    sed 's/^/  /' "$probe_dir/probe.err" >&2
    exit 0
fi
"$WINE" "$probe_dir/probe.exe"
if [[ $? -ne 42 ]]; then
    echo "skipping: wine cannot execute a $TRIPLE binary here" >&2
    exit 0
fi

if [[ ! -x "$BEANSC" ]]; then
    make
fi

fails=0
fail() {
    echo "FAIL: $1" >&2
    fails=$((fails + 1))
}

# ---- host-side checks: refusals and IR facts, no emulator needed ------------

refuses() { # <source file> <expected refusal text>
    local out
    out=$("$BEANSC" check --target $TRIPLE "$1" 2>&1)
    if [[ $? -eq 0 ]]; then
        fail "$1 checked clean for $TRIPLE; expected: $2"
        return
    fi
    if ! grep -qF "$2" <<<"$out"; then
        fail "$1 refused with the wrong message; wanted '$2', got: $out"
    fi
}

mkdir -p build/windows_gate

# Two build shapes the rest of this gate never exercises, both of which were
# broken while every example passed.
#
# The default linker. Everything else here passes --linker lld, and lld scans
# the whole input set before deciding what is unresolved. GNU ld does not: it
# walks left to right and pulls only the archive members that satisfy a symbol
# already undefined, so -lws2_32 ahead of the objects that call Winsock links
# nothing and every socket symbol is reported missing. A gate that always names
# a linker cannot see that.
cat > build/windows_gate/wants_socket.b <<'EOF'
import std.io
import std.net

fn main() {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(server) => { io.println("bound") }
        err(problem) => { io.println("no: {problem.msg}") }
    }
}
EOF
if ! "$BEANSC" build --target $TRIPLE build/windows_gate/wants_socket.b \
        -o build/windows_gate/wants_socket.exe \
        > build/windows_gate/default_linker.log 2>&1; then
    fail "a socket program does not link for $TRIPLE with the default linker:"
    tail -20 build/windows_gate/default_linker.log >&2
fi

# The minimal runtime profile. windows.h used to arrive with the filesystem
# shim, which only compiles at the full profile — so `--runtime minimal` failed
# on undeclared Sleep and DWORD while every example (all full-profile) passed.
cat > build/windows_gate/wants_minimal.b <<'EOF'
import std.io

fn main() {
    io.println("minimal {2 + 2}")
}
EOF
if ! "$BEANSC" build --target $TRIPLE --runtime minimal --linker lld \
        build/windows_gate/wants_minimal.b -o build/windows_gate/wants_minimal.exe \
        > build/windows_gate/minimal.log 2>&1; then
    fail "the minimal runtime profile does not build for $TRIPLE:"
    tail -20 build/windows_gate/minimal.log >&2
else
    got=$("$WINE" build/windows_gate/wants_minimal.exe 2>&1)
    [[ "$got" == "minimal 4" ]] ||
        fail "the minimal-profile binary printed '$got', wanted 'minimal 4'"
fi

# Windows compiles the full profile with the filesystem tier live, so the
# POSIX-only capabilities are refused by the per-target check, named triple
# and all — and std.fs must now check clean.
cat > build/windows_gate/wants_fs.b <<'EOF'
import std.fs
fn main() { }
EOF
if ! "$BEANSC" check --target $TRIPLE build/windows_gate/wants_fs.b \
        > build/windows_gate/wants_fs.log 2>&1; then
    fail "std.fs no longer checks clean for $TRIPLE:"
    sed 's/^/  /' build/windows_gate/wants_fs.log >&2
fi
cat > build/windows_gate/wants_net.b <<'EOF'
import std.net
fn main() { }
EOF
if ! "$BEANSC" check --target $TRIPLE build/windows_gate/wants_net.b \
        > build/windows_gate/wants_net.log 2>&1; then
    fail "std.net no longer checks clean for $TRIPLE:"
    sed 's/^/  /' build/windows_gate/wants_net.log >&2
fi
# Signals check clean (the compiler's own interpreter needs the import to
# exist) but every operation refuses at runtime; the exemption block below
# pins that sentence.
cat > build/windows_gate/wants_signal.b <<'EOF'
import std.signal
fn main() { }
EOF
if ! "$BEANSC" check --target $TRIPLE build/windows_gate/wants_signal.b \
        > build/windows_gate/wants_signal.log 2>&1; then
    fail "std.signal no longer checks clean for $TRIPLE:"
    sed 's/^/  /' build/windows_gate/wants_signal.log >&2
fi
cat > build/windows_gate/wants_proc.b <<'EOF'
import std.process
fn main() { }
EOF
if ! "$BEANSC" check --target $TRIPLE build/windows_gate/wants_proc.b \
        > build/windows_gate/wants_proc.log 2>&1; then
    fail "std.process no longer checks clean for $TRIPLE:"
    sed 's/^/  /' build/windows_gate/wants_proc.log >&2
fi

# Target facts folded into IR: the constants a Windows binary would print.
# examples/target_info.b is the canonical probe; the IR lands in
# build/target_info.ll exactly as test/targets.sh reads it.
if "$BEANSC" build --emit ir --target $TRIPLE examples/target_info.b \
        > /dev/null 2> build/windows_gate/facts.err; then
    grep -q 'target triple = "x86_64-pc-windows-gnu"' build/target_info.ll ||
        fail "target_info.ll does not carry the $TRIPLE triple"
    grep -q 'c"windows\\00"' build/target_info.ll ||
        fail "target_info.ll does not fold target.os() to \"windows\""
    grep -q 'c"coff\\00"' build/target_info.ll ||
        fail "target_info.ll does not fold target.object_format() to \"coff\""
else
    fail "could not emit IR for examples/target_info.b:"
    sed 's/^/  /' build/windows_gate/facts.err >&2
fi

# ---- the differential gate --------------------------------------------------

# target_info.b prints the selected target's facts, so the interpreter (host
# target) and a Windows binary differ *by design*. It gets a positive golden
# check under Wine below instead of a diff.
#
# poller.b hits the one readiness semantic Windows cannot express: a peer's
# FIN queued behind unread data is invisible to WSAPoll (POSIX RDHUP shows it
# immediately), and SIO_TCP_INFO's CLOSE_WAIT door is not implemented by
# Wine. Hangup there surfaces once the data is drained. The example runs
# under a masked diff below — only that one line is excused, and both sides'
# verdicts are pinned so the exemption cannot quietly grow.
# processes.b and child_process.b are POSIX *content*, not a runtime gap:
# they spawn /bin/echo and /bin/sh by absolute path, which no Windows machine
# has. The parametrized parent/child differential below proves the process
# runtime itself — both sides spawn a beans-built child for their own
# platform and must print identical bytes.
# signals.b exercises real signal delivery, which Windows does not have; its
# runtime stubs refuse with a sentence, pinned by the positive check below.
diff_exempt="target_info.b poller.b processes.b child_process.b signals.b"

ran=0
refused=0
declare -a refused_names=()

# No TMPDIR games: wine requires an absolute TMPDIR for its own sockets (a
# relative one aborts wine itself), and the fs examples are already proven
# temp-path independent — make test runs them on macOS and Linux, whose
# TMPDIRs differ, with byte-identical output. They use Dir.temp_path() as a base
# and never print it.
#
# A bare wine64 prefix synthesizes no Path variable at all, and files.b
# checks that the environment has one — true on every real system, Windows
# included. WINEPATH is wine's documented way to provide it.
export WINEPATH='C:\windows'

run_diff() { # <source> <exe stem>  — build, wine-run, diff vs interpreter
    local src=$1 stem=$2
    local exe=build/windows_gate/$stem.exe
    if ! "$BEANSC" build --target $TRIPLE --linker lld "$src" -o "$exe" \
            > build/windows_gate/$stem.buildlog 2>&1; then
        fail "$src does not build for $TRIPLE:"
        sed 's/^/  /' build/windows_gate/$stem.buildlog >&2
        return
    fi
    file -b "$exe" | grep -q 'PE32+' || fail "$exe is not a PE32+ binary"

    "$BEANSC" run "$src" > build/windows_gate/$stem.interp.out 2>&1
    local interp_code=$?
    "$WINE" "$exe" > build/windows_gate/$stem.wine.out 2>&1
    local wine_code=$?

    if [[ $interp_code -ne $wine_code ]]; then
        fail "$src: interpreter exit $interp_code, wine exit $wine_code"
    fi
    if ! cmp -s build/windows_gate/$stem.interp.out \
                build/windows_gate/$stem.wine.out; then
        fail "$src: output differs between interpreter and wine"
        diff build/windows_gate/$stem.interp.out \
             build/windows_gate/$stem.wine.out | head -20 >&2
    fi
    ran=$((ran + 1))
}

for src in examples/*.b; do
    name=$(basename "$src")
    check_out=$("$BEANSC" check --target $TRIPLE "$src" 2>&1)
    if [[ $? -ne 0 ]]; then
        if grep -q "does not have\|needs at least the" <<<"$check_out"; then
            refused=$((refused + 1))
            refused_names+=("$name")
            continue
        fi
        fail "$src fails to check for $TRIPLE with a non-capability error: $check_out"
        continue
    fi
    if [[ " $diff_exempt " == *" $name "* ]]; then continue; fi
    run_diff "$src" "${name%.b}"
done

# The multi-package program is a first-class diff target next to tour.b.
run_diff examples/shop/main.b shop

# The process differential: one parent source, two children — the interpreter
# spawns a host-native child, the Windows binary spawns the PE child inside
# wine — and the printed bytes must be identical. This is what stands in for
# the two /bin-path examples excused above.
cat > build/windows_gate/proc_child.b <<'EOF'
import std.io
import std.os
fn main() {
    let args: List<string> = os.args()
    io.println("child got {args.len()} args, first {args[0]}")
    match io.read_line() {
        some(line) => io.println("child heard [{line}]"),
        none => io.println("child heard nothing"),
    }
    io.eprintln("child stderr line")
    os.exit(7)
}
EOF
cat > build/windows_gate/proc_parent.b <<'EOF'
import std.io
import std.os
import std.process
fn main() {
    // The child's path arrives by environment: `beansc run` reads extra argv
    // as more source files, so argv cannot carry it on the interpreter side.
    let child_path: string = os.env("BEANS_GATE_CHILD").or("missing")
    var child: process.Command = new process.Command(child_path)
    child.arg("alpha").arg("two words")
    child.stdin_text("over the pipe\n")
    match child.run() {
        ok(done) => {
            io.println("out [{done.stdout_text().trim()}]")
            io.println("err [{done.stderr_text().trim()}]")
            io.println("status {done.status}")
        }
        err(e) => io.println("spawn failed: {e.kind}"),
    }
}
EOF
proc_ok=1
"$BEANSC" build build/windows_gate/proc_child.b -o build/windows_gate/proc_child_host \
    > build/windows_gate/proc.buildlog 2>&1 || proc_ok=0
"$BEANSC" build --target $TRIPLE --linker lld build/windows_gate/proc_child.b \
    -o build/windows_gate/proc_child.exe >> build/windows_gate/proc.buildlog 2>&1 || proc_ok=0
"$BEANSC" build --target $TRIPLE --linker lld build/windows_gate/proc_parent.b \
    -o build/windows_gate/proc_parent.exe >> build/windows_gate/proc.buildlog 2>&1 || proc_ok=0
if [[ $proc_ok -eq 1 ]]; then
    BEANS_GATE_CHILD=build/windows_gate/proc_child_host \
        "$BEANSC" run build/windows_gate/proc_parent.b \
        > build/windows_gate/proc.interp.out 2>&1
    proc_interp_code=$?
    BEANS_GATE_CHILD=build/windows_gate/proc_child.exe \
        "$WINE" build/windows_gate/proc_parent.exe \
        > build/windows_gate/proc.wine.out 2>&1
    proc_wine_code=$?
    if [[ $proc_interp_code -ne $proc_wine_code ]]; then
        fail "process differential: interpreter exit $proc_interp_code, wine exit $proc_wine_code"
    fi
    if ! cmp -s build/windows_gate/proc.interp.out build/windows_gate/proc.wine.out; then
        fail "process differential: output differs between interpreter and wine"
        diff build/windows_gate/proc.interp.out build/windows_gate/proc.wine.out | head -10 >&2
    fi
    ran=$((ran + 1))
else
    fail "process differential probes do not build:"
    sed 's/^/  /' build/windows_gate/proc.buildlog >&2
fi

# The signal stubs must refuse with their sentence from a real Windows binary.
cat > build/windows_gate/sig_probe.b <<'EOF'
import std.io
import std.signal
fn main() {
    match signal.Signal.user1() {
        ok(number) => {
            match signal.Signals.watch_signal(number) {
                ok(_) => io.println("watch unexpectedly worked"),
                err(e) => io.println("watch refused: {e.kind}: {e.msg}"),
            }
        }
        err(e) => io.println("watch refused: {e.kind}: {e.msg}"),
    }
}
EOF
if "$BEANSC" build --target $TRIPLE --linker lld build/windows_gate/sig_probe.b \
        -o build/windows_gate/sig_probe.exe > build/windows_gate/sig_probe.buildlog 2>&1; then
    "$WINE" build/windows_gate/sig_probe.exe > build/windows_gate/sig_probe.out 2>&1
    grep -q "watch refused: unsupported: signal watching is not available on Windows" \
        build/windows_gate/sig_probe.out ||
        fail "signal stub does not refuse with the pinned sentence: $(cat build/windows_gate/sig_probe.out)"
else
    fail "signal stub probe does not build:"
    sed 's/^/  /' build/windows_gate/sig_probe.buildlog >&2
fi

# poller.b, masked: everything must match except the RDHUP-behind-data line,
# and the two verdicts are asserted exactly — interpreter true, Windows false —
# so a change on either side reopens the question instead of hiding in the mask.
if "$BEANSC" build --target $TRIPLE --linker lld examples/poller.b \
        -o build/windows_gate/poller.exe > build/windows_gate/poller.buildlog 2>&1; then
    "$BEANSC" run examples/poller.b > build/windows_gate/poller.interp.out 2>&1
    poller_interp_code=$?
    "$WINE" build/windows_gate/poller.exe > build/windows_gate/poller.wine.out 2>&1
    poller_wine_code=$?
    if [[ $poller_interp_code -ne $poller_wine_code ]]; then
        fail "examples/poller.b: interpreter exit $poller_interp_code, wine exit $poller_wine_code"
    fi
    grep -q "^the peer closing is reported true$" build/windows_gate/poller.interp.out ||
        fail "poller.b interpreter no longer reports RDHUP true — re-examine the exemption"
    grep -q "^the peer closing is reported false$" build/windows_gate/poller.wine.out ||
        fail "poller.b under wine no longer reports false — Windows may express RDHUP now; drop the exemption"
    sed 's/^the peer closing is reported .*$/<rdhup line excused>/' \
        build/windows_gate/poller.interp.out > build/windows_gate/poller.interp.masked
    sed 's/^the peer closing is reported .*$/<rdhup line excused>/' \
        build/windows_gate/poller.wine.out > build/windows_gate/poller.wine.masked
    if ! cmp -s build/windows_gate/poller.interp.masked build/windows_gate/poller.wine.masked; then
        fail "examples/poller.b: output differs beyond the excused RDHUP line"
        diff build/windows_gate/poller.interp.masked build/windows_gate/poller.wine.masked | head -10 >&2
    fi
    ran=$((ran + 1))
else
    fail "examples/poller.b does not build for $TRIPLE:"
    sed 's/^/  /' build/windows_gate/poller.buildlog >&2
fi

# target_info under Wine must report the *Windows* target — a positive golden,
# and proof std.target facts survive into a running PE binary.
if "$BEANSC" build --target $TRIPLE --linker lld examples/target_info.b \
        -o build/windows_gate/target_info.exe > /dev/null 2>&1; then
    "$WINE" build/windows_gate/target_info.exe > build/windows_gate/target_info.out 2>&1
    grep -q "windows" build/windows_gate/target_info.out ||
        fail "target_info.exe does not report os windows"
    grep -q "coff" build/windows_gate/target_info.out ||
        fail "target_info.exe does not report object_format coff"
else
    fail "examples/target_info.b does not build for $TRIPLE"
fi

# The compiler itself must cross-compile to Windows and answer under Wine —
# the standing proof behind beansc.exe. The full hosted differential loop
# (test/windows_hosted.sh) runs on the real-Windows CI runner where a native
# clang exists; here the interpreter half is the strongest executable claim.
if "$BEANSC" build --target $TRIPLE --linker lld src/main.b \
        -o build/windows_gate/beansc.exe > build/windows_gate/beansc.buildlog 2>&1; then
    "$WINE" build/windows_gate/beansc.exe run examples/hello.b \
        > build/windows_gate/beansc.hello.out 2>&1
    grep -q "hello from beans" build/windows_gate/beansc.hello.out ||
        fail "beansc.exe under wine cannot interpret hello.b: $(cat build/windows_gate/beansc.hello.out | head -2)"
    "$WINE" build/windows_gate/beansc.exe target $TRIPLE \
        > build/windows_gate/beansc.target.out 2>&1
    grep -q "^os windows$" build/windows_gate/beansc.target.out ||
        fail "beansc.exe under wine does not report its own target"

    # The interpreter half of the hosted loop, run here rather than only on the
    # real-Windows runner. Two interpreters, one contract: what beansc.exe
    # reports under Wine must be byte-identical to what the Linux beansc
    # reports, panic lines and exit codes included. This is cheap and it is not
    # theoretical — the two bugs it was written for are a panic message that
    # jumped ahead of the program's output (the runtime owns the redirected
    # stdout buffer on Windows, so libc's fflush drained nothing) and extern "C"
    # resolving no libc symbol at all (no Windows call searches every loaded
    # image the way dlsym(RTLD_DEFAULT) does). Both were invisible to the
    # native differential above, which only ever runs the Linux interpreter.
    #
    # Skipped: the machine-fact examples, because beansc.exe answers for the
    # Windows target and the Linux beansc for this host, and the examples whose
    # content is POSIX (a /bin path, a signal, an RDHUP) rather than Beans.
    #
    # ffi.b and the encoding examples are skipped for a different and narrower
    # reason: their interpreter paths compile native C/C++ helpers. Wine has no
    # Windows clang to run, so those paths are unreachable here — not broken,
    # unreachable. The real-Windows hosted gate has a toolchain and keeps these
    # cases with no exemption.
    interp_skip="target_info.b cpu_dispatch.b intrinsics.b poller.b processes.b \
child_process.b signals.b net.b threads.b ffi.b zero_copy_json.b \
zero_copy_xml.b"
    hosted_ran=0
    for src in examples/*.b; do
        name=$(basename "$src")
        [[ " $interp_skip " == *" $name "* ]] && continue
        "$BEANSC" check --target $TRIPLE "$src" > /dev/null 2>&1 || continue
        stem=${name%.b}
        "$BEANSC" run "$src" > "build/windows_gate/$stem.hostinterp" 2>&1
        host_code=$?
        "$WINE" build/windows_gate/beansc.exe run "$src" \
            > "build/windows_gate/$stem.wineinterp" 2>&1
        wine_code=$?
        hosted_ran=$((hosted_ran + 1))
        if [[ $host_code -ne $wine_code ]]; then
            fail "beansc.exe interpreting $name exits $wine_code, the host beansc exits $host_code"
        fi
        if ! cmp -s "build/windows_gate/$stem.hostinterp" "build/windows_gate/$stem.wineinterp"; then
            fail "beansc.exe interpreting $name differs from the host interpreter:"
            diff "build/windows_gate/$stem.hostinterp" "build/windows_gate/$stem.wineinterp" \
                | head -8 >&2
        fi
    done
    if [[ $hosted_ran -lt 30 ]]; then
        fail "only $hosted_ran examples went through beansc.exe's interpreter"
    fi
    echo "  beansc.exe interpreted $hosted_ran examples identically to the host compiler"
else
    fail "the compiler does not cross-compile to $TRIPLE:"
    tail -3 build/windows_gate/beansc.buildlog >&2
fi

# The gate is only a claim if it actually exercised something. A wrong glob or
# an over-eager refusal classifier must not read as green.
if [[ $ran -lt 30 ]]; then
    fail "only $ran examples ran under wine; the discovery loop is broken"
fi

# ---- differential fuzz corpus: oracle-checked execution under wine ----------
# The same fixed corpus the Linux qemu gates run (seed 42, cases 0..5, byte
# identical on every OS): generated programs whose expected output comes from
# the generator's independent oracle, so wine execution is compared against a
# lane no compiler produced.
if command -v python3 >/dev/null 2>&1; then
    corpus=build/windows_gate/dfuzz-corpus
    rm -rf "$corpus"
    if python3 tools/differential_fuzz.py --corpus "$corpus" \
            --seed 42 --cases 6 >/dev/null 2>&1; then
        for src in "$corpus"/case_*.b; do
            cname=$(basename "$src" .b)
            if ! "$BEANSC" build --target $TRIPLE --linker lld "$src" \
                    -o "$corpus/$cname.exe" > "$corpus/$cname.buildlog" 2>&1; then
                fail "differential corpus $cname does not build for $TRIPLE"
                continue
            fi
            "$WINE" "$corpus/$cname.exe" > "$corpus/$cname.out" 2> "$corpus/$cname.err"
            corpus_code=$?
            want_exit=$(cat "$corpus/$cname.exit")
            if [[ $corpus_code -ne $want_exit ]]; then
                fail "differential corpus $cname: wine exit $corpus_code, oracle exit $want_exit"
            elif ! cmp -s "$corpus/$cname.stdout" "$corpus/$cname.out"; then
                fail "differential corpus $cname: wine output differs from the oracle"
                diff "$corpus/$cname.stdout" "$corpus/$cname.out" | head -8 >&2
            elif [[ -s "$corpus/$cname.err" ]]; then
                fail "differential corpus $cname: unexpected stderr under wine"
            fi
        done
        echo "differential corpus: 6 oracle-checked programs executed under wine"
    else
        fail "differential corpus generation failed"
    fi

    # classes,packages corpus: dispatch, super, ARC drop order, and
    # multi-package projects run under wine against the same oracle.
    corpus2=build/windows_gate/dfuzz-corpus-classes
    rm -rf "$corpus2"
    if python3 tools/differential_fuzz.py --corpus "$corpus2" \
            --seed 47 --cases 6 --groups classes,packages >/dev/null 2>&1; then
        while read -r cname; do
            # Generated file, so .gitattributes cannot pin its endings, and
            # `read -r` keeps a carriage return.
            cname=${cname%$'\r'}
            [[ -n "$cname" ]] || continue
            if [[ -f "$corpus2/$cname.b" ]]; then
                csrc="$corpus2/$cname.b"
                cwant_out="$corpus2/$cname.stdout"
                cwant_exit_file="$corpus2/$cname.exit"
            else
                csrc="$corpus2/$cname/main.b"
                cwant_out="$corpus2/$cname/expected_stdout.txt"
                cwant_exit_file="$corpus2/$cname/expected_exit.txt"
            fi
            if ! "$BEANSC" build --target $TRIPLE --linker lld "$csrc" \
                    -o "$corpus2/$cname.exe" > "$corpus2/$cname.buildlog" 2>&1; then
                fail "classes corpus $cname does not build for $TRIPLE"
                continue
            fi
            "$WINE" "$corpus2/$cname.exe" > "$corpus2/$cname.out" 2> "$corpus2/$cname.err"
            corpus_code=$?
            want_exit=$(cat "$cwant_exit_file")
            if [[ $corpus_code -ne $want_exit ]]; then
                fail "classes corpus $cname: wine exit $corpus_code, oracle exit $want_exit"
            elif ! cmp -s "$cwant_out" "$corpus2/$cname.out"; then
                fail "classes corpus $cname: wine output differs from the oracle"
                diff "$cwant_out" "$corpus2/$cname.out" | head -8 >&2
            elif [[ -s "$corpus2/$cname.err" ]]; then
                fail "classes corpus $cname: unexpected stderr under wine"
            fi
        done < "$corpus2/MANIFEST"
        echo "classes,packages corpus: 6 oracle-checked programs executed under wine"
    else
        fail "classes,packages corpus generation failed"
    fi
else
    echo "differential corpus skipped: python3 is not installed" >&2
fi

echo "windows gate: $ran examples byte-identical under wine, $refused refused by capability:"
printf '  %s\n' "${refused_names[@]}"

if [[ $fails -ne 0 ]]; then
    echo "windows gate: $fails failure(s)" >&2
    exit 1
fi
echo "ok windows gate ($TRIPLE, MinGW + Wine)"
