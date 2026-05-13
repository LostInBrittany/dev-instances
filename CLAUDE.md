# dev-instances — smolvm blueprints for autonomous agent CLIs

Recipes for three smolvm VM blueprints, plus a small `dev-instance` CLI that
spins up per-project isolated sandboxes in ~1 second each. Each blueprint
ships **three agent CLIs** preinstalled — Claude Code, OpenAI's Codex CLI,
and OpenCode — so the sandbox is agent-agnostic. The original motivation
was `claude --dangerously-skip-permissions`; the broader goal is "any
autonomous agent with shell access, in a place I'm comfortable letting it
loose."

The blueprints are *built* locally from the recipes in this repo — they're
not committed (hundreds of MB each). The `dev-instance` tool then creates
ephemeral, per-session clones from those blueprints (or directly from any
OCI image). Runs on macOS (via Hypervisor.framework) and Linux (via KVM,
needs `/dev/kvm`).

This file doubles as project documentation and as Claude Code's project
memory when you open this directory in a Claude session, so it errs on the
side of verbose.

## Picking a blueprint

| Blueprint | Base | Real Node | Bun | Pack | Pick when |
|---|---|---|---|---|---|
| `ubuntu-dev` | Ubuntu 26.04 LTS | ✓ Node 24 | ✓ | 408 MB | You want the "give me everything" default. Node + Bun side-by-side, glibc, full apt ecosystem. |
| `bun-dev` | Debian 13 (`oven/bun:slim`) | ✓ Node 24 | ✓ | 386 MB | Bun-first project, but keep Node as a safety net for npm CLIs that rely on Node-specific APIs. |
| `bun-only` | Debian 13 (`oven/bun:slim`) | — (`node→bun` shim) | ✓ | 307 MB | Strictly Bun, no real Node. Saves ~80 MB. `#!/usr/bin/env node` shebangs fall back to Bun's Node-compat mode — works for most things, may surprise on N-API native modules. |

All three include: **agent CLIs** (Claude Code via `claude.ai/install.sh`,
Codex via the prebuilt musl binary from `openai/codex` GH Releases,
OpenCode via `opencode.ai/install` — all symlinked into `/usr/local/bin`
by the shared `blueprints/_install-agents.sh`), git, curl, ca-certificates,
unzip, and build tools for native npm/Bun modules.

The `dev-instance` tool doesn't forward SSH agent or any other credentials
into clones by default (see *Security — credential reach* below). For
one-off use cases that genuinely need it, drop to raw `smolvm machine create
… --ssh-agent` and own the risk.

## What's in this repo

### Tracked

| Path | What |
|---|---|
| `README.md` | Tour and quickstart aimed at someone who just cloned the repo. |
| `CLAUDE.md` | This file — full reference. |
| `dev-instance` | Bash CLI: `create`, `shell`, `stop`, `rm`, `ls`, `build`, `new-blueprint`. Per-project sandbox lifecycle on top of smolvm, plus blueprint build + scaffolding. |
| `blueprints/<name>/build.sh` | One-shot build script per blueprint. Creates the source VM from a base image, installs distro-specific tooling, sources `_install-agents.sh` for the three agent CLIs, stops the VM, and packs it into `dist/<name>.smolmachine`. |
| `blueprints/<name>/pack.smolfile` | TOML config consumed by `smolvm pack create -s`. Currently just `net = true` (bakes outbound networking into the packed artifact). Required — `pack create` has no `--net` flag. |
| `blueprints/_install-agents.sh` | Shared installer (piped into the VM via `bash -s`) that installs Claude Code + Codex + OpenCode and writes `/etc/profile.d/agents-banner.sh`. One file, edited once, picked up by every blueprint. |
| `wip/issue-fedora-overlay*.md` | Bug report and follow-up comment filed upstream as [smol-machines/smolvm#263](https://github.com/smol-machines/smolvm/issues/263). Kept as reference until the fix lands — no Fedora blueprint until then. |
| `LICENSE` | MIT. |
| `.gitignore` | Excludes `dist/` plus any stray `.smolmachine` and legacy pack-stub binaries at the repo root. |

### Built locally (git-ignored)

Produced by the build scripts; sit in `dist/`:

| File | Size | What |
|---|---|---|
| `dist/<name>.smolmachine` | ~300-410 MB | The packed blueprint. Consumed by `dev-instance create` / `smolvm machine create --from`. |
| `dist/<name>` (no ext) | ~33 MB | Standalone pack-stub binary from `smolvm pack create`. Only useful for distributing a VM to a machine without smolvm installed (needs `libepoxy` + `libvirglrenderer` to actually run, and `libvirglrenderer` isn't in Homebrew core). Safe to delete in the normal workflow. |

## Per-project workflow

`dev-instance` handles the per-project lifecycle. Default flow: clone on
the host, `dev-instance create` mounts the working copy into a fresh VM,
edit/build/run inside, do all git operations on the host. No credentials
ever cross into the VM.

```bash
# 1. Clone on the host (host's git, host's SSH keys, never enters the VM)
git clone git@github.com:you/proj-foo.git ~/code/proj-foo
cd ~/code/proj-foo

# 2. Create + start a sandbox (default blueprint: bun-only). $PWD is mounted
#    as ~/workspace. Clone is auto-named "proj-foo-<4 hex>" and printed.
dev-instance create

# 3. Drop in — bun, claude, git all ready, cwd is ~/workspace
dev-instance shell

# 4. On the host: review and push at your own pace
git diff
git add -p && git commit && git push

# 5. Stop (keep overlay for next session) or rm (reclaim disk)
dev-instance stop
dev-instance rm
```

`shell`/`stop`/`rm` auto-target the cwd's clone when exactly one matches.
Pass an explicit name if you've created several. `dev-instance ls` shows
clones for the current dir; `dev-instance ls --all` shows everything.

Pick a different blueprint with `dev-instance create bun-dev` /
`ubuntu-dev`.

### Custom OCI image (escape hatch)

If a prebuilt blueprint doesn't fit, point `dev-instance` at any OCI image
directly — no packing step, just `smolvm machine create --image` under the
hood:

```bash
dev-instance create --image python:3.11-slim
dev-instance shell
```

No Claude Code preinstalled in this mode; you install whatever you need
inside, or build a proper blueprint if it's something you'll reuse. Same
lifecycle as blueprint-mode (`shell` / `stop` / `rm`).

### Mount notes

- Files the VM creates inside `~/workspace` show up on the host immediately,
  in the same directory. No `machine cp` round-trip.
- The VM runs as root, so files written from inside will be owned by root
  on Linux hosts (on macOS / APFS the mapping is more forgiving). If you
  need host-uid ownership, `chown -R $(id -u):$(id -g) ~/code/proj-foo`
  after the session.
- Anything *outside* `~/workspace` stays in the per-clone overlay and is
  thrown away on `dev-instance rm`. Good for ephemeral build caches and
  experiments; bad for anything you want to keep.

## Security — credential reach

The filesystem sandbox is solid: nothing inside the VM can read the host's
files, dotfiles, browser data, etc. **But credentials you forward into the
clone reach as far as your credentials reach.**

In particular, `--ssh-agent` (if you ever pass it to raw `smolvm machine
create`) forwards your host's SSH agent into the VM without putting any
keys in the VM filesystem. From inside the clone, that means anything
(including a misbehaving Claude run with `--dangerously-skip-permissions`)
can `git push --force`, delete remote branches, or push to *any* repo your
host key has access to. The agent is a network-reachable destructive
surface that the filesystem sandbox does not protect. "Keys never enter
the VM" is true and irrelevant once the agent socket is reachable.

`dev-instance` is built around this:

- **No `--ssh-agent`, ever.** The tool deliberately does not expose the
  flag. The VM has no credentials to GitHub at all.
- **Git operations happen on the host.** `git clone`, `git push`, branch
  management — all stay on the host where you can see them. The VM only
  reads/writes files in the mounted `~/workspace`.
- **`--net` stays on** because Claude Code needs to reach the Anthropic
  API. This means anything in the VM still has internet egress, so don't
  put secrets in the VM either — environment variables, `.env` files,
  etc. travel with the working copy via the mount.

If you have a session where you genuinely need git inside the VM (e.g.,
sub-modules updated by a build script), drop to raw smolvm: use HTTPS +
a fine-grained PAT scoped to just the repo(s) you're working on, and
consider adding `--allow-host github.com --allow-host api.github.com` so
the network can only reach GitHub — that way even a leaked PAT can't be
exfiltrated elsewhere.

The blueprints themselves keep `git` installed (it's the *binary* that's
fine — it's the *credentials* that are the risk).

## Authentication and autonomy

Agent CLIs ship in the blueprint; **credentials are bring-your-own**.
No API keys live in the packed `.smolmachine` — keys only enter a clone
if you forward them at create time or stash them in the mounted
`~/workspace`.

Per-agent env vars:

- **Claude Code** — `ANTHROPIC_API_KEY`, or sign in once with `claude` and
  let it cache the session under `~/workspace/.claude/` (anything outside
  `~/workspace` is thrown away on `dev-instance rm`).
- **Codex CLI** — `OPENAI_API_KEY`.
- **OpenCode** — provider-dependent; OpenCode supports multiple LLM
  providers via env vars and/or `~/.config/opencode/config.json`. See
  [opencode.ai](https://opencode.ai) for the current matrix.

Two common patterns:

1. **Forward from host at create time** — drop to raw smolvm for now
   (`dev-instance create` doesn't expose env-passthrough yet):
   ```bash
   smolvm machine create my-proj-abcd \
     --from ~/dev-instances/dist/bun-only.smolmachine --net \
     -v "$PWD:/root/workspace" -w /root/workspace \
     -e ANTHROPIC_API_KEY -e OPENAI_API_KEY
   ```
2. **Keep a `.env` in the project** — gitignored, mounted via `~/workspace`,
   sourced inside the VM:
   ```bash
   set -a; . ~/workspace/.env; set +a
   ```

**Autonomous-mode flag per agent** — the names vary:
- Claude Code: `claude --dangerously-skip-permissions`
- Codex CLI: `--full-auto`-style flags (check `codex --help`)
- OpenCode: same idea, agent-specific (check `opencode --help`)

Whichever you pick, the VM sandbox is the safety net: even if the agent
goes off the rails, the blast radius is `~/workspace` plus the per-clone
overlay (discarded on `dev-instance rm`).

## What's inside each blueprint

| Tool | ubuntu-dev | bun-dev | bun-only |
|---|---|---|---|
| OS | Ubuntu 26.04 | Debian 13 (trixie) | Debian 13 (trixie) |
| Node.js | 24.15 (NodeSource) | 24.15 (NodeSource) | — (`/usr/local/bun-node-fallback-bin/node → bun`) |
| npm | 11.12 | 11.12 | — (use `bun add` / `bun install`) |
| Bun | 1.3.13 | 1.3.14 | 1.3.14 |
| Claude Code | native installer (`claude.ai/install.sh`) | native installer | native installer |
| Codex CLI | prebuilt musl binary (`openai/codex` GH Releases, latest) | prebuilt musl binary | prebuilt musl binary |
| OpenCode | `opencode.ai/install` (Node-based) | `opencode.ai/install` | `opencode.ai/install` |
| git | 2.53 | 2.47 | 2.47 |
| build-essential / curl / unzip / ca-certificates / gnupg | ✓ | ✓ | ✓ |

All three agents are symlinked or installed into `/usr/local/bin/`, so a
non-login `smolvm machine exec` finds them without sourcing any profile.
Run `claude --version` / `codex --version` / `opencode --version` inside
a clone to confirm exact versions.

`/etc/profile.d/bun.sh` puts `/root/.bun/bin` (and on `bun-only` also
`/usr/local/bun-node-fallback-bin`) on PATH for login shells.
`/etc/profile.d/agents-banner.sh` prints the "Available agents: …" line
when you `dev-instance shell` into a clone.

## Building a blueprint

Each blueprint has a self-contained build script at
`blueprints/<name>/build.sh`. Each script:

1. Refuses to run if a source VM of the same name already exists (the
   error message tells you to either `smolvm machine delete <name> -f`
   for a clean rebuild, or to update in place — see next section).
2. `smolvm machine create <name> --image <base> --net`.
3. `smolvm machine exec` to install everything inside.
4. `smolvm machine stop`.
5. `smolvm pack create --from-vm <name> -s blueprints/<name>/pack.smolfile
   -o dist/<name>` — writes `dist/<name>.smolmachine` (and a stub binary).

Takes 5-10 minutes per blueprint, mostly download time. No `--ssh-agent`
needed — installs only fetch over HTTPS.

Run via the CLI:

```bash
dev-instance build              # default: bun-only
dev-instance build bun-dev
dev-instance build ubuntu-dev
dev-instance build --all        # iterates over all blueprints/*/build.sh
```

The scripts at `blueprints/<name>/build.sh` are also directly executable
if you'd rather skip the wrapper.

The source VMs stay in `~/Library/Caches/smolvm/vms/` after the build —
that's what makes incremental updates possible.

## Updating a blueprint

The source VM is reusable. To add a package — say, Python on `bun-only`:

```bash
smolvm machine start --name bun-only
smolvm machine exec --name bun-only -- \
  bash -c 'apt-get update -qq && apt-get install -y -qq python3 python3-pip'
dev-instance build bun-only      # re-packs the modified VM into dist/
```

`dev-instance build` (without `--rebuild`) repacks whatever's currently
in the source VM, so it overwrites `dist/bun-only.smolmachine` with the
modified state. Existing per-project clones aren't affected — they keep
using the layers they were created from. New clones (`dev-instance
create bun-only`) use the updated blueprint.

To rebuild from scratch (delete the source VM and reinstall everything
from the base image), pass `--rebuild`:

```bash
dev-instance build bun-only --rebuild
```

## Making your own blueprint

If none of the three shipped blueprints fits, scaffold a new one:

```bash
dev-instance new-blueprint my-python --image python:3.11-slim
```

This writes `blueprints/my-python/build.sh` and `pack.smolfile`. The
generated `build.sh` does package-manager autodetect (apt / apk / dnf /
yum), installs `curl` + `ca-certificates`, runs the native Claude Code
installer, and symlinks the binary into `/usr/local/bin`. Add tools your
projects need (Node, Bun, Python libs, etc.) in the marked block, then
run the script and `dev-instance create my-python`.

The scaffolder is dumb on purpose — it doesn't try to detect what's
already in the image. For images that already ship Node or Bun (like
`oven/bun:slim`), the apt-get install of `curl ca-certificates` is a
no-op, so you don't have to remove anything; just add your installs.

Naming: `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`. The scaffolder refuses to
overwrite an existing `blueprints/<name>/`.

## Distros and trade-offs

- **Fedora is currently blocked.** First by [#256](https://github.com/smol-machines/smolvm/issues/256)
  (fixed in 0.6.3), now by [#263](https://github.com/smol-machines/smolvm/issues/263)
  — overlay tars produced after any `dnf install` contain OverlayFS
  char-device whiteouts that the macOS pack extractor can't recreate as a
  non-root user. A no-op Fedora pack extracts fine, but any package
  changes make it unextractable. No Fedora blueprint is shipped here
  until #263 lands; the bug reports are in `wip/`.
- **Alpine works** and produces a smaller pack (~150–200 MB), but
  musl-vs-glibc occasionally makes `npm install` of random native modules
  compile from source. glibc (Ubuntu / Debian) just works for arbitrary
  Node ecosystem deps. If you need Alpine, use `dev-instance create
  --image alpine:latest` for a one-off.
- **Debian (oven/bun:slim) vs Ubuntu.** Debian slim is smaller and ships
  the right Bun version preinstalled. Ubuntu 26.04 LTS has a larger base
  but uses LTS-stable kernel headers and a more familiar apt ecosystem.

## Known limitations

- **Don't mount on `/workspace`.** smolvm mounts a per-machine ext4
  overlay disk at `/workspace` by default, *after* applying user `-v`
  binds. Mounting the host dir on `/workspace` therefore gets shadowed
  by the overlay (the virtiofs mount is still there underneath, but
  invisible). Confirmed by `mount` inside a clone: `smolvm0 on
  /workspace type virtiofs` followed by `/dev/vda on /workspace type
  ext4`. We mount under `~/workspace` (= `/root/workspace`, since the
  VM runs as root) to dodge the collision. If smolvm ever stops
  claiming `/workspace`, we can switch back.
- **No daemon mode inside clones.** smolvm currently can't run a
  long-lived service (like sshd) inside a `machine create`-style
  persistent VM — processes started by `--init` are reaped when init
  exits, and `machine exec --stream` runs in a separate namespace from
  the VM proper. Implication: VS Code Remote-SSH / JetBrains Gateway
  into clones is not possible today. Interact via `dev-instance shell`
  (which wraps `smolvm machine exec -it`).
- **Native Claude installer drops the binary under `$HOME`.** The exact
  path is `claude install`'s decision and may shift between versions.
  All three build scripts probe common locations (`/root/.local/bin`,
  `/root/.claude/...`) and fall back to a depth-limited `find`, then
  symlink the result into `/usr/local/bin/claude` so non-login
  `smolvm machine exec` sessions can find it. If the installer ever
  starts dropping the binary somewhere truly unexpected, that probe is
  the first thing to update.
- **Per-clone overlay disk: ~430 MB.** Each clone takes a copy-on-write
  overlay. Use `dev-instance ls --all` to see active overlays;
  `dev-instance rm <name>` reclaims disk.
- **First clone of the session is slow.** ~13 s on the first
  `dev-instance create` after a fresh boot — one-time layer extraction
  into smolvm's cache. After that, clones are ~25 ms create + ~750 ms
  start.
- **Pack stub needs `libepoxy` + `libvirglrenderer` to run.** Not needed
  for the standard `dev-instance create` workflow — the stub is only
  relevant if you want to ship the VM to a machine without smolvm.

## Locations

Paths below are for macOS; on Linux, smolvm follows XDG conventions
(typically `~/.cache/smolvm/` instead of `~/Library/Caches/smolvm/`).
`smolvm machine ls` is the source of truth either way.

- This repo: `~/dev-instances/`
- Build output: `~/dev-instances/dist/` (git-ignored)
- Source VMs (kept after build for incremental updates) and per-project
  clones: `~/Library/Caches/smolvm/vms/`
- Extracted pack layers cache: `~/Library/Caches/smolvm-pack/`
- smolvm bundled libs: `~/.smolvm/lib/`
- smolvm CLI: `~/.local/bin/smolvm` (bash wrapper) → `~/.smolvm/smolvm`
