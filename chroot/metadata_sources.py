#!/usr/bin/env python3
"""Extra metadata sources used after LaunchBox, so every game ends up with a cover,
description, developer, genre and background art.

  ScreenScraper   box art, wheel logo, screenshot, text  (needs a developer ID - see README)
  Google Play     store listing: hi-res icon, feature graphic, screenshot, text, rating
  F-Droid         open-source apps: icon, feature graphic, screenshot, summary/description

Every function returns a dict with any of:
  name desc dev pub genre date(YYYY-MM-DD) rating(0..1) cover fanart wheel   (images = URLs)
or {} when the app was not found.  Results are cached per package for 30 days.
"""
import os, re, json, time, html, difflib, unicodedata, urllib.error, urllib.parse, urllib.request

CACHE = "/root/.cache/android-addon/meta"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) batocera-android-addon/1.0",
      "Accept-Language": "en-US,en;q=0.8"}
TTL = 30 * 86400
os.makedirs(CACHE, exist_ok=True)


def _get(url, timeout=30):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def _cached(kind, key, fn):
    path = os.path.join(CACHE, f"{kind}-{re.sub(r'[^A-Za-z0-9._-]', '_', key)}.json")
    if os.path.exists(path) and time.time() - os.path.getmtime(path) < TTL:
        try:
            return json.load(open(path))
        except ValueError:
            pass
    try:
        data = fn() or {}
    except urllib.error.HTTPError as e:
        data = {} if e.code == 404 else None          # 404 = not listed (cache that too)
    except Exception:
        data = None                                   # offline / blocked: try again next time
    if data is None:
        return {}
    json.dump(data, open(path, "w"))
    return data


def _clean(text):
    text = re.sub(r"<br\s*/?>", "\n", text or "", flags=re.I)
    text = re.sub(r"</p\s*>", "\n\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"\n{3,}", "\n\n", html.unescape(text)).strip()


def _meta(page, attr, name):
    m = re.search(rf'<meta[^>]+{attr}="{re.escape(name)}"[^>]+content="([^"]*)"', page) or \
        re.search(rf'<meta[^>]+content="([^"]*)"[^>]+{attr}="{re.escape(name)}"', page)
    return html.unescape(m.group(1)) if m else ""


def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)|\[.*?\]", " ", s).replace("&", " and ")
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(re.sub(r"\b(the|a|an|hd|free|lite|mobile)\b", " ", s).split())


# ------------------------------------------------------------------ Google Play
PLAY_GENRES = {"GAME_ACTION": "Action", "GAME_ADVENTURE": "Adventure", "GAME_ARCADE": "Arcade",
               "GAME_BOARD": "Board game", "GAME_CARD": "Card game", "GAME_CASINO": "Casino",
               "GAME_CASUAL": "Casual", "GAME_EDUCATIONAL": "Educational", "GAME_MUSIC": "Music",
               "GAME_PUZZLE": "Puzzle", "GAME_RACING": "Racing", "GAME_ROLE_PLAYING": "Role-playing",
               "GAME_SIMULATION": "Simulation", "GAME_SPORTS": "Sports", "GAME_STRATEGY": "Strategy",
               "GAME_TRIVIA": "Trivia", "GAME_WORD": "Word"}


def _play_img(url, size):
    """play-lh image URLs take a size suffix: =s512, =w1024 ..."""
    return re.sub(r"=[swh]\d+.*$", "", url) + "=" + size if url else ""


def google_play(pkg):
    def fetch():
        page = _get(f"https://play.google.com/store/apps/details?id={urllib.parse.quote(pkg)}&hl=en&gl=US")
        out = {}
        for block in re.findall(r'<script[^>]+application/ld\+json[^>]*>(.*?)</script>', page, re.S):
            try:
                d = json.loads(block)
            except ValueError:
                continue
            if isinstance(d, dict) and d.get("@type") in ("SoftwareApplication", "VideoGame", "MobileApplication"):
                out["name"] = d.get("name", "")
                out["desc"] = _clean(d.get("description", ""))
                out["cover"] = _play_img(d.get("image", ""), "s1024")       # hi-res icon
                author = d.get("author") or {}
                out["dev"] = out["pub"] = author.get("name", "") if isinstance(author, dict) else ""
                out["genre"] = PLAY_GENRES.get(d.get("applicationCategory", ""), "")
                try:
                    out["rating"] = round(float((d.get("aggregateRating") or {}).get("ratingValue")) / 5, 2)
                except (TypeError, ValueError):
                    pass
                break
        if not out:
            title = _meta(page, "property", "og:title")
            if not title:
                return {}
            out["name"] = re.sub(r"\s+-\s+Apps on Google Play$", "", title)
            out["desc"] = _meta(page, "name", "description")
        # feature graphic / first screenshot -> background art
        og = _meta(page, "property", "og:image")
        shots = re.findall(r'<img[^>]+src="(https://play-lh\.googleusercontent\.com/[^"]+)"[^>]+alt="Screenshot image"', page)
        fan = og if og and _play_img(og, "") != _play_img(out.get("cover", ""), "") else (shots[0] if shots else "")
        if fan:
            out["fanart"] = _play_img(fan, "w1920")
        return {k: v for k, v in out.items() if v not in ("", None)}
    return _cached("play", pkg, fetch)


# ------------------------------------------------------------------ F-Droid
def fdroid(pkg):
    def fetch():
        page = _get(f"https://f-droid.org/en/packages/{urllib.parse.quote(pkg)}/")
        out = {}
        m = re.search(r'<h3 class="package-name">\s*(.*?)\s*</h3>', page, re.S)
        if not m:
            return {}
        out["name"] = _clean(m.group(1))
        s = re.search(r'<div class="package-summary"[^>]*>(.*?)</div>', page, re.S)
        d = re.search(r'<div class="package-description"[^>]*>(.*?)</div>', page, re.S)
        out["desc"] = _clean(d.group(1)) if d else (_clean(s.group(1)) if s else "")
        base = "https://f-droid.org"
        i = re.search(r'<img[^>]+class="package-icon"[^>]+src="([^"]+)"', page)
        if i:
            out["cover"] = urllib.parse.urljoin(base, i.group(1))
        f = re.search(r'src="([^"]*/featureGraphic[^"]*)"', page)
        shot = re.search(r'<li class="screenshot[^"]*"[^>]*>\s*(?:<a[^>]*>)?\s*<img[^>]+src="([^"]+)"', page)
        if f or shot:
            out["fanart"] = urllib.parse.urljoin(base, (f or shot).group(1))
        a = re.search(r'<li class="package-author"[^>]*>.*?<a[^>]*>(.*?)</a>', page, re.S)
        if a:
            out["dev"] = _clean(a.group(1))
        out["genre"] = ""
        return {k: v for k, v in out.items() if v}
    return _cached("fdroid", pkg, fetch)


# ------------------------------------------------------------------ ScreenScraper
SS_API = "https://api.screenscraper.fr/api2/"


class ScreenScraper:
    """devid/devpassword: a ScreenScraper developer ID (free, asked for on their forum).
    user/password: your normal ScreenScraper account (raises the daily quota)."""

    def __init__(self, devid, devpassword, user="", password=""):
        self.auth = {"devid": devid, "devpassword": devpassword, "softname": "batocera-android-addon",
                     "output": "json"}
        if user:
            self.auth.update(ssid=user, sspassword=password)
        self.ok = bool(devid and devpassword)
        self._system = None

    def _call(self, api, **params):
        q = urllib.parse.urlencode({**self.auth, **params})
        return json.loads(_get(f"{SS_API}{api}.php?{q}", timeout=40))

    def system_id(self):
        if self._system is None:
            def fetch():
                for s in self._call("systemesListe")["response"]["systemes"]:
                    names = " ".join(str(v) for v in (s.get("noms") or {}).values()).lower()
                    if re.search(r"\bandroid\b", names):
                        return {"id": s["id"]}
                return {}
            self._system = _cached("ss", "system-android", fetch).get("id") or ""
        return self._system

    @staticmethod
    def _pick(items, lang_key, prefer=("us", "wor", "en", "eu", "ss")):
        if not items:
            return ""
        if isinstance(items, dict):
            return items.get("text", "")
        by = {i.get(lang_key): i.get("text", "") for i in items if isinstance(i, dict)}
        for p in prefer:
            if by.get(p):
                return by[p]
        return next(iter(by.values()), "")

    def _media(self, medias, kind):
        found = {m.get("region", ""): m.get("url", "") for m in medias or [] if m.get("type") == kind}
        for r in ("us", "wor", "eu", "ss", ""):
            if found.get(r):
                return found[r]
        return next(iter(found.values()), "")

    def lookup(self, pkg, title):
        if not self.ok:
            return {}

        def fetch():
            sid = self.system_id()
            params = {"recherche": title}
            if sid:
                params["systemeid"] = sid
            games = (self._call("jeuRecherche", **params).get("response") or {}).get("jeux") or []
            want, best, score = norm(title), None, 0.0
            for g in games:
                if not g.get("id"):
                    continue
                for n in g.get("noms") or []:
                    r = difflib.SequenceMatcher(None, want, norm(n.get("text", ""))).ratio()
                    if r > score:
                        best, score = g, r
            if not best or score < 0.85:
                return {}
            g = best
            out = {
                "name": self._pick(g.get("noms"), "region"),
                "desc": self._pick(g.get("synopsis"), "langue", ("en", "fr")),
                "dev": (g.get("developpeur") or {}).get("text", ""),
                "pub": (g.get("editeur") or {}).get("text", ""),
                "date": self._pick(g.get("dates"), "region")[:10],
                "genre": self._pick(((g.get("genres") or [{}])[0]).get("noms"), "langue", ("en",)),
                "cover": self._media(g.get("medias"), "box-2D"),
                "wheel": self._media(g.get("medias"), "wheel-hd") or self._media(g.get("medias"), "wheel"),
                "fanart": self._media(g.get("medias"), "fanart") or self._media(g.get("medias"), "ss"),
            }
            try:
                out["rating"] = round(float((g.get("note") or {}).get("text")) / 20, 2)
            except (TypeError, ValueError):
                pass
            if len(out["date"]) == 4:
                out["date"] += "-01-01"
            return {k: v for k, v in out.items() if v not in ("", None)}
        return _cached("ss", pkg, fetch)


def merge(*sources):
    """First non-empty value wins, in the order given."""
    out = {}
    for s in sources:
        for k, v in (s or {}).items():
            if v not in ("", None) and k not in out:
                out[k] = v
    return out
