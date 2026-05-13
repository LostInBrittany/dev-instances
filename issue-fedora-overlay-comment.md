A bit more digging on this one, sharing what I found in case it's useful (apologies if it's stuff you'd already pieced together from the failure mode).

I unpacked the overlay tar from a failing pack and looked at the entries near the path the error mentions:

```
c---------  0 root  root  0,0 May 13 09:42 ./usr/lib/.build-id/84/fc7d6c5bc7591c5e3b7c7299ff8d6a9986d2ff
h---------  0 root  root    0 May 13 09:42 ./usr/lib/.build-id/d9/1d9c9c48… link to ./usr/lib/.build-id/84/fc7d6c…
… (33 more hardlinks to the same target)
```

Trying to extract just those two entries manually on macOS:

```
./usr/lib/.build-id/84/fc7d6c…: Can't create '…': Operation not permitted
./usr/lib/.build-id/d9/1d9c9c…: Hard-link target '…/84/fc7d6c…' does not exist
```

So the target of the failing hardlink is an OverlayFS whiteout (char dev `0:0`, mode `0000`), and the macOS extractor can't create char devices as a non-root user — which then cascades into the hardlink failure.

The chain that produces this, as I understand it:

1. `dnf install git` upgrades `util-linux-core` as a transitive dep, removing `/usr/bin/taskset` from the base.
2. Fedora's base image hardlinks `/usr/bin/taskset` from ~35 paths under `/usr/lib/.build-id/...` (RPM build-id convention — those hash dirs all share one inode).
3. OverlayFS represents the deletion as **one** whiteout char device + N hardlinks to it in the upper layer (because the deleted paths shared an inode).
4. The tar of the upper layer carries that structure verbatim; macOS extraction can't reproduce it.

If that's the right read, it would also explain why every fix attempt exposed the next failing path — different package, different hardlinked file, same pattern. The `libgcc_s-16-<date>.so.1` case from the issue body fits too (libgcc tends to be hardlinked to its versioned variant).

For context — not a suggestion, just what I bumped into while looking around — OCI image layers handle this by writing a zero-byte regular file `.wh.<basename>` in place of the char device, which Docker/containerd/podman all read. There may well be reasons smolvm went a different direction that I'm not seeing.

Happy to test a patch on this setup if it'd help.
