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


def build_note_body(summary: str, keywords: str, filename: str,
                    translation: str = "", source_lang: str = "") -> str:
    """Build an HTML body for the note — Notes renders basic HTML."""
    parts = [
        f"<br><b>Summary</b><br>{html_escape(summary)}",
        f"<br><br><b>Keywords</b><br>{html_escape(keywords)}",
    ]
    if translation:
        label = f"English Translation (from {source_lang})" if source_lang else "English Translation"
        # Preserve paragraph breaks from the model output.
        translation_html = html_escape(translation).replace("\n", "<br>")
        parts.append(f"<br><br><b>{label}</b><br>{translation_html}")
    parts.append(f"<br><br><b>Source file</b><br>{html_escape(filename)}")
    return "".join(parts)


def html_escape(s: str) -> str:
    """Minimal HTML escaping for note body content."""
    return (
        s.replace("&", "&amp;")
         .replace("<", "&lt;")
         .replace(">", "&gt;")
    )


def applescript_escape(s: str) -> str:
    """Escape a string for safe embedding in an AppleScript string literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def create_note(title: str, body: str, pdf_path: str, folder: str) -> bool:
    t = applescript_escape(title)
    b = applescript_escape(body)
    f = applescript_escape(folder)
    p = applescript_escape(pdf_path)

    # Note: Apple Notes' AppleScript attachment API has a long-standing bug
    # where attachments are sometimes registered twice (visible as duplicate
    # PDF chips in the note). The JXA equivalent silently produces zero
    # attachments. Sticking with AppleScript — duplicates are easy to delete
    # manually and at least the file is reliably present.
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
                make new attachment with data (POSIX file "{p}")
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
    parser.add_argument("--translation", default="",
                        help="Optional English translation of the document body.")
    parser.add_argument("--source-lang", default="",
                        help="BCP-47 source language code (used in the translation header).")
    args = parser.parse_args()

    body = build_note_body(
        args.summary,
        args.keywords,
        args.pdf.split("/")[-1],
        translation=args.translation,
        source_lang=args.source_lang,
    )

    success = create_note(
        title=args.title,
        body=body,
        pdf_path=args.pdf,
        folder=args.folder,
    )

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
