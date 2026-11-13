"""Patch ConanCenter Lua 5.4.6 to consume a SHA256-verified local .tar.gz.

The official recipe keeps its own build and package logic. Only source() is
replaced, so the source acquisition never needs to contact www.lua.org.

Why the filename matters: conan.tools.files.unzip() selects the archive
format using the filename extension. The original verified cache blob is named
by SHA256 (no .tar.gz suffix); passing it directly made Conan try ZIP extraction.
"""
from __future__ import annotations

import argparse
from pathlib import Path

LUA_SHA256 = "7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88"
PATCH_MARKER = "# ALKO-LUA-5.4.6-LOCAL-ARCHIVE-V0.5"

TARGET = '''    def source(self):
        get(self, **self.conan_data["sources"][self.version], strip_root=True)'''

REPLACEMENT = '''    def source(self):
        # ALKO-LUA-5.4.6-LOCAL-ARCHIVE-V0.5
        # Keep ConanCenter's build/package methods unchanged. Extract a real
        # .tar.gz, not the SHA256-named cache blob (which Conan treats as ZIP).
        import hashlib
        import os
        import shutil
        from pathlib import Path
        from conan.tools.files import unzip

        archive_var = os.environ.get("ALKO_LUA_ARCHIVE")
        if not archive_var:
            raise RuntimeError("ALKO_LUA_ARCHIVE is missing. Run the ALKO Lua preparation step first.")
        archive = Path(archive_var).resolve()
        if not archive.is_file():
            raise RuntimeError(f"Verified Lua archive not found: {archive}")
        expected = "7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88"
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Lua source SHA256 mismatch: {actual}; expected {expected}")

        # Conan determines archive type from filename, so preserve .tar.gz.
        source_dir = Path(self.source_folder)
        source_dir.mkdir(parents=True, exist_ok=True)
        named_archive = source_dir / "lua-5.4.6.tar.gz"
        if archive != named_archive:
            shutil.copyfile(archive, named_archive)
        try:
            unzip(self, str(named_archive), destination=str(source_dir),
                  strip_root=True, extract_filter="data")
        finally:
            # Keep the extracted source but not the temporary tarball.
            if archive != named_archive:
                named_archive.unlink(missing_ok=True)'''


def patch(recipe_directory: Path) -> Path:
    recipe = recipe_directory / "conanfile.py"
    data = recipe_directory / "conandata.yml"
    if not recipe.is_file() or not data.is_file():
        raise RuntimeError(f"ConanCenter Lua recipe files missing in {recipe_directory}")
    datatext = data.read_text(encoding="utf-8")
    if '"5.4.6"' not in datatext or LUA_SHA256 not in datatext:
        raise RuntimeError("Recipe conandata.yml is missing the expected Lua 5.4.6 version/checksum")
    original = recipe.read_text(encoding="utf-8")
    if PATCH_MARKER in original:
        print(f"Lua recipe already patched: {recipe}")
        return recipe
    if original.count(TARGET) != 1:
        raise RuntimeError("ConanCenter Lua recipe changed or already has a different patch; review it manually")
    updated = original.replace(TARGET, REPLACEMENT)
    compile(updated, str(recipe), "exec")
    recipe.write_text(updated, encoding="utf-8")
    return recipe


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe_directory", type=Path)
    args = parser.parse_args()
    result = patch(args.recipe_directory)
    print(f"Verified Lua .tar.gz recipe patch: {result}")


if __name__ == "__main__":
    main()
