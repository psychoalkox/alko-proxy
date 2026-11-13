# Windows engine startup error `0xC0000135`

The v0.6 engine imports `libssl-3-x64.dll` and `libcrypto-3-x64.dll`. Its packager searched the build tree and Conan cache, while the build used the OpenSSL SDK installed on the GitHub runner. The workflow logged both missing DLLs and still uploaded the artifact.

Use the artifact from the latest successful [Windows native engine build](https://github.com/psychoalkox/alko-proxy/actions/workflows/build-native-windows.yml). The packager bundles the OpenSSL DLLs from CMake's selected SDK and the Visual C++ runtime from the compiler's redistributable directory. Keep the extracted files together and select the new `Proxy.exe` in the dashboard.

For a local Release build, run the following from an x64 Visual Studio developer shell in the ALKO project folder.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\PACKAGE_ENGINE_WINDOWS.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\TEST_ENGINE_WINDOWS.ps1 -EngineExe .\ALKO-native-engine\Proxy.exe
```

`ENGINE_DLL_REPORT.txt` lists resolved and missing imports. The startup test checks for the engine's HTTPS listener on port 443 and a fresh ALKO bridge heartbeat. Close other GTProxy instances before running it so the engine can bind its ports.
