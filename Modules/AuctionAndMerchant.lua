--===========================================================================
-- EzWoW - Tooltip
-- Modules/AuctionAndMerchant.lua : Auction House Price Scanner, Cache & Merchant Price Hook
--===========================================================================
local _, ns = ...
local type, pairs, ipairs, tonumber, tostring, select, pcall = type, pairs, ipairs, tonumber, tostring, select, pcall
local AuctionPriceScanner = ns.AuctionPriceScanner or {}
ns.AuctionPriceScanner = AuctionPriceScanner
local EventDispatcher = ns.events
local addon = EzWoW_Tooltip
local compat = select(2, ...).compat
local issecret = compat.issecret
local nosecret = compat.nosecret
local format = string.format
local resolveActiveLocale = addon.GetActiveLocale
local resolveExtraLocaleText = addon.EL
local composeRelativeAge = addon.FormatRelativeAge

local ahScanState = {
    scanning          = false,
    waiting           = false,
    awaitingLegacy    = false,
    awaitingReplicate = false,
    mode              = nil, 
    index             = 1,
    total             = 0,
    minMap            = nil,
    pendingIndices    = nil,
    retryCount        = 0,
    btn               = nil,
    session           = 0,
    scannedSession    = 0,
    lastReqTime       = 0,
}

function AuctionPriceScanner.prepareAuctionStorage()
    EzWoW_TooltipDB = EzWoW_TooltipDB or {}
    if type(EzWoW_TooltipDB.auctionPrices) ~= "table" then
        EzWoW_TooltipDB.auctionPrices = {}
    end
    if type(EzWoW_TooltipDB.auctionTimes) ~= "table" then
        EzWoW_TooltipDB.auctionTimes = {}
    end
    return EzWoW_TooltipDB.auctionPrices, EzWoW_TooltipDB.auctionTimes
end

function addon:CountCachedAuctionPrices()
    local prices = EzWoW_TooltipDB and EzWoW_TooltipDB.auctionPrices
    if type(prices) ~= "table" then return 0 end
    local totalCount2 = 0
    for _, entryValue in pairs(prices) do
        if entryValue then totalCount2 = totalCount2 + 1 end
    end
    return totalCount2
end

function AuctionPriceScanner.notifyAuctionMessage(msg, showBanner)
    if not msg or msg == "" then return end
    print("|cffAEE26AEzWoW - Tooltip:|r " .. msg)
    if showBanner and UIErrorsFrame and UIErrorsFrame.AddMessage then
        pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "|cffAEE26A[EzWoW - Tooltip]|r " .. msg, 0.682, 0.886, 0.416, 1.0)
    end
end

function AuctionPriceScanner.refreshAhButtonLabel()
    local actionBtn = ahScanState.btn
    if actionBtn and actionBtn.label and AuctionPriceScanner.paintScanButton then
        AuctionPriceScanner.paintScanButton(actionBtn)
    end
    if _G.EzWoWTooltipConfig and _G.EzWoWTooltipConfig:IsShown() and _G.EzWoWTooltipConfig.updateLabels then
        _G.EzWoWTooltipConfig.updateLabels()
    end
end

function AuctionPriceScanner.commitSessionMinPrices(minMap)
    if not minMap then return 0 end
    local prices, times = AuctionPriceScanner.prepareAuctionStorage()
    local currentTime = (GetServerTime and GetServerTime()) or (time and time()) or 0
    local updated = 0
    for itemID, unitPrice in pairs(minMap) do
        if itemID and itemID > 0 and unitPrice and unitPrice > 0 then
            prices[itemID] = unitPrice
            times[itemID] = currentTime
            updated = updated + 1
        end
    end
    if updated > 0 then
        EzWoW_TooltipDB.auctionLastScan = currentTime
    end
    return updated
end

function AuctionPriceScanner.requestItemCacheLoad(itemID)
    if not itemID or itemID <= 0 then return end
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    elseif compat.GetItemInfo then
        pcall(compat.GetItemInfo, itemID)
    end
end

function AuctionPriceScanner.extractLegacyAuctionEntry(index, minMap, allowLinkLookup)
    if not GetAuctionItemInfo then return true end
    local displayName, _, totalCount2, _, _, _, r7Val, r8Val, r9Val, r10, r11, _, _, _, _, _, r17, containsAllInfo = GetAuctionItemInfo("list", index)
    local minBid, buyoutPrice, bidAmount, itemID
    if type(r7Val) == "number" and type(r17) ~= "number" then
        
        minBid = r7Val
        buyoutPrice = r9Val
        bidAmount = r10
        itemID = tonumber(r17)
    else
        
        minBid = r8Val
        buyoutPrice = r10
        bidAmount = r11
        itemID = tonumber(r17)
    end
    if (not itemID or itemID <= 0) and allowLinkLookup and GetAuctionItemLink then
        local link = GetAuctionItemLink("list", index)
        if link then
            itemID = tonumber(string.match(link, "item:(%d+)"))
        end
    end
    if not itemID or itemID <= 0 then return true end

    totalCount2 = tonumber(totalCount2) or 0
    buyoutPrice = tonumber(buyoutPrice) or 0
    local effectiveBid = tonumber(bidAmount)
    if not effectiveBid or effectiveBid <= 0 then
        effectiveBid = tonumber(minBid) or 0
    end
    -- the price is the buyout only: an auction without one (bids only) would
    -- otherwise count its usually very low starting bid as the lowest price
    local rawTotal = (buyoutPrice > 0) and buyoutPrice or 0

    if (not displayName or containsAllInfo == false) and (totalCount2 <= 0 or (rawTotal <= 0 and effectiveBid <= 0)) then
        AuctionPriceScanner.requestItemCacheLoad(itemID)
        return false
    end

    if totalCount2 <= 0 then totalCount2 = 1 end
    if rawTotal <= 0 and effectiveBid <= 0 then return true end

    if rawTotal > 0 then
        local unitPrice = math.max(1, math.floor(rawTotal / totalCount2))
        local prev = minMap[itemID]
        if not prev or unitPrice < prev then
            minMap[itemID] = unitPrice
        end
    end
    AuctionPriceScanner.addListedQuantity(itemID, totalCount2)
    return true
end

function AuctionPriceScanner.extractReplicateAuctionEntry(index, minMap)
    if not C_AuctionHouse or not C_AuctionHouse.GetReplicateItemInfo then return true end
    local displayName, _, totalCount2, _, _, _, _, minBid, _, buyoutPrice, bidAmount, _, _, _, _, _, itemID, containsAllInfo = C_AuctionHouse.GetReplicateItemInfo(index)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then return true end

    totalCount2 = tonumber(totalCount2) or 0
    buyoutPrice = tonumber(buyoutPrice) or 0
    local effectiveBid = tonumber(bidAmount)
    if not effectiveBid or effectiveBid <= 0 then
        effectiveBid = tonumber(minBid) or 0
    end
    -- the price is the buyout only: an auction without one (bids only) would
    -- otherwise count its usually very low starting bid as the lowest price
    local rawTotal = (buyoutPrice > 0) and buyoutPrice or 0

    if (not displayName or containsAllInfo == false) and (totalCount2 <= 0 or (rawTotal <= 0 and effectiveBid <= 0)) then
        AuctionPriceScanner.requestItemCacheLoad(itemID)
        return false
    end

    if totalCount2 <= 0 then totalCount2 = 1 end
    if rawTotal <= 0 and effectiveBid <= 0 then return true end

    if rawTotal > 0 then
        local unitPrice = math.max(1, math.floor(rawTotal / totalCount2))
        local prev = minMap[itemID]
        if not prev or unitPrice < prev then
            minMap[itemID] = unitPrice
        end
    end
    AuctionPriceScanner.addListedQuantity(itemID, totalCount2)
    return true
end

-- Listed quantity per item during a full scan (read by EzWoW - Bags for its price history).
function AuctionPriceScanner.addListedQuantity(itemID, count)
    local quantities = ahScanState.qtyMap
    if quantities and itemID and count and count > 0 then
        quantities[itemID] = (quantities[itemID] or 0) + count
    end
end

function AuctionPriceScanner.finishChunkedScan()
    local scannedListings = ahScanState.total or 0
    ahScanState.scanning = false
    ahScanState.waiting = false
    ahScanState.awaitingLegacy = false
    ahScanState.awaitingReplicate = false
    local updated = AuctionPriceScanner.commitSessionMinPrices(ahScanState.minMap)
    if updated > 0 and ahScanState.qtyMap then
        EzWoW_TooltipDB.auctionQuantities = ahScanState.qtyMap
        EzWoW_TooltipDB.auctionQuantityTime = (GetServerTime and GetServerTime()) or (time and time()) or 0
    end
    ahScanState.qtyMap = nil
    ahScanState.minMap = nil
    ahScanState.pendingIndices = nil
    ahScanState.retryCount = 0
    ahScanState.stallCount = 0
    ahScanState.doneAt, ahScanState.doneCount = GetTime and GetTime() or 0, updated
    AuctionPriceScanner.refreshAhButtonLabel()
    if updated > 0 then
        if resolveActiveLocale() == "koKR" and scannedListings > updated then
            AuctionPriceScanner.notifyAuctionMessage(format("경매장 시세 수집 완료 (전체 매물 %d건 · 고유 아이템 %d종 최저가 저장됨)", scannedListings, updated), true)
        else
            AuctionPriceScanner.notifyAuctionMessage(format(resolveExtraLocaleText("ahScanDone"), updated), true)
        end
    end
end

-- Rows whose item is not in the client's cache yet have no count or price; the
-- client loads them a few hundred at a time, so a big full scan had thousands
-- of such rows and dropped every one still unread after 2 seconds (up to a
-- seventh of the items, 2026-11-22). The rows are read again every half second
-- while they keep loading, and given up after RETRY_STALLS passes in a row
-- without any progress (or RETRY_MAX passes in all).
local RETRY_DELAY, RETRY_STALLS, RETRY_MAX = 0.5, 6, 120
function AuctionPriceScanner.keepRetrying(before, after)
    if after <= 0 then return false end
    ahScanState.stallCount = (after < before) and 0 or ((ahScanState.stallCount or 0) + 1)
    return ahScanState.stallCount < RETRY_STALLS and (ahScanState.retryCount or 0) < RETRY_MAX
end

function AuctionPriceScanner.retryPendingAuctionEntries(session)
    if not ahScanState.scanning or ahScanState.session ~= session then return end
    local pending = ahScanState.pendingIndices
    if not pending or #pending == 0 then
        AuctionPriceScanner.finishChunkedScan()
        return
    end
    local stillPending = {}
    if ahScanState.mode == "legacy" then
        for _, entryIndex in ipairs(pending) do
            if not AuctionPriceScanner.extractLegacyAuctionEntry(entryIndex, ahScanState.minMap, false) then
                stillPending[#stillPending + 1] = entryIndex
            end
        end
    elseif ahScanState.mode == "replicate" then
        for _, entryIndex in ipairs(pending) do
            if not AuctionPriceScanner.extractReplicateAuctionEntry(entryIndex - 1, ahScanState.minMap) then
                stillPending[#stillPending + 1] = entryIndex
            end
        end
    end
    ahScanState.pendingIndices = stillPending
    ahScanState.retryCount = (ahScanState.retryCount or 0) + 1
    if AuctionPriceScanner.keepRetrying(#pending, #stillPending) and C_Timer and C_Timer.After then
        C_Timer.After(RETRY_DELAY, function()
            AuctionPriceScanner.retryPendingAuctionEntries(session)
        end)
    else
        AuctionPriceScanner.finishChunkedScan()
    end
end

local ahWorkerFrame = CreateFrame("Frame")
ahWorkerFrame:Hide()
ahWorkerFrame:SetScript("OnUpdate", function(self)
    if not ahScanState.scanning or ahScanState.total <= 0 then
        self:Hide()
        return
    end
    local batchEnd = math.min(ahScanState.index + 600 - 1, ahScanState.total)
    local pending = ahScanState.pendingIndices
    if ahScanState.mode == "legacy" then
        for indexEntry = ahScanState.index, batchEnd do
            if not AuctionPriceScanner.extractLegacyAuctionEntry(indexEntry, ahScanState.minMap, false) and pending then
                pending[#pending + 1] = indexEntry
            end
        end
    elseif ahScanState.mode == "replicate" then
        for indexEntry = ahScanState.index, batchEnd do
            if not AuctionPriceScanner.extractReplicateAuctionEntry(indexEntry - 1, ahScanState.minMap) and pending then
                pending[#pending + 1] = indexEntry
            end
        end
    end
    ahScanState.index = batchEnd + 1
    AuctionPriceScanner.refreshAhButtonLabel()

    if ahScanState.index > ahScanState.total then
        self:Hide()
        if pending and #pending > 0 and C_Timer and C_Timer.After then
            local session = ahScanState.session
            C_Timer.After(0.5, function()
                AuctionPriceScanner.retryPendingAuctionEntries(session)
            end)
        else
            AuctionPriceScanner.finishChunkedScan()
        end
    end
end)

function AuctionPriceScanner.startChunkedScan(mode, totalCount)
    if ahScanState.scanning and ahScanState.mode == mode and ahWorkerFrame:IsShown() then
        return
    end
    ahScanState.scanning = true
    ahScanState.waiting = false
    ahScanState.awaitingLegacy = false
    ahScanState.awaitingReplicate = false
    ahScanState.mode = mode
    ahScanState.index = 1
    ahScanState.total = totalCount
    ahScanState.minMap = {}
    ahScanState.qtyMap = {}
    ahScanState.pendingIndices = {}
    ahScanState.retryCount = 0
    ahScanState.stallCount = 0
    AuctionPriceScanner.refreshAhButtonLabel()
    ahWorkerFrame:Show()
end

function AuctionPriceScanner.inspectVisibleLegacyPage(announce)
    if not GetNumAuctionItems then return 0 end
    local batch = GetNumAuctionItems("list") or 0
    
    if batch <= 0 or batch > 100 then return 0 end
    local minMap = {}
    for indexEntry = 1, batch do
        AuctionPriceScanner.extractLegacyAuctionEntry(indexEntry, minMap, true)
    end
    local updated = AuctionPriceScanner.commitSessionMinPrices(minMap)
    if announce and updated > 0 then
        AuctionPriceScanner.notifyAuctionMessage(format(resolveExtraLocaleText("ahScanPage"), updated), true)
    end
    AuctionPriceScanner.refreshAhButtonLabel()
    return updated
end

function AuctionPriceScanner.inspectModernBrowseResults(announce)
    if not C_AuctionHouse or not C_AuctionHouse.GetBrowseResults then return 0 end
    local isCallOk, results = pcall(C_AuctionHouse.GetBrowseResults)
    if not isCallOk or type(results) ~= "table" or #results == 0 then return 0 end
    local minMap = {}
    for _, entry in ipairs(results) do
        local itemID = entry and entry.itemKey and tonumber(entry.itemKey.itemID)
        local minPrice = entry and tonumber(entry.minPrice)
        if itemID and itemID > 0 and minPrice and minPrice > 0 then
            local prev = minMap[itemID]
            if not prev or minPrice < prev then
                minMap[itemID] = minPrice
            end
        end
    end
    local updated = AuctionPriceScanner.commitSessionMinPrices(minMap)
    if announce and updated > 0 then
        AuctionPriceScanner.notifyAuctionMessage(format(resolveExtraLocaleText("ahScanDone"), updated), true)
    end
    AuctionPriceScanner.refreshAhButtonLabel()
    return updated
end

function AuctionPriceScanner.hasAuctionWindowOpen()
    if _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() then return true, "modern" end
    if _G.AuctionFrame and _G.AuctionFrame:IsShown() then return true, "legacy" end
    if C_AuctionHouse and C_AuctionHouse.ReplicateItems and (not IsUsingLegacyAuctionClient or not IsUsingLegacyAuctionClient()) then
        return ahScanState.isOpen, "modern"
    end
    if QueryAuctionItems then
        return ahScanState.isOpen, "legacy"
    end
    return false, nil
end

-- The full list can take many seconds to arrive on a busy auction house. Its
-- event normally starts the scan; without the event, the scan starts once the
-- row count has stopped growing (checked every half second). The old fixed
-- 2.5 s wait could start on part of the list, or give up and ignore the list
-- that came later (2026-11-22).
local REPLICATE_POLL, REPLICATE_STEADY, REPLICATE_WAIT, REPLICATE_NODATA = 0.5, 3, 60, 15

-- The full list can be asked for once every 15 minutes; the server ignores a request
-- sooner, and after a /reload (which forgot the time) the bar stood at "0" for good
-- (2026-11-22). The time of the last request is saved; a request too soon shows when
-- the next one can be made and, with the window still open, makes it then.
local REPLICATE_COOLDOWN = 900
local function serverNow() return (GetServerTime and GetServerTime()) or (time and time()) or 0 end
function AuctionPriceScanner.lastReplicateRequest()
    local db = type(EzWoW_TooltipDB) == "table" and EzWoW_TooltipDB or {}
    -- saves from before the request time was kept: the end of the last full scan
    local at = tonumber(db.auctionReplicateAt) or tonumber(db.auctionQuantityTime) or 0
    return math.max(at, tonumber(ahScanState.lastReqTime) or 0)
end
function AuctionPriceScanner.replicateWaitLeft(now)
    local left = AuctionPriceScanner.lastReplicateRequest() + REPLICATE_COOLDOWN - (now or serverNow())
    if left > REPLICATE_COOLDOWN then left = REPLICATE_COOLDOWN end      -- a clock set back
    return left > 0 and left or 0
end
function AuctionPriceScanner.clockText(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
function AuctionPriceScanner.waitForCooldown(session, left, isAuto)
    ahScanState.cooldownSession = session
    AuctionPriceScanner.refreshAhButtonLabel()
    if not isAuto then
        AuctionPriceScanner.notifyAuctionMessage(format(resolveExtraLocaleText("ahScanCooldown"),
            AuctionPriceScanner.clockText(left)), false)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(left + 1, function()
            if ahScanState.isOpen and ahScanState.session == session and not ahScanState.scanning
                and not ahScanState.awaitingReplicate and AuctionPriceScanner.replicateWaitLeft() <= 0 then
                ahScanState.cooldownSession = nil
                ahScanState.scannedSession = 0
                addon:BeginAuctionHousePriceScan(true)
            end
        end)
    end
end
function AuctionPriceScanner.replicateReady(counts)
    local n = #counts
    if n < REPLICATE_STEADY then return false end
    local last = counts[n]
    if not last or last <= 0 then return false end
    for i = n - REPLICATE_STEADY + 1, n do
        if counts[i] ~= last then return false end
    end
    return true
end
function AuctionPriceScanner.waitForReplicate(session)
    if not (C_Timer and C_Timer.After) then return end
    local counts, waited = {}, 0
    local function poll()
        if ahScanState.session ~= session or not ahScanState.awaitingReplicate or ahScanState.scanning then return end
        waited = waited + REPLICATE_POLL
        local numRep = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
        counts[#counts + 1] = tonumber(numRep) or 0
        if AuctionPriceScanner.replicateReady(counts) then
            ahScanState.awaitingReplicate = false
            AuctionPriceScanner.startChunkedScan("replicate", counts[#counts])
        elseif waited >= REPLICATE_NODATA and counts[#counts] <= 0 then
            -- nothing came (the server did not answer the request): say so, and keep the browse results
            ahScanState.awaitingReplicate = false
            ahScanState.noListAt = GetTime and GetTime() or 0
            AuctionPriceScanner.refreshAhButtonLabel()
            if C_AuctionHouse.SendBrowseQuery then
                pcall(C_AuctionHouse.SendBrowseQuery, { searchString = "", sorts = {}, filters = {} })
            end
        elseif waited >= REPLICATE_WAIT then
            ahScanState.awaitingReplicate = false
            if counts[#counts] > 0 then
                AuctionPriceScanner.startChunkedScan("replicate", counts[#counts])
            else
                AuctionPriceScanner.refreshAhButtonLabel()
                if C_AuctionHouse.SendBrowseQuery then
                    pcall(C_AuctionHouse.SendBrowseQuery, { searchString = "", sorts = {}, filters = {} })
                end
            end
        else
            C_Timer.After(REPLICATE_POLL, poll)
        end
    end
    C_Timer.After(REPLICATE_POLL, poll)
end

function addon:BeginAuctionHousePriceScan(isAuto)
    if ahScanState.scanning and ahWorkerFrame:IsShown() then return end
    if ahScanState.awaitingReplicate then AuctionPriceScanner.refreshAhButtonLabel(); return end
    if isAuto and ahScanState.scannedSession == ahScanState.session then return end

    local hasOpen, uiKind = AuctionPriceScanner.hasAuctionWindowOpen()
    if not hasOpen then
        if not isAuto then
            AuctionPriceScanner.notifyAuctionMessage(resolveExtraLocaleText("ahScanOpen"), false)
        end
        return
    end

    local currentTime = (GetServerTime and GetServerTime()) or (time and time()) or 0

    if uiKind == "modern" and C_AuctionHouse then
        AuctionPriceScanner.inspectModernBrowseResults(false)

        if C_AuctionHouse.ReplicateItems and C_AuctionHouse.GetNumReplicateItems then
            local ready = true
            if C_AuctionHouse.IsThrottledMessageSystemReady then
                local isCallOk, rowEntry = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
                if isCallOk and rowEntry == false then ready = false end
            end

            if not ready then
                if not ahScanState.waiting then
                    ahScanState.waiting = true
                    AuctionPriceScanner.refreshAhButtonLabel()
                end
                local session = ahScanState.session
                if C_Timer and C_Timer.After then
                    C_Timer.After(0.5, function()
                        if ahScanState.session == session and ahScanState.isOpen and not ahScanState.scanning and ahScanState.scannedSession ~= session then
                            addon:BeginAuctionHousePriceScan(true)
                        end
                    end)
                end
                return
            end

            ahScanState.scannedSession = ahScanState.session
            ahScanState.waiting = false

            local cachedTotal = C_AuctionHouse.GetNumReplicateItems() or 0
            local waitLeft = AuctionPriceScanner.replicateWaitLeft(currentTime)
            if waitLeft > 0 and cachedTotal > 0 then
                AuctionPriceScanner.startChunkedScan("replicate", cachedTotal)
                return
            end
            if waitLeft > 0 then
                AuctionPriceScanner.waitForCooldown(ahScanState.session, waitLeft, isAuto)
                return
            end

            ahScanState.lastReqTime = currentTime
            if EzWoW_TooltipDB then EzWoW_TooltipDB.auctionReplicateAt = currentTime end
            ahScanState.waiting = false
            ahScanState.awaitingReplicate = true
            ahScanState.mode = "replicate"
            ahScanState.index = 1
            ahScanState.total = 0
            ahScanState.minMap = {}
            AuctionPriceScanner.refreshAhButtonLabel()
            pcall(C_AuctionHouse.ReplicateItems)
            AuctionPriceScanner.waitForReplicate(ahScanState.session)
            return
        end

        ahScanState.scannedSession = ahScanState.session
        AuctionPriceScanner.inspectModernBrowseResults(true)
        return
    end

    if QueryAuctionItems then
        local canQuery, canQueryAll = false, false
        if CanSendAuctionQuery then
            canQuery, canQueryAll = CanSendAuctionQuery("list")
        end

        if canQueryAll then
            if ITEM_QUALITY_COLORS and not ITEM_QUALITY_COLORS[-1] then
                ITEM_QUALITY_COLORS[-1] = { r = 0, g = 0, b = 0 }
            end
            ahScanState.scannedSession = ahScanState.session
            ahScanState.lastReqTime = currentTime
            ahScanState.waiting = false
            ahScanState.awaitingLegacy = true
            ahScanState.mode = "legacy"
            ahScanState.index = 1
            ahScanState.total = 0
            ahScanState.minMap = {}
            AuctionPriceScanner.refreshAhButtonLabel()
            AuctionPriceScanner.notifyAuctionMessage(resolveExtraLocaleText("ahScanStart"), true)
            pcall(QueryAuctionItems, "", nil, nil, 0, nil, nil, true, false, nil)
            return
        elseif canQuery then
            ahScanState.scannedSession = ahScanState.session
            local visibleCount = GetNumAuctionItems and GetNumAuctionItems("list") or 0
            if visibleCount > 0 and visibleCount <= 100 then
                AuctionPriceScanner.notifyAuctionMessage(resolveExtraLocaleText("ahScanStart"), true)
                AuctionPriceScanner.inspectVisibleLegacyPage(true)
            elseif visibleCount > 100 then
                AuctionPriceScanner.notifyAuctionMessage(resolveExtraLocaleText("ahScanStart"), true)
                AuctionPriceScanner.startChunkedScan("legacy", visibleCount)
            else
                AuctionPriceScanner.notifyAuctionMessage(resolveExtraLocaleText("ahScanStart"), true)
                ahScanState.autoPageQuery = true
                pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, false, false, nil)
            end
            return
        else
            
            if not ahScanState.waiting then
                ahScanState.waiting = true
                AuctionPriceScanner.refreshAhButtonLabel()
                AuctionPriceScanner.notifyAuctionMessage(resolveExtraLocaleText("ahScanStart"), true)
            end
            local session = ahScanState.session
            if C_Timer and C_Timer.After then
                C_Timer.After(0.5, function()
                    if ahScanState.session == session and ahScanState.isOpen and not ahScanState.scanning and ahScanState.scannedSession ~= session then
                        addon:BeginAuctionHousePriceScan(true)
                    end
                end)
            end
            return
        end
    end
end

-- Progress of the price scan in a bar over the auction window (2026-11-22, user):
-- the list being received (rows so far), the rows being read (read / all), rows
-- still waiting for their item data (left), then the result for a few seconds.
local PROGRESS_DONE_SHOW = 6
local function bigNumber(n)
    n = math.floor(tonumber(n) or 0)
    if type(BreakUpLargeNumbers) == "function" then
        local ok, text = pcall(BreakUpLargeNumbers, n)
        if ok and type(text) == "string" then return text end
    end
    return tostring(n)
end
local function safeCount(fn, ...)
    if type(fn) ~= "function" then return 0 end
    local ok, a, b = pcall(fn, ...)
    if not ok then return 0 end
    return tonumber(b) or tonumber(a) or 0
end
-- fraction (0..1) and text of the scan now; nil when there is nothing to show
function AuctionPriceScanner.progressInfo(now)
    local s = ahScanState
    if s.scanning and (s.total or 0) > 0 then
        if (s.index or 1) <= s.total then
            local read = math.max(0, (s.index or 1) - 1)
            return read / s.total, format(resolveExtraLocaleText("ahProgRead"), bigNumber(read), bigNumber(s.total))
        end
        local left = s.pendingIndices and #s.pendingIndices or 0
        return math.max(0, s.total - left) / s.total, format(resolveExtraLocaleText("ahProgItems"), bigNumber(left))
    end
    if s.awaitingReplicate then
        local count = safeCount(C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems)
        return 0, format(resolveExtraLocaleText("ahProgList"), bigNumber(count))
    end
    if s.awaitingLegacy then
        return 0, format(resolveExtraLocaleText("ahProgList"), bigNumber(safeCount(GetNumAuctionItems, "list")))
    end
    if s.waiting then return 0, resolveExtraLocaleText("ahProgWait") end
    if s.cooldownSession and s.cooldownSession == s.session and s.isOpen then
        local left = AuctionPriceScanner.replicateWaitLeft()
        if left > 0 then
            return 1 - left / REPLICATE_COOLDOWN, format(resolveExtraLocaleText("ahProgCooldown"), AuctionPriceScanner.clockText(left))
        end
    end
    if s.noListAt and (now or 0) - s.noListAt < PROGRESS_DONE_SHOW then
        return 0, resolveExtraLocaleText("ahProgNoList")
    end
    if s.doneAt and (s.doneCount or 0) > 0 and (now or 0) - s.doneAt < PROGRESS_DONE_SHOW then
        return 1, format(resolveExtraLocaleText("ahProgDone"), bigNumber(s.doneCount))
    end
    return nil
end

-- The scan button is the progress bar (2026-11-22, user: the bar over the window
-- and the button in the title bar, where it hid under the title art, were two
-- places): idle it reads "update prices"; during a scan it fills and tells the step.
local BUTTON_W, BUTTON_H = 300, 20
function AuctionPriceScanner.paintScanButton(btn)
    local fraction, text = AuctionPriceScanner.progressInfo(GetTime and GetTime() or 0)
    if text then
        fraction = math.max(0, math.min(1, fraction or 0))
        btn.fill:SetWidth(math.max(1, (BUTTON_W - 2) * fraction))
        btn.fill:SetShown(fraction > 0)
        btn.label:SetTextColor(0.929, 0.957, 0.969, 1.0)
        btn.label:SetText(text)
    else
        btn.fill:Hide()
        btn.label:SetTextColor(0.682, 0.886, 0.416, 1.0)
        btn.label:SetText(resolveExtraLocaleText("ahScanBtn"))
    end
    ns.UIKit:FitFontString(btn.label, BUTTON_W - 12, 1)
end

function AuctionPriceScanner.prepareAuctionScanButton()
    local parentFrame = (_G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() and _G.AuctionHouseFrame)
        or (_G.AuctionFrame and _G.AuctionFrame:IsShown() and _G.AuctionFrame)
        or _G.AuctionHouseFrame or _G.AuctionFrame
    if not parentFrame then return end

    if not ahScanState.btn then
        -- with the gamepad UI on, made without a parent and put in afterwards: a frame made
        -- inside the open auction window breaks the game's gamepad navigation (Libs/EzWoWGamePad)
        local pad = ns.GamePad
        local make = (pad and pad.MakeFrame and pad.IsActive and pad.IsActive() and pad.MakeFrame) or CreateFrame
        local actionBtn = make("Button", "EzWoWTooltipAHScanButton", parentFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
        actionBtn:SetSize(BUTTON_W, BUTTON_H)
        if actionBtn.SetBackdrop then
            ns.UIKit:ApplyBackdrop(actionBtn)
            actionBtn:SetBackdropColor(0.071, 0.094, 0.122, 0.96)
            actionBtn:SetBackdropBorderColor(0.682, 0.886, 0.416, 1.0)
        end
        local fill = actionBtn:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMLEFT", 1, 1)
        fill:SetColorTexture(0.682, 0.886, 0.416, 0.38)
        fill:Hide()
        actionBtn.fill = fill
        local lbl = actionBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("CENTER")
        lbl:SetTextColor(0.682, 0.886, 0.416, 1.0)
        actionBtn.label = lbl
        if actionBtn.SetClampedToScreen then actionBtn:SetClampedToScreen(true) end
        local since = 0
        actionBtn:SetScript("OnUpdate", function(self, elapsed)
            since = since + (elapsed or 0)
            if since < 0.1 then return end
            since = 0
            AuctionPriceScanner.paintScanButton(self)
        end)

        actionBtn:SetScript("OnEnter", function(self)
            if self.SetBackdropColor then
                self:SetBackdropColor(0.14, 0.22, 0.17, 1.0)
            end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(resolveExtraLocaleText("ahTipTitle"), 0.682, 0.886, 0.416)
            GameTooltip:AddLine(resolveExtraLocaleText("ahTipDesc"), 0.929, 0.957, 0.969, true)
            GameTooltip:AddLine(resolveExtraLocaleText("ahTipPassive"), 0.655, 0.725, 0.773, true)
            local itemCount = addon:CountCachedAuctionPrices()
            local age = composeRelativeAge(EzWoW_TooltipDB and EzWoW_TooltipDB.auctionLastScan)
            GameTooltip:AddLine(format(resolveExtraLocaleText("ahTipCount"), itemCount) .. age, 0.294, 0.784, 0.910)
            if addon.AttributeTooltip then addon.AttributeTooltip(GameTooltip) end
            GameTooltip:Show()
        end)
        actionBtn:SetScript("OnLeave", function(self)
            if self.SetBackdropColor then
                self:SetBackdropColor(0.071, 0.094, 0.122, 0.96)
            end
            GameTooltip:Hide()
        end)
        actionBtn:SetScript("OnClick", function()
            addon:BeginAuctionHousePriceScan(false)
        end)
        ahScanState.btn = actionBtn
    end

    local actionBtn = ahScanState.btn
    actionBtn:SetParent(parentFrame)
    actionBtn:ClearAllPoints()
    -- just over the auction window's top right corner, clear of its title and close button
    actionBtn:SetPoint("BOTTOMRIGHT", parentFrame, "TOPRIGHT", 0, 2)
    actionBtn:SetFrameLevel((parentFrame:GetFrameLevel() or 1) + 10)
    actionBtn:Show()
    AuctionPriceScanner.refreshAhButtonLabel()
end

local JUNK_SELL_BATCH = 10      -- items sold per tick (the server rejects large single-frame bursts)
local JUNK_SELL_INTERVAL = 0.25
local JUNK_SWEEP_BASE_DELAY = 0.4
local JUNK_SWEEP_MAX_DELAY = 1.6
local JUNK_SWEEP_MAX_PASSES = 12
local JUNK_SWEEP_MAX_STALLS = 3

-- Selling is allowed by the merchant interaction, not by the frame: at MERCHANT_SHOW
-- the merchant window may not be shown yet, so track the interaction ourselves.
local merchantOpen = false
local junkSweep = { current = nil }

function AuctionPriceScanner.forEachBagSlot(fn)
    local maxBags = NUM_BAG_SLOTS or 4
    for bag = 0, maxBags do
        local numSlots = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag))
            or (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
        for slot = 1, numSlots do
            fn(bag, slot)
        end
    end
end

function AuctionPriceScanner.readSlotLink(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local apiInfo = C_Container.GetContainerItemInfo(bag, slot)
        return apiInfo and apiInfo.hyperlink or nil
    elseif GetContainerItemInfo then
        local _, _, _, _, _, _, itemLink = GetContainerItemInfo(bag, slot)
        return itemLink
    end
    return nil
end

function AuctionPriceScanner.beginJunkSweep()
    local sweep = { seen = {}, reported = false }
    junkSweep.current = sweep
    return sweep
end

-- Counts sellable poor-quality items (and slots whose quality is not known yet),
-- remembering each one so the final report can tell what was really sold.
function AuctionPriceScanner.countJunk(sweep)
    local junk, unknown = 0, 0
    if not (C_Container and C_Container.GetContainerItemInfo) then return junk, unknown end
    local poor = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0
    AuctionPriceScanner.forEachBagSlot(function(bag, slot)
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID then
            if info.quality == nil then
                unknown = unknown + 1
            elseif info.quality == poor and not info.hasNoValue then
                junk = junk + 1
                local key = bag * 1000 + slot
                if sweep and not sweep.seen[key] then
                    local link, stackCount, sellPrice = AuctionPriceScanner.readJunkSlot(bag, slot)
                    if link then
                        sweep.seen[key] = { bag = bag, slot = slot, link = link, stack = stackCount or 1, price = sellPrice or 0 }
                    end
                end
            end
        end
    end)
    return junk, unknown
end

-- Prints the sold total (items that actually left the bags) and, when asked, the leftovers.
function AuctionPriceScanner.reportJunkSweep(sweep, reportLeft)
    if not sweep or sweep.reported then return end
    sweep.reported = true
    local soldCount, soldCopper = 0, 0
    for _, rec in pairs(sweep.seen) do
        if AuctionPriceScanner.readSlotLink(rec.bag, rec.slot) ~= rec.link then
            soldCount = soldCount + rec.stack
            soldCopper = soldCopper + rec.price * rec.stack
        end
    end
    if soldCount > 0 and soldCopper > 0 then
        print("|cffAEE26AEzWoW - Tooltip:|r " .. format(resolveExtraLocaleText("autoSellDone"), soldCount, addon.FormatCopperAsCoinIcons(soldCopper) or tostring(soldCopper)))
    end
    if reportLeft and merchantOpen then
        local left = AuctionPriceScanner.countJunk(nil)
        if left > 0 then
            print("|cffAEE26AEzWoW - Tooltip:|r |cffE77C70" .. format(resolveExtraLocaleText("autoSellLeft"), left) .. "|r")
        end
    end
end

function AuctionPriceScanner.readJunkSlot(bag, slot)
    local link, stackCount, quality, locked
    if C_Container and C_Container.GetContainerItemInfo then
        local apiInfo = C_Container.GetContainerItemInfo(bag, slot)
        if apiInfo then
            link = apiInfo.hyperlink
            stackCount = apiInfo.stackCount or 1
            quality = apiInfo.quality
            locked = apiInfo.isLocked
        end
    elseif GetContainerItemInfo then
        local _, itemCountEntry, hasLocked, itemQuality, _, _, itemLink = GetContainerItemInfo(bag, slot)
        link = itemLink
        stackCount = itemCountEntry or 1
        quality = itemQuality
        locked = hasLocked
    end
    if not link or locked then return nil end
    local _, _, infoQuality, _, _, _, _, _, _, _, sellPrice = compat.GetItemInfo(link)
    quality = quality or infoQuality
    if quality == 0 and sellPrice and sellPrice > 0 then
        return link, stackCount or 1, sellPrice
    end
    if quality == 0 and sellPrice == nil then
        -- item data not cached yet: ask the client to load it so a retry can sell it
        if C_Item and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, link)
        end
        return nil, nil, nil, true
    end
end

function AuctionPriceScanner.sellJunkInBatches(isRetry)
    -- per-item fallback for clients without the bulk junk-sell call
    local sweep = AuctionPriceScanner.beginJunkSweep()
    local queue, hasUncached = {}, false
    AuctionPriceScanner.forEachBagSlot(function(bag, slot)
        local link, stackCount, sellPrice, isUncached = AuctionPriceScanner.readJunkSlot(bag, slot)
        if link then
            queue[#queue + 1] = { bag = bag, slot = slot, link = link }
            sweep.seen[bag * 1000 + slot] = { bag = bag, slot = slot, link = link, stack = stackCount or 1, price = sellPrice or 0 }
        elseif isUncached then
            hasUncached = true
        end
    end)

    -- junk whose price was not cached yet gets one more pass once the data has loaded
    local willRetry = (hasUncached and not isRetry and C_Timer and C_Timer.After) and true or false
    local function finish()
        -- the server answers sell requests later: count what actually left the bags after a short wait
        if C_Timer and C_Timer.After then
            C_Timer.After(1.0, function()
                if sweep ~= junkSweep.current then return end
                AuctionPriceScanner.reportJunkSweep(sweep, not willRetry)
                if willRetry and merchantOpen then
                    AuctionPriceScanner.sellJunkInBatches(true)
                end
            end)
        else
            AuctionPriceScanner.reportJunkSweep(sweep, false)
        end
        return nil
    end
    if #queue == 0 then return finish() end

    local cursor = 1
    local function step()
        if sweep ~= junkSweep.current then return end
        if not merchantOpen then return finish() end
        local sentThisTick = 0
        while cursor <= #queue and sentThisTick < JUNK_SELL_BATCH do
            local q = queue[cursor]
            cursor = cursor + 1
            -- re-check: another addon (or the player) may have sold/moved it already
            local link = AuctionPriceScanner.readJunkSlot(q.bag, q.slot)
            if link and link == q.link then
                if C_Container and C_Container.UseContainerItem then
                    pcall(C_Container.UseContainerItem, q.bag, q.slot)
                elseif UseContainerItem then
                    pcall(UseContainerItem, q.bag, q.slot)
                end
                sentThisTick = sentThisTick + 1
            end
        end
        if cursor <= #queue and C_Timer and C_Timer.After then
            C_Timer.After(JUNK_SELL_INTERVAL, step)
        else
            finish()
        end
    end
    step()
end

-- Bulk junk sell. One SellAllJunkItems call is fire-and-forget: requests past the
-- server rate limit are dropped and items whose data is not cached yet are skipped,
-- so re-count after each pass and send again while the count keeps falling.
function AuctionPriceScanner.sellJunkSweep()
    local sweep = AuctionPriceScanner.beginJunkSweep()
    sweep.passes, sweep.lastCount, sweep.stalls, sweep.delay = 0, math.huge, 0, JUNK_SWEEP_BASE_DELAY

    local function pass()
        if sweep ~= junkSweep.current then return end
        if not merchantOpen then return AuctionPriceScanner.reportJunkSweep(sweep, false) end

        local junk, unknown = AuctionPriceScanner.countJunk(sweep)
        if junk == 0 and unknown == 0 then return AuctionPriceScanner.reportJunkSweep(sweep, false) end

        sweep.passes = sweep.passes + 1
        if junk > sweep.lastCount then
            -- uncached slots resolved into newly visible junk: progress, not a stall
            sweep.stalls, sweep.delay = 0, JUNK_SWEEP_BASE_DELAY
        elseif junk == sweep.lastCount then
            -- nothing moved: an unsellable item or a dropped request, so back off before giving up
            sweep.stalls = sweep.stalls + 1
            sweep.delay = math.min(sweep.delay * 2, JUNK_SWEEP_MAX_DELAY)
            if sweep.stalls >= JUNK_SWEEP_MAX_STALLS then
                return AuctionPriceScanner.reportJunkSweep(sweep, true)
            end
        else
            sweep.stalls, sweep.delay = 0, JUNK_SWEEP_BASE_DELAY
        end
        sweep.lastCount = junk

        if junk > 0 then pcall(C_MerchantFrame.SellAllJunkItems) end
        if sweep.passes >= JUNK_SWEEP_MAX_PASSES then
            -- the last request is still in flight: verify once more after it lands
            C_Timer.After(sweep.delay, function()
                if sweep ~= junkSweep.current then return end
                AuctionPriceScanner.reportJunkSweep(sweep, true)
            end)
            return
        end
        C_Timer.After(sweep.delay, pass)
    end
    pass()
end

-- Auto-sell and auto-repair belong to EzWoW-Bags; this copy only runs while Bags is not loaded.
AuctionPriceScanner.MERCHANT_OWNER = "EzWoW-Bags"

function AuctionPriceScanner.handleMerchantShow()
    if addon.OwnsOption(AuctionPriceScanner.MERCHANT_OWNER) then return end
    if IsShiftKeyDown and IsShiftKeyDown() then return end
    local iCfg = addon.db and addon.db.item

    if not iCfg or iCfg.autoSellJunk ~= false then
        if C_MerchantFrame and C_MerchantFrame.SellAllJunkItems and C_Container and C_Container.GetContainerItemInfo
            and C_Timer and C_Timer.After then
            AuctionPriceScanner.sellJunkSweep()
        else
            AuctionPriceScanner.sellJunkInBatches()
        end
    end

    if not iCfg or iCfg.autoRepair ~= false then
        if CanMerchantRepair and CanMerchantRepair() and GetRepairAllCost and RepairAllItems then
            local cost, canRepair = GetRepairAllCost()
            if canRepair and cost and cost > 0 then
                local money = GetMoney and GetMoney() or 0
                if money >= cost then
                    pcall(RepairAllItems)
                    print("|cffAEE26AEzWoW - Tooltip:|r " .. format(resolveExtraLocaleText("autoRepairDone"), addon.FormatCopperAsCoinIcons(cost) or tostring(cost)))
                else
                    print("|cffAEE26AEzWoW - Tooltip:|r |cffE77C70" .. resolveExtraLocaleText("autoRepairNoGold") .. "|r")
                end
            end
        end
    end
end

local extraEventsFrame = CreateFrame("Frame")
for _, eventFrame in ipairs({
    "VARIABLES_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "ADDON_LOADED",
    "MERCHANT_SHOW",
    "MERCHANT_CLOSED",
    "AUCTION_HOUSE_SHOW",
    "AUCTION_HOUSE_CLOSED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
    "AUCTION_ITEM_LIST_UPDATE",
    "REPLICATE_ITEM_LIST_UPDATE",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED",
}) do
    pcall(extraEventsFrame.RegisterEvent, extraEventsFrame, eventFrame)
end

extraEventsFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "VARIABLES_LOADED" or event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        AuctionPriceScanner.prepareAuctionStorage()
        addon:UpdateIssueReportState()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.2, function() addon:UpdateIssueReportState() end)
            C_Timer.After(1.0, function() addon:UpdateIssueReportState() end)
        end
    elseif event == "ADDON_LOADED" then
        addon:UpdateIssueReportState()
        if arg1 == "Blizzard_AuctionUI" or arg1 == "Blizzard_AuctionHouseUI" then
            AuctionPriceScanner.prepareAuctionScanButton()
        end
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        AuctionPriceScanner.handleMerchantShow()
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
    elseif event == "AUCTION_HOUSE_SHOW" then
        ahScanState.isOpen = true
        ahScanState.session = ahScanState.session + 1
        ahScanState.waiting = false
        ahScanState.awaitingLegacy = false
        ahScanState.awaitingReplicate = false
        AuctionPriceScanner.prepareAuctionScanButton()
        local iCfg = addon.db and addon.db.item
        if not iCfg or iCfg.showAuctionPrice ~= false then
            local session = ahScanState.session
            if C_Timer and C_Timer.After then
                C_Timer.After(0.2, function()
                    if ahScanState.isOpen and ahScanState.session == session and ahScanState.scannedSession ~= session then
                        addon:BeginAuctionHousePriceScan(true)
                    end
                end)
            else
                addon:BeginAuctionHousePriceScan(true)
            end
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- every row was read and only rows still loading were being retried: keep the prices read
        if ahScanState.scanning and ahScanState.minMap and (ahScanState.total or 0) > 0
            and (ahScanState.index or 1) > ahScanState.total then
            AuctionPriceScanner.finishChunkedScan()
        end
        ahScanState.isOpen = false
        ahScanState.session = ahScanState.session + 1
        ahScanState.scanning = false
        ahScanState.waiting = false
        ahScanState.awaitingLegacy = false
        ahScanState.awaitingReplicate = false
        ahWorkerFrame:Hide()
        AuctionPriceScanner.refreshAhButtonLabel()
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if ahScanState.isOpen and ahScanState.waiting and not ahScanState.scanning and ahScanState.scannedSession ~= ahScanState.session then
            addon:BeginAuctionHousePriceScan(true)
        end
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        local grandTotal = GetNumAuctionItems and GetNumAuctionItems("list") or 0
        if grandTotal > 0 then
            if ahScanState.awaitingLegacy then
                ahScanState.awaitingLegacy = false
                AuctionPriceScanner.startChunkedScan("legacy", grandTotal)
            elseif not ahScanState.scanning and grandTotal <= 100 then
                local announce = ahScanState.autoPageQuery and true or false
                ahScanState.autoPageQuery = false
                AuctionPriceScanner.inspectVisibleLegacyPage(announce)
            end
        end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        local grandTotal = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
        if ahScanState.awaitingReplicate then
            ahScanState.awaitingReplicate = false
            if grandTotal > 0 then
                AuctionPriceScanner.startChunkedScan("replicate", grandTotal)
            else
                AuctionPriceScanner.refreshAhButtonLabel()
            end
        elseif ahScanState.scanning and ahScanState.mode == "replicate" and grandTotal > (ahScanState.total or 0)
            and (ahScanState.index or 1) <= (ahScanState.total or 0) then
            -- more rows arrived while the scan was reading: read them as well
            ahScanState.total = grandTotal
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        AuctionPriceScanner.inspectModernBrowseResults(false)
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local itemID = tonumber(arg1)
        if itemID and itemID > 0 and C_AuctionHouse and C_AuctionHouse.GetNumCommoditySearchResults then
            local numericVal = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
            if numericVal > 0 then
                local apiInfo = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
                if apiInfo and apiInfo.unitPrice and apiInfo.unitPrice > 0 then
                    AuctionPriceScanner.commitSessionMinPrices({ [itemID] = apiInfo.unitPrice })
                end
            end
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        local itemKey = arg1
        local itemID = type(itemKey) == "table" and tonumber(itemKey.itemID)
        if itemID and itemID > 0 and C_AuctionHouse and C_AuctionHouse.GetNumItemSearchResults then
            local numericVal = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
            local minUnit
            for indexEntry = 1, numericVal do
                local apiInfo = C_AuctionHouse.GetItemSearchResultInfo(itemKey, indexEntry)
                -- buyout only: a starting bid is not a price to buy at
                local price = apiInfo and tonumber(apiInfo.buyoutAmount)
                if price and price > 0 and (not minUnit or price < minUnit) then
                    minUnit = price
                end
            end
            if minUnit then
                AuctionPriceScanner.commitSessionMinPrices({ [itemID] = minUnit })
            end
        end
    end
end)
