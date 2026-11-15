--!strict
--[[
	TutorialReplay -- puts a player back to the start of the tutorial, for free.

	WHAT HAS TO BE UNDONE, and none of it is optional:

	  TutSealed / TutorialDone / DepotSealed   the three flags the run sets
	  Lot_114 out of SealedNow                 or the driveway stays black

	The second one is the part that is easy to miss. DrivewayServer opens a slab's
	ledger ALREADY PAID when it finds it in SealedNow, so a replay that cleared only
	the flags would start a tutorial whose one objective could never be completed --
	the client restores the slab as finished, there is nothing left to seal, and
	DrivewayComplete returns on its first line forever.

	TutBought is deliberately LEFT SET. DepotGate raises it for anybody whose
	Upg_Blade is past level 1, which is everyone who could possibly be replaying, so
	clearing it only creates a step that re-satisfies itself six seconds later.

	AND THE RE-SEAL MUST NOT PAY. TutReplay is what says so; DrivewayServer reads it
	and pays nothing for that one completion, then clears it. Without that this
	button is a money press: the tutorial slab is worth its base times the player's
	rebirth multiplier, which at fifteen rounds sold is the better part of a million
	a click.

	A REJOIN IS REQUIRED and is not laziness. TutorialClient reads DepotSealed once
	on load and, finding it set, tears its own UI down and returns -- the script is
	finished for the session at that point, so clearing the attribute underneath it
	changes nothing. Restarting it in place would mean restructuring the whole tail
	of a two-thousand line file to be re-enterable, for a button most players press
	once. So the reset is written down and the player is told to rejoin.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Sections = require(Pack:WaitForChild("Sections"))

-- Mirrors DepotGate's TUT_SLAB_PATH. Kept in step by the warning below rather
-- than by hoping: if the slab moves, this says so instead of silently resetting
-- nothing.
local TUT_SLAB_PATH = { "Neighbourhood", "Pavement", "Lot_114", "Driveway" }

local function tutorialSlab(): BasePart?
	local node: Instance? = workspace
	for _, name in ipairs(TUT_SLAB_PATH) do
		node = node and node:FindFirstChild(name)
	end
	return (node and node:IsA("BasePart")) and node or nil
end

local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage.SealerUI
end
local fn = remotes:FindFirstChild("ReplayTutorial")
if not fn then
	fn = Instance.new("RemoteFunction")
	fn.Name = "ReplayTutorial"
	fn.Parent = remotes
end
local ReplayTutorial = fn :: RemoteFunction

-- One press is all it takes, and a second one mid-reset would race the first.
local busy: { [Player]: boolean } = {}
Players.PlayerRemoving:Connect(function(plr) busy[plr] = nil end)

ReplayTutorial.OnServerInvoke = function(plr: Player): (boolean, string)
	if busy[plr] then return false, "Already resetting" end

	--[[
		Refused before the profile lands, because the flags are not there yet: a reset
		run against an empty profile clears nothing, and then UpgradeService restores
		the finished tutorial straight over the top of it a second later.
	]]
	if not plr:GetAttribute("ProfileLoaded") then
		return false, "Still loading -- try again in a moment"
	end

	local slab = tutorialSlab()
	if not slab then
		warn(("[TutorialReplay] tutorial slab not found at workspace.%s")
			:format(table.concat(TUT_SLAB_PATH, ".")))
		return false, "Cannot reset the tutorial right now"
	end

	busy[plr] = true

	for _, flag in ipairs({ "TutSealed", "TutorialDone", "DepotSealed" }) do
		plr:SetAttribute(flag, nil)
	end

	-- the driveway goes back to bare concrete for this lap; SecSealed is untouched,
	-- since that is the lifetime record the road gates read and re-locking those is
	-- a different and much larger reset
	local set = Sections.decode(plr:GetAttribute(Sections.NowAttr))
	set[Sections.keyOf(slab)] = nil
	plr:SetAttribute(Sections.NowAttr, Sections.encode(set))

	-- what stops the re-seal paying; DrivewayServer clears it on the completion
	plr:SetAttribute("TutReplay", true)

	busy[plr] = nil
	if RunService:IsStudio() then
		print(("[TutorialReplay] %s reset -- rejoin to run it"):format(plr.Name))
	end
	return true, "Tutorial reset -- rejoin to play it again"
end

if RunService:IsStudio() then
	print("[TutorialReplay] ready")
end
