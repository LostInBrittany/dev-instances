#!/usr/bin/env bash
#
# Shared build harness for blueprints/<name>/build.sh.
#
# Each blueprint's build.sh sets NAME + IMAGE, sources this file, and
# calls:
#
#     build_with_prereqs "$@" -- COMMAND...
#
# COMMAND is what runs inside the source VM to install the per-blueprint
# distro prereqs (apt installs, NodeSource setup, Bun PATH, etc.). This
# file handles everything else: --rebuild parsing, source VM lifecycle
# (create / reuse / delete-and-recreate), running the shared
# _install-user.sh and _install-agents.sh inside the VM, and packing
# into dist/.
#
# Expected globals (set by the caller before sourcing):
#   NAME   — source VM name; also the dist/<NAME>.smolmachine basename.
#   IMAGE  — base OCI image used for fresh builds.
#
# Files used (resolved relative to the caller's directory):
#   $SCRIPT_DIR/pack.smolfile                  — per-blueprint pack config
#   $REPO_ROOT/blueprints/_install-user.sh     — user-matching installer
#   $REPO_ROOT/blueprints/_install-agents.sh   — agent CLIs installer

: "${NAME:?_build-lib.sh: NAME must be set before sourcing}"
: "${IMAGE:?_build-lib.sh: IMAGE must be set before sourcing}"

# The caller (blueprints/<name>/build.sh) is at BASH_SOURCE[1].
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST="$REPO_ROOT/dist"

# vm_exists: 0 if a VM named $NAME is registered in smolvm.
# Uses --json: the plain `machine ls` table truncates the NAME column at
# ~16 chars + "..." and uses space-padded columns, which makes substring
# matching unreliable for longer names.
vm_exists() {
    smolvm machine ls --json 2>/dev/null \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/.*"([^"]*)"$/\1/' \
        | grep -Fxq "$NAME"
}

# build_with_prereqs FLAGS... -- COMMAND...
#
# FLAGS: build script flags (currently just --rebuild and -h/--help).
# COMMAND: what to run inside the VM to install distro prereqs.
#          Typically `bash -c '...multiline script...'`.
#
# Lifecycle:
#   --rebuild        delete the existing source VM first (if any).
#   VM exists        stop it and re-pack (fast — no install step).
#   VM doesn't exist create from $IMAGE, run COMMAND, then run the
#                    shared _install-user.sh + _install-agents.sh, stop.
#   Always           pack into $DIST/$NAME.smolmachine.
build_with_prereqs() {
    local rebuild=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --)        shift; break ;;
            --rebuild) rebuild=true; shift ;;
            -h|--help) echo "Usage: $(basename "$0") [--rebuild]"; return 0 ;;
            *)         echo "$(basename "$0"): unknown arg: $1" >&2; return 1 ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        echo "build_with_prereqs: missing '-- COMMAND...' (the prereqs to run inside the VM)" >&2
        return 1
    fi

    local prereqs_cmd=("$@")

    mkdir -p "$DIST"

    if $rebuild && vm_exists; then
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

        # Per-blueprint distro prereqs (apt installs, NodeSource setup,
        # Bun PATH, etc.) — passed in by the caller.
        echo "==> Installing distro prereqs..."
        smolvm machine exec --name "$NAME" -- "${prereqs_cmd[@]}"

        # Runtime user-matching script (drops /usr/local/sbin/match-host-uid.sh
        # in the VM; invoked by `dev-instance create` via smolvm --init).
        # Use `cp + exec` instead of `bash -s < file` because smolvm exec
        # doesn't forward stdin without -i (and -i is interactive-flavored).
        echo "==> Installing user-matching runtime script..."
        smolvm machine cp "$REPO_ROOT/blueprints/_install-user.sh" "$NAME:/tmp/_install-user.sh"
        smolvm machine exec --name "$NAME" -- bash /tmp/_install-user.sh

        # Agent CLIs (Claude Code + Codex + OpenCode) via the shared installer.
        echo "==> Installing agents..."
        smolvm machine cp "$REPO_ROOT/blueprints/_install-agents.sh" "$NAME:/tmp/_install-agents.sh"
        smolvm machine exec --name "$NAME" -- bash /tmp/_install-agents.sh

        smolvm machine stop --name "$NAME"
    fi

    echo "==> Packing into $DIST/$NAME.smolmachine..."
    smolvm pack create --from-vm "$NAME" \
        -s "$SCRIPT_DIR/pack.smolfile" \
        -o "$DIST/$NAME"

    echo
    echo "Built: $DIST/$NAME.smolmachine"
}
