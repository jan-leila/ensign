# Ensign native shim for FTL + Hyperspace (Linux amd64).
# Builds build/ensign.amd64.so, a library preloaded BEFORE Hyperspace via LD_PRELOAD.
#
#   make            -> build/ensign.amd64.so
#   make check      -> compile-only syntax check
#   make clean
#
# libstdc++/libgcc are linked statically so the result does not depend on the
# Steam runtime's C++ library version. Lua headers (5.3) come from pkg-config.

CXX      ?= g++
BUILD    ?= ../build
TARGET   := $(BUILD)/ensign.amd64.so
SRCS     := src/ensign.cpp src/lua_shim.cpp src/steam_bridge.cpp src/game.cpp src/log.cpp
OBJS     := $(patsubst src/%.cpp,$(BUILD)/obj/%.o,$(SRCS))
LUA_CFLAGS := $(shell pkg-config --cflags lua5.3 2>/dev/null || pkg-config --cflags lua 2>/dev/null)
VERSION  ?= $(shell git -C .. describe --tags --always --dirty 2>/dev/null || echo dev)

CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++17 -fPIC -Wall -Wextra -Wno-unused-parameter -fno-strict-aliasing \
            -fvisibility=hidden -DENSIGN_VERSION=\"$(VERSION)\" $(LUA_CFLAGS) -Isrc -Ithird_party -I.
LDFLAGS  += -shared -static-libstdc++ -static-libgcc -Wl,--no-as-needed -ldl -lpthread \
            -Wl,-z,noexecstack -Wl,--exclude-libs,ALL

all: $(TARGET)

$(BUILD)/obj/%.o: src/%.cpp | $(BUILD)/obj
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CXX) $(OBJS) $(LDFLAGS) -o $@
	@echo "built $@"

$(BUILD)/obj:
	mkdir -p $@

check:
	for f in $(SRCS); do $(CXX) $(CXXFLAGS) -fsyntax-only $$f || exit 1; done

clean:
	rm -rf $(BUILD)/obj $(TARGET)

.PHONY: all check clean
