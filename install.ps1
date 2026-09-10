param([string]$ConfigPath)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$SourceDir = $PSScriptRoot
. (Join-Path $SourceDir "scripts\config.ps1")
. (Join-Path $SourceDir "scripts\log.ps1")
$CoreVersion = "v1.19.30"
$InstallDir = Join-Path $env:LOCALAPPDATA "AmneziaBrowser"
$CorePath = Join-Path $InstallDir "mihomo.exe"
$RuntimeConfig = Join-Path $InstallDir "config.yaml"
$ConnectionPath = Join-Path $InstallDir "connection.json"
$ManagerPath = Join-Path $InstallDir "backend.ps1"
$LogHelperPath = Join-Path $InstallDir "log.ps1"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunName = "AmneziaBrowser"
$PowerShellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Set-PrivateAccess {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $isDirectory = $item -is [IO.DirectoryInfo]
    if (-not $isDirectory -and $item -isnot [IO.FileInfo]) { throw "Private access requires a file or directory" }
    $acl = if ($isDirectory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $userSid = $currentUser.User } finally { $currentUser.Dispose() }
    $allowedSids = @($userSid.Value,"S-1-5-18","S-1-5-32-544")
    $existingOwner = (Get-Acl -LiteralPath $item.FullName -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($existingOwner -notin $allowedSids) { throw "Install target is owned by another account: $Path" }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $allowedSids) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $inheritance = if ($isDirectory) { [Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit" } else { [Security.AccessControl.InheritanceFlags]::None }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    if ($PSVersionTable.PSEdition -eq "Core") {
        [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
    } else {
        $item.SetAccessControl($acl)
    }
}
function Get-InstalledCoreProcess {
    $target = [IO.Path]::GetFullPath($CorePath)
    $result = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'")) {
        $candidate = $process.ExecutablePath
        if (-not $candidate) {
            try { $candidate = (Get-Process -Id $process.ProcessId -ErrorAction Stop).Path } catch { $candidate = $null }
        }
        if ($candidate -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($candidate),$target)) { $result += $process }
    }
    return $result
}
function Stop-LegacyCore {
    $processes = @(Get-InstalledCoreProcess)
    foreach ($process in $processes) {
        $item = Get-Process -Id $process.ProcessId
        Stop-Process -Id $item.Id -Force
        if (-not $item.WaitForExit(5000)) { throw "Previous backend did not stop" }
    }
}
function Invoke-Manager {
    param([string]$Operation)
    & $PowerShellPath -NoProfile -NonInteractive -File $ManagerPath -Action $Operation
    if ($LASTEXITCODE -ne 0) { throw "Backend operation failed: $Operation" }
}
function Assert-PortsAvailable {
    foreach ($port in @(1080,9090)) {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$port)
        $listener.ExclusiveAddressUse = $true
        try { $listener.Start() } catch { throw "Port $port is occupied by another application" } finally { $listener.Stop() }
    }
}
$ConfigPath = Select-Config $ConfigPath
$null = Read-Ini $ConfigPath
$null = Get-Command curl.exe -ErrorAction Stop
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-PrivateAccess $InstallDir
$lock = [IO.File]::Open((Join-Path $InstallDir "install.lock"),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("amnezia-browser-" + [Guid]::NewGuid().ToString("N"))
$swapStarted = $false
$installed = $false
$rollbackFailed = $false
$oldRunning = $false
$backups = @{}
$oldRun = $null
try {
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    Set-PrivateAccess $tempDir
    $secret = ""
    if (Test-Path -LiteralPath $ConnectionPath) {
        $existing = Get-Content -Raw -LiteralPath $ConnectionPath | ConvertFrom-Json
        if ($existing.schemaVersion -eq 1 -and $existing.secret -is [string] -and $existing.secret -cmatch '^[a-f0-9]{64}$') { $secret = $existing.secret }
    }
    if (-not $secret) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = [BitConverter]::ToString($bytes).Replace("-","").ToLowerInvariant()
    }
    $secretPath = Join-Path $tempDir "secret"
    [IO.File]::WriteAllText($secretPath,$secret + [Environment]::NewLine)
    $stagedConfig = Join-Path $tempDir "config.yaml"
    & (Join-Path $SourceDir "scripts\config.ps1") -InputFile $ConfigPath -OutputFile $stagedConfig -SecretFile $secretPath
    $connection = @{ schemaVersion=1; controllerUrl="http://127.0.0.1:9090"; proxyHost="127.0.0.1"; proxyPort=1080; secret=$secret }
    $stagedConnection = Join-Path $tempDir "connection.json"
    [IO.File]::WriteAllText($stagedConnection,($connection | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($arch.ToUpperInvariant()) {
        "AMD64" { $asset = "mihomo-windows-amd64-compatible-v1.19.30.zip"; $sha = "289fde5e29d37a5b3326480590d8b3551c5bf7f8737290355c19bce74d57a563" }
        "ARM64" { $asset = "mihomo-windows-arm64-v1.19.30.zip"; $sha = "b37c4b0259e85b020edc4215aa4c86052e21071cf520d4800364b21b4e2fc162" }
        default { throw "Unsupported Windows architecture: $arch" }
    }
    $archive = Join-Path $tempDir $asset
    $url = "https://github.com/MetaCubeX/mihomo/releases/download/$CoreVersion/$asset"
    Write-Output "Downloading verified backend $CoreVersion..."
    $downloaded = $false
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive -TimeoutSec 120; $downloaded=$true; break }
        catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -in @(400,401,403,404) -or $attempt -eq 2) { throw }
            Start-Sleep -Seconds (($attempt + 1) * 2)
        }
    }
    if (-not $downloaded) { throw "Backend download failed" }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw "Backend checksum mismatch" }
    $extract = Join-Path $tempDir "extract"
    Expand-Archive -LiteralPath $archive -DestinationPath $extract
    $cores = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object { $_.Name -match '^mihomo.*\.exe$' })
    if ($cores.Count -ne 1) { throw "Expected exactly one backend executable" }
    $stagedCore = $cores[0].FullName
    Unblock-File -LiteralPath $stagedCore
    $validationOut = Join-Path $tempDir "validation.log"
    $validationErr = Join-Path $tempDir "validation-error.log"
    $validationFailure = $null
    $validationCode = -1
    try { $validationCode = Invoke-LoggedProcess -FilePath $stagedCore -Arguments ('-t -d "{0}" -f "{1}"' -f $tempDir,$stagedConfig) -OutputLog $validationOut -ErrorLog $validationErr -TimeoutSeconds 30 }
    catch { $validationFailure = $_ }
    if ($validationCode -ne 0) {
        $failureLog = Join-Path $InstallDir "validation-failed.log"
        Write-BoundedText $failureLog ("Config validation failed at " + [DateTime]::UtcNow.ToString("o"))
        foreach ($logFile in @(($validationOut + ".previous"),$validationOut,($validationErr + ".previous"),$validationErr)) {
            if (Test-Path -LiteralPath $logFile) {
                $logBytes = [IO.File]::ReadAllBytes($logFile)
                Write-BoundedBytes $failureLog $logBytes $logBytes.Length
            }
        }
        if ($validationFailure) { Write-BoundedText $failureLog $validationFailure.Exception.Message }
        Set-PrivateAccess $failureLog
        throw "Generated config failed mihomo validation. Details: $failureLog (may contain private configuration; do not share the raw log)"
    }

    foreach ($destination in @($CorePath,$RuntimeConfig,$ConnectionPath,$ManagerPath,$LogHelperPath)) {
        $backup = $null
        if (Test-Path -LiteralPath $destination) {
            $backup = Join-Path $tempDir ([IO.Path]::GetFileName($destination) + ".previous")
            Copy-Item -LiteralPath $destination -Destination $backup
        }
        $backups[$destination] = $backup
    }
    if (Test-Path $RunKey) {
        $properties = Get-ItemProperty -Path $RunKey
        if ($properties.PSObject.Properties.Name -contains $RunName) { $oldRun = $properties.$RunName }
    }
    $oldRunning = @(Get-InstalledCoreProcess).Count -gt 0
    $swapStarted = $true
    if (Test-Path -LiteralPath $ManagerPath) { Invoke-Manager "Stop"; Stop-LegacyCore } else { Stop-LegacyCore }
    Assert-PortsAvailable
    foreach ($item in @(@($stagedCore,$CorePath),@($stagedConfig,$RuntimeConfig),@($stagedConnection,$ConnectionPath),@((Join-Path $SourceDir "backend.ps1"),$ManagerPath),@((Join-Path $SourceDir "scripts\log.ps1"),$LogHelperPath))) {
        $next = $item[1] + ".new"
        Copy-Item -LiteralPath $item[0] -Destination $next -Force
        Set-PrivateAccess $next
        Move-Item -LiteralPath $next -Destination $item[1] -Force
    }
    Unblock-File -LiteralPath $CorePath
    Unblock-File -LiteralPath $ManagerPath
    Unblock-File -LiteralPath $LogHelperPath
    Invoke-Manager "Start"
    $ready = $false
    for ($index=0; $index -lt 20; $index++) {
        try {
            $version = Invoke-RestMethod -Uri "http://127.0.0.1:9090/version" -Headers @{ Authorization="Bearer $secret" } -TimeoutSec 2
            if ($version.version -is [string] -and $version.version) { $ready=$true; break }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw "Controller did not become ready; restoring the previous installation" }
    New-Item -Path $RunKey -Force | Out-Null
    $command = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -File "{1}" -Action Run' -f $PowerShellPath,$ManagerPath
    New-ItemProperty -Path $RunKey -Name $RunName -Value $command -PropertyType String -Force | Out-Null
    $installed = $true
    Write-Output "Backend installed; controller authentication confirmed."
    try { Invoke-Manager "Check" } catch { Write-Warning "Installation completed, but SOCKS network connectivity is unconfirmed. Run backend.ps1 -Action Check after resolving the network error." }
    Write-Output "Import this connection file in extension settings: $ConnectionPath"
    Write-Output ("Extension folder: " + (Join-Path $SourceDir "extension"))
    Write-Output "System routes were not changed. Browser routing is configured separately."
} catch {
    $failure = $_
    if ($swapStarted -and -not $installed) {
        try {
            if (Test-Path -LiteralPath $ManagerPath) { Invoke-Manager "Stop" } else { Stop-LegacyCore }
            foreach ($destination in $backups.Keys) {
                if ($backups[$destination]) { Copy-Item -LiteralPath $backups[$destination] -Destination $destination -Force }
                elseif (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            }
            if ($oldRun) { New-ItemProperty -Path $RunKey -Name $RunName -Value $oldRun -PropertyType String -Force | Out-Null }
            elseif ((Test-Path $RunKey) -and (Get-ItemProperty -Path $RunKey).PSObject.Properties.Name -contains $RunName) { Remove-ItemProperty -Path $RunKey -Name $RunName }
            if ($oldRunning) {
                if (Test-Path -LiteralPath $ManagerPath) { Invoke-Manager "Start" }
                else { Start-Process -FilePath $CorePath -ArgumentList ('-d "{0}" -f "{1}"' -f $InstallDir,$RuntimeConfig) -WindowStyle Hidden }
            }
        } catch { $rollbackFailed = $true; Write-Warning "Rollback needs attention. Protected backup remains at $tempDir" }
    }
    throw $failure
} finally {
    foreach ($destination in @($CorePath,$RuntimeConfig,$ConnectionPath,$ManagerPath,$LogHelperPath)) {
        if (Test-Path -LiteralPath ($destination + ".new")) { Remove-Item -LiteralPath ($destination + ".new") -Force }
    }
    $lock.Dispose()
    if (-not $rollbackFailed -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
