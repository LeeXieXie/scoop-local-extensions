Describe 'Cleanup retention and read-only planning' -Tag 'Scoop' {
    BeforeEach {
        function Invoke-CleanupCommandFixture($Arguments) {
            $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'libexec/scoop-cleanup.ps1'), [ref]$null, [ref]$null)
            $parts = @($ast.EndBlock.Statements | Where-Object {
                $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] -and
                !($_ -is [Management.Automation.Language.PipelineAst] -and $_.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and $_.PipelineElements[0].InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot)
            } | ForEach-Object { $_.Extent.Text })
            $getopt = [IO.File]::ReadAllText((Join-Path $sourceRoot 'lib/getopt.ps1'))
            $stubs = @'
function error($Message) { [Console]::Out.WriteLine($Message) }
function my_usage {}
function is_admin { $true }
function Confirm-InstallationStatus($Apps, [switch]$Global) { , @('fixture', $false) }
function Invoke-CleanupApps($Apps, $Verbose, $Cache) {
    [Console]::Out.WriteLine(([pscustomobject]@{ Keep = $script:cleanupKeep; DryRun = $script:cleanupDryRun; Cache = [bool]$Cache } | ConvertTo-Json -Compress))
    return 7
}
'@
            $body = $parts -join "`n"
            $quoted = @($Arguments | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ','
            $command = $getopt + "`n" + $stubs + "`n`$cliArgs = @(" + $quoted + ")`n& {`n" + $body + "`n} @cliArgs; exit `$LASTEXITCODE"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $engine = (Get-Process -Id $PID).Path
            $output = & $engine -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 | Out-String
            [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $output }
        }
        function Invoke-CleanupPlanFixture {
            param($Keep = 1, [switch]$Preview, [switch]$Cache, $Current = '2.0', $Scenario = 'normal', $App = 'fixture')
            $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'libexec/scoop-cleanup.ps1'), [ref]$null, [ref]$null)
            $source = ($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Extent.Text }) -join "`n"
            $versions = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/versions.ps1'), [ref]$null, [ref]$null)
            $source += "`n" + $versions.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InstalledVersion' }, $false).Extent.Text
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
            $root = Join-Path $temp ('scoop-cleanup-plan-' + [guid]::NewGuid().ToString('N'))
            if (![IO.Path]::GetFullPath($root).StartsWith($temp + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
            $fixture = New-Module -ScriptBlock {
                function Invoke-Fixture($Source, $Root, $Keep, $Preview, $Cache, $Current, $Scenario, $App) {
                    $script:root = $Root
                    $script:currentVersion = $Current
                    $script:scenario = $Scenario
                    $script:messages = New-Object 'Collections.Generic.List[string]'
                    $script:mutations = 0
                    $cachedir = Join-Path $Root 'cache'
                    foreach ($name in @('cache', 'persist')) { New-Item -ItemType Directory -Path (Join-Path $Root $name) -Force | Out-Null }
                    [IO.File]::WriteAllText((Join-Path $Root 'persist\data.txt'), 'shared data')
                    $names = @('1.10', '1.9', 'nightly', '2.0')
                    if ($Scenario -eq 'few') { $names = @('1.10', '2.0') }
                    $index = 0
                    foreach ($version in $names) {
                        $directory = Join-Path $Root "$App\$version"
                        [void][IO.Directory]::CreateDirectory($directory)
                        [IO.File]::WriteAllText((Join-Path $directory 'payload.txt'), $version)
                        [IO.File]::WriteAllText((Join-Path $directory 'install.json'), '{}')
                        (Get-Item -LiteralPath (Join-Path $directory 'install.json')).LastWriteTimeUtc = [datetime]'2020-01-01' + [timespan]::FromMinutes($index++)
                        foreach ($suffix in @('payload.zip', 'payload.zip.download')) { [IO.File]::WriteAllText((Join-Path $cachedir "$App#$version#$suffix"), $version) }
                    }
                    if ($Scenario -eq 'backup') { New-Item -ItemType Directory -Path (Join-Path $Root "$App\_nightly.old-backup") | Out-Null }
                    if ($App -notmatch '[\[\]]') {
                        New-Item -ItemType Junction -Path (Join-Path $Root "$App\current") -Target (Join-Path $Root "$App\$Current") | Out-Null
                        New-Item -ItemType Junction -Path (Join-Path $Root "$App\1.10\data") -Target (Join-Path $Root 'persist') | Out-Null
                    }
                    if ($Scenario -eq 'readonly') { attrib +R /L (Join-Path $Root "$App\1.10\data"); attrib +R (Join-Path $Root "$App\1.10\payload.txt") }
                    [IO.File]::WriteAllText((Join-Path $cachedir 'unrelated.download'), 'partial')
                    [IO.File]::WriteAllText((Join-Path $cachedir 'fixtureX#1.10#keep.zip'), 'unrelated')
                    function Select-CurrentVersion { param($AppName, [switch]$Global) $script:currentVersion }
                    function appdir { param($App, $Global) Join-Path $script:root $App }
                    function versiondir {
                        param($App, $Version, $Global)
                        if ($script:scenario -eq 'unsafe' -and $Version -eq '1.10') { return (Join-Path $script:root 'persist') }
                        Join-Path $script:root "$App\$Version"
                    }
                    function installed_manifest { param($App, $Version, $Global) @{ persist = 'data' } }
                    function persist_def { param($Definition) $Definition }
                    function unlink_persist_data { $script:mutations++ }
                    function Write-Host { param($Object, $ForegroundColor, [switch]$NoNewline) $script:messages.Add([string]$Object) }
                    function warn { param($Message) $script:messages.Add([string]$Message) }
                    function success { param($Message) $script:messages.Add([string]$Message) }
                    function Get-Process { throw 'Preview must not inspect processes or probe locks.' }
                    function Stop-Process { throw 'Cleanup must never stop a process.' }
                    function Remove-Item {
                        [CmdletBinding()]
                        param($Path, $LiteralPath, [switch]$Recurse, [switch]$Force, $Exclude)
                        $script:mutations++
                        foreach ($target in @($Path) + @($LiteralPath)) {
                            if ($target -and ![IO.Path]::GetFullPath($target).StartsWith($script:root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture deletion: $target" }
                        }
                        $parameters = @{ Force = $Force; Recurse = $Recurse; ErrorAction = 'Stop' }
                        if ($LiteralPath) { $parameters.LiteralPath = $LiteralPath } else { $parameters.Path = $Path }
                        if ($Exclude) { $parameters.Exclude = $Exclude }
                        Microsoft.PowerShell.Management\Remove-Item @parameters
                    }
                    function Get-FixtureSnapshot {
                        $pending = New-Object 'Collections.Generic.Stack[string]'
                        $pending.Push($script:root)
                        $entries = @()
                        while ($pending.Count) {
                            foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                                $content = if (!$item.PSIsContainer) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($item.FullName)) } else { '' }
                                $entries += "$($item.FullName.Substring($script:root.Length))|$($item.Attributes)|$($item.Target)|$content"
                                if ($item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($item.FullName) }
                            }
                        }
                        ($entries | Sort-Object) -join "`n"
                    }
                    . ([scriptblock]::Create($Source))
                    $before = Get-FixtureSnapshot
                    $status = $null
                    $failure = $null
                    try { $status = Invoke-CleanupApps @(, @($App, $false)) $false $Cache $Keep $Preview } catch { $failure = $_.Exception.Message }
                    [pscustomobject]@{
                        Status = $status; Error = $failure; Mutations = $script:mutations; Before = $before; After = Get-FixtureSnapshot
                        Messages = $script:messages -join "`n"
                        Versions = @(Get-ChildItem -LiteralPath (Join-Path $Root $App) -Directory | Select-Object -ExpandProperty Name)
                        Cache = @(Get-ChildItem -LiteralPath $cachedir -File | Select-Object -ExpandProperty Name)
                    }
                }
                Export-ModuleMember Invoke-Fixture
            }
            try { & $fixture { param($Source, $Root, $Keep, $Preview, $Cache, $Current, $Scenario, $App) Invoke-Fixture $Source $Root $Keep $Preview $Cache $Current $Scenario $App } $source $root $Keep $Preview $Cache $Current $Scenario $App }
            finally {
                $resolved = [IO.Path]::GetFullPath($root)
                if (!$resolved.StartsWith($temp + '\scoop-cleanup-plan-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
                foreach ($relative in @("$App\current", "$App\1.10\data")) {
                    $link = Join-Path $resolved $relative
                    if (Test-Path -LiteralPath $link) { attrib -R /L $link; [IO.Directory]::Delete($link) }
                }
                if (Test-Path -LiteralPath $resolved) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolved -Recurse -Force }
                Remove-Module $fixture
            }
        }
    }
    It 'defaults to current-only retention' {
        $result = Invoke-CleanupPlanFixture
        if ($result.Error -or $result.Status -ne 0 -or ($result.Versions -join ',') -ne '2.0,current') { throw "Current-only retention failed: $($result.Error)" }
    }
    It 'keeps current plus the newest two installations, including nightly' {
        $result = Invoke-CleanupPlanFixture -Keep 3
        if ($result.Error -or $result.Status -ne 0 -or $result.Versions -contains '1.10' -or $result.Versions -notcontains '1.9' -or $result.Versions -notcontains 'nightly') { throw "Installation retention failed: $($result | Out-String)" }
    }
    It 'uses installation chronology for later-installed 1.9 rather than lexical order' {
        $result = Invoke-CleanupPlanFixture -Keep 3 -Current nightly
        if ($result.Error -or $result.Versions -contains '1.10' -or $result.Versions -notcontains '1.9' -or $result.Versions -notcontains '2.0') { throw 'Retention used version strings rather than installation chronology.' }
    }
    It 'keeps the selected current version after rollback' {
        $result = Invoke-CleanupPlanFixture -Keep 2 -Current '1.10'
        if ($result.Error -or $result.Status -ne 0 -or $result.Versions -notcontains '1.10' -or $result.Versions -notcontains '2.0' -or $result.Versions -contains 'nightly') { throw 'Rollback current did not remain protected.' }
    }
    It 'keeps all installations when fewer than N exist' {
        $result = Invoke-CleanupPlanFixture -Keep 8 -Scenario few
        if ($result.Error -or $result.Status -ne 0 -or $result.Versions.Count -ne 3) { throw 'Retention deleted a version below the requested count.' }
    }
    It 'does not count an unrecognized backup toward retained installations' {
        $result = Invoke-CleanupPlanFixture -Keep 3 -Scenario backup -Preview
        if ($result.Error -or $result.Messages -notmatch 'KEEP fixture _nightly.old-backup.*unrecognized' -or $result.Messages -notmatch 'KEEP fixture 1\.9') { throw 'The backup decision or retention plan was not explained.' }
    }
    It 'rejects invalid retention before changing any file (<Keep>)' -TestCases @(@{ Keep = 0 }, @{ Keep = -1 }, @{ Keep = '1.5' }, @{ Keep = 'banana' }, @{ Keep = '2147483648' }) {
        param($Keep)
        $result = Invoke-CleanupPlanFixture -Keep $Keep -Cache
        if (!$result.Error -and $result.Status -ne 1) { throw 'Invalid retention was accepted.' }
        if ($result.Mutations -or $result.Before -ne $result.After) { throw 'Invalid retention changed the fixture.' }
    }
    It 'previews versions, cache and remnants without modifying contents, links or attributes' {
        $result = Invoke-CleanupPlanFixture -Keep 3 -Preview -Cache -Scenario readonly
        if ($result.Error -or $result.Status -ne 0 -or $result.Mutations -or $result.Before -ne $result.After) { throw "Preview mutated the fixture: $($result.Error)" }
        if ($result.Messages -notmatch 'DELETE.*1\.10' -or $result.Messages -notmatch 'KEEP.*1\.9' -or $result.Messages -notmatch 'unrelated.download' -or $result.Messages -notmatch 'unknown|potential|not.*probe') { throw 'Preview omitted candidates, reasons or its lock-verification boundary.' }
    }
    It 'protects retained caches and executes exactly the preview plan' {
        $preview = Invoke-CleanupPlanFixture -Keep 3 -Preview -Cache
        $actual = Invoke-CleanupPlanFixture -Keep 3 -Cache
        if ($preview.Error -or $actual.Error -or $actual.Status -ne 0 -or $actual.Cache -contains 'fixture#1.10#payload.zip' -or $actual.Cache -contains 'fixture#1.10#payload.zip.download') { throw 'Planned old-version cache was not removed.' }
        foreach ($version in @('1.9', 'nightly', '2.0')) {
            foreach ($suffix in @('payload.zip', 'payload.zip.download')) {
                if ($actual.Cache -notcontains "fixture#$version#$suffix") { throw "Retained cache was removed: $version/$suffix" }
            }
        }
        if ($actual.Cache -contains 'unrelated.download' -or $actual.Cache -notcontains 'fixtureX#1.10#keep.zip') { throw 'Remnant selection was not precise.' }
        $previewPlan = ($preview.Messages -replace 'scoop-cleanup-plan-[a-f0-9]+', 'LAB') -split "`n" | Where-Object { $_ -match '^(KEEP|DELETE)' }
        $actualPlan = ($actual.Messages -replace 'scoop-cleanup-plan-[a-f0-9]+', 'LAB') -split "`n" | Where-Object { $_ -match '^(KEEP|DELETE)' }
        if (($previewPlan -join "`n") -ne ($actualPlan -join "`n")) { throw 'Preview and execution used different candidate plans.' }
    }
    It 'reports unsafe version paths in preview with failure status and no writes' {
        $result = Invoke-CleanupPlanFixture -Keep 3 -Preview -Cache -Scenario unsafe
        if ($result.Error -or $result.Status -ne 1 -or $result.Mutations -or $result.Before -ne $result.After -or $result.Messages -notmatch 'unsafe') { throw 'Unsafe preview was not a read-only failure.' }
    }
    It 'treats wildcard app names literally when removing cache files' {
        $result = Invoke-CleanupPlanFixture -Cache -App 'fixture[ab]'
        if ($result.Error -or $result.Status -ne 0 -or $result.Cache -contains 'fixture[ab]#1.10#payload.zip' -or $result.Cache -notcontains 'fixture[ab]#2.0#payload.zip' -or $result.Cache -notcontains 'fixtureX#1.10#keep.zip') { throw "App names were interpreted as cache wildcards: $($result.Messages); cache=$($result.Cache -join ',')" }
    }
    It 'executes the real top-level getopt and propagates CLI options and status (<Flag>)' -TestCases @(@{ Flag = '--keep' }, @{ Flag = '-n' }) {
        param($Flag)
        $result = Invoke-CleanupCommandFixture @('fixture', $Flag, '3', '--dry-run', '--cache')
        if ($result.Exit -ne 7 -or $result.Output -notmatch '"Keep":3' -or $result.Output -notmatch '"DryRun":true' -or $result.Output -notmatch '"Cache":true') { throw "CLI option fixture failed: exit=$($result.Exit), $($result.Output)" }
    }
    It 'rejects invalid CLI retention with exit 1 (<Value>)' -TestCases @(@{ Value = '0' }, @{ Value = '-1' }, @{ Value = '1.5' }, @{ Value = 'no' }) {
        param($Value)
        $result = Invoke-CleanupCommandFixture @('fixture', '--keep', $Value, '--dry-run')
        if ($result.Exit -ne 1 -or $result.Output -notmatch 'positive integer') { throw "CLI accepted invalid retention: exit=$($result.Exit), $($result.Output)" }
    }
    It 'reports missing keep arguments and defaults to keep one with preview disabled' {
        $missing = Invoke-CleanupCommandFixture @('fixture', '-n')
        $default = Invoke-CleanupCommandFixture @('fixture')
        if ($missing.Exit -ne 1 -or $missing.Output -notmatch 'requires an argument' -or $default.Exit -ne 7 -or $default.Output -notmatch '"Keep":1' -or $default.Output -notmatch '"DryRun":false') { throw 'CLI argument validation/defaults failed.' }
    }
}
