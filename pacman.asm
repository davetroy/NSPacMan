; ============================================================================
; PAC-MAN for the NorthStar Advantage
; Boots via the greenfield stage1 loader (payload at 0x8000).
; Bitmap maze, save-under sprites, chase AI, frightened mode, beeper sound.
; Honors the real-hardware contract: IOCTL bit 4 always held.
; ============================================================================

IOCTL:    equ 0f8h
STAT1:    equ 0e0h
STAT2:    equ 0d0h
CLRDISP:  equ 0b0h
SCANREG:  equ 090h
MAP0:     equ 0a0h
MAP1:     equ 0a1h

LEFT_COL: equ 12
SHIFT:    equ 0b000h            ; preshifted glyphs: 7 x 8 shifts x 16 bytes

pacpx:    equ 0c900h
pacpy:    equ 0c901h
pacdir:   equ 0c902h            ; 0 R, 1 L, 2 U, 3 D, 4 stopped
pacwant:  equ 0c903h
gtab:     equ 0c908h            ; 4 ghosts x 8: px,py,dir,state,timer,pers,-,-
scorelo:  equ 0c928h
scorehi:  equ 0c929h
lives:    equ 0c92ah
dotslo:   equ 0c92bh
dotshi:   equ 0c92ch
dotseat:  equ 0c92dh
frtimer:  equ 0c92eh            ; 2 bytes
frames:   equ 0c930h
wakaflip: equ 0c931h
seed:     equ 0c932h            ; 2 bytes
rowy:     equ 0c934h
hudflag:  equ 0c935h
mk_sc:    equ 0c936h
mk_gc:    equ 0c937h
pilla:    equ 0c938h            ; 4 flags
hitflag:  equ 0c93ch
dots_ram: equ 0c940h            ; 124 bytes
saves:    equ 0c9c0h            ; 5 x 24 (ghosts 0-3, pac at +96)
walbuf:   equ 0ca40h              ; 8-byte built wall tile
walflg:   equ 0ca48h              ; bit0 N open, 1 S, 2 W, 3 E
lastt:    equ 0ca50h              ; 5 x 4: px,py,glyph,valid
sndreq:   equ 0ca68h              ; deferred: 1 waka, 2 pill, 4 ghost-eaten
introfl:  equ 0ca6ah              ; play the intro tune at next READY
pillvis:  equ 0ca6bh              ; power pills currently lit?
sirph:    equ 0ca6ch              ; siren triangle phase (mothballed)
chaink:   equ 0ca6dh              ; ghost-eat chain within one pill
level:    equ 0ca6eh              ; mazes completed this game
bonusfl:  equ 0ca6fh              ; extra life awarded?
csx:      equ 0ca80h              ; cutscene pac x
csnp:     equ 0ca82h              ; cutscene tune pointer (2)
hsidx:    equ 0ca84h              ; high-score insertion index
hsins:    equ 0ca85h              ; -> initials slot in table (2)
HST:      equ 0cb00h              ; 10 entries x 5: I,I,I,scorehi,scorelo
SAVBUF:   equ 0a200h              ; track 4 sector 5 lands here at boot
HSTRK:    equ 4                   ; save track: empty except for the scores
HSSEC:    equ 5
DCTL:     equ 0a1h                ; drive control: bit7 | dir-in | drive 1
work:     equ 0ca70h              ; 5 x 4: new px,py,glyph,dirty

        org 08000h

start:
        di
        ld   sp,0fe00h
        ld   a,0f8h
        out  (MAP0),a
        ld   a,0f9h
        out  (MAP1),a
        xor  a
        out  (SCANREG),a
        out  (CLRDISP),a
        ld   a,10h              ; display on, bit4 held
        out  (IOCTL),a

        ld   a,r
        ld   (seed),a
        ld   a,r
        cpl
        or   1
        ld   (seed+1),a

        call mkshift
        ld   hl,lastt           ; invalidate sprite shadows + sound queue
        ld   b,32
iv1:
        ld   (hl),0
        inc  hl
        djnz iv1
        call hsload             ; saved table from disk, else ROM seeds
        jp   attract

newgame:
        ld   sp,0fe00h          ; clean stack (ESC reset can arrive mid-call)
        xor  a
        ld   (scorelo),a
        ld   (scorehi),a
        ld   a,3
        ld   (lives),a
        xor  a
        ld   (level),a
        ld   (bonusfl),a
        ld   a,1
        ld   (introfl),a

newlevel:
        call initdots
        call cls
        ld   hl,lastt+3         ; fresh canvas: forget on-screen sprites
        ld   de,4
        ld   b,5
nl1:
        ld   (hl),0
        add  hl,de
        djnz nl1
        call drawmaze
        call drawhud

restart:
        call resetpos
        call drawlives
        call spriteupd
        call ready

mainloop:
        call fsync
        call kpoll
        call movepac
        call moveghosts
        call collide
        ld   a,(hitflag)
        or   a
        jp   nz,pacdied
        call spriteupd          ; erase+redraw only what changed
        ld   a,(hudflag)
        or   a
        call nz,drawscore
        call ckbonus
        call sndplay
        ld   hl,(frtimer)
        ld   a,h
        or   l
        jr   z,ml1
        dec  hl
        ld   (frtimer),hl
        ld   a,h
        or   l
        call z,unfright
ml1:
        ld   a,(frames)
        and  0fh
        call z,pillblink        ; flash the power pills every 16 frames
        ld   hl,frames
        inc  (hl)
        ld   a,(dotslo)
        ld   hl,dotshi
        or   (hl)
        jp   nz,mainloop
        call sndwin
        ld   hl,level
        inc  (hl)
        ld   a,(hl)
        and  1
        call z,cutscene         ; intermission after every second maze
        jp   newlevel

; ---------------------------------------------------------------------------
movepac:
        ld   a,(pacpx)
        and  7
        jr   nz,mp_go
        ld   a,(pacpy)
        and  7
        jr   nz,mp_go
        ld   a,(pacwant)        ; aligned: try wanted direction
        cp   4
        jr   nc,mp_keep
        call paccan
        jr   nz,mp_keep
        ld   a,(pacwant)
        ld   (pacdir),a
mp_keep:
        ld   a,(pacdir)
        cp   4
        ret  z
        call paccan
        jr   z,mp_eat
        ld   a,4
        ld   (pacdir),a
        ret
mp_eat:
        call eathere
mp_go:
        ld   a,(pacdir)
        cp   4
        ret  z
        ld   hl,pacpx
        call stepdir
        ld   a,(pacpx)          ; tunnel wrap
        cp   224
        ret  c
        cp   240
        ld   a,0
        jr   c,mp_w0
        ld   a,223
mp_w0:
        ld   (pacpx),a
        ret

; paccan — in: A=dir. out: Z = pac may move that way from its tile.
paccan:
        ld   c,a
        ld   a,(pacpx)
        rrca
        rrca
        rrca
        and  1fh
        ld   d,a
        ld   a,(pacpy)
        rrca
        rrca
        rrca
        and  1fh
        ld   e,a
        call adddir
        call passable
        ret  nz
        ld   hl,doortab         ; ghost-house door blocks pac
        ld   b,2
pcd1:
        ld   a,(hl)
        inc  hl
        cp   d
        jr   nz,pcd2
        ld   a,(hl)
        cp   e
        jr   nz,pcd2
        or   1
        ret
pcd2:
        inc  hl
        djnz pcd1
        xor  a
        ret

; adddir — D,E (tx,ty) += delta for dir C
adddir:
        push bc
        ld   hl,dxtab
        ld   b,0
        add  hl,bc
        ld   a,(hl)
        add  a,d
        ld   d,a
        ld   hl,dytab
        add  hl,bc
        ld   a,(hl)
        add  a,e
        ld   e,a
        pop  bc
        ret

; passable — tile (D,E): Z = open (walls only)
passable:
        ld   a,e
        cp   14
        jr   nz,ps1
        ld   a,d
        cp   28
        jr   c,ps1
        xor  a                  ; tunnel: off-map row 14 is open
        ret
ps1:
        push bc
        push de
        ld   a,e
        add  a,a
        add  a,a
        ld   l,a
        ld   h,0
        ld   bc,wallrows
        add  hl,bc
        ld   a,d
        rrca
        rrca
        rrca
        and  3
        ld   c,a
        ld   b,0
        add  hl,bc
        ld   a,d
        and  7
        ld   c,a
        ld   e,(hl)             ; wall byte
        ld   hl,masktab
        add  hl,bc
        ld   a,(hl)
        and  e
        pop  de
        pop  bc
        ret

; stepdir — HL -> px(,py), A = dir: move 1px
stepdir:
        push bc
        ld   c,a
        ld   b,0
        push hl
        ld   hl,dxtab
        add  hl,bc
        ld   d,(hl)
        ld   hl,dytab
        add  hl,bc
        ld   e,(hl)
        pop  hl
        ld   a,(hl)
        add  a,d
        ld   (hl),a
        inc  hl
        ld   a,(hl)
        add  a,e
        ld   (hl),a
        dec  hl
        pop  bc
        ret

; ---------------------------------------------------------------------------
eathere:
        ld   a,(pacpx)
        rrca
        rrca
        rrca
        and  1fh
        ld   d,a
        ld   a,(pacpy)
        rrca
        rrca
        rrca
        and  1fh
        ld   e,a
        ; dot bitmap bit
        ld   a,e
        add  a,a
        add  a,a
        ld   l,a
        ld   h,0
        ld   bc,dots_ram
        add  hl,bc
        ld   a,d
        rrca
        rrca
        rrca
        and  3
        ld   c,a
        ld   b,0
        add  hl,bc
        ld   a,d
        and  7
        ld   c,a
        push hl
        ld   hl,masktab
        add  hl,bc
        ld   b,(hl)
        pop  hl
        ld   a,(hl)
        and  b
        jr   z,eh_pill
        ld   a,b
        cpl
        and  (hl)
        ld   (hl),a
        ld   a,d                ; clear dot pixels (doubled: 2 cols)
        add  a,a
        add  a,LEFT_COL
        ld   h,a
        ld   a,e
        add  a,a
        add  a,a
        add  a,a
        add  a,3
        ld   l,a
        ld   a,(hl)
        and  0fch
        ld   (hl),a
        inc  l
        ld   a,(hl)
        and  0fch
        ld   (hl),a
        inc  h
        ld   a,(hl)
        and  03fh
        ld   (hl),a
        dec  l
        ld   a,(hl)
        and  03fh
        ld   (hl),a
        ld   d,h                ; scrub all four bytes from pac's save-under
        ld   e,l                ; (col+1, row+3)
        ld   c,03fh
        push de
        call scrub
        pop  de
        push de
        inc  e
        ld   c,03fh
        call scrub
        pop  de
        push de
        dec  d
        ld   c,0fch
        call scrub
        pop  de
        dec  d
        inc  e
        ld   c,0fch
        call scrub
        ld   a,1
        call addscore
        call decdots
        ld   hl,dotseat
        inc  (hl)
        ld   hl,sndreq
        ld   a,(hl)
        or   1
        ld   (hl),a
        ret
eh_pill:
        ld   hl,pilltab
        ld   iy,pilla
        ld   b,4
eh_p1:
        ld   a,(iy+0)
        or   a
        jr   z,eh_p2
        ld   a,(hl)
        cp   d
        jr   nz,eh_p2
        inc  hl
        ld   a,(hl)
        dec  hl
        cp   e
        jr   nz,eh_p2
        ld   (iy+0),0
        push hl
        ld   a,d
        add  a,a
        add  a,LEFT_COL
        ld   h,a
        ld   a,e
        add  a,a
        add  a,a
        add  a,a
        add  a,1
        ld   l,a
        ld   b,6
eh_p3:
        ld   (hl),0
        inc  h
        ld   (hl),0
        dec  h
        inc  l
        djnz eh_p3
        ld   d,h                ; scrub pill from pac's save-under (2 cols)
        ld   e,l
        ld   b,6
eh_p4:
        dec  e
        push bc
        push de
        ld   c,0
        call scrub
        pop  de
        push de
        inc  d
        ld   c,0
        call scrub
        pop  de
        pop  bc
        djnz eh_p4
        pop  hl
        ld   a,5
        call addscore
        call decdots
        call frighten
        ld   hl,sndreq
        ld   a,(hl)
        or   2
        ld   (hl),a
        ret
eh_p2:
        inc  hl
        inc  hl
        inc  iy
        djnz eh_p1
        ret

decdots:
        push hl
        ld   hl,(dotslo)
        dec  hl
        ld   (dotslo),hl
        pop  hl
        ret

frighten:
        ld   hl,900
        ld   (frtimer),hl
        xor  a
        ld   (chaink),a
        ld   ix,gtab
        ld   b,4
fg1:
        ld   a,(ix+3)
        cp   1
        jr   nz,fg2
        ld   (ix+3),2
        push bc
        ld   c,(ix+2)           ; reverse
        ld   b,0
        ld   hl,revtab
        add  hl,bc
        ld   a,(hl)
        ld   (ix+2),a
        pop  bc
fg2:
        ld   de,8
        add  ix,de
        djnz fg1
        ret

unfright:
        ld   ix,gtab
        ld   b,4
uf1:
        ld   a,(ix+3)
        cp   2
        jr   nz,uf2
        ld   (ix+3),1
uf2:
        ld   de,8
        add  ix,de
        djnz uf1
        ret

; ---------------------------------------------------------------------------
moveghosts:
        ld   ix,gtab
        ld   b,4
        ld   c,0
mgs1:
        push bc
        call moveghost
        pop  bc
        ld   de,8
        add  ix,de
        inc  c
        djnz mgs1
        ret

moveghost:                      ; IX -> ghost, C = index
        ld   a,(ix+3)
        or   a
        jr   z,mg_house
        cp   3
        jr   z,mg_eaten
        cp   2
        jr   nz,mg_run
        ld   a,(frames)         ; frightened: half speed
        rrca
        ret  c
mg_run:
        ld   a,(ix+0)
        and  7
        jr   nz,mg_step
        ld   a,(ix+1)
        and  7
        jr   nz,mg_step
        call pickdir
mg_step:
        push ix
        pop  hl
        ld   a,(ix+2)
        call stepdir
        ld   a,(ix+0)
        cp   224
        ret  c
        cp   240
        ld   a,0
        jr   c,mg_w0
        ld   a,223
mg_w0:
        ld   (ix+0),a
        ret
mg_house:
        ld   hl,reltab
        ld   b,0
        add  hl,bc
        ld   a,(dotseat)
        cp   (hl)
        ret  c
        ld   (ix+3),1
        ld   (ix+2),2
        ret
mg_eaten:
        dec  (ix+4)
        ret  nz
        ld   (ix+3),1
        ld   (ix+2),2
        ret

pickdir:
        ld   a,(ix+3)
        cp   2
        jr   z,pk_rand
        ld   a,(ix+5)           ; personality: sometimes go random
        or   a
        jr   z,pk_best
        ld   b,a
        call rnd
        and  b
        jr   nz,pk_best
pk_rand:
        ld   b,8
pk_r1:
        push bc
        call rnd
        and  3
        ld   c,a
        call gcan
        pop  bc
        jr   nz,pk_r2
        push bc
        call rnd                ; C survived? redo: recompute candidate
        pop  bc
        ld   a,(ix+6)           ; (ix+6) holds last candidate — see gcan
        ld   (ix+2),a
        ret
pk_r2:
        djnz pk_r1
pk_best:
        ld   b,4
        ld   c,0
        ld   d,0ffh             ; best dist
        ld   e,0ffh             ; best dir
pk_b1:
        push bc
        push de
        call gcan
        pop  de
        pop  bc
        jr   nz,pk_b3
        push bc
        push de
        call gdist
        pop  de
        pop  bc
        cp   d
        jr   nc,pk_b3
        ld   d,a
        ld   e,c
pk_b3:
        inc  c
        djnz pk_b1
        ld   a,e
        cp   0ffh
        jr   nz,pk_b4
        push bc
        ld   c,(ix+2)           ; nothing valid: reverse
        ld   b,0
        ld   hl,revtab
        add  hl,bc
        ld   e,(hl)
        pop  bc
pk_b4:
        ld   (ix+2),e
        ret

; gcan — ghost IX may move in dir C? (not reverse, tile open) Z = yes
; also records C at (ix+6) for the random picker.
gcan:
        ld   (ix+6),c
        push bc
        ld   b,0
        push bc
        ld   c,(ix+2)
        ld   hl,revtab
        add  hl,bc
        pop  bc
        ld   a,(hl)
        pop  bc
        cp   c
        jr   nz,gc1
        or   1
        ret
gc1:
        ld   a,(ix+0)
        rrca
        rrca
        rrca
        and  1fh
        ld   d,a
        ld   a,(ix+1)
        rrca
        rrca
        rrca
        and  1fh
        ld   e,a
        call adddir
        jp   passable

; gdist — |tile+delta(C) - pactile| manhattan. A = dist
gdist:
        ld   a,(ix+0)
        rrca
        rrca
        rrca
        and  1fh
        ld   d,a
        ld   a,(ix+1)
        rrca
        rrca
        rrca
        and  1fh
        ld   e,a
        call adddir
        ld   a,(pacpx)
        rrca
        rrca
        rrca
        and  1fh
        sub  d
        jr   nc,gd1
        neg
gd1:
        ld   b,a
        ld   a,(pacpy)
        rrca
        rrca
        rrca
        and  1fh
        sub  e
        jr   nc,gd2
        neg
gd2:
        add  a,b
        ret

; ---------------------------------------------------------------------------
collide:
        xor  a
        ld   (hitflag),a
        ld   ix,gtab
        ld   b,4
cd1:
        push bc
        ld   a,(ix+3)
        cp   1
        jr   z,cd_chk
        cp   2
        jr   nz,cd_nx
cd_chk:
        ld   a,(pacpx)
        sub  (ix+0)
        jr   nc,cd2
        neg
cd2:
        cp   6
        jr   nc,cd_nx
        ld   a,(pacpy)
        sub  (ix+1)
        jr   nc,cd3
        neg
cd3:
        cp   6
        jr   nc,cd_nx
        ld   a,(ix+3)
        cp   2
        jr   z,cd_eat
        ld   a,1
        ld   (hitflag),a
        jr   cd_nx
cd_eat:
        ld   d,(ix+0)           ; where the meal happened
        ld   e,(ix+1)
        ld   (ix+3),3
        ld   (ix+4),120
        ld   (ix+0),104
        ld   (ix+1),112
        push ix
        push bc
        call eatshow
        pop  bc
        pop  ix
cd_nx:
        ld   de,8
        add  ix,de
        pop  bc
        djnz cd1
        ret

pacdied:
        ld   b,45               ; freeze the fatal moment (~3/4 s)
pd_f:
        push bc
        call fsync
        pop  bc
        djnz pd_f
        call sprwipe
        call deathfx
        call dbloops
        ld   hl,lives
        dec  (hl)
        jp   nz,restart
        ld   a,137
        ld   (rowy),a
        ld   b,31
        ld   hl,str_over
        call puts
        ld   b,120              ; ~2 s
go_w:
        push bc
        call fsync
        pop  bc
        djnz go_w
        call hscheck            ; new high score? -> initials entry
        jp   attract

; ---------------------------------------------------------------------------
; spriteupd — two-pass, overlap-aware:
;   1. compute every entity's new (px,py,glyph) into work[]
;   2. dirty = differs from last drawn (or never drawn)
;   3. propagate: an on-screen clean sprite overlapping any dirty sprite's
;      old or new window becomes dirty too (keeps LIFO honest at crossings)
;   4. erase pass in REVERSE draw order, draw pass in draw order
; ---------------------------------------------------------------------------
spriteupd:
        ld   a,(gtab+3)
        cp   3
        ld   c,0ffh
        jr   z,swg0
        ld   c,5
        cp   2
        jr   nz,swg0
        ld   c,6
swg0:
        ld   a,(gtab)
        ld   (work+0),a
        ld   a,(gtab+1)
        ld   (work+1),a
        ld   a,c
        ld   (work+2),a
        ld   a,(gtab+8+3)
        cp   3
        ld   c,0ffh
        jr   z,swg1
        ld   c,5
        cp   2
        jr   nz,swg1
        ld   c,6
swg1:
        ld   a,(gtab+8)
        ld   (work+4),a
        ld   a,(gtab+8+1)
        ld   (work+5),a
        ld   a,c
        ld   (work+6),a
        ld   a,(gtab+16+3)
        cp   3
        ld   c,0ffh
        jr   z,swg2
        ld   c,5
        cp   2
        jr   nz,swg2
        ld   c,6
swg2:
        ld   a,(gtab+16)
        ld   (work+8),a
        ld   a,(gtab+16+1)
        ld   (work+9),a
        ld   a,c
        ld   (work+10),a
        ld   a,(gtab+24+3)
        cp   3
        ld   c,0ffh
        jr   z,swg3
        ld   c,5
        cp   2
        jr   nz,swg3
        ld   c,6
swg3:
        ld   a,(gtab+24)
        ld   (work+12),a
        ld   a,(gtab+24+1)
        ld   (work+13),a
        ld   a,c
        ld   (work+14),a
        ; pac
        ld   a,(pacdir)
        cp   4
        jr   nz,swpa
        ld   c,0
        jr   swpc
swpa:
        ld   c,a
        ld   a,(frames)
        and  4
        jr   nz,swpb
        ld   c,0
        jr   swpc
swpb:
        inc  c
swpc:
        ld   a,(pacpx)
        ld   (work+16),a
        ld   a,(pacpy)
        ld   (work+17),a
        ld   a,c
        ld   (work+18),a

        ; ---- dirty flags ----
        ld   ix,work
        ld   iy,lastt
        ld   b,5
sud1:
        ld   a,(iy+3)
        or   a
        jr   z,sud2
        ld   a,(ix+0)
        cp   (iy+0)
        jr   nz,sud2
        ld   a,(ix+1)
        cp   (iy+1)
        jr   nz,sud2
        ld   a,(ix+2)
        cp   (iy+2)
        jr   nz,sud2
        ld   (ix+3),0
        jr   sud3
sud2:
        ld   (ix+3),1
sud3:
        ld   de,4
        add  ix,de
        add  iy,de
        djnz sud1

        ; ---- overlap propagation, two sweeps ----
        ld   b,2
prop:
        push bc
        ld   ix,work
        ld   iy,lastt
        ld   b,5
pr_i:
        push bc
        ld   a,(ix+3)
        or   a
        jr   nz,pr_in
        ld   a,(iy+3)
        or   a
        jr   z,pr_in
        ld   hl,work
        ld   de,lastt
        ld   c,5
pr_j:
        push hl
        push de
        inc  hl
        inc  hl
        inc  hl
        ld   a,(hl)             ; work_j dirty?
        or   a
        jr   z,pr_jn
        pop  de
        push de
        ld   a,(de)             ; last_j px
        sub  (iy+0)
        jr   nc,pr_a1
        neg
pr_a1:
        cp   12
        jr   nc,pr_nw
        pop  de
        push de
        inc  de
        ld   a,(de)             ; last_j py
        sub  (iy+1)
        jr   nc,pr_a2
        neg
pr_a2:
        cp   8
        jr   c,pr_hit
pr_nw:
        pop  de
        pop  hl
        push hl
        push de
        ld   a,(hl)             ; work_j px
        sub  (iy+0)
        jr   nc,pr_a3
        neg
pr_a3:
        cp   12
        jr   nc,pr_jn
        pop  de
        pop  hl
        push hl
        push de
        inc  hl
        ld   a,(hl)             ; work_j py
        sub  (iy+1)
        jr   nc,pr_a4
        neg
pr_a4:
        cp   8
        jr   nc,pr_jn
pr_hit:
        ld   (ix+3),1
pr_jn:
        pop  de
        pop  hl
        inc  hl
        inc  hl
        inc  hl
        inc  hl
        inc  de
        inc  de
        inc  de
        inc  de
        dec  c
        jr   nz,pr_j
pr_in:
        ld   de,4
        add  ix,de
        add  iy,de
        pop  bc
        djnz pr_i
        pop  bc
        dec  b
        jp   nz,prop

        ; ---- erase pass: reverse of draw order (g3..g0, then pac last,
        ;      so the player sprite has the shortest absent window) ----
        ld   hl,ordrev
        ld   b,5
er2_i:
        push bc
        push hl
        ld   a,(hl)
        call getent
        ld   a,(ix+3)           ; dirty?
        or   a
        jr   z,er2_n
        inc  hl
        inc  hl
        inc  hl
        ld   a,(hl)             ; lastt.valid?
        or   a
        jr   z,er2_n
        dec  hl
        dec  hl
        dec  hl
        ld   a,(hl)
        ld   d,a
        inc  hl
        ld   a,(hl)
        ld   e,a
        call sprrest
er2_n:
        pop  hl
        inc  hl
        pop  bc
        djnz er2_i

        ; ---- draw pass: pac first (on screen soonest), then ghosts ----
        ld   hl,orddrw
        ld   b,5
dw2_i:
        push bc
        push hl
        ld   a,(hl)
        call getent
        ld   a,(ix+3)
        or   a
        jr   z,dw2_n
        ld   a,(ix+2)
        cp   0ffh
        jr   nz,dw2_d
        inc  hl
        inc  hl
        inc  hl
        ld   (hl),0
        jr   dw2_n
dw2_d:
        ld   d,(ix+0)
        ld   e,(ix+1)
        push hl
        call sprsave
        ld   a,(ix+2)
        call sprdraw
        pop  hl
        ld   a,(ix+0)
        ld   (hl),a
        inc  hl
        ld   a,(ix+1)
        ld   (hl),a
        inc  hl
        ld   a,(ix+2)
        ld   (hl),a
        inc  hl
        ld   (hl),1
dw2_n:
        pop  hl
        inc  hl
        pop  bc
        djnz dw2_i
        ret

ordrev: db 3,2,1,0,4            ; erase order (reverse of draw)
orddrw: db 4,0,1,2,3            ; draw order: pac first, ghosts on top

; getent — A = entity index -> IX = work entry, HL = lastt entry, IY = save buf
getent:
        ld   c,a
        add  a,a
        add  a,a
        ld   e,a
        ld   d,0
        ld   ix,work
        add  ix,de
        ld   hl,lastt
        add  hl,de
        ld   a,c
        add  a,a
        ld   e,a
        ld   d,0
        push hl
        ld   hl,savetab
        add  hl,de
        ld   e,(hl)
        inc  hl
        ld   d,(hl)
        push de
        pop  iy
        pop  hl
        ret

savetab: dw saves, saves+24, saves+48, saves+72, saves+96

; sprwipe — take every drawn sprite off screen (before death pause etc.)
sprwipe:
        ld   ix,lastt+12
        ld   iy,saves+72
        call wipe1
        ld   ix,lastt+8
        ld   iy,saves+48
        call wipe1
        ld   ix,lastt+4
        ld   iy,saves+24
        call wipe1
        ld   ix,lastt+0
        ld   iy,saves+0
        call wipe1
        ld   ix,lastt+16
        ld   iy,saves+96
        call wipe1
        ret
wipe1:
        ld   a,(ix+3)
        or   a
        ret  z
        ld   d,(ix+0)
        ld   e,(ix+1)
        call sprrest
        ld   (ix+3),0
        ret

; scrub — AND mask C into pac's save-under byte covering vram (col D, row E),
; if that pixel lies inside pac's last-drawn 2x8 window.  trashes A,B,H,L,E
scrub:
        ld   a,(lastt+19)
        or   a
        ret  z
        ld   a,(lastt+17)       ; last py
        ld   b,a
        ld   a,e
        sub  b
        cp   8
        ret  nc
        ld   b,a
        add  a,a
        add  a,b
        ld   l,a                ; save offset = row*3
        ld   a,(lastt+16)       ; last px -> first col (doubled screen)
        rrca
        rrca
        and  3fh
        add  a,LEFT_COL
        cp   d
        jr   z,scb1
        inc  a
        cp   d
        jr   z,scb0
        inc  a
        cp   d
        ret  nz
        inc  l
scb0:
        inc  l
scb1:
        ld   e,l
        ld   d,0
        ld   hl,saves+96
        add  hl,de
        ld   a,(hl)
        and  c
        ld   (hl),a
        ret

; ---------------------------------------------------------------------------
; pillblink — toggle power-pill visibility.  A pill under any sprite's
; save-under window is skipped this cycle (keeps buffers truthful).
; ---------------------------------------------------------------------------
pillblink:
        ld   a,(pillvis)
        xor  1
        ld   (pillvis),a
        ld   hl,pilltab
        ld   iy,pilla
        ld   b,4
pb_1:
        push bc
        push hl
        ld   a,(iy+0)
        or   a
        jr   z,pb_n             ; eaten
        ld   d,(hl)
        inc  hl
        ld   e,(hl)
        call pillcov
        jr   nz,pb_n            ; covered by a sprite: leave it
        ld   a,(pillvis)
        or   a
        jr   z,pb_off
        pop  hl
        push hl
        ld   d,(hl)
        inc  hl
        ld   e,(hl)
        call drawtile           ; redraw = pill on
        jr   pb_n
pb_off:
        ld   a,d                ; clear both tile columns, 8 rows
        add  a,a
        add  a,LEFT_COL
        ld   h,a
        ld   a,e
        add  a,a
        add  a,a
        add  a,a
        ld   l,a
        ld   b,8
pb_o1:
        ld   (hl),0
        inc  h
        ld   (hl),0
        dec  h
        inc  l
        djnz pb_o1
pb_n:
        pop  hl
        inc  hl
        inc  hl
        inc  iy
        pop  bc
        djnz pb_1
        ret

; pillcov — NZ if any on-screen sprite window overlaps pill tile (D,E)
pillcov:
        push ix
        ld   ix,lastt
        ld   b,5
pc_1:
        ld   a,(ix+3)
        or   a
        jr   z,pc_nx
        ld   a,(ix+0)           ; entity col = LEFT + px>>2
        rrca
        rrca
        and  3fh
        add  a,LEFT_COL
        ld   c,a
        ld   a,d                ; pill col c0 = LEFT + 2tx
        add  a,a
        add  a,LEFT_COL
        sub  c                  ; c0 - ecol
        add  a,2                ; overlap iff -1..3 -> +2 = 1..5
        cp   6
        jr   nc,pc_nx
        ld   a,e                ; rows: |lastpy - ty*8| < 8
        add  a,a
        add  a,a
        add  a,a
        sub  (ix+1)
        jr   nc,pc_2
        neg
pc_2:
        cp   8
        jr   nc,pc_nx
        pop  ix
        or   1                  ; NZ: covered
        ret
pc_nx:
        push de
        ld   de,4
        add  ix,de
        pop  de
        djnz pc_1
        pop  ix
        xor  a                  ; Z: clear
        ret

; ---------------------------------------------------------------------------
; deathfx — collapse animation with a warbling descending sweep, then bloops.
; Runs with all sprites wiped; animates at pac's final position.
; ---------------------------------------------------------------------------
deathfx:
        ld   a,(pacpx)
        ld   d,a
        ld   a,(pacpy)
        ld   e,a
        ld   iy,saves+96
        ld   hl,dfxtab
df_1:
        ld   a,(hl)             ; glyph (FF = end)
        cp   0ffh
        ret  z
        ld   b,a                ; B = glyph
        inc  hl
        ld   c,(hl)             ; C = warble base period
        inc  hl
        push hl
        push bc
        call sprsave
        pop  bc
        push bc
        ld   a,b
        call sprdraw
        pop  bc
        push de
        ld   e,c                ; warble: two nearby pitches alternating
        ld   d,0
        ld   b,22
        call tone16
        ld   a,c
        add  a,12
        ld   e,a
        ld   d,0
        ld   b,22
        call tone16
        ld   e,c
        ld   d,0
        ld   b,14
        call tone16
        pop  de
        call sprrest
        pop  hl
        jr   df_1
dfxtab:                         ; glyph, warble-period
        db 0,80
        db 7,100
        db 8,124
        db 9,152
        db 10,184
        db 11,110
        db 0ffh

dbloops:
        ld   e,52               ; bleep
        ld   d,0
        ld   b,50
        call tone16
        ld   b,60               ; beat of silence
db_g:
        push bc
        ld   bc,3000
db_g1:
        dec  bc
        ld   a,b
        or   c
        jr   nz,db_g1
        pop  bc
        djnz db_g
        ld   e,52               ; bleep
        ld   d,0
        ld   b,50
        jp   tone16

; ---------------------------------------------------------------------------
; eatshow — D,E = spot.  Chain-scored points (200/400/800/1600) drawn at the
; spot, riser sound, brief freeze, then the tiles underneath are redrawn.
; Runs while all sprites are erased, so the background stays truthful.
; ---------------------------------------------------------------------------
eatshow:
        push de
        ld   a,(chaink)
        cp   3
        jr   c,es0
        ld   a,3
es0:
        ld   c,a
        ld   b,0
        ld   hl,chamt
        add  hl,bc
        ld   a,(hl)
        call addscore
        ld   a,c
        cp   3
        jr   nz,es1
        ld   a,80h              ; 1600 = 800 + 800
        call addscore
es1:
        ld   a,c
        add  a,a
        ld   c,a
        ld   hl,chstr
        add  hl,bc
        ld   a,(hl)
        inc  hl
        ld   h,(hl)
        ld   l,a                ; HL = points string
        pop  de
        push de
        ld   a,e
        ld   (rowy),a
        ld   a,d
        rrca
        rrca
        and  3fh
        add  a,LEFT_COL
        ld   b,a
        call puts
        call sndeatg
        ld   b,18               ; linger on the number
es2:
        push bc
        call fsync
        pop  bc
        djnz es2
        pop  de                 ; redraw the tiles under the text
        ld   a,d
        rrca
        rrca
        rrca
        and  1fh
        ld   d,a
        ld   a,e
        rrca
        rrca
        rrca
        and  1fh
        ld   e,a
        ld   c,2
es_y:
        push de
        ld   b,5
es_x:
        push bc
        ld   a,d
        cp   28
        jr   nc,es_sk
        ld   a,e
        cp   30
        jr   nc,es_sk
        call drawtile
es_sk:
        pop  bc
        inc  d
        djnz es_x
        pop  de
        inc  e
        dec  c
        jr   nz,es_y
        ld   hl,chaink
        inc  (hl)
        ret
chamt:  db 20h,40h,80h,80h
chstr:  dw s200,s400,s800,s1600
s200:   db "200",0
s400:   db "400",0
s800:   db "800",0
s1600:  db "1600",0

; ckbonus — one extra life at 10,000 points
ckbonus:
        ld   a,(bonusfl)
        or   a
        ret  nz
        ld   a,(scorehi)
        cp   10h                ; BCD 1000 x10 = 10,000
        ret  c
        ld   a,1
        ld   (bonusfl),a
        ld   hl,lives
        inc  (hl)
        call drawlives
        ld   hl,sndreq
        ld   a,(hl)
        or   8
        ld   (hl),a
        ret

sndbonus:                       ; rapid rising chirps
        ld   e,90
sb1:
        ld   d,0
        ld   b,4
        call tone16
        ld   a,e
        sub  11
        ld   e,a
        cp   28
        jr   nc,sb1
        ret

; ---------------------------------------------------------------------------
; cutscene — intermission after every second maze: a two-act chase across a
; dark stage with its own looping tune (original music and choreography).
; ---------------------------------------------------------------------------
cutscene:
        call sprwipe
        call cls
        ld   hl,cstune
        ld   (csnp),hl
        xor  a                  ; act 1: ghost flees right, pac in pursuit
        ld   (csx),a
csA:
        call csstep
        ld   a,(csx)
        add  a,3
        ld   (csx),a
        cp   180
        jr   c,csA
        ld   a,220              ; act 2: frightened ghost flees left
        ld   (csx),a
csB:
        call csstepB
        ld   a,(csx)
        sub  4
        ld   (csx),a
        cp   60
        jr   nc,csB
        ld   d,24               ; the catch: pop star + fanfare
        ld   e,112
        call cswipe
        ld   a,11
        call sprdraw
        call sndeatg
        jp   sndwin

csstep:                         ; act 1 frame
        ld   a,(csx)
        ld   d,a
        ld   e,112
        call cswipe
        push de
        ld   a,d
        add  a,40
        ld   d,a
        call cswipe
        ld   a,5                ; ghost
        call sprdraw
        pop  de
        ld   a,(csx)
        rrca
        and  1
        jr   z,cs1
        ld   a,1                ; pac chomping right
        jr   cs2
cs1:
        xor  a
cs2:
        call sprdraw
        jp   csnote

csstepB:                        ; act 2 frame
        ld   a,(csx)
        ld   d,a
        ld   e,112
        call cswipe
        push de
        ld   a,d
        sub  40
        ld   d,a
        call cswipe
        ld   a,6                ; frightened ghost
        call sprdraw
        pop  de
        ld   a,(csx)
        rrca
        and  1
        jr   z,cs3
        ld   a,2                ; pac chomping left
        jr   cs4
cs3:
        xor  a
cs4:
        call sprdraw
        jp   csnote

; cswipe — zero a 5-col x 8-row band at logical px D, py E (black stage)
cswipe:
        push de
        push bc
        ld   a,d
        rrca
        rrca
        and  3fh
        add  a,LEFT_COL-1
        ld   h,a
        ld   b,5
cw1:
        ld   l,e
        ld   c,8
cw2:
        ld   (hl),0
        inc  l
        dec  c
        jr   nz,cw2
        inc  h
        djnz cw1
        pop  bc
        pop  de
        ret

; csnote — next note of the looping intermission tune
csnote:
        push de
        ld   hl,(csnp)
        ld   a,(hl)
        or   a
        jr   nz,csn1
        ld   hl,cstune
        ld   a,(hl)
csn1:
        ld   e,a
        inc  hl
        ld   b,(hl)
        inc  hl
        ld   (csnp),hl
        ld   d,0
        call tone16
        pop  de
        ret
cstune:                         ; (half-period, cycles): bouncy 16-note loop
        db 147,37, 117,47, 98,56, 74,74
        db 98,56,  74,74,  58,95, 74,74
        db 87,63,  110,50, 87,63, 74,74
        db 78,70,  98,56,  65,84, 74,74
        db 0

; ---------------------------------------------------------------------------
; attract mode — title + ghost parade, alternating with the top-10 table.
; Any key starts a game.
; ---------------------------------------------------------------------------
attract:
        call attrA
        jr   nz,at_go
        call attrB
        jr   z,attract
at_go:
        jp   newgame

atkey:                          ; NZ = a key was pressed (and consumed)
        in   a,(STAT2)
        bit  6,a
        ret  z
        call kread
        or   1
        ret

attrA:
        call cls
        ld   a,40
        ld   (rowy),a
        ld   b,32
        ld   hl,str_title
        call puts
        ld   a,200
        ld   (rowy),a
        ld   b,27
        ld   hl,str_press
        call puts
        ld   c,5                ; parade crossings
aa0:
        xor  a
        ld   (csx),a
aa1:
        push bc
        call fsync
        call atkey
        pop  bc
        ret  nz
        push bc
        call paradeframe
        pop  bc
        ld   a,(csx)
        add  a,2
        ld   (csx),a
        cp   146
        jr   c,aa1
        push bc
        call wipestrip
        pop  bc
        dec  c
        jr   nz,aa0
        xor  a
        ret

paradeframe:                    ; pac chasing four ghosts at y=120
        ld   a,(csx)
        ld   d,a
        ld   e,120
        call cswipe
        ld   a,(csx)
        rrca
        and  1
        jr   z,pf1
        ld   a,1
        jr   pf2
pf1:
        xor  a
pf2:
        call sprdraw
        ld   b,4
        ld   a,(csx)
        add  a,30
pf3:
        push bc
        push af
        ld   d,a
        ld   e,120
        call cswipe
        ld   a,5
        call sprdraw
        pop  af
        add  a,16
        pop  bc
        djnz pf3
        ret

wipestrip:
        ld   b,11
ws1:
        ld   h,b
        ld   l,120
        ld   c,8
ws2:
        ld   (hl),0
        inc  l
        dec  c
        jr   nz,ws2
        inc  b
        ld   a,b
        cp   71
        jr   nz,ws1
        ret

attrB:
        call cls
        ld   a,24
        ld   (rowy),a
        ld   b,29
        ld   hl,str_hst
        call puts
        ld   ix,HST
        ld   c,1                ; rank, BCD
        ld   e,44               ; row
atb1:
        push de
        push bc
        ld   a,e
        ld   (rowy),a
        ld   b,24
        ld   a,c
        call puthex
        ld   b,30
        ld   a,(ix+0)
        call putc
        inc  b
        inc  b
        ld   a,(ix+1)
        call putc
        inc  b
        inc  b
        ld   a,(ix+2)
        call putc
        ld   b,42
        ld   a,(ix+3)
        call puthex
        ld   a,(ix+4)
        call puthex
        ld   a,'0'
        call putc
        ld   de,5
        add  ix,de
        pop  bc
        pop  de
        ld   a,e
        add  a,18
        ld   e,a
        ld   a,c
        add  a,1
        daa
        ld   c,a
        cp   11h
        jr   c,atb1
        ld   bc,480             ; ~8 s, polling
atb2:
        push bc
        call fsync
        call atkey
        pop  bc
        ret  nz
        dec  bc
        ld   a,b
        or   c
        jr   nz,atb2
        xor  a
        ret

; ---------------------------------------------------------------------------
; hscheck — does the final score make the table?  If so, shift, insert, and
; take the player's initials.
; ---------------------------------------------------------------------------
hscheck:
        ld   b,0
        ld   hl,HST+3
hs1:
        ld   a,(scorehi)
        cp   (hl)
        jr   c,hsnx
        jr   nz,hsfound
        inc  hl
        ld   a,(scorelo)
        cp   (hl)
        dec  hl
        jr   c,hsnx
        jr   z,hsnx
        jr   hsfound
hsnx:
        ld   de,5
        add  hl,de
        inc  b
        ld   a,b
        cp   10
        jr   c,hs1
        ret
hsfound:
        ld   a,b
        ld   (hsidx),a
        ld   a,9                ; shift lower entries down one slot
        sub  b
        jr   z,hswr
        ld   c,a
        add  a,a
        add  a,a
        add  a,c
        ld   c,a
        ld   b,0
        ld   hl,HST+44
        ld   de,HST+49
        lddr
hswr:
        ld   a,(hsidx)
        ld   c,a
        add  a,a
        add  a,a
        add  a,c
        ld   c,a
        ld   b,0
        ld   hl,HST
        add  hl,bc
        ld   (hsins),hl
        push hl
        pop  de
        inc  de
        inc  de
        inc  de
        ld   a,(scorehi)
        ld   (de),a
        inc  de
        ld   a,(scorelo)
        ld   (de),a
        ; fall into the initials screen
; hsentry — typed initials, echoed as entered
hsentry:
        call cls
        ld   a,60
        ld   (rowy),a
        ld   b,26
        ld   hl,str_newhs
        call puts
        ld   a,84
        ld   (rowy),a
        ld   b,35
        ld   a,(scorehi)
        call puthex
        ld   a,(scorelo)
        call puthex
        ld   a,'0'
        call putc
        ld   a,116
        ld   (rowy),a
        ld   b,21
        ld   hl,str_init
        call puts
        ld   hl,(hsins)
        ld   c,3
        ld   b,36
hse1:
        push bc
        push hl
hse2:
        call getkey
        cp   'a'
        jr   c,hse3
        cp   'z'+1
        jr   nc,hse3
        sub  20h
hse3:
        cp   '0'
        jr   c,hse2
        cp   '9'+1
        jr   c,hseok
        cp   'A'
        jr   c,hse2
        cp   'Z'+1
        jr   nc,hse2
hseok:
        pop  hl
        pop  bc
        ld   (hl),a
        inc  hl
        push hl
        push bc
        push af
        ld   a,150
        ld   (rowy),a
        pop  af
        call putc
        pop  bc
        pop  hl
        inc  b
        inc  b
        inc  b
        dec  c
        jr   nz,hse1
        call sndwin
        call savehs             ; persist the table to track 2 sector 9
        ld   b,60
hse4:
        push bc
        call fsync
        pop  bc
        djnz hse4
        ret

; ---------------------------------------------------------------------------
; hsload — adopt the saved table (loaded with track 2 at boot) if its magic
; is valid, otherwise fall back to the ROM seed table.
; ---------------------------------------------------------------------------
hsload:
        ld   hl,SAVBUF
        ld   de,svmagic
        ld   b,4
hl1:
        ld   a,(de)
        cp   (hl)
        jr   nz,hl_seed
        inc  hl
        inc  de
        djnz hl1
        ld   hl,SAVBUF+4
        jr   hl_copy
hl_seed:
        ld   hl,hsseed
hl_copy:
        ld   de,HST
        ld   bc,50
        ldir
        ret

; ---------------------------------------------------------------------------
; savehs — write the table to track 4, sector 5 (the head is parked there by
; the loader and the game never seeks; the track holds nothing else, so even
; a mistargeted write is harmless).  Follows the manual 3.7.7 write
; protocol plus every hardware lesson from the Gotek campaign: IOCTL bit 4
; held, cmd-5 motor keepalive + drive-control reload before the attempt, no
; STAT2 reads at a mark, flag set within 150us of the mark edge.  Every wait
; is bounded so a missing/protected disk aborts instead of hanging.
; ---------------------------------------------------------------------------
savehs:
        in   a,(STAT1)
        bit  4,a
        ret  nz                 ; write-protected: keep scores RAM-only
        ld   a,1dh
        out  (IOCTL),a          ; cmd-5 event: motor on / keepalive
        ld   bc,0
sv_d1:
        dec  bc
        ld   a,b
        or   c
        jr   nz,sv_d1           ; ~400 ms
        ld   a,DCTL
        out  (081h),a           ; reload drive control (3.7.3 recovery)
        ld   bc,0
sv_d2:
        dec  bc
        ld   a,b
        or   c
        jr   nz,sv_d2
        ld   d,40               ; sync attempts, one body each
sv_seek:
        ld   a,1dh
        out  (IOCTL),a          ; cmd-5 event per attempt (motor keepalive)
        ; settle to the body: mark LOW first (stage1 v_lo ordering).  The
        ; counter bumps MID-mark, so a debounce taken at a mark reads the
        ; old sector id and would aim the write one sector late — that is
        ; exactly the race that once let a save land outside its sector.
        ld   bc,4000
sv_lo:
        in   a,(STAT1)
        bit  6,a
        jr   z,sv_db
        dec  bc
        ld   a,b
        or   c
        jr   nz,sv_lo
        jr   sv_nxt
sv_db:
        ld   e,80h              ; debounce the body id (MEFD3 style)
        ld   b,0
sv_d3:
        in   a,(STAT2)
        and  0fh                ; counter nibble only (bits 6/7 are kbd flags)
        cp   e
        jr   z,sv_id
        ld   e,a
        djnz sv_d3
        jr   sv_nxt
sv_id:
        cp   0eh
        jr   z,sv_nxt           ; motor code: try again
        cp   HSSEC-1            ; in the body just before the save sector?
        jr   z,sv_edge
sv_nxt:
        dec  d
        jp   z,sv_out           ; exhausted: scores stay RAM-only
        ld   bc,2000            ; let the next hole arrive, then retry
sv_sk:
        in   a,(STAT1)
        bit  6,a
        jr   nz,sv_seek
        dec  bc
        ld   a,b
        or   c
        jr   nz,sv_sk
        jr   sv_seek
sv_edge:
        ld   bc,6000            ; catch the mark rise: start of the save sector
sv_e1:
        in   a,(STAT1)
        bit  6,a
        jr   nz,sv_wr
        in   a,(STAT1)
        bit  6,a
        jr   nz,sv_wr
        in   a,(STAT1)
        bit  6,a
        jr   nz,sv_wr
        in   a,(STAT1)
        bit  6,a
        jr   nz,sv_wr
        dec  bc
        ld   a,b
        or   c
        jr   nz,sv_e1
        jr   sv_nxt
sv_wr:
        ld   a,1
        out  (083h),a           ; write flag, within 150us of the edge
        ld   b,34
        xor  a
sv_z:
        out  (080h),a           ; preamble zeros (WAIT-paced by hardware)
        djnz sv_z
        ld   a,0fbh
        out  (080h),a           ; sync byte 1
        ld   a,HSSEC+16*HSTRK
        out  (080h),a           ; sync byte 2: sector + 16*track (0x45)
        ld   c,0                ; CRC seed
        ld   hl,svmagic         ; 512 data bytes: magic + table + zero fill
        ld   b,4
sv_g1:
        ld   a,(hl)
        inc  hl
        out  (080h),a
        xor  c
        rlca
        ld   c,a
        djnz sv_g1
        ld   hl,HST
        ld   b,50
sv_g2:
        ld   a,(hl)
        inc  hl
        out  (080h),a
        xor  c
        rlca
        ld   c,a
        djnz sv_g2
        ld   de,458
sv_g3:
        xor  a
        out  (080h),a
        xor  c
        rlca
        ld   c,a
        dec  de
        ld   a,d
        or   e
        jr   nz,sv_g3
        ld   a,c
        out  (080h),a           ; CRC (software-calculated, manual 3.7.7)
sv_out:
        ld   a,18h
        out  (IOCTL),a          ; back to the keyboard-friendly baseline
        ret
svmagic: db "HST1"

; sndplay — play whatever the frame queued, after sprites are on screen
sndplay:
        ld   a,(sndreq)
        or   a
        ret  z                  ; (siren mothballed: jp z,sndsiren to revive)
        ld   b,a
        xor  a
        ld   (sndreq),a
        ld   a,b
        and  2
        jp   nz,sndpill
        ld   a,b
        and  4
        jp   nz,sndeatg
        ld   a,b
        and  8
        jp   nz,sndbonus
        jp   sndwaka

; sprvid — doubled screen: H = LEFT_COL + px>>2, L = py, A = px&3
sprvid:
        ld   a,d
        rrca
        rrca
        and  3fh
        add  a,LEFT_COL
        ld   h,a
        ld   l,e
        ld   a,d
        and  3
        ret

sprsave:
        push bc
        push de
        call sprvid
        push iy
        pop  de
        ld   b,8
sv1:
        ld   a,(hl)
        ld   (de),a
        inc  de
        inc  h
        ld   a,(hl)
        ld   (de),a
        inc  de
        inc  h
        ld   a,(hl)
        ld   (de),a
        inc  de
        dec  h
        dec  h
        inc  l
        djnz sv1
        pop  de
        pop  bc
        ret

sprrest:
        push bc
        push de
        call sprvid
        push iy
        pop  de
        ld   b,8
rr1:
        ld   a,(de)
        ld   (hl),a
        inc  de
        inc  h
        ld   a,(de)
        ld   (hl),a
        inc  de
        inc  h
        ld   a,(de)
        ld   (hl),a
        inc  de
        dec  h
        dec  h
        inc  l
        djnz rr1
        pop  de
        pop  bc
        ret

; sprdraw — OR glyph A at D,E
sprdraw:
        push ix
        push bc
        push de
        ld   b,a
        call sprvid
        push hl
        ld   c,a                ; idx = px&3
        ld   a,b
        add  a,a
        add  a,a
        add  a,c                ; glyph*4 + idx
        ld   c,a
        add  a,a
        add  a,c                ; *3
        ld   l,a
        ld   h,0
        add  hl,hl
        add  hl,hl
        add  hl,hl              ; *24
        ld   de,SHIFT
        add  hl,de
        push hl
        pop  ix
        pop  hl
        ld   b,8
dr1:
        ld   a,(hl)
        or   (ix+0)
        ld   (hl),a
        inc  h
        ld   a,(hl)
        or   (ix+1)
        ld   (hl),a
        inc  h
        ld   a,(hl)
        or   (ix+2)
        ld   (hl),a
        dec  h
        dec  h
        inc  l
        inc  ix
        inc  ix
        inc  ix
        djnz dr1
        pop  de
        pop  bc
        pop  ix
        ret

; ---------------------------------------------------------------------------
; mkshift — 7 glyphs x 8 shifts x 8 rows x (hi,lo)
; ---------------------------------------------------------------------------
mkshift:
        ld   hl,glyphs
        ld   de,SHIFT
        ld   a,12
        ld   (mk_gc),a
mk_g:
        xor  a
        ld   (mk_sc),a          ; shift = 0,2,4,6
mk_s:
        push hl
        ld   b,8
mk_r:
        ld   a,(hl)
        inc  hl
        push bc
        push hl
        push de
        ld   e,a
        rrca
        rrca
        rrca
        rrca
        and  0fh
        ld   l,a
        ld   h,0
        ld   bc,dbltab
        add  hl,bc
        ld   d,(hl)
        ld   a,e
        and  0fh
        ld   l,a
        ld   h,0
        add  hl,bc
        ld   a,(hl)
        ld   h,d                ; 24-bit window H:L:C
        ld   l,a
        ld   c,0
        ld   a,(mk_sc)
        or   a
        jr   z,mkr2
        ld   b,a
mkr1:
        srl  h
        rr   l
        rr   c
        djnz mkr1
mkr2:
        pop  de
        ld   a,h
        ld   (de),a
        inc  de
        ld   a,l
        ld   (de),a
        inc  de
        ld   a,c
        ld   (de),a
        inc  de
        pop  hl
        pop  bc
        djnz mk_r
        pop  hl
        ld   a,(mk_sc)
        add  a,2
        ld   (mk_sc),a
        cp   8
        jr   c,mk_s
        ld   bc,8
        add  hl,bc
        ld   a,(mk_gc)
        dec  a
        ld   (mk_gc),a
        jr   nz,mk_g
        ret

dbltab: db 000h,003h,00ch,00fh,030h,033h,03ch,03fh
        db 0c0h,0c3h,0cch,0cfh,0f0h,0f3h,0fch,0ffh

; ---------------------------------------------------------------------------
; setup / drawing
; ---------------------------------------------------------------------------
initdots:
        ld   hl,dotrows
        ld   de,dots_ram
        ld   bc,124
        ldir
        ld   hl,pilla
        ld   a,1
        ld   (hl),a
        inc  hl
        ld   (hl),a
        inc  hl
        ld   (hl),a
        inc  hl
        ld   (hl),a
        ld   hl,NDOTS+4
        ld   (dotslo),hl
        ld   a,1
        ld   (pillvis),a
        xor  a
        ld   (dotseat),a
        ld   h,a
        ld   l,a
        ld   (frtimer),hl
        ret

resetpos:
        ld   a,104
        ld   (pacpx),a
        ld   a,176
        ld   (pacpy),a
        ld   a,1
        ld   (pacdir),a
        ld   (pacwant),a
        ld   ix,gtab
        ld   hl,ginit
        ld   b,4
rp1:
        ld   a,(hl)
        ld   (ix+0),a
        inc  hl
        ld   a,(hl)
        ld   (ix+1),a
        inc  hl
        ld   a,(hl)
        ld   (ix+3),a           ; state
        inc  hl
        ld   a,(hl)
        ld   (ix+5),a           ; personality
        inc  hl
        ld   (ix+2),2           ; dir up
        ld   (ix+4),0
        ld   de,8
        add  ix,de
        djnz rp1
        xor  a
        ld   (hitflag),a
        ret
ginit:                          ; px,py,state,personality
        db 112,88,1,0           ; blinky: outside, pure chaser
        db 96,112,0,0           ; in house
        db 104,112,0,3          ; 1/4 random
        db 120,112,0,7          ; 1/8 random

cls:
        ld   b,0
cl_c:
        ld   h,b
        ld   l,0
        xor  a
cl_r:
        ld   (hl),a
        inc  l
        jr   nz,cl_r
        inc  b
        ld   a,b
        cp   80
        jr   nz,cl_c
        ret

drawmaze:
        ld   e,0                ; ty
dm_y:
        ld   d,0                ; tx
dm_x:
        call drawtile
        inc  d
        ld   a,d
        cp   28
        jr   nz,dm_x
        inc  e
        ld   a,e
        cp   30
        jr   nz,dm_y
        ret

; drawtile — render tile (D,E) from current state
drawtile:
        push de
        push bc
        call passable           ; NZ = wall
        jr   z,dt_open
        call buildwall
        ld   bc,walbuf
        jr   dt_blit
dt_open:
        push hl
        ld   hl,doortab         ; ghost-house door: flat bar
        ld   b,2
dt_d1:
        ld   a,(hl)
        inc  hl
        cp   d
        jr   nz,dt_d2
        ld   a,(hl)
        cp   e
        jr   nz,dt_d2
        pop  hl
        ld   bc,doorglyph
        jp   dt_blit
dt_d2:
        inc  hl
        djnz dt_d1
        pop  hl
        ; pill?
        push hl
        ld   hl,pilltab
        ld   iy,pilla
        ld   b,4
dt_p1:
        ld   a,(iy+0)
        or   a
        jr   z,dt_p2
        ld   a,(hl)
        cp   d
        jr   nz,dt_p2
        inc  hl
        ld   a,(hl)
        dec  hl
        cp   e
        jr   nz,dt_p2
        pop  hl
        ld   bc,pillglyph
        jr   dt_blit
dt_p2:
        inc  hl
        inc  hl
        inc  iy
        djnz dt_p1
        pop  hl
        ; dot?
        ld   a,e
        add  a,a
        add  a,a
        ld   l,a
        ld   h,0
        ld   bc,dots_ram
        add  hl,bc
        ld   a,d
        rrca
        rrca
        rrca
        and  3
        ld   c,a
        ld   b,0
        add  hl,bc
        ld   a,d
        and  7
        ld   c,a
        ld   b,0
        ld   a,(hl)
        ld   hl,masktab
        add  hl,bc
        ld   b,a
        ld   a,(hl)
        and  b
        ld   bc,dotglyph
        jr   nz,dt_blit
        ld   bc,emptyglyph
dt_blit:
        ld   a,d
        add  a,a
        add  a,LEFT_COL
        ld   h,a
        ld   a,e
        add  a,a
        add  a,a
        add  a,a
        ld   l,a
        push bc
        pop  de                 ; DE = glyph (single-wide source)
        ld   b,8
dt_b1:
        ld   a,(de)
        inc  de
        push de
        push bc
        ld   e,a
        rrca
        rrca
        rrca
        rrca
        and  0fh
        ld   c,a
        ld   b,0
        push hl
        ld   hl,dbltab
        add  hl,bc
        ld   a,(hl)
        pop  hl
        ld   (hl),a             ; left byte
        inc  h
        ld   a,e
        and  0fh
        ld   c,a
        push hl
        ld   hl,dbltab
        add  hl,bc
        ld   a,(hl)
        pop  hl
        ld   (hl),a             ; right byte
        dec  h
        inc  l
        pop  bc
        pop  de
        djnz dt_b1
        pop  bc
        pop  de
        ret

doorglyph:  db 000h,000h,000h,0ffh,0ffh,000h,000h,000h
dotglyph:   db 000h,000h,000h,018h,018h,000h,000h,000h
pillglyph:  db 000h,000h,03ch,07eh,07eh,03ch,000h,000h
emptyglyph: db 000h,000h,000h,000h,000h,000h,000h,000h

; ---------------------------------------------------------------------------
; buildwall — arcade-style outline tile for wall (D,E) into walbuf.
; Lines only on edges facing open tiles; inner-corner pixels where a diagonal
; is open between two walls; notched (rounded) outer corners.
; Preserves D,E.
; ---------------------------------------------------------------------------
buildwall:
        push de
        ld   hl,walbuf          ; clear
        ld   b,8
bw_c:
        ld   (hl),0
        inc  hl
        djnz bw_c
        xor  a
        ld   (walflg),a
        ; --- N ---
        dec  e
        call iswall
        push af
        inc  e
        pop  af
        jr   nz,bw_s
        ld   a,(walflg)
        or   1
        ld   (walflg),a
        ld   a,0ffh
        ld   (walbuf),a
bw_s:
        inc  e
        call iswall
        push af
        dec  e
        pop  af
        jr   nz,bw_w
        ld   a,(walflg)
        or   2
        ld   (walflg),a
        ld   a,0ffh
        ld   (walbuf+7),a
bw_w:
        dec  d
        call iswall
        push af
        inc  d
        pop  af
        jr   nz,bw_e
        ld   a,(walflg)
        or   4
        ld   (walflg),a
        ld   hl,walbuf
        ld   b,8
bw_w1:
        ld   a,(hl)
        or   80h
        ld   (hl),a
        inc  hl
        djnz bw_w1
bw_e:
        inc  d
        call iswall
        push af
        dec  d
        pop  af
        jr   nz,bw_dg
        ld   a,(walflg)
        or   8
        ld   (walflg),a
        ld   hl,walbuf
        ld   b,8
bw_e1:
        ld   a,(hl)
        or   1
        ld   (hl),a
        inc  hl
        djnz bw_e1
bw_dg:
        ; --- inner corners: diagonal open, both orthogonals walls ---
        dec  d
        dec  e
        call iswall             ; NW
        push af
        inc  d
        inc  e
        pop  af
        jr   nz,bw_d2
        ld   a,(walflg)
        and  5                  ; N or W open?
        jr   nz,bw_d2
        ld   hl,walbuf
        ld   a,(hl)
        or   80h
        ld   (hl),a
bw_d2:
        inc  d
        dec  e
        call iswall             ; NE
        push af
        dec  d
        inc  e
        pop  af
        jr   nz,bw_d3
        ld   a,(walflg)
        and  9
        jr   nz,bw_d3
        ld   hl,walbuf
        ld   a,(hl)
        or   1
        ld   (hl),a
bw_d3:
        dec  d
        inc  e
        call iswall             ; SW
        push af
        inc  d
        dec  e
        pop  af
        jr   nz,bw_d4
        ld   a,(walflg)
        and  6
        jr   nz,bw_d4
        ld   hl,walbuf+7
        ld   a,(hl)
        or   80h
        ld   (hl),a
bw_d4:
        inc  d
        inc  e
        call iswall             ; SE
        push af
        dec  d
        dec  e
        pop  af
        jr   nz,bw_rc
        ld   a,(walflg)
        and  0ah
        jr   nz,bw_rc
        ld   hl,walbuf+7
        ld   a,(hl)
        or   1
        ld   (hl),a
bw_rc:
        ; --- notch outer corners (rounded look) ---
        ld   a,(walflg)
        ld   b,a
        and  5                  ; N+W open
        cp   5
        jr   nz,bw_r2
        ld   hl,walbuf
        ld   a,(hl)
        and  7fh
        ld   (hl),a
bw_r2:
        ld   a,b
        and  9                  ; N+E open
        cp   9
        jr   nz,bw_r3
        ld   hl,walbuf
        ld   a,(hl)
        and  0feh
        ld   (hl),a
bw_r3:
        ld   a,b
        and  6                  ; S+W open
        cp   6
        jr   nz,bw_r4
        ld   hl,walbuf+7
        ld   a,(hl)
        and  7fh
        ld   (hl),a
bw_r4:
        ld   a,b
        and  0ah                ; S+E open
        cp   0ah
        jr   nz,bw_dn
        ld   hl,walbuf+7
        ld   a,(hl)
        and  0feh
        ld   (hl),a
bw_dn:
        pop  de
        ret

; iswall — tile (D,E) with bounds guard (off-map = open). Z = open.
; Preserves D,E.
iswall:
        ld   a,d
        cp   28
        jr   c,iw1
        xor  a
        ret
iw1:
        ld   a,e
        cp   30
        jr   c,iw2
        xor  a
        ret
iw2:
        jp   passable

; ---------------------------------------------------------------------------
; HUD & text
; ---------------------------------------------------------------------------
drawhud:
        ld   a,16
        ld   (rowy),a
        ld   b,1
        ld   hl,str_score
        call puts
        call drawscore
        ld   a,60
        ld   (rowy),a
        ld   b,1
        ld   hl,str_high
        call puts
        ld   a,72
        ld   (rowy),a
        ld   b,1
        ld   a,(HST+3)
        call puthex
        ld   a,(HST+4)
        call puthex
        ld   a,'0'
        jp   putc

drawscore:
        xor  a
        ld   (hudflag),a
        ld   b,1                ; clear digit area cols 1-11, rows 28-35
ds_c:
        ld   h,b
        ld   l,28
        ld   c,8
ds_r:
        ld   (hl),0
        inc  l
        dec  c
        jr   nz,ds_r
        inc  b
        ld   a,b
        cp   12
        jr   nz,ds_c
        ld   a,28
        ld   (rowy),a
        ld   b,1
        ld   a,(scorehi)
        call puthex
        ld   a,(scorelo)
        call puthex
        ld   a,'0'
        jp   putc

drawlives:
        ld   b,1                ; clear cols 1-7, rows 44-51
dl_c:
        ld   h,b
        ld   l,44
        ld   c,8
dl_r:
        ld   (hl),0
        inc  l
        dec  c
        jr   nz,dl_r
        inc  b
        ld   a,b
        cp   11
        jr   nz,dl_c
        ld   a,(lives)
        dec  a                  ; spares only, not the life in play
        ret  z
        ret  m
        ld   b,a
        ld   c,1
dl_1:
        push bc
        ld   h,c
        ld   l,44
        ld   de,glyphs+8        ; pac_r: mouth open, doubled
        ld   b,8
dl_2:
        ld   a,(de)
        inc  de
        push de
        push bc
        ld   e,a
        rrca
        rrca
        rrca
        rrca
        and  0fh
        ld   c,a
        ld   b,0
        push hl
        ld   hl,dbltab
        add  hl,bc
        ld   a,(hl)
        pop  hl
        ld   (hl),a
        inc  h
        ld   a,e
        and  0fh
        ld   c,a
        push hl
        ld   hl,dbltab
        add  hl,bc
        ld   a,(hl)
        pop  hl
        ld   (hl),a
        dec  h
        inc  l
        pop  bc
        pop  de
        djnz dl_2
        pop  bc
        inc  c
        inc  c
        inc  c
        djnz dl_1
        ret

ready:
        ld   a,137
        ld   (rowy),a
        ld   b,35
        ld   hl,str_ready
        call puts
        ld   a,(introfl)
        or   a
        jr   z,rdy_s
        xor  a
        ld   (introfl),a
        call sndintro
        jr   rdy_go
rdy_s:
        call sndstart
rdy_go:
        ld   b,60               ; ~1s of frames
rd_1:
        push bc
        call fsync
        pop  bc
        djnz rd_1
        ld   b,35               ; clear the text
rd_c:
        ld   h,b
        ld   l,137
        ld   c,7                ; 7 rows: glyph row 8 is blank padding, and
                                ; scanline 144 is the island wall's top line
rd_r:
        ld   (hl),0
        inc  l
        dec  c
        jr   nz,rd_r
        inc  b
        ld   a,b
        cp   48
        jr   nz,rd_c
        ret

addscore:
        ld   hl,scorelo
        add  a,(hl)
        daa
        ld   (hl),a
        ld   a,(scorehi)
        adc  a,0
        daa
        ld   (scorehi),a
        ld   a,1
        ld   (hudflag),a
        ret

; ---------------------------------------------------------------------------
; timing / input / random
; ---------------------------------------------------------------------------
fsync:
        ld   bc,1500            ; wait for display flag (bit2), bounded
fs1:
        in   a,(STAT1)
        and  4
        jr   nz,fs2
        dec  bc
        ld   a,b
        or   c
        jr   nz,fs1
fs2:
        out  (CLRDISP),a
        ret

; kpoll — nonblocking: read a key if present, update pacwant
kpoll:
        in   a,(STAT2)
        bit  6,a
        ret  z
        call kread
        cp   1bh                ; ESC = new game
        jp   z,newgame
        cp   'a'
        jr   c,kp1
        cp   'z'+1
        jr   nc,kp1
        sub  20h                ; to upper
kp1:
        cp   'N'                ; N = finish maze now (skip / cutscene test)
        jr   nz,kpn
        ld   hl,0
        ld   (dotslo),hl
        ret
kpn:
        ld   hl,keytab
kp2:
        ld   b,(hl)
        inc  hl
        ld   c,(hl)
        inc  hl
        ld   e,a
        ld   a,b
        or   a
        ret  z                  ; end of table: ignore key
        cp   e
        ld   a,e
        jr   nz,kp2
        ld   a,c
        ld   (pacwant),a
        ret
keytab:                         ; char, dir
        db 'D',0
        db 'A',1
        db 'W',2
        db 'S',3
        db 'L',0
        db 'J',1
        db 'I',2
        db 'K',3
        db '6',0
        db '4',1
        db '8',2
        db '2',3
        db 0ch,0                ; keypad right (forespace)
        db 08h,1                ; keypad left (backspace)
        db 0bh,2                ; keypad up (reverse line feed)
        db 0ah,3                ; keypad down (line feed)
        db 0,0

; kread — read one key (flag known set). A = char.  greenfield's proven
; cmd 1/2 + STAT2 bit-7 ack handshake; bit 4 held in every IOCTL write.
kread:
        in   a,(STAT2)
        ld   b,a
        ld   a,19h
        out  (IOCTL),a
kr1:
        in   a,(STAT2)
        xor  b
        jp   p,kr1
        in   a,(STAT2)
        and  0fh
        ld   c,a
        ld   a,1ah
        out  (IOCTL),a
kr2:
        in   a,(STAT2)
        xor  b
        jp   m,kr2
        in   a,(STAT2)
        and  0fh
        rlca
        rlca
        rlca
        rlca
        or   c
        and  7fh
        ld   b,a                ; restore neutral cmd 0 (PROM does the same);
        ld   a,18h              ; leaving cmd 2 latched makes every STAT2 read
        out  (IOCTL),a          ; eat the next keypress's data flag
        ld   a,b
        ret

getkey:
        in   a,(STAT2)
        bit  6,a
        jr   z,getkey
        jp   kread

rnd:
        push hl
        ld   hl,(seed)
        add  hl,hl
        jr   nc,rn1
        ld   a,l
        xor  02dh
        ld   l,a
rn1:
        ld   a,(frames)
        add  a,l
        ld   l,a
        ld   (seed),hl
        ld   a,l
        pop  hl
        ret

; ---------------------------------------------------------------------------
; sound — square waves on IOCTL bit 6, bit 4 always held
; ---------------------------------------------------------------------------
tone:                           ; B = half-period, C = cycles
        push af
        push de
tn1:
        ld   a,50h
        out  (IOCTL),a
        ld   d,b
tn2:
        dec  d
        jr   nz,tn2
        ld   a,10h
        out  (IOCTL),a
        ld   d,b
tn3:
        dec  d
        jr   nz,tn3
        dec  c
        jr   nz,tn1
        pop  de
        pop  af
        ret

sndwaka:
        ld   hl,wakaflip
        ld   a,(hl)
        cpl
        ld   (hl),a
        or   a
        ld   b,70
        jr   z,wk1
        ld   b,100
wk1:
        ld   c,12
        jp   tone

sndpill:
        ld   b,160
sp1:
        ld   c,4
        call tone
        ld   a,b
        sub  20
        ld   b,a
        cp   40
        jr   nc,sp1
        ret

sndeatg:
        ld   e,220              ; bubbling two-octave riser
se1:
        ld   d,0
        ld   b,2
        call tone16
        push de
        srl  e                  ; octave-up partner note
        ld   d,0
        ld   b,2
        call tone16
        pop  de
        ld   a,e
        sub  8
        ld   e,a
        cp   40
        jr   nc,se1
        ld   e,34               ; top sparkle
        ld   d,0
        ld   b,10
        call tone16
        ld   e,42
        ld   d,0
        ld   b,8
        call tone16
        ld   e,30
        ld   d,0
        ld   b,12
        jp   tone16

snddeath:
        ld   b,40
sd_1:
        ld   c,6
        call tone
        ld   a,b
        add  a,8
        ld   b,a
        cp   200
        jr   c,sd_1
        ret

; tone16 — E = half-period (~6.5us units), B = cycles.  Bit 4 always held.
tone16:
        push af
        ld   d,0
t16a:
        ld   a,50h
        out  (IOCTL),a
        call d16
        ld   a,10h
        out  (IOCTL),a
        call d16
        djnz t16a
        pop  af
        ret
d16:
        push de
d16a:
        dec  de
        ld   a,d
        or   e
        jr   nz,d16a
        pop  de
        ret

; sndintro — an original chiptune fanfare (the arcade tune is copyrighted)
sndintro:
        ld   hl,tune
sn_i:
        ld   a,(hl)
        or   a
        ret  z
        ld   e,a
        inc  hl
        ld   b,(hl)
        inc  hl
        push hl
        call tone16
        pop  hl
        jr   sn_i
tune:                           ; (half-period, cycles) pairs; ascending flourish
        db 147,52               ; C5
        db 74,105               ; C6
        db 98,78                ; G5
        db 117,66               ; E5
        db 74,105               ; C6
        db 98,160               ; G5 hold
        db 117,66               ; E5
        db 98,78                ; G5
        db 87,88                ; A5
        db 78,99                ; B5
        db 74,210               ; C6 hold
        db 0

sndstart:
        ld   b,120
        ld   c,30
        call tone
        ld   b,90
        ld   c,30
        call tone
        ld   b,60
        ld   c,40
        jp   tone

sndwin:
        ld   b,80
        ld   c,40
        call tone
        ld   b,60
        ld   c,40
        call tone
        ld   b,40
        ld   c,60
        jp   tone

; ---------------------------------------------------------------------------
; sndsiren — background wail: ~2ms tone burst per frame, pitch on a slow
; triangle.  Pulsed through a real speaker, smoothed by the emulator's decay.
; Lower, slower character while ghosts are frightened.
; ---------------------------------------------------------------------------
sndsiren:
        ld   hl,sirph
        inc  (hl)
        ld   a,(hl)
        and  7fh
        ld   (hl),a
        cp   64                 ; triangle 0..63..0
        jr   c,ss1
        ld   b,a
        ld   a,128
        sub  b
ss1:
        rrca                    ; /2 -> 0..31
        and  1fh
        ld   b,a
        ld   a,(frtimer)
        ld   c,a
        ld   a,(frtimer+1)
        or   c
        jr   nz,ss_fr
        ld   a,110              ; normal chase wail: period 79..110
        sub  b
        ld   e,a
        jr   ss2
ss_fr:
        ld   a,170              ; frightened: lower, woozier
        sub  b
        ld   e,a
ss2:
        ld   d,0
        ld   b,2
        jp   tone16

; ---------------------------------------------------------------------------
; text: 5x7 font renderer (proven on hardware in the diagnostics)
; ---------------------------------------------------------------------------
puts:
        ld   a,(hl)
        or   a
        ret  z
        push hl
        call putc
        pop  hl
        inc  hl
        inc  b
        inc  b
        jr   puts

puthex:
        push af
        rrca
        rrca
        rrca
        rrca
        and  0fh
        call hexnib
        call putc
        inc  b
        inc  b
        pop  af
        and  0fh
        call hexnib
        call putc
        inc  b
        inc  b
        ret
hexnib:
        cp   10
        jr   c,hx0
        add  a,'A'-10
        ret
hx0:
        add  a,'0'
        ret

putc:
        cp   '!'
        jr   nz,pc_bang
        ld   a,36
        jp   pcix
pc_bang:
        cp   '0'
        ret  c
        cp   '9'+1
        jr   c,pcdg
        cp   'A'
        ret  c
        cp   'Z'+1
        ret  nc
        sub  'A'-10
        jr   pcix
pcdg:
        sub  '0'
pcix:
        push bc
        push de
        ld   l,a
        ld   h,0
        add  hl,hl
        add  hl,hl
        add  hl,hl
        ld   de,font8
        add  hl,de
        ld   a,(rowy)
        ld   c,a
        ld   e,8
pcrw:
        ld   a,(hl)
        inc  hl
        push hl
        push de
        ld   e,a
        rrca
        rrca
        rrca
        rrca
        and  0fh
        ld   l,a
        ld   h,0
        push bc
        ld   bc,dbltab
        add  hl,bc
        ld   d,(hl)             ; left half
        ld   a,e
        and  0fh
        ld   l,a
        ld   h,0
        add  hl,bc
        ld   a,(hl)             ; right half
        pop  bc
        ld   h,b
        ld   l,c
        ld   e,a
        ld   a,(hl)
        or   d
        ld   (hl),a
        inc  h
        ld   a,(hl)
        or   e
        ld   (hl),a
        dec  h
        pop  de
        pop  hl
        inc  c
        dec  e
        jr   nz,pcrw
        pop  de
        pop  bc
        ret

str_score: db "SCORE",0
str_high:  db "HIGH",0
str_title: db "NSPACMAN",0
str_press: db "PRESS ANY KEY",0
str_hst:   db "HIGH SCORES",0
str_newhs: db "NEW HIGH SCORE",0
str_init:  db "ENTER YOUR INITIALS",0
hsseed:
        db "NSP",005h,000h
        db "Z80",004h,050h
        db "ADV",004h,000h
        db "CPM",003h,050h
        db "FDC",003h,000h
        db "HXC",002h,050h
        db "GRN",002h,000h
        db "MED",001h,050h
        db "BIT",001h,000h
        db "DAV",000h,050h
str_ready: db "READY!",0
str_over:  db "GAME OVER",0

; ---------------------------------------------------------------------------
dxtab:  db 1,0ffh,0,0
dytab:  db 0,0,0ffh,1
revtab: db 1,0,3,2
masktab: db 080h,040h,020h,010h,008h,004h,002h,001h
reltab: db 0,10,30,60

        include "assets.inc"
