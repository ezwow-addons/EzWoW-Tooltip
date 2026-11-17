--===========================================================================
-- EzWoW - Tooltip
-- Modules/GatherSkill.lua : Required Gathering Skill on Herb, Ore & Skinnable Tooltips
--===========================================================================
local _, ns = ...
local type, pairs, ipairs, tonumber, tostring, select, pcall = type, pairs, ipairs, tonumber, tostring, select, pcall

local GatherSkill = ns.GatherSkill or {}
ns.GatherSkill = GatherSkill
local EventDispatcher = ns.events
local addon = EzWoW_Tooltip
local compat = ns.compat
local nosecret = compat.nosecret
local format = string.format

local HERBALISM, MINING, SKINNING = 182, 186, 393

-- Apprentice spell of each skill line: its name is the skill's name in the
-- client language when the player has not learned it.
local SKILL_SPELL = { [HERBALISM] = 2366, [MINING] = 2575, [SKINNING] = 8613 }
local SKILL_LOCALE_KEY = { [HERBALISM] = "gatherHerbalism", [MINING] = "gatherMining", [SKINNING] = "gatherSkinning" }

-----------------------------------------------------------------------------
-- Node data. World objects carry no ID on their tooltip, so a node is found
-- by its name: the English and Korean node names below, plus (for herbs) the
-- herb item's name in the client language, which is the node's name in most
-- languages.
-----------------------------------------------------------------------------

-- Herb item ID = { required skill, node name (enUS), node name (koKR) }
local HERB_NODES = {
    [2447]  = { 1,   "Peacebloom",          "평온초" },
    [765]   = { 1,   "Silverleaf",          "은엽수 덤불" },
    [2449]  = { 15,  "Earthroot",           "뱀뿌리" },
    [785]   = { 50,  "Mageroyal",           "마법초" },
    [2450]  = { 70,  "Briarthorn",          "찔레가시" },
    [3820]  = { 85,  "Stranglekelp",        "갈래물풀" },
    [2453]  = { 100, "Bruiseweed",          "생채기풀" },
    [3355]  = { 115, "Wild Steelbloom",     "야생 철쭉" },
    [3369]  = { 120, "Grave Moss",          "무덤이끼" },
    [3356]  = { 125, "Kingsblood",          "왕꽃잎풀" },
    [3357]  = { 150, "Liferoot",            "생명의 뿌리" },
    [3818]  = { 160, "Fadeleaf",            "미명초잎" },
    [3821]  = { 170, "Goldthorn",           "황금가시" },
    [3358]  = { 185, "Khadgar's Whisker",   "카드가의 수염" },
    [3819]  = { 195, "Wintersbite",         "용 송곳니" },
    [4625]  = { 205, "Firebloom",           "화염초" },
    [8831]  = { 210, "Purple Lotus",        "보라 연꽃" },
    [8836]  = { 220, "Arthas' Tears",       "아서스의 눈물" },
    [8838]  = { 230, "Sungrass",            "태양풀" },
    [8839]  = { 235, "Blindweed",           "실명초" },
    [8845]  = { 245, "Ghost Mushroom",      "유령버섯" },
    [8846]  = { 250, "Gromsblood",          "그롬의 피" },
    [13464] = { 260, "Golden Sansam",       "황금 산삼" },
    [13463] = { 270, "Dreamfoil",           "꿈풀" },
    [13465] = { 280, "Mountain Silversage", "은초롱이" },
    [13466] = { 285, "Plaguebloom",         "슬픔이끼" },
    [13467] = { 290, "Icecap",              "얼음송이" },
    [13468] = { 300, "Black Lotus",         "검은 연꽃" },
}

-- { required skill, node name (enUS), node name (koKR) or false }
-- Variants such as ooze-covered veins are also found by their base name at
-- the end of the node name (see lookupNode).
local ORE_NODES = {
    { 1,   "Copper Vein",                     "구리 광맥" },
    { 65,  "Tin Vein",                        "주석 광맥" },
    { 65,  "Incendicite Mineral Vein",        "발연 광맥" },
    { 75,  "Silver Vein",                     "은 광맥" },
    { 75,  "Lesser Bloodstone Deposit",       "저급 혈석 광맥" },
    { 125, "Iron Deposit",                    "철 광맥" },
    { 150, "Indurium Mineral Vein",           "인듀리움 광맥" },
    { 155, "Gold Vein",                       "금 광맥" },
    { 175, "Mithril Deposit",                 "미스릴 광맥" },
    { 230, "Truesilver Deposit",              "진은 광맥" },
    { 230, "Dark Iron Deposit",               "검은무쇠 광맥" },
    { 245, "Small Thorium Vein",              "작은 토륨 광맥" },
    { 275, "Rich Thorium Vein",               "풍부한 토륨 광맥" },
    { 75,  "Ooze Covered Silver Vein",        false },
    { 155, "Ooze Covered Gold Vein",          "진흙으로 덮인 금 광맥" },
    { 175, "Ooze Covered Mithril Deposit",    "진흙으로 덮인 미스릴 광맥" },
    { 230, "Ooze Covered Truesilver Deposit", false },
    { 245, "Ooze Covered Thorium Vein",       "진흙으로 덮인 토륨 광맥" },
    { 275, "Ooze Covered Rich Thorium Vein",  false },
    { 275, "Hakkari Thorium Vein",            false },
}

-----------------------------------------------------------------------------
-- Name table: node name -> { skill line, required skill }
-----------------------------------------------------------------------------
local nodeByName
local pendingHerbItems = {}
local lookupMemo, lookupMemoCount, LOOKUP_MEMO_MAX = {}, 0, 400
local itemLoadFrame = CreateFrame("Frame")

function GatherSkill.forgetLookups()
    wipe(lookupMemo)
    lookupMemoCount = 0
end

function GatherSkill.addHerbItemName(itemID)
    local itemAPI = _G.C_Item
    if not itemAPI or type(itemAPI.GetItemNameByID) ~= "function" then return true end
    local isCallOk, itemName = pcall(itemAPI.GetItemNameByID, itemID)
    itemName = isCallOk and nosecret(itemName) or nil
    if type(itemName) ~= "string" or itemName == "" then return false end
    if not nodeByName[itemName] then
        nodeByName[itemName] = { HERBALISM, HERB_NODES[itemID][1] }
    end
    return true
end

function GatherSkill.buildNodeTable()
    nodeByName = {}
    for _, oreEntry in ipairs(ORE_NODES) do
        local nodeInfo = { MINING, oreEntry[1] }
        nodeByName[oreEntry[2]] = nodeInfo
        if oreEntry[3] then nodeByName[oreEntry[3]] = nodeInfo end
    end
    for _, herbEntry in pairs(HERB_NODES) do
        local nodeInfo = { HERBALISM, herbEntry[1] }
        nodeByName[herbEntry[2]] = nodeInfo
        nodeByName[herbEntry[3]] = nodeInfo
    end
    local itemAPI = _G.C_Item
    for itemID in pairs(HERB_NODES) do
        if not GatherSkill.addHerbItemName(itemID) then
            pendingHerbItems[itemID] = true
            if itemAPI and type(itemAPI.RequestLoadItemDataByID) == "function" then
                pcall(itemAPI.RequestLoadItemDataByID, itemID)
            end
        end
    end
    if next(pendingHerbItems) then
        pcall(itemLoadFrame.RegisterEvent, itemLoadFrame, "ITEM_DATA_LOAD_RESULT")
    end
end

itemLoadFrame:SetScript("OnEvent", function(self, _, itemID, success)
    itemID = nosecret(itemID)
    if not itemID or not pendingHerbItems[itemID] then return end
    if nosecret(success) and nodeByName then
        GatherSkill.addHerbItemName(itemID)
        GatherSkill.forgetLookups()
    end
    pendingHerbItems[itemID] = nil
    if not next(pendingHerbItems) then self:UnregisterEvent("ITEM_DATA_LOAD_RESULT") end
end)

-- Plain node name: texture/atlas markup and colour codes removed, trimmed.
function GatherSkill.cleanName(rawText)
    local plainText = rawText:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (plainText:match("^%s*(.-)%s*$"))
end

-- Exact name first; then, for ore variants ("Ooze Covered Silver Vein"), the
-- longest run of trailing words that is a known vein name.
function GatherSkill.lookupNode(nodeName)
    if not nodeByName then GatherSkill.buildNodeTable() end
    local memoHit = lookupMemo[nodeName]
    if memoHit ~= nil then return memoHit or nil end
    local nodeInfo = nodeByName[nodeName]
    if not nodeInfo then
        local remainder = nodeName:match("^%S+%s+(.+)$")
        while remainder do
            local candidate = nodeByName[remainder]
            if candidate and candidate[1] == MINING then
                nodeInfo = candidate
                break
            end
            remainder = remainder:match("^%S+%s+(.+)$")
        end
    end
    if lookupMemoCount >= LOOKUP_MEMO_MAX then GatherSkill.forgetLookups() end
    lookupMemo[nodeName] = nodeInfo or false
    lookupMemoCount = lookupMemoCount + 1
    return nodeInfo
end

-----------------------------------------------------------------------------
-- Player skill
-----------------------------------------------------------------------------
local skillCache, skillCacheTime = nil, 0
local SKILL_CACHE_SECONDS = 10

function GatherSkill.forgetSkills()
    skillCache = nil
end

function GatherSkill.readSkills()
    local foundSkills = {}
    if type(_G.GetProfessions) == "function" and type(_G.GetProfessionInfo) == "function" then
        local profIndices = { pcall(_G.GetProfessions) }
        if profIndices[1] then
            for slotIndex = 2, 6 do
                local profIndex = nosecret(profIndices[slotIndex])
                if profIndex then
                    local isCallOk, profName, _, profRank, _, _, _, profLine = pcall(_G.GetProfessionInfo, profIndex)
                    profLine, profRank, profName = nosecret(profLine), nosecret(profRank), nosecret(profName)
                    if isCallOk and SKILL_SPELL[profLine] and type(profRank) == "number" then
                        foundSkills[profLine] = { rank = profRank, name = profName }
                    end
                end
            end
        end
    end
    -- Older skill list: matched by the skill's name.
    if type(_G.GetNumSkillLines) == "function" and type(_G.GetSkillLineInfo) == "function" then
        local okCount, lineCount = pcall(_G.GetNumSkillLines)
        lineCount = okCount and nosecret(lineCount) or 0
        for skillLine in pairs(SKILL_SPELL) do
            if not foundSkills[skillLine] then
                local wantedName = GatherSkill.skillName(skillLine)
                for lineIndex = 1, lineCount do
                    local isCallOk, lineName, isHeader, _, lineRank = pcall(_G.GetSkillLineInfo, lineIndex)
                    lineName, lineRank = nosecret(lineName), nosecret(lineRank)
                    if isCallOk and not isHeader and lineName == wantedName and type(lineRank) == "number" then
                        foundSkills[skillLine] = { rank = lineRank, name = lineName }
                        break
                    end
                end
            end
        end
    end
    return foundSkills
end

function GatherSkill.currentSkills()
    local nowTime = (type(_G.GetTime) == "function" and _G.GetTime()) or 0
    if not skillCache or nowTime - skillCacheTime > SKILL_CACHE_SECONDS then
        skillCache = GatherSkill.readSkills()
        skillCacheTime = nowTime
    end
    return skillCache
end

local skillNameCache = {}
function GatherSkill.skillName(skillLine)
    local cachedName = skillNameCache[skillLine]
    if cachedName then return cachedName end
    local resolvedName
    local tradeAPI = _G.C_TradeSkillUI
    if tradeAPI and type(tradeAPI.GetTradeSkillDisplayName) == "function" then
        local isCallOk, displayName = pcall(tradeAPI.GetTradeSkillDisplayName, skillLine)
        displayName = isCallOk and nosecret(displayName) or nil
        if type(displayName) == "string" and displayName ~= "" then resolvedName = displayName end
    end
    if not resolvedName then
        local spellAPI = _G.C_Spell
        if spellAPI and type(spellAPI.GetSpellName) == "function" then
            local isCallOk, spellName = pcall(spellAPI.GetSpellName, SKILL_SPELL[skillLine])
            spellName = isCallOk and nosecret(spellName) or nil
            if type(spellName) == "string" and spellName ~= "" then resolvedName = spellName end
        end
    end
    if resolvedName then
        skillNameCache[skillLine] = resolvedName
        return resolvedName
    end
    return addon.EL(SKILL_LOCALE_KEY[skillLine])
end

-- Classic difficulty colours: red below the requirement, then orange,
-- yellow, green and grey at +25 / +50 / +100.
function GatherSkill.skillColor(playerSkill, requiredSkill)
    if not playerSkill or playerSkill < requiredSkill then return "ff2020" end
    local overBy = playerSkill - requiredSkill
    if overBy < 25 then return "ff8040" end
    if overBy < 50 then return "ffff00" end
    if overBy < 100 then return "40bf40" end
    return "808080"
end

function GatherSkill.composeLine(skillLine, requiredSkill, nodeLabel)
    local skillInfo = GatherSkill.currentSkills()[skillLine]
    local displayName = (skillInfo and type(skillInfo.name) == "string" and skillInfo.name ~= "" and skillInfo.name) or GatherSkill.skillName(skillLine)
    local lineText
    if skillInfo then
        lineText = format(addon.EL("gatherReqFmt"), displayName, requiredSkill, skillInfo.rank)
    else
        lineText = format(addon.EL("gatherReqNoSkillFmt"), displayName, requiredSkill)
    end
    if nodeLabel then lineText = nodeLabel .. ": " .. lineText end
    return "|cff" .. GatherSkill.skillColor(skillInfo and skillInfo.rank, requiredSkill) .. lineText .. "|r"
end

-- Skinning requirement by creature level (classic rule).
function GatherSkill.skinningRequirement(unitLevel)
    if unitLevel < 10 then return 1 end
    if unitLevel <= 20 then return math.max(1, (unitLevel - 10) * 10) end
    return unitLevel * 5
end

-----------------------------------------------------------------------------
-- Minimap by place. The game hands addons the minimap tooltip text as secret
-- values (shown, but not readable), so there the node is found by place: the
-- cursor's point on the minimap becomes a world point, matched with the known
-- spawn points of herb and ore nodes (the map addon's data, or the shared data
-- addon's spawn table).
-----------------------------------------------------------------------------
local SPAWN_CELL = 64                -- yards per grid cell
local FIND_HERBS, FIND_MINERALS = 2383, 2580
local OUTDOOR_RADIUS = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 }   -- yards by zoom
local INDOOR_RADIUS = { [0] = 150, 120, 90, 60, 40, 25 }
local spawnGrid                      -- ["cont:cx:cy"] = { x, y, key, x, y, key, ... }
local spawnGridTriedAt = -1000
local nodeMeta = {}                  -- key -> { skill line, required skill, label }

local function isKorean()
    return type(_G.GetLocale) == "function" and _G.GetLocale() == "koKR"
end

local function herbKey(itemID)
    local key = "h" .. itemID
    if not nodeMeta[key] then
        local herbEntry = HERB_NODES[itemID]
        local label = isKorean() and herbEntry[3] or nil
        if not label and _G.C_Item and type(_G.C_Item.GetItemNameByID) == "function" then
            local isCallOk, itemName = pcall(_G.C_Item.GetItemNameByID, itemID)
            itemName = isCallOk and nosecret(itemName) or nil
            if type(itemName) == "string" and itemName ~= "" then label = itemName end
        end
        nodeMeta[key] = { HERBALISM, herbEntry[1], label or herbEntry[2] }
    end
    return key
end

local function oreKey(oreEntry)
    local key = "o" .. oreEntry[2]
    if not nodeMeta[key] then
        nodeMeta[key] = { MINING, oreEntry[1], (isKorean() and oreEntry[3]) or oreEntry[2] }
    end
    return key
end

local function addSpawns(spawnList, key)
    local added = false
    for _, spawn in ipairs(spawnList) do
        local cont, x, y = spawn[1], spawn[2], spawn[3]
        if type(cont) == "number" and type(x) == "number" and type(y) == "number" then
            local cell = cont .. ":" .. math.floor(x / SPAWN_CELL) .. ":" .. math.floor(y / SPAWN_CELL)
            local list = spawnGrid[cell]
            if not list then
                list = {}
                spawnGrid[cell] = list
            end
            list[#list + 1] = x
            list[#list + 1] = y
            list[#list + 1] = key
            added = true
        end
    end
    return added
end

-- Built once on first use; tried again at most every 30 seconds while no data
-- could be read (the shared data module only loads out of combat).
function GatherSkill.buildSpawnGrid()
    if spawnGrid then return true end
    local nowTime = (type(_G.GetTime) == "function" and _G.GetTime()) or 0
    if nowTime - spawnGridTriedAt < 30 then return false end
    spawnGridTriedAt = nowTime
    spawnGrid = {}
    local herbByEnglish, oreByEnglish = {}, {}
    for itemID, herbEntry in pairs(HERB_NODES) do herbByEnglish[herbEntry[2]] = itemID end
    for _, oreEntry in ipairs(ORE_NODES) do oreByEnglish[oreEntry[2]] = oreEntry end
    local hasData = false
    -- every node spot (Data/GatherSpots.lua): { [continent] = { [herb item or ore name] = { x, y, ... } } }
    if type(ns.GatherSpots) == "table" then
        for continent, kinds in pairs(ns.GatherSpots) do
            for kindKey, flatSpots in pairs(kinds) do
                local nodeKey
                if type(kindKey) == "number" and HERB_NODES[kindKey] then
                    nodeKey = herbKey(kindKey)
                elseif oreByEnglish[kindKey] then
                    nodeKey = oreKey(oreByEnglish[kindKey])
                end
                if nodeKey and type(flatSpots) == "table" then
                    local spawnList = {}
                    for i = 1, #flatSpots - 1, 2 do
                        spawnList[#spawnList + 1] = { continent, flatSpots[i], flatSpots[i + 1] }
                    end
                    hasData = addSpawns(spawnList, nodeKey) or hasData
                end
            end
        end
    end
    -- plus the map addon's spots, which also hold where players gathered
    local mapData = _G.EzWoWMapFinderData
    if type(mapData) == "table" then
        for _, entry in ipairs(mapData) do
            if type(entry) == "table" and entry.kind == "object" and type(entry.spawns) == "table"
                and type(entry.names) == "table" then
                local englishName = entry.names.enUS
                local herbItem = englishName and herbByEnglish[englishName]
                local oreEntry = englishName and oreByEnglish[englishName]
                if herbItem then
                    hasData = addSpawns(entry.spawns, herbKey(herbItem)) or hasData
                elseif oreEntry then
                    hasData = addSpawns(entry.spawns, oreKey(oreEntry)) or hasData
                end
            end
        end
    end
    if not hasData then
        -- herb nodes by the herb they give, from the shared data addon
        local sharedData = _G.EzWoW_Data
        local itemSpawns
        if type(sharedData) == "table" and type(sharedData.GetTable) == "function" then
            local isCallOk, spawnTable = pcall(sharedData.GetTable, "Spawns", "item")
            itemSpawns = isCallOk and spawnTable or nil
        end
        if type(itemSpawns) == "table" then
            for itemID in pairs(HERB_NODES) do
                if type(itemSpawns[itemID]) == "table" then
                    hasData = addSpawns(itemSpawns[itemID], herbKey(itemID)) or hasData
                end
            end
        end
    end
    if not hasData then spawnGrid = nil end
    return hasData
end

-- Which node kinds the minimap shows now (Find Herbs / Find Minerals); both when unknown.
function GatherSkill.trackedKinds()
    local minimapAPI = _G.C_Minimap
    if not (minimapAPI and type(minimapAPI.GetNumTrackingTypes) == "function"
        and type(minimapAPI.GetTrackingInfo) == "function") then
        return true, true
    end
    local okCount, trackCount = pcall(minimapAPI.GetNumTrackingTypes)
    trackCount = okCount and nosecret(trackCount) or nil
    if type(trackCount) ~= "number" then return true, true end
    local herbs, ores, sawEither = false, false, false
    for trackIndex = 1, trackCount do
        local isCallOk, a, _, c, _, _, f = pcall(minimapAPI.GetTrackingInfo, trackIndex)
        if isCallOk then
            local isActive, spellID
            if type(a) == "table" then
                isActive, spellID = nosecret(a.active), nosecret(a.spellID)
            else
                isActive, spellID = nosecret(c), nosecret(f)
            end
            if spellID == FIND_HERBS then
                sawEither = true
                herbs = isActive and true or false
            elseif spellID == FIND_MINERALS then
                sawEither = true
                ores = isActive and true or false
            end
        end
    end
    if not sawEither then return true, true end
    return herbs, ores
end

-- The player's spot as { continent, x, y } in world coordinates, like the data.
local function playerWorldPosition()
    local mapAPI = _G.C_Map
    if not (mapAPI and type(mapAPI.GetBestMapForUnit) == "function" and type(mapAPI.GetPlayerMapPosition) == "function"
        and type(mapAPI.GetWorldPosFromMapPos) == "function") then
        return nil
    end
    local okMap, uiMapID = pcall(mapAPI.GetBestMapForUnit, "player")
    uiMapID = okMap and nosecret(uiMapID) or nil
    if type(uiMapID) ~= "number" then return nil end
    local okPos, mapPos = pcall(mapAPI.GetPlayerMapPosition, uiMapID, "player")
    if not okPos or not mapPos then return nil end
    local okWorld, continent, worldPos = pcall(mapAPI.GetWorldPosFromMapPos, uiMapID, mapPos)
    continent = okWorld and nosecret(continent) or nil
    if type(continent) ~= "number" or type(worldPos) ~= "table" then return nil end
    local worldX, worldY = nosecret(worldPos.x), nosecret(worldPos.y)
    if type(worldX) ~= "number" or type(worldY) ~= "number" then return nil end
    return continent, worldX, worldY
end

local function minimapRadiusYards()
    local minimapAPI = _G.C_Minimap
    if minimapAPI and type(minimapAPI.GetViewRadius) == "function" then
        local isCallOk, viewRadius = pcall(minimapAPI.GetViewRadius)
        viewRadius = isCallOk and nosecret(viewRadius) or nil
        if type(viewRadius) == "number" and viewRadius > 0 then return viewRadius end
    end
    local minimap = _G.Minimap
    if not (minimap and minimap.GetZoom) then return nil end
    local zoom = nosecret(minimap:GetZoom())
    if type(zoom) ~= "number" then return nil end
    local indoors = type(_G.IsIndoors) == "function" and _G.IsIndoors() == true
    return (indoors and INDOOR_RADIUS or OUTDOOR_RADIUS)[zoom]
end

-- World point under the cursor on the minimap: continent, x, y, minimap units per yard.
function GatherSkill.cursorWorldPosition()
    local minimap = _G.Minimap
    if not (minimap and minimap.GetCenter and type(_G.GetCursorPosition) == "function") then return nil end
    local continent, playerX, playerY = playerWorldPosition()
    local radius = minimapRadiusYards()
    if not (continent and radius) then return nil end
    local halfWidth = nosecret(minimap:GetWidth()) or 0
    local centerX, centerY = minimap:GetCenter()
    centerX, centerY = nosecret(centerX), nosecret(centerY)
    local scale = nosecret(minimap:GetEffectiveScale())
    if halfWidth <= 0 or type(centerX) ~= "number" or type(centerY) ~= "number" or type(scale) ~= "number" or scale <= 0 then
        return nil
    end
    halfWidth = halfWidth / 2
    local cursorX, cursorY = _G.GetCursorPosition()
    local perYard = halfWidth / radius
    local right, up = (cursorX / scale - centerX) / perYard, (cursorY / scale - centerY) / perYard
    local east, north = right, up
    local getCVar = (_G.C_CVar and _G.C_CVar.GetCVar) or _G.GetCVar
    local okCVar, rotateValue = false, nil
    if type(getCVar) == "function" then okCVar, rotateValue = pcall(getCVar, "rotateMinimap") end
    if okCVar and rotateValue == "1" then
        local facing = type(_G.GetPlayerFacing) == "function" and nosecret(_G.GetPlayerFacing()) or nil
        if type(facing) ~= "number" then return nil end
        local cosF, sinF = math.cos(facing), math.sin(facing)
        east = right * cosF - up * sinF
        north = right * sinF + up * cosF
    end
    -- world X runs north, world Y runs west
    return continent, playerX + north, playerY - east, perYard, math.sqrt(east * east + north * north)
end

-- How far (yards) a spawn may be from the cursor point: a node icon's size (the
-- tooltip shows while the cursor is anywhere on the icon), plus a little more
-- the farther it is from the player (the minimap scale is not exact).
local function cursorReach(perYard, offsetYards)
    return math.max(6, math.min(60, 12 / perYard + (offsetYards or 0) * 0.13))
end

-- Node kinds with a spawn point near the cursor (reachScale times the usual
-- reach): { { key = key, distance = squared yards }, ... }, nearest first.
function GatherSkill.nodeCandidates(reachScale, fixedReach)
    local wantHerbs, wantOres = GatherSkill.trackedKinds()
    if not (wantHerbs or wantOres) then return {} end
    if not GatherSkill.buildSpawnGrid() then return {} end
    local continent, worldX, worldY, perYard, offsetYards = GatherSkill.cursorWorldPosition()
    if not continent then return {} end
    local reach = cursorReach(perYard, offsetYards)
    -- (a wider look stays within 60 yards, so a far node with a name of the
    -- same length is not taken)
    if reachScale and reachScale > 1 then reach = math.min(reach * reachScale, math.max(reach, 60)) end
    if fixedReach then reach = fixedReach end
    local bestDistance = {}
    local cellX0, cellX1 = math.floor((worldX - reach) / SPAWN_CELL), math.floor((worldX + reach) / SPAWN_CELL)
    local cellY0, cellY1 = math.floor((worldY - reach) / SPAWN_CELL), math.floor((worldY + reach) / SPAWN_CELL)
    for cellX = cellX0, cellX1 do
        for cellY = cellY0, cellY1 do
            local list = spawnGrid[continent .. ":" .. cellX .. ":" .. cellY]
            if list then
                for i = 1, #list, 3 do
                    local dx, dy = list[i] - worldX, list[i + 1] - worldY
                    local distance = dx * dx + dy * dy
                    local key = list[i + 2]
                    local meta = nodeMeta[key]
                    local wanted = meta and ((meta[1] == HERBALISM and wantHerbs) or (meta[1] == MINING and wantOres))
                    if wanted and distance <= reach * reach and (not bestDistance[key] or distance < bestDistance[key]) then
                        bestDistance[key] = distance
                    end
                end
            end
        end
    end
    local found = {}
    for key, distance in pairs(bestDistance) do found[#found + 1] = { key = key, distance = distance } end
    table.sort(found, function(a, b) return a.distance < b.distance end)
    return found
end

-- Node kinds with a spawn point under the cursor, nearest first (at most 3).
function GatherSkill.nodesUnderCursor()
    local found = GatherSkill.nodeCandidates(1)
    -- the nearest kind, plus others about as near (two nodes under one icon)
    local result = {}
    local nearest = found[1] and math.sqrt(found[1].distance)
    for i = 1, math.min(3, #found) do
        if math.sqrt(found[i].distance) <= nearest + 10 then result[#result + 1] = nodeMeta[found[i].key] end
    end
    return result
end

-- Which node the minimap shows, by width. Its text is secret, but the
-- tooltip's own width can be read (checked in game): with only the game's
-- line it is the node name's width plus the side insets. Each kind near the
-- cursor has its name measured in the same font; the nearest kind whose name
-- fits that width is the node (names one letter apart differ by a whole
-- letter, about 10 or more).
-- The tooltip comes out a fraction wider than its line (0.48 in game), so a
-- name fits from 0.3 below to 1 above; names differ by a pixel or more.
local FIT_LOW, FIT_HIGH = -0.3, 1.0
local WIDE_REACH = 400               -- yards: the second, wider look
local measurer
local nameWidths = {}

-- The first line's font (its own, else the header font it is made with: a
-- line holding a secret text may not tell its font).
local function lineFont(fontString)
    local path, size, flags
    if fontString and fontString.GetFont then
        local isCallOk, p, s, f = pcall(fontString.GetFont, fontString)
        if isCallOk then path, size, flags = nosecret(p), nosecret(s), nosecret(f) end
    end
    if type(path) ~= "string" or type(size) ~= "number" then
        local header = _G.GameTooltipHeaderText
        if not (header and header.GetFont) then return nil end
        path, size, flags = header:GetFont()
        path, size, flags = nosecret(path), nosecret(size), nosecret(flags)
        if type(path) ~= "string" or type(size) ~= "number" then return nil end
    end
    return path, size, type(flags) == "string" and flags or ""
end

local function measureName(fontString, label)
    if type(label) ~= "string" or label == "" then return nil end
    local path, size, flags = lineFont(fontString)
    if not path then return nil end
    local cacheKey = path .. "|" .. size .. "|" .. tostring(flags) .. "|" .. label
    local known = nameWidths[cacheKey]
    if known then return known end
    if not measurer then
        local holder = CreateFrame("Frame", nil, UIParent)
        holder:Hide()
        measurer = holder:CreateFontString(nil, "OVERLAY")
    end
    if not pcall(measurer.SetFont, measurer, path, size, flags) then return nil end
    measurer:SetText(label)
    local width = measurer.GetUnboundedStringWidth and measurer:GetUnboundedStringWidth() or measurer:GetStringWidth()
    width = nosecret(width)
    if type(width) ~= "number" or width <= 0 then return nil end
    nameWidths[cacheKey] = width
    return width
end

-- The tooltip's width minus its longest line: the line's offset on both sides
-- plus any padding.
local function sideInsets(tipFrame, firstLine)
    -- (10 on each side; the line's own offset reads secret or 0 there)
    local insets = 20
    if type(tipFrame.GetPadding) == "function" then
        local isCallOk, right, _, left = pcall(tipFrame.GetPadding, tipFrame)
        if isCallOk then
            right, left = nosecret(right), nosecret(left)
            insets = insets + (type(right) == "number" and right or 0) + (type(left) == "number" and left or 0)
        end
    end
    return insets
end

-- Names this addon knows exactly as the game shows them: Korean node names and
-- English names. Elsewhere the ore names are English only.
local function namesExact()
    local locale = type(_G.GetLocale) == "function" and _G.GetLocale() or ""
    return locale == "koKR" or locale == "enUS" or locale == "enGB"
end

-- Nodes under the cursor picked by width: a list (may be empty) when the width
-- could be read, nil when it could not (the caller then goes by place alone).
function GatherSkill.nodesByWidth(tipFrame)
    local firstLine = addon.LineRegions(tipFrame, 1)
    if not firstLine then return nil end
    tipFrame:Show()   -- lays the tooltip out with only the game's lines
    local tipWidth = nosecret(tipFrame:GetWidth())
    if type(tipWidth) ~= "number" or tipWidth <= 0 then return nil end
    local insets = sideInsets(tipFrame, firstLine)
    -- a node above or below the player gets an arrow before its name, as
    -- wide as the font is high (12.0 at size 12 in game)
    local _, fontSize = lineFont(firstLine)
    local arrowWidth = type(fontSize) == "number" and fontSize or 0
    local function fits(rest) return rest >= FIT_LOW and rest <= FIT_HIGH end
    local measured = false
    local function nearestFitting(candidates)
        for _, candidate in ipairs(candidates) do
            local meta = nodeMeta[candidate.key]
            local width = meta and measureName(firstLine, meta[3])
            if width then
                measured = true
                local rest = tipWidth - width - insets
                if fits(rest) or (arrowWidth > 0 and fits(rest - arrowWidth)) then return meta end
            end
        end
        return nil
    end
    -- near the cursor first; the game's spawn points are not always where the
    -- data has them, so then the nearest fitting kind around (this part of
    -- the zone)
    local meta = nearestFitting(GatherSkill.nodeCandidates(2))
        or nearestFitting(GatherSkill.nodeCandidates(nil, WIDE_REACH))
    -- no name could be measured: by place alone
    if not measured then return nil end
    return meta and { meta } or {}
end

local function hasSecretText(tipFrame, tooltipData)
    local isSecret = _G.issecretvalue
    if type(isSecret) ~= "function" then return false end
    local dataLines = type(tooltipData) == "table" and tooltipData.lines
    if type(dataLines) == "table" and not isSecret(dataLines) then
        for _, lineData in ipairs(dataLines) do
            if type(lineData) == "table" and isSecret(lineData.leftText) then return true end
        end
    end
    local leftRegion = type(tipFrame.NumLines) == "function" and tipFrame:NumLines() > 0 and addon.LineRegions(tipFrame, 1)
    return leftRegion and isSecret(leftRegion:GetText()) or false
end

-----------------------------------------------------------------------------
-- Tooltip hooks
-----------------------------------------------------------------------------
function GatherSkill.isEnabled()
    local generalCfg = addon.db and addon.db.general
    return generalCfg ~= nil and generalCfg.showGatherSkill ~= false
end

-- Left texts of the tooltip: from the tooltip data when present, else from
-- the tooltip's own lines.
function GatherSkill.collectLeftTexts(tipFrame, tooltipData)
    local textList = {}
    local dataLines = type(tooltipData) == "table" and nosecret(tooltipData.lines)
    if type(dataLines) == "table" then
        for _, lineData in ipairs(dataLines) do
            local leftText = type(lineData) == "table" and nosecret(lineData.leftText)
            if type(leftText) == "string" then textList[#textList + 1] = leftText end
        end
        if #textList > 0 then return textList end
    end
    if type(tipFrame.NumLines) ~= "function" then return textList end
    for lineIndex = 1, tipFrame:NumLines() do
        local leftRegion = addon.LineRegions(tipFrame, lineIndex)
        local leftText = leftRegion and nosecret(leftRegion:GetText())
        if type(leftText) == "string" then textList[#textList + 1] = leftText end
    end
    return textList
end

function GatherSkill.onObjectTooltip(tipFrame, tooltipData)
    if not GatherSkill.isEnabled() or not addon.IsDecoratableTooltip(tipFrame) then return end
    local leftTexts = GatherSkill.collectLeftTexts(tipFrame, tooltipData)
    local titleText = leftTexts[1]
    if not titleText then return end
    local nodeInfo = GatherSkill.lookupNode(GatherSkill.cleanName(titleText))
    if not nodeInfo then return end
    tipFrame:AddLine(GatherSkill.composeLine(nodeInfo[1], nodeInfo[2]))
    addon.AttributeTooltip(tipFrame)
    tipFrame:Show()
end

-- The minimap tooltip lists every tracked node under the cursor, one name
-- per line (several names can share one text, split by line breaks).
function GatherSkill.onMinimapTooltip(tipFrame, tooltipData)
    if not GatherSkill.isEnabled() or not addon.IsDecoratableTooltip(tipFrame) then return end
    local foundNodes, seenNames = {}, {}
    for _, leftText in ipairs(GatherSkill.collectLeftTexts(tipFrame, tooltipData)) do
        local splitText = leftText:gsub("|n", "\n") .. "\n"
        for namePart in splitText:gmatch("(.-)\n") do
            local nodeName = GatherSkill.cleanName(namePart)
            if nodeName ~= "" and not seenNames[nodeName] then
                seenNames[nodeName] = true
                local nodeInfo = GatherSkill.lookupNode(nodeName)
                if nodeInfo then foundNodes[#foundNodes + 1] = { nodeName, nodeInfo } end
            end
        end
    end
    if #foundNodes == 0 then
        -- the text is secret: the node is the nearest one whose name fits the
        -- tooltip's width; by place alone only when the width can't be read
        -- (or, outside Korean and English, no name fits)
        if not hasSecretText(tipFrame, tooltipData) then return end
        local okWidth, nearNodes = pcall(GatherSkill.nodesByWidth, tipFrame)
        if not okWidth or type(nearNodes) ~= "table" or (#nearNodes == 0 and not namesExact()) then
            local isCallOk, byPlace = pcall(GatherSkill.nodesUnderCursor)
            nearNodes = isCallOk and byPlace or nil
        end
        if type(nearNodes) ~= "table" or #nearNodes == 0 then return end
        for _, meta in ipairs(nearNodes) do
            tipFrame:AddLine(GatherSkill.composeLine(meta[1], meta[2], meta[3]))
        end
        addon.AttributeTooltip(tipFrame)
        tipFrame:Show()
        return
    end
    local labelEach = #foundNodes > 1
    for _, foundEntry in ipairs(foundNodes) do
        tipFrame:AddLine(GatherSkill.composeLine(foundEntry[2][1], foundEntry[2][2], labelEach and foundEntry[1] or nil))
    end
    addon.AttributeTooltip(tipFrame)
    tipFrame:Show()
end

-- Dead creatures that can be skinned carry the game's "Skinnable" line.
function GatherSkill.onUnitTooltip(tipFrame, tooltipData)
    if not GatherSkill.isEnabled() or not addon.IsDecoratableTooltip(tipFrame) then return end
    local skinnableText = nosecret(_G.UNIT_SKINNABLE_LEATHER)
    if type(skinnableText) ~= "string" or skinnableText == "" then return end
    local isSkinnable = false
    for _, leftText in ipairs(GatherSkill.collectLeftTexts(tipFrame, tooltipData)) do
        if GatherSkill.cleanName(leftText) == skinnableText then
            isSkinnable = true
            break
        end
    end
    if not isSkinnable then return end
    local _, unitToken = compat.GetTooltipUnit(tipFrame, tooltipData)
    if not unitToken or type(_G.UnitLevel) ~= "function" then return end
    local isCallOk, unitLevel = pcall(_G.UnitLevel, unitToken)
    unitLevel = isCallOk and nosecret(unitLevel) or nil
    if type(unitLevel) ~= "number" or unitLevel <= 0 then return end
    tipFrame:AddLine(GatherSkill.composeLine(SKINNING, GatherSkill.skinningRequirement(unitLevel)))
    addon.AttributeTooltip(tipFrame)
    tipFrame:Show()
    EventDispatcher:trigger("tooltip:layout", tipFrame)
end

compat.AddTooltipPostCall("Object", nil, GatherSkill.onObjectTooltip)
compat.AddTooltipPostCall("MinimapMouseover", nil, GatherSkill.onMinimapTooltip)
compat.AddTooltipPostCall("Unit", nil, GatherSkill.onUnitTooltip)

EventDispatcher:attachEvent("SKILL_LINES_CHANGED, CHAT_MSG_SKILL, LEARNED_SPELL_IN_TAB, PLAYER_ENTERING_WORLD", function()
    GatherSkill.forgetSkills()
end)
