# Milestone 2: Predictable Local Scoop Operations

## Approved Scope

Implement the first recommended group: operation locking, cleanup retention and
preview, and bounded Git network operations with truthful bucket-sync failures.
Batch prefetch, offline installation, and automatic process/service recovery are
explicitly deferred. Preserve the existing process, update-order, and cleanup
safety features. Add no runtime dependencies and do not operate on real apps.

## Design and Ownership

- Operation locking belongs in `bin/scoop.ps1`, with tests in
  `tests/Scoop-OperationLock.Tests.ps1`. Lock modifying operations only, use
  bounded waits and owner diagnostics, preserve command exit status, and release
  handles in `finally`. Read-only help/list/search must not wait. Same-process
  nesting must be reentrant; cross-process nesting must not wait indefinitely.
- Cleanup additions belong in `libexec/scoop-cleanup.ps1`, with tests in
  `tests/Scoop-CleanupPlan.Tests.ps1`. `--keep N` means current plus N-1 most
  recent installed old versions, using Scoop installation chronology rather than
  lexicographic directory order. Current is retained even after rollback.
  `--dry-run` previews the same candidates without unlinking, deleting, changing
  attributes, clearing caches, or ending processes. Retained-version caches are
  protected when `--cache` is used. The default remains current-only retention.
- Git timeout work belongs in `lib/core.ps1` and the bucket-sync portions of
  `libexec/scoop-update.ps1`, with focused network/bucket tests. A configurable
  `git_network_timeout` defaults to 120 seconds; zero explicitly disables it.
  Preserve argument quoting, process-local proxy behavior, output and exit codes.
  Timeout cleanup targets only the spawned child tree. A failed bucket does not
  stop healthy buckets, but the command must not report overall success or
  advance the last-success timestamp when synchronization is incomplete.
- Root owns config help, metadata, documentation, patch generation, apply-tool
  upgrades, integration review, local commits and public publication.

## Distribution

Expand the explicit production allowlist from four to six existing upstream
files: install, config help, cleanup, update, core and the command entry point.
Keep the original combined patch for v1 recognition and add a checked incremental
upgrade patch. Never reverse a live patch as an intermediate upgrade step.
Preflight either a clean upstream installation or a complete recognized v1,
refuse ambiguous partial states, back up the six source files, and verify
idempotence. Keep the pinned Scoop v0.6.0 upstream reference unchanged.

## Execution and Verification

- [x] Add and run failing focused tests for each new behavior before editing it.
- [x] Implement all three independent lanes without touching other owners' files.
- [x] Update exact-path patch validation and test fresh/v1-upgrade/idempotent modes.
- [x] Run all existing and new tests on PowerShell 5.1 and PowerShell 7.
- [x] Review destructive-path, lock, process-tree, exit-status and privacy risks.
- [x] Verify generated artifacts on disposable pinned upstream trees.
- [x] Commit installed local changes so Scoop self-update is not blocked by dirt.
- [ ] Update README/design and publish the public repository; verify both CI jobs.

All recursive fixture cleanup must verify its resolved absolute temporary path.
No automatic Explorer restart, service shutdown, ACL mutation, stash, hard reset,
or update-source replacement is introduced. No real app install/update/cleanup
or external network failure is used as a destructive verification shortcut.

## Verification Record

- Final local suite: 127/127 on PowerShell 7 against the installed source and
  127/127 on Windows PowerShell 5.1 against a clean, patched pinned source tree.
- Fresh application: `Applicable` -> `Applied` -> `AlreadyApplied`.
- Recognized v1 upgrade: `UpgradeApplicable` -> `Upgraded` -> `AlreadyApplied`.
- All six full-patch postimages match the installed source. Public credential,
  private-path, Markdown-link, workflow-YAML and whitespace checks passed.
- Initial review found the Git-start/job-assignment race and unnecessary global
  permissions for local imports. Suspended native process creation now assigns
  the job before execution, and local Scoopfile inspection determines lock scope.
- Direct URL/UNC import is intentionally rejected with a local-download hint;
  this compatibility restriction is documented instead of silently bypassing the
  operation lock. File input remains read-locked until import dispatch completes.
- File symlink targets, network credential-helper user interfaces, and future
  upstream compatibility are not claimed verified. The tests use disposable
  sources and process fixtures, not live application changes.
- Installed source is committed locally as `ee08b567`; its worktree is clean,
  official Scoop update source is unchanged, and bundle verification returns
  `AlreadyApplied` for version `0.2.0`.
