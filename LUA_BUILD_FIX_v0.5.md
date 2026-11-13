# Lua 5.4.6 BadZipFile fix — v0.5

The v0.4 patched recipe passed Conan's cache file (`<SHA256>`) directly to `conan.tools.files.unzip`. Conan selected ZIP handling because the filename lacked the `.tar.gz` extension. The file was a genuine gzip-compressed tar archive, causing `BadZipFile: File is not a zip file`.

v0.5 changes only the source download/extraction method in the official ConanCenter Lua recipe:

1. Acquire an original SHA256-verified Lua 5.4.6 archive from the mirror list (unchanged).
2. Put the archive into `ALKO_LUA_ARCHIVE` environment variable.
3. During Conan's `source()`, check SHA256 and **copy it into the Conan source directory as `lua-5.4.6.tar.gz`**.
4. Extract using Conan's `unzip(..., strip_root=True, extract_filter="data")`, now with the proper archive extension.
5. Delete the temporary named archive.

The same preparation script now runs in local Windows builds and GitHub Actions. The workflow exports `ALKO_LUA_ARCHIVE` via GitHub's `GITHUB_ENV` so a subsequent CMake/Conan invocation still has the path. Both Release and Debug Lua packages are prebuilt to reduce MSVC configuration mismatches.

The regression test creates a real tar.gz stored under an extensionless name and verifies the patched source extracts it. Seven local tests pass, but the actual Windows compilation has not been tested here.
