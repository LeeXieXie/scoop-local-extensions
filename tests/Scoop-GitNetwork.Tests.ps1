Describe 'Bounded isolated Git network commands' -Tag 'Scoop' {
    BeforeEach {
        function Assert-NetworkResult {
            param([Parameter(ValueFromPipeline = $true)]$Actual, [Parameter(Position = 0)][string]$Assertion, [Parameter(Position = 1)]$Expected)
            process {
                $valid = switch ($Assertion) {
                    Be { $Actual -eq $Expected }
                    Match { $Actual -match $Expected }
                    NotMatch { $Actual -notmatch $Expected }
                    BeLessThan { $Actual -lt $Expected }
                    BeGreaterThan { $Actual -gt $Expected }
                    Throw { $thrown = $false; try { & $Actual } catch { $thrown = $true }; $thrown }
                    default { throw "Unknown fixture assertion: $Assertion" }
                }
                if (!$valid) { throw "Assertion $Assertion failed: actual '$Actual', expected '$Expected'." }
            }
        }
        $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
        $parseErrors = $null
        $coreAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/core.ps1'), [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count) { throw 'Cannot parse core.ps1.' }
        $definitions = $coreAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -in @('Invoke-Git', 'Test-GitNetworkCommand', 'ConvertTo-GitCommandLine', 'Stop-GitProcessTree', 'Initialize-GitNetworkJob')
            }, $false).Extent.Text -join "`n"
        $fake = Join-Path $TestDrive 'fake git.exe'
        if (!(Test-Path -LiteralPath $fake)) {
            $helperSource = Join-Path $TestDrive 'FakeGit.cs'
            @'
using System;
using System.Diagnostics;
using System.Text;
using System.Threading;
class FakeGit {
    static int Main(string[] arguments) {
        foreach (string argument in arguments) {
            if (argument.StartsWith("--child-file=")) {
                var start = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--sleep=4000");
                start.UseShellExecute = false; start.CreateNoWindow = true;
                var child = Process.Start(start);
                System.IO.File.WriteAllText(argument.Substring(13), child.Id.ToString());
            }
        }
        foreach (string argument in arguments) {
            Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(argument)));
            if (argument.StartsWith("--sleep=")) Thread.Sleep(Int32.Parse(argument.Substring(8)));
            if (argument == "--stderr") Console.Error.WriteLine("fake stderr");
            if (argument == "--cwd") Console.WriteLine("CWD|" + System.IO.Directory.GetCurrentDirectory());
            if (argument == "--orphan") return 0;
            if (argument == "--flood") { Console.Out.WriteLine(new string('x', 100000)); Console.Error.WriteLine(new string('y', 100000)); }
        }
        Console.WriteLine("PROXY|" + Environment.GetEnvironmentVariable("HTTPS_PROXY"));
        foreach (string argument in arguments) if (argument.StartsWith("--exit=")) return Int32.Parse(argument.Substring(7));
        return 0;
    }
}

'@ | Set-Content -LiteralPath $helperSource -Encoding UTF8
            & "$env:WINDIR/Microsoft.NET/Framework64/v4.0.30319/csc.exe" /nologo /target:exe "/out:$fake" $helperSource
            if ($LASTEXITCODE) { throw 'Cannot compile isolated Git fixture.' }
        }
        $fixture = New-Module -ScriptBlock {
            function Invoke-Fixture {
                param($Definitions, $Executable, $GitArguments, $Timeout = 0.2, $Proxy, $Path)
                $script:timeout = $Timeout
                $script:proxy = $Proxy
                $script:executable = $Executable
                function get_config { param($Name, $Default)
                    if ($Name -eq 'PROXY') { return $script:proxy }
                    if ($Name -eq 'git_network_timeout') { $script:timeoutDefault = $Default; if ($null -eq $script:timeout) { return $Default }; return $script:timeout }
                    throw "Unexpected setting: $Name"
                }
                function Get-HelperPath { param($Helper) $script:executable }
                . ([scriptblock]::Create($Definitions))
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $parameters = @{ ArgumentList = $GitArguments; WarningAction = 'SilentlyContinue' }
                if ($Path) { $parameters.Path = $Path }
                $output = @(Invoke-Git @parameters 2>&1)
                [pscustomobject]@{ Output = $output; ExitCode = $global:LASTEXITCODE; Elapsed = $watch.Elapsed.TotalSeconds; TimedOut = $script:GitNetworkTimedOut; TimeoutDefault = $script:timeoutDefault }
            }
            Export-ModuleMember -Function Invoke-Fixture
        }
    }
    AfterEach { Remove-Module $fixture -ErrorAction SilentlyContinue }
    It 'bounds remote wall time and identifies a timeout' {
        $result = & $fixture { param($Definitions, $Executable) Invoke-Fixture $Definitions $Executable @('pull', '--sleep=4000', 'secret-token') } $definitions $fake
        $result.ExitCode | Assert-NetworkResult Be 124
        $result.TimedOut | Assert-NetworkResult Be $true
        $result.Elapsed | Assert-NetworkResult BeLessThan 3.5
    }
    It 'does not classify a local grep value as a network command' {
        $result = & $fixture { param($Definitions, $Executable) Invoke-Fixture $Definitions $Executable @('log', '--grep=pull', '--sleep=350') } $definitions $fake
        $result.ExitCode | Assert-NetworkResult Be 0
        $result.Elapsed | Assert-NetworkResult BeGreaterThan 0.3
    }
    It 'preserves local native failures without starting the network wrapper' {
        $result = & $fixture { param($Definitions, $Executable) Invoke-Fixture $Definitions $Executable @('rev-parse', '--exit=7') } $definitions $fake
        $result.ExitCode | Assert-NetworkResult Be 7
        $result.TimedOut | Assert-NetworkResult Be $false
        $result.TimeoutDefault | Assert-NetworkResult Be $null
    }
    It 'classifies only remote subcommands after Git global options' {
        foreach ($operation in @('clone', 'fetch', 'pull', 'ls-remote')) {
            $result = & $fixture { param($Definitions, $Executable, $Operation) Invoke-Fixture $Definitions $Executable @('-c', 'x=pull', $Operation, '--sleep=4000') } $definitions $fake $operation
            $result.ExitCode | Assert-NetworkResult Be 124
        }
    }
    It 'preserves argv including empty strings quotes and trailing backslashes' {
        $values = @('ls-remote', '', 'path with spaces\', 'one"two', 'a\\"b', 'last\\')
        $result = & $fixture { param($Definitions, $Executable, $Values) Invoke-Fixture $Definitions $Executable $Values -Timeout 5 -Path 'C:\path with spaces\' } $definitions $fake $values
        $expected = @('-C', 'C:\path with spaces\') + $values
        $decoded = @($result.Output | Where-Object { $_ -notlike 'PROXY|*' } | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
        ($decoded -join '|') | Assert-NetworkResult Be ($expected -join '|')
        $result.ExitCode | Assert-NetworkResult Be 0
    }
    It 'keeps proxy changes in the child and propagates native failure status' {
        $before = $env:HTTPS_PROXY
        $result = & $fixture { param($Definitions, $Executable) Invoke-Fixture $Definitions $Executable @('fetch', '--exit=7') -Timeout 5 -Proxy 'currentuser@proxy.invalid:8888' } $definitions $fake
        $result.ExitCode | Assert-NetworkResult Be 7
        ($result.Output -join '|') | Assert-NetworkResult Match 'PROXY\|:@proxy.invalid:8888'
        $env:HTTPS_PROXY | Assert-NetworkResult Be $before
    }
    It 'allows explicit zero to disable timeout and defaults unset values to 120 seconds' {
        foreach ($timeout in @(0, $null)) {
            $result = & $fixture { param($Definitions, $Executable, $Timeout) Invoke-Fixture $Definitions $Executable @('pull', '--sleep=350') -Timeout $Timeout } $definitions $fake $timeout
            $result.ExitCode | Assert-NetworkResult Be 0
            $result.TimeoutDefault | Assert-NetworkResult Be 120
            $result.Elapsed | Assert-NetworkResult BeGreaterThan 0.3
        }
    }
    It 'drains stdout and stderr concurrently and preserves stderr records' {
        $result = & $fixture { param($Definitions, $Executable) Invoke-Fixture $Definitions $Executable @('pull', '--flood', '--stderr') -Timeout 5 } $definitions $fake
        $result.ExitCode | Assert-NetworkResult Be 0
        ($result.Output -join "`n") | Assert-NetworkResult Match 'fake stderr'
        $result.Elapsed | Assert-NetworkResult BeLessThan 4
    }
    It 'starts the remote child in the PowerShell filesystem location' {
        Push-Location $TestDrive
        try {
            $result = & $fixture { param($Definitions, $Executable) Invoke-Fixture $Definitions $Executable @('ls-remote', '--cwd') -Timeout 5 } $definitions $fake
            ($result.Output -join '|') | Assert-NetworkResult Match ([regex]::Escape("CWD|$TestDrive"))
            $result.ExitCode | Assert-NetworkResult Be 0
        } finally { Pop-Location }
    }
    It 'terminates only its timed out child tree and leaves an unrelated process alive' {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $fake
        $start.Arguments = '--sleep=4000'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $unrelated = [Diagnostics.Process]::Start($start)
        try {
            $childFile = Join-Path $TestDrive 'child.pid'
            $result = & $fixture { param($Definitions, $Executable, $ChildFile) Invoke-Fixture $Definitions $Executable @('pull', "--child-file=$ChildFile", '--sleep=4000') -Timeout 0.4 } $definitions $fake $childFile
            $result.ExitCode | Assert-NetworkResult Be 124
            $childId = [int](Get-Content -LiteralPath $childFile)
            $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
            ($null -eq $child -or $child.HasExited) | Assert-NetworkResult Be $true
            $unrelated.HasExited | Assert-NetworkResult Be $false
        } finally {
            if (!$unrelated.HasExited) { $unrelated.Kill() }
            $unrelated.Dispose()
        }
    }
    It 'terminates descendants retaining pipes after the original process exits' {
        $childFile = Join-Path $TestDrive 'orphan.pid'
        $result = & $fixture { param($Definitions, $Executable, $ChildFile) Invoke-Fixture $Definitions $Executable @('pull', "--child-file=$ChildFile", '--orphan') -Timeout 0.4 } $definitions $fake $childFile
        $result.ExitCode | Assert-NetworkResult Be 124
        $childId = [int](Get-Content -LiteralPath $childFile)
        $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
        ($null -eq $child -or $child.HasExited) | Assert-NetworkResult Be $true
    }
    It 'keeps the child suspended when job assignment fails before any child code executes' {
        & $fixture { param($Definitions) . ([scriptblock]::Create($Definitions)); Initialize-GitNetworkJob } $definitions
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $fake
        $childFile = Join-Path $TestDrive 'never-started.pid'
        $start.Arguments = '"--child-file=' + $childFile + '"'
        $start.WorkingDirectory = $TestDrive
        $failure = $null
        try { $null = [ScoopGitNetworkJob]::Start($start, [IntPtr]::Zero) } catch { $failure = $_.Exception.InnerException }
        ($failure -is [ComponentModel.Win32Exception]) | Assert-NetworkResult Be $true
        $failure.NativeErrorCode | Assert-NetworkResult Be 6
        Start-Sleep -Milliseconds 200
        (Test-Path -LiteralPath $childFile) | Assert-NetworkResult Be $false
        ([ScoopGitNetworkJob].GetMethods().Name -contains 'Start') | Assert-NetworkResult Be $true
    }
}

Describe 'Bucket synchronization keeps independent failures truthful' -Tag 'Scoop' {
    BeforeEach {
        function Assert-NetworkResult {
            param([Parameter(ValueFromPipeline = $true)]$Actual, [Parameter(Position = 0)][string]$Assertion, [Parameter(Position = 1)]$Expected)
            process {
                $valid = switch ($Assertion) {
                    Be { $Actual -eq $Expected }
                    Match { $Actual -match $Expected }
                    NotMatch { $Actual -notmatch $Expected }
                    BeLessThan { $Actual -lt $Expected }
                    BeGreaterThan { $Actual -gt $Expected }
                    Throw { $thrown = $false; try { & $Actual } catch { $thrown = $true }; $thrown }
                    default { throw "Unknown fixture assertion: $Assertion" }
                }
                if (!$valid) { throw "Assertion $Assertion failed: actual '$Actual', expected '$Expected'." }
            }
        }
        $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
        $updateAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'libexec/scoop-update.ps1'), [ref]$null, [ref]$null)
        $syncSource = $updateAst.Find({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sync-Bucket'
            }, $false).Extent.Text
        $syncSource = $syncSource.Replace('. "$using:PSScriptRoot\..\lib\core.ps1"', '. $using:fixtureCore').Replace('. "$using:PSScriptRoot\..\lib\buckets.ps1"', '')
        $fixtureCore = Join-Path $TestDrive 'core.ps1'
        $fixtureRoot = $TestDrive
        @'
function Find-BucketDirectory { param($Name, [switch]$Root) Join-Path $PSScriptRoot $Name }
function get_config { param($Name) $false }
function Invoke-Git {
    param($Path, $ArgumentList)
    $name = Split-Path -Leaf $Path
    Add-Content -LiteralPath (Join-Path $Path 'events') -Value $ArgumentList[0]
    $script:GitNetworkTimedOut = $false
    $global:LASTEXITCODE = 0
    if ($ArgumentList[0] -eq 'rev-parse') { return 'previous' }
    if ($ArgumentList[0] -eq 'pull') {
        if ($name -eq 'bad') { $global:LASTEXITCODE = 7 }
        if ($name -eq 'timeout') { $global:LASTEXITCODE = 124; $script:GitNetworkTimedOut = $true }
        if ($name -eq 'throws') { throw 'credential-secret must not be copied into summary' }
    }
}
function Invoke-GitLog { param($Path) Add-Content -LiteralPath (Join-Path $Path 'events') -Value 'log' }
'@ | Set-Content -LiteralPath $fixtureCore -Encoding UTF8
        foreach ($name in @('main', 'bad', 'timeout', 'throws', 'healthy')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "$name/.git") -Force
        }
        $fixture = New-Module -ScriptBlock {
            function Invoke-Fixture {
                param($Source, $FixtureCore, $FixtureRoot, $Names)
                . $FixtureCore
                $script:names = $Names
                function Get-LocalBucket { $script:names }
                function rm_bucket { return 7 }
                function info { param($Message) }
                function warn { param($Message) Write-Warning $Message }
                . ([scriptblock]::Create($Source))
                $output = @(Sync-Bucket -Log 3>&1)
                [pscustomobject]@{ Output = $output; ExitCode = $global:LASTEXITCODE }
            }
            Export-ModuleMember -Function Invoke-Fixture
        }
    }
    AfterEach { Remove-Module $fixture -ErrorAction SilentlyContinue }
    It 'continues healthy buckets after a nonzero exit and reports a failing summary' {
        $result = & $fixture { param($Source, $Core, $Root) Invoke-Fixture $Source $Core $Root @('bad', 'healthy') } $syncSource $fixtureCore $fixtureRoot
        $result.ExitCode | Assert-NetworkResult Be 1
        ($result.Output -join '|') | Assert-NetworkResult Match 'bad.*exit.*7'
        (Get-Content (Join-Path $fixtureRoot 'healthy/events') -Raw) | Assert-NetworkResult Match 'pull'
        (Get-Content (Join-Path $fixtureRoot 'healthy/events') -Raw) | Assert-NetworkResult Match 'log'
        (Get-Content (Join-Path $fixtureRoot 'bad/events') -Raw) | Assert-NetworkResult NotMatch 'log'
    }
    It 'distinguishes timeout and exceptions without exposing exception credentials' {
        $result = & $fixture { param($Source, $Core, $Root) Invoke-Fixture $Source $Core $Root @('timeout', 'throws', 'healthy') } $syncSource $fixtureCore $fixtureRoot
        $result.ExitCode | Assert-NetworkResult Be 1
        ($result.Output -join '|') | Assert-NetworkResult Match 'timeout.*timed out'
        ($result.Output -join '|') | Assert-NetworkResult Match 'throws.*failed'
        ($result.Output -join '|') | Assert-NetworkResult NotMatch 'credential-secret'
        (Get-Content (Join-Path $fixtureRoot 'healthy/events') -Raw) | Assert-NetworkResult Match 'pull'
    }
    It 'sets zero on a fully successful sync even after a prior failure' {
        $global:LASTEXITCODE = 7
        $result = & $fixture { param($Source, $Core, $Root) Invoke-Fixture $Source $Core $Root @('healthy') } $syncSource $fixtureCore $fixtureRoot
        $result.ExitCode | Assert-NetworkResult Be 0
    }
    It 'continues healthy buckets when main repository conversion fails' {
        Remove-Item -LiteralPath (Join-Path $fixtureRoot 'main/.git')
        $result = & $fixture { param($Source, $Core, $Root) Invoke-Fixture $Source $Core $Root @('main', 'healthy') } $syncSource $fixtureCore $fixtureRoot
        $result.ExitCode | Assert-NetworkResult Be 1
        ($result.Output -join '|') | Assert-NetworkResult Match 'main.*conversion failed'
        (Get-Content (Join-Path $fixtureRoot 'healthy/events') -Raw) | Assert-NetworkResult Match 'pull'
    }
    It 'guards both CLI success paths and app updates after core or bucket sync failure' {
        $entry = $updateAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if (-not ($apps -or $all))') }
        $entry.Extent.Text | Assert-NetworkResult Match 'Sync-Scoop[^\r\n]*\r?\n\s*if \(\$LASTEXITCODE -ne 0\) \{ exit 1 \}'
        $entry.Extent.Text | Assert-NetworkResult Match 'Sync-Bucket[^\r\n]*\r?\n\s*if \(\$LASTEXITCODE -ne 0\) \{ exit 1 \}'
        ([regex]::Matches($entry.Extent.Text, 'if \(\$LASTEXITCODE -ne 0\) \{ exit 1 \}')).Count | Assert-NetworkResult Be 4
    }
    It 'executes both CLI branches without success timestamps or app work after either sync failure' {
        $entry = $updateAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if (-not ($apps -or $all))') }
        $entrySource = $entry.Extent.Text.Replace('exit 1', "throw 'fixture-stop'")
        foreach ($appMode in @($false, $true)) {
            foreach ($failCore in @($false, $true)) {
                $entryFixture = New-Module -ScriptBlock {
                    function Invoke-Entry {
                        param($Source, $AppMode, $FailCore)
                        $script:events = New-Object 'System.Collections.Generic.List[string]'
                        $script:failCore = $FailCore
                        $apps = if ($AppMode) { @('sample') } else { @() }
                        $global = $false
                        $use_cache = $true
                        function Sync-Scoop { $script:events.Add('core'); $global:LASTEXITCODE = [int]$script:failCore }
                        function Sync-Bucket { $script:events.Add('buckets'); $global:LASTEXITCODE = 1 }
                        function set_config { $script:events.Add('timestamp') }
                        function success { $script:events.Add('success') }
                        function is_scoop_outdated { $true }
                        function Confirm-InstallationStatus { $script:events.Add('apps'); throw 'fixture-stop' }
                        try { . ([scriptblock]::Create($Source)) } catch { if ($_.Exception.Message -ne 'fixture-stop') { throw } }
                        $script:events -join ','
                    }
                    Export-ModuleMember -Function Invoke-Entry
                }
                try {
                    $events = & $entryFixture { param($Source, $AppMode, $FailCore) Invoke-Entry $Source $AppMode $FailCore } $entrySource $appMode $failCore
                    $expected = if ($failCore) { 'core' } else { 'core,buckets' }
                    $events | Assert-NetworkResult Be $expected
                } finally { Remove-Module $entryFixture }
            }
        }
    }
    It 'does not write LAST_UPDATE while checking an invalid previous timestamp' {
        $coreAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/core.ps1'), [ref]$null, [ref]$null)
        $definition = $coreAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'is_scoop_outdated'}, $false)
        $definition.Extent.Text | Assert-NetworkResult NotMatch 'set_config'
    }
}
