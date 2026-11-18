#!/bin/bash
# APK Manager (runs INSIDE the chroot, Android session already running).
#   * install .apk files dropped in roms/android/apk
#   * reinstall stored Google Play apps from roms/android/apk/google-play
#   * uninstall apps (Play Store or APK)
#   * store copies of everything Google Play installed
APK_DIR=${ANDROID_APK_DIR:-/mnt/android-roms/apk}
DONE_DIR=$APK_DIR/installed
STORE_DIRS="google-play f-droid aurora aptoide"   # roms/android/apk/<store>/<package>/
CACHE=/mnt/android-roms/.cache/applist.txt
ADATA=${ANDROID_DATA_DIR:-/root/.local/share/waydroid/data}
WS=/opt/waydroid_script
export DIALOGRC=/opt/android/dialogrc
mkdir -p "$APK_DIR" "$DONE_DIR"
T="APK Manager  v$(cat /opt/android/VERSION 2>/dev/null || echo '?')"
# where things are, as the user sees them on the network share
if [ "$ANDROID_HOST_MODE" = 1 ]; then          # HippOS
    SHOW_APK="roms/android-apk"; SHOW_SAVES="roms/androidgames/saves"; SYSNAME="Android Games"
else
    SHOW_APK="roms/android/apk"; SHOW_SAVES="roms/android/saves"; SYSNAME="ANDROID"
fi

msg()  { dialog --backtitle "$T" --msgbox "$1" 16 72; }
busy() { echo "$1" | dialog --backtitle "$T" --progressbox 6 72; }
refresh_cache() { sleep 2; waydroid app list > "$CACHE" 2>/dev/null; /opt/android/installed-apps.sh --cache >/dev/null 2>&1; }

store_label() { case "$1" in google-play) echo "Google Play";; f-droid) echo "F-Droid";; aurora) echo "Aurora";; aptoide) echo "Aptoide";; *) echo "$1";; esac; }

installed_pkgs() { waydroid shell -- pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://'; }

# install a stored store app (base + split APKs) ------------------------------
install_bundle() {   # install_bundle <dir>
    local dir="$1" n
    n=$(ls "$dir"/*.apk 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || return 1
    if [ "$n" -eq 1 ]; then
        waydroid app install "$dir"/*.apk >/dev/null 2>&1; return $?
    fi
    local tmp="$ADATA/local/tmp/apkm"; rm -rf "$tmp"; mkdir -p "$tmp"
    cp -f "$dir"/*.apk "$tmp/"; chmod 644 "$tmp"/*.apk
    local list; list=$(cd "$tmp" && ls *.apk | sed 's#^#/data/local/tmp/apkm/#' | tr '\n' ' ')
    waydroid shell -- sh -c "pm install-multiple -r $list" 2>&1 | tr -d '\r' | grep -q Success
    local rc=$?; rm -rf "$tmp"; return $rc
}

install_menu() {
    local items=() f d name inst
    inst=" $(installed_pkgs | tr '\n' ' ') "
    local kind
    while IFS= read -r f; do
        case "${f##*.}" in
            [aA][pP][kK])         kind="APK" ;;
            [xX][aA][pP][kK])     kind="XAPK bundle (APKPure)" ;;
            [aA][pP][kK][sS])     kind="APKS split set" ;;
            [aA][pP][kK][mM])     kind="APKM bundle (APKMirror)" ;;
        esac
        items+=("apk:$f" "$kind" on)
    done < <(find "$APK_DIR" -maxdepth 1 -type f \( -iname '*.apk' -o -iname '*.xapk' -o -iname '*.apks' -o -iname '*.apkm' \) -printf '%f\n' | sort)
    local sd
    for sd in $STORE_DIRS; do
        for d in "$APK_DIR/$sd"/*/; do
            [ -d "$d" ] || continue
            f=$(basename "$d"); [[ "$inst" == *" $f "* ]] && continue      # already installed
            name=$(cat "$d/.name" 2>/dev/null)
            items+=("store:$sd/$f" "$(store_label "$sd"): ${name:-$f}" off)
        done
    done
    if [ ${#items[@]} -eq 0 ]; then
        msg "Nothing to install.\n\nCopy .apk / .xapk / .apks / .apkm files to the network share:\n  share / ${SHOW_APK//\// / }\n  (/userdata/$SHOW_APK)\n\nSaved store apps that are already installed are hidden."
        return
    fi
    local pick
    pick=$(dialog --backtitle "$T" --separate-output --checklist \
        "A = confirm   X = toggle   B = back" 20 76 12 "${items[@]}" 3>&1 1>&2 2>&3) || return
    local ok=0 fail=0 out="" it
    while IFS= read -r it; do
        [ -n "$it" ] || continue
        case "$it" in
            apk:*)  f="${it#apk:}"; busy "Installing $f ..."
                    local r; r=$(/opt/android/install-package.sh "$APK_DIR/$f")
                    if [ "${r:0:2}" = OK ]; then
                        mv -f "$APK_DIR/$f" "$DONE_DIR/"; ok=$((ok+1))
                    else fail=$((fail+1)); fi
                    out+="$r\n" ;;
            store:*) f="${it#store:}"; busy "Reinstalling ${f#*/} ..."
                    if install_bundle "$APK_DIR/$f"; then ok=$((ok+1)); out+="OK    ${f#*/}\n"
                        [ -d "$APK_DIR/$f/obb" ] && { busy "Restoring game data (OBB) for ${f#*/} ..."
                            /opt/android/app-data.sh obb-restore "${f#*/}" "$APK_DIR/$f" >/dev/null && out+="      + game data (OBB)\n"; }
                        [ -n "$(ls "$SAVES_DIR/${f#*/}"/*.tar.gz 2>/dev/null)" ] && out+="      saves backup found: Game saves -> Restore\n"
                    else fail=$((fail+1)); out+="FAIL  ${f#*/}\n"; fi ;;
        esac
    done <<< "$pick"
    refresh_cache
    msg "Installed: $ok   Failed: $fail\n\n$out\nNew games appear in the $SYSNAME system when you exit."
}

uninstall_menu() {
    local items=() p sid label n
    while IFS=$'\t' read -r p sid label n; do
        items+=("$p" "[$label] $n" off)
    done < <(/opt/android/installed-apps.sh | sort -t$'\t' -k4,4f)
    [ ${#items[@]} -eq 0 ] && { msg "No installed apps found."; return; }
    local pick
    pick=$(dialog --backtitle "$T" --separate-output --checklist \
        "Select apps to REMOVE   X = toggle   A = confirm" 20 76 12 "${items[@]}" 3>&1 1>&2 2>&3) || return
    [ -z "$pick" ] && return
    dialog --backtitle "$T" --yesno "Uninstall these apps and their save data?\n\n$pick\n\n(Saved copies of store apps are kept so you can reinstall.)" 18 72 || return
    while IFS= read -r p; do [ -n "$p" ] && { busy "Removing $p ..."; waydroid app remove "$p" >/dev/null 2>&1; }; done <<< "$pick"
    refresh_cache
    msg "Removed. Their entries disappear from the $SYSNAME system when you exit."
}

store_menu() {
    busy "Saving copies of apps from Google Play, F-Droid, Aurora and Aptoide ..."
    local r; r=$(/opt/android/store-installed-apps.sh 2>&1 | tail -n1)
    msg "$r\n\nLocation: $SHOW_APK/<store>/\n  google-play  f-droid  aurora  aptoide\nThis also happens automatically every time you leave Android."
}

CONF=/etc/android-addon/android.conf
SAVES_DIR=/mnt/android-roms/saves
conf_is() { [ "$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n1)" = 1 ]; }
conf_set() { sed -i "/^$1=/d" "$CONF"; echo "$1=$2" >> "$CONF"; }

pick_app() {    # pick_app "prompt" [only-with-backups] -> package on stdout
    local items=() p sid label n
    while IFS=$'\t' read -r p sid label n; do
        [ "$2" = backups ] && [ -z "$(ls "$SAVES_DIR/$p"/*.tar.gz 2>/dev/null)" ] && continue
        items+=("$p" "[$label] $n")
    done < <(/opt/android/installed-apps.sh | sort -t$'\t' -k4,4f)
    [ ${#items[@]} -eq 0 ] && { msg "No apps found${2:+ with a saves backup}."; return 1; }
    dialog --backtitle "$T" --menu "$1" 20 76 12 "${items[@]}" 3>&1 1>&2 2>&3
}

saves_menu() {
    while true; do
        local c AS AO
        conf_is BACKUP_SAVES && AS=ON || AS=OFF
        conf_is BACKUP_OBB && AO=ON || AO=OFF
        c=$(dialog --backtitle "$T" --menu "Game saves + game data\n\nSaves: $SHOW_SAVES/<package>/  (newest 5 kept)\nOBB game data: next to the stored APKs in $SHOW_APK/<store>/" 18 76 6 \
            1 "Back up an app's saves now" \
            2 "Restore an app's saves" \
            3 "Back up ALL apps' saves now" \
            4 "Auto-backup saves when leaving Android: $AS" \
            5 "Back up OBB game data with store apps: $AO" \
            6 "Back" 3>&1 1>&2 2>&3) || return
        case "$c" in
            1) local p; p=$(pick_app "Back up saves of:") || continue
               busy "Backing up $p ..."; msg "$(/opt/android/app-data.sh backup "$p" 2>&1)" ;;
            2) local p f items=() b; p=$(pick_app "Restore saves of:" backups) || continue
               while IFS= read -r b; do items+=("$b" "$(basename "$b" .tar.gz | sed 's/\(....\)\(..\)\(..\)-\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')"); done \
                   < <(/opt/android/app-data.sh list "$p")
               f=$(dialog --backtitle "$T" --no-tags --menu "Restore which backup of $p?\n(The app's current progress is replaced.)" 18 70 8 "${items[@]}" 3>&1 1>&2 2>&3) || continue
               busy "Restoring $p ..."; msg "$(/opt/android/app-data.sh restore "$p" "$f" 2>&1)" ;;
            3) /opt/android/installed-apps.sh | cut -f1 | grep -vxE 'org.fdroid.fdroid|org.fdroid.basic|com.aurora.store|cm.aptoide.pt' |
                   while read -r p; do /opt/android/app-data.sh backup "$p"; done 2>&1 | tee /tmp/saves.txt |
                   dialog --backtitle "$T" --progressbox "Backing up saves ..." 20 76
               dialog --backtitle "$T" --title "Saves backup" --textbox /tmp/saves.txt 20 76 ;;
            4) if conf_is BACKUP_SAVES; then conf_set BACKUP_SAVES 0; msg "Auto-backup of saves is OFF."
               else conf_set BACKUP_SAVES 1
                    msg "Auto-backup of saves is ON.\n\nEvery time you leave Android, apps whose data changed are backed up\nto $SHOW_SAVES/ (newest 5 per app). It runs in the background."
               fi ;;
            5) if conf_is BACKUP_OBB; then conf_set BACKUP_OBB 0; msg "OBB game data backup is OFF."
               else
                   dialog --backtitle "$T" --yesno "Back up OBB game data too?\n\nSome big games download extra data (often 1-4 GB) after install.\nWith this ON it is copied next to the stored APKs, so a reinstall from\nAPK Manager works fully without the store. Needs that much free space\non the share. Only changed data is copied, in the background." 14 76 || continue
                   conf_set BACKUP_OBB 1; msg "OBB game data backup is ON.\nIt runs the next time you leave Android."
               fi ;;
            *) return ;;
        esac
    done
}

always_on() { [ "$(sed -n 's/^ALWAYS_ON=//p' "$CONF" 2>/dev/null | tail -n1)" = 1 ]; }

toggle_always_on() {
    if always_on; then
        dialog --backtitle "$T" --yesno "Turn Always-on OFF?\n\nAndroid will boot only when you launch something\n(10-20 s wait) and shut down when you leave,\nfreeing ~2 GB of RAM." 11 60 || return
        sed -i '/^ALWAYS_ON=/d' "$CONF"; echo "ALWAYS_ON=0" >> "$CONF"
        msg "Always-on is OFF.\n\nAndroid shuts down when you leave this menu."
    else
        local note=""
        { [ -z "$DISPLAY" ] || [ "$WAYLAND_HOST" = 1 ]; } && note="\n\nNOTE: this screen is not plain X11, so Android will\nstay on-demand even with this setting ON."
        dialog --backtitle "$T" --yesno "Turn Always-on ON?\n\nAndroid stays booted, hidden behind EmulationStation:\n + games open in ~1 second\n + Play Store updates apps in the background\n - uses ~2 GB RAM and a little CPU all the time$note" 14 64 || return
        sed -i '/^ALWAYS_ON=/d' "$CONF"; echo "ALWAYS_ON=1" >> "$CONF"
        msg "Always-on is ON.\n\nAndroid stays booted from now on, including after a reboot."
    fi
}

multi_window() { [ "$(sed -n 's/^MULTI_WINDOW=//p' "$CONF" 2>/dev/null | tail -n1)" != 0 ]; }   # default ON

toggle_app_mode() {
    local cur pick
    multi_window && cur=native || cur=full
    pick=$(dialog --backtitle "$T" --default-item "$cur" --menu \
"How should Android apps open?\n\n\
Native windows - each game or app opens as its own full-screen window,\n\
                no Android UI (feels like a PC app). Use B / Esc for Back.\n\
                A few games handle this mode badly - use Full Android then.\n\
Full Android  - Android home screen, status bar and Back/Home/Recents\n\
                buttons stay on screen (like a tablet). Most compatible." 18 76 2 \
        native "Native windows (default)" \
        full   "Full Android" 3>&1 1>&2 2>&3) || return
    [ "$pick" = "$cur" ] && return
    sed -i '/^MULTI_WINDOW=/d' "$CONF"
    if [ "$pick" = native ]; then echo "MULTI_WINDOW=1" >> "$CONF"; else echo "MULTI_WINDOW=0" >> "$CONF"; fi
    msg "App mode set to: $( [ "$pick" = native ] && echo 'Native windows' || echo 'Full Android')\n\nIt takes effect the next time Android starts\n(Android restarts once to apply it)."
}

CLOG=/var/log/android-addon/android-controllers.log
REPO="rmach89/android-batocera-hippos"
QUEUE=/etc/android-addon/update-queue          # the host runs it after you leave Android
MYVER="v$(cat /opt/android/VERSION 2>/dev/null || echo 0.0.0)"
ver_num() { local v="${1#v}"; IFS=. read -r a b c <<< "$v"; echo $(( ${a:-0}*100 + ${b:-0}*10 + ${c:-0} )); }

updates_menu() {
    busy "Checking GitHub and the app stores for updates ..."
    local tag notes stores
    tag=$(python3 /opt/android/latest-version.py 2>/dev/null | cut -d' ' -f1)
    if [ -z "$tag" ]; then notes="Could not reach GitHub (offline?)"
    elif [ "$(ver_num "$tag")" -gt "$(ver_num "$MYVER")" ]; then notes="UPDATE AVAILABLE: $tag"
    else notes="Add-on is up to date"; fi
    stores=$(/opt/android/update-stores.sh check 2>/dev/null | cut -f2 | paste -sd, - | sed 's/,/, /g')
    local snote="App stores are up to date"
    [ -n "$stores" ] && snote="Store updates: $stores"
    local c
    c=$(dialog --backtitle "$T" --menu "Installed: $MYVER     Newest: ${tag:-?}\n$notes\n$snote\n\nAdd-on/Android updates run after you leave Android\n(Android is unavailable for a few minutes). Store updates install now." 19 72 5 \
        1 "Update the add-on to the newest version" \
        2 "Update Android (Waydroid + Android system image)" \
        3 "Update the app stores (F-Droid, Aurora, Aptoide)" \
        4 "Update everything" \
        5 "Back" 3>&1 1>&2 2>&3) || return
    case "$c" in
        1) echo addon > "$QUEUE" ;;
        2) echo android > "$QUEUE" ;;
        3) update_stores_now; return ;;
        4) update_stores_now; echo "android addon" > "$QUEUE" ;;
        *) return ;;
    esac
    msg "Queued. The update starts as soon as you leave APK Manager.\n\nProgress: /userdata/system/logs/android.log\nYour apps, saves and settings are kept."
}

update_stores_now() {
    /opt/android/update-stores.sh update 2>&1 | tee /tmp/stores.txt | \
        dialog --backtitle "$T" --progressbox "Updating app stores ..." 12 70
    [ -s /tmp/stores.txt ] || echo "All installed app stores are already up to date." > /tmp/stores.txt
    dialog --backtitle "$T" --title "App stores" --textbox /tmp/stores.txt 12 70
}

controllers_menu() {
    while true; do
        local c
        c=$(dialog --backtitle "$T" --menu "Controllers\n\nLog file: /userdata/system/logs/android-controllers.log" 15 72 4 \
            1 "Controller test (show every button + stick live)" \
            2 "Check which controllers Android sees" \
            3 "Show controller log" \
            4 "Back" 3>&1 1>&2 2>&3) || return
        case "$c" in
            1) clear; python3 /opt/android/padwatch.py --test ;;
            2) python3 /opt/android/padwatch.py --android-report
               grep -E "\] \[(watch|test)\] (linux|android)" "$CLOG" | tail -n 25 > /tmp/ctl.txt
               dialog --backtitle "$T" --title "Linux vs Android (newest last)" --textbox /tmp/ctl.txt 22 100 ;;
            3) tail -n 300 "$CLOG" > /tmp/ctl.txt 2>/dev/null || echo "(no log yet)" > /tmp/ctl.txt
               dialog --backtitle "$T" --title "android-controllers.log (newest last)" --textbox /tmp/ctl.txt 22 100 ;;
            *) return ;;
        esac
    done
}

rebuild_boxes() {
    dialog --backtitle "$T" --yesno "Rebuild every 3D box and game info?\n\nSources: LaunchBox, ScreenScraper, Google Play, F-Droid\n(Downloads the latest LaunchBox database first - a few minutes.)" 11 66 || return
    python3 /opt/android/scrape-launchbox.py --force --refresh 2>&1 | tail -n 15 | \
        dialog --backtitle "$T" --progressbox "Building boxes..." 20 76
    msg "Done. EmulationStation shows the new boxes when you exit.\n\nWrong match? Add a line  package=LaunchBoxID  to\n/userdata/system/add-ons/android/settings/launchbox-overrides.conf"
}

play_cert() {
    local id
    id=$(cd "$WS" && ./venv/bin/python3 main.py certified 2>/dev/null | grep -Eo '[0-9]{15,}' | head -n1)
    if [ -n "$id" ]; then
        echo "$id" > "$APK_DIR/PLAY-STORE-DEVICE-ID.txt"
        msg "Google Play device ID:\n\n  $id\n\n1. On a phone/PC open https://www.google.com/android/uncertified\n2. Sign in, paste the ID, Register.\n3. Wait ~10-20 min, then reopen the Play Store.\n\n(Saved to $SHOW_APK/PLAY-STORE-DEVICE-ID.txt)"
    else
        msg "Could not read the device ID yet.\nOpen the Google Play Store once, wait a minute, then try again."
    fi
}

while true; do
    always_on && AO="ON " || AO="OFF"
    multi_window && AM="Native windows" || AM="Full Android"
    c=$(dialog --backtitle "$T" --no-cancel --menu "D-pad = move   A = select   Select+Start = exit" 24 72 13 \
        1 "Install apps  (APK, XAPK, APKS, APKM + saved store apps)" \
        2 "Uninstall apps" \
        3 "Save copies of store apps now" \
        4 "Google Play: register this device ('not certified' fix)" \
        5 "Refresh $SYSNAME game list" \
        6 "Always-on (keep Android booted): $AO" \
        7 "App mode: $AM" \
        8 "Rebuild 3D boxes + game info (all sources)" \
        9 "Controllers: test, log, what Android sees" \
        10 "Updates: add-on, Android, app stores" \
        11 "Game saves + game data (backup / restore)" \
        12 "Exit" 3>&1 1>&2 2>&3) || c=12
    case "$c" in
        1) install_menu ;;
        2) uninstall_menu ;;
        3) store_menu ;;
        4) play_cert ;;
        5) refresh_cache; msg "The game list refreshes when you exit." ;;
        6) toggle_always_on ;;
        7) toggle_app_mode ;;
        8) rebuild_boxes ;;
        9) controllers_menu ;;
        10) updates_menu ;;
        11) saves_menu ;;
        12) exit 0 ;;
    esac
done
