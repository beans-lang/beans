CXX      := clang++
CXXFLAGS := -std=c++20 -Wall -Wextra -O2 -pthread
# compiler/version.h is the one source of the compiler, language and runtime-ABI
# versions. It lives beside the two compilers rather than inside either, so the
# public tree can read it without the private stage-0 submodule.
CPPFLAGS := -Icompiler
LDLIBS   :=

# The C++ stage 0 lives in a separate private repository, mounted here as a
# submodule. It is bootstrap-only code that is never shipped, and Beans builds
# without it: with the submodule you get the full stage0 -> 1 -> 2 -> 3 chain and
# the differential gates against stage 0; without it, an already-installed
# `beansc` builds the self-hosted compiler from source.
HAVE_BOOTSTRAP := $(wildcard compiler/bootstrap/main.cpp)

# musl has no reliable predefined C/C++ macro. Its dynamic-loader name is the
# native-host fact Make can test without compiling or executing a probe.
ifneq ($(wildcard /lib/ld-musl-*.so.1),)
CPPFLAGS += -DBEANS_HOST_MUSL=1
endif

# ARMv6 and some other 32-bit Linux hosts lower the compiler's 64-bit C++
# atomics to libatomic calls. Programs already get this rule from both Beans
# drivers; the source-bootstrap compiler needs the same rule.
ifeq ($(shell uname -s),Linux)
ifeq ($(shell getconf LONG_BIT 2>/dev/null),32)
LDLIBS += -latomic
endif
endif

SRC := compiler/bootstrap/token.cpp compiler/bootstrap/lexer.cpp compiler/bootstrap/parser.cpp compiler/bootstrap/ast_print.cpp compiler/bootstrap/process.cpp compiler/bootstrap/loader.cpp compiler/bootstrap/target.cpp compiler/bootstrap/mir.cpp compiler/bootstrap/c_abi.cpp compiler/bootstrap/checker.cpp compiler/bootstrap/expand.cpp compiler/bootstrap/builtins.cpp compiler/bootstrap/codegen.cpp compiler/bootstrap/interp.cpp compiler/bootstrap/lsppos.cpp compiler/bootstrap/json.cpp compiler/bootstrap/bindgen.cpp compiler/bootstrap/lsp.cpp compiler/bootstrap/lspserver.cpp compiler/bootstrap/main.cpp
HDR := compiler/bootstrap/token.h compiler/bootstrap/lexer.h compiler/bootstrap/ast.h compiler/bootstrap/parser.h compiler/bootstrap/types.h compiler/bootstrap/process.h compiler/bootstrap/target.h compiler/bootstrap/host_target.h compiler/bootstrap/int128.h compiler/bootstrap/mir.h compiler/bootstrap/hir.h compiler/bootstrap/c_abi.h compiler/bootstrap/loader.h compiler/bootstrap/checker.h compiler/bootstrap/expand.h compiler/bootstrap/value.h compiler/bootstrap/builtins.h compiler/bootstrap/interp.h compiler/bootstrap/codegen.h compiler/bootstrap/lsppos.h compiler/bootstrap/json.h compiler/bootstrap/bindgen.h compiler/bootstrap/lsp.h compiler/bootstrap/rounding.h compiler/version.h
BOOTSTRAP_BIN := build/beansc0
STAGE1_BIN := build/beansc-stage1
STAGE2_BIN := build/beansc-stage2
STAGE3_BIN := build/beansc-stage3
BIN := build/beansc

ifeq ($(OS),Windows_NT)
# The C++ stage 0 uses exceptions but no RTTI. Disabling unused RTTI avoids a
# MinGW static-libstdc++ duplicate type_info definition and makes beansc0.exe a
# single file with no compiler-runtime DLL beside it.
CXXFLAGS += -fno-rtti -static-libgcc -static-libstdc++
BOOTSTRAP_BIN := build/beansc0.exe
STAGE1_BIN := build/beansc-stage1.exe
STAGE2_BIN := build/beansc-stage2.exe
STAGE3_BIN := build/beansc-stage3.exe
BIN := build/beansc.exe
endif
SELF_HOST_SRC := $(wildcard compiler/beans/*.b) compiler/beans/beans.pot
FRONTEND_FUZZ_SRC := $(filter-out compiler/bootstrap/main.cpp,$(SRC))
ifeq ($(shell uname -s),Darwin)
FUZZ_FLAGS := -DBEANS_FUZZ_STANDALONE -fsanitize=address,undefined
else
FUZZ_FLAGS := -fsanitize=fuzzer,address,undefined
endif
RUNTIME_SRC := runtime/beans_rt.c
RUNTIME_COPY := build/beans_rt.c
.DEFAULT_GOAL := $(BIN)

$(RUNTIME_COPY): $(RUNTIME_SRC)
	@mkdir -p build
	cp $(RUNTIME_SRC) $(RUNTIME_COPY)

# The self-hosted half of the compiler cannot include compiler/version.h, so it
# reads the same numbers out of a generated source. Committed, not gitignored:
# the Windows source bootstrap runs stage 0 straight at main.b with no make step
# to generate it first. test/version.sh refuses a stale copy.
compiler/beans/version.b: compiler/version.h tools/gen_version_b.sh
	tools/gen_version_b.sh $@

ifneq ($(HAVE_BOOTSTRAP),)

$(BOOTSTRAP_BIN): $(SRC) $(HDR) $(RUNTIME_COPY)
	@mkdir -p build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(SRC) $(LDLIBS) -o $(BOOTSTRAP_BIN)

$(STAGE1_BIN): $(BOOTSTRAP_BIN) $(SELF_HOST_SRC)
	./$(BOOTSTRAP_BIN) build compiler/beans/main.b -o $@

$(STAGE2_BIN): $(STAGE1_BIN) $(SELF_HOST_SRC)
	./$(STAGE1_BIN) build compiler/beans/main.b -o $@

$(STAGE3_BIN): $(STAGE2_BIN) $(SELF_HOST_SRC)
	./$(STAGE2_BIN) build compiler/beans/main.b -o $@

# rm before cp — see build/beansc-next: a cp over an existing signed binary
# gets SIGKILLed on exec by macOS's stale signature cache.
$(BIN): $(STAGE3_BIN)
	rm -f $(BIN) && cp $(STAGE3_BIN) $(BIN)

else

# No stage 0 here, so the compiler is built the way a self-hosted language is
# normally built once it has shipped: with a released copy of itself. Install one
# with the one-line installer, or point BEANSC_BOOT at any working beansc.
BEANSC_BOOT ?= $(shell command -v beansc 2>/dev/null || \
	ls "$${BEANS_HOME:-$$HOME/.beans}/bin/beansc" 2>/dev/null)

$(BIN): $(SELF_HOST_SRC) $(RUNTIME_COPY)
	@mkdir -p build
	@test -n "$(BEANSC_BOOT)" || { \
	  echo "no Beans compiler found to build with."; \
	  echo ""; \
	  echo "This checkout has no stage-0 bootstrap: compiler/bootstrap is a"; \
	  echo "private submodule and building it is not required. Install a"; \
	  echo "released beansc and build with that instead:"; \
	  echo ""; \
	  echo "  curl -fsSL https://github.com/beans-lang/beans/releases/latest/download/beans-install.sh | sh"; \
	  echo ""; \
	  echo "or point BEANSC_BOOT at an existing one:"; \
	  echo ""; \
	  echo "  make BEANSC_BOOT=/path/to/beansc"; \
	  echo ""; \
	  exit 1; \
	}
	$(BEANSC_BOOT) build compiler/beans/main.b -o $(BIN).new
	rm -f $(BIN) && mv $(BIN).new $(BIN)

endif

.PHONY: stage0 run clean install test test-ci test-bootstrap-gitlink test-core test-stage0 test-quick test-frontend test-semantics test-runtime test-ffi test-platform platform-status test-platform-manifest test-portable-int128 test-compiler-arch-objects test-stage0-windows test-windows-source-bootstrap test-musl-hosted test-armv6hf-hosted test-sanitize test-release-package test-install-release test-release-completeness test-clean-bootstrap test-c-abi-tier1 test-mir-stage0 test-barq-core fuzz-smoke fuzz-differential fuzz-differential-smoke test-linux test-linux-arch test-linux-hosted test-windows test-windows-native test-windows-native-i686 test-windows-native-arm64 test-windows-arch test-windows-hosted test-encoding-targets test-encoding-windows access-score self-host-next test-self-host test-self-host-full test-bootstrap bench-compiler bench-quick bench-full bench-verify bench-profile bench-compare
stage0: $(BOOTSTRAP_BIN)

run: $(BIN)
	./$(BIN) parse examples/hello.b examples/tour.b

# Installs the self-hosted compiler only. beansc0 is internal bootstrap code and
# stays in build/, where bootstrap development needs it.
install: $(BIN)
	PREFIX="$(PREFIX)" DESTDIR="$(DESTDIR)" bash ./tools/install.sh

# The whole gate. `test-core` is everything that needs only the self-hosted
# compiler; `test-stage0` is the scripts that compare it against the C++ stage 0
# and therefore need the private bootstrap submodule.
test: test-core test-stage0

# What CI runs. Identical to `test` where stage 0 is checked out; on a fork pull
# request, which is not given the secret that can clone the private submodule,
# it is the bootstrap-free gate instead of a guaranteed failure.
test-ci: test-core
ifneq ($(HAVE_BOOTSTRAP),)
	$(MAKE) test-stage0
else
	@echo ""
	@echo "stage 0 is not checked out, so the differential gates against it did"
	@echo "not run. This is expected on a fork pull request."
endif

# This needs network access to the private bootstrap repository, so CI runs it
# explicitly instead of including it in the normal local test gate.
test-bootstrap-gitlink:
	bash ./test/bootstrap_gitlink.sh

# bench_compare.sh exercises the comparator binary, so a clean checkout's
# `make test` must build it first rather than assume an earlier bench run left
# one behind. The prerequisite is conditional because the comparator is built
# from the stage-0 sources: a checkout without that submodule must still reach
# the message below rather than fail on a missing rule.
test-stage0: $(BIN) $(if $(HAVE_BOOTSTRAP),build/bench/compare)
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test needs the stage-0 bootstrap compiler, which is not in this checkout."
	@echo ""
	@echo "  With access to it:  git submodule update --init compiler/bootstrap"
	@echo "  Without access:     make test-core"
	@echo ""
	@echo "test-core runs every gate that does not compare against stage 0."
	@exit 1
else
	./test/targets.sh
	./test/platform_manifest.sh
	./test/object_abi.sh
	bash ./test/runtime_abi.sh
	bash ./test/decimal_align.sh
	./test/cli_parity.sh
	bash ./test/package_semantics.sh
	bash ./test/package_identity.sh
	./test/self_host.sh
	bash ./test/unsafe.sh
	bash ./test/builtin_names.sh
	bash ./test/bench_compare.sh
	bash ./test/compiler_arch_objects.sh
endif

# The five-minute developer gate: the checks that catch almost every compiler
# mistake, cheapest first, so a parity break reports in seconds. This is a
# feedback loop, not the bar — `make test` stays the full suite. Timings are
# from build/test_timing on a dev laptop; the whole chain is under five
# minutes when the compiler is already built.
test-quick: $(BIN)
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test-quick needs the stage-0 bootstrap compiler (see make test)."
	@exit 1
else
	./test/cli_parity.sh
	./test/parse_recovery.sh
	bash ./test/package_semantics.sh
	bash ./test/package_identity.sh
	bash ./test/builtin_names.sh
	./test/deterministic_build.sh
	bash ./test/unsafe.sh
	./test/differential.sh
	bash ./test/ci_coverage.sh
	$(MAKE) test-bootstrap
	$(MAKE) fuzz-differential-smoke
endif

# Focused slices of the full suite for iterating on one area. Together the
# five slices run exactly the scripts `make test` runs — test/ci_coverage.sh
# fails if they ever drift apart — so a green run of all five plus nothing
# else is the same claim as `make test`.
test-frontend: $(BIN)
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test-frontend needs the stage-0 bootstrap compiler (see make test)."
	@exit 1
else
	./test/docs.sh
	./test/version.sh
	bash ./test/syntax_v07.sh
	./test/parse_recovery.sh
	./test/lsp_probe.sh
	./test/lsp_server.sh
	./test/stdlib_source.sh
	bash ./test/api_names.sh
	./test/fs_source.sh
	./test/reader_source.sh
	./test/dependencies.sh
	./test/cli_parity.sh
	bash ./test/package_semantics.sh
	bash ./test/package_identity.sh
	bash ./test/builtin_names.sh
endif

test-semantics: $(BIN) build/bench/compare
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test-semantics needs the stage-0 bootstrap compiler (see make test)."
	@exit 1
else
	./test/differential.sh
	./test/panic.sh
	./test/numerics.sh
	./test/moves.sh
	bash ./test/borrowed_iteration.sh
	./test/maps.sh
	./test/traits.sh
	./test/fixed_arrays.sh
	bash ./test/closure_captures.sh
	bash ./test/async.sh
	bash ./test/mir.sh
	bash ./test/devirtualize.sh
	bash ./test/default_eval_order.sh
	./test/inline_options.sh
	./test/inline_results.sh
	bash ./test/wide_lists.sh
	bash ./test/wide_maps.sh
	bash ./test/wide_enums.sh
	bash ./test/wide_owners.sh
	bash ./test/wide_sync.sh
	bash ./test/wide_concurrency.sh
	./test/portable_int128.sh
	./test/self_host.sh
	bash ./test/bench_compare.sh
endif

test-runtime: $(BIN)
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test-runtime needs the stage-0 bootstrap compiler (see make test)."
	@exit 1
else
	bash ./test/thread_cleanup.sh
	./test/resources.sh
	./test/shm.sh
	./test/process.sh
	./test/profiles.sh
	./test/atomics.sh
	./test/cpu_features.sh
	./test/clocks_random.sh
	./test/net.sh
	./test/poll.sh
	./test/signals.sh
	./test/dylib.sh
	./test/child.sh
	bash ./test/encoding.sh
endif

test-ffi: $(BIN)
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test-ffi needs the stage-0 bootstrap compiler (see make test)."
	@exit 1
else
	./test/raw_slices.sh
	./test/c_layout_structs.sh
	./test/c_layout_unions.sh
	./test/c_layout_c_abi.sh
	./test/c_wide_args.sh
	./test/c_callbacks.sh
	./test/c_opaque.sh
	./test/c_globals.sh
	./test/link_manifest.sh
	./test/library_output.sh
	./test/bindgen.sh
	./test/bindgen_link.sh
	./test/stack_pointer.sh
	./test/stored_callbacks.sh
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
	bash ./test/encoding_stage0.sh
endif

test-platform: $(BIN)
ifeq ($(HAVE_BOOTSTRAP),)
	@echo "make test-platform needs the stage-0 bootstrap compiler (see make test)."
	@exit 1
else
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
endif

test-core: $(BIN)
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
	./test/moves.sh
	bash ./test/borrowed_iteration.sh
	./test/maps.sh
	./test/traits.sh
	bash ./test/syntax_v07.sh
	./test/fixed_arrays.sh
	./test/packed_layout.sh
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
	./test/library_output.sh
	./test/bindgen.sh
	./test/bindgen_link.sh
	./test/stack_pointer.sh
	./test/stored_callbacks.sh
	bash ./test/closure_captures.sh
	bash ./test/async.sh
	./test/stdlib_source.sh
	bash ./test/api_names.sh
	bash ./test/encoding.sh
	bash ./test/encoding_symbols.sh
	bash ./test/encoding_outputs.sh
	bash ./test/encoding_cache.sh
	./test/parse_recovery.sh
	bash ./test/mir.sh
	bash ./test/devirtualize.sh
	bash ./test/default_eval_order.sh
	./test/lsp_probe.sh
	./test/lsp_server.sh
	./test/fs_source.sh
	./test/reader_source.sh
	./test/inline_options.sh
	./test/inline_results.sh
	bash ./test/wide_lists.sh
	bash ./test/wide_maps.sh
	bash ./test/wide_enums.sh
	bash ./test/wide_owners.sh
	bash ./test/wide_sync.sh
	bash ./test/wide_concurrency.sh

# Behavioural suites that each also assert something about the stage-0 C++
# sources (a grep for the implementation that backs the behaviour). The
# behaviour is portable; the assertion needs the private submodule, so a
# public checkout runs everything above and skips these.
ifneq ($(HAVE_BOOTSTRAP),)
	./test/portable_int128.sh
	./test/profiles.sh
	./test/asm.sh
	./test/dependencies.sh
	./test/layout_introspect.sh
	./test/atomics.sh
	./test/cpu_features.sh
	./test/clocks_random.sh
	./test/net.sh
	./test/poll.sh
	./test/signals.sh
	./test/dylib.sh
	./test/child.sh
	bash ./test/encoding_stage0.sh
else
	@echo "skipped 14 suites whose implementation assertions read the stage-0 sources"
endif

# Everything below needs the C++ stage 0. It lives in a private submodule, so a
# public checkout gets one clear message instead of a missing-file error from
# make, the C++ compiler, or a test script halfway through a run.
ifeq ($(HAVE_BOOTSTRAP),)

BOOTSTRAP_ONLY := stage0 platform-status test-platform-manifest \
	test-compiler-arch-objects test-windows-source-bootstrap \
	test-musl-hosted test-armv6hf-hosted test-stage0-windows test-sanitize \
	test-clean-bootstrap test-c-abi-tier1 test-mir-stage0 fuzz-smoke \
	fuzz-differential fuzz-differential-smoke test-bootstrap test-self-host \
	test-self-host-full bench-compare

$(BOOTSTRAP_ONLY):
	@echo "'$@' needs the stage-0 bootstrap compiler, which is not in this checkout."
	@echo ""
	@echo "compiler/bootstrap is a private submodule. Stage 0 exists only to build"
	@echo "the compiler on a machine that has none; it is never shipped, and Beans"
	@echo "builds and tests without it."
	@echo ""
	@echo "  With access to it:  git submodule update --init compiler/bootstrap"
	@echo "  Without access:     make test-core"
	@echo ""
	@exit 1

else

platform-status test-platform-manifest: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/platform_manifest.sh

test-compiler-arch-objects: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/compiler_arch_objects.sh

test-windows-source-bootstrap:
	bash ./test/windows_source_bootstrap.sh

test-musl-hosted:
	bash ./test/musl_hosted.sh

test-armv6hf-hosted:
	bash ./test/armv6hf_hosted.sh

test-stage0-windows:
	bash ./test/windows_stage0.sh

test-sanitize: $(BIN)
	bash ./test/sanitize.sh

endif

test-portable-int128:
	bash ./test/portable_int128.sh

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

ifneq ($(HAVE_BOOTSTRAP),)

test-clean-bootstrap:
	bash ./test/clean_bootstrap.sh

test-c-abi-tier1: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/c_abi_tier1.sh

test-mir-stage0: $(BOOTSTRAP_BIN)
	BEANSC="./$(BOOTSTRAP_BIN)" bash ./test/mir_stage0.sh

endif

# Network-heavy real-product integration. Kept out of `make test` and the
# scorecard so local C interop work depends only on the small fixtures.
test-barq-core: $(BIN)
	bash ./test/barq_core.sh

build/beansc-asan-ubsan: $(SRC) $(HDR) $(RUNTIME_COPY)
	@mkdir -p build
	$(CXX) $(CPPFLAGS) -std=c++20 -Wall -Wextra -O1 -g -pthread \
		-fsanitize=address,undefined -fno-sanitize-recover=undefined \
		$(SRC) -o $@

build/beansc-tsan: $(SRC) $(HDR) $(RUNTIME_COPY)
	@mkdir -p build
	$(CXX) $(CPPFLAGS) -std=c++20 -Wall -Wextra -O1 -g -pthread \
		-fsanitize=thread $(SRC) -o $@

build/fuzz-frontend: test/fuzz_frontend.cpp $(FRONTEND_FUZZ_SRC) $(HDR)
	@mkdir -p build
	$(CXX) $(CPPFLAGS) -std=c++20 -O1 -g -pthread -Icompiler/bootstrap \
		$(FUZZ_FLAGS) \
		test/fuzz_frontend.cpp $(FRONTEND_FUZZ_SRC) -o $@

ifneq ($(HAVE_BOOTSTRAP),)

fuzz-smoke: build/fuzz-frontend
	bash ./test/fuzz.sh "$${FUZZ_SECONDS:-15}"

# Semantic differential fuzzing: generated typed programs with an
# independent expected-output oracle, compared across both compilers'
# interpreters and native debug/release/LTO builds. Configure the long
# run with FUZZ_SEED / FUZZ_CASES / FUZZ_LANES / FUZZ_GROUPS (see
# test/differential_fuzz.sh).
fuzz-differential: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/differential_fuzz.sh run

fuzz-differential-smoke: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/differential_fuzz.sh smoke

# rm before cp: overwriting a signed binary in place leaves macOS's signature
# cache stale, and the kernel then kills the new binary on exec with SIGKILL
# and no message. A fresh inode never hits the cache.
build/beansc-next: $(BIN)
	rm -f $@ && cp $(BIN) $@

self-host-next: build/beansc-next

test-self-host: $(BOOTSTRAP_BIN) build/beansc-next
	BEANSC0="./$(BOOTSTRAP_BIN)" bash ./test/self_host.sh

# stage 1 (built by C++) compiles the compiler; the result must
# answer like the reference and re-emit the compiler byte-identically
test-bootstrap: $(BOOTSTRAP_BIN) $(STAGE1_BIN)
	BEANSC0="./$(BOOTSTRAP_BIN)" \
	BEANSC_STAGE1="./$(STAGE1_BIN)" \
	bash ./test/bootstrap.sh

test-self-host-full: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/self_host_full.sh

endif

# Both sides of this comparison are the self-hosted compiler, so it needs no
# stage 0.
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
# its self-compile fixed point and drives the examples byte-identical. It also
# cross-builds beansc0 from C++ and checks its native target default, which is
# required for a source bootstrap. ARCH defaults to ppc64le.
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

# The benchmark comparator reuses the stage-0 JSON reader, so it is bootstrap-only.
ifneq ($(HAVE_BOOTSTRAP),)

build/bench/compare: bench/compare.cpp compiler/bootstrap/json.cpp compiler/bootstrap/json.h
	@mkdir -p build/bench
	$(CXX) $(CPPFLAGS) -std=c++20 -Wall -Wextra -O2 bench/compare.cpp compiler/bootstrap/json.cpp -o $@

bench-compare: build/bench/compare
	@test -n "$(BEFORE)" || { echo "usage: make bench-compare BEFORE=before AFTER=after EXPECT=workload"; exit 2; }
	@test -n "$(AFTER)" || { echo "usage: make bench-compare BEFORE=before AFTER=after EXPECT=workload"; exit 2; }
	@test -n "$(EXPECT)" || { echo "usage: make bench-compare BEFORE=before AFTER=after EXPECT=workload"; exit 2; }
	./build/bench/compare "build/bench/results-full-$(BEFORE).json" \
	    "build/bench/results-full-$(AFTER).json" $(EXPECT)

endif

clean:
	rm -rf build
