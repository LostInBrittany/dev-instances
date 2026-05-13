#!/usr/bin/env bash
#
# Build the bun-node blueprint.
#
# Base: oven/bun:slim. Adds Node 24 (NodeSource) so npm CLIs that hit
# Node-specific APIs still work alongside Bun.
#
# Default: re-packs the existing source VM if one exists (fast);
# otherwise creates it from the base image (~5-10 min). Pass --rebuild
# to delete the existing source VM and start fresh.

set -euo pipefail

NAME="bun-node"
IMAGE="oven/bun:slim"

# shellcheck source=../_build-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/../_build-lib.sh"

build_with_prereqs "$@" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git curl unzip ca-certificates gnupg build-essential sudo

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
