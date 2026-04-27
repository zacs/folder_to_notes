#!/bin/bash
# install.sh — Set up scanner-to-notes.
# Run once from the project directory: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"

# ── Prompt for config ────────────────────────────────────────────────────────
echo ""
echo "=== scanner-to-notes installer ==="
echo ""

# When invoked via `curl ... | bash`, stdin is the pipe from curl, not the
# user's terminal — so plain `read` gets EOF and prompts are skipped. Read
# from /dev/tty when available so the prompts work in both modes.
if [[ -r /dev/tty ]]; then
    PROMPT_IN=/dev/tty
else
    PROMPT_IN=/dev/stdin
fi

read -rp "Dropbox scanner folder path [${HOME}/Dropbox/Scanner]: " DROPBOX_PATH < "$PROMPT_IN"
DROPBOX_PATH="${DROPBOX_PATH:-${HOME}/Dropbox/Scanner}"

read -rp "Apple Notes folder name [Scanned Documents]: " NOTES_FOLDER < "$PROMPT_IN"
NOTES_FOLDER="${NOTES_FOLDER:-Scanned Documents}"

echo ""

# ── Directories ──────────────────────────────────────────────────────────────
echo "→ Creating directories..."
mkdir -p "$INSTALL_DIR"/{bin,state,logs}
touch "$INSTALL_DIR/state/processed.txt"

# ── Update run.sh with Notes folder ─────────────────────────────────────────
echo "→ Configuring run.sh..."
sed -i '' \
    "s|NOTES_FOLDER=\"Scanned Documents\"|NOTES_FOLDER=\"${NOTES_FOLDER}\"|" \
    "$INSTALL_DIR/scripts/run.sh"
sed -i '' \
    "s|DROPBOX_FOLDER=\"\${HOME}/Dropbox/Scanner\"|DROPBOX_FOLDER=\"${DROPBOX_PATH}\"|" \
    "$INSTALL_DIR/scripts/run.sh"
chmod +x "$INSTALL_DIR/scripts/run.sh"
chmod +x "$INSTALL_DIR/scripts/create_note.py"

# ── Compile Swift binary ─────────────────────────────────────────────────────
echo "→ Compiling Swift binary (this takes ~30s)..."

SDK=$(xcrun --show-sdk-path)
xcrun swiftc \
    -O \
    -sdk "$SDK" \
    "$INSTALL_DIR/Sources/main.swift" \
    -o "$INSTALL_DIR/bin/process_scan"

echo "   ✓ Compiled: $INSTALL_DIR/bin/process_scan"

# ── Install launchd plist ────────────────────────────────────────────────────
echo "→ Installing launchd agent..."

PLIST_SRC="$INSTALL_DIR/launchd/com.user.scanner-to-notes.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/com.user.scanner-to-notes.plist"

# Substitute placeholders
sed \
    -e "s|INSTALL_DIR|${INSTALL_DIR}|g" \
    -e "s|DROPBOX_SCANNER_PATH|${DROPBOX_PATH}|g" \
    "$PLIST_SRC" > "$PLIST_DEST"

# Unload if already loaded
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo "   ✓ LaunchAgent loaded"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Installation complete ==="
echo ""
echo "  Watching:     ${DROPBOX_PATH}"
echo "  Notes folder: ${NOTES_FOLDER}"
echo "  Logs:         ${INSTALL_DIR}/logs/scanner.log"
echo ""
echo "Drop a PDF into ${DROPBOX_PATH} to test."
echo "Tail logs with: tail -f ${INSTALL_DIR}/logs/scanner.log"
echo ""
echo "To uninstall:"
echo "  launchctl unload ~/Library/LaunchAgents/com.user.scanner-to-notes.plist"
echo "  rm ~/Library/LaunchAgents/com.user.scanner-to-notes.plist"
echo ""
