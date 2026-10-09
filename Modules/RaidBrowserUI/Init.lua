-- A fully custom Raid Browser window, built with plain CreateFrame UI in the
-- suite's flat skin instead of reskinning Blizzard's stock LFRParentFrame.
-- That frame is shared system UI we don't own - fighting its native list
-- layout, textures and window stacking is fragile - so this reads the
-- RaidBrowser addon's already-parsed raid data directly
-- (raid_browser.lfm_messages) and renders it in our own frame, leaving
-- LFRParentFrame untouched and never shown.
--
-- Layout: sortable list on the left (leader, raid, GS requirement, roles
-- needed, age), and on the right what you advertise as, the filters, and the
-- selected raid with its Join / Whisper actions. A lockouts panel is docked
-- to the right edge; clicking one of its raids filters the list to it.
JohnnysRaidBrowser.RaidBrowserUI = {}
local RaidBrowserUI = JohnnysRaidBrowser.RaidBrowserUI
local Skin = JohnnysRaidBrowser.Skin

local FRAME_WIDTH, FRAME_HEIGHT = 760, 550
local ROW_HEIGHT = 22
local LIST_TOP = 40
local LIST_HEIGHT = 430
local RIGHT_WIDTH = 224

local COLUMN_ORDER = { "name", "raid", "gs", "needs", "age" }
local COLUMN_WIDTHS = { name = 130, raid = 140, gs = 50, needs = 80, age = 60 }
local COLUMN_LABELS = { name = "Leader", raid = "Raid", gs = "GS", needs = "Needs", age = "Age" }
-- "Needs" is three letters, not a single value, so it has no sort.
local COLUMN_SORTABLE = { name = true, raid = true, gs = true, age = true }

-- Listings older than this many seconds are dimmed: RaidBrowser drops a
-- listing once its leader hasn't re-advertised for raid_browser.expiry_time
-- (60s), so an old one is about to disappear.
local STALE_SECONDS = 40

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

-- [sender] = time() of your last whisper to that leader this session (Join
-- or Whisper), so a listing you've already answered is marked in the list.
local whispered = {}

local mainFrame, listContent, listScroll, detailText, countText, emptyText
local rows = {}
local headerButtons = {}
local raidsetButtons = {}
local raidsetInfoText, saveRaidsetBtn
local roleFilterButtons = {}
local hideSavedBtn, qualifyBtn
local joinBtn, whisperBtn
local lockoutRows = {}
local lockoutCharButton, lockoutMenu
local selectedLockoutChar
local selectedSender
-- nil = newest first (the default); otherwise one of COLUMN_SORTABLE's keys.
local sortColumn, sortAscending = nil, true
local refreshTicker
-- { instance = "Icecrown Citadel", size = 25, label = "ICC 25" } while the
-- list is narrowed to one raid from the lockouts panel. Session only.
local raidFilter
-- Assigned further down; the lockouts panel and the whisper popup call it.
local RefreshList, RefreshDetail

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
			whispered[self.data] = time()
			if mainFrame and mainFrame:IsShown() then
				RefreshList()
				RefreshDetail()
			end
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

local function NeedsRole(info, role)
	if role == "dps" then
		return NeedsDps(info)
	end
	return HasRole(info, role)
end

-- Role filters, Hide Saved and "I qualify" persist in the SavedVariable so
-- they survive a /reload. Role filters are OR'd together (any raid matching
-- at least one checked role passes); with none checked, every raid passes.
local function GetFilters()
	JohnnysRaidBrowserDB = JohnnysRaidBrowserDB or {}
	local db = JohnnysRaidBrowserDB
	db.filters = db.filters or {}
	db.filters.roles = db.filters.roles or {}
	return db.filters
end

-- What you'd be advertised as: RaidBrowser's current "raidset" (spec name and
-- GearScore). Either can be nil - no GearScore addon, or a Primary/Secondary
-- set that was never saved. Cached once per RefreshList, not read per row.
local mySpec, myGS, myRoles = nil, nil, { dps = true }

-- Talent-tree names that aren't plain DPS. Blood is listed as both since a
-- Blood DK can be either on this patch.
local SPEC_ROLES = {
	["Protection"] = { tank = true },
	["Feral (Bear)"] = { tank = true },
	["Holy"] = { healer = true },
	["Discipline"] = { healer = true },
	["Restoration"] = { healer = true },
	["Blood"] = { tank = true, dps = true },
}

local function RefreshMyRaidset()
	local ok, spec, gs = pcall(raid_browser.stats.current_raidset)
	if ok then
		mySpec, myGS = spec, tonumber(gs)
	else
		mySpec, myGS = nil, nil
	end
	myRoles = (mySpec and SPEC_ROLES[mySpec]) or { dps = true }
end

-- GearScore requirement in points. RaidBrowser stores it as text in
-- thousands ("5.8"), or blank when the advert named none.
local function RequiredGS(info)
	local n = tonumber(info.gs)
	if not n then
		return nil
	end
	if n < 100 then
		n = n * 1000
	end
	return n
end

local function MeetsGS(info)
	local required = RequiredGS(info)
	if not required or not myGS then
		return true
	end
	return myGS >= required
end

local function NeedsMe(info)
	for role in pairs(myRoles) do
		if NeedsRole(info, role) then
			return true
		end
	end
	return false
end

local function Qualifies(info)
	return MeetsGS(info) and NeedsMe(info) and not IsSaved(info)
end

local function PassesFilters(info)
	local filters = GetFilters()

	if next(filters.roles) then
		local matches = false
		for role in pairs(filters.roles) do
			if NeedsRole(info, role) then
				matches = true
				break
			end
		end
		if not matches then
			return false
		end
	end

	if filters.hideSaved and IsSaved(info) then
		return false
	end

	if filters.qualifyOnly and not Qualifies(info) then
		return false
	end

	if raidFilter then
		local raid = info.raid_info
		if not raid or not raid.instance_name
			or string.lower(raid.instance_name) ~= string.lower(raidFilter.instance)
			or raid.size ~= raidFilter.size then
			return false
		end
	end

	return true
end

local function SortValue(info, column)
	if column == "gs" then
		return RequiredGS(info) or 0
	elseif column == "raid" then
		return (info.raid_info and info.raid_info.name) or ""
	elseif column == "age" then
		return time() - (info.time or 0)
	end
	return string.lower(info.sender or "")
end

local function GetSortedMessages()
	local list = {}
	for _, info in pairs(raid_browser.lfm_messages) do
		table.insert(list, info)
	end
	if sortColumn then
		table.sort(list, function(a, b)
			local av, bv = SortValue(a, sortColumn), SortValue(b, sortColumn)
			if av == bv then
				return (a.time or 0) > (b.time or 0)
			end
			if sortAscending then
				return av < bv
			end
			return av > bv
		end)
	else
		table.sort(list, function(a, b) return (a.time or 0) > (b.time or 0) end)
	end
	return list
end

-- "T  H  D": bright for a role the raid wants, lime if that's also a role
-- you'd fill, and nearly invisible for one it doesn't want.
local NEED_LETTERS = { { "tank", "T" }, { "healer", "H" }, { "dps", "D" } }
local function NeedsText(info)
	local parts = {}
	for _, entry in ipairs(NEED_LETTERS) do
		local color = "36434a"
		if NeedsRole(info, entry[1]) then
			color = myRoles[entry[1]] and "b9e24a" or "e6ecea"
		end
		table.insert(parts, "|cff" .. color .. entry[2] .. "|r")
	end
	return table.concat(parts, "   ")
end

local function AgeText(seconds)
	if seconds < 60 then
		return seconds .. "s"
	end
	return math.floor(seconds / 60) .. "m"
end

-- A Skin button that stays lit (lime border, lighter fill) while isOn()
-- returns true. StyleButton's own OnMouseUp repaints the idle fill, so the
-- look is re-applied from there as well as from callers.
local function PaintToggle(btn, on)
	local C = Skin.C
	if on then
		btn:SetBackdropColor(0.122, 0.153, 0.169, 0.95)
		btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
		btn.text:SetTextColor(C.text[1], C.text[2], C.text[3])
	else
		btn:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 0.95)
		btn:SetBackdropBorderColor(C.rule2[1], C.rule2[2], C.rule2[3], 1)
		btn.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
	end
end

local function MakeToggle(btn, isOn)
	btn.isOn = isOn
	btn:SetScript("OnMouseUp", function(self) PaintToggle(self, self.isOn()) end)
	PaintToggle(btn, isOn())
end

-- Greys a Skin button out and stops it responding, or restores it. `primary`
-- buttons are the filled lime main action while enabled.
local function SetButtonEnabled(btn, enabled, primary)
	local C = Skin.C
	if enabled then
		btn:Enable()
		if primary then
			btn:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 1)
			btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
			btn.text:SetTextColor(C.ground[1], C.ground[2], C.ground[3])
		else
			btn:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 0.95)
			btn:SetBackdropBorderColor(C.rule2[1], C.rule2[2], C.rule2[3], 1)
			btn.text:SetTextColor(C.text[1], C.text[2], C.text[3])
		end
	else
		btn:Disable()
		btn:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 0.95)
		btn:SetBackdropBorderColor(C.rule[1], C.rule[2], C.rule[3], 1)
		btn.text:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
	end
end

local function RefreshSelectionHighlight()
	for _, row in ipairs(rows) do
		if row.sender and row.sender == selectedSender then
			row:SetBackdropColor(0.122, 0.153, 0.169, 0.9)
		else
			row:SetBackdropColor(0, 0, 0, 0)
		end
	end
end

-- The whisper Join would send, or nil plus a reason when RaidBrowser can't
-- build one (it needs your GearScore and spec - see build_inv_string).
local function BuildJoinMessage(info)
	local ok, message = pcall(raid_browser.stats.build_inv_string, info.raid_info.name)
	if ok and message then
		return message
	end
	return nil
end

RefreshDetail = function()
	local info = selectedSender and raid_browser.lfm_messages[selectedSender]
	if not info then
		if selectedSender then
			detailText:SetText("That listing has expired - its leader hasn't advertised again in the last minute.")
		else
			detailText:SetText("Select a raid from the list to see its details here. Double-click a raid to join it straight away.")
		end
		SetButtonEnabled(joinBtn, false, true)
		SetButtonEnabled(whisperBtn, selectedSender ~= nil)
		return
	end

	local roleList = {}
	for _, entry in ipairs(NEED_LETTERS) do
		if NeedsRole(info, entry[1]) then
			table.insert(roleList, entry[1] == "dps" and "DPS" or (entry[1] == "tank" and "Tank" or "Healer"))
		end
	end

	local locked = IsSaved(info)
	local lr, lg, lb = NameColor(info.sender)
	local required = RequiredGS(info)

	local gsLine = required and tostring(required) or "none stated"
	if required and myGS then
		if myGS >= required then
			gsLine = gsLine .. "  |cffb9e24a(you: " .. myGS .. ")|r"
		else
			gsLine = gsLine .. "  |cffff7366(you: " .. myGS .. ")|r"
		end
	end

	local lines = {
		string.format("|cffffffffLeader:|r |cff%02x%02x%02x%s|r", lr * 255, lg * 255, lb * 255, info.sender),
		"|cffffffffRaid:|r " .. info.raid_info.name,
		"|cffffffffGS required:|r " .. gsLine,
		"|cffffffffNeeds:|r " .. (next(roleList) and table.concat(roleList, ", ") or "unknown"),
		"|cffffffffSaved:|r " .. (locked and "|cffff7366Yes - you are locked to this raid|r" or "No"),
	}
	if whispered[info.sender] then
		table.insert(lines, "|cffb9e24aYou whispered " .. AgeText(time() - whispered[info.sender]) .. " ago|r")
	end
	table.insert(lines, "")
	table.insert(lines, "|cffffffffAdvert:|r")
	table.insert(lines, info.message or "")

	local joinMessage = BuildJoinMessage(info)
	table.insert(lines, "")
	if joinMessage then
		table.insert(lines, "|cffffffffJoin sends:|r")
		table.insert(lines, joinMessage)
	else
		table.insert(lines, "|cffff7366Join is unavailable:|r RaidBrowser has no GearScore or spec for the set you advertise as.")
	end

	detailText:SetText(table.concat(lines, "\n"))
	SetButtonEnabled(joinBtn, joinMessage ~= nil, true)
	SetButtonEnabled(whisperBtn, true)
end

local function OnJoinClick()
	if not selectedSender then return end
	local info = raid_browser.lfm_messages[selectedSender]
	if not info then return end
	local message = BuildJoinMessage(info)
	if not message then
		JohnnysRaidBrowser:Print("Can't build the join whisper - RaidBrowser has no GearScore or spec for the set you advertise as.")
		return
	end
	SendChatMessage(message, "WHISPER", nil, selectedSender)
	whispered[selectedSender] = time()
	RefreshList()
	RefreshDetail()
end

local function OnSendMessageClick()
	if not selectedSender then return end
	StaticPopup_Show("JAHUB_RAIDBROWSER_MSG", selectedSender, nil, selectedSender)
end

local function LayoutRows()
	for i, row in ipairs(rows) do
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", listContent, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
	end
	listContent:SetHeight(math.max(20, #rows * ROW_HEIGHT))
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

	-- Lime bar down the left edge once you've whispered this leader.
	row.sentBar = Skin:Solid(row, "ARTWORK", Skin.C.accent)
	row.sentBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
	row.sentBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
	row.sentBar:SetWidth(2)
	row.sentBar:Hide()

	for _, key in ipairs(COLUMN_ORDER) do
		local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", row, "LEFT", ColumnX(key) + 6, 0)
		fs:SetWidth(COLUMN_WIDTHS[key] - 10)
		fs:SetJustifyH("LEFT")
		row[key] = fs
	end

	row:SetScript("OnClick", function(self)
		selectedSender = self.sender
		RefreshSelectionHighlight()
		RefreshDetail()
	end)
	row:SetScript("OnDoubleClick", function(self)
		selectedSender = self.sender
		RefreshSelectionHighlight()
		OnJoinClick()
	end)
	row:SetScript("OnEnter", function(self)
		if not self.sender then return end
		local info = raid_browser.lfm_messages[self.sender]
		if not info then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(info.message, 1, 1, 1, true)
		GameTooltip:AddLine(string.format("Last advertised %d seconds ago", time() - info.time))
		if whispered[self.sender] then
			GameTooltip:AddLine("You whispered this leader " .. AgeText(time() - whispered[self.sender]) .. " ago", 0.725, 0.886, 0.290)
		end
		GameTooltip:AddLine("Double-click to join", 0.6, 0.66, 0.65)
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

-- Saved raids first (soonest reset on top), then everything still open,
-- dimmed - so what you're locked to is readable without scanning 18 rows of
-- red and green. Saved rows say when they reset; open ones just say "open".
local function RefreshLockouts()
	if not lockoutCharButton then return end
	local C = Skin.C

	local db = GetLockoutDB()
	if not selectedLockoutChar or not db[selectedLockoutChar] then
		selectedLockoutChar = CharacterKey()
	end
	lockoutCharButton.text:SetText(CharacterLabel(selectedLockoutChar) .. "  v")

	local char = db[selectedLockoutChar]
	local raids = char and char.raids or {}
	local now = time()

	local saved, open = {}, {}
	for _, raid in ipairs(LOCKOUT_RAIDS) do
		local resetAt = raids[LockoutKey(raid.instance, raid.size)]
		if resetAt and resetAt > now then
			table.insert(saved, { raid = raid, left = resetAt - now })
		else
			table.insert(open, { raid = raid })
		end
	end
	table.sort(saved, function(a, b) return a.left < b.left end)

	local index = 0
	local function Paint(entry)
		index = index + 1
		local row = lockoutRows[index]
		if not row then return end
		row.raid = entry.raid
		row.label:SetText(entry.raid.label)
		if entry.left then
			row.label:SetTextColor(C.short[1], C.short[2], C.short[3])
			row.status:SetTextColor(C.short[1], C.short[2], C.short[3])
			row.status:SetText(FormatReset(entry.left))
		else
			row.label:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
			row.status:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
			row.status:SetText("open")
		end
		if raidFilter and raidFilter.label == entry.raid.label then
			row.bar:Show()
			row.bg:Show()
		else
			row.bar:Hide()
			row.bg:Hide()
		end
	end
	for _, entry in ipairs(saved) do Paint(entry) end
	for _, entry in ipairs(open) do Paint(entry) end
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

RefreshList = function()
	if not raid_browser then return end

	RefreshMyRaidset()
	RefreshLockouts()

	local messages = {}
	local total = 0
	for _, info in ipairs(GetSortedMessages()) do
		total = total + 1
		if PassesFilters(info) then
			table.insert(messages, info)
		end
	end

	local C = Skin.C
	local now = time()
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

		row.raid:SetText(info.raid_info.name)
		if IsSaved(info) then
			row.raid:SetTextColor(C.short[1], C.short[2], C.short[3])
		else
			row.raid:SetTextColor(C.text[1], C.text[2], C.text[3])
		end

		local required = RequiredGS(info)
		row.gs:SetText(required and tostring(required) or "-")
		if MeetsGS(info) then
			row.gs:SetTextColor(C.text[1], C.text[2], C.text[3])
		else
			row.gs:SetTextColor(C.short[1], C.short[2], C.short[3])
		end

		row.needs:SetText(NeedsText(info))

		local age = now - (info.time or now)
		row.age:SetText(AgeText(age))
		row.age:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

		if whispered[info.sender] then
			row.sentBar:Show()
		else
			row.sentBar:Hide()
		end

		-- Dim what you can't get into, and listings about to expire.
		row:SetAlpha((Qualifies(info) and age < STALE_SECONDS) and 1 or 0.55)
		row:Show()
	end

	for i = #messages + 1, #rows do
		rows[i].sender = nil
		rows[i]:Hide()
	end

	RefreshSelectionHighlight()

	local count = (#messages == 1) and "1 RAID" or (#messages .. " RAIDS")
	if #messages < total then
		count = count .. "  OF  " .. total
	end
	if raidFilter then
		count = count .. "  -  " .. string.upper(raidFilter.label) .. " ONLY"
	end
	countText:SetText(count)

	if #messages > 0 then
		emptyText:Hide()
	else
		if total > 0 then
			emptyText:SetText("No advertised raid matches your filters right now. " .. total .. " hidden - loosen the filters on the right to see them.")
		else
			emptyText:SetText("No raids are being advertised right now. Listings appear here as leaders post LFM messages in chat, and drop off a minute after their last post.")
		end
		emptyText:Show()
	end

	if raidsetInfoText then
		local current = raid_browser_character_current_raidset or "Active"
		if mySpec and myGS then
			raidsetInfoText:SetText(mySpec .. ", GS " .. myGS)
		elseif mySpec then
			raidsetInfoText:SetText(mySpec .. ", GS unknown (no GearScore addon)")
		else
			raidsetInfoText:SetText(current .. " has nothing saved yet")
		end
	end
end

local function RefreshHeaders()
	for key, btn in pairs(headerButtons) do
		local label = COLUMN_LABELS[key]
		if key == sortColumn then
			label = label .. (sortAscending and "  ^" or "  v")
			btn.text:SetTextColor(Skin.C.accent[1], Skin.C.accent[2], Skin.C.accent[3])
		else
			btn.text:SetTextColor(Skin.C.text[1], Skin.C.text[2], Skin.C.text[3])
		end
		btn.text:SetText(label)
	end
end

-- First click sorts a column ascending, second descending, third returns to
-- the default newest-first order.
local function SetSort(column)
	if sortColumn ~= column then
		sortColumn, sortAscending = column, true
	elseif sortAscending then
		sortAscending = false
	else
		sortColumn, sortAscending = nil, true
	end
	RefreshHeaders()
	RefreshList()
end

local function RefreshRaidsetButtons()
	local current = raid_browser_character_current_raidset or "Active"
	for key, btn in pairs(raidsetButtons) do
		PaintToggle(btn, key == current)
	end
	-- Saving only applies to the two stored sets; "Active" is always live.
	SetButtonEnabled(saveRaidsetBtn, current ~= "Active")
end

local function SelectRaidset(key)
	raid_browser.stats.select_current_raidset(key)
	RefreshRaidsetButtons()
	RefreshList()
	RefreshDetail()
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
	RefreshList()
	RefreshDetail()
end

local function OnRefreshClick()
	RequestRaidInfo()
	RefreshList()
	RefreshDetail()
end

local function BuildFrame()
	local C = Skin.C
	local filters = GetFilters()

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

	local title = Skin:AddHeader(mainFrame, "Raid Browser")
	countText = Skin:Heading(mainFrame, 12, C.muted)
	countText:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 10, 1)

	local close = Skin:CreateButton(mainFrame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() RaidBrowserUI:Toggle() end)

	-- The update notice anchors itself to its host's top-left corner, which
	-- the title occupies, so give it a host left of the close button.
	local noticeHost = CreateFrame("Frame", nil, mainFrame)
	noticeHost:SetSize(220, Skin.HEADER_HEIGHT)
	noticeHost:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -30, 2)
	JohnnysRaidBrowser.VersionCheck:AttachNotice(noticeHost)

	-- Left: column headers + scrollable raid list.
	local headerX = 16
	for _, key in ipairs(COLUMN_ORDER) do
		local header = Skin:CreateButton(mainFrame, COLUMN_WIDTHS[key], 20, COLUMN_LABELS[key])
		header:SetPoint("TOPLEFT", headerX, -LIST_TOP)
		header.text:ClearAllPoints()
		header.text:SetPoint("LEFT", header, "LEFT", 6, 0)
		if COLUMN_SORTABLE[key] then
			header:SetScript("OnClick", function() SetSort(key) end)
			headerButtons[key] = header
		else
			-- Not sortable, so it shouldn't look or feel like a button.
			header:Disable()
			header:SetBackdropColor(0, 0, 0, 0)
			header:SetBackdropBorderColor(0, 0, 0, 0)
			header.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
		end
		headerX = headerX + COLUMN_WIDTHS[key]
	end

	listScroll = CreateFrame("ScrollFrame", "JohnnysRaidBrowserScroll", mainFrame, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", 16, -(LIST_TOP + 24))
	listScroll:SetSize(LEFT_WIDTH, LIST_HEIGHT)

	listContent = CreateFrame("Frame", nil, listScroll)
	listContent:SetSize(LEFT_WIDTH, 20)
	listScroll:SetScrollChild(listContent)

	emptyText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	emptyText:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 6, -10)
	emptyText:SetWidth(LEFT_WIDTH - 12)
	emptyText:SetJustifyH("LEFT")
	emptyText:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
	emptyText:Hide()

	local refreshBtn = Skin:CreateButton(mainFrame, 90, 24, "Refresh")
	refreshBtn:SetPoint("BOTTOMLEFT", 16, 16)
	refreshBtn:SetScript("OnClick", OnRefreshClick)

	local listHint = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	listHint:SetPoint("LEFT", refreshBtn, "RIGHT", 10, 0)
	listHint:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
	listHint:SetText("Double-click a raid to join. Dimmed raids are ones you can't get into, or are about to expire.")
	listHint:SetWidth(LEFT_WIDTH - 100)
	listHint:SetJustifyH("LEFT")

	-- Right column. Left margin (16) + list width + clearance (40) for the
	-- scrollbar, which renders just outside the scrollframe's own width.
	local rightX = 16 + LEFT_WIDTH + 40

	local function Section(text, y)
		local fs = Skin:Heading(mainFrame, 11, C.muted)
		fs:SetPoint("TOPLEFT", rightX, -y)
		fs:SetText(text)
		local rule = Skin:Solid(mainFrame, "ARTWORK", C.rule)
		rule:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", rightX, -(y + 14))
		rule:SetWidth(RIGHT_WIDTH)
		rule:SetHeight(1)
	end

	-- Which spec/GS your Join whisper advertises.
	Section("ADVERTISE AS", LIST_TOP)
	local raidsetX = rightX
	for _, key in ipairs({ "Active", "Primary", "Secondary" }) do
		local btn = Skin:CreateButton(mainFrame, 72, 20, key)
		btn:SetPoint("TOPLEFT", raidsetX, -(LIST_TOP + 20))
		btn:SetScript("OnClick", function() SelectRaidset(key) end)
		MakeToggle(btn, function() return (raid_browser_character_current_raidset or "Active") == key end)
		raidsetButtons[key] = btn
		raidsetX = raidsetX + 76
	end

	raidsetInfoText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	raidsetInfoText:SetPoint("TOPLEFT", rightX, -(LIST_TOP + 46))
	raidsetInfoText:SetWidth(RIGHT_WIDTH)
	raidsetInfoText:SetJustifyH("LEFT")
	raidsetInfoText:SetTextColor(C.text[1], C.text[2], C.text[3])

	saveRaidsetBtn = Skin:CreateButton(mainFrame, RIGHT_WIDTH, 20, "Save current gear/spec to this set")
	saveRaidsetBtn:SetPoint("TOPLEFT", rightX, -(LIST_TOP + 62))
	saveRaidsetBtn:SetScript("OnClick", SaveRaidset)

	-- Filters: role toggles are multi-select (OR'd together); the other two
	-- are independent. All persist (see GetFilters).
	local filterTop = LIST_TOP + 96
	Section("FILTERS", filterTop)
	local filterX = rightX
	for _, role in ipairs({ "tank", "healer", "dps" }) do
		local label = (role == "dps") and "DPS" or (role:sub(1, 1):upper() .. role:sub(2))
		local btn = Skin:CreateButton(mainFrame, 72, 20, label)
		btn:SetPoint("TOPLEFT", filterX, -(filterTop + 20))
		btn:SetScript("OnClick", function()
			filters.roles[role] = (not filters.roles[role]) or nil
			RefreshList()
		end)
		MakeToggle(btn, function() return filters.roles[role] == true end)
		roleFilterButtons[role] = btn
		filterX = filterX + 76
	end

	hideSavedBtn = Skin:CreateButton(mainFrame, 110, 20, "Hide saved")
	hideSavedBtn:SetPoint("TOPLEFT", rightX, -(filterTop + 44))
	hideSavedBtn:SetScript("OnClick", function()
		filters.hideSaved = not filters.hideSaved
		RefreshList()
	end)
	MakeToggle(hideSavedBtn, function() return filters.hideSaved == true end)

	qualifyBtn = Skin:CreateButton(mainFrame, 110, 20, "Only raids I fit")
	qualifyBtn:SetPoint("LEFT", hideSavedBtn, "RIGHT", 4, 0)
	qualifyBtn:SetScript("OnClick", function()
		filters.qualifyOnly = not filters.qualifyOnly
		RefreshList()
	end)
	MakeToggle(qualifyBtn, function() return filters.qualifyOnly == true end)
	qualifyBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Only raids I fit", 1, 1, 1)
		GameTooltip:AddLine("Shows raids that need your role, whose GearScore requirement you meet, and that you aren't saved to. Your role and GearScore come from the set under Advertise as.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	qualifyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Selected raid: details, then its two actions.
	local detailTop = filterTop + 78
	Section("SELECTED RAID", detailTop)

	detailText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	detailText:SetPoint("TOPLEFT", rightX, -(detailTop + 22))
	-- Explicit width (not just a RIGHT anchor) so the advert word-wraps onto
	-- multiple lines instead of being truncated with "..." at the edge.
	detailText:SetWidth(RIGHT_WIDTH)
	-- Fixed height so a long advert is cut off above the Join/Whisper buttons
	-- rather than running over them (the row tooltip still shows it in full).
	detailText:SetHeight(FRAME_HEIGHT - (detailTop + 22) - 52)
	detailText:SetJustifyH("LEFT")
	detailText:SetJustifyV("TOP")
	detailText:SetTextColor(C.muted[1], C.muted[2], C.muted[3])

	joinBtn = Skin:CreateButton(mainFrame, 110, 24, "Join")
	joinBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", rightX, 16)
	joinBtn:SetScript("OnClick", OnJoinClick)
	-- Keep the filled look through StyleButton's press/release repaint.
	joinBtn:SetScript("OnMouseDown", nil)
	joinBtn:SetScript("OnMouseUp", nil)

	whisperBtn = Skin:CreateButton(mainFrame, 110, 24, "Whisper")
	whisperBtn:SetPoint("LEFT", joinBtn, "RIGHT", 4, 0)
	whisperBtn:SetScript("OnClick", OnSendMessageClick)

	-- Lockout side panel, docked to the window's right edge. As a child of
	-- mainFrame it drags, shows and hides along with it.
	local lockoutPanel = CreateFrame("Frame", nil, mainFrame)
	lockoutPanel:SetSize(LOCKOUT_PANEL_WIDTH, FRAME_HEIGHT)
	lockoutPanel:SetPoint("TOPLEFT", mainFrame, "TOPRIGHT", 4, 0)
	Skin:StylePanel(lockoutPanel, 0.95)
	Skin:AddHeader(lockoutPanel, "Raid lockouts", 13)

	-- Character picker: a flat button that opens a list of every character
	-- with a recorded lockout snapshot (this one plus any alts logged in
	-- since this feature was added).
	lockoutCharButton = Skin:CreateButton(lockoutPanel, LOCKOUT_PANEL_WIDTH - 28, 20)
	lockoutCharButton:SetPoint("TOP", 0, -38)
	lockoutCharButton:SetScript("OnClick", ToggleLockoutMenu)

	lockoutMenu = CreateFrame("Frame", nil, lockoutPanel)
	lockoutMenu:SetWidth(LOCKOUT_PANEL_WIDTH - 28)
	lockoutMenu:SetPoint("TOP", lockoutCharButton, "BOTTOM", 0, -2)
	lockoutMenu:SetFrameLevel(lockoutPanel:GetFrameLevel() + 10)
	Skin:StylePanel(lockoutMenu, 1)
	lockoutMenu:Hide()

	-- One clickable row per raid+size. RefreshLockouts decides which raid
	-- each row shows (saved ones first); clicking a row narrows the list to
	-- that raid, clicking it again clears the filter.
	for i = 1, #LOCKOUT_RAIDS do
		local row = CreateFrame("Button", nil, lockoutPanel)
		row:SetSize(LOCKOUT_PANEL_WIDTH - 2, 22)
		row:SetPoint("TOPLEFT", 1, -66 - (i - 1) * 22)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetTexture(Skin.WHITE)
		row.bg:SetVertexColor(0.122, 0.153, 0.169, 1)
		row.bg:Hide()

		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture(Skin.WHITE)
		hl:SetVertexColor(1, 1, 1, 0.08)

		row.bar = Skin:Solid(row, "ARTWORK", C.accent)
		row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
		row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
		row.bar:SetWidth(2)
		row.bar:Hide()

		row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.label:SetPoint("LEFT", row, "LEFT", 13, 0)
		row.label:SetJustifyH("LEFT")

		row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.status:SetPoint("RIGHT", row, "RIGHT", -13, 0)
		row.status:SetJustifyH("RIGHT")

		row:SetScript("OnClick", function(self)
			if not self.raid then return end
			if raidFilter and raidFilter.label == self.raid.label then
				raidFilter = nil
			else
				raidFilter = self.raid
			end
			RefreshList()
		end)

		table.insert(lockoutRows, row)
	end

	local lockoutHint = lockoutPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	lockoutHint:SetPoint("BOTTOM", 0, 18)
	lockoutHint:SetWidth(LOCKOUT_PANEL_WIDTH - 20)
	lockoutHint:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
	lockoutHint:SetText("Click a raid to show only its listings.")

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
			RefreshDetail()
		end
	end)

	mainFrame:SetScript("OnShow", function()
		RequestRaidInfo()
		selectedLockoutChar = nil
		RefreshHeaders()
		RefreshRaidsetButtons()
		RefreshList()
		RefreshDetail()
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
