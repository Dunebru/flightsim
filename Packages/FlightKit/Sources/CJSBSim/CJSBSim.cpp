#include "CJSBSim.h"

// Placeholder (M0 stub). Compiled as C++17 to prove the toolchain path JSBSim will use in M2.
extern "C" const char *jsb_version(void) {
    static constexpr const char *kVersion = "stub";
    return kVersion;
}
