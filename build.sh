#!/bin/bash
# build.sh — assemble NSPacMan and pack a bootable NorthStar Advantage floppy.
#
#   ./build.sh          # assemble loader + game, build pacman.nsi
#   ./build.sh hfe      # ...and convert to a Gotek-ready HFEv3 image
#
# Requires: z80asm (brew install z80asm), python3.
# `hfe` needs greaseweazle (pipx install greaseweazle).
set -euo pipefail
cd "$(dirname "$0")"

echo "==> generating maze, sprites, and font"
python3 gen_assets.py

echo "==> assembling stage 1 (loader) + stage 2 (game)"
z80asm -o stage1.bin stage1.asm
z80asm -o pacman.bin pacman.asm

echo "==> building pacman.nsi"
python3 mkdisk.py stage1.bin pacman.bin pacman.nsi

if [ "${1:-}" = "hfe" ]; then
    echo "==> converting to hard-sectored HFEv3 for Gotek/HxC"
    gw convert --format northstar.mfm.ds pacman.nsi \
        "pacman.hfe::version=3:interface=GENERIC_SHUGART_DD:encoding=ISOIBM_MFM"
    echo "    copy pacman.hfe to the USB stick as DSKAnnnn.HFE"
fi
