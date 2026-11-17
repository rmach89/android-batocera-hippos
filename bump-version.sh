#!/bin/bash
# Bump the add-on version: v1.x.x where every digit rolls over at 10.
#   1.0.8 -> 1.0.9 -> 1.1.0      1.9.9 -> 2.0.0
#   ./bump-version.sh          bump by one
#   ./bump-version.sh 3        bump by three
#   ./bump-version.sh --show   print the current version
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FILE="$DIR/VERSION"
[ -f "$FILE" ] || echo "1.0.0" > "$FILE"
IFS=. read -r MAJ MIN PAT < "$FILE"

if [ "$1" = "--show" ]; then echo "v$MAJ.$MIN.$PAT"; exit 0; fi
STEPS="${1:-1}"
case "$STEPS" in ''|*[!0-9]*) echo "Usage: $0 [steps|--show]"; exit 1 ;; esac

OLD="v$MAJ.$MIN.$PAT"
for _ in $(seq 1 "$STEPS"); do
    PAT=$((PAT + 1))
    if [ "$PAT" -ge 10 ]; then PAT=0; MIN=$((MIN + 1)); fi
    if [ "$MIN" -ge 10 ]; then MIN=0; MAJ=$((MAJ + 1)); fi
done
echo "$MAJ.$MIN.$PAT" > "$FILE"
[ -f "$DIR/README.md" ] && sed -i "s/^\*\*Version: v[0-9]*\.[0-9]*\.[0-9]*\*\*/**Version: v$MAJ.$MIN.$PAT**/" "$DIR/README.md"
echo "$OLD -> v$MAJ.$MIN.$PAT"
