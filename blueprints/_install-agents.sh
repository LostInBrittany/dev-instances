#!/usr/bin/env bash
#
# Install three coding-agent CLIs inside the VM:
#   - Claude Code (Anthropic)
#   - Codex CLI (OpenAI)
#   - OpenCode (sst/opencode)
#
# Run via `smolvm machine exec --name X -- bash -s < this-file` from a
# blueprint build script, AFTER the distro-specific prereqs (curl,
# ca-certificates, etc.) are installed.
#
# Each agent ends up symlinked or installed into /usr/local/bin so
# non-login shells (like `smolvm machine exec` without `-l`) can find
# them without sourcing any profile.
#
# To skip an agent, comment out its section. To add a new one, follow
# the same pattern: install, then verify with `command -v`.

set -euo pipefail

# ---------------------------------------------------------------------
# Claude Code (Anthropic)
# ---------------------------------------------------------------------
echo "==> Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash

# Native installer places the binary somewhere under $HOME. Probe common
# locations, fall back to a depth-limited find, then symlink it into
# /usr/local/bin for non-login PATH safety.
CLAUDE_BIN=""
for d in /root/.local/bin /root/.claude/local/bin /root/.claude/bin /root/.bin; do
    if [ -x "$d/claude" ]; then CLAUDE_BIN="$d/claude"; break; fi
done
if [ -z "$CLAUDE_BIN" ]; then
    CLAUDE_BIN=$(find /root -maxdepth 6 -name claude -executable 2>/dev/null | head -1 || true)
fi
[ -n "$CLAUDE_BIN" ] || { echo "ERROR: claude binary not found after install" >&2; exit 1; }
ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
command -v claude >/dev/null

# ---------------------------------------------------------------------
# OpenAI Codex CLI
# ---------------------------------------------------------------------
echo "==> Installing Codex CLI..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  CODEX_TRIPLE="x86_64-unknown-linux-musl" ;;
    aarch64) CODEX_TRIPLE="aarch64-unknown-linux-musl" ;;
    *) echo "ERROR: unsupported arch '$ARCH' for Codex" >&2; exit 1 ;;
esac

# Latest release tarball URL via the GitHub API. The API returns JSON on a
# single line, so the previous grep-by-line / sed pipeline matched the wrong
# URL. Use grep -oE to extract URLs directly without depending on line
# structure (no jq dependency).
CODEX_URL=$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest \
    | grep -oE "https://[^\"]+codex-${CODEX_TRIPLE}\\.tar\\.gz" \
    | head -1)

[ -n "$CODEX_URL" ] || { echo "ERROR: no Codex Linux/musl release for $ARCH" >&2; exit 1; }

rm -rf /tmp/codex-install
mkdir -p /tmp/codex-install
curl -fsSL "$CODEX_URL" -o /tmp/codex-install/codex.tar.gz
tar -xzf /tmp/codex-install/codex.tar.gz -C /tmp/codex-install

# The archive contains a single binary named like `codex-<triple>`.
CODEX_BIN=$(find /tmp/codex-install -type f -executable -name 'codex-*' 2>/dev/null | head -1)
[ -n "$CODEX_BIN" ] || { echo "ERROR: codex binary not found in extracted archive" >&2; exit 1; }
install -m 0755 "$CODEX_BIN" /usr/local/bin/codex
rm -rf /tmp/codex-install
command -v codex >/dev/null

# ---------------------------------------------------------------------
# OpenCode (sst/opencode)
# ---------------------------------------------------------------------
echo "==> Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash

# Same probe-and-symlink dance as Claude — the installer's destination
# can vary ($OPENCODE_INSTALL_DIR / $XDG_BIN_DIR / $HOME/bin /
# $HOME/.opencode/bin) and not all of those are on the non-login PATH.
OPENCODE_BIN=""
for d in /root/.opencode/bin /root/.local/bin /root/bin; do
    if [ -x "$d/opencode" ]; then OPENCODE_BIN="$d/opencode"; break; fi
done
if [ -z "$OPENCODE_BIN" ]; then
    OPENCODE_BIN=$(find /root -maxdepth 6 -name opencode -executable 2>/dev/null | head -1 || true)
fi
[ -n "$OPENCODE_BIN" ] || { echo "ERROR: opencode binary not found after install" >&2; exit 1; }
ln -sf "$OPENCODE_BIN" /usr/local/bin/opencode
command -v opencode >/dev/null

# ---------------------------------------------------------------------
# Welcome banner for `dev-instance shell` (login bash).
# ---------------------------------------------------------------------
cat > /etc/profile.d/agents-banner.sh <<'BANNER'
#!/bin/sh
# Listed on interactive login. `dev-instance shell` runs `bash -l`,
# so /etc/profile.d/ is sourced before the user sees their prompt.
list=""
for a in claude codex opencode; do
    command -v "$a" >/dev/null 2>&1 && list="$list $a"
done
[ -n "$list" ] && printf 'Available agents:%s\n' "$list"
BANNER
chmod +x /etc/profile.d/agents-banner.sh

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
echo "Agents installed:"
for a in claude codex opencode; do
    p=$(command -v "$a" 2>/dev/null || echo "MISSING")
    printf '  %-9s -> %s\n' "$a" "$p"
done
