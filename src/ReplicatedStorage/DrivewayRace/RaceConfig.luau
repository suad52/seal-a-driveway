--!strict
--[[
	RaceConfig -- every number the Driveway Race runs on, in one place.

	Shared by the server (which schedules it, owns the score and pays it out) and
	the client (which builds the lane, draws the HUD and runs the paint), so the
	two can never disagree about how big a lane is or how long the cap is. Same
	rule Config, Economy and BattleConfig already follow.

	WHAT THIS EVENT IS

	The scheduler offers everyone a 30 second window to opt in. Up to eight are
	taken to a plaza where each of them gets THEIR OWN driveway, side by side on
	one start line, and the first to seal theirs wins. Second and third are paid
	too, on the same average-level purse the Squeegee Battle uses.

	THE THREE RULES THAT MAKE IT A RACE RATHER THAN A LADDER CHECK

	  1. Everybody keeps their own kit. Their blade, their walk speed, their
	     skin -- unlike the arena, which takes all of it away (see
	     BattleConfig.UseOwnBlade and EqualSpeed and the reasons there).
	  2. The LANE is sized to the kit instead. A player who can cover ground
	     three times faster is given three times the ground, so the two cancel
	     and the race is decided by driving rather than by receipts -- see
	     `areaFor`, which is the whole of the balance.
	  3. Nobody refills. The blade feeds itself out of a reservoir every player
	     is given the same amount of, so a Bucket Capacity track that has
	     nothing to do with squeegee work cannot decide the result either.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Config"))
local Upgrades = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Upgrades"))

local Race = {}

--==[ STATE MACHINE ]=========================================================

-- Strings rather than an Enum, because the state crosses the wire; a string
-- survives a RemoteEvent unchanged and an Enum-alike table does not. Same
-- shape, and the same reasoning, as BattleConfig.State.
Race.State = table.freeze({
	Idle     = "IDLE",
	Inviting = "INVITING",
	InGame   = "IN_GAME",
	Cleanup  = "CLEANUP",
})

Race.Enabled = true

--==[ THE WINDOW AND THE CLOCK ]==============================================

Race.InviteSeconds  = 30      -- how long the join prompt stands
Race.CountInSeconds = 3       -- READY / SET / SEAL once everyone has landed
Race.ResultSeconds  = 12      -- how long the summary screen stays up
Race.MinPlayers     = 2       -- fewer than this and the race is cancelled
Race.MaxPlayers     = 8       -- and the yard has exactly this many lanes
Race.MatchSeconds = 180
Race.FinishGrace = 30
Race.FinishAt = 0.98

-- The clock turns urgent here, and starts counting every second out loud below
-- that -- the same two numbers, and the same meaning, the event ticker uses.
Race.TimerWarnAt  = 60
Race.TimerHurryAt = 10

--==[ WHAT THE WHOLE SERVER CAN SEE ]=========================================
Race.PhaseAttr = "Phase"

--==[ THE YARD ]==============================================================

Race.Origin = Vector3.new(6000, 0, -6000)

Race.LaneGap = 12             -- studs of plaza between one lane and the next
Race.LaneApron = 14           -- studs of plaza in front of the start line
Race.PlazaMargin = 40         -- and round the whole thing
Race.SpawnRise = 3            -- how far above the lane a player is placed
Race.KerbHeight = 0.9         -- a visible kerb, so the edge of the job is obvious
Race.KerbThick = 1.4

Race.LaneColor = Color3.fromRGB(178, 176, 170)
Race.PlazaColor = Color3.fromRGB(96, 100, 108)
Race.KerbColor = Color3.fromRGB(232, 226, 208)

--==[ HOW BIG A LANE IS ]=====================================================
Race.BaseArea = 1830

-- Length over width. 61 x 30 is 2.03, and a lane that keeps that ratio at every
-- size reads as a bigger driveway rather than as a longer runway.
Race.LaneAspect = 2.03
Race.BladeWeight = 1.0
Race.SpeedWeight = 1.0

-- The kit the base lane is quoted against: rung 1 of both tracks. Read from the
-- ladder rather than typed, so re-tuning either track moves this with it.
Race.RefBlade = Upgrades.valueAt("Blade", 1)
Race.RefSpeed = Upgrades.valueAt("Speed", 1)

Race.MaxAreaMult = 4.0

Race.TargetCells = 40000
Race.MinCellSize = 0.18
Race.MaxCellSize = 0.62

function Race.areaFor(bladeLevel: number, speedLevel: number): number
	local blade = Upgrades.valueAt("Blade", bladeLevel)
	local speed = Upgrades.valueAt("Speed", speedLevel)
	local mult = (blade / Race.RefBlade) ^ Race.BladeWeight
		* (speed / Race.RefSpeed) ^ Race.SpeedWeight
	if mult < 1 then mult = 1 end
	if mult > Race.MaxAreaMult then mult = Race.MaxAreaMult end
	return Race.BaseArea * mult
end

function Race.cellFor(w: number, l: number): number
	local cell = math.sqrt((w * l) / Race.TargetCells)
	if cell < Race.MinCellSize then cell = Race.MinCellSize end
	if cell > Race.MaxCellSize then cell = Race.MaxCellSize end

	local budget = math.sqrt((w * l) / math.max(1, Config.MaxGridCells))
	if cell < budget then cell = budget end

	local axis = math.max(w, l) / math.max(1, Config.MaxGridAxis)
	if cell < axis then cell = axis end
	return cell
end

local function geomFor(area: number)
	local w0 = math.sqrt(area / Race.LaneAspect)
	local l0 = w0 * Race.LaneAspect
	local cell = Race.cellFor(w0, l0)
	local cw = math.max(8, math.round(w0 / cell))
	local ch = math.max(8, math.round(l0 / cell))
	return cw * cell, ch * cell, cell, cw, ch
end

function Race.geomFor(bladeLevel: number, speedLevel: number)
	return geomFor(Race.areaFor(bladeLevel, speedLevel))
end

function Race.maxSize(): (number, number)
	local w, l = geomFor(Race.BaseArea * Race.MaxAreaMult)
	return math.ceil(w), math.ceil(l)
end

function Race.gridOrigin(cw: number, ch: number, cell: number): (number, number)
	return -cw * cell * 0.5, -ch * cell * 0.5
end

--==[ THE BLADE ]=============================================================
Race.PourPerStud = 1.32       -- coat-studs per stud walked, per stud of blade
Race.PourIdle    = 3.60       -- and per second standing still, per stud of blade
Race.PourLead    = 1.10       -- studs ahead of the rubber the bead lands
Race.PourSpacing = 0.72       -- studs of blade per pour point
Race.PourMaxPoints = 16

Race.BladeCapacityPerStud = 8.33
Race.BladeForward = 2.9       -- matches DrivewayClient's BLADE_FORWARD exactly

Race.StampHalfBand = 0.85

--==[ SANITY ]================================================================

Race.MaxStrokeTravel = 7.0
Race.StrokeHz = 20            -- how often a client may send; server-enforced
Race.StrokeBurst = 6          -- packets it may bank up for one bad frame

Race.MaxAimError = 16.0
Race.JoinCooldown = 0.5       -- seconds between accepted Join/Decline presses
Race.ToolName = "Squeegee"    -- what ToolBuilder names it; checked on every stroke

--==[ THE PALETTE ]===========================================================
local Battle = require(ReplicatedStorage:WaitForChild("SqueegeeBattle")
	:WaitForChild("BattleConfig"))
Race.Palette = Battle.Palette
Race.SlotNames = Battle.SlotNames

function Race.colorOf(slot: number): Color3
	return Race.Palette[math.clamp(slot, 1, #Race.Palette)]
end

function Race.slotNameOf(slot: number): string
	return Race.SlotNames[math.clamp(slot, 1, #Race.SlotNames)]
end

--==[ REWARDS ]===============================================================
Race.PayoutBase = Battle.PayoutBase
Race.PurseScale = Battle.PurseScale
Race.ShowUpBonus = Battle.ShowUpBonus
Race.CashStats = Battle.CashStats

--==[ DERIVED ]===============================================================

-- One coat, in the same units SurfaceGrid works in. Named here so the pour and
-- the scoring threshold cannot be tuned apart.
Race.CoatDepth = Config.CoatDepth

return Race
