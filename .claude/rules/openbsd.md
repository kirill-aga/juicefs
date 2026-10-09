# OpenBSD fork

This repository is a fork of JuiceFS that adds OpenBSD support. General
project rules come from upstream's `CLAUDE.md` / `AGENTS.md`; this file only
adds what is specific to the fork.

- `main` is one upstream release tag plus five `OpenBSD: …` commits. Do not add
  other commits to `main`. Make fixes as normal commits on a work branch, then
  run `sh hack/openbsd_sync_upstream.sh restack`. The routine is in
  `docs/openbsd/upstream-sync.md`.
- Never tag the fork with a `v*` name; those mean "upstream release".
- OpenBSD cannot be cross-compiled locally (cgo-only dependencies). Only the
  GitLab pipeline (`build → package → smoke`) proves an OpenBSD change.
- Build on OpenBSD: `go mod download`, `sh hack/openbsd_patch_deps.sh`, then
  `CGO_ENABLED=1 GOTOOLCHAIN=local go build`; see `.gitlab-ci.yml`.
- FUSE on OpenBSD goes through `pkg/cgofuse` (system libfuse), not go-fuse.
- Pitfalls already paid for are in `tasks/lessons.md`. Read it before touching
  `deploy/openbsd/`, `hack/openbsd_*.sh` or any `*_openbsd.go` file.
- Jira project: OSS. Branches are named `OSS-N-short-description`.
