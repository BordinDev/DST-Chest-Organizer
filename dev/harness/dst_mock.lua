-- Minimal Don't Starve Together simulation for testing modmain.lua outside the game.
-- Mirrors the behaviour of the game scripts (build 756039) the mod relies on:
--   components/container.lua  GiveItem, RemoveItemBySlot / RemoveItem_Internal, CanTakeItemInSlot,
--                             DropOverstackedExcess, IsOpenedByOthers, infinite stack size
--   components/inventory.lua  RemoveItem, GiveItem (slots, overflow backpack, active item, drop)
--   components/inventoryitem.lua  OnPutInInventory (parent, limbo) / OnRemoved (back to the world)
--   components/stackable.lua  Get (split, copies freshness), Put (merge, dilutes freshness), SetIgnoreMaxSize
--   modindex.lua              modinfo.lua runs in an empty sandbox
--   mods.lua                  CreateEnvironment (what a modmain can see)

local M = {}

local HERE = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./")
M.MODROOT = os.getenv("MODROOT") or (HERE .. "../../")

local W -- current world

------------------------------------------------------------------------------------------ entities
local Entity = {}
Entity.__index = Entity

function Entity:HasTag(t) return self.tags[t] == true end
function Entity:AddTag(t) self.tags[t] = true end
function Entity:RemoveTag(t) self.tags[t] = nil end
function Entity:IsValid() return self.valid end
function Entity:IsInLimbo() return self.inlimbo end
function Entity:Remove() self.valid = false; W.ents[self.GUID] = nil end
function Entity:GetPosition()
  local x, y, z = self.Transform:GetWorldPosition()
  return { x = x, y = y, z = z, Get = function(p) return p.x, p.y, p.z end }
end

local function NewEntity(prefab)
  W.guid = W.guid + 1
  local e = setmetatable({ GUID = W.guid, prefab = prefab, components = {}, tags = {}, valid = true,
    inlimbo = false, parent = nil, pos = { 0, 0, 0 } }, Entity)
  e.Transform = {
    SetPosition = function(_, x, y, z) e.pos = { x, y, z } end,
    GetWorldPosition = function()
      local p = e
      while p.parent ~= nil do p = p.parent end
      return p.pos[1], p.pos[2], p.pos[3]
    end,
  }
  W.ents[e.GUID] = e
  return e
end

------------------------------------------------------------------------------------------ components
local function InventoryItem(inst)
  local self = { inst = inst, owner = nil, cangoincontainer = true, canonlygoinpocket = false }
  function self:OnPutInInventory(owner)
    self.owner = owner; inst.parent = owner; inst.inlimbo = true; inst.pos = { 0, 0, 0 }
  end
  function self:OnRemoved() -- RemoveChild + ClearOwner + ReturnToScene
    inst.parent = nil; self.owner = nil; inst.inlimbo = false
  end
  function self:OnDropped()
    local x, y, z = (self.owner or inst).Transform:GetWorldPosition()
    self:OnRemoved(); inst.pos = { x, y, z }
  end
  return self
end

local function Perishable(inst, percent)
  local self = { inst = inst, perishtime = 1000 }
  self.perishremainingtime = self.perishtime * (percent or 1)
  function self:Dilute(number, timeleft)
    local size = inst.components.stackable.stacksize
    self.perishremainingtime = (size * self.perishremainingtime + number * timeleft) / (number + size)
  end
  return self
end

local function Stackable(inst, maxsize, size)
  local self = { inst = inst, stacksize = size or 1, maxsize = maxsize, originalmaxsize = nil }
  function self:StackSize() return self.stacksize end
  function self:IsStack() return self.stacksize > 1 end
  function self:IsFull() return self.stacksize >= self.maxsize end
  function self:IsOverStacked() return self.stacksize > (self.originalmaxsize or self.maxsize) end
  function self:CanStackWith(item)
    return inst.prefab == item.prefab and inst.skinname == item.skinname
      and not (inst.stackable_CanStackWithFn and not inst.stackable_CanStackWithFn(inst, item))
  end
  function self:SetIgnoreMaxSize(on)
    if on then
      if self.maxsize ~= math.huge then self.originalmaxsize = self.maxsize; self.maxsize = math.huge end
    elseif self.originalmaxsize then
      self.maxsize = self.originalmaxsize; self.originalmaxsize = nil
    end
  end
  function self:Get(num)
    num = num or 1
    if self.stacksize > num then
      local piece = M.spawn(inst.prefab, { skin = inst.skinname })
      self.stacksize = self.stacksize - num
      piece.components.stackable.stacksize = num
      if piece.components.perishable then
        piece.components.perishable.perishremainingtime = inst.components.perishable.perishremainingtime
      end
      if inst.components.inventoryitem.owner then
        piece.components.inventoryitem:OnPutInInventory(inst.components.inventoryitem.owner)
      end
      return piece
    end
    return inst
  end
  function self:Put(item)
    assert(item ~= inst, "cant stack on self")
    if not self:CanStackWith(item) then return nil end
    local add = item.components.stackable.stacksize
    local total = self.stacksize + add
    local newsize = math.min(self.maxsize, total)
    local added = newsize - self.stacksize
    if inst.components.perishable then
      inst.components.perishable:Dilute(added, item.components.perishable.perishremainingtime)
    end
    local ret
    if self.maxsize >= total then
      item:Remove()
    else
      item.components.stackable.stacksize = total - self.maxsize
      ret = item
    end
    self.stacksize = newsize
    return ret
  end
  return self
end

local function Container(inst, numslots)
  local self = { inst = inst, slots = {}, numslots = numslots, canbeopened = true, acceptsstacks = true,
    usespecificslotsforitems = false, readonlycontainer = false, itemtestfn = nil, infinitestacksize = false,
    ignoreoverstacked = false, opencount = 0, openlist = {} }
  function self:GetNumSlots() return self.numslots end
  function self:GetItemInSlot(slot) return self.slots[slot] end
  function self:EnableInfiniteStackSize(on) self.infinitestacksize = on end
  function self:IsOpenedByOthers(guy) return (self.opencount - (self.openlist[guy] and 1 or 0)) > 0 end
  function self:Open(guy) self.openlist[guy] = true; self.opencount = self.opencount + 1 end
  function self:CanTakeItemInSlot(item, slot)
    local ii = item.components.inventoryitem
    if not (ii and ii.cangoincontainer and not ii.canonlygoinpocket and not self.readonlycontainer) then return false end
    if slot and (slot < 1 or slot > self.numslots) then return false end
    return self.itemtestfn == nil or self:itemtestfn(item, slot)
  end
  function self:DropOverstackedExcess(item)
    local maxsize = item.components.stackable and item.components.stackable.originalmaxsize or nil
    if maxsize then
      local num = item.components.stackable:StackSize()
      if num > maxsize then
        local x, y, z = inst.Transform:GetWorldPosition()
        repeat
          local excess = item.components.stackable:Get(math.min(num - maxsize, maxsize))
          excess.components.inventoryitem:OnRemoved(); excess.pos = { x, y, z }
          W.dropped = W.dropped + excess.components.stackable.stacksize
          num = item.components.stackable:StackSize()
        until num <= maxsize
      end
    end
  end
  function self:GiveItem(item, slot, src_pos, drop_on_fail)
    if item == nil then return false end
    if W.give_hook then W.give_hook(self, item) end
    if item.components.inventoryitem ~= nil and self:CanTakeItemInSlot(item, slot) then
      if item.components.stackable ~= nil and self.acceptsstacks then
        if slot ~= nil and slot <= self.numslots then
          local other = self.slots[slot]
          if other and item.components.stackable:CanStackWith(other) and not other.components.stackable:IsFull() then
            item = other.components.stackable:Put(item)
            if item == nil then return true end
            slot = nil
          end
        end
        if slot == nil then
          for k = 1, self.numslots do
            local other = self.slots[k]
            if other and item.components.stackable:CanStackWith(other) and not other.components.stackable:IsFull() then
              item = other.components.stackable:Put(item)
              if item == nil then return true end
            end
          end
        end
      end
      local in_slot
      if slot ~= nil and slot <= self.numslots and not self.slots[slot] then
        in_slot = slot
      elseif not self.usespecificslotsforitems and self.numslots > 0 then
        for i = 1, self.numslots do if not self.slots[i] then in_slot = i; break end end
      end
      if in_slot then
        self.slots[in_slot] = item
        if self.infinitestacksize and item.components.stackable then item.components.stackable:SetIgnoreMaxSize(true) end
        item.components.inventoryitem:OnPutInInventory(inst)
        return true
      end
    end
    if drop_on_fail ~= false then
      self:DropOverstackedExcess(item)
      item.components.inventoryitem:OnRemoved()
      item.pos = { inst.pos[1], inst.pos[2], inst.pos[3] }
    end
    return false
  end
  function self:RemoveItemBySlot(slot, keepoverstacked)
    local item = slot and self.slots[slot] or nil
    if item == nil or self.readonlycontainer then return nil end
    local stackable = item.components.stackable
    if stackable and stackable:IsStack() then
      local num = (keepoverstacked and stackable:IsOverStacked() and stackable.originalmaxsize) or nil
      if num then
        local dec = stackable:Get(num)
        dec.components.inventoryitem:OnRemoved()
        return dec
      end
    end
    self.slots[slot] = nil
    if self.infinitestacksize and stackable then
      if not self.ignoreoverstacked then self:DropOverstackedExcess(item) end
      stackable:SetIgnoreMaxSize(false)
    end
    item.components.inventoryitem:OnRemoved()
    return item
  end
  return self
end

local function Inventory(inst)
  local self = { inst = inst, itemslots = {}, maxslots = 15, activeitem = nil, equipped = {} }
  function self:GetNumSlots() return self.maxslots end
  function self:GetItemInSlot(slot) return self.itemslots[slot] end
  function self:GetOverflowContainer()
    local body = self.equipped.body
    return body and body.components.container and body.components.container.canbeopened and body.components.container or nil
  end
  function self:Equip(item, slot) self.equipped[slot] = item; item.parent = inst; item.inlimbo = true end
  function self:RemoveItem(item, wholestack)
    for k, v in pairs(self.itemslots) do
      if v == item then
        self.itemslots[k] = nil
        item.components.inventoryitem:OnRemoved()
        return item
      end
    end
  end
  function self:Put(slot, item) self.itemslots[slot] = item; item.components.inventoryitem:OnPutInInventory(inst) end
  function self:GiveItem(item, slot)
    if slot and self.itemslots[slot] == nil then
      self:Put(slot, item); return true
    end
    if item.components.stackable then
      for k = 1, self.maxslots do
        local other = self.itemslots[k]
        if other and item.components.stackable:CanStackWith(other) and not other.components.stackable:IsFull() then
          item = other.components.stackable:Put(item)
          if item == nil then return true end
        end
      end
    end
    for k = 1, self.maxslots do
      if self.itemslots[k] == nil then self:Put(k, item); return true end
    end
    local overflow = self:GetOverflowContainer()
    if overflow and overflow:GiveItem(item, nil, nil, false) then return true end
    if self.activeitem == nil then
      self.activeitem = item; item.components.inventoryitem:OnPutInInventory(inst); return true
    end
    item.components.inventoryitem:OnDropped() -- can't hold it: drops at the player's feet
    return false
  end
  return self
end

------------------------------------------------------------------------------------------ prefabs
-- Server-side components that matter for the mod, taken from the game's prefab files.
M.PREFABS = {
  log = { stack = 40, edible = "WOOD" }, rocks = { stack = 40, edible = "ELEMENTAL" },
  flint = { stack = 40, edible = "ELEMENTAL" }, twigs = { stack = 40, edible = "ROUGHAGE" },
  cutgrass = { stack = 40, edible = "ROUGHAGE" }, goldnugget = { stack = 40, edible = "ELEMENTAL" },
  meat = { stack = 20, edible = "MEAT", perish = true }, berries = { stack = 40, edible = "VEGGIE", perish = true },
  meatballs = { stack = 40, edible = "MEAT", perish = true, tags = { "preparedfood" } },
  seeds = { stack = 40, edible = "SEEDS", perish = true }, poop = { stack = 40, fertilizer = true },
  pinecone = { stack = 40, deploy = 4 }, turf_grass = { stack = 10, deploy = 3 },
  healingsalve = { stack = 40, healer = true }, spidergland = { stack = 40, healer = true },
  rope = { stack = 40 }, boards = { stack = 40 }, nightmarefuel = { stack = 40 }, redgem = { stack = 40, tags = { "gem" } },
  silk = { stack = 40 }, pigskin = { stack = 40, edible = "HORRIBLE" }, houndstooth = { stack = 40 },
  wall_stone_item = { stack = 20 },
  spear = { uses = true, weapon = true, equip = "hands" }, axe = { uses = true, weapon = true, equip = "hands", tags = { "tool" } },
  pickaxe = { uses = true, weapon = true, equip = "hands", tags = { "tool" } }, hammer = { uses = true, equip = "hands", tags = { "tool" } },
  torch = { equip = "hands" }, armorwood = { armor = true, equip = "body" }, footballhat = { armor = true, equip = "head" },
  strawhat = { equip = "head" }, chester_eyebone = { tags = { "irreplaceable" } }, blueprint = {},
  treasurechest = { container = 9, tags = { "chest", "structure" } }, dragonflychest = { container = 12, tags = { "chest", "structure" } },
  pandoraschest = { container = 9, tags = { "chest", "structure" } },
  icebox = { container = 9, tags = { "fridge", "structure" } },
  chester = { container = 9, tags = { "chester", "fridge" } }, -- Snow Chester: a creature with the fridge tag
  saltbox = { container = 9, tags = { "saltbox", "structure" } }, backpack = { container = 8, equip = "body", nocontainer = true },
  wilson = { player = true, tags = { "player" } },
}
-- Recipes as the crafting menu filters list them (recipes_filter.lua).
M.FILTERS = {
  TOOLS = { "axe", "pickaxe", "hammer" }, WEAPONS = { "spear" }, ARMOUR = { "armorwood", "footballhat" },
  LIGHT = { "torch" }, CLOTHING = { "strawhat" }, REFINE = { "rope", "boards", "nightmarefuel" },
  MAGIC = { "nightmarefuel" }, RESTORATION = { "healingsalve" }, STRUCTURES = { "wall_stone_item" },
}

function M.spawn(prefab, opts)
  opts = opts or {}
  local def = assert(M.PREFABS[prefab], "unknown prefab " .. tostring(prefab))
  local e = NewEntity(prefab)
  e.skinname = opts.skin
  for _, t in ipairs(def.tags or {}) do e:AddTag(t) end
  local c = e.components
  if def.container then
    c.container = Container(e, def.container)
    if prefab == "icebox" then
      c.container.itemtestfn = function(_, item) return item.components.perishable ~= nil end
    elseif prefab == "saltbox" then
      c.container.itemtestfn = function(_, item) return item.components.edible ~= nil and item.components.edible.foodtype == "VEGGIE" end
    end
  end
  if def.player then
    c.inventory = Inventory(e)
    c.talker = { Say = function(_, text) table.insert(W.said, text) end }
    return e
  end
  if not def.container or def.equip then c.inventoryitem = InventoryItem(e) end
  if def.nocontainer then c.inventoryitem.cangoincontainer = false end
  if def.stack then c.stackable = Stackable(e, def.stack, opts.n) end
  if def.edible then c.edible = { foodtype = def.edible } end
  if def.perish then c.perishable = Perishable(e, opts.fresh) end
  if def.healer then c.healer = {} end
  if def.fertilizer then c.fertilizer = {} end
  if def.deploy then c.deployable = { mode = def.deploy } end
  if def.uses then c.finiteuses = { uses = opts.uses or 100 } end
  if def.weapon then c.weapon = {} end
  if def.armor then c.armor = { condition = opts.condition or 100 } end
  if def.equip then c.equippable = { equipslot = def.equip } end
  return e
end

------------------------------------------------------------------------------------------ world + mod loading
local function LoadModinfo()
  local fn = assert(loadfile(M.MODROOT .. "modinfo.lua"))
  local env = { folder_name = "DST-Chest-Organizer", locale = "en", ChooseTranslationTable = function(t) return t[1] end }
  setfenv(fn, env)
  local ok, err = pcall(fn)
  assert(ok, "modinfo.lua failed in the sandbox: " .. tostring(err))
  return env
end

function M.new_world(opts)
  opts = opts or {}
  W = { ents = {}, guid = 0, said = {}, sent = {}, prints = {}, time = 100, dropped = 0, handlers = {}, rpc = {},
    hud_focus = false, dedicated = opts.dedicated or false, give_hook = nil }
  M.W = W
  local modinfo = LoadModinfo()
  local config = {}
  for _, option in ipairs(modinfo.configuration_options) do config[option.name] = option.default end
  for k, v in pairs(opts.config or {}) do config[k] = v end
  W.modinfo, W.config = modinfo, config

  local G = {}
  G.GLOBAL = G
  G.KEY_Z, G.KEY_X, G.KEY_V, G.KEY_F1 = 122, 120, 118, 282
  G.DEPLOYMODE = { NONE = 0, DEFAULT = 1, ANYWHERE = 2, TURF = 3, PLANT = 4, WALL = 5, WATER = 6 }
  G.rawget, G.setmetatable, G.pcall, G.print = rawget, setmetatable, pcall, function(...) table.insert(W.prints, table.concat({ ... }, " ")) end
  G.GetTime = function() return W.time end
  G.TheNet = { IsDedicated = function() return W.dedicated end }
  G.TheInput = { AddKeyDownHandler = function(_, key, fn) W.handlers[key] = fn end }
  G.CRAFTING_FILTERS = {}
  for name, list in pairs(M.FILTERS) do G.CRAFTING_FILTERS[name] = { name = name, recipes = list } end
  G.AllRecipes = {}
  G.TheSim = { FindEntities = function(_, x, y, z, r, must, cant, mustone)
    local out = {}
    for _, e in pairs(W.ents) do
      local ok = e.valid and not e.inlimbo
      for _, t in ipairs(must or {}) do if not e:HasTag(t) then ok = false end end
      for _, t in ipairs(cant or {}) do if t ~= "INLIMBO" and e:HasTag(t) then ok = false end end
      if ok and mustone then
        local any = false
        for _, t in ipairs(mustone) do if e:HasTag(t) then any = true end end
        ok = any
      end
      if ok then
        local ex, _, ez = e.Transform:GetWorldPosition()
        if (ex - x) ^ 2 + (ez - z) ^ 2 <= r * r then table.insert(out, e) end
      end
    end
    table.sort(out, function(a, b) return a.GUID > b.GUID end) -- deliberately not position order
    return out
  end }
  W.G = G

  local player = M.spawn("wilson")
  player.HUD = { HasInputFocus = function() return W.hud_focus end }
  G.ThePlayer = player
  W.player = player

  package.preload["vector3"] = function() return true end
  local env = { pairs = pairs, ipairs = ipairs, print = G.print, math = math, table = table, type = type, string = string,
    tostring = tostring, require = require, GLOBAL = G, modname = "DST-Chest-Organizer", MODROOT = M.MODROOT }
  env.env = env
  env.GetModConfigData = function(name, get_local) return W.config[name] end
  env.AddModRPCHandler = function(ns, name, fn) W.rpc[ns .. "." .. name] = fn end
  env.GetModRPC = function(ns, name) return { namespace = ns, id = name } end
  env.SendModRPCToServer = function(id)
    table.insert(W.sent, id.id)
    W.rpc[id.namespace .. "." .. id.id](W.player) -- the server handler receives the player entity
  end
  local fn = assert(loadfile(M.MODROOT .. "modmain.lua"))
  setfenv(fn, env)
  fn()
  return W
end

function M.chest(prefab, x, z, contents)
  local c = M.spawn(prefab)
  c.pos = { x, 0, z }
  for _, spec in ipairs(contents or {}) do
    local item = M.spawn(spec[1], spec[2])
    assert(c.components.container:GiveItem(item, nil, nil, false), "test setup: chest full")
  end
  return c
end

function M.press(key)
  local fn = W.handlers[key]
  if fn then fn() end
end

function M.rpc(name)
  W.rpc["AutoOrganizeChests." .. name](W.player)
end

------------------------------------------------------------------------------------------ inspection
function M.where(item)
  if not item.valid then return "removed" end
  local owner = item.components.inventoryitem and item.components.inventoryitem.owner
  if owner == nil then return W.player.components.inventory.activeitem == item and "cursor" or "loose" end
  return owner
end

-- Units per prefab+skin across the whole world, plus freshness and durability fingerprints.
function M.census()
  local units, fresh, uses, loose = {}, {}, {}, 0
  for _, e in pairs(W.ents) do
    if e.valid and e.components.inventoryitem and not e.components.container then
      local key = e.prefab .. (e.skinname and ("/" .. e.skinname) or "")
      local n = e.components.stackable and e.components.stackable.stacksize or 1
      units[key] = (units[key] or 0) + n
      if e.components.perishable then
        fresh[key] = (fresh[key] or 0) + n * e.components.perishable.perishremainingtime
      end
      if e.components.finiteuses then
        uses[key] = uses[key] or {}
        table.insert(uses[key], e.components.finiteuses.uses)
      end
      if M.where(e) == "loose" then loose = loose + n end
    end
  end
  for _, list in pairs(uses) do table.sort(list) end
  return { units = units, fresh = fresh, uses = uses, loose = loose }
end

function M.contents(chest)
  local out = {}
  local c = chest.components.container
  for slot = 1, c.numslots do
    local it = c.slots[slot]
    out[slot] = it and (it.prefab .. (it.components.stackable and ("x" .. it.components.stackable.stacksize) or "")) or "-"
  end
  return table.concat(out, " ")
end

return M
