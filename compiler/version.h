#pragma once

#include <cstdint>

namespace beans {

// One version source for the compiler, language server, release checks and the
// runtime contract. The project is still in the public 1.0 bake, so do not call
// it 1.0.0 until every release gate in ROADMAP.md has passed.
inline constexpr char version[] = "0.1.2";
inline constexpr char language_version[] = "1.0";
// 4: decimal coefficients use portable two-limb storage, and class descriptors
// carry an optional pointer-offset shape before their method table. This lets
// hosted 32-bit compilers represent decimal and classes wider than 58 slots.
inline constexpr uint32_t runtime_abi_version = 4;

} // namespace beans
