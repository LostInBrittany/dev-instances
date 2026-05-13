#!/usr/bin/env bash
#
# Build the ubuntu-bun-node blueprint.
#
# Base: ubuntu:26.04. Adds Node 24 (NodeSource) + Bun + build tools.
# The "give me everything" default among the three shipped blueprints.
#
# Default: re-packs the existing source VM if one exists (fast);
# otherwise creates it from the base image (~5-10 min). Pass --rebuild
# to delete the existing source VM and start fresh.

set -euo pipefail

NAME="ubuntu-bun-node"
IMAGE="ubuntu:26.04"

# shellcheck source=../_build-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/../_build-lib.sh"

build_with_prereqs "$@" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq git curl unzip ca-certificates gnupg build-essential sudo

# Node 24 via NodeSource (for user projects; agents use their own binaries).
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update -qq
apt-get install -y -qq nodejs

# Bun.
curl -fsSL https://bun.sh/install | bash
cat > /etc/profile.d/bun.sh <<EOF
export PATH=/root/.bun/bin:\$PATH
EOF
chmod +x /etc/profile.d/bun.sh
'
