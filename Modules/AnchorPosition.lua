--===========================================================================
-- EzWoW - Tooltip
-- Modules/AnchorPosition.lua : Dynamic Cursor Follow, Static Anchor & Corner Placement
--===========================================================================
local _, ns = ...
local type, pairs, ipairs, tonumber, tostring, select, pcall = type, pairs, ipairs, tonumber, tostring, select, pcall

local AnchorPlacementEngine = ns.AnchorPlacementEngine or {}
ns.AnchorPlacementEngine = AnchorPlacementEngine
local TooltipEngine = EzWoW_Tooltip
local PlatformBridge = ns.compat
local EventDispatcher = ns.events

local CURSOR_PRESETS = {
    topLeft      = { cp = "BOTTOMRIGHT", cx = -14, cy = 14 },
    topCenter    = { cp = "BOTTOM",      cx = 0,   cy = 22 },
    topRight     = { cp = "BOTTOMLEFT",  cx = 18,  cy = 14 },
    bottomLeft   = { cp = "TOPRIGHT",    cx = -14, cy = -22 },
    bottomCenter = { cp = "TOP",         cx = 0,   cy = -26 },
    bottomRight  = { cp = "TOPLEFT",     cx = 22,  cy = -22 },
}
TooltipEngine.CURSOR_DIRS = CURSOR_PRESETS

local LEGACY_ANCHOR_MAP = {
    BOTTOMRIGHT = "topLeft",
    BOTTOM      = "topCenter",
    BOTTOMLEFT  = "topRight",
    TOPRIGHT    = "bottomLeft",
    TOP         = "bottomCenter",
    TOPLEFT     = "bottomRight",
}

function TooltipEngine.ResolveCursorParams(anchorCfg)
    local dirKey = anchorCfg and anchorCfg.cursorDir
    if not CURSOR_PRESETS[dirKey or ""] then
        if anchorCfg and anchorCfg.position == "cursorRight" then
            dirKey = "bottomRight"
        else
            dirKey = LEGACY_ANCHOR_MAP[anchorCfg and anchorCfg.cp or ""] or "topRight"
        end
    end
    local activeCfg = CURSOR_PRESETS[dirKey]
    return activeCfg.cp, activeCfg.cx, activeCfg.cy, dirKey
end

local CORNER_ANCHOR_MAP = {
    defaultTopLeft     = "TOPLEFT",
    defaultBottomLeft  = "BOTTOMLEFT",
    defaultTopRight    = "TOPRIGHT",
    defaultBottomRight = "BOTTOMRIGHT",
}

local cursorDriver = CreateFrame("Frame")
cursorDriver:Hide()
local activeCursorTarget = nil

-- Near a screen edge the tooltip did not fit on the chosen side; the game then pushed it back onto the screen,
-- over the mouse and the thing pointed at (bag slots at the top of the screen, 2026-11-21). It goes to the other
-- side (above <-> below, right <-> left) when that side has room.
local FLIP_V = { topLeft = "bottomLeft", topCenter = "bottomCenter", topRight = "bottomRight",
                 bottomLeft = "topLeft", bottomCenter = "topCenter", bottomRight = "topRight" }
local FLIP_H = { topLeft = "topRight", topRight = "topLeft", bottomLeft = "bottomRight", bottomRight = "bottomLeft" }

-- current: the side taken for this tooltip while the mouse has not moved; it stays as long as it fits.
-- A tooltip that changed size in its first frames (lines arriving late) jumped from one side of the
-- mouse to the other and back (2026-11-23 dev check: 381 px with the mouse still, 98 times).
-- A new tooltip is often drawn narrow and widens a moment later (lines arriving late); placed beside the
-- mouse by its first width it then no longer fitted and jumped to the other side (2026-11-23 dev check:
-- 268 px). The side for a new placement is picked for at least this width (UI units).
local MIN_SIDE_ROOM = 340
local function fittingDirection(dir, tipFrame, posX, posY, effScale, current)
    if not CURSOR_PRESETS[dir or ""] then return dir end
    local okW, w = pcall(tipFrame.GetWidth, tipFrame)
    local okH, h = pcall(tipFrame.GetHeight, tipFrame)
    if not okW or not okH or PlatformBridge.issecret(w) or PlatformBridge.issecret(h)
        or type(w) ~= "number" or type(h) ~= "number" then
        return dir
    end
    local uiScale = UIParent:GetEffectiveScale()
    local screenW, screenH = UIParent:GetWidth() * uiScale, UIParent:GetHeight() * uiScale
    -- (a kept side is checked by the real width; a new pick by at least MIN_SIDE_ROOM)
    local pickW = math.max(w, MIN_SIDE_ROOM)
    w, h = w * effScale, h * effScale                      -- all in screen pixels, like the cursor
    pickW = pickW * effScale
    local function fitsV(d)
        local y = posY + CURSOR_PRESETS[d].cy * effScale
        if d:find("^top") then return y + h <= screenH end
        return y - h >= 0
    end
    local function fitsH(d, width)
        width = width or w
        local x = posX + CURSOR_PRESETS[d].cx * effScale
        if d:find("Right$") then return x + width <= screenW end
        if d:find("Left$") then return x - width >= 0 end
        return x - width / 2 >= 0 and x + width / 2 <= screenW
    end
    if current and CURSOR_PRESETS[current] and fitsV(current) and fitsH(current) then
        return current
    end
    if not fitsV(dir) and FLIP_V[dir] and fitsV(FLIP_V[dir]) then dir = FLIP_V[dir] end
    if not fitsH(dir, pickW) and FLIP_H[dir] and fitsH(FLIP_H[dir], pickW) then dir = FLIP_H[dir] end
    return dir
end

function AnchorPlacementEngine.refreshCursorTooltipPosition()
    if not activeCursorTarget then return end
    local tipFrame = activeCursorTarget.tip
    local posX, posY = GetCursorPosition()
    local effScale = tipFrame:GetEffectiveScale()
    local stillMouse = activeCursorTarget.lastX == posX and activeCursorTarget.lastY == posY
        and activeCursorTarget.lastScale == effScale
    local dir = fittingDirection(activeCursorTarget.dir, tipFrame, posX, posY, effScale,
        stillMouse and activeCursorTarget.curDir or nil)
    local preset = CURSOR_PRESETS[dir or ""]
    local point = preset and preset.cp or activeCursorTarget.point
    local dx = preset and preset.cx or activeCursorTarget.dx
    local dy = preset and preset.cy or activeCursorTarget.dy
    if activeCursorTarget.lastX == posX and activeCursorTarget.lastY == posY and activeCursorTarget.lastScale == effScale
        and activeCursorTarget.curDir == dir then
        -- the mouse did not move: only when something else re-anchored the tooltip (the game's own refresh of a
        -- button's tooltip) is it put back, so it never jumps between that place and the mouse
        local okP, curPoint, relFrame = pcall(tipFrame.GetPoint, tipFrame, 1)
        if okP and not PlatformBridge.issecret(curPoint) and not PlatformBridge.issecret(relFrame)
            and curPoint == point and relFrame == UIParent then
            return
        end
    end
    activeCursorTarget.lastX, activeCursorTarget.lastY, activeCursorTarget.lastScale = posX, posY, effScale
    activeCursorTarget.curDir = dir
    tipFrame:ClearAllPoints()
    tipFrame:SetPoint(point, UIParent, "BOTTOMLEFT", posX / effScale + dx, posY / effScale + dy)
end

cursorDriver:SetScript("OnUpdate", function()
    if not activeCursorTarget or not activeCursorTarget.tip:IsShown() then
        activeCursorTarget = nil
        cursorDriver:Hide()
        return
    end
    AnchorPlacementEngine.refreshCursorTooltipPosition()
end)

function AnchorPlacementEngine.releaseCursorTracking(tipFrame)
    if activeCursorTarget and (not tipFrame or activeCursorTarget.tip == tipFrame) then
        activeCursorTarget = nil
        cursorDriver:Hide()
    end
end

local internalOwnerLock = false

-- The EzWoW addons' own buttons, bag slots, map marks and windows put their tooltip next to the icon
-- (GameTooltip:SetOwner(self, "ANCHOR_RIGHT") and the like), which passed by the placement rule above
-- (only the game's default anchor goes through it). When the player chose a tooltip that follows the
-- mouse, those tooltips follow it too (2026-11-21). Owners that place the tooltip themselves
-- (ANCHOR_NONE) or already use the cursor are left alone, and so is the gamepad (its cursor jumps).
local CURSOR_MODES = { cursor = true, cursorRight = true }
local function calledByEzWoW()
    if type(debugstack) ~= "function" then return false end
    local ok, stack = pcall(debugstack, 2, 10, 0)
    if not ok or type(stack) ~= "string" then return false end
    for line in stack:gmatch("[^\n]+") do
        -- this file's own frames (the hook and its helpers) are on the stack too
        if line:find("AddOns[\\/]EzWoW%-") and not line:find("AnchorPosition%.lua") then return true end
    end
    return false
end
-- the cursor setting, when it applies to this tooltip now (nil otherwise); anyTip: an EzWoW addon's own
-- tooltip frame asked through TooltipEngine.FollowCursor (else only the game's GameTooltip)
local function cursorSettingFor(tipFrame, ownerFrame, anyTip)
    if (tipFrame ~= GameTooltip and not anyTip) or type(tipFrame) ~= "table" or not TooltipEngine.db then return nil end
    local cfg = TooltipEngine.db.general and TooltipEngine.db.general.anchor
    if type(cfg) ~= "table" or not CURSOR_MODES[cfg.position] then return nil end
    if cfg.returnInCombat and InCombatLockdown() then return nil end
    if type(IsUsingGamepad) == "function" and IsUsingGamepad() then return nil end
    if AnchorPlacementEngine.isFrameForbidden(tipFrame) or AnchorPlacementEngine.isFrameForbidden(ownerFrame) then
        return nil
    end
    return cfg
end

function AnchorPlacementEngine.followCursorForEzWoW(tipFrame, ownerFrame, anchorType)
    -- ANCHOR_NONE: the caller places the tooltip itself (or it is a hidden scanning tooltip). The game's own
    -- cursor anchors (ANCHOR_CURSOR...) are taken over too, so every EzWoW tooltip uses the chosen direction.
    if anchorType == nil or anchorType == "ANCHOR_NONE" or PlatformBridge.issecret(anchorType) then
        return false
    end
    local cfg = cursorSettingFor(tipFrame, ownerFrame)
    if not cfg or not calledByEzWoW() then return false end
    AnchorPlacementEngine.bindTooltipToCursor(tipFrame, ownerFrame, cfg)
    return true
end

-- For the EzWoW addons' own tooltip frames (not GameTooltip): EzWoW_Tooltip.FollowCursor(tip, owner) owns the
-- tooltip and keeps it at the mouse in the chosen direction when the setting follows the mouse; returns false
-- otherwise (the caller then uses its own anchor).
function TooltipEngine.FollowCursor(tipFrame, ownerFrame)
    local cfg = cursorSettingFor(tipFrame, ownerFrame, true)
    if not cfg then return false end
    AnchorPlacementEngine.bindTooltipToCursor(tipFrame, ownerFrame, cfg)
    return true
end

-- EzWoW - Bags' item slots use the game's bag button template: the game places the tooltip beside the slot
-- (ContainerFrameItemButton_CalculateItemTooltipAnchors, on mouse-over and on every tooltip refresh) from its
-- own code, so no EzWoW file is on the stack. Those slots (named EzWoWBagsSlot#) follow the cursor too. The
-- tooltip is already filled here, so only its points move (no SetOwner, which would clear it).
function AnchorPlacementEngine.followCursorKeepContent(tipFrame, ownerFrame)
    local cfg = cursorSettingFor(tipFrame, ownerFrame)
    if not cfg then return false end
    -- the game's code also set an anchor type (ANCHOR_LEFT / RIGHT of the slot): the tooltip goes back to it
    -- whenever its content is laid out again, so the tooltip jumped between the slot and the mouse (seen in a
    -- recording 2026-11-21). Without an anchor type our points stay.
    if type(tipFrame.SetAnchorType) == "function" then pcall(tipFrame.SetAnchorType, tipFrame, "ANCHOR_NONE") end
    local anchorPoint, offsetX, offsetY, dirKey = TooltipEngine.ResolveCursorParams(cfg)
    activeCursorTarget = { tip = tipFrame, point = anchorPoint, dx = offsetX, dy = offsetY, dir = dirKey }
    AnchorPlacementEngine.refreshCursorTooltipPosition()
    cursorDriver:Show()
    return true
end
if type(ContainerFrameItemButton_CalculateItemTooltipAnchors) == "function" then
    hooksecurefunc("ContainerFrameItemButton_CalculateItemTooltipAnchors", function(button, tipFrame)
        if AnchorPlacementEngine.isFrameForbidden(button) then return end
        local ok, name = pcall(button.GetName, button)
        if not ok or type(name) ~= "string" or PlatformBridge.issecret(name) or not name:find("^EzWoWBagsSlot") then return end
        AnchorPlacementEngine.followCursorKeepContent(tipFrame, button)
    end)
end

hooksecurefunc(GameTooltip, "SetOwner", function(tipFrame, ownerFrame, anchorType)
    if not internalOwnerLock then
        AnchorPlacementEngine.releaseCursorTracking(tipFrame)
        AnchorPlacementEngine.followCursorForEzWoW(tipFrame, ownerFrame, anchorType)
    end
end)
EventDispatcher:attachTrigger("tooltip:hide", function(_, tipFrame)
    AnchorPlacementEngine.releaseCursorTracking(tipFrame)
end)

function AnchorPlacementEngine.bindTooltipToCursor(tipFrame, ownerFrame, anchorCfg)
    local anchorPoint, offsetX, offsetY, dirKey = TooltipEngine.ResolveCursorParams(anchorCfg)
    internalOwnerLock = true
    tipFrame:SetOwner(ownerFrame or UIParent, "ANCHOR_NONE")
    internalOwnerLock = false
    activeCursorTarget = { tip = tipFrame, point = anchorPoint, dx = offsetX, dy = offsetY, dir = dirKey }
    AnchorPlacementEngine.refreshCursorTooltipPosition()
    cursorDriver:Show()
end

function AnchorPlacementEngine.commitStaticPlacement(tipFrame, anchorCfg)
    local anchorPoint = anchorCfg.p or "BOTTOMRIGHT"
    local posXEntry = tonumber(anchorCfg.x) or -((_G.CONTAINER_OFFSET_X or 0) + 13)
    local posYEntry = tonumber(anchorCfg.y) or (_G.CONTAINER_OFFSET_Y or 0)
    tipFrame:ClearAllPoints()
    tipFrame:SetPoint(anchorPoint, UIParent, anchorPoint, posXEntry, posYEntry)
end

function AnchorPlacementEngine.commitCornerPin(tipFrame, cornerPt)
    local _, relFrame = tipFrame:GetPoint(1)
    if PlatformBridge.issecret(relFrame) then return end
    relFrame = relFrame or _G.GameTooltipDefaultContainer or UIParent
    tipFrame:ClearAllPoints()
    tipFrame:SetPoint(cornerPt, relFrame, cornerPt, 0, 0)
end

local dismissInCombatActive = false
EventDispatcher:attachTrigger("tooltip:show", function(_, tipFrame)
    if dismissInCombatActive and tipFrame == GameTooltip then
        tipFrame:Hide()
    end
end)
EventDispatcher:attachTrigger("tooltip:hide", function(_, tipFrame)
    if tipFrame == GameTooltip then
        dismissInCombatActive = false
    end
end)

function AnchorPlacementEngine.determineHoveredUnitContext()
    local focusFrame = PlatformBridge.GetMouseFocus()
    local unitToken, hasUnitFrame
    if focusFrame and focusFrame.unit then
        unitToken, hasUnitFrame = focusFrame.unit, true
    elseif focusFrame and focusFrame.GetAttribute then
        unitToken = focusFrame:GetAttribute("unit")
    end
    if not unitToken or PlatformBridge.issecret(unitToken) then
        unitToken = "mouseover"
    end
    return unitToken, hasUnitFrame
end

function AnchorPlacementEngine.commitAnchorRule(tipFrame, ownerFrame, anchorCfg, hasUnitFrame, isFallbackPass)
    if not anchorCfg then return end
    local combatActive = InCombatLockdown()
    if anchorCfg.hiddenInCombat and combatActive then
        dismissInCombatActive = true
        tipFrame:Hide()
        return
    end
    if (anchorCfg.returnInCombat and combatActive) or (anchorCfg.returnOnUnitFrame and hasUnitFrame) then
        return
    end
    local posMode = anchorCfg.position
    if posMode == "inherit" then
        if not isFallbackPass then
            AnchorPlacementEngine.commitAnchorRule(tipFrame, ownerFrame, TooltipEngine.db.general.anchor, hasUnitFrame, true)
        end
    elseif posMode == "cursor" or posMode == "cursorRight" then
        AnchorPlacementEngine.bindTooltipToCursor(tipFrame, ownerFrame, anchorCfg)
    elseif posMode == "static" then
        AnchorPlacementEngine.commitStaticPlacement(tipFrame, anchorCfg)
    elseif CORNER_ANCHOR_MAP[posMode] then
        AnchorPlacementEngine.commitCornerPin(tipFrame, CORNER_ANCHOR_MAP[posMode])
    end
end

function TooltipEngine:PositionTooltip(tipFrame, ownerFrame)
    if tipFrame ~= GameTooltip or not self.db then return end
    AnchorPlacementEngine.releaseCursorTracking(tipFrame)
    dismissInCombatActive = false
    local unitToken, hasUnitFrame = AnchorPlacementEngine.determineHoveredUnitContext()
    local unitCfg = self.db.unit
    if PlatformBridge.nosecret(UnitIsPlayer(unitToken)) then
        AnchorPlacementEngine.commitAnchorRule(tipFrame, ownerFrame, unitCfg.player.anchor, hasUnitFrame, false)
    elseif PlatformBridge.nosecret(UnitExists(unitToken)) then
        AnchorPlacementEngine.commitAnchorRule(tipFrame, ownerFrame, unitCfg.npc.anchor, hasUnitFrame, false)
    else
        AnchorPlacementEngine.commitAnchorRule(tipFrame, ownerFrame, self.db.general.anchor, hasUnitFrame, true)
    end
end

-- Forbidden frames (e.g. nameplate aura buttons) also pass through the default
-- anchor; nothing can be anchored to them and SetOwner from our hook would error,
-- so such owners (and forbidden tooltips) are left to the default placement.
-- IsForbidden is the only method that is safe to call on a forbidden frame.
function AnchorPlacementEngine.isFrameForbidden(frameObj)
    if frameObj == nil then return false end
    if PlatformBridge.issecret(frameObj) or type(frameObj) ~= "table" then return true end
    local isForbiddenFn = frameObj.IsForbidden
    if type(isForbiddenFn) ~= "function" then return false end
    local isCallOk, isForbidden = pcall(isForbiddenFn, frameObj)
    return (not isCallOk) or PlatformBridge.issecret(isForbidden) or isForbidden == true
end

hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tipFrame, ownerFrame)
    if AnchorPlacementEngine.isFrameForbidden(tipFrame) or AnchorPlacementEngine.isFrameForbidden(ownerFrame) then
        return
    end
    TooltipEngine:PositionTooltip(tipFrame, ownerFrame)
    EventDispatcher:trigger("tooltip:anchor", tipFrame, ownerFrame)
end)

-----------------------------------------------------------------------------
-- Mouse moved out of the game window: the game keeps the cursor's last place,
-- so the frame under it never gets OnLeave and its tooltip stays. A cursor
-- that leaves the window was moving fast and then stops dead (the game no
-- longer gets its moves); a hand that stops slows down first (measured in the
-- game: about 60-90 per second at a stop, 2,000 and more when leaving). Fast,
-- then still for a moment: the tooltips are closed. Not while turning the
-- camera, and not with a gamepad (its cursor jumps between buttons).
-----------------------------------------------------------------------------
do
    local LEAVE_SPEED = 1000    -- cursor units per second (the screen is 768 high in them)
    local STILL_TIME = 0.3      -- seconds without a move
    local lastX, lastY
    local speed, sinceMove, done = 0, 0, false

    local function closeTooltips()
        local g = TooltipEngine.db and TooltipEngine.db.general
        if g and g.closeOnWindowLeave == false then return end
        if type(IsMouselooking) == "function" and IsMouselooking() then return end
        if type(IsUsingGamepad) == "function" and IsUsingGamepad() then return end
        if GameTooltip and GameTooltip:IsShown() and not AnchorPlacementEngine.isFrameForbidden(GameTooltip) then
            -- a new owner first: buttons that redraw their own tooltip while
            -- they own it (action buttons, bag slots) don't bring it back
            pcall(GameTooltip.SetOwner, GameTooltip, UIParent, "ANCHOR_NONE")
            GameTooltip:Hide()
        end
        for _, tip in ipairs({ _G.ShoppingTooltip1, _G.ShoppingTooltip2 }) do
            if tip and tip:IsShown() then tip:Hide() end
        end
    end

    local watcher = CreateFrame("Frame")
    watcher:SetScript("OnUpdate", function(_, elapsed)
        local x, y = GetCursorPosition()
        if type(x) ~= "number" or type(y) ~= "number" or PlatformBridge.issecret(x) or PlatformBridge.issecret(y) then return end
        sinceMove = sinceMove + (elapsed or 0)
        if x ~= lastX or y ~= lastY then
            if lastX then
                local dx, dy = x - lastX, y - lastY
                speed = math.sqrt(dx * dx + dy * dy) / math.max(sinceMove, 0.001)
            end
            lastX, lastY, sinceMove, done = x, y, 0, false
            return
        end
        if done or sinceMove < STILL_TIME then return end
        done = true
        if speed >= LEAVE_SPEED then pcall(closeTooltips) end
    end)
end

-----------------------------------------------------------------------------
-- Show delay: a tooltip comes up only after the mouse has rested on a thing
-- for general.hoverDelay seconds (2026-11-24, user: 0.25 s, every tooltip in the
-- game). The game fills its tooltip the moment the mouse arrives; it stays
-- invisible (alpha 0) until the delay is over, with its comparison tooltips,
-- and this addon's lines go on only then (EventDispatcher.holdSignal). Those
-- lines are the costly part: a piece of gear took 13 ms without them and
-- 65-75 ms with them on the tooltip and its comparisons, so a mouse sweeping
-- over a bag or a bar of icons dropped frame after frame.
-- The same thing filled again (bag slots and action buttons redraw their
-- tooltip while the mouse is on them) keeps its wait, or stays shown.
-----------------------------------------------------------------------------
do
    local REFILL_GAP = 0.25        -- hidden and filled again for the same owner within this: a refill
    local wait = nil               -- { owner = frame, since = time } while the tooltip waits
    local shownOwner, hiddenAt = nil, 0
    local skipOwner = nil
    local held = {}                -- tooltip -> { { signal, count, args... }, ... } (latest per signal)
    local driver = CreateFrame("Frame")
    driver:Hide()

    local function delayTips()
        return GameTooltip, _G.ShoppingTooltip1, _G.ShoppingTooltip2
    end
    local function isDelayTip(tipFrame)
        local a, b, c = delayTips()
        return tipFrame ~= nil and (tipFrame == a or tipFrame == b or tipFrame == c)
    end

    -- seconds (0: tooltips show at once)
    function TooltipEngine.ShowDelay()
        local g = TooltipEngine.db and TooltipEngine.db.general
        local d = g and tonumber(g.hoverDelay)
        if not d or d <= 0 then return 0 end
        return math.min(d, 2)
    end
    -- An addon that already waited for the mouse to rest (EzWoW - Utility Bar) shows the next tooltip of
    -- this owner at once.
    function TooltipEngine.ShowNextWithoutDelay(ownerFrame)
        skipOwner = ownerFrame
    end
    -- true while the tooltip is filled but not shown yet (the dev check counts from the moment it shows)
    function TooltipEngine.IsTooltipWaiting(tipFrame)
        return wait ~= nil and isDelayTip(tipFrame or GameTooltip)
    end

    local function setAlpha(alpha)
        for _, tipFrame in ipairs({ delayTips() }) do
            if tipFrame and not AnchorPlacementEngine.isFrameForbidden(tipFrame) then
                local okA, cur = pcall(tipFrame.GetAlpha, tipFrame)
                if not okA or PlatformBridge.issecret(cur) or cur ~= alpha then pcall(tipFrame.SetAlpha, tipFrame, alpha) end
            end
        end
    end

    local function release()
        wait = nil
        driver:Hide()
        setAlpha(1)
    end

    function AnchorPlacementEngine.revealWaitingTooltip()
        if not wait then return end
        local owner = wait.owner
        release()
        shownOwner = owner
        local list = {}
        for _, tipFrame in ipairs({ delayTips() }) do
            if tipFrame and held[tipFrame] and tipFrame:IsShown() then list[#list + 1] = { tipFrame, held[tipFrame] } end
        end
        wipe(held)
        for _, entry in ipairs(list) do
            for _, rec in ipairs(entry[2]) do
                pcall(EventDispatcher.trigger, EventDispatcher, rec[1], unpack(rec, 3, rec[2] + 2))
            end
        end
    end

    -- EventDispatcher:trigger asks here for the info signals (tooltip:item / spell / unit)
    EventDispatcher.holdSignal = function(signalName, tipFrame, ...)
        if not wait or not isDelayTip(tipFrame) then return false end
        local list = held[tipFrame]
        if not list then
            list = {}
            held[tipFrame] = list
        end
        local rec = { signalName, select("#", ...) + 1, tipFrame, ... }
        for index, old in ipairs(list) do
            if old[1] == signalName then
                list[index] = rec
                return true
            end
        end
        list[#list + 1] = rec
        return true
    end

    hooksecurefunc(GameTooltip, "SetOwner", function(tipFrame, ownerFrame)
        if internalOwnerLock then return end
        local delay = TooltipEngine.ShowDelay()
        if delay <= 0 or AnchorPlacementEngine.isFrameForbidden(tipFrame) or AnchorPlacementEngine.isFrameForbidden(ownerFrame) then
            if wait then release() end
            return
        end
        if ownerFrame ~= nil and ownerFrame == skipOwner then
            skipOwner = nil
            if wait then release() end
            shownOwner = ownerFrame
            return
        end
        local now = GetTime()
        local refill = ownerFrame ~= nil and (tipFrame:IsShown() or now - hiddenAt < REFILL_GAP)
        if refill and wait and wait.owner == ownerFrame then return end      -- still waiting: same wait
        if refill and not wait and shownOwner == ownerFrame then return end  -- already shown: stays
        wait = { owner = ownerFrame, since = now }
        shownOwner = nil
        setAlpha(0)
        driver:Show()
    end)

    for _, tipFrame in ipairs({ delayTips() }) do
        if tipFrame then
            -- a fill of the tooltip from the game's code may show it with full alpha
            if type(tipFrame.Show) == "function" then
                hooksecurefunc(tipFrame, "Show", function(self)
                    if wait then pcall(self.SetAlpha, self, 0) end
                end)
            end
            if tipFrame.HasScript and tipFrame.HookScript and tipFrame:HasScript("OnTooltipCleared") then
                tipFrame:HookScript("OnTooltipCleared", function(self) held[self] = nil end)
            end
        end
    end
    if GameTooltip.HookScript then
        GameTooltip:HookScript("OnHide", function()
            hiddenAt = GetTime()
        end)
    end

    driver:SetScript("OnUpdate", function()
        if not wait then
            driver:Hide()
            return
        end
        if not GameTooltip:IsShown() then
            -- gone (not a refill of the same owner): the wait ends
            if GetTime() - hiddenAt >= REFILL_GAP then
                release()
                wipe(held)
            end
            return
        end
        setAlpha(0)
        if GetTime() - wait.since >= TooltipEngine.ShowDelay() then
            AnchorPlacementEngine.revealWaitingTooltip()
        end
    end)
end
