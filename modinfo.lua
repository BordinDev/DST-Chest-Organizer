name = "Better Chests"
description = [[Organize every chest around you with one key, and quick stack your inventory into the chests that already hold the same items.

Organize (default: Z)
Groups the items of all nearby chests by category: food, farming, healing, tools, weapons, armor, clothing, magic, refined materials, resources, materials, building and misc. While there is room, each category starts in its own chest, and chests keep the category they already hold.

Quick stack (default: X)
Moves stackable items from your inventory and backpack into nearby chests that already contain them.

Items are moved, never re-created, so durability, freshness, skins and contents are kept. Works on dedicated servers and in worlds with caves. Each player can change the keys in the mod's client settings.]]
author = "Bordin"
version = "1.0.0"
forumthread = ""

api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false

all_clients_require_mod = true
client_only_mod = false
server_filter_tags = { "storage", "chest organizer", "quick stack" }

icon_atlas = "AutoOrganizeChests.xml"
icon = "AutoOrganizeChests.tex"

-- Workshop copies otherwise use a file manifest. The mod has almost no assets, so it loads files the
-- same way as the local copy that was tested.
forcemanifest = false

-- modinfo.lua runs in an empty sandbox: no ipairs and no string library, only plain Lua syntax.
local KEYS = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
}
local key_options = {}
for i = 1, #KEYS do
    key_options[i] = { description = KEYS[i], data = "KEY_" .. KEYS[i] }
end
key_options[#KEYS + 1] = { description = "Disabled", data = "none" }

local yes_no = {
    { description = "Yes", data = true },
    { description = "No", data = false },
}

configuration_options =
{
    {
        name = "organize_key",
        label = "Organize key",
        hover = "Key that organizes the chests around you.",
        options = key_options,
        default = "KEY_Z",
        client = true,
    },
    {
        name = "quickstack_key",
        label = "Quick stack key",
        hover = "Key that moves your items into nearby chests that already hold them.",
        options = key_options,
        default = "KEY_X",
        client = true,
    },
    {
        name = "radius",
        label = "Chest range",
        hover = "How far from you a chest can be. One turf tile is 4 units.",
        options =
        {
            { description = "6", data = 6 },
            { description = "10", data = 10 },
            { description = "15", data = 15 },
            { description = "20", data = 20 },
            { description = "30", data = 30 },
        },
        default = 10,
    },
    {
        name = "quickstack_backpack",
        label = "Quick stack backpack",
        hover = "Quick stack also takes the items in your backpack.",
        options = yes_no,
        default = true,
    },
    {
        name = "quickstack_fridges",
        label = "Quick stack into iceboxes",
        hover = "Quick stack also fills iceboxes and salt boxes that already hold the item. Organize never touches them.",
        options = yes_no,
        default = true,
    },
    {
        name = "feedback",
        label = "Speech feedback",
        hover = "Your character says what was organized or stacked.",
        options = yes_no,
        default = true,
    },
}
