# ALKO Proxy for Windows x64

1. Open the latest successful [Windows native engine build](https://github.com/psychoalkox/alko-proxy/actions/workflows/build-native-windows.yml) and extract the `ALKO-native-GTProxy-Windows-x64` artifact. Keep its DLLs, scripts and resources beside `Proxy.exe`.
2. Open `ALKOProxy.exe` from this repository. In **Settings**, select the extracted `Proxy.exe`, save the settings and start the engine.

The build checks that the packaged engine opens its local HTTPS listener and reports a heartbeat to the ALKO bridge. Growtopia 5.61 connectivity and ban safety remain unverified.

See [Local Windows build](LOCAL_INSTALL_WINDOWS.md) to compile from source and [Windows startup troubleshooting](DLL_STARTUP_FIX_v0.6.md) for error `0xC0000135`.

---

# ALKO Proxy Standalone — v0.2 (Windows x64)

## Start in one click
1. Double-click `ALKOProxy.exe` on Windows 10/11 x64.
2. The dashboard opens in your default browser at `http://127.0.0.1:8765`.
3. Use **World scanner → Import JSON** to try the offline scanner. Open `examples/world_scan.json` in Notepad, copy its contents, and paste into the app.
4. Close the application from **Settings → Quit ALKO Proxy** (closing the browser tab alone does not stop the local server).

No Python, Node, Go, command prompt, game account, or other installation is required to run the **dashboard**. Windows may display a reputation warning because the open-source binary is unsigned; don't override security warnings unless you trust the package and have inspected it.

## What this compiled EXE actually does
- Hosts the original ALKO sand/black browser dashboard **locally** with the HTML/CSS/JS assets embedded in its single file.
- Stores settings and scan data in `%APPDATA%\ALKO-Proxy` (or your user's configuration directory).
- Imports and normalizes world-scan JSON, filters item counts, displays module status and logs.
- Validates allowed slash commands and communicates through a file queue **only if** a separately compiled compatible GTProxy bridge is connected.
- Offers finite, cancellable, command-based automation workflows and opt-in Lua submission **only when that bridge is connected**.
- Can launch/stop a *separate* native engine executable after you set its path in Settings.
- Listens only on `127.0.0.1`, uses a random launch token on state-changing requests, and doesn't request or collect GrowID credentials.

## What it does NOT do
**This is not a complete Growtopia 5.61 proxy.** It does not include a compiled ENet relay, change game network settings, prove compatibility with v5.61, bypass bans, or attach to a running Growtopia client by itself. Native GrowScan and in-game slash commands are currently unavailable without a patched, compiled and live-tested engine.

Fast vending, unlimited zoom, packet-based autofarm, and multibot sessions are not implemented. The existing Lua feature pack and experimental drop/trash requests are **not validated against 5.61**. Do not test those commands on valuable items or an important game account.

### Why the engine is not included
The upstream C++ GTProxy engine and its build dependencies are not bundled. Compiling and verifying them requires upstream source, Windows C++ build tools, and actual Growtopia 5.61 network testing. This release does not claim that this step has been completed.

If you elect to build it yourself, `engine/SETUP_ENGINE_WINDOWS.ps1` has the previously prepared source-clone/patch/build workflow. It requires Git, Python, CMake, Conan, MSVC and network access and is **not** guaranteed to work without adjustments. Any engine build should be audited and tested before live use.

### Optional macro recorder
`tools/macro_recorder.py` is the separate **source-only** Python utility from the earlier project. It is not part of the standalone EXE and requires Python plus `pynput` if used. Automated gameplay may violate Growtopia rules and can lead to suspension.

## What was tested
- Go unit tests for command validation, offline world-scan parsing/import, settings and file-queue behavior: **passed on Linux**.
- Local HTTP smoke tests for the served dashboard, status/settings/scanner/logs API, JSON import, blocked offline commands, and Quit: **passed on Linux**.
- Cross-compilation for Windows amd64: **passed; PE32+ GUI executable generated**.
- Windows native execution, upstream ENet build, and a live Growtopia 5.61 connection: **not tested here**.

## Rebuild reproducibly
The Go source (`source/main.go`) has **no third-party Go dependencies**. On a machine with Go 1.23+:

```powershell
cd source
go test ./...
$env:GOOS = "windows"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"
go build -trimpath -ldflags "-s -w -H=windowsgui" -o ..\ALKOProxy.exe .
```

The dashboard sources are embedded in the EXE using Go `embed`. Contributions can modify `source/web/` and rebuild.

No affiliation with Ubisoft or Growtopia. The game may prohibit proxies, macros, autofarming and altered network traffic; ban-safe status cannot be guaranteed.
