#!/bin/bash
# Runs INSIDE the chroot as the child of cage (cage sets WAYLAND_DISPLAY).
#   session.sh app <package>      on-demand: boot Android, launch <package>, shut down on exit
#   session.sh manager            on-demand: APK Manager text UI
#   session.sh persistent         always-on: boot once, stay hidden, obey /run/android/cmd
#   session.sh confirm-uninstall  "Uninstall Android?" prompt
MODE="$1"; TARGET="$2"
ST=/run/android
CACHE=/mnt/android-roms/.cache/applist.txt
mkdir -p "$ST" "$(dirname "$CACHE")"
export DIALOGRC=/opt/android/dialogrc
W=/opt/android/window.sh
TERM_UI=(foot -F -f "monospace:size=16" -e)

# ---- uninstall confirmation: no Android needed ----
if [ "$MODE" = confirm-uninstall ]; then
    $W find && $W show
    python3 /opt/android/padwatch.py --keys &
    PW=$!
    "${TERM_UI[@]}" sh -c '
        rm -f /tmp/android-uninstall.answer
        c=$(dialog --backtitle "Uninstall Android" --default-item keep --menu \
"This removes Android, the Play Store, APK Manager and the ANDROID system.\n\nChoose what happens to your Android apps and save data:" 16 72 3 \
            keep "Cancel - keep Android installed" \
            data "Uninstall, but KEEP apps + saves (reinstall later)" \
            all  "Uninstall EVERYTHING (apps + saves deleted)" 3>&1 1>&2 2>&3) || c=keep
        if [ "$c" = all ]; then
            dialog --defaultno --yesno "Really delete ALL Android apps and save data?" 7 60 || c=keep
        fi
        echo "$c" > /tmp/android-uninstall.answer'
    kill $PW 2>/dev/null; rm -f "$ST/quit"
    exit 0
fi

cache_apps() { waydroid app list > "$CACHE.tmp" 2>/dev/null && [ -s "$CACHE.tmp" ] && mv -f "$CACHE.tmp" "$CACHE"; }
running()    { waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; }
run_manager() {
    python3 /opt/android/padwatch.py --keys &      # pad -> keyboard while the menu is open
    local kp=$!
    "${TERM_UI[@]}" /opt/android/apk-manager.sh
    kill $kp 2>/dev/null
}
# App stores in the F1 menu (F-Droid, Aurora Store, Aptoide) install themselves the first
# time they are opened; store-apk-url.py knows each store's official download.
ensure_app() {      # ensure_app <package>
    local pkg="$1" url md5 apk
    read -r url md5 < <(python3 /opt/android/store-apk-url.py "$pkg" 2>/dev/null) || true
    [ -n "$url" ] || return 0
    waydroid shell -- pm list packages 2>/dev/null | tr -d '\r' | grep -qx "package:$pkg" && return 0
    apk="/var/cache/android-addon/$pkg.apk"; mkdir -p "$(dirname "$apk")"
    if [ ! -s "$apk" ]; then
        curl -fsSL -m 300 -o "$apk.part" "$url" && mv -f "$apk.part" "$apk"
    fi
    if [ -n "$md5" ] && [ -s "$apk" ] && [ "$(md5sum < "$apk" | cut -d' ' -f1)" != "$md5" ]; then
        rm -f "$apk"; return 1                       # corrupted / tampered download
    fi
    [ -s "$apk" ] && waydroid app install "$apk" >/dev/null 2>&1
    sleep 3
}

leave_android() {   # back to ES: save state, refresh lists
    waydroid shell -- input keyevent KEYCODE_HOME >/dev/null 2>&1   # pauses the game
    cache_apps
    /opt/android/store-play-apps.sh >/dev/null 2>&1                  # copy Google Play installs
    /opt/android/detect-input.sh >/dev/null 2>&1                     # controller / touch badges
}

conf_get() { sed -n "s/^$1=//p" /etc/android-addon/android.conf 2>/dev/null | tail -n1; }
boot_session() {
    waydroid session start >/tmp/waydroid-session.log 2>&1 &
    for _ in $(seq 1 90); do
        running && waydroid shell getprop sys.boot_completed 2>/dev/null | grep -q 1 && return 0
        sleep 1
    done
}

# ---- boot Android ----
rm -f "$ST/quit"
$W find
[ "$MODE" = persistent ] && $W hide || $W show
boot_session

# App mode: Native windows (default: each app is its own full-screen window, no Android UI)
# or Full Android (home screen + nav bar).  persist.* props live in Android's /data, so a
# change only needs one session restart and then sticks.
MULTI=$(conf_get MULTI_WINDOW); [ "$MULTI" = 0 ] && WANT=false || WANT=true   # default: Native windows
if [ "$(waydroid prop get persist.waydroid.multi_windows 2>/dev/null | tr -d '\r')" != "$WANT" ]; then
    waydroid prop set persist.waydroid.multi_windows "$WANT" >/dev/null 2>&1
    waydroid session stop >/dev/null 2>&1; sleep 2
    boot_session
fi
[ "$WANT" = false ] && waydroid show-full-ui >/dev/null 2>&1 &
python3 /opt/android/padwatch.py &       # Select/Hotkey + Start held 1 s -> /run/android/quit
PW=$!
REPORT_DELAY=3 python3 /opt/android/padwatch.py --android-report >/dev/null 2>&1 &   # controller log

# ================= always-on =================
if [ "$MODE" = persistent ]; then
    trap 'kill $PW 2>/dev/null; $W hide; waydroid session stop >/dev/null 2>&1' EXIT
    cache_apps
    touch "$ST/ready"
    i=0
    while running; do
        if [ -f "$ST/cmd" ]; then
            read -r what pkg < "$ST/cmd"; rm -f "$ST/cmd" "$ST/quit" "$ST/hidden"
            $W show
            if [ "$what" = manager ]; then
                run_manager; touch "$ST/quit"
            else
                ensure_app "$pkg"
                waydroid app launch "$pkg"
            fi
        fi
        if [ -f "$ST/quit" ]; then
            rm -f "$ST/quit"
            if [ -f "$ST/visible" ]; then
                leave_android; $W hide; touch "$ST/hidden"
            fi
            [ "$(conf_get ALWAYS_ON)" = 1 ] || break
            # App mode changed in APK Manager -> end this session; the launcher re-boots it
            [ "$(conf_get MULTI_WINDOW)" = 0 ] && NOW=false || NOW=true
            [ "$NOW" = "$WANT" ] || break
        fi
        sleep 0.5; i=$((i+1)); [ $((i % 240)) -eq 0 ] && cache_apps
    done
    exit 0
fi

# ================= on-demand =================
trap 'kill $PW 2>/dev/null; leave_android; waydroid session stop >/dev/null 2>&1' EXIT
if [ "$MODE" = manager ]; then
    run_manager
    exit 0
fi
cache_apps
sleep 2
ensure_app "$TARGET"
waydroid app launch "$TARGET"
i=0
while [ ! -f "$ST/quit" ] && running; do
    sleep 1; i=$((i+1)); [ $((i % 30)) -eq 0 ] && cache_apps
done
rm -f "$ST/quit"
