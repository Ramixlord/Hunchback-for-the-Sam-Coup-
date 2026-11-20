import os, ctypes, numpy as np
from PIL import Image
E = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'samemu.so'))
E.get_ram.restype = ctypes.POINTER(ctypes.c_uint8)
E.get_clut.restype = ctypes.POINTER(ctypes.c_uint8)
E.reset(); ram = E.get_ram()
img = open('hbgame.bin', 'rb').read()
for i, b in enumerate(img): ram[2 * 16384 + i] = b
E.set_paging(0x1F, 2, 0x6E); E.set_pc_sp(0x8000, 0x7FF0)
def rgb(v):
    br = (v >> 3) & 1; f = lambda hi, lo: min(255, ((hi << 1) | lo) * 73 + br * 36)
    return (f((v >> 5) & 1, (v >> 1) & 1), f((v >> 6) & 1, (v >> 2) & 1), f((v >> 4) & 1, v & 1))
def grab():
    v = E.get_vmpr() & 31
    scr = np.frombuffer(bytes(ram[v * 16384:v * 16384 + 24576]), np.uint8).reshape(192, 128)
    a = np.zeros((192, 256), np.uint8); a[:, 0::2] = scr >> 4; a[:, 1::2] = scr & 15
    clut = E.get_clut(); pal = np.array([rgb(clut[i]) for i in range(16)], np.uint8)
    return pal[a]
shots = []
for f in range(2400):
    E.run_frame()
    if f >= 600 and f % 12 == 0:
        s = grab()
        if (s[60:176, 0:40] == (255, 255, 255)).all(-1).sum() > 10:   # white tunic on the left
            shots.append(s[60:176, 0:40])
print(len(shots), 'frames with the knight')
sel = shots[::max(1, len(shots) // 12)][:12]
Image.fromarray(np.concatenate(sel, 1)).resize((40 * len(sel) * 4, 116 * 4), Image.NEAREST).save('knight_demo.png')
picks = [shots[i] for i in (5, 15, 25, 35, 45)]
crops = []
for s in picks:
    m = (s == (255, 255, 255)).all(-1)
    ys, xs = np.nonzero(m); cy = int(ys.mean())
    y0 = max(0, cy - 20); crops.append(s[y0:y0 + 36, 0:36])
Image.fromarray(np.concatenate(crops, 1)).resize((36 * 5 * 7, 36 * 7), Image.NEAREST).save('knight_zoom.png')
