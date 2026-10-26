#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ScoopRoot
)

$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = (Resolve-Path -LiteralPath $ScoopRoot).ProviderPath
$sourcePaths = @('lib/install.ps1', 'libexec/scoop-config.ps1', 'libexec/scoop-update.ps1', 'libexec/scoop-cleanup.ps1', 'bin/scoop.ps1', 'lib/core.ps1', 'lib/download.ps1', 'libexec/scoop-install.ps1')
$parsePaths = @()
foreach ($relativePath in $sourcePaths) {
    $sourcePath = Join-Path $sourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Missing source file: $relativePath" }
    $parsePaths += $sourcePath
}
$testPaths = @(Get-ChildItem -LiteralPath (Join-Path $bundleRoot 'tests') -Filter '*.Tests.ps1' -File | Sort-Object Name | Select-Object -ExpandProperty FullName)
if ($testPaths.Count -eq 0) { throw 'No regression tests were found.' }
$parsePaths += @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
$parsePaths += $testPaths
foreach ($path in $parsePaths) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "PowerShell parser errors in ${path}: $($parseErrors.Message -join '; ')" }
}
Write-Host "PowerShell parser: $($parsePaths.Count) files passed."
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 3 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Preinstalled Pester 3 or newer is required; this script does not install dependencies.' }
Import-Module $pester.Path -Force
Write-Host "Running $($testPaths.Count) test files with Pester $($pester.Version)."
$previousSource = [Environment]::GetEnvironmentVariable('SCOOP_LOCAL_EXTENSIONS_SOURCE', 'Process')
try {
    $env:SCOOP_LOCAL_EXTENSIONS_SOURCE = $sourceRoot
    if ($pester.Version.Major -ge 5) {
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $testPaths
        $configuration.Run.PassThru = $true
        $configuration.Run.Exit = $false
        $configuration.Output.Verbosity = 'Detailed'
        $result = Invoke-Pester -Configuration $configuration
    } else {
        $result = Invoke-Pester -Script $testPaths -PassThru
    }
    if ($result.TotalCount -eq 0 -or $result.FailedCount -gt 0) {
        throw "Regression tests failed: $($result.FailedCount) failed of $($result.TotalCount)."
    }
    Write-Host "Regression tests: $($result.PassedCount)/$($result.TotalCount) passed."
    $result
} finally {
    [Environment]::SetEnvironmentVariable('SCOOP_LOCAL_EXTENSIONS_SOURCE', $previousSource, 'Process')
}
