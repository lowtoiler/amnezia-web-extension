$ErrorActionPreference = "Stop"

function Initialize-BoundedLog {
    param([string]$Path, [ValidateRange(1,999999999)][int]$Limit = 2097152)
    foreach ($file in @($Path, ($Path + ".previous"))) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $item = Get-Item -LiteralPath $file
        if ($item.PSIsContainer) { throw "Log path must be a regular file" }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Log path must not be a reparse point" }
        if ($item.Length -le $Limit) { continue }
        $temporary = $file + ".trim." + [Guid]::NewGuid().ToString("N")
        $source = $null
        $destination = $null
        try {
            $source = [IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $null = $source.Seek(-$Limit,[IO.SeekOrigin]::End)
            $destination = [IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $source.CopyTo($destination,16384)
            $destination.Dispose()
            $destination = $null
            $source.Dispose()
            $source = $null
            Move-Item -LiteralPath $temporary -Destination $file -Force
        } finally {
            if ($destination) { $destination.Dispose() }
            if ($source) { $source.Dispose() }
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

function Write-BoundedBytes {
    param([string]$Path, [byte[]]$Bytes, [int]$Count, [ValidateRange(1,999999999)][int]$Limit = 2097152)
    if ($Count -lt 0 -or $Count -gt $Bytes.Length) { throw "Invalid log byte count" }
    $offset = 0
    while ($offset -lt $Count) {
        $length = if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).Length } else { 0 }
        if ($length -gt $Limit) { Initialize-BoundedLog $Path $Limit; $length = (Get-Item -LiteralPath $Path).Length }
        if ($length -eq $Limit) {
            Move-Item -LiteralPath $Path -Destination ($Path + ".previous") -Force
            $length = 0
        }
        $take = [int][Math]::Min($Limit - $length, $Count - $offset)
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stream.Write($Bytes,$offset,$take) } finally { $stream.Dispose() }
        $offset += $take
    }
}

function Write-BoundedText {
    param([string]$Path, [string]$Text, [ValidateRange(1,999999999)][int]$Limit = 2097152)
    Initialize-BoundedLog $Path $Limit
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text + [Environment]::NewLine)
    Write-BoundedBytes $Path $bytes $bytes.Length $Limit
}

function Invoke-LoggedProcess {
    param([string]$FilePath, [string]$Arguments, [string]$OutputLog, [string]$ErrorLog, [int]$TimeoutSeconds = 0, [ValidateRange(1,999999999)][int]$LogLimit = 2097152, [string]$ProcessMetadataPath = "")
    if ($OutputLog -eq $ErrorLog) { throw "Output and error logs must be separate" }
    Initialize-BoundedLog $OutputLog $LogLimit
    Initialize-BoundedLog $ErrorLog $LogLimit
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $started = $false
    $streams = @()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $exitedAt = $null
    try {
        if (-not $process.Start()) { throw "Process did not start" }
        $started = $true
        if ($ProcessMetadataPath) {
            $processStart = $process.StartTime.ToUniversalTime(); $metadata = @{ pid=$process.Id; ownerPid=$PID; started=([string]$processStart.Ticks); startedUtc=$processStart.ToString("o",[Globalization.CultureInfo]::InvariantCulture) }
            [IO.File]::WriteAllText(($ProcessMetadataPath + ".new"), ($metadata | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath ($ProcessMetadataPath + ".new") -Destination $ProcessMetadataPath -Force
        }
        $streams = @(
            @{ Reader=$process.StandardOutput.BaseStream; Path=$OutputLog; Buffer=(New-Object byte[] 16384); Pending=$null; Done=$false },
            @{ Reader=$process.StandardError.BaseStream; Path=$ErrorLog; Buffer=(New-Object byte[] 16384); Pending=$null; Done=$false }
        )
        foreach ($item in $streams) { $item.Pending = $item.Reader.ReadAsync($item.Buffer,0,$item.Buffer.Length) }
        while ($true) {
            $progress = $false
            foreach ($item in $streams) {
                if ($item.Done -or -not $item.Pending.IsCompleted) { continue }
                $count = $item.Pending.GetAwaiter().GetResult()
                if ($count -eq 0) { $item.Done = $true }
                else {
                    Write-BoundedBytes $item.Path $item.Buffer $count $LogLimit
                    $item.Pending = $item.Reader.ReadAsync($item.Buffer,0,$item.Buffer.Length)
                }
                $progress = $true
            }
            if ($process.HasExited) {
                if ($null -eq $exitedAt) { $exitedAt = $clock.ElapsedMilliseconds }
                if ($streams[0].Done -and $streams[1].Done) { break }
                if ($clock.ElapsedMilliseconds - $exitedAt -gt 5000) { throw "Process output did not close after exit" }
            }
            if ($TimeoutSeconds -gt 0 -and $clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Process exceeded its timeout" }
            if (-not $progress) { Start-Sleep -Milliseconds 20 }
        }
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                if (-not $process.WaitForExit(5000)) { throw "Process did not stop after logging failure or timeout" }
            }
        } finally {
            if ($started -and $ProcessMetadataPath -and (Test-Path -LiteralPath $ProcessMetadataPath)) {
                try {
                    $metadata = Get-Content -Raw -LiteralPath $ProcessMetadataPath | ConvertFrom-Json
                    $expected = [long]([string]$metadata.started)
                    $actual = [long]$process.StartTime.ToUniversalTime().Ticks
                    if ([int]$metadata.pid -eq $process.Id -and [Math]::Abs($actual - $expected) -le [TimeSpan]::TicksPerSecond * 2) { Remove-Item -LiteralPath $ProcessMetadataPath -Force }
                } catch {}
            }
            if ($ProcessMetadataPath -and (Test-Path -LiteralPath ($ProcessMetadataPath + ".new"))) { Remove-Item -LiteralPath ($ProcessMetadataPath + ".new") -Force }
            foreach ($item in $streams) { $item.Reader.Dispose() }
            $process.Dispose()
            $clock.Stop()
        }
    }
}
