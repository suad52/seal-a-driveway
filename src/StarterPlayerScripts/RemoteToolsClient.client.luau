--!strict
--[[
	RemoteToolsClient -- other people's tools, in other people's hands.

	The squeegee and the wand are not ordinary welded tools. Everything you can
	SEE of one -- blade, head, collar, pole -- lives in a `Rig` model of ANCHORED
	parts; the only thing Roblox welds into the hand is a Handle at Transparency
	1. The rig is placed every frame by whoever is driving the tool, and until now
	that was only ever DrivewayClient placing the LOCAL player's.

	So on your screen everybody else was miming. Their squeegee was a set of
	anchored parts sitting wherever the server last left them -- for a freshly
	built tool, the world origin -- while an invisible handle rode in their fist.

	This is the missing half: every client poses every OTHER player's rig. It is
	the same arrangement the tools already rely on, just applied to the players
	who are not you. Anchored parts moved from a client do not replicate, so four
	people watching one squeegee each place their own copy of it and nobody
	fights anybody.

	The pail needs nothing here -- it is genuinely welded and always showed.

	WHAT THIS DOES NOT KNOW

	Whether they are actually pressing. Engage is local state on their machine and
	relaying it would be a remote per player per frame for a few degrees of blade
	tilt. The rig is placed in the working pose, which is right whenever they are
	working and reads as "carrying it ready" when they are not -- both far better
	than the tool being invisible.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Config"))
local ToolBuilder = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("ToolBuilder"))
--[[
	For the blade width, and it has to be the LADDER rather than the effect.

	SealerUIClient publishes `Eff_BladeWidth`, which looks like exactly the number
	wanted here and cannot be used: it is written by a LocalScript, and a client's
	attribute write never leaves that client. Read from another machine it is nil.
	`Upg_Blade` is UpgradeService's, set on the server on profile load and on every
	purchase, so it is the one figure about somebody else's squeegee this client is
	actually allowed to know -- and Upgrades.valueAt is pure, so turning a level
	into studs gives the same answer here as it does on their screen.
]]
local Upgrades = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Upgrades"))

local player = Players.LocalPlayer

-- Matches BLADE_FORWARD in DrivewayClient: the rubber rides this far ahead of
-- the torso. Kept in step by hand because the two files share no module and one
-- number is not worth one.
local BLADE_FORWARD = 2.9

local ground = RaycastParams.new()
ground.FilterType = Enum.RaycastFilterType.Exclude
ground.IgnoreWater = true

local function flatten(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude < 1e-4 then Vector3.new(0, 0, -1) else f.Unit
end

--==[ A RIG NOBODY IS POSING MUST NOT BE DRAWN ]==============================
--[[
	The ghost squeegee, and it is the hand-tool half of the bug the trucks below
	already guard against -- read the note over ORPHAN_FAR, because the mechanism
	is identical and this half simply never got the same treatment.

	A rig is ANCHORED. Its replicated pose is whatever the server last set, and the
	server never set one, so every squeegee in the game rests at the WORLD ORIGIN
	-- measured live: with the tool held, the server's copy of the blade sits at
	(0, 0.17, 0), 181 studs from a player standing at the depot. The origin is
	inside Neighbourhood.Street.Road (x -15..15, z -147..130), so that is a
	squeegee lying in the middle of the road with nobody near it. DrivewayServer
	parks it on its holder now, which moves the resting pose out of the road, but
	it does not follow them: only the per-frame pose below does that.

	So the rig is in the right place ONLY while this loop is placing it, and
	`pose` had four ways to stop placing one while it was still on screen:

	  no HumanoidRootPart. Under StreamingEnabled a character model arrives in
	    pieces, so this client can hold somebody's Tool -- and therefore their rig
	    -- before it holds their root. The truck half says the same thing about a
	    blade arriving without a chassis; it is the same engine behaviour.
	  Player.Character not yet assigned, though the model is already in Workspace
	    and named for them. That assignment is not simultaneous on a remote client.
	  the tool is not a kind this file places (the pail), which is fine, and
	  anything else that ever gets added to that list, which is not.

	Every one of them ends identically: an invisible handle in somebody's fist and
	a squeegee standing somewhere else, working away on its own. That is the report
	-- "a player with no squeegee in their hand and their squeegee a long distance
	from them, like a ghost squeegeeing".

	The first two are fixed outright below. This is the backstop for the rest, and
	it is deliberately the crude, total one: if nothing placed a rig on this frame,
	it is not drawn. Being briefly invisible is a far smaller lie than standing in
	the road pretending somebody is using it.

	LocalTransparencyModifier rather than Transparency, for the reason `conceal`
	gives further down: this is one client's opinion about a replicated part and
	the server's own value has to survive it.
]]
--[[
	The state only, never the parts.

	The table is weak-KEYED so a rig whose tool has been destroyed drops out on its
	own -- and holding its part list in the value would defeat exactly that: the
	value would keep the parts alive, the parts keep their Parent alive, and the
	key could never be collected. One entry leaked per player who ever joined.

	So the parts are re-walked on each transition instead. That runs only when the
	state actually flips, a rig is five parts, and it has the better property
	anyway: a part that streamed in after a cached look cannot be the one left
	visible on its own in the road.
]]
local rigs: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- rebuilt every frame; which rigs somebody actually placed
local placed: { [Model]: boolean } = {}

local function setRigHidden(rig: Model, hidden: boolean)
	if rigs[rig] == hidden then return end
	rigs[rig] = hidden
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d :: BasePart
			p.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

--[[
	Their character, and NOT only `plr.Character`.

	The model lands in Workspace and the Character property is assigned as two
	separate replicated facts, so a remote client genuinely does see one without
	the other -- and during that window the old code could not find a rig it was
	already drawing. The model is named for the player, which is what makes the
	fallback exact rather than a guess.
]]
local function characterOf(plr: Player): Model?
	local ch = plr.Character
	if ch and ch.Parent then return ch end
	local byName = workspace:FindFirstChild(plr.Name)
	return if byName and byName:IsA("Model") then byName :: Model else nil
end

local function pose(plr: Player)
	local ch = characterOf(plr)
	if not ch then return end
	local tool = ch:FindFirstChildOfClass("Tool")
	if not tool then return end

	local kind = tool:GetAttribute("SealerTool") :: string?
	local rig = tool:FindFirstChild("Rig")
	if not rig or not rig:IsA("Model") then return end

	--[[
		FOUND BEFORE IT IS PLACED, and that ordering is the whole fix.

		The rig has to be known to the sweep at the bottom of the frame whether or
		not this call can go on to place it -- a rig that bails out below is exactly
		the one that must be hidden, and the old shape returned before it had ever
		named it.
	]]
	if rigs[rig :: Model] == nil then setRigHidden(rig :: Model, true) end

	--[[
		A DRIVER'S BLADE IS NOT DRAWN, and it has to be said on this side too.

		DrivewayClient hides the LOCAL player's squeegee while they are sat in a rig,
		because a hip-parked blade lies broadside and comes out through both cab walls
		-- see the note over `setSqueegeeHidden` there for why hiding beats re-aiming.
		None of that reaches this file: every other client poses its own copy of that
		same rig, and this loop would go on laying it on the ground in front of the
		truck. So the driver would see a clean cab and everybody watching would see the
		bar through it.

		`SeatPart` is a replicated property, so this is the same question their own
		machine is asking and the two answers cannot drift.

		RETURNING is the whole mechanism: the rig is already registered above and this
		frame never claims it, so the sweep at the bottom hides it -- the same route a
		rig nobody is posing takes. The wand is deliberately NOT covered; it is a hose
		tool worked off the truck and TruckServer stows it on sitting anyway.
	]]
	if kind == "Squeegee" then
		local hum = ch:FindFirstChildOfClass("Humanoid")
		if hum and (hum.SeatPart ~= nil or hum.Sit) then return end
	end

	local hrp = ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local look = flatten(hrp.CFrame.LookVector)

	if kind == "Squeegee" then
		--[[
			Their blade, at THEIR width.

			The rig everybody clones out of StarterPack is built once on the server at
			the module default, 6.4 studs, and the only thing that ever resized one was
			SealerUIClient reaching into the LOCAL player's own tool. So on your screen
			every other player pushed a starter blade whatever they had bought -- and
			the bug hid itself, because it looks right whenever the other player happens
			to be on level 1. Two players at different levels see two different worlds:
			the one with the small blade sees two small blades, the one with the big
			blade sees a big and a small and assumes it is working.

			Cheap enough to do every frame -- setBladeWidth writes only on a change, and
			a level moves about fifteen times in a playthrough.
		]]
		local level = (plr:GetAttribute("Upg_Blade") :: number?) or 1
		ToolBuilder.setBladeWidth(rig, Upgrades.valueAt("Blade", level))

		--[[
			On the ground, found by ray rather than assumed from the root.

			A driveway, a kerb and the depot floor are all at different heights, and
			a blade pinned to a fixed offset under the torso floats over one and
			sinks through the next. Their own character is filtered out or the ray
			lands on their feet.
		]]
		local at = hrp.Position + look * BLADE_FORWARD
		ground.FilterDescendantsInstances = {
			ch, workspace:FindFirstChild("SealerVisuals") :: Instance,
		}
		local hit = workspace:Raycast(at + Vector3.new(0, 5, 0), Vector3.new(0, -12, 0), ground)
		local y = if hit then hit.Position.Y else hrp.Position.Y - 2.6
		local origin = Vector3.new(at.X, y + 0.17, at.Z)
		rig:PivotTo(CFrame.lookAt(origin, origin + look) * CFrame.Angles(math.rad(4), 0, 0))

	elseif kind == "Wand" then
		-- roughly their right hand, the same offset DrivewayClient uses for yours
		local grip = hrp.Position
			+ hrp.CFrame.RightVector * 0.85
			+ hrp.CFrame.LookVector * 0.55
			+ Vector3.new(0, 0.35, 0)
		rig:PivotTo(CFrame.lookAt(grip, grip + look * 8))
	else
		-- Not a kind this file knows how to place -- the pail, which is genuinely
		-- welded and needs nothing. Left unclaimed, so the sweep hides it rather than
		-- leaving it wherever it happens to be.
		return
	end

	placed[rig :: Model] = true
	setRigHidden(rig :: Model, false)
end

--==[ OTHER PEOPLE'S TRUCKS ]=================================================
--[[
	The same problem again, one size up, and this is the one people actually see.

	A rig's beacons, agitator, reel, gauge needle and front blade are ANCHORED and
	re-framed off the chassis every tick -- they cannot be welded, because a weld
	is exactly the thing that stops them turning. RigController does that work, and
	it binds to ONE model: the SealcoatRig stamped with your own UserId.

	So everybody else's rig had nobody driving its moving parts. They stayed frozen
	at the pose they were built in, which is the bay -- and the bay is where they
	stayed while the truck itself drove off down the street. Twelve parts of a
	truck standing in an empty garage, with the truck somewhere else entirely.

	That is the reported bug: "parts of the car show up in the garage even if the
	car isn't there". They were somebody else's.

	Everything below is read off replicated attributes rather than guessed, so a
	watched truck's gauge shows its real tank and its blade is down when its driver
	has put it down. The two we cannot know -- how far their hose is paid out, and
	where their beacons happen to be in the sweep -- do not matter: one is the reel
	at rest, the other is a rotation nobody can tell is out of phase.
]]
local REEL_STOWED = 0
type Watch = {
	base: BasePart?,
	parts: { BasePart },
	--[[
		Everything about the twelve posed pieces that never changes, worked out once
		and kept parallel to `parts`.

		`roles` is the five-way name match the pose loop used to redo from scratch for
		every part of every rig on every frame -- a part's Name does not change, so
		that was sixty answers a second to a question settled when it arrived. `pos`,
		`rot` and `axis` are its RigPos / RigRot / SpinAxis, which TruckBuilder.dynamic
		stamps before it ever parents the part and nothing rewrites. `lamps` is the
		PointLight on a beacon rotor, which a second walk of the same twelve parts
		used to go and find.

		The last four are LAZY: an entry stays nil until the part's three attributes
		are all there and is re-tried on the frames it is not. They replicate with the
		part so this all but always settles on the first look, but a part whose RigRot
		landed a tick late must not be left frozen for good.
	]]
	roles: { number },
	pos: { Vector3? },
	rot: { CFrame? },
	axis: { Vector3? },
	lamps: { PointLight? },
	blade: number,
	hidden: boolean,
	--[[
		The yard rule keeps NO lists. It covers the WHOLE truck, where `parts` above
		is just the twelve posed pieces -- a rig is 182 parts, and hiding a twelfth of
		one would leave a tanker standing in the garage with its blade missing -- and
		holding those 182 here is exactly the trap the note over `rigs` describes: the
		value would keep the parts alive, the parts keep their Parent alive, and the
		weak key could never be collected. So the truck is re-walked on each
		transition instead, which happens twice in its life, and the two facts a walk
		cannot recover afterwards live in weak-keyed side tables next to `adopt`.
	]]
	away: boolean,
}
--[[
	Weak-KEYED, and unlike `rigs` that is not enough on its own: the twelve posed
	parts and the chassis genuinely have to be kept, because they are wanted sixty
	times a second and re-walking 188 descendants for them is the cost this whole
	file exists to avoid. A part keeps its Parent alive, so while the value holds
	one the key cannot collect. The entry is therefore released outright when the
	rig is destroyed -- see the Destroying hook in poseRig -- and the weak key is
	left as the backstop for a rig that goes away without being destroyed.
]]
local watched: { [Model]: Watch } = setmetatable({}, { __mode = "k" }) :: any

local beaconAngle, agitatorAngle = 0, 0

local function isDynamic(d: Instance): boolean
	return d:IsA("BasePart") and d:GetAttribute("RigPos") ~= nil
end

--[[
	WHAT A PIECE IS FOR, DECIDED ONCE.

	The pose loop below used to ask this of every part of every rig on every frame:
	up to five string.find calls to turn a Name into an angle, for parts whose names
	never change. Thirty rigs is fifteen hundred searches a frame for twelve answers
	that were settled the moment the truck replicated.

	The ORDER is load-bearing and is exactly the old if-chain's: Beacon beats
	Agitator beats Reel beats Gauge beats Blade, so a part named for two of them
	keeps the angle it has always had. ROTOR is the subset of Beacon named
	BeaconRotor -- it takes the beacon angle like any other Beacon part and
	additionally owns the lamp, which is why the separate walk that used to go
	looking for it is gone. STILL is a part nothing spins, which is NOT the same as
	no role: it is still placed off the chassis every frame.
]]
local ROLE_STILL = 0
local ROLE_BEACON = 1
local ROLE_ROTOR = 2
local ROLE_AGITATOR = 3
local ROLE_REEL = 4
local ROLE_GAUGE = 5
local ROLE_BLADE = 6

local function roleOf(name: string): number
	if string.find(name, "Beacon") then
		return if string.find(name, "BeaconRotor") then ROLE_ROTOR else ROLE_BEACON
	elseif string.find(name, "Agitator") then return ROLE_AGITATOR
	elseif string.find(name, "Reel") then return ROLE_REEL
	elseif string.find(name, "Gauge") then return ROLE_GAUGE
	elseif string.find(name, "Blade") then return ROLE_BLADE
	end
	return ROLE_STILL
end

--[[
	AND A PIECE NOBODY IS POSING MUST NOT BE DRAWN. That is the other half of the
	same bug, and the half that survives everything.

	Those twelve parts are only ever in the right place because somebody is
	putting them there every frame, and every route by which that stops happening
	ends identically: they stand still, in the world, wherever they last were.
	Since the SERVER's copy of them stays at the bay until the rig moves -- see
	TruckServer.syncDynamics, which is the root fix for this -- "wherever they
	last were" is usually the depot garage. Hence the report this file's own
	header quotes, still arriving after that header was written.

	The routes are not hypothetical. StreamingEnabled can hand this client a
	blade without a chassis, and the loop below cannot pose a rig it has no Base
	for. RigController refuses to bind your OWN rig until Base, Seat, Drives and
	Steers have all arrived, so the same gap exists on the truck this file
	deliberately does not touch.

	So the rule is geometric and owner-blind: a rig piece further than ORPHAN_FAR
	from its own chassis, or with no chassis to measure against at all, is not
	being posed by anybody and is hidden until it is. Nothing legitimate comes
	near the threshold -- measured on a delivered Dart the furthest of the twelve
	is the blade rubber at 12.8 studs -- and a part is re-measured on the same
	frame it is placed, so this cannot hide a working truck.

	LocalTransparencyModifier rather than Transparency: this is one client's
	opinion about a replicated part, and the server's own value has to survive it.
	The beacon lamps go with it, or the garage keeps a pair of floating lights
	after the parts holding them have gone.
]]
local ORPHAN_FAR = 40   -- studs

local function conceal(p: BasePart, hidden: boolean)
	p.LocalTransparencyModifier = if hidden then 1 else 0
	local light = p:FindFirstChildOfClass("PointLight")
	if light then light.Enabled = not hidden end
end

local function setHidden(e: Watch, hidden: boolean)
	if e.hidden == hidden then return end
	e.hidden = hidden
	-- While the yard rule has the whole truck hidden it owns every part, these
	-- twelve included. It re-applies whatever this decided on the way back out, so
	-- the state is remembered rather than lost -- see setAway.
	if e.away then return end
	for _, p in ipairs(e.parts) do conceal(p, hidden) end
end

--==[ SOMEBODY ELSE'S TRUCK, STILL IN THE YARD ]==============================
--[[
	Not yours and not out yet, so as far as this client is concerned it is not
	there. The whole of why is in the note over Config.YardZoneMin; the short of it
	is that the bay is one truck wide, everyone else's rig is delivered on top of
	whoever called it, and the nearest Drive prompt wins -- so the garage hands you
	somebody else's cab and refuses you when you press it.

	Four things have to go, and three of them are not transparency:

	  LocalTransparencyModifier on all 182 parts. This client's opinion about a
	  replicated part, so the server's own Transparency survives it and the
	  fourteen parts that are meant to be invisible stay that way.

	  SurfaceGui.Enabled on the four screens -- the tank livery, the pump panel and
	  the caution sign. A GUI drawn on a part does NOT go with the part's
	  transparency, so leaving these is four billboards floating in an empty bay.

	  MaxActivationDistance on every prompt, NOT Enabled. This is the load-bearing
	  detail: the server writes Enabled on its own schedule -- when the wand is
	  taken, when the reel is wound, and whenever the seat's Occupant changes -- and
	  every one of those replicates and would clobber a client that had set it
	  false. It never touches MaxActivationDistance after the prompt is built, so
	  that one is safe for a client to own.

	  CanCollide on the nine parts that have it -- Base, Hull, Seat and the six
	  wheels. An invisible truck you can walk into is worse than a visible one, and
	  it is the same complaint in a new costume.

	All of it is per-client and all of it is restored on the way out, so nothing
	here can reach the server, another player's screen, or the truck's real state.
]]
local HIDE_YARD = Config.HideYardRigs
local YARD_MIN, YARD_MAX = Config.YardZoneMin, Config.YardZoneMax
local YARD_SLACK = Config.YardZoneSlack

local function inYard(at: Vector3, already: boolean): boolean
	-- The box grows once a rig is already hidden, so a truck parked exactly on the
	-- line cannot strobe. See the note over Config.YardZoneSlack.
	local m = if already then YARD_SLACK else 0
	return at.X >= YARD_MIN.X - m and at.X <= YARD_MAX.X + m
		and at.Y >= YARD_MIN.Y - m and at.Y <= YARD_MAX.Y + m
		and at.Z >= YARD_MIN.Z - m and at.Z <= YARD_MAX.Z + m
end

--[[
	THE TWO FACTS A RE-WALK CANNOT RECOVER, and nothing else is kept.

	The yard rule can find the truck's parts, screens and prompts again whenever it
	likes -- rig:GetDescendants() -- but it cannot find out what they were like
	BEFORE it took them away, because by then it has zeroed and unstuck them itself.
	So exactly two things are remembered, and both per instance rather than in a
	list on the Watch entry: a list of the rig's own instances in the value of a
	weak-keyed table pins the rig and the entry never collects, which is the note
	over `rigs` one size up. A number and a boolean point back at nothing.

	`promptReach` is per prompt because the three on a rig do not share one (Drive
	12, Take Wand 11, Wind In Hose 11) and putting them all back at one number
	would quietly retune the bay.
]]
local promptReach: { [ProximityPrompt]: number } = setmetatable({}, { __mode = "k" }) :: any
local solidAgain: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Recorded the first time the prompt is seen, which is always BEFORE anything
-- here zeroes it: TruckServer never writes MaxActivationDistance after the prompt
-- is built, so whatever it is holding on first sight is its real reach.
local function reachOf(p: ProximityPrompt): number
	local r = promptReach[p]
	if r == nil then
		r = p.MaxActivationDistance
		promptReach[p] = r
	end
	return r
end

--[[
	One instance arriving late, put into whatever state the truck is already in.

	That is now ALL this does -- it used to also build the four lists the yard rule
	walked, and holding them was the leak described on Watch. What is left is the
	same lesson the healed parts list below learned: a rig arrives over many frames,
	so a panel that streams in while the truck is hidden must arrive hidden, or it
	is the one piece left standing in the garage.
]]
local function adopt(e: Watch, d: Instance)
	if not e.away then return end
	if d:IsA("BasePart") then
		conceal(d, true)
		if d.CanCollide then
			solidAgain[d] = true
			d.CanCollide = false
		end
	elseif d:IsA("SurfaceGui") then
		d.Enabled = false
	elseif d:IsA("ProximityPrompt") then
		-- captured BEFORE we zero it, and captured per prompt; see `promptReach`
		reachOf(d)
		d.MaxActivationDistance = 0
	end
end

local function setAway(e: Watch, rig: Model, away: boolean)
	if e.away == away then return end
	e.away = away
	--[[
		Walked here rather than kept in four lists on the entry -- the note over `rigs`
		verbatim, one size up: the lists would keep 182 parts alive, the parts keep the
		rig alive, and the weak key could never collect. One entry leaked per truck
		ever delivered.

		It runs only when the state actually FLIPS, which is twice in a truck's life,
		and it has the better property anyway: a panel that streamed in since the last
		look is covered rather than left standing on its own in the bay.

		Still MaxActivationDistance and NEVER Enabled -- the server owns Enabled and
		would clobber a client that touched it; see the note above.
	]]
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			conceal(d, away)
			if away then
				if d.CanCollide then
					solidAgain[d] = true
					d.CanCollide = false
				end
			elseif solidAgain[d] then
				-- cleared as it is handed back, so a later trip to the yard reads the
				-- truck as it is then rather than as it was on the first one
				solidAgain[d] = nil
				d.CanCollide = true
			end
		elseif d:IsA("SurfaceGui") then
			d.Enabled = not away
		elseif d:IsA("ProximityPrompt") then
			-- read BEFORE the write, or the way out records the zero the way in left
			local reach = reachOf(d)
			d.MaxActivationDistance = if away then 0 else reach
		end
	end
	--[[
		Handing the posed twelve back to the orphan guard.

		It may well want them hidden even though the truck is now out -- a rig that
		drove off while this client was still missing its chassis is exactly that
		case -- and showing the whole truck must not quietly overrule it.
	]]
	if not away and e.hidden then
		for _, p in ipairs(e.parts) do conceal(p, true) end
	end
end

local function checkOrphans(e: Watch)
	local base = e.base
	if not base then setHidden(e, true) return end
	local at = (base :: BasePart).Position
	local far = false
	for _, p in ipairs(e.parts) do
		if (p.Position - at).Magnitude > ORPHAN_FAR then far = true break end
	end
	setHidden(e, far)
end

local function poseRig(rig: Model, dt: number, mine: boolean)
	local e = watched[rig]
	if not e then
		local parts: { BasePart } = {}
		local roles: { number } = {}
		for _, d in ipairs(rig:GetDescendants()) do
			if isDynamic(d) then
				-- the role is worked out HERE and never again; see roleOf
				local n = #parts + 1
				parts[n] = d :: BasePart
				roles[n] = roleOf(d.Name)
			end
		end
		if #parts == 0 then return end
		-- starts parked, like RigController's, so a rig that streams in with its
		-- blade up does not slam it down for one frame
		e = { base = nil, parts = parts, roles = roles,
			pos = {}, rot = {}, axis = {}, lamps = {},
			blade = math.rad(Config.TruckBladeRaise),
			hidden = false, away = false }
		watched[rig] = e

		--[[
			AND THE ENTRY GOES WHEN THE RIG DOES.

			`watched` is weak-keyed, but its value still holds the twelve posed parts and
			the chassis: they are wanted sixty times a second and re-walking 188
			descendants for them is the cost this file exists to avoid. A part keeps its
			Parent alive, so the key can never collect on its own -- one entry leaked per
			truck ever delivered. Dropping it outright is one connection per rig and
			NOTHING per frame, which is the same trade the healing list below makes.
		]]
		rig.Destroying:Connect(function()
			watched[rig] = nil
		end)

		--[[
			THE LIST HEALS. It used to be a snapshot, and that was the bug.

			A rig is 180-odd direct children and does not arrive in one piece. The
			scan above runs on the first Heartbeat that sees any ONE tagged part --
			and the blade is child #12 while the beacons are #49, the agitator #70,
			the gauge #89 and the reel #94. So "any one" is routinely the blade with
			everything behind it still in flight, and a list captured at that instant
			is missing most of the truck.

			Those parts are ANCHORED, and nobody else re-frames somebody else's rig.
			Left out of this list they do not lag or trail -- they never move again.
			They stand in the bay at the pose they were built in while the truck
			drives off, which is the "parts falling off the upgraded trucks" report:
			an upgraded rig is one that spawns MID-SESSION, when every client is
			already ticking Heartbeat at 60fps and is certain to look mid-stream.
			The rig you join with is usually finished replicating before you load.

			Appending on DescendantAdded costs one connection per rig and NOTHING
			per frame. Re-scanning to stay honest would be 180 GetDescendants per
			rig per frame, which is the trade this whole file exists to avoid.
		]]
		rig.DescendantAdded:Connect(function(d)
			-- re-read rather than closing over `e`: a rebind above swaps the entry,
			-- and appending to the dead one would silently do nothing
			local w = watched[rig]
			if not w then return end
			if isDynamic(d) then
				local p = d :: BasePart
				-- ONCE. A part reparented inside the rig fires this again for something
				-- already on the list, and a doubled entry is a piece posed, lit and
				-- measured twice a frame for the rest of the session.
				if not table.find(w.parts, p) then
					local n = #w.parts + 1
					w.parts[n] = p
					w.roles[n] = roleOf(p.Name)
					-- a piece that arrives while the rig is orphaned joins it in hiding,
					-- or it is the one part left standing in the bay. Skipped while the
					-- yard rule holds the truck, which adopt below covers instead.
					if w.hidden and not w.away then conceal(p, true) end
				end
			end
			-- and the yard rule, which takes parts, screens and prompts alike -- it keeps
			-- no lists now, so this is only about the state a latecomer arrives in. The
			-- prompts in particular only ever arrive this way: TruckServer builds them in
			-- spawnRig, after TruckBuilder has finished and replicated.
			adopt(w, d)
		end)
	end

	--[[
		The chassis is looked up lazily rather than captured, and the parts list is
		NOT thrown away when it goes.

		This used to rebuild the whole entry the moment `base.Parent` went nil,
		which under streaming is the moment the truck moved away -- so the healed
		list below was discarded exactly when the rig was hardest to see, and
		rebuilt from whatever happened to be resident. FindFirstChild on the frames
		where there is no Base costs nothing next to a GetDescendants that finds
		twelve parts in 188.
	]]
	local base = e.base
	if not base or not (base :: BasePart).Parent then
		base = rig:FindFirstChild("Base") :: BasePart?
		e.base = base
	end

	--[[
		The yard rule, and it runs BEFORE the no-chassis bail below on purpose: a rig
		that has streamed in without its Base yet is exactly the one that must not be
		left standing visible in the garage.

		Ownership is re-read here rather than taken from `mine`, and it is gated on
		the attribute actually being THERE. `mine` is false for an unknown owner,
		which is the right answer for posing -- somebody has to place it -- and the
		wrong one here: OwnerUserId is stamped in spawnRig and arrives with the model
		rather than before it, so trusting it while nil would blink your own truck out
		of its own bay for the frames before it lands.

		GetPivot only when there is no chassis to ask. It walks the model for a
		bounding box when there is no PrimaryPart, and that is 485 descendants a frame
		if it is left in the common path.
	]]
	if HIDE_YARD then
		local owner = rig:GetAttribute("OwnerUserId") :: number?
		if owner ~= nil and owner ~= player.UserId then
			local at = if base then (base :: BasePart).Position else rig:GetPivot().Position
			setAway(e, rig, inYard(at, e.away))
		elseif e.away then
			setAway(e, rig, false)
		end
	end

	if not base then setHidden(e, true) return end

	--[[
		Your own rig is RigController's to place and two writers would fight, so all
		this file does for it is notice when NOBODY is placing it. See ORPHAN_FAR.
	]]
	if mine then checkOrphans(e) return end

	local down = rig:GetAttribute("BladeDown") == true
	local want = if down then 0 else math.rad(Config.TruckBladeRaise)
	e.blade += (want - e.blade) * (1 - math.exp(-Config.TruckBladeEase * dt))

	local tank = (rig:GetAttribute("Tank") :: number?) or 0
	local cap = (rig:GetAttribute("TankCapacity") :: number?) or 1
	local needle = math.rad(-125 + 250 * math.clamp(tank / math.max(cap, 1), 0, 1))

	local baseCF = (base :: BasePart).CFrame
	local at = baseCF.Position
	-- the lamp brightening as the mirror comes round is most of what sells a
	-- rotating beacon; matched to RigController so two trucks look like one fleet
	local glow = 0.8 + 2.6 * math.abs(math.sin(beaconAngle))

	--[[
		ONE walk of the twelve where there used to be three.

		The pose, the beacon lamps and the orphan measurement all wanted the same list
		and each took its own lap of it. Sharing the pass changes nothing about the
		order that matters: a part is still measured AFTER its own CFrame is written --
		from the CFrame just written, so the position need not be read back off the
		engine -- which is the rule the note over ORPHAN_FAR sets out and is what stops
		a truck blinking out of its first frame. A part's distance depends only on
		itself and the chassis, so measuring it before its neighbours are placed is the
		same answer as measuring it after.
	]]
	local far = false
	for i, p in ipairs(e.parts) do
		local pos, rot, axis = e.pos[i], e.rot[i], e.axis[i]
		if pos == nil or rot == nil or axis == nil then
			-- all three are stamped before TruckBuilder.dynamic parents the part, so this
			-- settles on the first look; re-tried rather than given up on, because a part
			-- whose RigRot somehow landed a tick late must not stay frozen for the session
			pos = p:GetAttribute("RigPos") :: Vector3?
			rot = p:GetAttribute("RigRot") :: CFrame?
			axis = p:GetAttribute("SpinAxis") :: Vector3?
			if pos and rot and axis then
				e.pos[i], e.rot[i], e.axis[i] = pos, rot, axis
			end
		end

		local role = e.roles[i]
		if pos and rot and axis then
			local angle = 0
			if role == ROLE_BEACON or role == ROLE_ROTOR then angle = beaconAngle
			elseif role == ROLE_AGITATOR then angle = agitatorAngle
			elseif role == ROLE_REEL then angle = REEL_STOWED
			elseif role == ROLE_GAUGE then angle = needle
			elseif role == ROLE_BLADE then angle = e.blade
			end
			local cf = baseCF * CFrame.new(pos) * CFrame.fromAxisAngle(axis, angle) * rot
			p.CFrame = cf
			if not far and (cf.Position - at).Magnitude > ORPHAN_FAR then far = true end
		elseif not far and (p.Position - at).Magnitude > ORPHAN_FAR then
			far = true
		end

		if role == ROLE_ROTOR then
			-- found once and kept, but re-tried while it is missing: a lamp can stream in
			-- after the rotor it hangs on, and a cached nil would leave that beacon dark
			-- for the life of the rig
			local light = e.lamps[i]
			if light == nil then
				light = p:FindFirstChildOfClass("PointLight") :: PointLight?
				e.lamps[i] = light
			end
			if light then light.Brightness = glow end
		end
	end
	setHidden(e, far)
end

--==[ AND YOUR OWN, WHEN YOU ARE DRIVING ]====================================
--[[
	A BLADE IN A CAB IS NOT DRAWN AT ALL.

	Reported 2026-08-14 with a picture: a bar through both cab walls at window
	height, a couple of studs out either side of the truck. DrivewayClient parks a
	seated player's rig on their hip, and it pivots to `hrp.CFrame * CFrame.new(..)`
	-- which carries the CHARACTER's orientation. A squeegee's blade runs across its
	pole, so hip-parked and square to the body puts the rubber BROADSIDE, straight
	out through the doors.

	⚠ RE-AIMING IT IS NOT A FIX. Blade width is an upgrade TRACK, so whatever angle
	is picked, some level buys a blade long enough to come back out through the cab.
	Fore-and-aft is worse, not better: the cab is shorter that way than it is wide.
	Hiding it is the only answer that holds at every level, and it costs nothing --
	TruckServer stows the wand when you sit and the pail was taken off the cab for
	the same reason. You are not meant to be working from the driving seat.

	WHY HERE AND NOT IN DrivewayClient, which owns your rig everywhere else: that
	file's main chunk is at Luau's hard limit of 200 local registers, so adding a
	function to it stops the script compiling and silently kills the whole sealing
	simulation. Nothing is fought over by putting it here -- DrivewayClient places
	the rig and never touches its transparency, and transparency is this file's job
	for every other rig in the game.

	CLAIMED IN `placed` on every frame it is looked at, hidden or not. `setRigHidden`
	puts it in `rigs`, and the sweep below hides anything in `rigs` that nobody
	claimed -- so without the claim this would hide your own blade permanently, the
	moment you first equipped it.
]]
local function ownBlade()
	local ch = player.Character
	local tool = ch and ch:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute("SealerTool") ~= "Squeegee" then return end
	local rig = tool:FindFirstChild("Rig")
	if not rig or not rig:IsA("Model") then return end
	local hum = (ch :: Model):FindFirstChildOfClass("Humanoid")
	setRigHidden(rig :: Model, hum ~= nil and ((hum :: Humanoid).SeatPart ~= nil or (hum :: Humanoid).Sit))
	placed[rig :: Model] = true
end

RunService.Heartbeat:Connect(function(dt)
	table.clear(placed)
	for _, plr in ipairs(Players:GetPlayers()) do
		-- never your own: DrivewayClient owns that one and two writers would fight
		if plr ~= player then pose(plr) end
	end
	-- your own is posed by DrivewayClient, but its transparency is this file's
	ownBlade()

	--[[
		And anything still on screen that nobody claimed. See the note over `rigs`.

		The table is weak-keyed, so a rig whose tool has been destroyed drops out on
		its own; `rig.Parent` covers the commoner case of a tool that has merely gone
		back to a Backpack this client cannot see, where the parts are not being
		drawn and there is nothing to hide.
	]]
	for rig in pairs(rigs) do
		if rig.Parent and not placed[rig] then setRigHidden(rig, true) end
	end

	beaconAngle = (beaconAngle + dt * 7.5) % (math.pi * 2)
	agitatorAngle = (agitatorAngle + Config.AgitatorRPM * math.pi / 30 * dt) % (math.pi * 2)
	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name == "SealcoatRig" and m:IsA("Model") then
			-- RigController already drives your own, and only your own -- but the
			-- orphan check inside covers every rig, yours included
			poseRig(m, dt, m:GetAttribute("OwnerUserId") == player.UserId)
		end
	end
end)
