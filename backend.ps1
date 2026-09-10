param([ValidateSet("Start","Stop","Restart","Status","Check","Run")][string]$Action = "Status")
$ErrorActionPreference = "Stop"
$InstallDir = Join-Path $env:LOCALAPPDATA "AmneziaBrowser"
$Core = Join-Path $InstallDir "mihomo.exe"
$Config = Join-Path $InstallDir "config.yaml"
$Manager = Join-Path $InstallDir "backend.ps1"
$PidFile = Join-Path $InstallDir "supervisor.json"
$CorePidFile = Join-Path $InstallDir "core.json"
$Log = Join-Path $InstallDir "mihomo.log"
$ErrorLog = Join-Path $InstallDir "mihomo-error.log"
$PowerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function Get-CoreProcessForSupervisor {
    param([int]$SupervisorPid)
    if ($SupervisorPid -le 0 -or -not (Test-Path -LiteralPath $CorePidFile)) { return @() }
    try {
        $data = Get-Content -Raw -LiteralPath $CorePidFile | ConvertFrom-Json
        if (-not ($data.PSObject.Properties.Name -contains "ownerPid") -or [int]$data.ownerPid -ne $SupervisorPid) { return @() }
        $pidValue = [int]$data.pid
        $item = Get-Process -Id $pidValue -ErrorAction Stop
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($item.ProcessName,[IO.Path]::GetFileNameWithoutExtension($Core))) { return @() }
        try {
            $native = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $pidValue) -ErrorAction Stop
            if ($native -and [int]$native.ParentProcessId -ne $SupervisorPid) { return @() }
        } catch {}
        return @([pscustomobject]@{ ProcessId=$item.Id })
    } catch { return @() }
}
function Get-CoreProcess {
    $target = [IO.Path]::GetFullPath($Core)
    if (Test-Path -LiteralPath $CorePidFile) {
        try {
            $data = Get-Content -Raw -LiteralPath $CorePidFile | ConvertFrom-Json
            if ($data.PSObject.Properties.Name -contains "ownerPid") {
                $ownerPid = [int]$data.ownerPid
                try {
                    $owner = Get-Process -Id $ownerPid -ErrorAction Stop
                    if ([StringComparer]::OrdinalIgnoreCase.Equals($owner.ProcessName,[IO.Path]::GetFileNameWithoutExtension($PowerShellPath))) {
                        $owned = @(Get-CoreProcessForSupervisor -SupervisorPid $ownerPid)
                        if ($owned.Count -gt 0) { return $owned }
                    }
                } catch {}
            }
            $pidValue = [int]$data.pid
            $item = Get-Process -Id $pidValue -ErrorAction Stop
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($item.ProcessName,[IO.Path]::GetFileNameWithoutExtension($Core))) { return @() }
            $candidate = $null
            try { $candidate = $item.Path } catch {}
            if ($candidate -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($candidate),$target)) { return @([pscustomobject]@{ ProcessId=$item.Id }) }
            $startMatches = $false
            try {
                if ($data.PSObject.Properties.Name -contains "startedUtc" -and [string]$data.startedUtc) {
                    $expectedUtc = [DateTime]::Parse([string]$data.startedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                    $startMatches = [Math]::Abs(($item.StartTime.ToUniversalTime() - $expectedUtc).TotalSeconds) -le 2
                } elseif ($data.PSObject.Properties.Name -contains "started") {
                    $expected = [long]([string]$data.started)
                    $actual = [long]$item.StartTime.ToUniversalTime().Ticks
                    $startMatches = [Math]::Abs($actual - $expected) -le [TimeSpan]::TicksPerSecond * 2
                }
            } catch {}
            $metadataTimeMatches = $false
            try { $metadataTimeMatches = [Math]::Abs(((Get-Item -LiteralPath $CorePidFile).LastWriteTimeUtc - $item.StartTime.ToUniversalTime()).TotalSeconds) -le 10 } catch {}
            if ($startMatches -or $metadataTimeMatches) { return @([pscustomobject]@{ ProcessId=$item.Id }) }
        } catch {}
    }
    $result = @()
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction Stop)) {
            $candidate = $process.ExecutablePath
            if (-not $candidate) {
                try { $candidate = (Get-Process -Id $process.ProcessId -ErrorAction Stop).Path } catch { $candidate = $null }
            }
            if ($candidate -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($candidate),$target)) { $result += $process }
        }
    } catch {}
    return $result
}
function Get-BackendDiagnostic {
    $supervisorFile = Test-Path -LiteralPath $PidFile
    $coreFile = Test-Path -LiteralPath $CorePidFile
    $supervisorPid = $null
    $supervisorAlive = $false
    if ($supervisorFile) {
        try { $supervisorPid = [int](Get-Content -Raw -LiteralPath $PidFile | ConvertFrom-Json).pid } catch {}
        if ($supervisorPid) { try { $supervisorAlive = -not (Get-Process -Id $supervisorPid -ErrorAction Stop).HasExited } catch {} }
    }
    $corePid = $null
    $coreAlive = $false
    $coreName = $null
    $corePath = $null
    $ownerPid = $null
    $parentPid = $null
    if ($coreFile) {
        try {
            $coreData = Get-Content -Raw -LiteralPath $CorePidFile | ConvertFrom-Json
            $corePid = [int]$coreData.pid
            if ($coreData.PSObject.Properties.Name -contains "ownerPid") { $ownerPid = [int]$coreData.ownerPid }
        } catch {}
    }
    if ($corePid) {
        try {
            $coreItem = Get-Process -Id $corePid -ErrorAction Stop
            $coreAlive = -not $coreItem.HasExited
            $coreName = $coreItem.ProcessName
            try { $corePath = $coreItem.Path } catch {}
        } catch {}
        try {
            $native = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $corePid) -ErrorAction Stop
            if ($native) { $parentPid = [int]$native.ParentProcessId }
        } catch {}
    }
    return "supervisor.json=$supervisorFile; supervisorPid=$supervisorPid; supervisorAlive=$supervisorAlive; core.json=$coreFile; corePid=$corePid; coreAlive=$coreAlive; coreName=$coreName; corePath=$corePath; ownerPid=$ownerPid; parentPid=$parentPid"
}
function Get-Supervisor {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try {
        $data = Get-Content -Raw -LiteralPath $PidFile | ConvertFrom-Json
        $item = Get-Process -Id ([int]$data.pid) -ErrorAction Stop
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($item.ProcessName,[IO.Path]::GetFileNameWithoutExtension($PowerShellPath))) { return $null }
        $startMatches = $false
        try {
            if ($data.PSObject.Properties.Name -contains "startedUtc" -and [string]$data.startedUtc) {
                $expectedUtc = [DateTime]::Parse([string]$data.startedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                $startMatches = [Math]::Abs(($item.StartTime.ToUniversalTime() - $expectedUtc).TotalSeconds) -le 2
            } elseif ($data.PSObject.Properties.Name -contains "started") {
                $expected = [long]([string]$data.started)
                $actual = [long]$item.StartTime.ToUniversalTime().Ticks
                $startMatches = [Math]::Abs($actual - $expected) -le [TimeSpan]::TicksPerSecond * 2
            }
        } catch {}
        $metadataTimeMatches = $false
        try { $metadataTimeMatches = [Math]::Abs(((Get-Item -LiteralPath $PidFile).LastWriteTimeUtc - $item.StartTime.ToUniversalTime()).TotalSeconds) -le 10 } catch {}
        if (-not $startMatches -and -not $metadataTimeMatches) { return $null }
        return $item
    } catch { return $null }
}
function Stop-Backend {
    $supervisor = Get-Supervisor
    if ($supervisor) { Stop-Process -Id $supervisor.Id -Force; if (-not $supervisor.WaitForExit(5000)) { throw "Supervisor did not stop within 5 seconds" } }
    foreach ($process in (Get-CoreProcess)) {
        $item = Get-Process -Id $process.ProcessId
        Stop-Process -Id $item.Id -Force
        if (-not $item.WaitForExit(5000)) { throw "Backend did not stop within 5 seconds" }
    }
    if ((Get-CoreProcess).Count -gt 0) { throw "Backend is still running" }
    if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force }
    if (Test-Path -LiteralPath $CorePidFile) { Remove-Item -LiteralPath $CorePidFile -Force }
    if (Test-Path -LiteralPath ($CorePidFile + ".new")) { Remove-Item -LiteralPath ($CorePidFile + ".new") -Force }
}
function Start-Backend {
    if (Get-Supervisor) { Write-Output "Supervisor is already running"; return }
    if (-not (Test-Path -LiteralPath $Core) -or -not (Test-Path -LiteralPath $Config)) { throw "Backend is not installed" }
    if ((Get-CoreProcess).Count -gt 0) { throw "An unmanaged backend is running; use Restart" }
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -File "{0}" -Action Run' -f $Manager
    $parameters = @{ FilePath=$PowerShellPath; ArgumentList=$arguments; WindowStyle="Hidden"; PassThru=$true; RedirectStandardOutput=(Join-Path $InstallDir "supervisor-start.log"); RedirectStandardError=(Join-Path $InstallDir "supervisor-start-error.log") }
    $process = Start-Process @parameters
    for ($index=0; $index -lt 150; $index++) {
        if ($process.HasExited) { throw ("Supervisor failed. {0}. Check supervisor-start-error.log and supervisor.log" -f (Get-BackendDiagnostic)) }
        if (@(Get-CoreProcessForSupervisor -SupervisorPid $process.Id).Count -gt 0) { Write-Output "Backend process started"; return }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
    throw ("Backend process did not start. {0}. Check supervisor-start-error.log, supervisor.log and mihomo-error.log" -f (Get-BackendDiagnostic))
}
function Test-DataPath {
    if ((Get-CoreProcess).Count -eq 0) { throw "Backend process is not running" }
    $curl = Get-Command curl.exe -ErrorAction Stop
    foreach ($url in @("https://cp.cloudflare.com/generate_204","https://www.gstatic.com/generate_204")) {
        $code = & $curl.Source -sS --proxy socks5h://127.0.0.1:1080 --noproxy localhost,127.0.0.1 --connect-timeout 5 --max-time 12 -o NUL -w "%{http_code}" $url
        if ($LASTEXITCODE -eq 0 -and $code -in @("200","204")) { Write-Output "SOCKS HTTP data path: OK ($url)"; return }
    }
    throw "SOCKS HTTP data path could not be confirmed"
}
function Run-Supervisor {
    if (-not (Test-Path -LiteralPath $Core) -or -not (Test-Path -LiteralPath $Config)) { throw "Backend is not installed" }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $suffix = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($InstallDir))).Replace("-","") } finally { $hasher.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ("Local\AmneziaBrowserSupervisor" + $suffix))
    $owned = $false
    . (Join-Path $InstallDir "log.ps1")
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return }
        if ((Get-CoreProcess).Count -gt 0) { throw "An unmanaged backend is running; use Restart" }
        $supervisorStart = (Get-Process -Id $PID).StartTime.ToUniversalTime(); $metadata = @{ pid=$PID; started=([string]$supervisorStart.Ticks); startedUtc=$supervisorStart.ToString("o",[Globalization.CultureInfo]::InvariantCulture) }
        [IO.File]::WriteAllText(($PidFile + ".new"), ($metadata | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath ($PidFile + ".new") -Destination $PidFile -Force
        $attempt = 0
        while ($attempt -lt 5) {
            $started = [DateTime]::UtcNow
            $result = Invoke-LoggedProcess -FilePath $Core -Arguments ('-d "{0}" -f "{1}"' -f $InstallDir,$Config) -OutputLog $Log -ErrorLog $ErrorLog -ProcessMetadataPath $CorePidFile
            Write-BoundedText (Join-Path $InstallDir "supervisor.log") ("Backend exited with status {0}" -f $result)
            if (([DateTime]::UtcNow - $started).TotalSeconds -ge 60) { $attempt = 0 }
            $attempt++
            if ($attempt -lt 5) { Start-Sleep -Seconds ($attempt * 2) }
        }
        throw "Backend stopped after repeated failures"
    } catch {
        if ($owned) { Write-BoundedText (Join-Path $InstallDir "supervisor.log") $_.Exception.Message }
        throw
    } finally {
        if ($owned) {
            if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force }
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}
if (-not (Test-Path -LiteralPath $InstallDir)) { throw "Backend is not installed" }
$operationMutex = $null
$operationOwned = $false
try {
    if ($Action -in @("Start","Stop","Restart")) {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $suffix = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($InstallDir))).Replace("-","") } finally { $hasher.Dispose() }
        $operationMutex = New-Object Threading.Mutex($false, ("Local\AmneziaBrowserOperation" + $suffix))
        try { $operationOwned = $operationMutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $operationOwned = $true }
        if (-not $operationOwned) { throw "Another backend operation is running" }
    }
switch ($Action) {
    "Start" { Start-Backend }
    "Stop" { Stop-Backend }
    "Restart" { Stop-Backend; Start-Backend }
    "Check" { Test-DataPath }
    "Run" { Run-Supervisor }
    "Status" {
        $supervisor = Get-Supervisor
        [pscustomobject]@{ SupervisorPid=if ($supervisor) { $supervisor.Id } else { $null }; CorePids=@((Get-CoreProcess) | ForEach-Object { $_.ProcessId }) }
    }
}

} finally {
    if ($operationOwned) { $operationMutex.ReleaseMutex() }
    if ($operationMutex) { $operationMutex.Dispose() }
}
