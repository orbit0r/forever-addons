--[[-------------------------------------------------------------------
--  Clique - Copyright 2006-2026 - James N. Whitehead II
-------------------------------------------------------------------]]--

local addonName = select(1, ...)

---@class CliqueAddon: AddonCore
local addon = select(2, ...)
local L = addon.L

local twipe = table.wipe

function addon:Initialize()
    self:SetupDatabase()
    self:SetupSecureHeader()
    self:SetupGlobalButtons()

	-- Get denylist before doing anything else
    self:PopulateDenylistFromSettings()

    local setup, remove, applyCombat, applyOoc = self:GetClickAttributes()
    self.header:SetAttribute("setup_clicks", setup)
    self.header:SetAttribute("remove_clicks", remove)
    self.header:SetAttribute("apply_combat", applyCombat)
    self.header:SetAttribute("apply_ooc", applyOoc)

    local set, clr = self:GetBindingAttributes()
    self.header:SetAttribute("setup_onenter", set)
    self.header:SetAttribute("setup_onleave", clr)

    -- Get the override binding attributes for the global click frame
    self.globutton.setup, self.globutton.remove, self.globutton.applyCombat, self.globutton.applyOoc = self:GetClickAttributes(true)
    self.globutton.setbinds, self.globutton.clearbinds = self:GetBindingAttributes(true)

    self:RegisterEvent("PLAYER_REGEN_DISABLED", "EnteringCombat")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "LeavingCombat")
    self:RegisterEvent("UPDATE_MACROS", "MacrosUpdated")

    self:RegisterEvent("PLAYER_ENTERING_WORLD", "PlayerEnteringWorld")

    -- Enable housing mode changes for midnight+
    if self:ProjectIsWarWithin() or self:ProjectIsMidnight() then
        self:RegisterEvent("HOUSE_EDITOR_MODE_CHANGED", "HouseEditorModeChanged")
    end

    -- Register for Clique-based messages for settings updates, etc.
    self:RegisterMessage("BINDINGS_CHANGED")
    self:RegisterMessage("BLACKLIST_CHANGED")

    -- Support multiple talent specs
    self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "TalentGroupChanged")

    -- Watch for in-game click-casting changes that conflict with Clique (retail)
    self:SetupBindConfigWarningWatch()

    -- Wait to set up the registry until attributes are in place
    self:SetupUnitFrameRegistry()
    self:CaptureGlobalRegistry()

    self:IntegrateBlizzardFrames()
end

function addon:Enable()
    self:FixMyBindingsV1()

    self:AttachToSpellbook()

    self:FireMessage("BINDINGS_CHANGED")
    self:FireMessage("BLACKLIST_CHANGED")

    -- If the spec API is already populated, run immediately; otherwise defer
    -- until the player is fully loaded (e.g. on first login before PLAYER_LOGIN)
    if self:GetActiveTalentSpec() then
        self:TalentGroupChanged()
    else
        C_Timer.After(1.0, function()
            self:TalentGroupChanged()
        end)
    end
end

function addon:PlayerEnteringWorld()
    self:FireMessage("BINDINGS_CHANGED")
end

function addon:MacrosUpdated()
    self:FireMessage("MACROS_UPDATED")
end

function addon:SetupDatabase()
    -- Create an AceDB, but it needs to be cleared first
    self.db = LibStub("AceDB-3.0"):New("CliqueDB3", self.databaseDefaults)
    self.db.RegisterCallback(self, "OnNewProfile", "OnNewProfile")
    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")

    self.settings = self.db.char
    self.globalSettings = self.db.global
    self.bindings = self.db.profile.bindings

end

function addon:SetupUnitFrameRegistry()
    -- Normal click-cast frames
    self.ccframes = {}
    -- Secure header click-cast frames
    self.hccframes = {}

    -- Active per-frame proxy buttons
    self.proxies = {}
    -- Proxy cache so recycled frames reuse their proxy (frames can't be destroyed)
    self.proxyPool = {}
    -- Counter for unique CliqueProxyNNN names
    self.proxyCount = 0
    -- Original frame attributes, restored on unregister
    self.proxyBackup = {}

    -- Per-frame SetBindingClick targets for key binds; see docs/attributes.md
    self.keyProxies = {}
    self.keyProxyPool = {}
    self.keyProxyCount = 0

    -- Queue for frame registration
    self.regqueue = {}
    -- Queue for frame unregistration
    self.unregqueue = {}
    -- Queue for frame click updates
    self.regclickqueue = {}
    -- Frames whose routing Blizzard clobbered in combat, pending reassertion
    self.reassertqueue = {}
end

function addon:CaptureGlobalRegistry()
    -- Compatability with old Clique 1.x registrations
    local oldClickCastFrames = ClickCastFrames

    ClickCastFrames = setmetatable({}, {__newindex = function(t, k, v)
        if v == nil or v == false then
            self:UnregisterUnitFrame(k)
        else
            self:RegisterUnitFrame(k)
        end
    end})

    if oldClickCastFrames then
        for frame, options in pairs(oldClickCastFrames) do
            self:RegisterUnitFrame(frame)
        end
    end
end

function addon:SetupSecureHeader()
    -- Registration for group headers (in-combat safe)
    self.header = CreateFrame("Frame", addonName .. "HeaderFrame", UIParent, "SecureHandlerBaseTemplate,SecureHandlerAttributeTemplate")
    ClickCastHeader = self.header

    -- This snippet will clear any dangling bindings that might have occurred
    -- as a result of frames being shown/hidden.
    --
    -- This was updated following 12.0 due to changes to self:IsUnderMouse()
    -- to use a GetMousePosition() check instead to bound to the frame
    local oacScript = [[
        if name == "hasunit" and value == "false" and danglingButton then
            local x, y = danglingButton:GetMousePosition()
            local xInBounds = x and type(x) == "number" and x >= 0 and x <= 1
            local yInBounds = y and type(y) == "number" and y >= 0 and y <= 1
            local insideFrame = xInBounds and yInBounds

            -- Check if we should clear the bindings
            if not insideFrame or not danglingButton:IsVisible() then
                if {{debug}} then print("Clique: clearing bindings, unit lost") end
                self:RunFor(danglingButton, self:GetAttribute("setup_onleave"))
                danglingButton = nil
            else
                if {{debug}} then print("Clique: ignoring unit loss, frame still here") end
            end
        end
    ]]
    oacScript = oacScript:gsub("{{debug}}", self.settings.debugUnitIssue and "true" or "false")
    self.header:SetAttribute("_onattributechanged", oacScript)
    RegisterAttributeDriver(self.header, "hasunit", "[@mouseover, exists] true; false")

   -- Create a table within the addon header to store the frames
    -- that are registered for click-casting
    self.header:Execute([[
        ccframes = table.new()
    ]])

    -- Create a table within the addon header to store the frame bakcklist
    self.header:Execute([[
        blacklist = table.new()
    ]])

    -- Create a table within the addon header to store the Clique-owned proxy
    -- buttons. Bindings are (re)applied to these inside the restricted
    -- environment so the ooc/combat swap works during combat lockdown.
    self.header:Execute([[
        proxies = table.new()
    ]])

    -- This snippet is executed from the SecureHandlerEnterLeaveTemplate
    -- _onenter and _onleave attributes. The 'self' attribute will contain
    -- the unit frame itself.
    self.header:SetAttribute("clickcast_onenter", [===[
        local header = self:GetParent():GetFrameRef("clickcast_header")
        header:RunFor(self, header:GetAttribute("setup_onenter"))
    ]===])

    -- This snippet is executed from the SecureHandlerEnterLeaveTemplate
    -- _onenter and _onleave attributes. The 'self' attribute will contain
    -- the unit frame itself.
    self.header:SetAttribute("clickcast_onleave", [===[
        local header = self:GetParent():GetFrameRef("clickcast_header")
        header:RunFor(self, header:GetAttribute("setup_onleave"))
    ]===])

    -- This snippet is executed from within the initialConfigFunction secure
    -- snippet. The unit frame button is passed in the 'clickcast_button'
    -- attribute, which can only be accomplished in a restricted environment.
    self.header:SetAttribute("clickcast_register", [===[
        local button = self:GetAttribute("clickcast_button")

        -- Export this frame so we can display it in the insecure environment
        self:SetAttribute("export_register", button)

        button:SetAttribute("clickcast_onenter", self:GetAttribute("clickcast_onenter"))
        button:SetAttribute("clickcast_onleave", self:GetAttribute("clickcast_onleave"))
        ccframes[button] = true
    ]===])

    -- This snippet is executed from the Clique:UnregisterFrame() function, or
    -- possibly from some other restricted environment. The unit frame is passed
    -- in the 'clickcast_button' attribute, which can only be accomplished
    -- in a restricted environment.
    self.header:SetAttribute("clickcast_unregister", [===[
        local button = self:GetAttribute("clickcast_button")

        -- Export this frame so it can be removed from the blacklist editor
        self:SetAttribute("export_unregister", button)

        -- Remove any click and binding attributes that have already been set
        self:RunFor(button, self:GetAttribute("clickcast_onleave"))
        self:RunFor(button, self:GetAttribute("remove_clicks"))

        button:SetAttribute("clickcast_onenter", nil)
        button:SetAttribute("clickcast_onleave", nil)
        ccframes[button] = nil
    ]===])

    -- Track and secure frame registrartions so that we can update its registered
    -- clicks and display it in the denylist editor. This is done via the
    -- 'export_register' and 'export_unregister' attributes.
    self.header:HookScript("OnAttributeChanged", function(frame, name, value)
        if name == "export_register" and type(value) ~= nil then
            -- Convert the userdata object to the global object so we have access
            -- to all of the correct methods, such as 'RegisterForClicks''
            local frameName = value.GetName and value:GetName()
            if frameName then
                local button = _G[frameName]

                -- TODO: add denylist registry
                -- TODO: split frame registry so this is decoupled
                self.hccframes[frameName] = button
                self:UpdateRegisteredClicks(button)
                if not InCombatLockdown() and not self:IsFrameBlacklisted(button) then
                    local proxy = self:GetOrCreateProxy(button)
                    self:SetupFrameClickRouting(button, proxy)
                    self:StampProxySetup(button, proxy)
                end
            end
        elseif name == "export_unregister" and type(value) ~= nil then
            local frameName = value.GetName and value:GetName()
            if frameName then
                local button = self.hccframes[frameName]
                if button then
                    local proxy = self.proxies[button]
                    if proxy then
                        self:RemoveProxySetup(button, proxy)
                        self:TeardownFrameClickRouting(button)
                    end
                end
                self.hccframes[frameName] = nil
            end
        end
    end)
end

function addon:SetupGlobalButtons()
    -- Create a secure action button that's sole purpose is to cancel a
    -- pending spellcast (the targeting hand)
    self.stopbutton = CreateFrame("Button", addonName .. "StopButton", nil, "SecureActionButtonTemplate")
    self.stopbutton.name = self.stopbutton:GetName()
    self.stopbutton:SetAttribute("type", "stop")

    -- Create a secure action button that can be used for 'hovercast' and 'global'
    self.globutton = CreateFrame("Button", addonName .. "SABButton", UIParent, "SecureActionButtonTemplate, SecureHandlerBaseTemplate")
    self:UpdateGlobalButtonClicks()

end

function addon:FixMyBindingsV1()
    -- Reverse iterate over all bindings and fix broken ones
    local bindings = self.db.profile.bindings or {}
    for idx=#bindings, 1, -1 do
        local bind = bindings[idx]

        if bind.type == nil or bind.type == "" then
            table.remove(bindings, idx)
            self:Printf("Removed broken binding with action type '%s' from index %s", tostring(bind.type), tostring(idx))
        end
    end
end

function addon:EnteringCombat()
    -- If there are no 'ooc' bindings, then no need to re-apply
    if not self.has_ooc then
        return
    end

    -- Check to see if we're already in combat, so we don't re-apply
    if not self.header:GetAttribute("inCombat") then
        -- inCombat must stay accurate for the registration path; the delta then
        -- swaps only the ooc/combat keys.
        self.header:SetAttribute("inCombat", true)
        self.globutton:SetAttribute("inCombat", true)
        self:ApplyCombatTransition(true)
    end
end

function addon:LeavingCombat()
    -- Process any frames in the registration queue
    for _, button in ipairs(self.regqueue) do
        self:RegisterUnitFrame(button)
    end
    if next(self.regqueue) then twipe(self.regqueue) end

    -- Process any frames in the unregistration queue
    for _, button in ipairs(self.unregqueue) do
        self:UnregisterUnitFrame(button)
    end
    if next(self.unregqueue) then twipe(self.unregqueue) end

    -- Process any frames in the clickregister queue
    for _, button in ipairs(self.regclickqueue) do
        self:UpdateRegisteredClicks(button)
    end
    if next(self.regclickqueue) then twipe(self.regclickqueue) end

    -- Heal only the frames the SetUnit hook queued during combat. We deliberately
    -- don't reassert every proxied frame on combat exit: that full sweep is the
    -- job of the binding-change / PEW path (ApplyAttributes), and paying it on
    -- every combat transition is wasteful. The queue holds the frames Blizzard
    -- clobbered while we were locked out and couldn't write to them.
    for frame in pairs(self.reassertqueue) do
        self:ReassertFrameClickRouting(frame)
    end
    if next(self.reassertqueue) then twipe(self.reassertqueue) end

    -- Wire up hccframes that registered during combat (proxy creation is deferred
    -- under lockdown). inCombat is still true, so setup_clicks lays down the combat
    -- set; the has_ooc block below swaps it via the delta.
    for _, frame in pairs(self.hccframes) do
        if not self.proxies[frame] and not self:IsFrameBlacklisted(frame) then
            local proxy = self:GetOrCreateProxy(frame)
            self:SetupFrameClickRouting(frame, proxy)
            self:StampProxySetup(frame, proxy)
        end
    end

    -- Only apply attributes if we have an 'ooc' binding set
    if self.has_ooc then
        -- inCombat must stay accurate for the registration path; the delta then
        -- swaps only the combat/ooc keys (apply_ooc clears the masking keys first).
        self.header:SetAttribute("inCombat", false)
        self.globutton:SetAttribute("inCombat", false)
        self:ApplyCombatTransition(false)
    end
end

function addon:IsGamePadEnabled()
    return self.settings.enableGamePad
end

function addon:HouseEditorModeChanged(_event, _editMode)
    if not C_HouseEditor then
        return
    end

    if InCombatLockdown() then
        self:Defer("HouseEditorModeChanged")
        return
    end

    local isEditorActive = C_HouseEditor.IsHouseEditorActive()

    if isEditorActive and self.settings.disableInHousing then
        self:ClearAttributes()
    elseif not isEditorActive then
        self:ClearAttributes()
        self:ApplyAttributes()
    end
end

function addon:ADDON_LOADED_SPELLBOOK(event, name)
    if name == "Blizzard_PlayerSpells" then
        -- Unregister, we're done!
        self:UnregisterEvent("ADDON_LOADED", "ADDON_LOADED_SPELLBOOK")

        -- Place the spellbook tab
        self:ShowSpellBookButton()
    end
end

function addon:AttachToSpellbook()
    if SpellBookFrame then
        -- We're on a legacy spellbook
        self:ShowSpellBookButton()
    elseif PlayerSpellsFrame then
        -- Spellbook already loaded
        self:ShowSpellBookButton()
    else
        -- Wait for spellbook to be loaded
        self:RegisterEvent("ADDON_LOADED", "ADDON_LOADED_SPELLBOOK")
    end
end

function addon:ShowSpellBookButton()
    local iconPath = "Interface\\AddOns\\CliqueForever\\images\\icon_square_64"

    if not addon.spellbookTab then
        addon.spellbookTab = CreateFrame("Button", "CliqueSpellbookTabButton", UIParent)
        addon.spellbookTab.bg = addon.spellbookTab:CreateTexture(nil, "BACKGROUND")
        addon.spellbookTab.border = addon.spellbookTab:CreateTexture(nil, "OVERLAY")

        local tab = addon.spellbookTab
        tab:ClearAllPoints()
        tab:SetWidth(36)
        tab:SetHeight(36)
        tab:SetNormalTexture(iconPath)
        tab:SetPushedTexture(iconPath)
        tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

        local nt = tab:GetNormalTexture()
        if nt then
            nt:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            nt:SetVertexColor(1, 1, 1, 1)
            nt:SetDesaturated(false)
        end
        local pt = tab:GetPushedTexture()
        if pt then
            pt:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            pt:SetVertexColor(1, 0.9, 0.4, 1)
        end

        -- Thin gold edge (not a filled rectangle)
        tab.border:Hide()
        if not tab.iconFrame then
            tab.iconFrame = CreateFrame("Frame", nil, tab, "BackdropTemplate")
            tab.iconFrame:SetAllPoints(tab)
            tab.iconFrame:EnableMouse(false)
            tab.iconFrame:SetBackdrop({
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 2,
                insets = { left = 0, right = 0, top = 0, bottom = 0 },
            })
            tab.iconFrame:SetBackdropBorderColor(1, 0.82, 0, 1)
            tab.iconFrame:SetBackdropColor(0, 0, 0, 0)

            tab.iconBright = tab:CreateTexture(nil, "ARTWORK")
            tab.iconBright:SetPoint("TOPLEFT", 2, -2)
            tab.iconBright:SetPoint("BOTTOMRIGHT", -2, 2)
            tab.iconBright:SetTexture(iconPath)
            tab.iconBright:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            tab.iconBright:SetVertexColor(1, 1, 1, 1)
        end
        if nt then nt:SetAlpha(0) end

        tab.bg:ClearAllPoints()
        tab.bg:SetPoint("TOPLEFT", -3, 11)
        tab.bg:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
        tab.bg:Hide() -- side-tab tray; not used when docked with top categories

        if tab.iconFrame then
            tab.iconFrame:EnableMouse(false)
        end

        tab:SetScript("OnClick", function()
            addon:ShowBindingConfig()

            if InCombatLockdown() then
                return
            end

            if SpellBookFrame then
                HideUIPanel(SpellBookFrame)
            elseif PlayerSpellsFrame then
                HideUIPanel(PlayerSpellsFrame)
            end
        end)
    end

    -- Always (re)bind tooltip so hover says Clique Forever
    do
        local tab = addon.spellbookTab
        tab:EnableMouse(true)
        if tab.iconFrame then
            tab.iconFrame:EnableMouse(false)
        end
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Clique Forever", 1, 0.82, 0)
            GameTooltip:AddLine("Open click-casting bindings", 0.9, 0.9, 0.9, true)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    if SpellBookFrame then
        -- Legacy spellbook: stack under skill-line tabs on the right stack under skill-line tabs on the right
        local anchorSpellbookTab = function(frame)
            local tab = addon.spellbookTab
            tab:SetParent(SpellBookFrame)
            if tab.bg then tab.bg:Show() end
            if tab.border then tab.border:Hide() end
            local num = GetNumSpellTabs()
            local lastTab = _G["SpellBookSkillLineTab" .. tostring(num)]
            if lastTab then
                tab:ClearAllPoints()
                tab:SetPoint("TOPLEFT", lastTab, "BOTTOMLEFT", 0, -17)
            end
        end
        SpellBookFrame:HookScript("OnShow", anchorSpellbookTab)
        anchorSpellbookTab()
    elseif PlayerSpellsFrame then
        -- Forever / modern PlayerSpells: dock with category tabs (General / specs)
        local function FindLastCategoryTab(tabs)
            local last
            -- Prefer TabSystem API when present
            if tabs.GetTabButton then
                local i = 1
                while true do
                    local btn = tabs:GetTabButton(i)
                    if not btn then break end
                    if btn:IsShown() then last = btn end
                    i = i + 1
                    if i > 20 then break end
                end
                if last then return last end
            end

            -- Otherwise pick shown Button children that are roughly square
            local children = { tabs:GetChildren() }
            for i = 1, #children do
                local child = children[i]
                if child and child ~= addon.spellbookTab and child.IsObjectType and child:IsObjectType("Button")
                    and child.IsShown and child:IsShown() then
                    local w, h = child:GetWidth() or 0, child:GetHeight() or 0
                    if w >= 20 and h >= 20 and w <= 64 and h <= 64 and math.abs(w - h) <= 8 then
                        last = child
                    end
                end
            end
            return last
        end

        local function AnchorForeverSpellbookTab()
            local tab = addon.spellbookTab
            local spellBook = PlayerSpellsFrame.SpellBookFrame
            local tabs = spellBook and spellBook.CategoryTabSystem
            tab:Show()
            if tab.bg then tab.bg:Hide() end
            if tab.border then tab.border:Hide() end

            -- Parent to spellbook (NOT CategoryTabSystem) so we are not laid out as a wide tab
            local parent = spellBook or PlayerSpellsFrame
            tab:SetParent(parent)
            tab:SetFrameStrata(parent:GetFrameStrata())
            tab:SetFrameLevel((parent:GetFrameLevel() or 1) + 50)

            local size = 36
            local last = tabs and FindLastCategoryTab(tabs)
            if last then
                local h = last:GetHeight() or 36
                local w = last:GetWidth() or h
                size = math.min(w, h)
                if size < 28 then size = 36 end
                if size > 48 then size = 36 end
            end

            tab:SetSize(size, size)
            tab:ClearAllPoints()

            if last then
                tab:SetPoint("TOPLEFT", last, "TOPRIGHT", 4, 0)
            elseif tabs then
                tab:SetPoint("TOPRIGHT", tabs, "TOPRIGHT", 4, 0)
            else
                tab:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, -40)
            end

            -- Keep icon square inside the button
            if tab.iconBright then
                tab.iconBright:ClearAllPoints()
                tab.iconBright:SetPoint("TOPLEFT", 2, -2)
                tab.iconBright:SetPoint("BOTTOMRIGHT", -2, 2)
            end
            if tab.iconFrame then
                tab.iconFrame:SetAllPoints(tab)
            end
        end

        if not addon.spellbookTabForeverHooked then
            addon.spellbookTabForeverHooked = true
            PlayerSpellsFrame:HookScript("OnShow", AnchorForeverSpellbookTab)
            if PlayerSpellsFrame.SpellBookFrame then
                PlayerSpellsFrame.SpellBookFrame:HookScript("OnShow", AnchorForeverSpellbookTab)
            end
        end
        AnchorForeverSpellbookTab()
    end
end

function addon:SlashCommand(msg, editbox)
    msg = msg or ""

    if msg == "inspect" or msg:match("^inspect%s+") then
        local pattern = msg:match("^inspect%s+(.+)$")
        self:InspectRegisteredFrames(pattern)
        return
    end

    local profile = msg:match("^profile (.+)$")
    if profile then
        if InCombatLockdown() then
            self:Printf(L["Cannot change profiles while in combat lockdown"])
        else
            local availableProfiles = self.db:GetProfiles({})

            if self.tcontains(availableProfiles, profile) then
                self:Printf(L["Switching to profile '%s'"], profile)
                self.db:SetProfile(profile)
            else
                self:Printf(L["Cannot find profile '%s'"], profile)
            end
        end
    else
        self:ShowBindingConfig()
    end
end

SLASH_CLIQUE1 = "/clique"
SlashCmdList["CLIQUE"] = function(msg, editbox)
    addon:SlashCommand(msg, editbox)
end
