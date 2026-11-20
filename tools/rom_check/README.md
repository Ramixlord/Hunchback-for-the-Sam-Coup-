# Checking tools

Run these from the top folder of the repository, after `python3 build.py path/to/HunchbackFN.mgt`
(they use `hbgame.bin` and the bundled SAM emulator core).

```
gcc -O2 -shared -fPIC -o tools/rom_check/samemu.so tools/samemu.c
```

| Script | What it does |
|---|---|
| `dis2650.py ROMDIR [start end]` | Signetics 2650 disassembler for the arcade ROMs (`hunchbkd` layout: hb.5e, hbsc-1.5c, hb.5b, hb.5a). Used to check the bells, the palette writes and the wall colours. |
| `wall_test.py` | Runs `setup_level` for every screen and round in the emulator and prints the screen number, wall colour and bonus; saves `walls.png`. |
| `demo_knight.py` | Runs the attract demo and saves close-ups of the climbing knight. |
| `knight_mask.py path/to/HunchbackFN.mgt` | Shows the old and new cut-outs of the knight's climbing frames (`kmask.png`). |
