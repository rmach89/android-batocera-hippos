#!/bin/bash
# Every app YOU installed (Android's own "third-party" list, so nothing is hidden by its
# name), with the store it came from. Runs INSIDE the chroot, Android session running.
#   installed-apps.sh            package<TAB>source-id<TAB>Source label<TAB>App name
#   installed-apps.sh --cache    also write user-packages.txt + app-sources.txt to the ROMs cache
# source-id doubles as the backup folder name in roms/android/apk/<source-id>/
CACHE_DIR=/mnt/android-roms/.cache

source_of() {     # installer package -> "id<TAB>Label"
    case "$1" in
        com.android.vending)                 printf 'google-play\tGoogle Play' ;;
        org.fdroid.fdroid|org.fdroid.basic)  printf 'f-droid\tF-Droid' ;;
        com.aurora.store)                    printf 'aurora\tAurora' ;;
        cm.aptoide.pt)                       printf 'aptoide\tAptoide' ;;
        ""|null|com.android.packageinstaller|com.google.android.packageinstaller|com.android.shell)
                                             printf 'apk\tAPK' ;;
        *)                                   printf 'other\t%s' "$1" ;;
    esac
}

pkgs=$(waydroid shell -- pm list packages -3 -i 2>/dev/null | tr -d '\r')
names=$(waydroid app list 2>/dev/null | awk -F': ' '/^Name:/{n=$2} /^packageName:/{gsub(/[ \t]/,"",$2); print $2 "\t" n}')

list_apps() {
echo "$pkgs" | while read -r line; do
    pkg=$(echo "$line" | sed -n 's/^package:\([^ ]*\).*/\1/p')
    [ -n "$pkg" ] || continue
    inst=$(echo "$line" | sed -n 's/.*installer=\([^ ]*\).*/\1/p')
    name=$(echo "$names" | awk -F'\t' -v p="$pkg" '$1==p{print $2; exit}')
    printf '%s\t%s\t%s\n' "$pkg" "$(source_of "$inst")" "${name:-$pkg}"
done
}

if [ "$1" = "--cache" ]; then      # user-packages.txt: game list   app-sources.txt: pkg<TAB>source (scraper)
    mkdir -p "$CACHE_DIR"
    list_apps > "$CACHE_DIR/app-sources.txt.tmp"
    if [ -s "$CACHE_DIR/app-sources.txt.tmp" ]; then
        cut -f1 "$CACHE_DIR/app-sources.txt.tmp" > "$CACHE_DIR/user-packages.txt"
        cut -f1,2 "$CACHE_DIR/app-sources.txt.tmp" > "$CACHE_DIR/app-sources.txt"
        cat "$CACHE_DIR/app-sources.txt.tmp"
    fi
    rm -f "$CACHE_DIR/app-sources.txt.tmp"
else
    list_apps
fi
