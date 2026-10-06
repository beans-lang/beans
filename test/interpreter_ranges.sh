#!/usr/bin/env bash
# Ranges produce their next element only when the body needs it. The enormous
# ranges below cannot be materialized; each exits after its first element.
set -euo pipefail

cd "$(dirname "$0")/.."
beansc=${BEANSC:-./build/beansc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/beans-interpreter-ranges.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# This is a hang/allocation guard, not a timing benchmark. A broken eager
# interpreter would exhaust memory long before the range ended, so watch RSS
# as well as the deadline. Windows uses its process-memory API; macOS/Linux ps
# reports KiB. A missing memory guard is an error, never an unbounded run.
bounded() {
    python3 - "$@" <<'PY'
import shutil
import subprocess
import sys
import time

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    class ProcessMemoryCounters(ctypes.Structure):
        _fields_ = [
            ("cb", wintypes.DWORD),
            ("PageFaultCount", wintypes.DWORD),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    memory = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    memory.GetProcessMemoryInfo.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(ProcessMemoryCounters), wintypes.DWORD]
    memory.GetProcessMemoryInfo.restype = wintypes.BOOL

    def resident_bytes(pid):
        # PROCESS_QUERY_INFORMATION | PROCESS_VM_READ for our own child.
        handle = kernel.OpenProcess(0x0400 | 0x0010, False, pid)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            counters = ProcessMemoryCounters()
            counters.cb = ctypes.sizeof(counters)
            if not memory.GetProcessMemoryInfo(
                    handle, ctypes.byref(counters), counters.cb):
                raise ctypes.WinError(ctypes.get_last_error())
            return counters.WorkingSetSize
        finally:
            kernel.CloseHandle(handle)

elif sys.platform in ("darwin", "linux"):
    ps = shutil.which("ps")
    if ps is None:
        sys.exit("range memory guard requires ps on macOS/Linux")

    def resident_bytes(pid):
        usage = subprocess.run(
            [ps, "-o", "rss=", "-p", str(pid)],
            capture_output=True, text=True, check=True, timeout=5)
        return int(usage.stdout.strip()) * 1024

else:
    sys.exit(f"range memory guard does not support {sys.platform}")

process = subprocess.Popen(sys.argv[1:])
deadline = time.monotonic() + 30
try:
    while True:
        try:
            status = process.wait(timeout=0.05)
            sys.exit(status if status >= 0 else 128 - status)
        except subprocess.TimeoutExpired:
            pass
        if time.monotonic() >= deadline:
            sys.exit("range execution did not stop within 30 seconds")
        try:
            resident = resident_bytes(process.pid)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if process.poll() is not None:
                continue
            sys.exit(f"range memory guard could not read process memory: {error}")
        if resident > 512 * 1024 * 1024:
            sys.exit("range execution exceeded 512 MiB; possible eager expansion")
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
PY
}

for case in interpreter_ranges interpreter_ranges_lazy; do
    bounded "$beansc" run "test/cases/$case.b" >"$tmp/$case.interp"
    "$beansc" build "test/cases/$case.b" -o "$tmp/$case.native" \
        >"$tmp/$case.build" 2>&1
    bounded "$tmp/$case.native" >"$tmp/$case.native.out"
    diff -u "test/cases/$case.out" "$tmp/$case.interp"
    diff -u "test/cases/$case.out" "$tmp/$case.native.out"
done

# A panic in the last statement of the first turn must stop immediately too.
# Otherwise the shared iteration helper can swallow the stopped execution and
# walk the rest of a lazy range even though no subsequent body may execute.
interp_status=0
bounded "$beansc" run test/cases/interpreter_ranges_panic.b \
    >"$tmp/panic.interp" 2>&1 || interp_status=$?
"$beansc" build test/cases/interpreter_ranges_panic.b -o "$tmp/panic.native" \
    >"$tmp/panic.build" 2>&1
native_status=0
bounded "$tmp/panic.native" >"$tmp/panic.native.out" 2>&1 || native_status=$?
diff -u "$tmp/panic.interp" "$tmp/panic.native.out"
test "$interp_status" -eq 3
test "$native_status" -eq 3
grep -q 'runtime panic.*index' "$tmp/panic.interp"
if grep -q survived "$tmp/panic.interp"; then
    echo "range execution continued after panic" >&2
    exit 1
fi

echo "range iteration: bounds, captures, cleanup, lazy exits and panic agree"
