#!/usr/bin/env bash
#
# Install the runtime user-matching script that `dev-instance create`
# uses to make files written in /home/dev/workspace appear with the
# host user's uid/gid on the host filesystem.
#
# Run via `smolvm machine exec ... bash -s < this-file` at build time.
# Drops /usr/local/sbin/match-host-uid.sh into the VM. That script is
# then invoked by smolvm `--init` on every VM start.
#
# Why runtime rather than build-time? The host user's uid/gid is
# different per machine (501/20 on macOS, 1000/1000 on most Linux).
# Baking a fixed uid would only work for one host. Adjusting at boot
# via env vars works for everyone.

set -euo pipefail

# Write the runtime script.
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/match-host-uid.sh <<'RUNTIME'
#!/usr/bin/env bash
#
# Create or align a `dev` user to match the host's uid/gid, passed in
# via $HOST_UID / $HOST_GID env vars. Run on every VM start via
# `smolvm machine create --init /usr/local/sbin/match-host-uid.sh`.
#
# Side effects:
#   - `dev` user/group with the matching uid/gid (or 1000/1000 default)
#   - passwordless sudo for dev
#   - /home/dev exists and is owned by dev
#   - /home/dev/workspace exists as the mount point

set -euo pipefail

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Group: create with the target gid, or align if it already exists.
# `-o` allows a non-unique gid (macOS gid 20 collides with Debian's
# dialout group; we don't care, the numeric value is what matters).
if getent group dev >/dev/null; then
    groupmod -g "$HOST_GID" -o dev
else
    groupadd -g "$HOST_GID" -o dev
fi

# User: same pattern.
# -K UID_MIN=0 suppresses the "uid outside default range" warning for
# macOS host uids (501), which are below Debian's default UID_MIN=1000.
# -m is omitted because /home/dev already exists at this point (smolvm
# creates it as the mount point before --init runs); we handle the dir
# ownership explicitly below.
if id dev >/dev/null 2>&1; then
    usermod -u "$HOST_UID" -g "$HOST_GID" -o dev
else
    useradd -u "$HOST_UID" -g "$HOST_GID" -o -K UID_MIN=0 -s /bin/bash -d /home/dev dev
fi

# Passwordless sudo so agents can `apt install` etc. without prompting.
# Only configured if sudo is actually installed in the image — base
# images like oven/bun:slim don't include it, and the blueprint's
# build.sh is responsible for adding it. Skip silently otherwise.
if command -v sudo >/dev/null 2>&1; then
    mkdir -p /etc/sudoers.d
    if [ ! -f /etc/sudoers.d/dev ]; then
        echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev
        chmod 0440 /etc/sudoers.d/dev
    fi
fi

# Make sure /home/dev is dev-owned (in case smolvm pre-created it with
# root ownership for the mount, or usermod changed the uid and left
# stale-uid skel files behind).
#
# Use `find -prune` to skip /home/dev/workspace entirely — that path is
# the virtiofs mount, and (a) the files there already carry the host
# user's uid/gid via virtiofs, (b) chowning through virtiofs fails for
# read-only files like git's packed objects.
mkdir -p /home/dev
find /home/dev -path /home/dev/workspace -prune -o \
    -exec chown "$HOST_UID:$HOST_GID" {} +

# Make sure the mount point exists (smolvm normally creates it for the
# bind, but doesn't hurt as a fallback).
mkdir -p /home/dev/workspace
RUNTIME

chmod +x /usr/local/sbin/match-host-uid.sh

echo "Installed: /usr/local/sbin/match-host-uid.sh"
