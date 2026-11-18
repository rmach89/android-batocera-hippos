#!/bin/bash
# Shared settings + helpers for the Android (Waydroid) add-on.
# Works on Batocera and HippOS: everything lives under /userdata so it survives OS updates.

ADDON_DIR="/userdata/system/add-ons/android"
LOG_DIR="/userdata/system/logs"
LOG="$LOG_DIR/android.log"
DEBIAN_SUITE="trixie"
SETTINGS_DIR="$ADDON_DIR/settings"         # = /etc/android-addon for the scripts in chroot/
SETTINGS="$SETTINGS_DIR/android.conf"

detect_os() {
    if [ -x /usr/bin/batocera-services ] || grep -qi batocera /etc/os-release 2>/dev/null \
       || [ -f /usr/share/batocera/batocera.version ]; then
        echo batocera
    elif grep -qi hippos /etc/os-release 2>/dev/null || [ -d /etc/hippos ] || [ -f /etc/hippos-version ] \
         || [ -x /usr/lib/hippos/hippos-services ]; then
        echo hippos
    elif command -v systemctl >/dev/null 2>&1; then
        echo systemd
    else
        echo unknown
    fi
}
OS="${ANDROID_ADDON_OS:-$(detect_os)}"

# Two ways to run, picked automatically:
#  chroot mode (Batocera, others): Waydroid lives in our own Debian chroot under $ROOTFS.
#  host mode   (HippOS):           HippOS ships Waydroid itself - use it, so there is ONE Android
#                                  with one set of apps; HippOS's own Android systems are taken over.
if [ "$OS" = hippos ] && [ -x /usr/bin/waydroid ] && [ "${ANDROID_ADDON_FORCE_CHROOT:-0}" != 1 ]; then
    HOST_MODE=1
    ROOTFS=""                                          # the "chroot" is the system itself
    ROMS_DIR="/userdata/roms/androidgames"             # HippOS's Android Games system
    APK_DIR="/userdata/roms/android-apk"               # outside any system folder (ES would list the .apk files)
    SESSION_USER="$(id -un hippos 2>/dev/null || stat -c %U /userdata/system 2>/dev/null)"
    [ -n "$SESSION_USER" ] && [ "$SESSION_USER" != root ] || SESSION_USER=hippos
    SESSION_UID="$(id -u "$SESSION_USER" 2>/dev/null || echo 1000)"
    SESSION_HOME="$(getent passwd "$SESSION_USER" | cut -d: -f6)"; SESSION_HOME="${SESSION_HOME:-/userdata/system}"
    ANDROID_DATA_DIR="$SESSION_HOME/.local/share/waydroid/data"     # Android's /data
    CHROOT_UID_RUNTIME="/run/user/$SESSION_UID"
else
    HOST_MODE=0
    ROOTFS="$ADDON_DIR/rootfs"                         # Debian Trixie chroot that holds Waydroid
    ROMS_DIR="/userdata/roms/android"                  # EmulationStation "android" system
    APK_DIR="$ROMS_DIR/apk"                            # drop .apk files here
    ANDROID_DATA_DIR="/root/.local/share/waydroid/data"
    CHROOT_UID_RUNTIME="/run/user/0"
fi
STATE="$ROOTFS/run/android"                # always-on handshake files (/run/android for the scripts)

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
always_on_supported() {
    [ -S /tmp/.X11-unix/X0 ] || return 1
    [ "$HOST_MODE" = 1 ] && return 0                 # HippOS's screen is X11
    ! host_wayland_socket >/dev/null
}
always_on_wanted()    { [ "$(setting_get ALWAYS_ON 0)" = 1 ]; }
keeper_ready()        { [ -f "$STATE/ready" ] && [ -f "$STATE/keeper.pid" ] && kill -0 "$(cat "$STATE/keeper.pid")" 2>/dev/null; }


need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then exec sudo -n -E "$0" "$@"; fi
        echo "This must run as root." >&2; exit 1
    fi
}

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

# ---------- kernel binder ----------
setup_binder() {
    [ "$HOST_MODE" = 1 ] && return 0                 # HippOS's waydroid-container.service does this
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

# host mode: the scripts in chroot/ expect these paths - symlink them on the system itself.
# HippOS keeps /etc and /opt changes across OS updates, but this runs at every start anyway.
prepare_host() {
    local l
    for l in "/opt/android:$ADDON_DIR/chroot" "/mnt/android-roms:$ROMS_DIR" \
             "/etc/android-addon:$SETTINGS_DIR" "/var/log/android-addon:$LOG_DIR" \
             "/opt/waydroid_script:$ADDON_DIR/waydroid_script"; do
        local link="${l%%:*}" target="${l#*:}"
        if [ -e "$link" ] && [ ! -L "$link" ]; then
            # a leftover empty folder is replaced; one with files in it is never touched
            if [ -d "$link" ] && [ -z "$(find "$link" -type f -print -quit 2>/dev/null)" ]; then
                rm -rf "$link"
            else
                log "WARNING: $link exists and is not ours - leaving it alone"; continue
            fi
        fi
        mkdir -p "$(dirname "$link")"; ln -sfn "$target" "$link"
    done
    mkdir -p "$ROMS_DIR/.cache" "$APK_DIR" "$SETTINGS_DIR" "$STATE" /var/cache/android-addon /root/.cache/android-addon
    touch "$SETTINGS"
    chown "$SESSION_USER" "$ROMS_DIR" "$APK_DIR" 2>/dev/null
    systemctl start var-lib-waydroid.mount 2>/dev/null
    systemctl start waydroid-container.service 2>/dev/null
    return 0
}

mount_chroot() {
    if [ "$HOST_MODE" = 1 ]; then prepare_host; return; fi
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
    [ "$HOST_MODE" = 1 ] && return 0
    local w p
    if w=$(host_wayland_socket); then bind_into "$w" "$CHROOT_UID_RUNTIME/wayland-host" file; fi
    if p=$(host_pulse_socket);   then bind_into "$p" "$CHROOT_UID_RUNTIME/pulse/native" file; fi
}

umount_chroot() {
    [ "$HOST_MODE" = 1 ] && return 0                 # nothing of ours is mounted (and ROOTFS is /)
    [ -n "$ROOTFS" ] || return 0
    local m
    # unmount everything below the rootfs, deepest first
    for m in $(awk -v r="$ROOTFS" '$2 ~ "^"r {print $2}' /proc/self/mounts | sort -r); do
        umount -l "$m" 2>/dev/null
    done
}

x_authority() {
    local f
    for f in "$XAUTHORITY" "$SESSION_HOME/.Xauthority" "/run/user/${SESSION_UID:-0}/gdm/Xauthority"; do
        [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return; }
    done
}

# Run a command inside the chroot with a clean environment.
# Host mode: same environment, on the system itself; `waydroid` resolves to hostbin/waydroid,
# which runs the session parts as the desktop user and the root parts as root.
in_chroot() {
    if [ "$HOST_MODE" = 1 ]; then
        local xa; xa="$(x_authority)"
        /usr/bin/env -i \
            HOME=/root USER=root LANG=C.UTF-8 TERM=xterm-256color \
            PATH="$ADDON_DIR/hostbin:/opt/android:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            XDG_RUNTIME_DIR="$CHROOT_UID_RUNTIME" DISPLAY="${DISPLAY:-:0}" ${xa:+XAUTHORITY="$xa"} \
            ${WAYLAND_DISPLAY:+WAYLAND_DISPLAY="$WAYLAND_DISPLAY"} \
            ANDROID_HOST_MODE=1 ANDROID_SESSION_USER="$SESSION_USER" \
            ANDROID_DATA_DIR="$ANDROID_DATA_DIR" ANDROID_APK_DIR="$APK_DIR" \
            "$@"
        return
    fi
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

# package name of an .apk file (cached by path + modification time)
apk_package() {
    local f="$1" c="$ROMS_DIR/.cache/apk-packages.tsv" m p
    m="$(stat -c %Y "$f" 2>/dev/null)"
    p="$(awk -F'\t' -v f="$f" -v m="$m" '$1==f && $2==m {print $3; exit}' "$c" 2>/dev/null)"
    if [ -z "$p" ]; then
        p="$(in_chroot aapt dump badging "$f" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1)"
        if [ -n "$p" ]; then
            mkdir -p "$(dirname "$c")"
            { grep -v -F "$f	" "$c" 2>/dev/null; printf '%s\t%s\t%s\n' "$f" "$m" "$p"; } > "$c.tmp" && mv -f "$c.tmp" "$c"
        fi
    fi
    echo "$p"
}

container_running() { in_chroot waydroid status 2>/dev/null | grep -q "Container:.*RUNNING"; }

# Run session.sh in a full-screen cage window (blocks until it ends).
#   run_session [--x11] <session.sh args>
run_session() {
    local x11=""; [ "$1" = --x11 ] && { x11=1; shift; }
    if [ "$HOST_MODE" = 1 ]; then
        # cage must belong to the desktop user, so that user's Waydroid session can draw in it;
        # android-in-session then switches back to root for session.sh.
        local xa; xa="$(x_authority)"
        mkdir -p "$CHROOT_UID_RUNTIME" 2>/dev/null
        # let root (window show/hide for Always-on) use the desktop user's X screen
        sudo -n -u "$SESSION_USER" env DISPLAY="${DISPLAY:-:0}" ${xa:+XAUTHORITY="$xa"} \
            xhost +SI:localuser:root >/dev/null 2>&1
        sudo -n -u "$SESSION_USER" /usr/bin/env -i \
            HOME="$SESSION_HOME" USER="$SESSION_USER" LANG=C.UTF-8 PATH=/usr/sbin:/usr/bin:/sbin:/bin \
            XDG_RUNTIME_DIR="$CHROOT_UID_RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=$CHROOT_UID_RUNTIME/bus" \
            DISPLAY="${DISPLAY:-:0}" ${xa:+XAUTHORITY="$xa"} ${x11:+WLR_BACKENDS=x11} WLR_NO_HARDWARE_CURSORS=1 \
            cage -s -d -- "$ADDON_DIR/bin/android-in-session" "$@"
    else
        attach_session_sockets
        in_chroot ${x11:+env WLR_BACKENDS=x11} dbus-run-session -- cage -s -d -- /opt/android/session.sh "$@"
    fi
}

# ---------- F1 "Applications" menu entries (symlinked .desktop files) ----------
DESKTOP_SRC="$ADDON_DIR/config/applications"
if [ "$HOST_MODE" = 1 ]; then
    DESKTOP_DIRS="/userdata/Desktop"     # HippOS lists these under the "Desktop Shortcuts" system
else
    DESKTOP_DIRS="/userdata/system/.local/share/applications /usr/share/applications"
fi

install_desktop_links() {
    local d f
    for d in $DESKTOP_DIRS; do
        mkdir -p "$d" 2>/dev/null || continue           # /usr may be read-only on some systems
        for f in "$DESKTOP_SRC"/*.desktop; do
            [ -e "$f" ] || continue
            # HippOS already has a Waydroid entry (Android Apps) - ours would be a duplicate
            [ "$HOST_MODE" = 1 ] && [ "$(basename "$f")" = android-waydroid.desktop ] && continue
            ln -sfn "$f" "$d/$(basename "$f")" 2>/dev/null
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

# host mode: EmulationStation runs as the desktop user and must be able to update what we write
fix_owner() {
    [ "$HOST_MODE" = 1 ] || return 0
    local p
    for p in "$ROMS_DIR"/*.android "$ROMS_DIR/gamelist.xml" "$ROMS_DIR/images" "$ROMS_DIR/.cache" \
             "$ROMS_DIR/saves" "$APK_DIR"; do
        [ -e "$p" ] && chown -R "$SESSION_USER:" "$p" 2>/dev/null
    done
    return 0
}

reload_es() {
    # batocera-emulationstation (and forks such as HippOS') expose a local HTTP API
    curl -s -m 3 http://127.0.0.1:1234/reloadgames >/dev/null 2>&1 || true
}
