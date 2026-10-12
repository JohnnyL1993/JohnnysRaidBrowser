-- Changelog window, opened from the "Changelog" button at the bottom of the
-- Cfg panel (Modules\WindowSettings.lua). Lists what changed in each version,
-- newest first. Versions newer than the one you last opened this window on
-- are tagged NEW, so after an update the fresh entries stand out.
--
-- To add a release: put a new { version =, changes = { ... }, fixes = { ... } }
-- block at the TOP of ENTRIES and bump "## Version" in the .toc to match.
-- `changes` is what's new, `fixes` (optional) is bugs fixed - shown under
-- their own "Changes" / "Bug fixes" sub-headings.
local NS = JohnnysRaidBrowser
NS.Changelog = {}
local Changelog = NS.Changelog
local Skin = NS.Skin

local ENTRIES = {
	{
		version = "1.4",
		changes = {
			"Works without Johnny's Addon Hub: a minimap button opens the raid browser (left-click) or its settings (right-click). Drag it round the minimap to move it.",
			"Slash command: /jrb (or /raidbrowser) opens the window; /jrb minimap shows or hides the minimap button. It can also be turned off in the Cfg panel.",
		},
	},
	{
		version = "1.3",
		changes = {
			"Works on its own now: the raid chat parser is built in, so you no longer need to install RaidBrowser separately. If you already have it installed, your copy is used instead.",
			"New Cfg button: window scale and opacity, this changelog, and a Report a bug / request button.",
			"After an update, this changelog pops up beside the window the first time you open it.",
		},
	},
	{
		version = "1.2",
		changes = {
			"New blue-black \"workshop\" look with a lime accent.",
			"Reworked window: sortable Leader / Raid / GS / Needs / Age columns, filters that are remembered, a preview of your join message, and raids you've whispered marked in the list.",
			"Click a raid in the lockouts panel to show only its listings.",
			"Update checks from all of Johnny's addons share one slow queue, so logging in with several no longer trips the chat mute.",
		},
	},
	{
		version = "1.1",
		changes = {
			"Raid lockouts panel docked to the window: every raid, green when available, red with time to reset when saved. A character picker shows your alts' lockouts too.",
			"In-game \"Update available\" notice when someone with a newer version is seen.",
		},
	},
	{
		version = "1.0",
		changes = {
			"First release: a window listing raids advertised in chat, with role and GS filters and one-click whisper or join.",
		},
	},
}

local FRAME_W, FRAME_H = 460, 440
local PAD = 14

local frame

-- "1.10" > "1.9": compares dot-separated numbers, not text.
local function VersionNewer(a, b)
	local pa, pb = {}, {}
	for n in string.gmatch(tostring(a or ""), "%d+") do
		table.insert(pa, tonumber(n))
	end
	for n in string.gmatch(tostring(b or ""), "%d+") do
		table.insert(pb, tonumber(n))
	end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

local function InstalledVersion()
	return GetAddOnMetadata("JohnnysRaidBrowser", "Version") or "0"
end

-- True while there are entries the player hasn't opened the changelog on yet
-- (drives the "new" marker on the Cfg panel's button).
function Changelog:HasUnseen()
	local seen = JohnnysRaidBrowserDB and JohnnysRaidBrowserDB.changelogSeenVersion
	return VersionNewer(InstalledVersion(), seen or "0")
end

local function Build()
	local C = Skin.C
	frame = CreateFrame("Frame", "JohnnysRaidBrowserChangelog", UIParent)
	frame:SetSize(FRAME_W, FRAME_H)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("FULLSCREEN_DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	Skin:StylePanel(frame, 0.97)
	frame:Hide()
	table.insert(UISpecialFrames, "JohnnysRaidBrowserChangelog") -- Esc closes it

	local title = Skin:AddHeader(frame, "Changelog")
	local sub = Skin:Heading(frame, 12, C.muted)
	sub:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 10, 1)
	sub:SetText("JOHNNY'S RAID BROWSER  /  INSTALLED " .. InstalledVersion())

	local close = Skin:CreateButton(frame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() frame:Hide() end)

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", PAD, 8)
	hint:SetText("Mouse wheel to scroll - newest first.")

	local scroll = CreateFrame("ScrollFrame", nil, frame)
	scroll:SetPoint("TOPLEFT", PAD, -(Skin.HEADER_HEIGHT + 10))
	scroll:SetPoint("BOTTOMRIGHT", -PAD, 30)
	scroll:EnableMouseWheel(true)

	local content = CreateFrame("Frame", nil, scroll)
	local contentW = FRAME_W - PAD * 2
	content:SetWidth(contentW)
	content:SetHeight(10)
	scroll:SetScrollChild(content)

	-- Never shown: no width set, so GetStringWidth gives an entry's full
	-- unwrapped width (see the height calculation below).
	local measure = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	measure:Hide()
	local LINE_H = 13

	local installed = InstalledVersion()
	local seen = (JohnnysRaidBrowserDB and JohnnysRaidBrowserDB.changelogSeenVersion) or "0"
	local y = 0
	for _, entry in ipairs(ENTRIES) do
		local head = Skin:Heading(content, 15, C.accent)
		head:SetPoint("TOPLEFT", 0, -y)
		head:SetText("VERSION " .. entry.version)

		local tag
		if VersionNewer(entry.version, installed) then
			tag = "NOT RELEASED YET"
		elseif entry.version == installed then
			tag = VersionNewer(entry.version, seen) and "NEW  -  THIS VERSION" or "THIS VERSION"
		elseif VersionNewer(entry.version, seen) then
			tag = "NEW"
		end
		if tag then
			local tagText = Skin:Heading(content, 11, C.muted)
			tagText:SetPoint("BOTTOMLEFT", head, "BOTTOMRIGHT", 10, 1)
			tagText:SetText(tag)
			if string.find(tag, "NEW", 1, true) == 1 then
				tagText:SetTextColor(1, 0.85, 0.40)
			end
		end
		y = y + 22

		-- Changes first, then bug fixes. The two sub-headings only appear on a
		-- version that has fixes; one with changes alone is a plain list.
		local hasFixes = entry.fixes and #entry.fixes > 0
		local sections = {
			{ label = "CHANGES", items = entry.changes or {} },
			{ label = "BUG FIXES", items = entry.fixes or {} },
		}
		for _, section in ipairs(sections) do
			if #section.items > 0 then
				if hasFixes then
					local subHead = Skin:Heading(content, 11, C.muted)
					subHead:SetPoint("TOPLEFT", 2, -y)
					subHead:SetText(section.label)
					y = y + 16
				end

				for _, change in ipairs(section.items) do
					local dot = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					dot:SetPoint("TOPLEFT", 2, -y)
					dot:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
					dot:SetText("-")

					local line = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					line:SetPoint("TOPLEFT", 14, -y)
					line:SetWidth(contentW - 18)
					line:SetJustifyH("LEFT")
					line:SetJustifyV("TOP")
					line:SetTextColor(C.text[1], C.text[2], C.text[3])
					line:SetText(change)
					-- GetHeight can report one line for text that only just
					-- wraps onto a second, which made the next entry overlap
					-- it. Cross-check against the text's unwrapped width (with
					-- some slack, since word wrap breaks early) and take the
					-- taller of the two.
					measure:SetText(change)
					local wrapLines = math.ceil(measure:GetStringWidth() / ((contentW - 18) * 0.93))
					y = y + math.max(12, line:GetHeight(), wrapLines * LINE_H) + 6
				end

				if hasFixes then
					y = y + 4
				end
			end
		end

		local rule = Skin:Solid(content, "ARTWORK", C.rule)
		rule:SetPoint("TOPLEFT", 0, -(y + 4))
		rule:SetPoint("TOPRIGHT", 0, -(y + 4))
		rule:SetHeight(1)
		y = y + 16
	end
	content:SetHeight(y)

	scroll:SetScript("OnMouseWheel", function(self, delta)
		local maxScroll = math.max(0, content:GetHeight() - self:GetHeight())
		local target = self:GetVerticalScroll() - delta * 40
		self:SetVerticalScroll(math.max(0, math.min(maxScroll, target)))
	end)
end

-- Docks the window beside the Raid Browser window, tops level, so the two never
-- overlap: on its left if there's room, otherwise on its right (past the lockouts
-- panel docked there). Only if neither side has room - or Raid
-- Comp is closed - does it fall back to the middle of the screen.
local function Place()
	local comp = _G["JohnnysRaidBrowserFrame"]
	frame:ClearAllPoints()
	if comp and comp:IsShown() and comp:GetLeft() then
		-- Everything in real screen pixels, since the windows can be scaled.
		local need = (FRAME_W + 6) * frame:GetEffectiveScale()
		local compScale = comp:GetEffectiveScale()
		if comp:GetLeft() * compScale >= need then
			frame:SetPoint("TOPRIGHT", comp, "TOPLEFT", -6, 0)
			return
		end

		local edge, edgeScale = comp, compScale
		local spam = _G["JohnnysRaidBrowserLockouts"]
		if spam and spam:IsShown() and spam:GetRight()
			and spam:GetRight() * spam:GetEffectiveScale() > comp:GetRight() * compScale then
			edge, edgeScale = spam, spam:GetEffectiveScale()
		end
		local screenRight = UIParent:GetRight() * UIParent:GetEffectiveScale()
		if screenRight - edge:GetRight() * edgeScale >= need then
			frame:SetPoint("TOPLEFT", edge, "TOPRIGHT", 6, 0)
			return
		end
	end
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

local function Open()
	if not frame then
		Build()
	end
	Place()
	frame:Show()
	-- Everything up to the installed version now counts as seen. The NEW
	-- tags were painted when the window was built, so they stay up for the
	-- rest of this session.
	JohnnysRaidBrowserDB = JohnnysRaidBrowserDB or {}
	JohnnysRaidBrowserDB.changelogSeenVersion = InstalledVersion()
end

function Changelog:Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		Open()
	end
end

-- Called when the Raid Browser window opens: pops the changelog up beside it
-- once per update, until it has been looked at.
function Changelog:ShowIfUnseen()
	if self:HasUnseen() then
		Open()
	end
end

-- Called when the Raid Browser window closes, so the changelog doesn't stay
-- behind on its own.
function Changelog:Hide()
	if frame then
		frame:Hide()
	end
end
