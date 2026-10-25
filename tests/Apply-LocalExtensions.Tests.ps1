Describe 'Apply-LocalExtensions safety and compatibility' {
    BeforeEach {
        function Assert-TestEqual {
            param([Parameter(ValueFromPipeline = $true)]$Actual, [Parameter(Position = 0)]$Expected)
            process { if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." } }
        }
        function Assert-TestEmpty {
            param([Parameter(ValueFromPipeline = $true)]$Actual)
            process { if (-not [string]::IsNullOrEmpty($Actual)) { throw 'Expected no backup path.' } }
        }
        function Assert-TestThrows {
            param([Parameter(ValueFromPipeline = $true)][scriptblock]$Action)
            process {
                $thrown = $false
                try { & $Action | Out-Null } catch { $thrown = $true }
                if (-not $thrown) { throw 'Expected the operation to reject this input.' }
            }
        }
        function Remove-TestDirectory {
            param([string]$Path)
            $fullPath = [IO.Path]::GetFullPath($Path)
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $fullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($fullPath) -notmatch '^scoop-local-extensions-(test|backup)-') {
                throw "Refusing to remove unsafe test directory: $fullPath"
            }
            if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
        }
        $applyScriptSource = Join-Path $PSScriptRoot '../scripts/Apply-LocalExtensions.ps1'
        $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('scoop-local-extensions-test-' + [guid]::NewGuid().ToString('N'))
        $script:targetRoot = Join-Path $fixtureRoot 'scoop'
        $script:bundleRoot = Join-Path $fixtureRoot 'bundle'
        $script:backups = @()
        $script:sourcePaths = @('lib/install.ps1', 'libexec/scoop-config.ps1', 'libexec/scoop-update.ps1', 'libexec/scoop-cleanup.ps1')
        $script:subject = Join-Path $bundleRoot 'scripts/Apply-LocalExtensions.ps1'
        New-Item -ItemType Directory -Path $targetRoot, (Join-Path $bundleRoot 'scripts'), (Join-Path $bundleRoot 'patches') -Force | Out-Null
        if (Test-Path -LiteralPath $applyScriptSource) { Copy-Item -LiteralPath $applyScriptSource -Destination $subject }
        @{
            repository = 'https://github.com/ScoopInstaller/Scoop'
            revision = 'e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f'
            version = '0.6.0'
            patch = 'patches/local-extensions.patch'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bundleRoot 'upstream.json') -Encoding ASCII
        $patch = ''
        foreach ($relativePath in $sourcePaths) {
            $filePath = Join-Path $targetRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $filePath) -Force | Out-Null
            [IO.File]::WriteAllText($filePath, "old`n")
            $patch += "diff --git a/$relativePath b/$relativePath`n--- a/$relativePath`n+++ b/$relativePath`n@@ -1 +1 @@`n-old`n+new`n"
        }
        $script:patchPath = Join-Path $bundleRoot 'patches/local-extensions.patch'
        [IO.File]::WriteAllText($patchPath, $patch)
        & git -C $targetRoot init --quiet
        & git -C $targetRoot config core.autocrlf false
        & git -C $targetRoot add -- $sourcePaths
        if ($LASTEXITCODE -ne 0) { throw 'Could not initialize disposable Git fixture.' }
    }

    AfterEach {
        foreach ($backupPath in $backups) { Remove-TestDirectory $backupPath }
        Remove-TestDirectory $fixtureRoot
    }

    It 'provides an executable application script' {
        Test-Path -LiteralPath $subject | Assert-TestEqual $true
    }

    It 'checks compatibility without modifying source or creating backups' {
        $result = & $subject -ScoopRoot $targetRoot -Check
        $result.Status | Assert-TestEqual 'Applicable'
        $result.BackupPath | Assert-TestEmpty
        foreach ($path in $sourcePaths) { [IO.File]::ReadAllText((Join-Path $targetRoot $path)) | Assert-TestEqual "old`n" }
    }

    It 'backs up only the four originals outside the worktree' {
        [IO.File]::WriteAllText((Join-Path $targetRoot 'private-config.json'), 'do-not-copy')
        $result = & $subject -ScoopRoot $targetRoot
        $script:backups += $result.BackupPath
        $result.Status | Assert-TestEqual 'Applied'
        $result.BackupPath.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase) | Assert-TestEqual $false
        @(Get-ChildItem -LiteralPath $result.BackupPath -File -Recurse).Count | Assert-TestEqual 4
        foreach ($path in $sourcePaths) {
            [IO.File]::ReadAllText((Join-Path $targetRoot $path)) | Assert-TestEqual "new`n"
            [IO.File]::ReadAllText((Join-Path $result.BackupPath $path)) | Assert-TestEqual "old`n"
        }
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'private-config.json') | Assert-TestEqual $false
    }

    It 'recognizes a fully applied patch without another backup' {
        $first = & $subject -ScoopRoot $targetRoot
        $script:backups += $first.BackupPath
        $second = & $subject -ScoopRoot $targetRoot
        $second.Status | Assert-TestEqual 'AlreadyApplied'
        $second.BackupPath | Assert-TestEmpty
        (& $subject -ScoopRoot $targetRoot -Check).Status | Assert-TestEqual 'AlreadyApplied'
    }

    It 'keeps WhatIf read-only' {
        $result = & $subject -ScoopRoot $targetRoot -WhatIf
        $result.Status | Assert-TestEqual 'WhatIf'
        $result.BackupPath | Assert-TestEmpty
        [IO.File]::ReadAllText((Join-Path $targetRoot $sourcePaths[0])) | Assert-TestEqual "old`n"
    }

    It 'rejects drift before modifying any file' {
        [IO.File]::WriteAllText((Join-Path $targetRoot $sourcePaths[3]), "different`n")
        { & $subject -ScoopRoot $targetRoot } | Assert-TestThrows
        [IO.File]::ReadAllText((Join-Path $targetRoot $sourcePaths[0])) | Assert-TestEqual "old`n"
        [IO.File]::ReadAllText((Join-Path $targetRoot $sourcePaths[3])) | Assert-TestEqual "different`n"
    }

    It 'rejects a partially applied bundle without writing remaining files' {
        [IO.File]::WriteAllText((Join-Path $targetRoot $sourcePaths[0]), "new`n")
        { & $subject -ScoopRoot $targetRoot } | Assert-TestThrows
        [IO.File]::ReadAllText((Join-Path $targetRoot $sourcePaths[1])) | Assert-TestEqual "old`n"
    }

    It 'preserves unrelated local changes without requiring a pinned HEAD' {
        [IO.File]::WriteAllText((Join-Path $targetRoot 'notes.txt'), 'keep-local')
        $result = & $subject -ScoopRoot $targetRoot
        $script:backups += $result.BackupPath
        $result.Status | Assert-TestEqual 'Applied'
        [IO.File]::ReadAllText((Join-Path $targetRoot 'notes.txt')) | Assert-TestEqual 'keep-local'
        @(& git -C $targetRoot diff --cached --name-only).Count | Assert-TestEqual 4
    }

    It 'rejects a patch naming an unexpected source file' {
        [IO.File]::WriteAllText($patchPath, [IO.File]::ReadAllText($patchPath).Replace('lib/install.ps1', 'config.json'))
        { & $subject -ScoopRoot $targetRoot -Check } | Assert-TestThrows
    }

    It 'rejects non-source patch operations' {
        $text = [IO.File]::ReadAllText($patchPath).Replace("--- a/lib/install.ps1", "old mode 100644`nnew mode 100755`n--- a/lib/install.ps1")
        [IO.File]::WriteAllText($patchPath, $text)
        { & $subject -ScoopRoot $targetRoot -Check } | Assert-TestThrows
    }

    It 'rejects an unsafe patch location in metadata' {
        $path = Join-Path $bundleRoot 'upstream.json'
        [IO.File]::WriteAllText($path, [IO.File]::ReadAllText($path).Replace('patches/local-extensions.patch', '../outside.patch'))
        { & $subject -ScoopRoot $targetRoot -Check } | Assert-TestThrows
    }

    It 'rejects extra paths including traditional diff headers hidden after a valid section' {
        $original = [IO.File]::ReadAllText($patchPath)
        foreach ($header in @('diff --git a/private-config.json b/private-config.json', '')) {
            $extra = "$header`n--- a/private-config.json`n+++ b/private-config.json`n@@ -1 +1 @@`n-old`n+new`n"
            [IO.File]::WriteAllText($patchPath, $original + $extra)
            { & $subject -ScoopRoot $targetRoot -Check } | Assert-TestThrows
        }
        [IO.File]::ReadAllText((Join-Path $targetRoot $sourcePaths[0])) | Assert-TestEqual "old`n"
    }

    It 'rejects renames, new and deleted files, and binary patches' {
        $original = [IO.File]::ReadAllText($patchPath)
        foreach ($operation in @(
            "similarity index 100%`nrename from lib/install.ps1`nrename to lib/renamed.ps1",
            'new file mode 100644', 'deleted file mode 100644', 'GIT binary patch',
            'Binary files a/lib/install.ps1 and b/lib/install.ps1 differ'
        )) {
            [IO.File]::WriteAllText($patchPath, $original.Replace('--- a/lib/install.ps1', "$operation`n--- a/lib/install.ps1"))
            { & $subject -ScoopRoot $targetRoot -Check } | Assert-TestThrows
        }
    }

    It 'requires the top-level Git worktree rather than a subdirectory' {
        { & $subject -ScoopRoot (Join-Path $targetRoot 'lib') -Check } | Assert-TestThrows
    }

    It 'rejects a non-Git target' {
        { & $subject -ScoopRoot $bundleRoot -Check } | Assert-TestThrows
    }

    It 'rejects relative and parent-traversing target paths' {
        { & $subject -ScoopRoot '.' -Check } | Assert-TestThrows
        { & $subject -ScoopRoot (Join-Path $targetRoot '../scoop') -Check } | Assert-TestThrows
    }

    It 'rejects linked source directories' {
        $external = Join-Path $fixtureRoot 'outside'
        Move-Item -LiteralPath (Join-Path $targetRoot 'lib') -Destination $external
        New-Item -ItemType Junction -Path (Join-Path $targetRoot 'lib') -Target $external | Out-Null
        { & $subject -ScoopRoot $targetRoot -Check } | Assert-TestThrows
        [IO.File]::ReadAllText((Join-Path $external 'install.ps1')) | Assert-TestEqual "old`n"
        [IO.Directory]::Delete((Join-Path $targetRoot 'lib'))
    }
}
