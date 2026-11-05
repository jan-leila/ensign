#pragma once
#include <string>

namespace ensign {
// Logs go to stderr and to <game data dir>/ensign.log (next to FTL_HS.log).
void log_init(const std::string& dir);
void logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
double now_seconds();
std::string self_dir();   // directory containing this shared object
}
