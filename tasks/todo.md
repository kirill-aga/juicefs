## ToDo

- [x] Integrate takeaways from first attempt to build JuiceFS on OpenBSD (OSS-3)
- [x] Add OpenBSD native packaging (OSS-3)
- [x] Test the Gitlab pipeline (OSS-3, smoke stage added in OSS-5)

## OSS-5: Upstream sync routine

Spec: `docs/superpowers/specs/2026-10-09-upstream-sync-design.md`
Plan: `docs/superpowers/plans/2026-10-09-upstream-sync.md`

- [x] Task 1: Sync helper script (`preflight`, `start`, `restack`, `check-patches`)
- [x] Task 2: Go version check script
- [x] Task 3: Harden the dependency patch script
- [x] Task 4: Package artifact fix, smoke test, pipeline `smoke` stage
- [x] Task 5: Sync documentation, fork notes in `.claude/rules/openbsd.md`, spec corrections
- [x] Task 6: Prove the tooling on the old base (needs `doas` rule on the builder)
- [x] Task 7: Rebase onto `v1.4.1`, pipeline green
- [x] Task 8: Move `main`, verify acceptance, clean up branches

### Review

- Result: `main` is `v1.4.1` plus five `OpenBSD:` commits; pipeline green through `smoke`.
- Rollback point: tag `pre-sync/v1.4.1`.
- Routine for the next sync: `docs/openbsd/upstream-sync.md`.
- What went differently from the plan:
  - A misplaced edit in the patch script broke the first build; `check-patches` now also parses the generated Go files.
  - The smoke test found two bugs already present in the port's cgofuse bridge (truncate without a file handle; stale size after close). Both were fixed in `pkg/cgofuse/cgofuse.go`, which the plan did not expect to touch.
  - The builder had a real mount config (`/etc/juicefs/backup.env`) and no `doas.conf`; the owner sorted both out by hand.
  - A final review after the sync led to a second round on `main`: smoke-test state now survives a builder reboot (tested by a simulated crash in the pipeline), host checks run before cleanup, a watchdog and job timeout were added, and tested packages are published to the builder's package directory.
  - Local Go tests could not fully run: `pkg/vfs` needs Redis, `pkg/chunk` tests do not link with Go 1.27. The rebase itself went as predicted: one conflict, no OpenBSD compile errors against `v1.4.1`.
