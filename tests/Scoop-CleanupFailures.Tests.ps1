Describe 'Cleanup failures are isolated and reported safely' -Tag 'Scoop' {
    BeforeEach {
        function Invoke-CleanupFixture {
            param([string]$Scenario)
            $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'libexec/scoop-cleanup.ps1'), [ref]$null, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "Cannot parse cleanup command: $parseErrors" }
            $definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
            $source = ($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
            if ($Scenario -in @('readonly-hardlink', 'hardlink')) {
                $installErrors = $null
                $installAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/install.ps1'), [ref]$null, [ref]$installErrors)
                if ($installErrors.Count) { throw "Cannot parse persist helpers: $installErrors" }
                $persistHelpers = $installAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('persist_def', 'unlink_persist_data') }, $false)
                if ($persistHelpers.Count -ne 2) { throw 'The actual Scoop persist helpers were not found.' }
                $source += "`n" + (($persistHelpers | ForEach-Object { $_.Extent.Text }) -join "`n")
            }
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
            $root = Join-Path $temp ('scoop-cleanup-test-' + [guid]::NewGuid().ToString('N'))
            if (![IO.Path]::GetFullPath($root).StartsWith($temp + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
            $fixture = New-Module -ScriptBlock {
                function Invoke-Fixture {
                    param($Source, $Root, $Scenario)
                    $script:root = $Root
                    $script:scenario = $Scenario
                    $script:warnings = New-Object 'Collections.Generic.List[string]'
                    $script:successes = New-Object 'Collections.Generic.List[string]'
                    $script:processChecks = 0
                    $script:moduleReads = 0
                    $cachedir = Join-Path $Root 'cache'
                    New-Item -ItemType Directory -Path $cachedir -Force | Out-Null
                    if ($Scenario -eq 'cache') { [IO.File]::WriteAllText((Join-Path $cachedir 'first#1.0#payload.zip'), 'fixture') }
                    if ($Scenario -eq 'downloads') { [IO.File]::WriteAllText((Join-Path $cachedir 'partial.download'), 'fixture') }
                    foreach ($app in @('first', 'second')) {
                        foreach ($version in @('1.0', '2.0', '3.0')) {
                            $directory = Join-Path $Root "$app\$version"
                            New-Item -ItemType Directory -Path $directory -Force | Out-Null
                            [IO.File]::WriteAllText((Join-Path $directory 'payload.txt'), 'fixture')
                        }
                    }
                    foreach ($name in @('persist', 'outside')) {
                        New-Item -ItemType Directory -Path (Join-Path $Root $name) | Out-Null
                        [IO.File]::WriteAllText((Join-Path $Root "$name\keep.txt"), $name)
                    }
                    if ($Scenario -in @('readonly-hardlink', 'hardlink')) {
                        $targetPath = [IO.Path]::GetFullPath((Join-Path $Root 'persist\keep.txt'))
                        if (!$targetPath.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture file attribute path.' }
                        New-Item -ItemType HardLink -Path (Join-Path $Root 'first\1.0\data') -Target $targetPath | Out-Null
                        if ($Scenario -eq 'readonly-hardlink') {
                            attrib +R $targetPath
                            if ($LASTEXITCODE) { throw 'Could not mark the fixture hardlinked file read-only.' }
                        }
                    }
                    if ($Scenario -in @('persist', 'nested-persist', 'readonly-persist')) { New-Item -ItemType Junction -Path (Join-Path $Root 'first\1.0\data') -Target (Join-Path $Root 'persist') | Out-Null }
                    if ($Scenario -eq 'readonly-persist') {
                        $linkPath = [IO.Path]::GetFullPath((Join-Path $Root 'first\1.0\data'))
                        if (!$linkPath.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture link attribute path.' }
                        attrib +R /L $linkPath
                        if ($LASTEXITCODE) { throw 'Could not mark the fixture junction read-only.' }
                    }
                    if ($Scenario -eq 'nested-persist') {
                        New-Item -ItemType Directory -Path (Join-Path $Root 'first\1.0\nested') | Out-Null
                        New-Item -ItemType Junction -Path (Join-Path $Root 'first\1.0\nested\data') -Target (Join-Path $Root 'persist') | Out-Null
                    }
                    if ($Scenario -eq 'junction') {
                        Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $Root 'first\1.0') -Recurse -Force
                        New-Item -ItemType Junction -Path (Join-Path $Root 'first\1.0') -Target (Join-Path $Root 'outside') | Out-Null
                    }
                    if ($Scenario -eq 'current-parent-link') {
                        New-Item -ItemType Junction -Path (Join-Path $Root 'alias') -Target (Join-Path $Root 'first') | Out-Null
                        New-Item -ItemType Junction -Path (Join-Path $Root 'first\current') -Target (Join-Path $Root 'alias\2.0') | Out-Null
                    }
                    if ($Scenario -eq 'current-target') { New-Item -ItemType Junction -Path (Join-Path $Root 'first\current') -Target (Join-Path $Root 'first\2.0') | Out-Null }
                    function Select-CurrentVersion { param($AppName, [switch]$Global) if ($script:scenario -eq 'unknown-current' -and $AppName -eq 'first') { return }; '3.0' }
                    function appdir { param($App, $Global) Join-Path $script:root $App }
                    function versiondir {
                        param($App, $Version, $Global)
                        if ($script:scenario -eq 'escape' -and $App -eq 'first' -and $Version -eq '1.0') { return (Join-Path $script:root 'outside') }
                        if ($App -eq 'first' -and $Version -eq '1.0') {
                            if ($script:scenario -eq 'app-root') { return (Join-Path $script:root $App) }
                            if ($script:scenario -eq 'relative') { return 'first\1.0' }
                            if ($script:scenario -eq 'selected-current') { return (Join-Path $script:root 'first\3.0') }
                        }
                        Join-Path $script:root "$App\$Version"
                    }
                    function installed_manifest {
                        param($App, $Version, $Global)
                        if ($script:scenario -eq 'persist-escape' -and $App -eq 'first') { return @{ persist = '..\..\persist' } }
                        @{ persist = 'data' }
                    }
                    function persist_def { param($Definition) $Definition }
                    function unlink_persist_data {
                        param($Manifest, $Directory)
                        $link = Get-Item -LiteralPath (Join-Path $Directory 'data') -ErrorAction SilentlyContinue
                        if ($link -and $link.LinkType) { throw 'Persist junction reached the unsafe recursive unlink helper.' }
                    }
                    function Write-Host {}
                    function warn { param($Message) $script:warnings.Add([string]$Message) }
                    function success { param($Message) $script:successes.Add([string]$Message) }
                    function Get-Process {
                        param([int]$Id)
                        $script:processChecks++
                        if ($script:scenario -eq 'native-owner' -and $Id) { return Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop }
                        if ($script:scenario -eq 'many-processes') {
                            foreach ($index in 1..300) {
                                $process = [pscustomobject]@{ ProcessName = 'unrelated'; Id = $index }
                                $process | Add-Member -MemberType ScriptProperty -Name Modules -Value { $script:moduleReads++; @() }
                                $process
                            }
                            return
                        }
                        if ($script:scenario -eq 'owner') {
                            return [pscustomobject]@{ ProcessName = 'fixture-owner'; Id = 4242; Modules = @([pscustomobject]@{ FileName = (Join-Path $script:root 'first\1.0\payload.txt') }) }
                        }
                        throw 'Process inspection is unavailable in this fixture.'
                    }
                    function Remove-Item {
                        [CmdletBinding()]
                        param([string[]]$Path, [string[]]$LiteralPath, [switch]$Recurse, [switch]$Force, [string[]]$Exclude)
                        $target = if ($LiteralPath) { $LiteralPath[0] } else { $Path[0] }
                        if ($Recurse -and ![IO.Path]::GetFullPath($target).StartsWith($script:root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe recursive fixture target: $target" }
                        if ($script:scenario -in @('blocked', 'owner', 'many-processes') -and $target -eq (Join-Path $script:root 'first\1.0')) { throw 'Access denied to PowerToys.FileLocksmithExt.dll' }
                        if ($script:scenario -eq 'cache' -and $target -like '*#*') { throw 'Cache access denied.' }
                        if ($script:scenario -eq 'downloads' -and $target -like '*.download') { throw 'Download remnant access denied.' }
                        $arguments = @{ Force = $Force; Recurse = $Recurse; ErrorAction = 'Stop' }
                        if ($LiteralPath) { $arguments.LiteralPath = $LiteralPath } else { $arguments.Path = $Path }
                        if ($Exclude) { $arguments.Exclude = $Exclude }
                        Microsoft.PowerShell.Management\Remove-Item @arguments
                    }
                    . ([scriptblock]::Create($Source))
                    $handle = $null
                    if ($Scenario -in @('lock', 'native-owner')) { $handle = [IO.File]::Open((Join-Path $Root 'first\1.0\payload.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
                    $failure = $null
                    $status = $null
                    try {
                        if (Get-Command Invoke-CleanupApps -ErrorAction SilentlyContinue) { $status = Invoke-CleanupApps @(@('first', $false), @('second', $false)) $false ($Scenario -in @('cache', 'downloads')) }
                        else { foreach ($app in @('first', 'second')) { cleanup $app $false $false ($Scenario -eq 'cache') }; $status = 0 }
                    } catch { $failure = $_.Exception.Message }
                    finally { if ($handle) { $handle.Dispose() } }
                    [pscustomobject]@{
                        ProcessChecks = $script:processChecks; ModuleReads = $script:moduleReads; FixtureProcessId = $PID
                        PersistAttributes = (Get-Item -LiteralPath (Join-Path $Root 'persist')).Attributes
                        PersistFileAttributes = (Get-Item -LiteralPath (Join-Path $Root 'persist\keep.txt')).Attributes
                        PersistFileContent = [IO.File]::ReadAllText((Join-Path $Root 'persist\keep.txt'))
                        Error = $failure; Status = $status; Warnings = $script:warnings.ToArray(); Successes = $script:successes.ToArray()
                        FirstOld = Test-Path -LiteralPath (Join-Path $Root 'first\1.0')
                        FirstOtherOld = Test-Path -LiteralPath (Join-Path $Root 'first\2.0')
                        SecondOld = Test-Path -LiteralPath (Join-Path $Root 'second\1.0')
                        FirstCurrent = Test-Path -LiteralPath (Join-Path $Root 'first\3.0\payload.txt')
                        SecondCurrent = Test-Path -LiteralPath (Join-Path $Root 'second\3.0\payload.txt')
                        Persist = Test-Path -LiteralPath (Join-Path $Root 'persist\keep.txt')
                        Outside = Test-Path -LiteralPath (Join-Path $Root 'outside\keep.txt')
                    }
                }
            }
            try { & $fixture { param($Source, $Root, $Scenario) Invoke-Fixture $Source $Root $Scenario } $source $root $Scenario }
            finally {
                Remove-Module $fixture -ErrorAction SilentlyContinue
                $resolved = [IO.Path]::GetFullPath($root)
                if (!$resolved.StartsWith($temp + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
                if (Test-Path -LiteralPath $resolved) {
                    $pending = New-Object 'Collections.Generic.Stack[string]'
                    $pending.Push($resolved)
                    while ($pending.Count) {
                        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                            if ($item.PSIsContainer) {
                                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                                    attrib -R /L $item.FullName
                                    [IO.Directory]::Delete($item.FullName)
                                }
                                else { $pending.Push($item.FullName) }
                            }
                        }
                    }
                    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolved -Recurse -Force
                }
            }
        }
        function Invoke-OwnerDiagnosticFixture {
            param([string]$Scenario)
            $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'libexec/scoop-cleanup.ps1'), [ref]$null, [ref]$null)
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-CleanupOwner' }, $false)
            if (!$definition) { throw 'The safe owner diagnostic helper is missing.' }
            $fixture = New-Module -ScriptBlock {
                function Invoke-Fixture {
                    param($Source, $Scenario)
                    $script:scenario = $Scenario
                    $script:warnings = New-Object 'Collections.Generic.List[string]'
                    $script:started = [DateTime]::UtcNow.AddMinutes(-1)
                    function warn { param($Message) $script:warnings.Add([string]$Message) }
                    function Get-Process {
                        if ($script:scenario -eq 'unavailable') { throw 'Access denied.' }
                        $name = if ($script:scenario -eq 'explorer') { 'explorer' } elseif ($script:scenario -eq 'critical-name') { 'lsass' } else { 'fixture-owner' }
                        [pscustomobject]@{ ProcessName = $name; Path = 'C:\fixture\owner.exe'; StartTime = $script:started }
                    }
                    . ([scriptblock]::Create($Source))
                    $startTime = $script:started.ToFileTimeUtc()
                    if ($Scenario -eq 'reused') { $startTime-- }
                    $owner = [pscustomobject]@{ ProcessId = 4242; StartTime = $startTime; AppName = 'Fixture application'; ServiceName = ''; AppType = 0 }
                    if ($Scenario -eq 'service') { $owner.ServiceName = 'fixture-service'; $owner.AppType = 3 }
                    if ($Scenario -eq 'critical') { $owner.AppType = 1000 }
                    if ($Scenario -eq 'explorer') { $owner.AppType = 4 }
                    Write-CleanupOwner $owner
                    $script:warnings -join ' '
                }
            }
            try { & $fixture { param($Source, $Scenario) Invoke-Fixture $Source $Scenario } $definition.Extent.Text $Scenario }
            finally { Remove-Module $fixture -ErrorAction SilentlyContinue }
        }
        function Assert-CleanupPartial {
            param($Result)
            if ($Result.Error) { throw "Cleanup escaped its failure boundary: $($Result.Error)" }
            if ($Result.Status -ne 1) { throw "Expected incomplete status 1, got '$($Result.Status)'." }
            if ($Result.SecondOld) { throw 'Cleanup did not continue to the second app.' }
            if (!$Result.FirstCurrent -or !$Result.SecondCurrent -or !$Result.Persist -or !$Result.Outside) { throw 'Protected fixture data was removed.' }
            if (($Result.Successes -join ' ') -match 'Everything is shiny now') { throw 'Partial cleanup reported complete success.' }
            if (($Result.Warnings -join ' ') -notmatch 'incomplete') { throw 'The incomplete summary is missing.' }
        }
    }
    It 'continues across versions and apps after access is denied' {
        $result = Invoke-CleanupFixture blocked
        Assert-CleanupPartial $result
        if (!$result.FirstOld -or $result.FirstOtherOld) { throw 'Blocked and removable versions were not handled separately.' }
        if (($result.Warnings -join ' ') -notmatch 'first.*1\.0' -or ($result.Warnings -join ' ') -notmatch 'PowerToys.FileLocksmithExt.dll') { throw 'The failed app, version, path, and original error must be reported.' }
    }
    It 'continues after a real Windows exclusive file lock' {
        $result = Invoke-CleanupFixture lock
        Assert-CleanupPartial $result
        if (!$result.FirstOld -or $result.FirstOtherOld) { throw 'The real lock did not preserve only the blocked old version.' }
    }
    It 'rejects a version path outside the app directory' { Assert-CleanupPartial (Invoke-CleanupFixture escape) }
    It 'rejects a version directory junction without traversing its target' { Assert-CleanupPartial (Invoke-CleanupFixture junction) }
    It 'protects the current junction target even when the manifest disagrees' {
        $result = Invoke-CleanupFixture current-target
        Assert-CleanupPartial $result
        if (!$result.FirstOtherOld) { throw 'The actual current junction target was removed.' }
    }
    It 'unlinks persist directory junctions without recursive traversal' {
        $result = Invoke-CleanupFixture persist
        if ($result.Error -or $result.Status -ne 0 -or !$result.Persist -or !$result.FirstCurrent -or $result.FirstOld -or $result.SecondOld) { throw "Persist-safe cleanup failed: $($result.Error)" }
    }
    It 'continues after cache deletion fails' { Assert-CleanupPartial (Invoke-CleanupFixture cache) }
    It 'reports download-remnant failures instead of success' { Assert-CleanupPartial (Invoke-CleanupFixture downloads) }
    It 'reports complete success only when all work succeeds' {
        $result = Invoke-CleanupFixture success
        if ($result.Error -or $result.Status -ne 0 -or $result.FirstOld -or $result.SecondOld -or !$result.FirstCurrent -or !$result.SecondCurrent -or $result.ProcessChecks) { throw "Successful cleanup failed: $($result.Error)" }
        if (($result.Successes -join ' ') -notmatch 'Everything is shiny now') { throw 'The successful all-app summary is missing.' }
    }
    It 'propagates the aggregate cleanup exit status from the CLI' {
        $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
        $text = Get-Content -LiteralPath (Join-Path $sourceRoot 'libexec/scoop-cleanup.ps1') -Raw
        if ($text -notmatch 'exit\s+\(Invoke-CleanupApps\s+\$apps\s+\$verbose\s+\$cache\)') { throw 'The CLI must return the aggregate cleanup status.' }
    }
    It 'rejects the app root as a version removal target' { Assert-CleanupPartial (Invoke-CleanupFixture app-root) }
    It 'rejects relative version paths' { Assert-CleanupPartial (Invoke-CleanupFixture relative) }
    It 'rejects the selected current version as a removal target' { Assert-CleanupPartial (Invoke-CleanupFixture selected-current) }
    It 'fails closed when the current version cannot be determined' { Assert-CleanupPartial (Invoke-CleanupFixture unknown-current) }
    It 'rejects manifest persist paths that escape the version directory' { Assert-CleanupPartial (Invoke-CleanupFixture persist-escape) }
    It 'protects the current target through a junction in its parent path' {
        $result = Invoke-CleanupFixture current-parent-link
        Assert-CleanupPartial $result
        if (!$result.FirstOtherOld) { throw 'The current target through a parent junction was removed.' }
    }
    It 'unlinks nested directory junctions without touching persisted files' {
        $result = Invoke-CleanupFixture nested-persist
        if ($result.Error -or $result.Status -ne 0 -or !$result.Persist -or $result.FirstOld) { throw 'Nested persisted data was not protected.' }
    }
    It 'reports identifiable possible owners without claiming a proven file lock' {
        $result = Invoke-CleanupFixture owner
        Assert-CleanupPartial $result
        if (($result.Warnings -join ' ') -notmatch 'fixture-owner \(PID 4242\)' -or ($result.Warnings -join ' ') -notmatch 'not proof of a lock') { throw 'Possible-owner diagnostics were missing or overstated.' }
    }
    It 'unlinks read-only persist junctions without changing the target data' {
        $result = Invoke-CleanupFixture readonly-persist
        if ($result.Error -or $result.Status -ne 0 -or !$result.Persist -or $result.FirstOld -or ($result.PersistAttributes -band [IO.FileAttributes]::ReadOnly)) { throw 'Read-only persisted junction cleanup failed or changed the target attributes.' }
    }
    It 'bounds process module inspection after a cleanup failure' {
        $result = Invoke-CleanupFixture many-processes
        Assert-CleanupPartial $result
        if ($result.ModuleReads -gt 128) { throw "Expected a bounded owner scan, got $($result.ModuleReads) reads." }
    }
    It 'identifies a real lock with Restart Manager and reports the PID and executable' {
        $result = Invoke-CleanupFixture native-owner
        Assert-CleanupPartial $result
        $warnings = $result.Warnings -join ' '
        if ($warnings -notmatch 'Restart Manager' -or $warnings -notmatch "PID $($result.FixtureProcessId)" -or $warnings -notmatch 'Executable:' ) { throw "Native owner diagnostics are missing: $warnings" }
        if ($warnings -notmatch 'No termination command is suggested' -and $warnings -notmatch 'not executed') { throw 'The safe termination guidance is missing.' }
    }
    It 'prints a copyable manual-only command for a verified noncritical owner' {
        $warnings = Invoke-OwnerDiagnosticFixture regular
        if ($warnings -notmatch 'Stop-Process -Id 4242' -or $warnings -notmatch 'not executed' -or $warnings -notmatch 'Save work' -or $warnings -notmatch 'Executable: C:\\fixture\\owner.exe') { throw "Manual owner guidance is incomplete: $warnings" }
    }
    It 'warns about the desktop before offering a manual Explorer command' {
        $warnings = Invoke-OwnerDiagnosticFixture explorer
        if ($warnings -notmatch 'desktop and taskbar' -or $warnings -notmatch 'Stop-Process -Id 4242') { throw 'The Explorer risk warning or manual command is missing.' }
    }
    It 'never suggests termination for services or critical processes (<Scenario>)' -TestCases @(@{ Scenario = 'service' }, @{ Scenario = 'critical' }, @{ Scenario = 'critical-name' }) {
        param($Scenario)
        $warnings = Invoke-OwnerDiagnosticFixture $Scenario
        if ($warnings -match 'Stop-Process' -or $warnings -notmatch 'No termination command is suggested') { throw "Unsafe critical/service guidance: $warnings" }
    }
    It 'does not suggest termination for reused or unverifiable PIDs (<Scenario>)' -TestCases @(@{ Scenario = 'reused' }, @{ Scenario = 'unavailable' }) {
        param($Scenario)
        $warnings = Invoke-OwnerDiagnosticFixture $Scenario
        if ($warnings -match 'Stop-Process' -or $warnings -notmatch 'PID/start time could not be verified') { throw "Unsafe stale-PID guidance: $warnings" }
    }
    It 'preserves read-only persisted hardlinks rather than clearing shared target attributes' {
        $result = Invoke-CleanupFixture readonly-hardlink
        Assert-CleanupPartial $result
        if (!$result.FirstOld -or !$result.Persist -or $result.PersistFileContent -ne 'persist' -or !($result.PersistFileAttributes -band [IO.FileAttributes]::ReadOnly)) { throw "Read-only hardlinked data was changed or cleanup failed: error=$($result.Error), status=$($result.Status), attributes=$($result.PersistFileAttributes)" }
    }

    It 'deletes a writable old persist hardlink using the actual Scoop helper without deleting its target' {
        $result = Invoke-CleanupFixture hardlink
        if ($result.Error -or $result.Status -ne 0 -or $result.FirstOld -or !$result.Persist -or $result.PersistFileContent -ne 'persist' -or ($result.PersistFileAttributes -band [IO.FileAttributes]::ReadOnly)) { throw 'Writable hardlink cleanup changed the persisted data or failed.' }
    }

}
