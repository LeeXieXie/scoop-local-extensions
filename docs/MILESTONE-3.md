# Milestone 3: Prepared Updates, Cache-Only Installation and Explicit Relaunch

## Scope

Implement opt-in batch update preparation, cache-only install/update, and explicit
post-update relaunch. Keep default update behavior and all 0.2.0 protections.
No real installed applications are updated, stopped, installed or relaunched for
verification. Tests use temporary manifests/cache roots and controlled processes.

## Interfaces and Safety

- `scoop update <apps> --prefetch`: resolve and download/verify the entire batch,
  then exit without stopping applications, running hooks, or installing anything.
- `scoop update <apps> --batch`: prepare and verify every target and missing
  dependency before any application can be stopped. Freeze manifests, architecture,
  version, source identity and cached payload identity for that invocation. Abort
  the whole preflight if one target fails. Installation remains serial and is not
  a transaction or guaranteed rollback.
- `scoop install <apps> --offline` and `scoop update <apps> --offline`: do not sync
  Scoop/buckets, resolve remote manifests, or download payloads. Reject cache
  bypass and hash bypass. Validate all required cached files before creating app
  directories or stopping old instances. Nightly/unhashed payloads are rejected.
  Reject arbitrary manifest hooks and external installer/uninstaller execution;
  portable extraction alone is not an operating-system network sandbox, and the
  resulting applications can access the network when subsequently run.
- `scoop update <apps> --restart`: explicitly relaunch eligible ordinary GUI apps
  that this invocation actually stopped, only after verified successful update.
  Record relative executable identity, not full command lines or credentials.
  Never relaunch services, shells, system/critical processes, or arbitrary child
  helpers. Do not claim restoration of sessions, unsaved data, arguments or CWD.
  Failed/blocked updates must not launch the new version. Duplicate main
  executables are relaunched at most once with hidden process creation.

Shared offline helpers belong in `lib/download.ps1`: `Assert-ScoopOfflineInput`,
`Assert-ScoopOfflineManifest`, `Assert-ScoopCachedPayload`, and
`Get-ScoopOfflineInstallPlan`. Update/install code consumes these helpers rather
than duplicating cache and hook policy. Prepared entries contain App, Spec,
Manifest, Bucket, Source, Architecture and Version. Offline plan is a dependency-
ordered list and performs read-only validation only.

## Ownership

- Batch/update/relaunch lane: `libexec/scoop-update.ps1`, `lib/install.ps1`,
  focused batch and restart tests. Own all changes to install helpers together.
- Offline lane: `lib/download.ps1`, `libexec/scoop-install.ps1`, offline tests.
  Coordinate shared interfaces with the first lane before relying on them.
- Root: config/help if needed, metadata and allowlists, incremental patch paths,
  public README/design/references, integration tests, review and Git publication.

## Distribution and Verification

- [x] Run failing focused tests before new runtime implementation.
- [x] Implement batch barriers, offline preflight and explicit safe relaunch.
- [x] Preserve complete 0.2.0 and add a recognized direct upgrade to 0.3.0; support
  fresh upstream and the original v1 upgrade without intermediate live reversal.
- [x] Exercise all regressions on PS5.1/PS7 and regenerate exact source artifacts.
- [x] Review unsafe restart targets, offline escape paths, hashes and frozen plans.
- [x] Commit installed changes and verify its worktree remains clean.
- [x] Publish code/docs and verify fresh and recognized-upgrade CI paths.

## Verification Notes

- PowerShell 7 full suite: 195/195 passed against the installed source. Runtime
  restart tests use controlled process objects and stubbed launch/stop boundaries,
  not live application relaunches.
- Windows PowerShell 5.1 full suite: 195/195 passed against the clean, patched
  pinned upstream source. Installed runtime is committed locally as `b531cfd2`;
  its worktree is clean and the exact bundle check reports `AlreadyApplied` 0.3.0.
- Real artifact paths verified: clean upstream application, direct complete-v1
  upgrade, and direct complete-0.2.0 upgrade; each is idempotent after application.
- Independent review found conflicting offline dependency merges and undeclared
  GUI helper eligibility. Frozen-identity comparisons and old/new primary shortcut
  intersection now reject those cases; focused rereview passed 61 tests.
- Local-only metadata selection now precedes cache/policy validation for unchanged
  and held applications. Win32 payload-name aliases and incomplete cache sidecars
  fail before application changes. Online prepared hooks retain normal semantics;
  only strict offline execution rejects hooks and dynamic environment expansion.
- Public credential/private-path scans, all eight runtime patch postimage hashes,
  parser checks, Markdown links, and workflow YAML validation passed.
- Public implementation commit: `161ffe8`. [GitHub Actions run 40272123745](https://github.com/LeeXieXie/scoop-local-extensions/actions/runs/40272123745)
  passed on both PowerShell engines. Each engine ran 195/195 tests on fresh
  upstream, after the v1 upgrade and after the 0.2.0 upgrade: six passing suites.
