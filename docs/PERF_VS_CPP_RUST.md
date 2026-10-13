# Beans vs C++ and Rust

Date: 2026-10-13. Source: the "beans vs Rust vs C++" dashboard (beansc 0.1.53,
Apple M4, Apple clang 21.0.0, rustc 1.96.0), reproduced and investigated
locally, then fixed in beansc 0.1.54.

## Answer

Every gap on the dashboard had a cause in the compiler. Beans 0.1.54 closes
five of them. Release builds of hash, fib, collatz, sieve and matmul now run
level with C++, and so do the debug builds of hash and collatz, where Beans
now beats C++ on collatz. In plain release builds Rust is within 1–6% of C++
on every workload, so C++ parity there is also Rust parity.

Three gaps remain: debug matmul, the last few percent of sieve, and Rust's
LTO fib. See [What is left](#what-is-left).

## Results

Kernel time in ms on an Apple M4, best of 7 runs, timed inside each program
around the kernel only. "0.1.53" is beansc before these changes (main at
c59867f); "0.1.54" is with them.

| Case | C++ | 0.1.53 | 0.1.54 |
|---|---|---|---|
| sieve, release | 320–333 | 502 | 333 |
| matmul, release | 16 | 54 | 16 |
| fib, release + LTO | 176 | 202 | 179 |
| hash, debug | 781 | 1090 | 787 |
| collatz, debug | 457 | 500 | 340 |
| matmul, debug | 317–330 | 485 | 448 |

Release hash, fib and collatz were already level with C++ and did not change.

`count` was never slow code. In release, every compiler replaces the
counting loop with its answer, so the dashboard timed the clock. Beans showed
1.0 µs because `monotonic_nanos()` had 1 µs resolution on macOS (#220). #221
fixed that, and fiber sleeps now use the same clock, so Beans resolves about
42 ns, like C++ and Rust.

## What changed

### Bounds checks leave counted loops

Each checked index was a second exit from the loop, to a panic. LLVM's
vectorizer and unroller give up on loops like that. C++ has no checks, and
Rust avoids them with slices and iterators.

`analyze_bounds_guards` in `src/mir.b` now finds counted loops:

- the loop condition is `counter < limit`, and `limit` does not change in the
  loop;
- the counter steps once per turn, at the end, by an amount that does not
  change in the loop;
- every index is `base + counter`, `base` does not change, and the list or
  `Bytes` value is not reassigned in the loop;
- the body does only scalar work, element reads and writes, `len`, `get` and
  `get(i).or(default)`.

Before such a loop runs, one test checks the whole index range: the start is
not negative, the step is positive, the counter cannot wrap, and every
`base + counter` stays inside each list's length. When the test passes, the
loop's checks become constant true and LLVM deletes them. The counter's add
also gets `nsw`, so LLVM can compute the trip count. When the test fails, every
check runs as before: a loop that walks off the end panics at the same index,
with the same message, after the same stores. That matters because `contained`
can catch the panic. `test/cases/parity/bounds_guard.b` pins these edges under
the interpreter, debug and release builds.

The test also loads each list's length and data pointer once before the loop.
That removes the other matmul problem: an element store could, as far as LLVM
knew, change any list's header, so read-only lists reloaded their headers on
every turn.

### `Bytes` element reads and writes are inlined

`bytes[i]`, `bytes[i] = v` and `bytes.set(i, v)` called the runtime. The
runtime is a separate compile unit, so nothing inlined it without LTO. They
now emit a length check and a byte load or store. The out-of-range path still
calls the runtime, so the panic is unchanged.

### Literal divisors skip the divide checks

`x % 1000000007` and `x / 2` always emitted the divide-by-zero and
`MIN / -1` checks. Release builds fold them away; debug builds ran them every
time. A literal divisor other than `0` and `-1` now emits just the divide.

### arm64 functions are aligned to 16 bytes

Under LTO, Beans functions lost the 16-byte alignment that a normal release
build gives them. fib's machine code was identical in both builds, but under
LTO it started at a worse address and ran 25% slower. Function definitions
for arm64 targets now carry `align 16`.

## What is left

- **Debug matmul**, 448 vs about 320 ms. The guards remove the checks in debug
  builds too, but the rest of the gap is not explained. Loading elements as
  `double` instead of `i64` plus a bitcast was tried and made no difference
  at `-O0`.
- **Sieve**, about 3% behind C++ in some runs. The outer loop's step is the
  prime, and the inner loop starts at its square, so each prime pays one
  range test. C++ pays nothing.
- **Negative literal divisors.** `x / -7` lowers as `x / (0 - 7)`, so it
  keeps the run-time checks. Debug builds only.
- **Rust LTO fib** is 6% faster than C++ LTO fib (172 vs 182 ms on the
  dashboard). Beans now matches C++ there, so it still trails Rust. The cause
  is not known. Given the alignment fix, code placement is the first thing to
  check.
- The runtime is still compiled at `-O0` in debug builds. Building it at
  `-O2` helped debug sieve before `Bytes` access was inlined, but made no
  difference after, so it was left out.

## Not verified

- The dashboard's programs were not available. The five workloads were
  written from their descriptions, in Beans and C++. Local ratios match the
  dashboard for release builds. Debug C++ numbers differ, likely because the
  dashboard's sieve uses `std::vector<bool>` or nested vectors.
- Rust is not installed on this machine. Rust figures come from the dashboard.
- For part of the work this machine shared its CPU with a busy virtual
  machine. The table uses runs taken while it was quiet. A sweep under load
  moved even the C++ times by up to 3×, so only ratios from the same run are
  comparable.
- Measured on Apple M4 only. The guards and divide changes are
  target-independent; the alignment change applies to arm64 only.
