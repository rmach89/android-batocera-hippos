#!/bin/bash
# APK Manager (runs INSIDE the chroot, Android session already running).
#   * install .apk files dropped in roms/android/apk
#   * reinstall stored Google Play apps from roms/android/apk/google-play
#   * uninstall apps (Play Store or APK)
#   * store copies of everything Google Play installed
APK_DIR=/mnt/android-roms/apk
DONE_DIR=$APK_DIR/installed
PLAY_DIR=$APK_DIR/google-play
CACHE=/mnt/android-roms/.cache/applist.txt
ADATA=/root/.local/share/waydroid/data
WS=/opt/waydroid_script
export DIALOGRC=/opt/android/dialogrc
mkdir -p "$APK_DIR" "$DONE_DIR" "$PLAY_DIR"
T="APK Manager  v$(cat /opt/android/VERSION 2>/dev/null || echo '?')"

msg()  { dialog --backtitle "$T" --msgbox "$1" 16 72; }
busy() { echo "$1" | dialog --backtitle "$T" --progressbox 6 72; }
refresh_cache() { sleep 2; waydroid app list > "$CACHE" 2>/dev/null; }

is_system() { [[ "$1" =~ ^(android|com\.android\.|com\.google\.|org\.lineageos\.|id\.waydro\.|org\.chromium\.) ]]; }

installed_pkgs() { waydroid shell -- pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://'; }

# install a stored Play app (base + split APKs) -------------------------------
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
    while IFS= read -r f; do items+=("apk:$f" "APK file" on); done \
        < <(find "$APK_DIR" -maxdepth 1 -type f -iname '*.apk' -printf '%f\n' | sort)
    for d in "$PLAY_DIR"/*/; do
        [ -d "$d" ] || continue
        f=$(basename "$d"); [[ "$inst" == *" $f "* ]] && continue      # already installed
        name=$(cat "$d/.name" 2>/dev/null); items+=("play:$f" "Google Play: ${name:-$f}" off)
    done
    if [ ${#items[@]} -eq 0 ]; then
        msg "Nothing to install.\n\nCopy .apk files to the network share:\n  share / roms / android / apk\n  (/userdata/roms/android/apk)\n\nStored Google Play apps that are already installed are hidden."
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
                    if waydroid app install "$APK_DIR/$f" >/dev/null 2>&1; then
                        mv -f "$APK_DIR/$f" "$DONE_DIR/"; ok=$((ok+1)); out+="OK    $f\n"
                    else fail=$((fail+1)); out+="FAIL  $f\n"; fi ;;
            play:*) f="${it#play:}"; busy "Reinstalling $f ..."
                    if install_bundle "$PLAY_DIR/$f"; then ok=$((ok+1)); out+="OK    $f\n"
                    else fail=$((fail+1)); out+="FAIL  $f\n"; fi ;;
        esac
    done <<< "$pick"
    refresh_cache
    msg "Installed: $ok   Failed: $fail\n\n$out\nNew games appear in the ANDROID system when you exit."
}

uninstall_menu() {
    local play items=() p n src
    play=" $(/opt/android/store-play-apps.sh --list | tr '\n' ' ') "
    while IFS=$'\t' read -r p n; do
        is_system "$p" && continue
        [[ "$play" == *" $p "* ]] && src="Google Play" || src="APK"
        items+=("$p" "[$src] $n" off)
    done < <(waydroid app list 2>/dev/null | awk -F': ' '/^Name:/{n=$2} /^packageName:/{gsub(/[ \t]/,"",$2); print $2 "\t" n}')
    [ ${#items[@]} -eq 0 ] && { msg "No installed apps found."; return; }
    local pick
    pick=$(dialog --backtitle "$T" --separate-output --checklist \
        "Select apps to REMOVE   X = toggle   A = confirm" 20 76 12 "${items[@]}" 3>&1 1>&2 2>&3) || return
    [ -z "$pick" ] && return
    dialog --backtitle "$T" --yesno "Uninstall these apps and their save data?\n\n$pick\n\n(Stored Google Play copies are kept so you can reinstall.)" 18 72 || return
    while IFS= read -r p; do [ -n "$p" ] && { busy "Removing $p ..."; waydroid app remove "$p" >/dev/null 2>&1; }; done <<< "$pick"
    refresh_cache
    msg "Removed. Their entries disappear from the ANDROID system when you exit."
}

store_menu() {
    busy "Saving copies of Google Play apps ..."
    local r; r=$(/opt/android/store-play-apps.sh 2>&1 | tail -n1)
    msg "$r\n\nLocation: roms/android/apk/google-play/\nThis also happens automatically every time you leave Android."
}

CONF=/etc/android-addon/android.conf
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
    busy "Checking GitHub for the newest version ..."
    local tag notes
    tag=$(python3 /opt/android/latest-version.py 2>/dev/null | cut -d' ' -f1)
    if [ -z "$tag" ]; then notes="Could not reach GitHub (offline?)"
    elif [ "$(ver_num "$tag")" -gt "$(ver_num "$MYVER")" ]; then notes="UPDATE AVAILABLE: $tag"
    else notes="Add-on is up to date"; fi
    local c
    c=$(dialog --backtitle "$T" --menu "Installed: $MYVER     Newest: ${tag:-?}\n$notes\n\nUpdates run in the background after you leave Android.\nAndroid is unavailable for a few minutes while they install." 17 72 4 \
        1 "Update the add-on to the newest version" \
        2 "Update Android (Waydroid + Android system image)" \
        3 "Update both" \
        4 "Back" 3>&1 1>&2 2>&3) || return
    case "$c" in
        1) echo addon > "$QUEUE" ;;
        2) echo android > "$QUEUE" ;;
        3) echo "android addon" > "$QUEUE" ;;
        *) return ;;
    esac
    msg "Queued. The update starts as soon as you leave APK Manager.\n\nProgress: /userdata/system/logs/android.log\nYour apps, saves and settings are kept."
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
    dialog --backtitle "$T" --yesno "Rebuild every 3D box and game info from the\nLaunchBox Games Database?\n\n(Downloads the latest database first - a few minutes.)" 10 60 || return
    python3 /opt/android/scrape-launchbox.py --force --refresh 2>&1 | tail -n 15 | \
        dialog --backtitle "$T" --progressbox "Building boxes..." 20 76
    msg "Done. EmulationStation shows the new boxes when you exit.\n\nWrong match? Add a line  package=LaunchBoxID  to\n/userdata/system/add-ons/android/settings/launchbox-overrides.conf"
}

play_cert() {
    local id
    id=$(cd "$WS" && ./venv/bin/python3 main.py certified 2>/dev/null | grep -Eo '[0-9]{15,}' | head -n1)
    if [ -n "$id" ]; then
        echo "$id" > "$APK_DIR/PLAY-STORE-DEVICE-ID.txt"
        msg "Google Play device ID:\n\n  $id\n\n1. On a phone/PC open https://www.google.com/android/uncertified\n2. Sign in, paste the ID, Register.\n3. Wait ~10-20 min, then reopen the Play Store.\n\n(Saved to roms/android/apk/PLAY-STORE-DEVICE-ID.txt)"
    else
        msg "Could not read the device ID yet.\nOpen the Google Play Store once, wait a minute, then try again."
    fi
}

while true; do
    always_on && AO="ON " || AO="OFF"
    multi_window && AM="Native windows" || AM="Full Android"
    c=$(dialog --backtitle "$T" --no-cancel --menu "D-pad = move   A = select   Select+Start = exit" 23 72 12 \
        1 "Install apps  (APK files + stored Google Play apps)" \
        2 "Uninstall apps" \
        3 "Store Google Play apps now" \
        4 "Google Play: register this device ('not certified' fix)" \
        5 "Refresh ANDROID game list" \
        6 "Always-on (keep Android booted): $AO" \
        7 "App mode: $AM" \
        8 "Rebuild 3D boxes + game info (LaunchBox)" \
        9 "Controllers: test, log, what Android sees" \
        10 "Updates: add-on + Android" \
        11 "Exit" 3>&1 1>&2 2>&3) || c=11
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
        11) exit 0 ;;
    esac
done
