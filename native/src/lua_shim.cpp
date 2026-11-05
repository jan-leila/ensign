#include "lua_shim_defs.h"
#include "log.h"
#include <dlfcn.h>

namespace luashim {
#define ENSIGN_X(n) decltype(&::n) p_##n = nullptr;
ENSIGN_LUA_FUNCS(ENSIGN_X)
#undef ENSIGN_X

bool resolve() {
    bool ok = true;
#define ENSIGN_X(n) \
    if (!p_##n) { p_##n = (decltype(&::n))dlsym(RTLD_DEFAULT, #n); \
        if (!p_##n) { ensign::logf("lua shim: missing symbol %s", #n); ok = false; } }
    ENSIGN_LUA_FUNCS(ENSIGN_X)
#undef ENSIGN_X
    return ok;
}
}
