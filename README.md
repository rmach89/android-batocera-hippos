# Android add-on for Batocera & HippOS (Waydroid · Android 13 + Google Play)

**Version: v1.1.3** (see `VERSION`). Versions go v1.x.x and every digit rolls over at 10:
v1.0.9 → v1.1.0, v1.9.9 → v2.0.0. Bump with `./bump-version.sh` (or `./bump-version.sh 3`).
Check the installed version with `/userdata/system/services/android version`.

Adds an **ANDROID** system to EmulationStation. Install games from the **Google Play Store** or
from **.apk files**, and each one appears in ES as its own game. Android runs in a
Waydroid LXC container on the host kernel, using the real GPU. It is not emulated, so it runs close to native speed.

## Install / update
Over SSH (as root on Batocera; HippOS asks for `sudo` by itself), this one line is all you need:
```bash
curl -fsSL https://raw.githubusercontent.com/rmach89/android-batocera-hippos/main/install.sh | bash
```
`install.sh` is self-contained. It always downloads the **newest version and every file it needs** from GitHub
(a published release or `main`, whichever is newer), then **detects the system by itself** and sets up the matching way.
Nothing to answer or choose:

| Detected | How Android runs | Menu entries | Games |
|---|---|---|---|
| **Batocera** (and others) | Waydroid in the add-on's own Debian chroot | F1 → Applications | new **ANDROID** system |
| **HippOS** | HippOS's **own built-in Waydroid**: one Android, one set of apps | **Desktop Shortcuts** system | HippOS's **Android Games** / **Android Apps** systems, taken over (see [HippOS](#hippos)) |

Then:
- **New install:** checks your hardware, installs Waydroid, downloads Android 13 with Google Play, adds ARM
  translation, creates every symlink, then enables and starts the service. It's about a 2 GB download and takes 10–30 min.
- **Already installed:** updates the add-on in place, stopping Android while files are replaced. Your apps, saves,
  settings and boxes are kept.

It works the same whether you pipe it as above, download `install.sh` on its own, or run it from an older copy.
It needs only `bash`, `tar` and `curl` or `wget`.

| Option | Does |
|---|---|
| `install.sh --repair` | re-create symlinks, the service and packages (e.g. after an OS update) |
| `install.sh --rescrape` | rebuild every 3D box and the game info |
| `install.sh --local` | use the files next to the script; don't check GitHub (offline) |

Prefer a download? Get the zip (**Code → Download ZIP** or from [Releases](https://github.com/rmach89/android-batocera-hippos/releases)),
unzip it on the machine and run `bash install.sh`. It still updates itself if GitHub has something newer.

## HippOS
HippOS already ships Waydroid (Android + Google Play) and has no F1 Applications menu, so on HippOS the installer:
- **uses HippOS's Waydroid**, so there's no second copy of Android. Apps you install anywhere show up everywhere,
  and HippOS's own Android data in `/userdata/system/waydroid` stays where it is. If Android was never started
  on that HippOS, the installer starts HippOS's own download and waits for it (internet needed).
- installs the add-on's tools with apt (`cage`, `foot`, `dialog`, `aapt`, `xdotool`, …). HippOS puts user apt
  packages back automatically after an OS update, and the service re-installs them if any are still missing.
- puts **Google Play Store, APK Manager, F-Droid, Aurora Store, Aptoide** and **Uninstall Android** in the
  **Desktop Shortcuts** system, with their icons (via `/userdata/Desktop`). HippOS's own Waydroid entry stays in
  Android Apps, so there's no duplicate.
- takes over **Android Games** (`roms/androidgames`) and **Android Apps**, keeping HippOS's names, theme and logos:
  every installed game is listed automatically, `.apk` files you drop in there install on first launch, all of them
  get 3D boxes and game info, and every launch goes through the add-on (Select+Start exit, Always-on, App mode,
  controller handling, backups). A game you dropped as an `.apk` doesn't get a second entry.
- uses `roms/android-apk/` for APK Manager's install folder and store backups (`android-apk/<store>/`). It sits
  outside Android Games on purpose, otherwise every backup would show up as a game. Saves go to `roms/androidgames/saves/`.
- works on Raspberry Pi 4/5 HippOS too (ARM games run natively there, no translation needed).

**Uninstall** on HippOS removes only the add-on. Android, your apps and saves are part of HippOS and are always kept;
Android Games / Android Apps go back to HippOS's standard setup.

## What you get
**F1 → Applications menu** (seven entries; on HippOS these are in Desktop Shortcuts, see [HippOS](#hippos))
| Entry | Does |
|---|---|
| Google Play Store (Android) | Opens Android with the Play Store |
| APK Manager (Android) | Controller-driven menu: install `.apk` `.xapk` `.apks` `.apkm` files from `roms/android/apk` (HippOS: `roms/android-apk`), reinstall stored store apps, uninstall apps (each labelled with where it came from: *[Google Play]* *[F-Droid]* *[Aurora]* *[Aptoide]* *[APK]*), back up store apps now, **game saves + OBB backup/restore**, Play Store device registration, **Always-on** on/off, **App mode**, rebuild 3D boxes, **controller test + log**, **updates** (add-on, Android, app stores) |
| F-Droid (Android) | The free and open-source Android app store. It downloads and installs itself the first time you open it and keeps itself on the newest official build, and games you install from it appear in the ANDROID system (HippOS: Android Games) like any other |
| Aurora Store (Android) | The Google Play catalog without a Google account. It installs itself on first open, using the newest build from the official F-Droid repository |
| Aptoide (Android) | A community Android app store. It installs itself on first open, from Aptoide's official store, and the download is checked against Aptoide's published MD5 checksum |
| Waydroid (Android) | Opens Android's home screen and app drawer: Android Settings, files, any app. Handy when you need to get into Android itself. *(HippOS: its own Waydroid entry in Android Apps does this)* |
| Uninstall Android | Asks first. Choose **Cancel**, **Uninstall but keep apps + saves**, or **Uninstall everything** *(HippOS: Cancel or Remove the add-on; Android, apps and saves always stay)* |

**EmulationStation → ANDROID** lists every app *you* installed (Android's own third-party app list, so nothing
is hidden because of its package name, e.g. Google-made games show up too), each one launching straight in.
The app stores themselves stay in F1. Entries are added and removed automatically when you leave Android.

**Store installs are backed up automatically.** Every time you leave Android, each app installed from a store
is copied (base + split APKs) to `/userdata/roms/android/apk/<store>/<package>/`:

| Installed from | Backup folder |
|---|---|
| Google Play | `apk/google-play/` |
| F-Droid | `apk/f-droid/` |
| Aurora Store | `apk/aurora/` |
| Aptoide | `apk/aptoide/` |

APK Manager can reinstall them without the store, even after a full uninstall/reinstall. Uninstalling never deletes these folders.

## Game saves + game data (off by default)
**APK Manager → Game saves + game data**:
- **Back up / restore an app's saves.** The app's private data (progress, settings, offline saves) plus its
  `Android/data` folder when that's under 500 MB, to `roms/android/saves/<package>/<date-time>.tar.gz`.
  The newest 5 per app are kept. Restore works after a reinstall too (install the app first, then restore).
- **Auto-backup saves when leaving Android** (`BACKUP_SAVES=1`): only apps whose data changed, in the background.
- **Back up OBB game data with store apps** (`BACKUP_OBB=1`): big games that download extra data after install
  (`Android/obb/<package>`, often 1–4 GB) get it copied next to their stored APKs. Reinstalling from APK Manager
  then puts it back, so the game works fully without the store. Only changed data is copied, in the background.

Games signed in to Google Play Games usually sync their saves online as well.

**Exit Android:** hold **SELECT/Hotkey + START** for 1 second.

## System logo in every theme
The Android system logo (`config/theme/android-logo-light|dark.svg|png`, real vector SVGs) is added to **every
installed EmulationStation theme**, including Batocera's built-in themes, themes you added under `/userdata/themes`,
and HippOS's own themes. For each theme the add-on works out where that theme keeps its system logos and how it names
them (`logos/snes.svg`, `logo-snes.png`, `snes/art/logo.svg` ...). It then links the logo in with the matching name
and format and the matching colour: white text if the theme's logos are light, dark text if they're dark.
- Themes that already have their own Android logo are left alone.
- Logos are symlinks to the add-on's files. Themes in `/usr` (reset by Batocera at every boot) are re-linked each
  time the service starts. A new theme is picked up automatically.
- `bin/android-theme-logos --rescan` re-checks all themes now; `--remove` takes the logo out again (uninstall does this).

## Achievements
RetroAchievements doesn't support Android. It only has achievement sets for retro consoles, played through
emulators built with its `rcheevos` library, and Android games run natively here. Android games still have
their own achievements: sign in to **Google Play Games** (included with the Google Play image) and games that
use Play Games achievements track and show them as on a phone.

## Supported package files
Drop them in `/userdata/roms/android/apk` (network share: `roms/android/apk`), then **APK Manager → Install apps**.

| File | From | Notes |
|---|---|---|
| `.apk` | anywhere | single APK |
| `.xapk` | APKPure | base + split APKs. **Game data (OBB) is copied automatically** to `Android/obb/<package>/` |
| `.apks` | SAI, bundletool | split-APK set |
| `.apkm` | APKMirror | only unencrypted ones. If the file is encrypted, unlock it with APKMirror Installer first |

Split sets are installed whole first. If Android refuses them, the installer retries with just the base, the feature and
language splits, one CPU split (x86_64 preferred, then arm64) and one screen-density split.
Files that installed are moved to `apk/installed/`.

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
**APK Manager → Updates** shows your installed version and the newest one on GitHub (a published release or the
`main` branch, whichever is newer, so an old release never hides newer fixes), and offers:
- **Update the add-on**: installs the newest release. Apps, saves, settings and boxes are kept.
- **Update Android**: updates Waydroid and its helper packages, then downloads the newest Android (LineageOS) system
  image with `waydroid upgrade`. ARM translation and Play Store registration are kept.
- **Update the app stores**: F-Droid, Aurora Store and Aptoide are compared with their newest official build
  and updated right away (the menu shows which ones have an update).
- **Update everything**

Add-on and Android updates install in the background as soon as you leave APK Manager. Progress goes to `android.log`.
The app stores also check for a newer build of themselves (at most once a day) whenever you open them from F1.
When you're offline that check gives up after a few seconds and isn't retried for an hour,
and the stores keep your games up to date.

From SSH:
```bash
/userdata/system/add-ons/android/bin/android-update check     # installed vs newest
/userdata/system/add-ons/android/bin/android-update addon     # newest add-on
/userdata/system/add-ons/android/bin/android-update android   # Waydroid + Android image
/userdata/system/add-ons/android/bin/android-update all
```
Running the one-line `install.sh` again also updates the add-on.

## App mode: Native windows or Full Android
| | Native windows (default, multi-window mode) | Full Android |
|---|---|---|
| Look | Each game or app (the Play Store too) is its own full-screen window with no Android UI, like a PC app | Android home screen, status bar and Back/Home/Recents bar, like a tablet |
| Back | Controller B, Esc | On-screen Back button, controller B, Esc |
| Compatibility | A few games handle resizing badly. Use Full Android for those | Best |

Switch it in **APK Manager → App mode**, or with `/userdata/system/services/android app-mode full|native`.
The new mode applies the next time Android starts. Android restarts once to apply it.

## 3D boxes + game info (LaunchBox, ScreenScraper, Google Play, F-Droid)
Every game in ANDROID gets a CD-jewel-case 3D box:
- the black **android** band across the top;
- the Android bot and the game title on the spine;
- the best cover found on the front.

The box takes the shape of the cover, so the whole image always fits.
The description, developer, publisher, release date, genre and rating are filled in too, plus background art
(`fanart`) and a wheel logo (`marquee`) when a source has them.

**Sources.** Each field comes from the first source that has it:

| # | Source | Gives |
|---|---|---|
| 1 | LaunchBox Games Database | real box covers + full game info |
| 2 | ScreenScraper | box art, wheel logo, screenshot, game info (needs a developer ID, see below) |
| 3 | Google Play listing | hi-res icon, feature graphic, description, developer, genre, rating |
| 4 | F-Droid | icon, screenshot, description for open-source games (tried before Google Play for apps installed from F-Droid) |

A real box cover (LaunchBox, ScreenScraper) always wins over a store icon. With no match anywhere the box uses
the app's own icon. Lookups are cached for 30 days. Change the order or turn sources off in
`/userdata/system/add-ons/android/settings/android.conf`:
```
SCRAPE_SOURCES=launchbox screenscraper googleplay fdroid
```
**ScreenScraper** only answers apps that have a developer ID (free, requested on the ScreenScraper forum).
Add it to `android.conf`:
```
SCREENSCRAPER_DEVID=yourdevid
SCREENSCRAPER_DEVPASSWORD=yourdevpassword
```
Your normal ScreenScraper login is read from Batocera's scraper settings automatically (or set
`SCREENSCRAPER_USER=` / `SCREENSCRAPER_PASSWORD=`). Without a developer ID ScreenScraper is simply skipped.

* The LaunchBox database (`Metadata.zip`, published daily) is downloaded once and reduced to the Android games.
  It's refreshed every 30 days.
* **Support badge, bottom-right of the cover:** a controller badge if the game can be played with a gamepad,
  a touch badge if it's touch/mouse only. It's read from each game's own Android manifest when you leave Android
  (gamepad feature, Android TV support, or no touchscreen required → controller).
  Wrong badge? Put `package.name=controller` (or `touch` / `none`) in
  `/userdata/system/add-ons/android/settings/controller-overrides.conf`. The box is redrawn the next time you leave Android.
* LaunchBox and ScreenScraper match by name (LaunchBox alternate names too); Google Play and F-Droid by the exact package name.
* Wrong match? Put `package.name=LaunchBoxDatabaseID` in
  `/userdata/system/add-ons/android/settings/launchbox-overrides.conf`, then run **APK Manager → Rebuild 3D boxes**.
* Files (HippOS: `roms/androidgames/images/`): `roms/android/images/<Game>-box3d.png` (used as image, thumbnail and boxart), `<Game>-front.png`,
  `<Game>-fanart.jpg`, `<Game>-marquee.png`.
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
├── bin/android-theme-logos                ← Android logo into every installed theme
├── bin/android-in-session                 ← HippOS: back to root inside the desktop user's window
├── hostbin/waydroid                       ← HippOS: session commands as the desktop user, the rest as root
├── chroot/  (session.sh, apk-manager.sh, padwatch.py (controllers + log), window.sh, setup-waydroid.sh,
│            scrape-launchbox.py, metadata_sources.py, make_box3d.py, detect-input.sh, installed-apps.sh,
│            store-installed-apps.sh, app-data.sh, update-stores.sh, store-apk-url.py, install-package.sh, box3d/)
│                                           ← /opt/android (bind mount; HippOS: symlink)
├── settings/android.conf                   ← ALWAYS_ON  MULTI_WINDOW  BACKUP_SAVES  BACKUP_OBB  SCRAPE_SOURCES
│                                              SCREENSCRAPER_*  (+ launchbox-overrides.conf, controller-overrides.conf)
├── config/es_systems_android.cfg           ← Batocera: the ANDROID system
├── config/es_systems_android-hippos.cfg    ← HippOS: takes over Android Games / Android Apps
├── config/applications/*.desktop           ← F1 menu entries (HippOS: Desktop Shortcuts)
├── config/icons/*.png
├── systemd/android-waydroid.service
├── waydroid_script/                        ← HippOS: ARM translation + Play certification helper
└── rootfs/                                 ← Batocera: Debian Trixie + Waydroid + Android image & app data
                                               (HippOS: none - Android lives in /userdata/system/waydroid)

Symlinks:
/userdata/system/services/android                         → add-ons/android/bin/android-service
/userdata/system/configs/emulationstation/es_systems_android.cfg → add-ons/android/config/…
/userdata/system/.local/share/applications/android-*.desktop → add-ons/android/config/applications/…
/usr/share/applications/android-*.desktop                 → same (re-created by the service each boot)
/etc/systemd/system/android-waydroid.service (HippOS)     → add-ons/android/systemd/…   (systemctl link)

HippOS only (re-checked at every service start):
/userdata/Desktop/android-*.desktop                       → add-ons/android/config/applications/…
/opt/android → add-ons/android/chroot     /mnt/android-roms → /userdata/roms/androidgames
/etc/android-addon → add-ons/android/settings     /var/log/android-addon → /userdata/system/logs
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
* x86_64, Intel or AMD GPU (HippOS: also Raspberry Pi 4/5). NVIDIA falls back to software rendering, which is slow.
* The kernel must have binder support (`binder_linux` or binderfs). The installer checks this first.
* ARM-only games use ARM translation: libndk on AMD CPUs, libhoudini on Intel CPUs. Most games work.
  Some games with anti-cheat or SafetyNet checks will not run.
* Controllers are passed straight through to Android.

## Uninstall
`bash /userdata/system/add-ons/android/uninstall.sh` (add `--keep-data` to keep apps + saves).
On HippOS it only removes the add-on; Android, apps and saves stay (they're part of HippOS).
Logs: `/userdata/system/logs/android.log`

## Testing status
Everything was developed and tested with simulated systems (stand-in Waydroid, stores and metadata services),
not yet on real hardware. Worth confirming on a real machine first:
* **Both:** binder support in the kernel, GPU rendering, controller pass-through, ARM translation.
* **HippOS:** the Android window over HippOS's desktop (and Always-on hiding it), that Android Games / Android Apps
  launch through the add-on, and that HippOS's own hotkeys don't clash with the Select+Start exit.

Please open an issue with `/userdata/system/logs/android.log` if something doesn't work.
