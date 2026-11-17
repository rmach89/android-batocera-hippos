#!/bin/bash
# One-time setup, runs INSIDE the Debian chroot (called by install.sh).
set -e
export DEBIAN_FRONTEND=noninteractive

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

# Helper scripts for ARM translation + Play certification (casualsnek/waydroid_script)
if [ ! -d /opt/waydroid_script ]; then
    git clone --depth 1 https://github.com/casualsnek/waydroid_script /opt/waydroid_script
fi
cd /opt/waydroid_script
python3 -m venv venv
./venv/bin/pip install -q -r requirements.txt

# Most Play Store games are ARM-only: add ARM->x86 translation.
# libndk (Google's) runs better on AMD, libhoudini (Intel's) on Intel.
if grep -qi GenuineIntel /proc/cpuinfo; then TR=libhoudini; else TR=libndk; fi
./venv/bin/python3 main.py install "$TR" || echo "WARN: $TR install failed - retry later from APK manager README"

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

apt-get clean
echo "SETUP-OK"
