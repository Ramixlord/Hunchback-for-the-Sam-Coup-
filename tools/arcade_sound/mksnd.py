#!/usr/bin/env python3
"""Regenerate the SAM sound data from the arcade Hunchback sound CPU ROM.

    python3 mksnd.py path/to/hunchbkd.zip  OUTDIR

Builds i8035.c (an MCS-48 emulator of the Donkey Kong-style sound board),
plays each sound command the arcade main CPU sends and measures the pitch
and volume of the DAC output every 1/50 s. For the tunes and notes the tone
at the middle of each 1/50 s is taken, so every note starts on the nearest
frame and decays cleanly, with no burst of the new note's volume at the old
note's pitch just before it and writes OUTDIR/snd_data.bin
(runs of amp<<4|noise<<3|octave, note, frames) and OUTDIR/snd_tab.inc.
Needs gcc and numpy.
"""
import os, sys, subprocess, zipfile, ctypes, tempfile
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
zp, outdir = sys.argv[1], sys.argv[2]
rom = zipfile.ZipFile(zp).read('hb.3h')
so = os.path.join(tempfile.mkdtemp(), 'libi8035.so')
subprocess.check_call(['gcc', '-O2', '-shared', '-fPIC', '-Wl,-Bsymbolic', '-o', so, os.path.join(HERE, 'i8035.c')])
S = ctypes.CDLL(so)
S.get_dac_t.restype = ctypes.POINTER(ctypes.c_uint32)
for f in ('get_dac_v', 'get_rom'): getattr(S, f).restype = ctypes.POINTER(ctypes.c_uint8)
S.get_cyc.restype = ctypes.c_longlong
CPS = 400000            # 6 MHz / 15
FR = CPS // 50          # one SAM frame
mem = np.ctypeslib.as_array(S.get_rom(), shape=(4096,))
mem[:2048] = np.frombuffer(rom, np.uint8); mem[2048:] = mem[:2048]

def capture(seq, secs):
    """seq = [(time_s, command)]; returns DAC write times (cycles) and values"""
    S.reset(); S.set_latch(0xff); S.run(CPS // 10)
    S.clear_dac(); c0 = S.get_cyc(); now = 0
    for ts, c in seq:
        tc = int(ts * CPS); S.run(tc - now); now = tc
        S.set_latch(0xf0 | c); S.set_irq(1)
    S.run(int(secs * CPS) - now)
    n = S.get_dac_n()
    t = np.ctypeslib.as_array(S.get_dac_t(), shape=(1 << 22,))[:n].astype(np.int64) - c0
    v = np.ctypeslib.as_array(S.get_dac_v(), shape=(1 << 22,))[:n].copy()
    return t, v

def frames_edges(t, v, limit=None):
    end = int(t[-1] // FR) + 1 if len(t) else 0
    if limit: end = min(end, limit)
    out = []
    for k in range(end):
        a, b = k * FR, (k + 1) * FR
        i0, i1 = np.searchsorted(t, a), np.searchsorted(t, b)
        prev = v[i0 - 1] if i0 > 0 else 0
        seq = np.concatenate([[prev], v[i0:i1]]); tt = np.concatenate([[a], t[i0:i1]])
        rise = tt[1:][(seq[:-1] == 0) & (seq[1:] > 0)]       # square waves: count rising edges
        f = CPS / np.median(np.diff(rise)) if len(rise) >= 2 else (out[-1][1] if out else 0)
        out.append((int(seq.max()), f))
    return out

def frames(t, v, limit=None):
    """per frame: the tone playing at the frame's midpoint, so a note starts on the
    nearest frame boundary and the frame before it isn't given the new note's
    volume at the old pitch. Volume: the highest pulse of that note in the frame;
    pitch: the median period of the rising edges round the midpoint."""
    v = v.astype(int)
    rise = np.array([i for i in range(1, len(v)) if v[i - 1] == 0 and v[i] > 0])
    if len(rise) < 3: return frames_edges(t, v, limit)
    rt = t[rise]; ra = v[rise]
    per = np.diff(rt)
    # a new note: the pulse height jumps up (the arcade restarts its decay)
    newn = np.concatenate([[True], ra[1:] > ra[:-1] + 24])
    nid = np.cumsum(newn) - 1
    end = int(t[-1] // FR) + 1
    if limit: end = min(end, limit)
    out = []
    for k in range(end):
        a, b, tm = k * FR, (k + 1) * FR, (k + 0.5) * FR
        j = np.searchsorted(rt, tm, side='right') - 1     # last rising edge before the midpoint
        if j < 0:
            out.append((0, 0)); continue
        i0, i1 = np.searchsorted(rt, a), np.searchsorted(rt, b)
        same = [i for i in range(i0, i1) if nid[i] == nid[j]]
        amp = max([ra[i] for i in same] + [ra[j]])
        w = per[max(0, j - 2):j + 2]
        p = np.median(w) if len(w) else 0
        if not p or tm - rt[j] > 2.5 * p or CPS / p < 32:  # note over (or no tone)
            out.append((0, 0)); continue
        out.append((int(amp), CPS / p))
    return out

def saa_note(f):
    best = None
    for o in range(8):
        n = 511 - 15625 * 2 ** o / f
        if 0 <= n <= 255.4:
            n = int(round(min(n, 255))); e = abs(15625 * 2 ** o / (511 - n) - f) / f
            if best is None or e < best[0]: best = (e, o, n)
    return best[1], best[2]

def encode(fr):
    runs = []
    for amp, f in fr:
        a = int(round(amp / 255 * 15))
        r = (0, 0, 0) if (a == 0 or f <= 0) else (a,) + saa_note(f)
        if runs and runs[-1][0] == r and runs[-1][1] < 255: runs[-1][1] += 1
        else: runs.append([r, 1])
    b = []
    for (a, o, n), cnt in runs: b += [(a << 4) | o, n, cnt]
    return b + [0, 0, 0]

one = lambda c, limit=None: frames_edges(*capture([(0, c)], 4), limit)   # effects
tune = lambda c, limit=None: frames(*capture([(0, c)], 4), limit)        # notes and tunes
SOUNDS = [
    ('bell', tune(5)),                   # bell rung: ding-dong
    ('step', one(7)),                    # footstep while walking
    ('jump', one(8)),
    ('fall', one(9)),                    # falling (pit, gap, or off the wall after a hit)
    ('hiss', None),                      # fire pit (noise)
    ('launch', one(11)),                 # fireball / arrow launched
    ('start', tune(12)),                 # start tune, played to the end (2.9 s)
    ('hit', one(13)),                    # hit by a missile or pike
    ('land', one(14)),                   # thud at the bottom / knight's kill
    ('fanfare', frames(*capture([(0, 1), (11 / 60, 2), (22 / 60, 3), (33 / 60, 4), (44 / 60, 4)], 3))),  # five bells
    ('extra', tune(6)),                  # bonus man (extra life)
    ('note1', tune(1)),                  # rope grabbed: four-rope screens play note 1-4 for rope 1-4,
    ('note2', tune(2)),                  #   the single swinging rope plays note 3
    ('note3', tune(3)),
    ('note4', tune(4)),
    ('coin', one(0)),                    # coin in (SAM: start key pressed)
]
data, tab = [], []
for name, fr in SOUNDS:
    tab.append((name, len(data)))
    # the arcade hiss is DAC noise at 8 kHz and level 31/255: SAA noise at amplitude 2, ~10 s
    data += [(2 << 4) | 8, 0, 255, (2 << 4) | 8, 0, 255, 0, 0, 0] if fr is None else encode(fr)
lines = ['; generated by tools/arcade_sound/mksnd.py from the arcade sound CPU ROM (hb.3h)',
         '; run = amp<<4 | noise<<3 | octave, note, frames (50 Hz); 0,0,0 ends']
lines += ['SND_%s equ %d' % (n.upper(), i) for i, (n, _) in enumerate(tab)]
lines += ['snd_offs:'] + ['        dw SNDBASE+%d' % off for _, off in tab]
open(os.path.join(outdir, 'snd_tab.inc'), 'w').write('\n'.join(lines) + '\n')
open(os.path.join(outdir, 'snd_data.bin'), 'wb').write(bytes(data))
print('%d bytes of sound data' % len(data))
