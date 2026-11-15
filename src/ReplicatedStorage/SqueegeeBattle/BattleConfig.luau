--!strict
--[[
	BattleConfig -- every number the Squeegee Battle event runs on, in one place.

	Shared by the server (which schedules the event, owns the score and pays it
	out) and the client (which draws the arena, the HUD and the paint), so the
	two can never disagree about how wide a blade is or how long a match lasts.
	Same rule Config and Economy already follow.

	WHAT THIS EVENT IS

	Every 15-20 minutes the server offers everyone a 30 second window to opt in.
	Up to eight of them are teleported to a 100 x 100 arena, given sixty seconds,
	and paid on how much of the canvas is wearing THEIR colour when the buzzer
	goes. Painting is the game's own sealcoat simulation -- the same SurfaceGrid,
	the same squeegee physics, the same pour-and-spread -- with one extra buffer
	saying who owns each cell. Sweeping over somebody else's coat repaints it in
	yours, which is the whole of the competition.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Config"))
local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local Upgrades = require(SealerUI:WaitForChild("Upgrades"))
local Passes = require(SealerUI:WaitForChild("Passes"))

local Battle = {}

--==[ STATE MACHINE ]=========================================================
Battle.State = table.freeze({
	Idle    = "IDLE",
	Inviting= "INVITING",
	InGame  = "IN_GAME",
	Cleanup = "CLEANUP",
})

--==[ SCHEDULE ]==============================================================
Battle.Enabled = true

Battle.GapMin = 15 * 60         -- seconds between events, low end
Battle.GapMax = 20 * 60         -- and high end

Battle.FirstGapMin = 4 * 60
Battle.FirstGapMax = 7 * 60

--==[ THE ON-SCREEN COUNTDOWN ]===============================================

Battle.NextAtAttr = "NextEventAt"   -- number: server time the next event opens
Battle.PhaseAttr  = "Phase"         -- string: one of Battle.State

-- The clock turns urgent here, and starts counting every second out loud below
-- that. Seconds rather than a fraction of the gap: "a minute left" means the
-- same thing whether the gap was fifteen minutes or twenty.
Battle.TimerWarnAt  = 60
Battle.TimerHurryAt = 10

Battle.InviteSeconds  = 30      -- how long the join prompt stands
Battle.MatchSeconds   = 60      -- exact match length, buzzer to buzzer
Battle.CountInSeconds = 3       -- READY / SET / PAINT once everyone has landed
Battle.ResultSeconds  = 12      -- how long the summary screen stays up
Battle.MinPlayers     = 2       -- fewer than this and the match is cancelled
Battle.MaxPlayers     = 8       -- and the arena has exactly this many spawns

Battle.DebugFastCycle = false
Battle.DebugGap = 20

--==[ ARENA ]=================================================================
Battle.Origin = Vector3.new(-6000, 0, 6000)

Battle.CanvasSize = 100         -- studs a side; the brief's 100 x 100
Battle.CanvasThick = 4          -- how deep the slab is, purely so it reads as ground
Battle.WallHeight = 20          -- invisible wall round the rim, so nobody walks off
Battle.KerbHeight = 1.2         -- and a visible kerb, so they can see where the edge is
Battle.SpawnInset = 6           -- studs in from the rim the eight spawn pads sit
Battle.SpawnRise  = 3           -- how far above the canvas a player is placed

Battle.CanvasColor = Color3.fromRGB(58, 60, 66)
Battle.KerbColor   = Color3.fromRGB(232, 226, 208)

--==[ THE PAINT ]=============================================================

Battle.CellSize = 0.45

Battle.UseOwnBlade = false
Battle.BladeHalfLen = 3.60      -- half-width of the arena blade, in studs

Battle.PourPerStud = 9.5
Battle.PourIdle = 26.0          -- units a second while the blade is not moving
Battle.PourLead = 1.10          -- studs ahead of the rubber the bead lands
Battle.PourPoints = 5           -- spread across the blade; one circle misses the ends

Battle.BladeCapacity = 60.0     -- reservoir the blade carries, passed as `holds`
Battle.BladeForward = 2.9       -- matches DrivewayClient's BLADE_FORWARD exactly
Battle.EqualSpeed = true
Battle.WalkSpeed = 26
Battle.OwnedFloor = 0.42
Battle.StampHalfBand = 0.85
Battle.MaxStrokeTravel = 5.0
Battle.StrokeHz = 20            -- how often a client may send; server-enforced
Battle.StrokeBurst = 6          -- packets it may bank up for one bad frame
Battle.MaxAimError = 12.0       -- studs the blade may be from the player's own root

--==[ THE PALETTE ]===========================================================
Battle.Palette = table.freeze({
	Color3.fromRGB(255,  72,  86),   -- 1 red
	Color3.fromRGB( 70, 168, 255),   -- 2 blue
	Color3.fromRGB( 96, 226, 106),   -- 3 green
	Color3.fromRGB(255, 196,  48),   -- 4 gold
	Color3.fromRGB(196, 110, 255),   -- 5 violet
	Color3.fromRGB( 46, 226, 214),   -- 6 teal
	Color3.fromRGB(255, 138,  44),   -- 7 orange
	Color3.fromRGB(255, 122, 210),   -- 8 pink
})

Battle.SlotNames = table.freeze({
	"Red", "Blue", "Green", "Gold", "Violet", "Teal", "Orange", "Pink",
})

--==[ REWARDS ]===============================================================
Battle.PayoutBase = table.freeze({ 500, 300, 150, 50, 50, 50, 50, 50 })
Battle.PurseScale = 12
Battle.CashStats = table.freeze({ "Cash", "Coins", "Money" })
Battle.ShowUpBonus = 0.05       -- share of first place

--==[ SANITY ]================================================================

Battle.JoinCooldown = 0.5       -- seconds between accepted Join/Decline presses
Battle.ToolName = "Squeegee"    -- what ToolBuilder names it; checked on every stroke

if Battle.DebugFastCycle and game:GetService("RunService"):IsStudio() then
	Battle.GapMin = Battle.DebugGap
	Battle.GapMax = Battle.DebugGap
	Battle.FirstGapMin = Battle.DebugGap
	Battle.FirstGapMax = Battle.DebugGap
	Battle.InviteSeconds = 12
	warn("[SqueegeeBattle] DebugFastCycle is ON -- the schedule is seconds, not minutes")
end

--==[ DERIVED ]===============================================================

-- Half the canvas, in studs from its centre. Used by every bounds check there is.
Battle.HalfCanvas = Battle.CanvasSize * 0.5

-- Cells a side, and the EditableImage is exactly this. Ceil rather than round so
-- the grid always covers the canvas and the mask trims, never the other way.
Battle.GridCells = math.ceil(Battle.CanvasSize / Battle.CellSize)

-- One coat, in the same units SurfaceGrid works in. Named here so the pour and
-- the scoring threshold cannot be tuned apart.
Battle.CoatDepth = Config.CoatDepth

--==[ DUELS KEEP THEIR OWN KIT ]==============================================
Battle.DuelAttr = "IsDuel"

local function pack(): Instance?
	return ReplicatedStorage:FindFirstChild("SqueegeeBattle")
end

function Battle.isDuel(): boolean
	local p = pack()
	return p ~= nil and p:GetAttribute(Battle.DuelAttr) == true
end

function Battle.bladeHalfOf(plr: Player?): number
	if not plr or not Battle.isDuel() then return Battle.BladeHalfLen end
	local lv = plr:GetAttribute("Upg_Blade")
	if type(lv) ~= "number" then return Battle.BladeHalfLen end
	lv = math.clamp(math.floor(lv), 1, Upgrades.maxLevel("Blade"))
	return Upgrades.valueAt("Blade", lv) * 0.5
end

function Battle.walkSpeedOf(plr: Player?): number?
	if Battle.isDuel() then
		if not plr then return nil end
		local lv = plr:GetAttribute("Upg_Speed")
		lv = if type(lv) == "number"
			then math.clamp(math.floor(lv), 1, Upgrades.maxLevel("Speed")) else 1
		return Upgrades.valueAt("Speed", lv) * Passes.walkMultiplier(plr)
	end
	if Battle.EqualSpeed then return Battle.WalkSpeed end
	return nil
end

function Battle.colorOf(slot: number): Color3
	return Battle.Palette[math.clamp(slot, 1, #Battle.Palette)]
end

function Battle.slotNameOf(slot: number): string
	return Battle.SlotNames[math.clamp(slot, 1, #Battle.SlotNames)]
end

function Battle.nextGap(first: boolean?, rng: Random): number
	if first then
		return rng:NextNumber(Battle.FirstGapMin, Battle.FirstGapMax)
	end
	return rng:NextNumber(Battle.GapMin, Battle.GapMax)
end

return Battle
