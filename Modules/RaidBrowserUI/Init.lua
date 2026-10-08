-- A fully custom Raid Browser window, built the same way as the Gear Advisor
-- panel (plain CreateFrame UI, flat black/white skin) instead of reskinning
-- Blizzard's stock LFRParentFrame. That frame is shared system UI we don't
-- own - fighting its native list layout, textures and window stacking is
-- fragile - so this reads the RaidBrowser addon's already-parsed raid data
-- directly (raid_browser.lfm_messages) and renders it in our own frame,
-- leaving LFRParentFrame untouched and never shown.
JohnnysRaidBrowser.RaidBrowserUI = {}
local RaidBrowserUI = JohnnysRaidBrowser.RaidBrowserUI
local Skin = JohnnysRaidBrowser.Skin

local FRAME_WIDTH, FRAME_HEIGHT = 760, 550
local ROW_HEIGHT = 22

local COLUMN_ORDER = { "name", "gs", "raid", "tank", "healer", "dps" }
local COLUMN_WIDTHS = { name = 130, gs = 50, raid = 130, tank = 50, healer = 50, dps = 50 }
local COLUMN_LABELS = { name = "Name", gs = "GS", raid = "Raid", tank = "Tank", healer = "Healer", dps = "DPS" }

-- Lockout side panel: one row per WotLK raid and size. Instance names must
-- match RaidBrowser's raid_list (core.lua) exactly, since lock status comes
-- from the same raid_browser.stats.raid_lock_info lookup the list uses.
local LOCKOUT_PANEL_WIDTH = 170
local LOCKOUT_RAIDS = {}
for _, raid in ipairs({
	{ "ICC", "Icecrown Citadel" },
	{ "ToC", "Trial of the Crusader" },
	{ "RS", "The Ruby Sanctum" },
	{ "VoA", "Vault of Archavon" },
	{ "Ulduar", "Ulduar" },
	{ "Naxx", "Naxxramas" },
	{ "OS", "The Obsidian Sanctum" },
	{ "EoE", "The Eye of Eternity" },
	{ "Onyxia", "Onyxia's Lair" },
}) do
	for _, size in ipairs({ 10, 25 }) do
		table.insert(LOCKOUT_RAIDS, { label = raid[1] .. " " .. size, instance = raid[2], size = size })
	end
end

-- The scrollframe's own width must equal its content/row width exactly (that's
-- how the working scrollframes elsewhere in this addon are set up) - the
-- scrollbar renders in the margin AFTER this width, not inside it. Sizing rows
-- wider than this (as an earlier version did) gets the overflow clipped by the
-- scrollframe, which was cutting off the DPS column.
local LEFT_WIDTH = 0
for _, key in ipairs(COLUMN_ORDER) do
	LEFT_WIDTH = LEFT_WIDTH + COLUMN_WIDTHS[key]
end

local function ColumnX(key)
	local x = 0
	for _, k in ipairs(COLUMN_ORDER) do
		if k == key then return x end
		x = x + COLUMN_WIDTHS[k]
	end
	return x
end

StaticPopupDialogs["JAHUB_RAIDBROWSER_MSG"] = {
	text = "Send a whisper to %s:",
	button1 = "Send",
	button2 = "Cancel",
	hasEditBox = true,
	maxLetters = 255,
	OnAccept = function(self)
		local text = self.editBox and self.editBox:GetText()
		if text and text ~= "" and self.data then
			SendChatMessage(text, "WHISPER", nil, self.data)
		end
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		StaticPopupDialogs["JAHUB_RAIDBROWSER_MSG"].OnAccept(parent)
		parent:Hide()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local mainFrame, listContent, listScroll, detailText, statusText
local rows = {}
local raidsetButtons = {}
local roleFilterButtons = {}
local hideSavedBtn
local lockoutRows = {}
local lockoutCharButton, lockoutMenu
local selectedLockoutChar
local selectedSender
local sortColumn, sortAscending = nil, false
local refreshTicker

-- Class-colored names: lfm_messages carries no class info, but CHAT_MSG_CHANNEL
-- and CHAT_MSG_YELL (the same two events RaidBrowser's core.lua listens to for
-- LFM detection) carry the sender's GUID as their 12th payload arg, and
-- GetPlayerInfoByGUID resolves any GUID the client has seen - which includes
-- just having received a message from it. This is the same mechanism behind
-- Blizzard's own class-colored chat names, so every raid in the list ends up
-- colored once its LFM message has come in, no group/guild membership needed.
local nameToClass = {}
local classWatcher = CreateFrame("Frame")
classWatcher:RegisterEvent("CHAT_MSG_CHANNEL")
classWatcher:RegisterEvent("CHAT_MSG_YELL")
classWatcher:SetScript("OnEvent", function(self, event, message, sender,
	language, channelName, target, flags, zoneChannelID, channelIndex,
	channelBaseName, languageID, lineID, guid)
	if sender and guid and guid ~= "" then
		local _, class = GetPlayerInfoByGUID(guid)
		if class then
			nameToClass[sender] = class
		end
	end
end)

-- Role filters are OR'd together (any raid matching at least one checked role
-- passes) when one or more is active; with none active, every raid passes.
local activeRoleFilters = {}
local hideSaved = false

local function LayoutRows()
	for i, row in ipairs(rows) do
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
	end
	listContent:SetHeight(math.max(20, #rows * ROW_HEIGHT))
end

local function HasRole(info, role)
	for _, r in pairs(info.roles or {}) do
		if r == role then
			return true
		end
	end
	return false
end

-- DPS is stored as one of three possible role strings depending on how the
-- LFM message was parsed, so anything needing "is this raid looking for a
-- DPS" checks all three instead of a single exact match.
local function NeedsDps(info)
	return HasRole(info, "dps") or HasRole(info, "melee_dps") or HasRole(info, "ranged_dps")
end

local function IsSaved(info)
	return raid_browser.stats.raid_lock_info(info.raid_info.instance_name, info.raid_info.size)
end

local function NameColor(sender)
	local color = RAID_CLASS_COLORS[nameToClass[sender]]
	if color then
		return color.r, color.g, color.b
	end
	return 1, 1, 1
end

local function PassesFilters(info)
	if next(activeRoleFilters) then
		local matches = false
		for role in pairs(activeRoleFilters) do
			if (role == "dps" and NeedsDps(info)) or HasRole(info, role) then
				matches = true
				break
			end
		end
		if not matches then
			return false
		end
	end

	if hideSaved and IsSaved(info) then
		return false
	end

	return true
end

local function SortValue(info, column)
	if column == "gs" then
		return tonumber(info.gs) or 0
	elseif column == "raid" then
		return (info.raid_info and info.raid_info.name) or ""
	end
	return info.sender or ""
end

local function GetSortedMessages()
	local list = {}
	for _, info in pairs(raid_browser.lfm_messages) do
		table.insert(list, info)
	end
	if sortColumn then
		table.sort(list, function(a, b)
			local av, bv = SortValue(a, sortColumn), SortValue(b, sortColumn)
			if sortAscending then
				return av > bv
			end
			return av < bv
		end)
	else
		table.sort(list, function(a, b) return a.time > b.time end)
	end
	return list
end

local function RefreshSelectionHighlight()
	for _, row in ipairs(rows) do
		if row.sender and row.sender == selectedSender then
			row:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
		else
			row:SetBackdropColor(0, 0, 0, 0)
		end
	end
end

local function RefreshDetail()
	if not selectedSender then
		detailText:SetText("Select a raid from the list to see its full details here.")
		return
	end

	local info = raid_browser.lfm_messages[selectedSender]
	if not info then
		selectedSender = nil
		detailText:SetText("That raid listing is no longer active.")
		return
	end

	local roleList = {}
	for _, r in pairs(info.roles or {}) do
		table.insert(roleList, r)
	end

	local locked = IsSaved(info)
	local lr, lg, lb = NameColor(info.sender)

	local lines = {
		string.format("|cffffffffLeader:|r |cff%02x%02x%02x%s|r", lr * 255, lg * 255, lb * 255, info.sender),
		"|cffffffffRaid:|r " .. info.raid_info.name,
		"|cffffffffGS:|r " .. tostring(info.gs or "?"),
		"|cffffffffRoles needed:|r " .. (next(roleList) and table.concat(roleList, ", ") or "unknown"),
		"|cffffffffSaved:|r " .. (locked and "|cffff4040Yes|r" or "|cff40ff40No|r"),
		"",
		"|cffffffffMessage:|r",
		info.message or "",
	}
	detailText:SetText(table.concat(lines, "\n"))
end

local function CreateRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(LEFT_WIDTH, ROW_HEIGHT)
	row:SetBackdrop({ bgFile = Skin.WHITE })
	row:SetBackdropColor(0, 0, 0, 0)

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture(Skin.WHITE)
	highlight:SetVertexColor(1, 1, 1, 0.08)

	for _, key in ipairs(COLUMN_ORDER) do
		local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", row, "LEFT", ColumnX(key) + 4, 0)
		fs:SetWidth(COLUMN_WIDTHS[key] - 8)
		if key == "name" or key == "gs" or key == "raid" then
			fs:SetJustifyH("LEFT")
		else
			fs:SetJustifyH("CENTER")
		end
		row[key] = fs
	end

	row:SetScript("OnClick", function(self)
		selectedSender = self.sender
		RefreshSelectionHighlight()
		RefreshDetail()
	end)
	row:SetScript("OnEnter", function(self)
		if not self.sender then return end
		local info = raid_browser.lfm_messages[self.sender]
		if not info then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(info.message, 1, 1, 1, true)
		GameTooltip:AddLine(string.format("Last sent: %d seconds ago", time() - info.time))
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	return row
end

local function FormatReset(seconds)
	if not seconds or seconds <= 0 then return "Saved" end
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	if days > 0 then
		return string.format("%dd %dh", days, hours)
	end
	local minutes = math.floor((seconds % 3600) / 60)
	return string.format("%dh %dm", hours, minutes)
end

-- Per-character lockout snapshots, kept in the JohnnysRaidBrowserDB
-- SavedVariable so alts' lockouts can be viewed from any character. Each
-- character's entry is rewritten from GetSavedInstanceInfo whenever the server
-- sends fresh instance info, and stores absolute reset timestamps, so an alt's
-- lockout turns back to "available" on its own once its reset time passes.
-- Same name/size matching as raid_browser.stats.raid_lock_info.
local function LockoutKey(instanceName, size)
	return string.lower(instanceName) .. ":" .. tostring(size)
end

local function CharacterKey()
	return UnitName("player") .. " - " .. GetRealmName()
end

local function GetLockoutDB()
	JohnnysRaidBrowserDB = JohnnysRaidBrowserDB or {}
	JohnnysRaidBrowserDB.lockouts = JohnnysRaidBrowserDB.lockouts or {}
	return JohnnysRaidBrowserDB.lockouts
end

local function RecordLockouts()
	local raids = {}
	local now = time()
	for i = 1, GetNumSavedInstances() do
		local name, _, reset, _, locked, _, _, _, size = GetSavedInstanceInfo(i)
		if name and locked and reset and reset > 0 then
			raids[LockoutKey(name, size)] = now + reset
		end
	end

	local _, class = UnitClass("player")
	GetLockoutDB()[CharacterKey()] = {
		name = UnitName("player"),
		realm = GetRealmName(),
		class = class,
		raids = raids,
	}
end

local function CharacterLabel(key)
	local char = GetLockoutDB()[key]
	if not char then return key end
	local label = char.realm == GetRealmName() and char.name or key
	local color = RAID_CLASS_COLORS[char.class]
	if color then
		return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, label)
	end
	return label
end

local function RefreshLockouts()
	if not lockoutCharButton then return end

	local db = GetLockoutDB()
	if not selectedLockoutChar or not db[selectedLockoutChar] then
		selectedLockoutChar = CharacterKey()
	end
	lockoutCharButton.text:SetText(CharacterLabel(selectedLockoutChar) .. "  v")

	local char = db[selectedLockoutChar]
	local raids = char and char.raids or {}
	local now = time()
	for _, row in ipairs(lockoutRows) do
		local resetAt = raids[LockoutKey(row.raid.instance, row.raid.size)]
		if resetAt and resetAt > now then
			row.label:SetTextColor(1, 0.3, 0.3)
			row.status:SetTextColor(1, 0.3, 0.3)
			row.status:SetText(FormatReset(resetAt - now))
		else
			row.label:SetTextColor(0.3, 1, 0.3)
			row.status:SetTextColor(0.3, 1, 0.3)
			row.status:SetText("Available")
		end
	end
end

-- Records lockouts on every login/zone change, whether or not the window is
-- open, so each alt's snapshot is current as of the last time it was played.
local lockoutRecorder = CreateFrame("Frame")
lockoutRecorder:RegisterEvent("PLAYER_ENTERING_WORLD")
lockoutRecorder:RegisterEvent("UPDATE_INSTANCE_INFO")
lockoutRecorder:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_ENTERING_WORLD" then
		RequestRaidInfo()
		return
	end
	RecordLockouts()
	if mainFrame and mainFrame:IsShown() then
		RefreshLockouts()
	end
end)

local function ToggleLockoutMenu()
	if lockoutMenu:IsShown() then
		lockoutMenu:Hide()
		return
	end

	local keys = {}
	for key in pairs(GetLockoutDB()) do
		table.insert(keys, key)
	end
	table.sort(keys)

	lockoutMenu.buttons = lockoutMenu.buttons or {}
	for i, key in ipairs(keys) do
		local btn = lockoutMenu.buttons[i]
		if not btn then
			btn = Skin:CreateButton(lockoutMenu, lockoutCharButton:GetWidth() - 4, 20)
			btn:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 20)
			lockoutMenu.buttons[i] = btn
		end
		btn.text:SetText(CharacterLabel(key))
		btn:SetScript("OnClick", function()
			selectedLockoutChar = key
			lockoutMenu:Hide()
			RefreshLockouts()
		end)
		btn:Show()
	end
	for i = #keys + 1, #lockoutMenu.buttons do
		lockoutMenu.buttons[i]:Hide()
	end

	lockoutMenu:SetHeight(#keys * 20 + 4)
	lockoutMenu:Show()
end

local function RefreshList()
	if not raid_browser then return end

	RefreshLockouts()

	local messages = {}
	for _, info in ipairs(GetSortedMessages()) do
		if PassesFilters(info) then
			table.insert(messages, info)
		end
	end

	for i, info in ipairs(messages) do
		local row = rows[i]
		if not row then
			row = CreateRow(listContent)
			rows[i] = row
			LayoutRows()
		end

		row.sender = info.sender
		row.name:SetText(info.sender)
		row.name:SetTextColor(NameColor(info.sender))
		row.gs:SetText(tostring(info.gs or "?"))

		row.raid:SetText(info.raid_info.name)
		if IsSaved(info) then
			row.raid:SetTextColor(1, 0.3, 0.3)
		else
			row.raid:SetTextColor(0.3, 1, 1)
		end

		row.tank:SetText(HasRole(info, "tank") and "Yes" or "")
		row.healer:SetText(HasRole(info, "healer") and "Yes" or "")
		row.dps:SetText(NeedsDps(info) and "Yes" or "")

		row:Show()
	end

	for i = #messages + 1, #rows do
		rows[i].sender = nil
		rows[i]:Hide()
	end

	RefreshSelectionHighlight()
	statusText:SetText(#messages .. " raid(s) found")
end

local function SetSort(column)
	if sortColumn == column then
		sortAscending = not sortAscending
	else
		sortColumn = column
		sortAscending = false
	end
	RefreshList()
end

local function RefreshRaidsetButtons()
	local current = raid_browser_character_current_raidset or "Active"
	for key, btn in pairs(raidsetButtons) do
		if key == current then
			btn:SetBackdropColor(0.22, 0.22, 0.22, 0.95)
		else
			btn:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
		end
	end
end

local function SelectRaidset(key)
	raid_browser.stats.select_current_raidset(key)
	RefreshRaidsetButtons()
end

local function SaveRaidset()
	local current = raid_browser_character_current_raidset
	if current ~= "Primary" and current ~= "Secondary" then
		JohnnysRaidBrowser:Print("Select Primary or Secondary above before saving your current gear/spec to it.")
		return
	end
	if current == "Primary" then
		raid_browser.stats.save_primary_raidset()
	else
		raid_browser.stats.save_secondary_raidset()
	end
	local spec, gs = raid_browser.stats.current_raidset()
	JohnnysRaidBrowser:Print("Raid gear saved: " .. tostring(spec) .. " " .. tostring(gs) .. "gs")
end

local function OnJoinClick()
	if not selectedSender then return end
	local info = raid_browser.lfm_messages[selectedSender]
	if not info then return end
	local message = raid_browser.stats.build_inv_string(info.raid_info.name)
	SendChatMessage(message, "WHISPER", nil, selectedSender)
end

local function OnSendMessageClick()
	if not selectedSender then return end
	StaticPopup_Show("JAHUB_RAIDBROWSER_MSG", selectedSender, nil, selectedSender)
end

local function OnRefreshClick()
	RequestRaidInfo()
	RefreshList()
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "JohnnysRaidBrowserFrame", UIParent)
	mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	-- Leave room on the right for the docked lockout panel.
	mainFrame:SetPoint("RIGHT", UIParent, "RIGHT", -(20 + LOCKOUT_PANEL_WIDTH + 4), 0)
	mainFrame:SetFrameStrata("DIALOG")
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
	mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
	Skin:StylePanel(mainFrame, 0.95)
	mainFrame:Hide()

	local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Raid Browser")

	local close = Skin:CreateButton(mainFrame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() RaidBrowserUI:Toggle() end)

	JohnnysRaidBrowser.VersionCheck:AttachNotice(mainFrame)

	-- Left panel: sortable column headers + scrollable raid list.
	local headerX = 16
	for _, key in ipairs(COLUMN_ORDER) do
		local header = Skin:CreateButton(mainFrame, COLUMN_WIDTHS[key], 20, COLUMN_LABELS[key])
		header:SetPoint("TOPLEFT", headerX, -50)
		if key == "name" or key == "gs" or key == "raid" then
			header:SetScript("OnClick", function() SetSort(key) end)
		end
		headerX = headerX + COLUMN_WIDTHS[key]
	end

	listScroll = CreateFrame("ScrollFrame", "JohnnysRaidBrowserScroll", mainFrame, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", 16, -74)
	listScroll:SetSize(LEFT_WIDTH, 400)

	listContent = CreateFrame("Frame", nil, listScroll)
	listContent:SetSize(LEFT_WIDTH, 20)
	listScroll:SetScrollChild(listContent)

	-- Right panel: which spec/GS to advertise, filters, and the selected raid's
	-- details. Left margin (16) + list width + extra clearance (40) for the
	-- scrollbar, which renders just outside the scrollframe's own width.
	local rightX = 16 + LEFT_WIDTH + 40

	local raidsetLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	raidsetLabel:SetPoint("TOPLEFT", rightX, -50)
	raidsetLabel:SetTextColor(1, 1, 1)
	raidsetLabel:SetText("Advertise as:")

	local raidsetX = rightX
	for _, key in ipairs({ "Active", "Primary", "Secondary" }) do
		local btn = Skin:CreateButton(mainFrame, 72, 20, key)
		btn:SetPoint("TOPLEFT", raidsetX, -68)
		btn:SetScript("OnClick", function() SelectRaidset(key) end)
		raidsetButtons[key] = btn
		raidsetX = raidsetX + 76
	end

	local saveBtn = Skin:CreateButton(mainFrame, 224, 20, "Save Current Gear/Spec")
	saveBtn:SetPoint("TOPLEFT", rightX, -92)
	saveBtn:SetScript("OnClick", SaveRaidset)

	-- Filters: role toggles are multi-select (OR'd together), "Hide Saved"
	-- is its own independent toggle. Both just re-run RefreshList on click.
	local filterLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	filterLabel:SetPoint("TOPLEFT", rightX, -124)
	filterLabel:SetTextColor(1, 1, 1)
	filterLabel:SetText("Filter to roles needed:")

	local filterX = rightX
	for _, role in ipairs({ "tank", "healer", "dps" }) do
		local label = role:sub(1, 1):upper() .. role:sub(2)
		local btn = Skin:CreateButton(mainFrame, 72, 20, label)
		btn:SetPoint("TOPLEFT", filterX, -142)
		btn:SetScript("OnClick", function()
			if activeRoleFilters[role] then
				activeRoleFilters[role] = nil
				btn:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
				btn:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
			else
				activeRoleFilters[role] = true
				btn:SetBackdropColor(0.25, 0.25, 0.25, 0.95)
				btn:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
			end
			RefreshList()
		end)
		roleFilterButtons[role] = btn
		filterX = filterX + 76
	end

	hideSavedBtn = Skin:CreateButton(mainFrame, 224, 20, "Hide Saved Raids")
	hideSavedBtn:SetPoint("TOPLEFT", rightX, -166)
	hideSavedBtn:SetScript("OnClick", function()
		hideSaved = not hideSaved
		if hideSaved then
			hideSavedBtn:SetBackdropColor(0.25, 0.25, 0.25, 0.95)
			hideSavedBtn:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
		else
			hideSavedBtn:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
			hideSavedBtn:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
		end
		RefreshList()
	end)

	local detailTitle = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	detailTitle:SetPoint("TOPLEFT", rightX, -198)
	detailTitle:SetTextColor(1, 1, 1)
	detailTitle:SetText("Raid Details")

	detailText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	detailText:SetPoint("TOPLEFT", rightX, -218)
	-- Explicit width (not just a RIGHT anchor) so the Message line word-wraps
	-- onto multiple lines instead of being truncated with "..." at the edge.
	detailText:SetWidth(FRAME_WIDTH - rightX - 16)
	detailText:SetJustifyH("LEFT")
	detailText:SetJustifyV("TOP")
	detailText:SetTextColor(0.85, 0.85, 0.85)
	detailText:SetText("Select a raid from the list to see its full details here.")

	-- Bottom action bar.
	local sendBtn = Skin:CreateButton(mainFrame, 110, 24, "Send Message")
	sendBtn:SetPoint("BOTTOMLEFT", 16, 16)
	sendBtn:SetScript("OnClick", OnSendMessageClick)

	local joinBtn = Skin:CreateButton(mainFrame, 90, 24, "Join")
	joinBtn:SetPoint("LEFT", sendBtn, "RIGHT", 8, 0)
	joinBtn:SetScript("OnClick", OnJoinClick)

	local refreshBtn = Skin:CreateButton(mainFrame, 90, 24, "Refresh")
	refreshBtn:SetPoint("LEFT", joinBtn, "RIGHT", 8, 0)
	refreshBtn:SetScript("OnClick", OnRefreshClick)

	statusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	statusText:SetPoint("BOTTOMRIGHT", -16, 22)
	statusText:SetTextColor(0.7, 0.7, 0.7)
	statusText:SetText("0 raid(s) found")

	-- Lockout side panel, docked to the window's right edge. As a child of
	-- mainFrame it drags, shows and hides along with it.
	local lockoutPanel = CreateFrame("Frame", nil, mainFrame)
	lockoutPanel:SetSize(LOCKOUT_PANEL_WIDTH, FRAME_HEIGHT)
	lockoutPanel:SetPoint("TOPLEFT", mainFrame, "TOPRIGHT", 4, 0)
	Skin:StylePanel(lockoutPanel, 0.95)

	local lockoutTitle = lockoutPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	lockoutTitle:SetPoint("TOP", 0, -18)
	lockoutTitle:SetText("Raid Lockouts")

	-- Character picker: a flat button that opens a list of every character
	-- with a recorded lockout snapshot (this one plus any alts logged in
	-- since this feature was added).
	lockoutCharButton = Skin:CreateButton(lockoutPanel, LOCKOUT_PANEL_WIDTH - 28, 20)
	lockoutCharButton:SetPoint("TOP", 0, -40)
	lockoutCharButton:SetScript("OnClick", ToggleLockoutMenu)

	lockoutMenu = CreateFrame("Frame", nil, lockoutPanel)
	lockoutMenu:SetWidth(LOCKOUT_PANEL_WIDTH - 28)
	lockoutMenu:SetPoint("TOP", lockoutCharButton, "BOTTOM", 0, -2)
	lockoutMenu:SetFrameLevel(lockoutPanel:GetFrameLevel() + 10)
	Skin:StylePanel(lockoutMenu, 1)
	lockoutMenu:Hide()

	for i, raid in ipairs(LOCKOUT_RAIDS) do
		local y = -74 - (i - 1) * 22
		local label = lockoutPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("TOPLEFT", 14, y)
		label:SetJustifyH("LEFT")
		label:SetText(raid.label)

		local status = lockoutPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		status:SetPoint("TOPRIGHT", -14, y)
		status:SetJustifyH("RIGHT")

		table.insert(lockoutRows, { raid = raid, label = label, status = status })
	end

	local lockoutHint = lockoutPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	lockoutHint:SetPoint("BOTTOM", 0, 22)
	lockoutHint:SetTextColor(0.6, 0.6, 0.6)
	lockoutHint:SetText("Red = saved, Green = available")

	-- Raid messages arrive over time via chat, independent of whether this
	-- window is open, so poll for changes while it's shown instead of hooking
	-- into RaidBrowser's own internals.
	refreshTicker = CreateFrame("Frame")
	refreshTicker:Hide()
	local elapsed = 0
	refreshTicker:SetScript("OnUpdate", function(self, e)
		elapsed = elapsed + e
		if elapsed >= 3 then
			elapsed = 0
			RefreshList()
		end
	end)

	mainFrame:SetScript("OnShow", function()
		RequestRaidInfo()
		selectedLockoutChar = nil
		RefreshRaidsetButtons()
		RefreshList()
		refreshTicker:Show()
	end)
	mainFrame:SetScript("OnHide", function()
		lockoutMenu:Hide()
		refreshTicker:Hide()
	end)
end

function RaidBrowserUI:Toggle()
	if not raid_browser or not raid_browser.stats then
		JohnnysRaidBrowser:Print("RaidBrowser addon not found - can't open the raid browser.")
		return
	end

	if not mainFrame then
		BuildFrame()
	end

	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		mainFrame:Show()
	end
end
