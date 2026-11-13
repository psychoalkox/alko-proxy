// ALKO Proxy bridge patch for vinskeeper/GTProxy (MIT upstream).
// No external listening socket. Native engine and dashboard exchange files locally.
#pragma once
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>
#include <spdlog/spdlog.h>
#include "../scripting/lua_engine.hpp"

namespace alko_bridge {
namespace fs = std::filesystem;
inline fs::path root() {
    const auto* value = std::getenv("ALKO_BRIDGE_DIR");
    if (!value || !*value) return {};
    return fs::path(value);
}
inline bool valid_command(std::string const& c) {
    if (c.empty() || c.size() > 180 || c[0] != '/') return false;
    for (unsigned char x : c) if (x < 32 || x > 126) return false;
    const auto end = c.find(' ');
    const auto name = c.substr(1, end == std::string::npos ? end : end - 1);
    constexpr std::string_view allowed[] = {"alko","help","proxy","warp","nick","skin","debug","exit",
       "gscan","counts","pos","people","dropped","farmreport","qdrop","qtrash","ping"};
    return std::any_of(std::begin(allowed), std::end(allowed), [&](auto x){ return x == name; });
}
inline std::string lua_quote(std::string const& input) {
    std::string out = "\"";
    for (char c : input) {
        if (c == '\\' || c == '"') out.push_back('\\');
        out.push_back(c);
    }
    return out + '"';
}
inline void write_file_atomic(fs::path const& path, std::string const& data) {
    std::error_code ec;
    fs::create_directories(path.parent_path(), ec);
    const auto tmp = fs::path(path.string() + ".tmp");
    { std::ofstream stream(tmp, std::ios::binary | std::ios::trunc); if (!stream) return; stream << data; }
    fs::remove(path, ec);
    fs::rename(tmp, path, ec);
}
inline void install_emit(scripting::LuaEngine& engine) {
    const fs::path bridge = root();
    engine.state().set_function("alko_emit", [bridge](std::string const& kind, std::string const& payload) -> bool {
        if (bridge.empty() || kind != "scan" || payload.size() > 1500000) return false;
        write_file_atomic(bridge / "telemetry" / "scan.json", payload);
        return true;
    });
}
class Bridge {
public:
    void poll(scripting::LuaEngine& engine, bool game_connected, bool upstream_connected,
              std::string_view bootstrap) {
        const fs::path bridge = root();
        if (bridge.empty()) return;
        const auto* session_value = std::getenv("ALKO_BRIDGE_SESSION");
        const std::string session = session_value ? session_value : "";
        if (!session.empty() &&
            (session.size() != 32 || session.find_first_not_of("0123456789abcdef") != std::string::npos)) return;
        const auto inbox = session.empty() ? bridge / "inbox" : bridge / "inbox" / session;
        const auto now = std::chrono::steady_clock::now();
        if (now - last_check_ < std::chrono::milliseconds(120)) return;
        last_check_ = now;
        std::error_code ec;
        fs::create_directories(inbox, ec);
        fs::create_directories(bridge / "outbox", ec);
        fs::create_directories(bridge / "telemetry", ec);
        const std::string_view connection = game_connected
            ? (upstream_connected ? "connected" : "connecting")
            : "disconnected";
        if (connection != last_connection_ || bootstrap != last_bootstrap_ ||
            now - last_heartbeat_ >= std::chrono::seconds(1)) {
            write_file_atomic(bridge / "telemetry" / "heartbeat.json",
                "{\"bridge\":\"online\",\"engine\":\"GTProxy\",\"session\":\"" + session +
                "\",\"connection\":\"" + std::string(connection) + "\",\"bootstrap\":\"" +
                std::string(bootstrap) + "\"}");
            if (last_connection_ != connection || last_bootstrap_ != bootstrap) {
                spdlog::info("ALKO connection: {} (bootstrap: {})", connection, bootstrap);
            }
            last_connection_ = connection;
            last_bootstrap_ = bootstrap;
            last_heartbeat_ = now;
        }
        std::vector<fs::path> jobs;
        for (fs::directory_iterator it(inbox, ec), end; !ec && it != end; it.increment(ec)) {
            if (it->is_regular_file(ec) && (it->path().extension() == ".cmd" || it->path().extension() == ".lua")) {
                jobs.push_back(it->path());
                if (jobs.size() >= 20) break;
            }
        }
        std::sort(jobs.begin(), jobs.end());
        for (auto const& path : jobs) {
            const bool script = path.extension() == ".lua";
            bool success = false;
            std::string message;
            auto size = fs::file_size(path, ec);
            if (connection != "connected") {
                message = "Game relay disconnected; job was discarded";
            } else if (!ec && size <= (script ? 20000u : 200u)) {
                if (script) {
                    success = engine.execute_file(path);
                    message = success ? "Lua evaluated by engine; game effect unconfirmed" : "Lua evaluation failed";
                } else {
                    std::ifstream stream(path, std::ios::binary);
                    std::string cmd;
                    std::getline(stream, cmd);
                    if (valid_command(cmd)) {
                        success = engine.execute("if not command.execute(" + lua_quote(cmd) + ") then error('Command failed') end");
                        message = success ? "Command handled locally; game effect unconfirmed" : "Command dispatch failed";
                    } else message = "Rejected by bridge command allowlist";
                }
            } else message = "Job exceeds size limit";
            write_file_atomic(bridge / "outbox" / (path.stem().string() + ".json"),
                "{\"id\":\"" + path.stem().string() + "\",\"ok\":" + (success ? "true" : "false") +
                ",\"type\":\"" + (script ? "lua" : "command") + "\",\"message\":\"" + message + "\"}");
            spdlog::info("ALKO bridge job {}: {}", path.stem().string(), message);
            fs::remove(path, ec);
        }
    }
private:
    std::string last_connection_;
    std::string last_bootstrap_;
    std::chrono::steady_clock::time_point last_check_{};
    std::chrono::steady_clock::time_point last_heartbeat_{};
};
} // namespace alko_bridge
