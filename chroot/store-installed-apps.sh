#!/bin/bash
# Runs INSIDE the chroot with an Android session running (called when you leave Android).
# Keeps a copy of every app installed from an app store, one folder per store:
#   roms/android/apk/google-play/<package>/   Google Play
#   roms/android/apk/f-droid/<package>/       F-Droid
#   roms/android/apk/aurora/<package>/        Aurora Store
#   roms/android/apk/aptoide/<package>/       Aptoide
# (base.apk + any split APKs), so APK Manager can reinstall them without the store.
# Apps you installed from files are not copied - the file itself is in apk/installed/.
APKROOT=${ANDROID_APK_DIR:-/mnt/android-roms/apk}
ADATA=${ANDROID_DATA_DIR:-/root/.local/share/waydroid/data}     # Android's /data, seen from the chroot

n=0
while IFS=$'\t' read -r pkg sid _label name; do
    case "$sid" in google-play|f-droid|aurora|aptoide) ;; *) continue ;; esac
    path=$(waydroid shell -- pm path "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -n1)
    [ -n "$path" ] || continue
    src="$(dirname "$ADATA${path#/data}")"
    [ -d "$src" ] || continue
    ver=$(waydroid shell -- dumpsys package "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/.*versionName=//p' | head -n1)
    dst="$APKROOT/$sid/$pkg"
    [ -f "$dst/.version" ] && [ "$(cat "$dst/.version")" = "$ver" ] && continue   # already stored
    rm -rf "$dst"; mkdir -p "$dst"
    cp -f "$src"/*.apk "$dst/" 2>/dev/null || { rm -rf "$dst"; continue; }
    echo "$ver"  > "$dst/.version"
    echo "$name" > "$dst/.name"
    n=$((n+1))
done < <(/opt/android/installed-apps.sh)
echo "stored $n store app(s) in $APKROOT/<store>/"
