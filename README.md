# ALKO Proxy for Windows x64

1. Download the matching [Windows build](https://github.com/psychoalkox/alko-proxy/actions/workflows/build-native-windows.yml). Extract the artifact together. Open its ALKOProxy.exe and point **Settings → Engine path** at its Proxy.exe.
2. For an isolated Windows test profile, generate a fresh TLS pair into the extracted engine's existing resources folder with engine/NEW_ENGINE_TLS_WINDOWS.ps1 -Directory <engine-resources>. The script requires OpenSSL 3 and leaves system trust and hosts unchanged. Keep key.pem private. The engine also accepts ALKO_TLS_DIR if the certificate and key live outside resources.
3. In the test profile, trust only the generated public certificate for the test, and configure the bootstrap names used by the test client to resolve to 127.0.0.1. The upstream mechanism uses the bare and www forms of growtopia1.com and growtopia2.com. Confirm Windows resolves them locally before starting a fresh game process. Remove the test trust and hosts entries after the test. Client-specific certificate handling can still reject a local certificate.
4. Start the matching launcher and engine. Look for **Waiting for game HTTPS**, followed by a POST to /growtopia/server_data.php with status 200 and **ENet connected**. A 502 is a bootstrap failure with a reason in the native log. If no POST appears after a fresh launch, check routing and client TLS acceptance. ENet connected means both peers established transport.
5. Enter a world and type **/proxy** in the game's own chat. Expect **Proxy command executed successfully!** in game and **Proxy smoke-test response sent to game client** in the native log. This tests the native chat command and reply independently of the dashboard. The dashboard rejects jobs while the relay is disconnected.

The Windows build tests verified loopback HTTPS, the bound ENet port and disconnected queue rejection. Growtopia 5.61 login, in-world commands on the live service and account safety still require separate verification.

See [Local Windows build](LOCAL_INSTALL_WINDOWS.md) to compile from source and [Windows startup troubleshooting](DLL_STARTUP_FIX_v0.6.md) for error `0xC0000135`.

---

# ALKO Proxy Standalone â€” v0.2 (Windows x64)

## Start in one click
1. Double-click `ALKOProxy.exe` on Windows 10/11 x64.
2. The dashboard opens in your default browser at `http://127.0.0.1:8765`.
3. Use **World scanner â†’ Import JSON** to try the offline scanner. Open `examples/world_scan.json` in Notepad, copy its contents, and paste into the app.
4. Close the application from **Settings â†’ Quit ALKO Proxy** (closing the browser tab alone does not stop the local server).

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
