param(
    [switch]$RequireStandardUser,
    [string]$InstallerPath = (Join-Path $PSScriptRoot "..\install.ps1"),
    [string]$WorkDirectory = [IO.Path]::GetTempPath()
)
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "ACL tests require Windows" }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $userSid = $identity.User.Value
    if ($RequireStandardUser) {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "ACL test requires a non-administrator token" }
        $privileges = & whoami.exe /priv /fo csv
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect token privileges" }
        if (($privileges -join " ") -match '\bSeSecurityPrivilege\b') { throw "ACL test token must not possess SeSecurityPrivilege" }
    }
} finally { $identity.Dispose() }
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($InstallerPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Set-PrivateAccess" }, $true))
if ($definitions.Count -ne 1) { throw "Expected one installer ACL function" }
. ([ScriptBlock]::Create($definitions[0].Extent.Text))

function Assert-PrivateAcl {
    param([string]$Path, [bool]$Directory)
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw "Inherited access was not disabled: $Path" }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $expected = @($userSid, "S-1-5-18", "S-1-5-32-544") | Sort-Object
    $actual = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
    if (($actual -join ",") -ne ($expected -join ",")) { throw "Unexpected access entries: $Path" }
    $inheritance = if ($Directory) { [Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit" } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($rule in $rules) {
        if ($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $rule.InheritanceFlags -ne $inheritance -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) { throw "Incorrect access rule: $Path" }
    }
    return $acl
}

$sections = [Security.AccessControl.AccessControlSections]"Access,Owner,Group"
$ownership = [Security.AccessControl.AccessControlSections]"Owner,Group"
$parentBefore = (Get-Acl -LiteralPath $WorkDirectory).GetSecurityDescriptorSddlForm($sections)
$directory = Join-Path $WorkDirectory ("amnezia-access-test-" + [Guid]::NewGuid().ToString("N"))
$null = [IO.Directory]::CreateDirectory($directory)
try {
    $folder = Join-Path $directory "private [1] folder"
    $null = [IO.Directory]::CreateDirectory($folder)
    $file = Join-Path $folder "existing [1].txt"
    [IO.File]::WriteAllText($file, "fixture bytes")
    foreach ($path in @($folder, $file)) {
        $isDirectory = $path -eq $folder
        $grant = if ($isDirectory) { "*S-1-1-0:(OI)(CI)(R)" } else { "*S-1-1-0:(R)" }
        $output = & icacls.exe $path /grant $grant /q
        if ($LASTEXITCODE -ne 0) { throw ("Could not prepare permissive ACL fixture: " + ($output -join " ")) }
        $before = Get-Acl -LiteralPath $path
        if (-not @($before.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq "S-1-1-0" }).Count) { throw "Permissive fixture rule was not present" }
        $ownerBefore = $before.GetSecurityDescriptorSddlForm($ownership)
        Set-PrivateAccess $path
        $after = Assert-PrivateAcl $path $isDirectory
        if ($after.GetSecurityDescriptorSddlForm($ownership) -ne $ownerBefore) { throw "Owner or group changed" }
        $first = $after.GetSecurityDescriptorSddlForm($sections)
        Set-PrivateAccess $path
        $again = Assert-PrivateAcl $path $isDirectory
        if ($again.GetSecurityDescriptorSddlForm($sections) -ne $first) { throw "Repeated ACL application changed the descriptor" }
    }
    if ([IO.File]::ReadAllText($file) -ne "fixture bytes") { throw "Existing file contents changed" }
    $child = Join-Path $folder "inherited.txt"
    [IO.File]::WriteAllText($child, "new fixture")
    $childRules = @((Get-Acl -LiteralPath $child).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $expected = @($userSid, "S-1-5-18", "S-1-5-32-544") | Sort-Object
    $actual = @($childRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
    if (($actual -join ",") -ne ($expected -join ",") -or @($childRules | Where-Object { -not $_.IsInherited }).Count -ne 0) { throw "New file did not inherit private access" }
    $failed = $false
    try { Set-PrivateAccess (Join-Path $directory "missing") } catch { $failed = $true }
    if (-not $failed) { throw "Missing target was silently accepted" }
    if ((Get-Acl -LiteralPath $WorkDirectory).GetSecurityDescriptorSddlForm($sections) -ne $parentBefore) { throw "Parent permissions changed" }
    Write-Output "Windows ACL tests passed: private DACL, inheritance, owner/group preservation, repeat application, file contents and errors"
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
