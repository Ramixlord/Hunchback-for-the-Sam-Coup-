; =====================================================================
;  HUNCHBACK  -  SAM Coupe, screen mode 4 (256x192, 16 colours)
;  Graphics: HB SP / HB MU* / HB Main screens supplied on the disk.
;
;  Memory map once running (all interrupts our own, ROM paged out):
;    sections A+B (0000-7FFF) : code page pair K,K+1 (this file, ORG 0)
;    sections C+D (8000-FFFF) : current back screen (mode 4, 24K at 8000)
;  Two screen page pairs are used for flicker-free double buffering;
;  sprites are drawn with save-under and restored in reverse order.
;
;  Assembles with the included z80asm.py (pasmo/sjasm style syntax).
; =====================================================================

LMPR    equ 250
HMPR    equ 251
VMPR    equ 252
BORDER  equ 254
LINEINT equ 249
CLUTP   equ 248
KEYP    equ 254

FLOOR   equ 89              ; y of rampart top (player feet anchor)
PSTART  equ 8               ; player start x (pixels)
RINGX   equ 228             ; reaching here rings the bell (his hand on the rope)
PIT_X0  equ 60
PIT_X1  equ 196
ROPE_PX equ 128             ; rope pivot
KNIGHT_X equ 10
KTOP    equ 67              ; climbing knight top-of-sprite when at the top
KSTART  equ 150
NUMLEVELS equ 16           ; 15 castle screens, then the belfry (arcade)
BOXX    equ 16
BOXY    equ 40

; player states
PS_WALK equ 0
PS_JUMP equ 1
PS_ROPE equ 2
PS_FALL equ 3               ; falling into a gap/pit
PS_DEAD equ 4               ; hit: falls down the wall face
PS_RING equ 5               ; ringing the bell
PS_WAIT equ 6               ; start-of-screen pause
PS_INTRO equ 7              ; new-game run along the riverbank
PS_BROPE equ 8              ; belfry: riding a bell rope
PS_BDONE equ 9              ; belfry: all the bells found

; level flags
LF_GAPS  equ 1
LF_PIT   equ 2
LF_GUARD equ 4
LF_TOWER equ 8
LF_FIRE  equ 10h            ; fireballs
LF_ARROW equ 20h            ; arrows
LF_TWO   equ 40h             ; two missiles at a time
LF_PIT4  equ 80h             ; four short ropes over the pit

; per-buffer background jobs
OVLBASE  equ 0E000h         ; attract/intro code: spare 8K above each screen buffer
SNDBASE  equ 0F800h         ; sound data after it (file ends below FF00h; boot stack above)
SNDLEN   equ 1792
BG_HUD   equ 1
BG_MSG   equ 2
BG_UNMSG equ 4
BG_BELLR equ 8              ; erase static bell rope (for ringing)
BG_BOX   equ 10h            ; SCORE box
BG_BELLADD equ 20h          ; new bell on the top rope
BG_CAP   equ 40h            ; knight's wall over gaps / pit

        org 0
        jp start
bootK:  db 0                ; 0003  written by the boot stub
bootP:  db 0                ; 0004
bootV:  db 0                ; 0005
        ds 38h-$
        jp isr
        ds 66h-$
        retn

; ---------------------------------------------------------------------
; interrupt: frame counter + sound effects
; ---------------------------------------------------------------------
isr:    push af
        push bc
        push de
        push hl
        ld hl,frames
        inc (hl)
        call sfx_tick
        pop hl
        pop de
        pop bc
        pop af
        ei
        ret

; ---------------------------------------------------------------------
start:  di
        ld sp,stacktop
        ld hl,varstart
        ld de,varstart+1
        ld bc,varend-varstart-1
        ld (hl),0
        ldir
        ld a,255
        out (LINEINT),a             ; no line interrupts
        ld a,0
        out (BORDER),a
        ; choose two screen page pairs avoiding code (K) and title (V)
        ld hl,scand
        ld de,spage
        ld b,3
.sc:    ld a,(hl)
        inc hl
        ld c,a
        ld a,(bootK)
        sub c
        inc a
        cp 3
        jr c,.sc                    ; overlaps code pages
        ld a,(bootV)                ; (the title may start on an odd page)
        sub c
        inc a
        cp 3
        jr c,.sc                    ; overlaps title screen
        ld a,c
        ld (de),a
        inc de
        djnz .sc
        ld a,(bootV)
        and 31
        ld (tpage),a
        ld hl,1234h
        ld a,r
        xor l
        ld l,a
        ld (seed),hl
        call copy_ovl
        call mirror_player
        call sound_init
        call make_fire
        im 1
        ei

; =====================================================================
;  TITLE
; =====================================================================
title:  jp attract

; =====================================================================
;  NEW GAME
; =====================================================================
newgame:
        ld a,3
        ld (lives),a
        xor a
        ld (level),a
        ld (round),a
        ld (bells),a
        ld hl,score
        ld b,6
.z:     ld (hl),0
        inc hl
        djnz .z

        ld (xlife),a
        ld a,1
        ld (p1tune),a
        ld (dointro),a
newscreen:
        call player1_screen
        ld a,(dointro)
        or a
        jr z,.ni
        xor a
        ld (dointro),a
        call intro_begin            ; tower screen, Quasimodo on the riverbank
        jr gameloop
.ni:    call setup_level
        ld a,12
        ld (ptimer),a
        call wipe_to_new
        ; main loop
gameloop:
        call restore_all
        call bg_jobs
        ld a,(demo)
        or a
        call nz,demo_frame          ; attract demo: FEATURING THE BELLS, time limit
        call read_input
        ld b,a
        ld a,(demo)
        or a
        ld a,b
        call nz,demo_input          ; demo: SPACE starts a game, else computer's keys
        ld (keys),a
        call update
        call draw_all
        ld a,(keys)
        ld (keysprev),a
        call flip
        call chk_xlife
        ld a,(gamecmd)
        or a
        jr z,gameloop
        ld b,a
        xor a
        ld (gamecmd),a
        ld a,b
        cp 1
        jr z,.next
        cp 2
        jr z,.died
        cp 3
        jp z,main_menu
        cp 4
        jp z,demo_over
        cp 5
        jp z,intro_next
        jr gameloop
.next:  ; screen complete: a full rope of five bells has been paid, empty it
        call clear_sprites
        ld a,(bells)
        cp 5
        jr c,.nb
        xor a
        ld (bells),a
.nb:    ld a,(level)
        inc a
        cp NUMLEVELS
        jr c,.n1
        ; castle complete: start again, faster
        ld a,(round)
        inc a
        ld (round),a
        xor a
        ld (bells),a
.n1:    ld (level),a
        call setup_level
        ld a,12
        ld (ptimer),a
        call wipe_to_new
        jp gameloop
.died:  xor a                       ; arcade (hunchbkd 648E): every lost life
        ld (bells),a                ; empties the bell rope
        ld a,(demo)
        or a
        jp nz,demo_over
        ld a,(infl)                 ; LIFE cheat: lives never run out
        or a
        jp nz,newscreen
        ld a,(lives)
        dec a
        ld (lives),a
        jp nz,newscreen
        ; game over
        call show_gameover
        jp gameover_hs

show_gameover:
        ld hl,s_gameover
        ld (msgptr),hl
        ld a,BG_MSG
        call bg_post
        ld b,100
.w:     push bc
        call restore_all
        call bg_jobs
        call draw_all_static
        call flip
        pop bc
        djnz .w
        ret

; =====================================================================
;  LEVEL SETUP
; =====================================================================
setup_level:
        xor a
        ld (hisst),a
        ld (capx),a
        ld (kfrm),a
        ld a,(level)
        ld e,a
        ld d,0
        ld hl,lvl_flags
        add hl,de
        ld a,(hl)
        ld (lflags),a
        ; knight climb rate in 1/256 px per tick (arcade: 11.3 s on screen 1, faster later)
        ld a,(level)
        ld e,a
        ld d,0
        ld hl,krates
        add hl,de
        ld b,(hl)
        ld a,(round)
        or a
        jr z,.k1
        ld c,a
.k0:    ld a,b
        add a,24
        jr c,.k1
        ld b,a
        dec c
        jr nz,.k0
.k1:    ld a,b
        ld (krate),a
        ld a,(round)
        cp 3
        jr c,.r1
        ld a,3
.r1:    ld e,a
        ld d,0
        ld hl,haz_extra
        add hl,de
        ld a,(hl)
        ld (hzextra),a
        ; arcade bonus: screen number x 100 x (10 - k), where k rises by one
        ; every 3.73 s (a 0.932 s counter that starts at 2, divided by 4)
        ld hl,bunit
        ld b,6
.bz:    ld (hl),0
        inc hl
        djnz .bz
        ; the arcade's screen number: 1-15 the first time round, the belfry
        ; 16, then 17-31 for the castle every time after (its counter goes
        ; from 31 back to 16, the belfry)
        ld a,(level)
        inc a
        cp 16
        jr nc,.bn2                  ; the belfry
        ld b,a
        ld a,(round)
        or a
        ld a,b
        jr z,.bn2
        add a,16
.bn2:   push af
        ; wall colour for this screen (Century's original board, hunchbak 0554)
        ld e,a
        ld d,0
        ld hl,wallcols
        add hl,de
        ld a,(hl)
        ld (pal_game+2),a
        ld bc,256*2+CLUTP
        out (c),a
        pop af
        ld b,a
.ba:    push bc
        ld hl,bunit
        ld de,c_100
        call add6
        pop bc
        djnz .ba
        ld hl,512                   ; counter = 2.0
        ld (btimer),hl
        ld a,0FFh
        ld (bonk),a
        xor a
        call set_bonus
        ; ropes
        xor a
        ld (nropes),a
        ld (nograb),a
        ld (pjfast),a
        ld (kacc),a
        ld (ropeon),a
        ld a,(lflags)
        and LF_PIT
        jr z,.nr
        ld a,(lflags)
        and LF_PIT4
        jr nz,.r4
        ld a,1
        ld (nropes),a
        xor a                       ; long rope: pivot at the top of the screen
        ld (ropepy),a
        ld a,80
        ld (ropemax),a
        ld hl,rope1cfg
        jr .rc
.r4:    ld a,4
        ld (nropes),a
        ld a,38
        ld (ropepy),a
        ld a,30
        ld (ropemax),a
        ld hl,rope4cfg
.rc:    ld de,ropepx
        ld bc,8
        ldir
.nr:
        ; player
        ld a,PSTART
        ld (px),a
        ld a,FLOOR
        ld (py),a
        ld a,PS_WAIT
        ld (pstate),a
        ld a,40
        ld (ptimer),a
        xor a
        ld (pface),a
        ld (pwalk),a
        ld (gamecmd),a
        ld (haz),a
        ld (haz+HZSIZE),a
        ld (kstate),a
        ld (ktick),a
        ld (bonustick),a
        ld (ringt),a
        ld (heart),a
        ld a,KSTART
        ld (ky),a
        ld a,12                     ; first missile shortly after the start
        ld (spawnt0),a
        ld a,12+32                  ; second one 1.3 s behind it
        ld (spawnt1),a
        xor a
        ld (rphase),a
        ld (kacc2),a
        ld (dphase),a
        ld (phide),a
        ld (haz+6),a
        inc a
        ld (haz+HZSIZE+6),a         ; slot 1 is the faster missile
        ld a,(level)
        ld e,a
        ld d,0
        ld hl,lvl_height
        add hl,de
        ld a,(hl)
        ld (hmode),a
        ld a,KNIGHT_X
        ld (kx),a
        ; guards
        ld hl,guards
        ld b,3
        ld c,0
.g:     ld (hl),0                   ; state down
        inc hl
        ld a,c
        add a,25
        ld c,a
        ld (hl),a                   ; timer staggered
        inc hl
        ld (hl),255                 ; drawn in buf0
        inc hl
        ld (hl),255                 ; drawn in buf1
        inc hl
        djnz .g
        call belfry_setup
        ld hl,s_ready
        ld (msgptr),hl
        xor a
        ld (bgpend),a
        ld (bgpend+1),a
        ld (savecnt),a
        ld (savecnt+1),a
        ret

; build the background into both screens
build_both:
        ; blank display while building
        ld hl,pal_black
        call set_palette
        xor a
        ld (curbuf),a
        ld a,(spage)
        out (HMPR),a
        call build_screen
        ld a,(spage+1)
        out (HMPR),a
        call build_screen
        ; show buffer 1, draw into 0
        ld a,(spage+1)
        or 60h
        out (VMPR),a
        ld a,(spage)
        out (HMPR),a
        xor a
        ld (curbuf),a
        ld a,(frames)
        ld (lastflip),a
        ; palette
        ld hl,pal_game
        ld de,palbuf
        ld bc,16
        ldir
        ld hl,palbuf
        call set_palette
        ld a,BG_MSG
        jp bg_post

build_screen:
        ld a,(belf)
        or a
        jp nz,belfry_build
        ; top band rows 0..88
        ld hl,gfx_band1
        ld a,(lflags)
        and LF_TOWER
        jr z,.b1
        ld hl,gfx_band5
.b1:    ld de,8000h
        xor a
        ld (rlemode),a
        call unrle
        ; brick wall rows 89..175
        ld d,FLOOR
.br:    push de
        ld e,0
        call addr_xy
        ld a,d
        and 7
        add a,a
        add a,a
        ld c,a
        ld b,0
        push hl
        ld hl,gfx_brick
        add hl,bc
        pop de                      ; de = screen row
        push de
        ld bc,4
        ldir
        pop hl                      ; hl = row start
        ld bc,124
        ldir
        pop de
        inc d
        ld a,d
        cp 176
        jr c,.br
        ; ground strip overlay rows 154..175
        ld hl,gfx_ground
        ld de,8000h+154*128
        ld a,1
        ld (rlemode),a
        call unrle
        ; gaps
        ld a,(lflags)
        and LF_GAPS
        jr z,.ng
        ld e,60
        call make_gap
        ld e,116
        call make_gap
        ld e,172
        call make_gap
.ng:    ld a,(lflags)
        and LF_PIT
        jr z,.np
        call make_pit
.np:    ld a,(lflags)
        and LF_PIT4
        jr z,.n4
        ld e,70                     ; beam for the four ropes
        ld d,36
        ld b,54
        ld c,2
        ld a,44h
        call fill_bytes
.n4:    ld a,(lflags)
        and LF_TOWER
        jr z,.nt
        ld hl,gfx_towerbase
        ld de,256*FLOOR+196
        call draw_block
.nt:    ; collected bells on the top rope
        ld a,(bells)
        or a
        jr z,.nb
        ld b,a
        ld e,42
.bl:    push bc
        push de
        ld d,7
        ld hl,spr_bell
        call draw_plain
        pop de
        ld a,e
        add a,16
        ld e,a
        pop bc
        djnz .bl
.nb:    jp draw_hud

; gap at x=e : brown wedge e+1..e+5 on black e+2..e+25, rows 89..112
; (black behind the top of the wedge, no brickwork: as drawn on Image1.mgt)
make_gap:
        push de
        ld a,e
        add a,2
        ld e,a
        ld d,FLOOR
        ld b,12
        ld c,24
        xor a
        call fill_bytes
        pop de
        inc e
        ld b,24
        ld d,FLOOR
        jp wedge

; draw brown wedge at x=e, from y=d for b rows
wedge:  ld c,0
.r:     push bc
        ld a,c
        cp 4
        jr c,.w0
        ld a,4
.w0:    inc a                       ; width this row 1..5
        ld b,a
        push de
.p:     ld a,4
        call plot
        inc e
        djnz .p
        pop de
        inc d
        pop bc
        inc c
        djnz .r
        ret

make_pit:
        ld e,PIT_X0+2               ; black from behind the wedge's top
        ld d,FLOOR
        ld b,67
        ld c,72
        xor a
        call fill_bytes
        ld e,PIT_X0+1
        ld d,FLOOR
        ld b,80                     ; down behind the fire (rows 161-168)
        jp wedge

; The arcade knight lays wall over gaps and the pit as he walks the
; battlements: copy the brick pattern into rows FLOOR..FLOOR+7 of each
; gap / the pit, up to x = capx (current buffer).
cap_draw:
        ld a,(capx)
        srl a
        ld c,a                      ; c = end byte (exclusive)
        ld a,(lflags)
        and LF_PIT
        jr z,.gp
        ld b,30                     ; pit: x 60..195
        ld e,98
        jr cap_span
.gp:    ld a,(lflags)
        and LF_GAPS
        ret z
        ld b,30                     ; gaps: x 60..85, 116..141, 172..197
        ld e,43
        call cap_span
        ld b,58
        ld e,71
        call cap_span
        ld b,86
        ld e,99
; bytes b..min(e,c)-1 of the 8 rows; the brick rows repeat every 4 bytes
cap_span:
        ld a,e
        cp c
        jr c,.lim
        ld a,c
.lim:   sub b
        ret z
        ret c
        push bc
        ld c,a                      ; bytes per row
        ld a,FLOOR
.row:   push af
        ld l,0
        srl a
        rr l
        add a,80h
        ld h,a                      ; hl = row start
        ld a,l
        add a,b
        ld e,a
        ld d,h                      ; de = first byte to fill
        push bc
.byte:  push hl
        ld a,e
        and 3
        or l
        ld l,a
        ld a,(hl)
        ld (de),a
        pop hl
        inc e
        dec c
        jr nz,.byte
        pop bc
        pop af
        inc a
        cp FLOOR+8
        jr c,.row
        pop bc
        ret

; ---------------------------------------------------------------------
; HUD (rows 176..191)
; ---------------------------------------------------------------------
draw_hud:
        ld e,0
        ld d,176
        ld b,128
        ld c,16
        xor a
        call fill_bytes
        ld hl,gfx_castle
        ld de,256*176+0
        call draw_block
        ; progress marker
        ld a,(level)
        add a,a
        add a,a                     ; *4 (15 screens along the castle)
        add a,4
        ld e,a
        ld d,182
        ld b,1
        ld c,2
        ld a,0AAh
        call fill_bytes
        ld a,15
        ld (textcol),a
        ld hl,s_player
        ld de,256*177+74
        call print
        ld hl,s_bonus
        ld de,256*185+74
        call print
        ld hl,s_score
        ld de,256*177+210
        call print
        ; lives (spare)
        ld a,(lives)
        dec a
        jr z,.nl
        jr c,.nl
        cp 5
        jr c,.l0
        ld a,4
.l0:    ld b,a
        ld e,148
.ll:    push bc
        push de
        ld d,177
        ld hl,spr_life
        call draw_plain
        pop de
        ld a,e
        add a,10
        ld e,a
        pop bc
        djnz .ll
.nl:    ; fall through to values
hud_values:
        ld a,15
        ld (textcol),a
        ld hl,bonus+1
        ld b,5
        ld de,256*185+122
        call print_digits
        ld hl,score
        ld b,6
        ld de,256*185+208
        jp print_digits

; =====================================================================
;  PER-FRAME
; =====================================================================
; post a background job to both buffers
bg_post:
        ld hl,bgpend
        ld b,a
        or (hl)
        ld (hl),a
        inc hl
        ld a,b
        or (hl)
        ld (hl),a
        ret

; run pending background jobs for the current buffer (after restore)
bg_jobs:
        ld a,(curbuf)
        ld e,a
        ld d,0
        ld hl,bgpend
        add hl,de
        ld a,(hl)
        ld (hl),0
        or a
        jr z,.guards
        ld c,a
        push bc
        bit 0,c
        call nz,hud_values
        pop bc
        push bc
        bit 2,c
        call nz,msg_erase
        pop bc
        push bc
        bit 1,c
        call nz,msg_draw
        pop bc
        push bc
        bit 4,c
        call nz,box_draw
        pop bc
        push bc
        bit 5,c
        call nz,bell_add
        pop bc
        push bc
        bit 3,c
        call nz,trio_erase
        pop bc
        bit 6,c
        call nz,cap_draw
.guards:
        ld a,(lflags)
        and LF_GUARD
        ret z
        ; redraw any guard whose frame differs in this buffer
        ld ix,guards
        ld e,66
        ld b,3
.g:     push bc
        push de
        ld a,(curbuf)
        or a
        ld a,(ix+0)
        jr nz,.g1
        cp (ix+2)
        jr z,.gs
        ld (ix+2),a
        jr .gd
.g1:    cp (ix+3)
        jr z,.gs
        ld (ix+3),a
.gd:    push af
        push de
        ld d,72
        ld b,9
        ld c,41
        xor a
        call fill_bytes
        pop de
        pop af
        ld hl,spr_guard0
        or a
        jr z,.g2
        ld hl,spr_guard1
.g2:    ld d,113
        call draw_plain
        ld a,(capx)
        or a
        call nz,cap_draw
.gs:    pop de
        ld a,e
        add a,56
        ld e,a
        ld bc,4
        add ix,bc
        pop bc
        djnz .g
        ret

msg_draw:
        ld a,(belf)                 ; (no messages over the belfry floors)
        or a
        ret nz
        ld a,11
        ld (textcol),a
        ld hl,(msgptr)
        ld de,256*48+92
        jp print
msg_erase:
        ld a,(belf)
        or a
        ret nz
        ld e,80
        ld d,46
        ld b,52
        ld c,10
        xor a
        jp fill_bytes

box_draw:
        ld hl,gfx_box
        ld de,256*BOXY+BOXX
        call draw_block
        ld a,5
        ld (textcol),a
        ld hl,s_score
        ld de,256*(BOXY+7)+BOXX+6
        call print
        ld a,6                      ; fixed blue (colour 2 is the wall's)
        ld (textcol),a
        ld hl,boxval+1
        ld b,5
        ld de,256*(BOXY+18)+BOXX+6
        jp print_num

bell_add:
        ld a,(bells)
        dec a
        cp 5
        ret nc
        add a,a
        add a,a
        add a,a
        add a,a
        add a,42
        ld e,a
        ld d,7
        ld hl,spr_bell
        jp draw_plain

; remove all sprites from both screens
clear_sprites:
        call restore_all
        ld a,(curbuf)
        xor 1
        ld (curbuf),a
        call map_cur
        jp restore_all

map_cur:
        ld a,(curbuf)
        ld e,a
        ld d,0
        ld hl,spage
        add hl,de
        ld a,(hl)
        out (HMPR),a
        ret

; build the next screen in the spare buffer and wipe it in from the right
wipe_to_new:
        ld a,(spage+2)
        out (HMPR),a
        call build_screen
        ld a,124
        ld (wcol),a
.w:     ld a,(frames)
        ld (wtime),a
        ld a,(spage)
        call copy_strip
        ld a,(spage+1)
        call copy_strip
.ww:    ld a,(frames)
        ld hl,wtime
        sub (hl)
        ld hl,wfast                 ; 1 = intro: twice as fast
        cp (hl)
        jr c,.ww
        ld a,(wcol)
        sub 4
        ld (wcol),a
        jr nc,.w
        xor a
        ld (curbuf),a
        ld (savecnt),a
        ld (savecnt+1),a
        ld a,(spage+1)
        or 60h
        out (VMPR),a
        ld a,(spage)
        out (HMPR),a
        ld a,(frames)
        ld (lastflip),a
        ret

; copy a 4-byte wide column strip (wcol) from the spare buffer to page a
copy_strip:
        push af
        ld a,(spage+2)
        out (HMPR),a
        ld a,(wcol)
        ld l,a
        ld h,80h
        ld de,wipebuf
        ld a,192
.r1:    ld bc,4
        ldir
        ld bc,124
        add hl,bc
        dec a
        jr nz,.r1
        pop af
        out (HMPR),a
        ld a,(wcol)
        ld e,a
        ld d,80h
        ld hl,wipebuf
        ld a,192
.r2:    ld bc,4
        ldir
        ex de,hl
        ld bc,124
        add hl,bc
        ex de,hl
        dec a
        jr nz,.r2
        ret

; print b digits at hl with leading zeros blanked
print_num:
        ld c,0
.l:     ld a,(hl)
        inc hl
        or a
        jr nz,.nz
        bit 0,c
        jr nz,.dig
        ld a,b
        dec a
        jr z,.dig
        ld a,' '
        jr .put
.nz:    ld c,1
.dig:   add a,'0'
.put:   push hl
        push bc
        call putchar
        pop bc
        pop hl
        ld a,e
        add a,8
        ld e,a
        djnz .l
        ret

; z set while the death freeze is on (everything stops for 1.2 s)
frozen: ld a,(pstate)
        cp PS_DEAD
        jr nz,.no
        ld a,(dphase)
        or a
        ret
.no:    or 1
        ret

; black screen with PLAYER 1 (arcade, before a screen scrolls in)
player1_screen:
        ld hl,pal_game
        call set_palette
        xor a
        ld (curbuf),a
        ld a,(spage)
        call .one
        ld a,(spage+1)
        call .one
        ld a,(spage)
        or 60h
        out (VMPR),a
        ld b,50
        ld a,(p1tune)
        or a
        jr z,.w
        xor a
        ld (p1tune),a
        ld a,SND_START              ; new game: the arcade start tune, played to the end
        call snd_play
.t:     ld a,(frames)               ; hold the PLAYER 1 screen until it has finished
.t1:    ld hl,frames
        cp (hl)
        jr z,.t1
        ld hl,(sfxptr)
        ld a,h
        or l
        jr nz,.t
        ld b,10
.w:     ld a,(frames)
.w1:    ld hl,frames
        cp (hl)
        jr z,.w1
        djnz .w
        ret
.one:   out (HMPR),a
        ld e,0
        ld d,0
        ld b,128
        ld c,192
        xor a
        call fill_bytes
        ld a,13
        ld (textcol),a
        ld hl,s_player
        ld de,256*92+96
        jp print

bellrope_erase:
        ld e,244
        ld d,49
        ld b,32
.l:     xor a
        call plot
        inc d
        djnz .l
        ret

; flip: wait for >=2 frames since last flip, show back buffer, swap
flip:   ld a,(frames)
        ld c,a
.w1:    ld a,(frames)
        cp c
        jr z,.w1
        ld c,a
        ld hl,lastflip
        sub (hl)
        cp 2
        jr c,.w1
        ld (hl),c
        ld a,(curbuf)
        ld e,a
        ld d,0
        ld hl,spage
        add hl,de
        ld a,(hl)
        or 60h
        out (VMPR),a
        ld a,e
        xor 1
        ld (curbuf),a
        ld e,a
        ld hl,spage
        add hl,de
        ld a,(hl)
        out (HMPR),a
        ret

; =====================================================================
;  GAME LOGIC (one tick = 2 frames)
; =====================================================================
update:
        ld hl,tick
        inc (hl)
        ld a,(pstate)
        cp PS_INTRO
        jp z,intro_tick
        call upd_player
        call upd_knight
        call upd_hazards
        call upd_guards
        call frozen
        ret z
        ld a,(nropes)               ; only the long rope swings (4 s); the short ones hang still
        cp 1
        ret nz
        ld a,(tick)
        rrca
        ret nc
        ld hl,rphase
        inc (hl)
        ld a,(hl)
        cp 50
        jr c,.ph
        xor a
        ld (hl),a
.ph:    cp 12                       ; ends of the swing: the arcade's whoosh while
        jr z,.hs                    ; you hang on the rope
        cp 37
        ret nz
.hs:    ld a,(pstate)
        cp PS_ROPE
        ret nz
        ld a,SND_HISS
        jp snd_play

; ---------------- player ----------------
upd_player:
        ld a,(pstate)
        cp PS_BROPE
        jp z,p_brope
        cp PS_BDONE
        jp z,p_bdone
        cp PS_WAIT
        jr nz,.nw
        ld hl,ptimer
        dec (hl)
        ret nz
        ld a,BG_UNMSG
        call bg_post
        ld a,PS_WALK
        ld (pstate),a
        ret
.nw:    cp PS_WALK
        jp z,p_walk
        cp PS_JUMP
        jp z,p_jump
        cp PS_ROPE
        jp z,p_rope
        cp PS_FALL
        jp z,p_fall
        cp PS_DEAD
        jp z,p_dead
        cp PS_RING
        jp z,p_ring
        ret

p_walk: ld a,(keys)
        ld c,a
        bit 2,c
        jr z,.nj
        ld a,(keysprev)
        bit 2,a
        jr nz,.nj
        ; start jump
        ld a,PS_JUMP
        ld (pstate),a
        xor a
        ld (pjf),a
        ld (pjt),a
        ld (nograb),a
        ld (pjfast),a
        ld b,0
        bit 0,c
        jr z,.j1
        ld b,-2
        ld a,1
        ld (pface),a
.j1:    bit 1,c
        jr z,.j2
        ld b,2
        xor a
        ld (pface),a
.j2:    ld a,b
        ld (pjdx),a
        ld a,SND_JUMP
        jp snd_play
.nj:    ld b,0
        bit 0,c
        jr z,.w1
        ld b,-2
        ld a,1
        ld (pface),a
.w1:    bit 1,c
        jr z,.w2
        ld b,2
        xor a
        ld (pface),a
.w2:    ld a,b
        or a
        jr z,.stand
        ; arcade pace: 2 px every other tick (25 px/s)
        ld a,(tick)
        rrca
        ret nc
        call move_px
        ld a,SND_STEP
        call snd_play
        ld hl,pwalk
        inc (hl)
        call check_ring
        ld a,(pstate)
        cp PS_WALK
        ret nz
        jp check_ground
.stand: xor a
        ld (pwalk),a
        ret

; move px by b (signed), clamped 0..RINGX
move_px:
        ld a,(px)
        add a,b
        bit 7,b
        jr z,.r
        jr c,.ok                    ; no borrow -> still >= 0
        xor a
        jr .ok
.r:     cp RINGX+1
        jr c,.ok
        ld a,RINGX
.ok:    ld (px),a
        ret

check_ring:
        ld a,(belf)
        or a
        ret nz
        ld a,(px)
        cp RINGX
        ret c
        ld a,PS_RING
        ld (pstate),a
        ld a,RINGX
        ld (px),a
        ld a,FLOOR
        ld (py),a
        xor a
        ld (ringt),a
        ret

; returns: if over a hole start falling
check_ground:
        call foot_hole
        ret nc
        ld a,PS_FALL
        ld (pstate),a
        ld a,SND_FALL
        jp snd_play

; carry set if the player's foot is over a gap or pit
foot_hole:
        ld a,(belf)
        or a
        jp nz,bf_hole
        ld a,(px)
        add a,10
        ld c,a
        ld a,(lflags)
        and LF_PIT
        jr z,.ngp
        ld a,c
        cp PIT_X0+4
        jr c,.ngp
        cp PIT_X1-2
        jr nc,.ngp
        scf
        ret
.ngp:   ld a,(lflags)
        and LF_GAPS
        ret z                       ; carry clear
        ld a,c
        call .g
        ret c
        ld a,c
        sub 56
        call .g
        ret c
        ld a,c
        sub 112
.g:     ; is a within [66,80) ?  (a little forgiving at the edges)
        sub 66
        cp 14
        ret

; jump: 8 frames x 3 ticks (about 1 s), 2 px every other tick forward
p_jump: ld a,(pjfast)
        or a
        jr nz,.mv
        call air_steer
        ld a,(tick)
        rrca
        jr nc,.nm
.mv:    ld a,(pjdx)
        ld b,a
        call move_px
        call check_ring             ; touching the bell rope in mid-air rings it too
        ld a,(pstate)
        cp PS_JUMP
        ret nz
.nm:    ld hl,pjt
        inc (hl)
        ld a,(hl)
        cp 3
        jr c,.gr
        ld (hl),0
        ld hl,pjf
        inc (hl)
        ld a,(hl)
        cp 8
        jr c,.gr
        ; landed
        ld a,PS_WALK
        ld (pstate),a
        call check_ring
        ld a,(pstate)
        cp PS_WALK
        ret nz
        ld a,(belf)
        or a
        call nz,bf_land
        ld a,(pstate)
        cp PS_WALK
        ret nz
        jp check_ground
.gr:    ; try to grab a rope
        ld a,(belf)
        or a
        jp nz,bf_grab
        ld a,(nropes)
        or a
        ret z
        ld a,(pjf)
        cp 2
        ret c
        cp 7
        ret nc
        ld a,(nropes)
        ld b,a
        ld c,0
.try:   push bc
        call try_grab
        pop bc
        ret z                       ; grabbed
        inc c
        djnz .try
        ret

; steer a jump in the air: left or right held turns him that way (nothing
; held: he carries on as he was going)
air_steer:
        ld a,(demo)
        or a
        ret nz                      ; (the demo plays its jumps as recorded)
        ld a,(keys)
        ld c,a
        bit 0,c
        jr z,.r
        ld a,-2
        ld (pjdx),a
        ld a,1
        ld (pface),a
.r:     bit 1,c
        ret z
        ld a,2
        ld (pjdx),a
        xor a
        ld (pface),a
        ret

; try rope c: z set if grabbed
try_grab:
        ld a,(nograb)
        dec a
        cp c
        jr nz,.ok
        or 1                        ; nz: skip the rope we just let go
        ret
.ok:    ld hl,ropeex
        ld b,0
        add hl,bc
        ld a,(px)
        add a,10
        sub (hl)
        jr nc,.p
        neg
.p:     ld e,a
        ld a,(nropes)
        cp 1
        ld a,e
        jr nz,.p4
        cp 9                        ; the long swinging rope: within 8 px (a bit
        jr .px                      ; harder to catch than the short ones)
.p4:    cp 11
.px:    jr nc,.no
        push bc
        call ptop
        pop bc
        sub 8
        ld e,a
        ld hl,ropeey
        add hl,bc
        ld a,(hl)
        sub e
        jr c,.no
        cp 22
        jr nc,.no
        ld a,c
        ld (ropeon),a
        ld a,PS_ROPE
        ld (pstate),a
        call grab_pts
        xor a                       ; z = grabbed
        ret
.no:    or 1
        ret

; arcade: the four short ropes pay 400/300/200/100 and play note 1-4;
; the long swinging rope pays nothing and plays note 3
grab_pts:
        ld a,(nropes)
        cp 4
        ld a,SND_NOTE3
        jp nz,snd_play
        ld a,(ropeon)
        ld c,a
        ld a,4
        sub c
        ld b,a
.l:     push bc
        ld hl,score
        ld de,c_100
        call add6
        pop bc
        djnz .l
        ld a,BG_HUD
        call bg_post
        ld a,(ropeon)
        add a,SND_NOTE1
        jp snd_play

; player sprite top (absolute y) -> a
ptop:   call pframe_ptr
        inc hl
        inc hl
        inc hl
        ld a,(py)
        add a,(hl)
        ret

; phase byte of rope c -> a (preserves bc)
rope_pb:
        ld a,(nropes)
        cp 1
        jr z,.l
        xor a                       ; the four short ropes hang straight (arcade)
        ret
.l:     ld a,(rphase)
        ld e,a
        ld d,0
        ld hl,rope_phase
        add hl,de
        ld a,(hl)
        ret

p_rope: ; follow the end of the rope we hold
        ld a,(ropeon)
        ld c,a
        ld b,0
        ld hl,ropeex
        add hl,bc
        ld a,(hl)
        sub 10
        and 0FEh
        ld (px),a
        ld hl,ropeey
        add hl,bc
        ld a,(hl)
        add a,34
        ld (py),a
        ld a,(keys)
        bit 2,a
        ret z
        ld a,(keysprev)
        bit 2,a
        ret nz
        ; let go: continue as a fast jump from mid-air in the swing direction
        ld a,(ropeon)
        inc a
        ld (nograb),a
        ld a,1
        ld (pjfast),a
        ld a,FLOOR
        ld (py),a
        ld a,PS_JUMP
        ld (pstate),a
        ld a,3
        ld (pjf),a
        xor a
        ld (pjt),a
        ld a,(nropes)
        cp 4
        jr nz,.sw
        ld a,(keys)                 ; short ropes hang still: jump the way you push
        ld b,-2                     ; (right if neither)
        bit 0,a
        jr nz,.r
        ld b,2
        jr .r
.sw:    ld a,4                      ; long rope: one jump frame less in the air,
        ld (pjf),a                  ; so letting go needs better timing
        ld a,(ropeon)
        ld c,a
        call rope_pb
        ld b,2
        bit 6,a
        jr nz,.r
        ld b,-2
.r:     ld a,b
        ld (pjdx),a
        ld a,SND_JUMP
        jp snd_play

p_fall: ld a,(py)
        add a,4
        ld (py),a
        ld b,113
        ld a,(belf)
        or a
        jr z,.nb
        ld b,175                    ; belfry: down through the floors
        jr .f
.nb:    ld a,(lflags)
        and LF_PIT
        jr z,.f
        ld b,165
.f:     ld a,(py)
        cp b
        ret c
        ld a,b
        ld (py),a
        call kill_player
        xor a
        ld (dsnd),a
        ld a,SND_LAND
        call snd_play
        ; fell out of sight: straight to the pause
        ld a,2
        ld (dphase),a
        ld a,1
        ld (phide),a
        ld a,72
        ld (ptimer),a
        ret

; arcade death: freeze 1.2 s in the hit pose, drop off the wall fast,
; pause 2.9 s, then "PLAYER 1" and the screen wipes back in
p_dead: ld a,(dphase)
        or a
        jr nz,.p1
        ld hl,ptimer
        dec (hl)
        ret nz
        ld a,1
        ld (dphase),a
        ld a,(dsnd)
        or a
        ret z
        ld a,SND_FALL
        jp snd_play
.p1:    cp 1
        jr nz,.p2
        ld a,(py)
        add a,11
        ld (py),a
        cp 168
        ret c
        ld a,2
        ld (dphase),a
        ld a,1
        ld (phide),a
        ld a,72
        ld (ptimer),a
        ld a,(dsnd)
        or a
        ret z
        ld a,SND_LAND
        jp snd_play
.p2:    ld hl,ptimer
        dec (hl)
        ret nz
        ld a,2
        ld (gamecmd),a
        ret

kill_player:
        ld a,(pstate)
        cp PS_DEAD
        ret z
        ld a,PS_DEAD
        ld (pstate),a
        xor a
        ld (dphase),a
        ld (phide),a
        ld a,30
        ld (ptimer),a
        ld a,1
        ld (dsnd),a
        ld a,SND_HIT
        jp snd_play

; ringing the bell (arcade sequence): bell joins the top rope, the bonus is
; paid at once and shown in the SCORE box, everything freezes ~2 s.
; A full rope of five bells pays 25,000.  Esmeralda's tower adds 15,000.
p_ring: ld hl,ringt
        ld a,(hl)
        cp 250
        jr nc,.r0
        inc (hl)
.r0:    ld a,(hl)
        cp 1
        jr z,.first
        cp 34
        jr z,.fan
        cp 50
        ret c
        ld a,(lflags)
        and LF_TOWER
        jr z,.fin
        ; Esmeralda rescued
        ld a,(heart)
        or a
        jr nz,.h
        ld hl,s_super
        ld (msgptr),hl
        ld a,BG_MSG|BG_HUD|BG_BOX
        call bg_post
.h:     ld a,(heart)
        inc a
        ld (heart),a
        ; flash SUPER BONUS (colour 11)
        and 4
        ld a,6Eh
        jr z,.f1
        ld a,22h
.f1:    ld bc,256*11+CLUTP
        out (c),a
        ld a,(heart)
        cp 100
        ret c
        ld a,6Eh
        ld bc,256*11+CLUTP
        out (c),a
.fin:   ld a,1
        ld (gamecmd),a
        ret
.fan:   ld a,(bells)
        cp 5
        ret c
        ld a,SND_FANFARE
        jp snd_play
.first: ld a,SND_BELL
        call snd_play
        ; pay the bonus
        ld hl,bonus
        ld de,boxval
        ld bc,6
        ldir
        ld hl,score
        ld de,bonus
        call add6
        ld hl,bonus
        ld b,6
.z:     ld (hl),0
        inc hl
        djnz .z
        ld a,(bells)
        inc a
        ld (bells),a
        cp 5
        jr c,.nf
        ; five bells on the rope: 25,000
        ld hl,score
        ld de,c_25000
        call add6
        ld hl,boxval
        ld de,c_25000
        call add6
.nf:    ld a,BG_HUD|BG_BOX|BG_BELLADD
        jp bg_post

; ---------------- climbing knight / timer ----------------
; climbs (krate/256) px per tick; every pixel climbed costs bdec of bonus
upd_knight:
        ld a,(belf)
        or a
        jp nz,belfry_tick           ; the belfry has no knight
        ld a,(pstate)
        cp PS_WAIT
        ret z
        cp PS_RING
        ret z
        cp PS_DEAD
        ret z
        call bonus_tick
        ld a,(kstate)
        or a
        jr nz,.run
        ld a,(krate)
        ld hl,kacc
        add a,(hl)
        ld (hl),a
        ret nc
        ld hl,ky
        dec (hl)
        ld a,(ky)
        cp KTOP
        ret nc
        ; reached the top: he climbs onto the rampart and charges
        ld a,1
        ld (kstate),a
        ld a,8
        ld (kx),a
        xor a
        ld (kfrm),a
        ld a,22
        ld (ktim),a
        ret
.run:   ; arcade: sword raised 0.9 s, then lunge 0.9 s with an 8 px step;
        ; he builds wall over any gap or pit under him; can't be jumped
        ld hl,ktim
        dec (hl)
        jr nz,.nm
        ld a,(kfrm)
        xor 1
        ld (kfrm),a
        add a,22                    ; 22 + 23 ticks = 1.8 s cycle
        ld (hl),a
        dec a
        cp 22
        jr nz,.nm                   ; back to sword raised: no step
        ld a,(kx)
        cp 221
        jr nc,.nm
        add a,8
        ld (kx),a
        add a,16
        ld (capx),a
        ld a,BG_CAP
        call bg_post
.nm:    ld a,(kx)
        ld b,a
        ld a,(px)
        sub b
        jr c,.kill                  ; somehow behind him
        cp 16
        ret nc
.kill:  ld a,(pstate)
        cp PS_DEAD
        ret z
        call kill_player
        xor a
        ld (dsnd),a
        ld a,SND_LAND
        jp snd_play

; arcade bonus timer: +11/256 per 25 Hz tick = one count per 0.932 s
bonus_tick:
        ld hl,(btimer)
        ld de,11
        add hl,de
        ld (btimer),hl
        ld a,h
        rrca
        rrca
        and 3Fh
        cp 10
        jr c,.k
        ld a,10
.k:     ld hl,bonk
        cp (hl)
        ret z
; bonus = bunit x (10 - a)
set_bonus:
        ld (bonk),a
        ld b,a
        ld a,10
        sub b
        ld b,a
        ld hl,bonus
        ld c,6
.z:     ld (hl),0
        inc hl
        dec c
        jr nz,.z
        inc b
        jr .n
.a:     push bc
        ld hl,bonus
        ld de,bunit
        call add6
        pop bc
.n:     djnz .a
        ld a,BG_HUD
        jp bg_post

; carry set if 6-digit number at hl < number at de
lt6:    ld b,6
.l:     ld a,(de)
        cp (hl)
        jr z,.n
        ccf                         ; (hl) < (de)  <=>  (de) > (hl)
        ret
.n:     inc hl
        inc de
        djnz .l
        and a
        ret

; ---------------- hazards (fireballs / arrows) ----------------
HZSIZE  equ 7               ; active,x,y,kind,anim,scored,fast

upd_hazards:
        ld a,(belf)
        or a
        jp nz,belfry_haz
        ld a,(lflags)
        and LF_FIRE|LF_ARROW
        ret z
        ld a,(pstate)
        cp PS_WAIT
        ret z
        cp PS_RING                  ; everything freezes while the bell rings
        ret z
        call frozen
        ret z
        ld ix,haz
        call .one
        ld ix,haz+HZSIZE
        call .one
        jr .sp
.sp:    ; slot 0 launches every 3.2 s; slot 1 (two-missile screens) 1.3 s later
        ld hl,spawnt0
        ld ix,haz
        call .tm
        ld a,(lflags)
        and LF_TWO
        ret z
        ld hl,spawnt1
        ld ix,haz+HZSIZE
.tm:    ld a,(hl)
        or a
        jr z,.go
        dec (hl)
        ret
.go:    ld a,(ix+0)
        or a
        ret nz                      ; still flying: launch as soon as it's gone
        ld a,(lflags)
        and LF_ARROW
        jr nz,.ga
        ld a,(px)
        cp 180
        ret nc                      ; fireballs: hold while he's at the bell end
        ld c,232                    ; (the arcade's enter off-screen right)
        jr .gd
.ga:    ld a,(px)                   ; arrows come from the left, behind him
        cp 40
        ret c                       ; hold while he's at the start
        ld c,0
.gd:    ld a,(pstate)
        cp PS_DEAD
        ret z                       ; none launched while he's dying (arcade)
        ld (hl),80
        ld (ix+0),1
        ld (ix+1),c
        ld a,SND_LAUNCH
        call snd_play
        ld (ix+4),0
        ld (ix+5),0
        ld (ix+3),0
        ld a,(lflags)
        and LF_ARROW
        jr z,.h
        ld (ix+3),1
.h:     ; height: 0 = low, 1 = head high, 2 = random
        ld a,(hmode)
        or a
        jr z,.lo
        cp 1
        jr z,.hi
        call rand
        and 1
        jr z,.lo
.hi:    ld a,(ix+3)
        or a
        ld a,60
        jr z,.st
        ld a,58
        jr .st
.lo:    ld a,(ix+3)
        or a
        ld a,79
        jr z,.st
        ld a,85
.st:    ld (ix+2),a
        ret

.one:   ld a,(ix+0)
        or a
        ret z
        inc (ix+4)
        ld b,2                      ; first missile: 2/4 px/tick = 75 px/s
        ld a,(ix+6)
        or a
        jr z,.e1
        ld b,3                      ; second missile: 3/4 px/tick = 87 px/s (arcade 1.23x)
.e1:    ld a,(tick)
        rrca
        jr nc,.e0
        ld b,4
.e0:    ld a,(hzextra)
        or a
        jr z,.e
        ld c,a
        ld a,(tick)
        and c
        jr nz,.e
        inc b
        inc b
.e:     ld a,(ix+3)
        cp 1
        jr z,.er                    ; (kind 2: belfry arrow flying left)
        ld a,(ix+1)
        sub b
        jr c,.off
        cp 2
        jr c,.off
        ld (ix+1),a
        jr .ck
.er:    ld a,(ix+1)                 ; arrow: left to right
        add a,b
        cp 242
        jr nc,.off
        ld (ix+1),a
.ck:    ; collision with player
        ld a,(pstate)
        cp PS_WALK
        jr z,.c
        cp PS_JUMP
        ret nz                      ; safe while hanging on a rope
.c:     ld a,(ix+1)                 ; hazard box hx+2..hx+10 vs player px+5..px+15
        ld b,a
        ld a,(px)
        add a,13
        cp b
        jr c,.rgt                   ; hazard right of the player
        ld a,b
        add a,10
        ld c,a
        ld a,(px)
        add a,5
        cp c
        jr nc,.lft                  ; hazard left of the player
        ; vertical overlap
        call pvert                  ; d = top, e = feet (abs y)
        ld a,(ix+3)
        or a
        ld a,(ix+2)
        jr nz,.ar
        add a,2                     ; fireball box hy+2..hy+8
        ld c,6
        jr .v
.ar:    ld c,3
.v:     cp e
        ret nc                      ; box top at/below the feet
        add a,c
        cp d
        ret c
        ret z
        jp kill_player
.rgt:   ld a,(ix+3)                 ; fireball not reached him yet / arrow gone past
        or a
        ret z
        jr .passed
.lft:   ld a,(ix+3)                 ; fireball gone past / arrow not reached him yet
        or a
        ret nz
.passed:                            ; (the arcade gives no points for dodging)
        ld (ix+5),1
        ret
.pass:  ret
.off:   ld (ix+0),0
        ret

; player vertical extent: d = top, e = feet (abs)
pvert:  call pframe_ptr
        inc hl
        ld c,(hl)                   ; h
        inc hl
        inc hl
        ld a,(py)
        add a,(hl)                  ; top
        ld d,a
        add a,c
        ld e,a
        ret

; ---------------- guards (final screen) ----------------
upd_guards:
        call frozen
        ret z
        ld a,(lflags)
        and LF_GUARD
        ret z
        ld ix,guards
        ld e,60
.g:     dec (ix+1)
        jr nz,.chk
        ld a,(ix+0)
        xor 1
        ld (ix+0),a
        ld a,32                     ; pike down 1.3 s
        jr z,.t
        ld a,14                     ; pike up 0.56 s
.t:     ld (ix+1),a
.chk:   ; pike up and player jumping over this gap (not at the peak) -> dead
        ld a,(ix+0)
        or a
        jr z,.n
        ld a,(pstate)
        cp PS_JUMP
        jr nz,.n
        ld a,(px)
        add a,10-4                  ; foot over the gap itself (gx+4 .. gx+22)
        sub e
        jr c,.n
        cp 18
        jr nc,.n
        ld a,(pjf)
        cp 4
        jr z,.n
        push de
        call kill_player
        pop de
.n:     ld a,e
        add a,56
        ld e,a
        ld bc,4
        add ix,bc
        cp 60+56*3
        jr nz,.g
        ret

; =====================================================================
;  DRAWING
; =====================================================================
draw_all:
        ld a,(lflags)
        and LF_PIT
        call nz,draw_fire
draw_all_static:
        ; ropes (one long rope, or four short ones under a beam)
        ld a,(nropes)
        or a
        jr z,.nr
        ld b,a
        ld c,0
.rl:    push bc
        ld a,c
        ld (ridx),a
        call rope_pb
        ld c,a                      ; phase byte
        ld a,(ridx)
        ld e,a
        ld d,0
        ld hl,ropepx
        add hl,de
        ld e,(hl)
        ld a,(ropepy)
        ld d,a
        ld a,(ropemax)
        ld b,a
        call draw_rope              ; -> b = end x, c = end y
        ld a,(ridx)
        ld e,a
        ld d,0
        ld hl,ropeex
        add hl,de
        ld (hl),b
        ld hl,ropeey
        add hl,de
        ld (hl),c
        pop bc
        inc c
        djnz .rl
.nr:                                ; (the bell rope hangs still while ringing)
        ld a,(belf)
        or a
        jr z,.nb
        ld a,(byl)                  ; belfry: the two bell ropes
        ld e,24
        call bf_rope
        ld a,(byr)
        ld e,230
        call bf_rope
        jp .kd
.nb:    ; knight (gone while the bell rings, as in the arcade)
        ld a,(pstate)
        cp PS_RING
        jr z,.kd
        cp PS_INTRO
        jr z,.kd
        ld a,(kstate)
        or a
        jr nz,.kr
        ; climbing (arcade): reach, then pull up 8 px; the climb rate is unchanged
        ld a,(ky)
        ld b,a
        ld a,KSTART
        sub b
        ld c,a                      ; c = pixels climbed
        and 0F8h
        ld b,a
        ld a,KSTART
        sub b                       ; shown height moves in whole 8 px steps
        cp KTOP
        jr nc,.ky
        ld a,KTOP
.ky:    ld d,a
        ld a,c
        rrca
        rrca
        and 1                       ; crouch for 4 px of climb, then reach
        ld e,a
        ld a,d
        cp 85
        jr nc,.kw
        set 1,e                     ; head above the wall top: brown-outlined pair
.kw:    ld a,e
        add a,a
        ld e,a
        push de
        ld d,0
        ld hl,spr_kctab
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        pop de
        ld e,KNIGHT_X
        call draw_save
        jr .kd
.kr:    ld hl,spr_ksword            ; sword raised / lunge (arcade frames 9 / 8)
        ld a,(kfrm)
        or a
        jr z,.k1
        ld hl,spr_klunge
.k1:    ld d,73
        ld a,(kx)
        ld e,a
        call draw_save
.kd:    ; hazards
        ld ix,haz
        call .hz
        ld ix,haz+HZSIZE
        call .hz
        ; heart
        ld a,(heart)
        or a
        jr z,.nh
        ld b,a
        ld a,70
        sub b
        jr nc,.h1
        xor a
.h1:    srl a
        srl a
        add a,58
        ld d,a
        ld e,176
        ld hl,spr_heart
        call draw_save
.nh:    ; player
        ld a,(pstate)
        cp PS_DEAD
        jr nz,.pl
        ld a,(phide)
        or a
        ret nz                      ; dropped out of sight
.pl:    call pframe_ptr
        ld a,(px)
        ld e,a
        ld a,(py)
        ld d,a
        ld a,(pstate)
        cp PS_ROPE
        jp nz,draw_save
        ld a,d                      ; on a rope: the tucked frame drawn with his
        sub 22                      ; front hand on the rope's end
        ld d,a
        ld a,(pface)
        or a
        ld a,e
        jr nz,.pf
        sub 8
        jp draw_save
.pf:    add a,9
        jp draw_save

.hz:    ld a,(ix+0)
        or a
        ret z
        ld a,(ix+3)
        ld hl,spr_arrowl
        cp 2
        jr z,.a
        or a
        ld hl,spr_arrow
        jr nz,.a
        ld a,(ix+4)                 ; fireball: its three frames in turn,
        and 6                       ; at a steady height (no bobbing)
        ld e,a
        ld d,0
        ld hl,spr_fbtab
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
.a:     ld a,(ix+1)
        ld e,a
        ld d,(ix+2)
        jp draw_save

; current player sprite -> hl
pframe_ptr:
        ld a,(pstate)
        cp PS_JUMP
        jr z,.j
        cp PS_INTRO
        jr z,.j
        cp PS_ROPE
        jr z,.r
        cp PS_BROPE
        jr z,.r
        cp PS_FALL
        jr z,.f
        cp PS_DEAD
        jr z,.f
        ld a,(pwalk)
        rrca
        and 3
        add a,8
        jr .go
.j:     ld a,(pjf)
        jr .go
.r:     ld a,12                     ; hanging on a rope: the tucked pose (arcade)
        jr .go
.f:     ld a,12
.go:    add a,a
        ld e,a
        ld d,0
        ld hl,spr_ptab_r
        ld a,(pface)
        or a
        jr z,.rt
        ld hl,spr_ptab_l
.rt:    add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ret

; fire in the pit: 17 tiles a row, 8 rows, drawn straight from the 6 fire
; tiles each frame (tile i shows (phase + 5i) mod 6); the first tile comes
; from fire0, which has the pit wall's brown strip showing through it
draw_fire:
        ld a,(tick)
        rrca
        and 7
        cp 6
        jr c,.p
        sub 4
.p:     ld (fph),a
        ld de,8000h+161*128+30
        ld c,0
.r:     push de
        ld a,(fph)
        add a,a
        add a,a
        add a,a
        add a,c
        add a,a
        add a,a
        ld l,a
        ld h,0
        push bc
        ld bc,fire0
        add hl,bc
        ldi
        ldi
        ldi
        ldi
        pop bc
        ld a,(fph)
        ld b,16
.i:     add a,5
        cp 6
        jr c,.t
        sub 6
.t:     push af
        add a,a
        add a,a
        add a,a
        add a,c
        add a,a
        add a,a
        ld l,a
        ld h,0
        push bc
        ld bc,gfx_fire
        add hl,bc
        ldi
        ldi
        ldi
        ldi
        pop bc
        pop af
        djnz .i
        pop de
        ex de,hl
        ld de,128
        add hl,de
        ex de,hl
        inc c
        ld a,c
        cp 8
        jr c,.r
        ret

; fire0 = the fire tiles with the brown strip (x 61-65: 04h,44h,44h)
; showing through the gaps in the flames' first three bytes
make_fire:
        ld hl,gfx_fire
        ld de,fire0
        ld bc,192
        ldir
        ld hl,fire0
        ld b,48
.mw:    push bc
        ld de,fwedge
        ld b,3
.mb:    push bc
        ld a,(hl)
        ld c,a                      ; flame pixels
        ld b,0                      ; mask of the empty ones
        and 0F0h
        jr nz,.m1
        ld b,0F0h
.m1:    ld a,c
        and 0Fh
        jr nz,.m2
        ld a,b
        or 0Fh
        ld b,a
.m2:    ld a,(de)
        and b
        or c
        ld (hl),a
        pop bc
        inc hl
        inc de
        djnz .mb
        inc hl
        pop bc
        djnz .mw
        ret

; ---------------------------------------------------------------------
; draw a rope: e = pivot x, d = pivot y, c = phase byte, b = max rows
; white pixel per row, saved for restore.  returns b = end x, c = end y
; ---------------------------------------------------------------------
draw_rope:
        ld a,c
        ld (rsign),a
        ld a,d
        ld (rpy),a
        ld c,e                      ; c = pivot x
        push bc
        ld e,0
        call addr_xy
        ld (rbase),hl               ; row base of pivot row
        ld a,(rsign)
        and 15
        add a,a
        ld e,a
        ld d,0
        ld hl,rope_tab
        add hl,de
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ld a,(hl)                   ; rows in table
        inc hl
        pop bc
        cp b
        jr c,.n
        ld a,b
.n:     ld b,a
        ld (rrows),a
        ex de,hl                    ; de = dx table
        call save_begin
        ld (ix+0),1
        ld (ix+1),b
        push ix
        exx
        pop de
        inc de
        inc de                      ; de' = save write pointer
        ld hl,(rbase)               ; hl' = row base
        exx
        ld a,(rsign)
        rla
        jr c,.neg
.pos:   ld a,(de)
        inc de
        add a,c
        call .pix
        djnz .pos
        jr .done
.neg:   ld a,(de)
        inc de
        ld l,a
        ld a,c
        sub l
        call .pix
        djnz .neg
.done:  exx
        ld (savefree),de
        exx
        dec de
        ld a,(de)
        ld b,a
        ld a,(rsign)
        rla
        ld a,c
        jr c,.ex
        add a,b
        jr .ey
.ex:    sub b
.ey:    ld b,a                      ; end x
        ld a,(rpy)
        ld c,a
        ld a,(rrows)
        add a,c
        dec a
        ld c,a                      ; end y
        ret
; plot rope pixel at x = a on the current row (alt regs), advance row
.pix:   exx
        ld b,h
        ld c,l
        rra                         ; a = x/2, carry = odd pixel
        jr c,.odd
        or l
        ld l,a
        ld a,(hl)
        ex de,hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),a
        inc hl
        ex de,hl
        or 0F0h
        jr .w
.odd:   or l
        ld l,a
        ld a,(hl)
        ex de,hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),a
        inc hl
        ex de,hl
        or 0Fh
.w:     ld (hl),a
        ld h,b
        ld a,c
        add a,80h
        ld l,a
        jr nc,.k
        inc h
.k:     exx
        ret

; ---------------------------------------------------------------------
; save-under machinery
; ---------------------------------------------------------------------
; save_begin: ix = savefree ; record entry in current buffer's list
save_begin:
        push hl
        push de
        push bc
        ld ix,(savefree)
        ld a,(curbuf)
        ld e,a
        ld d,0
        ld hl,savecnt
        add hl,de
        ld a,(hl)
        cp 31
        jr nc,.full
        inc (hl)
        add a,a
        ld c,a
        ld b,0
        ld a,e
        or a
        ld hl,savelist0
        jr z,.s
        ld hl,savelist1
.s:     add hl,bc
        push ix
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
.full:  pop bc
        pop de
        pop hl
        ret

; save_end: ix = end of entry -> savefree
save_end:
        ld (savefree),ix
        ret

; draw masked sprite with save-under. hl = sprite, e = x (px), d = y
draw_save:
        ld a,e
        srl a
        inc hl
        inc hl
        add a,(hl)                  ; + ox
        ld e,a                      ; x byte
        inc hl
        ld a,d
        add a,(hl)                  ; + oy
        ld d,a
        dec hl
        dec hl
        dec hl
        ld b,(hl)                   ; w
        inc hl
        ld c,(hl)                   ; h
        inc hl
        inc hl
        inc hl
        push hl                     ; sprite data
        ; screen address
        ld a,d
        srl a
        or 80h
        ld h,a
        ld a,d
        rrca
        and 80h
        or e
        ld l,a
        push hl
        call save_begin
        pop hl
        ld (ix+0),0
        ld (ix+1),l
        ld (ix+2),h
        ld (ix+3),b
        ld (ix+4),c
        ld de,5
        add ix,de
        ; copy rect to save area
        push hl
        push bc
        push ix
        pop de
.sr:    push bc
        push hl
        ld c,b
        ld b,0
        ldir
        pop hl
        ld bc,128
        add hl,bc
        pop bc
        dec c
        jr nz,.sr
        ld (savefree),de
        pop bc
        pop hl
        pop de                      ; sprite data
        jr masked_blit

; draw masked sprite without saving: hl = sprite, e = x px, d = y
draw_plain:
        ld a,e
        srl a
        inc hl
        inc hl
        add a,(hl)
        ld e,a
        inc hl
        ld a,d
        add a,(hl)
        ld d,a
        dec hl
        dec hl
        dec hl
        ld b,(hl)
        inc hl
        ld c,(hl)
        inc hl
        inc hl
        inc hl
        push hl
        ld a,d
        srl a
        or 80h
        ld h,a
        ld a,d
        rrca
        and 80h
        or e
        ld l,a
        pop de
; hl = screen, de = mask/data pairs, b = width bytes, c = rows
masked_blit:
.row:   push hl
        push bc
.col:   ld a,(de)
        and (hl)
        inc de
        ld c,a
        ld a,(de)
        or c
        ld (hl),a
        inc de
        inc hl
        djnz .col
        pop bc
        pop hl
        push bc
        ld bc,128
        add hl,bc
        pop bc
        dec c
        jr nz,.row
        ret

; restore all saved entries of current buffer (reverse order)
restore_all:
        ld a,(curbuf)
        or a
        ld hl,savearea0
        jr z,.ra
        ld hl,savearea1
.ra:    ld (savefree),hl
        ld a,(curbuf)
        ld e,a
        ld d,0
        ld hl,savecnt
        add hl,de
        ld a,(hl)
        ld (hl),0
        or a
        ret z
        ld b,a
        ld a,e
        or a
        ld hl,savelist0
        jr z,.l
        ld hl,savelist1
.l:     ld a,b
        dec a
        add a,a
        ld e,a
        ld d,0
        add hl,de                   ; last slot
.ent:   push bc
        push hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                      ; entry
        ld a,(hl)
        inc hl
        or a
        jr nz,.pix
        ; rect
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld b,(hl)
        inc hl
        ld c,(hl)
        inc hl                      ; hl = data, de = screen
.rr:    push bc
        push de
        ld c,b
        ld b,0
        ldir
        ex de,hl
        pop hl
        ld bc,128
        add hl,bc
        ex de,hl
        pop bc
        dec c
        jr nz,.rr
        jr .next
.pix:   ld b,(hl)
        inc hl
.pp:    ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        inc hl
        ld (de),a
        djnz .pp
.next:  pop hl
        dec hl
        dec hl
        pop bc
        djnz .ent
        ret

; ---------------------------------------------------------------------
; setup-time primitives
; ---------------------------------------------------------------------
; hl = screen address of (e = x px, d = y)
addr_xy:
        ld a,d
        srl a
        or 80h
        ld h,a
        ld a,d
        rrca
        and 80h
        ld l,a
        ld a,e
        srl a
        or l
        ld l,a
        ret

; plot pixel e,d colour a (preserves bc,de)
plot:   push bc
        ld c,a
        call addr_xy
        bit 0,e
        jr nz,.odd
        ld a,c
        rlca
        rlca
        rlca
        rlca
        ld c,a
        ld a,(hl)
        and 0Fh
        or c
        ld (hl),a
        pop bc
        ret
.odd:   ld a,(hl)
        and 0F0h
        or c
        ld (hl),a
        pop bc
        ret

; fill bytes: e = x pixel (even), d = y, b = width bytes, c = rows, a = byte
fill_bytes:
        srl e
fill_bytes_x:                       ; e already byte x
        push af
        ld a,d
        srl a
        or 80h
        ld h,a
        ld a,d
        rrca
        and 80h
        or e
        ld l,a
        pop af
.r:     push hl
        push bc
.c:     ld (hl),a
        inc hl
        djnz .c
        pop bc
        pop hl
        push de
        ld de,128
        add hl,de
        pop de
        dec c
        jr nz,.r
        ret

; opaque block: hl = (w,h,data), e = x px, d = y
draw_block:
        call .a
        ld b,(hl)
        inc hl
        ld c,(hl)
        inc hl
.r:     push bc
        push de
        ld c,b
        ld b,0
        ldir
        pop de
        ex de,hl
        ld bc,128
        add hl,bc
        ex de,hl
        pop bc
        dec c
        jr nz,.r
        ret
.a:     push hl
        call addr_xy
        ex de,hl
        pop hl
        ret

; RLE decode hl -> de ; rlemode 1 = overlay with nibble-0 transparency
unrle:  ld a,(rlemode)
        or a
        jr nz,unrle_ov
.l:     ld a,(hl)
        inc hl
        or a
        ret z
        cp 128
        jr nc,.run
        ld c,a
        ld b,0
        ldir
        jr .l
.run:   sub 126
        ld b,a
        ld a,(hl)
        inc hl
.rp:    ld (de),a
        inc de
        djnz .rp
        jr .l

unrle_ov:
        ld a,(hl)
        inc hl
        or a
        ret z
        cp 128
        jr nc,.run
        ld b,a
.lit:   ld a,(hl)
        inc hl
        call .put
        djnz .lit
        jr unrle_ov
.run:   sub 126
        ld b,a
        ld a,(hl)
        inc hl
.rp:    call .put
        djnz .rp
        jr unrle_ov
.put:   ld c,a
        ld a,(rlemode)
        or a
        ld a,c
        jr z,.st
        or a
        jr z,.skip
        and 0F0h
        jr nz,.hi
        ld a,(de)
        and 0F0h
        or c
        jr .st
.hi:    ld a,c
        and 0Fh
        ld a,c
        jr nz,.st
        ld a,(de)
        and 0Fh
        or c
.st:    ld (de),a
.skip:  inc de
        ld a,c
        ret

; ---------------------------------------------------------------------
; text: hl = string (0 term), e = x, d = y ; colour in textcol
; ---------------------------------------------------------------------
print:  ld a,(hl)
        or a
        ret z
        inc hl
        push hl
        call putchar
        pop hl
        ld a,e
        add a,8
        ld e,a
        jr print

print_digits:                       ; hl = digits, b = count
.l:     ld a,(hl)
        add a,'0'
        inc hl
        push hl
        push bc
        call putchar
        pop bc
        pop hl
        ld a,e
        add a,8
        ld e,a
        djnz .l
        ret

; a = ascii, e,d position
putchar:
        push de
        sub 32
        ld c,a
        ld b,0
        ld hl,gfx_fontmap
        add hl,bc
        ld a,(hl)
        ld l,a
        ld h,0
        ld c,l
        ld b,h
        add hl,hl
        add hl,hl
        add hl,hl
        and a
        sbc hl,bc                   ; *7
        ld bc,gfx_font
        add hl,bc
        push hl
        call addr_xy
        pop de                      ; de = glyph
        ld a,(textcol)
        ld c,a
        ld b,7
.r:     push bc
        ld a,(de)
        inc de
        push de
        ld e,a
        ld b,4
.c:     xor a
        rl e
        jr nc,.n1
        ld a,c
        rlca
        rlca
        rlca
        rlca
.n1:    rl e
        jr nc,.n2
        or c
.n2:    ld (hl),a
        inc hl
        djnz .c
        ld bc,124
        add hl,bc
        pop de
        pop bc
        djnz .r
        pop de
        ret

; ---------------------------------------------------------------------
; input: returns a = bit0 left, bit1 right, bit2 jump
; keys O/P, Z/X, cursors, SPACE, M, 6/7/9/0 (Sinclair joystick)
; ---------------------------------------------------------------------
; typing LIFE on the main menu switches infinite lives on (or off again)
cheat_key:
        ld a,(cheatn)
        ld e,a
        ld d,0
        ld hl,cheat_seq
        add hl,de
        ld a,(hl)
        call keytest
        jr nz,.dn
        xor a                       ; letter not down: arm for the next press
        ld (cheatdn),a
        ret
.dn:    ld a,(cheatdn)
        or a
        ret nz
        inc a
        ld (cheatdn),a
        ld a,(cheatn)
        inc a
        cp 4
        jr c,.s
        ld a,(infl)
        xor 1
        ld (infl),a
        ld a,SND_EXTRA
        call snd_play
        xor a
.s:     ld (cheatn),a
        ret
cheat_show:                         ; on the title screen
        ld de,256*12+72
        ld bc,256*56+8
        xor a
        call fill_bytes
        ld a,(infl)
        or a
        ret z
        ld a,11
        ld (textcol),a
        ld hl,s_inf
        ld de,256*12+72
        jp print
cheat_seq: db 49,42,11,18           ; L I F E
s_inf:  db "INFINITE LIVES",0

; =====================================================================
;  THE BELFRY (arcade: the screen after Esmeralda's tower)
;  Four floors, three groups of bells on each. Walk over a group to take
;  it (10 points x the floor number). The two bell ropes at the sides go
;  up and down against each other: jump to a rope from the end of a
;  floor, ride it and press jump to step off on to another floor.
;  Arrows fly along the floor you're on, from either side.
;  All twelve groups: the remaining bonus is paid and the castle starts
;  again, faster.
; =====================================================================
BF_RTOP equ 23                      ; ropes hang from y 23
BF_YLO  equ 120                     ; rope bottom: 120 .. 175
BF_YHI  equ 175

belfry_setup:
        ld a,(level)
        cp 15
        ld a,0
        jr nz,.no
        inc a
.no:    ld (belf),a
        or a
        ret z
        ld hl,btrio
        ld b,4
.z:     ld (hl),0
        inc hl
        djnz .z
        ld a,BF_YHI
        ld (byl),a
        ld a,BF_YLO
        ld (byr),a
        ld a,0FFh                   ; the left rope rises first
        ld (bdir),a
        ld a,25
        ld (bdw),a
        ld (bbt),a
        xor a
        ld (bacc),a
        ld (bkind),a
        ld (nropes),a
        ld a,32
        ld (px),a
        ld a,171
        ld (py),a
        ld hl,bonus                 ; 10,000 to win, 100 less every second
        ld b,6
.c:     ld (hl),0
        inc hl
        djnz .c
        ld a,1
        ld (bonus+1),a
        ld a,40
        ld (spawnt0),a
        ret

belfry_build:
        ld e,0
        ld d,0
        ld b,128
        ld c,176
        xor a
        call fill_bytes
        ; brick walls at both sides
        ld d,0
.w:     push de
        ld e,0
        call addr_xy
        push hl
        ld a,d
        and 7
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,gfx_brick
        add hl,de
        pop de
        push hl
        ld bc,4
        ldir
        pop hl
        ld a,e
        add a,120
        ld e,a
        ld bc,4
        ldir
        pop de
        inc d
        ld a,d
        cp 176
        jr c,.w
        ; beam, bells, title
        ld e,8
        ld d,4
        ld b,120
        ld c,3
        ld a,44h
        call fill_bytes
        ld de,256*7+16
        ld hl,spr_bell
        call draw_plain
        ld de,256*7+222
        ld hl,spr_bell
        call draw_plain
        ld a,11
        ld (textcol),a
        ld hl,s_super
        ld de,256*12+84
        call print
        ld d,BF_RTOP                ; fixed upper part of the two bell ropes
.rp:    ld e,24
        ld a,15
        call plot
        ld e,230
        ld a,15
        call plot
        inc d
        ld a,d
        cp BF_YLO
        jr c,.rp
        ; the four floors
        ld hl,bf_ytab
        ld b,4
.f:     push bc
        push hl
        ld d,(hl)
        ld c,4
.fr:    push bc
        push de
        ld e,40
        call addr_xy
        push hl
        ld a,d
        and 7
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,gfx_brick
        add hl,de
        pop de
        ld b,22
.fb:    push hl
        ld c,4
.fc:    ld a,(hl)
        ld (de),a
        inc hl
        inc de
        dec c
        jr nz,.fc
        pop hl
        djnz .fb
        pop de
        inc d
        pop bc
        dec c
        jr nz,.fr
        pop hl
        inc hl
        pop bc
        djnz .f
        call trio_draw
        jp draw_hud

; groups of bells: b = group 0-2, c = floor 0-3
trio_draw:
        ld c,0
.fl:    ld b,0
.tj:    push bc
        call trio_bit
        jr nz,.sk
        pop bc
        push bc
        call trio_xy
        call draw_trio
.sk:    pop bc
        inc b
        ld a,b
        cp 3
        jr c,.tj
        inc c
        ld a,c
        cp 4
        jr c,.fl
        ret

; background job: blank the groups already taken (this buffer)
trio_erase:
        ld a,(belf)
        or a
        ret z
        ld c,0
.fl:    ld b,0
.tj:    push bc
        call trio_bit
        jr z,.sk
        pop bc
        push bc
        call trio_xy
        ld b,12
        ld c,4
        xor a
        call fill_bytes
.sk:    pop bc
        inc b
        ld a,b
        cp 3
        jr c,.tj
        inc c
        ld a,c
        cp 4
        jr c,.fl
        ret

; NZ if group b on floor c is taken; hl = its floor byte, e = its bit
trio_bit:
        ld hl,btrio
        ld a,l
        add a,c
        ld l,a
        jr nc,.h
        inc h
.h:     ld e,1
        ld a,b
        or a
        jr z,.m
.ml:    sla e
        dec a
        jr nz,.ml
.m:     ld a,(hl)
        and e
        ret

; -> e = x, d = top row, a = colour of group b on floor c
trio_xy:
        push bc
        ld hl,bf_tx
        ld a,l
        add a,b
        ld l,a
        jr nc,.a
        inc h
.a:     ld e,(hl)
        ld hl,bf_ytab
        ld a,l
        add a,c
        ld l,a
        jr nc,.b
        inc h
.b:     ld a,(hl)
        sub 4
        ld d,a
        ld hl,bf_tcol
        ld a,l
        add a,c
        ld l,a
        jr nc,.c
        inc h
.c:     ld a,(hl)
        pop bc
        ret

; three little bells (triangles 8 px wide, 4 rows) at e,d in colour a
draw_trio:
        ld (tcolv),a
        ld b,3
.t:     push bc
        push de
        ld c,0
.r:     push de
        ld a,e
        add a,3
        sub c
        ld e,a
        ld a,c
        add a,a
        add a,2
        ld b,a
.p:     ld a,(tcolv)
        call plot
        inc e
        djnz .p
        pop de
        inc d
        inc c
        ld a,c
        cp 4
        jr c,.r
        pop de
        ld a,e
        add a,8
        ld e,a
        pop bc
        djnz .t
        ret

; a bell rope at x e down to y a: the part above BF_YLO is always there
; (drawn with the background), only the moving end is drawn each frame
bf_rope:
        sub BF_YLO
        ret c
        ret z
        ld b,a
        ld c,13                     ; rope_lng
        ld d,BF_YLO
        jp draw_rope

; z if the player is standing on a floor; c = its number
bf_floor:
        ld hl,bf_ytab
        ld c,0
.l:     ld a,(py)
        cp (hl)
        ret z
        inc hl
        inc c
        ld a,c
        cp 4
        jr c,.l
        or a
        ret

; every tick (from upd_knight)
belfry_tick:
        ld a,(pstate)
        cp PS_WAIT
        ret z
        cp PS_BDONE
        ret z
        cp PS_DEAD
        ret z
        ; bell ropes: 2 px every 3 ticks, a second's rest at each end
        ld hl,bdw
        ld a,(hl)
        or a
        jr z,.mv
        dec (hl)
        jr .rd
.mv:    ld hl,bacc
        inc (hl)
        ld a,(hl)
        cp 3
        jr c,.m1
        ld (hl),0
        jr .rd
.m1:    ld a,(bdir)
        ld b,a
        ld a,(byl)
        add a,b
        ld (byl),a
        cp BF_YLO
        jr z,.end
        cp BF_YHI
        jr nz,.rd
.end:   ld a,(bdir)
        neg
        ld (bdir),a
        ld a,25
        ld (bdw),a
.rd:    ld a,(byl)
        ld b,a
        ld a,BF_YLO+BF_YHI-256
        sub b
        ld (byr),a
        ; bonus: 100 less every second
        ld hl,bbt
        dec (hl)
        jr nz,.nb
        ld (hl),25
        ld hl,bonus
        ld de,c_100
        call lt6
        jr c,.nb
        ld hl,bonus
        ld de,c_100
        call sub6
        ld a,BG_HUD
        call bg_post
.nb:    ; bells under his feet
        ld a,(pstate)
        cp PS_WALK
        jr z,.c
        cp PS_JUMP
        ret nz
.c:     call bf_floor
        ret nz
        ld a,(px)
        add a,10
        ld d,a                      ; foot x
        ld b,0
.tj:    push bc
        push de
        ld hl,bf_tx
        ld a,l
        add a,b
        ld l,a
        jr nc,.t0
        inc h
.t0:    ld a,(hl)
        add a,8
        ld e,a
        ld a,d
        sub e
        cp 8
        jr nc,.tn                   ; not over the middle of this group
        call trio_bit
        jr nz,.tn
        call trio_get
.tn:    pop de
        pop bc
        inc b
        ld a,b
        cp 3
        jr c,.tj
        ; all twelve?
        ld hl,btrio
        ld b,4
.al:    ld a,(hl)
        cp 7
        ret nz
        inc hl
        djnz .al
        ld a,PS_BDONE
        ld (pstate),a
        ld a,110
        ld (ptimer),a
        ld hl,score
        ld de,bonus
        call add6
        ld a,BG_HUD
        call bg_post
        ld a,SND_FANFARE
        jp snd_play

; take group (hl, e from trio_bit; c = floor)
trio_get:
        ld a,(hl)
        or e
        ld (hl),a
        inc c
        ld b,c
.s:     push bc
        ld hl,score
        ld de,c_10
        call add6
        pop bc
        djnz .s
        ld a,BG_HUD|BG_BELLR        ; (BG_BELLR: blank the taken groups)
        call bg_post
        ld a,SND_NOTE3
        jp snd_play

belfry_haz:
        ld a,(pstate)
        cp PS_WAIT
        ret z
        cp PS_BDONE
        ret z
        ld ix,haz
        call upd_hazards.one
        ld hl,spawnt0
        ld a,(hl)
        or a
        jr z,.go
        dec (hl)
        ret
.go:    ld a,(haz)
        or a
        ret nz
        ld a,(pstate)
        cp PS_WALK
        jr z,.l
        cp PS_JUMP
        ret nz
.l:     call bf_floor
        ret nz
        ld a,80                     ; an arrow every 3.2 s, sides in turn
        ld (spawnt0),a
        ld ix,haz
        ld (ix+0),1
        ld a,(bkind)
        xor 1
        ld (bkind),a
        ld b,1
        ld c,0
        jr z,.k
        ld b,2
        ld c,232
.k:     ld (ix+3),b
        ld (ix+1),c
        ld a,(py)
        sub 4
        ld (ix+2),a
        xor a
        ld (ix+4),a
        ld (ix+5),a
        ld (ix+6),a
        ld a,SND_LAUNCH
        jp snd_play

; carry if his foot is off the floors (x 40..215)
bf_hole:
        ld a,(px)
        add a,10
        cp 40
        ret c
        cp 216
        ccf
        ret

; landed from a jump: on to a floor within 8 px, else he falls
bf_land:
        ld hl,bf_ytab
        ld b,4
.l:     ld a,(py)
        sub (hl)
        jr nc,.p
        neg
.p:     cp 9
        jr c,.ok
        inc hl
        djnz .l
        ld a,PS_FALL
        ld (pstate),a
        ld a,SND_FALL
        jp snd_play
.ok:    ld a,(hl)
        ld (py),a
        ret

; jumping at a bell rope: catch it if it reaches down to his hands
bf_grab:
        ld a,(nograb)
        or a
        ret nz
        ld a,(px)
        cp 25
        jr c,.lf
        cp 211
        ret c
        ld c,1
        ld a,(byr)
        jr .ck
.lf:    ld c,0
        ld a,(byl)
.ck:    ld b,a
        add a,17
        ld e,a
        ld a,(py)
        cp e
        ret nc
        sub b
        ld (bhang),a
        ld a,c
        ld (bside),a
        or a                        ; hands on the rope: facing it
        ld a,22
        ld b,1
        jr z,.x
        ld a,213
        ld b,0
.x:     ld (px),a
        ld a,b
        ld (pface),a
        ld a,PS_BROPE
        ld (pstate),a
        ld a,SND_NOTE1
        jp snd_play

p_brope:
        ld a,(bside)
        or a
        ld a,(byl)
        jr z,.l
        ld a,(byr)
.l:     ld b,a
        ld a,(bhang)
        add a,b
        cp 40
        jr c,.lo
        cp 200
        jr c,.y
.lo:    ld a,40
.y:     ld (py),a
        ld a,(keys)
        bit 2,a
        ret z
        ld a,(keysprev)
        bit 2,a
        ret nz
        ; let go: a short jump in towards the floors
        ld a,1
        ld (nograb),a
        ld (pjfast),a
        ld a,PS_JUMP
        ld (pstate),a
        ld a,3
        ld (pjf),a
        xor a
        ld (pjt),a
        ld a,(bside)
        or a
        ld a,2
        ld b,0
        jr z,.d
        ld a,-2
        ld b,1
.d:     ld (pjdx),a
        ld a,b
        ld (pface),a
        ret

p_bdone:
        ld hl,ptimer
        dec (hl)
        ret nz
        ld a,1
        ld (gamecmd),a
        ret

fwedge:  db 04h,44h,44h
bf_ytab: db 171,131,91,51           ; floor tops (player feet)
bf_tx:   db 56,112,168              ; the three groups on each floor
bf_tcol: db 13,14,13,11             ; colours, bottom floor first


; =====================================================================
;  MAIN MENU (any key on the title, league table, instructions or demo)
;  1 insert a coin, 2 start a game (uses a credit), 3 redefine the keys.
;  LIFE typed here switches infinite lives on/off.
; =====================================================================
main_menu:
        ld sp,stacktop
        call sound_off
        xor a
        ld (demo),a
.redraw:
        call text_screen
        ld hl,mm_txt
        call print_list
        ld a,15
        ld (textcol),a
        ld c,0
.kl:    push bc
        ld hl,ukeys
        ld b,0
        add hl,bc
        ld a,(hl)
        call kname
        pop bc
        push bc
        ld a,c
        add a,a
        ld b,a
        add a,a
        add a,a
        add a,b
        add a,46
        ld d,a
        ld e,128
        call print
        pop bc
        inc c
        ld a,c
        cp 3
        jr c,.kl
        call mm_credits
        call mm_inf
.up:    ld hl,0
        ld (mmidle),hl
.u2:    call wait1
        call anykey
        jr c,.u2
.loop:  call wait1
        ld hl,(mmidle)
        inc hl
        ld (mmidle),hl
        ld de,1500                  ; 30 s with nothing pressed: the title again
        and a
        sbc hl,de
        jp nc,attract
        ld a,(infl)
        ld (mminf),a
        call cheat_key
        ld a,(infl)
        ld hl,mminf
        cp (hl)
        call nz,mm_inf
        call anykey
        jr nc,.loop
        cp 24                       ; 1
        jr z,.coin
        cp 25                       ; 2
        jr z,.start
        cp 26                       ; 3
        jr nz,.up
        call redefine
        jp .redraw
.coin:  ld a,(credits)
        cp 9
        jr nc,.up
        inc a
        ld (credits),a
        call mm_credits
        ld a,SND_COIN
        call snd_play
        jr .up
.start: ld a,(credits)
        or a
        jr z,.nocr
        dec a
        ld (credits),a
        jp start_game
.nocr:  call mm_clr152
        ld a,11
        ld (textcol),a
        ld hl,s_insert
        ld de,256*152+56
        call print
        jr .up

mm_clr152:
        ld de,256*152
        ld bc,256*128+8
        xor a
        jp fill_bytes

mm_credits:
        call mm_clr152
        ld a,15
        ld (textcol),a
        ld hl,s_credits
        ld de,256*152+88
        call print
        ld a,(credits)
        add a,'0'
        ld (klbuf),a
        xor a
        ld (klbuf+1),a
        ld hl,klbuf
        jp print

mm_inf:
        ld de,256*168
        ld bc,256*128+8
        xor a
        call fill_bytes
        ld a,(infl)
        or a
        ret z
        ld a,11
        ld (textcol),a
        ld hl,s_inf
        ld de,256*168+72
        jp print

mm_txt: db 16,92,13,"MAIN MENU",0
        db 34,72,8,"THE CONTROLS",0
        db 46,64,15,"LEFT",0
        db 56,64,15,"RIGHT",0
        db 66,64,15,"JUMP",0
        db 80,12,8,"CURSORS AND JOYSTICK WORK TOO",0
        db 100,56,15,"1  INSERT COIN",0
        db 114,56,15,"2  START GAME",0
        db 128,56,15,"3  REDEFINE KEYS",0
        db 255
s_credits: db "CREDITS ",0
s_insert:  db "INSERT A COIN FIRST",0

;  left-facing player frames: mirror the right-facing ones into RAM
mirror_player:
        ld ix,spr_ptab_r
        ld iy,spr_ptab_l
        ld de,plbuf
        ld b,13
.f:     push bc
        ld l,(ix+0)
        ld h,(ix+1)
        inc ix
        inc ix
        ld (iy+0),e
        ld (iy+1),d
        inc iy
        inc iy
        ld c,(hl)                   ; w (bytes)
        ld a,c
        ld (de),a
        inc hl
        inc de
        ld b,(hl)                   ; h
        ld a,b
        ld (de),a
        inc hl
        inc de
        ld a,10                     ; ox' = 10 - w - ox (20 px cell)
        sub c
        sub (hl)
        ld (de),a
        inc hl
        inc de
        ld a,(hl)                   ; oy
        ld (de),a
        inc hl
        inc de
.r:     push bc
        push hl
        ld a,c
        add a,a
        add a,l
        ld l,a
        jr nc,.e
        inc h
.e:     ld b,c
.p:     dec hl
        dec hl
        ld a,(hl)
        rlca
        rlca
        rlca
        rlca
        ld (de),a
        inc de
        inc hl
        ld a,(hl)
        rlca
        rlca
        rlca
        rlca
        ld (de),a
        inc de
        dec hl
        djnz .p
        pop hl
        ld a,c
        add a,a
        add a,l
        ld l,a
        jr nc,.n
        inc h
.n:     pop bc
        djnz .r
        pop bc
        djnz .f
        ret

read_input:                         ; -> a: bit0 left, bit1 right, bit2 jump
        ld e,0
        ld a,(ukeys)                ; the three (redefinable) keys
        call keytest
        jr z,.u1
        set 0,e
.u1:    ld a,(ukeys+1)
        call keytest
        jr z,.u2
        set 1,e
.u2:    ld a,(ukeys+2)
        call keytest
        jr z,.u3
        set 2,e
.u3:    ld bc,0FFFEh                ; cursor keys: CNTRL UP DOWN LEFT RIGHT
        in a,(c)
        bit 3,a
        jr nz,.a7
        set 0,e
.a7:    bit 4,a
        jr nz,.a8
        set 1,e
.a8:    bit 1,a
        jr nz,.a9
        set 2,e
.a9:    ld b,0EFh                   ; joystick 1: 0 9 8 7 6
        in a,(c)
        bit 4,a
        jr nz,.b1
        set 0,e
.b1:    bit 3,a
        jr nz,.b2
        set 1,e
.b2:    bit 0,a
        jr nz,.b3
        set 2,e
.b3:    bit 1,a
        jr nz,.b4
        set 2,e
.b4:    ld a,e
        ret

; key index a (row*8 + bit: bits 0-4 on port FE, 5-7 on port F9)
; -> NZ if the key is down.  Keeps de.
keytest:
        ld c,a
        rrca
        rrca
        rrca
        and 0Fh
        ld hl,krows
        add a,l
        ld l,a
        jr nc,.k1
        inc h
.k1:    ld b,(hl)                   ; row select on the high address byte
        ld a,c
        and 7
        ld hl,kbits
        add a,l
        ld l,a
        jr nc,.k2
        inc h
.k2:    ld h,(hl)                   ; bit mask
        ld a,c
        and 7
        cp 5
        ld c,KEYP
        jr c,.p
        ld c,0F9h
.p:     in a,(c)
        cpl
        and h
        ret
krows:  db 0FEh,0FDh,0FBh,0F7h,0EFh,0DFh,0BFh,07Fh,0FFh
kbits:  db 1,2,4,8,16,32,64,128

; key index a -> hl = its name
kname:  ld hl,knames
        or a
        ret z
        ld b,a
.s:     ld a,(hl)
        inc hl
        or a
        jr nz,.s
        djnz .s
        ret
knames: db "SHIFT",0,"Z",0,"X",0,"C",0,"V",0,"F1",0,"F2",0,"F3",0
        db "A",0,"S",0,"D",0,"F",0,"G",0,"F4",0,"F5",0,"F6",0
        db "Q",0,"W",0,"E",0,"R",0,"T",0,"F7",0,"F8",0,"F9",0
        db "1",0,"2",0,"3",0,"4",0,"5",0,"ESC",0,"TAB",0,"CAPS",0
        db "0",0,"9",0,"8",0,"7",0,"6",0,"MINUS",0,"PLUS",0,"DEL",0
        db "P",0,"O",0,"I",0,"U",0,"Y",0,"EQUAL",0,"QUOTE",0,"F0",0
        db "ENTER",0,"L",0,"K",0,"J",0,"H",0,"SEMI",0,"COLON",0,"EDIT",0
        db "SPACE",0,"SYM",0,"M",0,"N",0,"B",0,"COMMA",0,"DOT",0,"INV",0
        db "CTRL",0,"UP",0,"DOWN",0,"LEFT",0,"RIGHT",0

; build text from template hl into klbuf: bytes 1,2,3 insert the names of
; the left, right and jump keys.  -> b = length
kl_build:
        ld de,klbuf
        ld b,0
.l:     ld a,(hl)
        inc hl
        or a
        jr z,.e
        cp 4
        jr nc,.c
        push hl
        push de
        ld e,a
        ld d,0
        ld hl,ukeys-1
        add hl,de
        ld a,(hl)
        push bc
        call kname
        pop bc
        pop de
.n:     ld a,(hl)
        or a
        jr z,.nd
        ld (de),a
        inc de
        inc hl
        inc b
        jr .n
.nd:    pop hl
        jr .l
.c:     ld (de),a
        inc de
        inc b
        jr .l
.e:     ld (de),a
        ret

; template hl, d = y, textcol set: printed centred
print_kl:
        push de
        call kl_build
        pop de
        ld a,b
        add a,a
        add a,a
        neg
        add a,128
        ld e,a
        ld hl,klbuf
        jp print

; ---------------------------------------------------------------------
; palette: hl -> 16 colours
; ---------------------------------------------------------------------
set_palette:
        ld bc,256*15+CLUTP
        ld de,15
        add hl,de
.l:     ld a,(hl)
        dec hl
        out (c),a
        dec b
        jp p,.l
        ret

; ---------------------------------------------------------------------
; 6-digit decimal arithmetic (most significant digit first)
; ---------------------------------------------------------------------
add6:   ld bc,5
        add hl,bc
        ex de,hl
        add hl,bc
        ex de,hl
        ld b,6
        ld c,0
.l:     ld a,(de)
        add a,(hl)
        add a,c
        ld c,0
        cp 10
        jr c,.s
        sub 10
        ld c,1
.s:     ld (hl),a
        dec hl
        dec de
        djnz .l
        ld a,c                      ; overflow: clamp to 999999
        or a
        ret z
        inc hl
        ld b,6
.m:     ld (hl),9
        inc hl
        djnz .m
        ret

sub6:   ld bc,5
        add hl,bc
        ex de,hl
        add hl,bc
        ex de,hl
        ld b,6
        ld c,0
.l:     ld a,(hl)
        sub c
        ld c,0
        jr nc,.a
        add a,10
        ld c,1
.a:     ex de,hl
        sub (hl)
        ex de,hl
        jr nc,.s
        add a,10
        ld c,1
.s:     ld (hl),a
        dec hl
        dec de
        djnz .l
        ret

; z set if 6 digits at hl are all zero
is_zero6:
        ld b,6
        xor a
.l:     or (hl)
        inc hl
        djnz .l
        or a
        ret

; ---------------------------------------------------------------------
; random (xorshift 16)
; ---------------------------------------------------------------------
rand:   push hl
        ld hl,(seed)
        ld a,h
        rra
        ld a,l
        rra
        xor h
        ld h,a
        ld a,l
        rra
        ld a,h
        rra
        xor l
        ld l,a
        xor h
        ld h,a
        ld (seed),hl
        pop hl
        ret

; ---------------------------------------------------------------------
; SAA1099 sound effects (channel 0, optional noise)
; ---------------------------------------------------------------------
saa_w:  ; d = register, e = value
        ld bc,01FFh
        out (c),d
        dec b
        out (c),e
        ret

sound_init:
        ld de,1C02h
        call saa_w
        ld de,1C01h
        call saa_w
sound_off:
        ld hl,0
        ld (sfxptr),hl
        ld de,0000h
        call saa_w
        ld de,1400h
        call saa_w
        ld de,1500h
        call saa_w
        ld de,1602h
        jp saa_w

; ---------------------------------------------------------------------
; Arcade sounds: the Hunchback sound board plays one sound at a time and a
; new one replaces whatever is playing; the same here on SAA channel 0.
; Each sound is a list of runs (amp<<4|noise<<3|octave, note, frames)
; taken frame by frame from the arcade sound CPU (see tools/mksnd.py).
; The data sits at SNDBASE in the spare 8K above every screen buffer, so it
; is visible whichever buffer is paged into sections C/D.
; ---------------------------------------------------------------------
; a = sound number: start it now (keeps bc, de, hl)
snd_play:
        push hl
        ld hl,demo
        inc (hl)
        dec (hl)
        pop hl
        ret nz
        push hl
        push de
        add a,a
        ld e,a
        ld d,0
        ld hl,snd_offs
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,i                      ; keep the caller's interrupt state
        di
        ld (sfxptr),de
        xor a
        ld (sfxcnt),a
        jp po,.di
        ei
.di:    pop de
        pop hl
        ret

sfx_tick:
        ld hl,(sfxptr)
        ld a,h
        or l
        ret z
        ld a,(sfxcnt)
        or a
        jr z,.next
        dec a
        ld (sfxcnt),a
        ret nz
.next:  ld a,(hl)
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)
        inc hl
        ld (sfxptr),hl
        inc b
        dec b
        jr z,.end
        ld h,a
        ld a,b
        ld (sfxcnt),a
        ld l,c
        ; amplitude both sides
        ld a,h
        and 0F0h
        ld e,a
        rrca
        rrca
        rrca
        rrca
        or e
        ld e,a
        ld d,00h
        call saa_w
        ld e,l
        ld d,08h                    ; frequency ch0
        call saa_w
        ld a,h
        and 7
        ld e,a
        ld d,10h                    ; octave ch0
        call saa_w
        ld e,1
        ld a,h
        and 8
        jr z,.tn
        dec e
.tn:    ld d,14h                    ; tone on unless noise
        call saa_w
        ld e,0
        ld a,h
        and 8
        jr z,.nz
        inc e
.nz:    ld d,15h                    ; noise ch0
        jp saa_w
.end:   ld hl,0
        ld (sfxptr),hl
        ld de,0000h
        call saa_w
        ld de,1400h
        call saa_w
        ld de,1500h
        jp saa_w

; the game file carries E000-FFFF (attract/intro code, sound data) at the
; same place in the page it was loaded into; copy it above every screen buffer
copy_ovl:
        ld hl,spage
        ld b,3
.p:     push bc
        push hl
        ld a,(hl)
        ld (cpdst),a
        ld a,(bootP)
        and 31
        ld hl,OVLBASE
        ld bc,2000h
        call copy_pages
        pop hl
        inc hl
        pop bc
        djnz .p
        ret

; copy bc bytes at hl (8000-FFFF) from page pair a to page pair (cpdst),
; 2K at a time through the sprite save areas (free outside the game).
; Leaves (cpdst) paged in.
copy_pages:
        ld (cpsrc),a
.l:     ld a,b
        or c
        ret z
        push bc
        ld a,b
        cp 8
        jr c,.s
        ld bc,2048
.s:     push bc
        push hl
        ld a,(cpsrc)
        out (HMPR),a
        ld de,savearea0
        ldir
        pop de
        pop bc
        push bc
        ld a,(cpdst)
        out (HMPR),a
        ld hl,savearea0
        ldir
        ex de,hl
        pop bc
        ex (sp),hl
        and a
        sbc hl,bc
        ld b,h
        ld c,l
        pop hl
        jr .l

; bonus man at 10,000 (arcade)
chk_xlife:
        ld a,(xlife)
        ld hl,demo
        or (hl)
        ret nz
        ld hl,score
        ld a,(hl)
        inc hl
        or (hl)
        ret z
        ld a,1
        ld (xlife),a
        ld hl,lives
        ld a,(hl)
        cp 9
        jr nc,.m
        inc (hl)
.m:     ld a,SND_EXTRA
        call snd_play
        ld a,BG_HUD
        jp bg_post


; =====================================================================
;  DATA
; =====================================================================
scand:  db 8,10,12,14,4,2,6
; wall colour (colour 2) by arcade screen number 0-31, from Century's original
; board (hunchbak, table at 0554; its colour RAM byte is inverted BBBGGGRR):
;   7F dark blue -> 17 (the mockups' blue)   FC red -> 34   79 purple -> 48
;   F2 olive -> 6   92 grey-green -> 15   FF black -> 0
; The belfry (16) keeps the blue: it has no castle wall, and black would hide
; its brick sides.
wallcols:
        db 17,17,17,17,17, 34,34,34,34, 48,48, 6,6, 15, 0, 17   ; 0-15
        db 17, 0, 34,34,34, 17,17, 48,48, 6,6, 15,15, 0,0, 17   ; 16-31
; the 15 screens of the arcade castle, in arcade order
lvl_flags:
        db LF_FIRE                              ; 1  fireballs
        db LF_PIT                               ; 2  fire pit + rope
        db LF_GAPS                              ; 3  battlements
        db LF_GAPS|LF_GUARD                     ; 4  pikemen in the gaps
        db LF_GAPS|LF_GUARD|LF_FIRE             ; 5  pikemen + fireballs
        db LF_GAPS|LF_ARROW                     ; 6  battlements + arrows
        db LF_PIT                               ; 7  fire pit + rope
        db LF_GAPS|LF_GUARD|LF_ARROW|LF_TWO     ; 8  pikemen + two arrows
        db LF_PIT|LF_PIT4|LF_FIRE               ; 9  four-rope pit + fireballs
        db LF_GAPS|LF_ARROW|LF_TWO              ; 10 battlements + two arrows
        db LF_GAPS|LF_FIRE|LF_TWO               ; 11 battlements + two fireballs
        db LF_GAPS|LF_GUARD|LF_ARROW|LF_TWO     ; 12 pikemen + two arrows
        db LF_GAPS|LF_GUARD|LF_FIRE|LF_TWO      ; 13 pikemen + two fireballs
        db LF_PIT|LF_PIT4|LF_ARROW|LF_TWO       ; 14 four-rope pit + two arrows
        db LF_GAPS|LF_GUARD|LF_TOWER|LF_FIRE|LF_TWO ; 15 Esmeralda's tower
        db 0                                    ; 16 the belfry (own code)
; missile height per screen (arcade): 0 low, 1 head high, 2 random
lvl_height: db 0,0,0,0,1,0,0,2,0,2,0,2,0,2,0,0
; knight climb per tick (/256 px): 83 px in 11.3 s on screen 1 .. 10.3 s on screen 15
krates: db 75,75,76,76,77,77,78,78,79,79,80,80,81,81,82,82
haz_extra:  db 0,3,1,1                      ; and-mask for extra speed in later rounds
rope1cfg:   db 128,0,0,0, 0,0,0,0           ; pivot x, phase offset
rope4cfg:   db 76,108,140,172, 0,25,0,25    ; neighbours swing in opposite directions


c_10:   db 0,0,0,0,1,0
c_100:  db 0,0,0,1,0,0
c_25000: db 0,2,5,0,0,0

pal_black: ds 16,0
s_hiscore: db "HI SCORE",0
wfast:  db 2                ; screen wipe: frames per step (1 during the intro)
; league table: 5 x (6 score digits, 8 name characters), best first
; (the arcade starts with 50,000 on every line; graded here so that a
; first game of 10,000 or more gets to register a name)
hitab:  db 0,5,0,0,0,0
        db "        "
        db 0,4,0,0,0,0
        db "        "
        db 0,3,0,0,0,0
        db "        "
        db 0,2,0,0,0,0
        db "        "
        db 0,1,0,0,0,0
        db "        "
; left, right, jump: key indices for keytest (default O, P, SPACE)
ukeys:     db 41,40,56
s_player:  db "PLAYER 1",0
s_bonus:   db "BONUS",0
s_score:   db "SCORE",0
s_ready:   db "GET READY",0
s_gameover: db "GAME OVER",0
s_super:   db "SUPER BONUS",0

        include "snd_tab.inc"

        include "gfx.asm"

; =====================================================================
;  VARIABLES
; =====================================================================
varstart:
frames:   db 0
lastflip: db 0
tick:     db 0
curbuf:   db 0
spage:    db 0,0,0
tpage:    db 0
seed:     dw 0
keys:     db 0
keysprev: db 0
gamecmd:  db 0
level:    db 0
round:    db 0
lives:    db 0
bells:    db 0
lflags:   db 0
krate:    db 0
hzextra:  db 0
score:    ds 6
hiscore:  ds 6
bonus:    ds 6
bonustick: db 0
px:       db 0
py:       db 0
pstate:   db 0
pface:    db 0
pwalk:    db 0
pjf:      db 0
pjt:      db 0
pjdx:     db 0
nograb:   db 0
ptimer:   db 0
ringt:    db 0
heart:    db 0
kstate:   db 0
kx:       db 0
ky:       db 0
ktick:    db 0
haz:      ds HZSIZE*2
spawnt0:  db 0
spawnt1:  db 0
hmode:    db 0
dphase:   db 0
phide:    db 0
kacc2:    db 0
rphase:   db 0
ropex:    db 0
ropey:    db 0
rsign:    db 0
rlastx:   db 0
rpy:      db 0
rrows:    db 0
rbase:    dw 0
nropes:   db 0
ropepy:   db 0
ropemax:  db 0
rphtab:   dw 0
ropepx:   ds 4
ropeoff:  ds 4
ropeex:   ds 4
ropeey:   ds 4
ropeon:   db 0
ridx:     db 0
pjfast:   db 0
kacc:     db 0
bunit:    ds 6
btimer:   dw 0
bonk:     db 0
boxval:   ds 6
wcol:     db 0
wtime:    db 0
fk:       db 0
fr:       db 0
ft:       db 0
guards:   ds 12
textcol:  db 0
msgptr:   dw 0
bgpend:   db 0,0
rlemode:  db 0
sfxptr:   dw 0
sfxcnt:   db 0
hisst:    db 0
klbuf:    ds 32
demo:     db 0
xlife:    db 0
dointro:  db 0
ipart:    db 0
ihop:     db 0
istep:    db 0
dtime:    dw 0
ddir:     db 0
textx:    db 0
cpsrc:    db 0
cpdst:    db 0
tstate:   db 0
lcnt:     db 0
lred:     db 0
fcnt:     db 0
ttime:    dw 0
nerank:   db 0
rdy:      db 0
cheatn:   db 0
cheatdn:  db 0
infl:     db 0
credits:  db 0
mmidle:   dw 0
mminf:    db 0
belf:     db 0              ; 1 on the belfry screen
btrio:    ds 4              ; belfry: bells taken per floor (bits 0-2)
byl:      db 0              ; belfry: bottom of the left / right bell rope
byr:      db 0
bdir:     db 0
bdw:      db 0
bacc:     db 0
bside:    db 0
bhang:    db 0
bbt:      db 0
bkind:    db 0
tcolv:    db 0
necur:    db 0
nelen:    db 0
netime:   db 0
nesec:    db 0
nerep:    db 0              ; name entry: frames to the next held-key move
nebxy:    dw 0              ; name entry box: top left, width, colour
nebw:     db 0
nebc:     db 0
nebcc:    db 0
nename:   ds 8
ktim:     db 0
kfrm:     db 0
capx:     db 0
p1tune:   db 0
dsnd:     db 0
palbuf:   ds 16
savecnt:  db 0,0
savefree: dw 0
varend:
savelist0: ds 64
savelist1: ds 64
savearea0: ds 1536
savearea1: ds 1536
fire0:    ds 192
fph:      db 0
wipebuf:  ds 768
          ds 96                     ; stack (deepest measured use: 32 bytes)
stacktop:
spr_ptab_l: ds 26                   ; left-facing player frames (made by mirror_player)
plbuf:      ds spr_ptab_r-spr_pr0
codeend:
          assert codeend <= 8000h

        include "attract.asm"
