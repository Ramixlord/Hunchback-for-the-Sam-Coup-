#!/usr/bin/env python3
"""Cut graphics from the HB disk screens into SAM mode-4 data (gfx.asm)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from samdisk import read_files, screen

# usage: mkgfx.py <original HunchbackFN.mgt> <out gfx.asm>
_F = read_files(sys.argv[1])
SP, PALSP = screen(_F['HB SP'])
MU15, PAL = screen(_F['HB MU1.5'])
MU5, _ = screen(_F['HB MU5'])
MU4, PAL4 = screen(_F['HB MU4'])
MAIN, PALMAIN = screen(_F['HB Main'])

# clean 8x8 brick tile; screen pixel (X,Y) = T[(Y-1)&7][(X-1)&7]
T = np.array([[int(c, 16) for c in r] for r in
              ['33233333', '22222232', '22222232', '22222332',
               '33333323', '22322222', '22322222', '23322222']])


def brick(X, Y):
    return T[(Y - 1) & 7][(X - 1) & 7]


out = []
ovl = []
sizes = {}


OVL_LABELS = {'gfx_band5', 'gfx_tq', 'gfx_te'}   # read only while a screen buffer is paged in


def emit(label, data, comment=''):
    dst = ovl if label in OVL_LABELS else out
    dst.append('%s:%s' % (label, ('  ; ' + comment) if comment else ''))
    for i in range(0, len(data), 16):
        dst.append('        db ' + ','.join('%d' % b for b in data[i:i + 16]))
    sizes[label] = len(data)


def pack(pix):  # pix: list of nibbles (even length)
    return [(pix[i] << 4) | pix[i + 1] for i in range(0, len(pix), 2)]


def masked(img, opaque, ax, ay, label, comment=''):
    """img/opaque: 2D arrays of a cell. (ax,ay) anchor in cell coords.
    Crop to bbox of opaque pixels (x aligned even relative to anchor parity)."""
    ys, xs = np.nonzero(opaque)
    if len(xs) == 0:
        raise SystemExit('empty sprite ' + label)
    x0, x1 = xs.min(), xs.max() + 1
    y0, y1 = ys.min(), ys.max() + 1
    # align x0 so that (x0-ax) is even
    if (x0 - ax) % 2:
        x0 -= 1
    if (x1 - x0) % 2:
        x1 += 1
    h, w = img.shape
    data = []
    for y in range(y0, y1):
        for x in range(x0, x1, 2):
            m = 0
            d = 0
            for k in (0, 1):
                xx = x + k
                if 0 <= xx < w and opaque[y, xx]:
                    d |= img[y, xx] << (4 * (1 - k))
                else:
                    m |= 0xF << (4 * (1 - k))
            data += [m, d]
    wb = (x1 - x0) // 2
    oxb = (x0 - ax) // 2
    oy = y0 - ay
    emit(label, [wb, y1 - y0, oxb & 255, oy & 255] + data,
         comment or ('w=%d h=%d ox=%d oy=%d' % (wb, y1 - y0, oxb, oy)))
    return (wb, y1 - y0, oxb, oy)


def opaque_block(img, label, comment=''):
    h, w = img.shape
    assert w % 2 == 0
    data = [w // 2, h]
    for y in range(h):
        data += pack(list(img[y]))
    emit(label, data, comment)


def rle(data):
    """PackBits-like: c=0 end; 1..127 literal c bytes; 128..255 run of (c-126) copies."""
    res = []
    i = 0
    n = len(data)
    lit = []
    while i < n:
        j = i
        while j < n and data[j] == data[i] and j - i < 129:
            j += 1
        run = j - i
        if run >= 3:
            while lit:
                res += [min(len(lit), 127)] + lit[:127]
                lit = lit[127:]
            res += [126 + run, data[i]]
            i = j
        else:
            lit.append(data[i])
            i += 1
    while lit:
        res += [min(len(lit), 127)] + lit[:127]
        lit = lit[127:]
    res.append(0)
    return res


def screen_bytes(a, y0, y1):
    b = []
    for y in range(y0, y1):
        b += pack(list(a[y]))
    return b


# ---------------- player ----------------
CW, CH = 20, 37
player_frames = []
for i in range(8):
    player_frames.append((1 + 21 * i, 1))
for j in range(5):
    player_frames.append((1 + 21 * j, 39))
pinfo = []
for n, (cx, cy) in enumerate(player_frames):
    cell = SP[cy:cy + CH, cx:cx + CW].copy()
    cell[cell == 1] = 0  # remove any purple frame
    op = cell != 0
    pinfo.append(masked(cell, op, 0, CH, 'spr_pr%d' % n))
out.append('spr_ptab_r: dw ' + ','.join('spr_pr%d' % n for n in range(13)))
# the left-facing frames are made at start-up by mirroring these (mirror_player)

# ---------------- climbing knight ----------------
# The four cells on HB SP are drawn over bricks: 0/1 (black outline) for the wall
# face, 2/3 (brown outline) for when he is up against the black sky. The knight's
# teal is also the mortar colour, so pick him out by colour: white, yellow, red,
# brown and grey are his, teal and black only next to those (blue is brick).
from collections import deque


def grow8(m):
    p = np.pad(m, 1)
    g = p.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            g |= np.roll(np.roll(p, dy, 0), dx, 1)
    return g[1:-1, 1:-1]


def components8(m):
    seen = np.zeros(m.shape, bool)
    comps = []
    for y0, x0 in zip(*np.nonzero(m)):
        if seen[y0, x0]:
            continue
        comp, q = [], deque([(y0, x0)])
        seen[y0, x0] = True
        while q:
            y, x = q.popleft()
            comp.append((y, x))
            for yy in (y - 1, y, y + 1):
                for xx in (x - 1, x, x + 1):
                    if 0 <= yy < m.shape[0] and 0 <= xx < m.shape[1] and m[yy, xx] and not seen[yy, xx]:
                        seen[yy, xx] = True
                        q.append((yy, xx))
        comps.append(comp)
    return comps


def flood4(start, passable):
    """pixels reachable from start through passable (4-connected)"""
    h, w = passable.shape
    seen = start & passable
    q = deque(zip(*np.nonzero(seen)))
    while q:
        y, x = q.popleft()
        for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= yy < h and 0 <= xx < w and passable[yy, xx] and not seen[yy, xx]:
                seen[yy, xx] = True
                q.append((yy, xx))
    return seen


def knight_mask(cell):
    """Cut the knight out of a cell drawn over bricks. The bricks follow the 8x8
    brick tile, so fit its phase and treat as background: blue, black open to the
    sky, and teal only where the tile has mortar next to bricks. What can't be
    reached from the cell edge through background is his; mortar-coloured gaps with
    him on both sides are his; specks under 5 pixels go. (The old rule kept any teal
    within 2 pixels of him, so he carried bits of mortar up the wall.)"""
    h, w = cell.shape
    best = None
    for dy in range(8):
        for dx in range(8):
            exp = T[(np.arange(h)[:, None] + dy) & 7, (np.arange(w)[None, :] + dx) & 7]
            sc = (cell == exp)[np.isin(cell, [2, 3])].mean()
            if best is None or sc > best[0]:
                best = (sc, exp)
    exp = best[1]
    edge = np.zeros((h, w), bool)
    edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
    sky = flood4(edge & (cell == 0), cell == 0)
    mortar = (cell == 3) & (exp == 3) & grow8(grow8(cell == 2))
    him = ~flood4(edge, (cell == 2) | sky | mortar)
    p = np.pad(him, 1)
    him |= (cell == 3) & ((p[1:-1, :-2] & p[1:-1, 2:]) | (p[:-2, 1:-1] & p[2:, 1:-1]))
    keep = np.zeros(him.shape, bool)
    for comp in components8(him):
        if len(comp) >= 5:
            for y, x in comp:
                keep[y, x] = True
    return keep


for k in range(4):
    cx, cy = 169 + 17 * k, 1
    cell = SP[cy:cy + 22, cx:cx + 16].copy()
    op = knight_mask(cell)
    masked(cell, op, 0, 0, 'spr_kc%d' % k)
out.append('spr_kctab: dw ' + ','.join('spr_kc%d' % k for k in range(4)))

# ---------------- misc sprites (0 = transparent) ----------------
def simple(x0, y0, x1, y1, label, ax=None, ay=None, flip=False):
    cell = SP[y0:y1 + 1, x0:x1 + 1].copy()
    if flip:
        cell = cell[:, ::-1].copy()
    cell[cell == 1] = 0
    op = cell != 0
    return masked(cell, op, 0 if ax is None else ax, 0 if ay is None else ay, label)


simple(169, 24, 184, 39, 'spr_bell')
simple(186, 24, 203, 39, 'spr_ksword')
simple(205, 24, 229, 39, 'spr_klunge')     # lunge with sword flash (arcade knight frame 8)
simple(161, 50, 176, 58, 'spr_heart')
# the fireball's three frames, mirrored: it flies right to left with the sparks behind
for k, x in enumerate((178, 191, 204)):
    simple(x, 50, x + 11, 58, 'spr_fb%d' % k, flip=True)
out.append('spr_fbtab: dw spr_fb0,spr_fb1,spr_fb2,spr_fb1')
simple(165, 60, 176, 62, 'spr_arrow')             # arcade arrows fly left to right (head on the right)
simple(165, 60, 176, 62, 'spr_arrowl', flip=True)  # belfry: arrows from the right too
simple(237, 1, 254, 28, 'spr_guard0', 0, 28)      # anchor = feet line
simple(237, 30, 254, 70, 'spr_guard1', 0, 41)
# colour 2 is the wall's own colour, changed screen by screen (Century's original
# board); the two blue pixels of the lives icon use colour 6, a fixed copy of the blue
_l = SP[66:74, 106:114]
_l[_l == 2] = 6
simple(106, 66, 113, 73, 'spr_life')

# fire tiles 8x8 opaque, 6 frames
fire = []
for k in range(6):
    x = 106 + 9 * k
    fire += pack(list(SP[39:47, x:x + 8].flatten()))
emit('gfx_fire', fire, '6 tiles 4x8 bytes')

# brick row patterns: 8 rows x 4 bytes, phase for screen X
br = []
for r in range(8):
    Y = r  # row index = Y & 7
    row = [brick(X, Y) for X in range(8)]
    br += pack(row)
emit('gfx_brick', br, 'brick pattern rows (y&7) x 4 bytes')

# castle progress (HUD) opaque 64x16
opaque_block(SP[67:83, 169:233], 'gfx_castle', '32x16')

# ground strip 256x22 (rows 154..175), 0 = transparent ; RLE coded
g = SP[170:192, 0:256]
emit('gfx_ground', rle(screen_bytes(g, 0, 22)), 'RLE ground strip 22 rows')

# top bands: rows 0..88 from mockups with sprites erased
band = MU15[0:89].copy()
band[60:89, 50:80] = 0      # player
band[70:89, 168:192] = 0    # fireball
_t = band[0:32]
_t[_t == 2] = 6             # SUPER BONUS shading: fixed blue (colour 2 follows the wall)
emit('gfx_band1', rle(screen_bytes(band, 0, 89)), 'RLE top band (rampart)')
band5 = MU5[0:89].copy()
# erase guards' pike tips above wall (x 60..200) in rows 80..88
for x0 in (55, 110, 165):
    band5[70:89, x0:x0 + 35] = 0
_t = band5[0:32]
_t[_t == 2] = 6
emit('gfx_band5', rle(screen_bytes(band5, 0, 89)), 'RLE top band (tower)')
# tower base ledge rows 89..96 x 196..243
opaque_block(MU5[89:97, 196:244], 'gfx_towerbase', '24x8')

# font: 1bpp, 7 rows per glyph. chars: A..Z (F synthesised) 0..9 . ? ! , * # %
glyphs = {}
letters = 'ABCDEGHIJKLMNOPQRSTUVWXYZ'
for i, ch in enumerate(letters):
    glyphs[ch] = SP[161:168, 8 * i:8 * i + 8]
for i, ch in enumerate('.?~,*#%'):
    glyphs[ch] = SP[161:168, 200 + 8 * i:208 + 8 * i]
for i in range(7):
    glyphs[str(i)] = SP[141:148, 200 + 8 * i:208 + 8 * i]
for i, ch in enumerate('789!'):
    glyphs[ch] = SP[149:156, 200 + 8 * i:208 + 8 * i]
f = glyphs['E'].copy()
f[6, :] = 0
f[6, 1:3] = 15
glyphs['F'] = f
glyphs[' '] = np.zeros((7, 8), int)
glyphs['-'] = np.zeros((7, 8), int)
glyphs['-'][3, 1:7] = 15
order = ' !#%*,-.0123456789?ABCDEFGHIJKLMNOPQRSTUVWXYZ'
# map ascii 32..90 -> index ; table built here
fontdata = []
idxmap = [0] * 59
for i, ch in enumerate(order):
    g = glyphs[ch]
    for r in range(7):
        v = 0
        for x in range(8):
            if g[r, x] == 15:
                v |= 0x80 >> x
        fontdata.append(v)
    idxmap[ord(ch) - 32] = i
emit('gfx_font', fontdata, '1bpp 7 rows/glyph')
emit('gfx_fontmap', idxmap, 'ascii-32 -> glyph index')

# rope tables: length 76, 13 magnitudes up to 50 degrees (table 0 = straight:
# the four short ropes hang still as in the arcade). The long rope swings from a
# pivot at the top of the screen through rope_phase (50 steps).
import math
ROPE_L, NMAG, TMAX = 76, 13, math.radians(50)
labels = []
for m in range(NMAG):
    th = TMAX * m / (NMAG - 1)
    n = int(round(ROPE_L * math.cos(th)))
    dx = [int(round(y * math.tan(th))) for y in range(n)]
    emit('rope_m%d' % m, [n] + dx)
    labels.append('rope_m%d' % m)
emit('rope_lng', [152] + [0] * 152)   # the belfry's two long straight bell ropes
out.append('rope_tab: dw ' + ','.join(labels) + ',rope_lng')
P = 50
ph = []
for t in range(P):
    s = math.sin(2 * math.pi * t / P)
    c = math.cos(2 * math.pi * t / P)
    m = int(round(abs(s) * (NMAG - 1)))
    ph.append(m | (0x80 if s < 0 else 0) | (0x40 if c > 0 else 0))
emit('rope_phase', ph, 'bits0-3 magnitude, bit7 left of pivot, bit6 moving right')
# the SCORE box: the border drawn on Image1.mgt (inside its purple reference outline),
# 53x32, colours 5 and 11; a blank column on the right makes it 54 wide
BOX_ART = '''
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
b...................................................b
b.5555555555555555555555555555555555555555555555555.b
b.55.............................................55.b
b.5.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.b...........................................b.5.b
b.5.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.5.b
b.55.............................................55.b
b.5555555555555555555555555555555555555555555555555.b
b...................................................b
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
'''
_bx = np.array([[0 if ch == '.' else int(ch, 16) for ch in r + '.'] for r in BOX_ART.split()], np.uint8)
opaque_block(_bx, 'gfx_box', 'SCORE box 54x32 (Image1.mgt)')

# title figures cut from HB Main (opaque blocks; the attract screen moves them
# around the logo). Quasimodo's greens use the logo colour 10, so they are moved
# to palette entry 6 (same green) and the logo can flash on its own.
tq = MAIN[102:141, 66:100].copy()
tq[tq == 10] = 6
opaque_block(tq, 'gfx_tq', 'title Quasimodo 34x39')
opaque_block(MAIN[22:46, 92:108].copy(), 'gfx_te', 'title Esmeralda 16x24')

# palettes (16 entries)
_pg = list(PAL)
_pg[6] = _pg[2]             # colour 6 (unused on the mockups): fixed copy of the wall blue
emit('pal_game', _pg, 'from HB MU1.5 (colour 6 = fixed blue; colour 2 set per screen)')
emit('pal_main', list(PALMAIN), 'title (HB Main)')

open(sys.argv[2], 'w').write('; generated by mkgfx.py - do not edit\n' + '\n'.join(out) + '\n')
ovlpath = os.path.join(os.path.dirname(os.path.abspath(sys.argv[2])), 'gfx_ovl.asm')
open(ovlpath, 'w').write('; generated by mkgfx.py - do not edit (overlay area)\n' + '\n'.join(ovl) + '\n')
# the title picture (HB Main, 24K of mode 4 pixels): build.py puts it in the game
# file at 65536, so BASIC only has to load the loading screen and the game
_tp = MAIN.astype(np.uint8)
open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[2])), 'title.bin'), 'wb').write(((_tp[:, 0::2] << 4) | _tp[:, 1::2]).tobytes())
tot = sum(sizes.values())
print('gfx bytes', tot)
for k, v in sizes.items():
    if v > 400:
        print('  %-14s %5d' % (k, v))
