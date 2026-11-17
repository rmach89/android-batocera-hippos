#!/bin/bash
# Install one Android package file (runs INSIDE the chroot, Android session running).
#   install-package.sh <file>
# Supported:
#   .apk    single APK
#   .xapk   APKPure bundle: base + split APKs, optional game data (Android/obb/<package>/)
#   .apks   SAI / bundletool split-APK set
#   .apkm   APKMirror bundle (unencrypted ones; encrypted .apkm needs APKMirror Installer)
# Exit 0 = installed. Prints one result line.
F="$1"
ADATA=/root/.local/share/waydroid/data          # Android's /data, seen from the chroot
STAGE="$ADATA/local/tmp/apkm"                   # = /data/local/tmp/apkm inside Android
WORK=/tmp/pkg-install
[ -f "$F" ] || { echo "FAIL  $(basename "$F"): not found"; exit 1; }
NAME="$(basename "$F")"
ext="${NAME##*.}"; ext="${ext,,}"

cleanup() { rm -rf "$WORK" "$STAGE"; }
trap cleanup EXIT

# --- plain APK -------------------------------------------------------------------------
if [ "$ext" = apk ]; then
    out=$(waydroid app install "$F" 2>&1) && { echo "OK    $NAME"; exit 0; }
    echo "FAIL  $NAME: ${out##*$'\n'}"; exit 1
fi

case "$ext" in xapk|apks|apkm|zip) ;; *) echo "FAIL  $NAME: unsupported type .$ext"; exit 1 ;; esac

# --- bundles: unpack -------------------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK"
if ! python3 -m zipfile -e "$F" "$WORK" 2>/dev/null; then
    [ "$ext" = apkm ] && { echo "FAIL  $NAME: encrypted .apkm - unlock it with APKMirror Installer first"; exit 1; }
    echo "FAIL  $NAME: not a valid $ext archive"; exit 1
fi
mapfile -t APKS < <(find "$WORK" -type f -iname '*.apk' | sort)
[ ${#APKS[@]} -gt 0 ] || { echo "FAIL  $NAME: no APKs inside"; exit 1; }

# package name (for game data): xapk manifest.json / apkm info.json, else the base APK
PKG=$(python3 - "$WORK" <<'PY' 2>/dev/null
import json, os, sys
w = sys.argv[1]
for f, key in (("manifest.json", "package_name"), ("info.json", "pname")):
    p = os.path.join(w, f)
    if os.path.exists(p):
        try:
            print(json.load(open(p, encoding="utf-8", errors="ignore"))[key]); break
        except Exception:
            pass
PY
)
if [ -z "$PKG" ] && command -v aapt >/dev/null; then
    base=$(printf '%s\n' "${APKS[@]}" | grep -m1 -iE '/base\.apk$|/[^/]*\.apk$')
    PKG=$(aapt dump badging "$base" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
fi

# --- install the APK set -----------------------------------------------------------------
install_set() {   # install_set <apk files...>
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    local i=0 list="" a
    for a in "$@"; do i=$((i+1)); cp -f "$a" "$STAGE/$i.apk"; list+="/data/local/tmp/apkm/$i.apk "; done
    chmod 755 "$STAGE"; chmod 644 "$STAGE"/*.apk
    if [ "$#" -eq 1 ]; then
        waydroid app install "$1" >/dev/null 2>&1
    else
        waydroid shell -- sh -c "pm install-multiple -r $list" 2>&1 | tr -d '\r' | grep -q '^Success'
    fi
}

# Splits for the wrong CPU type / extra screen sizes can make Android refuse the set.
# Second try: base + feature/language splits + ONE CPU split + ONE screen-density split.
filtered_set() {
    local a b keep=() abi="" dpi=""
    for want in x86_64 arm64_v8a x86 armeabi_v7a; do
        printf '%s\n' "${APKS[@]}" | grep -qi "config\.$want\.apk" && { abi="$want"; break; }
    done
    for want in xxhdpi xhdpi xxxhdpi hdpi mdpi; do
        printf '%s\n' "${APKS[@]}" | grep -qi "config\.$want\.apk" && { dpi="$want"; break; }
    done
    for a in "${APKS[@]}"; do
        b="$(basename "$a")"; b="${b,,}"
        case "$b" in
            config.x86_64.apk|config.arm64_v8a.apk|config.x86.apk|config.armeabi_v7a.apk|config.armeabi.apk)
                [ "$b" = "config.$abi.apk" ] && keep+=("$a") ;;
            config.*dpi.apk)
                [ "$b" = "config.$dpi.apk" ] && keep+=("$a") ;;
            *) keep+=("$a") ;;
        esac
    done
    printf '%s\n' "${keep[@]}"
}

if ! install_set "${APKS[@]}"; then
    mapfile -t SUB < <(filtered_set)
    install_set "${SUB[@]}" || { echo "FAIL  $NAME: Android rejected the split APKs"; exit 1; }
fi

# --- game data (OBB), xapk style: Android/obb/<package>/main.*.obb --------------------------
OBB_NOTE=""
OBBDIR=$(find "$WORK" -mindepth 3 -maxdepth 4 -type d -path '*Android/obb/*' | head -n1)
if [ -n "$OBBDIR" ]; then
    opkg="$(basename "$OBBDIR")"
    rm -rf "$STAGE"; mkdir -p "$STAGE/obb"
    cp -f "$OBBDIR"/* "$STAGE/obb/" && chmod -R a+rX "$STAGE"
    # copy from inside Android so the files get the right owner/permissions
    if waydroid shell -- sh -c "mkdir -p /sdcard/Android/obb/$opkg && cp -f /data/local/tmp/apkm/obb/* /sdcard/Android/obb/$opkg/" >/dev/null 2>&1; then
        OBB_NOTE=" + game data"
    else
        OBB_NOTE=" (game data copy FAILED)"
    fi
fi

echo "OK    $NAME${PKG:+ ($PKG)}$OBB_NOTE"
exit 0
