--!strict
--[[
	AfkService -- who is in the yard, and paying them for it.

	The yard is an income system, not a sealing one. The picture the player
	watches -- their own character walking lanes and the drive going black behind
	it -- is AfkClient's business and runs entirely on their machine. None of it
	reaches this file, and that is the point: the money here is a rate against
	wall-clock time, so a client that stalls, drops to two frames a second or
	never builds its surface at all still earns exactly what it should, and a
	client that lies about what it has sealed earns exactly the same.

	See Afk for why this cannot go through DrivewayServer's payout instead. The
	short version is that every slab in the game pays once per rebirth, so an AFK
	driveway on that path would pay once and then be scenery.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Afk = require(Pack:WaitForChild("Afk"))
local AfkYardBuilder = require(Pack:WaitForChild("AfkYardBuilder"))
-- How anything that teleports a player somewhere ELSE tells the yard to let go
-- of them. Registered at the foot of this file; see the header there.
local AfkBus = require(game.ServerScriptService.AfkBus)
-- What a visit is worth is a lump sum handed over all at once, which is one of
-- the two moments in the game the second helping is sold at -- see the offer in
-- leave() below, and DoubleUpService for the rules it goes through.
local DoubleUpService = require(game.ServerScriptService.DoubleUpService)

local Remotes = Pack:WaitForChild("Remotes")

--==[ THE WORLD ]=============================================================

--[[
	Built if it is missing, the same contract DealershipBuilder and
	RetailParkBuilder have with their districts. The geometry is normally baked
	into the place, so this only fires on a place that has lost it -- but a door
	that opens onto empty space is a worse failure than a slightly slower startup.
]]
local yard = workspace:FindFirstChild(Afk.Container)
if not yard then
	yard = AfkYardBuilder.build(CFrame.new(Afk.Origin), workspace)
end

--[[
	The HUD key is gone (2026-08-14, owner's call), and the door is a place again.

	From 2026-08-08 going idle was a rail button and only a rail button. What that
	bought was reach -- the map is a 2,500-stud straight line and nobody walks back
	to go idle -- and what it cost was that the yard had no address: a thumb's
	width from Settings and Shop, on a screen edge, described by one word.

	It is a room by the spawn now. See THE DOOR IN, at the foot of this file, for
	where it is put and why walking into it is allowed to be the whole decision.
]]

local control = Remotes:FindFirstChild("AfkControl")
if not control then
	local made = Instance.new("RemoteEvent")
	made.Name = "AfkControl"
	made.Parent = Remotes
	control = made
end
local Control = control :: RemoteEvent

--==[ WHERE A PLAYER GOES BACK TO ]===========================================

--[[
	The fallback, for a return point that cannot be honoured.

	A saved CFrame is normally wherever the player was standing when they pressed
	the button, which is the only answer that does not feel like a punishment for
	going idle. It stops being usable in two cases: a player who was already in
	the yard somehow (so sending them "back" leaves them in it forever), and a
	stored spot from a previous session. Both land on the spawn instead.
]]
-- Two readers: the fallback below, and the arena, which is placed in this part's
-- own frame rather than on a coordinate. One lookup so they cannot disagree
-- about which pad is the spawn on a place that has grown a second one.
local function spawnPart(): SpawnLocation?
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("SpawnLocation") then return d end
	end
	return nil
end

local function spawnCFrame(): CFrame
	local sp = spawnPart()
	return if sp then sp.CFrame + Vector3.new(0, 4, 0) else CFrame.new(0, 10, 0)
end

-- Anything this close to the yard is IN the yard. The street is about 900 studs
-- end to end and 460 wide, so 1,200 covers it with room and still cannot reach
-- anything on the real map six thousand studs away.
local YARD_RADIUS = 1200

local function inYard(p: Vector3): boolean
	return (p - Afk.Origin).Magnitude < YARD_RADIUS
end

--==[ WHO IS IN IT ]==========================================================

type Visit = {
	plot: number,
	ret: CFrame,
	-- Fractional cash carried between ticks. Cash is an IntValue and the rate is
	-- a rebirth curve, so nearly every tick pays a fraction; floor it away each
	-- second and a player at 10.6 a second is quietly paid 10.
	owed: number,
	-- Rate-limits the enter/leave remote. Cheap, because there is nothing to gain
	-- from spamming it, but a remote that teleports a character is not one to
	-- leave uncapped.
	last: number,
}

local visits: { [Player]: Visit } = {}
local occupant: { [number]: Player? } = {}
local rota = 0

--[[
	A free plot, or the next one round if the yard is full.

	Doubling up rather than refusing at the door: a ninth idler standing in
	somebody else's driveway is a far smaller insult than a button that says no,
	and both puppets drive their own client's own grid, so neither one's work
	disturbs the other's picture. All they share is the ground they stand on.
]]
local function allocate(): number
	for i = 1, Afk.PlotCount do
		if not occupant[i] then return i end
	end
	rota = (rota % Afk.PlotCount) + 1
	return rota
end

--[[
	Hand back every plot this player holds, not just the one their visit names.

	By player rather than by index because the index is a record of an allocation
	and the allocation is the thing that can go wrong -- and a plot marked occupied
	by somebody who is not standing in it is invisible until the yard is full,
	at which point allocate() falls through to the rota and starts putting two
	people in one driveway. This makes that state unable to survive a visit ending.
]]
local function releasePlots(plr: Player)
	for i = 1, Afk.PlotCount do
		if occupant[i] == plr then occupant[i] = nil end
	end
end

local function partsOf(plr: Player): (Model?, Humanoid?, BasePart?)
	local char = plr.Character
	if not char then return nil, nil, nil end
	return char,
		char:FindFirstChildOfClass("Humanoid"),
		char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--==[ IN AND OUT ]============================================================

--[[
	The spot a visit ends at, which is not always the one it recorded.

	v.ret is where the player was standing when they pressed the button. It stops
	being usable in the two cases the fallback covers -- a player who was somehow
	already in the yard (so "back" would leave them in it forever) and a spot kept
	from a previous session -- and both land on the spawn instead.

	Pulled out of leave() because it now has two readers: the teleport below, and
	AfkBus, which hands the same answer to whoever is moving the player instead.
	One function, so a caller that only wants the ANSWER cannot get a different
	one from the caller that acts on it.
]]
local function homeOf(v: Visit): CFrame
	return if inYard(v.ret.Position) then spawnCFrame() else v.ret
end

--[[
	Answers where the visit sent them home to, or nil if there was no visit --
	which is what AfkBus passes on. Every existing caller ignores it.

	`returning` is whether the player is COMING BACK, which is not the same
	question as sendBack and is why it is a second flag rather than the same one.
	Dying in the yard passes sendBack false -- the respawn has already put them
	somewhere valid -- and is still a player arriving back on the map with a visit's
	earnings in their pocket. The battle passing through AfkBus is the opposite:
	sendBack is false there too, and they are not coming back, they are being
	teleported the other way into a match. Offering them a purchase on the ride in
	would land a card over a count-in, and the arena pays out sixty seconds later
	with an offer of its own.
]]
local function leave(plr: Player, sendBack: boolean, returning: boolean?): CFrame?
	local v = visits[plr]
	if not v then return nil end
	visits[plr] = nil
	releasePlots(plr)

	-- Read before the clear below, because the clear is what destroys it: the
	-- attribute IS the running total for this visit and nothing else keeps one.
	local earned = (plr:GetAttribute(Afk.EarnedAttr) :: number?) or 0

	--[[
		The attribute is cleared BEFORE the character moves, and the order matters.

		AfkClient hangs everything off this one value -- the puppet, the surface,
		the readout, and the controls it took away. Teleporting first would put the
		character back on Maple Drive with the puppet still driving it for however
		many frames the attribute change takes to replicate, which reads as the
		game walking off with the player's character.
	]]
	plr:SetAttribute(Afk.Attr, nil)
	plr:SetAttribute(Afk.EarnedAttr, nil)

	local back = homeOf(v)
	local char, _, hrp = partsOf(plr)
	if sendBack and char and hrp then
		char:PivotTo(back)
	end

	--[[
		Asked AFTER the character has been put back, not before.

		The card is drawn on the player's own machine off this fire, so a fire on the
		far side of the teleport is a card that is already up while they are still
		standing in the yard for a frame -- an offer about a visit, over the visit.

		It is only ever an OFFER: the money for the visit has already been paid, by
		the second, for as long as they stood there. Whether anything comes of this is
		DoubleUpService's business, and most visits are too small to be asked about
		at all.
	]]
	if returning then
		DoubleUpService.offer(plr, earned, "afk")
	end
	return back
end

--[[
	`home` is where the visit will END, and it is passed in rather than assumed.

	The default -- wherever the player was standing when they set off -- is the
	only answer that does not punish going idle, and it was right while the door
	was a button pressed from anywhere on the map. It is exactly wrong for a door
	you WALK INTO: it would put the player back on the trigger they just stood on,
	which re-enters them, which is a visit nobody can end.

	So the arena hands over its own step instead. See armArena at the foot of the
	file; the fallback stays for any door that is not standing on its own switch.
]]
local function enter(plr: Player, home: CFrame?)
	if visits[plr] then return end

	--[[
		AND NOT OUT OF A SQUEEGEE BATTLE.

		These three guards are older than the walk-in door and read as belt and
		braces against it: a player held by any of the events below is thousands of
		studs from the depot lawn and cannot stand on the trigger to begin with.

		They are kept, and not because a guard is free. What they defend is `enter`,
		not the door -- the mirror of the bug AfkBus exists to fix. Honouring a call
		here would teleport a participant out of a scored match into the yard and hand
		their character to the puppet, and the match would teleport them back at the
		buzzer regardless: two systems moving one character between them. The next
		door to be added does not get to rediscover that.

		The attribute is SqueegeeBattleServer's, set for exactly as long as a player
		is in the battle arena and cleared by its restore -- the same switch
		DrivewayClient reads to keep off their walk speed in there.

		Silent, because there is nothing to explain: the door opens again the moment
		the match lets go of them, sixty seconds at the outside.
	]]
	--[[
		AND NOT OUT OF A DRIVEWAY RACE, for exactly the same reason.

		A separate attribute rather than the battle's, because the two events want
		OPPOSITE things everywhere else the battle's is read: `BattleArena` also tells
		DrivewayClient and AfkClient to keep off the player's walk speed, and a race
		deliberately runs everybody at their own bought pace -- the lane is sized to it.
		Setting the battle's switch here would hand every racer the last speed the
		humanoid happened to be wearing for the whole event.

		Set by DrivewayRaceServer.placeOnLane and cleared by its restore.
	]]
	if plr:GetAttribute("BattleArena") ~= nil then return end
	if plr:GetAttribute("DrivewayRace") ~= nil then return end
	--[[
		AND NOT OUT OF A DUEL, which is the third thing that can be holding a
		character a long way from the map.

		A third attribute rather than reusing either of the two above, for the reason
		the race needed its own: `BattleArena` also tells DrivewayClient and AfkClient
		to keep off the player's walk speed, and a duel deliberately leaves every part
		of both players' kit alone -- they chose each other, so there is nothing to
		handicap. Setting the battle's switch here would freeze both duellists at
		whatever speed the humanoid happened to be wearing.

		Set by DuelServer.markIn and cleared by its restore. It carries the mode id
		rather than a boolean, so anything that wants to know WHICH duel can ask.
	]]
	if plr:GetAttribute("Duel") ~= nil then return end

	local char, hum, hrp = partsOf(plr)
	if not char or not hum or not hrp then return end
	if hum.Health <= 0 then return end

	--[[
		Stand them out of the rig first.

		PivotTo on a seated character fights the seat weld and can leave the driver
		welded to a truck that is now six thousand studs away, which strands the
		rig rather than the player. Refusing outright was the alternative and it is
		worse: "park first" is a rule the player has to learn by being told no.
	]]
	--[[
		The plot is claimed HERE, before anything below can yield.

		`visits[plr]` at the top of this function is the guard against entering
		twice, and it used to be written after the seat unwind -- which yields for
		200 ms. A second "enter" arriving inside that window passed the guard,
		found itself already out of the seat so took no yield of its own, and
		allocated a plot; the first call then woke up, allocated a SECOND plot and
		overwrote the visit record with it. The first plot was left marked occupied
		with no visit pointing at it, and nothing ever handed it back -- not leaving,
		not dying, not disconnecting.

		Ghosts like that are silent until the eighth one, and then allocate() runs
		out of free plots and the rota starts handing out driveways that are already
		being stood in. Two idlers in one house is what that looks like from the
		outside. A trigger that fires every frame a foot is on it is one stride away
		from producing it.

		ret is taken before the unseat rather than after, which is also the better
		answer: it is where the player actually was when they set off.
	]]
	local i = allocate()
	occupant[i] = plr
	visits[plr] = {
		plot = i,
		ret = home or hrp.CFrame,
		owed = 0,
		last = os.clock(),
	}

	if hum.SeatPart then
		hum.Sit = false
		task.wait(0.2)
		char, hum, hrp = partsOf(plr)
		if not char or not hum or not hrp then
			releasePlots(plr)
			visits[plr] = nil
			return
		end
	end

	local stand = Afk.standCFrame(i)

	--[[
		Ask this client for the ground BEFORE putting them on it.

		The yard sits ~5,900 studs off the rest of the map, so with streaming on it
		simply does not exist on the player's client until their region catches up --
		and the first thing AfkClient does on arrival is look its own slab up by name.
		Without this the attribute beat the geometry there and the client bailed with
		"no slab for plot N", which is a visit where the crew stands still and earns
		nothing. It is a plot of 1,171 parts; it does not arrive inside a frame.

		Yields, so it has to happen before the move and before the attribute. Wrapped,
		and a failure is not fatal: AfkClient waits for its slab as well, and this is
		only what makes that wait normally cost nothing.
	]]
	pcall(function()
		plr:RequestStreamAroundAsync(stand.Position, 10)
	end)

	--[[
		Move first, THEN say they have arrived -- the mirror of the order in leave().

		Setting the attribute first would start AfkClient's puppet walking lanes on
		whatever driveway the player happened to be standing on back on the real
		map, for the frame or two before the teleport lands.

		Re-checked after the yield above: a player can leave, die or be sent home while
		a stream request is in flight, and teleporting a character that is no longer
		theirs to move is how somebody ends up in the yard with no visit recorded.
	]]
	if visits[plr] ~= nil and plr.Character == char and hum.Health > 0 then
		char:PivotTo(stand)
		plr:SetAttribute(Afk.EarnedAttr, 0)
		plr:SetAttribute(Afk.Attr, i)
	else
		-- unwind the allocation, or the plot stays reserved for nobody
		releasePlots(plr)
		visits[plr] = nil
	end
end

--==[ THE MONEY ]=============================================================

local function statsOf(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash")
	return (cash and cash:IsA("IntValue")) and cash or nil
end

local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < Afk.TickSeconds then return end
	local elapsed = accum
	accum = 0

	for plr, v in pairs(visits) do
		local _, hum, hrp = partsOf(plr)

		--[[
			Paid for being THERE, not for having pressed the button.

			The position check is the whole anti-abuse story for this area, and it is
			deliberately the only one: a player cannot leave the yard except through
			leave(), which clears the visit -- so if a character is drawing this rate
			while standing somewhere else, something has gone wrong and the honest
			response is to stop paying rather than to guess.
		]]
		if hrp and hum and hum.Health > 0 and inYard(hrp.Position) then
			local gross = Afk.rateFor(plr) * elapsed + v.owed
			local pay = math.floor(gross)
			v.owed = gross - pay
			if pay > 0 then
				local cash = statsOf(plr)
				if cash then cash.Value += pay end
				--[[
					Q_Earned but NOT Q_Sealed, and the split is the honest one: the quest
					board counts money earned and driveways finished as two different
					things, and the yard genuinely produces the first and genuinely does
					not produce the second. Crediting driveways here would let a player
					clear a three-hundred-driveway quest without sealing one.
				]]
				plr:SetAttribute("Q_Earned",
					((plr:GetAttribute("Q_Earned") :: number?) or 0) + pay)
				plr:SetAttribute(Afk.EarnedAttr,
					((plr:GetAttribute(Afk.EarnedAttr) :: number?) or 0) + pay)
			end
		end
	end
end)

--==[ THE DOORS ]=============================================================

--[[
	The leave prompts are handled here rather than on the client.

	There is nothing to protect about leaving -- it only ever affects the player
	who pressed it -- but the handler MOVES A CHARACTER, and Triggered fires on
	the server with the player who actually held the key down, which needs no
	trust at all. The enter prompt used to live here too, for the same reason;
	see the note at the top of the file for where that door went.
]]
local function bindPrompts()
	-- Only the way OUT is a prompt now; the way in is the HUD rail button.
	local plots = yard and yard:FindFirstChild("Plots")
	if not plots then return end
	for _, m in ipairs(plots:GetChildren()) do
		local leavePad = m:FindFirstChild("LeavePad")
		local p = leavePad and leavePad:FindFirstChildOfClass("ProximityPrompt")
		if p then
			--[[
				Any plot's sign gets you out, not just your own.

				The alternative is a prompt that refuses a player standing in front of
				it because the driveway belongs to somebody else, which is a puzzle
				rather than a door. There is nothing to protect: leaving only ever
				affects the player who pressed it.
			]]
			p.Triggered:Connect(function(plr) leave(plr, true, true) end)
		end
	end
end
bindPrompts()

--==[ THE WAY OUT ]===========================================================

--[[
	The yard card's "Back to work" chip, and now the only thing this remote carries.

	"enter" went with the rail key. The way in is a room the server watches people
	walk into, so there is nothing left for a client to ask for -- and a remote that
	teleports a character on request is not one to leave standing with no button
	behind it. Anything arriving on it now is ignored unless the sender is actually
	in the yard, which is the one case that has something to undo.
]]
Control.OnServerEvent:Connect(function(plr, action)
	local v = visits[plr]
	if not v then return end
	local now = os.clock()
	if now - v.last < 0.75 then return end
	v.last = now

	if action == "leave" then leave(plr, true, true) end
end)

--==[ THE DOOR IN ]===========================================================

--[[
	The arena by the spawn. AfkYardBuilder draws it; this finds it and decides what
	happens to whoever walks in.

	SAVED INTO THE PLACE AND MOVED BY HAND, the same contract the yard, the
	dealership and the retail park all have: whatever is standing in Workspace is
	the authority, and the builder is only the fallback for a place that has lost
	it. Drag it, turn it, rebuild it from the command bar -- nothing here reads a
	baked coordinate back. armArena takes the exit spot off the model's own Step
	part, so the door and the way home cannot end up in two different places.

	The first build has to seat it somewhere, and that is the only thing the two
	constants below are for. Once it is saved they are never read again.

	To re-seat or re-draw it after editing AfkYardBuilder, from the command bar:

		local M = require(game.ReplicatedStorage.DrivewaySealer.AfkYardBuilder)
		local old = workspace:FindFirstChild(M.ArenaName)
		local at = old and old:GetPivot()
		if old then old:Destroy() end
		M.buildArena(at or CFrame.new(52, 0, 197), workspace)

	The pivot is the survey origin the model was built at -- buildArena sets
	WorldPivot for exactly this -- so a re-draw lands where the old one stood
	rather than back by the spawn.
]]

local ARENA_BACK = 21   -- studs behind the pad: clear of it, and unmissable
local ARENA_SIDE = -4   -- and a shade to its left, off the walk out to the lots

local function findArena(): Model?
	-- The prompt pad from before 2026-08-08, if a place file still carries one.
	-- Purged for the same reason DrivewayServer purges the old field drum: a second
	-- door standing in the courtyard is a door nobody maintains.
	local stale = workspace:FindFirstChild("AfkEntry")
	if stale then stale:Destroy() end

	local found = workspace:FindFirstChild(AfkYardBuilder.ArenaName)
	if found and found:IsA("Model") then return found end

	local sp = spawnPart()
	if not sp then
		warn("[Afk] no arena in Workspace and no SpawnLocation to seat one against;"
			.. " the yard has no door")
		return nil
	end

	--[[
		Seated in the PAD'S OWN FRAME, not on a survey coordinate.

		+Z is behind a SpawnLocation -- a character lands facing its LookVector,
		which is -Z -- so this puts the arena at the player's back with its door
		turned to face them, and they meet it by turning round.

		The HEIGHT is the ground under it rather than the pad's, because the pad is
		sunk halfway into its own apron and a room built on its top surface floats.
	]]
	local seat = sp.CFrame * CFrame.new(ARENA_SIDE, 0, ARENA_BACK)
	local hit = workspace:Raycast(seat.Position + Vector3.new(0, 80, 0),
		Vector3.new(0, -160, 0), RaycastParams.new())
	local ground = if hit then hit.Position.Y else sp.Position.Y + sp.Size.Y * 0.5

	warn("[Afk] no arena in the place; building one by the spawn")
	return AfkYardBuilder.buildArena(
		CFrame.new(seat.Position.X, ground, seat.Position.Z)
			* (sp.CFrame - sp.CFrame.Position),
		workspace)
end

--[[
	Walking in IS the choice, so there is nothing to confirm.

	The rail key asked first, and it had to: it sat a thumb's width from Settings
	and Shop and a misfire cost the player the walk back and whatever pass they
	were in the middle of. Neither half of that is true here. Getting onto the
	trigger means walking through a doorway with the answer written over it, and
	leaving puts them back on the step they came in by -- so the cost of a mistake
	is the two seconds it takes to notice.
]]

-- One entry per player per few seconds. Touched fires every frame a foot is on
-- the disc, and the stamp is taken BEFORE enter() rather than after, so a player
-- the guards inside it turn away -- mid-match, mid-race, mid-duel -- is throttled
-- just the same instead of re-asking sixty times a second.
local ENTER_REARM = 3
local lastEntry: { [Player]: number } = {}

local function armArena(arena: Model)
	local trigger = arena:FindFirstChild("Enter")
	local step = arena:FindFirstChild("Step")
	if not (trigger and trigger:IsA("BasePart") and step and step:IsA("BasePart")) then
		warn("[Afk] the arena is missing its trigger or its step")
		return
	end

	--[[
		Where a visit that started here ENDS, read off the step rather than worked
		out from the room's radius: the arch can be moved in the builder without the
		exit landing somewhere else.

		It has to be OUTSIDE the trigger, and that is not a nicety -- see the note
		over enter(). The step's own rotation is the arena's, whose -Z faces the
		spawn, so the player is set down looking back the way they came in.
	]]
	local home = step.CFrame + Vector3.new(0, 3.5, 0)

	trigger.Touched:Connect(function(hit: BasePart)
		-- a limb's parent is the character; a hat's is an Accessory inside it
		local char = hit:FindFirstAncestorOfClass("Model")
		local plr = char and Players:GetPlayerFromCharacter(char :: Model)
		if not plr then return end
		if visits[plr] then return end

		local now = os.clock()
		if now - (lastEntry[plr] or 0) < ENTER_REARM then return end
		lastEntry[plr] = now

		enter(plr, home)
	end)
end

local arena = findArena()
if arena then armArena(arena) end

--==[ TAKEN AWAY BY SOMETHING ELSE ]==========================================

--[[
	The one way out of the yard that is not the player choosing it.

	A player can opt into the Squeegee Battle from in here -- the invitation is a
	card, and a card takes a click, which is the one input a visit does not sink.
	The match then teleports them to the arena, and everything about this visit
	that is not the attribute would otherwise still be running when they land:
	the plot held, the wall-clock payout ticking (against a position check it now
	fails), and, six thousand studs away on their own machine, the puppet walking
	them back toward a driveway and the sink swallowing their keys.

	sendBack is FALSE and that is the whole reason this is not just leave(): the
	caller is moving the character itself, and two teleports racing for one
	character is how somebody arrives in the arena and is immediately pulled out
	of it. What the caller gets instead is the CFrame this would have used, to put
	them back on when the match is over.

	Registered here rather than reached into from the battle, so the yard's rules
	-- claim, release, pay, where home is -- stay in the one file that owns them.
]]
AfkBus.provide(function(plr: Player): CFrame?
	-- Not `returning`: they are being taken to the arena, not brought home. See
	-- the note over leave for why that is a separate question from sendBack.
	return leave(plr, false, false)
end)

--==[ HOUSEKEEPING ]==========================================================

--[[
	A new character is a visit over.

	Dying respawns the player at the depot, so the visit is already finished in
	every way that matters -- the state left behind would keep paying a character
	standing on Maple Drive, and the stale plot would be held against the next
	person to arrive. sendBack is false because the respawn has already put them
	somewhere valid; teleporting them again would drag them off the spawn pad.
]]
local function watch(plr: Player)
	plr.CharacterAdded:Connect(function()
		-- Returning, despite sendBack being false: the respawn has already put them
		-- back on the map, and what they earned standing in the yard is theirs.
		leave(plr, false, true)
	end)
end

Players.PlayerAdded:Connect(watch)
for _, plr in ipairs(Players:GetPlayers()) do watch(plr) end

Players.PlayerRemoving:Connect(function(plr)
	releasePlots(plr)
	visits[plr] = nil
	-- the door's re-arm stamp, which is keyed by the player object and would
	-- otherwise hold one alive for as long as the server runs
	lastEntry[plr] = nil
end)
