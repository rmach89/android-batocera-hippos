#!/bin/bash
# One-line install / update of the newest release:
#   curl -fsSL https://raw.githubusercontent.com/rmach89/android-batocera-hippos/main/get.sh | bash
# Already installed? This updates the add-on (apps, saves and settings are kept).
set -e
REPO="rmach89/android-batocera-hippos"
TMP="/userdata/system/add-ons/.android-get"
[ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null && exec sudo bash "$0" "$@"; echo "Run as root."; exit 1; }

echo "==> Looking up the newest Android add-on release"
JSON="$(curl -fsSL -m 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
if command -v python3 >/dev/null; then
    read -r TAG URL < <(echo "$JSON" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["tag_name"], next((a["browser_download_url"] for a in r.get("assets",[]) if a["name"].endswith(".zip")), ""))')
else
    TAG="$(echo "$JSON" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    URL="$(echo "$JSON" | grep '"browser_download_url"' | grep -m1 '\.zip"' | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"
fi
if [ -z "$TAG" ]; then      # no published release: use the main branch
    TAG="v$(curl -fsSL -m 20 "https://raw.githubusercontent.com/$REPO/main/VERSION")" || { echo "Could not reach GitHub."; exit 1; }
    URL="https://github.com/$REPO/archive/refs/heads/main.zip"
fi
[ -n "$URL" ] || URL="https://github.com/$REPO/archive/refs/tags/$TAG.zip"

echo "==> Downloading $TAG"
rm -rf "$TMP"; mkdir -p "$TMP"
curl -fL --progress-bar -o "$TMP/addon.zip" "$URL"
cd "$TMP"
if command -v unzip >/dev/null; then unzip -q addon.zip; else python3 -m zipfile -e addon.zip .; fi
SRC="$(dirname "$(find "$TMP" -maxdepth 3 -name install.sh | head -n1)")"
[ -f "$SRC/install.sh" ] || { echo "Release has no install.sh"; exit 1; }

if [ -x /userdata/system/add-ons/android/rootfs/usr/bin/waydroid ]; then
    echo "==> Android add-on already installed - updating to $TAG"
    bash "$SRC/install.sh" --repair
    /userdata/system/add-ons/android/bin/android-service restart >/dev/null 2>&1 || true
else
    bash "$SRC/install.sh"
fi
cd /; rm -rf "$TMP"
