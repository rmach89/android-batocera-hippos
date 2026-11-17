#!/bin/bash
# Show / hide / fullscreen the cage window on an X11 host (runs INSIDE the chroot).
#   window.sh find   -> waits for cage's X11 window, stores its id in /run/android/winid
#   window.sh show   -> map, fullscreen, raise, focus
#   window.sh hide   -> unmap (EmulationStation is visible again)
[ -n "$DISPLAY" ] && command -v xdotool >/dev/null || exit 0
ST=/run/android; mkdir -p "$ST"
wid() { cat "$ST/winid" 2>/dev/null; }

case "$1" in
  find)
    for _ in $(seq 1 40); do
        id=$(xdotool search --name '^(wlroots|cage)' 2>/dev/null | tail -n1)
        [ -n "$id" ] && { echo "$id" > "$ST/winid"; exit 0; }
        sleep 0.25
    done; exit 1 ;;
  show)
    id=$(wid); [ -n "$id" ] || exit 1
    read -r W H < <(xdotool getdisplaygeometry)
    xdotool windowmap "$id" windowmove "$id" 0 0 windowsize "$id" "$W" "$H" windowraise "$id" 2>/dev/null
    xdotool windowfocus "$id" 2>/dev/null; xdotool windowactivate "$id" 2>/dev/null
    touch "$ST/visible" ;;
  hide)
    id=$(wid); [ -n "$id" ] && xdotool windowunmap "$id" 2>/dev/null
    rm -f "$ST/visible" ;;
esac
exit 0
