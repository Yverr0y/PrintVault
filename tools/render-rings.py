#!/usr/bin/env python3
"""Render the sizing rings to listing images.

Headfit shows one mesh at a time, white on a dark ground, which is right for
judging a fit and wrong for a listing. What gets posted is the set, so the set
has to be in the picture, and the number has to be legible.

A z buffer rather than a depth sort. Sorting by centroid is the obvious thing
and it fails on exactly the detail that matters here: the label pad is one
wide quad and the digits sit 0.7 mm above it, close enough that the pad's
centroid wins about half the time and paints over them. The far side of the
ring came through the near side for the same reason. Rendered at twice the
output size and scaled down, which is the whole of the antialiasing.
"""

import math, os, struct, sys
import numpy as np
from PIL import Image, ImageDraw

BG_TOP, BG_BOT = (18, 22, 30), (10, 12, 16)
ACCENT, DARKEN = (255, 140, 70), (116, 56, 22)
W, H, SS = 1600, 1200, 2
LIGHT = (0.38, 0.60, 0.70)          # over the left shoulder, camera relative

def load_stl(path):
    b = open(path, 'rb').read()
    n = struct.unpack('<I', b[80:84])[0]
    a = np.frombuffer(b[84:84 + 50 * n], dtype=np.uint8).reshape(n, 50)
    return a[:, 12:48].copy().view('<f4').reshape(n, 3, 3).astype(np.float64)

def rotate(v, az, el):
    ca, sa, ce, se = math.cos(az), math.sin(az), math.cos(el), math.sin(el)
    x, y, z = v[..., 0], v[..., 1], v[..., 2]
    x, z = x * ca - z * sa, x * sa + z * ca
    y, z = y * ce - z * se, y * se + z * ce
    return np.stack([x, y, z], axis=-1)

def background(w, h, grid=True):
    img = Image.new('RGB', (w, h), BG_BOT)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    if grid:
        # the same ground cue Headfit uses, so the set looks related to the tool
        for gx in range(-24, 25):
            d.line([(w / 2 + gx * w / 25, h * 0.70), (w / 2 + gx * w / 9, h)],
                   fill=(31, 37, 48))
        for i in range(10):
            d.line([(0, h * 0.70 + h * 0.30 * (i / 9) ** 1.8),
                    (w, h * 0.70 + h * 0.30 * (i / 9) ** 1.8)], fill=(31, 37, 48))
    return img

def label_pad(mesh):
    """The raised label, found as whatever stands above the band."""
    top = mesh[..., 1].max()
    pts = mesh.reshape(-1, 3)
    return pts[pts[:, 1] > top - 0.01].mean(axis=0)

def render(meshes, out, az=0.6, el=0.5, margin=0.90, focus=None, grid=True,
           ao_depth=2.0):
    """meshes is a list of (triangles, offset); one image, however many parts.

    ao_depth is how far, in millimetres, something has to stand above its
    surroundings to cast full contact shading. It wants to be near the size of
    the detail being shown, so the label crop sets it small.

    focus is (point, span_mm) and frames that much of the model around that
    point. At full frame the digits land on fifteen pixels and read as a
    smudge, so cropping is the only way they become digits.
    """
    tris = np.concatenate([rotate(m + np.asarray(o, float), az, el)
                           for m, o in meshes])
    w, h = W * SS, H * SS

    if focus:
        c = rotate(np.asarray(focus[0], float), az, el)
        cx, cy, scale = c[0], c[1], min(w, h) * margin / focus[1]
    else:
        lo, hi = tris.reshape(-1, 3).min(axis=0), tris.reshape(-1, 3).max(axis=0)
        cx, cy = (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2
        scale = min(w * margin / max(hi[0] - lo[0], 1e-6),
                    h * margin / max(hi[1] - lo[1], 1e-6))

    sx = w / 2 + (tris[..., 0] - cx) * scale
    sy = h / 2 - (tris[..., 1] - cy) * scale
    sz = tris[..., 2]

    e1, e2 = tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]
    nrm = np.cross(e1, e2)
    nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
    front = nrm[:, 2] > 0                       # anything else is never seen
    sx, sy, sz, nrm = sx[front], sy[front], sz[front], nrm[front]

    # one key light, plus enough ambient that the shadow side stays a surface
    # rather than a silhouette
    lam = np.clip(nrm @ np.array(LIGHT), 0, None)
    k = (0.28 + 0.72 * lam)[:, None]
    col = (np.array(DARKEN) + (np.array(ACCENT) - np.array(DARKEN)) * k)

    buf = np.array(background(w, h, grid), dtype=np.float64)
    zbuf = np.full((h, w), -np.inf)

    for i in range(len(sx)):
        x0, x1 = int(np.floor(sx[i].min())), int(np.ceil(sx[i].max())) + 1
        y0, y1 = int(np.floor(sy[i].min())), int(np.ceil(sy[i].max())) + 1
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, w), min(y1, h)
        if x0 >= x1 or y0 >= y1:
            continue
        px = np.arange(x0, x1) + 0.5
        py = (np.arange(y0, y1) + 0.5)[:, None]
        ax, ay = sx[i][0], sy[i][0]
        bx, by = sx[i][1] - ax, sy[i][1] - ay
        cxx, cyy = sx[i][2] - ax, sy[i][2] - ay
        den = bx * cyy - cxx * by
        if abs(den) < 1e-9:
            continue
        qx, qy = px - ax, py - ay
        u = (qx * cyy - cxx * qy) / den
        v = (bx * qy - qx * by) / den
        inside = (u >= 0) & (v >= 0) & (u + v <= 1)
        if not inside.any():
            continue
        z = sz[i][0] + u * (sz[i][1] - sz[i][0]) + v * (sz[i][2] - sz[i][0])
        win = inside & (z > zbuf[y0:y1, x0:x1])
        if not win.any():
            continue
        zbuf[y0:y1, x0:x1][win] = z[win]
        buf[y0:y1, x0:x1][win] = col[i]

    # Contact shading off the depth buffer. Without it the raised digits are
    # nearly invisible: their top faces share a normal with the pad they sit
    # on, so a directional light gives them the identical colour and all that
    # separates them is a hairline of side wall. Real parts read because the
    # relief catches a shadow, and this is the cheap version of that: a pixel
    # gets darker the further it sits below whatever stands around it.
    occ = np.zeros((h, w))
    for dx, dy in ((r * ox, r * oy) for r in (5 * SS, 11 * SS)
                   for ox, oy in ((1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1))):
        sh = np.full((h, w), -np.inf)
        sh[max(0,-dy):h - max(0,dy), max(0,-dx):w - max(0,dx)] =             zbuf[max(0,dy):h - max(0,-dy), max(0,dx):w - max(0,-dx)]
        ok = np.isfinite(sh) & np.isfinite(zbuf)
        occ = np.maximum(occ, np.where(ok, np.where(ok, sh, 0) - np.where(ok, zbuf, 0), 0))
    shade = 1.0 - 0.42 * np.clip(occ / ao_depth, 0, 1)
    buf *= np.where(np.isfinite(zbuf), shade, 1.0)[:, :, None]

    img = Image.fromarray(np.clip(buf, 0, 255).astype(np.uint8)).resize((W, H), Image.LANCZOS)
    img.save(out, 'PNG', optimize=True)
    return int(front.sum())

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src  = os.path.normpath(os.path.join(here, '..', 'rings'))
    out  = os.path.join(src, 'images')
    os.makedirs(out, exist_ok=True)
    sizes = sorted(int(f.split('-')[2][:-6]) for f in os.listdir(src) if f.endswith('.stl'))
    if not sizes:
        print('no rings found, run make-rings.py first'); return
    mesh = {s: load_stl(os.path.join(src, 'head-ring-%dmm.stl' % s)) for s in sizes}
    mid  = 570 if 570 in sizes else sizes[len(sizes) // 2]

    # 1. the set laid out, because the set is what gets posted. Not stacked:
    #    sizes this close cannot nest without the walls clashing, and thirteen
    #    stacked reads as one spring anyway.
    laid, i, dz = [], 0, 0.0
    for count in (5, 4, 4):
        row = sizes[i:i + count]; i += count
        for c, s in enumerate(row):
            laid.append((mesh[s], ((c - (count - 1) / 2) * 212.0, 0.0, dz)))
        dz += 238.0
    print('  01-the-set        %d rings, %d faces' % (
        len(sizes), render(laid, os.path.join(out, '01-the-set.png'),
                           az=0.0, el=1.06, margin=0.95)))

    # 2. one ring in three quarter, the plain product shot
    print('  02-one-ring       %d mm, %d faces' % (
        mid, render([(mesh[mid], (0, 0, 0))], os.path.join(out, '02-one-ring.png'),
                    az=0.60, el=0.44, margin=0.86)))

    # 3. the label, close enough to read. Lit from the side so the walls of the
    #    raised digits darken against the pad; their top faces share a normal
    #    with the pad and on their own would be invisible.
    print('  03-the-label      %d mm, %d faces' % (
        mid, render([(mesh[mid], (0, 0, 0))], os.path.join(out, '03-the-label.png'),
                    az=0.0, el=0.80, margin=0.80, focus=(label_pad(mesh[mid]), 46.0),
                    grid=False, ao_depth=0.55)))

    for f in sorted(os.listdir(out)):
        print('   %-20s %6.0f KB' % (f, os.path.getsize(os.path.join(out, f)) / 1024))

if __name__ == '__main__':
    main()
