# devinstances

Recipes for three small Linux VMs I use to run `claude --dangerously-skip-permissions`
without giving Claude access to my host filesystem. Each VM is a packed
[smolvm](https://github.com/smol-machines/smolvm) blueprint (`.smolmachine`) that can
be cloned in ~1 second for per-project, throwaway sandboxes.

The packed blobs themselves are not committed — they're hundreds of MB each
and can be rebuilt from the recipes in this repo. See *Rebuilding a blueprint*
below.

## Blueprints

| Blueprint | Base | Real Node | Bun | Pack | Pick when |
|---|---|---|---|---|---|
| `ubuntu-dev` | Ubuntu 26.04 LTS | yes (Node 24) | yes | 408 MB | "Give me everything" default. Node + Bun, glibc, full apt. |
| `bun-dev` | Debian 13 (`oven/bun:slim`) | yes (Node 24) | yes | 386 MB | Bun-first projects, but keep Node as a safety net for npm CLIs that hit Node-specific APIs. |
| `bun-only` | Debian 13 (`oven/bun:slim`) | shim (`node` → `bun`) | yes | 307 MB | Strictly Bun. Saves ~80 MB. `#!/usr/bin/env node` shebangs fall back to Bun's Node-compat mode. |

All three include: Claude Code, git, curl, ca-certificates, unzip, and build
tools for native modules.

## What's in this repo

- `*.smolfile` — TOML recipes used at pack time. Currently just `net = true`.
- `CLAUDE.md` — full reference: per-blueprint contents, build commands for
  each VM, security notes, known limitations, file locations.
- `issue-fedora-overlay*.md` — drafts for an upstream smolvm bug
  ([#263](https://github.com/smol-machines/smolvm/issues/263)) that currently
  blocks a Fedora blueprint on macOS.

The actual packed VMs (`.smolmachine`) and their standalone pack-stub binaries
are git-ignored.

## Per-project workflow

The default flow keeps credentials on the host. Git operations stay on the
host; the VM only sees a mounted working copy.

```bash
# 1. Clone on the host (host's git, host's SSH keys)
git clone git@github.com:you/proj-foo.git ~/code/proj-foo

# 2. Spin up a VM clone with the working copy mounted as /workspace
smolvm machine create proj-foo \
  --from ~/devinstances/bun-only.smolmachine \
  --net \
  -v ~/code/proj-foo:/workspace \
  -w /workspace

smolvm machine start --name proj-foo

# 3. Drop in — bun, claude, git all ready, cwd is /workspace
smolvm machine exec --name proj-foo -it -- bash -l

# 4. On the host: review and push at your own pace
cd ~/code/proj-foo
git diff
git add -p && git commit && git push

# 5. Stop (keep overlay) or delete (reclaim disk)
smolvm machine stop --name proj-foo
smolvm machine delete proj-foo -f
```

Swap `bun-only.smolmachine` for `bun-dev.smolmachine` or
`ubuntu-dev.smolmachine` based on the table above.

## Security note

The filesystem sandbox is solid — nothing in the VM can read host files,
dotfiles, browser data, etc. But forwarding `--ssh-agent` into the VM
reaches *anywhere your host SSH key reaches*: any repo, force-push,
branch-delete. The agent socket is a destructive surface that the
filesystem sandbox does not protect.

So: **no `--ssh-agent` by default**, git operations stay on the host, the
VM only reads/writes files in the mounted `/workspace`. `--net` stays on
because Claude Code needs the Anthropic API — don't put secrets in the VM
either. For details and exceptions, see `CLAUDE.md`.

## Rebuilding a blueprint

The packed `.smolmachine` files aren't tracked. To recreate one from
scratch, follow the relevant *How the blueprints were built* section in
`CLAUDE.md` — each blueprint has its full build script (apt installs, Node
setup, Bun install, Claude Code install, `smolvm pack create` invocation).

To update an existing blueprint (e.g., add a package), boot the source VM,
install, stop, and re-pack:

```bash
smolvm machine start --name bun-only
smolvm machine exec --name bun-only -- bash -c \
  'apt-get update -qq && apt-get install -y -qq python3'
smolvm machine stop --name bun-only
smolvm pack create --from-vm bun-only \
  -s ~/devinstances/bun-only.smolfile \
  -o ~/devinstances/bun-only
```

## Locations

- Blueprint files (this repo): `~/devinstances/`
- Source VMs and clones: `~/Library/Caches/smolvm/vms/`
- Extracted pack layers cache: `~/Library/Caches/smolvm-pack/`
- smolvm CLI: `~/.local/bin/smolvm`

See `CLAUDE.md` for the long-form reference.
