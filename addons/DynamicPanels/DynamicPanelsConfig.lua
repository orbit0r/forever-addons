------------------------------------------------------------------------
-- Dynamic Panels — simple options UI
------------------------------------------------------------------------

local function DB()
	return DynamicPanels_DB and DynamicPanels_DB() or DynamicPanelsDB
end

local config

local function RefreshLabels()
	if not config or not config.modLabel then return end
	local summary = DynamicPanels_ModSummary and DynamicPanels_ModSummary() or '?'
	config.modLabel:SetText('Active combo: |cffffff00' .. summary .. '|r')
end

local function MakeCheck(parent, label, key)
	local btn = CreateFrame('CheckButton', nil, parent, 'UICheckButtonTemplate')
	btn:SetSize(24, 24)
	btn.Text:SetText(label)
	btn.Text:SetFontObject(GameFontHighlight)
	btn:SetScript('OnClick', function(self)
		local db = DB()
		db[key] = self:GetChecked() and true or false
		RefreshLabels()
	end)
	btn._dpKey = key
	btn._dpRefresh = function(self)
		self:SetChecked(DB()[key] and true or false)
	end
	return btn
end

function DynamicPanels_ToggleConfig()
	if not config then
		local f = CreateFrame('Frame', 'DynamicPanelsConfigFrame', UIParent, 'BasicFrameTemplateWithInset')
		f:SetSize(380, 320)
		f:SetPoint('CENTER')
		f:SetFrameStrata('DIALOG')
		f:EnableMouse(true)
		f:SetMovable(true)
		f:RegisterForDrag('LeftButton')
		f:SetScript('OnDragStart', f.StartMoving)
		f:SetScript('OnDragStop', f.StopMovingOrSizing)
		f:Hide()
		f.TitleText:SetText('Dynamic Panels')

		local intro = f:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
		intro:SetPoint('TOPLEFT', 16, -36)
		intro:SetPoint('TOPRIGHT', -16, -36)
		intro:SetJustifyH('LEFT')
		intro:SetText('Hold modifiers → drag header to move, or bottom-right corner to resize. ElvUI frames stay on /moveui.')

		local y = -88
		local ctrl = MakeCheck(f, 'Require Ctrl', 'modCtrl')
		ctrl:SetPoint('TOPLEFT', 20, y)
		y = y - 26
		local shift = MakeCheck(f, 'Require Shift', 'modShift')
		shift:SetPoint('TOPLEFT', 20, y)
		y = y - 26
		local alt = MakeCheck(f, 'Require Alt', 'modAlt')
		alt:SetPoint('TOPLEFT', 20, y)
		y = y - 32

		local header = MakeCheck(f, 'Header bar only for move (recommended)', 'headerOnly')
		header:SetPoint('TOPLEFT', 20, y)
		y = y - 26
		local resize = MakeCheck(f, 'Enable bottom-right resize', 'enableResize')
		resize:SetPoint('TOPLEFT', 20, y)
		y = y - 30

		local modLabel = f:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
		modLabel:SetPoint('TOPLEFT', 20, y)
		f.modLabel = modLabel

		y = y - 36
		local reset = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
		reset:SetSize(180, 24)
		reset:SetPoint('TOPLEFT', 20, y)
		reset:SetText('Reset all positions/sizes')
		reset:SetScript('OnClick', function()
			SlashCmdList.DYNAMICPANELS('reset')
		end)

		local close = CreateFrame('Button', nil, f, 'UIPanelButtonTemplate')
		close:SetSize(80, 24)
		close:SetPoint('BOTTOMRIGHT', -16, 16)
		close:SetText('Close')
		close:SetScript('OnClick', function() f:Hide() end)

		f.checks = { ctrl, shift, alt, header, resize }
		f:SetScript('OnShow', function(self)
			for _, c in ipairs(self.checks) do
				c:_dpRefresh()
			end
			RefreshLabels()
		end)

		config = f
	end

	if config:IsShown() then
		config:Hide()
	else
		config:Show()
	end
end
