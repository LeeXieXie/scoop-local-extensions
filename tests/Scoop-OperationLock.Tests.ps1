Describe 'Bounded Scoop operation leases' -Tag Scoop {
    BeforeEach {
        function Assert-LockResult {
            param([Parameter(ValueFromPipeline = $true)]$Actual, [Parameter(Position = 0)][string]$Assertion, [Parameter(Position = 1)]$Expected)
            process {
                $valid = switch ($Assertion) {
                    Be { $Actual -eq $Expected }
                    Match { $Actual -match $Expected }
                    LessThan { $Actual -lt $Expected }
                    NotEmpty { ![string]::IsNullOrEmpty([string]$Actual) }
                    default { throw "Unknown fixture assertion: $Assertion" }
                }
                if (!$valid) { throw "Assertion $Assertion failed: actual '$Actual', expected '$Expected'." }
            }
        }
        $source = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'bin/scoop.ps1'), [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Invalid entry point: $parseErrors" }
        $definitions = @($ast.FindAll({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    ($node.Name -like '*ScoopOperationLock*' -or $node.Name -eq 'Get-ScoopOperationScope')
                }, $false) | ForEach-Object { $_.Extent.Text }) -join "`r`n"
        $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('scoop-operation-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $userRoot = (New-Item -ItemType Directory -Path (Join-Path $fixtureRoot user)).FullName
        $globalRoot = (New-Item -ItemType Directory -Path (Join-Path $fixtureRoot global)).FullName
        [IO.File]::WriteAllText((Join-Path $fixtureRoot helpers.ps1), $definitions)
        . (Join-Path $fixtureRoot helpers.ps1)
        $children = New-Object Collections.ArrayList
        $workerPath = Join-Path $fixtureRoot worker.ps1
        $worker = @'
param($Root, $SharedRoot, $Mode, $Timeout, $Signal, $Delay)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/helpers.ps1"
try {
    $lease = Enter-ScoopOperationLock $Root $SharedRoot -Global:($Mode -eq 'global') -Command install -TimeoutSeconds ([double]$Timeout)
    try {
        if ($Signal) { [IO.File]::WriteAllText($Signal, 'ready') }
        if ($Delay) { Start-Sleep -Milliseconds ([int]$Delay) }
        if ($Mode -eq 'nested') {
            & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath $Root $SharedRoot local 10 '' 0
            if ($LASTEXITCODE -eq 0) { throw 'Nested child acquired ancestor lease.' }
        }
        if ($Mode -eq 'throw') { throw 'fixture failure' }
    } finally { Exit-ScoopOperationLock $lease }
    exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
        [IO.File]::WriteAllText($workerPath, $worker)
        function Start-Fixture {
            param($Root = $userRoot, $Mode = 'local', $Timeout = 0, $Signal = '', $Delay = 0, $Entry = $workerPath)
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = (Get-Process -Id $PID).Path
            $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}" "{4}" "{5}" "{6}"' -f $Entry, $Root, $globalRoot, $Mode, $Timeout, $Signal, $Delay
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $child = [Diagnostics.Process]::Start($start)
            [void]$children.Add($child)
            $child
        }
        function Wait-Fixture($Child) {
            if (!$Child.WaitForExit(15000)) { throw 'Child exceeded fixture deadline.' }
            $Child.StandardOutput.ReadToEnd() | Out-Null
            $script:lockError = $Child.StandardError.ReadToEnd()
            $Child.ExitCode
        }
        function Wait-Signal($Signal) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (!(Test-Path -LiteralPath $Signal) -and $clock.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 25 }
            (Test-Path -LiteralPath $Signal) | Assert-LockResult Be $true
        }
    }
    AfterEach {
        foreach ($child in $children) {
            if (!$child.HasExited) { [void]$child.WaitForExit(15000) }
            if (!$child.HasExited) { throw 'Cannot clean up while a child is running.' }
            $child.Dispose()
        }
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (!$resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'scoop-operation-test-*') { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    It 'classifies mutations and read-only commands' {
        foreach ($command in 'install','update','uninstall','reset','cleanup','hold','unhold','download','create','custom-alias') {
            (Get-ScoopOperationScope $command @('app')).Mutating | Assert-LockResult Be $true
        }
        foreach ($command in 'help','list','search','status','--version','info','cat','prefix','which','depends','export','home') {
            (Get-ScoopOperationScope $command @()).Mutating | Assert-LockResult Be $false
        }
    }
    It 'classifies mutating subcommands and respects help and global terminators' {
        foreach ($pair in @(@('bucket','add'),@('bucket','rm'),@('alias','add'),@('cache','rm'),@('shim','alter'),@('config','rm'))) {
            (Get-ScoopOperationScope $pair[0] @($pair[1])).Mutating | Assert-LockResult Be $true
        }
        foreach ($pair in @(@('bucket','list'),@('bucket','known'),@('cache','show'),@('alias','list'),@('shim','info'),@('config','proxy'),@('install','--help'))) {
            (Get-ScoopOperationScope $pair[0] @($pair[1])).Mutating | Assert-LockResult Be $false
        }
        (Get-ScoopOperationScope config @('proxy','secret')).Mutating | Assert-LockResult Be $true
        (Get-ScoopOperationScope install @('app','-g')).Global | Assert-LockResult Be $true
        (Get-ScoopOperationScope update @('app','-gf')).Global | Assert-LockResult Be $true
        (Get-ScoopOperationScope cleanup @('-ag')).Global | Assert-LockResult Be $true
        (Get-ScoopOperationScope shim @('add','app','--','--global')).Global | Assert-LockResult Be $false
        (Get-ScoopOperationScope cleanup @('app','--dry-run','--global')).Mutating | Assert-LockResult Be $false
        (Get-ScoopOperationScope cleanup @('app','--','--dry-run')).Mutating | Assert-LockResult Be $true
    }
    It 'retains an outer reentrant same-process lease' {
        $outer = Enter-ScoopOperationLock $userRoot $globalRoot -Command install -TimeoutSeconds 0
        try {
            $inner = Enter-ScoopOperationLock $userRoot $globalRoot -Command update -TimeoutSeconds 0
            Exit-ScoopOperationLock $inner
            (Wait-Fixture (Start-Fixture)) | Assert-LockResult Be 1
            $script:lockError | Assert-LockResult Match 'PID|pid'
        } finally { Exit-ScoopOperationLock $outer }
        (Wait-Fixture (Start-Fixture)) | Assert-LockResult Be 0
    }
    It 'serializes independent mutators and records only safe owner metadata' {
        $signal = Join-Path $fixtureRoot ready
        $holder = Start-Fixture -Signal $signal -Delay 2800
        Wait-Signal $signal
        $owner = Get-Content -LiteralPath (Join-Path $userRoot '.scoop-operation.lock') -Raw | ConvertFrom-Json
        $owner.pid | Assert-LockResult Be $holder.Id
        $owner.command | Assert-LockResult Be install
        $owner.start_time | Assert-LockResult NotEmpty
        ($owner.PSObject.Properties.Name -contains 'arguments') | Assert-LockResult Be $false
        (Wait-Fixture (Start-Fixture -Timeout 0)) | Assert-LockResult Be 1
        $script:lockError | Assert-LockResult Match install
        (Wait-Fixture (Start-Fixture -Timeout 5)) | Assert-LockResult Be 0
        (Wait-Fixture $holder) | Assert-LockResult Be 0
    }
    It 'bounds waits without truncating another owners metadata' {
        $signal = Join-Path $fixtureRoot ready
        $holder = Start-Fixture -Signal $signal -Delay 2800
        Wait-Signal $signal
        $ownerPath = Join-Path $userRoot '.scoop-operation.lock'
        $before = Get-Content -LiteralPath $ownerPath -Raw
        $clock = [Diagnostics.Stopwatch]::StartNew()
        (Wait-Fixture (Start-Fixture -Timeout 0.25)) | Assert-LockResult Be 1
        $clock.Elapsed.TotalSeconds | Assert-LockResult LessThan 3
        (Get-Content -LiteralPath $ownerPath -Raw) | Assert-LockResult Be $before
        (Wait-Fixture $holder) | Assert-LockResult Be 0
    }
    It 'releases a lease after an exception' {
        (Wait-Fixture (Start-Fixture -Mode throw)) | Assert-LockResult Be 1
        (Wait-Fixture (Start-Fixture)) | Assert-LockResult Be 0
    }
    It 'fails fast for a child waiting on its own ancestor' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        (Wait-Fixture (Start-Fixture -Mode nested)) | Assert-LockResult Be 0
        $clock.Elapsed.TotalSeconds | Assert-LockResult LessThan 5
        $script:lockError | Assert-LockResult Match 'nested|ancestor'
    }
    It 'shares global locks across user roots but not independent local operations' {
        $otherRoot = (New-Item -ItemType Directory -Path (Join-Path $fixtureRoot other)).FullName
        $signal = Join-Path $fixtureRoot ready
        $holder = Start-Fixture -Mode global -Signal $signal -Delay 2800
        Wait-Signal $signal
        (Wait-Fixture (Start-Fixture -Root $otherRoot -Mode global)) | Assert-LockResult Be 1
        (Wait-Fixture (Start-Fixture -Root $otherRoot)) | Assert-LockResult Be 0
        (Wait-Fixture $holder) | Assert-LockResult Be 0
    }
    It 'refuses a same-process local-to-global upgrade before it can deadlock' {
        $outer = Enter-ScoopOperationLock $userRoot $globalRoot -Command install -TimeoutSeconds 0
        try {
            $rejected = $false
            try { Enter-ScoopOperationLock $userRoot $globalRoot -Global -Command install -TimeoutSeconds 0 } catch { $rejected = $true }
            $rejected | Assert-LockResult Be $true
            (Test-Path -LiteralPath (Join-Path $globalRoot '.scoop-operation.lock')) | Assert-LockResult Be $false
        } finally { Exit-ScoopOperationLock $outer }
    }
    It 'rejects invalid timeouts and missing or Git worktree roots' {
        $rejected = $false
        try { Enter-ScoopOperationLock $userRoot $globalRoot -Command install -TimeoutSeconds -1 } catch { $rejected = $true }
        $rejected | Assert-LockResult Be $true
        $rejected = $false
        try { Enter-ScoopOperationLock (Join-Path $fixtureRoot missing) $globalRoot -Command install -TimeoutSeconds 0 } catch { $rejected = $true }
        $rejected | Assert-LockResult Be $true
        New-Item -ItemType Directory -Path (Join-Path $userRoot '.git') | Out-Null
        $rejected = $false
        try { Enter-ScoopOperationLock $userRoot $globalRoot -Command install -TimeoutSeconds 0 } catch { $rejected = $true }
        $rejected | Assert-LockResult Be $true
    }
    It 'rejects junction roots and hard links without altering their target' {
        $junction = Join-Path $fixtureRoot redirect
        New-Item -ItemType Junction -Path $junction -Target $userRoot | Out-Null
        try {
            $rejected = $false
            try { Enter-ScoopOperationLock $junction $globalRoot -Command install -TimeoutSeconds 0 } catch { $rejected = $true }
            $rejected | Assert-LockResult Be $true
        }
        finally { [IO.Directory]::Delete($junction) }
        $target = Join-Path $fixtureRoot target.txt
        [IO.File]::WriteAllText($target, 'untouched')
        New-Item -ItemType HardLink -Path (Join-Path $userRoot '.scoop-operation.lock') -Target $target | Out-Null
        $rejected = $false
        try { Enter-ScoopOperationLock $userRoot $globalRoot -Command install -TimeoutSeconds 0 } catch { $rejected = $true }
        $rejected | Assert-LockResult Be $true
        [IO.File]::ReadAllText($target) | Assert-LockResult Be untouched
    }
    It 'preserves exit 7 and releases the lease through the actual dispatcher' {
        $dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.SwitchStatementAst] })[0].Extent.Text
        [IO.File]::WriteAllText((Join-Path $fixtureRoot fake-command.ps1), 'exit 7')
        $entryPath = Join-Path $fixtureRoot entry.ps1
        $entry = @'
param($Root, $SharedRoot)
$scoopdir = $Root
$globaldir = $SharedRoot
$subCommand = 'install'
$Args = @('install', 'fake')
function commands { 'install' }
function get_config { param($Name, $Default) $Default }
function exec { & "$PSScriptRoot/fake-command.ps1" }
'@
        [IO.File]::WriteAllText($entryPath, $entry + "`r`n" + $definitions + "`r`n" + $dispatch)
        (Wait-Fixture (Start-Fixture -Entry $entryPath)) | Assert-LockResult Be 7
        (Wait-Fixture (Start-Fixture)) | Assert-LockResult Be 0
    }
    It 'dispatches read-only commands immediately while the user lease is held' {
        $dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.SwitchStatementAst] })[0].Extent.Text
        $entryPath = Join-Path $fixtureRoot readonly.ps1
        $entry = @'
param($Root, $SharedRoot)
$scoopdir = $Root
$globaldir = $SharedRoot
$subCommand = 'list'
$Args = @('list')
function commands { 'list' }
function get_config { throw 'Read-only commands must not read lock configuration.' }
function exec { exit 7 }
'@
        [IO.File]::WriteAllText($entryPath, $entry + "`r`n" + $definitions + "`r`n" + $dispatch)
        $outer = Enter-ScoopOperationLock $userRoot $globalRoot -Command install -TimeoutSeconds 0
        try { (Wait-Fixture (Start-Fixture -Entry $entryPath)) | Assert-LockResult Be 7 }
        finally { Exit-ScoopOperationLock $outer }
    }
    It 'dispatches cleanup preview and help without lock files or even an existing root' {
        $dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.SwitchStatementAst] })[0].Extent.Text
        foreach ($option in '--dry-run', '--help') {
            $entryPath = Join-Path $fixtureRoot readonly-cleanup.ps1
            $entry = @'
param($Root, $SharedRoot)
$scoopdir = $Root
$globaldir = $SharedRoot
$subCommand = 'cleanup'
$Args = @('cleanup', 'OPTION', '--global')
function commands { 'cleanup' }
function get_config { throw 'Read-only cleanup must not read lock configuration.' }
function exec { exit 7 }
'@
            $entry = $entry.Replace('OPTION', $option)
            [IO.File]::WriteAllText($entryPath, $entry + "`r`n" + $definitions + "`r`n" + $dispatch)
            $missing = Join-Path $fixtureRoot missing
            (Wait-Fixture (Start-Fixture -Entry $entryPath -Root $missing)) | Assert-LockResult Be 7
            (Test-Path -LiteralPath $missing) | Assert-LockResult Be $false
            (Test-Path -LiteralPath (Join-Path $globalRoot '.scoop-operation.lock')) | Assert-LockResult Be $false
        }
    }
    It 'imports local-only files without a global root and scopes global entries before locking' {
        $dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.SwitchStatementAst] })[0].Extent.Text
        $entryPath = Join-Path $fixtureRoot import-entry.ps1
        $entry = @'
param($Root, $SharedRoot)
$scoopdir = $Root
$globaldir = $SharedRoot
$subCommand = 'import'
$Args = @('import', "$PSScriptRoot/scoopfile.json")
function commands { 'import' }
function get_config { param($Name, $Default) 0 }
function exec { exit 7 }
'@
        [IO.File]::WriteAllText($entryPath, $entry + "`r`n" + $definitions + "`r`n" + $dispatch)
        $inputPath = Join-Path $fixtureRoot scoopfile.json
        [IO.File]::WriteAllText($inputPath, '{"apps":[{"Name":"fake","Info":"64bit"}]}')
        $oldGlobal = $globalRoot
        $globalRoot = Join-Path $fixtureRoot missing-global
        (Wait-Fixture (Start-Fixture -Entry $entryPath)) | Assert-LockResult Be 7
        (Test-Path -LiteralPath $globalRoot) | Assert-LockResult Be $false
        $globalRoot = $oldGlobal
        [IO.File]::WriteAllText($inputPath, '{"apps":[{"Name":"fake","Info":"Global install, 64bit"}]}')
        $otherUser = (New-Item -ItemType Directory -Path (Join-Path $fixtureRoot other-user)).FullName
        $holder = Enter-ScoopOperationLock $otherUser $globalRoot -Global -Command update -TimeoutSeconds 0
        try {
            (Wait-Fixture (Start-Fixture -Entry $entryPath)) | Assert-LockResult Be 1
            $script:lockError | Assert-LockResult Match 'update|ancestor'
        } finally { Exit-ScoopOperationLock $holder }
        (Wait-Fixture (Start-Fixture -Entry $entryPath)) | Assert-LockResult Be 7
        (Test-Path -LiteralPath (Join-Path $globalRoot '.scoop-operation.lock')) | Assert-LockResult Be $true
        [IO.File]::WriteAllText($inputPath, '{"apps":[]}')
        $scope = Get-ScoopOperationScope import @($inputPath)
        try {
            $scope.Global | Assert-LockResult Be $false
            $scope.Mutating | Assert-LockResult Be $true
            $rejected = $false
            try { [IO.File]::WriteAllText($inputPath, 'changed during dispatch') } catch { $rejected = $true }
            $rejected | Assert-LockResult Be $true
        } finally { $scope.ImportStream.Dispose() }
        [IO.File]::WriteAllText($inputPath, '{"apps":[]}')
    }
    It 'rejects unreadable invalid and remote imports without acquiring locks' {
        foreach ($inputPath in @((Join-Path $fixtureRoot missing.json), $fixtureRoot, 'https://example.invalid/scoopfile.json')) {
            $rejected = $false
            try { Get-ScoopOperationScope import @($inputPath) } catch { $rejected = $true }
            $rejected | Assert-LockResult Be $true
        }
        $invalid = Join-Path $fixtureRoot invalid.json
        [IO.File]::WriteAllText($invalid, '{invalid')
        $rejected = $false
        try { Get-ScoopOperationScope import @($invalid) } catch { $rejected = $true }
        $rejected | Assert-LockResult Be $true
        (Test-Path -LiteralPath (Join-Path $userRoot '.scoop-operation.lock')) | Assert-LockResult Be $false
    }
}
