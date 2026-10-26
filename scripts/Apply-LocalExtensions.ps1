#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ScoopRoot,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$allowedPaths = @('lib/install.ps1', 'libexec/scoop-config.ps1', 'libexec/scoop-update.ps1', 'libexec/scoop-cleanup.ps1', 'bin/scoop.ps1', 'lib/core.ps1', 'lib/download.ps1', 'libexec/scoop-install.ps1')
$legacyPaths = $allowedPaths[0..3]
$upgradePaths = $allowedPaths
$legacyV2Paths = $allowedPaths[0..5]
$upgradeV2Paths = @('lib/install.ps1', 'libexec/scoop-update.ps1', 'lib/download.ps1', 'libexec/scoop-install.ps1')

function Assert-UnlinkedPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Linked paths are not supported. Use a physical Scoop source tree: $Path"
        }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}

function Invoke-TargetGit {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $gitCommand -C $targetRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | ForEach-Object { $_.ToString() }) -join "`n" }
}

function New-ApplyResult {
    param([string]$Status, [string]$BackupPath)
    [pscustomobject]@{
        Status = $Status
        ScoopRoot = $targetRoot
        BackupPath = $BackupPath
        Revision = $metadata.revision
        BundleVersion = $metadata.bundle_version
        Files = $allowedPaths
    }
}

function Get-ValidatedPatch {
    param([string]$RelativePath, [string[]]$ExpectedPaths)
    $path = Join-Path $bundleRoot $RelativePath
    Assert-UnlinkedPath $path
    $text = [IO.File]::ReadAllText($path)
    $sections = @([regex]::Split($text, '(?m)(?=^diff --git )') | Where-Object { $_.Length -gt 0 })
    if ($sections.Count -ne $ExpectedPaths.Count) { throw 'The patch must modify exactly its supported Scoop source files.' }
    $seen = @()
    foreach ($section in $sections) {
        $header = [regex]::Match($section, '\Adiff --git a/([^\r\n ]+) b/\1\r?\n(?:index [0-9a-f]+\.\.[0-9a-f]+ 100644\r?\n)?--- a/\1\r?\n\+\+\+ b/\1\r?\n@@ ')
        if (-not $header.Success) { throw 'Only ordinary unified text modifications are supported; no renames, modes, creation, deletion, or binary changes.' }
        $relative = $header.Groups[1].Value
        if ($ExpectedPaths -cnotcontains $relative -or $seen -ccontains $relative) {
            throw 'The patch contains an unexpected or duplicate source path.'
        }
        $seen += $relative
    }
    $statistics = Invoke-TargetGit @('apply', '--numstat', '-z', '--', $path)
    if ($statistics.ExitCode -ne 0) { throw 'Git could not parse the source patch.' }
    $parsed = @()
    foreach ($entry in $statistics.Output.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $stat = [regex]::Match($entry, '\A[0-9]+\t[0-9]+\t([^\x00]+)\z')
        if (-not $stat.Success -or $ExpectedPaths -cnotcontains $stat.Groups[1].Value -or
            $parsed -ccontains $stat.Groups[1].Value) {
            throw 'Git parsed an unsupported patch operation or source path.'
        }
        $parsed += $stat.Groups[1].Value
    }
    if ($parsed.Count -ne $ExpectedPaths.Count) { throw 'The Git patch path list does not match the source allowlist.' }
    $path
}

if ($ScoopRoot -notmatch '^[A-Za-z]:[\\/]' -or $ScoopRoot -match '(^|[\\/])\.{1,2}([\\/]|$)') {
    throw 'ScoopRoot must be an explicit absolute Windows path without dot or parent segments.'
}
$targetRoot = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\', '/')
if ($targetRoot -ne $ScoopRoot.Replace('/', '\').TrimEnd('\') -or
    $targetRoot -eq [IO.Path]::GetPathRoot($targetRoot).TrimEnd('\', '/')) {
    throw 'ScoopRoot must be a canonical source tree directory, not a drive root.'
}
if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { throw 'ScoopRoot does not exist.' }
Assert-UnlinkedPath $targetRoot
foreach ($variable in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY')) {
    if ([Environment]::GetEnvironmentVariable($variable)) { throw "Unset $variable before applying this source patch." }
}
$gitCommand = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$worktree = Invoke-TargetGit @('rev-parse', '--show-toplevel')
if ($worktree.ExitCode -ne 0 -or [IO.Path]::GetFullPath($worktree.Output).TrimEnd('\', '/') -ne $targetRoot) {
    throw 'ScoopRoot must be the top-level directory of a Git worktree.'
}

$bundleRoot = Split-Path -Parent $PSScriptRoot
$metadataPath = Join-Path $bundleRoot 'upstream.json'
Assert-UnlinkedPath $metadataPath
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($metadata.repository -cne 'https://github.com/ScoopInstaller/Scoop' -or
    $metadata.revision -cnotmatch '^[0-9a-f]{40}$' -or $metadata.patch -cne 'patches/local-extensions.patch' -or
    $metadata.bundle_version -cne '0.3.0' -or $metadata.legacy_patch -cne 'patches/local-extensions-v1.patch' -or
    $metadata.upgrade_patch -cne 'patches/upgrade-v1.patch' -or
    $metadata.legacy_v2_patch -cne 'patches/local-extensions-v2.patch' -or
    $metadata.upgrade_v2_patch -cne 'patches/upgrade-v2.patch') {
    throw 'Invalid upstream metadata or patch location.'
}
$patchPath = Get-ValidatedPatch $metadata.patch $allowedPaths
$legacyPatchPath = Get-ValidatedPatch $metadata.legacy_patch $legacyPaths
$upgradePatchPath = Get-ValidatedPatch $metadata.upgrade_patch $upgradePaths
$legacyV2PatchPath = Get-ValidatedPatch $metadata.legacy_v2_patch $legacyV2Paths
$upgradeV2PatchPath = Get-ValidatedPatch $metadata.upgrade_v2_patch $upgradeV2Paths
foreach ($relativePath in $allowedPaths) {
    $sourcePath = Join-Path $targetRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Missing source file: $relativePath" }
    Assert-UnlinkedPath $sourcePath
    $tracked = Invoke-TargetGit @('ls-files', '--error-unmatch', '--', $relativePath)
    if ($tracked.ExitCode -ne 0) { throw "Source file is not tracked by Git: $relativePath" }
}

$forward = Invoke-TargetGit @('apply', '--check', '--', $patchPath)
$selectedPatch = $patchPath
$appliedStatus = 'Applied'
$checkStatus = 'Applicable'
if ($forward.ExitCode -ne 0) {
    $reverse = Invoke-TargetGit @('apply', '--check', '--reverse', '--', $patchPath)
    if ($reverse.ExitCode -eq 0) { New-ApplyResult 'AlreadyApplied'; return }
    $selectedPatch = $null
    foreach ($candidate in @(
        @{ Legacy = $legacyPatchPath; Upgrade = $upgradePatchPath },
        @{ Legacy = $legacyV2PatchPath; Upgrade = $upgradeV2PatchPath }
    )) {
        $legacy = Invoke-TargetGit @('apply', '--check', '--reverse', '--', $candidate.Legacy)
        $upgrade = Invoke-TargetGit @('apply', '--check', '--', $candidate.Upgrade)
        if ($legacy.ExitCode -eq 0 -and $upgrade.ExitCode -eq 0) {
            $selectedPatch = $candidate.Upgrade
            break
        }
    }
    if (-not $selectedPatch) {
        throw 'Patch compatibility check failed. The source tree may have upstream drift or only part of a bundle. No files were changed; review local changes manually.'
    }
    $appliedStatus = 'Upgraded'
    $checkStatus = 'UpgradeApplicable'
}
if ($Check) { New-ApplyResult $checkStatus; return }
if (-not $PSCmdlet.ShouldProcess($targetRoot, 'Back up supported source files and apply local Scoop extensions')) {
    New-ApplyResult 'WhatIf'
    return
}

$backupRoot = Join-Path ([IO.Path]::GetTempPath()) ('scoop-local-extensions-backup-' + [guid]::NewGuid().ToString('N'))
$backupRoot = [IO.Path]::GetFullPath($backupRoot)
if ($backupRoot.StartsWith($targetRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The temporary backup location must be outside the Scoop worktree. Set TEMP to an external directory.'
}
New-Item -ItemType Directory -Path $backupRoot | Out-Null
Assert-UnlinkedPath $backupRoot
foreach ($relativePath in $allowedPaths) {
    $sourcePath = Join-Path $targetRoot $relativePath
    Assert-UnlinkedPath $sourcePath
    $destination = Join-Path $backupRoot $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    [IO.File]::Copy($sourcePath, $destination, $false)
}
Write-Host "Source backup: $backupRoot"
$finalCheck = Invoke-TargetGit @('apply', '--check', '--', $selectedPatch)
if ($finalCheck.ExitCode -ne 0) { throw "Source changed during preflight; no patch applied. Backup: $backupRoot" }
$applied = Invoke-TargetGit @('apply', '--', $selectedPatch)
if ($applied.ExitCode -ne 0) { throw "Git could not apply the patch. Inspect your source and backup: $backupRoot" }
$verified = Invoke-TargetGit @('apply', '--check', '--reverse', '--', $patchPath)
if ($verified.ExitCode -ne 0) { throw "Applied source did not pass complete-bundle verification. Inspect your source and backup: $backupRoot" }
New-ApplyResult $appliedStatus $backupRoot
