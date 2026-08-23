# Abstraction proof suite

This suite compares two Beans implementations of the same work. It answers a
different question from `bench/suite.tsv`, which compares Beans with C++.

Each row:

- builds one release/LTO binary containing every variant;
- checks that every variant prints the same result;
- gives every variant an unmeasured warmup;
- reports median wall time;
- reports emitted allocation, retain and release traffic from a separate
  `BEANS_ARC_STATS` build; and
- keeps optimized LLVM under `build/abstractions/` for inspection.

Run a small correctness pass with:

```sh
./bench/abstractions/run.sh verify
```

Use `make bench-abstractions-quick` while developing and
`make bench-abstractions` for the nine-sample proof run. A final zero-cost
claim still requires clean runs on macOS ARM64 and Linux x86-64.
