<!--
Title: machine create --from: tar extraction aborts on overlay-layer entries for replaced base-layer files (Fedora, post-#256)
-->

## Description

After #256 was fixed in v0.6.3, `smolvm machine create --from` still fails to extract `.smolmachine` files packed from Fedora-based VMs whenever the source VM has had any `dnf install` run on it. A no-op pack (source VM with zero changes) now extracts cleanly, confirming the #256 fix is partially effective.

The failure happens in the overlay layer (`…/layers-cs/<hash>/overlay-fedo/…`) and the path that trips it is always a base-layer file that dnf either upgraded or replaced — e.g. a `libgcc_s-16-<date>.so.1` whose date got bumped, a `/usr/lib/.build-id/<xx>/<hash>` symlink, or `/usr/lib/debug/lib64`. Manually stripping the failing entry from the source VM before re-packing just exposes the next one, so the underlying issue is the extractor not handling the *class* of overlay tar entries that represent **replaced or removed base-layer files** (character-device whiteouts and/or duplicate-path entries) on macOS.

Same shape as #235 and #256 (extraction aborts on a specific entry pattern); different trigger. Ubuntu packs are unaffected in practice because `apt-get install` rarely upgrades base libs like glibc/libgcc/util-linux — `dnf install` almost always does, so this triggers on essentially any useful Fedora customization.

## Reproduction

```bash
smolvm machine create fedora-test --image fedora:latest --net
smolvm machine start --name fedora-test
smolvm machine exec --name fedora-test -- bash -c 'dnf install -y git'
smolvm machine stop --name fedora-test
smolvm pack create --from-vm fedora-test -o /tmp/fedora-test
smolvm machine create dst --from /tmp/fedora-test.smolmachine
# Error: agent operation failed: extract sidecar: failed to unpack
#   `…/layers-cs/<hash>/overlay-fedo/usr/lib/.build-id/d9/1d9c9c48e8bbc51bac6db108cdc97344f265b6`
```

Installing `git` alone is enough — dnf also upgrades `util-linux-core`, `libmount`, `libblkid`, `libuuid`, `libsmartcols` as transitive dependencies, and any of those upgrades is sufficient to produce a failing overlay entry.

A no-op pack (`smolvm machine create … --image fedora:latest`, start, stop, pack, re-extract) succeeds, confirming the regression is specific to overlay entries produced by package upgrades/removals rather than overlays in general.

## Environment

smolvm v0.6.3, macOS (Apple Silicon, darwin/aarch64), `fedora:latest` (Fedora 44 container image).
