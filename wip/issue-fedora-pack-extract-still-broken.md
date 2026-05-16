# Fedora packs containing real `dnf install` content still fail to extract on macOS (continuation of #263)

**Filed upstream as
[smolvm#278](https://github.com/smol-machines/smolvm/issues/278).**

Filed as a new issue since #263 is closed; this is the same shape of bug for a case the 0.7.0 fix didn't catch.

## Summary

On **smolvm 0.7.0 / macOS 26.4.1 (Apple Silicon M4)**, Fedora packs whose overlay contains real `dnf install` output (i.e. anything beyond a no-op transaction) still fail at `machine create --from` time:

```
Error: agent operation failed: extract sidecar:
  failed to unpack `/Users/horacio/Library/Caches/smolvm-pack/<hash>/overlay.raw`
```

Pack creation itself succeeds — the failure is on the host side when extracting the sidecar.

## Reproducer

```bash
# Build a Fedora pack with a real dnf install (this is what a typical
# blueprint workflow does — installing git pulls dependencies and
# upgrades base libs to satisfy them).
smolvm machine create fc-src --image fedora:44 --net
smolvm machine start --name fc-src
smolvm machine exec --name fc-src -- bash -c '
    set -e
    dnf install -y --setopt=install_weak_deps=False \
        git curl unzip ca-certificates sudo
    curl -fsSL https://rpm.nodesource.com/setup_24.x | bash -
    dnf install -y --setopt=install_weak_deps=False nodejs
    curl -fsSL https://bun.sh/install | bash
'
smolvm machine stop --name fc-src

echo "net = true" > pack.smolfile
smolvm pack create --from-vm fc-src -s pack.smolfile -o fc-pack
# pack create succeeds: 414 MB .smolmachine, "Signed successfully"
smolvm machine delete fc-src -f

smolvm machine create fc-clone --from fc-pack.smolmachine --net
# Error: agent operation failed: extract sidecar:
#   failed to unpack `/Users/horacio/Library/Caches/smolvm-pack/<hash>/overlay.raw`
```

## What works in 0.7.0

A Fedora pack with **no real overlay changes** (e.g. `dnf install` of a package that's already present in the base image — a no-op transaction) extracts fine. So whatever 0.7.0 fixed handles the empty-overlay case but not a populated one.

```bash
smolvm machine create empty-src --image fedora:42 --net
smolvm machine start --name empty-src
# vim-minimal is already in the base image — this is a no-op
smolvm machine exec --name empty-src -- dnf install -y vim-minimal
smolvm machine stop --name empty-src
echo "net = true" > empty.smolfile
smolvm pack create --from-vm empty-src -s empty.smolfile -o empty-pack
smolvm machine create empty-clone --from empty-pack.smolmachine --net  # ✅ extracts fine
```

## What I think is happening

The original #263 described "OverlayFS char-device whiteouts that the macOS pack extractor can't recreate as a non-root user." Real `dnf install` transactions trigger exactly that pattern:

1. dnf's resolver pulls in upgrades of base libraries (libblkid, libmount, libuuid, libsmartcols, util-linux-core, etc.) to satisfy the transitive deps of newly-installed packages.
2. Each upgrade writes the new version's files in the upper overlay layer and creates whiteouts for the old version's files.
3. The macOS pack extractor still can't recreate those whiteouts.

The no-op transaction case doesn't generate whiteouts (no files are replaced), so 0.7.0's fix path is sufficient. Any non-trivial dnf install does, and we're back to the original failure mode.

## Real-world impact

This blocks shipping any Fedora-based blueprint that needs more than the base image's packages. We tried adding a `fedora-bun-node` blueprint (Fedora 44 + git + Node 24 from NodeSource + Bun, 414 MB pack) to https://github.com/HoracioGonzalez/dev-instances and immediately hit this failure end-to-end. Rolled it back to keep the project usable.

## Environment

- smolvm `0.7.0`
- macOS `26.4.1` (build `25E253`), Apple Silicon (M4)

Happy to test patches or provide additional diagnosis. The 414 MB failing pack is on disk locally if a tarball would help.
