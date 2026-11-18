#!/bin/bash
# Android (Waydroid + Google Play) add-on for Batocera and HippOS.
#
# This one file is all you need - it fetches the newest version and every file it needs:
#   curl -fsSL https://raw.githubusercontent.com/rmach89/android-batocera-hippos/main/install.sh | bash
#
#   install.sh             install, or update an existing install (apps/saves/settings kept)
#   install.sh --repair    re-create symlinks / service / packages (e.g. after an OS update)
#   install.sh --rescrape  rebuild every 3D box + game info
#   install.sh --local     use the files next to this script, don't check GitHub
set -o pipefail
REPO="rmach89/android-batocera-hippos"

# ------------------------------------------------------------------ bootstrap from GitHub
# Runs before anything else, so it works when piped (curl | bash), when this file was
# downloaded alone, or from an older copy: it downloads the newest version (release or main,
# whichever is newer) and re-runs that version's install.sh. Needs only bash, tar, gzip and curl or wget.
LOCAL=0; _args=()
for _a in "$@"; do [ "$_a" = "--local" ] && LOCAL=1 || _args+=("$_a"); done
set -- "${_args[@]}"

_self="${BASH_SOURCE[0]:-$0}"
SRC=""
[ -f "$_self" ] && SRC="$(cd "$(dirname "$(readlink -f "$_self")")" && pwd)"

_fetch() {      # _fetch URL  -> stdout
    if command -v curl >/dev/null 2>&1; then curl -fsSL -m 30 "$1"
    elif command -v wget >/dev/null 2>&1; then wget -qO- -T 30 "$1"
    else return 1; fi
}
_fetch_file() { # _fetch_file URL FILE
    if command -v curl >/dev/null 2>&1; then curl -fL --progress-bar -m 600 -o "$2" "$1"
    else wget -q -T 60 -O "$2" "$1"; fi
}
_vnum() { local v="${1#v}" a b c; IFS=. read -r a b c <<< "$v"; echo $(( ${a:-0}*100 + ${b:-0}*10 + ${c:-0} )); }

if [ -z "$ANDROID_ADDON_BOOTSTRAPPED" ] && [ "$LOCAL" = 0 ]; then
    _have_local=0
    [ -n "$SRC" ] && [ -f "$SRC/bin/android-common.sh" ] && _have_local=1
    _local_ver="v$(cat "$SRC/VERSION" 2>/dev/null || echo 0.0.0)"

    # newest version: the published release or the main branch, whichever is newer
    _tag=""; _url=""
    _json="$(_fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)"
    _rtag="$(echo "$_json" | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    [ -n "$_rtag" ] && { _tag="$_rtag"; _url="https://github.com/$REPO/archive/refs/tags/$_rtag.tar.gz"; }
    _v="$(_fetch "https://raw.githubusercontent.com/$REPO/main/VERSION" 2>/dev/null | tr -dc '0-9.')"
    if [ -n "$_v" ] && { [ -z "$_tag" ] || [ "$(_vnum "v$_v")" -gt "$(_vnum "$_tag")" ]; }; then
        _tag="v$_v"; _url="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
    fi

    if [ -n "$_url" ] && { [ "$_have_local" = 0 ] || [ "$(_vnum "$_tag")" -gt "$(_vnum "$_local_ver")" ]; }; then
        echo -e "\e[1;32m==>\e[0m Downloading Android add-on $_tag from GitHub"
        _tmp="$(mktemp -d /tmp/android-addon.XXXXXX)"
        if _fetch_file "$_url" "$_tmp/addon.tar.gz" && tar -xzf "$_tmp/addon.tar.gz" -C "$_tmp"; then
            _new="$(dirname "$(find "$_tmp" -maxdepth 3 -name install.sh | head -n1)")"
            if [ -f "$_new/bin/android-common.sh" ]; then
                export ANDROID_ADDON_BOOTSTRAPPED=1 ANDROID_ADDON_TMP="$_tmp"
                if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
                    exec sudo -E bash "$_new/install.sh" "$@"
                fi
                exec bash "$_new/install.sh" "$@"
            fi
        fi
        rm -rf "$_tmp"
        echo "WARNING: could not download the add-on from GitHub." >&2
    fi
    if [ "$_have_local" = 0 ]; then
        echo "ERROR: could not download the Android add-on from GitHub (https://github.com/$REPO)." >&2
        echo "       Check the internet connection, or download the zip, unzip it and run install.sh from it." >&2
        exit 1
    fi
fi
# downloaded copy: remove it again when we're done
[ -n "$ANDROID_ADDON_TMP" ] && case "$SRC" in "$ANDROID_ADDON_TMP"/*) trap 'rm -rf "$ANDROID_ADDON_TMP"' EXIT ;; esac

. "$SRC/bin/android-common.sh"
if [ "$(id -u)" -ne 0 ]; then       # need_root, but re-run as a file (we may have been piped)
    command -v sudo >/dev/null 2>&1 && exec sudo -E ANDROID_ADDON_BOOTSTRAPPED=1 bash "$SRC/install.sh" --local "$@"
    echo "This must run as root." >&2; exit 1
fi

OS="$(detect_os)"
say() { echo -e "\e[1;32m==>\e[0m $*"; log "install: $*"; }
die() { echo -e "\e[1;31mERROR:\e[0m $*" >&2; log "install: ERROR $*"; exit 1; }

# ---------------------------------------------------------------- files + symlinks
install_files() {
    say "Copying add-on to $ADDON_DIR"
    mkdir -p "$ADDON_DIR"
    cp -rf "$SRC/bin" "$SRC/chroot" "$SRC/config" "$SRC/systemd" "$SRC/hostbin" "$ADDON_DIR/"
    OLD_VERSION="$(cat "$ADDON_DIR/VERSION" 2>/dev/null)"
    cp -f "$SRC/install.sh" "$SRC/uninstall.sh" "$SRC/VERSION" "$SRC/bump-version.sh" "$ADDON_DIR/" 2>/dev/null
    cp -f "$SRC/VERSION" "$ADDON_DIR/chroot/VERSION" 2>/dev/null       # for APK Manager
    NEW_VERSION="$(cat "$SRC/VERSION" 2>/dev/null)"
    if [ -n "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$NEW_VERSION" ]; then
        say "Updating v$OLD_VERSION -> v$NEW_VERSION"
    fi
    chmod +x "$ADDON_DIR"/bin/* "$ADDON_DIR"/hostbin/* "$ADDON_DIR"/chroot/*.sh "$ADDON_DIR"/chroot/*.py "$ADDON_DIR"/*.sh
}

make_links() {
    say "Creating symlinks"
    mkdir -p "$ROMS_DIR" "$APK_DIR/google-play" "$ROMS_DIR/.cache"
    [ "$HOST_MODE" = 1 ] && prepare_host

    # F1 Applications menu: Google Play Store, APK Manager, Uninstall Android
    install_desktop_links

    # EmulationStation system definition
    for esdir in /userdata/system/configs/emulationstation /userdata/system/.emulationstation; do
        [ "$esdir" = /userdata/system/.emulationstation ] && [ ! -d "$esdir" ] && continue
        mkdir -p "$esdir"
        if [ "$HOST_MODE" = 1 ]; then   # HippOS: take over its Android Games / Android Apps systems
            ln -sfn "$ADDON_DIR/config/es_systems_android-hippos.cfg" "$esdir/es_systems_android.cfg"
        else
            ln -sfn "$ADDON_DIR/config/es_systems_android.cfg" "$esdir/es_systems_android.cfg"
        fi
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
    [ "$HOST_MODE" = 1 ] && return 0          # HippOS: Waydroid is part of the system
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

setup_android_host() {
    [ -f "$ADDON_DIR/.android-setup-ok" ] && { say "HippOS Android already set up - skipping"; return; }
    prepare_host
    say "Setting up HippOS's built-in Android: add-on tools, ARM translation, controller settings"
    say "(if Android was never started on this HippOS, its download runs first - needs internet)"
    local out="$ADDON_DIR/setup.log"
    bash "$ADDON_DIR/chroot/setup-waydroid.sh" --host 2>&1 | tee "$out" | grep --line-buffered -E '^(\[|SETUP-OK|WARN|E:)'
    cat "$out" >> "$LOG"
    grep -q SETUP-OK "$out" || die "setup failed - see $out"
    touch "$ADDON_DIR/.android-setup-ok"
}

setup_android() {
    [ "$HOST_MODE" = 1 ] && { setup_android_host; return; }
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
    if [ "$HOST_MODE" = 1 ]; then
        command -v cage >/dev/null && command -v aapt >/dev/null && command -v dialog >/dev/null && return 0
        say "Installing the add-on's tools"
        bash "$ADDON_DIR/chroot/setup-waydroid.sh" --host --packages-only >>"$LOG" 2>&1
        return 0
    fi
    mount_chroot || return
    if ! in_chroot sh -c 'command -v xdotool >/dev/null && command -v aapt >/dev/null && python3 -c "import PIL, numpy"' 2>/dev/null; then
        say "Adding packages for Always-on, 3D boxes and badges"
        in_chroot sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xdotool python3-pil python3-numpy aapt' >>"$LOG" 2>&1
    fi
}

UPDATING=0; [ -x "$ROOTFS/usr/bin/waydroid" ] && UPDATING=1
[ "$HOST_MODE" = 1 ] && { UPDATING=0; [ -f "$ADDON_DIR/.android-setup-ok" ] && UPDATING=1; }
stop_running() {   # an update replaces scripts Android may be running - stop it first
    if [ "$UPDATING" = 1 ] && [ -x "$ADDON_DIR/bin/android-service" ]; then
        say "Stopping Android while files are updated"
        "$ADDON_DIR/bin/android-service" stop >/dev/null 2>&1
    fi
}

if [ "$1" = "--repair" ]; then
    stop_running; install_files; make_links; ensure_packages
    "$ADDON_DIR/bin/android-service" start >/dev/null 2>&1
    "$ADDON_DIR/bin/android-theme-logos" --rescan
    reload_es; say "Repaired - now v$(cat "$SRC/VERSION")."; exit 0
fi
if [ "$1" = "--rescrape" ]; then   # rebuild every 3D box + metadata
    "$ADDON_DIR/bin/android-service" start >/dev/null && \
      in_chroot python3 /opt/android/scrape-launchbox.py --force --refresh && reload_es; exit 0
fi

if [ "$HOST_MODE" = 1 ]; then
    say "Android add-on v$(cat "$SRC/VERSION" 2>/dev/null) - detected HippOS: using its built-in Waydroid"
else
    [ "$(uname -m)" = x86_64 ] || die "Only x86_64 is supported here (Waydroid images are x86_64)."
    say "Android add-on v$(cat "$SRC/VERSION" 2>/dev/null) - detected OS: $OS"
fi
setup_binder || die "This kernel has no binder support, so Android cannot run. (Batocera: use a recent x86_64 build.)"
if [ "$UPDATING" = 1 ]; then
    say "Existing install found - updating to v$(cat "$SRC/VERSION") (apps, saves and settings are kept)"
else
    free_kb=$(df -Pk /userdata | awk 'NR==2{print $4}')
    need_kb=6000000; [ "$HOST_MODE" = 1 ] && need_kb=2000000
    [ "${free_kb:-0}" -gt "$need_kb" ] || die "Need at least $((need_kb / 1000000)) GB free on /userdata."
fi
if lspci 2>/dev/null | grep -iE 'vga|3d' | grep -qi nvidia; then
    say "WARNING: NVIDIA GPU detected - Waydroid needs Intel/AMD graphics (software rendering will be slow)."
fi

stop_running
install_files
bootstrap_rootfs
setup_android
ensure_packages
make_links

say "Starting service"
"$ADDON_DIR/bin/android-service" start || die "service failed to start - see $LOG"
if [ "$HOST_MODE" = 1 ]; then
    reload_es
    cat <<EOF

  Android add-on v$(cat "$SRC/VERSION") is $( [ "$UPDATING" = 1 ] && echo updated || echo installed ) on HippOS (using HippOS's own Android).
  * Desktop Shortcuts: Google Play Store, APK Manager, F-Droid, Aurora Store, Aptoide, Uninstall Android
  * Android Games lists every installed game (plus your .apk files) with 3D boxes.
  * Android Apps keeps HippOS's Waydroid entry.
  * Store installs are copied to /userdata/roms/android-apk/<store>/
  * Drop .apk files in /userdata/roms/android-apk, then open APK Manager
    (or straight into roms/androidgames - they install on first launch).
  * In Android: hold SELECT (hotkey) + START for 1 second to exit.
  * Log: $LOG
EOF
    exit 0
fi
say "Adding the Android logo to your EmulationStation themes"
"$ADDON_DIR/bin/android-theme-logos" --rescan
reload_es

cat <<EOF

  Android add-on v$(cat "$SRC/VERSION") (Waydroid, Android 13 + Google Play) is $( [ "$UPDATING" = 1 ] && echo updated || echo installed ).
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
