import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class BackendTests(unittest.TestCase):
    def test_windows_start_normalizes_single_core_result_to_array(self):
        source = (ROOT / "backend.ps1").read_text(encoding="utf-8")
        self.assertIn('if (@(Get-CoreProcessForSupervisor -SupervisorPid $process.Id).Count -gt 0)', source)
        self.assertNotIn('if ((Get-CoreProcessForSupervisor -SupervisorPid $process.Id).Count -gt 0)', source)

    def test_supervision_concurrent_start_and_owned_process_stop(self):
        with tempfile.TemporaryDirectory(prefix="amnezia-supervisor-test-") as temporary:
            folder = Path(temporary)
            install = folder / "install"
            config = folder / "config"
            install.mkdir()
            config.mkdir()
            source = folder / "fixture.c"
            source.write_text("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n")
            subprocess.run(["gcc", str(source), "-o", str(install / "mihomo")], check=True)
            shutil.copy2(install / "mihomo", folder / "unrelated-mihomo")
            shutil.copy2(ROOT / "backend.sh", install / "backend.sh")
            shutil.copy2(ROOT / "scripts/log.sh", install / "log.sh")
            (install / "backend.sh").chmod(0o700)
            (config / "config.yaml").write_text("test fixture only\n")
            environment = dict(os.environ, AMNEZIA_BROWSER_INSTALL_DIR=str(install), AMNEZIA_BROWSER_CONFIG_DIR=str(config))
            manager = str(install / "backend.sh")
            def invoke(action):
                return subprocess.run([manager, action], env=environment, capture_output=True, text=True, timeout=25)
            def pids():
                found = []
                for proc in Path("/proc").glob("[0-9]*"):
                    try:
                        if (proc / "exe").resolve(strict=True) == install / "mihomo": found.append(int(proc.name))
                    except (OSError, RuntimeError): pass
                return found
            unrelated = subprocess.Popen([str(folder / "unrelated-mihomo")])
            try:
                first = subprocess.Popen([manager, "start"], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                second = subprocess.Popen([manager, "start"], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for process in [first, second]:
                    out, err = process.communicate(timeout=15)
                    self.assertEqual(process.returncode, 0, (out + err).decode() + "\n" + "\n".join(file.read_text() for file in install.glob("*.log")))
                self.assertEqual(len(pids()), 1)
                old_pid = pids()[0]
                os.kill(old_pid, signal.SIGKILL)
                limit = time.monotonic() + 6
                while time.monotonic() < limit:
                    current = pids()
                    if current and old_pid not in current: break
                    time.sleep(0.1)
                self.assertEqual(len(pids()), 1)
                self.assertNotEqual(pids()[0], old_pid)
                self.assertEqual(invoke("status").returncode, 0)
                result = invoke("stop")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(pids(), [])
                self.assertIsNone(unrelated.poll())
                self.assertNotEqual(invoke("status").returncode, 0)
            finally:
                invoke("stop")
                unrelated.terminate()
                unrelated.wait(timeout=5)

if __name__ == "__main__":
    if not shutil.which("gcc") or not Path("/proc").exists():
        raise SystemExit("Linux /proc and gcc are required for lifecycle tests")
    if os.readlink("/proc/self") != str(os.getpid()):
        raise SystemExit("BLOCKED: /proc and the test process use different PID namespaces; run on a regular Linux host")
    unittest.main()
