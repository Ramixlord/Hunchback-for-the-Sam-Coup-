# Hunchback for the SAM Coupé (mode 4)

A Hunchback-style arcade game built from the graphics on `HunchbackFN.mgt`
(the loading screen, `HB Main` title, the five `HB MU` mockups and the `HB SP` sprite page).

## Running it

Boot `Hunchback.mgt` in SimCoupé (or on a real SAM: insert the disk and press F9).
MasterDOS loads the `auto` BASIC program, which:

```
 1 MODE 4: FOR P=0 TO 15: PALETTE P,0: NEXT P
 2 LOAD "LghtStuds" CODE 32768: CALL 32768
 5 MODE 4: BORDER 0: PALETTE 0,0: ... : PALETTE 15,127: CLS
10 CLEAR 32767: LOAD 3: LOAD 12
20 CALL 32768
```

First the Lightning Studios logo and intro (file 13 `LghtStuds`, with lines 1 and 2 of
its loader, taken from the Moon Cresta disk; `src/intro/`). Then the HB LS 2 loading
screen, with its colours set first so it shows properly as it loads. It stays on show
while the game loads, and the game starts by itself. The HB Main title picture is carried
inside the game file (at 65536), so nothing else is loaded on to the screen.
`tools/intro_loader.py` rewrites the intro loader's last three lines (in the same number of
bytes, so the file's header stays right) and `tools/mkdisk.py` writes the disk.

If it stops at the BASIC prompt instead, type `LOAD "HBGAME"`; the game starts by itself.

The game and the intro go in the first two free slots on the disk. Your HunchbackFN.mgt
has an extra screen, `Image1`, as file 11, so the game is file 12 (`HBGAME`) and the intro
is file 13. The build writes the right number into line 10.

`CLEAR` comes first on line 10 because it also clears the screen. If it came after
`LOAD 3`, it would wipe the loading screen as soon as it had loaded.

## Controls

| Action | Keys |
|---|---|
| Left | O (redefinable), cursor left, 6 (joystick) |
| Right | P (redefinable), cursor right, 7 (joystick) |
| Jump | SPACE (redefinable), cursor up, 0 or 9 (joystick) |

**Steering a jump:** hold left or right in the air to turn him that way; with neither
held he carries on as he took off. (Not when leaping off a rope, and not in the demo.)

**Main menu:** press any key on the title screen, the demo, the league table or the
instructions. The menu shows the current keys and offers:

- 1 INSERT COIN: adds a credit (up to 9) with the arcade's coin-in sound.
- 2 START GAME: uses a credit. With no credits it says INSERT A COIN FIRST.
- 3 REDEFINE KEYS.

After 30 s with nothing pressed it goes back to the title.

**Redefine keys:** choose 3 on the main menu, then press the key you want for LEFT,
RIGHT and JUMP in turn. Any key on the SAM keyboard can be used, including the function
keys, but not the same key twice. The cursor keys and joystick always work as well. The main menu
and the name registration screen show your current keys. The choice
lasts until the machine is switched off.

**Infinite lives:** type LIFE on the main menu. INFINITE LIVES appears at the bottom of
the menu (and under the high score on the title) and the extra-life tune plays. Type LIFE again to switch it off.

## Title and attract mode

As in the arcade, the title doesn't just sit there: it runs a loop until you press a
key, which brings up the main menu. The title has no key prompts on it, as in the
arcade.

1. **Title:** the HUNCH BACK logo flashes red and green. Esmeralda and Quasimodo change
   places around it every second. After about 10 s a shower of hearts appears.
2. **Demo game:** the computer plays screen 1, starting with the riverbank intro below.
   FEATURING THE BELLS slides in after 9 s of play. The demo is silent, like the arcade's.
3. **League table:** the top five scores and names, and BONUS MAN AT 10000.
4. **Player instructions.**
5. Back to the title.

**New game intro:** after the PLAYER 1 screen, Quasimodo hops right to left along the
riverbank below the castle wall, first on the tower screen (Esmeralda watching) and then
on screen 1, where he leaps up onto the rampart and play begins. The arcade scrolls the
castle past him; here the screens stay put. Only a new game has the intro, not a new life.

**Bonus man:** an extra life at 10,000 points, with the arcade's extra-life tune.

**Name registration:** a game-over score that makes the top five asks for a name of up
to 8 letters. Move along the letters with left and right (hold the key down to keep
moving: after 0.3 s it runs on at 10 letters a second), press jump to pick one, RUB to
delete and END to finish. A 16x16 box marks the chosen letter (32x16 round RUB and END) (or wait for the 30 s timer). The table lasts until you
switch the machine off. The arcade starts with 50,000 on all five lines, so a name can
only be entered after beating 50,000. Here the table starts at 50,000, 40,000, 30,000,
20,000 and 10,000, so any score of 10,000 or more gets a name.

## The game

Run along the castle wall and ring the bell at the far end before the climbing
knight reaches the top. If he gets there, he advances along the rampart after you,
raising his sword and lunging. As in the arcade, he builds wall across any gap or
fire pit in his way and walks over it. You can't jump him, so keep ahead of him
and reach the bell.
The layout, speeds and bell sequence follow the Century arcade game (measured from the `hunchbkd` ROM).

The 15 screens, in arcade order:

| | Screen | | Screen |
|---|---|---|---|
| 1 | Fireballs | 9 | Four-rope fire pit and fireballs |
| 2 | Fire pit and rope | 10 | Battlements and two arrows |
| 3 | Battlements | 11 | Battlements and two fireballs |
| 4 | Pikemen in the gaps | 12 | Pikemen and two arrows |
| 5 | Pikemen and fireballs | 13 | Pikemen and two fireballs |
| 6 | Battlements and arrows | 14 | Four-rope fire pit and two arrows |
| 7 | Fire pit and rope | 15 | Esmeralda's tower |
| 8 | Pikemen and two arrows | | |

**Wall colours (Century's original board):** the castle wall changes colour from screen to
screen, as on the original `hunchbak` board (its colour table at 0554, by screen number):

| Screens | Wall | Screens (later rounds) | Wall |
|---|---|---|---|
| 1-4 | blue | 17 | black |
| 5-8 | red | 18-20 | red |
| 9-10 | purple | 21-22 | blue |
| 11-12 | olive | 23-24 | purple |
| 13 | grey-green | 25-26 | olive |
| 14 | black (just the mortar shows) | 27-28 | grey-green |
| 15 (Esmeralda) | blue | 29-30 | black |
| | | 31 (Esmeralda) | blue |

The wall is colour 2 of the palette, set as each screen starts. The SUPER BONUS lettering, the
SCORE box figures and the lives icons use colour 6, a fixed copy of the blue. The belfry keeps
the blue (the arcade's table gives black there, but the belfry has no castle wall). The
Donkey Kong conversion (`hunchbkd`) keeps one wall colour throughout.

After Esmeralda's tower comes the belfry (below), and then the castle starts again with
faster missiles and a quicker knight.

**The belfry** (the arcade's bonus screen after Esmeralda): four floors, each with
three groups of little bells, and a bell rope hanging down each side of the tower. Walk
over a group to take it: 10 points on the bottom floor, 20, 30 and 40 on the floors
above. The two ropes go up and down against each other like a bell-pull. Jump off the
end of a floor to catch one, ride it, and press jump to step off on to a floor. Arrows
fly along your floor from either side, so jump them. Walking or stepping off where there's no floor
is a fall. A 10,000 bonus counts down by 100 a second. Take all twelve groups and the
fanfare plays, you get what's left of the bonus, and the castle starts again. Losing a
life restarts the belfry.
The layout, scoring, two-rope bell-pull and arrows follow the arcade (checked in the
`hunchbkd` ROM). The arcade's timing for the ropes and its prize for finishing were
estimated, so treat those as approximate.

**Ropes:** jump to catch a rope and press jump again to let go. On screens 2 and
7 the long rope swings from a pivot at the top of the screen (a full swing every 4 s), and
you fly on in the direction of the swing. The long rope is a little harder than the short ones:
you must be within 8 px of its end to catch it (10 px for the short ropes), and after letting
go you are in the air one jump frame less, which leaves about 0.5 s of each swing to land safely. On screens 9 and 14 the four short ropes hang still, as
in the arcade: let go while holding left to jump back, otherwise you jump right.
While he hangs on a rope Quasimodo uses the tucked frame from the sprite page (the
arcade's hanging pose is tucked up the same way), with his front hand on the rope's end.
Missiles can't hit you while you're hanging on a rope.

**Pikemen:** only cross a gap while its pike is down. Fireballs and arrows come
low (jump them) or at head height (don't jump into them).

**The bell:** touch the bell rope, walking or in mid-jump, to ring it. Quasimodo walks right
up to the rope, so his hand touches it when it rings. The rope hangs still. The bell joins the rope at the top left, your bonus is added at once
and shown in the SCORE box, and everything freezes for two seconds. Then the next
screen wipes in from the right. Five bells on the rope pay 25,000 and empty it. Losing a life empties the rope too, as in the arcade
(checked in the `hunchbkd` ROM: every death clears the bell count at 648E), so the five bells
have to come from five screens in a row without dying.
Rescuing Esmeralda pays the bell bonus (as in the arcade) while SUPER BONUS flashes.

**Missiles:** a fireball or arrow comes every 3.2 s, as in the arcade. On screens
8 and 10 to 15 a second, faster one follows 1.3 s behind it. Screen 5's fireballs come
at head height, screen 6's arrows come low, and the arrows on screens 8, 10, 12 and 14
come at either height. All other fireballs come low. No missile is launched while you're
in the last stretch before the bell. Fireballs come from the right, flickering through their three flame
frames at a steady height (no bobbing); arrows come from behind you, flying left to right and pointing the way they fly, as in the arcade.

**Losing a life:** Quasimodo freezes for just over a second, drops off the wall and
the screen pauses. Then the black PLAYER 1 screen appears and the screen scrolls back
in from the start. That's about 7.7 s in all (7.9 s in the arcade).

**Scoring (as in the arcade):**
- Bell: the bonus. It is 100 × the screen number × (10 − k), where k goes up by one every
  3.7 s from the start of the screen. That is 1,000 × the screen number for the first
  1.9 s, dropping by a tenth every 3.7 s to nothing after about 35 s. (The screen number is the
  arcade's: 1 to 15 the first time round, 16 for the belfry, then 17 to 31 for the castle
  every time after, as its counter goes from 31 back to 16.)
- Four-rope screens (9 and 14): 400 for catching the first rope, then 300, 200 and 100.
- No points for jumping fireballs or arrows, or for the single swinging rope.

**Sound:** the effects and tunes are the arcade's own, measured from its sound CPU ROM
(hb.3h) frame by frame and replayed on the SAA1099. Like the arcade board, one sound plays
at a time and a new one replaces it.
- Start tune when a new game begins, played to the end before the riverbank run starts.
- Footsteps, about 12 a second, while walking.
- Jump.
- Each fireball or arrow launch.
- A whoosh at each end of the swing while you hang on the long rope (screens 2 and 7).
- A chime note when you catch a rope: notes 1 to 4 for the four short ropes and
  note 3 for the long one.
- Bell ding-dong.
- Rising chime fanfare when the fifth bell completes the rope.
- Coin-in sound when a game is started, and the extra-life tune at 10,000.
- Losing a life: the hit, the fall sound as he drops, then a thud at the bottom.
  Falling into a gap or the pit plays the fall and the thud; the knight's kill is just the thud.

As in the arcade, there's no sound for the knight reaching the top or for game over.

**Speeds, matched to the arcade:**
- Walking: about 25 px/s.
- Jump: about 1 s in the air.
- Fireballs and arrows: about 75 px/s; the second missile about 87 px/s.
- Knight: reaches the top in 11.3 s on screen 1, shortening to about 10.3 s by screen 15.
  On top he alternates sword-raised and lunge frames every 0.9 s and steps 8 px with
  each lunge (about 4.4 px/s), laying an 8-pixel layer of wall over gaps and the pit as
  he goes. He strikes within 15 px.

## Building from source

```
python3 build.py path/to/HunchbackFN.mgt  [Hunchback.mgt]
```

Needs Python 3 and numpy. `tools/mkgfx.py` cuts the sprites straight out of the
original screens, so you can redraw anything on `HB SP` and rebuild.
The climbing knight's four frames are drawn over bricks on `HB SP`, and his armour is the
same teal as the mortar. `mkgfx.py` fits the brick pattern behind each frame and keeps only
what isn't brick or mortar, so no mortar travels up the wall with him.
`tools/z80asm.py` is the bundled two-pass Z80 assembler, and `tools/mkdisk.py` writes the disk.
`src/hunchback.asm` is the game, `src/attract.asm` the title, attract mode, name registration
and intro, and `src/stub.asm` the 72-byte relocating loader.

## Technical notes

- **Memory:** the stub copies the code (about 23K) into a free page pair, mapped into
  sections A/B with ROM0 paged out. It then uses its own IM 1 interrupt at 0038h.
- **Display:** two mode 4 screens are double-buffered through HMPR/VMPR.
  Sprites are drawn masked with save-under and restored in reverse order.
  The game runs at 25 fps, and every flip happens just after the frame interrupt, so there's no tearing.
- **Movement:** player and object x positions are on 2-pixel (byte) boundaries,
  so no pixel shifting is needed in mode 4.
- **Screens:** three mode 4 screens are used: two for double buffering and a third to
  build the next screen for the wipe.
- **Spare memory above the screens:** a mode 4 screen uses 24K of its 32K page pair. The
  game file carries an 8K block for E000-FFFF: the attract, name registration, intro and
  demo code (`src/attract.asm`), the tower picture, the title figures and the sound data.
  At start-up it is copied above each of the three screen buffers, so it can run and be read
  whichever buffer is paged into sections C/D. The title picture comes in the game file at
  65536 (page b+2, after the code's two) and is copied into a screen buffer, so the figures
  and hearts can be drawn on it.
- **Sound:** SAA1099 channel 0, driven from the 50 Hz interrupt. Each sound is a list of
  runs (volume, octave, note or noise, frames); the data (about 1K) sits at F800h in the
  block above.
  `tools/arcade_sound/mksnd.py hunchbkd.zip src` regenerates it with an i8035 emulator of the
  arcade sound board.
- **Speed:** profiled with a model of mode 4 memory contention (about 2× slower in
  the display area). The heaviest screen (rope plus fire) still has about 50% of each frame spare.
- **Testing:** the game was tested in a purpose-written Z80/SAM emulator, not in SimCoupé or
  on real hardware. The parts most worth checking on a real machine are the BASIC loader,
  the cursor-key row (read at port FFFEh) and the sound.
