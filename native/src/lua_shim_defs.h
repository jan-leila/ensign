// Function-pointer declarations for the Lua API (no name-routing macros here).
#pragma once
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#define ENSIGN_LUA_FUNCS(X) \
    X(lua_gettop) X(lua_settop) X(lua_pushvalue) X(lua_type) X(lua_typename) \
    X(lua_tonumberx) X(lua_tointegerx) X(lua_toboolean) X(lua_tolstring) X(lua_rawlen) \
    X(lua_isinteger) X(lua_isnumber) X(lua_isstring) \
    X(lua_pushnil) X(lua_pushnumber) X(lua_pushinteger) X(lua_pushlstring) X(lua_pushstring) \
    X(lua_pushcclosure) X(lua_pushboolean) X(lua_createtable) X(lua_setfield) X(lua_getfield) \
    X(lua_setglobal) X(lua_getglobal) X(lua_rawseti) X(lua_rawgeti) X(lua_next) X(lua_pcallk) \
    X(lua_error) X(lua_settable) X(lua_gettable) \
    X(luaL_checklstring) X(luaL_checknumber) X(luaL_checkinteger) X(luaL_optinteger) \
    X(luaL_optnumber) X(luaL_optlstring) X(luaL_error) X(luaL_setfuncs) X(luaL_checktype) \
    X(luaL_checkversion_) X(luaL_loadstring) X(luaL_traceback)

namespace luashim {
#define ENSIGN_X(n) extern decltype(&::n) p_##n;
ENSIGN_LUA_FUNCS(ENSIGN_X)
#undef ENSIGN_X
bool resolve();
}
