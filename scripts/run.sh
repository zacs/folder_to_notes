#!/bin/bash
# run.sh — Triggered by launchd when new files appear in the scanner Dropbox folder.
# Finds unprocessed PDFs, runs OCR + AI analysis, creates Apple Notes.

set -euo pipefail

# ── Single-instance guard ────────────────────────────────────────────────────
# launchd can fire WatchPaths events twice in rapid succession for a single
# file change. Without this, two concurrent runs both try to process the same
# PDFs and we create duplicate notes / attachments.
# (macOS doesn't ship flock(1), so we use an atomic mkdir as a lock.)
LOCK_DIR="/tmp/folder-to-notes.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Another instance is already handling this batch — exit silently.
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# ── Configuration ────────────────────────────────────────────────────────────
DROPBOX_FOLDER="/Users/zac/Dropbox/Scanner"
NOTES_FOLDER="Inbox"       # Folder name inside Apple Notes / iCloud

# Resolve BASE_DIR to the repo root (parent of this scripts/ folder),
# regardless of where the project is installed.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BASE_DIR}/bin/process_scan"
CREATE_NOTE="${BASE_DIR}/scripts/create_note.py"
DONE_FOLDER="${DROPBOX_FOLDER}/ImportComplete"
LOG="${BASE_DIR}/logs/scanner.log"
# ─────────────────────────────────────────────────────────────────────────────

log() {
    # Write only to the log file. launchd already redirects stdout/stderr to
    # scanner.log / scanner-error.log via the plist, so tee'ing here would
    # cause every line to appear twice.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

die() {
    log "FATAL: $*"
    exit 1
}

# Sanity checks
[[ -x "$BIN" ]]           || die "Swift binary not found at $BIN — run install.sh"
[[ -f "$CREATE_NOTE" ]]   || die "create_note.py not found at $CREATE_NOTE"
[[ -d "$DROPBOX_FOLDER" ]] || { log "Dropbox folder not found: $DROPBOX_FOLDER — skipping run"; exit 0; }

mkdir -p "$DONE_FOLDER"

# Brief pause — Dropbox may still be syncing when launchd fires
sleep 3

log "Scanning ${DROPBOX_FOLDER} for new PDFs..."

found=0
processed=0

while IFS= read -r -d '' pdf; do
    filename=$(basename "$pdf")
    found=$((found + 1))

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
    source_lang=$(python3 -c "import sys,json; print(json.load(open('$tmpjson')).get('sourceLanguage') or '')")
    translation=$(python3 -c "import sys,json; print(json.load(open('$tmpjson')).get('translation') or '')")
    rm -f "$tmpjson"

    log "  Title: $title"
    log "  Keywords: $keywords"
    [[ -n "$source_lang" ]] && log "  Source language: $source_lang (translation included)"

    # Create Apple Note
    if python3 "$CREATE_NOTE" \
        --title    "$title" \
        --summary  "$summary" \
        --keywords "$keywords" \
        --source-lang "$source_lang" \
        --translation "$translation" \
        --pdf      "$pdf" \
        --folder   "$NOTES_FOLDER" 2>>"$LOG"; then

        log "  ✓ Note created: $title"

        # Move processed PDF into ImportComplete/ so it won't be picked up
        # again. The destination folder lives inside the watched Dropbox
        # folder, so the state survives moves between machines (Dropbox
        # syncs the move) and there's no local-only state file to lose.
        # If a same-named file already exists there, suffix with timestamp.
        dest="${DONE_FOLDER}/${filename}"
        if [[ -e "$dest" ]]; then
            ts=$(date '+%Y%m%d-%H%M%S')
            base="${filename%.pdf}"
            dest="${DONE_FOLDER}/${base} (${ts}).pdf"
        fi
        if mv "$pdf" "$dest"; then
            processed=$((processed + 1))
        else
            log "  WARN: Note created but could not move $filename to ImportComplete"
        fi
    else
        log "  ERROR: Failed to create note for $filename"
    fi

done < <(find "$DROPBOX_FOLDER" -maxdepth 1 -name "*.pdf" -print0 2>/dev/null)

log "Done — found $found PDF(s), processed $processed new."
