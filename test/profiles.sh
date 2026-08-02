#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-profiles.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "checking the profiles are refused and accepted by name"
if ./build/beansc build --runtime bogus examples/hello.b >"$tmp/err" 2>&1; then
    echo "an unknown profile was accepted" >&2
    exit 1
fi
grep -qF "unknown --runtime 'bogus'" "$tmp/err"
grep -qF "full, minimal, freestanding" "$tmp/err"
# The default is full, and it must stay behaviour-preserving.
./build/beansc build examples/hello.b -o "$tmp/full" >/dev/null 2>&1
./build/beansc build --runtime full examples/hello.b -o "$tmp/full_explicit" >/dev/null 2>&1
diff <("$tmp/full") <("$tmp/full_explicit")

echo "checking minimal builds, runs, and is smaller"
./build/beansc build --runtime minimal examples/hello.b -o "$tmp/min" >/dev/null 2>&1
diff <("$tmp/full") <("$tmp/min")
full_size=$(wc -c <"$tmp/full" | tr -d ' ')
min_size=$(wc -c <"$tmp/min" | tr -d ' ')
if [[ "$min_size" -ge "$full_size" ]]; then
    echo "the minimal binary ($min_size) is not smaller than the full one ($full_size)" >&2
    exit 1
fi

echo "checking the profile decides what the runtime contains"
# Compiling the runtime at each level and counting what it still needs from outside is
# the direct measurement. A profile that dropped nothing would show the same count.
for level in 3 2 1; do
    clang -std=c11 -O2 -DBEANS_RT_PROFILE=$level -c runtime/beans_rt.c \
        -o "$tmp/rt$level.o" 2>"$tmp/rt$level.log" || {
        echo "the runtime does not compile at profile $level" >&2
        cat "$tmp/rt$level.log" >&2
        exit 1
    }
done
full_obj=$(wc -c <"$tmp/rt3.o" | tr -d ' ')
min_obj=$(wc -c <"$tmp/rt2.o" | tr -d ' ')
free_obj=$(wc -c <"$tmp/rt1.o" | tr -d ' ')
if [[ "$min_obj" -ge "$full_obj" || "$free_obj" -ge "$min_obj" ]]; then
    echo "the profiles are not strictly smaller: $full_obj / $min_obj / $free_obj" >&2
    exit 1
fi
echo "  (runtime object: full $full_obj, minimal $min_obj, freestanding $free_obj bytes)"

echo "checking minimal really has no filesystem, sockets or processes"
# The symbols themselves, because "smaller" alone would also be true of a profile that
# merely dropped a comment.
#
# Each object's symbols are dumped **once into a file** and matched from there, never
# piped into `grep -q`. That is not a style preference: `grep -q` exits at the first
# match, GNU nm then dies on EPIPE, and `set -o pipefail` turns the whole pipeline into
# a failure even though the symbol was found. It is deterministic on Linux and
# intermittent on macOS, which is what made it look for a long time like a flaky
# compiler — see ROADMAP 8.4.
for level in 1 2 3; do
    nm "$tmp/rt$level.o" >"$tmp/sym$level" || {
        echo "nm failed on the profile-$level object" >&2
        exit 1
    }
    nm -u "$tmp/rt$level.o" >"$tmp/undef$level" || {
        echo "nm -u failed on the profile-$level object" >&2
        exit 1
    }
done
# A leading underscore on Mach-O, none on ELF, so every pattern allows either.
defines() { grep -q " T _\?$2\$" "$tmp/sym$1"; }
requires() { grep -q "_\?$2\$" "$tmp/undef$1"; }

for gone in beans_file_open beans_dir_list beans_mmap_open beans_net_listen \
            beans_poll_open beans_proc_run beans_signal_watch beans_dl_open \
            beans_shm_open; do
    if defines 2 "$gone"; then
        echo "minimal still defines $gone" >&2
        exit 1
    fi
    # And full must still have it, or this test would pass on an empty runtime.
    defines 3 "$gone" || {
        echo "full is missing $gone, so the check above proves nothing" >&2
        exit 1
    }
done
# What minimal keeps: allocation, the collector, containers, printing, clocks, threads.
for kept in beans_alloc beans_retain beans_release beans_println beans_list_new \
            beans_map_new beans_time_monotonic_nanos beans_thread_spawn; do
    defines 2 "$kept" || {
        echo "minimal dropped $kept, which it needs" >&2
        exit 1
    }
done
# Freestanding drops threads and the clocks too.
for gone in beans_thread_spawn beans_time_monotonic_nanos beans_random_bytes \
            beans_os_env beans_cpu_has; do
    if defines 1 "$gone"; then
        echo "freestanding still defines $gone" >&2
        exit 1
    fi
done
# But it keeps the core, including somewhere to put bytes.
for kept in beans_alloc beans_release beans_println beans_eprintln beans_list_new \
            beans_map_new beans_decv_add; do
    defines 1 "$kept" || {
        echo "freestanding dropped $kept, which is core" >&2
        exit 1
    }
done

echo "checking a capability is refused by name, at check time"
# Dead-code stripping would give an undefined symbol at link time, which says nothing
# about what the caller did wrong. Naming the capability and the profile is the point.
expect_refusal() {
    local profile=$1 source=$2 wanted=$3
    if ./build/beansc check --runtime "$profile" "$source" >"$tmp/refuse" 2>&1; then
        echo "$source was accepted under --runtime $profile" >&2
        exit 1
    fi
    if ! grep -qF -- "$wanted" "$tmp/refuse"; then
        echo "$source under $profile did not report \"$wanted\"" >&2
        sed -n '1,10p' "$tmp/refuse" >&2
        exit 1
    fi
    # One capability, one error — not one per file that happens to import it.
    local count
    count=$(grep -c "does not have" "$tmp/refuse" || true)
    if [[ "$count" -ne 1 ]]; then
        echo "$source under $profile reported the same refusal $count times" >&2
        cat "$tmp/refuse" >&2
        exit 1
    fi
}
expect_refusal minimal test/cases/profile_sockets.b \
    "'std.net' needs sockets, which the minimal runtime does not have"
expect_refusal minimal test/cases/profile_filesystem.b \
    "'std.fs' needs the filesystem, which the minimal runtime does not have"
expect_refusal minimal test/cases/profile_processes.b \
    "'std.process' needs processes, which the minimal runtime does not have"
expect_refusal freestanding test/cases/profile_clocks.b \
    "'std.time' needs clocks, which the freestanding runtime does not have"
expect_refusal freestanding test/cases/profile_threads.b \
    "'std.thread' needs threads, which the freestanding runtime does not have"

echo "checking the blame lands on the caller's own import"
# stdlib/std/net importing std.sock is an implementation detail. Blaming that line would
# point at a file the caller never opened, and it is what the first attempt did.
./build/beansc check --runtime minimal test/cases/profile_sockets.b >"$tmp/blame" 2>&1 || true
if grep -q 'stdlib/std' "$tmp/blame"; then
    echo "the refusal blamed a shipped package instead of the caller" >&2
    cat "$tmp/blame" >&2
    exit 1
fi
grep -q 'profile_sockets.b' "$tmp/blame"
# And it names the package the caller wrote, not the low-level module.
if grep -q "std.sock" "$tmp/blame"; then
    echo "the refusal named std.sock, which the caller never mentioned" >&2
    exit 1
fi

echo "checking what each profile still allows"
# The other half: a program that stays inside a profile must be accepted, or the gate
# would be indistinguishable from refusing everything.
./build/beansc check --runtime minimal test/cases/profile_clocks.b >/dev/null
./build/beansc check --runtime freestanding examples/hello.b >/dev/null
./build/beansc check --runtime freestanding test/cases/profile_core_only.b >/dev/null
./build/beansc build --runtime minimal test/cases/profile_clocks.b \
    -o "$tmp/clocks" >/dev/null 2>&1
"$tmp/clocks" >/dev/null

echo "checking the freestanding runtime needs no libc service"
# What "freestanding" has to mean, measured rather than asserted: the object may need
# compiler primitives — memcpy and friends, and the 128-bit helpers the decimal type uses
# — because every freestanding toolchain provides those. It must need no libc *service*:
# no allocator, no stdio, no exit, no threads, no environment, no snprintf.
#
# Mach-O prefixes every symbol with an underscore and ELF does not, and GNU nm prints
# "U name" where Apple's prints just the name. Both are normalized to a bare name here,
# because the previous form matched Mach-O spellings only — which meant that on Linux
# *nothing* matched the allowlist and this check could never have passed there.
leftovers=$(nm -u "$tmp/rt1.o" | awk '{ print $NF }' | sed 's/^_*//' | sort -u |
            grep -v '^beans_' || true)
# The 128-bit helpers decimal needs, the memory primitives a compiler open-codes calls
# to, the stack-protector hooks, and arm64's outline atomics — all compiler builtins,
# all supplied by any freestanding toolchain.
allowed='^(divti3|modti3|udivti3|umodti3|multi3|floattidf|floatuntidf)$'
allowed="$allowed"'|^(bzero|bcmp|memchr|memcmp|memcpy|memmove|memset|strlen)$'
allowed="$allowed"'|^(chkstk_darwin|stack_chk_fail|stack_chk_guard|memcpy_chk)$'
allowed="$allowed"'|^aarch64_(ldadd|ldclr|ldeor|ldset|swp|cas)[0-9]*(_relax|_acq|_rel|_acq_rel)?$'
if echo "$leftovers" | grep -vE "$allowed" | grep -q .; then
    echo "the freestanding runtime still needs libc services:" >&2
    echo "$leftovers" | grep -vE "$allowed" >&2
    exit 1
fi
# And the hooks it replaced them with are the documented five.
for hook in beans_host_alloc beans_host_realloc beans_host_free beans_host_write \
            beans_host_exit; do
    requires 1 "$hook" || {
        echo "the freestanding runtime does not call $hook" >&2
        exit 1
    }
done
# Hosted profiles must not require them: the weak defaults are there, so nothing to link.
# The pattern allows either symbol spelling. It used to demand a leading underscore,
# which meant the check could never fire on ELF — it passed on Linux for the wrong
# reason.
if requires 3 beans_host_alloc; then
    echo "the full profile requires a hook it should default" >&2
    exit 1
fi

echo "checking the profile enters the runtime cache key"
# Without this a minimal object would be silently reused for a full link, which is the
# same class of bug the target triple already fixed in the key.
rm -f build/beans_rt.*.o
./build/beansc build examples/hello.b -o "$tmp/k1" >/dev/null 2>&1
./build/beansc build --runtime minimal examples/hello.b -o "$tmp/k2" >/dev/null 2>&1
objects=$(ls build/beans_rt.*.o 2>/dev/null | wc -l | tr -d ' ')
if [[ "$objects" -lt 2 ]]; then
    echo "the two profiles shared one cached runtime object" >&2
    exit 1
fi

echo "checking the compiler and the runtime agree about the levels"
# One table, two readers. If the numbers drift, the failure is a link error naming a
# mangled symbol rather than anything about capabilities.
grep -q 'freestanding = 1' compiler/bootstrap/runtime_profile.h
grep -q 'minimal = 2' compiler/bootstrap/runtime_profile.h
grep -q 'full = 3' compiler/bootstrap/runtime_profile.h
grep -q '#define BEANS_RT_FREESTANDING 1' runtime/beans_rt.c
grep -q '#define BEANS_RT_MINIMAL 2' runtime/beans_rt.c
grep -q '#define BEANS_RT_FULL 3' runtime/beans_rt.c
# Every capability in the table names a real module or package.
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    case "$path" in
        std.io|std.fmt|std.os|std.target|std.intrinsic|std.cpu|std.thread) continue ;;
        # Handled in the checker like std.intrinsic, and backed by a table rather
        # than a runtime symbol: there is nothing to link, the assembly is the code.
        std.asm) continue ;;
    esac
    module_path=${path#std.}
    if [[ ! -d "stdlib/std/$module_path" ]] && ! grep -q "\"$path\"" compiler/bootstrap/builtins.cpp; then
        echo "the capability table names '$path', which is neither a shipped package" \
             "nor a native module" >&2
        exit 1
    fi
done < <(grep -oE '"std\.[a-z]+"' compiler/bootstrap/runtime_profile.h | tr -d '"' | sort -u)

echo "ok runtime profiles: named capabilities, refused at check time, smaller runtimes"
