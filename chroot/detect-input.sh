#!/bin/bash
# Runs INSIDE the chroot with an Android session running (called when you leave Android).
# Reads each installed app's manifest and records what input it supports:
#   controller  - declares gamepad support, Android TV (leanback) support, or does not
#                 require a touchscreen  -> playable with a controller
#   touch       - everything else (touch / mouse only)
# Result: /mnt/android-roms/.cache/input-support.txt   lines: package|versionCode|controller|touch
# Wrong guess?  /userdata/system/add-ons/android/settings/controller-overrides.conf
#               package.name=controller | touch | none
OUT=/mnt/android-roms/.cache/input-support.txt
ADATA=${ANDROID_DATA_DIR:-/root/.local/share/waydroid/data}
mkdir -p "$(dirname "$OUT")"; touch "$OUT"
command -v aapt >/dev/null || { echo "detect-input: aapt missing - no badges"; exit 0; }

tmp=$(mktemp)
cp "$OUT" "$tmp"
for pkg in $(waydroid shell -- pm list packages -3 2>/dev/null | tr -d '\r' | sed -n 's/^package://p'); do
    ver=$(waydroid shell -- dumpsys package "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n1)
    grep -q "^$pkg|$ver|" "$tmp" && continue                 # already checked this version
    path=$(waydroid shell -- pm path "$pkg" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | grep -m1 'base.apk')
    apk="$ADATA${path#/data}"
    [ -f "$apk" ] || continue
    badging=$(aapt dump badging "$apk" 2>/dev/null)
    if echo "$badging" | grep -qE "android\.hardware\.gamepad|android\.software\.leanback|leanback-launchable-activity|uses-feature-not-required: name='android\.hardware\.touchscreen'"; then
        kind=controller
    else
        kind=touch
    fi
    sed -i "/^$pkg|/d" "$tmp"
    echo "$pkg|$ver|$kind" >> "$tmp"
    echo "detect-input: $pkg -> $kind"
done
mv -f "$tmp" "$OUT"
