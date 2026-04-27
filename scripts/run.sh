#!/bin/bash
# run.sh — Triggered by launchd when new files appear in the scanner Dropbox folder.
# Finds unprocessed PDFs, runs OCR + AI analysis, creates Apple Notes.

set -euo pipefail

# ── Single-instance guard ────────────────────────────────────────────────────
# launchd can fire WatchPaths events twice in rapid succession for a single
# file change. Without this, two concurrent runs both pass the processed.txt
# check and we create duplicate notes / attachments.
LOCK_FILE="/tmp/scanner-to-notes.lock"
exec 9>"$LOCK_FILE"
if ! /usr/bin/flock -n 9; then
    # Another instance is already handling this batch — exit silently.
    exit 0
fi

# ── Configuration ────────────────────────────────────────────────────────────
DROPBOX_FOLDER="/Users/zac/Dropbox/Scanner"
NOTES_FOLDER="Inbox"       # Folder name inside Apple Notes / iCloud

# Resolve BASE_DIR to the repo root (parent of this scripts/ folder),
# regardless of where the project is installed.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BASE_DIR}/bin/process_scan"
CREATE_NOTE="${BASE_DIR}/scripts/create_note.py"
PROCESSED_FILE="${BASE_DIR}/state/processed.txt"
LOG="${BASE_DIR}/logs/scanner.log"
# ─────────────────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

die() {
    log "FATAL: $*"
    exit 1
}

# Sanity checks
[[ -x "$BIN" ]]           || die "Swift binary not found at $BIN — run install.sh"
[[ -f "$CREATE_NOTE" ]]   || die "create_note.py not found at $CREATE_NOTE"
[[ -d "$DROPBOX_FOLDER" ]] || { log "Dropbox folder not found: $DROPBOX_FOLDER — skipping run"; exit 0; }

touch "$PROCESSED_FILE"

# Brief pause — Dropbox may still be syncing when launchd fires
sleep 3

log "Scanning ${DROPBOX_FOLDER} for new PDFs..."

found=0
processed=0

while IFS= read -r -d '' pdf; do
    filename=$(basename "$pdf")
    found=$((found + 1))

    # Already handled?
    if grep -qxF "$filename" "$PROCESSED_FILE"; then
        continue
    fi

    # Wait for file size to stabilise (still syncing guard)
    size1=$(stat -f%z "$pdf" 2>/dev/null || echo 0)
    sleep 2
    size2=$(stat -f%z "$pdf" 2>/dev/null || echo 0)
    if [[ "$size1" != "$size2" ]]; then
        log "  Skipping $filename — file size still changing, will retry next run"
        continue
    fi

    log "  Processing: $filename"

    # Run Swift OCR + AI tool, capture JSON
    tmpjson=$(mktemp)
    if ! "$BIN" "$pdf" >"$tmpjson" 2>>"$LOG"; then
        log "  ERROR: process_scan failed for $filename"
        rm -f "$tmpjson"
        continue
    fi

    # Parse JSON fields
    title=$(python3 -c "import sys,json; print(json.load(open('$tmpjson'))['title'])")
    summary=$(python3 -c "import sys,json; print(json.load(open('$tmpjson'))['summary'])")
    keywords=$(python3 -c "import sys,json; print(', '.join(json.load(open('$tmpjson'))['keywords']))")
    rm -f "$tmpjson"

    log "  Title: $title"
    log "  Keywords: $keywords"

    # Create Apple Note
    if python3 "$CREATE_NOTE" \
        --title    "$title" \
        --summary  "$summary" \
        --keywords "$keywords" \
        --pdf      "$pdf" \
        --folder   "$NOTES_FOLDER" 2>>"$LOG"; then

        log "  ✓ Note created: $title"
        echo "$filename" >> "$PROCESSED_FILE"
        processed=$((processed + 1))
    else
        log "  ERROR: Failed to create note for $filename"
    fi

done < <(find "$DROPBOX_FOLDER" -maxdepth 1 -name "*.pdf" -print0 2>/dev/null)

log "Done — found $found PDF(s), processed $processed new."
