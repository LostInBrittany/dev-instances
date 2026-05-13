#!/usr/bin/env bash
#
# Build the bun-dev blueprint.
#
# Default: if the source VM `bun-dev` exists, just re-pack it into
# dist/bun-dev.smolmachine (fast). If it doesn't, create it from
# oven/bun:slim and install Node 24 + build tools + Claude Code
# (~5-10 min) before packing.
#
# Pass --rebuild to delete the existing source VM first and rebuild
# from the base image.

set -euo pipefail

REBUILD=false
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=true ;;
        -h|--help) echo "Usage: $0 [--rebuild]"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST="$REPO_ROOT/dist"
NAME="bun-dev"
IMAGE="oven/bun:slim"

mkdir -p "$DIST"

# Use --json: the plain `machine ls` table truncates the NAME column at ~16
# chars + "..." and uses space-padded columns, which makes substring matching
# unreliable for longer names.
vm_exists() {
    smolvm machine ls --json 2>/dev/null \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/.*"([^"]*)"$/\1/' \
        | grep -Fxq "$NAME"
}

if $REBUILD && vm_exists; then
    echo "==> --rebuild: deleting existing source VM '$NAME'..."
    smolvm machine delete "$NAME" -f
fi

if vm_exists; then
    echo "==> Re-packing existing source VM '$NAME' (no install step)."
    echo "    Pass --rebuild to recreate from $IMAGE."
    smolvm machine stop --name "$NAME" 2>/dev/null || true
else
    echo "==> Creating source VM '$NAME' from $IMAGE..."
    smolvm machine create "$NAME" --image "$IMAGE" --net
    smolvm machine start --name "$NAME"

    # Distro prereqs + Node (Bun is already in the base image).
    smolvm machine exec --name "$NAME" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      git curl unzip ca-certificates gnupg build-essential

    # Node 24 via NodeSource (for user projects; agents use their own binaries).
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.key
    gpg --dearmor < /tmp/nodesource.key > /etc/apt/keyrings/nodesource.gpg
    cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main
EOF
    apt-get update -qq
    apt-get install -y -qq nodejs
    '

    # Agent CLIs (Claude Code + Codex + OpenCode) via the shared installer.
    echo "==> Installing agents..."
    smolvm machine exec --name "$NAME" -- bash -s < "$REPO_ROOT/blueprints/_install-agents.sh"

    smolvm machine stop --name "$NAME"
fi

echo "==> Packing into $DIST/$NAME.smolmachine..."
smolvm pack create --from-vm "$NAME" \
    -s "$SCRIPT_DIR/pack.smolfile" \
    -o "$DIST/$NAME"

echo
echo "Built: $DIST/$NAME.smolmachine"
