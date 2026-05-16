# `smolvm pack create` panics on VM names shorter than ~4 characters

**Filed upstream as
[smolvm#277](https://github.com/smol-machines/smolvm/issues/277).**

Reproducible on **smolvm 0.7.0 / macOS 26.4.1 (Apple Silicon M4)**.

## Summary

`smolvm pack create --from-vm <name>` panics when the VM name is too short, because internal code at `crates/smolvm-pack/src/assets.rs:235:55` tries to take a 12-byte slice of the string `overlay-<vm_name>`, which is shorter than 12 bytes for short names.

## Reproducer

```bash
smolvm machine create x --image debian:13 --net
smolvm machine start --name x
smolvm machine exec --name x -- bash -c 'touch /etc/probe-marker'
smolvm machine stop --name x

echo "net = true" > pack.smolfile
smolvm pack create --from-vm x -s pack.smolfile -o pack
# thread 'main' (24496987) panicked at crates/smolvm-pack/src/assets.rs:235:55:
# end byte index 12 is out of bounds of `overlay-x`
# note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
# Error: config operation failed: create from .smolmachine: file not found: pack.smolmachine
```

A longer VM name (e.g. `four`, `foursome`, anything ≥ 4 chars where `overlay-<name>` reaches 12 bytes) avoids the panic.

## What I think is happening

The error message says:

```
end byte index 12 is out of bounds of `overlay-x`
```

`overlay-x` is 9 bytes. A `&str[..12]` (or equivalent) at `assets.rs:235:55` assumes the name is long enough to reach byte 12. Short VM names break that assumption.

## Suggested fix

Either:

- Use `name.get(..12)` (returns `Option<&str>`) and handle the short case explicitly, or
- Pad short names, or use the full `overlay-<name>` regardless of length, or
- Reject too-short names at `machine create` time so they never reach this code path.

Whichever direction, a panic-free path with a clear error message would be a friendlier failure mode than the current Rust panic.

## Environment

- smolvm 0.7.0
- macOS 26.4.1 (build 25E253), Apple Silicon (M4)
