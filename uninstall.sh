#!/bin/bash
# Removes the Android add-on.
#   uninstall.sh              remove everything (apps + saves too)
#   uninstall.sh --keep-data  remove menus/service/ES system but keep the Android rootfs
#                             (apps + saves); run install.sh again to bring it all back.
# HippOS: Android is part of HippOS, so its apps and saves are always kept; only the add-on
# goes, and Android Games / Android Apps return to HippOS's standard setup.
# Stored APKs in /userdata/roms/android/apk (incl. google-play/) are never deleted.
SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
if [ -f "$DIR/bin/android-common.sh" ]; then . "$DIR/bin/android-common.sh"
else . /userdata/system/add-ons/android/bin/android-common.sh; fi
need_root "$@"

"$ADDON_DIR/bin/android-theme-logos" --remove 2>/dev/null     # Android logo out of all themes
"$ADDON_DIR/bin/android-service" stop 2>/dev/null
umount_chroot
if [ "$HOST_MODE" = 1 ]; then
    for l in /opt/android /mnt/android-roms /etc/android-addon /var/log/android-addon /opt/waydroid_script; do
        [ -L "$l" ] && rm -f "$l"
    done
fi

# service
batocera-services disable android >/dev/null 2>&1
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable android-waydroid.service >/dev/null 2>&1
    rm -f /etc/systemd/system/android-waydroid.service
    systemctl daemon-reload 2>/dev/null
fi
rm -f /userdata/system/services/android

# F1 Applications menu + ES system
remove_desktop_links
rm -f /userdata/system/configs/emulationstation/es_systems_android.cfg \
      /userdata/system/.emulationstation/es_systems_android.cfg

# generated ES game entries (your apk folder is kept)
for f in "$ROMS_DIR"/*.android; do
    [ -e "$f" ] && head -n1 "$f" | grep -qx '# managed-by-android-addon' && rm -f "$f"
done
rm -rf "$ROMS_DIR/.cache"
rm -f "$ROMS_DIR"/images/*-box3d.png "$ROMS_DIR"/images/*-front.png "$ROMS_DIR"/images/*-fanart.jpg "$ROMS_DIR"/images/*-marquee.png

if [ "$HOST_MODE" = 1 ]; then
    rm -rf "$ADDON_DIR"          # holds no Android data on HippOS
elif [ "$1" = "--keep-data" ]; then
    echo "Kept $ROOTFS - run install.sh again to restore Android with your apps."
else
    if awk -v r="$ROOTFS" '$2 ~ "^"r' /proc/self/mounts | grep -q .; then
        echo "Something is still mounted under $ROOTFS - reboot and run again."; exit 1
    fi
    rm -rf "$ADDON_DIR"
fi
curl -s -m 3 http://127.0.0.1:1234/reloadgames >/dev/null 2>&1
echo "Android add-on removed."
