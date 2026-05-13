#!/usr/bin/env bash
#
# Build the bun-only blueprint.
#
# Default: if the source VM `bun-only` exists, just re-pack it into
# dist/bun-only.smolmachine (fast). If it doesn't, create it from
# oven/bun:slim and install build tools + Claude Code via the native
# installer (~5-10 min) before packing. No real Node — relies on
# Bun's Node-compat mode via the bun-node-fallback shim.
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
NAME="bun-only"
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

    # Distro prereqs + bun PATH.
    smolvm machine exec --name "$NAME" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      git curl unzip ca-certificates gnupg build-essential

    # PATH: bun bin first, then the node→bun fallback so `#!/usr/bin/env node` works.
    cat > /etc/profile.d/bun.sh <<EOF
export PATH=/root/.bun/bin:/usr/local/bun-node-fallback-bin:\$PATH
EOF
    chmod +x /etc/profile.d/bun.sh
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
