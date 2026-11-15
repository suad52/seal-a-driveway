--!strict
--[[
	DepotGate -- the yard gate stays shut until you have sealed the depot's own
	apron, which makes the workshop driveway the first job of the game.

	This script only decides *whether* a player has earned the gate; the swing
	itself happens on their client (see DepotGateClient). That split is deliberate.
	Progression here is per player -- one person finishing the apron must not open
	the yard for everyone in the server -- and a single physical gate cannot be
	shut for one player and open for another. So the canonical gate in Workspace
	stays closed forever, and each client swings its own copy once its owner has
	earned it. Local changes to a replicated instance do not replicate back, and a
	character's physics is simulated on its own client, so the player who opened it
	walks through while everyone else still sees a shut gate.

	The result is stored as a Player attribute so the client can just watch it, and
	UpgradeService persists it with the rest of the profile.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
-- both only for the payable-tutorial check at the bottom of this file
local Economy = require(Pack:WaitForChild("Economy"))
local Upgrades = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Upgrades"))
local Remotes = Pack:WaitForChild("Remotes")
local ReportCoverage = Remotes:WaitForChild("ReportCoverage") :: RemoteEvent
local DrivewayComplete = Remotes:WaitForChild("DrivewayComplete") :: RemoteEvent

local ATTR = "DepotSealed"

--[[
	Two doors, ONE stage.

	Seal the front walk at House_114, then walk into the store and buy a longer
	squeegee at the counter terminal. That is the whole of it: the store's roll door
	and the yard gate both come off the same moment, and the map is open.

	The first job was the DRIVEWAY at House_114 until 2026-08-13 and the slab is
	still named Driveway, because its name is its key in the sealed record -- see
	the note at the top of TutorialClient. Nothing in this file cares which it is;
	it reads the same part at the same path either way.

	THE DEPOT APRON USED TO BE A SECOND STAGE and is not any more (2026-08-11,
	owner's call). It was a third job on top of an already-taught loop -- the player
	had poured, spread, finished and bought by then, and sealing another slab to the
	same recipe taught nothing the first one had not. The apron is still a perfectly
	ordinary sealable slab; it simply does not gate anything.

	`DepotSealed` therefore no longer means "the apron is sealed". It means "the
	tutorial is done and the yard gate is open", and it is set alongside
	TutorialDone. THE NAME IS KEPT ON PURPOSE: it is persisted under that key in
	every saved profile, so renaming it would hand the whole map back to everybody
	who has already finished. See the migration in `bind`.
]]
local TUT_SEALED = "TutSealed"     -- the House_114 driveway is done
local TUT_BOUGHT = "TutBought"     -- an upgrade has been bought
local TUT_DONE   = "TutorialDone"  -- both: the roll door may open

local function tutorialDrive(): BasePart?
	local hood = workspace:FindFirstChild("Neighbourhood")
	local pave = hood and hood:FindFirstChild("Pavement")
	local lot = pave and pave:FindFirstChild("Lot_114")
	local drive = lot and lot:FindFirstChild("Driveway")
	return (drive and drive:IsA("BasePart")) and drive or nil
end

--==[ per-player progress on the apron ]======================================
--[[
	DrivewayServer already tracks exactly this, but keeps it in a local table, and
	the slab's Coverage attribute is no substitute: it is per slab, so once anyone
	had sealed the apron every later joiner would inherit a finished job. Mirroring
	the few lines here keeps the gate per player and costs one extra listener on a
	remote that is already firing.

	The rate limit is the same one DrivewayServer applies, and for the same reason:
	coverage is reported by the client, so the cap is what stops a tampered client
	claiming a finished driveway the moment it spawns. Like the payout, it is a
	speed bump rather than a hard boundary -- the gate opens onto the rest of the
	map, not onto anything valuable.

	⚠ IT IS NOW LITERALLY THE SAME ONE -- Config.maxCoverageRate -- because that
	sentence used to be a lie and it cost players the tutorial.

	This file kept its own copy at a flat 0.12 a second. DrivewayServer's was fixed
	to an area rate and this one was not, so on the 320-square-stud tutorial drive
	the two disagreed by fifty times: anyone who sealed that little strip in under
	about eight seconds had TutSealed silently refused, and -- because the client had
	already latched the slab `completed`, and a completed slab refuses a pour -- was
	left on "EMPTY THE PAIL" with no way to empty it. The full reasoning is in the
	note over Config.maxCoverageRate.
]]

type Progress = { coverage: number, lastStamp: number }

-- Keyed by slab as well as player. Only one slab is watched now that the apron
-- has stopped gating anything, but the shape is left alone: it costs one table
-- and it is what stops a second gated slab needing this rewritten.
local progressFor: { [Player]: { [BasePart]: Progress } } = {}

Players.PlayerRemoving:Connect(function(plr)
	progressFor[plr] = nil
end)

local function track(plr: Player, slab: BasePart): Progress
	local byPlayer = progressFor[plr]
	if not byPlayer then
		byPlayer = {}
		progressFor[plr] = byPlayer
	end
	local e = byPlayer[slab]
	if not e then
		e = { coverage = 0, lastStamp = os.clock() }
		byPlayer[slab] = e
	end
	return e
end

local function coverageOf(plr: Player, slab: BasePart?): number
	if not slab then return 0 end
	local byPlayer = progressFor[plr]
	local e = byPlayer and byPlayer[slab]
	return e and e.coverage or 0
end

ReportCoverage.OnServerEvent:Connect(function(plr, slab, coverage)
	if slab ~= tutorialDrive() then return end
	if type(coverage) ~= "number" or coverage ~= coverage then return end
	coverage = math.clamp(coverage, 0, 1)

	local e = track(plr, slab)
	local now = os.clock()
	-- Sized to the slab, not a flat fraction. See the note above the type.
	local allowed = e.coverage + Config.maxCoverageRate(slab) * (now - e.lastStamp) + 0.01
	e.lastStamp = now
	e.coverage = math.min(coverage, allowed)
end)

--==[ opening it ]============================================================

-- Reuses the shell's existing toast channel rather than adding a remote: the
-- client end already turns (id, ok, message) into a toast.
local function toast(plr: Player, message: string)
	local ui = ReplicatedStorage:FindFirstChild("SealerUI")
	local remotes = ui and ui:FindFirstChild("Remotes")
	local result = remotes and remotes:FindFirstChild("BuyResult")
	if result and result:IsA("RemoteEvent") then
		result:FireClient(plr, "DepotGate", true, message)
	end
end

-- The message is the caller's, because the two callers are saying different
-- things: one is finishing a tutorial, the other is letting somebody out who
-- should never have been shut in.
local function openFor(plr: Player, message: string?)
	if plr:GetAttribute(ATTR) then return end
	plr:SetAttribute(ATTR, true)
	if message then toast(plr, message) end
end

--==[ finishing the tutorial ]================================================

-- Both flags together, so the roll door and the yard gate come off the same
-- frame. DepotGateClient retires each on its own attribute and neither knows
-- about the other, so this is the only place the two are tied.
local function checkTutorial(plr: Player)
	if plr:GetAttribute(TUT_DONE) then return end
	if not (plr:GetAttribute(TUT_SEALED) and plr:GetAttribute(TUT_BOUGHT)) then return end
	plr:SetAttribute(TUT_DONE, true)
	openFor(plr)
	toast(plr, "Tutorial complete -- the yard gate is opening")
end

--[[
	Squeegee Length specifically.

	An upgrade is only a lesson if the player can feel it, and the blade is the one
	they can: the very next pass visibly covers more ground. Bucket Capacity was
	the obvious pick -- the tutorial has just run them dry -- but a bigger pail
	only pays off on the trip after next, which is a poor first purchase to be
	taught with.

	The rung this buys is level 2 at 1.2K, and it stayed 1.2K when the ladder's
	bottom was re-spaced on 2026-08-08 -- `costs` was left untouched entry for
	entry precisely so this step could not move. (The note that used to sit here
	said the 1.2K came from "a 5.2 rung under the starting blade"; that rung is
	gone, the starting blade IS 6.4 now, and the price is unchanged regardless.)
	UpgradeService refuses every other track until it lands.
]]
local TUT_TRACK = "Blade"

--[[
	AND THE ONE JOB BEFORE IT HAS TO PAY FOR IT.

	The tutorial hands a new player exactly one slab and then asks them to spend
	1,200 on the track above. Nothing else is buyable until it lands, so if that
	slab pays less than the price, the tutorial cannot be finished -- the player is
	left standing at the counter with a button they can never press and a gate that
	never opens. That is what it shipped as once: Lot_114 was trimmed to PayScale
	0.7 and paid 996 in the worst accepted case against a 1,200 gate, so the only
	way through was to earn tips, which is the one thing a first-time player will
	not do.

	Checked out loud rather than trusted, because the numbers that decide it live
	in three different files -- the slab's PayScale in the place, CallOut and
	RatePerStud in Economy, the cost in Upgrades -- and any one of them can be
	retuned by somebody with no reason to be thinking about the tutorial.

	AND THE SLAB'S OWN SIZE IS NOW ONE OF THEM. The payout is priced by area, so
	resizing the tutorial slab moves what it pays: shrinking the job from the old
	30 x 20 driveway to a 40 x 8 front walk (2026-08-13) took 1,454 down to 872
	until PayScale was raised to put it back. Anyone reshaping this slab has to
	re-derive the scale with it, and this is the check that says so.

	Warning only, and deferred: a wrong number here must not stop the game booting,
	and the audience is whoever moved it rather than the player. The path mirrors
	TutorialClient's own `drivewayPart`; if that ever moves, this says so too.
]]
local TUT_SLAB_PATH = { "Neighbourhood", "Pavement", "Lot_114", "Driveway" }

task.defer(function()
	local node: Instance? = workspace
	for _, name in ipairs(TUT_SLAB_PATH) do
		node = node and node:FindFirstChild(name)
	end
	if not (node and node:IsA("BasePart")) then
		warn(("[DepotGate] tutorial slab not found at workspace.%s -- cannot check that"
			.. " the tutorial is payable"):format(table.concat(TUT_SLAB_PATH, ".")))
		return
	end
	local slab = node :: BasePart
	local cost = Upgrades.costOf(TUT_TRACK, 1)
	if type(cost) ~= "number" then return end

	-- Tips are excluded on purpose: they are the thing a first-timer does not
	-- earn, so the floor has to hold without them.
	local base = Economy.jobBase(slab)
	local worst = base * (Config.CompleteAt - 0.05)
	if worst < cost then
		local scale = Economy.scaleOf(slab)
		warn(("[DepotGate] THE TUTORIAL CANNOT BE FINISHED: %s pays %d at the lowest"
			.. " coverage a completion is accepted at, but %s level 2 costs %d. Raise the"
			.. " slab's PayScale from %.2f to at least %.3f.")
			:format(slab:GetFullName(), math.floor(worst), TUT_TRACK, cost, scale,
				scale * cost / worst))
	else
		print(("[DepotGate] tutorial payable: %s pays %d..%d against a %d gate")
			:format(slab.Name, math.floor(worst), math.floor(base), cost))
	end
end)

local function watchPurchases(plr: Player)
	local function look()
		if plr:GetAttribute(TUT_BOUGHT) then return end
		local lv = plr:GetAttribute("Upg_" .. TUT_TRACK)
		if type(lv) == "number" and lv > 1 then
			plr:SetAttribute(TUT_BOUGHT, true)
			checkTutorial(plr)
		end
	end
	plr:GetAttributeChangedSignal("Upg_" .. TUT_TRACK):Connect(look)
	-- a returning profile may already own it
	task.delay(6, look)
end

--[[
	And the migration, for everybody caught mid-flight by the apron being dropped.

	A profile saved with TutorialDone set but DepotSealed clear is a player who
	bought the blade and never sealed the apron. Under the old rules they still owed
	a job; under these there is nothing left to owe, and checkTutorial cannot help
	them because it returns on its first line for anyone already done. Without this
	they rejoin forever to a shut gate with no step that would open it.

	Waits on the profile rather than firing blind, because the flags are not there
	yet at PlayerAdded. One cost, accepted: these players hear the gate's clunk on
	the rejoin that migrates them, since DepotGateClient's silent path needs the
	attribute to be true BEFORE it looks. It happens once and then the flag persists.
]]
local function bind(plr: Player)
	watchPurchases(plr)
	task.spawn(function()
		local t0 = os.clock()
		while plr.Parent and not plr:GetAttribute("ProfileLoaded") and os.clock() - t0 < 15 do
			task.wait(0.2)
		end
		if plr.Parent and plr:GetAttribute(TUT_DONE) then
			openFor(plr)
		end
	end)
end

Players.PlayerAdded:Connect(bind)
for _, plr in ipairs(Players:GetPlayers()) do bind(plr) end

--==[ completion ]============================================================

DrivewayComplete.OnServerEvent:Connect(function(plr, slab)
	-- same slack under CompleteAt as the payout: coverage arrives through the rate
	-- limiter, so the server's figure trails the client's at the moment it claims
	-- the job is done
	local function finished(target: BasePart?): boolean
		return slab == target and coverageOf(plr, target) >= Config.CompleteAt - 0.05
	end

	if finished(tutorialDrive()) and not plr:GetAttribute(TUT_SEALED) then
		plr:SetAttribute(TUT_SEALED, true)
		if not plr:GetAttribute(TUT_BOUGHT) then
			toast(plr, "Nice work -- now spend it on an upgrade")
		end
		checkTutorial(plr)
	end
end)

--[[
	A player who somehow ends up outside the yard with the gate still shut would be
	stuck looking at the back of it, so treat being out there as having earned it.
	The realistic way in is a rejoin before the profile save lands, or being pushed
	through during the swing.

	Both of those put the player in front of the GATE, which is the depot half of
	the yard -- west of the divide wall. The tutorial lot's own fence runs along the
	same front line at X 33..160, so a bare "south of the front wall" test also
	caught anyone who got over that fence and handed them the gate for nothing:
	the whole first stage skipped, and the second one paid out for free. The lot is
	capped now (Depot.TutorialBounds), but the reward stays behind the divide so a
	future hole in the fence is a nuisance rather than a shortcut.
]]
local FRONT_Z = 150.8
local DIVIDE_X = 33.5   -- east of this is the tutorial lot, not the yard
local YARD_X_MIN = -120 -- the west wall, with slack

task.spawn(function()
	while true do
		task.wait(3)
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr:GetAttribute(ATTR) then continue end
			local ch = plr.Character
			local root = ch and ch:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local p = root.Position
				if p.Z < FRONT_Z - 6 and p.X < DIVIDE_X and p.X > YARD_X_MIN then
					openFor(plr, "The gate is open")
				end
			end
		end
	end
end)
