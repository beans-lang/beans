# VERSION is the one source of the compiler, language and runtime-ABI versions.
# tools/gen_version_b.sh copies those numbers into src/version.b, which is what
# the compiler itself reads.

BIN := build/beansc

ifeq ($(OS),Windows_NT)
BIN := build/beansc.exe
endif
SELF_HOST_SRC := $(wildcard src/*.b) src/beans.pot
RUNTIME_SRC := runtime/beans_rt.c
RUNTIME_COPY := build/beans_rt.c
.DEFAULT_GOAL := $(BIN)

$(RUNTIME_COPY): $(RUNTIME_SRC) runtime/beans_fiber.c runtime/beans_fiber.h
	@mkdir -p build
	cp runtime/beans_fiber.c runtime/beans_fiber.h build/
	cp $(RUNTIME_SRC) $(RUNTIME_COPY)

# The compiler cannot read VERSION while compiling itself, so it reads the same
# numbers out of a generated source. Committed, not gitignored.
# test/version.sh refuses a stale copy.
src/version.b: VERSION tools/gen_version_b.sh
	tools/gen_version_b.sh $@

# The compiler is built the way a self-hosted language is normally built once it
# has shipped: with a released copy of itself. Install one with the one-line
# installer, or point BEANSC_BOOT at any working beansc.
#
# --release, always. A plain `beansc build` runs no optimizer, which is right
# for the program you are iterating on and wrong for the compiler that builds
# it: an unoptimized beansc makes every build anyone runs with it slower.
BEANSC_BOOT ?= $(shell command -v beansc 2>/dev/null || \
	ls "$${BEANS_HOME:-$$HOME/.beans}/bin/beansc" 2>/dev/null)

$(BIN): $(SELF_HOST_SRC) $(RUNTIME_COPY)
	@mkdir -p build
	@test -n "$(BEANSC_BOOT)" || { \
	  echo "no Beans compiler found to build with."; \
	  echo ""; \
	  echo "Beans is self-hosted, so building it needs a Beans compiler."; \
	  echo "Install a released one and build with that:"; \
	  echo ""; \
	  echo "  curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh"; \
	  echo ""; \
	  echo "or point BEANSC_BOOT at an existing one:"; \
	  echo ""; \
	  echo "  make BEANSC_BOOT=/path/to/beansc"; \
	  echo ""; \
	  exit 1; \
	}
	@$(BEANSC_BOOT) check tools/bootstrap_probe.b >/dev/null 2>&1 || { \
	  echo "the compiler at $(BEANSC_BOOT) is too old to build these sources."; \
	  echo ""; \
	  echo "src/ uses 'partial class', which that compiler does not have."; \
	  echo "A self-hosted compiler can only adopt a feature its bootstrap"; \
	  echo "already supports, so build once with a compiler that has it and"; \
	  echo "install the result:"; \
	  echo ""; \
	  echo "  make BEANSC_BOOT=/path/to/newer/beansc && make install"; \
	  echo ""; \
	  exit 1; \
	}
# The released launcher exports its package's BEANS_* paths, so an installed
# bootstrap would compile THIS tree's sources against LAST release's runtime
# and stdlib — and the link breaks the first time src needs a runtime symbol
# the release does not have. The launcher honours preset values, so the
# bootstrap pins every source root to the tree it is building.
	BEANS_RUNTIME=runtime/beans_rt.c BEANS_STDLIB=stdlib/std \
	BEANS_ENCODING=runtime/encoding BEANS_NET=runtime/net \
	BEANS_LOG=runtime/log \
	$(BEANSC_BOOT) build --release src/main.b -o $(BIN).new
	rm -f $(BIN) && mv $(BIN).new $(BIN)

.PHONY: run clean install test test-ci fuzz-ownership fuzz-ownership-long test-core test-quick test-frontend test-semantics test-runtime test-ffi test-platform platform-status test-platform-manifest test-compiler-arch-objects test-musl-hosted test-armv6hf-hosted test-release-package test-install-release test-release-completeness test-c-abi-tier1 test-barq-core test-sanitize fuzz-oop fuzz-oop-smoke fuzz-oop-long fuzz-reflection fuzz-reflection-smoke fuzz-net fuzz-net-soak fuzz-differential fuzz-differential-smoke test-fixpoint test-clean-self-host test-linux test-linux-arch test-linux-hosted test-windows test-windows-native test-windows-native-i686 test-windows-native-arm64 test-windows-arch test-windows-hosted test-encoding-targets test-encoding-windows access-score self-host-next test-self-host test-self-host-full bench-compiler bench-quick bench-full bench-verify bench-profile bench-abstractions bench-abstractions-quick
run: $(BIN)
	./$(BIN) parse examples/hello.b examples/tour.b

install: $(BIN)
	PREFIX="$(PREFIX)" DESTDIR="$(DESTDIR)" bash ./tools/install.sh

# The whole gate: every behavioural suite, then the fixed point — the compiler
# rebuilt by itself must be byte-identical to itself. That fixed point is what
# a self-hosted compiler has instead of a second implementation to diff against.
test: test-core test-self-host test-fixpoint

# What CI runs.
test-ci: test

# The five-minute developer gate: the checks that catch almost every compiler
# mistake, cheapest first, so a parity break reports in seconds. This is a
# feedback loop, not the bar — `make test` stays the full suite. Timings are
# from build/test_timing on a dev laptop; the whole chain is under five
# minutes when the compiler is already built.
test-quick: $(BIN)
	./test/parse_recovery.sh
	bash ./test/diagnostics.sh
	bash ./test/package_semantics.sh
	bash ./test/package_identity.sh
	bash ./test/builtin_names.sh
	./test/annotations.sh
	./test/deterministic_build.sh
	bash ./test/unsafe.sh
	./test/differential.sh
	bash ./test/ownership_fuzz.sh smoke
	bash ./test/ci_coverage.sh
	$(MAKE) fuzz-differential-smoke

# Focused slices of the full suite for iterating on one area. Together the
# five slices run exactly the scripts `make test` runs — test/ci_coverage.sh
# fails if they ever drift apart — so a green run of all five plus nothing
# else is the same claim as `make test`.
test-frontend: $(BIN)
	bash ./test/diagnostics.sh
	./test/docs.sh
	./test/version.sh
	bash ./test/syntax_v07.sh
	bash ./test/language_gaps.sh
	bash ./test/crema_findings.sh
	bash ./test/string_literals.sh
	bash ./test/generic_calls.sh
	bash ./test/named_imports.sh
	bash ./test/private_fields.sh
	bash ./test/private_methods.sh
	bash ./test/abstract_classes.sh
	bash ./test/generic_interfaces.sh
	bash ./test/backend_parity.sh
	bash ./test/panic_position_parity.sh
	bash ./test/emitter_gaps.sh
	bash ./test/singleton_classes.sh
	bash ./test/partial_classes.sh
	bash ./test/static_fields.sh
	bash ./test/struct_methods.sh
	bash ./test/oop_fuzz.sh smoke
	bash ./test/reflection_fuzz.sh
	bash ./test/differential_fuzz.sh smoke
	./test/parse_recovery.sh
	./test/lsp_probe.sh
	./test/lsp_server.sh
	./test/lsp_semantic.sh
	./test/lsp_navigation.sh
	./test/dap.sh
	./test/native_debug.sh
	./test/stdlib_source.sh
	bash ./test/api_names.sh
	./test/fs_source.sh
	./test/reader_source.sh
	./test/dependencies.sh
	./test/pot_init.sh
	./test/system_dependencies.sh
	bash ./test/package_semantics.sh
	bash ./test/package_identity.sh
	bash ./test/builtin_names.sh
	./test/annotations.sh

test-semantics: $(BIN)
	./test/differential.sh
	./test/panic.sh
	./test/numerics.sh
	bash ./test/decimal_conformance.sh
	./test/moves.sh
	bash ./test/ownership_fuzz.sh smoke
	bash ./test/borrowed_iteration.sh
	bash ./test/downcast_borrow.sh
	bash ./test/math.sh
	bash ./test/slice_fusion.sh
	bash ./test/list_header_cache.sh
	./test/maps.sh
	bash ./test/map_inline.sh
	./test/traits.sh
	bash ./test/calendar.sh
	bash ./test/collections.sh
	bash ./test/collections_fuzz.sh smoke
	bash ./test/display_width.sh
	bash ./test/derived_render.sh
	bash ./test/module_consts.sh
	./test/fixed_arrays.sh
	bash ./test/closure_captures.sh
	bash ./test/send_functions.sh
	bash ./test/mir.sh
	bash ./test/devirtualize.sh
	bash ./test/default_eval_order.sh
	./test/inline_options.sh
	./test/inline_results.sh
	bash ./test/wide_lists.sh
	bash ./test/wide_maps.sh
	bash ./test/wide_enums.sh
	bash ./test/enum_repr.sh
	bash ./test/wide_owners.sh
	bash ./test/wide_sync.sh
	bash ./test/wide_concurrency.sh
	bash ./test/channel_try.sh
	bash ./test/brew.sh
	bash ./test/fiber_std.sh
	bash ./test/gate.sh
	bash ./test/taskgroup.sh
	bash ./test/fiber_soak.sh
	bash ./test/fiber_net.sh
	./test/self_host.sh
	./test/fixpoint.sh

test-runtime: $(BIN)
	bash ./test/fiber_core.sh
	bash ./test/thread_cleanup.sh
	./test/resources.sh
	./test/shm.sh
	./test/process.sh
	./test/profiles.sh
	./test/atomics.sh
	./test/cpu_features.sh
	./test/clocks_random.sh
	bash ./test/reflect_perf.sh
	./test/net_bridge_api.sh
	./test/log.sh
	./test/net.sh
	./test/poll.sh
	bash ./test/send_builtin_owners.sh
	bash ./test/send_handles.sh
	./test/net_torture.sh
	./test/poll_semantics.sh
	bash ./test/net_fuzz.sh smoke
	./test/http.sh
	./test/llhttp_corpus.sh
	./test/http2.sh
	./test/compress.sh
	./test/tls.sh
	./test/websocket.sh
	./test/signals.sh
	./test/dylib.sh
	./test/child.sh
	bash ./test/encoding.sh
	bash ./test/json_direct.sh
	bash ./test/list_iteration.sh

test-ffi: $(BIN)
	./test/raw_slices.sh
	./test/c_layout_structs.sh
	./test/c_layout_unions.sh
	./test/c_layout_c_abi.sh
	./test/c_wide_args.sh
	./test/c_callbacks.sh
	./test/c_opaque.sh
	./test/c_globals.sh
	./test/link_manifest.sh
	bash ./test/csrc_build.sh
	./test/library_output.sh
	bash ./test/shared_statics.sh
	./test/bindgen.sh
	./test/bindgen_link.sh
	./test/sqlite_system.sh
	./test/stack_pointer.sh
	./test/stored_callbacks.sh
	bash ./test/same_thread_callbacks.sh
	./test/simd.sh
	./test/intrinsics.sh
	./test/packed_layout.sh
	./test/layout_introspect.sh
	bash ./test/unsafe.sh
	bash ./test/runtime_abi.sh
	bash ./test/decimal_align.sh
	./test/object_abi.sh
	bash ./test/encoding_symbols.sh
	bash ./test/encoding_outputs.sh
	bash ./test/encoding_cache.sh

test-platform: $(BIN)
	./test/freestanding.sh
	bash ./test/abi_probe.sh
	./test/wasm_matrix.sh
	./test/wasm.sh
	./test/embedded.sh
	bash ./test/release_completeness.sh --self-test
	./test/deterministic_build.sh
	./test/asm.sh
	./test/targets.sh
	./test/platform_manifest.sh
	bash ./test/compiler_arch_objects.sh

test-core: $(BIN)
	bash ./test/diagnostics.sh
	./test/differential.sh
	./test/panic.sh
	./test/freestanding.sh
	bash ./test/abi_probe.sh
	./test/wasm_matrix.sh
	./test/wasm.sh
	./test/embedded.sh
	./test/docs.sh
	bash ./test/release_completeness.sh --self-test
	./test/version.sh
	./test/deterministic_build.sh
	./test/numerics.sh
	bash ./test/decimal_conformance.sh
	./test/moves.sh
	bash ./test/borrowed_iteration.sh
	bash ./test/list_iteration.sh
	bash ./test/downcast_borrow.sh
	bash ./test/math.sh
	bash ./test/slice_fusion.sh
	bash ./test/list_header_cache.sh
	./test/maps.sh
	bash ./test/map_inline.sh
	./test/traits.sh
	bash ./test/calendar.sh
	bash ./test/collections.sh
	bash ./test/collections_fuzz.sh smoke
	bash ./test/display_width.sh
	bash ./test/derived_render.sh
	bash ./test/module_consts.sh
	bash ./test/syntax_v07.sh
	bash ./test/language_gaps.sh
	bash ./test/crema_findings.sh
	bash ./test/string_literals.sh
	bash ./test/generic_calls.sh
	bash ./test/named_imports.sh
	bash ./test/private_fields.sh
	bash ./test/private_methods.sh
	bash ./test/abstract_classes.sh
	bash ./test/generic_interfaces.sh
	bash ./test/backend_parity.sh
	bash ./test/panic_position_parity.sh
	bash ./test/emitter_gaps.sh
	bash ./test/singleton_classes.sh
	bash ./test/partial_classes.sh
	bash ./test/static_fields.sh
	bash ./test/struct_methods.sh
	bash ./test/oop_fuzz.sh smoke
	bash ./test/reflection_fuzz.sh
	bash ./test/differential_fuzz.sh smoke
	bash ./test/ownership_fuzz.sh smoke
	./test/fixed_arrays.sh
	bash ./test/send_functions.sh
	./test/packed_layout.sh
	bash ./test/fiber_core.sh
	bash ./test/thread_cleanup.sh
	./test/simd.sh
	./test/intrinsics.sh
	./test/resources.sh
	./test/shm.sh
	./test/process.sh
	./test/raw_slices.sh
	./test/c_layout_structs.sh
	./test/c_layout_unions.sh
	./test/c_layout_c_abi.sh
	./test/c_wide_args.sh
	./test/c_callbacks.sh
	./test/c_opaque.sh
	./test/c_globals.sh
	./test/link_manifest.sh
	bash ./test/csrc_build.sh
	./test/library_output.sh
	bash ./test/shared_statics.sh
	./test/bindgen.sh
	./test/bindgen_link.sh
	./test/sqlite_system.sh
	./test/stack_pointer.sh
	./test/stored_callbacks.sh
	bash ./test/same_thread_callbacks.sh
	bash ./test/closure_captures.sh
	./test/stdlib_source.sh
	bash ./test/api_names.sh
	bash ./test/encoding.sh
	bash ./test/json_direct.sh
	bash ./test/encoding_symbols.sh
	bash ./test/encoding_outputs.sh
	bash ./test/encoding_cache.sh
	./test/parse_recovery.sh
	bash ./test/mir.sh
	bash ./test/devirtualize.sh
	bash ./test/default_eval_order.sh
	./test/lsp_probe.sh
	./test/lsp_server.sh
	./test/lsp_semantic.sh
	./test/lsp_navigation.sh
	./test/dap.sh
	./test/native_debug.sh
	./test/fs_source.sh
	./test/reader_source.sh
	./test/pot_init.sh
	./test/system_dependencies.sh
	./test/inline_options.sh
	./test/inline_results.sh
	bash ./test/wide_lists.sh
	bash ./test/wide_maps.sh
	bash ./test/wide_enums.sh
	bash ./test/enum_repr.sh
	bash ./test/wide_owners.sh
	bash ./test/wide_sync.sh
	bash ./test/wide_concurrency.sh
	bash ./test/channel_try.sh
	bash ./test/brew.sh
	bash ./test/fiber_std.sh
	bash ./test/gate.sh
	bash ./test/taskgroup.sh
	bash ./test/fiber_soak.sh
	bash ./test/fiber_net.sh

	./test/profiles.sh
	./test/asm.sh
	./test/dependencies.sh
	./test/layout_introspect.sh
	./test/atomics.sh
	./test/cpu_features.sh
	./test/clocks_random.sh
	bash ./test/reflect_perf.sh
	./test/net_bridge_api.sh
	./test/log.sh
	./test/net.sh
	./test/poll.sh
	bash ./test/send_builtin_owners.sh
	bash ./test/send_handles.sh
	./test/net_torture.sh
	./test/poll_semantics.sh
	bash ./test/net_fuzz.sh smoke
	./test/http.sh
	./test/llhttp_corpus.sh
	./test/http2.sh
	./test/compress.sh
	./test/tls.sh
	./test/websocket.sh
	./test/signals.sh
	./test/dylib.sh
	./test/child.sh

# The gates that used to compare against the C++ stage 0. Each now checks the
# shipped compiler and runtime on their own.
	./test/targets.sh
	./test/platform_manifest.sh
	./test/object_abi.sh
	bash ./test/runtime_abi.sh
	bash ./test/decimal_align.sh
	bash ./test/package_semantics.sh
	bash ./test/package_identity.sh
	bash ./test/unsafe.sh
	bash ./test/builtin_names.sh
	./test/annotations.sh
	bash ./test/compiler_arch_objects.sh


platform-status test-platform-manifest: $(BIN)
	bash ./test/platform_manifest.sh

test-compiler-arch-objects: $(BIN)
	bash ./test/compiler_arch_objects.sh

test-musl-hosted:
	bash ./test/musl_hosted.sh

test-armv6hf-hosted:
	bash ./test/armv6hf_hosted.sh


test-release-package: $(BIN)
	bash ./test/release_package.sh

# The contract the publish job enforces: a release is every target in
# targets/release_assets.tsv, or it is not a release.
test-release-completeness:
	bash ./test/release_completeness.sh --self-test

# Drives tools/install-release.sh end to end against a locally built package:
# same detection, checksum, staging and PATH handling as a real release.
test-install-release: $(BIN)
	bash ./test/install_release.sh

test-c-abi-tier1: $(BIN)
	bash ./test/c_abi_tier1.sh

# Network-heavy real-product integration. Kept out of `make test` and the
# scorecard so local C interop work depends only on the small fixtures.
test-barq-core: $(BIN)
	bash ./test/barq_core.sh

# Memory and thread checking of what this compiler emits: every program is
# built here and then linked against beans_rt.c under AddressSanitizer,
# UndefinedBehaviorSanitizer and ThreadSanitizer, with a `leaks` sweep on
# macOS. Too slow for test-core, and the one place reference counting and the
# cycle collector are checked for real memory errors rather than for output.
test-sanitize: $(BIN)
	bash ./test/sanitize.sh

# This fuzzer exercises self-hosted OOP semantics. The smoke target is also
# part of test-core.
# Ownership fuzzing: what a Mutex may own across a thread boundary, and how
# many live readers a move-only map value may have. Both answers come from a
# type shape, so the shapes are generated and an independent model in
# tools/ownership_fuzz.py answers alongside the compiler.
fuzz-ownership: $(BIN)
	bash ./test/ownership_fuzz.sh run

fuzz-ownership-long: $(BIN)
	bash ./test/ownership_fuzz.sh long

fuzz-oop: $(BIN)
	bash ./test/oop_fuzz.sh run

fuzz-oop-smoke: $(BIN)
	bash ./test/oop_fuzz.sh smoke

fuzz-oop-long: $(BIN)
	bash ./test/oop_fuzz.sh long

# Reflection fuzzing over generated programs: the tree interpreter and the
# native backend must agree, debug and release alike.
fuzz-reflection: $(BIN)
	bash ./test/reflection_fuzz.sh

fuzz-reflection-smoke: $(BIN)
	REFLECT_FUZZ_SEEDS="$${REFLECT_FUZZ_SEEDS:-2}" \
	REFLECT_FUZZ_CASES="$${REFLECT_FUZZ_CASES:-8}" \
		bash ./test/reflection_fuzz.sh

# Socket and poller fuzzing: seeded op sequences over live loopback sockets
# with deterministic failpoint injection (BEANS_SOCK_FAILPOINTS), an fd
# census, and a readiness oracle. `fuzz-net` is a configurable session;
# `fuzz-net-soak` is the wall-clock nightly lane (NET_FUZZ_SECONDS).
fuzz-net: $(BIN)
	bash ./test/net_fuzz.sh run

fuzz-net-soak: $(BIN)
	bash ./test/net_fuzz.sh soak

# Semantic differential fuzzing: generated typed programs whose expected
# output comes from the independent evaluator in tools/differential_fuzz.py,
# compared against the interpreter and against native debug, release and LTO
# builds. Both fuzzers used to need the stage-0 bootstrap to diff against and
# were skipped wherever it was absent; comparing the compiler's own backends
# against a separate oracle needs no second compiler, so they now run
# everywhere. `run` is the configurable session — see the script header.
fuzz-differential: $(BIN)
	bash ./test/differential_fuzz.sh run

fuzz-differential-smoke: $(BIN)
	bash ./test/differential_fuzz.sh smoke

# rm before cp: overwriting a signed binary in place leaves macOS's signature
# cache stale, and the kernel then kills the new binary on exec with SIGKILL
# and no message. A fresh inode never hits the cache.
build/beansc-next: $(BIN)
	rm -f $@ && cp $(BIN) $@

self-host-next: build/beansc-next

# The compiler against itself: every construct it compiles natively must mean
# the same thing when its own tree interpreter runs it. This is a differential
# between the two backends, not a rebuild of the compiler.
test-self-host: $(BIN) build/beansc-next
	bash ./test/self_host.sh

# The fixed point: the compiler must build a compiler identical to itself.
# This is what replaced the stage-0 differential.
test-fixpoint: $(BIN)
	bash ./test/fixpoint.sh

test-clean-self-host: $(BIN)
	bash ./test/clean_self_host.sh

test-self-host-full: $(BIN)
	bash ./test/self_host_full.sh

bench-compiler: $(BIN) build/beansc-next
	bash ./bench/compiler.sh

# The whole gate inside a Linux container. Correctness only — a container on a
# non-matching host is emulated, and the script says so.
test-linux:
	bash ./test/linux_docker.sh $(DOCKER_ARGS)

# Real cross-execution for one Linux architecture: cross-build every eligible
# example, run each under the matching qemu-user, and require byte-identical
# output against the interpreter. Skips with a message when the sysroot or qemu
# is absent, so it is safe to run on a dev machine; the Linux container and CI
# have the tools and run it for real (ARCH defaults to riscv64).
test-linux-arch: $(BIN)
	bash ./test/linux_arch.sh $(or $(ARCH),riscv64)

# The hosted gate: beansc built for the target and run under qemu-user reaches
# its self-compile fixed point and drives the examples byte-identical.
# ARCH defaults to ppc64le.
test-linux-hosted: $(BIN)
	bash ./test/linux_hosted.sh $(or $(ARCH),ppc64le)

# Cross-compile to x86-64 Windows with MinGW-w64 and execute under Wine, in a
# linux/amd64 container that runs test/windows.sh. Wine runs the instructions
# directly, so this is the strongest Windows claim available without a Windows
# machine; the real Windows runner in CI stays the final word.
test-windows:
	bash ./test/windows_docker.sh $(DOCKER_ARGS)

# Stage the real-Windows differential bundle: every eligible example as an
# .exe beside the interpreter's expected output and exit code. CI's
# windows-latest runner executes it with test/windows_native_run.sh; a machine
# with wine can run the same pair locally.
test-windows-native:
	bash ./test/windows_native_stage.sh build/windows_native
	@echo "bundle staged; on Windows (or under wine) run:"
	@echo "  bash test/windows_native_run.sh build/windows_native x86_64"

# The same bundle for the other two Windows architectures. Both need
# LLVM-MinGW: the distro's mingw-w64 has no aarch64 at all.
#
# Which machine can execute which is the whole reason these are separate
# targets. x86-64 and i686 both run on an x64 Windows box (i686 through
# WOW64); an aarch64 bundle needs a Windows-on-ARM machine, which is what CI's
# windows-11-arm runner is for. Staging is cross-compilation and works
# anywhere.
test-windows-native-i686:
	PATH="$$(bash ./test/windows_toolchain.sh):$$PATH" \
	    bash ./test/windows_native_stage.sh --target i686-pc-windows-gnu build/windows_i686
	@echo "bundle staged; on any x64 or ARM64 Windows machine run:"
	@echo "  bash test/windows_native_run.sh build/windows_i686 i686"

test-windows-native-arm64:
	PATH="$$(bash ./test/windows_toolchain.sh):$$PATH" \
	    bash ./test/windows_native_stage.sh --target aarch64-pc-windows-gnu build/windows_arm64
	@echo "bundle staged; on a Windows-on-ARM machine run:"
	@echo "  bash test/windows_native_run.sh build/windows_arm64 aarch64"

# Every Windows architecture staged in one pass, for the machine that is about
# to execute them.
test-windows-arch: test-windows-native test-windows-native-i686 test-windows-native-arm64

# The compiler hosted on Windows: beansc.exe runs its own differential loop
# (test/windows_hosted.sh) on a real Windows machine under Git Bash. CI wires
# it after cross-building beansc.exe; locally it needs a Windows box.
test-windows-hosted:
	bash ./test/windows_hosted.sh

# Cross-target verification for the std.encoding bridges: compiles all three
# for a target, links them with the plain C driver, and runs a C smoke
# program on it. Needs Docker for the container targets, so it is not part of
# `make test`; each unreachable target skips with its reason.
#
#   make test-encoding-targets                 # every reachable target
#   make test-encoding-targets TARGET=big-endian
test-encoding-targets:
	bash ./test/encoding_targets.sh $(or $(TARGET),all)

# The local half of Windows support for std.encoding: every bridge compiles
# with the Windows toolchain and every package cross-builds for all four
# registered Windows ABIs. Execution happens in CI's windows-native job,
# which builds and runs the same cases on real Windows machines. Kept out of
# `make test` because it fetches an LLVM-MinGW toolchain on first use.
test-encoding-windows:
	bash ./test/encoding_windows.sh

access-score: $(BIN)
	bash ./test/access_score.sh

bench-quick: $(BIN)
	./bench/run.sh quick "$(BENCH_RUN)"

bench-full: $(BIN)
	./bench/run.sh full "$(BENCH_RUN)"

bench-verify: $(BIN)
	./bench/run.sh verify "$(BENCH_RUN)"

bench-profile: $(BIN)
	@test -n "$(NAME)" || { echo "usage: make bench-profile NAME=trees"; exit 2; }
	./bench/profile.sh "$(NAME)"

bench-abstractions: $(BIN)
	./bench/abstractions/run.sh full

bench-abstractions-quick: $(BIN)
	./bench/abstractions/run.sh quick

clean:
	rm -rf build
