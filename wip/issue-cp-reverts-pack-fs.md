# `machine cp` reverts writable filesystem changes on machines created with `--from <pack>`

## Summary

On a machine created with `smolvm machine create --from <packed .smolmachine>`, any subsequent `smolvm machine cp` reverts the machine's writable filesystem to the state it was in immediately after pack restore. State created since machine start (users added via `useradd`, files written to `/etc`, `/var`, `/home`, etc.) is lost. Only the just-transferred file is preserved.

The same scenario using `--image <stock>` instead of `--from <pack>` works correctly: state set via `exec` survives `cp`.

## Environment

- smolvm `0.6.3`
- macOS `26.4.1` (build `25E253`), Apple Silicon (M4)

## Reproducer

```bash
#!/usr/bin/env bash
set -euo pipefail

# If the calling shell has a stale TMPDIR pointing at a deleted
# directory, smolvm's temp-file creation will fail. Drop it so the
# system default is used.
unset TMPDIR

WORK=/tmp/smolvm-cp-bug
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

# Clean up anything from a prior failed run so the script is rerunnable.
for m in cp-bug-src cp-bug-frompack cp-bug-fromimage; do
    smolvm machine stop   --name "$m"    >/dev/null 2>&1 || true
    smolvm machine delete       "$m" -f  >/dev/null 2>&1 || true
done

# Build a tiny pack from a stock image. Start, write something, then
# stop — `pack create` needs the VM's overlay disk to be non-empty
# (a trivial write does the job).
smolvm machine create cp-bug-src --image debian:13 --net
smolvm machine start --name cp-bug-src
smolvm machine exec --name cp-bug-src -- touch /etc/pack-marker
smolvm machine stop --name cp-bug-src
echo "net = true" > pack.smolfile
smolvm pack create --from-vm cp-bug-src -s pack.smolfile -o pack
smolvm machine delete cp-bug-src -f

# --- Case 1: machine created with --from <pack> ---
smolvm machine create cp-bug-frompack --from pack.smolmachine --net
smolvm machine start --name cp-bug-frompack

smolvm machine exec --name cp-bug-frompack -- useradd -m alice
echo "[from-pack] before cp:"
smolvm machine exec --name cp-bug-frompack -- id alice

echo data > probe.txt
smolvm machine cp probe.txt cp-bug-frompack:/tmp/probe.txt

echo "[from-pack] after cp:"
smolvm machine exec --name cp-bug-frompack -- id alice || echo "  alice is gone"

smolvm machine stop --name cp-bug-frompack
smolvm machine delete cp-bug-frompack -f

# --- Case 2: machine created with --image <stock> (control) ---
smolvm machine create cp-bug-fromimage --image debian:13 --net
smolvm machine start --name cp-bug-fromimage

smolvm machine exec --name cp-bug-fromimage -- useradd -m alice
echo "[from-image] before cp:"
smolvm machine exec --name cp-bug-fromimage -- id alice

smolvm machine cp probe.txt cp-bug-fromimage:/tmp/probe.txt

echo "[from-image] after cp:"
smolvm machine exec --name cp-bug-fromimage -- id alice

smolvm machine stop --name cp-bug-fromimage
smolvm machine delete cp-bug-fromimage -f

cd / && rm -rf "$WORK"
```

## Expected output (with the bug)

```
[from-pack] before cp:
uid=1000(alice) gid=1000(alice) groups=1000(alice)
[from-pack] after cp:
id: 'alice': no such user
  alice is gone
[from-image] before cp:
uid=1000(alice) gid=1000(alice) groups=1000(alice)
[from-image] after cp:
uid=1000(alice) gid=1000(alice) groups=1000(alice)
```

## Findings from a wider matrix

| `--from` pack | `--init` | mount | `cp` reverts state? |
|---|---|---|---|
| ✓ | — | — | yes |
| ✓ | `/bin/true` | — | yes |
| ✓ | `/bin/true` | ✓ | yes |
| `--image debian:13` | `/bin/true` | ✓ | no |

The trigger is `--from`. `--init`, mounts, and env vars all turned out to be irrelevant. File size also turned out to be irrelevant — a 1 MB `cp` reverts state just as completely as a 30 MB `cp`.

## Scope of the revert

Confirmed wiped after `cp`:

- `/etc/passwd` (users added via `useradd`)
- Custom files written via `exec` to `/etc/` and `/var/`
- Files previously transferred via earlier `smolvm machine cp` (e.g., earlier `/tmp/foo.bin`)

Confirmed preserved after `cp`:

- The file being transferred in the current `cp`.

This suggests `cp` doesn't merge into the existing writable layer — it rebuilds it from the pack's restore point plus only the new file. Anything between has been silently dropped.

## Workaround

We re-run our user/group setup script via `exec` after every `cp` so the lost users get recreated. It's awkward and only covers state we know about — files written by other means inside the VM are still silently lost.

## Why this matters

The packed-machine workflow (`smolvm pack create` → `smolvm machine create --from`) is the primary way users build reusable, pre-configured dev environments. Without `cp` working safely against those, the workflow is hard to build on: any tool that needs to bring host files into a packed-clone VM will lose all other state without warning.

Happy to test patches or provide additional information.
