--!strict
--[[
	SettingsClient -- puts the saved graphics switches back on the world.

	The Settings panel writes an attribute AND tells the server (see Shell), and
	UpgradeService keeps them with the profile. This is the other half: when the
	profile lands, those attributes arrive from the server, and something has to
	turn them into actual Lighting properties. The panel cannot -- it is built once,
	often before the profile has arrived, and may never be opened at all.

	WHY THIS FILE RATHER THAN THE PANEL: a player who sets Shadows off and rejoins
	must get a shadowless world whether or not they ever open Settings again. That
	is the entire point of persisting it.

	SOUND IS NOT HERE. AudioClient already owns the mixer and reads Set_Music and
	Set_Sfx itself; two writers on one bus is how the old "the music slider controls
	both" bug happened. This file touches Lighting and nothing else.

	SHADOWS DEFAULT OFF (2026-08-15, owner's call). 561 shadow casters make
	GlobalShadows the largest lighting cost in the place, and `== true` is the whole
	of the default: an unset attribute reads as off, so every player gets the cheap
	world until they ask for the other one. Same rule, and same reasoning, as
	Config's 3D Sealer Surface.

	Applied on EVERY change, not just at load: the panel writes the attribute for
	the immediate effect, the server writes it again when a profile restores, and
	both land here.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local plr = Players.LocalPlayer

local function applyShadows()
	Lighting.GlobalShadows = plr:GetAttribute("Set_Shadows") == true
end

--[[
	Bloom and sun rays. Absent means ON here, unlike shadows -- these are a fraction
	of the cost and they are most of what the place looks like, so the default is
	the pretty one and only an explicit `false` takes them away.
]]
local function applyFancy()
	local on = plr:GetAttribute("Set_Fancy") ~= false
	for _, fx in ipairs(Lighting:GetChildren()) do
		if fx:IsA("BloomEffect") or fx:IsA("SunRaysEffect") then
			(fx :: any).Enabled = on
		end
	end
end

plr:GetAttributeChangedSignal("Set_Shadows"):Connect(applyShadows)
plr:GetAttributeChangedSignal("Set_Fancy"):Connect(applyFancy)

--[[
	Immediately, then again when the profile lands.

	The first call is what makes shadows off the DEFAULT rather than merely the
	saved value -- it runs before any profile exists, with the attribute unset, and
	`== true` resolves that to off. A player who saved them ON gets them back a
	second later when the restore fires the listener above.

	That order is deliberate. The other way round -- default on, then turn off if
	saved -- would show a shadowed world to every phone for the length of a
	DataStore read, which is the exact moment a weak device is busiest.
]]
applyShadows()
applyFancy()
plr:GetAttributeChangedSignal("ProfileLoaded"):Connect(function()
	applyShadows()
	applyFancy()
end)
