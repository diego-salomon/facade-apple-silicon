#!/usr/bin/env bash
#
# uninstall.sh — remove everything install.sh created, and nothing else.
#
# Deletes:
#   • ~/Applications/Facade.app        (the wrapper, including its save transcripts)
#   • ~/Library/Caches/facade-apple-silicon   (the download cache, if kept)
#
# It does NOT touch Rosetta, Homebrew, or any other app.
#
#   Usage:  ./uninstall.sh [--yes]

set -euo pipefail

APP_DIR="$HOME/Applications/Facade.app"
CACHE_DIR="${FACADE_CACHE:-$HOME/Library/Caches/facade-apple-silicon}"

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

targets=()
[ -d "$APP_DIR" ]   && targets+=("$APP_DIR")
[ -d "$CACHE_DIR" ] && targets+=("$CACHE_DIR")

if [ ${#targets[@]} -eq 0 ]; then
  echo "Nothing to remove — Façade is not installed here."
  exit 0
fi

echo "This will permanently delete:"
for t in "${targets[@]}"; do echo "  • $t"; done

# Warn if the wrapper holds saved transcripts the user may want.
plays="$APP_DIR/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Facade/stageplays"
if [ -d "$plays" ] && [ "$(ls -A "$plays" 2>/dev/null)" ]; then
  echo
  echo "Note: $(ls "$plays" | wc -l | tr -d ' ') saved stageplay transcript(s) in the wrapper will be lost."
  echo "      Copy them out first if you want to keep them:"
  echo "      open \"$plays\""
fi

if [ $ASSUME_YES -eq 0 ]; then
  echo
  read -r -p "Delete them? [y/N] " ans
  case "${ans:-N}" in [yY]*) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

for t in "${targets[@]}"; do rm -rf "$t" && echo "removed $t"; done
echo "Done."
