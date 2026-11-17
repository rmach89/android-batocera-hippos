#!/usr/bin/env python3
"""Work out where each installed EmulationStation theme keeps its per-system logos and
what an Android logo must be called there.  Runs INSIDE the chroot (it has Pillow); the
themes are bind-mounted read-only at the paths given on the command line.

    theme-logos.py <root1> [<root2> ...]

Prints one plan line per place an Android logo should go:
    <root-index>\t<relative path>\t<variant: light|dark>\t<ext>
and, for themes that keep one folder per system (snes/theme.xml ...):
    <root-index>\tCLONE\t<relative system dir to copy>\t<relative logo file inside it>\t<variant>\t<ext>

The android logo itself is never written here - the host links it in.
"""
import os, re, sys
from collections import defaultdict

try:
    from PIL import Image
except ImportError:
    Image = None

SYSTEMS = ["snes", "nes", "megadrive", "genesis", "psx", "n64", "gba", "gb", "gbc", "mastersystem",
           "pcengine", "dreamcast", "ps2", "gamecube", "wii", "nds", "psp", "saturn", "segacd", "atari2600"]
EXTS = {".svg", ".png", ".jpg", ".jpeg", ".webp"}
LOGO_HINT = re.compile(r"logo|marquee|wheel", re.I)
NOT_LOGO_HINT = re.compile(r"background|fanart|/bg|_bg|-bg|console|controller|device|screenshot|"
                           r"video|carousel-art|systemart|/art/systems|cover|box|cart|photo", re.I)
MAX_DEPTH = 6


def svg_size(path):
    try:
        head = open(path, "rb").read(4000).decode("utf-8", "ignore")
    except OSError:
        return None
    m = re.search(r'viewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)', head)
    if m:
        return float(m.group(1)), float(m.group(2))
    w = re.search(r'\bwidth="([\d.]+)', head)
    h = re.search(r'\bheight="([\d.]+)', head)
    return (float(w.group(1)), float(h.group(1))) if w and h else None


def size(path):
    if path.lower().endswith(".svg"):
        return svg_size(path)
    if Image:
        try:
            with Image.open(path) as im:
                return im.size
        except Exception:
            return None
    return None


def lum_hex(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def brightness(path):
    """Average brightness of the visible part of a logo, 0 (black) .. 1 (white)."""
    if path.lower().endswith(".svg"):
        try:
            txt = open(path, "rb").read(400000).decode("utf-8", "ignore")
        except OSError:
            return None
        cols = re.findall(r'(?:fill|stroke|stop-color)\s*[:=]\s*"?\s*(#[0-9a-fA-F]{3,6})\b', txt)
        cols = [c for c in cols if len(c) in (4, 7)]
        if not cols and "fill" not in txt:
            return 0.0          # no fill given -> SVG default is black
        return sum(lum_hex(c) for c in cols) / len(cols) if cols else None
    if not Image:
        return None
    try:
        with Image.open(path) as im:
            im = im.convert("RGBA").resize((64, 64))
            data = im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()
            px = [(r, g, b) for r, g, b, a in data if a > 128]
    except Exception:
        return None
    if not px:
        return None
    return sum(0.2126 * r + 0.7152 * g + 0.0722 * b for r, g, b in px) / len(px) / 255


def variant(samples):
    vals = [v for v in (brightness(p) for p in samples[:4]) if v is not None]
    if not vals:
        return "light"                      # most ES themes are dark
    return "light" if sum(vals) / len(vals) >= 0.5 else "dark"


def token_in(stem):
    for s in sorted(SYSTEMS, key=len, reverse=True):     # "gbc" before "gb"
        m = re.search(r"(?<![a-z0-9])" + re.escape(s) + r"(?![a-z0-9])", stem)
        if m:
            return s, m
    return None, None


def scan(idx, root):
    groups = defaultdict(list)               # (dir, pattern, ext) -> [(system, path)]
    system_dirs = []                          # folder-per-system themes
    root_depth = root.rstrip("/").count("/")
    for d, subdirs, files in os.walk(root, followlinks=False):
        depth = d.count("/") - root_depth
        if depth >= MAX_DEPTH:
            subdirs[:] = []
        base = os.path.basename(d).lower()
        if base in SYSTEMS and "theme.xml" in files:
            system_dirs.append(d)
        for f in files:
            stem, ext = os.path.splitext(f)
            if ext.lower() not in EXTS:
                continue
            sysname, m = token_in(stem.lower())
            if not sysname:
                continue
            pattern = stem[:m.start()] + "{sys}" + stem[m.end():]
            groups[(d, pattern, ext)].append((sysname, os.path.join(d, f)))

    plan = []
    for (d, pattern, ext), items in groups.items():
        if len({s for s, _ in items}) < 3:   # not a per-system set
            continue
        rel_dir = os.path.relpath(d, root)
        name_hint = rel_dir + "/" + pattern
        samples = [p for _, p in items]
        if NOT_LOGO_HINT.search(name_hint) and not LOGO_HINT.search(name_hint):
            continue
        if not LOGO_HINT.search(name_hint):  # ambiguous folder: logos are wide
            dims = [s for s in (size(p) for p in samples[:4]) if s and s[1]]
            if not dims or sum(w / h for w, h in dims) / len(dims) < 1.6:
                continue
        target = os.path.join(rel_dir, pattern.replace("{sys}", "android") + ext)
        plan.append(f"{idx}\t{os.path.normpath(target)}\t{variant(samples)}\t{ext.lower().lstrip('.')}")

    # folder-per-system: copy e.g. snes/ -> android/, then swap its logo image(s)
    own_android = [p for p in os.listdir(root) if p.lower() == "android" and os.path.isdir(os.path.join(root, p))
                   and not os.path.exists(os.path.join(root, p, ".android-addon"))]
    if system_dirs and not own_android:      # (re)create unless the theme ships its own
        src = sorted(system_dirs, key=lambda p: SYSTEMS.index(os.path.basename(p).lower()))[0]
        for dd, _, files in os.walk(src):
            for f in files:
                stem, ext = os.path.splitext(f)
                if ext.lower() in EXTS and LOGO_HINT.search(stem):
                    p = os.path.join(dd, f)
                    plan.append(f"{idx}\tCLONE\t{os.path.relpath(src, root)}\t{os.path.relpath(p, src)}"
                                f"\t{variant([p])}\t{ext.lower().lstrip('.')}")
    return plan


if __name__ == "__main__":
    for i, r in enumerate(sys.argv[1:]):
        if os.path.isdir(r):
            for line in scan(i, r):
                print(line)
