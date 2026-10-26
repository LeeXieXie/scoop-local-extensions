# Design and Safety Boundaries

## Distribution

This repository distributes one combined unified patch against the exact public
Scoop revision recorded in `upstream.json`. It does not vendor application data,
user configuration, or the entire upstream Git history. The original Scoop
license is retained. Only these production paths belong in the patch:

- `lib/install.ps1`: the existing opt-in process-stop extension.
- `libexec/scoop-config.ps1`: documentation for that local option.
- `libexec/scoop-update.ps1`: download/validation before the process guard.
- `libexec/scoop-cleanup.ps1`: safe partial-cleanup handling and diagnostics.
- `bin/scoop.ps1`: bounded mutation-operation locking and command classification.
- `lib/core.ps1`: bounded network Git subprocesses with isolated proxy settings.
- `lib/download.ps1`: local-only manifest planning and verified cache acquisition.
- `libexec/scoop-install.ps1`: explicit offline preflight before installation.

## Apply Contract

The caller selects a Scoop source tree explicitly. A forward compatibility check
must succeed for the entire patch before source modification. A successful
reverse check recognizes an already-complete installation. A recognized complete
v1 or 0.2.0 can upgrade with an incremental patch; no live reverse-application
step is performed. These paths back up the eight allowlisted source files. Partial application
or conflicting changes are rejected; no force/overwrite mode is provided.
Source backups precede application. A check-only invocation does not modify the
target. Installation configuration, remotes, update channels, and applications
are never changed by this script.

Application deliberately leaves source changes uncommitted for human review.
Scoop's own updater rejects tracked uncommitted changes by default, so the user
must review and commit the eight source paths in the target Scoop repository.
Publishing this bundle is not a substitute for that local commit. The bundle
repository is not a valid replacement for the complete Scoop update source.

## Runtime Boundaries

Process termination remains opt-in and limited to the original target-app guard.
The update command invokes that guard only after all download preparation and
enabled hash verification succeed, before hooks or old-version uninstall.
Reset and uninstall retain their original process-check behavior.

Cleanup must continue past a failed old-version removal while preserving a
truthful incomplete result. Canonical path and current-version checks precede
recursive deletion. Persisted data is not a cleanup target. Failed deletion may
already have removed some unlocked files, so documentation must not promise an
atomic old-version removal or complete rollback.

Read-only persisted files and identifiable read-only hardlinks fail closed,
because clearing their attributes may also change the shared persisted target.
Writable persisted-hardlink removal and read-only directory-junction removal are
covered with the actual upstream persist helpers. File symlink behavior is not
claimed verified. Target-app process matching uses literal, case-insensitive
directory boundaries, not wildcard matching against user-controlled paths.

File-holder diagnostics use Windows Restart Manager where available and remain
best effort. Process IDs, names, paths, and diagnostic provenance are display-only;
PID reuse and shell/service/critical-process risks must be made explicit. Cleanup
does not terminate holders,
restart Explorer, change permissions, claim ownership, or schedule reboot work.
Unknown access-denied causes must not be asserted to be a specific process.

Cleanup retention counts the current version plus the requested number minus one
old installations, using Scoop's installation chronology. Rollback does not make
the current version deletable. Preview shares candidate selection but performs
no deletion, link unlink, attribute modification, cache write, or process action.
Actual execution revalidates targets; preview cannot guarantee later access.

Mutation locks live outside the Scoop Git source tree. Read-only commands and
cleanup preview do not acquire a write lease. Contention waits are bounded,
same-process nesting is reentrant, and ancestor-process waits must fail rather
than deadlock. Global mutations require a shared global scope without changing
permissions. Lock metadata excludes complete arguments and credentials.

Network Git subprocesses preserve argument boundaries and process-local proxies.
Deadlines apply to network operations only; zero disables them. Cancellation
targets the child process tree created for that operation. Failed bucket syncs
are aggregated without marking a partial operation as fully successful. There is
no automatic reset, stash, remote replacement, service recovery, or app rollback.

## Prepared Acquisition and Explicit Relaunch

Batch preparation freezes manifest/version/source/architecture and covers missing
dependencies before any process stop or installation side effect. Prefetch-only
exits at the preparation barrier. Payload identity is rechecked before use;
serial installation does not imply a transaction or complete recovery.

Offline acquisition uses local manifests and existing complete cache files only.
Missing hashes, nightly versions, remote metadata inputs and incompatible cache
or hash bypass options fail closed. Arbitrary hooks and external installer or
uninstaller execution are rejected before stopping an old application or making
installation directories. Prepared installation serializes the frozen manifest
instead of re-fetching the source through the legacy manifest-save function.
This policy is not an OS network sandbox for extraction tools or installed apps.
Metadata-only local selection precedes cache/policy checks for held or unchanged
applications. Duplicate dependency keys must agree on their frozen identities;
individually valid plans from different buckets cannot silently overwrite one another.

Relaunch is explicit and limited to ordinary GUI executables actually stopped by
the current update, deduplicated by safe relative identity. Do not capture command
lines, credentials, environment or CWD. Verify successful new installation and
physical path containment before starting without arguments. Services, shells,
system/critical processes, the current execution chain and background helpers are
excluded. Primary identity is restricted to verified manifest GUI shortcut targets,
not every child process that happens to have a window. Do not promise restored application sessions or recover failed updates
by launching an unverified new executable.

## Verification

Focused regression tests isolate update side effects and exercise cleanup in
temporary fixtures, including a real Windows exclusive-file lock where
available. CI applies the patch to the pinned upstream tree and tests both
Windows PowerShell and PowerShell. Applying a patch or running a mocked order
test is not end-to-end evidence for an application upgrade. No claim is made
that all live locks can be removed or that future upstream revisions will apply.
