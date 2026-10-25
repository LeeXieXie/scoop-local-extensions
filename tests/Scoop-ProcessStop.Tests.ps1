Describe 'Opt-in target-app process stopping' {
    BeforeEach {
        function Invoke-ProcessStopFixture {
            param([bool]$Kill, [bool]$Ignore, [bool]$Remaining = $false, [bool]$Running = $true, [bool]$BracketRoot = $false)
            $sourceRoot = $env:SCOOP_LOCAL_EXTENSIONS_SOURCE
            if (!$sourceRoot) { throw 'SCOOP_LOCAL_EXTENSIONS_SOURCE must identify the patched Scoop source tree.' }
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'lib/install.ps1'), [ref]$tokens, [ref]$errors)
            if ($errors.Count) { throw 'Unable to parse the installed process guard.' }
            $definition = $ast.Find({ param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'test_running_process'
                }, $false)
            if (!$definition) { throw 'The process guard was not found.' }
            $fixture = New-Module -ScriptBlock {
                function Invoke-Fixture {
                    param($Source, $Kill, $Ignore, $Remaining, $Running, $BracketRoot)
                    $script:kill = $Kill
                    $script:ignore = $Ignore
                    $script:remaining = $Remaining
                    $script:running = $Running
                    $script:root = if ($BracketRoot) { 'C:\fixture[ab]\apps\sample' } else { 'C:\fixture\apps\sample' }
                    $script:otherRoot = if ($BracketRoot) { 'C:\fixturea\apps\sample' } else { 'C:\fixture\apps\sample-other' }
                    $script:queries = 0
                    $script:stopped = New-Object 'System.Collections.Generic.List[int]'
                    $script:forceUsed = $false
                    function appdir { $script:root }
                    function Convert-Path { process { $_ } }
                    function get_config {
                        param($Name)
                        if ($Name -eq 'KILL_RUNNING_PROCESSES') { return $script:kill }
                        if ($Name -eq 'IGNORE_RUNNING_PROCESSES') { return $script:ignore }
                        throw 'Unexpected configuration lookup.'
                    }
                    function Get-Process {
                        $script:queries++
                        [pscustomobject]@{ Id = 2; Path = $script:otherRoot + '\other.exe' }
                        if ($script:running -and ($script:queries -eq 1 -or $script:remaining)) {
                            [pscustomobject]@{ Id = 1; Path = $script:root + '\current\app.exe' }
                        }
                    }
                    function Stop-Process {
                        [CmdletBinding()]
                        param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force)
                        process {
                            $script:stopped.Add($InputObject.Id)
                            $script:forceUsed = [bool]$Force
                        }
                    }
                    function Wait-Process {
                        [CmdletBinding()]
                        param([Parameter(ValueFromPipeline)]$InputObject, [int]$Timeout)
                        process {}
                    }
                    function Write-Host {}
                    function warn {}
                    function error {}
                    . ([scriptblock]::Create($Source))
                    $blocked = test_running_process 'sample' $false
                    [pscustomobject]@{ Blocked = $blocked; Stopped = $script:stopped.ToArray(); Forced = $script:forceUsed }
                }
            }
            try {
                & $fixture { param($Source, $Kill, $Ignore, $Remaining, $Running, $BracketRoot)
                    Invoke-Fixture $Source $Kill $Ignore $Remaining $Running $BracketRoot
                } $definition.Extent.Text $Kill $Ignore $Remaining $Running $BracketRoot
            } finally { Remove-Module $fixture -ErrorAction SilentlyContinue }
        }
    }

    It 'force-stops only target-app processes when explicitly enabled' {
        $result = Invoke-ProcessStopFixture -Kill $true -Ignore $false
        if ($result.Blocked -or !$result.Forced -or ($result.Stopped -join ',') -ne '1') {
            throw 'The opt-in stop must affect only the target application.'
        }
    }

    It 'retains the block when a target process remains after stopping' {
        $result = Invoke-ProcessStopFixture -Kill $true -Ignore $false -Remaining $true
        if (!$result.Blocked -or ($result.Stopped -join ',') -ne '1') { throw 'Remaining processes must block the operation.' }
    }

    It 'gives the explicit stop option precedence over the ignore option' {
        $result = Invoke-ProcessStopFixture -Kill $true -Ignore $true
        if ($result.Blocked -or ($result.Stopped -join ',') -ne '1') { throw 'The explicit stop option must take precedence.' }
    }

    It 'does not stop processes when both options are disabled' {
        $result = Invoke-ProcessStopFixture -Kill $false -Ignore $false
        if (!$result.Blocked -or $result.Stopped.Count) { throw 'The default guard must block without terminating processes.' }
    }

    It 'preserves ignore behavior without terminating processes' {
        $result = Invoke-ProcessStopFixture -Kill $false -Ignore $true
        if ($result.Blocked -or $result.Stopped.Count) { throw 'The ignore option must not terminate processes.' }
    }

    It 'does not affect unrelated processes when the target is not running' {
        $result = Invoke-ProcessStopFixture -Kill $true -Ignore $false -Running $false
        if ($result.Blocked -or $result.Stopped.Count) { throw 'Unrelated applications must remain untouched.' }
    }

    It 'matches bracket-containing application roots literally in both process scans' {
        $result = Invoke-ProcessStopFixture -Kill $true -Ignore $false -BracketRoot $true
        if ($result.Blocked -or ($result.Stopped -join ',') -ne '1') {
            throw 'Wildcard characters in a path must not select a different application.'
        }
    }
}
