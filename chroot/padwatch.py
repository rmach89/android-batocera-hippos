#!/usr/bin/env python3
"""Gamepad helper (runs inside the chroot).

  padwatch.py                 watch for HOTKEY (Select/Back or Guide) + START held 1 s
                              -> writes /run/android/quit (session.sh returns to ES)
  padwatch.py --keys          also turn the gamepad into a keyboard (APK Manager menus)
  padwatch.py --test          Controller test: show + log every button/stick live
  padwatch.py --android-report   log which input devices Android itself sees

Everything is logged to /userdata/system/logs/android-controllers.log
(/var/log/android-addon/android-controllers.log inside the chroot).
"""
import os, re, select, subprocess, sys, time

try:
    import evdev
    from evdev import ecodes as e
except ImportError:
    sys.exit("python3-evdev missing")

LOG = "/var/log/android-addon/android-controllers.log"
KEYMODE = "--keys" in sys.argv
TESTMODE = "--test" in sys.argv
ROLE = "test" if TESTMODE else ("keys" if KEYMODE else "watch")
HOTKEYS = {e.BTN_SELECT, e.BTN_MODE}
HOLD = 2.0 if TESTMODE else 1.0
BUS = {0x03: "USB", 0x05: "Bluetooth", 0x06: "virtual", 0x19: "built-in"}


# ------------------------------------------------------------------ logging
def log(msg):
    line = f"[{time.strftime('%F %T')}] [{ROLE}] {msg}"
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:   # keep it small
            os.replace(LOG, LOG + ".1")
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    if TESTMODE:
        print(msg, flush=True)


def btn_name(code):
    n = e.BTN.get(code) or e.KEY.get(code) or str(code)
    return "/".join(n) if isinstance(n, (list, tuple)) else n


def abs_name(code):
    n = e.ABS.get(code, str(code))
    return "/".join(n) if isinstance(n, (list, tuple)) else n


def describe(d):
    caps = d.capabilities()
    keys, axes = caps.get(e.EV_KEY, []), [c if isinstance(c, int) else c[0] for c in caps.get(e.EV_ABS, [])]
    i = d.info
    flags = [n for n, c in (("SELECT", e.BTN_SELECT), ("START", e.BTN_START), ("GUIDE", e.BTN_MODE)) if c in keys]
    return (f"'{d.name}'  {d.path}  {BUS.get(i.bustype, hex(i.bustype))}  "
            f"vid:pid={i.vendor:04x}:{i.product:04x}  buttons={len(keys)} axes={len(axes)}  "
            f"has={','.join(flags) or 'none'}")


# ------------------------------------------------------------------ Android side
def android_report():
    """Which input devices does Android see? (proves pass-through works)"""
    try:
        out = subprocess.run(["waydroid", "shell", "--", "dumpsys", "input"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception as ex:
        log(f"android: could not query ({ex})"); return
    devs, cur = [], None
    for line in out.splitlines():
        m = re.match(r"\s+Device (-?\d+): (.+)", line)
        if m:
            cur = {"id": m.group(1), "name": m.group(2).strip(), "src": 0}; devs.append(cur); continue
        m = re.match(r"\s+Sources: (0x[0-9a-fA-F]+)", line)
        if m and cur and not cur["src"]:
            cur["src"] = int(m.group(1), 16)
    pads = [d for d in devs if d["src"] & 0x401 == 0x401 or d["src"] & 0x1000010 == 0x1000010]
    if not devs:
        log("android: no input device list returned (is Android booted?)"); return
    log(f"android: {len(devs)} input devices, {len(pads)} game controller(s):")
    for d in pads:
        kinds = [k for k, m in (("gamepad", 0x401), ("joystick", 0x1000010), ("dpad", 0x201)) if d["src"] & m == m]
        log(f"android:   #{d['id']} '{d['name']}'  ({'+'.join(kinds)})")
    if not pads:
        log("android:   NONE - controller is not reaching Android. Check persist.waydroid.uevent/udev "
            "and that the controller is listed above under 'linux:'")


if "--android-report" in sys.argv:
    time.sleep(float(os.environ.get("REPORT_DELAY", "0")))
    android_report(); sys.exit(0)


# ------------------------------------------------------------------ devices
def pads():
    out = []
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
            if d.name.startswith("android-addon-"):     # our own virtual keyboard
                continue
            caps = d.capabilities().get(e.EV_KEY, [])
            if e.BTN_START in caps or e.BTN_SOUTH in caps or e.BTN_GAMEPAD in caps or e.BTN_JOYSTICK in caps:
                out.append(d)
        except OSError:
            pass
    return out


ui = None
if KEYMODE:
    ui = evdev.UInput({e.EV_KEY: [e.KEY_UP, e.KEY_DOWN, e.KEY_LEFT, e.KEY_RIGHT, e.KEY_ENTER,
                                  e.KEY_ESC, e.KEY_SPACE, e.KEY_TAB, e.KEY_PAGEUP, e.KEY_PAGEDOWN]},
                      name="android-addon-pad-keys")
BTN2KEY = {e.BTN_SOUTH: e.KEY_ENTER, e.BTN_EAST: e.KEY_ESC, e.BTN_WEST: e.KEY_SPACE,
           e.BTN_NORTH: e.KEY_TAB, e.BTN_TL: e.KEY_PAGEUP, e.BTN_TR: e.KEY_PAGEDOWN,
           e.BTN_DPAD_UP: e.KEY_UP, e.BTN_DPAD_DOWN: e.KEY_DOWN,
           e.BTN_DPAD_LEFT: e.KEY_LEFT, e.BTN_DPAD_RIGHT: e.KEY_RIGHT}


def tap(key, val):
    ui.write(e.EV_KEY, key, val); ui.syn()


def quit_session():
    if TESTMODE:
        log("test: Select+Start held - leaving controller test"); finish(0)
    log("exit combo (HOTKEY+START) detected -> back to EmulationStation")
    os.makedirs("/run/android", exist_ok=True)
    open("/run/android/quit", "w").close()
    subprocess.call(["pkill", "-x", "foot"])
    if KEYMODE:
        sys.exit(0)


def finish(code):
    for d in devs.values():
        try: d.ungrab()
        except OSError: pass
    sys.exit(code)


def add_device(d, why):
    devs[d.fd] = d
    log(f"linux: {why} {describe(d)}")
    if TESTMODE:
        try: d.grab()          # test only: nothing else (Android, menus) gets these presses
        except OSError: pass
    elif ROLE == "watch" and why == "connected":
        # tell us whether Android picked the new controller up too
        subprocess.Popen([sys.executable, __file__, "--android-report"],
                         env=dict(os.environ, REPORT_DELAY="3"))


# ------------------------------------------------------------------ main loop
devs = {}
found = pads()
if ROLE != "keys":
    log(f"linux: {len(found)} controller(s) found" + ("" if found else
        " - none! Check the cable/Bluetooth pairing and that it works in EmulationStation"))
for d in found:
    if ROLE == "keys":
        devs[d.fd] = d
    else:
        add_device(d, "found")

if TESTMODE:
    print("\n=== CONTROLLER TEST ===  press buttons / move sticks.  "
          "Hold SELECT + START for 2 s (or type q + Enter) to leave.\n", flush=True)

held, combo_since, axis_state, fired = set(), None, {}, False
last_axis_log, last_scan = {}, time.time()

while True:
    watch = list(devs) + ([sys.stdin] if TESTMODE and sys.stdin.isatty() else [])
    r, _, _ = select.select(watch, [], [], 0.25)
    for fd in r:
        if fd is sys.stdin:
            if sys.stdin.readline().strip().lower().startswith("q"):
                log("test: closed with keyboard"); finish(0)
            continue
        dev = devs.get(fd)
        try:
            events = list(dev.read())
        except OSError:
            if ROLE != "keys":
                log(f"linux: disconnected '{dev.name}' {dev.path}")
            devs.pop(fd, None); continue
        for ev in events:
            if ev.type == e.EV_KEY:
                (held.add if ev.value else held.discard)(ev.code)
                if TESTMODE and ev.value in (0, 1):
                    log(f"  {dev.name[:28]:28}  {btn_name(ev.code):22} {'pressed' if ev.value else 'released'}")
                if ui and ev.code in BTN2KEY and ev.value in (0, 1):
                    tap(BTN2KEY[ev.code], ev.value)
            elif ev.type == e.EV_ABS:
                try:
                    info = dev.absinfo(ev.code)
                    mid = (info.max + info.min) / 2
                    span = (info.max - info.min) / 2 or 1
                    norm = (ev.value - mid) / span
                except Exception:
                    norm = float(ev.value)
                if TESTMODE:
                    key = (fd, ev.code)
                    now = time.time()
                    if abs(norm - last_axis_log.get(key, (9, 0))[0]) > 0.25 and now - last_axis_log.get(key, (0, 0))[1] > 0.1:
                        last_axis_log[key] = (norm, now)
                        bar = "#" * int(abs(norm) * 10)
                        log(f"  {dev.name[:28]:28}  {abs_name(ev.code):22} {norm:+.2f} {bar}")
                if ui and ev.code in (e.ABS_HAT0X, e.ABS_HAT0Y, e.ABS_X, e.ABS_Y):
                    v = 0 if abs(norm) < 0.5 else (1 if norm > 0 else -1)
                    horiz = ev.code in (e.ABS_HAT0X, e.ABS_X)
                    prev = axis_state.get(ev.code, 0)
                    if v != prev:
                        neg, pos = (e.KEY_LEFT, e.KEY_RIGHT) if horiz else (e.KEY_UP, e.KEY_DOWN)
                        if prev: tap(neg if prev < 0 else pos, 0)
                        if v:    tap(neg if v < 0 else pos, 1)
                        axis_state[ev.code] = v
    if e.BTN_START in held and held & HOTKEYS:
        combo_since = combo_since or time.time()
        if time.time() - combo_since >= HOLD and not fired:
            fired = True
            quit_session()
    else:
        combo_since, fired = None, False
    if time.time() - last_scan > 3:          # hot-plugged controllers
        last_scan = time.time()
        known = {d.path for d in devs.values()}
        for d in pads():
            if d.path in known:
                d.close()                    # already watching this one
            elif ROLE == "keys":
                devs[d.fd] = d
            else:
                add_device(d, "connected")
