$ErrorActionPreference = "Stop"

$InstallDir = Join-Path $env:LOCALAPPDATA "AmneziaBrowser"
$CorePath = Join-Path $InstallDir "mihomo.exe"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunName = "AmneziaBrowser"

if (Test-Path -LiteralPath $CorePath) {
    $normalized = [IO.Path]::GetFullPath($CorePath)

    Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ExecutablePath -and
        ([IO.Path]::GetFullPath($_.ExecutablePath) -eq $normalized)
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Amnezia Browser backend removed."
