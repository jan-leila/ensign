#include "log.h"
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <dlfcn.h>
#include <mutex>
#include <string>

namespace ensign {
static FILE* g_file = nullptr;
static bool g_tried = false;
static std::mutex g_mu;

// Opened lazily on first use: Hyperspace may call into us (luaL_newstate) before
// our own constructor has run, so logging cannot depend on initialization order.
static void open_locked() {
    if (g_tried) return;
    g_tried = true;
    std::string path = self_dir() + "/ensign.log";
    g_file = fopen(path.c_str(), "w");
}

void log_init(const std::string&) {
    std::lock_guard<std::mutex> lk(g_mu);
    open_locked();
}

void logf(const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    std::lock_guard<std::mutex> lk(g_mu);
    open_locked();
    fprintf(stderr, "[Ensign] %s\n", buf);
    if (g_file) {
        fprintf(g_file, "[%10.3f] %s\n", now_seconds(), buf);
        fflush(g_file);
    }
}

double now_seconds() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

std::string self_dir() {
    Dl_info info;
    if (dladdr((void*)&self_dir, &info) && info.dli_fname) {
        // the launcher preloads us by a relative path; Steam needs absolute paths
        char resolved[4096];
        std::string p = realpath(info.dli_fname, resolved) ? resolved : info.dli_fname;
        auto slash = p.rfind('/');
        if (slash != std::string::npos) return p.substr(0, slash);
    }
    return ".";
}
}
