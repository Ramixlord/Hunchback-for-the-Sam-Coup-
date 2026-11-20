; Boot stub: loaded with the game at 32768 (section C) by SAM BASIC and
; auto-run. Picks a free page pair for the game code, copies the main
; image there, pages it into sections A/B (ROM off) and jumps to it.
; The title picture follows in the file at 65536 (page b+2).
LMPR    equ 250
HMPR    equ 251
VMPR    equ 252

        org 8000h
boot:   di
        ld sp,0FFFEh                ; own stack (BASIC's may be overwritten)
        in a,(HMPR)
        and 31
        ld b,a                      ; page holding this code
        ld c,b                      ; the title picture comes in the game file
        inc c                       ; at 65536: two pages after this one
        inc c
        ld hl,kcand
.k:     ld a,(hl)
        inc hl
        ld e,a                      ; not this file's pages (b..b+3)
        sub b
        inc a
        cp 6
        jr c,.k
        ld a,e
        sub c
        inc a
        cp 3
        jr c,.k
        ld a,e
        or 20h                      ; RAM in section A
        out (LMPR),a
        push de
        push bc
        ld hl,mainimg
        ld de,0
        ld bc,MAINLEN
        ldir
        pop bc
        pop de
        ld a,e
        ld (3),a
        ld a,b
        ld (4),a
        ld a,c
        ld (5),a
        jp 0
kcand:  db 2,4,6,8,10,12
mainimg:
