import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 8192

class LogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="amnezia-log-test-")
        self.addCleanup(self.directory.cleanup)
        self.file = Path(self.directory.name) / "backend.log"

    def command(self):
        return ["bash", str(ROOT / "scripts/log.sh"), str(self.file), str(LIMIT)]

    def write(self, data):
        result = subprocess.run(self.command(), input=data, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result

    def retained(self):
        previous = self.file.with_suffix(".log.previous")
        return (previous.read_bytes() if previous.exists() else b"") + self.file.read_bytes()

    def assert_bounded(self):
        for file in [self.file, self.file.with_suffix(".log.previous")]:
            if file.exists(): self.assertLessEqual(file.stat().st_size, LIMIT)

    def test_binary_unicode_and_long_lines(self):
        data = (bytes(range(256)) + "Ошибка туннеля\n".encode()) * 500
        self.write(data)
        self.assert_bounded()
        retained = self.retained()
        self.assertGreaterEqual(len(retained), LIMIT)
        self.assertEqual(retained, data[-len(retained):])

    def test_repeated_writers_append_until_rotation(self):
        combined = b""
        for data in [b"first\n", b"x" * 8000, b"second\n", b"y" * 10000]:
            self.write(data)
            combined += data
            self.assert_bounded()
            retained = self.retained()
            self.assertEqual(retained, combined[-len(retained):])

    def test_already_oversized_logs_are_bounded(self):
        self.file.write_bytes(b"a" * (LIMIT * 3))
        self.file.with_suffix(".log.previous").write_bytes(b"b" * (LIMIT * 5))
        self.write(b"last error")
        self.assert_bounded()
        self.assertTrue(self.retained().endswith(b"last error"))

    def test_partial_line_is_written_before_stream_closes(self):
        process = subprocess.Popen(self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b"error without newline")
            process.stdin.flush()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if self.file.exists() and self.file.read_bytes() == b"error without newline": break
                time.sleep(0.02)
            self.assertEqual(self.file.read_bytes(), b"error without newline")
            self.assertIsNone(process.poll())
        finally:
            process.stdin.close()
            self.assertEqual(process.wait(timeout=5), 0, process.stderr.read().decode())
            process.stdout.close()
            process.stderr.close()

    def test_partial_line_after_rotation_is_written_before_stream_closes(self):
        self.write(b"x" * LIMIT)
        self.test_partial_line_is_written_before_stream_closes()
        self.assert_bounded()

    def test_concurrent_writer_is_rejected(self):
        process = subprocess.Popen(self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not self.file.exists() and time.monotonic() < deadline: time.sleep(0.02)
            rejected = subprocess.run(self.command(), input=b"conflict", capture_output=True, timeout=3)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"Another writer", rejected.stderr)
        finally:
            process.stdin.close()
            self.assertEqual(process.wait(timeout=5), 0, process.stderr.read().decode())
            process.stdout.close()
            process.stderr.close()

    def test_invalid_output_is_a_visible_failure(self):
        self.file.mkdir()
        result = subprocess.run(self.command(), input=b"error", capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"regular file", result.stderr)

if __name__ == "__main__":
    unittest.main()
