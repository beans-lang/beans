CXX      := clang++
CXXFLAGS := -std=c++20 -Wall -Wextra -O2 -pthread
CPPFLAGS :=
LDLIBS   :=

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

SRC := compiler/bootstrap/token.cpp compiler/bootstrap/lexer.cpp compiler/bootstrap/parser.cpp compiler/bootstrap/ast_print.cpp compiler/bootstrap/process.cpp compiler/bootstrap/loader.cpp compiler/bootstrap/target.cpp compiler/bootstrap/mir.cpp compiler/bootstrap/c_abi.cpp compiler/bootstrap/checker.cpp compiler/bootstrap/builtins.cpp compiler/bootstrap/codegen.cpp compiler/bootstrap/interp.cpp compiler/bootstrap/lsppos.cpp compiler/bootstrap/json.cpp compiler/bootstrap/bindgen.cpp compiler/bootstrap/lsp.cpp compiler/bootstrap/lspserver.cpp compiler/bootstrap/main.cpp
HDR := compiler/bootstrap/token.h compiler/bootstrap/lexer.h compiler/bootstrap/ast.h compiler/bootstrap/parser.h compiler/bootstrap/types.h compiler/bootstrap/process.h compiler/bootstrap/target.h compiler/bootstrap/host_target.h compiler/bootstrap/int128.h compiler/bootstrap/mir.h compiler/bootstrap/hir.h compiler/bootstrap/c_abi.h compiler/bootstrap/loader.h compiler/bootstrap/checker.h compiler/bootstrap/value.h compiler/bootstrap/builtins.h compiler/bootstrap/interp.h compiler/bootstrap/codegen.h compiler/bootstrap/lsppos.h compiler/bootstrap/json.h compiler/bootstrap/bindgen.h compiler/bootstrap/lsp.h compiler/bootstrap/rounding.h compiler/bootstrap/version.h
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

.PHONY: stage0 run clean install test platform-status test-platform-manifest test-portable-int128 test-compiler-arch-objects test-stage0-windows test-windows-source-bootstrap test-musl-hosted test-armv6hf-hosted test-sanitize test-release-package test-clean-bootstrap test-c-abi-tier1 test-mir-stage0 test-barq-core fuzz-smoke test-linux test-linux-arch test-linux-hosted test-windows test-windows-native test-windows-native-i686 test-windows-native-arm64 test-windows-arch test-windows-hosted access-score self-host-next test-self-host test-self-host-full test-bootstrap bench-compiler bench-quick bench-full bench-verify bench-profile bench-compare
stage0: $(BOOTSTRAP_BIN)

run: $(BIN)
	./$(BIN) parse examples/hello.b examples/tour.b

install: $(BIN) $(BOOTSTRAP_BIN)
	PREFIX="$(PREFIX)" DESTDIR="$(DESTDIR)" bash ./tools/install.sh

test: $(BIN) build/bench/compare
	./test/differential.sh
	./test/panic.sh
	./test/targets.sh
	./test/platform_manifest.sh
	./test/portable_int128.sh
	./test/profiles.sh
	./test/freestanding.sh
	./test/object_abi.sh
	bash ./test/compiler_arch_objects.sh
	bash ./test/runtime_abi.sh
	bash ./test/abi_probe.sh
	bash ./test/decimal_align.sh
	./test/wasm_matrix.sh
	./test/wasm.sh
	./test/embedded.sh
	./test/asm.sh
	./test/docs.sh
	./test/version.sh
	./test/cli_parity.sh
	./test/dependencies.sh
	./test/self_host.sh
	./test/deterministic_build.sh
	./test/numerics.sh
	./test/moves.sh
	./test/maps.sh
	./test/traits.sh
	bash ./test/syntax_v07.sh
	bash ./test/unsafe.sh
	./test/fixed_arrays.sh
	./test/layout_introspect.sh
	./test/packed_layout.sh
	./test/atomics.sh
	bash ./test/thread_cleanup.sh
	./test/simd.sh
	./test/cpu_features.sh
	./test/intrinsics.sh
	./test/resources.sh
	./test/clocks_random.sh
	./test/shm.sh
	./test/process.sh
	./test/net.sh
	./test/poll.sh
	./test/signals.sh
	./test/dylib.sh
	./test/child.sh
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
	./test/stack_pointer.sh
	./test/stored_callbacks.sh
	bash ./test/closure_captures.sh
	./test/stdlib_source.sh
	./test/parse_recovery.sh
	bash ./test/mir.sh
	bash ./test/devirtualize.sh
	bash ./test/bench_compare.sh
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

platform-status test-platform-manifest: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/platform_manifest.sh

test-portable-int128:
	bash ./test/portable_int128.sh

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

test-release-package: $(BIN)
	bash ./test/release_package.sh

test-clean-bootstrap:
	bash ./test/clean_bootstrap.sh

test-c-abi-tier1: $(BIN) $(BOOTSTRAP_BIN)
	bash ./test/c_abi_tier1.sh

test-mir-stage0: $(BOOTSTRAP_BIN)
	BEANSC="./$(BOOTSTRAP_BIN)" bash ./test/mir_stage0.sh

# Network-heavy real-product integration. Kept out of `make test` and the
# scorecard so local C interop work depends only on the small fixtures.
test-barq-core: $(BIN)
	bash ./test/barq_core.sh

build/beansc-asan-ubsan: $(SRC) $(HDR) $(RUNTIME_COPY)
	@mkdir -p build
	$(CXX) -std=c++20 -Wall -Wextra -O1 -g -pthread \
		-fsanitize=address,undefined -fno-sanitize-recover=undefined \
		$(SRC) -o $@

build/beansc-tsan: $(SRC) $(HDR) $(RUNTIME_COPY)
	@mkdir -p build
	$(CXX) -std=c++20 -Wall -Wextra -O1 -g -pthread \
		-fsanitize=thread $(SRC) -o $@

build/fuzz-frontend: test/fuzz_frontend.cpp $(FRONTEND_FUZZ_SRC) $(HDR)
	@mkdir -p build
	$(CXX) -std=c++20 -O1 -g -pthread -Icompiler/bootstrap \
		$(FUZZ_FLAGS) \
		test/fuzz_frontend.cpp $(FRONTEND_FUZZ_SRC) -o $@

fuzz-smoke: build/fuzz-frontend
	bash ./test/fuzz.sh "$${FUZZ_SECONDS:-15}"

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

build/bench/compare: bench/compare.cpp compiler/bootstrap/json.cpp compiler/bootstrap/json.h
	@mkdir -p build/bench
	$(CXX) -std=c++20 -Wall -Wextra -O2 bench/compare.cpp compiler/bootstrap/json.cpp -o $@

bench-compare: build/bench/compare
	@test -n "$(BEFORE)" || { echo "usage: make bench-compare BEFORE=before AFTER=after EXPECT=workload"; exit 2; }
	@test -n "$(AFTER)" || { echo "usage: make bench-compare BEFORE=before AFTER=after EXPECT=workload"; exit 2; }
	@test -n "$(EXPECT)" || { echo "usage: make bench-compare BEFORE=before AFTER=after EXPECT=workload"; exit 2; }
	./build/bench/compare "build/bench/results-full-$(BEFORE).json" \
	    "build/bench/results-full-$(AFTER).json" $(EXPECT)

clean:
	rm -rf build
