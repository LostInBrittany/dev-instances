#!/usr/bin/env bash
#
# Build the bun-only blueprint.
#
# Base: oven/bun:slim. No real Node — relies on Bun's Node-compat mode
# via the bun-node-fallback shim. Smallest pack of the three.
#
# Default: re-packs the existing source VM if one exists (fast);
# otherwise creates it from the base image (~5-10 min). Pass --rebuild
# to delete the existing source VM and start fresh.

set -euo pipefail

NAME="bun-only"
IMAGE="oven/bun:slim"

# shellcheck source=../_build-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/../_build-lib.sh"

build_with_prereqs "$@" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git curl unzip ca-certificates gnupg build-essential sudo

# PATH: bun bin first, then the node→bun fallback so `#!/usr/bin/env node` works.
cat > /etc/profile.d/bun.sh <<EOF
export PATH=/root/.bun/bin:/usr/local/bun-node-fallback-bin:\$PATH
EOF
chmod +x /etc/profile.d/bun.sh
'
