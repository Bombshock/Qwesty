local ADDON_NAME = "Qwesty"
local enabled = true
local debug   = false

-- Default blacklist entries applied on first install (or when the user has no saved preference).
-- Users can override these via the gossip checkbox; their choice is persisted in SavedVariables.
local defaultBlacklist = {
    [243907] = "Decimus",  -- weekly/daily quest vendor, player must choose
}

-- Runtime blacklist: truthy value = blocked, false = user explicitly unblocked a default.
local blacklist = {}

-- Cached NPC info set during GOSSIP_SHOW (non-tainted context) so OnShow hooks
-- can read it safely without calling UnitGUID during secure UI execution.
local cachedNpcId, cachedNpcName

local function GetCurrentNPC()
    local ok, guid = pcall(UnitGUID, "npc")
    if not ok or not guid then return nil, nil end
    local ok2, result = pcall(strmatch, guid, "Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    if not ok2 then return nil, nil end
    local npcId = tonumber(result)
    local ok3, name = pcall(UnitName, "npc")
    return npcId, ok3 and name or nil
end

local function IsBlacklisted(npcId)
    -- false means the user explicitly unblocked a default; nil/name means blocked.
    return npcId and blacklist[npcId] ~= nil and blacklist[npcId] ~= false
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFD700[Qwesty]|r " .. msg)
end

local function DBG(msg)
    if not debug then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cffFFD700[Qwesty]|r |cff888888[DBG]|r " .. msg)
end

-- -- Minimap button ----------------------------------------------------------

local ICON = "Interface\\GossipFrame\\ActiveQuestIcon"  -- yellow question mark

local minimapButton = CreateFrame("Button", "QwestyMinimapButton", Minimap)
minimapButton:SetSize(32, 32)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)

-- Circular mask so it looks like a standard minimap icon
local mask = minimapButton:CreateMaskTexture()
mask:SetAllPoints()
mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")

local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
icon:SetAllPoints()
icon:SetTexture(ICON)
icon:AddMaskTexture(mask)
minimapButton.icon = icon

-- Highlight ring
local hl = minimapButton:CreateTexture(nil, "HIGHLIGHT")
hl:SetAllPoints()
hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

-- Border ring
local border = minimapButton:CreateTexture(nil, "OVERLAY")
border:SetSize(54, 54)
border:SetPoint("CENTER")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function UpdateMinimapIcon()
    if enabled then
        icon:SetDesaturated(false)
        icon:SetVertexColor(1, 1, 1)
    else
        icon:SetDesaturated(true)
        icon:SetVertexColor(0.35, 0.35, 0.35)
    end
end

-- Position the button around the minimap edge.
-- `angle` is stored in SavedVariables-style via a simple upvalue so it
-- persists only for the session (full persistence would need SavedVariables).
local minimapAngle = 195  -- degrees; 0 = right, clockwise

local function RepositionMinimapButton()
    local rad    = math.rad(minimapAngle)
    local radius = 80  -- distance from minimap center to button center
    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(rad) * radius, math.sin(rad) * radius)
end

RepositionMinimapButton()

-- Drag to reposition around the minimap ring
minimapButton:SetMovable(false)
minimapButton:RegisterForDrag("LeftButton")

minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local cx, cy   = Minimap:GetCenter()
        local mx, my   = GetCursorPosition()
        local scale    = Minimap:GetEffectiveScale()
        mx, my         = mx / scale, my / scale
        minimapAngle   = math.deg(math.atan2(my - cy, mx - cx))
        RepositionMinimapButton()
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

-- Tooltip
local function UpdateMinimapTooltip()
    GameTooltip:SetOwner(minimapButton, "ANCHOR_LEFT")
    GameTooltip:SetText("Qwesty", 1, 1, 0)
    GameTooltip:AddLine(enabled and "|cff00FF00Enabled|r" or "|cffFF4444Disabled|r")
    GameTooltip:AddLine("|cffAAAAAALeft-click|r to toggle", 1, 1, 1)
    GameTooltip:AddLine("|cffAAAAAARight-click|r for options", 1, 1, 1)
    GameTooltip:AddLine("|cffAAAAAADrag|r to reposition", 1, 1, 1)
    GameTooltip:Show()
end

minimapButton:SetScript("OnEnter", function(self)
    UpdateMinimapTooltip()
end)

-- Right-click dropdown menu
local minimapDropdown = CreateFrame("Frame", "QwestyMinimapDropdown", UIParent, "UIDropDownMenuTemplate")
local function BuildMinimapMenu()
    local info = UIDropDownMenu_CreateInfo()

    info.text         = "Debug Log"
    info.checked      = debug
    info.isNotRadio   = true
    info.func         = function(_, _, _, checked)
        debug = not checked
        QwestySavedVars = QwestySavedVars or {}
        QwestySavedVars.debug = debug
        Print("Debug log " .. (debug and "|cff00FF00ON|r" or "|cffAAAAAAdisabled|r") .. ".")
    end
    UIDropDownMenu_AddButton(info)
end

-- Click to toggle / right-click for options
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapButton:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        UIDropDownMenu_Initialize(minimapDropdown, BuildMinimapMenu, "MENU")
        ToggleDropDownMenu(1, nil, minimapDropdown, self, 0, 0)
    else
        enabled = not enabled
        UpdateMinimapIcon()
        Print(enabled and "Enabled." or "Disabled.")
        if GameTooltip:GetOwner() == minimapButton then
            UpdateMinimapTooltip()
        end
    end
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- -- End minimap button ------------------------------------------------------

local GOSSIP_FLAG_LABELS = {
    [0] = "dialog",
    [1] = "quest",
}

-- Keywords (lowercase) that identify a "skip content" dialog option.
local SKIP_KEYWORDS = { "skip", "überspring" }

local function IsSkipOption(opt)
    local lower = string.lower(tostring(opt.name))
    for _, kw in ipairs(SKIP_KEYWORDS) do
        if string.find(lower, kw, 1, true) then
            return true
        end
    end
    return false
end

-- GOSSIP_SHOW: auto-proceed only when there is exactly one option and it is not a player choice.
local function HandleGossipShow(suppressed)
    local options         = C_GossipInfo.GetOptions()
    local activeQuests    = C_GossipInfo.GetActiveQuests()
    local availableQuests = C_GossipInfo.GetAvailableQuests()

    -- Pre-compute counts used for both debug and logic.
    local questOptions, dialogOptions, skipOptions = {}, {}, {}
    for _, opt in ipairs(options) do
        if opt.flags == 1 then
            questOptions[#questOptions + 1] = opt
        elseif IsSkipOption(opt) then
            skipOptions[#skipOptions + 1] = opt
        else
            dialogOptions[#dialogOptions + 1] = opt
        end
    end

    local completeQuests, incompleteQuests = {}, {}
    for _, q in ipairs(activeQuests) do
        if q.isComplete then
            completeQuests[#completeQuests + 1] = q
        else
            incompleteQuests[#incompleteQuests + 1] = q
        end
    end

    local npcId, npcName = GetCurrentNPC()
    cachedNpcId, cachedNpcName = npcId, npcName

    if debug then
        DBG("|cffFFFFFFGOSSIP_SHOW|r ----------------------------")
        local npcTag = npcId
            and string.format("  NPC: |cffFFFFFF%s|r (id=%d)%s", tostring(npcName), npcId,
                IsBlacklisted(npcId) and " |cffFF4444[BLACKLISTED]|r" or "")
            or  "  NPC: unknown"
        DBG(npcTag)
        DBG(string.format("  State:  addon=%s  shift=%s",
            enabled and "|cff00FF00ON|r" or "|cffFF4444OFF|r",
            tostring(IsShiftKeyDown())))
        DBG(string.format("  Summary: %d dialog opt  %d quest opt  %d skip opt  |  %d available quest  %d complete  %d in-progress",
            #dialogOptions, #questOptions, #skipOptions,
            #availableQuests, #completeQuests, #incompleteQuests))

        if #options > 0 then
            DBG("  Gossip options:")
            for i, opt in ipairs(options) do
                local flagLabel = opt.flags == 1 and "quest"
                    or IsSkipOption(opt) and "skip"
                    or "dialog"
                DBG(string.format("    [%d] id=%-8s  %-8s  \"%s\"",
                    i, tostring(opt.gossipOptionID), flagLabel, tostring(opt.name)))
            end
        end

        if #availableQuests > 0 then
            DBG("  Available quests (can pick up):")
            for i, q in ipairs(availableQuests) do
                DBG(string.format("    [%d] id=%-8s  \"%s\"", i, tostring(q.questID), tostring(q.title)))
            end
        end

        if #activeQuests > 0 then
            DBG("  Active quests:")
            for i, q in ipairs(activeQuests) do
                local status = q.isComplete and "|cff00FF00ready to turn in|r" or "|cffAAAAAA in progress|r"
                DBG(string.format("    [%d] id=%-8s  %s  \"%s\"",
                    i, tostring(q.questID), status, tostring(q.title)))
            end
        end
    end

    if IsBlacklisted(npcId) then
        DBG("  -> |cffFF4444SKIP|r: NPC " .. tostring(npcId) .. " is blacklisted")
        return
    end

    local suppTag = suppressed and " |cffFF8800[suppressed]|r" or ""

    -- Collect only quest-related gossip options (flags==1).
    -- Plain dialog options (flags==0) are never auto-selected.
    local questGossipOptions = {}
    for _, opt in ipairs(options) do
        if opt.flags == 1 then
            questGossipOptions[#questGossipOptions + 1] = opt
        end
    end

    -- Priority 1: skip options.
    if #skipOptions == 1 then
        local opt = skipOptions[1]
        DBG("  -> |cff00FF00AUTO|r: skip option (id=" .. tostring(opt.gossipOptionID) .. ") \"" .. tostring(opt.name) .. "\"" .. suppTag)
        if not suppressed then C_GossipInfo.SelectOption(opt.gossipOptionID) end
        return
    elseif #skipOptions > 1 then
        DBG("  -> |cffFF8800SKIP|r: " .. #skipOptions .. " skip options -player must choose")
        return
    end

    -- Priority 2: quest gossip options (flags==1).
    if #questGossipOptions > 1 then
        DBG("  -> |cffFF8800SKIP|r: " .. #questGossipOptions .. " quest gossip options -player must choose")
        return
    end

    if #questGossipOptions == 1 then
        local opt = questGossipOptions[1]
        DBG(string.format("  -> |cff00FF00AUTO|r: single quest option (id=%s) \"%s\"%s",
            tostring(opt.gossipOptionID), tostring(opt.name), suppTag))
        if not suppressed then C_GossipInfo.SelectOption(opt.gossipOptionID) end
        return
    end

    if #dialogOptions > 0 then
        DBG("  -> |cffAAAAAASKIP|r: " .. #dialogOptions .. " dialog option(s) ignored -not quest-related")
    end

    -- No quest gossip options -handle quest links directly.
    if #availableQuests > 1 then
        DBG("  -> |cffFF8800SKIP|r: " .. #availableQuests .. " available quests -player must choose")
        return
    end

    if #availableQuests == 1 then
        DBG("  -> |cff00FF00AUTO|r: 1 available quest (id=" .. tostring(availableQuests[1].questID) .. ") -selecting" .. suppTag)
        if not suppressed then C_GossipInfo.SelectAvailableQuest(availableQuests[1].questID) end
        return
    end

    if #completeQuests >= 1 then
        local q = completeQuests[1]
        DBG("  -> |cff00FF00AUTO|r: turning in quest (id=" .. tostring(q.questID) .. ") \"" .. tostring(q.title) .. "\"" ..
            (#completeQuests > 1 and " (" .. #completeQuests .. " complete, doing one at a time)" or "") .. suppTag)
        if not suppressed then C_GossipInfo.SelectActiveQuest(q.questID) end
        return
    end

    DBG("  -> |cffAAAAAASKIP|r: nothing actionable (all active quests still in progress)")
end

-- QUEST_GREETING fires when an NPC has a dedicated quest-only dialog (no gossip).
local function HandleQuestGreeting(suppressed)
    local numAvailable = GetNumAvailableQuests()
    local numActive    = GetNumActiveQuests()

    if debug then
        DBG("|cffFFFFFFQUEST_GREETING|r --------------------------")
        local npcTag = cachedNpcId
            and string.format("  NPC: |cffFFFFFF%s|r (id=%d)%s", tostring(cachedNpcName), cachedNpcId,
                IsBlacklisted(cachedNpcId) and " |cffFF4444[BLACKLISTED]|r" or "")
            or  "  NPC: unknown"
        DBG(npcTag)
        DBG("  available=" .. numAvailable .. "  active=" .. numActive)
        for i = 1, numAvailable do
            DBG(string.format("  available[%d] \"%s\"", i, tostring(GetAvailableQuestInfo(i))))
        end
        for i = 1, numActive do
            DBG(string.format("  active[%d] \"%s\"", i, tostring(GetActiveTitle(i))))
        end
    end

    if IsBlacklisted(cachedNpcId) then
        DBG("  -> |cffFF4444SKIP|r: NPC " .. tostring(cachedNpcId) .. " is blacklisted")
        return
    end

    local suppTag = suppressed and " |cffFF8800[suppressed]|r" or ""

    if numAvailable == 1 then
        DBG("  -> |cff00FF00AUTO|r: single available quest" .. suppTag)
        if not suppressed then SelectAvailableQuest(1) end
        return
    end

    if numAvailable > 1 then
        DBG("  -> |cffFF8800SKIP|r: " .. numAvailable .. " available quests -player must choose")
        return
    end

    if numActive == 1 then
        DBG("  -> |cff00FF00AUTO|r: single active quest" .. suppTag)
        if not suppressed then SelectActiveQuest(1) end
        return
    end

    DBG("  -> |cffFF8800SKIP|r: " .. numActive .. " active quests -player must choose")
end

-- -- Gossip frame checkbox ---------------------------------------------------

local gossipCheckbox = CreateFrame("CheckButton", "QwestyGossipCheckbox", GossipFrame, "UICheckButtonTemplate")
gossipCheckbox:SetSize(20, 20)
gossipCheckbox:SetPoint("BOTTOMLEFT", GossipFrame, "BOTTOMLEFT", 6, 4)

local gossipCheckLabel = gossipCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
gossipCheckLabel:SetPoint("LEFT", gossipCheckbox, "RIGHT", 4, 0)
gossipCheckLabel:SetText("Qwesty: Ignored")

local function SaveBlacklist()
    QwestySavedVars = QwestySavedVars or {}
    local saved = {}
    for id, value in pairs(blacklist) do
        -- Save name (blocked), false (user-unblocked default), skip nil.
        if value ~= nil then
            -- Only persist non-default entries and explicit overrides of defaults.
            if defaultBlacklist[id] == nil or value == false then
                saved[id] = value
            elseif value ~= defaultBlacklist[id] then
                saved[id] = value  -- user renamed or re-added a default
            end
            -- If value matches the default name exactly, no need to persist it.
        end
    end
    QwestySavedVars.blacklist = saved
end

GossipFrame:HookScript("OnShow", function()
    gossipCheckbox:SetChecked(IsBlacklisted(cachedNpcId))
end)

gossipCheckbox:SetScript("OnClick", function(self)
    local npcId, npcName = GetCurrentNPC()
    if not npcId then
        self:SetChecked(false)
        return
    end
    if self:GetChecked() then
        blacklist[npcId] = npcName or "Unknown"
        SaveBlacklist()
        Print("Blacklisted: |cffFFFFFF" .. tostring(npcName) .. "|r (id=" .. npcId .. ")")
    else
        -- false signals "user explicitly unblocked" so defaults don't re-apply on next login.
        blacklist[npcId] = defaultBlacklist[npcId] and false or nil
        SaveBlacklist()
        Print("Removed from blacklist: |cffFFFFFF" .. tostring(npcName) .. "|r (id=" .. npcId .. ")")
    end
end)

-- -- End gossip frame checkbox ------------------------------------------------

-- QUEST_COMPLETE fires when the reward screen opens.
local function HandleQuestComplete(suppressed)
    local rewardCount = GetNumQuestChoices()

    if debug then
        DBG("|cffFFFFFFQUEST_COMPLETE|r --------------------------")
        DBG("  reward choices=" .. rewardCount)
        for i = 1, rewardCount do
            local name, _, _, quality = GetQuestItemInfo("choice", i)
            DBG(string.format("  reward[%d] \"%s\"  quality=%s", i, tostring(name), tostring(quality)))
        end
    end

    local suppTag = suppressed and " |cffFF8800[suppressed]|r" or ""

    if rewardCount <= 1 then
        DBG("  -> |cff00FF00AUTO|r: 0-1 rewards, completing quest" .. suppTag)
        if not suppressed then GetQuestReward(1) end
    else
        DBG("  -> |cffFF8800SKIP|r: " .. rewardCount .. " rewards -player must choose")
    end
end

local frame = CreateFrame("Frame")

frame:RegisterEvent("GOSSIP_SHOW")
frame:RegisterEvent("QUEST_GREETING")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("QUEST_PROGRESS")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_TARGET_CHANGED" then
        -- Update NPC cache in a non-tainted context so QUEST_DETAIL/QUEST_GREETING
        -- can safely check the blacklist without calling UnitGUID themselves.
        local npcId, npcName = GetCurrentNPC()
        if npcId then
            cachedNpcId, cachedNpcName = npcId, npcName
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        QwestySavedVars = QwestySavedVars or {}
        if QwestySavedVars.debug ~= nil then debug = QwestySavedVars.debug end
        local saved = QwestySavedVars.blacklist or {}
        -- Apply defaults first, then let saved preferences override them.
        -- saved[id] = false means the user explicitly unblocked a default.
        for id, name in pairs(defaultBlacklist) do
            if saved[id] == nil then
                blacklist[id] = name
            else
                blacklist[id] = saved[id]  -- may be false (unblocked) or a name (user-added)
            end
        end
        for id, value in pairs(saved) do
            if defaultBlacklist[id] == nil then
                blacklist[id] = value
            end
        end
        UpdateMinimapIcon()
        Print("Loaded. Type /qwesty on|off|debug to toggle.")
        return
    end

    local shiftHeld = IsShiftKeyDown()

    if debug and event ~= "PLAYER_LOGIN" then
        DBG("Event: |cffFFFFFF" .. event .. "|r" ..
            (shiftHeld and "  |cffFF8800[shift -suppressed]|r" or "") ..
            (not enabled and "  |cffFF4444[addon OFF -suppressed]|r" or ""))
    end

    local suppressed = not enabled or shiftHeld

    -- Always run handlers in debug mode so the full state is logged;
    -- the handlers themselves will not fire any WoW API actions when suppressed.
    if event == "GOSSIP_SHOW" then
        HandleGossipShow(suppressed)
    elseif event == "QUEST_GREETING" then
        HandleQuestGreeting(suppressed)
    elseif event == "QUEST_DETAIL" then
        if IsBlacklisted(cachedNpcId) then
            DBG("QUEST_DETAIL -> |cffFF4444SKIP|r: NPC " .. tostring(cachedNpcId) .. " is blacklisted")
        elseif suppressed then
            DBG("QUEST_DETAIL -> |cffFF8800SUPPRESSED|r")
        else
            DBG("QUEST_DETAIL -> |cff00FF00AUTO|r: accepting quest")
            AcceptQuest()
        end
    elseif event == "QUEST_PROGRESS" then
        if suppressed then
            DBG("QUEST_PROGRESS -> |cffFF8800SUPPRESSED|r")
        else
            DBG("QUEST_PROGRESS -> |cff00FF00AUTO|r: completing quest progress")
            CompleteQuest()
        end
    elseif event == "QUEST_COMPLETE" then
        HandleQuestComplete(suppressed)
    end
end)

SLASH_QWESTY1 = "/qwesty"
SLASH_QWESTY2 = "/qw"

SlashCmdList["QWESTY"] = function(msg)
    msg = string.lower(string.match(msg, "^%s*(.-)%s*$"))
    if msg == "on" then
        enabled = true
        UpdateMinimapIcon()
        Print("Enabled.")
    elseif msg == "off" then
        enabled = false
        UpdateMinimapIcon()
        Print("Disabled.")
    elseif msg == "debug" then
        debug = not debug
        QwestySavedVars = QwestySavedVars or {}
        QwestySavedVars.debug = debug
        Print("Debug log " .. (debug and "|cff00FF00ON|r" or "|cffAAAAAAdisabled|r") .. ".")
    elseif msg == "block" then
        local npcId, npcName = GetCurrentNPC()
        if not npcId then
            Print("No NPC targeted. Talk to an NPC first.")
        elseif blacklist[npcId] then
            Print("NPC already blacklisted: |cffFFFFFF" .. tostring(npcName) .. "|r (id=" .. npcId .. ")")
        else
            blacklist[npcId] = npcName or "Unknown"
            SaveBlacklist()
            Print("Blacklisted: |cffFFFFFF" .. tostring(npcName) .. "|r (id=" .. npcId .. ")")
        end
    elseif msg == "unblock" then
        local npcId, npcName = GetCurrentNPC()
        if not npcId then
            Print("No NPC targeted. Talk to an NPC first.")
        elseif not blacklist[npcId] then
            Print("NPC not in blacklist: |cffFFFFFF" .. tostring(npcName) .. "|r (id=" .. npcId .. ")")
        else
            blacklist[npcId] = defaultBlacklist[npcId] and false or nil
            SaveBlacklist()
            Print("Removed from blacklist: |cffFFFFFF" .. tostring(npcName) .. "|r (id=" .. npcId .. ")")
        end
    elseif msg == "blocklist" then
        local count = 0
        for id, name in pairs(blacklist) do
            Print("  [" .. id .. "] " .. tostring(name))
            count = count + 1
        end
        if count == 0 then
            Print("Blacklist is empty.")
        else
            Print(count .. " blacklisted NPC(s) total.")
        end
    else
        Print("Status: " .. (enabled and "|cff00FF00enabled|r" or "|cffFF4444disabled|r") ..
              "  |cffAAAAAAdebug=" .. tostring(debug) .. "|r" ..
              "  - /qwesty on|off|debug|block|unblock|blocklist")
    end
end
