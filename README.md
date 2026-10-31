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
   (saved to `state/config`, which `scripts/run.sh` reads)
2. Compile the Swift binary
3. Install and load the launchd agent

Then grant the permissions below — without them the agent runs but can't see
your scans.

---

## Permissions

launchd runs `scripts/run.sh` with a bare `/bin/bash` — no Terminal window
involved — so macOS privacy controls apply to `/bin/bash` itself. On current
macOS, Dropbox lives under `~/Library/CloudStorage` (managed by macOS's File
Provider), and a background `bash` can't list it until you allow it. When
that's the problem, the log says:

```
FATAL: Cannot list /Users/you/Dropbox/Scanner: ... Operation not permitted ...
```

To fix it, open System Settings → Privacy & Security → Full Disk Access, click
**+**, press ⌘⇧G, enter `/bin/bash`, and turn it on. Note that Full Disk Access
applies to every script launchd runs with `/bin/bash`, not just this one.

If notes stop appearing, check the log for the `FATAL` line above.

The first note created also asks to let `bash` control Notes (Privacy &
Security → Automation).

---

## How it works

```
Dropbox folder (local sync)
        │  launchd WatchPaths fires on any change
        ▼
   scripts/run.sh
        │  finds new .pdf files at the top of the watched folder
        │  (anything in ImportComplete/ has already been handled)
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

   Then: PDF is moved into Dropbox/Scanner/ImportComplete/
   so it won't be reprocessed (state lives in Dropbox — survives
   moving to a new machine).
```

---

## File structure

```
~/.folder-to-notes/
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
│   └── config              ← Dropbox + Notes folder (written by install.sh)
└── logs/
    ├── scanner.log
    └── scanner-error.log
```

Processed PDFs are moved into `<your-Dropbox-scanner-folder>/ImportComplete/`,
which is the durable record of what's already been handled. Because that folder
lives inside Dropbox, the state syncs across machines — no risk of
reprocessing every PDF if you set this up on a second Mac.

---

## Tips

**Tail the log:**
```bash
tail -f ~/.folder-to-notes/logs/scanner.log
```

**Manually trigger a run** (as launchd runs it, so permission problems show up):
```bash
launchctl kickstart gui/$(id -u)/com.user.folder-to-notes
```

**Test the Swift tool standalone:**
```bash
~/.folder-to-notes/bin/process_scan ~/path/to/test.pdf
```

**Reprocess a file** (if something went wrong):
```bash
# Move it back from the ImportComplete folder to the watched folder
mv ~/Dropbox/Scanner/ImportComplete/filename.pdf ~/Dropbox/Scanner/
# Then drop another file in the folder, or run manually
```

**Change the Dropbox folder or Notes folder:**
Re-run the installer (or the bootstrap one-liner). It saves the new values to
`state/config` and updates the launchd watch path:
```bash
bash ~/.folder-to-notes/install.sh
```

---

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.user.folder-to-notes.plist
rm ~/Library/LaunchAgents/com.user.folder-to-notes.plist
rm -rf ~/.folder-to-notes
```
