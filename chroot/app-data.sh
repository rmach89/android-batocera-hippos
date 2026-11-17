#!/bin/bash
# Game data that lives outside the APK. Runs INSIDE the chroot; works on Android's /data
# directly from the chroot, so most of it does not need the Android session.
#
#   OBB data (big games download their graphics/levels here after install)
#     app-data.sh obb-backup  PKG DIR     copy Android/obb/PKG  -> DIR/obb/   (skipped if unchanged)
#     app-data.sh obb-restore PKG DIR     copy DIR/obb/        -> Android/obb/PKG
#
#   Saves (the app's private data: progress, settings, offline saves)
#     app-data.sh backup  PKG             -> roms/android/saves/PKG/<date-time>.tar.gz (newest 5 kept)
#     app-data.sh restore PKG [FILE]      newest backup (or FILE) back into the installed app
#     app-data.sh list    PKG             backups of PKG, newest first
#
#   app-data.sh auto      run when you leave Android: OBB backups if BACKUP_OBB=1 and save backups
#                         if BACKUP_SAVES=1 (android.conf), only for apps whose data changed
ADATA=/root/.local/share/waydroid/data              # Android's /data, seen from the chroot
OBB=$ADATA/media/0/Android/obb
EXT=$ADATA/media/0/Android/data
SAVES=/mnt/android-roms/saves
APKROOT=/mnt/android-roms/apk
SOURCES=/mnt/android-roms/.cache/app-sources.txt
CONF=/etc/android-addon/android.conf
KEEP=5
EXT_MAX_MB=500          # Android/data/PKG bigger than this is downloaded content, not saves
EXT_DATA_GID=1078       # ext_data_rw
EXT_OBB_GID=1079        # ext_obb_rw

conf()    { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n1; }
app_uid() { stat -c %u "$ADATA/data/$1" 2>/dev/null; }
sig()     { find "$1" -type f -printf '%s %T@ %P\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1; }
label()   { awk -F'\t' -v p="$1" '$1==p{print $4; exit}' <(/opt/android/installed-apps.sh 2>/dev/null); }
fix_context() { waydroid shell -- restorecon -RF "$1" >/dev/null 2>&1 || true; }   # needs the session; harmless without

# ------------------------------------------------------------------ OBB
obb_backup() {          # obb_backup PKG DIR
    local pkg="$1" dst="$2/obb" s
    [ -d "$OBB/$pkg" ] && [ -n "$(ls -A "$OBB/$pkg" 2>/dev/null)" ] || return 0
    s=$(sig "$OBB/$pkg")
    [ -f "$2/.obb-sig" ] && [ "$(cat "$2/.obb-sig")" = "$s" ] && return 0       # unchanged
    rm -rf "$dst.part"; mkdir -p "$dst.part"
    cp -a "$OBB/$pkg/." "$dst.part/" || { rm -rf "$dst.part"; echo "$pkg: OBB copy failed (disk full?)"; return 1; }
    rm -rf "$dst"; mv "$dst.part" "$dst"; echo "$s" > "$2/.obb-sig"
    echo "$pkg: OBB data saved ($(du -sh "$dst" | cut -f1))"
}

obb_restore() {         # obb_restore PKG DIR
    local pkg="$1" src="$2/obb" uid
    [ -d "$src" ] || return 0
    uid=$(app_uid "$pkg"); [ -n "$uid" ] || { echo "$pkg: not installed"; return 1; }
    mkdir -p "$OBB/$pkg"
    cp -a "$src/." "$OBB/$pkg/" || return 1
    chown -R "$uid:$EXT_OBB_GID" "$OBB/$pkg"; chmod -R u+rwX,g+rwX "$OBB/$pkg"
    fix_context "/data/media/0/Android/obb/$pkg"
    echo "$pkg: OBB data restored"
}

# ------------------------------------------------------------------ saves
backup() {              # backup PKG
    local pkg="$1" dir="$SAVES/$1" ts last
    [ -d "$ADATA/data/$pkg" ] || { echo "$pkg: not installed"; return 1; }
    mkdir -p "$dir"
    last=$(ls -1t "$dir"/*.tar.gz 2>/dev/null | head -n1)
    if [ -n "$last" ] && [ "$3" = changed ] &&
       [ -z "$(find "$ADATA/data/$pkg" "$EXT/$pkg" -newer "$last" -type f -print -quit 2>/dev/null)" ]; then
        return 0                                                    # nothing changed since last backup
    fi
    ts=$(date +%Y%m%d-%H%M%S)
    local t="$dir/$ts.tar"
    tar -cf "$t" -C "$ADATA/data" --exclude="$pkg/cache" --exclude="$pkg/code_cache" \
        --exclude="$pkg/lib" "$pkg" 2>/dev/null || { rm -f "$t"; echo "$pkg: backup failed"; return 1; }
    if [ -d "$EXT/$pkg" ] && [ "$(du -sm "$EXT/$pkg" | cut -f1)" -le "$EXT_MAX_MB" ]; then
        tar -rf "$t" -C "$EXT" --exclude="$pkg/cache" --transform "s#^$pkg#external/$pkg#" "$pkg" 2>/dev/null
    fi
    gzip -c "$t" > "$dir/$ts.tar.gz.part" && rm -f "$t" || { rm -f "$t" "$dir/$ts.tar.gz.part"; echo "$pkg: backup failed (disk full?)"; return 1; }
    mv "$dir/$ts.tar.gz.part" "$dir/$ts.tar.gz"
    [ -n "$2" ] && echo "$2" > "$dir/.name"
    ls -1t "$dir"/*.tar.gz | tail -n +$((KEEP+1)) | xargs -r rm -f
    echo "$pkg: saves backed up ($ts)"
}

restore() {             # restore PKG [FILE]
    local pkg="$1" file="${2:-$(ls -1t "$SAVES/$1"/*.tar.gz 2>/dev/null | head -n1)}" uid tmp
    [ -f "$file" ] || { echo "$pkg: no backup found"; return 1; }
    uid=$(app_uid "$pkg"); [ -n "$uid" ] || { echo "$pkg: install the app first, then restore"; return 1; }
    waydroid shell -- am force-stop "$pkg" >/dev/null 2>&1
    tmp=$(mktemp -d /tmp/restore.XXXXXX)
    tar -xzf "$file" -C "$tmp" || { rm -rf "$tmp"; echo "$pkg: backup is damaged"; return 1; }
    # private data: replace everything except lib (a link into the installed APK)
    find "$ADATA/data/$pkg" -mindepth 1 -maxdepth 1 ! -name lib -exec rm -rf {} +
    cp -a "$tmp/$pkg/." "$ADATA/data/$pkg/"
    chown -R "$uid:$uid" "$ADATA/data/$pkg"
    [ -d "$ADATA/data/$pkg/cache" ] && chown "$uid:$(( uid % 100000 - 10000 + 20000 ))" "$ADATA/data/$pkg/cache"
    fix_context "/data/data/$pkg"
    if [ -d "$tmp/external/$pkg" ]; then
        mkdir -p "$EXT/$pkg"; cp -a "$tmp/external/$pkg/." "$EXT/$pkg/"
        chown -R "$uid:$EXT_DATA_GID" "$EXT/$pkg"; chmod -R u+rwX,g+rwX "$EXT/$pkg"
        fix_context "/data/media/0/Android/data/$pkg"
    fi
    rm -rf "$tmp"
    echo "$pkg: saves restored from $(basename "$file" .tar.gz)"
}

auto() {
    local obb saves pkg sid _l name
    obb=$(conf BACKUP_OBB); saves=$(conf BACKUP_SAVES)
    [ "$obb" = 1 ] || [ "$saves" = 1 ] || return 0
    [ -s "$SOURCES" ] || return 0
    while IFS=$'\t' read -r pkg sid; do
        [ -n "$pkg" ] || continue
        if [ "$obb" = 1 ] && [ -d "$APKROOT/$sid/$pkg" ]; then      # only store apps have a backup folder
            obb_backup "$pkg" "$APKROOT/$sid/$pkg"
        fi
        if [ "$saves" = 1 ]; then
            case "$pkg" in org.fdroid.fdroid|org.fdroid.basic|com.aurora.store|cm.aptoide.pt) continue ;; esac
            backup "$pkg" "" changed
        fi
    done < "$SOURCES"
}

case "$1" in
    obb-backup)  obb_backup "$2" "$3" ;;
    obb-restore) obb_restore "$2" "$3" ;;
    backup)      backup "$2" "$(label "$2")" ;;
    restore)     restore "$2" "$3" ;;
    list)        ls -1t "$SAVES/$2"/*.tar.gz 2>/dev/null ;;
    auto)        auto ;;
    *) sed -n '2,17p' "$0"; exit 1 ;;
esac
