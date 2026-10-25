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

## Apply Contract

The caller selects a Scoop source tree explicitly. A forward compatibility check
must succeed for the entire patch before source modification. A successful
reverse check recognizes an already-complete installation. Partial application
or conflicting changes are rejected; no force/overwrite mode is provided.
Source backups precede application. A check-only invocation does not modify the
target. Installation configuration, remotes, update channels, and applications
are never changed by this script.

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

## Verification

Focused regression tests isolate update side effects and exercise cleanup in
temporary fixtures, including a real Windows exclusive-file lock where
available. CI applies the patch to the pinned upstream tree and tests both
Windows PowerShell and PowerShell. Applying a patch or running a mocked order
test is not end-to-end evidence for an application upgrade. No claim is made
that all live locks can be removed or that future upstream revisions will apply.
