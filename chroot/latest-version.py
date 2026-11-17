#!/usr/bin/env python3
"""Print "<tag> <zip-url>" for the newest add-on version (runs inside the chroot).

1. A published GitHub release (uses its attached .zip, else the source zip)
2. Otherwise the VERSION file on the main branch + the main branch zip
"""
import json, sys, urllib.request

REPO = "rmach89/android-batocera-hippos"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "android-addon-updater",
                                               "Accept": "application/vnd.github+json"})
    return urllib.request.urlopen(req, timeout=20).read()


try:
    r = json.loads(get(f"https://api.github.com/repos/{REPO}/releases/latest"))
    url = next((a["browser_download_url"] for a in r.get("assets", []) if a["name"].endswith(".zip")),
               r["zipball_url"])
    print(r["tag_name"], url)
except Exception:
    try:
        v = get(f"https://raw.githubusercontent.com/{REPO}/main/VERSION").decode().strip()
        print("v" + v.lstrip("v"), f"https://github.com/{REPO}/archive/refs/heads/main.zip")
    except Exception as ex:
        sys.exit(f"could not reach GitHub: {ex}")
