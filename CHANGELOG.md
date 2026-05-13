# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project (loosely) follows [Semantic Versioning](https://semver.org/).

## [0.1.3] — 2026-05-13

### Added

- **`dev-instance create --copy-claude`** — copies a Claude Code
  config allowlist from the host's `~/.claude/` into the new clone
  (`settings.json`, `CLAUDE.md`, `skills/`, `agents/`, `commands/`,
  `hooks/`, `plugins/`, `statusline.{sh,js}`, `claude-quota.js`) and
  chowns it to the `dev` user. Host-keyed runtime state
  (`sessions/`, `projects/`, `todos/`, `statsig/`,
  `shell-snapshots/`, history, caches, telemetry, etc.) is
  explicitly skipped — see [BACKLOG.md](BACKLOG.md) for the
  filtering rationale. Blueprint-mode only (the `--image` escape
  hatch runs as root with no `~dev`, so it's not supported).
  Codex / OpenCode equivalents are still in the backlog.

  Implementation notes worth knowing:
  - Tar uses `--dereference` so host-side symlinks in `~/.claude/`
    (e.g. `skills/clever-tools` pointing into a project dir) land
    inside the VM as real directories rather than dangling symlinks.
  - `--init` is async (`smolvm machine start` returns before it
    finishes), so `cmd_create` polls `id dev` before doing any exec
    work to avoid racing the dev-user setup.
  - `smolvm machine cp` reverts the writable filesystem on
    `--from <pack>` machines, so the `dev` user created by `--init`
    disappears after the copy. `cmd_create` re-runs
    `match-host-uid.sh` after the copy as a workaround. Tracked
    upstream as
    [smol-machines/smolvm#264](https://github.com/smol-machines/smolvm/issues/264)
    (filed during this release).
- **`BACKLOG.md`** — new tracking file at the repo root listing
  pending features and design decisions, including planned Codex /
  OpenCode equivalents of `--copy-claude` and the
  bash-or-something-else question for the `dev-instance` CLI.

### Documentation

- New "terminal size stuck at 80×24" entry in the *Known limitations*
  section of `CLAUDE.md`, with a pointer to upstream
  [smol-machines/smolvm#156](https://github.com/smol-machines/smolvm/issues/156)
  (we contributed evidence as a comment during this release; SIGWINCH
  forwarding doesn't take effect in smolvm 0.6.3 on macOS 26.4.1,
  regardless of `--image` vs `--from`).

### Upstream filings

Not strictly user-visible but worth recording — these came out of
landing `--copy-claude`:

- Filed [smol-machines/smolvm#264](https://github.com/smol-machines/smolvm/issues/264):
  `machine cp` reverts writable filesystem changes on `--from <pack>`
  machines. Draft + reproducer kept in `wip/issue-cp-reverts-pack-fs.md`.
- Posted comment on
  [smol-machines/smolvm#156](https://github.com/smol-machines/smolvm/issues/156)
  confirming SIGWINCH forwarding is still broken in 0.6.3 despite
  the claimed fix in 0.5.18 / commit `ce832d0`. Draft kept in
  `wip/comment-smolvm-156.md`.
- Five additional smolvm papercuts drafted at
  `wip/issue-papercuts.md` for future filing.

## [0.1.2] — 2026-05-13

### Changed

- **Blueprint build scripts refactored to a shared harness.** Each
  `blueprints/<name>/build.sh` is now a ~25-line shim that sets `NAME`
  + `IMAGE`, sources `blueprints/_build-lib.sh`, and calls
  `build_with_prereqs "$@" -- bash -c '<distro-specific install...>'`.
  The shared lib handles `--rebuild` parsing, source-VM lifecycle
  (create / reuse / delete-and-recreate), `cp + exec` of the two
  shared installers, and `pack create`. Almost every line in a
  per-blueprint `build.sh` is now actually unique to that blueprint
  (the install commands themselves) — the previous ~70 lines of
  identical lifecycle boilerplate per file are gone.
- `dev-instance new-blueprint` scaffold template adopts the same
  shim pattern, so scaffolded blueprints stay in sync with shipped
  ones automatically when the lib changes.
- **Blueprints renamed for clarity** — names now describe what's in
  the blueprint rather than carrying a generic `-dev` suffix:
  - `ubuntu-dev` → `ubuntu-bun-node` (Ubuntu base, ships Bun + Node)
  - `bun-dev` → `bun-node` (Bun base image, adds Node)
  - `bun-only` unchanged (already descriptive)

  If you've already built the old names locally, the source VMs and
  `dist/*.smolmachine` artifacts under the old names are orphaned —
  `smolvm machine delete ubuntu-dev` / `bun-dev` and
  `rm dist/{ubuntu-dev,bun-dev}.smolmachine` to reclaim disk, then
  `dev-instance build` the new names.

### Added

- `blueprints/_build-lib.sh` — shared build harness. Exports
  `vm_exists` and `build_with_prereqs FLAGS -- COMMAND...`. One file,
  edited once.
- **`dev-instance clean`** — stop and delete every clone for the
  current directory in one go. Lists the matches and prompts by
  default; pass `-f` / `--force` to skip the prompt. Continues past
  per-clone failures and exits nonzero if any failed.

## [0.1.1] — 2026-05-13

### Added

- **Host-uid-matching `dev` user in blueprint clones.** Files written
  inside `~/workspace` (= `/home/dev/workspace`) now keep their host
  owner, on both macOS (uid 501) and Linux (uid 1000) — no
  post-session `chown` needed. Implemented at runtime via
  `/usr/local/sbin/match-host-uid.sh`, invoked through smolvm
  `--init` with `HOST_UID` / `HOST_GID` env vars from
  `dev-instance create`. `dev` has passwordless sudo so agents that
  need `apt install` still work.
- `blueprints/_install-user.sh` — build-time installer for the
  runtime user-matching script. Sourced by every blueprint's
  `build.sh` and by the `dev-instance new-blueprint` scaffold
  template.

### Changed

- Blueprint clones mount the host project at `/home/dev/workspace`
  (instead of `/root/workspace`) and run as `dev`, not root.
- `dev-instance shell` probes for the `dev` user and uses
  `runuser -u dev -- bash -l` when present; falls back to plain
  `bash -l` as root for `--image` clones that don't ship the
  matching script.
- Blueprint apt-get installs now include `sudo` so the runtime
  user-matching script can drop `/etc/sudoers.d/dev` cleanly.

### Fixed

These were uncovered while landing the dev-user feature; several were
silently broken in 0.1.0 too (the install scripts ran, but nothing
inside them actually executed).

- **Shared install scripts now run inside the VM.** The previous
  `smolvm machine exec ... -- bash -s < script.sh` pattern was a
  no-op: `smolvm machine exec` doesn't forward host stdin without
  `-i`, so `bash -s` got EOF and exited 0. Replaced with `smolvm
  machine cp` + `bash /tmp/script.sh`. (This had silently kept the
  agent installer from doing anything in 0.1.0, too — only the
  legacy inline blueprints were really shipping any agents.)
- **Codex installer URL extraction.** The GitHub Releases JSON is a
  single line, so the previous `grep | head | sed` pipeline matched
  the wrong URL and the download ended up not a gzip tarball
  (`gzip: stdin: not in gzip format`). Switched to `grep -oE` to
  extract the right URL directly.
- **OpenCode probe-and-symlink** fallback for whichever dir the
  installer chooses (`$HOME/.opencode/bin`, `$HOME/.local/bin`,
  `$HOME/bin`), mirroring the Claude installer pattern. The
  `OPENCODE_INSTALL_DIR=/usr/local/bin` env var was unreliable.
- **Runtime user setup robustness:** `_install-user.sh`'s sudoers
  step now skips silently when sudo isn't installed (instead of
  failing the entire init). The `useradd` invocation drops `-m`
  (home dir pre-exists from smolvm's mount setup) and adds
  `-K UID_MIN=0` to silence "uid 501 outside default UID_MIN range"
  warnings on macOS hosts.
- **Runtime `chown` skips the virtiofs mount.** `chown -R /home/dev`
  was recursing into `/home/dev/workspace` and failing on read-only
  files like git's packed objects. Now uses `find /home/dev -path
  /home/dev/workspace -prune -o -exec chown ...`.

## [0.1.0] – 2026-05-13

First public layout — companion repo for an upcoming talk and blog
post on sandboxing autonomous agent CLIs with smolvm.

### Added

- Three blueprints under `blueprints/<name>/`: **`ubuntu-dev`**
  (Ubuntu 26.04 + Node 24 + Bun + agents), **`bun-dev`** (Debian 13
  + Node 24 + Bun + agents), **`bun-only`** (Debian 13, Bun-only,
  agents). Each is a self-contained `build.sh` + `pack.smolfile`.
- **Three agent CLIs preinstalled** in every blueprint via the
  shared `blueprints/_install-agents.sh`: Claude Code (native
  installer), OpenAI Codex CLI (prebuilt musl binary from GH
  Releases), OpenCode (`opencode.ai/install`). All symlinked into
  `/usr/local/bin/` and announced by `/etc/profile.d/agents-banner.sh`
  on shell entry: `Available agents: claude codex opencode`.
- **`dev-instance` CLI** with subcommands `create`, `shell`, `stop`,
  `rm`, `ls`, `build`, `new-blueprint`. Auto-detects repo root,
  handles per-project sandbox lifecycle, scaffolds new blueprints
  from any OCI image.
- **`dev-instance build`** wraps the blueprint build scripts; default
  re-packs the existing source VM (fast), `--rebuild` deletes and
  rebuilds from the base image. `--all` builds every blueprint in
  `blueprints/`.
- **`dev-instance create --image <ref>`** escape hatch — spin up a
  clone from any OCI image directly, no packing, no agent CLIs
  preinstalled.
- **`dev-instance new-blueprint NAME --image IMG`** scaffolds a new
  blueprint folder with a generic apt/apk/dnf-aware template.
- `need_smolvm` guard in `dev-instance` — clear install instructions
  when smolvm is missing instead of a cryptic pipeline failure.
- Linux host support documented (smolvm runs on macOS via
  Hypervisor.framework and on Linux via KVM).
- MIT `LICENSE`.

### Fixed

- `smolvm machine ls` parsing — switched to `--json` because the
  plain table truncates names at ~16 chars + `...`, which made
  `dev-instance ls` blind to clones with long auto-generated names.
- **Workspace mount collision** with smolvm's default `/workspace`
  overlay disk. Mounting the host bind on `/workspace` got shadowed
  by smolvm's ext4 overlay. Bind target moved to `~/workspace`.
- Build scripts no longer refuse to run when the source VM already
  exists; they re-pack it by default. `--rebuild` forces a clean
  rebuild from the base image.

### Removed

- Root-level `*.smolfile` recipes — moved into per-blueprint
  `blueprints/<name>/pack.smolfile`.
- `fedora-dev` blueprint — still blocked upstream by
  [smol-machines/smolvm#263](https://github.com/smol-machines/smolvm/issues/263).
  The bug-report drafts live in `wip/` for reference.
- Legacy pack-stub binaries from the repo root. Built artifacts now
  live in `dist/` (git-ignored).
