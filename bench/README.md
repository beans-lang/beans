# Benchmarks

Run these commands from the repository root after building the compiler.

```bash
make bench-verify
make bench-quick
make bench-full BENCH_RUN=baseline
```

- `bench-verify` builds every workload and checks its output against fixed
  checksums and the C++ references. It checks correctness, not speed.
- `bench-quick` runs a smaller timing suite for use during development. Its
  results do not meet the requirements for a published performance claim.
- `bench-full` runs the full timing suite. A run must also pass the checks below
  before its results can support a performance claim.

Named runs write their reports and raw JSON under `build/bench/`. Timed runs
without a name write their report to `bench/report.md`.

## What the suite measures

The harness compares Beans with two C++ implementations: one tuned for C++ and
one using ownership rules like Beans. Beans runs with reference counting and
cycle collection enabled.

The suite uses runtime inputs, fixed checksums, randomized run order, separate
cold-start measurements, process CPU time, peak memory, and raw timing samples.
Full mode uses ten timing batches and at least ten measured seconds per target.
If a row has more than 3% variation, the runner repeats all three scored targets
with longer batches. It keeps discarded attempts in the JSON and does not relax
the variation limit.

The workload list is in [suite.tsv](suite.tsv). The suite hash covers workload
sources, shared C++ workload headers, and that manifest. The harness and
[policy](policy.tsv) have separate hashes.

`kv_store` measures the append, restart, and compact algorithm in memory. File
and mmap tests belong in the systems report, so storage hardware does not affect
the compiler score. The C++ cycle baselines explicitly break their test cycles
because C++ has no cycle collector; reports keep that difference visible.

## Publishing results

Beans does not yet have a current performance result that meets the publication
requirements on both required machines: native GNU Linux x86-64 and macOS ARM64.
Older development results do not establish release performance.

A result needs a clean working tree and must pass every timing and memory limit
in [policy.tsv](policy.tsv). These include a 3% variation limit and separate
workload, group, overall, and memory limits against both C++ baselines.
Emulated runs cannot support a performance claim.

For a performance change, collect two full runs on the same machine:

```bash
make bench-full BENCH_RUN=before
# Make the change, then run the full correctness suite.
make test
make bench-full BENCH_RUN=after
```

Compare each workload's Beans time with its own earlier time. Keep the suite,
policy, machine, compiler flags, inputs, outputs, and workload set the same.
Check group and overall results against tuned C++, and check memory as well as
speed. A change in the C++ reference time should not hide a Beans regression.

## Other checks

```bash
make bench-profile NAME=trees
make bench-compiler
make bench-abstractions-quick
make bench-abstractions
make access-score
```

`bench-profile` profiles one workload. `bench-compiler` measures compiler work.
The [abstraction suite](abstractions/README.md) compares paired Beans programs.

`access-score` runs the tests listed in
[the systems-access scorecard](../test/access_scorecard.tsv). Planned features
score zero until their tests pass.
