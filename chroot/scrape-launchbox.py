#!/usr/bin/env python3
"""Scrape metadata for every game in the ANDROID system and write 3D jewel-case boxes,
background art and game info to gamelist.xml.

Sources, first one that has something wins (per field):
  1. LaunchBox Games Database (platform: Android)   - real box covers
  2. ScreenScraper                                   - box art, wheel logo (needs a developer ID)
  3. Google Play store listing                        - hi-res icon, feature graphic, text, rating
  4. F-Droid                                          - open-source apps (tried before Google Play
                                                        for apps that came from F-Droid)
Change the order or turn sources off with SCRAPE_SOURCES in android.conf.

Runs INSIDE the chroot.  Paths as seen there:
  /mnt/android-roms/*.android            ES entries (line 2 = package name)
  /mnt/android-roms/gamelist.xml         ES metadata
  /mnt/android-roms/images/              boxes and covers
  /etc/android-addon/launchbox-overrides.conf   optional "package=LaunchBoxDatabaseID" lines

LaunchBox publishes its whole database as one daily Metadata.zip; we download it, keep only
the Android games in a small JSON index, then delete the zip.  Refreshed every 30 days.

  scrape-launchbox.py            new games only
  scrape-launchbox.py --force    redo every box
  scrape-launchbox.py --refresh  re-download the LaunchBox database first
"""
import os, re, sys, json, time, fcntl, glob, difflib, zipfile, unicodedata, urllib.parse, urllib.request, html
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_box3d import render, BOX_STYLE_VERSION   # noqa: E402
import metadata_sources as ms   # noqa: E402
from PIL import Image, ImageDraw, ImageFont

ROMS = "/mnt/android-roms"
IMG_DIR = os.path.join(ROMS, "images")
GAMELIST = os.path.join(ROMS, "gamelist.xml")
CACHE = "/root/.cache/android-addon"
INDEX = os.path.join(CACHE, "launchbox-android.json")
MATCHES = os.path.join(CACHE, "launchbox-matches.json")
OVERRIDES = "/etc/android-addon/launchbox-overrides.conf"
INPUT_SUPPORT = os.path.join(ROMS, ".cache", "input-support.txt")        # from detect-input.sh
INPUT_OVERRIDES = "/etc/android-addon/controller-overrides.conf"
BADGES = os.path.join(CACHE, "badges.json")                               # badge last drawn per box
META_URL = "https://gamesdb.launchbox-app.com/Metadata.zip"
IMG_URL = "https://images.launchbox-app.com/{}"
WAYDROID_ICONS = os.path.join(os.environ.get("ANDROID_DATA_DIR", "/root/.local/share/waydroid/data"), "icons")
APP_SOURCES = os.path.join(ROMS, ".cache", "app-sources.txt")          # from installed-apps.sh
APK_PACKAGES = os.path.join(ROMS, ".cache", "apk-packages.tsv")         # HippOS .apk games -> package
SETTINGS = "/etc/android-addon/android.conf"
DEFAULT_SOURCES = "launchbox screenscraper googleplay fdroid"
MARK = "# managed-by-android-addon"
UA = {"User-Agent": "batocera-android-addon/1.0"}
IMAGE_PRIORITY = ["Box - Front", "Box - Front - Reconstructed", "Fanart - Box - Front",
                  "Steam Banner", "Screenshot - Game Title", "Screenshot - Gameplay"]
REGION_PRIORITY = ["", "North America", "United States", "World", "Europe"]
os.makedirs(CACHE, exist_ok=True); os.makedirs(IMG_DIR, exist_ok=True)


def log(*a):
    print("[launchbox]", *a, flush=True)


def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[™®©]", "", s)
    s = re.sub(r"\(.*?\)|\[.*?\]", " ", s)
    s = s.replace("&", " and ")
    s = re.sub(r"[^a-z0-9]+", " ", s)
    s = re.sub(r"\b(the|a|an|hd|free|lite|mobile|pocket edition)\b", " ", s)
    return " ".join(s.split())


# ---------------------------------------------------------------- LaunchBox index
def download(url, dest):
    tmp = dest + ".part"
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r, open(tmp, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
    os.replace(tmp, dest)


def iter_elements(zpath, tags):
    with zipfile.ZipFile(zpath) as z:
        name = next(n for n in z.namelist() if n.lower().endswith("metadata.xml"))
        with z.open(name) as f:
            root, depth = None, 0
            for ev, el in ET.iterparse(f, events=("start", "end")):
                if ev == "start":
                    depth += 1
                    if root is None:
                        root = el
                    continue
                depth -= 1
                if depth == 1:                      # a direct child of <LaunchBox>
                    if el.tag in tags:
                        yield el.tag, {c.tag: (c.text or "") for c in el}
                    root.clear()                    # keep memory flat on the ~1 GB XML


def build_index(force=False):
    if not force and os.path.exists(INDEX) and time.time() - os.path.getmtime(INDEX) < 30 * 86400:
        return json.load(open(INDEX))
    zpath = os.path.join(CACHE, "Metadata.zip")
    log("downloading LaunchBox database (one time, refreshed monthly)...")
    download(META_URL, zpath)
    games = {}
    for _, g in iter_elements(zpath, {"Game"}):
        if g.get("Platform", "").strip().lower() == "android":
            games[g["DatabaseID"]] = {
                "name": g.get("Name", ""), "overview": g.get("Overview", ""),
                "date": (g.get("ReleaseDate") or "")[:10], "dev": g.get("Developer", ""),
                "pub": g.get("Publisher", ""), "genre": g.get("Genres", ""),
                "rating": g.get("CommunityRating", ""), "alt": [], "img": []}
    for tag, e in iter_elements(zpath, {"GameAlternateName", "GameImage"}):
        g = games.get(e.get("DatabaseID"))
        if not g:
            continue
        if tag == "GameAlternateName" and e.get("AlternateName"):
            g["alt"].append(e["AlternateName"])
        elif tag == "GameImage" and e.get("Type") in IMAGE_PRIORITY:
            g["img"].append([e.get("Type"), e.get("Region") or "", e.get("FileName")])
    json.dump(games, open(INDEX, "w"))
    os.remove(zpath)
    log(f"indexed {len(games)} Android games")
    return games


def best_image(g):
    def key(i):
        t, r, _ = i
        return (IMAGE_PRIORITY.index(t), REGION_PRIORITY.index(r) if r in REGION_PRIORITY else 99)
    imgs = sorted(g["img"], key=key)
    return imgs[0][2] if imgs else None


class Matcher:
    def __init__(self, games):
        self.games = games
        self.by_name = {}
        for gid, g in games.items():
            for n in [g["name"]] + g["alt"]:
                self.by_name.setdefault(norm(n), gid)
        self.names = list(self.by_name)

    def find(self, title):
        n = norm(title)
        if not n:
            return None
        if n in self.by_name:
            return self.by_name[n]
        # "Game: Subtitle" / "Game - Subtitle" -> try the main title too
        main = norm(re.split(r"[:\-–|]", title)[0])
        if main and main in self.by_name and len(main) > 3:
            return self.by_name[main]
        close = difflib.get_close_matches(n, self.names, n=1, cutoff=0.88)
        return self.by_name[close[0]] if close else None


# ---------------------------------------------------------------- art sources
def fetch_url(url, dest):
    try:
        download(url, dest)
        Image.open(dest).verify()
        return True
    except Exception as e:
        log("image download failed:", url.split("?")[0], e)
        if os.path.exists(dest):
            os.remove(dest)
        return False


def fetch_cover(fname, dest):
    return fetch_url(IMG_URL.format(urllib.request.quote(fname)), dest)


def cached_image(url, key):
    """download an image once into the cache, return its path (or None)"""
    if not url:
        return None
    ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower()
    raw = os.path.join(CACHE, "img-" + re.sub(r"[^A-Za-z0-9._-]", "_", key) + (ext if ext in (".png", ".jpg", ".jpeg", ".webp") else ".img"))
    return raw if os.path.exists(raw) or fetch_url(url, raw) else None


def save_as(src, dest, mode="RGB"):
    im = Image.open(src)
    im = im.convert("RGBA" if mode == "RGBA" else "RGB")
    im.save(dest)
    return dest


def waydroid_icon(pkg):
    p = os.path.join(WAYDROID_ICONS, pkg + ".png")
    return p if os.path.exists(p) else None


def title_card(title, dest):
    im = Image.new("RGB", (900, 900), (32, 33, 36))
    d = ImageDraw.Draw(im)
    try:
        f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 80)
    except OSError:
        f = ImageFont.load_default()
    words, lines, cur = title.split(), [], ""
    for w in words:
        if f.getlength((cur + " " + w).strip()) > 760:
            lines.append(cur); cur = w
        else:
            cur = (cur + " " + w).strip()
    lines.append(cur)
    y = 450 - len(lines) * 50
    for l in lines:
        d.text((450, y), l, font=f, fill=(240, 240, 240), anchor="mt"); y += 100
    im.save(dest)
    return dest


# ---------------------------------------------------------------- gamelist.xml
def load_gamelist():
    if os.path.exists(GAMELIST):
        try:
            return ET.parse(GAMELIST)
        except ET.ParseError:
            os.replace(GAMELIST, GAMELIST + ".broken")
    return ET.ElementTree(ET.Element("gameList"))


def set_field(game, tag, value):
    if value in (None, ""):
        return
    el = game.find(tag)
    if el is None:
        el = ET.SubElement(game, tag)
    el.text = str(value)


def es_date(d):
    return d.replace("-", "") + "T000000" if re.match(r"\d{4}-\d{2}-\d{2}", d or "") else ""


# ---------------------------------------------------------------- main
def main():
    force, refresh = "--force" in sys.argv, "--refresh" in sys.argv
    lock = open(os.path.join(CACHE, "scrape.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another scrape is running"); return

    entries = []
    for f in sorted(glob.glob(os.path.join(ROMS, "*.android"))):
        lines = [l.strip() for l in open(f, errors="ignore") if l.strip()]
        if not lines or lines[0] != MARK:
            continue
        pkg = next((l for l in lines[1:] if not l.startswith("#")), "")
        entries.append((os.path.basename(f), os.path.splitext(os.path.basename(f))[0], pkg))
    # HippOS: .apk files in Android Games are games too (package names cached by the launcher)
    if os.environ.get("ANDROID_HOST_MODE") == "1" and os.path.exists(APK_PACKAGES):
        pk = {}
        for l in open(APK_PACKAGES, errors="ignore"):
            parts = l.rstrip("\n").split("\t")
            if len(parts) == 3:
                pk[os.path.realpath(parts[0])] = parts[2]
        for f in sorted(glob.glob(os.path.join(ROMS, "*.apk")) + glob.glob(os.path.join(ROMS, "*.APK"))):
            pkg = pk.get(os.path.realpath(f))
            if pkg:
                entries.append((os.path.basename(f), os.path.splitext(os.path.basename(f))[0], pkg))

    def read_conf(path):
        out = {}
        if os.path.exists(path):
            for l in open(path):
                if "=" in l and not l.strip().startswith("#"):
                    k, v = l.split("=", 1); out[k.strip()] = v.strip()
        return out
    overrides = read_conf(OVERRIDES)
    conf = read_conf(SETTINGS)
    order = (conf.get("SCRAPE_SOURCES") or DEFAULT_SOURCES).replace(",", " ").lower().split()
    ss = ms.ScreenScraper(conf.get("SCREENSCRAPER_DEVID", ""), conf.get("SCREENSCRAPER_DEVPASSWORD", ""),
                          conf.get("SCREENSCRAPER_USER") or os.environ.get("SS_USER", ""),
                          conf.get("SCREENSCRAPER_PASSWORD") or os.environ.get("SS_PASS", ""))
    if "screenscraper" in order and not ss.ok:
        log("ScreenScraper skipped: no developer ID (SCREENSCRAPER_DEVID in android.conf)")
    installed_from = {}
    if os.path.exists(APP_SOURCES):
        for l in open(APP_SOURCES):
            parts = l.rstrip("\n").split("\t")
            if len(parts) >= 2:
                installed_from[parts[0]] = parts[1]

    # controller / touch badge per package (override > manifest detection > none)
    support = {}
    if os.path.exists(INPUT_SUPPORT):
        for l in open(INPUT_SUPPORT):
            parts = l.strip().split("|")
            if len(parts) == 3:
                support[parts[0]] = parts[2]
    support.update(read_conf(INPUT_OVERRIDES))
    badge_of = lambda pkg: support.get(pkg) if support.get(pkg) in ("controller", "touch") else None
    drawn = json.load(open(BADGES)) if os.path.exists(BADGES) else {}

    tree = load_gamelist(); root = tree.getroot()
    by_path = {g.findtext("path"): g for g in root.findall("game")}
    todo = [e for e in entries if force or not os.path.exists(os.path.join(IMG_DIR, e[1] + "-box3d.png"))
            or by_path.get("./" + e[0]) is None
            or drawn.get(e[2]) != f"{BOX_STYLE_VERSION}:{badge_of(e[2])}"]   # badge or box design changed

    games, matcher = {}, None
    if todo and "launchbox" in order:
        try:
            games = build_index(force=refresh); matcher = Matcher(games)
        except Exception as e:
            log("LaunchBox database unavailable, trying the other sources:", e)
    matches = json.load(open(MATCHES)) if os.path.exists(MATCHES) else {}

    for fname, title, pkg in todo:
        path = "./" + fname
        gid = overrides.get(pkg) or (matcher.find(title) if matcher else None)
        g = games.get(gid) if gid else None

        # every source as the same dict shape, in the configured order
        lb = {}
        if g:
            lb = {"name": g["name"], "desc": html.unescape(g["overview"]), "dev": g["dev"], "pub": g["pub"],
                  "date": g["date"], "genre": g["genre"].split(";")[0].strip()}
            try:
                lb["rating"] = round(min(1.0, float(g["rating"]) / 5), 2)
            except ValueError:
                pass
        src_order = list(order)
        if installed_from.get(pkg) == "f-droid" and "fdroid" in src_order and "googleplay" in src_order:
            src_order.remove("fdroid"); src_order.insert(src_order.index("googleplay"), "fdroid")
        found, used = [], []
        for name in src_order:
            if name == "launchbox":
                d = lb
            elif name == "screenscraper":
                d = ss.lookup(pkg, title)
            elif name == "googleplay":
                d = ms.google_play(pkg)
            elif name == "fdroid":
                d = ms.fdroid(pkg)
            else:
                continue
            if d:
                found.append((name, d)); used.append(name)
        meta = ms.merge(*(d for _, d in found))

        # cover: a real box (LaunchBox, ScreenScraper) beats a store icon
        cover = os.path.join(IMG_DIR, title + "-front.png")
        art = None
        for name, d in found:
            if name == "launchbox" and best_image(g):
                ext = os.path.splitext(best_image(g))[1] or ".png"
                raw = os.path.join(CACHE, "cover-" + gid + ext)
                art = raw if os.path.exists(raw) or fetch_cover(best_image(g), raw) else None
            elif d.get("cover"):
                art = cached_image(d["cover"], f"{name}-{pkg}-cover")
            if art:
                break
        art = art or waydroid_icon(pkg) or title_card(title, os.path.join(CACHE, "card.png"))
        save_as(art, cover)
        box = os.path.join(IMG_DIR, title + "-box3d.png")
        badge = badge_of(pkg)
        render(Image.open(cover), meta.get("name") or title, 640, badge).save(box, optimize=True)
        drawn[pkg] = f"{BOX_STYLE_VERSION}:{badge}"

        game = by_path.get(path)
        if game is None:
            game = ET.SubElement(root, "game"); set_field(game, "path", path); by_path[path] = game
        set_field(game, "name", meta.get("name") or title)
        for tag in ("image", "thumbnail", "boxart"):
            set_field(game, tag, "./images/" + os.path.basename(box))
        for key, tag, suffix, mode in (("fanart", "fanart", "-fanart.jpg", "RGB"),
                                       ("wheel", "marquee", "-marquee.png", "RGBA")):
            raw = cached_image(meta.get(key), f"{pkg}-{key}")
            if raw:
                set_field(game, tag, "./images/" + os.path.basename(save_as(raw, os.path.join(IMG_DIR, title + suffix), mode)))
        set_field(game, "desc", meta.get("desc"))
        set_field(game, "developer", meta.get("dev")); set_field(game, "publisher", meta.get("pub"))
        set_field(game, "releasedate", es_date(meta.get("date", "")))
        set_field(game, "genre", meta.get("genre"))
        if "rating" in meta:
            set_field(game, "rating", f"{meta['rating']:.2f}")
        matches[pkg] = gid or ""
        log(f"{title}: {', '.join(used) or 'no match (app icon)'}, badge={badge or 'none'}")

    # drop gamelist entries whose .android file is gone (only ones we made boxes for)
    names = {e[0] for e in entries}
    for g in list(root.findall("game")):
        p = (g.findtext("path") or "")[2:]
        if p.endswith(".android") and p not in names and "-box3d.png" in (g.findtext("image") or ""):
            root.remove(g)
            for suffix in ("-box3d.png", "-front.png", "-fanart.jpg", "-marquee.png"):
                try: os.remove(os.path.join(IMG_DIR, p[:-8] + suffix))
                except OSError: pass

    json.dump(matches, open(MATCHES, "w"), indent=1)
    json.dump(drawn, open(BADGES, "w"), indent=1)
    ET.indent(tree) if hasattr(ET, "indent") else None
    tree.write(GAMELIST + ".tmp", encoding="utf-8", xml_declaration=True)
    os.replace(GAMELIST + ".tmp", GAMELIST)
    log(f"done: {len(todo)} updated, {len(entries)} games total")


if __name__ == "__main__":
    main()
