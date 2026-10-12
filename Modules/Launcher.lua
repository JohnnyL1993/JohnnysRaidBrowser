-- Standalone launcher for Johnny's Raid Browser.
--
-- With Johnny's Addon Hub installed the hub opens this window, so nothing is
-- built here. Without it the addon would have no way in, so it gets its own
-- minimap button (left-click opens the window, drag to move it round the
-- minimap) plus the /jrb slash command, which always works. The button can be
-- hidden from the Cfg panel or with /jrb minimap; its state lives in
-- JohnnysRaidBrowserDB.minimap = { hide =, angle = }.
local NS = JohnnysRaidBrowser

local MINIMAP_RADIUS = 80
local DEFAULT_ANGLE = 165

local button

local function MinimapDB()
	JohnnysRaidBrowserDB = JohnnysRaidBrowserDB or {}
	JohnnysRaidBrowserDB.minimap = JohnnysRaidBrowserDB.minimap or {}
	return JohnnysRaidBrowserDB.minimap
end

-- Sits on the minimap's edge at the saved angle: on the circle for the round
-- Blizzard minimap, on the border for square ones (ElvUI, SexyMap and others
-- report "SQUARE" through GetMinimapShape).
local function Position()
	local a = math.rad(MinimapDB().angle or DEFAULT_ANGLE)
	local dx, dy = math.cos(a), math.sin(a)
	local halfW = (Minimap:GetWidth() or (MINIMAP_RADIUS * 2)) / 2
	local halfH = (Minimap:GetHeight() or (MINIMAP_RADIUS * 2)) / 2
	local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
	local x, y
	if square then
		local m = math.max(math.abs(dx), math.abs(dy))
		x, y = dx / m * halfW, dy / m * halfH
	else
		x, y = dx * (halfW + 10), dy * (halfH + 10)
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function Build()
	button = CreateFrame("Button", "JohnnysRaidBrowserMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	-- The JRB magnifier logo (Media\\minimap.tga, 64x64, round with a clear
	-- background).
	icon:SetTexture("Interface\\AddOns\\JohnnysRaidBrowser\\Media\\minimap")
	icon:SetSize(21, 21)
	icon:SetPoint("CENTER", 0, 1)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT", 0, 0)

	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			NS.WindowSettings:Toggle()
		else
			NS.RaidBrowserUI:Toggle()
		end
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Johnny's Raid Browser")
		GameTooltip:AddLine("Left-click: open the raid browser", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Right-click: settings", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Drag to move. /jrb minimap hides this button.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)

	-- Drag round the minimap ring, saving the angle as it goes.
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			MinimapDB().angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			Position()
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	Position()
end

-- Shows or hides the minimap button to match the saved setting. The hub, when
-- installed, is the launcher, so the button only appears without it.
local function Refresh()
	local want = not IsAddOnLoaded("JohnnysAddonHub") and not MinimapDB().hide
	if want then
		if not button then
			Build()
		end
		button:Show()
	elseif button then
		button:Hide()
	end
end

local function SetMinimapShown(shown)
	MinimapDB().hide = not shown or nil
	Refresh()
	if shown and IsAddOnLoaded("JohnnysAddonHub") then
		NS:Print("The minimap button stays hidden while Johnny's Addon Hub is installed - open the raid browser from the hub.")
	end
end

-- "Show minimap button" tick box in the Cfg panel.
NS.WindowSettings:RegisterOption("minimap", "Show minimap button",
	function() return not MinimapDB().hide end,
	function(checked) SetMinimapShown(checked) end)

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", Refresh)

SLASH_JOHNNYSRAIDBROWSER1 = "/jrb"
SLASH_JOHNNYSRAIDBROWSER2 = "/raidbrowser"
SlashCmdList["JOHNNYSRAIDBROWSER"] = function(msg)
	local arg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if arg == "" then
		NS.RaidBrowserUI:Toggle()
	elseif arg == "minimap" then
		SetMinimapShown(MinimapDB().hide and true or false)
	elseif arg == "settings" or arg == "config" or arg == "cfg" then
		NS.WindowSettings:Toggle()
	elseif arg == "changelog" then
		NS.Changelog:Toggle()
	else
		NS:Print("/jrb - open the raid browser. /jrb minimap - show or hide the minimap button. /jrb cfg - settings. /jrb changelog - what's new.")
	end
end
