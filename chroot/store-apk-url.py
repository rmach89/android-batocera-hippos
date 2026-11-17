#!/usr/bin/env python3
"""Print "<apk-url> [md5]" for an app store the F1 menu installs on first launch.

    store-apk-url.py <package>

  org.fdroid.fdroid  F-Droid       official stable link on f-droid.org
  com.aurora.store   Aurora Store  newest build in the official F-Droid repository
  cm.aptoide.pt      Aptoide       Aptoide's own official store ("aptoide-web"), with md5 to verify
"""
import json, sys, urllib.request

UA = {"User-Agent": "android-addon"}


def get_json(url):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30))


def fdroid(pkg):
    code = get_json(f"https://f-droid.org/api/v1/packages/{pkg}")["suggestedVersionCode"]
    return f"https://f-droid.org/repo/{pkg}_{code}.apk"


def aptoide(pkg):
    f = get_json(f"https://ws75.aptoide.com/api/7/app/getMeta/package_name={pkg}/store_name=aptoide-web")["data"]["file"]
    return f"{f['path']} {f['md5sum']}"


RESOLVERS = {
    "org.fdroid.fdroid": lambda p: "https://f-droid.org/F-Droid.apk",
    "com.aurora.store": fdroid,
    "cm.aptoide.pt": aptoide,
}

if __name__ == "__main__":
    pkg = sys.argv[1] if len(sys.argv) > 1 else ""
    if pkg not in RESOLVERS:
        sys.exit(1)             # not a store we install -> nothing to do
    try:
        print(RESOLVERS[pkg](pkg))
    except Exception as ex:
        sys.exit(f"could not resolve {pkg}: {ex}")
