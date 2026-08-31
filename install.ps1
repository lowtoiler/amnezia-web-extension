param(
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$CoreVersion = "v1.19.30"
$ControllerSecret = "amnezia-browser-local-v1-6f2e62c4"
$InstallDir = Join-Path $env:LOCALAPPDATA "AmneziaBrowser"
$CorePath = Join-Path $InstallDir "mihomo.exe"
$RuntimeConfig = Join-Path $InstallDir "config.yaml"
$LogPath = Join-Path $InstallDir "mihomo.log"
$ErrorLogPath = Join-Path $InstallDir "mihomo-error.log"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunName = "AmneziaBrowser"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Quote-Yaml {
    param([string]$Value)
    return (ConvertTo-Json -InputObject $Value -Compress)
}

function Split-Csv {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
}

function Read-Ini {
    param([string]$Path)

    $sections = @{}
    $current = ""

    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith("#") -or $line.StartsWith(";")) {
            continue
        }

        if ($line.StartsWith("[") -and $line.EndsWith("]")) {
            $current = $line.Substring(1, $line.Length - 2).Trim()

            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = @{}
            }

            continue
        }

        if (-not $current) {
            continue
        }

        $pos = $line.IndexOf("=")

        if ($pos -lt 1) {
            continue
        }

        $key = $line.Substring(0, $pos).Trim()
        $value = $line.Substring($pos + 1).Trim()
        $sections[$current][$key] = $value
    }

    return $sections
}

function Ini-Value {
    param(
        [hashtable]$Sections,
        [string]$Section,
        [string]$Key
    )

    if (-not $Sections.ContainsKey($Section)) {
        return ""
    }

    if (-not $Sections[$Section].ContainsKey($Key)) {
        return ""
    }

    return [string]$Sections[$Section][$Key]
}

function Add-YamlOption {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [hashtable]$Sections,
        [string]$IniKey,
        [string]$YamlKey,
        [string]$Kind
    )

    $value = Ini-Value $Sections "Interface" $IniKey

    if ([string]::IsNullOrWhiteSpace($value)) {
        return
    }

    if ($Kind -eq "bool") {
        $normalized = $value.ToLowerInvariant()

        switch ($normalized) {
            "true" { $normalized = "true" }
            "on" { $normalized = "true" }
            "1" { $normalized = "true" }
            "false" { $normalized = "false" }
            "off" { $normalized = "false" }
            "0" { $normalized = "false" }
            default { throw "Invalid $IniKey value: $value" }
        }

        $Lines.Add("      $YamlKey`: $normalized") | Out-Null
        return
    }

    if ($Kind -eq "number" -and $value -match '^\d+$') {
        $Lines.Add("      $YamlKey`: $value") | Out-Null
        return
    }

    $Lines.Add("      $YamlKey`: $(Quote-Yaml $value)") | Out-Null
}

function Select-Config {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        $resolved = Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop
        return $resolved.Path
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select Amnezia Premium config"
    $dialog.Filter = "Amnezia config (*.conf)|*.conf|All files (*.*)|*.*"
    $dialog.Multiselect = $false

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "Amnezia Premium config was not selected."
    }

    return $dialog.FileName
}

function Get-Endpoint {
    param([string]$Value)

    if ($Value -match '^\[(.+)\]:(\d+)$') {
        return @{
            Host = $Matches[1]
            Port = [int]$Matches[2]
        }
    }

    if ($Value -match '^(.+):(\d+)$') {
        return @{
            Host = $Matches[1]
            Port = [int]$Matches[2]
        }
    }

    throw "Invalid Endpoint: $Value"
}

function Build-MihomoConfig {
    param(
        [hashtable]$Sections,
        [string]$OutputPath
    )

    $privateKey = Ini-Value $Sections "Interface" "PrivateKey"
    $publicKey = Ini-Value $Sections "Peer" "PublicKey"
    $preSharedKey = Ini-Value $Sections "Peer" "PresharedKey"
    $endpointValue = Ini-Value $Sections "Peer" "Endpoint"
    $addressValue = Ini-Value $Sections "Interface" "Address"
    $dnsValue = Ini-Value $Sections "Interface" "DNS"
    $allowedValue = Ini-Value $Sections "Peer" "AllowedIPs"
    $keepaliveValue = Ini-Value $Sections "Peer" "PersistentKeepalive"
    $mtuValue = Ini-Value $Sections "Interface" "MTU"

    if (-not $privateKey) {
        throw "Missing Interface.PrivateKey"
    }

    if (-not $publicKey) {
        throw "Missing Peer.PublicKey"
    }

    if (-not $endpointValue) {
        throw "Missing Peer.Endpoint"
    }

    $addresses = Split-Csv $addressValue
    $ipv4 = $addresses | Where-Object { $_ -notmatch ":" } | Select-Object -First 1
    $ipv6 = $addresses | Where-Object { $_ -match ":" } | Select-Object -First 1

    if (-not $ipv4) {
        throw "Amnezia config does not contain an IPv4 Address."
    }

    $ipv4 = ($ipv4 -split "/", 2)[0]

    if ($ipv6) {
        $ipv6 = ($ipv6 -split "/", 2)[0]
    }

    $endpoint = Get-Endpoint $endpointValue
    $dnsServers = Split-Csv $dnsValue

    if ($dnsServers.Count -eq 0) {
        $dnsServers = @("1.1.1.1")
    }

    $allowed = Split-Csv $allowedValue

    if ($allowed.Count -eq 0) {
        $allowed = @("0.0.0.0/0")
    }

    $mtu = 1420

    if ($mtuValue -match '^\d+$') {
        $mtu = [int]$mtuValue
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("mixed-port: 1080") | Out-Null
    $lines.Add("allow-lan: false") | Out-Null
    $lines.Add("bind-address: `"127.0.0.1`"") | Out-Null
    $lines.Add("mode: rule") | Out-Null
    $lines.Add("unified-delay: true") | Out-Null
    $lines.Add("tcp-concurrent: true") | Out-Null
    $lines.Add("log-level: warning") | Out-Null
    $lines.Add("external-controller: `"127.0.0.1:9090`"") | Out-Null
    $lines.Add("secret: $(Quote-Yaml $ControllerSecret)") | Out-Null
    $lines.Add("proxies:") | Out-Null
    $lines.Add("  - name: `"AMNEZIA`"") | Out-Null
    $lines.Add("    type: wireguard") | Out-Null
    $lines.Add("    server: $(Quote-Yaml $endpoint.Host)") | Out-Null
    $lines.Add("    port: $($endpoint.Port)") | Out-Null
    $lines.Add("    ip: $(Quote-Yaml $ipv4)") | Out-Null

    if ($ipv6) {
        $lines.Add("    ipv6: $(Quote-Yaml $ipv6)") | Out-Null
    }

    $lines.Add("    private-key: $(Quote-Yaml $privateKey)") | Out-Null
    $lines.Add("    public-key: $(Quote-Yaml $publicKey)") | Out-Null

    if ($preSharedKey) {
        $lines.Add("    pre-shared-key: $(Quote-Yaml $preSharedKey)") | Out-Null
    }

    $allowedYaml = "[" + (($allowed | ForEach-Object { Quote-Yaml $_ }) -join ", ") + "]"
    $dnsYaml = "[" + (($dnsServers | ForEach-Object { Quote-Yaml $_ }) -join ", ") + "]"

    $lines.Add("    allowed-ips: $allowedYaml") | Out-Null
    $lines.Add("    udp: true") | Out-Null
    $lines.Add("    mtu: $mtu") | Out-Null
    $remoteDnsValue = "false"

    try {
        $youtubeAddresses = @(
            [System.Net.Dns]::GetHostAddresses("www.youtube.com") |
            Where-Object {
                $address = $_.ToString()
                $address -and
                $address -ne "0.0.0.0" -and
                $address -ne "::" -and
                $address -ne "::1" -and
                -not $address.StartsWith("127.")
            }
        )

        if ($youtubeAddresses.Count -eq 0) {
            $remoteDnsValue = "true"
        }
    } catch {
        $remoteDnsValue = "true"
    }

    if ($remoteDnsValue -eq "true") {
        Write-Warning "Local DNS cannot resolve www.youtube.com; tunnel DNS will be used."
    }

    $lines.Add("    remote-dns-resolve: $remoteDnsValue") | Out-Null
    $lines.Add("    dns: $dnsYaml") | Out-Null

    if ($keepaliveValue -match '^\d+$') {
        $lines.Add("    persistent-keepalive: $keepaliveValue") | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace($keepaliveValue)) {
        Write-Warning "PersistentKeepalive '$keepaliveValue' is not numeric and is not supported by this mihomo configuration; it will be omitted."
    }

    $awgKeys = @(
        "Jc", "Jmin", "Jmax",
        "S1", "S2", "S3", "S4",
        "H1", "H2", "H3", "H4",
        "I1", "I2", "I3", "I4", "I5",
        "J1", "J2", "J3", "ITime",
        "HeaderProtectionKey",
        "ContentPaddingAddition",
        "RekeyAfterTime",
        "RekeyTimeout",
        "RejectAfterTime",
        "KeepaliveTimeout",
        "MaxHandshakeAttempts",
        "RandomTrailers",
        "DisableCookies"
    )

    $hasAwg = $false

    foreach ($key in $awgKeys) {
        if (Ini-Value $Sections "Interface" $key) {
            $hasAwg = $true
            break
        }
    }

    if ($hasAwg) {
        $lines.Add("    amnezia-wg-option:") | Out-Null

        $isV3 = (
            (Ini-Value $Sections "Interface" "HeaderProtectionKey") -or
            (Ini-Value $Sections "Interface" "ContentPaddingAddition") -or
            (Ini-Value $Sections "Interface" "RekeyAfterTime") -or
            (Ini-Value $Sections "Interface" "RekeyTimeout") -or
            (Ini-Value $Sections "Interface" "RejectAfterTime") -or
            (Ini-Value $Sections "Interface" "KeepaliveTimeout") -or
            (Ini-Value $Sections "Interface" "MaxHandshakeAttempts") -or
            (Ini-Value $Sections "Interface" "RandomTrailers") -or
            (Ini-Value $Sections "Interface" "DisableCookies")
        )

        if ($isV3) {
            $lines.Add("      version: 3") | Out-Null
        }

        Add-YamlOption $lines $Sections "Jc" "jc" "number"
        Add-YamlOption $lines $Sections "Jmin" "jmin" "number"
        Add-YamlOption $lines $Sections "Jmax" "jmax" "number"
        Add-YamlOption $lines $Sections "S1" "s1" "number"
        Add-YamlOption $lines $Sections "S2" "s2" "number"
        Add-YamlOption $lines $Sections "S3" "s3" "number"
        Add-YamlOption $lines $Sections "S4" "s4" "number"
        Add-YamlOption $lines $Sections "H1" "h1" "string"
        Add-YamlOption $lines $Sections "H2" "h2" "string"
        Add-YamlOption $lines $Sections "H3" "h3" "string"
        Add-YamlOption $lines $Sections "H4" "h4" "string"
        Add-YamlOption $lines $Sections "I1" "i1" "string"
        Add-YamlOption $lines $Sections "I2" "i2" "string"
        Add-YamlOption $lines $Sections "I3" "i3" "string"
        Add-YamlOption $lines $Sections "I4" "i4" "string"
        Add-YamlOption $lines $Sections "I5" "i5" "string"
        Add-YamlOption $lines $Sections "J1" "j1" "string"
        Add-YamlOption $lines $Sections "J2" "j2" "string"
        Add-YamlOption $lines $Sections "J3" "j3" "string"
        Add-YamlOption $lines $Sections "ITime" "itime" "number"
        Add-YamlOption $lines $Sections "HeaderProtectionKey" "header-protection-key" "string"
        Add-YamlOption $lines $Sections "ContentPaddingAddition" "content-padding-addition" "string"
        Add-YamlOption $lines $Sections "RekeyAfterTime" "rekey-after-time" "string"
        Add-YamlOption $lines $Sections "RekeyTimeout" "rekey-timeout" "string"
        Add-YamlOption $lines $Sections "RejectAfterTime" "reject-after-time" "string"
        Add-YamlOption $lines $Sections "KeepaliveTimeout" "keepalive-timeout" "string"
        Add-YamlOption $lines $Sections "MaxHandshakeAttempts" "max-handshake-attempts" "string"
        Add-YamlOption $lines $Sections "RandomTrailers" "random-trailers" "bool"
        Add-YamlOption $lines $Sections "DisableCookies" "disable-cookies" "bool"
    }

    $lines.Add("rules:") | Out-Null
    $lines.Add("  - `"MATCH,AMNEZIA`"") | Out-Null

    [IO.File]::WriteAllLines($OutputPath, $lines, (New-Object Text.UTF8Encoding($false)))
}

function Test-InstalledCoreRunning {
    if (-not (Test-Path -LiteralPath $CorePath)) {
        return $false
    }

    $normalized = [IO.Path]::GetFullPath($CorePath)
    $process = Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath) -eq $normalized)
        } |
        Select-Object -First 1

    return $null -ne $process
}

function Stop-InstalledCore {
    if (-not (Test-Path -LiteralPath $CorePath)) {
        return
    }

    $normalized = [IO.Path]::GetFullPath($CorePath)

    $processes = @(
        Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            ([IO.Path]::GetFullPath($_.ExecutablePath) -eq $normalized)
        }
    )

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)

    do {
        $running = @(
            Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                ([IO.Path]::GetFullPath($_.ExecutablePath) -eq $normalized)
            }
        )

        if ($running.Count -eq 0) {
            return
        }

        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "mihomo.exe did not stop within 5 seconds"
}

function Wait-Controller {
    $headers = @{
        Authorization = "Bearer $ControllerSecret"
    }

    for ($i = 0; $i -lt 40; $i++) {
        try {
            $null = Invoke-RestMethod `
                -Uri "http://127.0.0.1:9090/version" `
                -Headers $headers `
                -TimeoutSec 2
            return
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }

    throw "Backend did not start. Check $ErrorLogPath"
}

function Get-ProxyDelay {
    param([string]$ProxyName)

    $headers = @{
        Authorization = "Bearer $ControllerSecret"
    }

    $encodedProxy = [Uri]::EscapeDataString($ProxyName)
    $testUrls = @(
        "https://www.gstatic.com/generate_204",
        "https://cp.cloudflare.com/generate_204"
    )

    $lastError = $null

    foreach ($testUrl in $testUrls) {
        try {
            $encodedUrl = [Uri]::EscapeDataString($testUrl)
            $uri = "http://127.0.0.1:9090/proxies/$encodedProxy/delay?url=$encodedUrl&timeout=12000"

            $result = Invoke-RestMethod `
                -Uri $uri `
                -Headers $headers `
                -TimeoutSec 15

            if ($null -ne $result.delay) {
                $delay = [int]$result.delay

                if ($delay -ge 0) {
                    return $delay
                }
            }
        } catch {
            $lastError = $_
        }
    }

    if ($lastError) {
        throw $lastError
    }

    throw "No delay result for $ProxyName"
}

function Test-AmneziaTunnel {
    try {
        return Get-ProxyDelay "AMNEZIA"
    } catch {
        $tail = ""

        if (Test-Path -LiteralPath $ErrorLogPath) {
            $tail = (Get-Content -LiteralPath $ErrorLogPath -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
        }

        if (-not $tail -and (Test-Path -LiteralPath $LogPath)) {
            $tail = (Get-Content -LiteralPath $LogPath -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
        }

        if ($tail) {
            throw "Amnezia Premium connection test failed: $($_.Exception.Message)`n$tail"
        }

        throw "Amnezia Premium connection test failed: $($_.Exception.Message)"
    }
}

$ConfigPath = Select-Config $ConfigPath
$sections = Read-Ini $ConfigPath

if (-not $sections.ContainsKey("Interface") -or -not $sections.ContainsKey("Peer")) {
    throw "Config must contain [Interface] and [Peer]."
}

$sectionLines = [IO.File]::ReadAllLines($ConfigPath) | ForEach-Object { $_.Trim() }
$interfaceCount = @($sectionLines | Where-Object { $_ -match '^\[Interface\]$' }).Count
$peerCount = @($sectionLines | Where-Object { $_ -match '^\[Peer\]$' }).Count

if ($interfaceCount -ne 1 -or $peerCount -ne 1) {
    throw "Config must contain exactly one [Interface] and one [Peer] section."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$arch = $env:PROCESSOR_ARCHITECTURE

if ($env:PROCESSOR_ARCHITEW6432) {
    $arch = $env:PROCESSOR_ARCHITEW6432
}

switch ($arch.ToUpperInvariant()) {
    "AMD64" {
        $assetName = "mihomo-windows-amd64-compatible-v1.19.30.zip"
        $expectedSha = "289fde5e29d37a5b3326480590d8b3551c5bf7f8737290355c19bce74d57a563"
    }
    "ARM64" {
        $assetName = "mihomo-windows-arm64-v1.19.30.zip"
        $expectedSha = "b37c4b0259e85b020edc4215aa4c86052e21071cf520d4800364b21b4e2fc162"
    }
    default {
        throw "Unsupported Windows architecture: $arch"
    }
}

$coreUrl = "https://github.com/MetaCubeX/mihomo/releases/download/$CoreVersion/$assetName"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("amnezia-browser-" + [Guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $tempDir $assetName
$extractDir = Join-Path $tempDir "extract"

$stagedConfig = Join-Path $tempDir "config.yaml"
$backupCore = Join-Path $tempDir "mihomo.previous.exe"
$backupConfig = Join-Path $tempDir "config.previous.yaml"
$hadCore = $false
$hadConfig = $false
$oldRunning = $false
$swapStarted = $false
$installedOk = $false

try {
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

    Write-Host "Downloading backend..."
    Invoke-WebRequest -Uri $coreUrl -OutFile $archivePath

    $actualSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actualSha -ne $expectedSha) {
        throw "Backend checksum mismatch."
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
    $downloadedCore = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -match '^mihomo.*\.exe$' } |
        Select-Object -First 1

    if (-not $downloadedCore) {
        throw "Backend executable was not found in the downloaded package."
    }

    Unblock-File -LiteralPath $downloadedCore.FullName -ErrorAction SilentlyContinue
    Build-MihomoConfig $sections $stagedConfig

    $validation = & $downloadedCore.FullName -t -d $tempDir -f $stagedConfig 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Generated backend config is invalid.`n$($validation -join "`n")"
    }

    $hadCore = Test-Path -LiteralPath $CorePath
    $hadConfig = Test-Path -LiteralPath $RuntimeConfig

    if ($hadCore) {
        Copy-Item -LiteralPath $CorePath -Destination $backupCore -Force
    }

    if ($hadConfig) {
        Copy-Item -LiteralPath $RuntimeConfig -Destination $backupConfig -Force
    }

    $oldRunning = Test-InstalledCoreRunning
    $swapStarted = $true
    Stop-InstalledCore
    Copy-Item -LiteralPath $downloadedCore.FullName -Destination $CorePath -Force
    Copy-Item -LiteralPath $stagedConfig -Destination $RuntimeConfig -Force
    Unblock-File -LiteralPath $CorePath -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ErrorLogPath -Force -ErrorAction SilentlyContinue

    $arguments = "-d `"$InstallDir`" -f `"$RuntimeConfig`""

    Start-Process `
        -FilePath $CorePath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $LogPath `
        -RedirectStandardError $ErrorLogPath |
        Out-Null

    Wait-Controller
    $delay = $null

    try {
        $delay = Test-AmneziaTunnel
    } catch {
        Write-Warning $_.Exception.Message
    }

    $directDelay = $null

    try {
        $directDelay = Get-ProxyDelay "DIRECT"
    } catch {
        Write-Warning "Direct RTT baseline is unavailable: $($_.Exception.Message)"
    }

    New-Item -Path $RunKey -Force | Out-Null
    $runCommand = "`"$CorePath`" -d `"$InstallDir`" -f `"$RuntimeConfig`""

    New-ItemProperty `
        -Path $RunKey `
        -Name $RunName `
        -Value $runCommand `
        -PropertyType String `
        -Force |
        Out-Null

    $installedOk = $true

    Write-Host ""
    Write-Host "Amnezia Browser backend: OK"

    if ($null -ne $delay) {
        Write-Host "Amnezia Premium RTT test: ${delay} ms"
    } else {
        Write-Host "Amnezia Premium RTT test: unavailable"
    }

    if ($null -ne $directDelay) {
        Write-Host "Direct RTT baseline: ${directDelay} ms"
    }

    if ($null -ne $delay -and $null -ne $directDelay) {
        $delta = $delay - $directDelay
        Write-Host "VPN RTT delta: ${delta} ms"
    }

    Write-Host "System VPN: OFF"
    Write-Host "System routes: unchanged"
    Write-Host "Extension folder: $(Join-Path $PSScriptRoot 'extension')"
} catch {
    $installError = $_

    if ($swapStarted -and -not $installedOk) {
        Stop-InstalledCore

        if ($hadCore) {
            Copy-Item -LiteralPath $backupCore -Destination $CorePath -Force
        } else {
            Remove-Item -LiteralPath $CorePath -Force -ErrorAction SilentlyContinue
        }

        if ($hadConfig) {
            Copy-Item -LiteralPath $backupConfig -Destination $RuntimeConfig -Force
        } else {
            Remove-Item -LiteralPath $RuntimeConfig -Force -ErrorAction SilentlyContinue
        }

        if ($hadCore -and $hadConfig -and $oldRunning) {
            $previousArguments = "-d `"$InstallDir`" -f `"$RuntimeConfig`""

            Start-Process `
                -FilePath $CorePath `
                -ArgumentList $previousArguments `
                -WindowStyle Hidden `
                -RedirectStandardOutput $LogPath `
                -RedirectStandardError $ErrorLogPath |
                Out-Null
        }
    }

    throw $installError
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
