# ALKO Proxy v0.5 — Local Windows build (Lua `BadZipFile` fixed)

**Status:** Dashboard executable included. Source-build instructions for the native engine included. The engine is *not* included as a precompiled binary and has **not** been live-tested against Growtopia 5.61.

## 1. Install build prerequisites (Windows 10/11, 64-bit)

Install the following from their official sites and restart PowerShell afterwards:

| Program | What to select |
| --- | --- |
| Visual Studio 2022 Build Tools | **Desktop development with C++** workload, MSVC v143 and a Windows SDK |
| Python 3.12 | Select **Add python.exe to PATH**; `python --version` should work |
| Git for Windows | Default installation is fine; `git --version` should work |
| CMake | Add CMake to PATH; `cmake --version` should work |

Conan 2 is installed automatically by the setup script. No game account is required for compilation.

## 2. Extract the complete v0.5 package

Extract `ALKOProxy-native-engine-build-kit-v0.5.zip`, for example into:

`C:\ALKOProxy\`

The following files should exist:

- `C:\ALKOProxy\ALKOProxy.exe` — already-built Windows dashboard
- `C:\ALKOProxy\engine\SETUP_ENGINE_WINDOWS.ps1` — native engine builder
- `C:\ALKOProxy\engine\PREPARE_LUA_WINDOWS.ps1` — updated Lua preparation
- `C:\ALKOProxy\engine\patch_lua_conan_recipe.py` — corrected tar.gz extraction

## 3. Build the native engine from source

Open **PowerShell** (ordinary user is fine) and run:

```powershell
cd C:\ALKOProxy
powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\SETUP_ENGINE_WINDOWS.ps1
```

The builder fetches the upstream GTProxy source, fetches and patches the ConanCenter Lua recipe, obtains an SHA-256-verified original Lua 5.4.6 archive from configured mirrors, builds Lua Release + Debug, configures GTProxy and attempts to compile `Proxy.exe`. It does **not** modify the system hosts file or certificates.

If successful, the engine will be placed at:

`C:\ALKOProxy\ALKO-native-engine\Proxy.exe`

**If you have a failed old `vendor\GTProxy\build` folder**, delete only that folder to clear stale CMake configuration before retrying. You can keep the source clone and the Conan cache:

```powershell
Remove-Item -Recurse -Force .\vendor\GTProxy\build -ErrorAction SilentlyContinue
powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\SETUP_ENGINE_WINDOWS.ps1
```

## 4. Launch the dashboard

Double-click `C:\ALKOProxy\ALKOProxy.exe` and open `http://127.0.0.1:8765` if the browser doesn't launch. In **Settings**, find the engine executable/path field and select:

`C:\ALKOProxy\ALKO-native-engine\Proxy.exe`

**That is a file path, not proof of a live connection.** The bridge, upstream login flow, native commands and Growtopia 5.61 compatibility must still be tested. Do not use an important game account for initial tests. There is no guaranteed ban protection.

## 5. Alternatively, run the GitHub Actions build

If you prefer GitHub's Windows runner, extract `ALKOProxy-Lua-BadZipFile-Fix-v0.5.zip` into your existing repository, replacing files and retaining directories, commit and push, then open **Actions → Build ALKO native GTProxy engine (Windows) → Run workflow**.

Look for **Prepare Lua from verified tar.gz and build locally (Release + Debug)**. If your run still shows the old steps `Cache verified Lua...` and `Build verified Lua locally...`, the repository has not picked up the v0.5 workflow.

If compilation succeeds, download `ALKO-native-GTProxy-Windows-x64` from the run's **Artifacts** section.

## Troubleshooting

- `BadZipFile`: verify the workflow uses the **v0.5** `patch_lua_conan_recipe.py`; the patched source should copy the archive to `lua-5.4.6.tar.gz` before extraction.
- `No compatible configuration found`: informational if the next line says **Build**; Conan is rebuilding a suitable binary.
- `lua.org SSL error`: indicates Conan is still using the old unpatched recipe or lacks `ALKO_LUA_ARCHIVE` in a later step. Check that `PREPARE_LUA_WINDOWS.ps1` ran successfully.
- `Could not find Visual Studio 17 2022`: install the VS 2022 C++ Build Tools workload.
- `conan: command not found`: restart PowerShell; the local builder attempts to find Python's `Scripts` folder after installing Conan.
- Any **new** compiler error: copy the **first error** above the final `exit code 1` line. That is the relevant issue.

## Verification notes

Seven local Python tests pass, including the extensionless-cache-to-tar.gz regression. CI YAML is parsed locally. The modified PowerShell scripts and full Windows native build were **not executed on Windows** in this environment. The Lua download is SHA-256 verified, but no blanket security or anti-ban guarantee is made.
