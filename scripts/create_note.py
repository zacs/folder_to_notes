#!/usr/bin/env python3
"""
create_note.py — Creates an Apple Note with a summary body and PDF attachment.

Usage:
    python3 create_note.py \
        --title "Invoice - Acme Corp - Jan 2025" \
        --summary "Invoice for services rendered..." \
        --keywords "invoice, acme, 2025, billing" \
        --pdf "/path/to/file.pdf" \
        --folder "Scanned Documents"
"""

import argparse
import subprocess
import sys


def build_note_body(summary: str, keywords: str, filename: str) -> str:
    """Build an HTML body for the note — Notes renders basic HTML."""
    return (
        f"<b>Summary</b><br>{summary}"
        f"<br><br><b>Keywords</b><br>{keywords}"
        f"<br><br><b>Source file</b><br>{filename}"
    )


def applescript_escape(s: str) -> str:
    """Escape a string for safe embedding in an AppleScript string literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def create_note(title: str, body: str, pdf_path: str, folder: str) -> bool:
    t = applescript_escape(title)
    b = applescript_escape(body)
    f = applescript_escape(folder)
    p = applescript_escape(pdf_path)

    script = f'''
tell application "Notes"
    set targetFolder to missing value
    tell account "iCloud"
        repeat with aFolder in folders
            if name of aFolder is "{f}" then
                set targetFolder to aFolder
                exit repeat
            end if
        end repeat
        if targetFolder is missing value then
            set targetFolder to make new folder with properties {{name:"{f}"}}
        end if
        tell targetFolder
            set newNote to make new note with properties {{name:"{t}", body:"{b}"}}
            tell newNote
                make new attachment with properties {{file:POSIX file "{p}"}}
            end tell
        end tell
    end tell
end tell
'''

    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"AppleScript error: {result.stderr.strip()}", file=sys.stderr)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Create an Apple Note from a scanned document")
    parser.add_argument("--title",    required=True)
    parser.add_argument("--summary",  required=True)
    parser.add_argument("--keywords", required=True)
    parser.add_argument("--pdf",      required=True)
    parser.add_argument("--folder",   default="Scanned Documents")
    args = parser.parse_args()

    body = build_note_body(args.summary, args.keywords, args.pdf.split("/")[-1])

    success = create_note(
        title=args.title,
        body=body,
        pdf_path=args.pdf,
        folder=args.folder,
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
