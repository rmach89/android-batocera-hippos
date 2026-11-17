#!/usr/bin/env python3
"""Print "<tag> <zip-url>" for the newest add-on version (runs inside the chroot).

Checks both and uses whichever is NEWER (a tie goes to the release):
  - the latest published GitHub release (its attached .zip, else the source zip)
  - the VERSION file on the main branch + the main branch zip
So an old release never hides newer fixes pushed to main.
"""
import json, sys, urllib.request

REPO = "rmach89/android-batocera-hippos"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "android-addon-updater",
                                               "Accept": "application/vnd.github+json"})
    return urllib.request.urlopen(req, timeout=20).read()


def ver(tag):
    try:
        return tuple(int(x) for x in tag.lstrip("v").split("."))
    except ValueError:
        return (0,)


candidates = []          # (version, tag, url) - whichever is newer wins
try:
    r = json.loads(get(f"https://api.github.com/repos/{REPO}/releases/latest"))
    url = next((a["browser_download_url"] for a in r.get("assets", []) if a["name"].endswith(".zip")),
               r["zipball_url"])
    candidates.append((ver(r["tag_name"]), r["tag_name"], url))
except Exception:
    pass
try:
    v = "v" + get(f"https://raw.githubusercontent.com/{REPO}/main/VERSION").decode().strip().lstrip("v")
    candidates.append((ver(v), v, f"https://github.com/{REPO}/archive/refs/heads/main.zip"))
except Exception:
    pass
if not candidates:
    sys.exit("could not reach GitHub")
_, tag, url = max(candidates, key=lambda c: c[0])      # a tie keeps the release (listed first)
print(tag, url)
