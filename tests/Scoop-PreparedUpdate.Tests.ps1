Describe 'Batch short option parsing' {
    BeforeEach {
        function Read-UpdateOptions {
            param([string[]]$Options)
            $root = $env:SCOOP_LOCAL_EXTENSIONS_SOURCE
            $text = [IO.File]::ReadAllText((Join-Path $root 'libexec/scoop-update.ps1'))
            $start = $text.IndexOf('$opt, $apps, $err = getopt')
            $end = $text.IndexOf('# load config', $start)
            if ($start -lt 0 -or $end -le $start) { throw 'Update option parser was not found.' }
            $parser = $text.Substring($start, $end - $start).Replace('exit 1', "throw 'Invalid update options'")
            $getopt = [IO.File]::ReadAllText((Join-Path $root 'lib/getopt.ps1'))
            $fixture = New-Module -ScriptBlock {
                function Invoke-Parser {
                    param($GetoptSource, $ParserSource, $Options)
                    function error {}
                    . ([scriptblock]::Create($GetoptSource))
                    . ([scriptblock]::Create($ParserSource)) @Options
                    [pscustomobject]@{ Prepared = [bool]$preparedMode; All = [bool]$all; Apps = @($apps) }
                }
            }
            try {
                & $fixture { param($GetoptSource, $ParserSource, $Options)
                    Invoke-Parser $GetoptSource $ParserSource $Options
                } $getopt $parser $Options
            } finally { Remove-Module $fixture -ErrorAction SilentlyContinue }
        }
    }

    It 'enables the same batch mode through short, long and clustered options (<Mode>)' -TestCases @(
        @{ Mode = '-b'; Options = @('*', '-b'); All = $false },
        @{ Mode = '--batch'; Options = @('*', '--batch'); All = $false },
        @{ Mode = '-ab'; Options = @('-ab'); All = $true }
    ) {
        param($Mode, $Options, $All)
        $result = Read-UpdateOptions $Options
        if (!$result.Prepared -or $result.All -ne $All) { throw "Batch option did not select the expected mode: $Mode" }
        if (!$All -and ($result.Apps -join ',') -ne '*') { throw 'The short option changed the application arguments.' }
    }

    It 'keeps hash and cache bypass guards for the short alias (<Option>)' -TestCases @(
        @{ Option = '-bk' }, @{ Option = '-bs' }
    ) {
        param($Option)
        $rejected = $false
        try { Read-UpdateOptions @('*', $Option) | Out-Null } catch { $rejected = $true }
        if (!$rejected) { throw "Batch safety guard was bypassed: $Option" }
    }

    It 'leaves ordinary update mode unchanged without a batch option' {
        if ((Read-UpdateOptions @('*')).Prepared) { throw 'Batch mode must remain opt-in.' }
    }
}

Describe 'Frozen prepared updates' {
    BeforeEach {
        $sourceRoot = $env:SCOOP_LOCAL_EXTENSIONS_SOURCE
        if (!$sourceRoot) { throw 'SCOOP_LOCAL_EXTENSIONS_SOURCE is required.' }
        foreach ($file in @('lib/install.ps1', 'lib/download.ps1', 'libexec/scoop-update.ps1')) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $file), [ref]$null, [ref]$errors)
            if ($errors.Count) { throw "Source does not parse: $file" }
            foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                if ($file -eq 'lib/install.ps1' -or $definition.Name -in @('New-ScoopUpdatePlan', 'update', 'Assert-ScoopOfflineManifest', 'Assert-ScoopCachedPayload', 'Assert-ScoopOfflinePhysicalPath', 'get_hash', 'hash_for_url')) {
                    . ([scriptblock]::Create($definition.Extent.Text))
                }
            }
        }
        $cachedir = Join-Path $TestDrive 'cache'
        $appRoot = Join-Path $TestDrive 'apps'
        New-Item $cachedir, $appRoot -ItemType Directory -Force | Out-Null
        $events = New-Object 'System.Collections.Generic.List[string]'
        $manifests = @{}
        $script:fixtureInstalled = @('parent', 'second')
        function script:url($Manifest, $Architecture) { $Manifest.url }
        function arch_specific($Field, $Manifest, $Architecture) { $Manifest.$Field }
        function hash($Manifest, $Architecture) { $Manifest.hash }
        function cache_path($App, $Version, $Url) { Join-Path $cachedir ($App + '-' + [IO.Path]::GetFileName($Url)) }
        function url_filename($Url) { [IO.Path]::GetFileName($Url) }
        function Get-SupportedArchitecture { '64bit' }
        function Format-ArchitectureString { '64bit' }
        function Get-Manifest($Spec) {
            $name = ($Spec -split '/')[-1]
            $events.Add('resolve:' + $name)
            if (!$manifests.ContainsKey($name)) { throw "Missing manifest $name" }
            $name, $manifests[$name], 'main', $null
        }
        function Select-CurrentVersion { '1' }
        function install_info { @{ architecture = '64bit'; bucket = 'main' } }
        function installed_manifest { [pscustomobject]@{ version = '1'; url = 'old.zip'; hash = ('a' * 64); shortcuts = @(,@('app.exe', 'App')) } }
        function installed($App) { $script:fixtureInstalled -contains $App }
        function parse_app($Spec) { ($Spec -split '/')[-1], 'main', $null }
        function usermanifest($App) { 'C:\fixture\' + $App + '.json' }
        function Get-InstallationHelper { @() }
        function Test-HelperInstalled { $true }
        function Invoke-CachedDownload($App, $Version, $Url) { $events.Add('download:' + $App) }
        function Write-Host {}
        function warn {}
        function success {}
        function get_config { $false }
        function show_app($App) { $App }
        function check_hash($Source, $Expected) { @(((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq $Expected), 'bad hash') }
        function Add-FixtureManifest($Name, $Depends, $Hook) {
            $payload = Join-Path $cachedir ($Name + '-payload.zip')
            [IO.File]::WriteAllText($payload, 'fixture-payload')
            $manifest = [pscustomobject]@{ version = '2'; url = 'https://example.invalid/payload.zip'; hash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash }
            $manifest | Add-Member NoteProperty shortcuts @(,@('app.exe', 'App'))
            if ($Depends) { $manifest | Add-Member NoteProperty depends $Depends }
            if ($Hook) { $manifest | Add-Member NoteProperty pre_install $Hook }
            $manifests[$Name] = $manifest
            return $manifest
        }
        function Assert-Rejected([scriptblock]$Action) {
            $caught = $false
            try { & $Action | Out-Null } catch { $caught = $true }
            if (!$caught) { throw 'Unsafe prepared action was accepted.' }
        }
    }
    It 'CLI prefetch prepares the entire batch without process, hook or app-directory actions' {
        $null = Add-FixtureManifest 'parent'
        $null = Add-FixtureManifest 'second'
        $script:cliOptions = @{ prefetch = $true }
        $script:cliApps = @('parent', 'second')
        function getopt { $script:cliOptions, $script:cliApps, $null }
        function set_config {}
        function is_scoop_outdated { $false }
        function Confirm-InstallationStatus($Apps) { , @($Apps | ForEach-Object { , @($_, $false) }) }
        function applist($Apps, $Global) { , @($Apps | ForEach-Object { , @($_, $Global) }) }
        function app_status { @{ installed = $true; outdated = $true; hold = $false; version = '1'; latest_version = '2' } }
        function Test-Aria2Enabled { $false }
        function test_running_process { throw 'Prefetch reached process handling.' }
        function Invoke-HookScript { throw 'Prefetch ran hooks.' }
        function ensure { throw 'Prefetch created an app directory.' }
        function install_app { throw 'Prefetch installed an app.' }
        $command = [IO.File]::ReadAllText((Join-Path $sourceRoot 'libexec/scoop-update.ps1'))
        $command = $command -replace '(?m)^\s*\. "\$PSScriptRoot[^\r\n]*', ''
        $command = $command -replace '\bexit ([01])', 'throw "FIXTURE_EXIT_$1"'
        $message = $null
        try { & ([scriptblock]::Create($command)) | Out-Null } catch { $message = $_.Exception.Message }
        if ($message -ne 'FIXTURE_EXIT_0') { throw "Prefetch did not finish successfully: $message" }
        if (($events | Where-Object { $_ -like 'download:*' }).Count -ne 2) { throw 'CLI did not prepare both targets.' }
        if (Test-Path -LiteralPath (Join-Path $appRoot 'parent')) { throw 'Prefetch created an app directory.' }
    }
    It 'CLI online batch preserves normal hook download helpers while offline still blocks them' {
        $null = Add-FixtureManifest 'parent' $null 'Start-Download "https://example.invalid/hook-asset" "fixture-destination"'
        $script:cliOptions = @{ batch = $true }
        $script:cliApps = @('parent')
        $script:ScoopOfflineMode = $false
        function getopt { $script:cliOptions, $script:cliApps, $null }
        function set_config {}
        function is_scoop_outdated { $false }
        function Confirm-InstallationStatus($Apps) { , @($Apps | ForEach-Object { , @($_, $false) }) }
        function applist($Apps, $Global) { , @($Apps | ForEach-Object { , @($_, $Global) }) }
        function app_status { @{ installed = $true; outdated = $true; hold = $false; version = '1'; latest_version = '2' } }
        function Test-Aria2Enabled { $false }
        function test_running_process { $false }
        function versiondir { Join-Path $appRoot 'parent/1' }
        function persistdir { Join-Path $TestDrive 'persist' }
        function Invoke-Installer {}
        function rm_shims {}
        function unlink_current { Join-Path $appRoot 'parent/1' }
        function uninstall_psmodule {}
        function env_rm_path {}
        function env_rm {}
        function handle_special_urls($Url) { $Url }
        function Invoke-Download { $events.Add('hook-download') }
        $errors = $null
        $downloadAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/download.ps1'), [ref]$null, [ref]$errors)
        $startDownload = $downloadAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Download' }, $false)
        . ([scriptblock]::Create($startDownload.Extent.Text))
        function install_app($App, $Architecture, $Global, $Suggested, $UseCache, $CheckHash, $Prepared) {
            Invoke-HookScript -HookType pre_install -Manifest $Prepared.Manifest -Arch $Prepared.Architecture
        }
        $command = [IO.File]::ReadAllText((Join-Path $sourceRoot 'libexec/scoop-update.ps1'))
        $command = $command -replace '(?m)^\s*\. "\$PSScriptRoot[^\r\n]*', ''
        $command = $command -replace '\bexit ([01])', 'throw "FIXTURE_EXIT_$1"'
        $message = $null
        try { & ([scriptblock]::Create($command)) | Out-Null } catch { $message = $_.Exception.Message }
        if ($message -ne 'FIXTURE_EXIT_0' -or $events -notcontains 'hook-download') { throw "Online hook download semantics changed: $message" }
        $previousMode = $script:ScoopOfflineMode
        try {
            $script:ScoopOfflineMode = $true
            Assert-Rejected { Start-Download 'https://example.invalid/offline-hook' 'fixture-destination' }
        } finally { $script:ScoopOfflineMode = $previousMode }
    }
    It 'CLI offline wildcard skips strict hook/cache checks for unchanged or held apps (<State>)' -TestCases @(@{ State = 'unchanged' }, @{ State = 'held' }) {
        param($State)
        $script:fixtureState = $State
        $script:cliOptions = @{ offline = $true }
        $script:cliApps = @('*')
        function getopt { $script:cliOptions, $script:cliApps, $null }
        function set_config {}
        function installed_apps { 'parent' }
        function applist($Apps, $Global) { , @($Apps | ForEach-Object { , @($_, $Global) }) }
        function install_info { @{ architecture = '64bit'; bucket = 'main'; hold = ($script:fixtureState -eq 'held') } }
        function Get-ScoopOfflineManifestEntry { [pscustomobject]@{ App = 'parent'; Version = $(if ($script:fixtureState -eq 'held') { '2' } else { '1' }); Manifest = @{ pre_install = 'unsafe and irrelevant because not updating' } } }
        function Get-ScoopOfflineInstallPlan { throw 'Unselected app reached strict offline preflight.' }
        function is_scoop_outdated { throw 'Offline status queried Scoop metadata.' }
        function app_status { throw 'Offline status used the remote-aware fallback.' }
        function Test-Aria2Enabled { $false }
        function test_running_process { throw 'Skipped app reached process handling.' }
        function install_app { throw 'Skipped app was installed.' }
        $command = [IO.File]::ReadAllText((Join-Path $sourceRoot 'libexec/scoop-update.ps1'))
        $command = $command -replace '(?m)^\s*\. "\$PSScriptRoot[^\r\n]*', ''
        $command = $command -replace '\bexit ([01])', 'throw "FIXTURE_EXIT_$1"'
        $message = $null
        try { & ([scriptblock]::Create($command)) | Out-Null } catch { $message = $_.Exception.Message }
        if ($message -ne 'FIXTURE_EXIT_0') { throw "Offline selection did not safely skip app: $message" }
    }
    It 'CLI batch never reaches a process or install when the last target payload is bad' {
        $null = Add-FixtureManifest 'parent'
        $null = Add-FixtureManifest 'second'
        [IO.File]::WriteAllText((Join-Path $cachedir 'second-payload.zip'), 'corrupt-last-payload')
        $script:cliOptions = @{ batch = $true }
        $script:cliApps = @('parent', 'second')
        function getopt { $script:cliOptions, $script:cliApps, $null }
        function set_config {}
        function is_scoop_outdated { $false }
        function Confirm-InstallationStatus($Apps) { , @($Apps | ForEach-Object { , @($_, $false) }) }
        function applist($Apps, $Global) { , @($Apps | ForEach-Object { , @($_, $Global) }) }
        function app_status { @{ installed = $true; outdated = $true; hold = $false; version = '1'; latest_version = '2' } }
        function Test-Aria2Enabled { $false }
        function test_running_process { $events.Add('process'); throw 'Unsafe process barrier breach.' }
        function install_app { $events.Add('install'); throw 'Unsafe install barrier breach.' }
        $command = [IO.File]::ReadAllText((Join-Path $sourceRoot 'libexec/scoop-update.ps1'))
        $command = $command -replace '(?m)^\s*\. "\$PSScriptRoot[^\r\n]*', ''
        $command = $command -replace '\bexit ([01])', 'throw "FIXTURE_EXIT_$1"'
        $message = $null
        try { & ([scriptblock]::Create($command)) | Out-Null } catch { $message = $_.Exception.Message }
        if ($message -notlike '*hash mismatch*') { throw "Expected cache barrier failure: $message" }
        if ($events -contains 'process' -or $events -contains 'install') { throw 'Whole-batch barrier was breached.' }
        if ($script:ScoopRestartEnabled) { throw 'CLI restart state leaked after failure.' }
    }
    It 'prepares dependencies and all targets before returning without stopping or installing' {
        $null = Add-FixtureManifest 'child'
        $null = Add-FixtureManifest 'parent' @('child')
        $null = Add-FixtureManifest 'second'
        $plan = @(New-ScoopUpdatePlan @(@('parent', $false), @('second', $false)) $false $false $false)
        if (($plan.App -join ',') -ne 'child,parent,second') { throw "Wrong preparation order: $($plan.App)" }
        if (($events | Where-Object { $_ -like 'download:*' }).Count -ne 3) { throw 'Not every payload was prepared.' }
        if (!$plan[1].Update -or $plan[0].Update) { throw 'Dependency must install, target must update.' }
        foreach ($entry in $plan) { Assert-ScoopPreparedEntry $entry }
    }
    It 'permits normal online hooks while keeping offline execution policy strict' {
        $null = Add-FixtureManifest 'parent' $null 'Write-Host normal-online-hook'
        $plan = @(New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false)
        if ($plan.Count -ne 1 -or !$plan[0].Manifest.pre_install) { throw 'Online hooks were discarded.' }
        $plan[0].Offline = $true
        Assert-Rejected { Assert-ScoopPreparedPayload $plan[0] }
    }
    It 'honors independent without resolving missing dependencies or helpers' {
        $null = Add-FixtureManifest 'parent' @('missing')
        function Get-InstallationHelper { 'missing-helper' }
        $plan = @(New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false)
        if (($plan.App -join ',') -ne 'parent') { throw 'Independent mode expanded dependencies.' }
    }
    It 'orders an already installed targeted dependency ahead of its targeted parent' {
        $script:fixtureInstalled = @('parent', 'second')
        $null = Add-FixtureManifest 'parent' @('second')
        $null = Add-FixtureManifest 'second'
        $plan = @(New-ScoopUpdatePlan @(@('parent', $false), @('second', $false)) $false $false $false)
        if (($plan.App -join ',') -ne 'second,parent') { throw 'Target dependency order was not frozen.' }
    }
    It 'does not return partial entries when a later target cache is corrupt' {
        $null = Add-FixtureManifest 'parent'
        $null = Add-FixtureManifest 'second'
        [IO.File]::WriteAllText((Join-Path $cachedir 'second-payload.zip'), 'corrupt')
        $returned = @()
        Assert-Rejected { $returned = @(New-ScoopUpdatePlan @(@('parent', $false), @('second', $false)) $false $true $false) }
        if ($returned.Count) { throw 'Partial preparation escaped the barrier.' }
    }
    It 'rejects nightly and absent hashes before downloading' {
        $manifest = Add-FixtureManifest 'parent'
        $manifest.version = 'nightly'
        Assert-Rejected { New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false }
        $manifest.version = '2'; $manifest.hash = 'skip'
        Assert-Rejected { New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false }
        if ($events -contains 'download:parent') { throw 'Invalid payload was downloaded.' }
    }
    It 'detects mutation of source identity, architecture and frozen manifest' {
        $null = Add-FixtureManifest 'parent'
        $entry = @(New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false)[0]
        $entry.Spec = 'other/parent'
        Assert-Rejected { Assert-ScoopPreparedEntry $entry }
        $entry.Spec = 'main/parent'; $entry.Architecture = '32bit'
        Assert-Rejected { Assert-ScoopPreparedEntry $entry }
        $entry.Architecture = '64bit'; $entry.Manifest.url = 'https://example.invalid/replaced.zip'
        Assert-Rejected { Assert-ScoopPreparedEntry $entry }
    }
    It 'rechecks cache immediately before process checks and never resolves the prepared manifest again' {
        $null = Add-FixtureManifest 'parent'
        $entry = @(New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false)[0]
        function Get-Manifest { throw 'Prepared manifest was resolved again.' }
        function manifest { throw 'Prepared update must not resolve a manifest.' }
        function test_running_process { throw 'Cache failure reached process handling.' }
        [IO.File]::WriteAllText((Join-Path $cachedir 'parent-payload.zip'), 'changed after barrier')
        $message = $null
        try { update 'parent' $false $false $true $true @{} $true $true $entry } catch { $message = $_.Exception.Message }
        if ($message -notlike '*hash mismatch*') { throw "Expected cache revalidation failure, got $message" }
    }
    It 'rejects conflicting shared offline dependency or explicit target identity (<Field>)' -TestCases @(@{ Field = 'Version' }, @{ Field = 'Spec' }, @{ Field = 'Source' }, @{ Field = 'Bucket' }, @{ Field = 'Architecture' }, @{ Field = 'Manifest' }, @{ Field = 'Explicit' }) {
        param($Field)
        $script:fixtureConflictField = $Field
        $null = Add-FixtureManifest 'parent'
        $null = Add-FixtureManifest 'second'
        $null = Add-FixtureManifest 'shared'
        function Get-ScoopOfflineInstallPlan($Apps) {
            $rootName = ($Apps[0] -split '/')[-1]
            $sharedManifest = $manifests.shared | ConvertTo-Json -Depth 100 | ConvertFrom-Json
            $sharedEntry = [pscustomobject]@{ App = 'shared'; Spec = 'main/shared'; Source = 'C:\fixture\shared.json'; Bucket = 'main'; Architecture = '64bit'; Version = $sharedManifest.version; Manifest = $sharedManifest; Offline = $true }
            if ($rootName -ne 'parent') {
                switch ($script:fixtureConflictField) {
                    'Version' { $sharedEntry.Version = '3'; $sharedEntry.Manifest.version = '3' }
                    'Explicit' { $sharedEntry.Version = '3'; $sharedEntry.Manifest.version = '3' }
                    'Spec' { $sharedEntry.Spec = 'other/shared' }
                    'Source' { $sharedEntry.Source = 'C:\fixture\other\shared.json' }
                    'Bucket' { $sharedEntry.Bucket = 'other' }
                    'Architecture' { $sharedEntry.Architecture = '32bit' }
                    'Manifest' { $sharedEntry.Manifest.hash = ('b' * 64) }
                }
            }
            $sharedEntry
            [pscustomobject]@{ App = $rootName; Spec = ('main/' + $rootName); Source = ('C:\fixture\' + $rootName + '.json'); Bucket = 'main'; Architecture = '64bit'; Version = '2'; Manifest = $manifests[$rootName]; Offline = $true }
        }
        $secondTarget = if ($Field -eq 'Explicit') { 'shared' } else { 'second' }
        $message = $null
        try { New-ScoopUpdatePlan @(@('parent', $false), @($secondTarget, $false)) $true $false $false | Out-Null } catch { $message = $_.Exception.Message }
        if ($message -notlike '*Conflicting prepared offline identity*') { throw "Expected source identity collision rejection, got: $message" }
    }
    It 'rejects old uninstall hooks during offline preflight before any cache or process action' {
        function installed_manifest { [pscustomobject]@{ version = '1'; pre_uninstall = 'unsafe'; url = 'old.zip'; hash = ('a' * 64) } }
        function Get-ScoopOfflineInstallPlan { throw 'Old hooks must be rejected first.' }
        $message = $null
        try { New-ScoopUpdatePlan (,@('parent', $false)) $true $true $false } catch { $message = $_.Exception.Message }
        if ($message -notlike '*pre_uninstall*') { throw "Old uninstallation hook was not rejected: $message" }
    }
    It 'relaunches only a successfully installed update, never blocked or failed updates (<Outcome>)' -TestCases @(@{ Outcome = 'success' }, @{ Outcome = 'blocked' }, @{ Outcome = 'failed' }) {
        param($Outcome)
        $null = Add-FixtureManifest 'parent'
        $entry = @(New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false)[0]
        $script:fixtureCurrent = '1'
        $script:fixtureOutcome = $Outcome
        $script:fixtureLaunches = 0
        $script:ScoopRestartEnabled = $true
        $script:ScoopRestartExecutables = @()
        $newRoot = Join-Path $appRoot 'parent/2'
        New-Item -Path $newRoot -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $newRoot 'app.exe'), 'controlled stub only')
        function Select-CurrentVersion { $script:fixtureCurrent }
        function installed_manifest { @{ version = $script:fixtureCurrent; shortcuts = @(,@('app.exe', 'App')) } }
        function manifest { throw 'Prepared update resolved its manifest again.' }
        function test_running_process {
            if ($script:fixtureOutcome -eq 'blocked') { return $true }
            if ($script:ScoopRestartPrimaryExecutables -notcontains 'app.exe') { throw 'Frozen primary executable map was not supplied.' }
            $script:ScoopRestartExecutables = @('app.exe', 'app.exe')
            return $false
        }
        function versiondir { $newRoot }
        function persistdir { Join-Path $TestDrive 'persist' }
        function Invoke-HookScript {}
        function Invoke-Installer {}
        function rm_shims {}
        function unlink_current { $newRoot }
        function uninstall_psmodule {}
        function env_rm_path {}
        function env_rm {}
        function install_app {
            if ($script:fixtureOutcome -eq 'failed') { throw 'Controlled install failure.' }
            $script:fixtureCurrent = '2'
        }
        function Start-Process { [CmdletBinding()] param($FilePath, $WindowStyle) $script:fixtureLaunches++ }
        try {
            $message = $null
            try { update 'parent' $false $false $true $true @{} $true $true $entry } catch { $message = $_.Exception.Message }
            if ($Outcome -eq 'success' -and ($script:fixtureLaunches -ne 1 -or $message)) { throw "Verified update did not relaunch once: $message" }
            if ($Outcome -ne 'success' -and $script:fixtureLaunches) { throw 'Blocked or failed update launched the new app.' }
            if ($Outcome -eq 'failed' -and $message -ne 'Controlled install failure.') { throw 'Install failure was lost.' }
        } finally {
            $script:ScoopRestartEnabled = $false
            $script:ScoopRestartExecutables = @()
        }
    }
    It 'installs frozen manifest content directly with no metadata refetch or downloader' {
        $null = Add-FixtureManifest 'parent'
        $entry = @(New-ScoopUpdatePlan (,@('parent', $false)) $false $true $false)[0]
        function Get-Manifest { throw 'Prepared installation resolved a new manifest.' }
        function save_installed_manifest { throw 'Prepared installation refetched manifest content.' }
        function Invoke-ScoopDownload { throw 'Prepared installation used a downloader.' }
        function versiondir($App, $Version) { Join-Path $appRoot ($App + '/' + $Version) }
        function ensure($Path) { New-Item -Path $Path -ItemType Directory -Force | Out-Null; $Path }
        function persistdir { Join-Path $TestDrive 'persist' }
        function Invoke-Extraction {}
        function Invoke-HookScript {}
        function Invoke-Installer {}
        function ensure_install_dir_not_in_path {}
        function link_current($Path) { $Path }
        function create_shims {}
        function create_startmenu_shortcuts {}
        function install_psmodule {}
        function env_add_path {}
        function env_set {}
        function persist_data {}
        function persist_permission {}
        function ConvertToPrettyJson { param([Parameter(ValueFromPipeline)]$Value) process { $Value | ConvertTo-Json -Depth 100 } }
        function Out-UTF8File { param($Path, [Parameter(ValueFromPipeline)]$Value) process { [IO.File]::WriteAllText($Path, $Value) } }
        function save_install_info {}
        function show_notes {}
        install_app 'parent' '64bit' $false @{} $true $true $entry | Out-Null
        $saved = Get-Content -LiteralPath (Join-Path $appRoot 'parent/2/scoop-manifest.json') -Raw | ConvertFrom-Json
        if ($saved.version -ne '2' -or $saved.hash -ne $entry.Manifest.hash) { throw 'Frozen manifest was not saved directly.' }
        if (!(Test-Path -LiteralPath (Join-Path $appRoot 'parent/2/payload.zip'))) { throw 'Prepared cache payload was not consumed.' }
    }
}
