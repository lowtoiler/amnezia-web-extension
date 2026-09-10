$ErrorActionPreference = "Stop"
$InstallDir = Join-Path $env:LOCALAPPDATA "AmneziaBrowser"
$Core = Join-Path $InstallDir "mihomo.exe"
$Manager = Join-Path $InstallDir "backend.ps1"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$PowerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Output "This removes the backend, its connection key, configuration and logs. Disable routing in the extension and remove the extension separately."
if (Test-Path -LiteralPath $InstallDir) {
    $lock = [IO.File]::Open((Join-Path $InstallDir "install.lock"),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Delete)
    try {
        if (Test-Path -LiteralPath $Manager) {
            & $PowerShellPath -NoProfile -NonInteractive -File $Manager -Action Stop
            if ($LASTEXITCODE -ne 0) { throw "Backend did not stop; files were not removed" }
        } else {
            foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" | Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq [IO.Path]::GetFullPath($Core) })) {
                $item = Get-Process -Id $process.ProcessId
                Stop-Process -Id $item.Id -Force
                if (-not $item.WaitForExit(5000)) { throw "Backend did not stop" }
            }
        }
        if ((Test-Path $RunKey) -and (Get-ItemProperty -Path $RunKey).PSObject.Properties.Name -contains "AmneziaBrowser") { Remove-ItemProperty -Path $RunKey -Name "AmneziaBrowser" }
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    } finally { $lock.Dispose() }
}
if ((Test-Path $RunKey) -and (Get-ItemProperty -Path $RunKey).PSObject.Properties.Name -contains "AmneziaBrowser") { Remove-ItemProperty -Path $RunKey -Name "AmneziaBrowser" }
if (Test-Path -LiteralPath $InstallDir) { throw "Backend directory was not removed" }
Write-Output "Backend files were removed. Browser extension and its routing settings must be removed separately."
