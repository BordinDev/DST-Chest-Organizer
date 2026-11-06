#!/bin/sh
# Copies the mod into the local Don't Starve Together install, so it shows up in the game's Mods menu.
# Run it again after every change. Override the game folder with DST_DIR=/path/to/game.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DST="${DST_DIR:-/mnt/Ventoy/SteamLibrary/steamapps/common/Don't Starve Together}"
DEST="$DST/mods/DST-Chest-Organizer"
mkdir -p "$DEST"
cp "$HERE/modinfo.lua" "$HERE/modmain.lua" "$HERE/AutoOrganizeChests.xml" "$HERE/AutoOrganizeChests.tex" "$DEST/"
echo "Installed to $DEST"
