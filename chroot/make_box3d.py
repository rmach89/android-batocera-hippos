#!/usr/bin/env python3
"""Render a 3D CD-jewel-case box for an Android game.

    make_box3d.py <front-art> "<Game Title>" <out.png> [--size 640]

* Jewel-case style: 10 mm spine, 125 mm tall; the front's width follows the cover image so
  the whole cover fills the front exactly (square covers -> square art area).
* Front: black "android" band across the top, game art below it, and an optional
  support badge (controller / touch) in the bottom-right corner.
* Spine: Android bot at the top, game title running down the spine.
"""
import os, sys, argparse
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.environ.get("BOX3D_ASSETS", os.path.join(HERE, "box3d"))
GREEN = (61, 220, 132)
CASE = (30, 31, 34)
FONT_CANDIDATES = ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                   "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"]

# texture sizes (px) - 8 px per mm
MM = 8
CW, CH, CD = 142 * MM, 125 * MM, 10 * MM


def font(size):
    for f in FONT_CANDIDATES:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def tinted(mask_path, color, height):
    m = Image.open(mask_path).convert("L")
    m = m.resize((max(1, int(m.width * height / m.height)), height), Image.LANCZOS)
    im = Image.new("RGBA", m.size, color + (255,))
    im.putalpha(m)
    return im


def fit_art(art, w, h):
    """Whole image visible, centred, on a blurred + darkened fill of itself."""
    art = art.convert("RGBA")
    bg = ImageOps.fit(art.convert("RGB"), (w, h), Image.LANCZOS)
    bg = bg.filter(ImageFilter.GaussianBlur(w / 30))
    bg = ImageEnhance.Brightness(bg).enhance(0.55).convert("RGBA")
    s = min(w / art.width, h / art.height)
    fg = art.resize((max(1, int(art.width * s)), max(1, int(art.height * s))), Image.LANCZOS)
    bg.alpha_composite(fg, ((w - fg.width) // 2, (h - fg.height) // 2))
    return bg


def badge_image(kind, size):
    """White rounded tile with the black line icon: 'controller' or 'touch'."""
    mask = Image.open(os.path.join(ASSETS, f"badge-{kind}-mask.png")).convert("L")
    pad = int(size * 0.17)
    inner = size - 2 * pad
    k = min(inner / mask.width, inner / mask.height)
    mask = mask.resize((max(1, int(mask.width * k)), max(1, int(mask.height * k))), Image.LANCZOS)
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.22),
                                           fill=(255, 255, 255, 240), outline=(20, 20, 20, 255),
                                           width=max(2, size // 40))
    icon = Image.new("RGBA", mask.size, (15, 15, 15, 255)); icon.putalpha(mask)
    tile.alpha_composite(icon, ((size - mask.width) // 2, (size - mask.height) // 2))
    shadow = Image.new("RGBA", (size + 24, size + 24), (0, 0, 0, 0))
    sm = Image.new("L", shadow.size, 0)
    ImageDraw.Draw(sm).rounded_rectangle((12, 16, size + 12, size + 16), radius=int(size * 0.22), fill=150)
    shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(8)))
    shadow.alpha_composite(tile, (12, 12))
    return shadow


def front_texture(art, badge=None):
    """The box is shaped by the cover: the art area below the band keeps the image's
    exact aspect ratio, so the whole cover fills the front with nothing cropped."""
    band = int(CH * 0.13)                     # "android" header band
    rule = int(0.6 * MM)
    art_h = CH - band - rule
    aspect = max(0.55, min(1.9, art.width / art.height))   # keep extreme images sane
    CWd = int(art_h * aspect)
    tex = Image.new("RGBA", (CWd, CH), CASE + (255,))
    ix, iw = 0, CWd
    # header band
    d = ImageDraw.Draw(tex)
    d.rectangle((ix, 0, CWd, band), fill=(16, 16, 18, 255))
    word = tinted(os.path.join(ASSETS, "android-wordmark-mask.png"), (255, 255, 255), int(band * 0.52))
    head = tinted(os.path.join(ASSETS, "android-head-mask.png"), GREEN, int(band * 0.48))
    total = word.width + int(band * 0.18) + head.width
    if total > iw * 0.9:                      # narrow (portrait) covers: shrink the logo
        k = iw * 0.9 / total
        word = word.resize((int(word.width * k), int(word.height * k)), Image.LANCZOS)
        head = head.resize((int(head.width * k), int(head.height * k)), Image.LANCZOS)
        total = word.width + int(band * 0.18) + head.width
    x0 = ix + (iw - total) // 2
    tex.alpha_composite(word, (x0, (band - word.height) // 2 + int(band * 0.02)))
    tex.alpha_composite(head, (x0 + word.width + int(band * 0.18), (band - head.height) // 2 + int(band * 0.06)))
    d.rectangle((ix, band, CWd, band + rule), fill=GREEN + (255,))   # green rule
    # art: exact fit (fit_art only adds a fill if the aspect had to be clamped)
    top = band + rule
    tex.alpha_composite(fit_art(art, iw, CH - top), (ix, top))
    # support badge, bottom-right corner of the cover
    if badge in ("controller", "touch"):
        b = badge_image(badge, int((CH - top) * 0.17))
        m = int(CH * 0.025)
        tex.alpha_composite(b, (iw - b.width - m + 12, CH - b.height - m + 12))
    # gloss: diagonal sheen across the plastic lid
    CW = tex.width
    gloss = Image.new("L", (CW, CH), 0)
    gd = ImageDraw.Draw(gloss)
    gd.polygon([(int(CW * 0.15), 0), (int(CW * 0.45), 0), (int(CW * 0.05), CH), (0, CH), (0, int(CH * 0.6))], fill=38)
    gloss = gloss.filter(ImageFilter.GaussianBlur(40))
    white = Image.new("RGBA", (CW, CH), (255, 255, 255, 0)); white.putalpha(gloss)
    tex.alpha_composite(white)
    # thin case edge
    ImageDraw.Draw(tex).rectangle((0, 0, CW - 1, CH - 1), outline=(10, 10, 10, 255), width=4)
    return tex


def spine_texture(title):
    tex = Image.new("RGBA", (CD, CH), CASE + (255,))
    d = ImageDraw.Draw(tex)
    d.rectangle((0, 0, CD, int(CH * 0.13)), fill=(16, 16, 18, 255))
    head = tinted(os.path.join(ASSETS, "android-head-mask.png"), GREEN, int(CD * 0.48))
    if head.width > CD * 0.8:
        head = head.resize((int(CD * 0.8), int(head.height * CD * 0.8 / head.width)), Image.LANCZOS)
    tex.alpha_composite(head, ((CD - head.width) // 2, int(CH * 0.065) - head.height // 2))
    d.rectangle((0, int(CH * 0.13), CD, int(CH * 0.13) + int(0.6 * MM)), fill=GREEN + (255,))
    # vertical title (reads top -> bottom, like real spines)
    avail = int(CH * 0.80)
    size = int(CD * 0.46)
    f = font(size)
    while size > 14 and f.getlength(title) > avail:
        size -= 2; f = font(size)
    t = title
    while f.getlength(t + "...") > avail and len(t) > 3:
        t = t[:-1]
    if t != title:
        t = t.rstrip() + "..."
    tw = int(f.getlength(t)) + 4
    timg = Image.new("RGBA", (tw, CD), (0, 0, 0, 0))
    ImageDraw.Draw(timg).text((2, CD // 2), t, font=f, fill=(240, 240, 240, 255), anchor="lm")
    timg = timg.rotate(-90, expand=True)
    tex.alpha_composite(timg, ((CD - timg.width) // 2, int(CH * 0.155)))
    # shading: spine faces away from the light
    shade = Image.new("RGBA", (CD, CH), (0, 0, 0, 90))
    tex.alpha_composite(shade)
    ImageDraw.Draw(tex).rectangle((0, 0, CD - 1, CH - 1), outline=(8, 8, 8, 255), width=3)
    return tex


def coeffs(dst, src):
    """PIL PERSPECTIVE coefficients mapping output quad `dst` -> texture rect `src`."""
    A, B = [], []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); B.append(u)
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y]); B.append(v)
    return np.linalg.solve(np.array(A, float), np.array(B, float)).tolist()


def warp(tex, quad, size):
    w, h = tex.size
    return tex.transform(size, Image.PERSPECTIVE,
                         coeffs(quad, [(0, 0), (w, 0), (w, h), (0, h)]),
                         Image.BICUBIC, fillcolor=(0, 0, 0, 0))


def render(art, title, out_h=640, badge=None):
    S = 2                                   # supersample
    H = out_h * S
    front = front_texture(art.convert("RGBA"), badge)
    aspect = front.width / front.height
    # 3/4 view from the left: spine visible, front receding slightly to the right
    pad = H * 0.04
    sw = H * 0.095                          # projected spine width
    fw = aspect * H * 0.88 * 0.92           # projected front width (a little foreshortened)
    W = int(pad + sw + fw + pad)
    top_l, bot_l = H * 0.06, H * 0.94       # near (spine-side) edge of the front
    top_r, bot_r = H * 0.105, H * 0.895     # far edge, a little shorter
    xs, xf, xr = pad, pad + sw, pad + sw + fw
    sp_top, sp_bot = H * 0.085, H * 0.915
    spine_q = [(xs, sp_top), (xf, top_l), (xf, bot_l), (xs, sp_bot)]
    front_q = [(xf, top_l), (xr, top_r), (xr, bot_r), (xf, bot_l)]

    canvas = Image.new("RGBA", (W, int(H * 1.04)), (0, 0, 0, 0))
    size = canvas.size
    sh = Image.new("L", size, 0)
    ImageDraw.Draw(sh).polygon([(xs + 20 * S, sp_bot), (xr, bot_r), (xr, bot_r + 14 * S), (xs + 20 * S, sp_bot + 18 * S)], fill=140)
    sh = sh.filter(ImageFilter.GaussianBlur(14 * S))
    shadow = Image.new("RGBA", size, (0, 0, 0, 0)); shadow.putalpha(sh)
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(warp(spine_texture(title), spine_q, size))
    canvas.alpha_composite(warp(front, front_q, size))
    canvas = canvas.crop(canvas.getbbox())
    return canvas.resize((canvas.width // S, canvas.height // S), Image.LANCZOS)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("art"); ap.add_argument("title"); ap.add_argument("out")
    ap.add_argument("--size", type=int, default=640, help="output height in px")
    ap.add_argument("--badge", choices=["controller", "touch"], help="support badge, bottom-right")
    a = ap.parse_args()
    render(Image.open(a.art), a.title, a.size, a.badge).save(a.out, optimize=True)
