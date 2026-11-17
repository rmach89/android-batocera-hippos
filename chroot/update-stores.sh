#!/bin/bash
# Install / update the app stores in the F1 menu (F-Droid, Aurora Store, Aptoide) from their
# official downloads. Runs INSIDE the chroot with the Android session running.
#   update-stores.sh ensure PKG     install if missing; update if a newer build exists
#                                   (online check at most once a day per store)
#   update-stores.sh check          list stores with an update: pkg<TAB>name<TAB>installed<TAB>newest
#   update-stores.sh update         update every installed store that has a newer build
STORES="org.fdroid.fdroid com.aurora.store cm.aptoide.pt"
DL=/var/cache/android-addon
STAMP=/root/.cache/android-addon/store-check
mkdir -p "$DL" "$STAMP"

store_name() { case "$1" in org.fdroid.fdroid) echo F-Droid ;; com.aurora.store) echo "Aurora Store" ;;
                            cm.aptoide.pt) echo Aptoide ;; *) echo "$1" ;; esac; }
installed_code() {      # versionCode of the installed app, empty if not installed
    waydroid shell -- dumpsys package "$1" 2>/dev/null | tr -d '\r' |
        sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | sort -n | tail -n1
}
newest() { python3 /opt/android/store-apk-url.py "$1" 2>/dev/null; }    # "url md5|- code"

install_from() {        # install_from PKG URL MD5 CODE
    local pkg="$1" url="$2" md5="$3" code="$4" apk="$DL/$1-$4.apk"
    [ -s "$apk" ] || { curl -fsSL -m 300 -o "$apk.part" "$url" && mv -f "$apk.part" "$apk"; } || return 1
    if [ "$md5" != "-" ] && [ -n "$md5" ] && [ "$(md5sum < "$apk" | cut -d' ' -f1)" != "$md5" ]; then
        rm -f "$apk"; echo "$pkg: download failed the checksum, not installed"; return 1
    fi
    waydroid app install "$apk" >/dev/null 2>&1 || return 1
    find "$DL" -name "$pkg-*.apk" ! -name "$pkg-$code.apk" -delete 2>/dev/null   # keep only the newest
    sleep 3
    echo "$(store_name "$pkg"): installed build $code"
}

update_one() {          # update_one PKG
    local pkg="$1" have url md5 code
    have=$(installed_code "$pkg")
    # already installed = only an update check: give up after a few seconds when offline
    read -r url md5 code < <(STORE_URL_TIMEOUT=$([ -n "$have" ] && echo 6 || echo 30) newest "$pkg") || true
    if [ -z "$url" ]; then
        touch -d '-23 hours' "$STAMP/$pkg" 2>/dev/null   # offline: try again in an hour, not every open
        return 1
    fi
    if [ -z "$have" ] || [ "${code:-0}" -gt "$have" ]; then
        install_from "$pkg" "$url" "$md5" "${code:-0}"
    fi
    touch "$STAMP/$pkg"
}

case "$1" in
    ensure)
        pkg="$2"; case " $STORES " in *" $pkg "*) ;; *) exit 0 ;; esac
        if [ -z "$(installed_code "$pkg")" ] || [ -z "$(find "$STAMP/$pkg" -mmin -1440 2>/dev/null)" ]; then
            update_one "$pkg"
        fi ;;
    check)
        for pkg in $STORES; do
            have=$(installed_code "$pkg"); [ -n "$have" ] || continue
            read -r url md5 code < <(newest "$pkg") || continue
            [ "${code:-0}" -gt "$have" ] && printf '%s\t%s\t%s\t%s\n' "$pkg" "$(store_name "$pkg")" "$have" "$code"
        done ;;
    update)
        for pkg in $STORES; do [ -n "$(installed_code "$pkg")" ] && update_one "$pkg"; done ;;
    *) echo "usage: $0 ensure PKG | check | update"; exit 1 ;;
esac
exit 0
