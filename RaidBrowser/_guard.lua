-- Loads before the bundled Raid Browser files below. When the standalone
-- RaidBrowser addon is also installed and enabled it has already loaded (it is
-- an OptionalDep in the .toc) and created raid_browser, so the bundled copy
-- steps aside instead of registering a second "RaidBrowser" addon.
JohnnysRaidBrowser_ExternalRB = (raid_browser ~= nil) or IsAddOnLoaded("RaidBrowser") and true or false
