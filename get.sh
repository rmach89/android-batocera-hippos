#!/bin/bash
# Kept for older instructions - install.sh does everything itself now:
#   curl -fsSL https://raw.githubusercontent.com/rmach89/android-batocera-hippos/main/install.sh | bash
REPO="rmach89/android-batocera-hippos"
URL="https://raw.githubusercontent.com/$REPO/main/install.sh"
if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" | bash -s -- "$@"
else wget -qO- "$URL" | bash -s -- "$@"; fi
