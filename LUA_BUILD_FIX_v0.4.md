# ALKO Proxy v0.4 — Lua/5.4.6 Conan download blocker

The original 5.4.6 package fails to download from lua.org (TLS reset). v0.3 tried adding a verified download cache, but your latest log proves Conan still reached lua.org. The v0.4 workflow **changes approach**: it builds Lua from a checksum-verified archive as a local Conan package before it configures GTProxy.

## Use

1. In your existing GitHub repo, replace `.github/workflows/build-native-windows.yml` and add `engine/patch_lua_conan_recipe.py`. Existing `engine/prime_conan_lua.py` must be present.
2. Commit the changes (GitHub Actions only runs committed workflows).
3. Open Actions → **Build ALKO native GTProxy engine (Windows)** → **Run workflow**.
4. Confirm the job log includes **Build verified Lua locally before GTProxy (bypasses lua.org entirely)**. If this step is absent, you ran an old workflow/revision.

What the new workflow does:
* Downloads the Lua 5.4.6 tarball from a mirror and verifies official SHA-256 `7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88`.
* Fetches the official ConanCenter Lua recipe (the same source recipe already used by the project).
* Changes only the recipe's `source()` method to load that verified local tarball instead of downloading from lua.org.
* Runs `conan create ... --version=5.4.6 -s build_type=Release --build=missing` before CMake. CMake's Conan provider can then reuse the locally exported recipe rather than downloading Lua from the failing site.
* Configures the Windows build as Release.

If it fails again, the error should now be in **Cache verified Lua**, **Build verified Lua locally**, or a later dependency/compile step, rather than Lua source download at lua.org.

## Limits

The workflow and Python patch are syntax/structure tested; no Windows GitHub Actions run is possible in this environment. This is a build fix, not a v5.61 compatibility guarantee or a promise of avoiding account suspension. Do not use valuable game accounts to test an unverified native relay.
