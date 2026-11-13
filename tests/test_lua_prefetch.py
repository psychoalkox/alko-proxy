import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'engine' / 'prime_conan_lua.py'
spec = importlib.util.spec_from_file_location('prime_conan_lua', MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ContextResponse(io.BytesIO):
    pass


class TestLuaPrefetch(unittest.TestCase):
    def test_fetch_fallback_and_correct_checksum(self):
        content = b'fixed lua archive mock'
        digest = hashlib.sha256(content).hexdigest()
        attempts = []
        def opener(request, timeout):
            attempts.append(request.full_url)
            if len(attempts) == 1:
                raise ConnectionResetError('simulate source host outage')
            return ContextResponse(content)
        out = mod.fetch_verified(('https://offline.invalid', 'https://mirror.invalid'), digest, opener)
        self.assertEqual(out, content)
        self.assertEqual(len(attempts), 2)

    def test_no_unverified_archive_persisted(self):
        with tempfile.TemporaryDirectory() as d:
            home, cache = Path(d) / 'conan', Path(d) / 'sources'
            def opener(request, timeout):
                return ContextResponse(b'wrong contents')
            with self.assertRaises(RuntimeError):
                mod.prime_cache(cache, home, sources=('https://mirror.invalid',), opener=opener)
            self.assertFalse((cache / mod.LUA_SHA256).exists())

    def test_cache_reuse_and_config_preservation(self):
        content = b'known good bytes'
        digest = hashlib.sha256(content).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            home, cache = Path(d) / 'conan', Path(d) / 'sources'
            home.mkdir()
            (home/'global.conf').write_text('core:non_interactive=True\ncore.sources:download_cache=old\n')
            def opener(request, timeout):
                return ContextResponse(content)
            path = mod.prime_cache(cache, home, expected_sha256=digest,
                                   sources=('https://mirror.invalid',), opener=opener)
            self.assertEqual(path.read_bytes(), content)
            def failed_opener(request, timeout):
                raise AssertionError('Network should not be used for cached archive')
            mod.prime_cache(cache, home, expected_sha256=digest, opener=failed_opener)
            config = (home/'global.conf').read_text()
            self.assertIn('core:non_interactive=True', config)
            self.assertEqual(config.count('core.sources:download_cache='), 1)
            self.assertIn(cache.resolve().as_posix(), config)

if __name__ == '__main__':
    unittest.main()
