#!/bin/bash
# Shared settings + helpers for the Android (Waydroid) add-on.
# Works on Batocera and HippOS: everything lives under /userdata so it survives OS updates.

ADDON_DIR="/userdata/system/add-ons/android"
ROOTFS="$ADDON_DIR/rootfs"                 # Debian Trixie chroot that holds Waydroid
ROMS_DIR="/userdata/roms/android"          # EmulationStation "android" system
APK_DIR="$ROMS_DIR/apk"                    # drop .apk files here
LOG_DIR="/userdata/system/logs"
LOG="$LOG_DIR/android.log"
CHROOT_UID_RUNTIME="/run/user/0"
DEBIAN_SUITE="trixie"
SETTINGS_DIR="$ADDON_DIR/settings"         # bind-mounted at /etc/android-addon in the chroot
SETTINGS="$SETTINGS_DIR/android.conf"
STATE="$ROOTFS/run/android"                # always-on handshake files (/run/android in chroot)

mkdir -p "$LOG_DIR" 2>/dev/null
ADDON_VERSION="v$(cat "$ADDON_DIR/VERSION" 2>/dev/null || cat "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../VERSION" 2>/dev/null || echo '?')"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }

# ---------- settings ----------
setting_get() {   # setting_get KEY DEFAULT
    local v
    v=$(sed -n "s/^$1=//p" "$SETTINGS" 2>/dev/null | tail -n1)
    echo "${v:-$2}"
}
setting_set() {   # setting_set KEY VALUE
    mkdir -p "$SETTINGS_DIR"; touch "$SETTINGS"
    sed -i "/^$1=/d" "$SETTINGS"; echo "$1=$2" >> "$SETTINGS"
}

# Always-on needs a plain X11 screen (Batocera PC default): the Android window is hidden
# with xdotool while you are in EmulationStation.
always_on_supported() { [ -S /tmp/.X11-unix/X0 ] && ! host_wayland_socket >/dev/null; }
always_on_wanted()    { [ "$(setting_get ALWAYS_ON 0)" = 1 ]; }
keeper_ready()        { [ -f "$STATE/ready" ] && [ -f "$STATE/keeper.pid" ] && kill -0 "$(cat "$STATE/keeper.pid")" 2>/dev/null; }

detect_os() {
    if [ -x /usr/bin/batocera-services ] || grep -qi batocera /etc/os-release 2>/dev/null \
       || [ -f /usr/share/batocera/batocera.version ]; then
        echo batocera
    elif grep -qi hippos /etc/os-release 2>/dev/null || [ -d /etc/hippos ]; then
        echo hippos
    elif command -v systemctl >/dev/null 2>&1; then
        echo systemd
    else
        echo unknown
    fi
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then exec sudo -E "$0" "$@"; fi
        echo "This must run as root." >&2; exit 1
    fi
}

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

# ---------- kernel binder ----------
setup_binder() {
    if [ -e /dev/binderfs/binder-control ] || [ -e /dev/binder ]; then return 0; fi
    modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null
    if grep -qw binder /proc/filesystems; then
        mkdir -p /dev/binderfs
        mount -t binder binder /dev/binderfs 2>/dev/null
    fi
    if [ -e /dev/binderfs/binder-control ] || [ -e /dev/binder ]; then return 0; fi
    log "ERROR: kernel has no Android binder support (binder_linux / binderfs). Waydroid cannot run."
    return 1
}

# ---------- host display / audio discovery ----------
host_wayland_socket() {
    local s
    for s in "${XDG_RUNTIME_DIR:-/nonexistent}/${WAYLAND_DISPLAY:-wayland-0}" \
             /run/user/*/wayland-0 /run/user/*/wayland-1 /run/wayland-0; do
        [ -S "$s" ] && { echo "$s"; return 0; }
    done
    return 1
}

host_pulse_socket() {
    local s
    for s in "${XDG_RUNTIME_DIR:-/nonexistent}/pulse/native" /run/user/0/pulse/native \
             /run/user/*/pulse/native /var/run/pulse/native /run/pulse/native; do
        [ -S "$s" ] && { echo "$s"; return 0; }
    done
    return 1
}

# ---------- chroot mounts ----------
bind_into() {   # bind_into <host path> <path inside rootfs> [file|dir]
    local src="$1" dst="$ROOTFS$2" kind="${3:-dir}"
    [ -e "$src" ] || return 0
    if [ "$kind" = file ]; then mkdir -p "$(dirname "$dst")"; touch "$dst"; else mkdir -p "$dst"; fi
    is_mounted "$dst" || mount --bind "$src" "$dst"
}

mount_chroot() {
    if [ "$1" != "--bootstrap" ]; then
        [ -x "$ROOTFS/usr/bin/waydroid" ] || { log "ERROR: rootfs not installed ($ROOTFS)"; return 1; }
    fi
    is_mounted "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc"
    is_mounted "$ROOTFS/sys"  || { mount --rbind /sys "$ROOTFS/sys"; mount --make-rslave "$ROOTFS/sys"; }
    is_mounted "$ROOTFS/dev"  || { mount --rbind /dev "$ROOTFS/dev"; mount --make-rslave "$ROOTFS/dev"; }
    is_mounted "$ROOTFS/run"  || mount -t tmpfs -o mode=755 tmpfs "$ROOTFS/run"
    mkdir -p "$ROOTFS/run/dbus" "$ROOTFS$CHROOT_UID_RUNTIME" "$ROOTFS/tmp/.X11-unix"
    chmod 700 "$ROOTFS$CHROOT_UID_RUNTIME"
    bind_into /run/udev /run/udev
    bind_into /tmp/.X11-unix /tmp/.X11-unix
    # add-on scripts are bind-mounted (symlinks can't cross the chroot boundary)
    bind_into "$ADDON_DIR/chroot" /opt/android
    bind_into "$ROMS_DIR" /mnt/android-roms
    mkdir -p "$SETTINGS_DIR" "$STATE"; touch "$SETTINGS"
    bind_into "$SETTINGS_DIR" /etc/android-addon
    bind_into "$LOG_DIR" /var/log/android-addon            # controller log lands in /userdata/system/logs
    cp -fL /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null
}

attach_session_sockets() {   # display + audio sockets, refreshed for every launch
    local w p
    if w=$(host_wayland_socket); then bind_into "$w" "$CHROOT_UID_RUNTIME/wayland-host" file; fi
    if p=$(host_pulse_socket);   then bind_into "$p" "$CHROOT_UID_RUNTIME/pulse/native" file; fi
}

umount_chroot() {
    local m
    # unmount everything below the rootfs, deepest first
    for m in $(awk -v r="$ROOTFS" '$2 ~ "^"r {print $2}' /proc/self/mounts | sort -r); do
        umount -l "$m" 2>/dev/null
    done
}

# Run a command inside the chroot with a clean environment.
in_chroot() {
    local wl="" disp="${DISPLAY:-}"
    [ -S "$ROOTFS$CHROOT_UID_RUNTIME/wayland-host" ] && wl="wayland-host"
    [ -z "$disp" ] && [ -S /tmp/.X11-unix/X0 ] && disp=":0"
    chroot "$ROOTFS" /usr/bin/env -i \
        HOME=/root USER=root LANG=C.UTF-8 TERM=xterm-256color \
        PATH=/opt/android:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        XDG_RUNTIME_DIR="$CHROOT_UID_RUNTIME" \
        ${disp:+DISPLAY="$disp"} ${wl:+WAYLAND_DISPLAY="$wl"} ${wl:+WAYLAND_HOST=1} \
        LIBSEAT_BACKEND=builtin WLR_NO_HARDWARE_CURSORS=1 \
        "$@"
}

container_running() { in_chroot waydroid status 2>/dev/null | grep -q "Container:.*RUNNING"; }

# ---------- F1 "Applications" menu entries (symlinked .desktop files) ----------
DESKTOP_SRC="$ADDON_DIR/config/applications"
DESKTOP_DIRS="/userdata/system/.local/share/applications /usr/share/applications"

install_desktop_links() {
    local d f
    for d in $DESKTOP_DIRS; do
        mkdir -p "$d" 2>/dev/null || continue           # /usr may be read-only on some systems
        for f in "$DESKTOP_SRC"/*.desktop; do
            [ -e "$f" ] && ln -sfn "$f" "$d/$(basename "$f")" 2>/dev/null
        done
    done
    command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications 2>/dev/null
    return 0
}

remove_desktop_links() {
    local d
    for d in $DESKTOP_DIRS; do
        rm -f "$d"/android-playstore.desktop "$d"/android-apk-manager.desktop "$d"/android-uninstall.desktop \
              "$d"/android-waydroid.desktop "$d"/android-fdroid.desktop \
              "$d"/android-aurora.desktop "$d"/android-aptoide.desktop 2>/dev/null
    done
}

reload_es() {
    # batocera-emulationstation (and forks such as HippOS') expose a local HTTP API
    curl -s -m 3 http://127.0.0.1:1234/reloadgames >/dev/null 2>&1 || true
}
