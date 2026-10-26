Describe 'Explicit ordinary GUI relaunch policy' {
    BeforeEach {
        $sourceRoot = $env:SCOOP_LOCAL_EXTENSIONS_SOURCE
        if (!$sourceRoot) { throw 'SCOOP_LOCAL_EXTENSIONS_SOURCE is required.' }
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/install.ps1'), [ref]$null, [ref]$errors)
        if ($errors.Count) { throw 'Install source does not parse.' }
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $fixtureRoot = Join-Path $TestDrive 'sample'
        $newRoot = Join-Path $fixtureRoot '2'
        New-Item (Join-Path $fixtureRoot 'current'), $newRoot -ItemType Directory -Force | Out-Null
        $guiPath = Join-Path $fixtureRoot 'current/app.exe'
        $fixtureProcess = [pscustomobject]@{ Id = 81234; Path = $guiPath; MainWindowHandle = 1; ProcessName = 'app' }
        $script:fixtureIsService = $false
        $script:fixtureAncestor = 81236
        $script:fixtureProcesses = @($fixtureProcess)
        $script:fixtureRemaining = $false
        $script:fixtureStopFailure = $false
        $script:fixtureQueries = 0
        $script:fixtureKill = $true
        $script:ScoopRestartEnabled = $false
        $script:ScoopRestartExecutables = @()
        $script:ScoopRestartPrimaryExecutables = @('app.exe')
        $stopped = New-Object 'System.Collections.Generic.List[int]'
        $launched = New-Object 'System.Collections.Generic.List[object]'
        function Get-CimInstance($ClassName, $Filter) {
            if ($ClassName -eq 'Win32_Service') {
                if ($script:fixtureIsService) { [pscustomobject]@{ Name = 'fixture-service' } }
            } elseif ($Filter -eq "ProcessId=$PID") { [pscustomobject]@{ ParentProcessId = $script:fixtureAncestor } }
            else { [pscustomobject]@{ ParentProcessId = 0 } }
        }
        function appdir { $fixtureRoot }
        function get_config($Name) { if ($Name -eq 'KILL_RUNNING_PROCESSES') { $script:fixtureKill } else { $false } }
        function Get-Process {
            $script:fixtureQueries++
            if ($script:fixtureQueries -eq 1 -or $script:fixtureRemaining) { $script:fixtureProcesses }
        }
        function Stop-Process {
            [CmdletBinding()]
            param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force)
            process {
                if ($script:fixtureStopFailure) { throw 'Controlled stop failure.' }
                $stopped.Add($InputObject.Id)
            }
        }
        function Wait-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, [int]$Timeout) process {} }
        function Write-Host {}
        function warn {}
        function error {}
        function Select-CurrentVersion { '2' }
        function installed_manifest { @{ version = '2' } }
        function versiondir { $newRoot }
        function Start-Process {
            [CmdletBinding()]
            param([string]$FilePath, [string]$WindowStyle)
            $launched.Add([pscustomobject]@{ File = $FilePath; Hidden = $WindowStyle -eq 'Hidden'; Parameters = @($PSBoundParameters.Keys) })
        }
        $entry = [pscustomobject]@{ App = 'sample'; Version = '2' }
        [IO.File]::WriteAllText((Join-Path $newRoot 'app.exe'), 'not an executable; controlled launch stub only')
        function Assert-Rejected([scriptblock]$Action) {
            $caught = $false
            try { & $Action | Out-Null } catch { $caught = $true }
            if (!$caught) { throw 'Unsafe relaunch was accepted.' }
        }
    }
    AfterEach {
        $script:ScoopRestartEnabled = $false
        $script:ScoopRestartExecutables = @()
        $script:ScoopRestartPrimaryExecutables = @()
    }
    It 'derives primary identity only from safe executable shortcuts and skips undeclared apps' {
        function arch_specific($Field, $Manifest) { $Manifest.$Field }
        $manifest = '{"shortcuts":[["app.exe","App"],["$dir\\sub\\gui.exe","Gui"],["..\\escape.exe","Bad"],["C:\\outside.exe","Bad"],["$env:TEMP\\a.exe","Bad"],["script.cmd","Script"]]}' | ConvertFrom-Json
        $primary = @(Get-ScoopRestartPrimaryExecutable $manifest '64bit')
        if (($primary -join ',') -ne 'app.exe,sub\gui.exe') { throw "Unsafe or missing primary mapping: $primary" }
        $script:ScoopRestartPrimaryExecutables = @()
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'GUI without declared primary executable was guessed.' }
    }
    It 'records only GUI instances selected and successfully stopped under the explicit opt-in' {
        $script:ScoopRestartEnabled = $true
        $headless = [pscustomobject]@{ Id = 81235; Path = (Join-Path $fixtureRoot 'current/helper.exe'); MainWindowHandle = 0; ProcessName = 'helper' }
        $script:fixtureProcesses += $headless
        if (test_running_process 'sample' $false) { throw 'Controlled stopped process remained blocked.' }
        if (($stopped -join ',') -ne '81234,81235') { throw 'Process-stop selection changed.' }
        if (($script:ScoopRestartExecutables -join ',') -ne 'app.exe') { throw 'Only the stopped GUI should be recorded.' }
        if ($launched.Count) { throw 'The process guard must never relaunch.' }
    }
    It 'records a declared primary GUI but never an undeclared windowed helper' {
        $script:ScoopRestartEnabled = $true
        $script:ScoopRestartPrimaryExecutables = @('app.exe')
        $helper = [pscustomobject]@{ Id = 81235; Path = (Join-Path $fixtureRoot 'current/helper.exe'); MainWindowHandle = 2; ProcessName = 'helper' }
        $script:fixtureProcesses += $helper
        $null = test_running_process 'sample' $false
        if (($script:ScoopRestartExecutables -join ',') -ne 'app.exe') { throw 'Windowed helper was incorrectly recorded for relaunch.' }
        if (($stopped -join ',') -ne '81234,81235') { throw 'Existing stop policy changed.' }
    }
    It 'does not record ordinary stop operations without restart opt-in' {
        $null = test_running_process 'sample' $false
        if ($script:ScoopRestartExecutables.Count) { throw 'Restart records leaked into ordinary stop.' }
    }
    It 'does not record a failed stop or ignored running process' {
        $script:ScoopRestartEnabled = $true
        $script:fixtureStopFailure = $true
        Assert-Rejected { test_running_process 'sample' $false }
        if ($script:ScoopRestartExecutables.Count) { throw 'Failed stop was recorded.' }
        $script:fixtureKill = $false
        $script:fixtureQueries = 0
        $null = test_running_process 'sample' $false
        if ($script:ScoopRestartExecutables.Count) { throw 'Blocked process was recorded.' }
    }
    It 'rejects background, shell, system, service, current and ancestor processes' {
        $fixtureProcess.MainWindowHandle = 0
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Headless process accepted.' }
        $fixtureProcess.MainWindowHandle = 1
        foreach ($name in @('pwsh', 'powershell', 'cmd', 'explorer', 'svchost', 'windowsterminal', 'bash', 'ssh', 'alacritty', 'wezterm-gui', 'kitty', 'tabby', 'nu', 'git-bash')) {
            $fixtureProcess.ProcessName = $name
            if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw "Unsafe process accepted: $name" }
        }
        $fixtureProcess.ProcessName = 'app'
        $script:fixtureIsService = $true
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Service process accepted.' }
        $script:fixtureIsService = $false
        $fixtureProcess.Id = $PID
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Current process accepted.' }
        $fixtureProcess.Id = $script:fixtureAncestor
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Ancestor process accepted.' }
    }
    It 'fails closed if service and parent identity cannot be checked' {
        function Get-CimInstance { throw 'Controlled CIM failure.' }
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Unknown process identity accepted.' }
    }
    It 'maps only current alias and its physical version, not old or sibling versions' {
        if ((Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) -ne 'app.exe') { throw 'Current alias was not mapped.' }
        function Get-Item { [pscustomobject]@{ Target = (Join-Path $fixtureRoot '1') } }
        $fixtureProcess.Path = Join-Path $fixtureRoot '1/app.exe'
        if ((Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) -ne 'app.exe') { throw 'Physical current version was not mapped.' }
        $fixtureProcess.Path = Join-Path $fixtureRoot '0/app.exe'
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Old unrelated version accepted.' }
        $fixtureProcess.Path = $fixtureRoot + '-sibling\current\app.exe'
        if (Get-ScoopRestartCandidate $fixtureProcess $fixtureRoot) { throw 'Sibling app accepted.' }
    }
    It 'launches each recorded GUI once under the verified new root with hidden creation and no arguments' {
        Invoke-ScoopPreparedRestart $entry $false @('app.exe', 'APP.EXE')
        if ($launched.Count -ne 1 -or !$launched[0].Hidden) { throw 'Relaunch was not deduplicated and hidden.' }
        if ($launched[0].File -ne (Join-Path $newRoot 'app.exe')) { throw 'Relaunch used the old executable.' }
        if ($launched[0].Parameters -contains 'ArgumentList' -or $launched[0].Parameters -contains 'WorkingDirectory') { throw 'Relaunch restored unsupported arguments or CWD.' }
    }
    It 'does not relaunch unverified versions, missing executables or escaping paths' {
        function Select-CurrentVersion { '1' }
        Assert-Rejected { Invoke-ScoopPreparedRestart $entry $false @('app.exe') }
        function Select-CurrentVersion { '2' }
        Assert-Rejected { Invoke-ScoopPreparedRestart $entry $false @('missing.exe') }
        Assert-Rejected { Invoke-ScoopPreparedRestart $entry $false @('..\current\app.exe') }
        if ($launched.Count) { throw 'Invalid update launched a process.' }
    }
    It 'rejects reparse points anywhere in the new executable ancestry' {
        function Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        Assert-Rejected { Invoke-ScoopPreparedRestart $entry $false @('app.exe') }
        if ($launched.Count) { throw 'Reparse executable was launched.' }
    }
    It 'reports launch failures rather than claiming restoration succeeded' {
        function Start-Process { throw 'Controlled launch failure.' }
        Assert-Rejected { Invoke-ScoopPreparedRestart $entry $false @('app.exe') }
    }
}
