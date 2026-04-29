#!/bin/bash
# install.sh — Set up folder-to-notes.
# Run once from the project directory: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR"
CONFIG_FILE="$INSTALL_DIR/state/config"

# ── Load previous answers as defaults (if any) ──────────────────────────────
# Saved from a prior install run so re-running the bootstrap is hit-Enter-twice.
DEFAULT_DROPBOX="${HOME}/Dropbox/Scanner"
DEFAULT_NOTES="Scanned Documents"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    DEFAULT_DROPBOX="${SAVED_DROPBOX_PATH:-$DEFAULT_DROPBOX}"
    DEFAULT_NOTES="${SAVED_NOTES_FOLDER:-$DEFAULT_NOTES}"
fi

# ── Prompt for config ────────────────────────────────────────────────────────
echo ""
echo "=== folder-to-notes installer ==="
echo ""

# When invoked via `curl ... | bash`, stdin is the pipe from curl, not the
# user's terminal — so plain `read` gets EOF and prompts are skipped. Read
# from /dev/tty when available so the prompts work in both modes.
if [[ -r /dev/tty ]]; then
    PROMPT_IN=/dev/tty
else
    PROMPT_IN=/dev/stdin
fi

read -rp "Dropbox scanner folder path [${DEFAULT_DROPBOX}]: " DROPBOX_PATH < "$PROMPT_IN"
DROPBOX_PATH="${DROPBOX_PATH:-${DEFAULT_DROPBOX}}"

read -rp "Apple Notes folder name [${DEFAULT_NOTES}]: " NOTES_FOLDER < "$PROMPT_IN"
NOTES_FOLDER="${NOTES_FOLDER:-${DEFAULT_NOTES}}"

echo ""

# ── Directories ──────────────────────────────────────────────────────────────
echo "→ Creating directories..."
mkdir -p "$INSTALL_DIR"/{bin,state,logs}
# Create the ImportComplete folder inside the watched Dropbox folder.
# Processed PDFs are moved here — this is our durable, cross-machine state.
mkdir -p "$DROPBOX_PATH/ImportComplete" 2>/dev/null || true

# ── Persist answers for next time ────────────────────────────────────────────
cat > "$CONFIG_FILE" <<EOF
# Saved by install.sh — used as defaults on the next install run.
SAVED_DROPBOX_PATH="${DROPBOX_PATH}"
SAVED_NOTES_FOLDER="${NOTES_FOLDER}"
EOF

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

PLIST_SRC="$INSTALL_DIR/launchd/com.user.folder-to-notes.plist"
PLIST_DEST="${HOME}/Library/LaunchAgents/com.user.folder-to-notes.plist"
OLD_PLIST_DEST="${HOME}/Library/LaunchAgents/com.user.scanner-to-notes.plist"

# Migrate from old name if present (project was previously called scanner-to-notes).
if [[ -f "$OLD_PLIST_DEST" ]]; then
    echo "   → Removing legacy LaunchAgent (com.user.scanner-to-notes)"
    launchctl unload "$OLD_PLIST_DEST" 2>/dev/null || true
    rm -f "$OLD_PLIST_DEST"
fi

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
echo "  launchctl unload ~/Library/LaunchAgents/com.user.folder-to-notes.plist"
echo "  rm ~/Library/LaunchAgents/com.user.folder-to-notes.plist"
echo ""
