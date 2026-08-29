#!/usr/bin/env python3
"""
mkdisk.py — build a bootable two-stage NSPacMan floppy (350 KB DSDD).

Layout:
  sector 0          volume label
  track 0 sec 4-7   stage 1, the loader  (file 0x800; PROM auto-loads this 2 KB)
  track 1 sec 0-9   stage 2, the game    (file 0x1400; loader reads it to 0x8000)

The PROM contract: stage1 byte 0x00 == load page (0xC1), byte 0x0A == 0xC3 (JP).
Track 1 = storeSectNum 10..19 = file offset 0x1400..0x27FF (5 KB) on side 0.
"""
import sys

DISK_SIZE   = 358400
SECTOR      = 512
STAGE1_OFF  = 0x800            # track 0, sector 4
STAGE1_MAX  = 4 * SECTOR       # PROM reads 4 sectors
STAGE2_OFF  = 0x1400           # track 1, sector 0
STAGE2_MAX  = 10 * SECTOR      # one track (loader reads 10 sectors)
LOAD_PAGE   = 0xC1


def build(stage1_path, stage2_path, out_path):
    s1 = open(stage1_path, "rb").read()
    s2 = open(stage2_path, "rb").read()

    if s1[0x00] != LOAD_PAGE:
        sys.exit(f"stage1 byte 0x00 = {s1[0x00]:#04x}, must be {LOAD_PAGE:#04x}")
    if s1[0x0A] != 0xC3:
        sys.exit(f"stage1 byte 0x0A = {s1[0x0A]:#04x}, must be 0xC3 (JP)")
    if len(s1) > STAGE1_MAX:
        sys.exit(f"stage1 {len(s1)} > {STAGE1_MAX} byte boot window")
    if len(s2) > STAGE2_MAX:
        sys.exit(f"stage2 {len(s2)} > {STAGE2_MAX} bytes (one track). "
                 f"Extend the loader to read a second track.")

    img = bytearray(DISK_SIZE)
    label = b"NSPACMAN for the NorthStar Advantage"
    img[0:len(label)] = label
    img[STAGE1_OFF:STAGE1_OFF + len(s1)] = s1
    img[STAGE2_OFF:STAGE2_OFF + len(s2)] = s2

    open(out_path, "wb").write(img)
    print(f"wrote {out_path}: {DISK_SIZE} bytes (DSDD)")
    print(f"  stage1 {len(s1):4d} B @ file 0x{STAGE1_OFF:04X}  (track 0 sec 4-7 -> RAM 0xC100)")
    print(f"  stage2 {len(s2):4d} B @ file 0x{STAGE2_OFF:04X}  (track 1 sec 0-9 -> RAM 0x8000)")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: mkdisk.py <stage1.bin> <stage2.bin> <out.nsi>")
    build(sys.argv[1], sys.argv[2], sys.argv[3])
