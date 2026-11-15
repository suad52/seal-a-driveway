--!strict
--[[
	DrivewayRaceClient -- the player's half of the event.

	Owns four things and nothing else: the prompt, the input, the local sealcoat
	simulation of THIS PLAYER'S OWN LANE, and the HUD (through RaceUI, which draws
	but decides nothing).

	ONE LISTENER PER REMOTE, IN ONE FILE

	The UI is a module rather than a second LocalScript on purpose. Two scripts both
	connected to RaceState is two copies of the phase, and they go out of step the
	first time one of them yields -- which the paint side does, building an
	EditableImage. Same shape SealerUIClient, Shell and SqueegeeBattleClient use.

	WHAT IS SIMULATED LOCALLY AND WHAT IS NOT

	Everything you can see. The fluid solver, the coat, the cure and the shading all
	run on this machine, over the same SurfaceGrid the neighbourhood's driveways
	use, from the strokes this client made. What is NOT local is the SCORE: that
	lives in the server's own stamp grid, arrives on RaceState, and is what the HUD
	draws. So the placings cannot be argued with and the picture cannot cost a frame
	of latency.

	The two do not disagree in any way a player can see, because the blade feeds
	itself: ground the rubber has been over is ground that has sealer on it. Where
	they differ is TIMING -- the coat takes a few seconds to cure and the stamp does
	not -- which is exactly why the race is ranked on the stamp. See RaceGrid.

	THE SQUEEGEE'S VISUAL RIG IS NOT DRAWN HERE. DrivewayClient already places it
	every frame -- its no-surface fallback rays to the ground BLADE_FORWARD ahead of
	the torso, which is exactly where this file puts the simulated blade. Posing it
	from here as well would be two writers on one model, which is the bug that left
	half a squeegee standing in the garage.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local Pack = ReplicatedStorage:WaitForChild("DrivewayRace")
local Race = require(Pack:WaitForChild("RaceConfig"))
local RaceYard = require(Pack:WaitForChild("RaceYard"))
local RaceSurface = require(Pack:WaitForChild("RaceSurface"))
local RaceNet = require(Pack:WaitForChild("RaceNet"))
local RaceUI = require(Pack:WaitForChild("RaceUI"))
-- Whether this player is in the events at all yet. The invitation is held back
-- while the tutorial is running.
local Tutorial = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Tutorial"))

local Remotes = RaceNet.remotes()
local PromptRaceUI = Remotes.PromptRaceUI :: RemoteEvent
local JoinResponse = Remotes.JoinResponse :: RemoteEvent
local QueueUpdate  = Remotes.QueueUpdate :: RemoteEvent
local RaceState    = Remotes.RaceState :: RemoteEvent
local StrokeSend   = Remotes.StrokeSend
local RaceResults  = Remotes.RaceResults :: RemoteEvent

local ui = RaceUI.new(player)

--==[ STATE ]=================================================================

local phase = Race.State.Idle
local surface = nil        -- RaceSurface, only while a race is on
local mySlot: number? = nil
local sealing = false      -- the flag has dropped; strokes count
local pressing = false
local myLane: any = nil    -- the geometry the server sent, kept for the rebuild

-- Where this client's blade was when it last sent. Kept even while not sealing,
-- so pressing the button does not sweep a line from wherever the player was
-- standing when they let go of it.
local lastX, lastZ = 0, 0
local sinceSend = 0

--==[ SMALL HELPERS ]=========================================================

local function flatten(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude < 1e-4 then Vector3.new(0, 0, -1) else f.Unit
end

local function characterBits(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	if not char or not char.Parent then return nil, nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or not hrp:IsA("BasePart") then return char, hum, nil end
	return char, hum, hrp
end

local function holdingSqueegee(): boolean
	local char = player.Character
	if not char then return false end
	local t = char:FindFirstChild(Race.ToolName)
	return t ~= nil and t:IsA("Tool")
end

--==[ INPUT ]=================================================================

--[[
	Mouse, touch and the right trigger, and nothing else.

	Deliberately NOT shared with DrivewayClient's own press state -- that lives in
	its closure and there is no way to read it, and duplicating the three input
	sources is four lines. `gameProcessed` is honoured so that clicking a button on
	the HUD does not also lay a stroke underneath it.
]]
local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))

Console.Changed:Connect(function() pressing = false end)
local function pressStart(input: InputObject, gameProcessed: boolean)
	if gameProcessed or Console.blocked() then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.ButtonR2 then
		pressing = true
	end
end

local function pressEnd(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.ButtonR2 then
		pressing = false
	end
end

UserInputService.InputBegan:Connect(pressStart)
UserInputService.InputEnded:Connect(pressEnd)
-- A window that loses focus mid-stroke leaves the button "down" forever
-- otherwise, and the player comes back sealing a hole in one spot.
UserInputService.WindowFocusReleased:Connect(function() pressing = false end)

--==[ THE LANE ]==============================================================

local function teardown()
	sealing = false
	mySlot = nil
	myLane = nil
	if surface then
		surface:Destroy()
		surface = nil
	end
	ui:HideHud()
end

--[[
	Built from the NUMBERS THE SERVER SENT, not from the lane part.

	The slab is resized and moved a fraction of a second before this runs, and a
	property write and a RemoteEvent fired straight after it are not ordered against
	each other for a client that is streaming the region in at the same moment. A
	client that measured the part could therefore build a grid for the PREVIOUS
	race's lane and seal half of it into the plaza. The payload cannot be stale --
	it was written by the same call that placed the part. See RaceYard.layout.

	The part still has to exist for the player to stand on, which is what the yard
	being Persistent and the stream request before the teleport are for; nothing
	here waits on it.
]]
local function buildSurface(lane)
	if surface then return end
	surface = RaceSurface.new({
		topCF = lane.topCF,
		cell = lane.cell,
		cw = lane.cw,
		ch = lane.ch,
		halfLen = lane.halfLen,
	})
end

-- Anchor the blade where the player is standing THIS frame, or the next stroke
-- sweeps a stripe from wherever the anchor was left to where they are now.
local function reanchor()
	local s = surface
	local _, _, hrp = characterBits()
	if not s or not hrp then return end
	local look = flatten(hrp.CFrame.LookVector)
	lastX, lastZ = s:ToLocal(s:SurfacePoint(hrp.Position + look * Race.BladeForward))
end

--[[
	One frame of this client's own blade, at Race.StrokeHz.

	Applied locally and sent in the SAME call, from the same numbers. That is what
	makes this client's picture and the server's score agree: they are two consumers
	of one packet rather than two derivations of one motion. Running the local apply
	per frame instead would seal a slightly different swept rectangle from the one
	the server stamps, and the difference shows up on turns as coat the score does
	not credit.
]]
local function strokeTick(dt: number)
	local s = surface
	if not s then return end

	local _, hum, hrp = characterBits()
	if not hum or not hrp then return end

	local look = flatten(hrp.CFrame.LookVector)
	local centre = s:SurfacePoint(hrp.Position + look * Race.BladeForward)
	local ex, ez = s:ToLocal(centre)
	local ax, az = s:DirToLocal(Vector3.new(-look.Z, 0, look.X))
	local lx, lz = s:DirToLocal(look)

	--[[
		Off the ground, the blade comes out of the work -- cut, not ramped.

		Exactly DrivewayClient's rule and for its reason: leaving the ground is not a
		deliberate lift, so there is nothing to ease. Without it a player can hop the
		length of their lane laying coat through the air.
	]]
	local state = hum:GetState()
	local airborne = state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.FallingDown

	local on = sealing and pressing and not airborne and holdingSqueegee()
	if not on then
		-- Keep the anchor current, or the next press sweeps a stripe from here to
		-- wherever they walked in between.
		lastX, lastZ = ex, ez
		return
	end

	local packet = { lastX, lastZ, ex, ez, ax, az, lx, lz, dt }
	s:ApplyStroke(lastX, lastZ, ex, ez, ax, az, lx, lz, dt)
	StrokeSend:FireServer(packet)
	lastX, lastZ = ex, ez
end

--==[ FRAME BUDGETS ]=========================================================

--[[
	The two ceilings the neighbourhood learned the hard way, ported.

	1. The solver is STRETCHED under load rather than allowed to eat the frame, and
	   when it is stretched it is told so (`longStep`), or the surface clamps the
	   carried interval to one fixed step and bins the rest -- measured at 83% of
	   real time thrown away at 30 fps, which starves the cure as well as the flow.

	2. The repaint allowance is texels PER FRAME, so it has to scale with dt or its
	   texels-per-SECOND falls with the frame rate while the squeegee keeps moving
	   in real time. Same SEALER_FRAME_REF correction, same cap of 3x.

	The budgets are the arena's rather than the neighbourhood's, because the shape
	of the load is the arena's: ONE surface with a blade on it continuously for the
	whole event, instead of a street of mostly-idle slabs to round-robin between.
	There is no priority split here for the same reason -- the lane underfoot IS the
	lane.
]]
local SOLVE_MS = 2.6
local PAINT_TEXELS = 9000
local FRAME_REF = 1 / 60
local FRAME_MAX = 3

local solveMs = 0

RunService.Heartbeat:Connect(function(dt)
	local s = surface
	if not s then return end

	--[[
		NOTHING TOUCHES WalkSpeed HERE, and that is the whole difference from the
		arena.

		SqueegeeBattleClient re-asserts one speed for everybody every frame, because
		the arena is a shared canvas and a 2.2x movement advantage would settle it
		before anybody turned a corner. A race gives every player their own driveway
		sized to their own kit instead -- so their legs are theirs, DrivewayClient goes
		on writing their bought speed every frame exactly as it does at home, and the
		lane they were given already accounts for it. See RaceConfig.SpeedWeight.
	]]

	sinceSend += dt
	local every = 1 / Race.StrokeHz
	if sinceSend >= every then
		strokeTick(sinceSend)
		sinceSend = 0
	end

	local frameScale = math.clamp(dt / FRAME_REF, 1, FRAME_MAX)
	local solveEvery = math.clamp(math.ceil(solveMs / SOLVE_MS), 1, 3)

	local t0 = os.clock()
	s:Step(dt, solveEvery, solveEvery > 1)
	local ms = (os.clock() - t0) * 1000
	-- Snap up, decay down: an expensive frame has to be believed at once, a cheap
	-- one only suggests the load has lifted. Same asymmetry DrivewayClient uses on
	-- its own paint estimate.
	if ms > solveMs then solveMs = ms else solveMs += (ms - solveMs) * 0.08 end

	s:Render(math.floor(PAINT_TEXELS * frameScale))
end)

--==[ THE LANE BOARDS ]=======================================================

--[[
	Every racer's name and percentage, written onto the post at the head of their
	lane -- from THIS client, off the standings it already receives.

	The server could set the labels and they would replicate, but that is eight
	string properties five times a second replicated to everyone in the server for a
	sign only eight people can read. The standings are already on their way here for
	the HUD; drawing them twice out of one message is free.
]]
local function paintBoards(rows: { any })
	local model = RaceYard.find()
	if not model then return end
	for rank, r in ipairs(rows) do
		local who, pct = RaceYard.boardOf(model, r.slot)
		if who then who.Text = ("%d. %s"):format(rank, r.name or Race.slotNameOf(r.slot)) end
		if pct then
			pct.Text = if r.finishedAt then "DONE"
				else ("%.0f%%"):format((r.progress or 0) * 100)
		end
	end
end

local function clearBoards()
	local model = RaceYard.find()
	if not model then return end
	for slot = 1, Race.MaxPlayers do
		local who, pct = RaceYard.boardOf(model, slot)
		if who then who.Text = "" end
		if pct then pct.Text = "" end
	end
end

--==[ REMOTES ]===============================================================

PromptRaceUI.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	if payload.open then
		--[[
			The second half of a rule the server already keeps.

			DrivewayRaceServer does not fire the invitation at a player who has not
			finished the tutorial, and its JoinResponse handler refuses one anyway -- so
			this cannot normally be reached. It is here because a rule kept in one place
			is a rule the other place is free to break by accident later.

			`isDone` rather than `not inProgress`, and the asymmetry is deliberate -- this
			one lets somebody IN, so a profile that has not landed yet reads as not
			eligible. See the note at the top of Tutorial.
		]]
		if not Tutorial.isDone(player) then return end
		--[[
			Both answers close the panel. A decision the player has already made does not
			need a panel across the middle of their screen for the rest of the window.
			AcceptPrompt rather than HidePrompt because the two are not the same
			afterwards: it remembers that this player is IN, which is what brings the
			panel back if the event is then cancelled under them.
		]]
		ui:ShowPrompt(payload.seconds or Race.InviteSeconds, function()
			JoinResponse:FireServer(true)
			ui:AcceptPrompt()
		end, function()
			JoinResponse:FireServer(false)
			ui:HidePrompt()
		end)
	else
		ui:HidePrompt(payload.reason)
	end
end)

QueueUpdate.OnClientEvent:Connect(function(info)
	if type(info) ~= "table" then return end
	if info.cancelled then
		ui:HidePrompt(info.reason or "Race cancelled")
		return
	end
	ui:SetQueue(info)
end)

RaceState.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	if payload.phase then phase = payload.phase end

	--[[
		The roster message is the start of a race, and it is the only one that carries
		names and lane geometry -- see the note where the server sends it.
	]]
	if payload.roster then
		mySlot = nil
		for _, e in ipairs(payload.roster) do
			if e.userId == player.UserId then mySlot = e.slot end
		end
		sealing = false
		myLane = payload.lane
		if myLane then buildSurface(myLane) end
		ui:ShowHud(payload.roster)
		ui:SetClock(0, nil)
		if payload.countIn then ui:CountIn(payload.countIn) end
	end

	if payload.go then
		sealing = true
		reanchor()
	end

	if payload.finished then
		ui:Finished(payload.finished.place or 1, payload.finished.at or 0)
	end

	if payload.elapsed then
		ui:SetClock(payload.elapsed, payload.closing)
	end
	if payload.rows then
		ui:SetStandings(payload.rows)
		paintBoards(payload.rows)
	end
	if payload.over then
		sealing = false
	end

	if payload.phase == Race.State.Idle then
		clearBoards()
		teardown()
	end
end)

RaceResults.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	sealing = false
	ui:ShowResults(payload)
end)

--[[
	A respawn mid-race keeps the HUD and re-anchors the blade.

	The ScreenGui is ResetOnSpawn = false so the bar survives on its own; what does
	not survive is `lastX/lastZ`, which point at where the old character was
	standing. Left alone, the first stroke after a respawn sweeps a stripe from the
	place they died to the head of the lane the server has just put them back on.
]]
player.CharacterAdded:Connect(function(char)
	pressing = false
	char:WaitForChild("HumanoidRootPart", 5)
	reanchor()
end)
