# dev-instance — smolvm blueprints for Bun/TypeScript + Claude Code

Three packed smolvm VMs (`.smolmachine`) preloaded with the tooling needed to
spin up per-project isolated sandboxes in ~1 second each. Primary motivation:
run `claude --dangerously-skip-permissions` without giving it access to the
host filesystem.

## Picking a blueprint

| Blueprint | Base | Real Node | Bun | Pack | Pick when |
|---|---|---|---|---|---|
| `ubuntu-dev` | Ubuntu 26.04 LTS | ✓ Node 24 | ✓ | 408 MB | You want the "give me everything" default. Node + Bun side-by-side, glibc, full apt ecosystem. |
| `bun-dev` | Debian 13 (`oven/bun:slim`) | ✓ Node 24 | ✓ | 386 MB | Bun-first project, but keep Node as a safety net for npm CLIs that rely on Node-specific APIs. |
| `bun-only` | Debian 13 (`oven/bun:slim`) | — (`node→bun` shim) | ✓ | 307 MB | Strictly Bun, no real Node. Saves ~80 MB. `#!/usr/bin/env node` shebangs fall back to Bun's Node-compat mode — works for most things, may surprise on N-API native modules. |

All three include: Claude Code 2.1.140, git, curl, ca-certificates, unzip, and
build tools for native npm/Bun modules. SSH agent forwarding into the clone
is supported via `--ssh-agent` (see *Security — credential reach* below).

## Files in this directory

| File | Size | What |
|---|---|---|
| `ubuntu-dev.smolmachine` | ~408 MB | Ubuntu blueprint. zstd archive containing the agent rootfs, base image layer, and the installed-deps overlay. |
| `bun-dev.smolmachine` | ~386 MB | Debian + Bun + Node 24 blueprint. |
| `bun-only.smolmachine` | ~307 MB | Debian + Bun (no real Node) blueprint. |
| `*.smolfile` | 11 B each | TOML recipe used at pack time. Currently just `net = true`, which bakes outbound networking into the artifact. Kept so you can edit and re-pack without remembering what to set. |
| `ubuntu-dev`, `bun-dev`, `bun-only` (no ext) | ~33 MB each | Standalone pack-stub binaries. Optional — only useful for distributing a VM to a machine without smolvm installed. Needs `brew install libepoxy virglrenderer` to actually run (and virglrenderer isn't in Homebrew core). Safe to delete. |
| `fedora-dev.smolfile` | 11 B | Recipe for the **broken** Fedora blueprint — kept while waiting on [smol-machines/smolvm#263](https://github.com/smol-machines/smolvm/issues/263). The `fedora-dev` source VM is also kept; the `.smolmachine` is not (extraction is broken on macOS). |
| `issue-fedora-overlay*.md` | small | Drafted GitHub issue + comment for #263. Keep until the bug is fixed. |
| `CLAUDE.md` | — | This file. |

## Per-project workflow

The default flow: clone on the host, mount the working copy into the VM, do
all editing/building/running inside, do all git operations on the host. No
credentials ever cross into the VM.

```bash
# 1. Clone on the host (host's git, host's SSH keys, never enters the VM)
git clone git@github.com:you/proj-foo.git ~/code/proj-foo

# 2. Spin up a clone with the working copy mounted as /workspace
#    (~25 ms create + ~750 ms start once layers are cached;
#    ~13 s on the very first clone after a fresh boot — one-time layer extraction)
smolvm machine create proj-foo \
  --from ~/devinstances/bun-only.smolmachine \
  --net \
  -v ~/code/proj-foo:/workspace \
  -w /workspace

smolvm machine start --name proj-foo

# 3. Drop into the VM — bun, claude, git all ready, cwd is /workspace
smolvm machine exec --name proj-foo -it -- bash -l

# 4. On the host: review and push at your own pace
cd ~/code/proj-foo
git status              # everything the VM changed is right here
git diff
git add -p
git commit
git push

# 5. Stop (keep overlay for next session) or delete (reclaim disk)
smolvm machine stop --name proj-foo
smolvm machine delete proj-foo -f
```

Swap `bun-only.smolmachine` for `bun-dev.smolmachine` or `ubuntu-dev.smolmachine`
based on the table above.

A few practical notes on the mount:

- Files the VM creates inside `/workspace` show up on the host immediately,
  in the same directory. No `machine cp` round-trip.
- The VM runs as root, so files written from inside will be owned by root
  on Linux hosts (on macOS / APFS the mapping is more forgiving). If you
  need host-uid ownership, `chown -R $(id -u):$(id -g) ~/code/proj-foo`
  after the session.
- Anything *outside* `/workspace` stays in the per-clone overlay and is
  thrown away on `machine delete`. Good for ephemeral build caches and
  experiments; bad for anything you want to keep.

## Security — credential reach

The filesystem sandbox is solid: nothing inside the VM can read the host's
files, dotfiles, browser data, etc. **But credentials you forward into the
clone reach as far as your credentials reach.**

In particular, `--ssh-agent` forwards your host's SSH agent into the VM
without putting any keys in the VM filesystem. From inside the clone, that
means anything (including a misbehaving Claude run with
`--dangerously-skip-permissions`) can `git push --force`, delete remote
branches, or push to *any* repo your host key has access to. The agent is a
network-reachable destructive surface that the filesystem sandbox does not
protect. "Keys never enter the VM" is true and irrelevant once the agent
socket is reachable.

The default workflow above is built around this:

- **No `--ssh-agent` by default.** The VM has no credentials to GitHub at all.
- **Git operations happen on the host.** `git clone`, `git push`, branch
  management — all stay on the host where you can see them. The VM only
  reads/writes files in the mounted `/workspace`.
- **`--net` stays on** because Claude Code needs to reach the Anthropic API.
  This means anything in the VM still has internet egress, so don't put
  secrets in the VM either — environment variables, `.env` files, etc.
  travel with the working copy via the mount.

If you have a session where you genuinely need git inside the VM (e.g.,
sub-modules updated by a build script), use HTTPS + a fine-grained PAT
scoped to just the repo(s) you're working on, and consider adding
`--allow-host github.com --allow-host api.github.com` so the network can
only reach GitHub — that way even a leaked PAT can't be exfiltrated
elsewhere.

The blueprints themselves keep `git` installed (it's the *binary* that's
fine — it's the *credentials* that are the risk).

## What's inside each blueprint

| Tool | ubuntu-dev | bun-dev | bun-only |
|---|---|---|---|
| OS | Ubuntu 26.04 | Debian 13 (trixie) | Debian 13 (trixie) |
| Node.js | 24.15 (NodeSource) | 24.15 (NodeSource) | — (`/usr/local/bun-node-fallback-bin/node → bun`) |
| npm | 11.12 | 11.12 | — (use `bun add` / `bun install`) |
| Bun | 1.3.13 | 1.3.14 | 1.3.14 |
| Claude Code | 2.1.140 (via npm `-g`) | 2.1.140 (via npm `-g`) | 2.1.140 (native ELF binary via `bun add -g`) |
| git | 2.53 | 2.47 | 2.47 |
| build-essential / curl / unzip / ca-certificates / gnupg | ✓ | ✓ | ✓ |

Run `claude --version` etc. inside a clone to confirm exact versions on the
current blueprint.

`/etc/profile.d/bun.sh` puts `/root/.bun/bin` (and on `bun-only` also
`/usr/local/bun-node-fallback-bin`) on PATH for login shells.

## How the blueprints were built

Each blueprint has a stopped source VM kept in `~/Library/Caches/smolvm/vms/`
(visible via `smolvm machine ls`). The files in *this* directory are derived
from those source VMs. Source VM names: `devbase` (Ubuntu), `bun-dev`, `bun-only`.

### ubuntu-dev (source VM: `devbase`)

```bash
smolvm machine create devbase --image ubuntu:26.04 --net --ssh-agent
smolvm machine start --name devbase

smolvm machine exec --name devbase -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq git curl unzip ca-certificates gnupg build-essential

# Node 24 via NodeSource
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update -qq
apt-get install -y -qq nodejs

# Claude Code
npm install -g @anthropic-ai/claude-code

# Bun
curl -fsSL https://bun.sh/install | bash
cat > /etc/profile.d/bun.sh <<EOF
export PATH=/root/.bun/bin:\$PATH
EOF
chmod +x /etc/profile.d/bun.sh
'

smolvm machine stop --name devbase
smolvm pack create --from-vm devbase \
  -s ~/devinstances/ubuntu-dev.smolfile \
  -o ~/devinstances/ubuntu-dev
```

### bun-dev (source VM: `bun-dev`)

Same recipe, but starting from `oven/bun:slim`. Bun is preinstalled in the
base; add Node and everything else.

```bash
smolvm machine create bun-dev --image oven/bun:slim --net --ssh-agent
smolvm machine start --name bun-dev

smolvm machine exec --name bun-dev -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git curl unzip ca-certificates gnupg build-essential

# Node 24 via NodeSource
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.key
gpg --dearmor < /tmp/nodesource.key > /etc/apt/keyrings/nodesource.gpg
cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main
EOF
apt-get update -qq
apt-get install -y -qq nodejs

# Claude Code
npm install -g @anthropic-ai/claude-code
'

smolvm machine stop --name bun-dev
smolvm pack create --from-vm bun-dev \
  -s ~/devinstances/bun-dev.smolfile \
  -o ~/devinstances/bun-dev
```

### bun-only (source VM: `bun-only`)

No NodeSource. Claude Code is installed via Bun, but with two manual
post-steps because `bun add -g` doesn't run postinstall scripts by default
and doesn't always create the `/root/.bun/bin/` symlinks.

```bash
smolvm machine create bun-only --image oven/bun:slim --net --ssh-agent
smolvm machine start --name bun-only

smolvm machine exec --name bun-only -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git curl unzip ca-certificates gnupg build-essential

# Claude Code via Bun — pulls the native @anthropic-ai/claude-code-linux-{arch} binary
bun add -g @anthropic-ai/claude-code

# Manually run the postinstall (which copies the right native binary into
# bin/claude.exe inside the wrapper package). Uses the bun-node-fallback as `node`.
CLAUDE_PKG=/root/.bun/install/global/node_modules/@anthropic-ai/claude-code
(cd "$CLAUDE_PKG" && node install.cjs)

# Bun did not create /root/.bun/bin/ — make it and the symlinks ourselves.
mkdir -p /root/.bun/bin
ln -sf "$CLAUDE_PKG/bin/claude.exe" /root/.bun/bin/claude
ln -sf /root/.bun/bin/claude /usr/local/bin/claude

# PATH: bun bin first, then the node→bun fallback so `#!/usr/bin/env node` works
cat > /etc/profile.d/bun.sh <<EOF
export PATH=/root/.bun/bin:/usr/local/bun-node-fallback-bin:\$PATH
EOF
chmod +x /etc/profile.d/bun.sh
'

smolvm machine stop --name bun-only
smolvm pack create --from-vm bun-only \
  -s ~/devinstances/bun-only.smolfile \
  -o ~/devinstances/bun-only
```

## Updating a blueprint

Example — add Python to `bun-only`:

```bash
smolvm machine start --name bun-only
smolvm machine exec --name bun-only -- bash -c 'apt-get update -qq && apt-get install -y -qq python3 python3-pip'
smolvm machine stop --name bun-only
smolvm pack create --from-vm bun-only \
  -s ~/devinstances/bun-only.smolfile \
  -o ~/devinstances/bun-only
```

This overwrites `bun-only.smolmachine` (and its stub) in place. Existing
clones aren't affected — they keep using the layers they were created from.
New clones use the new blueprint.

If a source VM is gone, recreate it from the relevant **How the blueprints
were built** subsection above.

## Distros and trade-offs

- **Fedora is currently blocked.** First by [#256](https://github.com/smol-machines/smolvm/issues/256)
  (fixed in 0.6.3), now by [#263](https://github.com/smol-machines/smolvm/issues/263)
  — overlay tars produced after any `dnf install` contain
  OverlayFS char-device whiteouts that the macOS pack extractor can't
  recreate as a non-root user. A no-op Fedora pack extracts fine, but any
  package changes make it unextractable. `fedora-dev` source VM and
  `fedora-dev.smolfile` are kept for re-packing once #263 lands.
- **Alpine works** and produces a smaller pack (~150–200 MB), but
  musl-vs-glibc occasionally makes `npm install` of random native modules
  compile from source. glibc (Ubuntu / Debian) just works for arbitrary Node
  ecosystem deps.
- **Debian (oven/bun:slim) vs Ubuntu.** Debian slim is smaller and ships
  the right Bun version preinstalled. Ubuntu 26.04 LTS has a larger base
  but uses LTS-stable kernel headers and a more familiar apt ecosystem.

## Known limitations

- **No daemon mode inside clones.** smolvm currently can't run a long-lived
  service (like sshd) inside a `machine create`-style persistent VM —
  processes started by `--init` are reaped when init exits, and
  `machine exec --stream` runs in a separate namespace from the VM proper.
  Implication: VS Code Remote-SSH / JetBrains Gateway into clones is not
  possible today. Interact via `smolvm machine exec -it` instead.
- **`bun add -g` skips postinstalls.** Bun does not run package
  `postinstall` scripts by default (security). Some packages (including
  `@anthropic-ai/claude-code`) rely on postinstall to put the right native
  binary in place. The `bun-only` build script does this manually after
  `bun add -g`. Bun also did not auto-create `/root/.bun/bin/` for the
  Claude Code install — the build script also handles that.
- **Per-clone overlay disk: ~430 MB.** Each clone takes a copy-on-write
  overlay. Use `smolvm machine ls` to see active overlays;
  `smolvm machine delete <name> -f` reclaims disk.
- **First clone of the session is slow.** ~13 s on the first
  `machine create --from` after a fresh boot — one-time layer extraction
  into smolvm's cache. After that, clones are ~25 ms create + ~750 ms start.
- **Pack stub needs `libepoxy` + `libvirglrenderer` to run.** Not needed for
  the standard `machine create --from` workflow — the stub is only relevant
  if you want to ship the VM to a machine without smolvm.

## Locations

- Blueprint files: `~/devinstances/` (this directory)
- Source VMs and clones: `~/Library/Caches/smolvm/vms/`
- Extracted pack layers cache: `~/Library/Caches/smolvm-pack/`
- smolvm bundled libs: `~/.smolvm/lib/`
- smolvm CLI: `~/.local/bin/smolvm` (bash wrapper) → `~/.smolvm/smolvm`
