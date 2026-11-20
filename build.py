#!/usr/bin/env python3
"""Build Hunchback.mgt from the original graphics disk.

    python3 build.py path/to/HunchbackFN.mgt  [out.mgt]

Needs Python 3 with numpy.  Steps: cut graphics -> assemble -> write disk.
"""
import os, sys, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'tools'))
from z80asm import assemble_file

src_disk = os.path.abspath(sys.argv[1])
out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'Hunchback.mgt'))
S = os.path.join(HERE, 'src')
subprocess.check_call([sys.executable, os.path.join(HERE, 'tools', 'mkgfx.py'), src_disk, os.path.join(S, 'gfx.asm')],
                      stdout=subprocess.DEVNULL)
m = assemble_file(os.path.join(S, 'hunchback.asm'))
mainlen = m.symbols['varstart']
open(os.path.join(S, 'stub_cfg.asm'), 'w').write('MAINLEN equ %d\n include "stub.asm"\n' % mainlen)
st = assemble_file(os.path.join(S, 'stub_cfg.asm'))
img = st.image(0x8000, st.symbols['mainimg']) + m.image(0, mainlen)
# E000h onwards of the load page carries the attract/intro code (src/attract.asm)
# and the sound data (src/snd_data.bin, from tools/arcade_sound/mksnd.py); the
# game copies that 8K above every screen buffer at start-up
ovl0 = m.symbols['OVLBASE']
ovl = m.image(ovl0, m.symbols['ovlend'])
snd = open(os.path.join(S, 'snd_data.bin'), 'rb').read()
assert len(img) <= ovl0 - 0x8000 and len(snd) <= m.symbols['SNDLEN']
img += bytes(ovl0 - 0x8000 - len(img)) + ovl
img += bytes(m.symbols['SNDBASE'] - 0x8000 - len(img)) + snd
# the title picture (src/title.bin, cut by mkgfx.py) at 65536, the page after the
# code's two: the stub finds it there
assert len(img) <= 0x8000
img += bytes(0x8000 - len(img)) + open(os.path.join(S, 'title.bin'), 'rb').read()
binp = os.path.join(HERE, 'hbgame.bin')
open(binp, 'wb').write(img)
subprocess.check_call([sys.executable, os.path.join(HERE, 'tools', 'mkdisk.py'), src_disk, binp, out])
print('game code %d bytes; disk written to %s' % (len(img), out))
