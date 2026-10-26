# Design References

These references were read during the 2026-10-26 design review. They are design
inputs, not dependencies, endorsements, or claims that upstream accepted this
bundle. The runtime code is reviewed against this repository's own safety rules.

## First Milestone-2 Features

- [Scoop PR 6557: file lock for concurrent executions](https://github.com/ScoopInstaller/Scoop/pull/6557)
  was open/unmerged at review. Borrow the need for mutation serialization, not
  unconditional locking of read-only commands. Require bounded waits and explicit
  nesting/global-scope behavior.
- [Scoop PR 5441: cleanup retention](https://github.com/ScoopInstaller/Scoop/pull/5441)
  was open/unmerged. Borrow the `--keep` interface, but do not rely on directory
  enumeration order. Define current plus the most recently installed old versions
  using Scoop installation chronology, and protect the retained cache entries.
- [Scoop issue 3760: what-if/check mode](https://github.com/ScoopInstaller/Scoop/issues/3760)
  was closed, but that is not evidence of an implemented dry-run. Preview must
  share candidate selection with execution while performing no filesystem changes.
- [xrgzs/scoop Git timeout change](https://github.com/xrgzs/scoop/commit/032e6706ae9fd2ef7e4c2dd68cdd4f8c0b2be66b)
  motivates bounded network work. Preserve process-local proxy settings and exit
  codes, and terminate only the subprocess started by the timed operation.

The fork's fetch-plus-hard-reset synchronization policy is deliberately not
adopted: this bundle must preserve reviewed local commits and never hide or
discard them to make an update appear successful.

## Deferred Ideas

- [hok update planning](https://github.com/chawyehsu/hok/blob/0de5a4d60aa77bacb8eaa93a93c9aa28937c2bdf/src/cmd/upgrade.rs#L104-L184)
  provides examples of batch plans and download budgets. Offline download/cache
  behavior is not a guarantee that arbitrary installer hooks cannot access a network.
- [Scoop PR 6775: aria2 RPC](https://github.com/ScoopInstaller/Scoop/pull/6775)
  was open/unmerged. It is not evidence of complete cross-application parallel
  installation. Any future parallelism should first target downloads only.
- [Scoop PR 6603: force-kill processes and services](https://github.com/ScoopInstaller/Scoop/pull/6603)
  was open/unmerged. It does not provide a general graceful-close protocol or
  restoration of command lines, working directories, and application sessions.
- [Scoop PR 6768: staging and rollback](https://github.com/ScoopInstaller/Scoop/pull/6768)
  was closed/unmerged. Restoring a directory is not a transaction rollback for
  hook side effects, PATH changes, shortcuts, and shared persistent-data migrations.
