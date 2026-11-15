--!strict
--[[
	SqueegeeBattleClient -- the player's half of the event.

	Owns four things and nothing else: the prompt, the input, the local paint
	simulation, and the HUD (through BattleUI, which draws but decides nothing).

	ONE LISTENER PER REMOTE, IN ONE FILE

	The UI is a module rather than a second LocalScript on purpose. Two scripts
	both connected to MatchState is two copies of the phase, and they go out of
	step the first time one of them yields -- which the paint side does, waiting
	for the arena and building an EditableImage. Same shape SealerUIClient and
	Shell already use here.

	WHAT IS SIMULATED LOCALLY AND WHAT IS NOT

	Everything you can see. The fluid solver, the coat, the cure and the shading
	all run on this machine, over the same SurfaceGrid the neighbourhood's
	driveways use, from the strokes this client made plus the strokes the server
	relayed. What is NOT local is the score: that lives in the server's own
	ownership grid, arrives on MatchState, and is what the HUD draws. So the
	numbers cannot be argued with and the picture cannot cost a frame of latency.

	⚠ THE SQUEEGEE'S VISUAL RIG IS NOT DRAWN HERE. DrivewayClient already places
	it every frame -- its no-surface fallback rays to the ground BLADE_FORWARD
	ahead of the torso, which is exactly where this file puts the simulated blade.
	Posing it from here as well would be two writers on one model, which is the
	bug that left half a squeegee standing in the garage.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local Pack = ReplicatedStorage:WaitForChild("SqueegeeBattle")
local Battle = require(Pack:WaitForChild("BattleConfig"))
local BattleArena = require(Pack:WaitForChild("BattleArena"))
local BattleSurface = require(Pack:WaitForChild("BattleSurface"))
local BattleNet = require(Pack:WaitForChild("BattleNet"))
local BattleUI = require(Pack:WaitForChild("BattleUI"))
-- Whether this player is in the events at all yet. The countdown and the
-- invitation are both held back while the tutorial is running.
local Tutorial = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Tutorial"))

local Remotes = BattleNet.remotes()
local PromptEventUI = Remotes.PromptEventUI :: RemoteEvent
local JoinResponse  = Remotes.JoinResponse :: RemoteEvent
local QueueUpdate   = Remotes.QueueUpdate :: RemoteEvent
local MatchState    = Remotes.MatchState :: RemoteEvent
local StrokeSend    = Remotes.StrokeSend
local StrokeRelay   = Remotes.StrokeRelay
local MatchResults  = Remotes.MatchResults :: RemoteEvent

local ui = BattleUI.new(player)

--==[ STATE ]=================================================================

local phase = Battle.State.Idle
local surface = nil        -- BattleSurface, only while a match is on
local mySlot: number? = nil
local painting = false     -- the clock has started; strokes count
local pressing = false

--[[
	HOW WIDE EACH SLOT'S RUBBER IS, straight from the roster the server sends.

	One number for everybody in a scheduled match; two different ones in a duel,
	where each player keeps the Squeegee Length they bought. This client paints
	EVERY player's strokes -- its own the frame it makes them, and the rest off the
	relay -- so it needs all of them, or a duellist's opponent would be drawn with
	the wrong blade and the picture would disagree with the score.

	The server froze these at seat time, so they cannot change mid-match. Empty
	falls back to Battle.BladeHalfLen inside ApplyStroke, which is the correct
	answer for every scheduled match and for a client that somehow missed the
	roster.
]]
local bladeOf: { [number]: number } = {}

-- Where this client's blade was when it last sent. Kept even while not
-- painting, so pressing the button does not sweep a line from wherever the
-- player was standing when they let go of it.
local lastX, lastZ = 0, 0
local sinceSend = 0

local canvas: BasePart? = nil

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
	local t = char:FindFirstChild(Battle.ToolName)
	return t ~= nil and t:IsA("Tool")
end

--==[ INPUT ]=================================================================

--[[
	Mouse, touch and the right trigger, and nothing else.

	Deliberately NOT shared with DrivewayClient's own press state -- that lives in
	its closure and there is no way to read it, and duplicating the three input
	sources is four lines. `gameProcessed` is honoured so that clicking a button
	on the HUD does not also lay a stroke underneath it.
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
-- otherwise, and the player comes back painting a hole in one spot.
UserInputService.WindowFocusReleased:Connect(function() pressing = false end)

--==[ THE MATCH ]=============================================================

local function teardown()
	painting = false
	mySlot = nil
	if surface then
		surface:Destroy()
		surface = nil
	end
	ui:HideHud()
end

local function buildSurface()
	if surface then return end
	local _, found = BattleArena.await(20)
	canvas = found
	if not canvas then
		warn("[SqueegeeBattle] the arena never arrived; playing without paint")
		return
	end
	surface = BattleSurface.new(canvas)
end

--[[
	One frame of this client's own blade, at Battle.StrokeHz.

	Applied locally and sent in the SAME call, from the same numbers. That is
	what makes this client's picture and the server's score agree: they are two
	consumers of one packet rather than two derivations of one motion. Running
	the local apply per frame instead would paint a slightly different swept
	rectangle from the one the server stamps, and the difference shows up on
	turns as colour the score does not credit.
]]
local function strokeTick(dt: number)
	local s = surface
	local slot = mySlot
	if not s or not slot then return end

	local _, hum, hrp = characterBits()
	if not hum or not hrp then return end

	local look = flatten(hrp.CFrame.LookVector)
	local centre = s:SurfacePoint(hrp.Position + look * Battle.BladeForward)
	local ex, ez = s:ToLocal(centre)
	local ax, az = s:DirToLocal(Vector3.new(-look.Z, 0, look.X))
	local lx, lz = s:DirToLocal(look)

	--[[
		Off the ground, the blade comes out of the work -- cut, not ramped.

		Exactly DrivewayClient's rule and for its reason: leaving the ground is not
		a deliberate lift, so there is nothing to ease. Without it a player can hop
		the length of the arena laying coat through the air.
	]]
	local state = hum:GetState()
	local airborne = state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.FallingDown

	local live = painting and pressing and not airborne and holdingSqueegee()
	if not live then
		-- Keep the anchor current, or the next press sweeps a stripe from here to
		-- wherever they walked in between.
		lastX, lastZ = ex, ez
		return
	end

	local packet = { lastX, lastZ, ex, ez, ax, az, lx, lz, dt }
	s:ApplyStroke(slot, lastX, lastZ, ex, ez, ax, az, lx, lz, dt, bladeOf[slot])
	StrokeSend:FireServer(packet)
	lastX, lastZ = ex, ez
end

--==[ FRAME BUDGETS ]=========================================================

--[[
	The two ceilings the neighbourhood learned the hard way, ported.

	1. The solver is STRETCHED under load rather than allowed to eat the frame,
	   and when it is stretched it is told so (`longStep`), or DrivewaySurface
	   clamps the carried interval to one fixed step and bins the rest -- measured
	   at 83% of real time thrown away at 30 fps, which starves the cure as well
	   as the flow.

	2. The repaint allowance is texels PER FRAME, so it has to scale with dt or
	   its texels-per-SECOND falls with the frame rate while eight squeegees keep
	   moving in real time. Same SEALER_FRAME_REF correction, same cap of 3x.

	The arena is one surface rather than a street of them, so there is no
	round-robin here and no priority split -- the slab underfoot IS the slab.
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
		Re-asserted every frame rather than set once.

		SealerUIClient rewrites WalkSpeed from the Speed track on every CharacterAdded
		and on every Upg_ change, and a player can die and respawn mid-match. One write
		a frame is nothing and it makes the rule true rather than merely intended.

		WHAT the rule is now comes from Battle.walkSpeedOf: the arena's flat speed for
		a scheduled match, this player's own bought speed for a duel, and NIL for a
		place running with EqualSpeed off -- in which case nothing here touches
		WalkSpeed at all, which is what the old `if Battle.EqualSpeed` guard did and
		why the nil has to be honoured rather than defaulted.
	]]
	if painting then
		local want = Battle.walkSpeedOf(player)
		if want then
			local _, hum = characterBits()
			if hum and hum.WalkSpeed ~= want then
				hum.WalkSpeed = want
			end
		end
	end

	sinceSend += dt
	local every = 1 / Battle.StrokeHz
	if sinceSend >= every then
		strokeTick(sinceSend)
		sinceSend = 0
	end

	local frameScale = math.clamp(dt / FRAME_REF, 1, FRAME_MAX)
	local solveEvery = math.clamp(math.ceil(solveMs / SOLVE_MS), 1, 3)

	local t0 = os.clock()
	s:Step(dt, solveEvery, solveEvery > 1)
	local ms = (os.clock() - t0) * 1000
	-- Snap up, decay down: an expensive frame has to be believed at once, a
	-- cheap one only suggests the load has lifted. Same asymmetry DrivewayClient
	-- uses on its own paint estimate.
	if ms > solveMs then solveMs = ms else solveMs += (ms - solveMs) * 0.08 end

	s:Render(math.floor(PAINT_TEXELS * frameScale))
end)

--==[ THE STANDING CLOCK ]====================================================

--[[
	Driven by ATTRIBUTES on the pack folder, not by a remote.

	Both are read once here and then on every change, which is what makes this
	correct for a player who joins eleven minutes into a gap: the attribute is
	already replicated and already carries the right deadline, so their first
	frame draws the same number everybody else is looking at. A remote would have
	to be re-fired per join, and anyone who missed a broadcast would sit in front
	of a blank clock until the next event.

	The phase is read from the same place rather than from the local `phase`
	above, deliberately -- `phase` only moves when a MatchState arrives, and a
	non-participant never receives most of those.
]]
--[[
	Nothing is drawn until we know whether this player is still in the tutorial.

	Same gate, same reasoning and the same twenty second give-up as
	GoldenHourClient's: the flag arrives from the DataStore a moment after this
	script does, and the attribute this widget watches can change inside that
	moment. Drawing either answer and correcting it a second later is a badge
	that appears and vanishes in front of the player, which reads as a bug.
]]
local tutorialKnown = false

local function refreshTicker()
	if not tutorialKnown then return end

	--[[
		AND NOT WHILE THE TUTORIAL IS RUNNING (owner's call, 2026-08-12).

		This badge is the only warning either event gives, so it is the timer the
		brief means: a player who has not yet sealed their first driveway is not
		offered the battle and is not inside a Golden Hour, and a countdown to
		something they cannot take part in is furniture at best and a distraction
		from the one job they have been given at worst.

		It comes back by itself. Tutorial.onChanged re-enters here the moment the
		flag moves, and the deadline is an attribute that was replicated the whole
		time -- so the badge appears mid-gap reading the same number everybody else
		has been looking at, rather than waiting for the next slot to be announced.
	]]
	if Tutorial.inProgress(player) then
		ui:SetTicker(nil, nil)
		return
	end

	local at = Pack:GetAttribute(Battle.NextAtAttr)
	local ph = Pack:GetAttribute(Battle.PhaseAttr)

	--[[
		THE POPULATION GUARD IS GONE, and what it was guarding against went first.

		This used to hide the badge whenever the server held fewer than MinPlayers,
		and at the time that was right: the clock meant "a battle is coming", the
		scheduler would not open one below two players, so on a quiet server it
		reached zero with nothing to show and jumped back to a fresh fifteen
		minutes -- which reads as broken, because it is indistinguishable from it.

		It can no longer reach zero with nothing to show. There is one schedule now
		(ServerScriptService.EventHandler), it tosses a coin between the battle and
		Golden Hour, and a battle that cannot run hands its slot over rather than
		spending it -- and Golden Hour needs nobody else. So EVERY slot produces an
		event at zero whatever the population.

		Keeping the guard would therefore hide an honest countdown from precisely
		the lone player whose event is the certain one, which is the opposite of
		what it was written to do.
	]]
	ui:SetTicker(if type(at) == "number" then at else nil,
		if type(ph) == "string" then ph else nil)
end

Pack:GetAttributeChangedSignal(Battle.NextAtAttr):Connect(refreshTicker)
Pack:GetAttributeChangedSignal(Battle.PhaseAttr):Connect(refreshTicker)
-- PlayerAdded/PlayerRemoving used to be hooked here as well. They existed only
-- to re-test the population guard above, and with it gone they were two
-- connections that recomputed an unchanged answer on every join.
--
-- The third source is the tutorial finishing -- or, for a returning player, the
-- profile landing with it already finished, which fires no change of its own.
-- Tutorial.onChanged covers both; see the note there.
Tutorial.onChanged(player, refreshTicker)
task.spawn(function()
	Tutorial.await(player)
	tutorialKnown = true
	refreshTicker()
end)

--==[ REMOTES ]===============================================================

PromptEventUI.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	if payload.open then
		--[[
			The second half of a rule the server already keeps.

			SqueegeeBattleServer does not fire the invitation at a player who has not
			finished the tutorial, and its JoinResponse handler refuses one anyway --
			so this cannot normally be reached. It is here for the same reason the
			Daily rail lock has a matching refusal in the till: a rule kept in one
			place is a rule the other place is free to break by accident later.

			`isDone` rather than `not inProgress`, and the asymmetry is deliberate --
			this one lets somebody IN, so a profile that has not landed yet reads as
			not eligible. See the note at the top of Tutorial.
		]]
		if not Tutorial.isDone(player) then return end
		--[[
			Both answers close the panel, and only DECLINE used to.

			Accepting left it up so the queue readout could fill in underneath the
			button -- but a decision the player has already made does not need a panel
			across the middle of their screen for the rest of the window, and the
			invitation is the last thing they want to still be looking at while they
			walk to the arena. AcceptPrompt rather than HidePrompt because the two are
			not the same afterwards: it remembers that this player is IN, which is what
			brings the panel back if the event is then cancelled under them.
		]]
		ui:ShowPrompt(payload.seconds or Battle.InviteSeconds, function()
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
		ui:HidePrompt(info.reason or "Event cancelled")
		return
	end
	ui:SetQueue(info)
end)

MatchState.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	if payload.phase then phase = payload.phase end

	--[[
		The roster message is the start of a match, and it is the only one that
		carries names -- see the note where the server sends it.
	]]
	if payload.roster then
		mySlot = nil
		table.clear(bladeOf)
		for _, e in ipairs(payload.roster) do
			if e.userId == player.UserId then mySlot = e.slot end
			-- nil for a server that predates the duel kit; ApplyStroke falls back.
			if type(e.blade) == "number" then bladeOf[e.slot] = e.blade end
		end
		painting = false
		buildSurface()
		ui:ShowHud(payload.roster)
		ui:SetClock(payload.total or Battle.MatchSeconds, payload.total or Battle.MatchSeconds)
		if payload.countIn then ui:CountIn(payload.countIn) end
	end

	if payload.go then
		painting = true
		-- Anchor the blade where the player is standing THIS frame, or the first
		-- stroke of the match sweeps from the arena origin to their spawn pad.
		local s = surface
		local _, _, hrp = characterBits()
		if s and hrp then
			local look = flatten(hrp.CFrame.LookVector)
			lastX, lastZ = s:ToLocal(s:SurfacePoint(hrp.Position + look * Battle.BladeForward))
		end
	end

	if payload.dropped and surface then
		surface:ReleaseSlot(payload.dropped)
	end

	if payload.left then
		ui:SetClock(payload.left, payload.total or Battle.MatchSeconds)
	end
	if payload.rows then
		ui:SetStandings(payload.rows)
	end
	if payload.over then
		painting = false
	end

	if payload.phase == Battle.State.Idle then
		teardown()
	end
end)

StrokeRelay.OnClientEvent:Connect(function(batch)
	local s = surface
	if not s or type(batch) ~= "table" then return end
	local mine = mySlot
	for _, row in ipairs(batch) do
		if type(row) == "table" and #row == 10 then
			local slot = row[1]
			--[[
				Skip our own. They were applied the frame they were made; replaying
				them a relay period later would lay a second coat over the same
				ground and, worse, stamp ownership from a stale position -- paint
				appearing a fifth of a second behind the squeegee.
			]]
			if slot ~= mine then
				s:ApplyStroke(slot, row[2], row[3], row[4], row[5],
					row[6], row[7], row[8], row[9], row[10], bladeOf[slot])
			end
		end
	end
end)

MatchResults.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then return end
	painting = false
	ui:ShowResults(payload)
end)

--[[
	A respawn mid-match keeps the HUD and re-anchors the blade.

	The ScreenGui is ResetOnSpawn = false so the bar survives on its own; what
	does not survive is `lastX/lastZ`, which point at where the old character was
	standing. Left alone, the first stroke after a respawn sweeps a stripe from
	the place they died to the place they came back.
]]
player.CharacterAdded:Connect(function(char)
	pressing = false
	local hrp = char:WaitForChild("HumanoidRootPart", 5)
	local s = surface
	if s and hrp and hrp:IsA("BasePart") then
		local look = flatten(hrp.CFrame.LookVector)
		lastX, lastZ = s:ToLocal(s:SurfacePoint(hrp.Position + look * Battle.BladeForward))
	end
end)
