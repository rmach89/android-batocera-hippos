#!/bin/bash
# Android (Waydroid + Google Play) add-on for Batocera and HippOS.
#   ./install.sh            full install (downloads ~2 GB)
#   ./install.sh --repair   re-create symlinks / service only (e.g. after an OS update)
set -o pipefail
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$SRC/bin/android-common.sh"
need_root "$@"

OS="$(detect_os)"
say() { echo -e "\e[1;32m==>\e[0m $*"; log "install: $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; log "install: ERROR $*"; exit 1; }

# ---------------------------------------------------------------- files + symlinks
install_files() {
    say "Copying add-on to $ADDON_DIR"
    mkdir -p "$ADDON_DIR"
    cp -rf "$SRC/bin" "$SRC/chroot" "$SRC/config" "$SRC/systemd" "$ADDON_DIR/"
    OLD_VERSION="$(cat "$ADDON_DIR/VERSION" 2>/dev/null)"
    cp -f "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC/VERSION" "$SRC/bump-version.sh" "$ADDON_DIR/" 2>/dev/null
    cp -f "$SRC/VERSION" "$ADDON_DIR/chroot/VERSION" 2>/dev/null       # for APK Manager
    NEW_VERSION="$(cat "$SRC/VERSION" 2>/dev/null)"
    if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
        say "Updating v$OLD_VERSION -> v$NEW_VERSION"
    fi
    chmod +x "$ADDON_DIR"/bin/* "$ADDON_DIR"/chroot/*.sh "$ADDON_DIR"/chroot/*.py "$ADDON_DIR"/*.sh
}

make_links() {
    say "Creating symlinks"
    mkdir -p "$ROMS_DIR" "$APK_DIR/google-play" "$ROMS_DIR/.cache"

    # F1 Applications menu: Google Play Store, APK Manager, Uninstall Android
    install_desktop_links

    # EmulationStation system definition
    for esdir in /userdata/system/configs/emulationstation /userdata/system/.emulationstation; do
        [ "$esdir" = /userdata/system/.emulationstation ] && [ ! -d "$esdir" ] && continue
        mkdir -p "$esdir"
        ln -sfn "$ADDON_DIR/config/es_systems_android.cfg" "$esdir/es_systems_android.cfg"
    done

    case "$OS" in
        batocera)
            mkdir -p /userdata/system/services
            ln -sfn "$ADDON_DIR/bin/android-service" /userdata/system/services/android
            batocera-services enable android >/dev/null 2>&1 \
                || say "Enable it in MAIN MENU > SYSTEM SETTINGS > SERVICES > android"
            ;;
        hippos|systemd)
            # systemctl link = symlink /etc/systemd/system/android-waydroid.service -> /userdata copy
            systemctl link "$ADDON_DIR/systemd/android-waydroid.service" >/dev/null 2>&1 \
                || ln -sfn "$ADDON_DIR/systemd/android-waydroid.service" /etc/systemd/system/android-waydroid.service
            systemctl daemon-reload
            systemctl enable android-waydroid.service >/dev/null 2>&1
            # keep a copy of the service in /userdata too, same convention as Batocera
            mkdir -p /userdata/system/services
            ln -sfn "$ADDON_DIR/bin/android-service" /userdata/system/services/android
            ;;
        *)
            mkdir -p /userdata/system/services
            ln -sfn "$ADDON_DIR/bin/android-service" /userdata/system/services/android
            say "Unknown OS: start the service yourself with /userdata/system/services/android start"
            ;;
    esac

    # ANDROID game list = installed games only
    "$ADDON_DIR/bin/android-sync-games" >/dev/null 2>&1
}

# ---------------------------------------------------------------- rootfs
bootstrap_rootfs() {
    [ -x "$ROOTFS/usr/bin/waydroid" ] && { say "Waydroid rootfs already present - skipping download"; return; }
    local base="https://images.linuxcontainers.org/images/debian/$DEBIAN_SUITE/amd64/default"
    say "Finding latest Debian $DEBIAN_SUITE rootfs"
    local build
    build=$(curl -fsSL "$base/" | grep -oE '[0-9]{8}_[0-9]{2}(:|%3A)[0-9]{2}' | sed 's/%3A/:/' | sort -u | tail -n1)
    [ -n "$build" ] || die "could not list $base"
    say "Downloading rootfs ($build)"
    mkdir -p "$ROOTFS"
    curl -fL --progress-bar "$base/$build/rootfs.tar.xz" -o "$ADDON_DIR/rootfs.tar.xz" || die "download failed"
    tar -xJf "$ADDON_DIR/rootfs.tar.xz" -C "$ROOTFS" || die "extract failed"
    rm -f "$ADDON_DIR/rootfs.tar.xz"
}

setup_android() {
    [ -f "$ROOTFS/.android-setup-ok" ] && { say "Android already set up (kept data) - skipping"; return; }
    mount_chroot --bootstrap || die "could not mount chroot"
    rm -f "$ROOTFS/run/dbus/pid"
    in_chroot sh -c 'command -v dbus-daemon >/dev/null && dbus-daemon --system --fork' 2>/dev/null
    say "Installing Waydroid + Android with Google Play inside the chroot (10-30 min)"
    local out="$ADDON_DIR/setup.log"
    in_chroot bash /opt/android/setup-waydroid.sh 2>&1 | tee "$out" | grep --line-buffered -E '^(Setting up waydroid|\[|SETUP-OK|WARN|E:)'
    cat "$out" >> "$LOG"
    grep -q SETUP-OK "$out" || { umount_chroot; die "chroot setup failed - see $out"; }
    touch "$ROOTFS/.android-setup-ok"
    in_chroot sh -c 'kill $(cat /run/dbus/pid) 2>/dev/null'
    umount_chroot
}

# ---------------------------------------------------------------- main
ensure_packages() {   # bring older installs up to date with newer features
    mount_chroot || return
    if ! in_chroot sh -c 'command -v xdotool >/dev/null && command -v aapt >/dev/null && python3 -c "import PIL, numpy"' 2>/dev/null; then
        say "Adding packages for Always-on, 3D boxes and badges"
        in_chroot sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xdotool python3-pil python3-numpy aapt' >>"$LOG" 2>&1
    fi
}

if [ "$1" = "--repair" ]; then
    install_files; make_links; ensure_packages; reload_es; say "Repaired - now v$(cat "$SRC/VERSION")."; exit 0
fi
if [ "$1" = "--rescrape" ]; then   # rebuild every 3D box + metadata
    "$ADDON_DIR/bin/android-service" start >/dev/null && \
      in_chroot python3 /opt/android/scrape-launchbox.py --force --refresh && reload_es; exit 0
fi

[ "$(uname -m)" = x86_64 ] || die "Only x86_64 is supported (Waydroid images are x86_64)."
say "Android add-on v$(cat "$SRC/VERSION" 2>/dev/null) - detected OS: $OS"
setup_binder || die "This kernel has no binder support, so Android cannot run. (Batocera: use a recent x86_64 build.)"
free_kb=$(df -Pk /userdata | awk 'NR==2{print $4}')
[ "${free_kb:-0}" -gt 6000000 ] || die "Need at least 6 GB free on /userdata."
if lspci 2>/dev/null | grep -iE 'vga|3d' | grep -qi nvidia; then
    say "WARNING: NVIDIA GPU detected - Waydroid needs Intel/AMD graphics (software rendering will be slow)."
fi

install_files
bootstrap_rootfs
setup_android
make_links

say "Starting service"
"$ADDON_DIR/bin/android-service" start || die "service failed to start - see $LOG"
reload_es

cat <<EOF

  Android add-on v$(cat "$SRC/VERSION") (Waydroid, Android 13 + Google Play) is installed.
  * F1 (Applications menu):
      - Google Play Store (Android)
      - APK Manager (Android)   install / uninstall APKs + stored Google Play apps
      - Uninstall Android
  * EmulationStation > ANDROID lists every installed game, added automatically.
  * Google Play installs are copied to /userdata/roms/android/apk/google-play/
  * Drop .apk files in /userdata/roms/android/apk, then open APK Manager.
  * In Android: hold SELECT (hotkey) + START for 1 second to exit.
  * Log: $LOG
EOF
