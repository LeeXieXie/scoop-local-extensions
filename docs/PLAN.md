# Local Scoop Extensions Plan

## Goal and Boundaries

Preserve the existing local process-stop feature and download-before-stop update
ordering, make cleanup resilient to occupied files, and publish a public GitHub
repository containing only source patches, regression tests, and documentation.
Do not upload local configuration, credentials, installed applications, or caches.
Do not run cleanup against real installed applications as part of testing.

The distribution is a small patch bundle, not a full Scoop fork. Its reference
upstream is Scoop v0.6.0, commit
`e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f`. Patch application must be explicit,
idempotent, checked for compatibility before writing, and leave unrelated changes
and Scoop configuration untouched. A check-only mode performs no source changes.

## Work Items

- [x] Protect cleanup behavior with tests before edits. Cover an occupied old
  version, continuation to other versions/apps, truthful incomplete results,
  current-version and persisted-data protection, and unsafe path rejection.
- [x] Handle deletion failures without killing processes, restarting Explorer,
  changing ACLs, taking ownership, or scheduling reboot deletion. Provide
  best-effort diagnostics without making process inspection a prerequisite.
- [x] Verify actual Windows file-lock handling in an isolated temporary fixture.
  Validate resolved absolute paths stay under that fixture before recursive work.
- [x] Package the three local features as one reviewed patch against the pinned
  upstream revision. Keep regression tests and the original Scoop license.
- [x] Add a safe apply/check script and Windows PowerShell/PowerShell CI that
  uses a disposable upstream source tree, never the developer's installed apps.
- [x] Write Chinese README and design notes explaining behavior, limitations,
  application, backups, future upstream drift, and verification boundaries.
- [x] Run focused tests, parser/static checks, secret/path review, independent
  review, and idempotence/compatibility checks before publishing.
- [ ] Create `LeeXieXie/scoop-local-extensions` as a public repository, push,
  and verify GitHub contents and CI. Do not change the installed Scoop remote or
  its update configuration as a side effect of publication.

## Local Verification

- Pinned upstream source: clean application succeeded, check-only made no source
  changes, and a second application returned `AlreadyApplied` without a new backup.
- Final bundle: 66/66 tests on Windows PowerShell 5.1 and 66/66 on PowerShell 7,
  using preinstalled Pester 3.4.0. Both source and test files passed parser checks.
- Tests cover a real exclusive-file lock, Restart Manager owner identification,
  read-only persisted junctions, actual upstream persist helpers for hardlinks,
  unsafe paths, partial failure aggregation, download ordering, and apply safety.
- Independent security review identified wildcard process-root matching and a
  shared hardlink-attribute hazard. Both were fixed and regression protected.
- Public source/path and credential scans passed. Local verification directory
  paths are ignored and excluded from publication.
- No real cleanup of installed applications or process termination was performed
  by this implementation. A read-only query of the previously reported PowerToys
  DLL identified Explorer; this was diagnostics, not remediation of the live lock.
- Remaining boundaries: file-symlink target behavior is unverified; Restart
  Manager/module calls are best effort and not individually interruptible.
