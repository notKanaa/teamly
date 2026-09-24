#!/usr/bin/env bash
# Exports the XCTAttachments (screenshots) of an .xcresult bundle into a folder, one file per attachment, named after
# the attachment (e.g. 01-connexion.png). The raw export (UUID file names + manifest.json) goes to <output-dir>-raw,
# so that the uploaded folder only holds the named captures. Never fails the job: missing captures are reported as
# warnings (the UI test failures say why).
# Usage: export-screenshots.sh <result.xcresult> <output-dir>
set -uo pipefail
RESULT="${1:?xcresult path}"
OUT="${2:?output dir}"
OUT="${OUT%/}"
RAW="$OUT-raw"
# Attachment names of App/UITests/ScreenshotTests.swift.
EXPECTED=(01-connexion 02-groupes 03-creer-groupe 04-code-invitation 05-nouvelle-tache 06-detail-groupe 07-mes-taches 08-membres 09-reglages)

if [ ! -d "$RESULT" ]; then
  echo "No result bundle at $RESULT — nothing to export."
  exit 0
fi
rm -rf "$RAW"
mkdir -p "$OUT" "$RAW"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RAW" || { echo "export failed"; exit 0; }

MANIFEST="$RAW/manifest.json"
if [ -f "$MANIFEST" ]; then
  # Rename the exported files to their attachment names: xcresulttool suggests "<name>_<index>_<uuid>.<ext>".
  jq -r '.[] | .attachments[]? | [.exportedFileName, (.suggestedHumanReadableName // .exportedFileName)] | @tsv' "$MANIFEST" |
    while IFS=$'\t' read -r file name; do
      case "$file" in *.*) ext="${file##*.}" ;; *) ext="png" ;; esac
      base="$(printf '%s' "$name" | sed -E \
        -e 's/\.[A-Za-z0-9]+$//' \
        -e 's/(_[0-9]+)?(_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})?$//')"
      [ -n "$base" ] || base="${file%.*}"
      cp "$RAW/$file" "$OUT/$base.$ext" 2>/dev/null || echo "Could not copy $file ($name)."
    done
else
  echo "No manifest.json in the export: copying the attachments with their exported names."
  cp "$RAW"/* "$OUT"/ 2>/dev/null || true
fi

found=0
for name in "${EXPECTED[@]}"; do
  if [ -f "$OUT/$name.png" ]; then
    found=$((found + 1))
  else
    echo "::warning title=Screenshots::Missing capture $name.png (see the UI test failures)."
  fi
done
echo "Screenshots: $found of ${#EXPECTED[@]} expected captures exported to $OUT."
ls -la "$OUT"
