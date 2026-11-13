# ALKO Proxy v0.6 – Engine exits with 0xc0000135

The native Windows loader returned `STATUS_DLL_NOT_FOUND`, which indicates that `Proxy.exe` requires a DLL unavailable on the target PC. It **does not** establish game-server compatibility or ban status.

## Fastest fix for your existing engine (no rebuilding)

1. Install the official **Microsoft Visual C++ Redistributable for x64**: https://aka.ms/vc14/vc_redist.x64.exe
2. Restart `ALKOProxy.exe`, then start the native engine again.
3. If it still exits, open PowerShell in the ALKO project folder and run:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\DIAGNOSE_ENGINE_WINDOWS.ps1 -EngineExe 'C:\ALKOProxy\ALKO-native-engine\Proxy.exe'
   ```
4. If Visual Studio Build Tools are installed, run the command inside **x64 Native Tools Command Prompt for VS 2022** so `dumpbin.exe` is available. Run `dumpbin /DEPENDENTS "C:\ALKOProxy\ALKO-native-engine\Proxy.exe"` and check the listed DLLs. Alternatively use the trusted open-source [Dependencies tool](https://github.com/lucasg/Dependencies) for missing indirect DLLs.
5. Copy only DLLs from your own verified build/dependency folders, and do not download arbitrary DLLs from third-party sites.

## Fix future packaged builds

The v0.5 workflow copied only `Proxy.exe`, `scripts`, and `resources`. v0.6 adds `engine/PACKAGE_ENGINE_WINDOWS.ps1` to enumerate native imports (`dumpbin /DEPENDENTS`) and bring required **non-system** DLLs from the Release tree or Conan package cache into `ALKO-native-engine`. It also creates `ENGINE_DLL_REPORT.txt` documenting any unresolved imports and references Microsoft's supported VC++ redistributable rather than repackaging system DLLs.

The same packaging script runs from `.github/workflows/build-native-windows.yml` or `engine/SETUP_ENGINE_WINDOWS.ps1` locally.

### GitHub Actions
Replace files from the v0.6 fix-only ZIP in your existing repository, commit, and re-run **Build ALKO native GTProxy engine (Windows)**. Download the new `ALKO-native-GTProxy-Windows-x64` artifact, keep its files together, and select its `Proxy.exe` from the dashboard. Inspect `ENGINE_DLL_REPORT.txt` if it still exits.

### Local compilation
If you already have `vendor/GTProxy` and a successful CMake build, rerun from your extracted ALKO project folder:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\PACKAGE_ENGINE_WINDOWS.ps1
```
If you need to compile from scratch, use:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\SETUP_ENGINE_WINDOWS.ps1
```

**Test status:** Code and workflow have not been executed on Windows. This release fixes the known omission in release packaging, but a working native engine and Growtopia 5.61 connection remain unverified.
