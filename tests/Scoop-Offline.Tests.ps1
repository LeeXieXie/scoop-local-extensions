Describe 'Strict cache-only installation' {
    BeforeEach {
        $root = $env:SCOOP_LOCAL_EXTENSIONS_SOURCE
        if (!$root) { throw 'SCOOP_LOCAL_EXTENSIONS_SOURCE is required.' }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'lib/download.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'Download source does not parse.' }
        $definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
        foreach ($file in @('manifest.ps1', 'core.ps1', 'depends.ps1')) {
            $helperAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('lib/' + $file)), [ref]$tokens, [ref]$errors)
            foreach ($definition in $helperAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                if ($definition.Name -in @('url', 'hash', 'arch_specific', 'Get-SupportedArchitecture', 'parse_app', 'cache_path', 'Get-InstallationHelper', 'Test-7zipRequirement', 'Test-LessmsiRequirement', 'url_filename', 'url_remote_filename', 'fname')) { . ([scriptblock]::Create($definition.Extent.Text)) }
            }
        }
        function script:url($manifest, $arch) { arch_specific 'url' $manifest $arch }
        $cachedir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $bucketRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item $cachedir, $bucketRoot -ItemType Directory -Force | Out-Null
        function Get-LocalBucket { 'main' }
        function Find-BucketDirectory { $bucketRoot }
        function installed { $false }
        function Test-HelperInstalled { $true }
        function get_config { $false }
        function Get-Manifest { throw 'Forbidden remote-aware resolver.' }
        function Test-Aria2Enabled { throw 'Offline mode must bypass aria2.' }
        function handle_special_urls { throw 'Offline mode must bypass URL rewriting.' }
        function Add-FixtureManifest($App, $Depends) {
            $inputPath = Join-Path $root 'lib/download.ps1'
            $manifest = [pscustomobject]@{ version = '1'; url = ('https://example.org/' + $App + '.zip'); hash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash }
            if ($Depends) { $manifest | Add-Member -NotePropertyName depends -NotePropertyValue $Depends }
            $manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $bucketRoot ($App + '.json'))
            Copy-Item -LiteralPath $inputPath -Destination (cache_path $App '1' $manifest.url)
            return $manifest
        }
        function Assert-Rejected { param([scriptblock]$Action) $rejected = $false; try { & $Action } catch { $rejected = $true }; if (!$rejected) { throw 'Unsafe offline operation was accepted.' } }
    }
    It 'rejects remote and historical manifest inputs' {
        Assert-ScoopOfflineInput 'main/example'
        foreach ($spec in @('https://example.org/app.json', '\\server\app.json', 'app@1', '../app', 'main/../app', '&app')) { Assert-Rejected { Assert-ScoopOfflineInput $spec } }
    }
    It 'rejects hooks in inactive architecture and root fallback' {
        foreach ($field in @('pre_install', 'post_install', 'pre_uninstall', 'post_uninstall', 'installer', 'uninstaller', 'env_set')) {
            $manifest = [pscustomobject]@{ version = '1'; url = 'https://example.org/app.zip'; hash = ('a' * 64) }
            $manifest | Add-Member $field 'Write-Host unsafe'
            Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' }
            $manifest.PSObject.Properties.Remove($field)
            $manifest | Add-Member architecture ([pscustomobject]@{ '32bit' = [pscustomobject]@{ $field = 'unsafe' } })
            Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' }
        }
    }
    It 'rejects missing hash, skipped hash, nightly and MSI installer surfaces' {
        foreach ($hash in @($null, '', 'skip', 'a')) {
            $manifest = [pscustomobject]@{ version = '1'; url = 'https://example.org/app.zip'; hash = $hash }
            Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' }
        }
        Assert-Rejected { Assert-ScoopOfflineManifest ([pscustomobject]@{ version = 'nightly'; url = 'a'; hash = ('a' * 64) }) '64bit' }
        Assert-Rejected { Assert-ScoopOfflineManifest ([pscustomobject]@{ version = '1'; url = 'a'; hash = ('a' * 64); msi = $true }) '64bit' }
    }
    It 'accepts a hashed portable manifest and dependency-ordered frozen plan' {
        $null = Add-FixtureManifest 'child'
        $null = Add-FixtureManifest 'parent' @('child')
        $plan = @(Get-ScoopOfflineInstallPlan @('main/parent') '64bit' $false $false)
        if (($plan.App -join ',') -ne 'child,parent' -or !$plan[1].Offline -or !$plan[1].Identity) { throw 'Incorrect frozen dependency plan.' }
        Set-Content (Join-Path $bucketRoot 'parent.json') '{"version":"changed"}'
        if ($plan[1].Manifest.version -ne '1') { throw 'Prepared manifest was not frozen.' }
    }
    It 'rejects missing and corrupt cache files without deleting them' {
        $manifest = Add-FixtureManifest 'sample'
        $path = cache_path 'sample' '1' $manifest.url
        Set-Content -LiteralPath $path 'corrupt'
        Assert-Rejected { Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit' }
        if (!(Test-Path -LiteralPath $path)) { throw 'Preflight deleted bad cache.' }
        Remove-Item -LiteralPath $path
        Assert-Rejected { Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit' }
    }
    It 'rejects a missing second dependency before returning any plan entries' {
        $null = Add-FixtureManifest 'child'
        $null = Add-FixtureManifest 'parent' @('child', 'missing')
        $returned = @()
        Assert-Rejected { $returned = @(Get-ScoopOfflineInstallPlan @('parent') '64bit' $false $false) }
        if ($returned.Count) { throw 'Partial plan escaped preflight.' }
    }
    It 'rejects dependency cycles and conflicting explicit sources' {
        $null = Add-FixtureManifest 'one' @('two')
        $null = Add-FixtureManifest 'two' @('one')
        Assert-Rejected { Get-ScoopOfflineInstallPlan @('one') '64bit' $false $false }
        $null = Add-FixtureManifest 'one'
        $other = Join-Path $TestDrive 'other'
        New-Item $other -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $bucketRoot 'one.json') $other
        Assert-Rejected { Get-ScoopOfflineInstallPlan @('main/one', (Join-Path $other 'one.json')) '64bit' $false $false }
    }
    It 'never follows installed remote metadata when planning a requested root' {
        $null = Add-FixtureManifest 'sample'
        function installed { $true }
        function install_info { throw 'Installed remote metadata must not be read.' }
        $plan = @(Get-ScoopOfflineInstallPlan @('sample') '64bit')
        if ($plan[0].App -ne 'sample') { throw 'Local root did not resolve.' }
    }
    It 'rejects cache escapes and partial download sidecars read-only' {
        $manifest = Add-FixtureManifest 'sample'
        $path = cache_path 'sample' '1' $manifest.url
        Set-Content -LiteralPath ($path + '.aria2') 'pending'
        Assert-Rejected { Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit' }
        if (!(Test-Path -LiteralPath ($path + '.aria2'))) { throw 'Sidecar was deleted.' }
        function cache_path { Join-Path $bucketRoot 'sample.json' }
        Assert-Rejected { Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit' }
    }
    It 'blocks low-level network download entry points offline' {
        $script:ScoopOfflineMode = $true
        try {
            Assert-Rejected { Start-Download 'https://example.org/a' 'unused' }
            Assert-Rejected { Invoke-Download 'https://example.org/a' 'unused' }
            Assert-Rejected { Invoke-CachedDownload 'a' '1' 'https://example.org/a' 'unused' }
        } finally { $script:ScoopOfflineMode = $false }
    }
    It 'copies and rehashes cached payloads without any download fallback' {
        $manifest = Add-FixtureManifest 'sample'
        $destination = Join-Path $TestDrive 'destination'
        New-Item $destination -ItemType Directory -Force | Out-Null
        $script:ScoopOfflineMode = $true
        try {
            $names = @(Invoke-ScoopDownload 'sample' '1' $manifest 'main' '64bit' $destination)
            if ($names.Count -ne 1 -or !(Test-Path -LiteralPath (Join-Path $destination 'sample.zip'))) { throw 'Offline copy missing.' }
            Assert-Rejected { Invoke-ScoopDownload 'sample' '1' $manifest 'main' '64bit' $destination $false $true }
            Assert-Rejected { Invoke-ScoopDownload 'sample' '1' $manifest 'main' '64bit' $destination $true $false }
        } finally { $script:ScoopOfflineMode = $false }
    }
    It 'allows online batch cache verification without weakening offline hook policy' {
        $manifest = Add-FixtureManifest 'sample'
        $manifest | Add-Member -NotePropertyName pre_install -NotePropertyValue 'Write-Host online-only'
        Assert-ScoopOfflineManifest $manifest '64bit' $true
        $payloads = @(Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit')
        if ($payloads.Count -ne 1) { throw 'Online cache verification lost its payload.' }
        Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' }
    }
    It 'rejects MSI payload extraction and cache links before installation' {
        $manifest = Add-FixtureManifest 'sample'
        $manifest.url = 'https://example.org/sample.msi'
        Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' }
        $manifest = Add-FixtureManifest 'linked'
        $cachePath = cache_path 'linked' '1' $manifest.url
        Remove-Item -LiteralPath $cachePath
        $target = Join-Path $bucketRoot 'hardlink-target.zip'
        Copy-Item -LiteralPath (Join-Path $root 'lib/download.ps1') -Destination $target
        New-Item -ItemType HardLink -Path $cachePath -Target $target -ErrorAction Stop | Out-Null
        Assert-Rejected { Assert-ScoopCachedPayload 'linked' '1' $manifest '64bit' }
    }
    It 'rejects bypass flags before offline CLI preflight and skips self-update' {
        $source = Get-Content (Join-Path $root 'libexec/scoop-install.ps1') -Raw
        $offlineStart = $source.IndexOf('if ($opt.offline)')
        $updateStart = $source.IndexOf('if (is_scoop_outdated)')
        $planStart = $source.IndexOf('Get-ScoopOfflineInstallPlan $apps')
        if ($offlineStart -lt 0 -or $updateStart -le $offlineStart -or $planStart -le $offlineStart) { throw 'Offline CLI ordering regressed.' }
        $branch = $source.Substring($offlineStart, $updateStart - $offlineStart)
        if ($branch -notmatch '!\$use_cache -or !\$check_hash' -or $branch -notmatch 'exit 0') { throw 'Offline bypass flags or early exit regressed.' }
    }
    It 'rejects leftover aria2 application input before accepting cached files' {
        $manifest = Add-FixtureManifest 'sample'
        Set-Content -LiteralPath (Join-Path $cachedir 'sample.txt') 'unfinished'
        Assert-Rejected { Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit' }
        if (!(Test-Path -LiteralPath (Join-Path $cachedir 'sample.txt'))) { throw 'Preflight removed aria2 state.' }
    }
    It 'does not accept missing hashes through the cache helper online or offline' {
        $manifest = Add-FixtureManifest 'sample'
        foreach ($bad in @($null, '', 'skip')) {
            $manifest.hash = $bad
            Assert-Rejected { Assert-ScoopCachedPayload 'sample' '1' $manifest '64bit' }
        }
    }
    It 'aborts the offline CLI before creating directories when a later dependency is missing' {
        $null = Add-FixtureManifest 'child'
        $null = Add-FixtureManifest 'parent' @('child', 'missing')
        $source = Get-Content (Join-Path $root 'libexec/scoop-install.ps1') -Raw
        $start = $source.IndexOf('if ($opt.offline)')
        $end = $source.IndexOf('if (is_scoop_outdated)')
        $branch = [scriptblock]::Create($source.Substring($start, $end - $start))
        $opt = @{ offline = $true }; $apps = @('parent'); $architecture = '64bit'; $global = $false; $independent = $false; $use_cache = $true; $check_hash = $true
        $script:offlineInstallEffects = 0
        function install_app { $script:offlineInstallEffects++; throw 'Unexpected installation effect.' }
        function ensure { $script:offlineInstallEffects++; throw 'Unexpected directory creation.' }
        function abort { param($Message) throw $Message }
        Assert-Rejected { & $branch }
        if ($script:offlineInstallEffects) { throw 'Incomplete dependency closure started installation.' }
    }
    It 'requires an actual extraction helper even for independent offline installs' {
        $null = Add-FixtureManifest 'sample'
        function Get-InstallationHelper { '7zip' }
        function Test-HelperInstalled { $false }
        Assert-Rejected { Get-ScoopOfflineInstallPlan @('sample') '64bit' $false $true }
    }
    It 'rejects directory-alias versions and mismatched cached version identity' {
        $manifest = Add-FixtureManifest 'sample'
        Assert-Rejected { Assert-ScoopCachedPayload 'sample' 'different' $manifest '64bit' }
        foreach ($version in @('.', '..', 'version.', 'NUL', 'CON.zip')) {
            $manifest.version = $version
            Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' }
        }
    }
    It 'reads frozen local metadata without requiring cached payloads or permitting effects' {
        $manifest = Add-FixtureManifest 'sample'
        $manifest | Add-Member -NotePropertyName pre_install -NotePropertyValue 'throw "must not execute"'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $bucketRoot 'sample.json')
        Remove-Item -LiteralPath (cache_path 'sample' '1' $manifest.url)
        function Assert-ScoopOfflineManifest { throw 'Metadata lookup cannot enforce install hook policy.' }
        function Assert-ScoopCachedPayload { throw 'Metadata lookup cannot require cached payloads.' }
        function install_info { throw 'Metadata lookup cannot follow installed remote origins.' }
        $entry = Get-ScoopOfflineManifestEntry 'main/sample' '64bit'
        if ($entry.App -ne 'sample' -or $entry.Version -ne '1' -or $entry.Bucket -ne 'main' -or $entry.Architecture -ne '64bit' -or !$entry.Identity -or $entry.PSObject.Properties['Payloads']) { throw 'Invalid metadata-only entry.' }
        Set-Content -LiteralPath (Join-Path $bucketRoot 'sample.json') '{"version":"changed"}'
        if ($entry.Manifest.version -ne '1' -or !$entry.Manifest.pre_install) { throw 'Metadata manifest was not frozen.' }
    }
    It 'rejects remote and historical metadata inputs before reading a manifest' {
        foreach ($spec in @('https://example.org/app.json', '\\server\app.json', 'main/app@1')) {
            Assert-Rejected { Get-ScoopOfflineManifestEntry $spec '64bit' }
        }
        $null = Add-FixtureManifest 'sample'
        $entry = Get-ScoopOfflineManifestEntry 'sample' '64bit'
        if ($entry.Source -ne (Join-Path $bucketRoot 'sample.json')) { throw 'Metadata lookup lost local source identity.' }
    }
    It 'allows local metadata for an unselected nightly unhashed manifest' {
        $manifest = Add-FixtureManifest 'sample'
        $manifest.version = 'nightly'
        $manifest.hash = $null
        $path = Join-Path $bucketRoot 'sample.json'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        $entry = Get-ScoopOfflineManifestEntry $path '64bit'
        if ($entry.Version -ne 'nightly' -or $entry.Manifest.hash -or $entry.Source -ne $path) { throw 'Metadata unexpectedly applied install policy.' }
        Assert-Rejected { Get-ScoopOfflineInstallPlan @($path) '64bit' }
    }
    It 'rejects Win32 payload aliases for offline and online prepared modes' {
        $manifest = [pscustomobject]@{ version = '1'; url = 'https://example.org/safe.zip'; hash = ('a' * 64) }
        Assert-ScoopOfflineManifest $manifest '64bit'
        Assert-ScoopOfflineManifest $manifest '64bit' $true
        foreach ($name in @('sample.zip.', 'sample.zip ', ' sample.zip', 'CON', 'con.zip', 'PrN.exe', 'AUX.data', 'nul.zip', 'COM1.zip', 'LPT9.tar.gz', 'bad|name.zip', 'bad<name.zip', 'bad>name.zip', 'bad"name.zip', 'bad*name.zip', ('bad' + [char]1 + 'name.zip'))) {
            $manifest.url = 'https://example.org/download#/' + $name
            foreach ($allowScripts in @($false, $true)) {
                Assert-Rejected { Assert-ScoopOfflineManifest $manifest '64bit' $allowScripts }
            }
        }
    }
    It 'rejects linked local metadata before reading its JSON' {
        $null = Add-FixtureManifest 'sample'
        $linked = Join-Path $bucketRoot 'linked.json'
        New-Item -ItemType HardLink -Path $linked -Target (Join-Path $bucketRoot 'sample.json') -ErrorAction Stop | Out-Null
        $script:offlineMetadataReads = 0
        function Get-Content { $script:offlineMetadataReads++; throw 'Unexpected manifest read.' }
        Assert-Rejected { Get-ScoopOfflineManifestEntry $linked '64bit' }
        if ($script:offlineMetadataReads) { throw 'Linked metadata was read before physical path validation.' }
    }
}
