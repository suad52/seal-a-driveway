--!strict
--[[
	DuelConfig -- every number the 1v1 duel runs on, in one place.

	Shared by the server (which brokers the challenge, owns the score and pays the
	purse) and the client (which draws the challenge menu, the accept card and the
	HUD), so the two can never disagree about how long Turf War is or what a duel
	is worth. Same rule Config, Economy, BattleConfig and RaceConfig already follow.

	WHAT THIS IS, AND HOW IT DIFFERS FROM THE OTHER TWO EVENTS

	The Squeegee Battle and the Driveway Race are SCHEDULED: the server picks a
	moment, offers the whole lobby a window, and runs one match for everybody. A
	duel is the opposite of that in every respect -- it is PLAYER-STARTED, it is
	always two people, it costs nothing to send and nothing to accept, and several
	of them can be running at once.

	That is why this is a third pack rather than a fourth mode inside one of the
	other two. Those servers are single state machines with one roster, one arena
	and one clock; a second concurrent match would need every one of those
	multiplied, which is a rewrite of a working event to add something it was never
	shaped for.

	WHAT IT DOES REUSE, WHICH IS NEARLY EVERYTHING BELOW THE STATE MACHINE

	  Speed Run and Turf War lay ORDINARY SEALABLE SLABS. They are tagged
	  Sections.Tag like any driveway in the neighbourhood, so DrivewayClient builds
	  them, paints them, spreads the sealer and draws the coverage readout with no
	  duel-specific client code at all. What makes them a duel is one attribute --
	  see SlabAttr -- which tells DrivewayServer to keep its hands off and tells
	  DuelServer to count them.

	  Squeegee Battle is not re-implemented AT ALL. It is handed to the arena that
	  already exists, through ServerScriptService.DuelBus -- see the header there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Config"))

local Duel = {}

--==[ THE MASTER SWITCH ]=====================================================

Duel.Enabled = true

--==[ STATE MACHINE ]=========================================================

Duel.State = table.freeze({
	Idle     = "IDLE",
	CountIn  = "COUNT_IN",
	InGame   = "IN_GAME",
	Over     = "OVER",
})

--==[ THE THREE MODES ]=======================================================

Duel.Modes = table.freeze({
	table.freeze({
		id = "SpeedRun",
		name = "Speed Run",
		glyph = "⚡",
		blurb = "Two huge driveways, side by side. Endless sealer -- no refills."
			.. " First to finish theirs wins.",
		tint = Color3.fromRGB(255, 196, 48),
	}),
	table.freeze({
		id = "Battle",
		name = "Squeegee Battle",
		glyph = "🎨",
		blurb = "One canvas, one arena, one minute. Paint over their colour and"
			.. " hold the most ground.",
		tint = Color3.fromRGB(255, 72, 86),
	}),
	table.freeze({
		id = "TurfWar",
		name = "Turf War",
		glyph = "🏘️",
		blurb = "An empty cul-de-sac and three minutes. Normal pail -- you WILL be"
			.. " walking back to refill. Most driveways claimed wins.",
		tint = Color3.fromRGB(96, 226, 106),
	}),
})

local byId: { [string]: any } = {}
for _, m in ipairs(Duel.Modes) do byId[m.id] = m end

function Duel.modeById(id: any): any?
	if type(id) ~= "string" then return nil end
	return byId[id]
end

function Duel.nameOf(id: any): string
	local m = Duel.modeById(id)
	return if m then m.name else "Duel"
end

--==[ THE CHALLENGE ]=========================================================

Duel.PromptText = "Challenge to a Duel"
Duel.PromptRange = 8
Duel.PromptKey = Enum.KeyCode.R
Duel.PromptHold = 0.6
Duel.PromptName = "DuelPrompt"
Duel.PromptAttachName = "DuelPromptAt"
Duel.PromptHeight = 0
Duel.OfferSeconds = 20
Duel.ChallengeCooldown = 6

-- Seconds a player must wait after a duel ends before they can be pulled into
-- another one. Long enough to walk away from the person who just beat you.
Duel.RematchCooldown = 10
Duel.CountInSeconds = 3        -- READY / SET / SEAL once both have landed
Duel.ResultSeconds = 10        -- how long the summary card stays up
Duel.MaxConcurrent = 3

--==[ WHERE THE ARENAS GO ]===================================================

Duel.Origin = Vector3.new(-6000, 0, -6000)
Duel.Stride = Vector3.new(0, 0, -1500)

function Duel.originOf(slot: number): Vector3
	return Duel.Origin + Duel.Stride * (slot - 1)
end

Duel.SpawnRise = 3             -- how far above the ground a player is placed
Duel.KerbHeight = 0.9
Duel.KerbThick = 1.4
Duel.WallHeight = 24           -- invisible, round the rim, so nobody walks off
Duel.SlabColor = Color3.fromRGB(178, 176, 170)
Duel.GroundColor = Color3.fromRGB(96, 128, 84)
Duel.RoadColor = Color3.fromRGB(78, 80, 86)
Duel.KerbColor = Color3.fromRGB(232, 226, 208)

--==[ WHAT MARKS A DUEL SLAB ]================================================

Duel.SlabAttr = "DuelSlab"       -- number: the duel id this slab belongs to
Duel.SlabOwnerAttr = "DuelOwner" -- number: userId, when a slab belongs to one side
Duel.SlabAreaAttr = "DuelArea"   -- number: square studs, so the score need not measure
Duel.PlayerAttr = "Duel"             -- string: the mode id, while they are in one
Duel.InfiniteAttr = "DuelEndlessPail" -- boolean: Speed Run's bottomless bucket

--==[ SPEED RUN ]=============================================================
Duel.SpeedRun = table.freeze({
	SlabW = 42,
	SlabL = 100,
	Gap = 30,               -- studs of apron between the two driveways
	Margin = 34,            -- and round the outside of both
	-- 0.98, and it is Config.CompleteAt on purpose: the player who knows what
	-- "done" feels like on their own drive is right about what it feels like here.
	-- RaceConfig.FinishAt borrows the same number for the same reason.
	FinishAt = Config.CompleteAt,
	-- The backstop, not the length of the match. A duel ends when somebody
	-- finishes; this ends one where a player has wandered off or cannot do it.
	Cap = 420,
})

--==[ TURF WAR ]==============================================================

Duel.TurfWar = table.freeze({
	Seconds = 180,          -- the brief's three minutes, buzzer to buzzer
	CountIn = 6,
	Lots = 8,
	SlabW = 30,
	SlabL = 58,             -- a Maple drive, near enough
	Radius = 84,
	Circle = 46,            -- radius of the turning circle itself
	-- What counts as CLAIMED. The same 0.98 the rest of the game calls finished,
	-- for the same reason -- see SpeedRun.FinishAt.
	ClaimAt = Config.CompleteAt,
})

--==[ THE PURSE ]=============================================================

Duel.PrizeShare = 0.5
Duel.MinAccountAgeDays = 7
Duel.PairPaidLimit = 0      -- 0 = unlimited; 3 was the shipping value
Duel.PaidCooldown = 0       -- 0 = none; 240 was the shipping value
Duel.MaxPrize = 2000000
Duel.MinPrize = 6000
Duel.CashStats = table.freeze({ "Cash", "Coins", "Money" })

--==[ SANITY ]================================================================
Duel.ToolName = "Squeegee"
Duel.BucketName = "Sealer Bucket"
Duel.MaxAreaPerSecond = 2000

return Duel
