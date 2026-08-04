#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#ifdef BEANS_FUZZ_STANDALONE
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#endif

#include "ast.h"
#include "checker.h"
#include "lexer.h"
#include "parser.h"
#include "target.h"

// The interpreter's C ABI bridge calls this, and the real definition lives in
// the driver's main.cpp — which this build deliberately leaves out, because
// libFuzzer supplies its own main. The harness only lexes, parses and checks,
// so it never reaches the bridge; this satisfies the linker with the same
// default the driver would pick.
std::string find_c_driver() {
    if (const char* configured = std::getenv("BEANS_CC")) {
        if (*configured) return configured;
    }
    return "clang";
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    // Keep one input bounded even when a caller forgets libFuzzer's -max_len.
    if (size > 65536) return 0;

    auto file = std::make_unique<beans::PFile>();
    file->path = "fuzz.b";
    file->source.assign(reinterpret_cast<const char*>(data), size);

    beans::Lexer lexer(file->source);
    std::vector<beans::Token> tokens = lexer.scan_all();
    beans::Parser parser(std::move(tokens));
    file->mod = parser.parse_module();
    (void)beans::dump(file->mod);

    auto package = std::make_unique<beans::Package>();
    package->prefix = "";
    package->import_path = "main";
    package->dir = ".";
    package->files.push_back(std::move(file));

    beans::Program program;
    program.packages.push_back(std::move(package));
    beans::Checker checker(program, beans::TargetSpec::host());
    checker.run();
    return 0;
}

#ifdef BEANS_FUZZ_STANDALONE
int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: fuzz-frontend <corpus-directory> <seconds>\n";
        return 2;
    }
    std::vector<std::string> corpus;
    for (const auto& entry :
         std::filesystem::directory_iterator(argv[1])) {
        if (!entry.is_regular_file()) continue;
        std::ifstream in(entry.path(), std::ios::binary);
        corpus.emplace_back(std::istreambuf_iterator<char>(in),
                            std::istreambuf_iterator<char>());
    }
    if (corpus.empty()) corpus.emplace_back();

    uint64_t state = 0x4d595df4d0f33173ULL;
    auto random = [&]() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    };
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::seconds(std::stoi(argv[2]));
    size_t runs = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        std::string input = corpus[random() % corpus.size()];
        size_t edits = 1 + random() % 16;
        while (edits-- > 0) {
            if (input.empty() || (random() & 3) == 0) {
                if (input.size() < 65536) {
                    size_t at = input.empty() ? 0 : random() % input.size();
                    input.insert(input.begin() + at,
                                 static_cast<char>(random()));
                }
            } else if ((random() & 1) == 0) {
                input[random() % input.size()] = static_cast<char>(random());
            } else {
                input.erase(input.begin() + random() % input.size());
            }
        }
        LLVMFuzzerTestOneInput(
            reinterpret_cast<const uint8_t*>(input.data()), input.size());
        ++runs;
    }
    std::cout << "standalone fuzz runs: " << runs << '\n';
    return 0;
}
#endif
