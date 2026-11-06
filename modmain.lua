--[[
    Better Chests

    Client: a key press only sends a mod RPC, and only while no chat, console or menu has input focus.
    Server: finds the usable chests around the player, plans the whole layout first, and only then moves
    the real item entities with the game's own container calls. Items are never re-created, so durability,
    freshness, skins and contents travel with them. Whatever cannot be placed goes back into a chest, then
    into the player's inventory, and only as a last resort to the player's feet.
]]

local G = GLOBAL

local NAMESPACE = "AutoOrganizeChests"
local COOLDOWN = 1 -- seconds between two requests from the same player
local MAX_PIECES_PER_SLOT = 1000 -- safety stop when emptying a slot

--------------------------------------------------------------------------------------------------
-- Settings and messages
--------------------------------------------------------------------------------------------------

local RADIUS = GetModConfigData("radius") or 10
local QUICKSTACK_BACKPACK = GetModConfigData("quickstack_backpack") ~= false
local QUICKSTACK_FRIDGES = GetModConfigData("quickstack_fridges") ~= false
local FEEDBACK = GetModConfigData("feedback") ~= false

local MESSAGES = {
    ORGANIZED = "Organized %d chest%s.",
    ALREADY_ORGANIZED = "These chests are already organized.",
    NO_CHESTS = "There are no chests around here.",
    NO_ROOM = "These chests don't have room to be organized.",
    STACKED = "Stacked %d item%s into the chests.",
    NOTHING_TO_STACK = "Nothing here to stack.",
}

local function Plural(count)
    return count == 1 and "" or "s"
end

local function Say(player, text)
    if FEEDBACK and player.components.talker ~= nil then
        player.components.talker:Say(text)
    end
end

--------------------------------------------------------------------------------------------------
-- Which containers can be used
--------------------------------------------------------------------------------------------------

-- These carry the "chest" tag but belong to the world, a puzzle, a boat or a drone.
local EXCLUDED_PREFABS = {
    pandoraschest = true,
    minotaurchest = true,
    terrariumchest = true,
    sunkenchest = true,
    sacred_chest = true,
    boat_ancient_container = true,
    wx78_drone_delivery = true,
    wx78_drone_delivery_small = true,
}

-- "structure" keeps creatures out: Snow Chester also has the "fridge" tag, and Chester and Hutch carry items.
local MUST_TAGS = { "structure" }
local CANT_TAGS = { "INLIMBO", "burnt", "FX", "NOCLICK" }
local CHEST_TAGS = { "chest" }
local STORAGE_TAGS = { "chest", "fridge", "saltbox" }

-- allow_restricted lets quick stack use containers that only accept some items, like iceboxes and salt
-- boxes: the game itself refuses what doesn't belong. Organize moves everything, so it skips them.
local function IsUsable(inst, player, allow_restricted)
    local container = inst.components.container
    return container ~= nil
        and not EXCLUDED_PREFABS[inst.prefab]
        and not inst:HasTag("burnt")
        and inst.components.inventoryitem == nil
        and container:GetNumSlots() > 0
        and container.canbeopened
        and container.acceptsstacks
        and not container.readonlycontainer
        and not container.usespecificslotsforitems
        and (allow_restricted or container.itemtestfn == nil)
        and not container:IsOpenedByOthers(player)
end

-- Upgraded chests come first, so big stacks stay in them. Then world position, so the result doesn't
-- depend on where the player stands.
local function SortChests(list)
    local order = {}
    for _, inst in ipairs(list) do
        local x, y, z = inst.Transform:GetWorldPosition()
        order[inst] = { inst.components.container.infinitestacksize and 0 or 1, math.floor(x * 10 + 0.5), math.floor(z * 10 + 0.5) }
    end
    table.sort(list, function(a, b)
        local ka, kb = order[a], order[b]
        for i = 1, 3 do
            if ka[i] ~= kb[i] then
                return ka[i] < kb[i]
            end
        end
        return a.GUID < b.GUID
    end)
    return list
end

local function FindContainers(player, include_fridges, allow_restricted)
    local x, y, z = player.Transform:GetWorldPosition()
    local found = G.TheSim:FindEntities(x, y, z, RADIUS, MUST_TAGS, CANT_TAGS, include_fridges and STORAGE_TAGS or CHEST_TAGS)
    local usable = {}
    for _, inst in ipairs(found) do
        if IsUsable(inst, player, allow_restricted) then
            table.insert(usable, inst)
        end
    end
    return SortChests(usable)
end

--------------------------------------------------------------------------------------------------
-- Categories
--------------------------------------------------------------------------------------------------

-- Categories in the order they are laid out. Related categories form a family that stays together.
local CATEGORIES = {
    { "food", "provisions" }, { "farming", "provisions" }, { "healing", "provisions" },
    { "tools", "equipment" }, { "weapons", "equipment" }, { "armor", "equipment" },
    { "clothing", "equipment" }, { "magic", "equipment" },
    { "resources", "materials" }, { "materials", "materials" }, { "refined", "materials" },
    { "building", "materials" },
    { "misc", "misc" },
}
local CATEGORY_FAMILY, FAMILY_RANK = {}, {}
for rank, entry in ipairs(CATEGORIES) do
    CATEGORY_FAMILY[entry[1]] = entry[2]
    FAMILY_RANK[entry[2]] = FAMILY_RANK[entry[2]] or rank
end

local BASIC_RESOURCES = {
    log = true, twigs = true, cutgrass = true, cutreeds = true, rocks = true, flint = true,
    goldnugget = true, nitre = true, marble = true, moonrocknugget = true, charcoal = true,
    ash = true, ice = true, saltrock = true, thulecite_pieces = true, moonglass = true, boneshard = true,
}

local FOOD_TYPES = { MEAT = true, VEGGIE = true, GENERIC = true, GOODIES = true, INSECT = true, BERRY = true, RAW = true }

-- Crafting menu filters in priority order. A crafted item gets the category of the first filter
-- that lists its recipe, so modded recipes are categorized too.
local FILTER_CATEGORIES = {
    { "MAGIC", "magic" }, { "WEAPONS", "weapons" }, { "ARMOUR", "armor" }, { "TOOLS", "tools" },
    { "LIGHT", "tools" }, { "FISHING", "tools" }, { "RIDING", "tools" },
    { "CLOTHING", "clothing" }, { "WINTER", "clothing" }, { "SUMMER", "clothing" }, { "RAIN", "clothing" },
    { "RESTORATION", "healing" }, { "GARDENING", "farming" }, { "REFINE", "refined" },
    { "COOKING", "building" }, { "STRUCTURES", "building" }, { "DECOR", "building" },
    { "SEAFARING", "building" }, { "CONTAINERS", "building" }, { "PROTOTYPERS", "building" },
}

local recipe_categories = nil -- built on first use, after every mod has added its recipes

local function GetRecipeCategory(prefab)
    if recipe_categories == nil then
        recipe_categories = {}
        local filters = G.rawget(G, "CRAFTING_FILTERS")
        local recipes = G.rawget(G, "AllRecipes")
        for _, entry in ipairs(FILTER_CATEGORIES) do
            local filter = filters ~= nil and filters[entry[1]] or nil
            if filter ~= nil and type(filter.recipes) == "table" then
                for _, recipe_name in ipairs(filter.recipes) do
                    local recipe = recipes ~= nil and recipes[recipe_name] or nil
                    local product = recipe ~= nil and recipe.product or recipe_name
                    if recipe_categories[product] == nil then
                        recipe_categories[product] = entry[2]
                    end
                end
            end
        end
    end
    return recipe_categories[prefab]
end

local function GetCategory(item)
    local prefab = item.prefab
    if BASIC_RESOURCES[prefab] then
        return "resources"
    end

    local cmp = item.components
    if cmp.healer ~= nil then
        return "healing"
    end

    local edible = cmp.edible
    if edible ~= nil and edible.foodtype == "SEEDS" then
        return "farming"
    elseif edible ~= nil and FOOD_TYPES[edible.foodtype] and (cmp.perishable ~= nil or item:HasTag("preparedfood")) then
        return "food"
    end

    local deploy_mode = cmp.deployable ~= nil and cmp.deployable.mode or nil
    if cmp.fertilizer ~= nil or deploy_mode == G.DEPLOYMODE.PLANT then
        return "farming"
    elseif cmp.armor ~= nil then
        return "armor"
    end

    local from_recipe = GetRecipeCategory(prefab)
    if from_recipe ~= nil then
        return from_recipe
    elseif item:HasTag("tool") then
        return "tools"
    elseif cmp.weapon ~= nil then
        return "weapons"
    elseif cmp.equippable ~= nil then
        return "clothing"
    elseif item:HasTag("gem") or cmp.spellcaster ~= nil then
        return "magic"
    elseif deploy_mode == G.DEPLOYMODE.TURF or deploy_mode == G.DEPLOYMODE.WALL then
        return "building"
    elseif cmp.stackable ~= nil then
        return "materials"
    end
    return "misc"
end

--------------------------------------------------------------------------------------------------
-- Stacks
--------------------------------------------------------------------------------------------------

local function StackSize(item)
    return item.components.stackable ~= nil and item.components.stackable:StackSize() or 1
end

-- Inside an upgraded chest a stack reports an infinite maxsize; originalmaxsize keeps the real one.
local function StackMax(item)
    local stackable = item.components.stackable
    return stackable.originalmaxsize or stackable.maxsize
end

-- Items the game merges into one stack share a key. Anything else is handled one entity at a time.
local function StackKey(item)
    if item.components.stackable == nil or item.stackable_CanStackWithFn ~= nil then
        return nil
    end
    return item.prefab .. "|" .. (item.skinname or "")
end

local function IsLoose(item)
    return item:IsValid() and item.components.inventoryitem ~= nil and item.components.inventoryitem.owner == nil
end

--------------------------------------------------------------------------------------------------
-- Organize: read, plan, then move
--------------------------------------------------------------------------------------------------

-- Reads every chest without changing anything.
local function TakeSnapshot(chests)
    local snapshot = { chests = {}, blocks = {}, presence = {}, count = 0, capacity = 0 }
    local block_of_key = {}
    for index, inst in ipairs(chests) do
        local container = inst.components.container
        local chest = {
            inst = inst,
            container = container,
            numslots = container:GetNumSlots(),
            infinite = container.infinitestacksize == true,
            slots = {},
        }
        snapshot.chests[index] = chest
        snapshot.capacity = snapshot.capacity + chest.numslots

        for slot = 1, chest.numslots do
            local item = container:GetItemInSlot(slot)
            if item ~= nil then
                chest.slots[slot] = item
                snapshot.count = snapshot.count + 1

                local category = GetCategory(item)
                snapshot.blocks[category] = snapshot.blocks[category] or {}
                local family = CATEGORY_FAMILY[category]
                local presence = snapshot.presence[family]
                if presence == nil then
                    presence = { slots = {}, first = {} }
                    snapshot.presence[family] = presence
                end
                presence.slots[index] = (presence.slots[index] or 0) + 1
                presence.first[index] = presence.first[index] or slot

                local key = StackKey(item)
                local block = key ~= nil and block_of_key[key] or nil
                if block ~= nil then
                    block.units = block.units + StackSize(item)
                else
                    block = { prefab = item.prefab, skin = item.skinname or "", chest = index, slot = slot }
                    if key ~= nil then
                        block.key, block.units, block.max = key, StackSize(item), StackMax(item)
                        block_of_key[key] = block
                    else
                        block.item = item
                    end
                    table.insert(snapshot.blocks[category], block)
                end
            end
        end
    end

    for _, blocks in pairs(snapshot.blocks) do
        table.sort(blocks, function(a, b)
            if a.prefab ~= b.prefab then
                return a.prefab < b.prefab
            elseif a.skin ~= b.skin then
                return a.skin < b.skin
            elseif a.chest ~= b.chest then
                return a.chest < b.chest
            end
            return a.slot < b.slot
        end)
    end
    return snapshot
end

-- Each family is anchored to the chest that holds most of it today, so chests keep what they store.
-- Inside a family the categories always follow the CATEGORIES order.
local function LayoutOrder(snapshot)
    local families, anchor = {}, {}
    for family, presence in pairs(snapshot.presence) do
        local best
        for index, slots in pairs(presence.slots) do
            if best == nil or slots > presence.slots[best] or (slots == presence.slots[best] and index < best) then
                best = index
            end
        end
        anchor[family] = { chest = best, slot = presence.first[best] }
        table.insert(families, family)
    end
    table.sort(families, function(a, b)
        local x, y = anchor[a], anchor[b]
        if x.chest ~= y.chest then
            return x.chest < y.chest
        elseif x.slot ~= y.slot then
            return x.slot < y.slot
        end
        return FAMILY_RANK[a] < FAMILY_RANK[b]
    end)

    local order = {}
    for _, family in ipairs(families) do
        local first = true
        for _, entry in ipairs(CATEGORIES) do
            if entry[2] == family and snapshot.blocks[entry[1]] ~= nil then
                table.insert(order, { category = entry[1], new_family = first })
                first = false
            end
        end
    end
    return order
end

-- Lays the categories out chest after chest like books on a shelf. Spare slots are spent first on
-- starting each family in a fresh chest, and on starting a category in a fresh chest only when plenty
-- are left. Returns the plan and how many slots it fills, or nil when everything doesn't fit.
local function PlanLayout(snapshot, order, spare)
    local chests = snapshot.chests
    local largest, families_left = 0, 0
    for _, chest in ipairs(chests) do
        largest = math.max(largest, chest.numslots)
    end
    for _, entry in ipairs(order) do
        if entry.new_family then
            families_left = families_left + 1
        end
    end

    local plan, filled = {}, 0
    for index = 1, #chests do
        plan[index] = {}
    end
    local current, used = 1, 0
    local function Fill(slots)
        used, filled = used + slots, filled + slots
        if used >= chests[current].numslots then
            current, used = current + 1, 0
        end
    end

    for _, entry in ipairs(order) do
        if entry.new_family then
            families_left = families_left - 1
        end
        if used > 0 then
            local free = chests[current].numslots - used
            local reserve = entry.new_family and 0 or families_left * (largest - 1)
            if spare - reserve >= free then
                spare = spare - free
                current, used = current + 1, 0
            end
        end
        for _, block in ipairs(snapshot.blocks[entry.category]) do
            if block.item ~= nil then
                if current > #chests then
                    return nil
                end
                table.insert(plan[current], { item = block.item })
                Fill(1)
            else
                local remaining = block.units
                while remaining > 0 do
                    if current > #chests then
                        return nil
                    end
                    local chest = chests[current]
                    local per_slot = chest.infinite and remaining or block.max
                    local slots = math.min(math.ceil(remaining / per_slot), chest.numslots - used)
                    local units = math.min(remaining, slots * per_slot)
                    table.insert(plan[current], { key = block.key, units = units, max = block.max })
                    remaining = remaining - units
                    Fill(slots)
                end
            end
        end
    end
    return plan, filled
end

-- What each slot of a chest will hold once the plan is applied.
local function ExpectedSlots(chest, entries)
    local slots = {}
    for _, entry in ipairs(entries) do
        if entry.item ~= nil then
            table.insert(slots, entry.item)
        elseif chest.infinite then
            table.insert(slots, entry.key .. "#" .. entry.units)
        else
            local left = entry.units
            while left > 0 do
                local units = math.min(left, entry.max)
                table.insert(slots, entry.key .. "#" .. units)
                left = left - units
            end
        end
    end
    return slots
end

local function SlotSignature(item)
    local key = StackKey(item)
    return key ~= nil and (key .. "#" .. StackSize(item)) or item
end

local function IsAlreadyOrganized(snapshot, plan)
    for index, chest in ipairs(snapshot.chests) do
        local expected = ExpectedSlots(chest, plan[index])
        for slot = 1, chest.numslots do
            local item = chest.slots[slot]
            if item == nil then
                if expected[slot] ~= nil then
                    return false
                end
            elseif expected[slot] == nil or SlotSignature(item) ~= expected[slot] then
                return false
            end
        end
    end
    return true
end

local function AddToPool(pool, item)
    table.insert(pool.all, item)
    local key = StackKey(item)
    if key ~= nil then
        pool.stacks[key] = pool.stacks[key] or {}
        table.insert(pool.stacks[key], item)
    end
end

local function TakeEverything(snapshot, pool)
    for _, chest in ipairs(snapshot.chests) do
        for slot = 1, chest.numslots do
            -- keepoverstacked: an oversized stack from an upgraded chest comes out in normal-size pieces
            -- instead of spilling its excess on the ground.
            for _ = 1, MAX_PIECES_PER_SLOT do
                local item = chest.container:RemoveItemBySlot(slot, true)
                if item == nil then
                    break
                end
                AddToPool(pool, item)
            end
        end
    end
end

local function GiveStacks(container, pool, key, units)
    local list = pool.stacks[key]
    while units > 0 and list ~= nil and #list > 0 do
        local item = table.remove(list)
        if item:IsValid() then
            local piece = item
            if StackSize(item) > units then
                -- The game's own split keeps freshness, skin, wetness and temperature.
                piece = item.components.stackable:Get(units)
                table.insert(list, item)
                table.insert(pool.all, piece)
            end
            local size = StackSize(piece)
            if not container:GiveItem(piece, nil, nil, false) then
                if piece:IsValid() then
                    table.insert(list, piece)
                end
                return
            end
            units = units - size
        end
    end
end

local function ApplyPlan(snapshot, plan, pool)
    for index, chest in ipairs(snapshot.chests) do
        for _, entry in ipairs(plan[index]) do
            if entry.item ~= nil then
                chest.container:GiveItem(entry.item, nil, nil, false)
            else
                GiveStacks(chest.container, pool, entry.key, entry.units)
            end
        end
    end
end

local function TryGive(container, item)
    local ok, placed = G.pcall(container.GiveItem, container, item, nil, nil, false)
    return ok and placed
end

-- Gives a loose item to the player. If even that fails it lands at the player's feet, never at the
-- spot where the game left it after taking it out of a container.
local function GiveToPlayer(player, item)
    local inventory = player.components.inventory
    G.pcall(inventory.GiveItem, inventory, item, nil, player:GetPosition())
    if IsLoose(item) then
        item.Transform:SetPosition(player.Transform:GetWorldPosition())
    end
end

-- Anything still loose goes into the first chest with room, then to the player.
local function PutBackLooseItems(items, containers, player)
    local count = 0
    for _, item in ipairs(items) do
        if IsLoose(item) then
            count = count + 1
            for _, container in ipairs(containers) do
                if not IsLoose(item) or (container.inst:IsValid() and TryGive(container, item)) then
                    break
                end
            end
            if IsLoose(item) then
                GiveToPlayer(player, item)
            end
        end
    end
    return count
end

local function Organize(player)
    local chests = FindContainers(player, false, false)
    if #chests == 0 then
        return Say(player, MESSAGES.NO_CHESTS)
    end

    local snapshot = TakeSnapshot(chests)
    if snapshot.count == 0 then
        return Say(player, MESSAGES.ALREADY_ORGANIZED)
    end
    -- A tight first pass measures exactly how many slots everything needs; the free slots it leaves
    -- are then spent on giving families and categories their own chests.
    local order = LayoutOrder(snapshot)
    local plan, filled = PlanLayout(snapshot, order, 0)
    if plan == nil then
        return Say(player, MESSAGES.NO_ROOM)
    end
    plan = PlanLayout(snapshot, order, snapshot.capacity - filled) or plan
    if IsAlreadyOrganized(snapshot, plan) then
        return Say(player, MESSAGES.ALREADY_ORGANIZED)
    end

    local pool = { all = {}, stacks = {} }
    local ok, err = G.pcall(function()
        TakeEverything(snapshot, pool)
        ApplyPlan(snapshot, plan, pool)
    end)
    local containers = {}
    for index, chest in ipairs(snapshot.chests) do
        containers[index] = chest.container
    end
    local put_back = PutBackLooseItems(pool.all, containers, player)
    if not ok then
        print("[Better Chests] organize failed and items were put back: " .. tostring(err))
    elseif put_back > 0 then
        print("[Better Chests] " .. put_back .. " items did not follow the plan and were put back.")
    end
    Say(player, string.format(MESSAGES.ORGANIZED, #chests, Plural(#chests)))
end

--------------------------------------------------------------------------------------------------
-- Quick stack
--------------------------------------------------------------------------------------------------

local function QuickStack(player)
    local inventory = player.components.inventory
    local chests = FindContainers(player, QUICKSTACK_FRIDGES, true)
    if #chests == 0 then
        return Say(player, MESSAGES.NO_CHESTS)
    end

    -- For each prefab, the chests that already hold it, the fullest first.
    local holders = {}
    for index, inst in ipairs(chests) do
        local container = inst.components.container
        local units = {}
        for slot = 1, container:GetNumSlots() do
            local item = container:GetItemInSlot(slot)
            if item ~= nil then
                units[item.prefab] = (units[item.prefab] or 0) + StackSize(item)
            end
        end
        for prefab, count in pairs(units) do
            holders[prefab] = holders[prefab] or {}
            table.insert(holders[prefab], { container = container, units = count, index = index })
        end
    end
    for _, list in pairs(holders) do
        table.sort(list, function(a, b)
            if a.units ~= b.units then
                return a.units > b.units
            end
            return a.index < b.index
        end)
    end

    -- Only stackable items move: tools, weapons and clothes stay with the player.
    local sources = {}
    local backpack = QUICKSTACK_BACKPACK and inventory:GetOverflowContainer() or nil
    for _, owner in ipairs({ inventory, backpack }) do
        for slot = 1, owner:GetNumSlots() do
            local item = owner:GetItemInSlot(slot)
            if item ~= nil and item.components.stackable ~= nil and holders[item.prefab] ~= nil then
                table.insert(sources, { owner = owner, slot = slot, item = item })
            end
        end
    end

    local moved, removed_items = 0, {}
    local ok, err = G.pcall(function()
        for _, source in ipairs(sources) do
            local item = source.item
            local before = StackSize(item)
            local removed
            if source.owner == inventory then
                removed = inventory:RemoveItem(item, true)
            else
                removed = source.owner:RemoveItemBySlot(source.slot)
            end
            if removed ~= nil then
                table.insert(removed_items, removed)
                local rest = removed
                for _, holder in ipairs(holders[item.prefab]) do
                    if holder.container:GiveItem(rest, nil, nil, false) then
                        rest = nil
                        break
                    end
                end
                moved = moved + before - (rest ~= nil and StackSize(rest) or 0)
                if rest ~= nil then
                    -- What didn't fit goes back where it came from.
                    if source.owner == inventory then
                        inventory:GiveItem(rest, source.slot)
                    elseif not source.owner:GiveItem(rest, source.slot, nil, false) then
                        inventory:GiveItem(rest)
                    end
                end
            end
        end
    end)
    if not ok then
        print("[Better Chests] quick stack failed and items were put back: " .. tostring(err))
    end
    for _, item in ipairs(removed_items) do
        if IsLoose(item) then
            GiveToPlayer(player, item)
        end
    end

    if moved > 0 then
        Say(player, string.format(MESSAGES.STACKED, moved, Plural(moved)))
    else
        Say(player, MESSAGES.NOTHING_TO_STACK)
    end
end

--------------------------------------------------------------------------------------------------
-- Server side: RPC handlers
--------------------------------------------------------------------------------------------------

local last_request = G.setmetatable({}, { __mode = "k" })

local function HandleRequest(player, action)
    if player == nil or not player:IsValid() or player:HasTag("playerghost") or player.components.inventory == nil then
        return
    end
    local now = G.GetTime()
    if last_request[player] ~= nil and now - last_request[player] < COOLDOWN then
        return
    end
    last_request[player] = now

    local ok, err = G.pcall(action, player)
    if not ok then
        print("[Better Chests] error: " .. tostring(err))
    end
end

AddModRPCHandler(NAMESPACE, "Organize", function(player)
    HandleRequest(player, Organize)
end)

AddModRPCHandler(NAMESPACE, "QuickStack", function(player)
    HandleRequest(player, QuickStack)
end)

--------------------------------------------------------------------------------------------------
-- Client side: key bindings (configured per player)
--------------------------------------------------------------------------------------------------

local function ConfiguredKey(option)
    local value = GetModConfigData(option, true)
    if type(value) ~= "string" or value == "none" then
        return nil
    end
    return G.rawget(G, value)
end

local function CanSendRequest()
    local player = G.ThePlayer
    return player ~= nil
        and player.HUD ~= nil
        and not player.HUD:HasInputFocus() -- chat, console, pause menu, crafting menu...
        and not player:HasTag("playerghost")
end

local function BindKey(option, rpc_name)
    local key = ConfiguredKey(option)
    if key == nil then
        return
    end
    G.TheInput:AddKeyDownHandler(key, function()
        if CanSendRequest() then
            SendModRPCToServer(GetModRPC(NAMESPACE, rpc_name))
        end
    end)
end

if not G.TheNet:IsDedicated() then
    BindKey("organize_key", "Organize")
    BindKey("quickstack_key", "QuickStack")
end
