# folder-to-notes

_Disclaimer: This was 100% done using AI because I needed something quick. Caveat emptor._

Watches a Dropbox folder for scanned PDFs, OCRs them with Apple Vision,
summarizes them with Apple's on-device Foundation Models, and creates
an Apple Note with title, summary, keywords, and the original PDF attached.

100% local. No API keys. No cloud AI.

---

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon Mac
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Xcode Command Line Tools: `xcode-select --install`
- Dropbox desktop app installed and syncing

---

## Install

One-liner (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/zacs/folder_to_notes/main/bootstrap.sh | bash
```

This clones the repo into `~/.folder-to-notes` and runs the installer. Re-running
the same command later updates to the latest version.

Or manually:

```bash
git clone https://github.com/zacs/folder_to_notes.git ~/.folder-to-notes
cd ~/.folder-to-notes
bash install.sh
```

The installer will:
1. Ask for your Dropbox scanner folder path and target Notes folder name
2. Compile the Swift binary
3. Install and load the launchd agent

---

## How it works

```
Dropbox folder (local sync)
        │  launchd WatchPaths fires on any change
        ▼
   scripts/run.sh
        │  finds new .pdf files not in state/processed.txt
        ▼
   bin/process_scan  (Swift CLI)
        │  Vision framework — OCR each page at 2x scale
        │  Foundation Models — generate title, summary, keywords
        │  outputs JSON to stdout
        ▼
   scripts/create_note.py
        │  AppleScript — creates Note in target folder
        │  attaches original PDF
        ▼
   Apple Notes / iCloud
```

---

## File structure

```
folder-to-notes/
├── install.sh              ← run once to set up
├── Sources/
│   └── main.swift          ← Swift OCR + AI tool
├── scripts/
│   ├── run.sh              ← shell orchestration (called by launchd)
│   └── create_note.py      ← AppleScript wrapper with proper escaping
├── launchd/
│   └── com.user.folder-to-notes.plist  ← launchd template
├── bin/
│   └── process_scan        ← compiled Swift binary (created by install.sh)
├── state/
│   └── processed.txt       ← tracks which files have been handled
└── logs/
    ├── scanner.log
    └── scanner-error.log
```

---

## Tips

**Tail the log:**
```bash
tail -f ~/.folder-to-notes/logs/scanner.log
```

**Manually trigger a run:**
```bash
bash ~/.folder-to-notes/scripts/run.sh
```

**Test the Swift tool standalone:**
```bash
~/.folder-to-notes/bin/process_scan ~/path/to/test.pdf
```

**Reprocess a file** (if something went wrong):
```bash
# Remove its entry from the processed list
sed -i '' '/filename.pdf/d' ~/.folder-to-notes/state/processed.txt
# Then drop the file in the folder or run manually
```

**Change the Dropbox folder or Notes folder:**
Edit the variables at the top of `scripts/run.sh` and reload the agent:
```bash
launchctl unload ~/Library/LaunchAgents/com.user.folder-to-notes.plist
launchctl load  ~/Library/LaunchAgents/com.user.folder-to-notes.plist
```

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.user.folder-to-notes.plist
rm ~/Library/LaunchAgents/com.user.folder-to-notes.plist
rm -rf ~/.folder-to-notes
```
