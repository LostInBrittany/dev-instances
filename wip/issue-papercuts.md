# smolvm papercuts collected while building dev-instances

A small backlog of smolvm rough edges encountered while building
[dev-instances](https://github.com/HoracioGonzalez/dev-instances), a
per-project sandbox tool layered on top of smolvm. Each is separately
filable; combining here for tracking until we get round to opening them
upstream.

The headline bug (cp reverts writable filesystem on `--from <pack>`
machines) is its own write-up at
[`issue-cp-reverts-pack-fs.md`](./issue-cp-reverts-pack-fs.md).

Environment for all of these: smolvm `0.6.3`, macOS `26.4.1` (Apple
Silicon M4).

---

## 1. `machine start --init …` returns before init has completed

`smolvm machine start --name <vm>` returns as soon as the machine
process is up, but the `--init` command is still running. Subsequent
`smolvm machine exec` calls can race the init script — at best you see
intermittent failures, at worst you proceed against a half-initialized
VM.

Symptom in dev-instances: when the next step after `start` is a
`smolvm machine cp` plus an `exec` that depends on the dev user
created by `--init`, we land in a clone where the user doesn't exist
yet, all subsequent commands fall through to root, and the user thinks
the tool is broken.

Workaround we use: poll `id <expected-user>` via `smolvm machine exec`
until it returns 0 (or time out). It works but it's brittle — any
init that doesn't end with a side effect we can probe needs a
different sentinel.

Suggestions:

- Make `machine start` block until `--init` exits (with a timeout
  flag for callers that want async).
- Or add a `smolvm machine wait-init --name <vm>` subcommand so
  callers can opt into "block until init finishes" without polling.

---

## 2. `pack create` requires the VM to have been started at least once

Fresh `machine create` immediately followed by `pack create`:

```
Error: agent operation failed: pack from VM: overlay disk not found
at /Users/horacio/Library/Caches/smolvm/vms/<id>/overlay.raw.
The VM may not have been started yet.
```

The error message is clear, which is great — this one is more of a
docs / "tighten the workflow" point than a real bug:

- The README / `smolvm pack create --help` could explicitly say "the
  source VM must have been started at least once" up front.
- Or `pack create` could auto-start (and stop) the source VM as part
  of pack creation if it hasn't been started yet.

---

## 3. `pack create` fails non-obviously on an empty overlay

After fixing #2 (start before pack create), packing a VM that was
started and stopped *without any writes* fails partway through with:

```
Packing VM 'cp-bug-src' snapshot...
Collecting runtime libraries...
Collecting agent rootfs...
Creating storage template...
Starting agent VM to export layers...
Pulling image debian:13... done.
Exporting 1 layers...
  Layer 1/1: sha256:b5d74b688654... 139 MB done
Exporting container overlay...
Error: agent operation failed: read file: failed to open /tmp/overlay-export.tar: No such file or directory (os error 2)
```

The error makes it sound like a path / I/O problem; the actual cause
is "the overlay has no contents to pack." A trivial write between
start and stop (`smolvm machine exec --name <vm> -- touch /etc/foo`)
makes the export succeed.

Suggestions:

- Detect an empty overlay and either pack it as an empty layer or
  fail with a clearer message ("the source VM's overlay is empty;
  start the VM and make at least one change before packing").
- Or simply succeed and produce a pack equivalent to the base image
  (which is what you'd reasonably expect from an empty overlay).

---

## 4. `machine exec` silently no-ops when host stdin isn't forwarded

```bash
smolvm machine exec --name <vm> -- bash -s < script.sh
```

This *looks* like it should pipe `script.sh` into the inner `bash -s`,
but `smolvm machine exec` doesn't forward host stdin by default — the
inner `bash -s` gets EOF and exits 0 without running anything. No
error, no warning, just a silent no-op.

We hit this in dev-instances 0.1.0 — our agent-installer script
"ran" successfully but did nothing inside the VM, so clones came up
without Claude Code / Codex / OpenCode. Took a while to diagnose
because the exit code was 0 and there's no stderr output.

Workaround we use: `smolvm machine cp script.sh <vm>:/tmp/script.sh`
followed by `smolvm machine exec --name <vm> -- bash /tmp/script.sh`.
This works fine but is more plumbing than seemed necessary.

Suggestions:

- Forward host stdin by default when `--name … --` is followed by a
  command that reads stdin (heuristic: skip if `-i` / `-t` is not
  set?), or
- Detect that stdin is piped from a non-TTY and warn ("note: host
  stdin is not forwarded; use `--stdin` if you want to pipe data in"),
  or
- Add an explicit `--stdin` flag and error out if stdin is non-empty
  but the flag isn't set.

The current silent-success behavior is the worst of the available
options because it masks broken plumbing as a working command.

---

## 5. `machine ls` truncates the name column at ~16 chars

The default table format truncates long VM names mid-string with
`...`, which makes substring matching from scripts (e.g., "find clones
whose name starts with `proj-foo-`") unreliable.

`--json` avoids the truncation and is what our tooling uses now, but
discovering this took a confused debugging session: `dev-instance ls`
appeared to "not see" newly-created clones because the table was
showing truncated names while the grep we were doing matched the full
name.

Suggestions:

- Don't truncate in the default table — wrap or let the column be
  whatever width the longest name needs.
- Or add a `--no-truncate` / `--full` flag for cases where you'd
  rather not switch to `--json`.

This one's mild but it bites people writing shell scripts around
smolvm.

---

## 6. `machine exec -it` doesn't propagate host terminal size, and the PTY ignores in-VM `stty`

**Already tracked upstream as
[smol-machines/smolvm#156](https://github.com/smol-machines/smolvm/issues/156)**
— SIGWINCH forwarding is claimed fixed in 0.5.18 / commit `ce832d0`,
but we confirmed on **smolvm 0.6.3 / macOS 26.4.1** that the fix
isn't taking effect: `stty size` inside the VM stays at 24×80 even
when the host terminal is resized after attach. Holds for both
`--image` and `--from <pack>` machines. Our reproducer + findings
posted as a comment on the issue
([source](./comment-smolvm-156.md)).

Keeping the long-form description below for reference.

---

When attaching interactively with `smolvm machine exec -it`, the PTY
inside the VM is allocated at the default 80×24 regardless of the
host terminal's actual dimensions. Apps that read `TIOCGWINSZ`
(Claude Code, `vim`, `less`, `top`, anything that draws based on
terminal width) clamp to 80 columns even though the host terminal
is much wider.

What makes this harder to work around than expected: running
`stty cols X rows Y` *inside the VM* over a `machine exec -it`
session is silently ignored. `stty size` immediately afterwards still
reports `24 80`. So the usual "set the size in-band" workaround that
works for misbehaving terminals doesn't apply here — the PTY appears
to reject `TIOCSWINSZ` from the guest side.

Verified with this sequence (host terminal at 155×43):

```bash
# On host
tput cols   # → 155
tput lines  # → 43

# Inside the VM (via smolvm machine exec -it)
stty cols 155 rows 43
stty size   # → 24 80   (unchanged!)
```

SSH and `docker exec -it` both handle this correctly: capture the
client's terminal size at attach time and forward `SIGWINCH` for live
resizes.

Workaround we settled on in dev-instances: export `COLUMNS`/`LINES`
inside the inner shell so apps that respect env vars (Claude Code is
one) draw at the right width even though the kernel PTY is still
stuck at 80×24. We still attempt `stty cols/rows` ahead of that for
the day smolvm fixes the underlying issue.

Suggestions:

- Forward the host PTY's size into the inner PTY at attach time, so
  `TIOCGWINSZ` returns the right value to in-VM apps.
- Forward `SIGWINCH` from the host so live resizes work.
- Even short of those, accepting `TIOCSWINSZ` from the guest would
  let users set the size in-band as a workaround.

---

## Out of scope here

- The pack-create-resets-state-on-`cp` bug (the big one) is in
  [`issue-cp-reverts-pack-fs.md`](./issue-cp-reverts-pack-fs.md).
- The Fedora overlay char-device-whiteout pack bug is filed upstream
  as [smol-machines/smolvm#263](https://github.com/smol-machines/smolvm/issues/263);
  reference drafts in [`issue-fedora-overlay.md`](./issue-fedora-overlay.md)
  and [`issue-fedora-overlay-comment.md`](./issue-fedora-overlay-comment.md).
