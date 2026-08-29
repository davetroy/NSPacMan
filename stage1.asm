; ============================================================================
; stage1p — GREENFIELD loader rebuilt on the PROVEN FDC protocol.
; ============================================================================
; Sources of truth: the stock boot PROM (works on the Gotek every boot) and
; the EC0A CP/M secondary loader (reads hundreds of sectors on the Gotek).
; Not the emulator model.  The rules extracted from them:
;
;   * I/O control (0xF8): bit 4 stays SET, always.  Only 0x15/0x1D are ever
;     written (acquire off/on around each sector), exactly like the PROM.
;     Never 0x05 — the old init's 0x05 cleared bit 4, and that is the prime
;     suspect for every hang we have seen on real hardware.
;   * Drive control (0x81): bit 7 SET, like the PROM (0xA0/0x80|sel) and
;     MED3C (0x81).  Step = base, base|0x10, base^0x10, then a long settle.
;   * After seeking, run the PROM's FDC init dance: 4x (OUT 82, delay,
;     IN 82, delay).
;   * Clear read-enable with IN 82 after every sector, success or failure.
;   * Sector identity read from STAT2 MID-SECTOR (after the sync bytes),
;     which agrees with both the emulator and MED3C's usage — never any
;     up-front wait for the 0x0F index code.
;   * CRC (xor;rlca over the 512 bytes) verified per sector; bad sectors are
;     simply not marked done and come round again.  All waits bounded.
;
; Layout contract unchanged: PROM loads this at 0xC100, enters at 0xC10A;
; stage 2 = track 1 sectors 0-9 -> 0x8000.
;
; Read-out: ALIVE bar (scanlines 32-39); one tick per sector loaded
; (row 48, col = secnum*6); on success jumps to stage 2; on budget
; exhaustion a solid bar at scanlines 96-103.
; ----------------------------------------------------------------------------

IOCTL:    equ 0f8h
FDC_DATA: equ 080h
FDC_SYNC: equ 081h
FDC_RDF:  equ 082h
STAT1:    equ 0e0h
STAT2:    equ 0d0h
MAP2:     equ 0a2h

DEST:     equ 8000h
NSEC:     equ 10
DCTL:     equ 0a1h              ; drive control base: bit7 | bit5 dir-in | drive 1

flags:    equ 0c900h
seen:     equ 0c910h              ; 16 flags: raw STAT2 nibbles observed
cser:     equ 0c920h              ; serial-data timeouts
csyn:     equ 0c921h              ; sync byte not 0xFB
ccrc:     equ 0c922h              ; CRC failures
cdup:     equ 0c923h              ; duplicate-sector skips
cmark:    equ 0c924h              ; sector-mark wait timeouts
crsp:     equ 0c925h              ; motor-off (0x0E) sightings
seen2:    equ 0c930h              ; 16 flags: raw STAT2 nibbles during mark timeouts
remain:   equ 0c90ah
budget:   equ 0c90bh
dstpg:    equ 0c90dh              ; high byte of current track's load base
rowy:     equ 0c90ch

        org 0c100h
        db   0c1h
        db   0,0,0,0,0,0,0,0,0
        jp   start

start:
        di
        ld   sp,0fe00h

        ld   a,0f8h                     ; video RAM back at 0x0000
        out  (0a0h),a
        ld   a,0f9h
        out  (0a1h),a
        xor  a
        out  (90h),a
        call clstop

        ld   a,32                       ; ALIVE
        ld   (rowy),a
        call bar

        ld   a,01h                      ; logical page 2 -> RAM bank 1
        out  (MAP2),a

        ; ---- seek track 0 -> 1, PROM style (bit 7 set, long settle) ----
        ld   a,DCTL
        out  (FDC_SYNC),a
        or   10h
        out  (FDC_SYNC),a
        xor  10h
        out  (FDC_SYNC),a
        ld   a,28h                      ; PROM 819c settle: 0x28 x 0xFA
        call dly

        ; ---- PROM's FDC init dance (8107-8117) ----
        ld   b,4
dance:
        out  (FDC_RDF),a                ; set read flag
        ld   a,7dh
        call dly
        in   a,(FDC_RDF)                ; clear read flag
        ld   a,7dh
        call dly
        djnz dance

        ; ---- clear bookkeeping ----
        ld   hl,flags
        ld   b,NSEC
        xor  a
clf:
        ld   (hl),a
        inc  hl
        djnz clf
        ld   hl,seen                    ; clear instrumentation
        ld   b,48                       ; seen + counters + seen2
        xor  a
cli:
        ld   (hl),a
        inc  hl
        djnz cli
        ld   a,DEST/256
        ld   (dstpg),a
        call loadtrk                    ; track 1 -> 0x8000

        ld   a,DCTL                     ; step in to track 2
        out  (FDC_SYNC),a
        or   10h
        out  (FDC_SYNC),a
        xor  10h
        out  (FDC_SYNC),a
        ld   a,28h
        call dly
        ld   a,94h                      ; -> 0x9400 (0x8000 + 10 sectors)
        ld   (dstpg),a
        call loadtrk
        jp   DEST

; loadtrk — read all ten sectors of the current track to (dstpg)<<8
loadtrk:
        ld   hl,flags
        ld   b,NSEC
        xor  a
ltf1:
        ld   (hl),a
        inc  hl
        djnz ltf1
        ld   a,NSEC
        ld   (remain),a
        ld   a,200                      ; mark-cycle budget
        ld   (budget),a
main:
        ld   a,(remain)
        or   a
        ret  z                          ; track done
        ld   a,(budget)
        dec  a
        ld   (budget),a
        jp   z,failed
        call readsec
        jr   main

; --------------------------------------------------------------------------
; failed — print the counters as hex text, then stop.
;   S xxxx  bitmap of sectors loaded (bit k = sector k)
;   V xxxx  bitmap of raw STAT2 values seen mid-sector (bit v = value v)
;   T xx  Y xx   serial-data timeouts / sync-byte mismatches
;   C xx  D xx   CRC failures / duplicate skips
;   M xx         sector-mark wait timeouts
; --------------------------------------------------------------------------
failed:
        ld   a,48
        ld   (rowy),a
        ld   b,2
        ld   a,'S'
        call putc
        inc  b
        inc  b
        ld   hl,flags
        ld   c,10
        call mkbm
        ld   a,d
        call puthex
        ld   a,e
        call puthex

        ld   a,58
        ld   (rowy),a
        ld   b,2
        ld   a,'V'
        call putc
        inc  b
        inc  b
        ld   hl,seen
        ld   c,16
        call mkbm
        ld   a,d
        call puthex
        ld   a,e
        call puthex

        ld   a,68
        ld   (rowy),a
        ld   b,2
        ld   a,'W'
        call putc
        inc  b
        inc  b
        ld   hl,seen2
        ld   c,16
        call mkbm
        ld   a,d
        call puthex
        ld   a,e
        call puthex

        ld   a,78
        ld   (rowy),a
        ld   b,2
        ld   a,'T'
        call putc
        inc  b
        inc  b
        ld   a,(cser)
        call puthex
        inc  b
        ld   a,'Y'
        call putc
        inc  b
        inc  b
        ld   a,(csyn)
        call puthex

        ld   a,88
        ld   (rowy),a
        ld   b,2
        ld   a,'C'
        call putc
        inc  b
        inc  b
        ld   a,(ccrc)
        call puthex
        inc  b
        ld   a,'D'
        call putc
        inc  b
        inc  b
        ld   a,(cdup)
        call puthex

        ld   a,98
        ld   (rowy),a
        ld   b,2
        ld   a,'M'
        call putc
        inc  b
        inc  b
        ld   a,(cmark)
        call puthex
        inc  b
        ld   a,'R'
        call putc
        inc  b
        inc  b
        ld   a,(crsp)
        call puthex

        ld   a,108
        ld   (rowy),a
        call bar
fh:     jr   fh

; --- mkbm: HL=flag table, C=count -> DE bitmap (bit k set if table[k]!=0) --
mkbm:
        ld   de,0
        ld   b,c
        push hl
        ld   a,c
        dec  a
        add  a,l
        ld   l,a
        jr   nc,mkb0
        inc  h
mkb0:
        pop  af                         ; discard saved HL low? no --
        ; (re-push corrected) walk from table[count-1] down to table[0]
mk1:
        sla  e
        rl   d
        ld   a,(hl)
        or   a
        jr   z,mk2
        set  0,e
mk2:
        dec  hl
        djnz mk1
        ret

; --- puthex: print A as two hex digits at column B (advances B) -----------
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
        pop  af
        and  0fh
        call hexnib
        call putc
        inc  b
        ret
hexnib:
        cp   10
        jr   c,hexn0
        add  a,'A'-10
        ret
hexn0:
        add  a,'0'
        ret

; --- putc: draw glyph for char A at column B, top scanline (rowy) ---------
putc:
        cp   '0'
        ret  c
        cp   '9'+1
        jr   c,pc_dig
        cp   'A'
        ret  c
        cp   'Z'+1
        ret  nc
        sub  'A'-10
        jr   pc_idx
pc_dig:
        sub  '0'
pc_idx:
        ld   l,a
        ld   h,0
        ld   d,h
        ld   e,l
        add  hl,hl
        add  hl,hl
        add  hl,de
        add  hl,de
        add  hl,de                      ; *7
        ld   de,font
        add  hl,de
        ld   a,(rowy)
        ld   c,a
        ld   e,7
pc_row:
        ld   a,(hl)
        inc  hl
        push hl
        push bc
        ld   d,a
        ld   h,b
        ld   l,c
        ld   a,(hl)
        or   d
        ld   (hl),a
        pop  bc
        pop  hl
        inc  c
        dec  e
        jr   nz,pc_row
        ret

; ---------------------------------------------------------------------------
; readsec — MED3C's literal algorithm.  The FDC contract (proven by MED3C's
; stable+1 arithmetic, the PROM's sync-on-3-read-4, and the emulator's
; startSectorRead): an acquire delivers the sector AFTER the one STAT2
; currently shows.  So: mid-body, debounce-read STAT2 -> S; target = S+1;
; if we need it, wait for the next mark and acquire.  STAT2 is never read
; at or after the mark, and never during a stream.
; ---------------------------------------------------------------------------
readsec:
        ld   a,1dh                      ; fresh cmd-5 event: motor stays alive
        out  (IOCTL),a
        in   a,(FDC_RDF)                ; clear read enable (PROM 8120 parity)
        ld   bc,4000                    ; settle to mid-body (mark LOW)
v_lo:
        in   a,(STAT1)
        and  40h
        jr   z,v_lo0
        dec  bc
        ld   a,b
        or   c
        jr   nz,v_lo
        jp   mtout
v_lo0:
        ld   e,80h                      ; stable STAT2 read (MEFD3 debounce)
        ld   b,0
v_st:
        in   a,(STAT2)
        and  0fh
        cp   e
        jr   z,v_st0
        ld   e,a
        djnz v_st
        ret                             ; never stabilised; try again
v_st0:
        ld   c,a                        ; C = current body id (raw)
        ld   hl,seen                    ; V line: body ids actually observed
        ld   b,0
        add  hl,bc
        ld   (hl),1
        ld   a,c
        cp   0eh
        jp   z,mtout                    ; motor-off code: respin
        inc  a                          ; target = S+1 (mod 16)
        and  0fh
        cp   10
        jr   c,v_tgt
        jp   skipw                      ; body 9 first half etc: no valid target
v_tgt:
        ld   c,a                        ; C = target sector
        ld   hl,flags
        ld   b,0
        add  hl,bc
        ld   a,(hl)
        or   a
        jr   z,v_new
        ld   hl,cdup
        inc  (hl)
        jp   skipw                      ; already have it: let one hole pass
v_new:
        ; wait for the target's mark: tight, 16 samples per pass
        ld   d,3
v_qo:
        ld   b,0
v_q:
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        in   a,(STAT1)
        and  40h
        jr   nz,v_hi
        djnz v_q
        dec  d
        jr   nz,v_qo
        jp   mtout
v_hi:
        ld   a,64h                      ; PROM post-rise delay (01b4)
v_d1:
        dec  a
        jr   nz,v_d1
        ld   a,15h                      ; acquire off  (bit4 stays set)
        out  (IOCTL),a
        out  (FDC_RDF),a                ; set read flag
        ld   a,18h
v_d2:
        dec  a
        jr   nz,v_d2
        ld   a,1dh                      ; acquire on
        out  (IOCTL),a
        ld   e,c                        ; E = target (C needed for port)
        ld   c,STAT1
        ld   b,64h
v_ws:
        in   f,(c)                      ; serial data -> sign flag
        jp   m,v_got
        djnz v_ws
        ld   hl,cser
        inc  (hl)
        jp   rs_clr
v_got:
        in   a,(FDC_SYNC)               ; sync byte
        cp   0fbh
        jr   z,v_sy
        ld   hl,csyn
        inc  (hl)
        jp   rs_clr
v_sy:
        in   a,(FDC_DATA)               ; second 0xFB, discard
        ld   a,e                        ; DE = (dstpg<<8) + target*512
        add  a,a
        ld   d,a
        ld   a,(dstpg)
        add  a,d
        ld   d,a
        ld   c,e                        ; C = target again
        ld   e,0
        push bc                         ; save target
        ld   b,0                        ; 256 pairs
        ld   c,0                        ; CRC seed
v_r:
        in   a,(FDC_DATA)
        ld   (de),a
        inc  de
        xor  c
        rlca
        ld   c,a
        in   a,(FDC_DATA)
        ld   (de),a
        inc  de
        xor  c
        rlca
        ld   c,a
        djnz v_r
        in   a,(FDC_DATA)               ; CRC byte
        xor  c
        ld   c,a                        ; 0 iff good
        in   a,(FDC_RDF)                ; clear read enable
        ld   a,c
        pop  bc                         ; C = target
        or   a
        jr   z,v_good
        ld   hl,ccrc
        inc  (hl)
        ret                             ; bad CRC: comes round again
v_good:
        ld   hl,flags
        ld   b,0
        add  hl,bc
        ld   (hl),1
        ld   a,(remain)
        dec  a
        ld   (remain),a
        ld   a,40
        ld   (rowy),a
        ld   a,c                        ; tick col = target*6
        add  a,a
        add  a,c
        add  a,a
        call blip
        ret

; skipw — let one sector hole pass so the next attempt lands in a new body
skipw:
        ld   d,2
sk_qo:
        ld   b,0
sk_q:
        in   a,(STAT1)
        and  40h
        ret  nz
        djnz sk_q
        dec  d
        jr   nz,sk_qo
        ret

rs_clr:
        in   a,(FDC_RDF)                ; clear read enable, try next mark
        ret

; --------------------------------------------------------------------------
; mtout — a sector-mark wait timed out.  Record what STAT2 says during the
; dead time (motor-off shows 0x0E per manual 3.7.2), then re-issue command 5
; as a fresh event (0x18 = cmd 0, then 0x1D = cmd 5) and give the motor
; ~100 ms before the caller retries.
; --------------------------------------------------------------------------
mtout:
        ld   hl,cmark
        inc  (hl)
        in   a,(STAT2)
        and  0fh
        ld   c,a
        ld   hl,seen2
        ld   b,0
        add  hl,bc
        ld   (hl),1
        ld   a,c
        cp   0eh
        jr   nz,mt1
        ld   hl,crsp
        inc  (hl)
mt1:
        ld   a,18h                      ; cmd 0 (keeps bits 3,4 set)
        out  (IOCTL),a
        ld   a,10
        call dly
        ld   a,1dh                      ; cmd 5: fresh "start motors" event
        out  (IOCTL),a
        ld   a,0d0h                     ; ~100 ms spin-up
        call dly
        ld   a,DCTL                     ; manual 3.7.3: after motor-on, reload
        out  (FDC_SYNC),a               ;   the drive control register (motor-
        ret                             ;   off zeroed it -> drive deselected)

; --- dly: outer A times, inner 0xFA — the PROM's 819e ----------------------
dly:
        ld   c,0fah
dl1:
        dec  c
        jr   nz,dl1
        dec  a
        jr   nz,dly
        ret

; --- blip: 4 cols x 8 scanlines at column A, row (rowy) --------------------
blip:
        ld   c,4
blc:
        push af
        ld   h,a
        ld   a,(rowy)
        ld   l,a
        ld   b,8
bl1:
        ld   (hl),0ffh
        inc  l
        djnz bl1
        pop  af
        inc  a
        dec  c
        jr   nz,blc
        ret

; --- bar: full width, 8 scanlines at row (rowy) ----------------------------
bar:
        ld   b,0
bar1:
        ld   h,b
        ld   a,(rowy)
        ld   l,a
        ld   c,8
bar2:
        ld   (hl),0ffh
        inc  l
        dec  c
        jr   nz,bar2
        inc  b
        ld   a,b
        cp   80
        jr   nz,bar1
        ret

; --- clear the top 112 scanlines ------------------------------------------
clstop:
        ld   b,0
ct1:
        ld   h,b
        ld   l,0
        ld   c,112
ct2:
        ld   (hl),0
        inc  l
        dec  c
        jr   nz,ct2
        inc  b
        ld   a,b
        cp   80
        jr   nz,ct1
        ret

        include "font5x7.inc"
