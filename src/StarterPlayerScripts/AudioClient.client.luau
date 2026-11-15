--!strict
--[[
	AudioClient -- music, the world bed, and everything that makes a noise which
	is not the sealing simulation itself.

	DrivewayClient owns the pour/scrape/squelch layer, because those are driven
	frame by frame off the solver and belong next to it. Everything that is about
	the PLAYER rather than the sealer lives here: the soundtrack, the ambience
	under it, tools coming out of the pack, and the interface answering back.

	All of it routes through the buses SoundKit.bus creates, which is what finally
	makes the settings panel's two volume sliders work -- see below.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local SoundKit = require(Pack:WaitForChild("SoundKit"))

local plr = Players.LocalPlayer

--==[ buses ]=================================================================
--[[
	The Sound Effects slider used to write SoundService.Volume, which is the
	global master -- so turning effects down turned the music down with it, and
	the Music slider did nothing at all because nothing ever read Set_Music.
	Both now move their own bus.

	Defaults match the sliders' own starting positions, so a player who never
	opens Settings hears what the panel claims they are hearing.
]]
local musicBus = SoundKit.bus("Music")
local sfxBus = SoundKit.bus("Sfx")
local uiBus = SoundKit.bus("Ui")

local MUSIC_DEFAULT, SFX_DEFAULT = 0.6, 0.8

local function num(attr: string, fallback: number): number
	local v = plr:GetAttribute(attr)
	return if typeof(v) == "number" then math.clamp(v, 0, 1) else fallback
end

local function applySettings()
	musicBus.Volume = num("Set_Music", MUSIC_DEFAULT)
	sfxBus.Volume = num("Set_Sfx", SFX_DEFAULT)
	-- the interface rides the effects slider; a separate control for three clip
	-- types is a setting nobody wants to find
	uiBus.Volume = sfxBus.Volume
end
applySettings()
plr:GetAttributeChangedSignal("Set_Music"):Connect(applySettings)
plr:GetAttributeChangedSignal("Set_Sfx"):Connect(applySettings)

--==[ the world bed ]=========================================================
-- Low under everything, so the map is never a vacuum between jobs.
task.spawn(function()
	local bed = SoundKit.create("Ambience", SoundService)
	bed.Name = "SealerAmbience"
	local target = bed.Volume
	bed.Volume = 0
	bed:Play()
	TweenService:Create(bed, TweenInfo.new(4), { Volume = target }):Play()
end)

--==[ music ]=================================================================
--[[
	A shuffled playlist rather than one looping track.

	The reshuffle happens per pass, and the last track of a pass is remembered so
	it cannot open the next one -- otherwise a five-track shuffle plays the same
	song twice in a row often enough to be noticed.
]]
local GAP = 6          -- seconds of quiet between tracks; the bed carries it
local FADE = 2.5

local function shuffled(exclude: string?): { string }
	local order = table.clone(SoundKit.MusicTracks)
	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end
	if exclude and #order > 1 and order[1] == exclude then
		order[1], order[2] = order[2], order[1]
	end
	return order
end

task.spawn(function()
	local last: string? = nil
	while true do
		for _, name in ipairs(shuffled(last)) do
			while game.ReplicatedStorage:GetAttribute("PumpkinWeatherActive") == true do task.wait(.25) end
			local track = SoundKit.create(name, SoundService)
			track.Name = "SealerMusic"

			--[[
				Wait for the length before playing.

				Music is deliberately not preloaded (see SoundKit), so TimeLength is 0
				for the first moment. Ended never fires on a track that failed to
				load, so without this the playlist would park on a silent track
				forever rather than moving on.
			]]
			local t0 = os.clock()
			while track.TimeLength <= 0 and os.clock() - t0 < 12 do task.wait(0.25) end

			if track.TimeLength > 0 and game.ReplicatedStorage:GetAttribute("PumpkinWeatherActive") ~= true then
				last = name
				local target = track.Volume
				track.Volume = 0
				track:Play()
				TweenService:Create(track, TweenInfo.new(FADE), { Volume = target }):Play()

				local done = false
				local conn = track.Ended:Connect(function() done = true end)
				-- belt and braces: a stalled stream should not stop the playlist
				local deadline = os.clock() + track.TimeLength + 8
				while not done and os.clock() < deadline and game.ReplicatedStorage:GetAttribute("PumpkinWeatherActive") ~= true do task.wait(0.4) end
				conn:Disconnect()
			end

			track:Destroy()
			task.wait(GAP)
		end
	end
end)

--==[ tools coming out of the pack ]==========================================
--[[
	Watched on the character rather than hooked into the hotbar.

	A tool moves Backpack -> Character when it is equipped whatever equipped it:
	the hotbar, a number key, the backpack UI, or a script. Listening to the
	character catches all of them and cannot drift out of step with the UI.

	Swapping tools fires both a remove and an add, which is correct -- one goes
	away as the other comes out, and that is what it should sound like.
]]
local lastToolSound = 0
local function toolSound(name: string, char: Model)
	-- several tools can change hands on one frame; one noise is enough
	if os.clock() - lastToolSound < 0.06 then return end
	lastToolSound = os.clock()
	local at = char:FindFirstChild("HumanoidRootPart")
	SoundKit.play(name, at, 0.07)
	if name == "EquipTool" then
		task.delay(0.06, function()
			if at and at.Parent then SoundKit.play("EquipClick", at, 0.09) end
		end)
	end
end

local function watchCharacter(char: Model)
	char.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then toolSound("EquipTool", char) end
	end)
	char.ChildRemoved:Connect(function(c)
		if c:IsA("Tool") and char.Parent then toolSound("HolsterTool", char) end
	end)
end
if plr.Character then watchCharacter(plr.Character) end
plr.CharacterAdded:Connect(watchCharacter)

--==[ the interface answering back ]==========================================
--[[
	One hook on the whole PlayerGui rather than a call inside each UIKit factory.

	There are seven widget constructors in UIKit and more will be added; binding
	by class here means a control built next month clicks without anyone
	remembering to wire it, and it costs one connection per button.
]]
local function hookButton(inst: Instance)
	if inst:IsA("GuiButton") then
		inst.Activated:Connect(function()
			SoundKit.play("UiClick", nil, 0.06)
		end)
	end
end
local pg = plr:WaitForChild("PlayerGui")
for _, d in ipairs(pg:GetDescendants()) do hookButton(d) end
pg.DescendantAdded:Connect(hookButton)

--[[
	Purchases. UpgradeService answers every buy on this remote, and DepotGate
	borrows it to announce a door -- both are "something good happened", so the
	same chime is right for them.
]]
task.spawn(function()
	local ui = ReplicatedStorage:WaitForChild("SealerUI", 30)
	local remotes = ui and ui:WaitForChild("Remotes", 30)
	local result = remotes and remotes:WaitForChild("BuyResult", 30)
	if result and result:IsA("RemoteEvent") then
		result.OnClientEvent:Connect(function(_id, ok)
			SoundKit.play(if ok then "UiBuy" else "UiDeny", nil, 0.03)
		end)
	end
end)
