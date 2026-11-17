#!/bin/bash
# Runs INSIDE the chroot with an Android session running.
# Saves a copy of every app installed by Google Play to roms/android/apk/google-play/<package>/
# (base.apk + any split APKs), so APK Manager can reinstall them later without the Play Store.
#   store-play-apps.sh            store new/updated Play installs
#   store-play-apps.sh --list     print packages installed by Google Play
STORE=/mnt/android-roms/apk/google-play
ADATA=/root/.local/share/waydroid/data     # Android's /data, seen from the chroot
mkdir -p "$STORE"

play_pkgs() {
    waydroid shell -- pm list packages -3 -i 2>/dev/null | tr -d '\r' |
        awk '/installer=com.android.vending/ {sub(/^package:/,"",$1); print $1}'
}

[ "$1" = "--list" ] && { play_pkgs; exit 0; }

n=0
for pkg in $(play_pkgs); do
    path=$(waydroid shell -- pm path "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -n1)
    [ -n "$path" ] || continue
    src="$ADATA${path#/data}"; src="$(dirname "$src")"
    [ -d "$src" ] || continue
    ver=$(waydroid shell -- dumpsys package "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/.*versionName=//p' | head -n1)
    dst="$STORE/$pkg"
    [ -f "$dst/.version" ] && [ "$(cat "$dst/.version")" = "$ver" ] && continue   # already stored
    rm -rf "$dst"; mkdir -p "$dst"
    cp -f "$src"/*.apk "$dst/" 2>/dev/null || { rm -rf "$dst"; continue; }
    echo "$ver" > "$dst/.version"
    waydroid app list 2>/dev/null | awk -v p="$pkg" '/^Name:/{n=substr($0,7)} /^packageName:/{if($2==p)print n}' > "$dst/.name"
    n=$((n+1))
done
echo "stored $n Google Play app(s) in $STORE"
