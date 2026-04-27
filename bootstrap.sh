#!/bin/bash
# bootstrap.sh — Remote installer for folder-to-notes.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/zacs/folder_to_notes/main/bootstrap.sh | bash
#
# Clones the repo into ~/.folder-to-notes (or pulls the latest if already
# present), then hands off to install.sh which prompts for config and sets
# up the launchd agent.

set -euo pipefail

REPO_URL="https://github.com/zacs/folder_to_notes.git"
INSTALL_DIR="${HOME}/.folder-to-notes"
BRANCH="main"

echo ""
echo "=== folder-to-notes bootstrap ==="
echo ""
echo "  Install location: ${INSTALL_DIR}"
echo ""

# ── Sanity checks ────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: This tool only runs on macOS." >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required. Install Xcode Command Line Tools with:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "ERROR: Swift toolchain not found. Install Xcode Command Line Tools with:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

# ── Clone or update ──────────────────────────────────────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "→ Existing install found — pulling latest from ${BRANCH}..."
    git -C "${INSTALL_DIR}" fetch --quiet origin "${BRANCH}"
    git -C "${INSTALL_DIR}" reset --hard --quiet "origin/${BRANCH}"
elif [[ -e "${INSTALL_DIR}" ]]; then
    echo "ERROR: ${INSTALL_DIR} exists but is not a git checkout." >&2
    echo "Move or remove it, then re-run." >&2
    exit 1
else
    echo "→ Cloning ${REPO_URL}..."
    git clone --quiet --branch "${BRANCH}" "${REPO_URL}" "${INSTALL_DIR}"
fi

# ── Hand off to installer ────────────────────────────────────────────────────
echo ""
echo "→ Running installer..."
echo ""
cd "${INSTALL_DIR}"
exec bash install.sh
