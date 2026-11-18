#!/bin/bash
# One-time setup (called by install.sh).
#   setup-waydroid.sh                     Batocera & others: INSIDE our Debian chroot - installs Waydroid
#   setup-waydroid.sh --host              HippOS: on the system itself - HippOS already ships Waydroid,
#                                         so only the add-on's tools + ARM translation + settings
#   setup-waydroid.sh --host --packages-only   just the tools (after a HippOS OS update)
set -e
export DEBIAN_FRONTEND=noninteractive
HOST=0; [ "$1" = --host ] && HOST=1
WS=/opt/waydroid_script; [ "$HOST" = 1 ] && WS=/userdata/system/add-ons/android/waydroid_script

if [ "$HOST" = 1 ]; then
    # HippOS keeps these across OS updates (it re-installs the user's apt packages after an update)
    apt-get update -qq || true
    apt-get install -y -qq --no-install-recommends \
        cage foot dialog fonts-dejavu-core xdotool x11-xserver-utils python3-evdev python3-pil python3-numpy aapt \
        python3-venv git lzip unzip sqlite3 curl ca-certificates
    [ "$2" = --packages-only ] && { echo "SETUP-OK"; exit 0; }

    # Android image: HippOS downloads it itself (hippos-waydroid-init, Android + Google Play).
    systemctl start var-lib-waydroid.mount 2>/dev/null || true
    if [ ! -f /var/lib/waydroid/images/system.img ] || [ ! -f /var/lib/waydroid/images/vendor.img ]; then
        echo "[setup] waiting for HippOS to download Android (needs internet, ~1 GB) ..."
        systemctl start --no-block hippos-waydroid-init.service 2>/dev/null || waydroid init -s GAPPS || true
        for _ in $(seq 1 360); do       # up to 30 min
            [ -f /var/lib/waydroid/images/system.img ] && [ -f /var/lib/waydroid/images/vendor.img ] && \
                ! systemctl is-active --quiet hippos-waydroid-init.service && break
            sleep 5
        done
        [ -f /var/lib/waydroid/images/system.img ] || { echo "E: Android image not downloaded (no internet?)"; exit 1; }
    fi
    systemctl start waydroid-container.service 2>/dev/null || true
else

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release dbus dbus-x11 \
    python3 python3-venv python3-pip python3-evdev git lzip unzip sqlite3 \
    cage foot dialog fonts-dejavu-core xwayland xdotool \
    python3-pil python3-numpy aapt \
    mesa-vulkan-drivers libgl1-mesa-dri libegl1 libgles2 \
    lxc iptables dnsmasq-base kmod procps

# Official Waydroid repo (falls back to Debian's own package)
if ! apt-cache policy waydroid | grep -q 'repo.waydro.id'; then
    curl -fsSL https://repo.waydro.id | bash -s trixie || true
fi
apt-get update
apt-get install -y waydroid

# Download Android (LineageOS) image WITH Google Play services
waydroid init -s GAPPS -f
fi

# Helper scripts for ARM translation + Play certification (casualsnek/waydroid_script)
if [ ! -d "$WS/.git" ]; then
    rm -rf "$WS"; git clone --depth 1 https://github.com/casualsnek/waydroid_script "$WS"
fi
cd "$WS"
python3 -m venv venv
./venv/bin/pip install -q -r requirements.txt

# Most Play Store games are ARM-only: add ARM->x86 translation.
# libndk (Google's) runs better on AMD, libhoudini (Intel's) on Intel.
# (Raspberry Pi / ARM runs ARM games natively - nothing to add)
if [ "$(uname -m)" = x86_64 ]; then
    if grep -qi GenuineIntel /proc/cpuinfo; then TR=libhoudini; else TR=libndk; fi
    ./venv/bin/python3 main.py install "$TR" || echo "WARN: $TR install failed - retry later from APK manager README"
fi

# Android properties for a console-like experience
waydroid prop set persist.waydroid.multi_windows true    2>/dev/null || true  # Native windows (default)
waydroid prop set persist.waydroid.uevent true           2>/dev/null || true  # gamepads
waydroid prop set persist.waydroid.udev true             2>/dev/null || true
waydroid prop set persist.waydroid.suspend false         2>/dev/null || true
grep -q '^\[properties\]' /var/lib/waydroid/waydroid.cfg || echo '[properties]' >> /var/lib/waydroid/waydroid.cfg
for kv in "persist.waydroid.multi_windows=true" "persist.waydroid.uevent=true" \
          "persist.waydroid.udev=true" "persist.waydroid.suspend=false"; do
    k="${kv%%=*}"; grep -q "^$k" /var/lib/waydroid/waydroid.cfg || sed -i "/^\[properties\]/a $kv" /var/lib/waydroid/waydroid.cfg
done
waydroid upgrade --offline || true

[ "$HOST" = 1 ] || apt-get clean
echo "SETUP-OK"
