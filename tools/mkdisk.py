#!/usr/bin/env python3
"""Build the bootable Hunchback .mgt from the original disk image.

- keeps MasterDOS (mdos21) and all the original screens, as files 1 and 3-10
- file 2 'auto': the Lightning Studios intro's BASIC loader (from the Moon
  Cresta disk) with its last lines changed to load Hunchback:
      1 MODE 4: FOR P=0 TO 15: PALETTE P,0: NEXT P
      2 LOAD "LghtStuds" CODE 32768: CALL 32768     (Lightning Studios logo + intro)
      5 MODE 4: BORDER 0: PALETTE 0,0: ... PALETTE 15,127: CLS   (HB LS 2's colours)
     10 CLEAR 32767: LOAD 3: LOAD n                 (loading screen, then the game)
     20 CALL 32768
  The loading screen stays on show while the game loads; the game file carries
  the title picture (at 65536), so nothing else is loaded on to the screen.
- file n 'HBGAME' (CODE, 32768, auto-execute 32768) and then 'LghtStuds' (the
  intro, CODE 32768), in the first two free slots: 11 and 12 normally, 12 and 13
  on a disk that also has 'Image1' as file 11
"""
import sys
from intro_loader import make_auto, intro_file

# usage: mkdisk.py <original HunchbackFN.mgt> <hbgame.bin> <out.mgt>
SRC, GAME, OUT = sys.argv[1], sys.argv[2], sys.argv[3]

d = bytearray(open(SRC, 'rb').read())
assert len(d) == 819200


def off(t, s):
    side = 1 if t >= 128 else 0
    return (((t & 127) * 2 + side) * 10 + (s - 1)) * 512


def entry_off(i):
    t = i // 20
    s = (i % 20) // 2 + 1
    return off(t, s) + (i % 2) * 256


def bit_to_ts(k):
    t = 4 + k // 10
    if t >= 80:
        t = 128 + (t - 80)
    return t, k % 10 + 1


def used_sectors():
    used = set()
    for i in range(80):
        eo = entry_off(i)
        if d[eo] == 0:
            continue
        mp = d[eo + 15:eo + 210]
        for k in range(195 * 8):
            if mp[k // 8] >> (k % 8) & 1:
                used.add(k)
    return used


def add_file(slot, ent, payload):
    """write payload (header + data) into free sectors; directory entry from ent
    (name, type and the header fields at 210-255) with the new sector chain"""
    assert d[entry_off(slot)] == 0, slot
    nsec = (len(payload) + 509) // 510
    used = used_sectors()
    alloc = [k for k in range(1560) if k not in used][:nsec]
    assert len(alloc) == nsec
    for n, k in enumerate(alloc):
        o = off(*bit_to_ts(k))
        chunk = payload[n * 510:(n + 1) * 510]
        sec = bytearray(512)
        sec[:len(chunk)] = chunk
        if n + 1 < nsec:
            sec[510], sec[511] = bit_to_ts(alloc[n + 1])
        d[o:o + 512] = sec
    e = bytearray(ent)
    e[11], e[12] = nsec >> 8, nsec & 255
    e[13], e[14] = bit_to_ts(alloc[0])
    mp = bytearray(195)
    for k in alloc:
        mp[k // 8] |= 1 << (k % 8)
    e[15:210] = mp
    d[entry_off(slot):entry_off(slot) + 256] = e
    return nsec, bit_to_ts(alloc[0])


# ---------------- file 2: the new 'auto' loader ----------------
eo = entry_off(1)
assert d[eo] == 16 and d[eo + 1:eo + 11] == b'auto      '
# the loading screen's colours, for line 5
ls = entry_off(2)
assert d[ls + 1:ls + 11] == b'HB LS 2   '
t, s = d[ls + 13], d[ls + 14]
hdr_ls = bytes(d[off(t, s):off(t, s) + 9])
data = b''
n = d[ls + 11] * 256 + d[ls + 12]
for _ in range(n):
    sec = d[off(t, s):off(t, s) + 512]
    data += bytes(sec[:510])
    t, s = sec[510], sec[511]
palette = list(data[9 + 24576:9 + 24576 + 16])
d[eo:eo + 256] = bytes(256)                 # free the old one
# the game and the intro go in the first two free directory slots (11 and 12 on
# the usual disk; later if the disk has extra files, e.g. 'Image1')
free = [i for i in range(80) if i != 1 and d[entry_off(i)] == 0][:2]
gslot, islot = free
ent, dat = make_auto(palette, gslot + 1)
add_file(1, ent, dat)

# ---------------- the game ----------------
game = open(GAME, 'rb').read()
L = len(game)
start = 32768
page, offs = start // 16384 - 1, 0x8000 + start % 16384
hdr = bytes([19, (L % 16384) & 255, (L % 16384) >> 8, offs & 255, offs >> 8, 0xFF, 0xFF, L // 16384, 0x60 | page])
tmpl = bytearray(d[entry_off(0):entry_off(0) + 256])   # the mdos21 CODE entry layout
ent = bytearray(256)
ent[0] = 19
ent[1:11] = b'HBGAME    '
ent[210:256] = tmpl[210:256]
ent[211:220] = hdr
ent[236] = 0x60 | page
ent[237], ent[238] = offs & 255, offs >> 8
ent[239] = L // 16384
ent[240], ent[241] = (L % 16384) & 255, (L % 16384) >> 8
ent[242] = page                 # auto-execute address: page 1 ...
ent[243], ent[244] = 0x00, 0x80  # ... offset 8000h  => 32768
nsec, ts0 = add_file(gslot, ent, hdr + game)

# ---------------- the Lightning Studios intro ----------------
ient, idat = intro_file()
add_file(islot, ient, idat)

open(OUT, 'wb').write(d)
print('wrote', OUT, 'game (file %d)' % (gslot + 1), L, 'bytes in', nsec, 'sectors from', ts0, '+ intro')
