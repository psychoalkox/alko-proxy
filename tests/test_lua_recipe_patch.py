"""Regression tests for ALKO's offline ConanCenter Lua recipe patch.

The archive-format regression is tested with a REAL tar.gz whose original
cache filename deliberately has no extension, reproducing the Windows error.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import importlib.util
import io
from pathlib import Path
import os
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "engine" / "patch_lua_conan_recipe.py"
spec = importlib.util.spec_from_file_location("alko_lua_recipe_patch", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fake_recipe(folder: Path) -> Path:
    (folder / "conanfile.py").write_text(
        "from conan.tools.files import get\nclass LuaConan:\n" + module.TARGET + "\n"
        + "    def generate(self):\n        pass\n", encoding="utf-8"
    )
    (folder / "conandata.yml").write_text(
        f'sources:\n  "5.4.6":\n    sha256: "{module.LUA_SHA256}"\n', encoding="utf-8"
    )
    return module.patch(folder)


class LuaRecipePatchTests(unittest.TestCase):
    def test_precise_verified_recipe_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = fake_recipe(Path(tmp))
            data = out.read_text(encoding="utf-8")
            self.assertIn('ALKO_LUA_ARCHIVE', data)
            self.assertIn('"lua-5.4.6.tar.gz"', data)
            self.assertIn('extract_filter="data"', data)
            self.assertIn('    def generate(self):', data)
            self.assertNotIn(module.TARGET, data)
            compile(data, str(out), 'exec')
            # Safe to run again when developing locally.
            self.assertEqual(data, module.patch(Path(tmp)).read_text(encoding="utf-8"))

    def test_no_guessing_when_recipe_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'conanfile.py').write_text('def source(self):\n   print("changed")\n')
            (d / 'conandata.yml').write_text(
                f'"5.4.6": {module.LUA_SHA256}\n')
            with self.assertRaises(RuntimeError):
                module.patch(d)

    def test_extensionless_sha_cache_blob_extracts_as_tar_gz(self):
        # Actual Conan isn't installed in this environment. We simulate its
        # documented extension-sensitive extraction and verify the fixed source.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            recipe_path = fake_recipe(root)
            data = b'# Lua synthetic source file\n'
            archive_stream = io.BytesIO()
            with tarfile.open(fileobj=archive_stream, mode='w:gz') as archive:
                info = tarfile.TarInfo('lua-5.4.6/src/lua.h')
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            archive_bytes = archive_stream.getvalue()
            digest = hashlib.sha256(archive_bytes).hexdigest()
            # Conan's source-backup cache names files by digest with NO suffix.
            bare_archive = root / digest
            bare_archive.write_bytes(archive_bytes)
            # Only replace the hash in the test copy; shipped code retains
            # the exact official SHA256 for the actual Lua tarball.
            test_source = recipe_path.read_text(encoding="utf-8").replace(module.LUA_SHA256, digest)

            calls = []
            fake_conan = types.ModuleType('conan')
            fake_tools = types.ModuleType('conan.tools')
            fake_files = types.ModuleType('conan.tools.files')
            def fake_unzip(conanfile, filename, destination, strip_root, extract_filter):
                calls.append((filename, strip_root, extract_filter))
                self.assertTrue(filename.endswith('.tar.gz'))
                self.assertEqual(extract_filter, 'data')
                with tarfile.open(filename, 'r:gz') as f:
                    for member in f.getmembers():
                        relative = member.name.removeprefix('lua-5.4.6/')
                        if not relative or not member.isfile():
                            continue
                        dest = Path(destination) / relative
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_bytes(f.extractfile(member).read())
            fake_files.get = lambda *_args, **_kwargs: None
            fake_files.unzip = fake_unzip
            fake_tools.files = fake_files
            fake_conan.tools = fake_tools
            with patch.dict(sys.modules, {'conan': fake_conan, 'conan.tools': fake_tools, 'conan.tools.files': fake_files}), \
                 patch.dict(os.environ, {'ALKO_LUA_ARCHIVE': str(bare_archive)}):
                namespace = {}
                exec(compile(test_source, str(recipe_path), 'exec'), namespace)
                lua = namespace['LuaConan']()
                lua.source_folder = str(root / 'conan-source')
                lua.source()
            self.assertEqual((root / 'conan-source' / 'src' / 'lua.h').read_bytes(), data)
            self.assertEqual(len(calls), 1)
            self.assertTrue(bare_archive.is_file())
            self.assertFalse((root / 'conan-source' / 'lua-5.4.6.tar.gz').exists())

    def test_build_scripts_share_prep_helper_and_persist_environment(self):
        root = MODULE_PATH.parents[1]
        workflow = (root / '.github/workflows/build-native-windows.yml').read_text()
        prep = (root / 'engine/PREPARE_LUA_WINDOWS.ps1').read_text()
        local = (root / 'engine/SETUP_ENGINE_WINDOWS.ps1').read_text()
        self.assertIn('PREPARE_LUA_WINDOWS.ps1', workflow)
        self.assertIn('PREPARE_LUA_WINDOWS.ps1', local)
        self.assertIn('$env:GITHUB_ENV', prep)
        self.assertIn('$env:ALKO_LUA_ARCHIVE', prep)
        self.assertIn("'Release', 'Debug'", prep)

if __name__ == '__main__':
    unittest.main()
