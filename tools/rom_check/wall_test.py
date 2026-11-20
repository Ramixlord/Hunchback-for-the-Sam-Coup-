import os, ctypes, sys
sys.path.insert(0, 'tools')
from z80asm import assemble_file
S = assemble_file('src/hunchback.asm').symbols
E = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'samemu.so'))
E.get_ram.restype = ctypes.POINTER(ctypes.c_uint8)
E.get_clut.restype = ctypes.POINTER(ctypes.c_uint8)
E.reset()
ram = E.get_ram()
img = open('hbgame.bin', 'rb').read()
for i, b in enumerate(img):            # BASIC loads it at 32768 = page 2 onwards
    ram[2 * 16384 + i] = b
E.set_paging(0x1F, 2, 0x6E)           # ROM0 in A, page 2 in C (as after LOAD)
E.set_pc_sp(0x8000, 0x7FF0)
for f in range(150):
    E.run_frame()
K = E.get_lmpr() & 31
print('booted: code page', K, 'pc %04x' % E.get_pc(), 'bad pc', E.get_bad_pc())
def addr(a):  # code-space address -> ram offset
    return K * 16384 + a
stub = 0x7F00
code = [0xCD, S['setup_level'] & 255, S['setup_level'] >> 8, 0x18, 0xFE]
for i, b in enumerate(code):
    ram[addr(stub) + i] = b
clut = E.get_clut()
for rnd in (0, 1, 2):
    for lvl in range(16):
        ram[addr(S['level'])] = lvl
        ram[addr(S['round'])] = rnd
        E.set_pc_sp(stub, S['stacktop'])
        for f in range(3):
            E.run_frame()
            if E.get_pc() in (stub + 3, stub + 4): break
        bu = [ram[addr(S['bunit']) + k] for k in range(6)]
        scr = int(''.join(map(str, bu))) // 100
        print('round %d level %2d -> screen %2d  wall clut %3d  pal_game[2] %3d  pc %04x' %
              (rnd, lvl + 1, scr, clut[2], ram[addr(S['pal_game'] + 2)], E.get_pc()))

# draw whole screens: setup_level, build_both, SCORE box, then render the shown buffer
import numpy as np
from PIL import Image
def rgb(v):
    br = (v >> 3) & 1
    f = lambda hi, lo: min(255, ((hi << 1) | lo) * 73 + br * 36)
    return (f((v >> 5) & 1, (v >> 1) & 1), f((v >> 6) & 1, (v >> 2) & 1), f((v >> 4) & 1, v & 1))
shots = []
for rnd, lvl in ((0, 0), (0, 4), (0, 10), (0, 13)):
    code = [0xCD, S['setup_level'] & 255, S['setup_level'] >> 8,
            0xCD, S['build_both'] & 255, S['build_both'] >> 8,
            0xCD, S['box_draw'] & 255, S['box_draw'] >> 8, 0x18, 0xFE]
    for i, b in enumerate(code):
        ram[addr(stub) + i] = b
    ram[addr(S['level'])] = lvl
    ram[addr(S['round'])] = rnd
    E.set_pc_sp(stub, S['stacktop'])
    for f in range(40):
        E.run_frame()
        if E.get_pc() in (stub + 9, stub + 10): break
    v = E.get_vmpr() & 31
    hp = E.get_hmpr() & 31
    print('level', lvl + 1, 'pc %04x' % E.get_pc(), 'vmpr page', v, 'hmpr page', hp)
    scr = np.frombuffer(bytes(ram[hp * 16384:hp * 16384 + 24576]), np.uint8).reshape(192, 128)
    a = np.zeros((192, 256), np.uint8); a[:, 0::2] = scr >> 4; a[:, 1::2] = scr & 15
    pal = np.array([rgb(clut[i]) for i in range(16)], np.uint8)
    shots.append(pal[a])
Image.fromarray(np.concatenate([np.concatenate(shots[:2], 1), np.concatenate(shots[2:], 1)], 0)).resize((1024, 768), Image.NEAREST).save('walls.png')
