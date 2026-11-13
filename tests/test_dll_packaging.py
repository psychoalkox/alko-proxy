from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DllPackagingTests(unittest.TestCase):
    def test_packager_starts_with_real_executable(self):
        s = (ROOT / "engine" / "PACKAGE_ENGINE_WINDOWS.ps1").read_text()
        self.assertIn("Proxy.exe", s)
        self.assertIn("dumpbin.exe /DEPENDENTS", s)
        self.assertIn("ENGINE_DLL_REPORT.txt", s)
        self.assertIn(".conan2", s)
        self.assertIn("MICROSOFT VC RUNTIME", s)

    def test_local_build_uses_packager(self):
        s = (ROOT / "engine" / "SETUP_ENGINE_WINDOWS.ps1").read_text()
        self.assertIn("PACKAGE_ENGINE_WINDOWS.ps1", s)

    def test_ci_build_uses_packager(self):
        s = (ROOT / ".github/workflows/build-native-windows.yml").read_text()
        self.assertIn("PACKAGE_ENGINE_WINDOWS.ps1", s)
        self.assertIn("Upload compiled engine", s)

if __name__ == '__main__': unittest.main()
