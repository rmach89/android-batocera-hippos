# Android add-on for Batocera & HippOS (Waydroid · Android 13 + Google Play)

**Version: v1.0.2** (see `VERSION`). Versions go v1.x.x and every digit rolls over at 10:
v1.0.9 → v1.1.0, v1.9.9 → v2.0.0. Bump with `./bump-version.sh` (or `./bump-version.sh 3`).
Check the installed version with `/userdata/system/services/android version`.

Adds an **ANDROID** system to EmulationStation. Install games from the **Google Play Store** or
from **.apk files**, and each one appears in ES as its own game. Android runs in a
Waydroid LXC container on the host kernel, using the real GPU. It is not emulated, so it runs close to native speed.

## Install
Over SSH (as root), one line installs the newest release:
```bash
curl -fsSL https://raw.githubusercontent.com/rmach89/android-batocera-hippos/main/get.sh | bash
```
Or download the code (**Code → Download ZIP**, or a zip from [Releases](https://github.com/rmach89/android-batocera-hippos/releases)),
copy it to the machine, unzip, then run `bash install.sh` (~2 GB download, 10–30 min).

The updater uses the newest published GitHub release. If there isn't one, it uses the `VERSION` file on `main`.
The installer checks your hardware, installs Waydroid, downloads Android 13 with Google Play, adds ARM
translation, creates every symlink, then enables and starts the service. Nothing else to set up.

After an OS update, if the ANDROID system, the F1 entries or the service are gone, run `bash /userdata/system/add-ons/android/install.sh --repair`.

## What you get
**F1 → Applications menu**
| Entry | Does |
|---|---|
| Google Play Store (Android) | Opens Android with the Play Store |
| APK Manager (Android) | Controller-driven menu: install `.apk` files from `roms/android/apk`, reinstall stored Google Play apps, uninstall apps (labelled *[Google Play]* or *[APK]*), store Play apps now, Play Store device registration, **Always-on** on/off, **App mode**, rebuild 3D boxes |
| Uninstall Android | Asks first. Choose **Cancel**, **Uninstall but keep apps + saves**, or **Uninstall everything** |

**EmulationStation → ANDROID** lists only your installed games and apps, each one launching straight in.
Entries are added and removed automatically when you leave Android.

**Google Play installs are stored automatically.** Every time you leave Android, each app installed by
Google Play is copied (base + split APKs) to `/userdata/roms/android/apk/google-play/<package>/`. APK Manager
can reinstall them without the Play Store, even after a full uninstall/reinstall. Uninstalling never deletes this folder.

**Exit Android:** hold **SELECT/Hotkey + START** for 1 second.

## Always-on (off by default)
| | Off (default) | On |
|---|---|---|
| Launching a game | Android boots first (10–20 s) | Opens in ~1 s |
| Leaving a game | Android shuts down | Game pauses (Home), Android hides behind ES |
| RAM when idle | ~0 | ~2 GB |
| Play Store background updates | No | Yes |

Turn it on or off in **APK Manager → Always-on**, or over SSH with
`/userdata/system/services/android always-on on|off`.
Always-on needs a plain X11 screen (Batocera's normal PC setup). On a Wayland or bare-KMS screen it
automatically stays on-demand.

## Updates
**APK Manager → Updates** shows your installed version and the newest one on GitHub, and offers:
- **Update the add-on**: installs the newest release. Apps, saves, settings and boxes are kept.
- **Update Android**: updates Waydroid and its helper packages, then downloads the newest Android (LineageOS) system
  image with `waydroid upgrade`. ARM translation and Play Store registration are kept.
- **Update both**

Updates install in the background as soon as you leave APK Manager. Progress goes to `android.log`.
Google Play keeps your games themselves up to date.

From SSH:
```bash
/userdata/system/add-ons/android/bin/android-update check     # installed vs newest
/userdata/system/add-ons/android/bin/android-update addon     # newest add-on
/userdata/system/add-ons/android/bin/android-update android   # Waydroid + Android image
/userdata/system/add-ons/android/bin/android-update all
```
Running the one-line `get.sh` install again also updates the add-on.

## App mode: Native windows or Full Android
| | Native windows (default, multi-window mode) | Full Android |
|---|---|---|
| Look | Each game or app (the Play Store too) is its own full-screen window with no Android UI, like a PC app | Android home screen, status bar and Back/Home/Recents bar, like a tablet |
| Back | Controller B, Esc | On-screen Back button, controller B, Esc |
| Compatibility | A few games handle resizing badly. Use Full Android for those | Best |

Switch it in **APK Manager → App mode**, or with `/userdata/system/services/android app-mode full|native`.
The new mode applies the next time Android starts. Android restarts once to apply it.

## 3D boxes + game info (LaunchBox Games Database)
Every game in ANDROID gets a CD-jewel-case 3D box:
- the black **android** band across the top;
- the Android bot and the game title on the spine;
- the LaunchBox *Box - Front* cover on the front.

The box takes the shape of the cover, so the whole image always fits.
The description, developer, publisher, release date, genre and rating are filled in too.

* The LaunchBox database (`Metadata.zip`, published daily) is downloaded once and reduced to the Android games.
  It's refreshed every 30 days.
* **Support badge, bottom-right of the cover:** a controller badge if the game can be played with a gamepad,
  a touch badge if it's touch/mouse only. It's read from each game's own Android manifest when you leave Android
  (gamepad feature, Android TV support, or no touchscreen required → controller).
  Wrong badge? Put `package.name=controller` (or `touch` / `none`) in
  `/userdata/system/add-ons/android/settings/controller-overrides.conf`. The box is redrawn the next time you leave Android.
* Games are matched by name, including LaunchBox alternate names. When there is no match, the box uses the app's own icon.
* Wrong match? Put `package.name=LaunchBoxDatabaseID` in
  `/userdata/system/add-ons/android/settings/launchbox-overrides.conf`, then run **APK Manager → Rebuild 3D boxes**.
* Files: `roms/android/images/<Game>-box3d.png` (used as image, thumbnail and boxart) and `<Game>-front.png`.
* Rebuild everything over SSH: `bash /userdata/system/add-ons/android/install.sh --rescrape`.

## Layout (service script + symlinks)
```
/userdata/system/add-ons/android/          ← everything real lives here (survives OS updates)
├── bin/android-service                    ← start|stop|restart|status
├── bin/android-launch                     ← ES <command>
├── bin/android-sync-games                 ← installed apps → .android ES entries
├── bin/android-common.sh
├── bin/android-uninstall-menu             ← F1 "Uninstall Android"
├── bin/android-keeper                     ← Always-on background Android
├── bin/android-update                     ← add-on + Android updates (GitHub releases)
├── chroot/  (session.sh, apk-manager.sh, store-play-apps.sh, padwatch.py (controllers + log), window.sh,
│            scrape-launchbox.py, make_box3d.py, detect-input.sh, box3d/, setup-waydroid.sh)  ← bind-mounted at /opt/android
├── settings/android.conf                   ← ALWAYS_ON=0|1  (+ launchbox-overrides.conf)
├── config/es_systems_android.cfg
├── config/applications/*.desktop           ← F1 menu entries
├── config/icons/*.png
├── systemd/android-waydroid.service
└── rootfs/                                 ← Debian Trixie + Waydroid + Android image & app data

Symlinks:
/userdata/system/services/android                         → add-ons/android/bin/android-service
/userdata/system/configs/emulationstation/es_systems_android.cfg → add-ons/android/config/…
/userdata/system/.local/share/applications/android-*.desktop → add-ons/android/config/applications/…
/usr/share/applications/android-*.desktop                 → same (re-created by the service each boot)
/etc/systemd/system/android-waydroid.service (HippOS)     → add-ons/android/systemd/…   (systemctl link)
```
* **Batocera:** toggle it in *Main Menu → System Settings → Services → android*, or run `batocera-services enable|disable android`.
* **HippOS:** run `systemctl start|stop|status android-waydroid`.
* Launching a game starts the service automatically if it isn't already running.

## Play Store "device is not Play Protect certified"
APK Manager → *Google Play: register this device*. It shows your ID. Enter it at
https://www.google.com/android/uncertified, wait 10–20 minutes, then relaunch.

## Troubleshooting controllers
Log: `/userdata/system/logs/android-controllers.log` (rotates at 1 MB). Each Android session records:
- `linux:` every controller Linux finds, with name, USB/Bluetooth, vid:pid, button and axis counts,
  and whether it has SELECT, START or GUIDE. Plugging in and unplugging during play are logged too.
- `android:` which game controllers **Android itself** sees, checked a few seconds after boot and
  after every new controller.
- `exit combo ... detected`: each time HOTKEY + START sent you back to EmulationStation.

**APK Manager → Controllers**
- *Controller test*: shows and logs every button and stick live. The test takes the controller for
  itself, so nothing reaches Android or the menu. Hold SELECT + START for 2 s to leave.
- *Check which controllers Android sees*: Linux vs Android side by side.
- *Show controller log*: the latest 300 lines.

| What the log shows | Meaning |
|---|---|
| `linux: 0 controller(s) found` | Linux can't see it: cable, Bluetooth pairing or driver problem |
| listed under `linux:`, `android: NONE` | Pass-through problem: run `install.sh --repair`, then restart Android |
| listed under both, but no response in the game | The game is touch-only (use a mouse) or has its own controller setting |
| `has=none`, or no START/SELECT | The exit combo can't work with that controller. Use another controller or the keyboard |

## Requirements / limits
* x86_64, Intel or AMD GPU. NVIDIA falls back to software rendering, which is slow.
* The kernel must have binder support (`binder_linux` or binderfs). The installer checks this first.
* ARM-only games use ARM translation: libndk on AMD CPUs, libhoudini on Intel CPUs. Most games work.
  Some games with anti-cheat or SafetyNet checks will not run.
* Controllers are passed straight through to Android.

## Uninstall
`bash /userdata/system/add-ons/android/uninstall.sh` (add `--keep-data` to keep apps + saves).
Logs: `/userdata/system/logs/android.log`
