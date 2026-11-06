#!/bin/sh
# Publishes the mod to the Steam Workshop with SteamCMD.
#
#   dev/publish.sh <steam_login> ["change note"]
#
# SteamCMD asks for the password and the Steam Guard code. The first run creates the item as PRIVATE
# and saves its id in dev/workshop/published_id; later runs update that same item. Visibility is only
# set on creation, so an update never hides a public mod. Title comes from modinfo.lua and the text from
# dev/workshop/description.txt, which overwrite edits made on the Workshop page.
set -e
LOGIN="$1"
NOTE="${2:-Update}"
if [ -z "$LOGIN" ]; then
    echo "usage: dev/publish.sh <steam_login> [\"change note\"]"
    exit 1
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WS="$HERE/dev/workshop"
STEAMCMD="${STEAMCMD:-$HOME/steamcmd/steamcmd.sh}"
STAGE="$WS/content"
VDF="$WS/item.vdf"

# Only the files the game needs go to the Workshop.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$HERE/modinfo.lua" "$HERE/modmain.lua" "$HERE/AutoOrganizeChests.xml" "$HERE/AutoOrganizeChests.tex" "$STAGE/"

ID=0
[ -f "$WS/published_id" ] && ID="$(cat "$WS/published_id")"
TITLE="$(sed -n 's/^name = "\(.*\)"$/\1/p' "$HERE/modinfo.lua")"
VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$HERE/modinfo.lua")"
escape() { sed 's/\\/\\\\/g; s/"/\\"/g'; }
DESCRIPTION="$(escape < "$WS/description.txt")"
CHANGENOTE="$(printf '%s: %s' "$VERSION" "$NOTE" | escape)"
VISIBILITY=""
[ "$ID" = "0" ] && VISIBILITY="	\"visibility\"	\"2\""

cat > "$VDF" <<VDF
"workshopitem"
{
	"appid"	"322330"
	"publishedfileid"	"$ID"
	"contentfolder"	"$STAGE"
	"previewfile"	"$WS/preview.png"
$VISIBILITY
	"title"	"$TITLE"
	"description"	"$DESCRIPTION"
	"changenote"	"$CHANGENOTE"
}
VDF

"$STEAMCMD" +login "$LOGIN" +workshop_build_item "$VDF" +quit

# SteamCMD writes the id of a newly created item back into the VDF.
NEW_ID="$(sed -n 's/.*"publishedfileid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$VDF")"
if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "0" ]; then
    echo "$NEW_ID" > "$WS/published_id"
    echo "Workshop item: https://steamcommunity.com/sharedfiles/filedetails/?id=$NEW_ID"
else
    echo "No Workshop id came back; check the SteamCMD output above."
    exit 1
fi
