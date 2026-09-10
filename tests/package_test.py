import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("packaging", ROOT / "scripts/package.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)

class PackageTests(unittest.TestCase):
    def test_archive_round_trip_and_source_unchanged(self):
        original = (ROOT / "extension/release.json").read_bytes()
        with tempfile.TemporaryDirectory(prefix="amnezia-package-test-") as temporary:
            output = Path(temporary) / "fixed.zip"
            PACKAGE.build(output, "example/project", "v1")
            version, count = PACKAGE.validate(output)
            self.assertEqual(version, "1")
            self.assertGreater(count, 20)
            with zipfile.ZipFile(output) as archive:
                data = json.loads(archive.read(PACKAGE.PREFIX + "extension/release.json"))
                self.assertEqual(data["repository"], "example/project")
                self.assertFalse(any("connection.json" in name or "__pycache__" in name or "/.git/" in name for name in archive.namelist()))
            self.assertEqual((ROOT / "extension/release.json").read_bytes(), original)

    def test_invalid_release_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="amnezia-package-test-") as temporary:
            output = Path(temporary) / "fixed.zip"
            with self.assertRaises(ValueError): PACKAGE.build(output, version="v2")
            with self.assertRaises(ValueError): PACKAGE.build(output, repository="https://example.test")

if __name__ == "__main__":
    unittest.main()
