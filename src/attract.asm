; =====================================================================
;  ATTRACT MODE, NAME REGISTRATION, NEW-GAME INTRO RUN, DEMO
;  Lives at E000h in the spare 8K above every screen buffer (copied there
;  at start-up by copy_ovl), so it can run whenever a screen buffer is
;  paged into sections C/D - which is always the case outside start-up.
;  Follows the Century arcade game (hunchbkd ROM):
;    title (logo flashes red/green, Esmeralda and Quasimodo hop about it,
;    hearts) -> demo game with FEATURING THE BELLS -> league table
;    (jump: player instructions) -> title ...
; =====================================================================
        org OVLBASE

IBANK   equ 172                     ; feet on the riverbank for the intro run

; ---------------------------------------------------------------------
attract:
        ld sp,stacktop
        call sound_off
        xor a
        ld (demo),a
attract_title:
        call title_run
        jp nz,main_menu             ; any key: the main menu
        jp demo_start

demo_over:                          ; demo time up / demo man died
        ld sp,stacktop
        call sound_off
        xor a
        ld (demo),a
        call league_run
        jp nz,main_menu
        jr attract_title

start_game:
        ld sp,stacktop
        call sound_off
        xor a
        ld (demo),a
        ld a,r
        ld hl,seed
        xor (hl)
        or 1
        ld (hl),a
        jp newgame

; ---------------------------------------------------------------------
; REDEFINE KEYS (R on the title screen)
redefine:
        call text_screen
        ld hl,rd_txt
        call print_list
        ld c,0                      ; action 0 left, 1 right, 2 jump
.a:     push bc
        ld a,c
        add a,a
        add a,a
        add a,a
        add a,a
        add a,72
        ld (rdy),a
        ld d,a
        ld e,64
        ld a,15
        ld (textcol),a
        ld a,c
        ld hl,s_left
        or a
        jr z,.p
        ld hl,s_right
        dec a
        jr z,.p
        ld hl,s_jump
.p:     call print
.k:     call getkey
        pop bc
        push bc
        ld b,c                      ; no key twice
        ld hl,ukeys
        inc b
        jr .d1
.d:     cp (hl)
        jr z,.k
        inc hl
.d1:    djnz .d
        ld (hl),a                   ; hl = ukeys + c
        call kname
        ld a,(rdy)
        ld d,a
        ld e,136
        ld a,11
        ld (textcol),a
        call print
        pop bc
        inc c
        ld a,c
        cp 3
        jr c,.a
        ld b,50
.w:     call wait1
        djnz .w
        jp keyrel

; wait for every key to be up, then -> a = index of the key pressed
getkey:
.u:     call wait1
        call anykey
        jr c,.u
.n:     call wait1
        call anykey
        jr nc,.n
        ret
anykey: ld e,0                      ; -> carry and a = key, if one is down
.l:     ld a,e
        call keytest
        jr nz,.f
        inc e
        ld a,e
        cp 69
        jr c,.l
        and a
        ret
.f:     ld a,e
        scf
        ret

rd_txt: db 30,76,13,"REDEFINE KEYS",0
        db 140,40,8,"PRESS A KEY FOR EACH",0
        db 158,12,8,"CURSORS AND JOYSTICK WORK TOO",0
        db 255
s_left:  db "LEFT",0
s_right: db "RIGHT",0
s_jump:  db "JUMP",0

; ---------------------------------------------------------------------
; helpers
wait1:  ld hl,frames
        ld a,(hl)
.w:     cp (hl)
        jr z,.w
        ret

keyrel: call read_input
        and 7
        jr nz,keyrel
        ret

; hl = frames to wait; NZ if any key was pressed
waitkey:
.l:     push hl
        call wait1
        call anykey
        pop hl
        jr nc,.n
        or 1
        ret
.n:     dec hl
        ld a,h
        or l
        jr nz,.l
        ret

; db y, x, colour, "text", 0 ... 255
print_list:
        ld a,(hl)
        cp 255
        ret z
        ld d,a
        inc hl
        ld e,(hl)
        inc hl
        ld a,(hl)
        ld (textcol),a
        inc hl
        call print
        inc hl
        jr print_list

; black screen in buffer 0, shown, text palette
text_screen:
        ld hl,pal_blk
        call set_palette
        ld a,(spage)
        out (HMPR),a
        or 60h
        out (VMPR),a
        ld e,0
        ld d,0
        ld b,128
        ld c,192
        xor a
        call fill_bytes
        ld hl,pal_text
        call set_palette
        jp keyrel

; a -> hl = hitab + a*14
entry_ptr:
        ld l,a
        ld h,0
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        and a
        sbc hl,de
        ld de,hitab
        add hl,de
        ret

; =====================================================================
;  TITLE
; =====================================================================
title_run:
        call sound_off
        ld hl,pal_blk
        call set_palette
        ld a,(spage)
        ld (cpdst),a
        ld a,(tpage)
        ld hl,8000h
        ld bc,6000h
        call copy_pages             ; HB Main -> screen buffer 0 (left paged in)
        ; take the two figures out of the picture: they move about now
        ld de,256*102+66
        ld bc,256*17+39
        xor a
        call fill_bytes
        ld de,256*22+92
        ld bc,256*8+24
        xor a
        call fill_bytes
        ld e,0                      ; top rows and the credit line
        ld d,0
        ld b,128
        ld c,10
        xor a
        call fill_bytes
        ld e,0
        ld d,172
        ld b,128
        ld c,20
        xor a
        call fill_bytes
        ld hl,title_txt
        call print_list
        ld a,15
        ld (textcol),a
        ld a,15
        ld (textcol),a
        ld hl,hitab
        ld b,6
        ld de,256*2+144
        call print_digits
        ld a,(infl)
        or a
        call nz,cheat_show
        ld a,(spage)
        or 60h
        out (VMPR),a
        ld hl,pal_title
        call set_palette
        call keyrel
        xor a
        ld (tstate),a
        ld hl,0
        ld (ttime),hl
        ld a,27
        ld (lcnt),a
        ld a,53
        ld (fcnt),a
        ld a,1                      ; the logo starts red (arcade)
        ld (lred),a
        call logo_col
        call fig_draw
.loop:  call wait1
        ld a,(frames)               ; PRESS SPACE flashes
        and 16
        ld a,7fh
        jr z,.t1
        xor a
.t1:    ld bc,256*13+CLUTP
        out (c),a
        ld hl,(ttime)
        inc hl
        ld (ttime),hl
        ; logo red <-> green every 0.54 s
        ld hl,lcnt
        dec (hl)
        jr nz,.nl
        ld (hl),27
        ld a,(lred)
        xor 1
        ld (lred),a
        call logo_col
.nl:    ; figures change places every 1.07 s
        ld hl,fcnt
        dec (hl)
        jr nz,.nf
        ld (hl),53
        call fig_erase
        ld a,(tstate)
        inc a
        cp 3
        jr c,.s
        xor a
.s:     ld (tstate),a
        call fig_draw
.nf:    ; after 10.2 s: 24 hearts, one every 2 frames, then on to the demo
        ld hl,(ttime)
        ld de,508
        and a
        sbc hl,de
        jr c,.nh
        ld a,l
        cp 52
        jr nc,.end
        cp 48
        jr nc,.nh
        bit 0,a
        jr nz,.nh
        srl a
        call heart_draw
.nh:    call anykey
        jr nc,.loop
        or 1                        ; NZ: a key was pressed
        ret
.end:   xor a
        ret

logo_col:
        ld a,(lred)
        or a
        ld a,68                     ; green
        jr z,.g
        ld a,35                     ; red
.g:     ld bc,256*10+CLUTP
        out (c),a
        ret

fig_ptr:
        ld a,(tstate)
        add a,a
        add a,a
        ld e,a
        ld d,0
        ld hl,figpos
        add hl,de
        ret

fig_draw:
        call fig_ptr
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld hl,gfx_te
        call draw_block
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,gfx_tq
        jp draw_block

fig_erase:
        call fig_ptr
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl
        ld bc,256*8+24
        xor a
        call fill_bytes
        pop hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld bc,256*17+39
        xor a
        jp fill_bytes

heart_draw:
        add a,a
        ld e,a
        ld d,0
        ld hl,hpos
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,spr_heart
        jp draw_plain

; =====================================================================
;  LEAGUE TABLE / PLAYER INSTRUCTIONS
; =====================================================================
league_run:                         ; NZ = a key was pressed (main menu)
        call league_show
        ld hl,300
        call waitkey
        ret nz
        call instr_show             ; then the player instructions
        ld hl,400
        jp waitkey

league_show:
        call text_screen
        ld hl,league_txt
        call print_list
        ld a,15
        ld (textcol),a
        ld hl,hitab
        ld b,6
        ld de,256*18+104
        call print_digits
        ld b,0
.r:     push bc
        ld a,b
        ld e,a
        ld d,0
        ld hl,rowcol
        add hl,de
        ld a,(hl)
        ld (textcol),a
        ld a,b
        add a,a
        add a,a
        ld c,a
        add a,a
        add a,c                     ; 12 * rank
        add a,58
        ld d,a
        ld e,32
        ld hl,s_no
        call print
        pop bc
        push bc
        ld a,b
        add a,'1'
        call putchar
        pop bc
        push bc
        ld a,b
        push de
        call entry_ptr
        pop de
        ld e,96
        ld b,6
        call print_digits           ; hl -> name
        ld e,168
        ld b,8
.n:     push bc
        ld a,(hl)
        inc hl
        push hl
        call putchar
        pop hl
        ld a,e
        add a,8
        ld e,a
        pop bc
        djnz .n
        pop bc
        inc b
        ld a,b
        cp 5
        jr c,.r
        ret

instr_show:
        call text_screen
        ld hl,instr_txt
        call print_list
        ld hl,spr_bell
        ld de,256*92+128
        call draw_plain
        ld hl,spr_bell
        ld de,256*130+68
        jp draw_plain

; =====================================================================
;  NAME REGISTRATION (after game over, if the score makes the league)
; =====================================================================
gameover_hs:
        ld sp,stacktop
        call sound_off
        ld de,hitab
        ld c,0
.f:     push de
        push bc
        call beats
        pop bc
        pop de
        jr c,.got
        ld hl,14
        add hl,de
        ex de,hl
        inc c
        ld a,c
        cp 5
        jr c,.f
        jp attract
.got:   ld a,c
        ld (nerank),a
        call name_entry
        call insert_entry
        call league_run
        jp nz,start_game
        jp attract

; C if score > entry at de
beats:  ld hl,score
        ld b,6
.l:     ld a,(de)
        cp (hl)
        ret nz
        inc hl
        inc de
        djnz .l
        and a
        ret

insert_entry:
        ld a,(nerank)
        ld b,a
        ld a,4
        sub b
        jr z,.w
        ld l,a                      ; entries to move down * 14
        ld h,0
        add hl,hl
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        and a
        sbc hl,de
        ld b,h
        ld c,l
        ld hl,hitab+55
        ld de,hitab+69
        lddr
.w:     ld a,(nerank)
        call entry_ptr
        ex de,hl
        ld hl,score
        ld bc,6
        ldir
        ld hl,nename
        ld bc,8
        ldir
        ret

name_entry:
        call text_screen
        ld hl,ne_txt
        call print_list
        ld a,8
        ld (textcol),a
        ld hl,t_necur
        ld d,144
        call print_kl
        ld hl,t_nesel
        ld d,154
        call print_kl
        ld a,15
        ld (textcol),a
        ld hl,score
        ld b,6
        ld de,256*34+136
        call print_digits
        ld hl,nename
        ld b,8
.c:     ld (hl),' '
        inc hl
        djnz .c
        xor a
        ld (necur),a
        ld (nelen),a
        ld (keysprev),a
        ld a,30
        ld (nesec),a
        ld a,50
        ld (netime),a
        call ne_grid
        ld a,(necur)
        ld b,NEBOXC
        call ne_box
        call ne_name
        call ne_time
.loop:  call wait1
        ld hl,netime
        dec (hl)
        jr nz,.k
        ld (hl),50
        ld hl,nesec
        dec (hl)
        ret z                       ; time up
        call ne_time
.k:     call read_input
        ld b,a
        ld a,(keysprev)
        cpl
        and b
        ld c,a                      ; newly pressed
        ld a,b
        ld (keysprev),a
        bit 0,c
        jr nz,.left0
        bit 1,c
        jr nz,.right0
        bit 2,c
        jr nz,.sel
        ld a,b                      ; left or right held down: keep moving,
        and 3                       ; after 0.3 s, 10 letters a second
        jp z,.loop
        ld hl,nerep
        dec (hl)
        jp nz,.loop
        ld (hl),5
        bit 0,b
        jr nz,.left
        jr .right
.left0: ld a,15
        ld (nerep),a
        jr .left
.right0:
        ld a,15
        ld (nerep),a
        jr .right
.sel:   ld a,(necur)
        cp 29
        ret z                       ; END
        cp 28
        jr z,.rub
        ld b,a
        ld a,(nelen)
        cp 8
        jp nc,.loop
        ld e,a
        ld d,0
        ld hl,nename
        add hl,de
        ld a,b
        call ne_char
        ld (hl),a
        ld hl,nelen
        inc (hl)
        call ne_name
        jp .loop
.rub:   ld a,(nelen)
        or a
        jp z,.loop
        dec a
        ld (nelen),a
        ld e,a
        ld d,0
        ld hl,nename
        add hl,de
        ld (hl),' '
        call ne_name
        jp .loop
.left:  ld a,(necur)
        or a
        jr nz,.l1
        ld a,30
.l1:    dec a
        jr .mv
.right: ld a,(necur)
        inc a
        cp 30
        jr c,.mv
        xor a
.mv:    push af
        ld a,15
        ld (textcol),a
        ld a,(necur)
        call ne_item
        ld a,(necur)
        ld b,0                      ; rub out its box
        call ne_box
        pop af
        ld (necur),a
        ld a,11
        ld (textcol),a
        ld a,(necur)
        call ne_item
        ld a,(necur)
        ld b,NEBOXC
        call ne_box
        jp .loop

; item 0..27 -> ascii
ne_char:
        cp 26
        jr nc,.p
        add a,'A'
        ret
.p:     sub 26
        ld a,'.'
        ret z
        ld a,'-'
        ret

; position of item a: e = x, d = y (top left), c = width (8, or 24 for RUB / END)
ne_pos: cp 28
        jr c,.ch
        ld c,24
        ld d,122
        ld e,80
        ret z
        ld e,152
        ret
.ch:    ld d,0
.dv:    cp 10
        jr c,.dd
        sub 10
        inc d
        jr .dv
.dd:    add a,a
        add a,a
        add a,a
        ld c,a
        add a,a
        add a,c                     ; 24 * column
        add a,12
        ld e,a
        ld a,d
        add a,a
        add a,a
        add a,a
        add a,a
        add a,74
        ld d,a
        ld c,8
        ret

; draw item a (0-25 letters, 26 '.', 27 '-', 28 RUB, 29 END) in textcol
ne_item:
        push af
        call ne_pos
        pop af
        cp 28
        jr c,.ch
        ld hl,s_rub
        jp z,print
        ld hl,s_end
        jp print
.ch:    call ne_char
        jp putchar

; box round item a in colour b: 16x16 round a letter (4 px clear all round),
; 32x16 round RUB / END
NEBOXC  equ 13
ne_box: push bc
        call ne_pos
        ld a,e
        sub 4
        ld e,a
        ld a,d
        sub 4
        ld d,a
        ld (nebxy),de
        ld a,c
        add a,8
        ld (nebw),a
        pop bc
        ld a,b
        ld (nebc),a
        rlca
        rlca
        rlca
        rlca
        or b
        ld (nebcc),a
        call .h                     ; top
        ld de,(nebxy)
        ld a,d
        add a,15
        ld d,a
        call .h1                    ; bottom
        ld de,(nebxy)
        ld b,14
.v:     inc d                       ; sides
        push bc
        push de
        ld a,(nebc)
        call plot
        ld a,(nebw)
        dec a
        add a,e
        ld e,a
        ld a,(nebc)
        call plot
        pop de
        pop bc
        djnz .v
        ret
.h:     ld de,(nebxy)
.h1:    ld a,(nebw)
        srl a
        ld b,a
        ld c,1
        ld a,(nebcc)
        jp fill_bytes

ne_grid:
        ld b,0
.l:     push bc
        ld a,(necur)
        cp b
        ld a,15
        jr nz,.c
        ld a,11
.c:     ld (textcol),a
        ld a,b
        call ne_item
        pop bc
        inc b
        ld a,b
        cp 30
        jr c,.l
        ret

ne_name:
        ld a,11
        ld (textcol),a
        ld hl,nename
        ld de,256*50+96
        ld b,8
.l:     ld a,(hl)
        inc hl
        cp ' '
        jr nz,.c
        ld a,'-'
.c:     push hl
        push bc
        call putchar
        pop bc
        pop hl
        ld a,e
        add a,8
        ld e,a
        djnz .l
        ret

ne_time:
        ld a,14
        ld (textcol),a
        ld de,256*178+136
        ld a,(nesec)
        ld b,'0'
.t:     cp 10
        jr c,.u
        sub 10
        inc b
        jr .t
.u:     push af
        ld a,b
        call putchar
        ld e,144
        pop af
        add a,'0'
        call putchar
        ld e,152
        ld a,'S'
        jp putchar

; =====================================================================
;  NEW-GAME INTRO: Quasimodo hops right to left along the riverbank of
;  the tower screen, then of screen 1, and leaps up onto the rampart.
;  (The arcade scrolls the castle past him; here the screens stay put.)
; =====================================================================
intro_begin:
        ld a,14                     ; start on Esmeralda's tower (the bell tower)
        ld (level),a
intro_screen:
        call setup_level
        ld a,PS_INTRO
        ld (pstate),a
        ld a,232
        ld (px),a
        ld a,IBANK
        ld (py),a
        ld a,1
        ld (pface),a
        xor a
        ld (ihop),a
        ld (ipart),a
        ld (istep),a
        ld (pjf),a
        inc a
        ld (wfast),a
        call wipe_to_new
        ld a,2
        ld (wfast),a
        ret

intro_next:                         ; gamecmd 5: off the tower screen, on to screen 1
        call clear_sprites
        xor a
        ld (level),a
        call intro_screen
        jp gameloop

intro_tick:
        ld a,(ipart)
        or a
        jr nz,.leap
        ld b,3                      ; 75 px/s (arcade 60, but here two screens)
        ld a,(px)
        sub b
        jr c,.edge
        ld (px),a
        ld c,a
        ld a,(level)
        or a
        jr nz,.hop
        ld a,c
        cp 36
        jr c,.toleap
.hop:   ld hl,ihop                  ; a hop every 11 ticks (0.44 s), 12 px high
        ld a,(hl)
        inc a
        cp 11
        jr c,.h1
        xor a
.h1:    ld (hl),a
        or a
        ld a,SND_JUMP
        call z,snd_play
        ld a,(ihop)
        cp 10
        ld a,SND_STEP
        call z,snd_play
        ld a,(ihop)
        ld e,a
        ld d,0
        ld hl,hoptab
        add hl,de
        ld a,IBANK
        sub (hl)
        ld (py),a
        ld hl,hopfrm
        add hl,de
        ld a,(hl)
        ld (pjf),a
        ret
.edge:  ld a,5
        ld (gamecmd),a
        ret
.toleap:
        ld a,1
        ld (ipart),a
        xor a
        ld (ihop),a
        ld a,SND_JUMP
        jp snd_play
.leap:  ld hl,ihop                  ; up onto the rampart at the start
        inc (hl)
        ld a,(hl)
        cp 15
        jr nc,.done
        ld e,a
        ld d,0
        ld hl,leapx-1
        add hl,de
        ld a,(hl)
        ld (px),a
        ld hl,leapy-1
        add hl,de
        ld a,(hl)
        ld (py),a
        ld hl,leapf-1
        add hl,de
        ld a,(hl)
        ld (pjf),a
        ret
.done:  ld a,PSTART
        ld (px),a
        ld a,FLOOR
        ld (py),a
        xor a
        ld (pface),a
        ld (pwalk),a
        ld a,PS_WALK
        ld (pstate),a
        ld a,SND_STEP
        jp snd_play

hoptab: db 0,4,7,9,11,12,11,9,7,4,1
hopfrm: db 1,2,3,4,4,5,5,6,6,7,0
leapx:  db 32,30,28,26,24,22,20,18,16,14,14,12,10,8
leapy:  db 157,143,129,117,106,97,90,86,83,81,82,84,86,89
leapf:  db 1,2,2,3,3,4,4,5,5,5,6,6,7,7

; =====================================================================
;  DEMO GAME (silent, as the arcade attract mode)
; =====================================================================
demo_start:
        ld a,1
        ld (demo),a
        ld hl,0
        ld (dtime),hl
        xor a
        ld (ddir),a
        ld a,226
        ld (textx),a
        jp newgame

; a = real keys -> keys for the demo man
demo_input:
        call anykey
        jr nc,.ai
        ld a,3                      ; any key: the main menu
        ld (gamecmd),a
        xor a
        ret
.ai:    ld a,(pstate)
        cp PS_WALK
        jr nz,.none
        ld ix,haz
        call .thr
        or a
        jr nz,.jump
        ld ix,haz+HZSIZE
        call .thr
        or a
        jr nz,.jump
        ld a,(px)                   ; wander between x 70 and 180
        cp 180
        jr c,.p1
        ld a,1
        ld (ddir),a
.p1:    ld a,(px)
        cp 70
        jr nc,.p2
        xor a
        ld (ddir),a
.p2:    ld a,(ddir)
        or a
        ld a,2
        ret z
        ld a,1
        ret
.jump:  ld a,4
        ret
.none:  xor a
        ret
.thr:   ld a,(ix+0)                 ; 1 if a low missile is 38..51 px ahead
        or a
        ret z
        ld a,(ix+2)
        cp 75
        jr c,.no
        ld a,(px)
        ld b,a
        ld a,(ix+1)
        sub b
        jr c,.no
        cp 38
        jr c,.no
        cp 52
        jr nc,.no
        ld a,1
        ret
.no:    xor a
        ret

; every tick of the demo (back buffer paged in, before the sprites)
demo_frame:
        ld a,(pstate)
        cp PS_INTRO
        ret z
        ld hl,(dtime)
        inc hl
        ld (dtime),hl
        ld de,400                   ; 16 s of play, then the league table
        and a
        sbc hl,de
        jr c,.t
        ld a,4
        ld (gamecmd),a
        ret
.t:     ld hl,(dtime)
        ld de,225                   ; 9 s in: FEATURING THE BELLS
        and a
        sbc hl,de
        ret c
        ld a,h                      ; drawn while it slides in (+2 ticks for
        or a                        ; both buffers); after that the sprites'
        ret nz                      ; save-under keeps it
        ld a,l
        cp 88
        ret nc
        cp 2                        ; FEATURING stays put: once per buffer
        jr nc,.f
        ld a,5
        ld (textcol),a
        ld hl,s_feat
        ld de,256*42+92
        call print
.f:
        ld a,(textx)
        cp 58
        jr c,big_text
        sub 2
        ld (textx),a
; THE BELLS in double-size letters at textx, sliding in from x 224
big_text:
        ld a,(textx)
        ld e,a
        ld hl,s_bells
.l:     ld a,(hl)
        or a
        jr z,.end
        ld a,e
        cp 224-15
        jr nc,.end
        ld a,(hl)
        inc hl
        push hl
        push de
        call big_char
        pop de
        pop hl
        ld a,e
        add a,16
        ld e,a
        jr .l
.end:   ld a,e                      ; clear the 4 px the text has just left
        cp 224
        ret nc
        ld d,54
        ld b,2
        ld c,14
        xor a
        jp fill_bytes

; a = ascii, e = x (even), y 54, 16x14, colour 2
big_char:
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
        sbc hl,bc
        ld bc,gfx_font
        add hl,bc                   ; glyph (7 rows)
        push hl
        ld d,54
        call addr_xy                ; hl = screen
        pop de
        ld b,7
.r:     push bc
        ld a,(de)
        inc de
        push de
        ld c,a
        push hl
        ld b,8
.c:     xor a
        rl c
        jr nc,.z
        ld a,22h
.z:     ld (hl),a
        inc hl
        djnz .c
        pop hl
        push hl
        ld de,128
        ex de,hl
        add hl,de                   ; hl = next row, de = this row
        ex de,hl
        ld bc,8
        ldir                        ; double the row
        pop hl
        ld de,256
        add hl,de
        pop de
        pop bc
        djnz .r
        ret

; =====================================================================
;  DATA
; =====================================================================
; Esmeralda x,y ; Quasimodo x,y  for each of the three title positions
figpos: db 92,22, 66,102            ; as drawn on HB Main
        db 76,116, 194,46
        db 204,60, 66,102

; the 24 hearts (arcade positions mapped to the SAM screen)
hpos:   db 152,10,192,29,120,98,40,123,176,142,16,16,16,79,112,41
        db 104,142,208,104,24,154,168,98,200,10,192,148,104,10,208,85
        db 120,148,208,29,16,48,144,35,64,166,208,10,72,29,144,10

rowcol: db 10,5,2,9,8

pal_blk:   db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
pal_title: db 0,18,17,13,36,34,68,112,0,65,68,110,10,0,114,127
pal_text:  db 0,18,17,13,36,34,106,112,85,65,68,110,10,59,114,127

title_txt:
        db 2,72,15,"HI SCORE",0
        db 255
t_necur: db 1," ",2,"  MOVE CURSOR",0
t_nesel: db 3,"  SELECT LETTER",0

league_txt:
        db 8,96,13,"HI SCORE",0
        db 32,32,1,"LEAGUE",0
        db 42,32,1,"ORDER",0
        db 42,96,1,"SCORE",0
        db 42,168,1,"NAME",0
        db 124,56,6,"BONUS MAN AT 10000",0
        db 142,40,13,"PRESS YOUR JUMP BUTTON",0
        db 152,100,2,"TO READ",0
        db 162,52,2,"PLAYER INSTRUCTIONS",0
        db 176,72,15,"COPYRIGHT 1983",0
        db 184,24,15,"CENTURY ELECTRONICS UK LTD",0
        db 255

instr_txt:
        db 14,52,13,"PLAYER INSTRUCTIONS",0
        db 40,40,8,"JOYSTICK CONTROLS HERO",0
        db 58,48,2,"PRESS BUTTON TO JUMP",0
        db 76,64,10,"SCORE EACH PHASE",0
        db 96,32,13,"HERO WINS A",0
        db 96,152,13,"EACH TIME",0
        db 114,52,6,"HE COMPLETES A WALL",0
        db 134,28,14,"FIVE",0
        db 134,92,14,"GIVES SUPER BONUS",0
        db 176,72,15,"COPYRIGHT 1983",0
        db 184,24,15,"CENTURY ELECTRONICS UK LTD",0
        db 255

ne_txt:
        db 14,60,13,"NAME REGISTRATION",0
        db 34,72,15,"SCORE",0
        db 50,48,15,"NAME",0
        db 164,48,8,"SELECT END TO FINISH",0
        db 178,96,14,"TIME",0
        db 255

s_no:    db "NO",0
s_rub:   db "RUB",0
s_end:   db "END",0
s_feat:  db "FEATURING",0
s_bells: db "THE BELLS",0

        include "gfx_ovl.asm"
ovlend:
        assert ovlend <= SNDBASE
