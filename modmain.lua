require "vector3"
local TheSim = GLOBAL.TheSim;
local TheNet = GLOBAL.TheNet;

--components that can be completely ignored
local ignorableComponents = {
	"inventoryitemmoisture",
	"inspectable",
	"hauntable",
	"snowmandecor",
	"vasedecoration",
	"winter_treeseed",
	"halloweenmoonmutable",
	"inventoryitem",
	"activatable",
	"floater",
	"weighable",
	"propagator",
	"tradable",
	"burnable",
	"bait",
	"fishingrod",
	"terraformer",
	"rangedweapon",
	"rangedlighter",
	"extinguisher",
	"nopunch",
	"oceanfishingtackle",
	"fuel",
	"repairer",
	"blinkstaff",

	--IA recommend
	"named",          -- Doesn't affect functionality
	"writeable",      -- Doesn't affect functionality
	"drawable",       -- Doesn't affect functionality
	"repairable",     -- Doesn't affect sorting
	"stackable",      -- Already handled by selfstacker
	"fueled",         -- Doesn't affect sorting
	"heater",         -- Doesn't affect sorting
	"freezable",      -- Doesn't affect sorting
	"shadowlevel",    -- Doesn't affect sorting
	"teleportable",   -- Doesn't affect sorting
}

--components that will weight more on comparison by items.
local weightedComponents = {
	["mobdrop"] = 5,
	["basicresource"] = 5,
	["refinedresource"] = 5,
	["molebait"] = 3,
	["equippable"] = 3,
	["tool"] = 3,
	["cookable"] = 2,
	["edible"] = 2,
	["repairer"] = 2,
	["fuel"] = 0.5,
	--IA recommend
	["armor"] = 3,          -- High priority for armor
	["weapon"] = 3,         -- High priority for weapons
	["farmplantable"] = 2,  -- Important for farming items
	["healer"] = 2,         -- Important for healing items
	["magic"] = 2,          -- Important for magical items
}

--Tags that doesnt make sense
local ignoreByItem = {
	["flint"] = "edible",
	["twigs"] = "edible",
	["log"] = "edible",
	["seeds"] = "edible",
	["rocks"] = "edible",
	["goldnugget"] = "edible",
	["cutgrass"] = "edible",
	["charcoal"] = "edible",
	["boneshard"] = "edible",
	["houndstooth"] = "edible",
	["thulecite"] = "edible",
	["boards"] = "edible",
	["cutstone"] = "edible",
	["cutreeds"] = "edible",
	["axe"] = "weapon",
	["pickaxe"] = "weapon",
	["hammer"] = "weapon",
	["bugnet"] = "weapon",
	["shovel"] = "weapon"
}

local extraTags = {
	["houndstooth"] = { "mobdrop" },
	["pigskin"] = { "mobdrop" },
	["log"] = { "basicresource" },
	["stick"] = { "basicresource" },
	["cutgrass"] = { "basicresource" },
	["stone"] = { "basicresource" },
	["flint"] = { "basicresource" },
	["cutstone"] = { "refinedresource" },
	["boards"] = { "refinedresource" },
	["papyrus"] = { "refinedresource" },
	["rope"] = { "refinedresource" },
	["electricaldoodad"] = { "refinedresource" },
}

local possibleTags = {
	"magic", "plantable", "healer", "structure", "wall", "spicedfood", "renewable", "preparedfood", "honeyed", "monstermeat",
	"quakedebris", "cattoy", "dryable", "sharp", "pointy", "jab",  "tool", "lureplant_bait", "rawmeat", "shadowlevel",
	"ressurector", "HASHEATER", "marble", "grass", "shadow", "shadow_item", "shell", "molebait", "sanity", "fossil", "hat",
	"wood", "metal", "magiciantool", "hide", "umbrella", "heavyarmor", "frozen", "icebox_valid", "nightvision", "goggles",
	"handfed", "shadowdominance", "dreadstone", "cloth", "junk", "cannotuse", "meat", "veggie", "mobdrop", "basicresource",
	"refinedresource"
}

local function CountDictionary(dic)
	local validItemsCount = 0
	for _ in pairs(dic) do validItemsCount = validItemsCount + 1 end
	return validItemsCount
end

local function GetNearbyChests(player)
	if not player then
		return
	end

	-- Get player position
	local x, y, z = player.Transform:GetWorldPosition()

	-- Find nearby chests
	local allCloseChests = TheSim:FindEntities(x, y, z, 10, {"chest"})

	local closeChests = {}
	for _, chest in pairs(allCloseChests) do
		closeChests[_] = chest.prefab
	end

	return closeChests, allCloseChests;
end

local function GetAllItemsFromChests(chestsRef)
	local allItemsByChest = {}
	local itemsReference = {}
	for indexChest, chest in pairs(chestsRef) do
		local itemsInChest = {}
		if chest.components.container then
			for i = 1, chest.components.container:GetNumSlots() do
				local item = chest.components.container:GetItemInSlot(i)
				if item then
					table.insert(itemsInChest, item.prefab)
					table.insert(itemsReference, item)
				end
			end
		end

		allItemsByChest[chest] = itemsInChest;
	end
	return allItemsByChest, itemsReference
end

local function GetAllComponentsFromItems(itemsRef)
	-- Iterate through chests and their contents
	local componentReference = {}
	local componentsByItem = {}
	for itemIdx, item in pairs(itemsRef) do
		local componentsFoundInItem = {}
		-- Get all components
		if item.components then
			for componentName, comp in pairs(item.components) do
				local safeComponent = true;
				for _, bannedComponent in pairs(ignorableComponents) do
					if componentName == bannedComponent then
						safeComponent = false;
					end
				end

				for itemName, ignoreComponent in pairs(ignoreByItem) do
					if (item.prefab == itemName and componentName == ignoreComponent) then
						safeComponent = false;
					end
				end

				if safeComponent then
					table.insert(componentsFoundInItem, componentName)
					table.insert(componentReference, comp)
				end
			end
		end
			componentsByItem[item.prefab] = componentsFoundInItem;
	end
	return componentsByItem, componentReference;
end

local function GetAllTagsFromItems(itemsRef)
	local tagsByItem = {}
	for _, itemRef in pairs(itemsRef) do
		local prefab = itemRef.prefab
		tagsByItem[prefab] = {}
		for _, tag in ipairs(possibleTags) do
			if itemRef:HasTag(tag) then
				table.insert(tagsByItem[prefab], tag)
			end
		end

		for itemName, tagList in pairs(extraTags) do
			if tostring(itemRef.prefab) == itemName then
				for _, extraTag in pairs(tagList) do
					table.insert(tagsByItem[prefab], extraTag)
				end
			end
		end
	end
	return tagsByItem
end

local function GetCrossedTableValues(allItemsList, tagsByItem)
	local matrixComparison = {}
	for item1, comps1 in pairs(allItemsList) do
		matrixComparison[item1] = {}
		local tags1 = tagsByItem[item1] or {} -- Get tags for item1
		for item2, comps2 in pairs(allItemsList) do
			local tags2 = tagsByItem[item2] or {} -- Get tags for item2
			local equalFeatures = 0
			if item1 == item2 then
				matrixComparison[item1][item2] = 1
			else
				local extraWeight = 0

				-- Compare components
				for _, comp1 in ipairs(comps1) do
					for _, comp2 in ipairs(comps2) do
						if comp1 == comp2 then
							local weight = weightedComponents[comp1] or 1
							equalFeatures = equalFeatures + weight
							extraWeight = extraWeight + weight
							break
						end
					end
				end

				-- Compare tags
				for _, tag1 in ipairs(tags1) do
					for _, tag2 in ipairs(tags2) do
						if tag1 == tag2 then
							local weight = weightedComponents[tag1] or 1 -- Use component weight or default to 1
							equalFeatures = equalFeatures + weight
							extraWeight = extraWeight + weight
							break
						end
					end
				end

				-- Calculate total features
				local totalFeatures = math.max(#comps1 + #tags1, #comps2 + #tags2) + extraWeight
				if totalFeatures <= 0 then
					totalFeatures = 1
				end
				local result = equalFeatures / totalFeatures
				matrixComparison[item1][item2] = result
			end
		end
	end
	return matrixComparison
end

--IA Generated
local function TableToString(tbl, indent, seen)
	indent = indent or 0
	seen = seen or {} -- Table to track already processed tables
	local str = ""
	local indentStr = string.rep("  ", indent)

	-- Check if the table has already been processed
	if seen[tbl] then
		return str .. indentStr .. tostring(tbl) .. " (circular reference)\n"
	end
	seen[tbl] = true -- Mark the table as processed

	for k, v in pairs(tbl) do
		if type(v) == "table" then
			str = str .. indentStr .. tostring(k) .. ":\n"
			str = str .. TableToString(v, indent + 1, seen)
		else
			str = str .. indentStr .. tostring(k) .. ": " .. tostring(v) .. "\n"
		end
	end

	return str
end

local function CheckDeviationFromCrossedTable(matrixCrossingTable)
	local totalDeviation = {}

	for item1, item2AndScores in pairs(matrixCrossingTable) do
		local itemDeviation = 0
		for item2, score in pairs(item2AndScores) do
			itemDeviation = itemDeviation + (1 - score)
		end
		totalDeviation[item1] = itemDeviation
	end

	-- Sort the array by deviation (ascending order)
	table.sort(totalDeviation, function(a, b)
		return a.deviation < b.deviation
	end)

	return totalDeviation
end

local function ReconstructOriginalTable(deviationArray)
	local totalDeviation = {}
	for _, entry in ipairs(deviationArray) do
		totalDeviation[entry.item] = entry.deviation
	end
	return totalDeviation
end


local function GetKeyItemForEachChest(allCloseChests, deviationValue)
	local keyItemByChest = {}
	for i = 1, #allCloseChests do
		local itemIndex = 1
		for item, deviation in pairs(deviationValue) do
			if itemIndex == i then
				print("Chest idx: " .. tostring(i) .. " Choosed: " .. item)
				keyItemByChest[i] = item
				break
			end
			itemIndex = itemIndex + 1
		end
	end
	return keyItemByChest;
end

local function CreateRecursiveStructureWithKeys(keyItemByChest, chestRef)
	local itemListInChest = {}
	for i = 1, #keyItemByChest do
		local chest = chestRef[i]
		local keyItem = keyItemByChest[i]
		itemListInChest[chest] = {keyItem}
	end
	return itemListInChest
end

local function GetQuantityOfEachItem(itemsRef)
	local nonStackables = {}
	local stackables = {}
	for itemIdx, item in pairs(itemsRef) do
		if(item.components.stackable) then
			if stackables[item.prefab] == nil then
				stackables[item.prefab] = item.components.stackable:StackSize()
			else
				stackables[item.prefab] = stackables[item.prefab] + item.components.stackable:StackSize()
			end
		else
			if nonStackables[item.prefab] == nil then
				nonStackables[item.prefab] = 1
			else
				nonStackables[item.prefab] = nonStackables[item.prefab] + 1
			end
		end
	end
	return nonStackables, stackables
end

local function GetActualValidItems(itemsSortedInChest, matrixCrossingTable)
	local lockedItems = {}
	for chest, itemList in pairs(itemsSortedInChest) do
		for _, item in pairs(itemList) do
			lockedItems[item] = true
		end
	end

	TheNet:SystemMessage("Locked Items: " .. TableToString(lockedItems))
	local validItems = {}
	for chest, alreadyOnChestItems in pairs(itemsSortedInChest) do
		local crossedInfo = {}
		for _, item in pairs(alreadyOnChestItems) do
			local uncrossableItems = {}
			local crossedItems = {}
			for crossingItem, crossedPercentage in pairs(matrixCrossingTable[item]) do
				local isLockedItem = false
				--Check if score is 0, and store on table.
				for lockedItem, locked in pairs(lockedItems) do
					if crossingItem == lockedItem then
						isLockedItem = true
					end
				end

				-- If the item is not locked, add it to validItems
				if not isLockedItem then
					if crossedPercentage <= 0 then
						table.insert(crossedItems, { item = crossingItem, percent = crossedPercentage })
					else
						table.insert(uncrossableItems, item)
					end
				end
			end
			if #crossedItems > 0 then
				crossedInfo[item] = {validItems = crossedItems, invalidItems = uncrossableItems}
			end
		end

		if CountDictionary(crossedInfo) > 0 then
			validItems[chest] = crossedInfo
		end
	end

	if #validItems > 0 then
		for chest, itemList in pairs(validItems) do
			for keyItem, crossedItemList in pairs(itemList) do
				local crossedValidItems = crossedItemList.validItems;
				table.sort(crossedValidItems, function(a, b)
					return a.percent > b.percents
				end)
			end
		end
	end

	return validItems
end

local function PutItemsInChest(stackables, nonStackables, sortedItemsInChest, chestRef)
	-- Clear all chests
	for _, chest in pairs(chestRef) do
		if chest.components.container then
			for i = 1, chest.components.container:GetNumSlots() do
				local item = chest.components.container:GetItemInSlot(i)
				if item then
					chest.components.container:RemoveItemBySlot(i)
				end
			end
		end
	end

	-- Add items to chests based on sortedItemsInChest
	for chest, itemList in pairs(sortedItemsInChest) do
		if chest then
			for _, item in pairs(itemList) do
				if chest.components.container then
					-- Determine the quantity of the item to add
					local quantity = stackables[item] or nonStackables[item] or 1

					-- Add the item to the chest
					for i = 1, quantity do
						local newItem = GLOBAL.SpawnPrefab(item)
						if newItem then
							if not chest.components.container:GiveItem(newItem) then
								-- Drop the item at the chest's position instead of deleting it
								newItem.Transform:SetPosition(chest.Transform:GetWorldPosition())
							end
						end
					end
				end
			end
		end
	end
end

local function RemoveItemsFromPlayerInventory(playerInventory, itemsRef)
	local removedItemsFromInventory = {}
	for i = 1, playerInventory:GetNumSlots() do
		local item = playerInventory:GetItemInSlot(i)
		if item then
			for _, itemRef in pairs(itemsRef) do
				if itemRef.prefab == item.prefab then
					playerInventory:RemoveItemBySlot(i)
					if removedItemsFromInventory[item] == nil then
						removedItemsFromInventory[item] = item.components.stackable:StackSize()
					else
						removedItemsFromInventory[item] = removedItemsFromInventory[item] + item.components.stackable:StackSize()
					end
				end
			end
		end
	end
	return removedItemsFromInventory
end

local function SortRemovedItemsInChests(allItemsByChest, removedItemsFromInventory)
	-- Iterate over all chests
	for chest, itemsPrefab in pairs(allItemsByChest) do
		-- Iterate over the items in the chest
		for _, itemPrefab in pairs(itemsPrefab) do

			-- Check if the item matches any removed item
			for removedItem, quantity in pairs(removedItemsFromInventory) do
				if itemPrefab == removedItem.prefab then
					-- Add the item to the chest
					for i = 1, quantity do
						local newItem = GLOBAL.SpawnPrefab(itemPrefab)
						if newItem then
							if not chest.components.container:GiveItem(newItem) then
								newItem.Transform:SetPosition(chest.Transform:GetWorldPosition())
							end
						end
					end
				end
			end
		end
	end
end

local function GetOneItemForEachChestBasedOnContents(itemListByChest, validItems)
	local scoreListByChest = {}
	for chest, itemListInChest in pairs(itemListByChest) do
		--Get best item comparing all items inside the chest
		local itemAndTotalScore = {}
		for _, item in pairs(itemListInChest) do
			for i, itemAndScore in pairs(validItems[chest][item]) do
				local bestScoreItem = itemAndScore.item
				local bestSimilarity = itemAndScore.percent

				if itemAndTotalScore[item] == nil then
					itemAndTotalScore[bestScoreItem] = bestSimilarity
				else
					itemAndTotalScore[bestScoreItem] = itemAndTotalScore[bestScoreItem] + bestSimilarity
				end
			end
		end
		scoreListByChest[chest] = itemAndTotalScore
	end

	local chosenItemByChest = {}
	for chest, itemScoreList in pairs(scoreListByChest) do
		local bestScore = -1
		local itemChose = nil
		for item, score in pairs(itemScoreList) do
			local locked = false
			for inputChest, inputItem in pairs(chosenItemByChest) do
				if item == inputItem then
					locked = true
				end
			end

			if not locked then
				if score > bestScore then
					TheNet:SystemMessage("Find a better item: ".. tostring(item) .. " / " .. tostring(score))
					bestScore = score
					itemChose = item
				end
			end
		end
		chosenItemByChest[chest] = itemChose
	end

	local output = {}
	for chest, items in pairs(itemListByChest) do
		output[chest] = {}
		for i = 1, #items do -- Iterate as array
			output[chest][i] = items[i]
		end
	end

	for chest, insertItem in pairs(chosenItemByChest) do
		if output[chest] then
			table.insert(output[chest], insertItem)
		end
	end

	return output
end

--IA Generated
local function GetMostFrequentComponent(chest)
	local componentWeights = {} -- Table to store the total weight of each component
	local mostFrequentComponent = nil
	local maxWeight = 0

	-- Iterate through items in the chest
	for slot = 1, chest.components.container:GetNumSlots() do
		local item = chest.components.container:GetItemInSlot(slot)
		if item then
			-- Iterate through the item's components
			for componentName, _ in pairs(item.components) do
				local safeComponent = true
				for _, ignorableComp in pairs(ignorableComponents) do
					if componentName == ignorableComp then
						safeComponent = false
					end
				end

				if safeComponent then
					-- Get the weight of the component (default to 1 if not in weightedComponents)
					local weight = weightedComponents[componentName] or 1

					-- Add the weight to the component's total
					componentWeights[componentName] = (componentWeights[componentName] or 0) + weight

					-- Update the most frequent component
					if componentWeights[componentName] > maxWeight then
						mostFrequentComponent = componentName
						maxWeight = componentWeights[componentName]
					end
				end
			end
		end
	end

	return mostFrequentComponent
end

--IA Generated
local function AddNamedComponent(chest)
	if not chest.components.named then
		chest:AddComponent("named")
	end
end

--IA Generated
local function RenameChestBasedOnComponents(chest)
	AddNamedComponent(chest)
	if chest.components.named then
		local mostFrequentComponent = GetMostFrequentComponent(chest)
		if mostFrequentComponent then
			local componentName = string.gsub(mostFrequentComponent, "component%.", "")
			chest.components.named:SetName("Chest of " .. componentName)
		else
			chest.components.named:SetName("Mystery Chest")
		end
	end
end

local function GetTrueUncrossableItems(validItems)
	local uncrossableItems = {}
	for chest, itemChecking in pairs(validItems) do
		local uncrossedItemsInThisChest = itemChecking.invalidItems
		local trueUncrossableByChest = {}
		if uncrossedItemsInThisChest ~= nil then
			local validItemsInThisChest = itemChecking.validItems
			for _, uncrossable in pairs(uncrossedItemsInThisChest) do
				local hasValidValue = false
				for _, validItem in pairs(validItemsInThisChest) do
					if uncrossable == validItem.item then
						hasValidValue = true
					end
				end
				if not hasValidValue then
					table.insert(trueUncrossableByChest, uncrossable)
				end
			end
		end
		uncrossableItems[chest] = trueUncrossableByChest
	end
	TheNet:SystemMessage("Uncrossable Items: " .. TableToString(uncrossableItems))

	local uncrossableCount = {}
	for chest, uncrossableItemList in pairs(uncrossableItems) do
		for _, uncrossableItem in ipairs(uncrossableItemList) do
			if uncrossableCount[uncrossableItem] == nil then
				uncrossableCount[uncrossableItem] = 0
			else
				uncrossableCount[uncrossableItem] = uncrossableCount[uncrossableItem] + 1
			end
		end
	end

	TheNet:SystemMessage("Uncrossable Count: " .. TableToString(uncrossableCount))

	local rejectedOnAllChestItems = {}
	for item, count in pairs(uncrossableCount) do
		if count >= #validItems - 2 then
			table.insert(rejectedOnAllChestItems, item)
		end
	end

	return rejectedOnAllChestItems
end

--Sort Function
GLOBAL.TheInput:AddKeyDownHandler(GLOBAL.KEY_Z, function()
	local player = GLOBAL.ThePlayer
	if player then
		--Get chests
		local allCloseChests, chestRef = GetNearbyChests(player)

		--Get items
		local allItemsByChest, itemsRef = GetAllItemsFromChests(chestRef)

		--Get components
		local componentsByItem, componentReference = GetAllComponentsFromItems(itemsRef)

		local tagsByItem = GetAllTagsFromItems(itemsRef)

		--Count item by stacks
		local nonStackables, stackables = GetQuantityOfEachItem(itemsRef)

		--Cross components (score) similarity in a matrix.
		local matrixCrossingTable = GetCrossedTableValues(componentsByItem, tagsByItem)

		--Check wich item has less difference (score) between others
		local deviationValue = CheckDeviationFromCrossedTable(matrixCrossingTable)

		--Set a Key Item for each chest.
		local keyItemByChest = GetKeyItemForEachChest(allCloseChests, deviationValue)

		local itemListByChest = CreateRecursiveStructureWithKeys(keyItemByChest, chestRef)

		local validItems = GetActualValidItems(itemListByChest, matrixCrossingTable)
		print("Valid Items: " .. TableToString(validItems))

		local rejectedOnAllChestItems = GetTrueUncrossableItems(validItems)
		TheNet:SystemMessage("Rejected on all chests: " .. TableToString(rejectedOnAllChestItems))

		while CountDictionary(validItems) > 0 do
			itemListByChest = GetOneItemForEachChestBasedOnContents(itemListByChest, validItems)
			TheNet:SystemMessage("Score chest: " .. TableToString(itemListByChest))
			validItems = GetActualValidItems(itemListByChest, matrixCrossingTable)
			TheNet:SystemMessage("Valid items: " .. TableToString(validItems))
		end

		--Fill Chests
		PutItemsInChest(stackables, nonStackables, itemListByChest, chestRef)

		--Trocar isso aqui pra uma funcao fora do for que faz tudo dentro e checa pela lista nao pelo componente
		for _, chest in pairs(chestRef) do
			RenameChestBasedOnComponents(chest)
		end
	end
end)

--Quick Stack function
GLOBAL.TheInput:AddKeyDownHandler(GLOBAL.KEY_X, function()
	local player = GLOBAL.ThePlayer
	if player then
		--Get Player Inventory
		local playerInventory = player.components.inventory
		if playerInventory then
			--Get Chests
			local allCloseChests, chestRef = GetNearbyChests(player)
			--Get Items
			local allItemsByChest, itemsRef = GetAllItemsFromChests(chestRef)
			--Remove items from player inventory
			local removedItemsFromInventory = RemoveItemsFromPlayerInventory(playerInventory, itemsRef)
			--Put removed inventory items in the chests
			SortRemovedItemsInChests(allItemsByChest, removedItemsFromInventory)
		end
	end
end)

-- Add this function to your existing code
local function SpawnDebugItems()
	local player = GLOBAL.ThePlayer
	if not player then return end

	-- Organized item categories
	local debug_categories = {
		{
			name = "Base Resources",
			items = {"log", "twigs", "rocks", "flint", "cutreeds", "charcoal", "pinecone",
					 "boards", "cutstone", "rope", "papyrus", "houndstooth", "silk", "goldnugget",
					 "marble", "thulecite", "livinglog"}
		},
		{
			name = "Tools/Weapons",
			items = {"axe", "pickaxe", "shovel", "hammer", "bugnet", "fishingrod", "razor", "pitchfork",
					 "spear", "tentaclespike", "boomerang", "blowdart_pipe", "nightstick", "batbat",
					 "hambat", "ruins_bat", "nightsword"},
		},
		{
			name = "Mob Drops",
			items = {
				"spidergland", "stinger", "tentaclespots", "phlegm",
				"slurper_pelt", "batwing", "beardhair", "furtuft",
				"coontail", "deerclops_eyeball", "glommerfuel", "dragon_scales",
				"slurtleslime", "snurtleshell", "rock_avocado_fruit",
				"cookiecuttershell", "venomgland", "snakeskin", "nightmarefuel", "pigskin"
			}
		},
		{
			name = "Armor/Clothing",
			items = {"armorwood", "footballhat", "armormarble", "armorgrass", "armorslurper",
					 "armorsnurtleshell", "sweater", "trunkvest_summer", "raincoat", "catcoonhat",
					 "beefalohat", "winterhat"},
		},
		{
			name = "Structures",
			items = {"wall_hay_item", "wall_wood_item", "wall_stone_item", "fence_gate_item", "signitem"},
		},
		{
			name = "Food",
			items = {"berries", "carrot", "meat", "fish", "monstermeat", "dragonfruit", "pomegranate",
					 "watermelon", "cookedmeat", "cookedmonstermeat", "fishsticks", "frogglebunwich",
					 "taffy", "dragonpie"},
		},
		{
			name = "Magic Items",
			items = {"telestaff", "icestaff", "firestaff", "orangestaff", "greenstaff", "yellowstaff",
					 "nightsword", "armor_sanity", "amulet", "purpleamulet", "orangeamulet", "yellowamulet",
					 "panflute", "onemanband"},
		}
	}

	local pos = player:GetPosition()
	local start_x = pos.x + 3  -- Start 3 units right of player
	local start_z = pos.z      -- Align with player's Z position
	local row_spacing = 1      -- Space between rows

	local actualChestIdx = 1
	local lastChestIdx = 0
	local actualChest
	local startCount = 1
	local endCount = 0
	for cat_idx, category in ipairs(debug_categories) do
		endCount = endCount + #category.items
		for i = startCount, endCount do
			local chestIsFull = i % 9 == 0

			if chestIsFull then
				lastChestIdx = actualChestIdx
				actualChestIdx = actualChestIdx + 1
			end

			if actualChestIdx ~= lastChestIdx then
				local row_x = start_x
				local row_z = start_z + (lastChestIdx * row_spacing)
				actualChest = GLOBAL.SpawnPrefab("treasurechest")
				actualChest.Transform:SetPosition(row_x, 0, row_z)
				lastChestIdx = actualChestIdx
			end

			-- Fill chest with items
			local item = GLOBAL.SpawnPrefab(category.items[i - startCount + 1])
			if item and actualChest.components.container then
				actualChest.components.container:GiveItem(item)
			end
		end
		startCount = endCount + 1
	end
end

-- Keep your existing key handler
GLOBAL.TheInput:AddKeyDownHandler(GLOBAL.KEY_V, function()
	SpawnDebugItems()
end)