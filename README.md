# dev-instances

A toolkit for running autonomous coding agents (Claude Code, OpenAI's
Codex CLI, OpenCode, …) inside per-project ephemeral Linux VMs, without
giving them access to your host filesystem. Each sandbox clones a
prebuilt [smolvm](https://github.com/smol-machines/smolvm) blueprint in
~1 second, mounts your project at `~/workspace`, and runs as a `dev`
user whose uid/gid match the host — so file ownership stays correct
both ways.

What's in the box:

- **`dev-instance`** — the per-project lifecycle CLI: `create`, `shell`,
  `stop`, `rm`, `ls`, `build`, `new-blueprint`.
- **Three example blueprints** as starting points — `ubuntu-dev`,
  `bun-dev`, `bun-only`. Build the one(s) you'll use; the others can
  wait. (Or ignore them entirely and scaffold your own.)
- **Shared installers** in `blueprints/_install-{user,agents}.sh` that
  every blueprint — shipped *or* scaffolded — sources. They set up the
  host-uid-matching `dev` user and preinstall Claude Code + Codex CLI
  + OpenCode into `/usr/local/bin/`.
- **`dev-instance new-blueprint NAME --image IMG`** — scaffold your own
  blueprint from any OCI image (`python:3.11-slim`, `golang:1.22`,
  whatever). The scaffolded `build.sh` inherits the same dev-user +
  three-agent setup; you just add the project-specific tools.

The original itch was `claude --dangerously-skip-permissions`; the
broader goal is "any agent with shell access in a place I'm comfortable
letting it loose."

Companion repo for an upcoming talk and blog post on sandboxing agent
CLIs with smolvm. Links coming soon — feel free to clone and adapt in
the meantime.

Packed blueprints (`.smolmachine`, hundreds of MB each) aren't committed
— they rebuild quickly from the scripts in `blueprints/`. **Newcomers:
do the prereqs, build a blueprint, put `dev-instance` on your PATH,
then use it per-project.**

## Prerequisites

- **macOS or Linux host.** smolvm uses hardware virtualization —
  Hypervisor.framework on macOS, KVM (`/dev/kvm`) on Linux.
- **[smolvm](https://github.com/smol-machines/smolvm)** on your PATH:
  ```bash
  # macOS & Linux:
  curl -sSL https://smolmachines.com/install.sh | bash

  # macOS also has a brew tap:
  brew tap smol-machines/tap && brew install smolvm
  ```
  `dev-instance` checks for it before running anything that needs it; if
  it's missing you'll get a clear install hint instead of a cryptic
  pipeline failure.

## Why a VM and not devcontainers?

If you want a *dev environment* — IDE integration, team-shareable config,
"live in my container, edit in VS Code" — use devcontainers. That's not what
this is.

This targets a different problem: **a sandbox for autonomous agent CLIs
(Claude Code, Codex, OpenCode, …)**, where the priority is host-filesystem
isolation, not editor integration.

|  | devcontainer | dev-instance |
|---|---|---|
| Isolation | Linux namespaces (shared host kernel) | Hardware virtualization (separate kernel) |
| Default credential reach | Often `~/.ssh`, agent socket, or `docker.sock` mounted in | Empty — no credentials in the VM at all |
| Lifecycle | Persistent per project | Ephemeral per session; ~1s clone, ~0s discard |
| Source code | Edited inside the container | Edited on host (git stays on host too) |
| Editor integration | First-class (VS Code, JetBrains Gateway) | None — terminal-only |
| Platforms | Linux / macOS / Windows | Linux / macOS |

If you also edit the project in VS Code or JetBrains, run both — devcontainer
(or just local dev) for the IDE, `dev-instance` for letting the agent work
autonomously. Same working copy, mounted into each.

The genuinely unusual bit is the **inverted credential model**: git operations
stay on the host, only the working tree enters the sandbox. Even if the agent
inside gets prompt-injected or goes off the rails, the blast radius is the
project folder — not your GitHub account, not your other repos, not your
remote infrastructure.

## The shipped blueprints

Three Node/Bun-oriented blueprints come with the repo as examples /
starting points. None of them is the "right" blueprint for every
project — they're representative shapes. If your project needs a
different base, [scaffold one](#making-your-own-blueprint).

| Blueprint | Base | Real Node | Bun | Pack | Pick when |
|---|---|---|---|---|---|
| `ubuntu-dev` | Ubuntu 26.04 LTS | yes (Node 24) | yes | 408 MB | "Give me everything" default. Node + Bun, glibc, full apt. |
| `bun-dev` | Debian 13 (`oven/bun:slim`) | yes (Node 24) | yes | 386 MB | Bun-first projects, but keep Node as a safety net for npm CLIs that hit Node-specific APIs. |
| `bun-only` | Debian 13 (`oven/bun:slim`) | shim (`node` → `bun`) | yes | 307 MB | Strictly Bun. Saves ~80 MB. `#!/usr/bin/env node` shebangs fall back to Bun's Node-compat mode. |

All three include the three agent CLIs (Claude Code, Codex CLI,
OpenCode), git, curl, ca-certificates, unzip, build tools, and sudo
(for the `dev` user). On `dev-instance shell` you'll see an
`Available agents: claude codex opencode` banner; pick whichever you
want by typing the command.

## What's in this repo

```
dev-instances/
├── dev-instance                      # per-project sandbox CLI (bash)
├── blueprints/
│   ├── _install-user.sh              # shared: dev user + uid-matching
│   ├── _install-agents.sh            # shared: Claude + Codex + OpenCode
│   ├── ubuntu-dev/   { build.sh, pack.smolfile }
│   ├── bun-dev/      { build.sh, pack.smolfile }
│   └── bun-only/     { build.sh, pack.smolfile }
├── dist/                             # build output (git-ignored)
├── wip/                              # upstream fedora-issue drafts (smolvm#263)
├── README.md
├── CLAUDE.md                         # full reference + Claude Code project memory
├── CHANGELOG.md
└── LICENSE
```

`CLAUDE.md` is the long-form reference: per-blueprint contents, mount notes,
known limitations, security nuance. It also doubles as Claude Code's project
memory when you open this directory in a Claude session. `CHANGELOG.md`
tracks user-visible changes in Keep-a-Changelog format.

## Building a blueprint

Build the blueprint(s) you want via the CLI:

```bash
./dev-instance build              # default: bun-only
./dev-instance build bun-dev
./dev-instance build ubuntu-dev
./dev-instance build --all        # all three, ~15-30 min total
```

(`./dev-instance` from the repo dir while you set things up; once it's on
your PATH — see next section — just `dev-instance build`. The build
scripts themselves live at `blueprints/<name>/build.sh` if you want to
read or run them directly.)

Each script creates a source VM from a base image, installs everything inside
(git, build tools, Node where applicable, Bun, Claude Code, PATH config),
stops the VM, and packs it into `dist/<name>.smolmachine`. Takes 5-10 minutes
per blueprint, mostly download time. They're independent — only build the
ones you'll use.

The source VM stays in `~/Library/Caches/smolvm/vms/` after the build, so
[updating a blueprint](#updating-a-blueprint) later is fast (no rebuild from
scratch).

## Making your own blueprint

If none of the three shipped blueprints is what you want, scaffold a new one
from any OCI image:

```bash
dev-instance new-blueprint my-python --image python:3.11-slim
```

This writes `blueprints/my-python/build.sh` and `pack.smolfile`. The build
script:

- Auto-detects the package manager (`apt-get` / `apk` / `dnf` / `yum`).
- Installs `curl` + `ca-certificates`.
- Runs the native Claude Code installer (`claude.ai/install.sh`), which
  handles musl/glibc and arch detection automatically.
- Symlinks `claude` into `/usr/local/bin/` so non-login shells find it.

Open it, add anything your projects need in the marked block (Node, Bun,
Python deps, system libs…), then build and use:

```bash
dev-instance build my-python
dev-instance create my-python
```

## Putting `dev-instance` on your PATH

`dev-instance` is meant to be run from inside your project directories, not
from this repo. The script auto-detects the repo location from its own path
(following symlinks), so any of these works:

**Symlink into a PATH dir** (recommended — survives `git pull`, no shell-rc
edit needed if `~/.local/bin/` is already on your PATH):

```bash
ln -s ~/dev-instances/dev-instance ~/.local/bin/dev-instance
```

**Or add the repo to your PATH directly:**

```bash
echo 'export PATH="$HOME/dev-instances:$PATH"' >> ~/.zshrc   # or ~/.bashrc
```

**Override the repo location** if it's somewhere unusual or you have
multiple checkouts:

```bash
export DEV_INSTANCES_ROOT=~/code/forks/dev-instances
```

This wins over auto-detection. Combine with either of the above.

> **Don't `cp` the script** into a PATH dir. The script resolves the repo by
> walking back through symlinks; a plain copy points at the directory where
> the copy lives, which has no `blueprints/` or `dist/`. Use a symlink.

After any of the above, verify:

```bash
which dev-instance
dev-instance help
```

## Per-project workflow

Once at least one blueprint is built, this is the day-to-day. The default
flow keeps credentials on the host — git operations stay on the host, the VM
only sees a mounted working copy.

```bash
# 1. Clone on the host (host's git, host's SSH keys)
git clone git@github.com:you/proj-foo.git ~/code/proj-foo
cd ~/code/proj-foo

# 2. Create + start a sandbox. $PWD is mounted as ~/workspace.
#    Auto-named "proj-foo-<4 hex>". Default blueprint: bun-only.
dev-instance create
# (or: dev-instance create bun-dev / ubuntu-dev)

# 3. Drop in — bun, all three agent CLIs (claude/codex/opencode), git ready.
#    cwd is ~/workspace.
dev-instance shell

# 4. On the host: review and push at your own pace
git diff
git add -p && git commit && git push

# 5. Stop (keep overlay) or rm (reclaim disk)
dev-instance stop
dev-instance rm
```

`shell`, `stop`, `rm` auto-target the cwd's clone when exactly one matches —
no name needed. Pass `--all` to `dev-instance ls` to see every clone, not
just the ones from this dir.

### Host-matching user inside the VM

You're not root inside a blueprint clone — `dev-instance` creates a `dev`
user whose uid/gid match your host user's (passed via `HOST_UID`/`HOST_GID`
env vars and applied by `/usr/local/sbin/match-host-uid.sh` at every VM
start). The point is **bidirectional file ownership**: files you create
on the host show up as `dev`-owned in the VM, and files agents create in
`~/workspace` from inside the VM show up with *your* uid/gid on the host
— no post-session `chown` dance.

`dev` has passwordless sudo, so an agent that decides it needs
`sudo apt install foo` to finish a task can do that without prompting.

The `--image` escape hatch below doesn't have this setup — those clones
run as root in `/root/workspace` (the original behavior). The fix is
blueprint-only because the runtime user-matching script ships in the
blueprint, not in arbitrary OCI images.

### Custom OCI image (escape hatch)

If a prebuilt blueprint doesn't fit, point `dev-instance` at any OCI image
directly — no packing step:

```bash
dev-instance create --image python:3.11-slim
dev-instance shell
```

**Caveat:** `--image` mode gives you the image as-is, with **no agent CLIs
preinstalled**. Install whichever you need manually inside, or — if you'll
reuse this image — build a proper blueprint with
[`dev-instance new-blueprint`](#making-your-own-blueprint) (the scaffolded
build.sh installs all three agents by default).

## Authentication and autonomy

The blueprints ship the binaries; **credentials are bring-your-own** and
stay on the host except where you choose to pass them in. None of these
keys live in the packed `.smolmachine` — they only enter a clone if you
forward them at create time or stash them in the mounted `~/workspace`.

Per-agent env vars:

| Agent | Env var | Notes |
|---|---|---|
| Claude Code | `ANTHROPIC_API_KEY` | Or sign in via `claude` once and let it cache the session in `~/workspace`. |
| Codex CLI | `OPENAI_API_KEY` | Same shape. |
| OpenCode | depends on provider | Anthropic / OpenAI / others via `OPENCODE_*` env vars or `~/.config/opencode/config.json`. See [opencode.ai](https://opencode.ai) for the current matrix. |

Two clean ways to wire them up:

```bash
# Option 1: forward from the host shell at create time
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY OPENAI_API_KEY=$OPENAI_API_KEY \
  smolvm machine create my-proj-abcd --from ~/dev-instances/dist/bun-only.smolmachine \
    --net -v "$PWD:/home/dev/workspace" -w /home/dev/workspace \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    --init /usr/local/sbin/match-host-uid.sh \
    -e ANTHROPIC_API_KEY -e OPENAI_API_KEY
# (dev-instance create doesn't currently forward env; use raw smolvm if you
#  want this until that surface lands.)

# Option 2: keep a .env in the project, source it inside the VM
echo "ANTHROPIC_API_KEY=…" > .env       # gitignored
# inside the VM:
set -a; . ~/workspace/.env; set +a
```

**Autonomous-mode flags** vary per agent — `claude
--dangerously-skip-permissions` is the headline one; Codex and OpenCode each
have their own "yes, just go" mode (`--full-auto`-style). Check each
agent's `--help` for the current spelling. The whole point of the VM
sandbox is that whichever flag you pick, the blast radius stays inside
`~/workspace`.

## Updating a blueprint

To add a package to a blueprint you've already built (say, Python on
`bun-only`), boot the source VM that's still in smolvm's cache, install,
and re-pack:

```bash
smolvm machine start --name bun-only
smolvm machine exec --name bun-only -- \
  bash -c 'apt-get update -qq && apt-get install -y -qq python3 python3-pip'
dev-instance build bun-only      # re-packs the modified VM into dist/
```

`dev-instance build` repacks whatever's in the source VM by default, so the
final command overwrites `dist/bun-only.smolmachine` with the modified
state. Existing clones aren't affected — they keep using whatever layers
they were created from. New clones (`dev-instance create bun-only`) get
the update.

To start completely over (delete the source VM and reinstall everything
from the base image), use `dev-instance build bun-only --rebuild`.

## Security note

The filesystem sandbox is solid — nothing in the VM can read host files,
dotfiles, browser data, etc. But **`--ssh-agent` forwarding** (which
`dev-instance` deliberately doesn't expose, but raw `smolvm machine create`
does) reaches *anywhere your host SSH key reaches*: any repo, force-push,
branch-delete. The agent socket is a destructive surface that the filesystem
sandbox does not protect.

The defaults are built around this: no SSH agent in the VM, git stays on the
host, the VM only reads/writes `~/workspace`. `--net` stays on because Claude
Code needs the Anthropic API, so don't put secrets in the VM either.

Details and the "I really do need git inside the VM" exception are in
`CLAUDE.md` under *Security — credential reach*.

## Locations

- This repo: `~/dev-instances/`
- Build output: `~/dev-instances/dist/` (git-ignored)
- Source VMs (kept after build) and per-project clones: `~/Library/Caches/smolvm/vms/`
- Extracted pack layers cache: `~/Library/Caches/smolvm-pack/`
- smolvm CLI: `~/.local/bin/smolvm`

See `CLAUDE.md` for the long-form reference, including what's installed in
each blueprint, mount semantics, and known limitations.

## License

MIT — see [`LICENSE`](./LICENSE). Fork, adapt, ship your own variant. If you
use this as the basis for your own setup or talk, a link back is appreciated
but not required.
