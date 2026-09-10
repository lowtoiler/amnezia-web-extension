param([string]$InputFile, [string]$OutputFile, [string]$SecretFile)
$ErrorActionPreference = "Stop"

function ConvertTo-YamlString {
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
    $counts = @{}

    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = ($raw -replace "#.*$", "").Trim().TrimStart([char]0xFEFF)

        if (-not $line -or $line.StartsWith("#") -or $line.StartsWith(";")) {
            continue
        }

        if ($line.StartsWith("[") -and $line.EndsWith("]")) {
            $current = $line.Substring(1, $line.Length - 2).Trim()

            if ($current -notin @("Interface", "Peer")) { throw "Unsupported INI section" }
            if ($counts.ContainsKey($current)) { throw "Duplicate INI section" }
            $counts[$current] = 1
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = @{}
            }

            continue
        }

        if (-not $current) { throw "INI assignment outside a section" }

        $pos = $line.IndexOf("=")

        if ($pos -lt 1) { throw "Invalid INI assignment" }

        $key = $line.Substring(0, $pos).Trim()
        $value = $line.Substring($pos + 1).Trim()
        $allowedInterface = @("PrivateKey","Address","DNS","MTU","Jc","Jmin","Jmax","S1","S2","S3","S4","H1","H2","H3","H4","I1","I2","I3","I4","I5","J1","J2","J3","ITime","HeaderProtectionKey","ContentPaddingAddition","RekeyAfterTime","RekeyTimeout","RejectAfterTime","KeepaliveTimeout","MaxHandshakeAttempts","RandomTrailers","DisableCookies")
        $allowedPeer = @("PublicKey","PresharedKey","Endpoint","AllowedIPs","PersistentKeepalive")
        if (($current -eq "Interface" -and $key -notin $allowedInterface) -or ($current -eq "Peer" -and $key -notin $allowedPeer)) { throw "Unsupported INI field: $key" }
        if ($sections[$current].ContainsKey($key)) {
            if ($key -in @("Address","DNS","AllowedIPs")) { $value = $sections[$current][$key] + ", " + $value }
            else { throw "Duplicate INI key: $key" }
        }
        $sections[$current][$key] = $value
    }

    if (-not $sections.ContainsKey("Interface") -or -not $sections.ContainsKey("Peer")) { throw "Config must contain exactly one Interface and Peer" }
    return $sections
}

function Get-IniValue {
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

    $value = Get-IniValue $Sections "Interface" $IniKey

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

    if ($Kind -eq "number") {
        if ($value -notmatch '^\d+$') { throw "Invalid numeric field: $IniKey" }
        $value = [string][UInt64]::Parse($value)
        $Lines.Add("      $YamlKey`: $value") | Out-Null
        return
    }

    $Lines.Add("      $YamlKey`: $(ConvertTo-YamlString $value)") | Out-Null
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

    if ($Value -match '^\[([0-9a-fA-F:.]+)\]:([0-9]{1,5})$') {
        return @{
            Host = $Matches[1]
            Port = [int]$Matches[2]
        }
    }

    if ($Value -match '^([A-Za-z0-9][A-Za-z0-9.-]*):([0-9]{1,5})$') {
        return @{
            Host = $Matches[1]
            Port = [int]$Matches[2]
        }
    }

    throw "Invalid Endpoint: $Value"
}

function New-MihomoConfig {
    param(
        [hashtable]$Sections,
        [string]$OutputPath
    )

    $privateKey = Get-IniValue $Sections "Interface" "PrivateKey"
    $publicKey = Get-IniValue $Sections "Peer" "PublicKey"
    $preSharedKey = Get-IniValue $Sections "Peer" "PresharedKey"
    $endpointValue = Get-IniValue $Sections "Peer" "Endpoint"
    $addressValue = Get-IniValue $Sections "Interface" "Address"
    $dnsValue = Get-IniValue $Sections "Interface" "DNS"
    $allowedValue = Get-IniValue $Sections "Peer" "AllowedIPs"
    $keepaliveValue = Get-IniValue $Sections "Peer" "PersistentKeepalive"
    $mtuValue = Get-IniValue $Sections "Interface" "MTU"

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
    $v4Addresses = @($addresses | Where-Object { $_ -notmatch ":" } | ForEach-Object { ($_ -split "/",2)[0] } | Select-Object -Unique)
    $v6Addresses = @($addresses | Where-Object { $_ -match ":" } | ForEach-Object { ($_ -split "/",2)[0] } | Select-Object -Unique)
    if ($v4Addresses.Count -gt 1 -or $v6Addresses.Count -gt 1) { throw "Multiple distinct addresses of the same family are not supported by this backend" }
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
    if ($endpoint.Port -lt 1 -or $endpoint.Port -gt 65535) { throw "Endpoint port must be 1..65535" }
    foreach ($key in @($privateKey, $publicKey, $preSharedKey)) {
        if (-not $key) { continue }
        if ($key -notmatch '^[A-Za-z0-9+/]{43}=$' -or [Convert]::FromBase64String($key).Length -ne 32) { throw "WireGuard key must encode exactly 32 bytes" }
    }
    $dnsServers = Split-Csv $dnsValue

    if ($dnsServers.Count -eq 0) {
        $dnsServers = @("1.1.1.1")
    }

    $allowed = Split-Csv $allowedValue

    if ($allowed.Count -eq 0) {
        $allowed = @("0.0.0.0/0")
    }

    $mtu = 1420

    if ($mtuValue) {
        if ($mtuValue -notmatch '^\d{1,5}$') { throw "Invalid MTU" }
        $mtu = [int]$mtuValue
    }
    if ($mtu -lt 576 -or $mtu -gt 65535) { throw "MTU must be 576..65535" }
    if ($ipv6 -and $mtu -lt 1280) { throw "IPv6 requires MTU >= 1280" }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("mixed-port: 1080") | Out-Null
    $lines.Add("allow-lan: false") | Out-Null
    $lines.Add("bind-address: `"127.0.0.1`"") | Out-Null
    $lines.Add("mode: rule") | Out-Null
    $lines.Add("unified-delay: true") | Out-Null
    $lines.Add("tcp-concurrent: true") | Out-Null
    $lines.Add("log-level: warning") | Out-Null
    $lines.Add("external-controller: `"127.0.0.1:9090`"") | Out-Null
    $lines.Add("secret: $(ConvertTo-YamlString $ControllerSecret)") | Out-Null
    $lines.Add("proxies:") | Out-Null
    $lines.Add("  - name: `"AMNEZIA`"") | Out-Null
    $lines.Add("    type: wireguard") | Out-Null
    $lines.Add("    server: $(ConvertTo-YamlString $endpoint.Host)") | Out-Null
    $lines.Add("    port: $($endpoint.Port)") | Out-Null
    $lines.Add("    ip: $(ConvertTo-YamlString $ipv4)") | Out-Null

    if ($ipv6) {
        $lines.Add("    ipv6: $(ConvertTo-YamlString $ipv6)") | Out-Null
    }

    $lines.Add("    private-key: $(ConvertTo-YamlString $privateKey)") | Out-Null
    $lines.Add("    public-key: $(ConvertTo-YamlString $publicKey)") | Out-Null

    if ($preSharedKey) {
        $lines.Add("    pre-shared-key: $(ConvertTo-YamlString $preSharedKey)") | Out-Null
    }

    $allowedYaml = "[" + (($allowed | ForEach-Object { ConvertTo-YamlString $_ }) -join ", ") + "]"
    $dnsYaml = "[" + (($dnsServers | ForEach-Object { ConvertTo-YamlString $_ }) -join ", ") + "]"

    $lines.Add("    allowed-ips: $allowedYaml") | Out-Null
    $lines.Add("    udp: true") | Out-Null
    $lines.Add("    mtu: $mtu") | Out-Null
    $lines.Add("    ip-stack:") | Out-Null
    $lines.Add("      mode: mips") | Out-Null
    $lines.Add("      congestion-controller: bbr") | Out-Null
    $remoteDnsValue = "true"

    $lines.Add("    remote-dns-resolve: $remoteDnsValue") | Out-Null
    $lines.Add("    dns: $dnsYaml") | Out-Null

    if ($keepaliveValue -eq "off") { $keepaliveValue = "0" }
    if ($keepaliveValue) {
        if ($keepaliveValue -notmatch '^[0-9]{1,5}$' -or [int]$keepaliveValue -gt 65535) { throw "PersistentKeepalive must be off or 0..65535" }
        $lines.Add(("    persistent-keepalive: {0}" -f [int]$keepaliveValue)) | Out-Null
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
        if (Get-IniValue $Sections "Interface" $key) {
            $hasAwg = $true
            break
        }
    }

    if ($hasAwg) {
        $lines.Add("    amnezia-wg-option:") | Out-Null

        $isV3 = (
            (Get-IniValue $Sections "Interface" "HeaderProtectionKey") -or
            (Get-IniValue $Sections "Interface" "ContentPaddingAddition") -or
            (Get-IniValue $Sections "Interface" "RekeyAfterTime") -or
            (Get-IniValue $Sections "Interface" "RekeyTimeout") -or
            (Get-IniValue $Sections "Interface" "RejectAfterTime") -or
            (Get-IniValue $Sections "Interface" "KeepaliveTimeout") -or
            (Get-IniValue $Sections "Interface" "MaxHandshakeAttempts") -or
            (Get-IniValue $Sections "Interface" "RandomTrailers") -or
            (Get-IniValue $Sections "Interface" "DisableCookies")
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


if ($InputFile) {
    $ControllerSecret = [IO.File]::ReadAllText($SecretFile).Trim()
    if ($ControllerSecret -cnotmatch '^[a-f0-9]{64}$') { throw "Invalid controller secret" }
    New-MihomoConfig (Read-Ini $InputFile) $OutputFile
}
