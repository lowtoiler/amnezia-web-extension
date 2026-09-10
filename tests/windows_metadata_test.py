from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WindowsMetadataTests(unittest.TestCase):
    def test_process_start_metadata_has_lossless_utc_legacy_ticks_and_owner(self):
        backend = (ROOT / "backend.ps1").read_text()
        logger = (ROOT / "scripts/log.ps1").read_text()
        self.assertIn('startedUtc=$supervisorStart.ToString("o",[Globalization.CultureInfo]::InvariantCulture)', backend)
        self.assertIn('startedUtc=$processStart.ToString("o",[Globalization.CultureInfo]::InvariantCulture)', logger)
        self.assertIn('started=([string]$supervisorStart.Ticks)', backend)
        self.assertIn('started=([string]$processStart.Ticks)', logger)
        self.assertIn('ownerPid=$PID', logger)

    def test_fresh_start_uses_supervisor_child_ownership(self):
        backend = (ROOT / "backend.ps1").read_text()
        self.assertIn('function Get-CoreProcessForSupervisor', backend)
        self.assertIn('[int]$data.ownerPid -ne $SupervisorPid', backend)
        self.assertIn('[int]$native.ParentProcessId -ne $SupervisorPid', backend)
        self.assertIn('Get-CoreProcessForSupervisor -SupervisorPid $process.Id', backend)

    def test_general_process_identity_has_owner_and_legacy_fallbacks(self):
        backend = (ROOT / "backend.ps1").read_text()
        self.assertIn('Get-CoreProcessForSupervisor -SupervisorPid $ownerPid', backend)
        self.assertIn('startedUtc', backend)
        self.assertIn('$metadataTimeMatches', backend)
        self.assertIn('LastWriteTimeUtc', backend)
        self.assertIn('ProcessName', backend)
        self.assertIn('OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($candidate),$target)', backend)


    def test_windows_wireguard_uses_mips_bbr(self):
        config = (ROOT / "scripts/config.ps1").read_text()
        self.assertIn('$lines.Add("    ip-stack:") | Out-Null', config)
        self.assertIn('$lines.Add("      mode: mips") | Out-Null', config)
        self.assertIn('$lines.Add("      congestion-controller: bbr") | Out-Null', config)

    def test_start_failure_contains_runtime_metadata(self):
        backend = (ROOT / "backend.ps1").read_text()
        self.assertIn("Get-BackendDiagnostic", backend)
        for field in ["supervisorAlive", "coreAlive", "coreName", "corePath", "ownerPid", "parentPid"]:
            self.assertIn(field, backend)
        self.assertIn("$index -lt 150", backend)

if __name__ == "__main__":
    unittest.main()
