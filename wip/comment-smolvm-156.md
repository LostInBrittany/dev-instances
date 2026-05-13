# Comment for smolvm#156

Paste the section below into a new comment on
https://github.com/smol-machines/smolvm/issues/156.

---

Hi — adding a data point: this is still reproducible on **smolvm 0.6.3 / macOS 26.4.1 (Apple Silicon M4)**. The "AI-assisted investigation" comment above suggests `ce832d0` (released in 0.5.18) made SIGWINCH forward end-to-end, but I can't observe that here — the in-VM PTY size never changes when I resize the host terminal.

Tested with both `--image` and `--from <pack>` machines; both behave the same way.

## Reproducer

```bash
smolvm machine create sigwinch-probe --image debian:13 --net
smolvm machine start --name sigwinch-probe
smolvm machine exec --name sigwinch-probe -it -- bash -l
```

Then inside the resulting shell:

```
# stty size
24 80
# (now resize the host terminal — drag a corner, fullscreen toggle, anything)
# stty size
24 80
```

Same result with a packed machine:

```bash
# Build a tiny pack from anything
smolvm machine create probe-src --image debian:13 --net
smolvm machine start --name probe-src
smolvm machine exec --name probe-src -- touch /etc/marker
smolvm machine stop --name probe-src
echo "net = true" > pack.smolfile
smolvm pack create --from-vm probe-src -s pack.smolfile -o pack
smolvm machine delete probe-src -f

# Repro
smolvm machine create sigwinch-probe-pack --from pack.smolmachine --net
smolvm machine start --name sigwinch-probe-pack
smolvm machine exec --name sigwinch-probe-pack -it -- bash -l
# ... same `stty size` doesn't update on resize.
```

Host side (verified) reports the right size before launching: `tput cols` → 155, `tput lines` → 43. The host terminal is a native macOS terminal app with no tmux/zellij in between.

## What I'd expect

After `ce832d0`, resizing the host terminal should propagate `TIOCSWINSZ` into the guest PTY such that `stty size` inside the VM reflects the new dimensions. That's what's failing.

## Knock-on impact

TUIs inside the VM all draw at 80×24 even on a 155-column host terminal. There's no in-VM workaround either: `stty cols X rows Y` issued by the guest is silently ignored (smolvm seems to override it), and bash resets `COLUMNS`/`LINES` from `TIOCGWINSZ` at startup, so exporting them via env vars before `bash -l` doesn't survive either. So this single bug effectively locks all TUIs to 80×24 from the host's perspective.

## Suggested directions

In addition to the existing options in the prior comment (fold initial `cols`/`rows` into `VmExec`/`Run` requests, pre-spawn handshake, sane default in `open_pty()`), a quick win would be a minimal "send an initial Resize as soon as the child reports `Started`" — even if not race-free for the first frame, it'd at least get `TIOCSWINSZ` into the right state before the user types anything, and live SIGWINCH would follow.

Happy to test patches or do further diagnosis if useful.
