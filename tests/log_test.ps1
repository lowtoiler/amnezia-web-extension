$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\log.ps1")
$directory = Join-Path ([IO.Path]::GetTempPath()) ("amnezia-log-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $directory | Out-Null
function Assert-Log {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
try {
    $path = Join-Path $directory "bounded.log"
    $bytes = New-Object byte[] 25000
    for ($index=0; $index -lt $bytes.Length; $index++) { $bytes[$index] = $index % 256 }
    Write-BoundedBytes $path $bytes $bytes.Length 8192
    $previous = [IO.File]::ReadAllBytes($path + ".previous")
    $current = [IO.File]::ReadAllBytes($path)
    Assert-Log ($previous.Length -eq 8192 -and $current.Length -eq 424) "Log sizes were not bounded"
    $retained = [byte[]]($previous + $current)
    $expected = [byte[]]$bytes[16384..24999]
    Assert-Log ([Convert]::ToBase64String($retained) -eq [Convert]::ToBase64String($expected)) "Log bytes were changed"
    [IO.File]::WriteAllBytes($path,$bytes)
    Initialize-BoundedLog $path 8192
    Assert-Log ((Get-Item -LiteralPath $path).Length -eq 8192) "Existing large log was not bounded"

    $fixture = Join-Path $directory "fixture.ps1"
    $source = @'
param([switch]$Slow)
if ($Slow) { Start-Sleep -Seconds 20; exit 0 }
$bytes = New-Object byte[] 1048576
for ($index=0; $index -lt $bytes.Length; $index++) { $bytes[$index] = $index % 256 }
$out = [Console]::OpenStandardOutput()
$err = [Console]::OpenStandardError()
$out.Write($bytes,0,$bytes.Length)
$out.Flush()
$err.Write($bytes,0,$bytes.Length)
$err.Flush()
exit 7
'@
    [IO.File]::WriteAllText($fixture,$source)
    $shell = (Get-Process -Id $PID).Path
    $output = Join-Path $directory "stdout.log"
    $errorOutput = Join-Path $directory "stderr.log"
    $arguments = '-NoProfile -NonInteractive -File "{0}"' -f $fixture
    $code = Invoke-LoggedProcess $shell $arguments $output $errorOutput 15 8192
    Assert-Log ($code -eq 7) "Child process exit code was lost"
    foreach ($log in @($output,$errorOutput)) {
        Assert-Log ((Get-Item -LiteralPath $log).Length -le 8192) "Live log exceeded the limit"
        Assert-Log ((Get-Item -LiteralPath ($log + ".previous")).Length -eq 8192) "Rotation did not keep the previous block"
    }
    $timedOut = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { $null = Invoke-LoggedProcess $shell ($arguments + " -Slow") $output $errorOutput 1 8192 }
    catch { if ($_.Exception.Message -notmatch "timeout") { throw }; $timedOut = $true }
    Assert-Log ($timedOut -and $clock.Elapsed.TotalSeconds -lt 7) "Process timeout did not stop promptly"
    Write-Output "Windows log tests passed: rotation, byte preservation, both streams, exit code and timeout"
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
