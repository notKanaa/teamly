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
# Attachment names of App/UITests/ScreenshotTests.swift (the design checks' captures go to debug/).
EXPECTED=(01-connexion 02-groupes 03-creer-groupe 04-code-invitation 05-nouvelle-tache 06-detail-groupe 07-mes-taches 08-membres 09-reglages
  10-reglages-compte 11-onboarding-bienvenue 12-onboarding-avatar 13-onboarding-groupe 14-onboarding-notifications)

# v2 task screens (App/UITests/TasksFlowTests.swift and TasksScreenshotTests.swift).
EXPECTED+=(07-mes-taches-sombre 18-mes-taches-vitrine 19-tache-checklist 20-nouvelle-tache-repetition)

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
  # The expected captures go to $OUT; every other attachment (automatic screenshots of failures, debug
  # descriptions) goes to $OUT/debug, prefixed by its test, with a file-system-safe name (artifact uploads
  # refuse " : < > | * ? and new lines).
  mkdir -p "$OUT/debug"
  jq -r '.[] | (.testIdentifier // "test") as $test | .attachments[]?
         | [.exportedFileName, (.suggestedHumanReadableName // .exportedFileName), $test] | @tsv' "$MANIFEST" |
    while IFS=$'\t' read -r file name test; do
      case "$file" in *.*) ext="${file##*.}" ;; *) ext="png" ;; esac
      base="$(printf '%s' "$name" | sed -E \
        -e 's/\.[A-Za-z0-9]+$//' \
        -e 's/(_[0-9]+)?(_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})?$//')"
      [ -n "$base" ] || base="${file%.*}"
      is_expected=0
      for expected in "${EXPECTED[@]}"; do [ "$base" = "$expected" ] && is_expected=1; done
      if [ "$is_expected" = 1 ]; then
        cp "$RAW/$file" "$OUT/$base.$ext" 2>/dev/null || echo "Could not copy $file ($name)."
      else
        safe="$(printf '%s--%s' "${test##*/}" "$base" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120)"
        cp "$RAW/$file" "$OUT/debug/$safe.$ext" 2>/dev/null || echo "Could not copy $file ($name)."
      fi
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
