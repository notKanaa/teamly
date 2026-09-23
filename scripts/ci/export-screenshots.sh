#!/usr/bin/env bash
# Exports XCTAttachments (screenshots) from an .xcresult bundle into a folder, named after the attachment.
# Usage: export-screenshots.sh <result.xcresult> <output-dir>
set -uo pipefail
RESULT="${1:?xcresult path}"
OUT="${2:?output dir}"
if [ ! -d "$RESULT" ]; then
  echo "No result bundle at $RESULT — nothing to export."
  exit 0
fi
mkdir -p "$OUT/raw"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/raw" || { echo "export failed"; exit 0; }
MANIFEST="$OUT/raw/manifest.json"
if [ -f "$MANIFEST" ]; then
  # Rename exported files to their human-readable attachment names (e.g. 01-connexion.png).
  jq -r '.[] | .attachments[]? | [.exportedFileName, (.suggestedHumanReadableName // .exportedFileName)] | @tsv' "$MANIFEST" |
    while IFS=$'\t' read -r file name; do
      base="${name%%_[0-9]*_*}"          # drop xcresulttool's _<index>_<uuid> suffix when present
      ext="${file##*.}"
      case "$base" in *."$ext") target="$base" ;; *) target="$base.$ext" ;; esac
      cp "$OUT/raw/$file" "$OUT/$target" 2>/dev/null || true
    done
fi
ls -la "$OUT"
