-- Run from anywhere with Lua 5.1:  lua dev/harness/tests.lua
package.path = (arg[0]:match("(.*/)") or "./") .. "?.lua;" .. package.path
local M = require("dst_mock")

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. msg) end
end
local function test(name, fn)
  print("== " .. name)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then failed = failed + 1; print("  ERROR: " .. tostring(err)) end
end

-- Category of each test prefab, as the mod should see it.
local CATEGORY = {
  log = "resources", rocks = "resources", flint = "resources", twigs = "resources", cutgrass = "resources", goldnugget = "resources",
  meat = "food", berries = "food", meatballs = "food", seeds = "farming", poop = "farming", pinecone = "farming",
  healingsalve = "healing", spidergland = "healing", rope = "refined", boards = "refined", nightmarefuel = "magic", redgem = "magic",
  silk = "materials", pigskin = "materials", houndstooth = "materials", wall_stone_item = "building", turf_grass = "building",
  spear = "weapons", axe = "tools", pickaxe = "tools", hammer = "tools", torch = "tools", armorwood = "armor", footballhat = "armor",
  strawhat = "clothing", chester_eyebone = "misc", blueprint = "misc",
}

local slot_categories_fwd
local FAMILY = { food = "provisions", farming = "provisions", healing = "provisions",
  tools = "equipment", weapons = "equipment", armor = "equipment", clothing = "equipment", magic = "equipment",
  resources = "materials", materials = "materials", refined = "materials", building = "materials", misc = "misc" }

local function families_in(chest)
  local set, n = {}, 0
  for _, c in ipairs(slot_categories_fwd(chest)) do
    if not set[FAMILY[c]] then set[FAMILY[c]] = true; n = n + 1 end
  end
  return n
end

local function same_census(a, b)
  for k, v in pairs(a.units) do check(b.units[k] == v, ("units of %s: %s -> %s"):format(k, v, tostring(b.units[k]))) end
  for k, v in pairs(b.units) do check(a.units[k] ~= nil, "new item type appeared: " .. k .. " x" .. v) end
  for k, v in pairs(a.fresh) do check(math.abs((b.fresh[k] or 0) - v) < 1e-6 * math.max(1, v), "freshness of " .. k .. " changed") end
  for k, list in pairs(a.uses) do
    check(table.concat(list, ",") == table.concat(b.uses[k] or {}, ","), "durability of " .. k .. " changed")
  end
end

local function slot_categories(chest)
  local out = {}
  local c = chest.components.container
  for slot = 1, c.numslots do
    local it = c.slots[slot]
    if it then table.insert(out, CATEGORY[it.prefab] or "?") end
  end
  return out
end

slot_categories_fwd = slot_categories

-- Checks the bookshelf layout: inside a chest every category is one contiguous run, categories never
-- come back after another one started, and empty slots only at the end.
local function check_layout(chests)
  local seen_done = {}
  local last
  for i, chest in ipairs(chests) do
    local c = chest.components.container
    local gap = false
    for slot = 1, c.numslots do
      local it = c.slots[slot]
      if it == nil then gap = true
      else
        check(not gap, ("chest %d has a hole before slot %d"):format(i, slot))
        local cat = CATEGORY[it.prefab]
        if cat ~= last then
          check(not seen_done[cat], ("category %s is split around another category (chest %d slot %d)"):format(cat, i, slot))
          if last then seen_done[last] = true end
          last = cat
        end
      end
    end
  end
end

local function snapshot_slots(chests)
  local out = {}
  for i, chest in ipairs(chests) do
    out[i] = {}
    for slot = 1, chest.components.container.numslots do out[i][slot] = chest.components.container.slots[slot] or false end
  end
  return out
end

local function show(chests)
  for i, chest in ipairs(chests) do print(("   chest %d: %s"):format(i, M.contents(chest))) end
end

------------------------------------------------------------------------------------------------------------
test("modinfo loads in the empty sandbox and keys are per-player options", function()
  local W = M.new_world()
  local keys = 0
  for _, o in ipairs(W.modinfo.configuration_options) do
    if o.name == "organize_key" or o.name == "quickstack_key" then keys = keys + 1; check(o.client == true, o.name .. " should be client = true") end
  end
  check(keys == 2, "both key options exist")
  check(W.modinfo.all_clients_require_mod == true and W.modinfo.client_only_mod == false, "server + client mod flags")
end)

test("organize: three mixed chests", function()
  local W = M.new_world()
  local chests = {
    M.chest("treasurechest", 0, 0, { { "log", { n = 20 } }, { "meat", { n = 3, fresh = 0.4 } }, { "spear", { uses = 30 } }, { "rope", { n = 5 } }, { "berries", { n = 10, fresh = 0.5 } }, { "silk", { n = 3 } } }),
    M.chest("treasurechest", 3, 0, { { "axe", { uses = 55 } }, { "rocks", { n = 15 } }, { "healingsalve", { n = 2 } }, { "log", { n = 27 } }, { "strawhat" }, { "meat", { n = 2, fresh = 0.9 } } }),
    M.chest("treasurechest", 6, 0, { { "twigs", { n = 30 } }, { "pickaxe", { uses = 80 } }, { "meatballs", { n = 2 } }, { "silk", { n = 6 } }, { "seeds", { n = 12 } }, { "nightmarefuel", { n = 4 } } }),
  }
  local before = M.census()
  M.rpc("Organize")
  show(chests)
  local after = M.census()
  same_census(before, after)
  check(after.loose == 0, "no item left loose in the world")
  check(W.dropped == 0, "nothing spilled on the ground")
  check(W.said[#W.said] == "Organized 3 chests.", "message was: " .. tostring(W.said[#W.said]))
  check_layout(chests)
  for i, chest in ipairs(chests) do
    check(families_in(chest) == 1, ("chest %d should hold one family of categories, holds %d"):format(i, families_in(chest)))
  end
  -- logs 20 + 27 merge into 40 + 7; silk 3 + 6 into one stack
  local logs = {}
  for _, chest in ipairs(chests) do for _, it in pairs(chest.components.container.slots) do if it.prefab == "log" then table.insert(logs, it.components.stackable.stacksize) end end end
  table.sort(logs)
  check(table.concat(logs, ",") == "7,40", "logs merged into full stacks, got " .. table.concat(logs, ","))

  local layout = snapshot_slots(chests)
  W.time = W.time + 5
  M.rpc("Organize")
  check(W.said[#W.said] == "These chests are already organized.", "second press: " .. tostring(W.said[#W.said]))
  local again = snapshot_slots(chests)
  local same = true
  for i = 1, #chests do for s = 1, 9 do if layout[i][s] ~= again[i][s] then same = false end end end
  check(same, "second press changes nothing")
end)

test("organize: chests keep the category they already hold", function()
  local W = M.new_world()
  local food = M.chest("treasurechest", 0, 0, { { "meat", { n = 3 } }, { "berries", { n = 10 } }, { "meatballs", { n = 2 } }, { "spear" } })
  local tools = M.chest("treasurechest", 3, 0, { { "axe" }, { "pickaxe" }, { "hammer" }, { "berries", { n = 5 } } })
  M.rpc("Organize")
  show({ food, tools })
  local cats = slot_categories(food)
  for _, c in ipairs(cats) do check(c == "food", "food chest got " .. c) end
  local has_tools = false
  for _, c in ipairs(slot_categories(tools)) do if c == "tools" then has_tools = true end check(c ~= "food", "tools chest got food") end
  check(has_tools, "tools stay in the tools chest")
end)

test("organize: with spare chests every category gets its own chest", function()
  local W = M.new_world()
  local chests = {
    M.chest("treasurechest", 0, 0, { { "log", { n = 10 } }, { "axe" }, { "meat", { n = 2 } } }),
    M.chest("treasurechest", 3, 0, { { "rocks", { n = 10 } }, { "berries", { n = 4 } } }),
    M.chest("treasurechest", 6, 0, { { "pickaxe" } }),
    M.chest("treasurechest", 9, 0, {}),
    M.chest("dragonflychest", 12, 0, {}),
  }
  local before = M.census()
  M.rpc("Organize")
  show(chests)
  same_census(before, M.census())
  for i, chest in ipairs(chests) do
    local distinct = {}
    for _, c in ipairs(slot_categories(chest)) do distinct[c] = true end
    local n = 0 for _ in pairs(distinct) do n = n + 1 end
    check(n <= 1, ("chest %d mixes %d categories"):format(i, n))
  end
end)

test("organize: upgraded chest with an oversized stack spills nothing", function()
  local W = M.new_world()
  local normal = M.chest("treasurechest", 0, 0, { { "log", { n = 20 } }, { "spear" }, { "spear", { uses = 12 } }, { "spear", { uses = 70 } } })
  local upgraded = M.spawn("treasurechest"); upgraded.pos = { 3, 0, 0 }
  upgraded.components.container:EnableInfiniteStackSize(true)
  upgraded.components.container:GiveItem(M.spawn("rocks", { n = 500 }), nil, nil, false)
  upgraded.components.container:GiveItem(M.spawn("berries", { n = 5 }), nil, nil, false)
  local before = M.census()
  M.rpc("Organize")
  show({ normal, upgraded })
  local after = M.census()
  same_census(before, after)
  check(W.dropped == 0, "excess of the oversized stack was not dropped (dropped " .. W.dropped .. ")")
  check(after.loose == 0, "no item left loose")
  for _, chest in ipairs({ normal }) do
    for _, it in pairs(chest.components.container.slots) do
      if it.components.stackable then check(it.components.stackable.stacksize <= 40, "normal chest holds an oversized stack") end
    end
  end
  local rock_stacks = {}
  for _, chest in ipairs({ normal, upgraded }) do
    for _, it in pairs(chest.components.container.slots) do
      if it.prefab == "rocks" then table.insert(rock_stacks, (chest == upgraded and "upgraded:" or "normal:") .. it.components.stackable.stacksize) end
    end
  end
  check(#rock_stacks == 1 and rock_stacks[1] == "upgraded:500", "the 500 rocks stay together in the upgraded chest, got " .. table.concat(rock_stacks, " "))
end)

test("organize: loot chests, burnt chests, chests open by others and iceboxes are left alone", function()
  local W = M.new_world()
  local mine = M.chest("treasurechest", 0, 0, { { "axe" }, { "meat" }, { "log", { n = 5 } } })
  local loot = M.chest("pandoraschest", 2, 0, { { "spear" }, { "redgem", { n = 2 } } })
  local burnt = M.chest("treasurechest", 4, 0, { { "rope", { n = 3 } } }); burnt:AddTag("burnt")
  local busy = M.chest("treasurechest", 6, 0, { { "rocks", { n = 3 } } }); busy.components.container:Open({})
  local ice = M.chest("icebox", 8, 0, { { "berries", { n = 3 } } })
  local before = snapshot_slots({ loot, burnt, busy, ice })
  M.rpc("Organize")
  local after = snapshot_slots({ loot, burnt, busy, ice })
  local same = true
  for i = 1, 4 do for s = 1, 9 do if before[i][s] ~= after[i][s] then same = false end end end
  check(same, "excluded containers were not touched")
  check(W.said[#W.said] == "Organized 1 chest." or W.said[#W.said] == "These chests are already organized.", "message: " .. tostring(W.said[#W.said]))
end)

test("organize: chest out of range is left alone", function()
  local W = M.new_world()
  local near = M.chest("treasurechest", 3, 0, { { "axe" }, { "meat" } })
  local far = M.chest("treasurechest", 12, 0, { { "log", { n = 5 } }, { "spear" } })
  local before = snapshot_slots({ far })
  M.rpc("Organize")
  local after = snapshot_slots({ far })
  check(before[1][1] == after[1][1] and before[1][2] == after[1][2], "chest at 12 units (range 10) untouched")
end)

test("organize: an error in the middle puts every item back", function()
  local W = M.new_world()
  local a = M.chest("treasurechest", 0, 0, { { "log", { n = 20 } }, { "meat", { n = 3 } }, { "spear", { uses = 33 } } })
  local b = M.chest("treasurechest", 3, 0, { { "axe", { uses = 44 } }, { "rocks", { n = 15 } }, { "berries", { n = 7 } } })
  local fired = false
  W.give_hook = function(container)
    if not fired and container.inst == b then fired = true; error("simulated failure") end
  end
  local before = M.census()
  M.rpc("Organize")
  local after = M.census()
  check(fired, "failure was injected")
  same_census(before, after)
  check(after.loose == 0, "no item left loose after the failure")
  local logged = false
  for _, p in ipairs(W.prints) do if p:find("organize failed") then logged = true end end
  check(logged, "failure was logged")
end)

test("organize: skins, durability and freshness travel with the items", function()
  local W = M.new_world()
  local skinned = M.spawn("spear", { skin = "spear_rose", uses = 41 })
  local a = M.chest("treasurechest", 0, 0, { { "berries", { n = 3, fresh = 0.2 } }, { "rocks", { n = 2 } } })
  a.components.container:GiveItem(skinned, nil, nil, false)
  local b = M.chest("treasurechest", 3, 0, { { "berries", { n = 3, fresh = 0.9 } }, { "spear", { uses = 5 } } })
  local before = M.census()
  M.rpc("Organize")
  same_census(before, M.census())
  check(skinned:IsValid() and skinned.skinname == "spear_rose" and skinned.components.finiteuses.uses == 41, "skinned spear is the same entity, same skin and durability")
  check(M.where(skinned) ~= "loose", "skinned spear is inside a chest")
end)

test("quick stack: stackables go to chests that hold them; the rest stays", function()
  local W = M.new_world()
  local inv = W.player.components.inventory
  local logs = M.spawn("log", { n = 20 }); inv:Put(1, logs)
  local rocks = M.spawn("rocks", { n = 5 }); inv:Put(2, rocks)
  local axe = M.spawn("axe"); inv:Put(3, axe)
  local berries = M.spawn("berries", { n = 3 }); inv:Put(4, berries)
  local a = M.chest("treasurechest", 0, 0, { { "log", { n = 30 } } })
  local full = { { "rocks", { n = 39 } } }
  for i = 1, 8 do table.insert(full, { "silk", { n = 40 } }) end
  local b = M.chest("treasurechest", 3, 0, full)
  local ice = M.chest("icebox", 6, 0, { { "berries", { n = 2 } } })
  local axes = M.chest("treasurechest", -3, 0, { { "axe" } })
  local before = M.census()
  M.rpc("QuickStack")
  show({ a, b, ice })
  same_census(before, M.census())
  check(M.census().loose == 0, "nothing loose")
  check(inv.itemslots[1] == nil, "logs left the inventory")
  check(inv.itemslots[2] ~= nil and inv.itemslots[2].components.stackable.stacksize == 4, "4 rocks did not fit and came back to slot 2")
  check(inv.itemslots[3] == axe, "the axe stays with the player")
  check(inv.itemslots[4] == nil, "berries went to the icebox")
  check(W.said[#W.said] == "Stacked 24 items into the chests.", "message: " .. tostring(W.said[#W.said]))
end)

test("quick stack: backpack items, and the icebox option", function()
  local W = M.new_world({ config = { quickstack_fridges = false } })
  local inv = W.player.components.inventory
  local pack = M.spawn("backpack"); inv:Equip(pack, "body")
  pack.components.container:GiveItem(M.spawn("twigs", { n = 10 }), nil, nil, false)
  local meat = M.spawn("meat", { n = 2 }); inv:Put(1, meat)
  local chest = M.chest("treasurechest", 0, 0, { { "twigs", { n = 5 } } })
  local ice = M.chest("icebox", 3, 0, { { "meat", { n = 1 } } })
  M.rpc("QuickStack")
  check(pack.components.container.slots[1] == nil, "twigs left the backpack")
  check(chest.components.container.slots[1].components.stackable.stacksize == 15, "twigs merged in the chest")
  check(inv.itemslots[1] == meat, "with the icebox option off, meat stays")
end)

test("quick stack: Snow Chester is a creature, not a chest", function()
  local W = M.new_world()
  local inv = W.player.components.inventory
  local berries = M.spawn("berries", { n = 4 }); inv:Put(1, berries)
  local chester = M.chest("chester", 2, 0, { { "berries", { n = 3 } } })
  M.chest("treasurechest", 4, 0, { { "log", { n = 3 } } })
  M.rpc("QuickStack")
  check(inv.itemslots[1] == berries, "berries stay with the player")
  check(chester.components.container.slots[1].components.stackable.stacksize == 3, "nothing went into Chester")
  check(W.said[#W.said] == "Nothing here to stack.", "message: " .. tostring(W.said[#W.said]))
end)

test("client: keys are ignored while typing, and work otherwise", function()
  local W = M.new_world()
  M.chest("treasurechest", 0, 0, { { "axe" }, { "meat" } })
  W.hud_focus = true
  M.press(W.G.KEY_Z)
  check(#W.sent == 0, "no request while chat or a menu has focus")
  W.hud_focus = false
  M.press(W.G.KEY_Z)
  check(#W.sent == 1 and W.sent[1] == "Organize", "Z sends the organize request")
  W.time = W.time + 5
  M.press(W.G.KEY_X)
  check(W.sent[2] == "QuickStack", "X sends the quick stack request")
  W.player:AddTag("playerghost")
  M.press(W.G.KEY_Z)
  check(#W.sent == 2, "ghosts don't send requests")
end)

test("client: keys come from each player's own settings", function()
  local W = M.new_world({ config = { organize_key = "KEY_F1", quickstack_key = "none" } })
  check(W.handlers[282] ~= nil, "organize bound to F1")
  check(W.handlers[122] == nil and W.handlers[120] == nil, "Z and X unbound; quick stack disabled")
end)

test("dedicated server: no key handlers, RPC handlers ready", function()
  local W = M.new_world({ dedicated = true })
  local n = 0 for _ in pairs(W.handlers) do n = n + 1 end
  check(n == 0, "no key handlers on a dedicated server")
  check(W.rpc["AutoOrganizeChests.Organize"] ~= nil and W.rpc["AutoOrganizeChests.QuickStack"] ~= nil, "RPC handlers registered")
end)

test("server: requests within the cooldown are ignored", function()
  local W = M.new_world()
  M.chest("treasurechest", 0, 0, { { "axe" }, { "meat" } })
  M.rpc("Organize"); M.rpc("Organize")
  check(#W.said == 1, "second request inside 1 s ignored, got " .. #W.said .. " messages")
  W.time = W.time + 2
  M.rpc("Organize")
  check(#W.said == 2, "works again after the cooldown")
end)

test("messages when there is nothing to do", function()
  local W = M.new_world()
  M.rpc("Organize")
  check(W.said[#W.said] == "There are no chests around here.", "no chests: " .. tostring(W.said[#W.said]))
  W.time = W.time + 5
  M.chest("treasurechest", 0, 0, {})
  M.rpc("Organize")
  check(W.said[#W.said] == "These chests are already organized.", "empty chest: " .. tostring(W.said[#W.said]))
  W.time = W.time + 5
  M.rpc("QuickStack")
  check(W.said[#W.said] == "Nothing here to stack.", "nothing to stack: " .. tostring(W.said[#W.said]))
end)

test("300 random bases: organize twice, then quick stack, never create, lose or spill anything", function()
  local STACKABLES = { "log", "rocks", "flint", "twigs", "cutgrass", "goldnugget", "meat", "berries", "meatballs", "seeds",
    "poop", "pinecone", "healingsalve", "spidergland", "rope", "boards", "nightmarefuel", "redgem", "silk", "pigskin",
    "houndstooth", "wall_stone_item", "turf_grass" }
  local SINGLES = { "spear", "axe", "pickaxe", "hammer", "torch", "armorwood", "footballhat", "strawhat", "chester_eyebone", "blueprint" }

  local function diff(a, b)
    for k, v in pairs(a.units) do if b.units[k] ~= v then return ("units of %s %s -> %s"):format(k, v, tostring(b.units[k])) end end
    for k, v in pairs(b.units) do if a.units[k] == nil then return "new item type " .. k end end
    for k, v in pairs(a.fresh) do if math.abs((b.fresh[k] or 0) - v) > 1e-6 * math.max(1, v) then return "freshness of " .. k end end
    for k, list in pairs(a.uses) do if table.concat(list, ",") ~= table.concat(b.uses[k] or {}, ",") then return "durability of " .. k end end
  end

  local function mod_order(list)
    table.sort(list, function(a, b)
      local ia = a.components.container.infinitestacksize and 0 or 1
      local ib = b.components.container.infinitestacksize and 0 or 1
      if ia ~= ib then return ia < ib end
      local ax, az, bx, bz = math.floor(a.pos[1] * 10 + 0.5), math.floor(a.pos[3] * 10 + 0.5), math.floor(b.pos[1] * 10 + 0.5), math.floor(b.pos[3] * 10 + 0.5)
      if ax ~= bx then return ax < bx elseif az ~= bz then return az < bz end
      return a.GUID < b.GUID
    end)
    return list
  end

  local bad, organized_runs, replies = {}, 0, {}
  for seed = 1, 300 do
    math.randomseed(seed)
    local W = M.new_world()
    local in_range = {}
    for i = 1, math.random(1, 7) do
      local c = M.spawn(math.random() < 0.2 and "dragonflychest" or "treasurechest")
      c.pos = { math.random(-9, 9), 0, math.random(-9, 9) }
      local container = c.components.container
      if math.random() < 0.25 then container:EnableInfiniteStackSize(true) end
      for _ = 1, math.random(0, container.numslots) do
        local item
        if math.random() < 0.65 then
          local prefab = STACKABLES[math.random(#STACKABLES)]
          local max = M.PREFABS[prefab].stack
          local n = math.random(1, max)
          if container.infinitestacksize and math.random() < 0.3 then n = math.random(max, max * 6) end
          item = M.spawn(prefab, { n = n, fresh = math.random(), skin = math.random() < 0.1 and "skin_a" or nil })
        else
          item = M.spawn(SINGLES[math.random(#SINGLES)], { uses = math.random(1, 100), skin = math.random() < 0.2 and "skin_b" or nil })
        end
        container:GiveItem(item, nil, nil, false)
      end
      if c.pos[1] ^ 2 + c.pos[3] ^ 2 <= 100 then table.insert(in_range, c) end
    end
    local inv = W.player.components.inventory
    for _ = 1, math.random(0, 16) do
      if math.random() < 0.7 then
        local prefab = STACKABLES[math.random(#STACKABLES)]
        inv:GiveItem(M.spawn(prefab, { n = math.random(1, M.PREFABS[prefab].stack), fresh = math.random() }))
      else
        inv:GiveItem(M.spawn(SINGLES[math.random(#SINGLES)], { uses = math.random(1, 100) }))
      end
    end
    local start = M.census()

    local problem
    M.rpc("Organize")
    local first = W.said[#W.said]
    local reply = tostring(first):gsub("%d+", "N")
    replies[reply] = (replies[reply] or 0) + 1
    local now = M.census()
    problem = diff(start, now) or (now.loose > 0 and "loose items after organize") or (W.dropped > 0 and "items spilled")
    if not problem and first and first:find("^Organized") then
      organized_runs = organized_runs + 1
      local passed_before, failed_before = passed, failed
      check_layout(mod_order(in_range))
      if failed > failed_before then problem = "layout broken" end
      for _, c in ipairs(in_range) do
        if not c.components.container.infinitestacksize then
          for _, it in pairs(c.components.container.slots) do
            if it.components.stackable and it.components.stackable.stacksize > it.components.stackable.maxsize then problem = "oversized stack in a normal chest" end
          end
        end
      end
      W.time = W.time + 5
      M.rpc("Organize")
      if not problem and W.said[#W.said] ~= "These chests are already organized." then problem = "second organize changed things: " .. tostring(W.said[#W.said]) end
    end
    if not problem then
      W.time = W.time + 5
      M.rpc("QuickStack")
      local after = M.census()
      problem = diff(start, after) or (after.loose > 0 and "loose items after quick stack")
    end
    for _, line in ipairs(W.prints) do problem = problem or ("mod printed: " .. line) end
    if problem then table.insert(bad, "seed " .. seed .. ": " .. problem) end
  end
  check(#bad == 0, #bad .. " random bases failed; first: " .. tostring(bad[1]) .. (bad[2] and (" | " .. bad[2]) or ""))
  for reply, n in pairs(replies) do print(("   %3d x %s"):format(n, reply)) end
end)

print(("\n%d checks passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
