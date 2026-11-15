--!strict
--[[
	AfkClient -- your own character, working without you.

	The whole of the yard's picture lives here. AfkService moves the player in,
	stamps the plot number on them and pays them by the second; this file watches
	that one attribute and, while it is set, drives the character up and down its
	driveway laying a coat.

	IT IS THE REAL SIMULATION

	Not an animation of one. The puppet calls DrivewaySurface:Pour and
	DrivewaySurface:Squeegee with the same arguments the player's own hands make
	-- the same trick CrewHand uses, and for the same reason: there is no second,
	fake spreader to keep in step with the first, there is one simulation and this
	is another hand on it. The coat spreads, pools at the blade, thins where the
	pass was quick and goes glossy as it cures, because it is the same grid doing
	all of that on a real driveway.

	The slab it works is NOT tagged SealableDriveway, so DrivewayClient never sees
	it -- it is not in that file's build queue and never becomes its `surface`.
	The two run side by side on one client and share nothing but the module.

	AND THE MONEY IS NOT HERE

	Nothing in this file pays anything or asks to be paid. AfkService pays for
	wall-clock seconds spent standing in the yard, which is what makes all of the
	above safely cosmetic: a client that cannot build a surface at all, or that is
	rendering at two frames a second in a background tab, earns exactly what a
	client watching every stroke earns.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local Afk = require(Pack:WaitForChild("Afk"))
local DrivewaySurface = require(Pack:WaitForChild("DrivewaySurface"))
local SqueegeePose = require(Pack:WaitForChild("SqueegeePose"))

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(SealerUI:WaitForChild("UIKit"))
local TopBand = require(SealerUI:WaitForChild("TopBand"))
local HudBus = require(SealerUI:WaitForChild("HudBus"))

local Remotes = Pack:WaitForChild("Remotes")
local Control = Remotes:WaitForChild("AfkControl") :: RemoteEvent

local T = UIKit.Theme

--==[ THE WALK ]==============================================================

--[[
	Lane spacing, and why the lanes overlap.

	The blade is Config.BladeHalfLen either side of the walk line -- 6.4 studs of
	rubber -- so lanes at 4.3 overlap by a third. Overlap is not tidiness: a pass
	lays its heaviest coat down the middle and feathers at the ends of the blade,
	so lanes laid edge to edge leave a thin stripe on every seam.
]]
local LANE_STEP = 4.3
local INSET_X = 2.0
local INSET_Z = 2.0

--[[
	How close counts as arriving, and the thing it quietly costs.

	The puppet turns for the next waypoint as soon as it is this close to the
	current one, which is what keeps it moving in a smooth serpentine instead of
	stopping dead at every corner. The cost is that it never actually reaches a
	lane end: the last ARRIVE studs of every lane are walked PAST rather than
	swept, and with the insets above that left about nine percent of the slab --
	a strip down each end -- that no blade ever crossed.

	That is why the trim exists below. It was worth measuring rather than
	guessing: coverage plateaued in the low nineties and the lap simply never
	ended, because the first version asked Config.CompleteAt (98%) to decide when
	the job was done and the geometry could not reach it.
]]
local ARRIVE = 1.6

-- The end trim: two crossways passes over exactly the ground the lanes cannot
-- reach. In from the edge by less than the blade's half-length so the rubber
-- hangs over the end of the slab, and out past the sides so the corners get
-- swept rather than turned in.
local TRIM_IN = 2.2
local TRIM_OVER = 3.0

-- How long the finished drive is left standing before it is handed back. The
-- pause IS the reward -- without it the coat is complete for a single frame and
-- is bare concrete again, which reads as a glitch rather than as a job done.
-- Six rather than four since the puppet walks off the coat before it stands and
-- looks at it: the standing is what the beat is for, and the walk was eating it.
local HOLD = 6

--==[ PACE ]=================================================================

--[[
	The things that stop the walk reading as a machine following a path.

	The pace itself is Afk.WalkSpeed and lives in the shared module, because the
	reason it is not the player's own speed is a design decision rather than a
	detail of this file. What is here is the shape of the walk on top of it.

	None of it touches the coat. Pour and spread are both priced per stud walked,
	so slowing down, pausing, or wandering half a stud off the line lays exactly
	the same sealer -- these are free to tune purely on how they look.
]]

-- How much of the pace survives a corner, and over what distance it comes off.
-- A crew walking a lane slows as it runs out of driveway; it does not arrive at
-- the kerb at full tilt and pivot on the spot.
local TURN_FLOOR = 0.42
local TURN_RADIUS = 6.0

-- The beat at the end of a pass -- stop, lift the blade, step across, set off.
-- Varied, because twenty identical pauses is its own kind of tell.
local PAUSE_MIN, PAUSE_MAX = 0.28, 0.62

-- And a slow drift off the line. Lanes overlap by a third of the blade (see
-- LANE_STEP), so half a stud is far inside what the coat can absorb; it is here
-- because eight ruler-straight passes read as a printed pattern rather than as
-- somebody walking.
local WANDER = 0.5
local WANDER_RATE = 0.9   -- radians a second

local function lanePlan(slab: BasePart): { Vector3 }
	local half = slab.Size * 0.5
	local function w(x: number, z: number): Vector3
		return slab.CFrame:PointToWorldSpace(Vector3.new(x, half.Y, z))
	end

	local x0, x1 = -half.X + INSET_X, half.X - INSET_X
	local zLo, zHi = -half.Z + INSET_Z, half.Z - INSET_Z
	local lanes = math.max(2, math.ceil((zHi - zLo) / LANE_STEP) + 1)
	local gap = (zHi - zLo) / (lanes - 1)

	local pts: { Vector3 } = {}
	for k = 0, lanes - 1 do
		local z = zLo + k * gap
		local a, b = x0, x1
		-- every other lane runs the other way, so the puppet serpentines rather
		-- than walking back down its own wet lane to start the next one
		if k % 2 == 1 then a, b = x1, x0 end
		pts[#pts + 1] = w(a, z)
		pts[#pts + 1] = w(b, z)
	end

	--[[
		Then the two ends, crossways -- the order a real crew works in, lanes first
		and edges last.

		It picks up where the serpentine left off (an even lane count ends at the
		west end), runs the west edge south, crosses the foot of the drive to the
		east edge, and runs that one north. The walk back to lane one from there is
		a diagonal across the whole slab, which sweeps as it goes and costs nothing.
	]]
	local ex = half.X - TRIM_IN
	local tLo, tHi = zLo - TRIM_OVER, zHi + TRIM_OVER
	pts[#pts + 1] = w(-ex, tHi)
	pts[#pts + 1] = w(-ex, tLo)
	pts[#pts + 1] = w(ex, tLo)
	pts[#pts + 1] = w(ex, tHi)
	return pts
end

--[[
	How much sealer goes down per stud walked, rather than per second.

	Per second is the obvious way to write it and it is wrong: the walk speed here
	is the player's own, off the Walk Speed upgrade track and the VIP pass, so a
	fixed rate per second lays a thin coat for a fast player and floods the drive
	for a slow one. Priced against ground covered instead, the coat is the same
	for everybody and the puppet needs no speed of its own.

	The 1.35 is margin. A squeegee pass leaves some of what it pushes behind it
	and carries the rest to the end of the lane, so laying exactly one coat's
	worth arrives at the far end a little short of a coat.
]]
local POUR_PER_STUD = LANE_STEP * Config.CoatDepth * 1.35
-- Where the ribbon lands now that the pail is visibly doing it: under the lip,
-- which is a stride in front rather than the five and a half studs it used to be.
-- See the note at the pour itself for why that changed.
local POUR_LIP = 1.5
-- The pour leg is the only one laying sealer, so it lays what the old combined
-- pass spread over both. Two legs, one of them pouring: twice per stud.
local POUR_HEAVY = 2.0

--==[ CONTROLS ]==============================================================

--[[
	The player's own movement input has to be taken away, or it fights the puppet.

	The default control script calls Humanoid:Move() every frame with whatever the
	player is pressing, and that overrides the MoveTo order the puppet is steering
	by -- so a player who wanders off with a finger on W walks their crew into the
	hedge and the lap never ends.

	THIS IS NOT DONE THE USUAL WAY, AND IT IS WORTH KNOWING WHY

	The textbook answer is require(PlayerScripts.PlayerModule):GetControls():Disable(),
	and in this place that silently does nothing: PlayerModule sits at
	StarterPlayer.PlayerModule, which is never copied into PlayerScripts, so the
	FindFirstChild misses, the function returns nil and every call site politely
	skips. It was written that way first and the bug is invisible in testing --
	the puppet walks perfectly as long as nobody touches the keyboard.

	Sinking the PlayerActions through ContextActionService needs no PlayerModule
	and cannot be moved out from under us: it takes the input before the control
	script ever sees it, whatever and wherever that script is. Camera control is
	deliberately left alone, so an idling player can still look around at the work.
]]
local FREEZE = "AfkFreezeMovement"
local LEAVE_KEY = "AfkLeaveKey"

local function sink(): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

--[[
	And E gets you out, from anywhere in the yard.

	This started as a ProximityPrompt on the pad by each drive, which is the
	idiom the rest of the game uses -- and it is unreachable here, which took a
	playtest to see. The prompt needs the character within fourteen studs of it;
	the character is a puppet walking lanes; and the player has no movement input
	to walk over to it, because the whole point of the lines above is that we took
	it away. The prompt could only ever fire in the second or two the lap happens
	to pass the sign.

	A key has no position, so it cannot be walked away from. The pad and its sign
	stay exactly where they were and now say what to press, which is the same
	signpost doing the same job.

	Bound alongside the movement sink and unbound with it, so the one thing that
	can release the character is live for exactly as long as the thing that holds
	it. Guarded on Begin: BindAction fires for Begin, Change and End, and without
	the check one press would ask the server to leave three times.
]]
--[[
	The hotbar keys go the same way the movement keys do.

	A visit is the crew working, not the player working: the ONE thing the player
	decides is whether to go back to the real map. So the number keys are sunk here
	and the held tool is enforced every frame in holdTool -- both, because they are
	two different doors. This closes the keyboard; the Shell also draws clickable
	hotbar slots, and a GUI button cannot be sunk from out here, so the per-frame
	re-equip is what actually makes the rule true rather than merely suggested.

	1 to 9 because that is what the Shell binds -- it switches the CoreGui backpack
	off and rebinds the digits itself, so there is no Roblox binding to fight, just
	that one.
]]
local TOOL_KEYS = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four,
	Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight,
	Enum.KeyCode.Nine, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1, Enum.KeyCode.ButtonR2,
}
local TOOLS_KEY = "AfkSinkTools"

local function takeWheel()
	ContextActionService:BindAction(FREEZE, sink, false,
		Enum.PlayerActions.CharacterForward,
		Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,
		Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump)

	ContextActionService:BindAction(TOOLS_KEY, sink, false, table.unpack(TOOL_KEYS))

	ContextActionService:BindAction(LEAVE_KEY, function(_, state)
		if state == Enum.UserInputState.Begin then
			Control:FireServer("leave")
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonB)
end

-- Has to run on EVERY exit path, or the player gets their character back unable
-- to walk. Unbinding an action that is not bound is a no-op, so it is safe to
-- call from stop() unconditionally.
local function giveBackWheel()
	ContextActionService:UnbindAction(FREEZE)
	ContextActionService:UnbindAction(LEAVE_KEY)
	ContextActionService:UnbindAction(TOOLS_KEY)
end

--==[ THE READOUT ]===========================================================

local function comma(n: number): string
	local str = tostring(math.floor(n))
	local out = str:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

type Card = { gui: ScreenGui, rate: TextLabel, earned: TextLabel }

local function buildCard(onLeave: () -> ()): Card
	local gui = Instance.new("ScreenGui")
	gui.Name = "AfkOverlay"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		Top centre, and positioned in SCALE.

		The shell already owns the top left (area header), the right edge (rail) and
		the bottom (hotbar and stats), so this is the one clear band. Scale rather
		than offset against ViewportSize on purpose -- see the note in Shell: the
		gui's own space starts above the 3D viewport, so laying anything out against
		viewport numbers comes out short by the inset, which differs per device.

		"The one clear band" was true of every file that said it and false of all of
		them together: five other widgets are written to the same strip, and the event
		ticker drew straight across this card's title. The 14 below is now what this
		card gets when nothing else is up -- SealerUI.TopBand owns the strip and
		stacks it, and the claim is made at the foot of this function.
	]]
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 14)
	card.Size = UDim2.fromOffset(380, 172)
	card.BackgroundColor3 = T.navy
	card.BackgroundTransparency = 0.08
	card.BorderSizePixel = 0
	card.Parent = gui

	--[[
		And it shrinks with the window, which it did not before.

		This was the last block in the strip still fixed at its desktop size, and at
		380 x 172 it is the biggest of them -- wider than half a handset and close to
		half the height of one. The ticker and the Golden Hour bar were both given this
		same fit for this same reason and both wrote the note; the card kept its full
		size because nothing stacked underneath it to make the cost visible. The tally
		and the toast lane do now, so an unscaled card would push them down the screen
		on exactly the devices with the least room to spare.

		Anchored (0.5, 0), so a UIScale shrinks it about its own top centre and it hugs
		the top of its slot rather than drifting down inside it. It is the card's only
		UIScale -- nothing here animates it -- and only one per instance is honoured.
	]]
	local fitScale = Instance.new("UIScale")
	fitScale.Parent = card
	UIKit.onFit(function(f) fitScale.Scale = f end)

	--[[
		Its slot is above the tally and the toast lane and below the two event bars: a
		visit is long, but a match and the countdown to one are the things a player is
		actually waiting on.

		No release anywhere: stop() destroys this whole ScreenGui, and TopBand drops a
		claim whose frame has left the DataModel. A fresh card each visit is a fresh
		claim, which is what the per-visit rebuild wants.
	]]
	TopBand.claim("Afk", TopBand.Rank.Afk, card, function(f) return 172 * f end)

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 16)
	round.Parent = card

	local edge = Instance.new("UIStroke")
	edge.Color = T.gold
	edge.Thickness = 2.5
	edge.Parent = card

	--[[
		Every line is centred, and it has to be asked for.

		UIKit.outlined ranges LEFT by default -- the recipe was written for the
		HUD's bottom-left stat column, where the readouts line up down one edge.
		Three of them dropped into a full-width label on a centred card inherit
		that, and the chip below is the only thing on the card that centres
		itself, so the whole readout reads as having slipped sideways: three
		lines hard against the left keyline with a button under the middle of
		them. The alignment is the fix; the labels were always full width.
	]]
	local function line(text: string, size: number, colour: Color3, y: number, h: number): TextLabel
		local l = UIKit.outlined(card, text, size, colour)
		l.TextXAlignment = Enum.TextXAlignment.Center
		l.Size = UDim2.new(1, 0, 0, h)
		l.Position = UDim2.fromOffset(0, y)
		return l
	end

	line("THE YARD", 30, T.gold, 10, 38)
	local rate = line("", 25, T.teal, 50, 32)
	local earned = line("", 22, T.cream, 82, 30)

	-- Centred off the card's own middle rather than off a second copy of the 380
	-- above it, so the chip cannot drift if the card is ever resized.
	local chip = UIKit.chip(card, "Back to work", 210, T.green, onLeave)
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.Position = UDim2.new(0.5, 0, 0, 122)

	return { gui = gui, rate = rate, earned = earned }
end

--==[ A VISIT ]===============================================================

local surface: any = nil
-- What the surface has actually been ASKED for, against what the player wants.
-- A fresh DrivewaySurface draws flat, so false is the honest starting value and
-- a player with the setting off never costs a SetDetail call at all.
local sheetOn = false
local plan: { Vector3 } = {}
local step = 1
local card: Card? = nil
local lastAt: Vector3? = nil
local holdUntil = 0
local conn: RBXScriptConnection? = nil
-- the shape of the walk: when the current beat ends, where the leg it is on
-- started (so the turn eases out of a corner as well as into one), and one
-- random phase per visit so two idlers side by side do not wander in step
local pauseUntil = 0
local legFrom: Vector3? = nil
local wanderPhase = 0
-- where it stands to look at the finished job, in two beats -- see start()
local admireBack: Vector3? = nil
local admireStand: Vector3? = nil
local admireTurned = false

local function characterBits(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char then return nil, nil, nil end
	return char,
		char:FindFirstChildOfClass("Humanoid"),
		char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--==[ THE TOOL IN ITS HANDS ]=================================================

--[[
	The squeegee has to be POSED here, and that is not a nicety -- without it the
	tool is invisible.

	Everything you can see of a squeegee (Blade, Head, Collar, Pole) lives in a
	`Rig` model of ANCHORED parts; the only thing Roblox welds into the hand is the
	Handle, and the Handle is Transparency 1. The rig is placed each frame by
	whoever is driving the tool -- and DrivewayClient, which normally does it, keeps
	that behind `if surface and hrp and character`, where `surface` is the nearest
	TAGGED slab within about 90 studs. The AFK plot is deliberately untagged (see the
	note on that in the yard's own design), and it is 6,000 studs from anything that
	is, so nothing ever placed the rig: measured mid-visit, Blade/Head/Collar/Pole
	were sitting 148 studs away from the character while the invisible Handle rode
	in its hand.

	AfkClient's own comment used to claim the equip "buys the authentic model, grip
	and idle for nothing". It buys the grip and the idle. The model needs placing.

	So it is placed the same way DrivewayClient does it, deliberately mirroring that
	call so the puppet's squeegee reads identically to a player's: pivot the rig onto
	the blade line, THEN let SqueegeePose put the hands and the lean around where the
	blade landed. Engage is a flat 1 -- this crew never carries the blade, it is
	always pressing.
]]
--[[
	Studs the blade sits ahead of the feet, and it has to clear the HANDS.

	The Rig's pivot IS the Blade, and the Pole stands almost straight up off it
	(+1.78 y, -0.15 z). SqueegeePose then re-lengths that pole so it ends at the
	hands. So the pole runs from the blade to the hands, and which way it leans is
	decided entirely by which of the two is further forward.

	At 1.3 the blade landed about 0.7 studs ahead of the root once the ease had
	trailed it, and the hands reach roughly a stud out -- so the pole ran FORWARD
	from the blade up to the hands and the whole tool read as being held backwards,
	pulled in toward the body instead of pushed away. Measured that way on 129 frames
	of 152.

	Sized off the reference instead: a player holding one on a driveway, posed by
	DrivewayClient, puts the blade 2.89 studs out and the pole at 1.75, i.e. the
	blade a clear stud beyond the pole. The ease costs about speed/RigEase = 12/19 =
	0.6 studs of that while walking, so 3.0 lands near the reference rather than at
	it. Proven reachable: the reference is a real character's own arms at 2.89.
]]
local BLADE_LEAD = 3.0

local squeegeePose = SqueegeePose.new(player, workspace)
local rigCF: CFrame? = nil
-- the last direction the blade was actually swept in, so a paused puppet keeps
-- holding its squeegee the way it was pushing it rather than snapping to a facing
local sweptDir: Vector3? = nil

--[[
	The tool the CREW is holding, which is the only tool that may be held.

	Re-equipped rather than merely requested, every frame, because the player has a
	clickable hotbar and a GUI button cannot be sunk from out here (see TOOL_KEYS).
	Guarded on already being right, so the ordinary frame is one FindFirstChild and
	no work.

	WHICH tool is the lap's business, not the player's -- see the phase note over
	frame(): the pail while it lays a ribbon, the squeegee while it spreads it.
]]
local function holdTool(name: string): Tool?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum then return nil end
	local held = char:FindFirstChildOfClass("Tool")
	if held and held.Name == name then return held end

	local bp = player:FindFirstChildOfClass("Backpack")
	local want = (bp and bp:FindFirstChild(name)) or char:FindFirstChild(name)
	if want and want:IsA("Tool") then
		pcall(function() hum:EquipTool(want) end)
		return char:FindFirstChild(name) :: Tool?
	end
	return nil
end

--==[ TIPPING THE PAIL ]======================================================

--[[
	The pail tips through its Grip, and it has to be that way.

	A welded tool cannot be posed the way the squeegee is -- the squeegee's parts are
	anchored in a Rig that gets re-framed every tick, the pail's are welded to a
	visible handle. Grip is the HAND's frame in handle space, so multiplying a
	rotation onto it swings the pail about the hand: the bail stays in the fist and
	the pail turns under it, which is how a pail actually tips. That reasoning, the
	tip axis and PourTilt are all DrivewayClient's; this is the same move made for
	the puppet, because the pour has to read from thirty studs away.

	The rest grip is read once per tool and remembered, exactly as DrivewayClient
	does. It assumes the pail is at rest the first time we see it, which holds: the
	player cannot be mid-pour at the moment they arrive in the yard, because entering
	is a teleport and the pour ramp unwinds to rest the moment they stop pressing.
]]
local restGrip: { [Tool]: CFrame } = {}
local pourTilt = 0    -- 0..1 ramp onto Config.PourTilt, so it tips and untips

-- Frame-rate independent ease, same one DrivewayClient and RigController use. This
-- file had no copy of it: the first draft of tipPail called it anyway, which
-- compiles fine and is a nil global at runtime.
local function approach(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function tipPail(tool: Tool, pouring: boolean, dt: number)
	local rest = restGrip[tool]
	if not rest then
		rest = tool.Grip
		restGrip[tool] = rest
	end
	pourTilt = approach(pourTilt, if pouring then 1 else 0, Config.PourTiltEase, dt)
	tool.Grip = (rest :: CFrame) * CFrame.Angles(math.rad(Config.PourTilt) * pourTilt, 0, 0)
end

--[[
	Place the rig, EVERY frame of the visit.

	This used to be called from the tail of frame(), after the pour-and-spread block
	-- which returns early whenever the puppet is paused at a waypoint, turning
	between lanes, or standing admiring the finished job. On those frames nothing
	placed the rig, so it stayed where it last was while its owner walked on and
	rotated: the squeegee ended up beside the character, or behind it, at an angle
	that had been correct several studs ago. That is the "held weird at certain
	times".

	So it runs unconditionally, and when there is no sweep to take a direction from
	it falls back to the way the character is facing -- which is where a person who
	has stopped pushing would be holding it anyway.
]]
local function poseSqueegee(hrp: BasePart, dt: number)
	local tool = holdTool("Squeegee")
	local rig = tool and tool:FindFirstChild("Rig") :: Model?
	if not rig then
		rigCF = nil
		return
	end

	local dir = sweptDir
	if not dir then
		local lv = hrp.CFrame.LookVector
		local flat = Vector3.new(lv.X, 0, lv.Z)
		dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	end

	--[[
		AHEAD of the feet, not under them.

		The simulation sweeps at the puppet's own position -- that is the ground it is
		standing on and the coat has to land there -- but a person pushing a squeegee
		has it out in front, with their arms reaching down the pole. Placed under the
		feet it measured dead centre in the character's own frame (x 0.00, z 0.02),
		which reads as standing on top of the blade rather than pushing it, and is what
		was left of "held weird" once it stopped being left behind entirely.

		Visual only, and small: the coat still appears where the simulation put it, and
		the player's own blade is drawn at their aim point, which is ahead of them too.
	]]
	local lead = (dir :: Vector3) * BLADE_LEAD
	local at = if surface and surface.ready
		then surface:SurfacePoint(hrp.Position + lead)
		else hrp.Position + lead - Vector3.new(0, 2.6, 0)

	-- eased toward the target rather than snapped, on the same constant
	-- DrivewayClient uses, or the blade twitches each time the lane turns
	local target = CFrame.lookAt(at, at + (dir :: Vector3)) * CFrame.Angles(math.rad(6), 0, 0)
	rigCF = if rigCF then rigCF:Lerp(target, 1 - math.exp(-Config.RigEase * dt)) else target
	rig:PivotTo((rigCF :: CFrame) * CFrame.new(0, 0.17, 0))
	-- after the pivot, never before: the poser re-lengths the handle to end at the
	-- hands and measures from where the blade just landed
	SqueegeePose.Update(squeegeePose, rig, 1)
end

--[[
	Texels the yard's surface may repaint in one frame; see frame().

	A formula rather than the flat 8,000 it used to be, because the yard was the
	one repaint in the game that was not priced against the device. DrivewayClient
	converts a millisecond budget at the measured cost of a texel and then scales
	it by frame time -- SEALER_FRAME_REF / SEALER_FRAME_MAX / SEALER_PAINT_MIN
	there -- while this file handed out the same 8,000 whether the client was
	drawing at 144 fps or crawling at 20. A phone already down at 20 fps still
	spent the full 8,000, about 2.7x what DrivewayClient would have allowed itself
	on the same hardware, on hardware that is by definition already behind. And
	this is the screen people leave running overnight.

	So the allowance falls with frame time: a frame three times as long gets a
	third of the texels. That is the opposite sign to DrivewayClient's scale, and
	deliberately so. There the budget is milliseconds PER FRAME and the player's
	own blade dirties proportionally more ground while the frame lasts, so a long
	frame is OWED more. Here nobody is pushing anything -- demand is a settling
	coat and the odd lap reset -- and a long frame means only that the device
	cannot afford what it is being handed.

	Floored for SEALER_PAINT_MIN's reason, a sweep that stops advancing leaves a
	coat half drawn, and at SEALER_PAINT_MIN's value, since it is the same grid and
	the same chunk rows. The floor is what actually binds past ~2.7x; the 3x clamp
	is kept anyway because it states the other half of the rule -- a fast frame
	never buys MORE than the reference frame's worth, which is what keeps a healthy
	client at exactly the 8,000 it always had.

	Nothing about the picture changes. The dirty flags survive being partly served
	(SurfaceGrid:DirtyRegions), so this only ever moves texels to a later frame.
]]
local AFK_PAINT_CELLS = 8000
local AFK_FRAME_REF = 1 / 60   -- the frame the count above was chosen against
local AFK_FRAME_MAX = 3        -- same cap, and same reason, as SEALER_FRAME_MAX
local AFK_PAINT_MIN = 3000     -- SEALER_PAINT_MIN's value, for SEALER_PAINT_MIN's reason

local function slabFor(i: number): BasePart?
	local yard = workspace:FindFirstChild(Afk.Container)
	local plots = yard and yard:FindFirstChild("Plots")
	local m = plots and plots:FindFirstChild(Afk.plotName(i))
	local slab = m and m:FindFirstChild("Driveway")
	return (slab and slab:IsA("BasePart")) and slab or nil
end

--[[
	Bumped by stop(), and read by the waiter in start().

	A visit that is waiting for its plot to stream in has to be cancellable, or a
	player who arrives and leaves again inside that window gets a puppet that takes
	the wheel a second after they walked out of the yard.
]]
local startGen = 0

local function stop()
	startGen += 1
	if conn then conn:Disconnect() conn = nil end
	-- give the arms and the waist back to the walk animation, and forget the eased
	-- blade CFrame so the next visit does not lerp in from the last one's lane
	SqueegeePose.Clear(squeegeePose)
	rigCF = nil
	sweptDir = nil

	local _, hum = characterBits()
	if hum then
		hum.AutoRotate = true
		--[[
			And the legs go back to the player's own speed.

			`Eff_WalkSpeed` is what SealerUIClient actually applied -- the Walk Speed
			track times the VIP pass -- so it is still right for a player who bought
			the upgrade while they were standing in the yard, which a remembered value
			would not be. DrivewayClient writes the same number every frame once its
			guard clears, so this is belt and braces; it is what matters if that file
			has fallen over, because the one thing this must never do is hand a player
			their character back walking at yard pace.
		]]
		--[[
			UNLESS THE SQUEEGEE BATTLE HAS THEM, in which case the speed is not theirs
			to hand back.

			A visit can end because the arena took the player: they readied up from in
			here, and SqueegeeBattleServer asks the yard to let go (AfkBus) before it
			teleports them and sets everyone in the match to one WalkSpeed, so that a
			maxed Speed track is not the whole contest. Which of those two lands on
			this client first is replication order, and neither order is wrong -- so
			this reads the arena's own switch rather than assuming one.

			The same attribute and the same reasoning as DrivewayClient's guard, which
			has to keep off the arena speed for the whole match. This is one write on
			one frame, so all it can cost is a count-in spent at the player's own pace,
			but it is the only writer left that the arena does not know about.
		]]
		local own = player:GetAttribute("Eff_WalkSpeed")
		if type(own) == "number" and own > 0
			and player:GetAttribute("BattleArena") == nil then
			hum.WalkSpeed = own
		end
		-- cancel the standing MoveTo order, or the humanoid keeps walking to the
		-- last waypoint for a moment after the player has their controls back
		if hum.RootPart then hum:MoveTo(hum.RootPart.Position) end
	end

	giveBackWheel()

	if surface then surface:Destroy() surface = nil end
	sheetOn = false
	if card then card.gui:Destroy() card = nil end
	HudBus.afk = nil
	plan, step, lastAt, holdUntil = {}, 1, nil, 0
	pauseUntil, legFrom = 0, nil
	admireBack, admireStand, admireTurned = nil, nil, false
end

--[[
	The lap is over, and it is the CHOREOGRAPHY that says so, not the coverage.

	The first version waited for Config.CompleteAt and never got there: the walk
	cannot reach the last couple of studs at the end of a lane (see ARRIVE), and
	the fluid does not always carry a full coat into a corner, so coverage settled
	in the low nineties and the drive was never handed back. Gating on the plan
	instead means the lap always ends, on a schedule the player can feel.

	FillSealed is what closes the gap honestly. It is the same call the rebirth
	restore uses to put a driveway straight to finished, and here it is the beat
	where the crew steps back off a job: the coat snaps to perfect, stands for
	HOLD seconds looking like a finished drive, and only then goes back to bare.
]]
local function finishLap()
	local mine = surface
	if not mine or not mine.ready then return end
	mine:FillSealed()
	-- FillSealed already flags the repaint; a solver wake on top of it just bought
	-- SleepDelay's worth of full-grid steps over a cured coat. See
	-- SurfaceGrid.MarkAllDirty.
	mine.grid:MarkAllDirty()
	holdUntil = os.clock() + HOLD
	admireTurned = false
	task.delay(HOLD, function()
		-- `mine == surface` rather than a bare nil check: a player who left and came
		-- straight back has a NEW surface by now, and resetting that one would wipe
		-- a lap that had only just started
		if mine == surface then
			mine:Reset()
			mine.grid:MarkAllDirty()
			lastAt = nil
		end
	end)
end

--[[
	One frame of work.

	Deliberately tolerant: every stage checks whether the thing it needs exists
	and simply skips its own contribution if not. A surface that has not finished
	its mask sweep yet, a character mid-respawn, a slab that has been deleted --
	none of them should stop the puppet walking, because walking is what the
	player is looking at and the money does not depend on any of it.
]]
local function frame(dt: number)
	local _, hum, hrp = characterBits()
	if not hum or not hrp or hum.Health <= 0 then return end

	--[[
		The repaint is metered here too, for the same reason as in DrivewayClient:
		a lap reset calls MarkAllDirty, and an unbudgeted call to that lands the
		whole grid on one frame. The yard is watched rather than played, so a couple
		of frames of catch-up on a settling coat is invisible -- a hitch is not.
		A plot slab is small enough that this is usually the whole thing anyway.
	]]
	if surface then
		surface:Step(dt)
		-- Priced off the frame rather than flat; see AFK_PAINT_CELLS. The clamp's
		-- lower bound of 1 is what hands a healthy client exactly what it always got.
		local frameScale = math.clamp(dt / AFK_FRAME_REF, 1, AFK_FRAME_MAX)
		local paintCells = AFK_PAINT_CELLS / frameScale
		if paintCells < AFK_PAINT_MIN then paintCells = AFK_PAINT_MIN end
		surface:Render(paintCells)

		--[[
			The 3D sheet, IF THE PLAYER ASKED FOR IT.

			The yard is a good home for the sheet -- the player is standing on this
			one slab and DrivewayClient's level-of-detail pass has demoted every real
			driveway on the map, all six thousand studs away, so the editable budget
			is going spare. That is an argument about the BUDGET, and this file used
			to treat it as an argument about the setting: it promoted unconditionally.

			Harmless while the sheet defaulted on -- it only disagreed with somebody
			who had gone and turned it off -- and plainly wrong since it became opt-in
			(2026-08-11), because the yard then handed the 3D surface to everybody who
			had never asked for it. The idle area is also the last place that should
			spend a struggling device's frame budget: it is what people leave running.

			Same `== true` test as DrivewayClient's, and read live rather than once, so
			the switch behaves the same inside the yard as outside -- flip it and the
			slab follows on the next frame, either way.

			Gated on `ready` rather than on a timer. This was a `task.delay(1.5)` with
			a guard against the surface having been swapped underneath it; waiting for
			the thing it was actually waiting for -- the mask sweep -- is both the
			honest condition and immune to that race, since `surface` is re-read here
			every frame.
		]]
		local want = player:GetAttribute("Set_Sheet") == true
		if want ~= sheetOn and surface.ready then
			sheetOn = want
			pcall(function()
				surface:SetDetail(if want
					then DrivewaySurface.Detail.Sheet
					else DrivewaySurface.Detail.Flat)
			end)
		end
	end

	--[[
		WHICH TOOL, and it is the half of the lap that reads from a distance.

		The puppet used to pour and spread on the same frame, every frame, which meant
		it could only ever be holding one of the two -- and it held the squeegee while
		sealer appeared out of thin air in front of it.

		So the legs of the plan alternate. On a pour leg the pail is out and tipping and
		a ribbon goes down; on the next leg the squeegee is out and spreads it. That is
		the order a real crew works in and it is legible at thirty studs, which is the
		only distance this display is ever watched from.

		By LANE, not by `step`. lanePlan lays down two waypoints per lane -- the two
		ends of it -- so consecutive legs alternate long (across a lane) and short (the
		hop sideways to the next one), and parity of `step` therefore put every pour on
		a 4-stud hop and every spread on a full lane. Measured: the pail was out for 26
		frames of 163. Dividing by two counts the lane instead, and the short hop
		inherits the lane it is heading into, which is where the tool swap hides.

		One lane poured, the next spread. LANE_STEP is 4.3 studs and the rubber is 6.4
		wide, so the spreading lane reaches back over the ribbon its neighbour laid --
		which is why alternating works without walking the drive twice.

		Posed and enforced HERE, at the top, not at the tail: everything below can
		return early -- paused at a waypoint, turning, admiring the finished job -- and
		a rig placed only on the surviving frames is a rig left behind its owner.
	]]
	local pouring = (math.ceil(step / 2) % 2) == 1
	if pouring then
		--[[
			Give the ARMS back before putting anything else in them.

			SqueegeePose holds both hands with IKControls, and they stay weighted until
			something clears them -- Clear was only being called when the player left the
			yard. So through every pour lane the arms were still being dragged to where
			the squeegee's pole had been, with the pail simply welded to whatever the hand
			was doing: measured over one lap, the pail sat inside the torso on 145 frames
			of 263 and behind the character on 30. It was not the tip -- at REST the pail
			measured 2.14 studs BEHIND the root, and no rotation of a grip can fix a hand
			that is in the wrong place.

			Clear early-outs when it is already inactive, so this costs nothing on the
			frames after the first.
		]]
		SqueegeePose.Clear(squeegeePose)
		local pail = holdTool("Sealer Bucket")
		if pail then tipPail(pail, true, dt) end
		-- the squeegee goes back to the pack with its Rig inside it, so nothing of it
		-- is left standing on the driveway
		rigCF = nil
	else
		poseSqueegee(hrp, dt)
	end

	--[[
		Standing back and looking at it -- which means stepping OFF it first.

		The puppet used to freeze wherever the last stroke left it, in the middle of
		a coat it had supposedly just finished. That is the one moment in the lap
		nobody stands still for: you walk down to the kerb and look back up the
		drive. Two beats, because the walk down there faces AWAY from the job and a
		crew admiring its own work does not do it with its back turned.
	]]
	if os.clock() < holdUntil then
		hum.WalkSpeed = Afk.WalkSpeed * 0.8
		local goTo = if admireTurned then admireStand else admireBack
		if goTo then
			if not admireTurned then
				local flat = Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
				if (flat - Vector3.new(goTo.X, 0, goTo.Z)).Magnitude < ARRIVE then
					admireTurned = true
				end
			end
			hum:MoveTo(goTo)
		else
			hum:MoveTo(hrp.Position)
		end
		return
	end

	if #plan == 0 then return end

	--[ walking ]-------------------------------------------------------------
	local now = os.clock()

	-- the beat at the end of the last pass; see PAUSE_MIN
	if now < pauseUntil then
		hum:MoveTo(hrp.Position)
		return
	end

	local target = plan[step]
	local flat = Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
	local flatTarget = Vector3.new(target.X, 0, target.Z)
	local gap = (flat - flatTarget).Magnitude
	-- distance out of the corner it has just left; nil on the first leg of a
	-- visit, where there is no corner behind it to be easing out of
	local into = if legFrom then (flat - legFrom).Magnitude else TURN_RADIUS

	--[[
		Slow into the corner and back up out of it, and drift off the line in
		between. Both ride the SAME term, which is what keeps them from fighting:
		the wander is already gone by the time the turn matters, so the puppet still
		arrives at its waypoint instead of circling a target that has been nudged
		sideways out from under it.
	]]
	local edge = math.clamp(math.min(gap, into) / TURN_RADIUS, 0, 1)
	edge = edge * edge * (3 - 2 * edge)
	hum.WalkSpeed = Afk.WalkSpeed * (TURN_FLOOR + (1 - TURN_FLOOR) * edge)

	local aim = target
	local leg = flatTarget - flat
	if leg.Magnitude > 1e-3 then
		local dir = leg.Unit
		local side = Vector3.new(-dir.Z, 0, dir.X)
		aim = target + side * (math.sin(now * WANDER_RATE + wanderPhase) * WANDER * edge)
	end
	hum:MoveTo(aim)

	-- Arrival is tested against the REAL waypoint, never the wandered aim, so a
	-- lane still ends where the plan says it does.
	if gap < ARRIVE then
		legFrom = flatTarget
		pauseUntil = now + PAUSE_MIN + math.random() * (PAUSE_MAX - PAUSE_MIN)
		local nextStep = step % #plan + 1
		step = nextStep
		if nextStep == 1 then
			finishLap()
			return
		end
	end

	if not surface or not surface.ready then return end

	--[ pouring and spreading ]-----------------------------------------------
	local at = surface:SurfacePoint(hrp.Position)
	local last = lastAt
	lastAt = at
	if not last then return end

	local delta = at - last
	local travel = Vector3.new(delta.X, 0, delta.Z).Magnitude
	if travel <= 1e-3 or dt <= 0 then return end
	local dir = Vector3.new(delta.X, 0, delta.Z).Unit

	-- remembered for the pose, which runs on every frame including the ones this
	-- function returns early from
	sweptDir = dir

	if pouring then
		--[[
			The ribbon goes down just AHEAD of the pail's lip, not five studs out.

			It used to land five and a half studs ahead so "the wet pool arrives first and
			the blade walks into it" -- the right call while one frame did both jobs and
			the pour had to happen somewhere the squeegee had not reached. Now the pour
			is its own leg with the pail visibly tipped over that spot, so it belongs
			under the lip: sealer appearing five studs from the pail pouring it is the
			same class of wrong as the squeegee being out for it.

			Poured heavier per stud than the old combined pass, because this leg is the
			only one laying anything and the next one has to have something to push.
		]]
		local lip = surface:SurfacePoint(hrp.Position + dir * POUR_LIP)
		if surface:Contains(lip) then
			surface:Pour(lip, POUR_PER_STUD * travel * POUR_HEAVY, Config.PourRadius)
		end
	else
		-- Spread along the puppet's OWN travel, not its facing -- the same signed
		-- rule the player's blade uses, so a corner gets swept round rather than
		-- smeared across.
		local axis = Vector3.new(-dir.Z, 0, dir.X)
		surface:Squeegee(at, axis, dir, travel, travel / dt, dt, 1)
	end
end

--[[
	The body of a visit, once the ground is definitely here.

	Split out of start() so the slab can be waited for; see start below for why it
	might not be here yet.
]]
local function begin(i: number, slab: BasePart)
	plan = lanePlan(slab)
	sweptDir = nil
	step = 1
	lastAt = nil
	holdUntil = 0
	pauseUntil = 0
	wanderPhase = math.random() * math.pi * 2

	--[[
		Where it stands to look at the finished job, in two beats.

		The bottom of the drive by the kerb is the same spot the player is put down
		on arrival -- the shot the area exists to sell, looking up the drive at the
		house. Reached by walking a couple of studs PAST it and then back, because
		the humanoid faces the way it is walking and the way to that spot is away
		from the work. Both points sit on the slab, so neither puts the puppet in
		the road.
	]]
	local stand = Afk.standCFrame(i).Position
	local topY = slab.Position.Y + slab.Size.Y * 0.5
	admireStand = Vector3.new(stand.X, topY, stand.Z)
	admireBack = (admireStand :: Vector3) + Vector3.new(2.5, 0, 0)
	admireTurned = false

	local _, hum, hrp0 = characterBits()
	if hum then
		hum.AutoRotate = true
		hum.WalkSpeed = Afk.WalkSpeed
	end
	-- so the first leg eases out of standing still rather than starting at pace
	legFrom = if hrp0 then Vector3.new(hrp0.Position.X, 0, hrp0.Position.Z) else nil

	takeWheel()

	--[[
		The real Squeegee out of the backpack, not a prop.

		DrivewayClient's whole tool block is behind `if surface and hrp and
		character`, and its `surface` is the nearest TAGGED slab -- there are none
		within six thousand studs of here -- so the tool is inert in its hands and
		merely held. That buys the authentic model, grip and idle for nothing.
	]]
	local char = player.Character
	local bp = player:FindFirstChildOfClass("Backpack")
	local tool = (bp and bp:FindFirstChild("Squeegee"))
		or (char and char:FindFirstChild("Squeegee"))
	if tool and tool:IsA("Tool") and hum then
		pcall(function() hum:EquipTool(tool) end)
	end

	surface = DrivewaySurface.new(slab)
	sheetOn = false

	card = buildCard(function()
		Control:FireServer("leave")
	end)

	--[[
		The pcall stays; the warn behind it could not.

		Guarding the visit is right -- one bad frame should not stop the puppet, and
		the walk is what the player is looking at -- but an error inside frame() is
		an error on EVERY frame, so the report was sixty warns a second for the rest
		of the visit. warn() is expensive enough on its own that this WAS the freeze:
		a small bug became an unplayable client, and the one line anybody needed
		scrolled past in the first tenth of a second regardless.

		So it is still said, at a rate a person can read, and the ones in between are
		counted rather than dropped -- a fault repeating sixty times a second must not
		look in the log like a fault that happened once. Per visit, so a fresh visit
		always reports straight away.
	]]
	local WARN_EVERY = 3
	local warnAt, warnHidden = -math.huge, 0
	conn = RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(frame, dt)
		if not ok then
			local now = os.clock()
			if now - warnAt >= WARN_EVERY then
				if warnHidden > 0 then
					warn(("[Afk] %s (+%d more since the last of these)")
						:format(tostring(err), warnHidden))
				else
					warn("[Afk] " .. tostring(err))
				end
				warnAt, warnHidden = now, 0
			else
				warnHidden += 1
			end
		end
	end)
end

--[[
	Start a visit, waiting for the ground if it is not here yet.

	This used to look the slab up once and give up with a warning, which was fine
	while the whole map lived on every client. With streaming on it is not: the yard
	is ~5,900 studs from everything else, so on arrival the plot genuinely does not
	exist on this client for a moment -- 1,171 parts do not land inside a frame --
	and giving up there is a visit where the crew stands still and earns nothing.
	That is exactly what shipped: "[Afk] no slab for plot 1; the yard may not be
	built", every time.

	AfkService asks the client to pre-stream the plot before it teleports, so in the
	ordinary case the first look already finds it and none of this runs. This is the
	backstop for the cases it cannot cover -- a slow client, a rejoin straight into
	the yard, a stream request that timed out.

	Bounded by the VISIT rather than by a stopwatch: it gives up when the player is
	no longer on this plot, or when another start/stop has superseded it. A fixed
	timeout would be a guess about someone else's connection.
]]
local function start(i: number)
	stop()                      -- also bumps startGen, cancelling any earlier wait
	local gen = startGen

	local slab = slabFor(i)
	if slab then begin(i, slab) return end

	task.spawn(function()
		local waited = 0
		while true do
			task.wait(0.2)
			waited += 0.2
			-- superseded by another start, or by a stop
			if gen ~= startGen then return end
			-- left the yard while we were waiting
			if Afk.plotOf(player) ~= i then return end
			local s = slabFor(i)
			if s then
				begin(i, s)
				return
			end
			-- said once, not every pass: if it really is not built, the log should say
			-- so without becoming the log
			if waited > 20 and waited < 20.3 then
				warn(("[Afk] still waiting on plot %d after 20 s;"
					.. " the yard may not be built"):format(i))
			end
		end
	end)
end

--==[ THE READOUT'S OWN CLOCK ]===============================================

-- Off the frame loop: these numbers change once a second at most, and
-- formatting them sixty times for the same answer is waste. This is also where
-- the shell's area header gets the yard's name and lap -- see HudBus.afk.
task.spawn(function()
	while true do
		task.wait(0.25)
		local c = card
		local i = Afk.plotOf(player)
		if c and i then
			local perMin = Afk.perMinuteFor(player)
			c.rate.Text = ("$%s / min"):format(comma(perMin))
			local got = (player:GetAttribute(Afk.EarnedAttr) :: number?) or 0
			c.earned.Text = ("$%s earned this visit"):format(comma(got))
			HudBus.afk = {
				plot = i,
				coverage = if surface and surface.ready then surface:Coverage() else 0,
				perMinute = perMin,
			}
		end
	end
end)

--==[ THE SWITCH ]============================================================

--[[
	One attribute drives everything, and the client never decides it.

	Going into the yard is a teleport, so it has to be the server's call; hanging
	the puppet off the same value the server sets means the picture cannot get out
	of step with where the character actually is. It is also what makes leaving
	safe: whatever route out the player takes -- the sign, the button, dying,
	rejoining -- the attribute clears and everything here unwinds from one place.
]]
local function sync()
	local i = Afk.plotOf(player)
	if i then start(i) else stop() end
end

player:GetAttributeChangedSignal(Afk.Attr):Connect(sync)
player.CharacterAdded:Connect(function()
	-- a fresh character has fresh controls and no tool; rebuild against it
	task.wait(0.5)
	sync()
end)
sync()

--==[ THE DOOR IS A PLACE NOW ]============================================

--[[
	There is no "go to the yard" anything on this side any more.

	The rail key that used to live here fired a HudActions action, and because it
	sat a thumb's width from Settings and Shop it had to put a confirm dialog in
	front of itself first -- a teleport six thousand studs is not a press to take
	on trust. Both went on 2026-08-14. The way in is an arena by the spawn that
	AfkService builds and watches: getting onto its trigger means walking through
	a doorway with the answer written over it, which is the confirmation, and the
	server is the only thing that moves a character either way.

	What is left in this file is the VISIT -- the puppet, the surface, the readout
	and the way out, which is the card's own "Back to work" chip. Leaving still
	needs no confirming, for the reason it never did: it is the safe direction,
	and a dialog in front of an exit traps whoever wants out.
]]
