"""The Lightning Studios intro in front of Hunchback (from the Moon Cresta disk).

The intro's own BASIC loader (src/intro/auto.dat, from MoonCrestaLS3.mgt) runs
    1 MODE 4: FOR P=0 TO 15: PALETTE P,0: NEXT P
    2 LOAD "LghtStuds" CODE 32768: CALL 32768          (the logo and intro)
Lines 5, 10 and 20 load Moon Cresta; they are rewritten, in the same number of
bytes so the file's header stays right, to load Hunchback instead:
    5 MODE 4: BORDER 0: PALETTE n,v ...: CLS          (HB LS 2's colours)
   10 CLEAR 32767: LOAD 3: LOAD 11                     (loading screen, game)
   20 CALL 32768: REM ...
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
INTRO = os.path.join(HERE, '..', 'src', 'intro')
LOAD, CLEAR, CALL, REM = 0x95, 0xB3, 0xE4, 0xB7


def num(v, text=None):
    text = text or str(v)
    return text.encode() + bytes([0x0E, 0, 0, v & 255, v >> 8, 0])


def line(n, body):
    body = body + b'\x0d'
    return bytes([n >> 8, n & 255, len(body) & 255, len(body) >> 8]) + body


def lines(prog):
    out, i = [], 0
    while prog[i] != 0xFF:
        ln = prog[i] * 256 + prog[i + 1]
        ll = prog[i + 2] + 256 * prog[i + 3]
        out.append((ln, i, 4 + ll))
        i += 4 + ll
    return out, i


def make_auto(palette, game=11):
    """-> (directory entry, file data) of the new 'auto' program"""
    ent = bytearray(open(os.path.join(INTRO, 'auto.ent'), 'rb').read())
    dat = bytearray(open(os.path.join(INTRO, 'auto.dat'), 'rb').read())
    prog = dat[9:]
    ls, end = lines(prog)
    pos = {ln: (i, n) for ln, i, n in ls}
    assert [ln for ln, _, _ in ls] == [1, 2, 5, 10, 20]
    i5 = pos[5][0]
    old = prog[i5 + 4:i5 + pos[5][1] - 1]               # line 5 body
    # line 5 is MODE 4:BORDER 0:PALETTE 0,v:...:PALETTE 15,v:CLS:OUT 248,v:...:OUT 4088,v
    MODE, BORDER, PALETTE, CLS, OUT = 0xAA, 0x9E, 0xA0, 0x9F, 0xE0
    assert old[0] == MODE and old[9] == BORDER and old[18] == PALETTE and CLS in old and OUT in old
    C = b':'
    b5 = bytes([MODE]) + num(4) + C + bytes([BORDER]) + num(0)
    for n, v in enumerate(palette):
        b5 += C + bytes([PALETTE]) + num(n) + b',' + num(v)
    b5 += C + bytes([CLS])          # (PALETTE sets the colours at once: no OUTs needed)
    new = line(5, b5)
    # CLEAR also clears the screen (as on the Spectrum), so it must come before
    # the loading screen is loaded, or the picture is wiped as soon as it is in
    new += line(10, bytes([CLEAR]) + num(32767) + C + bytes([LOAD]) + num(3) + C + bytes([LOAD]) + num(game))
    room = pos[5][1] + pos[10][1] + pos[20][1] - len(new)
    head = bytes([CALL]) + num(32768) + C + bytes([REM])
    pad = room - 4 - len(head) - 1
    assert pad >= 0, pad
    new += line(20, head + b' HUNCHBACK - SAM COUPE'.ljust(pad)[:pad])
    assert len(new) == pos[5][1] + pos[10][1] + pos[20][1]
    prog[i5:i5 + len(new)] = new
    dat[9:] = prog
    return bytes(ent), bytes(dat)


def intro_file():
    return (open(os.path.join(INTRO, 'LghtStuds.ent'), 'rb').read(),
            open(os.path.join(INTRO, 'LghtStuds.dat'), 'rb').read())
