#!/bin/bash
# run.sh — Triggered by launchd when new files appear in the scanner Dropbox folder.
# Finds unprocessed PDFs, runs OCR + AI analysis, creates Apple Notes.

set -euo pipefail

# ── Single-instance guard ────────────────────────────────────────────────────
# Keeps a manual run and a launchd-triggered run from processing the same
# PDFs at the same time, which would create duplicate notes / attachments.
# (macOS doesn't ship flock(1), so we use an atomic mkdir as a lock.)
LOCK_DIR="/tmp/folder-to-notes.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Only back off if the owner is still alive. A run that was SIGKILLed
    # can't clean up after itself, and a stale lock would otherwise make
    # every later run exit silently until the next reboot.
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# ── Configuration ────────────────────────────────────────────────────────────
# Resolve BASE_DIR to the repo root (parent of this scripts/ folder),
# regardless of where the project is installed.
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Folder paths come from state/config, written by install.sh. Re-run the
# installer to change them (it also updates the launchd WatchPaths).
SAVED_DROPBOX_PATH="${HOME}/Dropbox/Scanner"
SAVED_NOTES_FOLDER="Scanned Documents"
if [[ -f "${BASE_DIR}/state/config" ]]; then
    # shellcheck disable=SC1091
    source "${BASE_DIR}/state/config"
fi
DROPBOX_FOLDER="$SAVED_DROPBOX_PATH"
NOTES_FOLDER="$SAVED_NOTES_FOLDER"   # Folder name inside Apple Notes / iCloud

BIN="${BASE_DIR}/bin/process_scan"
CREATE_NOTE="${BASE_DIR}/scripts/create_note.py"
DONE_FOLDER="${DROPBOX_FOLDER}/ImportComplete"
# Older versions recorded handled filenames here instead of moving the PDFs.
LEGACY_PROCESSED="${BASE_DIR}/state/processed.txt"
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

# Move a handled PDF into ImportComplete/ so it won't be picked up again.
# The destination folder lives inside the watched Dropbox folder, so the
# state survives moves between machines (Dropbox syncs the move) and
# there's no local-only state file to lose.
# If a same-named file already exists there, suffix with timestamp.
move_to_done() {
    local pdf="$1" filename="$2"
    local dest="${DONE_FOLDER}/${filename}"
    if [[ -e "$dest" ]]; then
        local ts
        ts=$(date '+%Y%m%d-%H%M%S')
        dest="${DONE_FOLDER}/${filename%.*} (${ts}).${filename##*.}"
    fi
    mv "$pdf" "$dest"
}

# Sanity checks
[[ -x "$BIN" ]]           || die "Swift binary not found at $BIN — run install.sh"
[[ -f "$CREATE_NOTE" ]]   || die "create_note.py not found at $CREATE_NOTE"
[[ -d "$DROPBOX_FOLDER" ]] || { log "Dropbox folder not found: $DROPBOX_FOLDER — skipping run"; exit 0; }

# launchd runs this as a bare /bin/bash, so macOS privacy controls (TCC)
# apply to bash itself. Without access to Dropbox (which lives under
# ~/Library/CloudStorage), the -d check above still passes but listing the
# folder fails with "Operation not permitted". Say so instead of quietly
# reporting 0 PDFs.
if ! list_err=$(ls "$DROPBOX_FOLDER" 2>&1 >/dev/null); then
    die "Cannot list ${DROPBOX_FOLDER}: ${list_err} — give /bin/bash access to it (see README → Permissions)"
fi

mkdir -p "$DONE_FOLDER"

# Brief pause — Dropbox may still be syncing when launchd fires
sleep 3

log "Scanning ${DROPBOX_FOLDER} for new PDFs..."

found=0
processed=0

while IFS= read -r -d '' pdf; do
    filename=$(basename "$pdf")
    found=$((found + 1))

    # Imported by an older version, which left the PDF in place — move it
    # aside without creating a duplicate note.
    if [[ -f "$LEGACY_PROCESSED" ]] && grep -qxF "$filename" "$LEGACY_PROCESSED"; then
        log "  Already imported (state/processed.txt): $filename — moving to ImportComplete"
        move_to_done "$pdf" "$filename" || log "  WARN: could not move $filename to ImportComplete"
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

    # Run Swift OCR + AI tool, capture JSON. For non-English scans it also
    # writes an English overlay PDF into the work dir — outside the watched
    # folder, so it's never picked up as a new scan.
    work=$(mktemp -d)
    tmpjson="${work}/output.json"
    if ! "$BIN" "$pdf" --translated-pdf "${work}/${filename%.*} (English).pdf" >"$tmpjson" 2>>"$LOG"; then
        log "  ERROR: process_scan failed for $filename"
        rm -rf "$work"
        continue
    fi

    # Parse JSON fields
    title=$(python3 -c "import sys,json; print(json.load(open('$tmpjson'))['title'])")
    summary=$(python3 -c "import sys,json; print(json.load(open('$tmpjson'))['summary'])")
    keywords=$(python3 -c "import sys,json; print(', '.join(json.load(open('$tmpjson'))['keywords']))")
    source_lang=$(python3 -c "import sys,json; print(json.load(open('$tmpjson')).get('sourceLanguage') or '')")
    translation=$(python3 -c "import sys,json; print(json.load(open('$tmpjson')).get('translation') or '')")
    translated_pdf=$(python3 -c "import sys,json; print(json.load(open('$tmpjson')).get('translatedPdf') or '')")

    log "  Title: $title"
    log "  Keywords: $keywords"
    [[ -n "$source_lang" ]] && log "  Source language: $source_lang (translation included)"
    [[ -n "$translated_pdf" ]] && log "  English PDF: $(basename "$translated_pdf")"

    # Create Apple Note
    if python3 "$CREATE_NOTE" \
        --title    "$title" \
        --summary  "$summary" \
        --keywords "$keywords" \
        --source-lang "$source_lang" \
        --translation "$translation" \
        --translated-pdf "$translated_pdf" \
        --pdf      "$pdf" \
        --folder   "$NOTES_FOLDER" 2>>"$LOG"; then

        log "  ✓ Note created: $title"

        if move_to_done "$pdf" "$filename"; then
            processed=$((processed + 1))
        else
            log "  WARN: Note created but could not move $filename to ImportComplete"
        fi
        # Keep the English PDF next to the original.
        if [[ -n "$translated_pdf" ]]; then
            move_to_done "$translated_pdf" "$(basename "$translated_pdf")" \
                || log "  WARN: could not move English PDF to ImportComplete"
        fi
    else
        log "  ERROR: Failed to create note for $filename"
    fi
    rm -rf "$work"

# -H: follow the folder itself if it's a symlink. -iname: scanners often
# write .PDF. Skip dotfiles (AppleDouble ._ files, sync temp files).
done < <(find -H "$DROPBOX_FOLDER" -maxdepth 1 -type f -iname "*.pdf" ! -name ".*" -print0 2>>"$LOG")

log "Done — found $found PDF(s), processed $processed new."
