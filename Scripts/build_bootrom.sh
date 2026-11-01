#!/bin/sh
# Rebuilds SameBoy's open-source CGB boot ROM and copies it into the app bundle resources.
# Requires rgbds (`brew install rgbds`). Never use Nintendo's original boot ROM.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
make -C "$ROOT/Vendor/SameBoy" build/bin/BootROMs/cgb_boot.bin
cp "$ROOT/Vendor/SameBoy/build/bin/BootROMs/cgb_boot.bin" "$ROOT/GBEmu/Resources/BootROMs/cgb_boot.bin"
echo "Updated GBEmu/Resources/BootROMs/cgb_boot.bin"
