local ADDON_NAME = ...

local AGRO = CreateFrame("Frame", "AGROFrame")
AGRO.name = "AGRO"

local L = AGRO_L or {}

local DEFAULT_DB = {
    enabled = true,
    output = "local",
    threshold = 90,
    resetThreshold = 75,
    globalCooldown = 8,
    playerCooldown = 30,
    requireTankRole = true,
    useFocus = true,
    showIndicator = true,
    indicatorLocked = false,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -180,
}

local COLORS = {
    green = {0.25, 0.95, 0.35, 1},
    yellow = {1.0, 0.78, 0.16, 1},
    gray = {0.45, 0.45, 0.45, 1},
    red = {0.95, 0.25, 0.25, 1},
}

local db
local scanElapsed = 0
local lastGlobalAlert = 0
local alertState = {}
local currentVisualState = nil
local optionControlSets = {}
local optionsPanel
local standalonePanel
local standaloneOptions

local function CopyDefaults(defaults, target)
    target = target or {}
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = value
        end
    end
    return target
end

local function EnsureDb()
    AGRODB = CopyDefaults(DEFAULT_DB, AGRODB or {})
    db = AGRODB
    if db.resetThreshold >= db.threshold then
        db.resetThreshold = math.max(50, db.threshold - 15)
    end
end

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd966AGRO|r: " .. tostring(message))
end

local function RefreshOptions()
    if AGRO.RefreshOptions then
        AGRO:RefreshOptions()
    end
end

local function TrimLower(message)
    message = message or ""
    message = message:match("^%s*(.-)%s*$") or ""
    return string.lower(message)
end

local function ClampNumber(value, minValue, maxValue)
    value = tonumber(value)
    if not value then
        return nil
    end
    value = math.floor(value + 0.5)
    if value < minValue or value > maxValue then
        return nil
    end
    return value
end

local function UnitFullName(unit)
    local name, realm = UnitName(unit)
    if not name then
        return nil
    end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function UnitShortName(unit)
    local name = UnitName(unit)
    return name or UNKNOWN or "?"
end

local function GetTargetName(unit)
    local name = UnitName(unit)
    return name or UnitName("target") or "target"
end

local function GetUnitRole(unit)
    if UnitGroupRolesAssigned then
        return UnitGroupRolesAssigned(unit)
    end
    return "NONE"
end

local function PlayerHasTankRole()
    return GetUnitRole("player") == "TANK"
end

local function IsEnabledByRole()
    if not db.requireTankRole then
        return true
    end
    return PlayerHasTankRole()
end

local function IsValidEnemy(unit)
    return UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsDead(unit)
end

local function IsPlayerTanking(unit)
    if not UnitDetailedThreatSituation then
        return false
    end
    local ok, isTanking = pcall(UnitDetailedThreatSituation, "player", unit)
    if not ok then
        return false
    end
    return isTanking and true or false
end

local function GetThreatInfo(source, target)
    if not UnitDetailedThreatSituation then
        return nil
    end
    local ok, isTanking, status, threatpct, rawthreatpct, threatvalue = pcall(UnitDetailedThreatSituation, source, target)
    if not ok or not status then
        return nil
    end
    return isTanking, status, threatpct or 0, rawthreatpct or 0, threatvalue or 0
end

local function StateKey(playerName, targetGuid)
    return tostring(playerName) .. ":" .. tostring(targetGuid or "noguid")
end

local function ResetOldAlertStates(activeTargetGuids)
    for key, state in pairs(alertState) do
        if state.targetGuid and not activeTargetGuids[state.targetGuid] then
            alertState[key] = nil
        end
    end
end

local function GetGroupUnits()
    local units = {}
    if IsInRaid and IsInRaid() then
        for index = 1, GetNumGroupMembers() do
            units[#units + 1] = "raid" .. index
        end
    elseif IsInGroup and IsInGroup() then
        for index = 1, GetNumSubgroupMembers() do
            units[#units + 1] = "party" .. index
        end
        units[#units + 1] = "player"
    else
        units[#units + 1] = "player"
    end
    return units
end

local function IsCandidate(unit)
    if unit == "player" then
        return false
    end
    local isDead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) or UnitIsDead(unit)
    if not UnitExists(unit) or not UnitIsConnected(unit) or isDead then
        return false
    end
    if GetUnitRole(unit) == "TANK" then
        return false
    end
    return true
end

local function GetOutputChannel()
    if db.output == "group" and IsInRaid and IsInRaid() then
        return "RAID"
    end
    if db.output == "group" and IsInGroup and IsInGroup() then
        return "PARTY"
    end
    return "SAY"
end

local function SendWarning(playerName, threatpct)
    local roundedThreat = math.floor((threatpct or db.threshold or 0) + 0.5)
    local message = L.warning:format(playerName, roundedThreat)
    local channel = GetOutputChannel()
    SendChatMessage(message, channel)
end

local function CanAlert(state, now)
    if now - lastGlobalAlert < db.globalCooldown then
        return false
    end
    if state.armed == false then
        return false
    end
    if state.lastAlert and now - state.lastAlert < db.playerCooldown then
        return false
    end
    return true
end

local function MarkAlert(state, now)
    state.lastAlert = now
    state.armed = false
    lastGlobalAlert = now
end

local function EvaluateUnit(source, target)
    if not IsCandidate(source) then
        return
    end

    local _, _, threatpct = GetThreatInfo(source, target)
    if not threatpct or threatpct <= 0 then
        return
    end

    local playerName = UnitFullName(source)
    local targetGuid = UnitGUID(target)
    if not playerName or not targetGuid then
        return
    end

    local key = StateKey(playerName, targetGuid)
    local state = alertState[key]
    if not state then
        state = {armed = true, targetGuid = targetGuid}
        alertState[key] = state
    end

    if threatpct <= db.resetThreshold then
        state.armed = true
        return
    end

    if threatpct >= db.threshold then
        local now = GetTime()
        if CanAlert(state, now) then
            SendWarning(UnitShortName(source), threatpct)
            MarkAlert(state, now)
        end
    end
end

local function GetTankTargets()
    local targets = {}
    local activeGuids = {}

    if IsValidEnemy("target") and IsPlayerTanking("target") then
        targets[#targets + 1] = "target"
        activeGuids[UnitGUID("target")] = true
    end

    if db.useFocus and IsValidEnemy("focus") and IsPlayerTanking("focus") then
        local focusGuid = UnitGUID("focus")
        if not activeGuids[focusGuid] then
            targets[#targets + 1] = "focus"
            activeGuids[focusGuid] = true
        end
    end

    return targets, activeGuids
end

function AGRO:Scan()
    EnsureDb()
    if not db.enabled or not IsEnabledByRole() or not UnitAffectingCombat("player") then
        return false
    end
    if not UnitDetailedThreatSituation then
        return false
    end

    local targets, activeGuids = GetTankTargets()
    ResetOldAlertStates(activeGuids)

    if #targets == 0 then
        return false
    end

    local units = GetGroupUnits()
    for _, target in ipairs(targets) do
        for _, source in ipairs(units) do
            EvaluateUnit(source, target)
        end
    end

    return true
end

function AGRO:HasMonitoringTarget()
    EnsureDb()
    if not db.enabled or not IsEnabledByRole() or not UnitDetailedThreatSituation then
        return false
    end

    local targets = GetTankTargets()
    return #targets > 0
end

local function SaveIndicatorPosition(frame)
    EnsureDb()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    db.point = point
    db.relativePoint = relativePoint
    db.x = x
    db.y = y
end

local function EnsureIndicator()
    if AGRO.indicator then
        return
    end

    EnsureDb()
    local frame = CreateFrame("Button", "AGROIndicator", UIParent, "BackdropTemplate")
    frame:SetSize(68, 22)
    frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 0, db.y or -180)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 8,
        insets = {left = 2, right = 2, top = 2, bottom = 2},
    })
    frame:SetBackdropColor(0.03, 0.03, 0.04, 0.78)
    frame:SetBackdropBorderColor(0.35, 0.35, 0.35, 0.85)

    frame.dot = frame:CreateTexture(nil, "ARTWORK")
    frame.dot:SetPoint("LEFT", 7, 0)
    frame.dot:SetSize(9, 9)
    frame.dot:SetColorTexture(COLORS.gray[1], COLORS.gray[2], COLORS.gray[3], COLORS.gray[4])

    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.text:SetPoint("LEFT", frame.dot, "RIGHT", 5, 0)
    frame.text:SetText("AGRO")

    frame:SetScript("OnDragStart", function(self)
        if not db.indicatorLocked then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveIndicatorPosition(self)
    end)
    frame:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            AGRO:OpenStandaloneOptions()
        else
            db.enabled = not db.enabled
            alertState = {}
            AGRO:UpdateIndicator()
            Print(db.enabled and L.enabled or L.disabled)
        end
    end)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    AGRO.indicator = frame
end

function AGRO:UpdateIndicator(monitoring)
    EnsureDb()
    EnsureIndicator()

    if db.showIndicator then
        AGRO.indicator:Show()
    else
        AGRO.indicator:Hide()
        return
    end

    local state
    local color
    if not db.enabled then
        state = "off"
        color = COLORS.gray
    elseif not IsEnabledByRole() then
        state = "role"
        color = COLORS.yellow
    elseif monitoring then
        state = "monitoring"
        color = COLORS.green
    else
        state = "idle"
        color = COLORS.yellow
    end

    if currentVisualState ~= state then
        currentVisualState = state
        AGRO.indicator.dot:SetColorTexture(color[1], color[2], color[3], color[4])
        AGRO.indicator.text:SetText("AGRO")
    end
end

local function PrintHelp()
    Print(L.helpHeader)
    Print(L.helpConfig)
    Print(L.helpOn)
    Print(L.helpOff)
    Print(L.helpToggle)
    Print(L.helpStatus)
    Print(L.helpChannel)
    Print(L.helpThreshold)
    Print(L.helpReset)
    Print(L.helpGlobal)
    Print(L.helpPlayer)
    Print(L.helpFocus)
    Print(L.helpRole)
    Print(L.helpIndicator)
end

local function PrintStatus()
    local armed
    if not db.enabled then
        armed = L.disabled
    elseif not UnitDetailedThreatSituation then
        armed = L.noThreatApi
    elseif not IsEnabledByRole() then
        armed = L.tankRoleMissing
    elseif AGRO:HasMonitoringTarget() then
        armed = L.monitoring
    else
        armed = L.noTarget
    end

    Print(L.statusHeader)
    Print(armed)
    Print("output: " .. (db.output == "group" and L.outputGroup or L.outputLocal))
    Print("threshold: " .. db.threshold .. "% / reset: " .. db.resetThreshold .. "%")
    Print("global: " .. db.globalCooldown .. "s / player: " .. db.playerCooldown .. "s")
    Print("focus: " .. tostring(db.useFocus) .. " / role: " .. tostring(db.requireTankRole))
end

local function SetOutput(output)
    db.output = output
    Print(L.outputSet:format(output == "group" and L.outputGroup or L.outputLocal))
end

local function ResetDefaults()
    AGRODB = CopyDefaults(DEFAULT_DB, {})
    db = AGRODB
    alertState = {}
    currentVisualState = nil
    if AGRO.indicator then
        AGRO.indicator:ClearAllPoints()
        AGRO.indicator:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
    end
    AGRO:UpdateIndicator(false)
    RefreshOptions()
end

local function CreateText(parent, text, template)
    local font = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    font:SetText(text)
    font:SetJustifyH("LEFT")
    return font
end

local function AddTooltip(frame, title, body)
    if not body or body == "" then
        return
    end
    frame.tooltipTitle = title
    frame.tooltipBody = body
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipTitle or "")
        GameTooltip:AddLine(self.tooltipBody, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function CreateCheck(parent, label, getter, setter, tooltip)
    local check = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    check:SetHitRectInsets(0, -190, 0, 0)
    if check.Text then
        check.Text:SetText(label)
    else
        check.Text = CreateText(check, label, "GameFontHighlight")
        check.Text:SetPoint("LEFT", check, "RIGHT", 2, 0)
    end
    check.getter = getter
    check.setter = setter
    check:SetScript("OnClick", function(self)
        self.setter(self:GetChecked() and true or false)
        AGRO:UpdateIndicator(false)
        RefreshOptions()
    end)
    AddTooltip(check, label, tooltip)
    return check
end

local function CreateButton(parent, label, width)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 110, 24)
    button:SetText(label)
    return button
end

local function CreateStepper(parent, label, dbKey, minValue, maxValue, step, suffix, onChange, tooltip)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(230, 26)
    frame:EnableMouse(true)

    local labelText = CreateText(frame, label, "GameFontHighlight")
    labelText:SetPoint("LEFT", frame, "LEFT", 0, 0)
    labelText:SetWidth(112)

    local minus = CreateButton(frame, "-", 24)
    minus:SetPoint("LEFT", labelText, "RIGHT", 4, 0)

    local valueText = CreateText(frame, "", "GameFontNormal")
    valueText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    valueText:SetSize(48, 20)
    valueText:SetJustifyH("CENTER")

    local plus = CreateButton(frame, "+", 24)
    plus:SetPoint("LEFT", valueText, "RIGHT", 6, 0)

    frame.valueText = valueText
    frame.dbKey = dbKey
    frame.suffix = suffix or ""

    function frame:Refresh()
        EnsureDb()
        self.valueText:SetText(tostring(db[self.dbKey]) .. self.suffix)
    end

    local function Adjust(delta)
        EnsureDb()
        local value = db[dbKey] + delta
        if value < minValue then
            value = minValue
        elseif value > maxValue then
            value = maxValue
        end
        db[dbKey] = value
        if onChange then
            onChange(value)
        end
        RefreshOptions()
    end

    minus:SetScript("OnClick", function()
        Adjust(-step)
    end)
    plus:SetScript("OnClick", function()
        Adjust(step)
    end)

    AddTooltip(frame, label, tooltip)
    AddTooltip(minus, label, tooltip)
    AddTooltip(plus, label, tooltip)

    return frame
end

function AGRO:RefreshOptions()
    EnsureDb()

    for _, controls in ipairs(optionControlSets) do
        for _, check in ipairs(controls.checks or {}) do
            check:SetChecked(check.getter() and true or false)
        end
        for _, stepper in ipairs(controls.steppers or {}) do
            stepper:Refresh()
        end
    end
end

local function RegisterOptionsPanel(panel)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
        AGRO.settingsCategory = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function AGRO:BuildOptionsPanel(panelName, register, showTitle)
    EnsureDb()
    local panel = CreateFrame("Frame", panelName)
    panel.name = "AGRO"
    panel:SetSize(560, 360)

    local topOffset = showTitle == false and 0 or -36
    if showTitle ~= false then
        local title = CreateText(panel, L.optionsTitle, "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    end

    local general = CreateText(panel, L.general, "GameFontNormal")
    general:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, topOffset - 16)

    local checks = {}
    local function AddCheck(label, x, y, getter, setter, tooltip)
        local check = CreateCheck(panel, label, getter, setter, tooltip)
        check:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
        checks[#checks + 1] = check
        return check
    end

    AddCheck(L.enableAlerts, 16, topOffset - 40, function() return db.enabled end, function(value)
        db.enabled = value
        if not value then
            alertState = {}
        end
    end, L.enableAlertsDesc)
    AddCheck(L.requireTankRole, 16, topOffset - 70, function() return db.requireTankRole end, function(value)
        db.requireTankRole = value
    end, L.requireTankRoleDesc)
    AddCheck(L.monitorFocus, 16, topOffset - 100, function() return db.useFocus end, function(value)
        db.useFocus = value
        alertState = {}
    end, L.monitorFocusDesc)
    AddCheck(L.showIndicator, 16, topOffset - 130, function() return db.showIndicator end, function(value)
        db.showIndicator = value
    end, L.showIndicatorDesc)
    AddCheck(L.lockIndicator, 16, topOffset - 160, function() return db.indicatorLocked end, function(value)
        db.indicatorLocked = value
    end, L.lockIndicatorDesc)

    local announce = CreateText(panel, L.announce, "GameFontNormal")
    announce:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, topOffset - 16)

    AddCheck(L.localOnly, 292, topOffset - 40, function() return db.output == "local" end, function(value)
        if value then
            db.output = "local"
        else
            db.output = "group"
        end
    end, L.localOnlyDesc)

    AddCheck(L.partyRaidChat, 292, topOffset - 70, function() return db.output == "group" end, function(value)
        if value then
            db.output = "group"
        else
            db.output = "local"
        end
    end, L.partyRaidChatDesc)

    local thresholds = CreateText(panel, L.thresholds, "GameFontNormal")
    thresholds:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, topOffset - 106)

    local steppers = {}
    local threshold = CreateStepper(panel, L.warningThreshold, "threshold", 80, 99, 1, "%", function(value)
        if db.resetThreshold >= value then
            db.resetThreshold = math.max(50, value - 15)
        end
    end, L.warningThresholdDesc)
    threshold:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, topOffset - 130)
    steppers[#steppers + 1] = threshold

    local reset = CreateStepper(panel, L.resetThreshold, "resetThreshold", 50, 95, 1, "%", function(value)
        if value >= db.threshold then
            db.threshold = math.min(99, value + 1)
        end
    end, L.resetThresholdDesc)
    reset:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, topOffset - 162)
    steppers[#steppers + 1] = reset

    local globalDelay = CreateStepper(panel, L.globalDelay, "globalCooldown", 3, 60, 1, " " .. L.seconds, nil, L.globalDelayDesc)
    globalDelay:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, topOffset - 194)
    steppers[#steppers + 1] = globalDelay

    local playerCooldown = CreateStepper(panel, L.playerCooldown, "playerCooldown", 5, 120, 5, " " .. L.seconds, nil, L.playerCooldownDesc)
    playerCooldown:SetPoint("TOPLEFT", panel, "TOPLEFT", 292, topOffset - 226)
    steppers[#steppers + 1] = playerCooldown

    local resetButton = CreateButton(panel, L.resetDefaults, 130)
    resetButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, topOffset - 214)
    resetButton:SetScript("OnClick", ResetDefaults)
    AddTooltip(resetButton, L.resetDefaults, L.resetDefaultsDesc)

    optionControlSets[#optionControlSets + 1] = {
        checks = checks,
        steppers = steppers,
    }

    panel:SetScript("OnShow", function()
        AGRO:RefreshOptions()
    end)

    if register then
        RegisterOptionsPanel(panel)
    end
    self:RefreshOptions()
    return panel
end

function AGRO:CreateOptionsPanel()
    if optionsPanel then
        return optionsPanel
    end

    optionsPanel = self:BuildOptionsPanel("AGROOptionsPanel", true, true)
    return optionsPanel
end

function AGRO:CreateStandalonePanel()
    if standalonePanel then
        return standalonePanel
    end

    standalonePanel = self:BuildOptionsPanel("AGROStandaloneOptionsPanelContent", false, false)
    return standalonePanel
end

local function SaveStandalonePosition(frame)
    EnsureDb()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    db.configPoint = point
    db.configRelativePoint = relativePoint
    db.configX = x
    db.configY = y
end

function AGRO:OpenStandaloneOptions()
    local panel = self:CreateStandalonePanel()
    if not standaloneOptions then
        local frame = CreateFrame("Frame", "AGROStandaloneOptionsFrame", UIParent, "BackdropTemplate")
        frame:SetSize(600, 410)
        frame:SetPoint(db.configPoint or "CENTER", UIParent, db.configRelativePoint or "CENTER", db.configX or 0, db.configY or 0)
        frame:SetFrameStrata("DIALOG")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetClampedToScreen(true)
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = {left = 3, right = 3, top = 3, bottom = 3},
        })
        frame:SetBackdropColor(0.03, 0.03, 0.04, 0.94)
        frame:SetBackdropBorderColor(0.45, 0.42, 0.28, 0.9)
        frame:SetScript("OnDragStart", function(self)
            self:StartMoving()
        end)
        frame:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            SaveStandalonePosition(self)
        end)
        frame:Hide()

        local title = CreateText(frame, L.optionsTitle, "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -10)

        local close = CreateButton(frame, L.close, 80)
        close:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 18)
        close:SetScript("OnClick", function()
            frame:Hide()
        end)

        if UISpecialFrames then
            UISpecialFrames[#UISpecialFrames + 1] = "AGROStandaloneOptionsFrame"
        end

        standaloneOptions = frame
    end

    panel:SetParent(standaloneOptions)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", standaloneOptions, "TOPLEFT", 18, -30)
    panel:Show()
    standaloneOptions:Show()
    standaloneOptions:Raise()
    self:RefreshOptions()
end

function AGRO:OpenOptions()
    self:OpenStandaloneOptions()
end

local function SlashHandler(message)
    EnsureDb()
    local normalized = TrimLower(message)
    local command, rest = normalized:match("^(%S+)%s*(.*)$")
    command = command or ""
    rest = rest or ""

    if command == "" or command == "config" or command == "options" then
        AGRO:OpenOptions()
    elseif command == "help" then
        PrintHelp()
    elseif command == "on" or command == "enable" then
        db.enabled = true
        Print(L.enabled)
    elseif command == "off" or command == "disable" then
        db.enabled = false
        alertState = {}
        Print(L.disabled)
    elseif command == "toggle" then
        db.enabled = not db.enabled
        alertState = {}
        Print(db.enabled and L.enabled or L.disabled)
    elseif command == "status" then
        PrintStatus()
    elseif command == "local" then
        SetOutput("local")
    elseif command == "group" or command == "raid" or command == "party" then
        SetOutput("group")
    elseif command == "threshold" then
        local value = ClampNumber(rest, 80, 99)
        if value and value > db.resetThreshold then
            db.threshold = value
            Print(L.thresholdSet:format(value))
        else
            Print(L.invalidNumber)
        end
    elseif command == "reset" then
        local value = ClampNumber(rest, 50, 95)
        if value and value < db.threshold then
            db.resetThreshold = value
            Print(L.resetSet:format(value))
        else
            Print(L.invalidNumber)
        end
    elseif command == "global" then
        local value = ClampNumber(rest, 3, 60)
        if value then
            db.globalCooldown = value
            Print(L.globalSet:format(value))
        else
            Print(L.invalidNumber)
        end
    elseif command == "player" then
        local value = ClampNumber(rest, 5, 120)
        if value then
            db.playerCooldown = value
            Print(L.playerSet:format(value))
        else
            Print(L.invalidNumber)
        end
    elseif command == "focus" then
        db.useFocus = not db.useFocus
        Print(db.useFocus and L.focusOn or L.focusOff)
    elseif command == "role" then
        db.requireTankRole = not db.requireTankRole
        Print(db.requireTankRole and L.roleOn or L.roleOff)
    elseif command == "show" then
        db.showIndicator = true
        AGRO:UpdateIndicator()
    elseif command == "hide" then
        db.showIndicator = false
        AGRO:UpdateIndicator()
    elseif command == "lock" then
        db.indicatorLocked = not db.indicatorLocked
        Print(db.indicatorLocked and L.locked or L.unlocked)
    elseif command == "test" then
        SendWarning(UnitName("player") or "Player", db.threshold)
    else
        PrintHelp()
    end

    AGRO:UpdateIndicator()
end

function AGRO:OnUpdate(elapsed)
    scanElapsed = scanElapsed + elapsed
    if scanElapsed < 0.35 then
        return
    end
    scanElapsed = 0

    local monitoring = self:Scan()
    self:UpdateIndicator(monitoring)
end

function AGRO:OnEvent(event, addonName)
    if event == "ADDON_LOADED" and addonName ~= ADDON_NAME then
        return
    end

    if event == "ADDON_LOADED" then
        EnsureDb()
        EnsureIndicator()
        self:CreateOptionsPanel()
        self:UpdateIndicator(false)
        Print(L.loaded)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" then
        alertState = {}
        self:UpdateIndicator(false)
    elseif event == "PLAYER_REGEN_ENABLED" then
        alertState = {}
        self:UpdateIndicator(false)
    elseif event == "PLAYER_REGEN_DISABLED" then
        self:UpdateIndicator(false)
    end
end

AGRO:SetScript("OnEvent", function(self, event, ...)
    self:OnEvent(event, ...)
end)
AGRO:SetScript("OnUpdate", function(self, elapsed)
    self:OnUpdate(elapsed)
end)

AGRO:RegisterEvent("ADDON_LOADED")
AGRO:RegisterEvent("PLAYER_LOGIN")
AGRO:RegisterEvent("GROUP_ROSTER_UPDATE")
AGRO:RegisterEvent("PLAYER_TARGET_CHANGED")
AGRO:RegisterEvent("PLAYER_FOCUS_CHANGED")
AGRO:RegisterEvent("PLAYER_REGEN_DISABLED")
AGRO:RegisterEvent("PLAYER_REGEN_ENABLED")

SLASH_AGRO1 = "/agro"
SlashCmdList.AGRO = SlashHandler
