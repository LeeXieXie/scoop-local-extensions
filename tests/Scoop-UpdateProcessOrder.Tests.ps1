Describe 'Update process checks follow successful download preparation' -Tag 'Scoop' {
    BeforeEach {
        function Invoke-UpdateOrderFixture {
            param([string]$Backend, [string]$Failure, [bool]$Blocked = $false, [bool]$Current = $false, [bool]$CheckHash = $true)
            $sourceRoot = if ($env:SCOOP_LOCAL_EXTENSIONS_SOURCE) { $env:SCOOP_LOCAL_EXTENSIONS_SOURCE } else { Join-Path $PSScriptRoot '..' }
            $path = Join-Path $sourceRoot 'libexec/scoop-update.ps1'
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            if ($errors.Count) { throw "Cannot parse update command: $errors" }
            $definition = $ast.Find({ param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'update'
                }, $false)
            if (!$definition) { throw 'The update function was not found.' }
            $fixture = New-Module -ScriptBlock {
                function script:url { $script:urls }
                function Invoke-Fixture {
                    param($Source, $Backend, $Failure, $Blocked, $Current, $CheckHash)
                    $script:events = New-Object 'System.Collections.Generic.List[string]'
                    $script:urls = @('https://example.invalid/first.zip', 'https://example.invalid/second.zip')
                    $script:backend = $Backend
                    $script:failure = $Failure
                    $script:blocked = $Blocked
                    $script:current = $Current
                    $script:installHash = $null
                    function Select-CurrentVersion { '1.0' }
                    function installed_manifest { @{ version = '1.0' } }
                    function install_info { @{ architecture = '64bit'; bucket = 'main' } }
                    function Format-ArchitectureString { '64bit' }
                    function manifest { @{ version = $(if ($script:current) { '1.0' } else { '2.0' }) } }
                    function Write-Host {}
                    function warn {}
                    function error {}
                    function Test-Aria2Enabled { $script:backend -eq 'aria2' }
                    function Invoke-CachedDownload {
                        param($App, $Version, $Url)
                        $script:events.Add("download:$Url")
                        if ($script:failure -eq 'download' -and $Url -eq $script:urls[1]) { throw 'download failed' }
                    }
                    function hash_for_url { 'expected-hash' }
                    function cache_path { param($App, $Version, $Url) $Url }
                    function show_app { 'fixture-app' }
                    function check_hash {
                        param($Source)
                        $script:events.Add("hash:$Source")
                        @(!($script:failure -eq 'hash' -and $Source -eq $script:urls[1]), 'hash failed')
                    }
                    function Invoke-CachedAria2Download {
                        param($App, $Version, $Manifest, $Architecture, $CacheDir, $Cookie, $UseCache, $CheckHash)
                        foreach ($downloadUrl in $script:urls) { Invoke-CachedDownload $App $Version $downloadUrl }
                        if ($CheckHash) {
                            foreach ($downloadUrl in $script:urls) {
                                $valid, $message = check_hash $downloadUrl
                                if (!$valid) { throw $message }
                            }
                        }
                    }
                    function Test-Path { $false }
                    function new_issue_msg { 'hash failed' }
                    function abort { param($Message) throw $Message }
                    function test_running_process { $script:events.Add('process'); $script:blocked }
                    function versiondir { 'fixture-version-directory' }
                    function persistdir { 'fixture-persist-directory' }
                    function Invoke-HookScript { param($HookType, $Manifest, $Arch) $script:events.Add($HookType) }
                    function Invoke-Installer {
                        param($Path, $Manifest, $ProcessorArchitecture, [switch]$Global, [switch]$Uninstall)
                        $script:events.Add('uninstall')
                    }
                    function rm_shims {}
                    function unlink_current { 'fixture-reference-directory' }
                    function uninstall_psmodule {}
                    function env_rm_path {}
                    function env_rm {}
                    function install_app {
                        param($App, $Architecture, $Global, $Suggested, $UseCache, $CheckHash)
                        $script:events.Add('install')
                        $script:installHash = $CheckHash
                    }
                    . ([scriptblock]::Create($Source))
                    $failureMessage = $null
                    try { update 'fixture-app' $false $false $true $true $null $true $CheckHash }
                    catch { $failureMessage = $_.Exception.Message }
                    [pscustomobject]@{ Events = $script:events.ToArray(); Error = $failureMessage; InstallHash = $script:installHash }
                }
            }
            try {
                & $fixture { param($Source, $Backend, $Failure, $Blocked, $Current, $CheckHash)
                    Invoke-Fixture $Source $Backend $Failure $Blocked $Current $CheckHash
                } $definition.Extent.Text $Backend $Failure $Blocked $Current $CheckHash
            } finally { Remove-Module $fixture -ErrorAction SilentlyContinue }
        }

        function Assert-UpdateOrder {
            param($Actual, [string[]]$Expected, $ExpectedError = $null)
            if (($Actual.Events -join ',') -cne ($Expected -join ',')) {
                throw "Expected [$($Expected -join ',')], got [$($Actual.Events -join ',')]. Error: $($Actual.Error)"
            }
            if ($Actual.Error -ne $ExpectedError) { throw "Expected error '$ExpectedError', got '$($Actual.Error)'." }
        }

    }
    $backends = @(@{ Backend = 'builtin' }, @{ Backend = 'aria2' })
    It 'checks processes after every download and hash, before uninstalling (<Backend>)' -TestCases $backends {
        param($Backend)
        $result = Invoke-UpdateOrderFixture -Backend $Backend
        $downloads = @('download:https://example.invalid/first.zip', 'download:https://example.invalid/second.zip')
        $hashes = @('hash:https://example.invalid/first.zip', 'hash:https://example.invalid/second.zip')
        $prepared = if ($Backend -eq 'aria2') { $downloads + $hashes } else { @($downloads[0], $hashes[0], $downloads[1], $hashes[1]) }
        Assert-UpdateOrder $result ($prepared + @('process', 'pre_uninstall', 'uninstall', 'post_uninstall', 'install'))
        if ($result.InstallHash -ne $false) { throw 'Installation must not repeat hash validation.' }
    }
    It 'never checks processes or uninstalls after a failed download (<Backend>)' -TestCases $backends {
        param($Backend)
        $result = Invoke-UpdateOrderFixture -Backend $Backend -Failure download
        $expected = @('download:https://example.invalid/first.zip')
        if ($Backend -eq 'builtin') { $expected += 'hash:https://example.invalid/first.zip' }
        Assert-UpdateOrder $result ($expected + 'download:https://example.invalid/second.zip') 'download failed'
    }
    It 'never checks processes or uninstalls after a failed hash (<Backend>)' -TestCases $backends {
        param($Backend)
        $result = Invoke-UpdateOrderFixture -Backend $Backend -Failure hash
        $downloads = @('download:https://example.invalid/first.zip', 'download:https://example.invalid/second.zip')
        $hashes = @('hash:https://example.invalid/first.zip', 'hash:https://example.invalid/second.zip')
        $expected = if ($Backend -eq 'aria2') { $downloads + $hashes } else { @($downloads[0], $hashes[0], $downloads[1], $hashes[1]) }
        Assert-UpdateOrder $result $expected 'hash failed'
    }
    It 'preserves the old installation when a process blocks update (<Backend>)' -TestCases $backends {
        param($Backend)
        $result = Invoke-UpdateOrderFixture -Backend $Backend -Blocked $true
        $downloads = @('download:https://example.invalid/first.zip', 'download:https://example.invalid/second.zip')
        $hashes = @('hash:https://example.invalid/first.zip', 'hash:https://example.invalid/second.zip')
        $prepared = if ($Backend -eq 'aria2') { $downloads + $hashes } else { @($downloads[0], $hashes[0], $downloads[1], $hashes[1]) }
        Assert-UpdateOrder $result ($prepared + @('process'))
    }
    It 'does nothing when already current (<Backend>)' -TestCases $backends {
        param($Backend)
        Assert-UpdateOrder (Invoke-UpdateOrderFixture -Backend $Backend -Current $true) @()
    }
    It 'downloads before checking processes with hash validation disabled (<Backend>)' -TestCases $backends {
        param($Backend)
        $result = Invoke-UpdateOrderFixture -Backend $Backend -CheckHash $false
        Assert-UpdateOrder $result @('download:https://example.invalid/first.zip', 'download:https://example.invalid/second.zip', 'process', 'pre_uninstall', 'uninstall', 'post_uninstall', 'install')
    }
}
