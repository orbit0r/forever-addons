------------------------------------------------------------------------
-- Dynamic Panels (Forever)
-- Hold configurable modifiers (default Ctrl+Shift):
--   • Header bar  → drag to move
--   • Bottom-right corner → drag to resize
-- Same mods + right-click resets that panel.
-- ElvUI frames stay on /moveui.
------------------------------------------------------------------------

local UIParent = UIParent
local UIPanelWindows = UIPanelWindows

local active -- frame being moved/resized
local mode -- "move" | "size"
local applying
local leftWasDown
local rightWasDown

local MIN_W, MIN_H = 200, 150

-- Frames ElvUI (or the game) already owns — never take over.
local SKIP = {
	WorldFrame = true,
	UIParent = true,
	ElvUIParent = true,
	Minimap = true,
	MinimapCluster = true,
	MinimapBackdrop = true,
	MinimapMover = true,
	MMHolder = true,
	GameTooltip = true,
	ShoppingTooltip1 = true,
	ShoppingTooltip2 = true,
	ShoppingTooltip3 = true,
	ItemRefTooltip = true,
	DropDownList1 = true,
	DropDownList2 = true,
	DropDownList3 = true,
	ChatFrameMenuButton = true,
	AlertFrame = true,
	ElvUI_ContainerFrame = true,
	ElvUI_BankContainerFrame = true,
	ScriptErrorsFrame = true,
}

local DEFAULTS = {
	pos = {},
	modCtrl = true,
	modShift = true,
	modAlt = false,
	headerOnly = true,
	headerHeight = 36,
	enableResize = true,
	resizeCorner = 28,
	hint = false,
}

local function DB()
	if not DynamicPanelsDB then
		DynamicPanelsDB = {}
	end
	for k, v in pairs(DEFAULTS) do
		if DynamicPanelsDB[k] == nil then
			if type(v) == 'table' then
				DynamicPanelsDB[k] = {}
			else
				DynamicPanelsDB[k] = v
			end
		end
	end
	if not DynamicPanelsDB.pos then
		DynamicPanelsDB.pos = {}
	end
	return DynamicPanelsDB
end

_G.DynamicPanels_DB = DB

local function ModifiersDown()
	local db = DB()
	if not (db.modCtrl or db.modShift or db.modAlt) then
		return false
	end
	if db.modCtrl and not IsControlKeyDown() then return false end
	if db.modShift and not IsShiftKeyDown() then return false end
	if db.modAlt and not IsAltKeyDown() then return false end
	return true
end

local function FrameName(frame)
	if not frame or not frame.GetName then return nil end
	local name = frame:GetName()
	if not name or name == '' then return nil end
	return name
end

local function GetFocusFrame()
	if GetMouseFoci then
		local foci = GetMouseFoci()
		if foci then
			return foci[1] or foci[0]
		end
	end
	if GetMouseFocus then
		return GetMouseFocus()
	end
	return nil
end

local function IsElvManaged(frame)
	if not frame then return false end
	if frame.mover then return true end
	local name = FrameName(frame)
	if not name then return false end
	if SKIP[name] then return true end
	if name:find('^Elv') or name:find('^ElvUF') then return true end
	if name:find('Mover$') then return true end
	if name:find('^ChatFrame') or name:find('^ChatButton') then return true end
	if name:find('NamePlate') then return true end
	return false
end

local function ShouldSkip(frame)
	local f = frame
	for _ = 1, 24 do
		if not f then break end
		if IsElvManaged(f) then return true end
		local parent = f.GetParent and f:GetParent()
		if not parent or parent == UIParent or parent == _G.ElvUIParent then
			break
		end
		f = parent
	end
	return false
end

local function RootFrame(frame)
	local f = frame
	for _ = 1, 24 do
		if not f then return frame end
		local parent = f:GetParent()
		if not parent or parent == UIParent or parent == _G.ElvUIParent then
			return f
		end
		f = parent
	end
	return frame
end

local function IsDescendantOf(frame, ancestor)
	if not frame or not ancestor then return false end
	if frame.IsDescendantOf then
		return frame:IsDescendantOf(ancestor)
	end
	local f = frame
	for _ = 1, 24 do
		if f == ancestor then return true end
		f = f.GetParent and f:GetParent()
		if not f then return false end
	end
	return false
end

local function CursorOnRoot(root)
	if not root or not root.GetTop then return nil end
	local top, bottom, left, right = root:GetTop(), root:GetBottom(), root:GetLeft(), root:GetRight()
	if not top or not left or not right or not bottom then return nil end
	local scale = root:GetEffectiveScale() or 1
	local cx, cy = GetCursorPosition()
	cx, cy = cx / scale, cy / scale
	if cx < left or cx > right or cy < bottom or cy > top then
		return nil
	end
	return cx, cy, top, bottom, left, right
end

local function CursorInTopBand(root, height)
	local cx, cy, top, _, left, right = CursorOnRoot(root)
	if not cx then return false end
	return cy <= top and cy >= (top - (height or 36))
end

local function CursorInBottomRight(root, corner)
	local cx, cy, _, bottom, _, right = CursorOnRoot(root)
	if not cx then return false end
	corner = corner or 28
	return cx >= (right - corner) and cy <= (bottom + corner)
end

local function IsHeaderHit(focus, root)
	if not focus or not root then return false end
	local db = DB()
	if not db.headerOnly then
		return true
	end

	if root.TitleContainer and (focus == root.TitleContainer or IsDescendantOf(focus, root.TitleContainer)) then
		return true
	end
	if root.TitleRegion and (focus == root.TitleRegion or IsDescendantOf(focus, root.TitleRegion)) then
		return true
	end

	local f = focus
	for _ = 1, 10 do
		if not f then break end
		local name = FrameName(f) or ''
		if name:find('Title') or name:find('Header') or name:find('Drag') then
			return true
		end
		if f == root then break end
		f = f.GetParent and f:GetParent()
	end

	return CursorInTopBand(root, db.headerHeight or 36)
end

local function CloseButtonFocus(focus)
	if not focus or not focus.GetObjectType then return false end
	if focus:GetObjectType() ~= 'Button' then return false end
	local name = FrameName(focus) or ''
	return name:find('Close') or name:find('Exit') or name:find('Hide')
end

local function TakeOverPanel(name)
	if UIPanelWindows and UIPanelWindows[name] then
		UIPanelWindows[name] = nil
	end
	local frame = _G[name]
	if frame and frame.SetAttribute then
		frame:SetAttribute('UIPanelLayout-enabled', false)
	end
end

local function ApplyPos(name)
	local pos = DB().pos[name]
	local frame = _G[name]
	if not pos or not frame or not frame.SetPoint then return end
	applying = true
	if pos.w and pos.h and frame.SetSize then
		frame:SetSize(pos.w, pos.h)
	elseif pos.w and frame.SetWidth then
		frame:SetWidth(pos.w)
	elseif pos.h and frame.SetHeight then
		frame:SetHeight(pos.h)
	end
	frame:ClearAllPoints()
	frame:SetPoint('BOTTOMLEFT', UIParent, 'BOTTOMLEFT', pos.x, pos.y)
	applying = nil
end

local function SavePos(frame)
	local name = FrameName(frame)
	if not name then return end
	local x, y = frame:GetLeft(), frame:GetBottom()
	if not x or not y then return end
	local w, h = frame:GetWidth(), frame:GetHeight()
	local entry = DB().pos[name] or {}
	entry.x, entry.y = x, y
	if w and h then
		entry.w, entry.h = w, h
	end
	DB().pos[name] = entry
	TakeOverPanel(name)
end

local function ResetFrame(name)
	DB().pos[name] = nil
	local frame = _G[name]
	if frame and frame.IsShown and frame:IsShown() and HideUIPanel and ShowUIPanel then
		HideUIPanel(frame)
		ShowUIPanel(frame)
	end
	print('|cff1784d1Dynamic Panels|r reset ' .. name)
end

local function HookKeep(frame)
	if frame.DynamicPanelsHooked then return end
	frame.DynamicPanelsHooked = true
	local name = FrameName(frame)
	if not name then return end

	hooksecurefunc(frame, 'SetPoint', function()
		if applying or active then return end
		if DB().pos[name] then
			ApplyPos(name)
		end
	end)

	if frame.SetSize then
		hooksecurefunc(frame, 'SetSize', function()
			if applying or active then return end
			local pos = DB().pos[name]
			if pos and pos.w and pos.h then
				applying = true
				frame:SetSize(pos.w, pos.h)
				applying = nil
			end
		end)
	end

	frame:HookScript('OnShow', function()
		if DB().pos[name] then
			TakeOverPanel(name)
			ApplyPos(name)
		end
	end)
end

local function PrepareFrame(frame)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	if frame.SetResizable then
		frame:SetResizable(true)
	end
	if frame.SetResizeBounds then
		frame:SetResizeBounds(MIN_W, MIN_H)
	elseif frame.SetMinResize then
		frame:SetMinResize(MIN_W, MIN_H)
	end
	if frame.EnableMouse then
		frame:EnableMouse(true)
	end
	HookKeep(frame)
end

local function StartMove(frame)
	if not frame.SetMovable then return end
	PrepareFrame(frame)
	active, mode = frame, 'move'
	if frame.StartMoving then
		pcall(frame.StartMoving, frame)
	end
end

local function StartSize(frame)
	if not frame.SetResizable and not frame.StartSizing then return end
	PrepareFrame(frame)
	active, mode = frame, 'size'
	-- Anchor top-left so bottom-right sizing grows correctly
	local left, top = frame:GetLeft(), frame:GetTop()
	if left and top then
		applying = true
		frame:ClearAllPoints()
		frame:SetPoint('TOPLEFT', UIParent, 'BOTTOMLEFT', left, top)
		applying = nil
	end
	if frame.StartSizing then
		pcall(frame.StartSizing, frame, 'BOTTOMRIGHT')
	end
end

local function StopActive()
	local frame = active
	local wasMode = mode
	active, mode = nil, nil
	if not frame then return end
	if frame.StopMovingOrSizing then
		pcall(frame.StopMovingOrSizing, frame)
	end
	-- Clamp size
	if wasMode == 'size' then
		local w, h = frame:GetWidth(), frame:GetHeight()
		if w and w < MIN_W then frame:SetWidth(MIN_W) end
		if h and h < MIN_H then frame:SetHeight(MIN_H) end
	end
	SavePos(frame)
	local name = FrameName(frame)
	if name then
		ApplyPos(name)
	end
end

local function TryBegin(isRight)
	local focus = GetFocusFrame()
	if not focus or focus == WorldFrame then return end
	if CloseButtonFocus(focus) then return end

	local frame = RootFrame(focus)
	if ShouldSkip(frame) then return end

	local name = FrameName(frame)
	if isRight then
		-- Right-click+mods resets from header or resize corner
		local db = DB()
		local onHeader = IsHeaderHit(focus, frame)
		local onCorner = db.enableResize and CursorInBottomRight(frame, db.resizeCorner)
		if name and (onHeader or onCorner or not db.headerOnly) then
			ResetFrame(name)
		end
		return
	end

	local db = DB()
	if db.enableResize and CursorInBottomRight(frame, db.resizeCorner) then
		StartSize(frame)
		return
	end

	if not IsHeaderHit(focus, frame) then return end
	StartMove(frame)
end

local driver = CreateFrame('Frame', 'DynamicPanelsDriver', UIParent)
driver:SetScript('OnUpdate', function()
	local mods = ModifiersDown()
	local left = mods and IsMouseButtonDown('LeftButton')
	local right = mods and IsMouseButtonDown('RightButton')

	if left and not leftWasDown then
		TryBegin(false)
	elseif (not left) and leftWasDown then
		if active then StopActive() end
	end

	if right and not rightWasDown and not active then
		TryBegin(true)
	end

	leftWasDown = left and true or false
	rightWasDown = right and true or false
end)

if type(UpdateUIPanelPositions) == 'function' then
	hooksecurefunc('UpdateUIPanelPositions', function()
		for name in pairs(DB().pos) do
			ApplyPos(name)
		end
	end)
end

local boot = CreateFrame('Frame')
boot:RegisterEvent('PLAYER_LOGIN')
boot:SetScript('OnEvent', function(self)
	self:UnregisterEvent('PLAYER_LOGIN')
	local db = DB()
	for name in pairs(db.pos) do
		local frame = _G[name]
		if frame then
			HookKeep(frame)
			if frame:IsShown() then
				TakeOverPanel(name)
				ApplyPos(name)
			end
		end
	end
	if not db.hint then
		db.hint = true
		print('|cff1784d1Dynamic Panels|r Mods (default Ctrl+Shift): header=move, bottom-right=resize, right-click=reset. ElvUI=/moveui. |cffffff00/dp|r options')
	end
end)

local function ModSummary()
	local db = DB()
	local parts = {}
	if db.modCtrl then parts[#parts + 1] = 'Ctrl' end
	if db.modShift then parts[#parts + 1] = 'Shift' end
	if db.modAlt then parts[#parts + 1] = 'Alt' end
	if #parts == 0 then return '(none — set mods in /dp)' end
	return table.concat(parts, '+')
end

_G.DynamicPanels_ModSummary = ModSummary

SLASH_DYNAMICPANELS1 = '/dp'
SLASH_DYNAMICPANELS2 = '/dynamicpanels'
SlashCmdList.DYNAMICPANELS = function(msg)
	msg = string.lower(strtrim(msg or ''))
	if msg == 'reset' then
		local db = DB()
		DynamicPanelsDB = {
			modCtrl = db.modCtrl,
			modShift = db.modShift,
			modAlt = db.modAlt,
			headerOnly = db.headerOnly,
			headerHeight = db.headerHeight,
			enableResize = db.enableResize,
			resizeCorner = db.resizeCorner,
			hint = db.hint,
			pos = {},
		}
		print('|cff1784d1Dynamic Panels|r all panel positions/sizes cleared. Reopen panels to see defaults.')
		return
	end
	local name = msg:match('^reset%s+(.+)$')
	if name and name ~= '' then
		ResetFrame(name)
		return
	end
	if msg == 'options' or msg == 'config' or msg == '' then
		if DynamicPanels_ToggleConfig then
			DynamicPanels_ToggleConfig()
		end
		return
	end
	print('|cff1784d1Dynamic Panels|r mods=' .. ModSummary() .. ' | header=move corner=resize | /dp options | /dp reset')
end
