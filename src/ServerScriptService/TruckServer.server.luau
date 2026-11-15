--!strict
--[[
	TruckServer.

	Owns the one thing about the rig that has to be shared: its state. The tank
	level, whether the PTO is engaged, and who is holding the wand all live here
	as attributes on the model, because two players working the same truck have
	to agree on them.

	Everything else about the truck is deliberately somewhere else. Driving is
	done by whoever is sitting in it (they own its physics, so anything the
	server sets would arrive a round trip late), and the sealing simulation is
	client-side for the same reason it always was.

	Tank draw is client-reported and rate-limited below, matching how coverage is
	handled: enough to stop the tank reading as infinite, not an anti-exploit
	boundary.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
-- Only for the Starter Rig upsell on the drive prompt; PassService is still the
-- only place that ASKS Roblox who owns what.
local MarketplaceService = game:GetService("MarketplaceService")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Pack:WaitForChild("Config"))
local TruckBuilder = require(Pack:WaitForChild("TruckBuilder"))
local CyberStandBuilder = require(Pack:WaitForChild("CyberStandBuilder"))
local ToolBuilder = require(Pack:WaitForChild("ToolBuilder"))
local Depot = require(Pack:WaitForChild("Depot"))
local Rigs = require(Pack:WaitForChild("Rigs"))
local DealershipBuilder = require(Pack:WaitForChild("DealershipBuilder"))

local UIPack = ReplicatedStorage:WaitForChild("SealerUI")
local Upgrades = require(UIPack:WaitForChild("Upgrades"))
local Passes = require(UIPack:WaitForChild("Passes"))

local Remotes = Pack:WaitForChild("Remotes")
local TruckControl = Remotes:FindFirstChild("TruckControl") :: RemoteEvent?
if not TruckControl then
	local r = Instance.new("RemoteEvent")
	r.Name = "TruckControl"
	r.Parent = Remotes
	TruckControl = r
end
assert(TruckControl)

--[[
	Refusals from the bay are sent down the shop's own result remote, so "you do
	not own this yet" arrives in exactly the same toast the counter uses. Created
	here the same idempotent way UpgradeService creates it, because which of the
	two scripts runs first is not guaranteed.
]]
local uiRemotes = UIPack:FindFirstChild("Remotes")
if not uiRemotes then
	uiRemotes = Instance.new("Folder")
	uiRemotes.Name = "Remotes"
	uiRemotes.Parent = UIPack
end
local BuyResult = uiRemotes:FindFirstChild("BuyResult") :: RemoteEvent?
if not BuyResult then
	local r = Instance.new("RemoteEvent")
	r.Name = "BuyResult"
	r.Parent = uiRemotes
	BuyResult = r
end

--==[ RIG STATE ]=============================================================

--[[
	The rig is not built at server start. It is a purchase, and it exists only
	while somebody who owns it has called it up.

	ONE PER PLAYER, and that is a fix rather than a flourish. All of this used to
	be a handful of module-level locals -- one model, one base, one seat -- which
	meant one truck for the entire SERVER: the second player to buy a rig was told
	"there is already a rig in the bay" and could never call theirs up at all,
	while the first player's truck answered everybody's prompts.

	The bay is still one physical spot, so the trucks queue along it: each player
	takes the first free slot, which is why the park position is an index rather
	than a constant.
]]
type Fleet = {
	model: Model,
	base: BasePart,
	seat: VehicleSeat,
	wandPrompt: ProximityPrompt,
	reelPrompt: ProximityPrompt,
	slot: number,
	-- anchored out of the physics solver because nobody is driving it; see setParked
	parked: boolean,
	-- every frozen part's pose relative to the chassis, taken at the moment it was
	-- parked and put back at the moment it is released; see setParked
	frozen: { [BasePart]: CFrame }?,
	-- the twelve anchored pieces nobody welds -- blade bar, beacons, agitator,
	-- gauge, reel -- and where the chassis was when they were last dragged along
	-- behind it. See syncDynamics.
	dynamics: { BasePart },
	syncedAt: Vector3?,
}
local fleet: { [Player]: Fleet } = {}

--[[
	Where each rig stands -- and only the FIRST one is in the bay.

	The bay is one truck wide. It was being treated as six, pitched 14 studs along
	+X from TruckPark, and that is a lane the garage does not have. Measured, with
	a 22 x 7.6 truck at each of the six:

		slot 0  x   0   clear -- the bay
		slot 1  x  14   inside RigSpawner/Console -- the "RIG BAY" post itself
		slot 2  x  28   on Counter/Desk and the shop terminal, ground probe 3.2 up
		slot 3  x  42   out on GrassField, through the divide wall, into a tree
		slot 4  x  56   out on GrassField, in the tutorial lot
		slot 5  x  70   out on GrassField, on Mailbox_114

	One player never sees it. The second one gets a truck delivered inside the
	furniture, which is the "their cars spawn weird" report: the ground probe finds
	the counter or the console instead of the floor, the rig materialises on top of
	it and slides off on its side.

	So slot 0 keeps the bay and everyone after it parks in the yard lane west of
	the apron, nearest first. Off the DepotApron deliberately -- that is a sealable
	job and a truck stood on it punches a hole in somebody's coverage -- and nose
	south like the bay, so the row reads as a yard full of rigs rather than a
	scatter. Every one of these was measured clear for the body plus margin.
]]
local MAX_SLOTS = 1   -- the bay, and there is only ever one of it

local function parkFor(_slot: number): Vector3
	return Config.TruckPark
end

--[[
	Why the bay is not a car park, and what happens to everyone else's rig.

	The yard was swept for anywhere a 22 x 7.6 truck could stand: outdoors, clear
	of everything solid, on real ground, off every sealable slab, and not on the
	dealership showroom floor. The only strip that qualifies is x -32..24 at
	z = 252 -- behind the garage, walled in by DivideNorth on one side and the
	showroom on the other, with no way to drive a truck back out of it. Everywhere
	else is the building, the forecourt (a job), the apron (a job), or the street
	(a job, and a rig parked on one punches a hole in its mask now that parked rigs
	are anchored).

	So the bay stays one truck wide, which is what it physically is, and a player
	who calls up a rig while it is taken has theirs delivered to WHERE THEY ARE
	standing instead. That needs no map real estate, cannot collide with anybody
	else's rig by construction, and scales past six players -- which the slot lane
	never did.
]]
--[[
	Rings rather than a handful of fixed offsets, and it is worth saying why.

	This was ten hard-coded vectors, none further than 30 studs and all of them on
	the world axes. Measured from the rig bay prompt -- which is exactly where a
	player stands when they call a rig up -- not one of the ten fitted a truck, so
	the call was simply refused. Swept properly there are three clear spots at 30
	studs out and six more at 45; the offsets were just missing them.

	Angles run out from straight BEHIND the player and alternate either side, so the
	tidiest spot still wins and a 22-stud flatbed never appears in the face of
	somebody about to walk forward. Radii climb, so a truck lands as close as it can.

	48 candidates, each a box query and a ray, once per rig call-up. That is a
	button press, not a frame.
]]
local DROP_RINGS = { 18, 26, 34, 44 }
local DROP_ANGLES = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150, 180 }

--[[
	The bay is taken when there is a TRUCK IN IT, not when somebody once claimed it.

	This used to be a ledger test -- walk `fleet` and see if any entry still held
	slot 0 -- and `slot` is written once at spawn and never cleared. So the first
	player to call a rig up reserved the bay for the entire life of that rig, and
	driving it out to a job did not hand it back: the bay stood visibly empty while
	every other player in the server was told it was full and had their truck
	delivered to wherever they happened to be standing.

	Where they happen to be standing is the rig bay prompt, inside the garage. So a
	second, third and fourth player each got a 22-stud flatbed materialising around
	them in the same small room -- and since rigs pass through each other now (see
	TruckBuilder's collision groups) what that looks like is trucks inside trucks.
	That is the "everyone's cars spawn on top of each other" report.

	Asking the world instead needs no bookkeeping and cannot go stale: slotClear
	already does exactly this test for the physical case, and a rig standing in the
	bay is the thing it is looking for. Deleted rather than fixed, because a ledger
	that has to be kept in step with reality is the bug, not the entry that was
	missing from it.
]]

--[[
	A rig nobody is driving comes out of the physics solver entirely.

	This is a truck, not a prop: one chassis assembly plus four wheel/upright/
	knuckle assemblies, joined by 20 constraints -- a PrismaticConstraint and a
	SpringConstraint per corner for the suspension, a HingeConstraint motor per
	wheel, a ServoConstraint per steered knuckle. Left unanchored it stays in the
	solver for the whole session whether or not anyone is in it, and with
	MAX_SLOTS rigs that is 30 assemblies and 120 constraints of continuously
	simulated vehicle sitting in a bay.

	And it is not only the owner who pays. Nothing here ever called SetNetworkOwner,
	so Roblox assigns an unanchored assembly to the nearest player -- walk past
	somebody else's parked truck and your client inherits its physics. That is the
	real answer to "another player's rig makes ME lag": their sealing cannot reach
	you (nothing about it is replicated or broadcast) but their TRUCK can, and does.

	Anchoring is the whole fix. A parked truck is meant to be immovable anyway --
	it weighs five tonnes and it is stood in a bay -- so freezing it costs nothing
	visible, stops it replicating a CFrame stream, and takes it off every client at
	once. The Heartbeat below parks one once it has actually come to rest, so a rig
	coasting to a stop after the driver hops out settles first rather than freezing
	in mid-bounce.

	The beacons, agitator, reel drum, gauge needle and blade are skipped: those are
	anchored for their whole life by design and re-framed off the chassis by their
	owner's client every tick (see TruckBuilder.dynamic), so unanchoring one would
	drop it through the deck. They carry a RigPos attribute and nothing else does.
]]
local PARK_SPEED = 1.5   -- studs/s under which a rig counts as stopped

local function setParked(e: Fleet, parked: boolean)
	if e.parked == parked then return end

	--[[
		A TRUCK WITH SOMEBODY IN IT IS NEVER PARKED, whoever is asking, and this is
		"sometimes it just doesn't let you move it" (owner, 2026-08-12).

		Parking anchors the chassis, and an anchored chassis with a driver sitting in
		it is a truck that answers the throttle with nothing at all. Measured: seated,
		vehicle controls armed, throttle arriving at the seat, moved 0.00 studs.
		Getting out and back in clears it, because the drive prompt un-parks -- which
		is exactly what makes it read as "sometimes".

		The way in was setHolder: taking the wand anchors the rig on purpose, so the
		hose has something immovable to pull against. Its note says that can never
		catch a driver because "climbing in stows it" -- but the Occupant handler only
		stows the wand `if holderOf(e) == plr`, i.e. only when the DRIVER is the one
		holding it. Another player holding it was never stowed, so any passer-by could
		take the wand off a truck somebody else was driving and freeze it under them.

		The reel is owner-only now, which shuts that particular door. This is the
		invariant behind the door: the rule belongs here, where every caller has to go
		through it, rather than in each caller's good manners. A rig that cannot be
		parked under its driver cannot be frozen under its driver by anything anybody
		adds later either.

		Nothing is lost by refusing. The Heartbeat below re-offers every quarter
		second, so a rig whose driver has since got out parks on the next tick.
	]]
	if parked and e.seat.Occupant ~= nil then return end

	e.parked = parked

	--[[
		The pose is recorded on the way in and RESTORED on the way out, and that is
		what stops a rig driving off without its wheels.

		Parking anchors the whole assembly. The body is welded and comes back exactly
		as it left, but the hubs, knuckles, uprights and wheels are held on by
		HingeConstraints -- and a constraint whose two parts are anchored, moved, and
		then released does not reliably pull them back together. The solver wakes to
		find the geometry already wrong and simply keeps it, so the chassis drives
		away and the running gear stays in the bay. Measured on a rig moved off its
		park spot: wheels 146-369 studs adrift, knuckles 191, hubs 83 -- every one of
		them a constraint-linked part, and not one of the welded or anchored ones.

		So release does not merely unanchor. Each part is put back at the offset it
		had when it was frozen, WHILE it is still anchored, and only then handed to
		the solver -- which therefore wakes to an assembly that is already correct
		rather than one it has to guess its way out of.

		Keyed on the part rather than by index: the model can gain parts between
		parking and leaving (the wand, a rebuilt prompt), and anything not in the
		table is simply unanchored as before.
	]]
	local baseCF = e.base.CFrame

	--[[
		RE-SEATED ON THE WAY OUT, because a rig parked INSIDE the floor is a rig that
		cannot be driven at all (owner, 2026-08-14, with a photograph of a truck
		buried to its axles in the depot).

		The park height comes from one downward ray in spawnRig, fired from six studs
		up and falling back to the raw park height when it hits nothing -- and it
		excludes every other rig, so a probe fired where a truck already stands
		carries on through it hunting for real floor. Any of those seats the chassis
		low, and the release below then hands ~440 parts to the solver already
		intersecting the ground. The wheels have nothing to push against, the throttle
		moves it nowhere, and from the cab it reads as a truck that will simply not go.

		SO THE HEIGHT IS ASKED AGAIN HERE, at the one moment the answer has to be
		right, and the correction is folded into baseCF BEFORE the restore loop -- so
		every frozen part lands at its corrected place in the same pass, rather than
		the rig being teleported afterwards with its running gear left behind. The
		dynamics follow on their own: RigController re-frames them off the base every
		Heartbeat.

		IT ONLY EVER LIFTS. A ray that misses, or finds ground below the truck, is
		ignored -- dropping a rig on a bad reading would be a new way to lose one, and
		a rig standing slightly proud settles by itself once the solver has it. The
		0.05 deadband stops a correctly-seated rig being nudged on every unpark.
	]]
	if not parked then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		-- its own parts only: another rig is something to stand ON, not something to
		-- sink through, which is the exact assumption the spawn probe gets wrong
		params.FilterDescendantsInstances = { e.model }
		local at = e.base.Position
		local hit = workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), params)
		if hit and hit.Position.Y > at.Y + 0.05 then
			local lift = hit.Position.Y - at.Y
			baseCF = baseCF + Vector3.new(0, lift, 0)
			warn(("[TruckServer] a rig was %.2f studs into the ground -- lifted out")
				:format(lift))
		end
	end

	if parked then e.frozen = {} end
	local frozen = e.frozen

	for _, d in ipairs(e.model:GetDescendants()) do
		--[[
			The SEAT is never anchored, and that is what "sometimes you cannot drive at
			all" was.

			Parking anchors the rig, which is right -- a five-tonne truck standing in a
			bay has no business in the solver. But anchoring the VehicleSeat with it
			means the one part whose whole job is to hand control over is frozen, and
			every route in depends on the unpark landing first. The prompt does unpark
			before it seats; anything that does not go through the prompt -- a Sit()
			from elsewhere, a respawn onto the seat, a second player's client racing the
			signal -- gets a driver welded to an anchored truck and a throttle that
			goes nowhere, with nothing on screen to say why.

			Leaving one 4x1x2 seat in the solver costs nothing next to the ~440 parts
			this still freezes, and it makes the failure unreachable rather than rare.
		]]
		if d:IsA("BasePart") and d:GetAttribute("RigPos") == nil
			and not d:IsA("VehicleSeat") then
			if parked then
				if frozen then frozen[d] = baseCF:ToObjectSpace(d.CFrame) end
			elseif frozen and frozen[d] then
				-- back into place BEFORE it is unanchored, so the solver never sees the
				-- broken pose at all
				d.CFrame = baseCF * frozen[d]
			end
			d.Anchored = parked
		end
	end
	if not parked then e.frozen = nil end
end

--[[
	And the slot has to be physically empty, not merely unclaimed.

	The table above says who the game THINKS is parked where; this asks the world.
	A rig driven back into the bay and abandoned, a prop dropped in the lane, a
	future edit that moves the counter -- none of those touch `fleet`, and every
	one of them ends with a truck delivered inside something solid. Characters are
	ignored on purpose: a player stood in the bay should not be able to stop
	anybody calling a rig up, and a truck arriving simply pushes them aside.
]]
local function ignoreList(): { Instance }
	local skip: { Instance } = {}
	local fx = workspace:FindFirstChild("SealerVisuals")
	if fx then skip[#skip + 1] = fx end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then skip[#skip + 1] = plr.Character end
	end
	--[[
		And another rig is not an obstacle either (2026-08-10, owner's call).

		Rigs stopped colliding with each other some time ago, but this test did not
		know that -- so a truck standing in the bay still read as solid, `slotClear`
		said no, and everybody after the first player had theirs delivered out in the
		yard instead. Boxed in somewhere tight it could refuse the call-up outright,
		which is a button that does nothing.

		Since two rigs pass through each other, standing in the same place is allowed:
		they interpenetrate rather than fight, and either can be driven straight out.
		So the clearance test asks about the WORLD -- walls, furniture, the counter --
		and ignores the fleet entirely.

		By RigId rather than off `fleet`, so a stray rig left by an edit or a player
		who has since gone is covered by the same rule. The dealership's exhibits do
		NOT carry it and stay solid, which is what still stops a truck being parked
		inside a display model.
	]]
	for _, d in ipairs(workspace:GetChildren()) do
		if d:GetAttribute("RigId") ~= nil then skip[#skip + 1] = d end
	end
	return skip
end

-- Is there room for a truck standing here, and is it standing on something?
local function roomAt(at: Vector3): boolean
	local op = OverlapParams.new()
	op.MaxParts = 40
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = ignoreList()
	for _, p in ipairs(workspace:GetPartBoundsInBox(
		CFrame.new(at + Vector3.new(0, 3.4, 0)),
		Vector3.new(Config.TruckWidth + 2, 5.6, Config.TruckLength + 3), op)) do
		if p.CanCollide then return false end
	end
	return workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, -20, 0)) ~= nil
end

local function slotClear(i: number): boolean
	return roomAt(parkFor(i))
end

--[[
	Somewhere beside this player to leave a rig, or nil if they are boxed in.

	Tried behind them first: a 22-stud truck appearing on the spot they are stood
	on would shove them, and appearing in front of them is in the way of wherever
	they were about to walk. Kept flat and square to the world rather than to the
	player, so a row of delivered rigs still looks parked rather than scattered.
]]
--[[
	Outdoors, and not standing on somebody's job.

	Two things a bare clearance test cannot see, and both of them are what a
	delivered truck actually looked wrong doing.

	INDOORS: the rig bay prompt is inside the garage, which is where a player stands
	when they call a rig up -- so "16 studs behind you" is very often another part of
	the same room. It fits, there is floor under it, and roomAt is perfectly happy;
	it is still a flatbed truck in a shop. Tested by looking UP, which needs no map
	knowledge and stays true if the building is ever moved.

	ON A JOB: nothing stopped a delivery landing on a driveway, the apron or the
	road. A parked rig is anchored, and DrivewaySurface's blocker sweep counts
	anchored parts -- so a truck sitting on a slab when somebody builds its surface
	punches a permanent hole in their coverage. The slot lane was kept off the apron
	for exactly this reason; the delivery path never got the same care.

	A PREFERENCE, NOT A RULE. It runs as a first pass over the same offsets and
	falls through to the old test, so this can only ever move a delivery to a better
	spot -- never refuse one that used to succeed. A player boxed in indoors still
	gets their truck.
]]
local function underRoof(at: Vector3): boolean
	local op = RaycastParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = ignoreList()
	return workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, 40, 0), op) ~= nil
end

local function onSealableSlab(at: Vector3): boolean
	for _, p in ipairs(CollectionService:GetTagged("SealableDriveway")) do
		if p:IsA("BasePart") then
			local l = p.CFrame:PointToObjectSpace(Vector3.new(at.X, p.Position.Y, at.Z))
			-- the truck's own half-length of margin, so it is off the slab rather than
			-- merely centred beside it
			if math.abs(l.X) < p.Size.X * 0.5 + Config.TruckWidth
				and math.abs(l.Z) < p.Size.Z * 0.5 + Config.TruckWidth then
				return true
			end
		end
	end
	return false
end

local function dropSpotNear(plr: Player): Vector3?
	local ch = plr.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return nil end
	local here = hrp.Position
	-- straight behind them is angle zero; the sweep opens out from there
	local back = -hrp.CFrame.LookVector
	local facing = math.deg(math.atan2(back.Z, back.X))

	--[[
		One pass, two answers: the first spot that is outdoors and off every job wins
		outright, and the nearest spot that merely FITS is kept as the fallback.

		That ordering is the whole point. Preferring the good spot cannot cost a
		delivery -- if none exists the fallback is exactly what the old code would
		have returned -- so a player boxed inside the garage still gets their truck,
		and everybody else gets one parked out in the open instead of in the shop.
	]]
	local fallback: Vector3? = nil
	for _, r in ipairs(DROP_RINGS) do
		for _, swing in ipairs(DROP_ANGLES) do
			local a = math.rad(facing + swing)
			local at = Vector3.new(here.X + math.cos(a) * r, Config.TruckPark.Y,
				here.Z + math.sin(a) * r)
			if roomAt(at) then
				if not underRoof(at) and not onSealableSlab(at) then return at end
				if not fallback then fallback = at end
			end
		end
	end
	return fallback
end

local function freeSlot(): number?
	for i = 0, MAX_SLOTS - 1 do
		if slotClear(i) then return i end
	end
	return nil
end

local function prompt(host: BasePart, action: string, object: string, dist: number, hold: number?): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.ActionText = action
	p.ObjectText = object
	p.MaxActivationDistance = dist
	p.HoldDuration = hold or 0
	p.RequiresLineOfSight = false
	p.Parent = host
	return p
end

local function notify(plr: Player, ok: boolean, message: string)
	if BuyResult then (BuyResult :: RemoteEvent):FireClient(plr, "Rig", ok, message) end
end

-- Owns at least one of the three. Each is its own two-level unlock track; see
-- the note where they are generated in SealerUI.Upgrades.
local function ownsAnyRig(plr: Player): boolean
	return Rigs.chosen(plr) ~= nil
end

--==[ WHOSE CAB IT IS ]=======================================================

--[[
	The wand is communal; the driver's seat is not.

	A RIG IS ITS OWNER'S, AND BOTH DOORS INTO IT ARE GUARDED -- the cab always was,
	the reel as of 2026-08-12 (owner's call).

	Anyone used to be able to pull the wand off anyone's truck, on the reasoning
	that two players on one job is the good version of this game. What it bought in
	practice was strangers walking off with the wand of a truck they had nothing to
	do with -- and the reel then reads as IN USE to the person who owns it, whose
	own prompt is gone until the stranger winds it back or leaves. The truck is
	their purchase, the drum is theirs to fill, and the sealer coming out of the
	nozzle is theirs.

	DRIVING somebody else's rig was never allowed, and that is the sharper version
	of the same thing: it is not helping them, it is taking it, and RigController
	only binds a model stamped with your own OwnerUserId -- so a passer-by in the
	cab is a passer-by in a truck that answers nothing they press, parked wherever
	they left it while its owner walks back to an empty bay.

	Who owns a given rig needs no lookup: every prompt and signal below is built
	inside spawnRig, which was handed the owner, so all three guards close over the
	same value rather than searching the fleet for it.
]]

--[[
	Turned away at the door, and sold the way in on the way past.

	A player with no truck of their own who reaches for somebody else's has just
	said, as plainly as the game will ever hear it, that they want a truck. That is
	exactly what the Starter Rig pass is -- see the note on it in SealerUI.Passes
	-- so they get Roblox's purchase dialog rather than a refusal and no idea what
	to do about it. Buying it grants the ordinary unlock and the delivery watcher
	brings their own rig round to the bay a second later.

	Somebody who already owns a rig is not a customer, they are just at the wrong
	truck, so they get told which and nothing is offered to them.

	`what` is the part of the truck they were turned away from, so the cab and the
	reel each name themselves. One function for both, because the answer is the
	same either way: it is not your rig, and here is how to come by one.

	Prompted from the SERVER, which needs no remote of its own -- and matters more
	here than it reads: both doors are guarded on the server whether or not a
	client is playing along, so the refusal and the offer have to come from the
	same place as the refusal itself or a hacked client gets one without the other.
]]
local function refuseRig(plr: Player, owner: Player?, what: string?)
	local noun = what or "rig"
	if ownsAnyRig(plr) then
		-- "call up" rather than "yours is in the bay": owning a rig is not the same
		-- as having it out, and the console is the answer either way
		notify(plr, false, (if owner then owner.DisplayName .. "'s " .. noun
			else "Somebody else's " .. noun)
			.. " -- call up your own at the bay")
		return
	end
	local pass = Passes.ById.PermanentRig
	notify(plr, false, "That rig is not yours -- grab a Starter Rig of your own")
	-- A pass with no asset id behind it is one nobody can be shown; see the note
	-- at the top of SealerUI.Passes. The refusal above still stands on its own.
	if pass and pass.assetId ~= 0 then
		pcall(function() MarketplaceService:PromptGamePassPurchase(plr, pass.assetId) end)
	end
end

--[[
	The Bucket Capacity track scales the truck's drum as well as the pail.

	Without this the track dies the moment a rig is bought -- even the cheapest
	truck carries eight pails, so every further level of it buys nothing at all,
	and a quarter of the upgrade screen becomes decoration for the rest of the
	game. As a ratio rather than a sum, so the three trucks keep their relative
	sizes and the Cistern is always the big one.
]]
local TANK_BASE_L = Upgrades.valueAt("Tank", 1)
local function tankScaleOf(plr: Player): number
	local lv = (plr:GetAttribute("Upg_Tank") :: number?) or 1
	return Upgrades.valueAt("Tank", lv) / TANK_BASE_L
end

--==[ WAND ]==================================================================

--[[
	Who has the wand is kept on the model as an attribute rather than in a local
	here. It has to be replicated anyway -- a second player walking up needs to
	see that the reel is already in use -- and keeping one copy of the fact means
	the prompt states and the tank draw check can never disagree about it.
]]
local function holderOf(e: Fleet?): Player?
	if not e then return nil end
	local id = (e.model:GetAttribute("HolderUserId") :: number?) or 0
	return if id ~= 0 then Players:GetPlayerByUserId(id) else nil
end

-- Which rig, if any, this player currently has the wand off. A search rather
-- than a lookup on `fleet[plr]`, so it still answers for a wand that outlived
-- the rig it came from -- stored, swapped, or taken before the reel was guarded.
local function rigHeldBy(plr: Player): Fleet?
	for _, e in pairs(fleet) do
		if holderOf(e) == plr then return e end
	end
	return nil
end

--[[
	And which rig this player is SITTING IN, which is a different question.

	A search on the seat rather than a lookup on `fleet[plr]`, for the same reason
	rigHeldBy is one: the cab is owner-only today, but reading it off the seat keeps
	the answer true however that rule changes again -- and it is the driver the
	blade's game pass is a fact about.

	This exists because the two outlets on a rig are reached from opposite places.
	The wand is held, so rigHeldBy finds it; the spray bar and the squeegee bar are
	driven, and rigHeldBy answers nil for somebody in the cab -- climbing in stows
	the wand, so a driver is never a holder. Three call sites had grown their own
	copy of this loop.
]]
local function rigDrivenBy(plr: Player): Fleet?
	local ch = plr.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat then return nil end
	for _, e in pairs(fleet) do
		if e.seat == seat then return e end
	end
	return nil
end

local function setHolder(e: Fleet, plr: Player?)
	e.model:SetAttribute("HolderUserId", if plr then plr.UserId else 0)
	e.wandPrompt.Enabled = plr == nil
	e.reelPrompt.Enabled = plr ~= nil
	--[[
		The hose is a tether, so the thing at the other end of it has to be immovable.

		HoseRig hangs a RopeConstraint between the player's root and ReelOutlet, and
		ReelOutlet is a cosmetic part welded to the chassis -- so with the chassis
		loose in the solver, walking to the end of the hose did not stop the player,
		it started a tug of war between a humanoid and five tonnes of truck. The truck
		lost: you could walk the whole rig down the street on the end of its own hose.

		Anchoring while the wand is out makes the rope pull against the world instead,
		which is what "you reach the end and run on the spot" actually is.

		It does not need undoing when the wand goes back: parked is the resting state,
		and the drive prompt un-parks before it seats anybody.

		THIS USED TO CLAIM IT COULD NEVER FREEZE A TRUCK UNDER ITS OWN DRIVER, on the
		grounds that climbing in stows the wand. It does -- but only for the driver:
		the Occupant handler stows `if holderOf(e) == plr`, so a wand in SOMEBODY
		ELSE'S hands stayed out, and taking one off a truck a stranger was driving
		anchored it under them. That is fixed twice over now: the reel is owner-only,
		and setParked refuses to park an occupied rig whoever asks. See the note there.
	]]
	if plr then setParked(e, true) end
end

local function findWand(plr: Player): Tool?
	local character = plr.Character
	if character then
		local held = character:FindFirstChild("Spray Wand")
		if held and held:IsA("Tool") then return held end
	end
	local pack = plr:FindFirstChildOfClass("Backpack")
	if pack then
		local stowed = pack:FindFirstChild("Spray Wand")
		if stowed and stowed:IsA("Tool") then return stowed end
	end
	return nil
end

local function stowWand(e: Fleet)
	local plr = holderOf(e)
	if plr then
		local tool = findWand(plr)
		if tool then tool:Destroy() end
	end
	setHolder(e, nil)
end

--==[ WHERE THE TRUCK IS ]====================================================

--[[
	This player's chassis position, published onto the PLAYER rather than onto
	the rig.

	The client draws a locator tag over your own truck once you are out of it (see
	DrivewaySealer.RigMarker), and the entire point of that tag is long range --
	which is exactly where StreamingEnabled has taken the model away from the
	client that wants to draw it. A Player instance never streams out, so this is
	the one place the answer can be kept where it will still be there when it is
	needed. Attributes replicate on their own, so there is no remote in it.

	Written only when the truck has actually moved: a rig standing where it was
	left costs nothing at all, and a rig being driven costs one Vector3 five times
	a second -- to a driver who cannot see the tag anyway, since it hides while
	anybody is in the seat.
]]
local MARKER_MOVE = 1.0   -- studs; under this the spot already published stands

local function publishMarker(owner: Player, e: Fleet)
	local at = e.base.Position
	local was = owner:GetAttribute("RigMarkerAt")
	if typeof(was) ~= "Vector3" or ((was :: Vector3) - at).Magnitude > MARKER_MOVE then
		owner:SetAttribute("RigMarkerAt", at)
	end
end

--[[
	The rig's ANCHORED pieces are dragged along on the server too, and this is
	why the garage kept filling up with other people's squeegees.

	Twelve parts of every truck -- the front blade bar (BladeArm x2, BladeBar,
	BladeRubber, BladeSkirt), the two beacons, the agitator, the gauge needle and
	the reel -- are anchored rather than welded, because a weld is exactly the
	thing that would stop them turning (see TruckBuilder.dynamic). They are
	re-framed off the chassis sixty times a second by CLIENTS: RigController for
	your own, RemoteToolsClient for everybody else's. Nothing has ever moved them
	on the server.

	So the moment a rig leaves the bay the server's own copy of it comes apart.
	Measured on a delivered Bantam Dart whose chassis was moved 300 studs: all
	twelve stayed exactly where TruckBuilder put them, in the depot at z 203-226,
	over two thousand studs from their own Base.

	That is not a bookkeeping detail, because this place has StreamingEnabled. A
	part is streamed to a client according to where the SERVER believes it is --
	so those twelve are handed to whoever is standing in the GARAGE, while the
	chassis they belong to, being genuinely out on a job, is not. RemoteToolsClient
	can only pose a rig it can find a Base for, so it steps over them and they just
	sit there on the bay floor. That is "somebody else's squeegee left behind in
	the garage", and it is the same stale belief that can hand a distant player a
	truck with no blade on it -- the blade was filed under the depot.

	Only on the marker's throttle, and only once the rig has actually moved: a
	parked truck is still where it was last put. The pose written is the RESTING
	one -- the blade at whatever the server has commanded, everything else at
	angle zero -- because the job here is to file the parts under the right
	POSTCODE, not to animate them. Every client overwrites all twelve on its own
	Heartbeat before anything is drawn, so nobody ever sees this pose.
]]
local SYNC_MOVE = 4.0   -- studs; under this the pose already published stands

local function syncDynamics(e: Fleet)
	local baseCF = e.base.CFrame
	local was = e.syncedAt
	if was and ((was :: Vector3) - baseCF.Position).Magnitude < SYNC_MOVE then return end
	e.syncedAt = baseCF.Position

	local blade = if e.model:GetAttribute("BladeDown") == true
		then 0 else math.rad(Config.TruckBladeRaise)
	for _, p in ipairs(e.dynamics) do
		local pos = p:GetAttribute("RigPos") :: Vector3?
		local rot = p:GetAttribute("RigRot") :: CFrame?
		local axis = p:GetAttribute("SpinAxis") :: Vector3?
		if pos and rot and axis then
			local angle = if string.find(p.Name, "Blade") then blade else 0
			p.CFrame = baseCF * CFrame.new(pos) * CFrame.fromAxisAngle(axis, angle) * rot
		end
	end
end

--==[ SPAWN / STORE ]=========================================================

local function storeRig(owner: Player)
	local e = fleet[owner]
	if not e then return end
	fleet[owner] = nil
	stowWand(e)
	e.model:Destroy()
	-- and the tag goes with it, or it hangs over the empty bay pointing at a
	-- truck that no longer exists
	owner:SetAttribute("RigMarkerAt", nil)
end

local function spawnRig(owner: Player, rig: Rigs.Rig): boolean
	storeRig(owner)

	--[[
		The bay if it is free, otherwise delivered to the player.

		`slot` stays as the bay's reservation and nothing else; a delivered rig holds
		no slot (-1), so it can never make somebody else's call-up think the bay is
		taken. Refusing only happens when there is nowhere at all to put a truck,
		which means the player is stood somewhere genuinely boxed in.
	]]
	local slot = if require(Pack.ExtraRefuel).at(owner) then nil else freeSlot()
	local park: Vector3
	if slot then
		park = parkFor(slot)
	else
		local drop = dropSpotNear(owner)
		if not drop then return false end
		slot, park = -1, drop
	end

	--[[
		The probe starts just above the park height, not forty studs up. The rig
		spawns inside the depot garage, and a ray dropped from up there lands on
		the building's roof -- which would put a 22-stud flatbed on top of it.
	]]
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	--[[
		Every other rig is excluded, not just the sealer's visuals.

		This probe is what decides the delivery height, and a single downward ray at
		the park spot will happily land on the ROOF of a truck already standing
		there -- which spawns the new one eight studs up, on top of it, and it slides
		off. That now arises by design rather than by accident -- rigs are allowed to
		stand in the same place since they pass through each other -- so this is the
		last thing between a bad answer and a truck on its side.

		The same list the clearance test uses, so "a rig is not an obstacle" is one
		rule rather than two that can drift. It covers a stray rig as well as a live
		one: the old version asked `fleet`, which does not know about a truck left
		behind by an edit or by an owner who has already gone, and either of those
		would have been a perfectly good ramp.
	]]
	params.FilterDescendantsInstances = ignoreList()
	local probe = workspace:Raycast(Vector3.new(park.X, park.Y + 6, park.Z),
		Vector3.new(0, -30, 0), params)
	local groundY = if probe then probe.Position.Y else park.Y

	-- Paint AND proportions. Rigs.body turns this truck's own stats into the size
	-- of its barrel and reel, so the three rigs are three different vehicles
	-- rather than one vehicle in three colours.
	local shape = Rigs.body(rig)
	local model = TruckBuilder.build(
		CFrame.new(Vector3.new(park.X, groundY, park.Z))
			* CFrame.Angles(0, math.rad(Config.TruckYaw), 0),
		workspace,
		{
			cab = rig.cab,
			tint = rig.tint,
			tankDia = shape.tankDia, tankLen = shape.tankLen,
			reelDia = shape.reelDia, reelWidth = shape.reelWidth,
			-- Nil for every rig on the cash ladder, which is what makes them build
			-- exactly as they always have. See buildShellBody in TruckBuilder.
			shell = rig.shell,
		})
	model:SetAttribute("OwnerUserId", owner.UserId)

	--[[
		The rig's own numbers ride on the model rather than being read from Config.

		That is what makes the three trucks actually different: the controller, the
		hose and the HUD all read these, so a Longline really does pay out 280
		studs and a Cistern really does carry nineteen thousand. Config keeps the
		same keys as fallbacks for anything that spawns a rig without a catalogue
		entry.
	]]
	model:SetAttribute("RigId", rig.id)
	model:SetAttribute("RigName", rig.name)
	model:SetAttribute("TopSpeed", rig.topSpeed)
	model:SetAttribute("HoseMax", rig.hose)
	model:SetAttribute("Pump", rig.pump)
	-- Brakes, when this rig has its own. nil CLEARS the attribute, which is the
	-- right thing: RigController falls back to Config for a rig that says nothing,
	-- and that is every truck on the cash ladder. See the note on Rigs.brake.
	model:SetAttribute("Brake", rig.brake)
	model:SetAttribute("BrakeEase", rig.brakeEase)
	-- TankBase is the catalogue figure; TankCapacity is that figure after the
	-- owner's Bucket Capacity level, and the refill loop keeps it current.
	model:SetAttribute("TankBase", rig.tank)
	local capacity = rig.tank * tankScaleOf(owner)
	model:SetAttribute("TankCapacity", capacity)
	model:SetAttribute("Tank", capacity)
	-- Every rig is built with the front squeegee bar, parked. Called up with it
	-- already down it would scrub the bay floor on the way out of the door.
	model:SetAttribute("BladeDown", false)
	-- And with the spray bar's valve shut, for the same reason: a rig that came out
	-- of the bay pouring would lay a trail of sealer across the depot floor.
	model:SetAttribute("Pouring", false)

	local theBase = model:FindFirstChild("Base") :: BasePart
	local theSeat = model:FindFirstChild("Seat") :: VehicleSeat
	local wandDock = model:FindFirstChild("WandDock") :: BasePart
	local reelDrum = model:FindFirstChild("ReelDrum") :: BasePart

	-- Prompts are built per spawn and die with the model, so nothing has to be
	-- disconnected by hand when the rig is stored.
	local takePrompt = prompt(wandDock, "Take Wand", "Hose Reel", 11)
	local windPrompt = prompt(reelDrum, "Wind In Hose", "Hose Reel", 11, 0.4)
	local drivePrompt = prompt(theSeat, "Drive", "Sealcoat Rig", 12)
	--[[
		A KEY OF ITS OWN, and this is the "sometimes you cannot get in the truck"
		bug (owner, 2026-08-11).

		Roblox shows ONE prompt per key -- `Exclusivity = OnePerButton` -- and it
		picks the CLOSEST one in range. The depot bay has four things on E crowded
		into it: this seat, the pump nozzle (reach 14, deliberately loose so it can
		be worked from beside a rig backed onto the pad), the bay console, and the
		truck's own wand dock fifteen studs behind the cab. So walking up to your own
		parked rig from the wrong side showed you "Fill Up" or "Spawn Rig" or "Take
		Wand", and NO way into the cab at all -- not a refusal, not a disabled
		prompt, simply nothing on screen to press.

		Measured on a rig standing in its bay, over every square metre of ground
		where this prompt is actually in range (437 of them): Drive won 288 and was
		invisible on 149 -- **a third of the ground beside your own truck**, and
		which third depended only on which way you walked up. That is the whole of
		"it happens at random".

		Shrinking the others is the wrong lever: each of those reaches is load-bearing
		somewhere (see the note over Config.FillReach). Moving off the contested key
		costs nothing and cannot regress -- F is the only F in the game, so the cab is
		always offered alongside whatever E is doing. It is also the convention
		players already have for getting into a vehicle, and the prompt prints the key
		so it teaches itself.

		This is the same fix, and the same reasoning, as the Store Rig prompt's X
		down in buildSpawner -- that one lost to Spawn Rig for sharing a PART. This
		one lost to half the garage for sharing a BAY.
	]]
	drivePrompt.KeyboardKeyCode = Enum.KeyCode.F
	-- and the same clash exists on a controller, where every prompt in the place
	-- defaults to ButtonX
	drivePrompt.GamepadKeyCode = Enum.KeyCode.ButtonY

	--[[
		The anchored pieces, listed once here.

		Complete by construction -- TruckBuilder has finished by this line and
		nothing adds another one -- and kept rather than re-walked because
		syncDynamics runs off the same throttle as the marker, and a 488-descendant
		sweep five times a second per rig to find twelve parts is not a search worth
		repeating.
	]]
	local dynamics: { BasePart } = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("RigPos") ~= nil then
			dynamics[#dynamics + 1] = d :: BasePart
		end
	end

	local e: Fleet = {
		model = model, base = theBase, seat = theSeat,
		wandPrompt = takePrompt, reelPrompt = windPrompt, slot = slot,
		dynamics = dynamics,
		-- spawned live so it can drop onto its own springs; the Heartbeat parks it
		-- as soon as it has settled
		parked = false,
	}
	fleet[owner] = e
	setHolder(e, nil)
	-- Straight away rather than waiting on the Heartbeat below, so a rig delivered
	-- to somebody stood in a doorway is signposted on the frame it arrives.
	publishMarker(owner, e)

	takePrompt.Triggered:Connect(function(plr)
		--[[
			THE REEL IS THE OWNER'S TOO (2026-08-12, owner's call).

			This had no guard at all, so anybody walking past could pull the wand off
			anybody's truck. Refused the same way the cab is, and through the same
			function, so a player with no rig of their own is offered one instead of
			simply being told no.

			Left ENABLED for everybody, for the reason the drive prompt is -- see the
			note over it. A shared prompt has no per-player Enabled to set anyway, and
			a control nobody can see is a sale nobody makes.
		]]
		if plr ~= owner then refuseRig(plr, owner, "reel") return end
		if holderOf(e) then return end
		local character = plr.Character
		if not character or not character:FindFirstChildOfClass("Humanoid") then return end
		if findWand(plr) then return end

		local wand = ToolBuilder.buildWand()
		-- Straight into the character rather than the backpack: the player walked
		-- up and pulled it off the reel, so it should already be in their hands.
		wand.Parent = character
		setHolder(e, plr)
	end)

	windPrompt.Triggered:Connect(function(plr)
		if holderOf(e) ~= plr then return end
		stowWand(e)
	end)

	--[[
		Left ENABLED for everybody, and that is the point.

		The prompt is one shared instance -- there is no per-player Enabled to set --
		but even if there were, hiding it is the wrong answer for the same reason the
		squeegee bar is built on rigs whose owner has not bought the pass: a control
		nobody can see is a sale nobody makes. Walking up to a truck and being offered
		one of your own is the shortest path there is between wanting a rig and having
		one. What the key does is decided here, once, on the server.
	]]
	drivePrompt.Triggered:Connect(function(plr)
		if plr ~= owner then refuseRig(plr, owner) return end
		local character = plr.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and theSeat.Occupant == nil then
			-- BEFORE the weld, not after: sitting welds the driver to the seat, and a
			-- seat that is still anchored would anchor the driver to the spot with it
			setParked(e, false)
			theSeat:Sit(humanoid)
		end
	end)

	-- You cannot drive and spray at once: the wand goes back on the reel when you
	-- climb in, which is also the only thing stopping a player towing themselves
	-- along on the end of their own hose.
	theSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = theSeat.Occupant
		drivePrompt.Enabled = occupant == nil
		if occupant then
			local plr = Players:GetPlayerFromCharacter(occupant.Parent)
			--[[
				The backstop on the ownership rule.

				TruckBuilder switches the seat's CanTouch off so the prompt above is the
				only door, which is what makes the check up there sufficient in practice.
				This is here for the case where it is not -- a Sit() from somewhere else,
				a seat that came back with touch on -- because "the only way in" is a
				claim about today's code and this is a claim about the truck.

				Unseating rather than refusing, since by here the weld already exists.
				Returning BEFORE the network-owner handover below is the whole reason
				this sits at the top: handing the assembly to somebody who is about to
				be thrown out of it leaves the truck's physics on a client that has no
				further interest in it.
			]]
			if plr and plr ~= owner then
				occupant.Sit = false
				refuseRig(plr, owner)
				return
			end
			-- the prompt un-parks before it seats, but this signal is also what catches
			-- a rig entered any other way, and a driver welded to an anchored truck is
			-- a driver anchored to the spot
			setParked(e, false)
			if plr then
				--[[
					Pin the assembly to the driver rather than leaving it to be assigned.

					Roblox hands an unanchored assembly to whoever is nearest, which for a
					truck being driven past a crowd is a different client every few seconds
					-- every one of them paying for physics they did not ask for, and the
					driver getting a rig that hitches each time it changes hands. RigController
					drives from the seated player's client, so this is also the client that
					needs it.
				]]
				pcall(function() e.base:SetNetworkOwner(plr) end)
				if holderOf(e) == plr then stowWand(e) end
			end
		else
			--[[
				And the assembly comes back to the server when the driver gets out.

				There was no `else` here at all: entering handed the physics to the driver
				and nothing ever took them back, so an abandoned rig went on being
				simulated by whoever last drove it -- or, once they wandered off, by
				whichever bystander Roblox reassigned it to. The note over setParked is
				about exactly that cost.

				Ownership first, THEN the velocity, and the order is the whole trick: a
				velocity written on the server while a client still owns the assembly is
				overwritten by that client's next physics frame. Taking ownership back is
				what makes the stop stick.
			]]
			pcall(function() e.base:SetNetworkOwner(nil) end)
			e.base.AssemblyLinearVelocity = Vector3.zero
			e.base.AssemblyAngularVelocity = Vector3.zero
			--[[
				AND THE VALVE SHUTS, which is where the spray bar parts company with the
				blade.

				Nothing raises the rubber when the driver gets out and that is on purpose
				-- a bar is a thing you leave where you left it. A valve is not. Left open
				it would go on emptying the drum onto the ground under an abandoned truck,
				at the idle rate, until the tank was gone; the driver would come back to a
				rig that had drunk itself dry doing nothing. The switch is only reachable
				from the driver's gauge, so leaving it open would also leave it unreachable.
			]]
			e.model:SetAttribute("Pouring", false)
		end
	end)

	return true
end

--[[
	The Heartbeat the note over setParked promises, which did not exist.

	setParked was only ever called with `false` -- twice, both on the way IN. Nothing
	anywhere called it with `true`, and PARK_SPEED was declared and never read. So
	the entire parking design was dead code: no rig was ever anchored, every one of
	them stayed in the solver for the whole session, and "another player's rig makes
	ME lag" was still true for exactly the reason that note gives.

	It runs on a timer rather than every frame because it is a poll over a handful
	of rigs looking for one that has stopped, and a rig that has stopped is in no
	hurry. Quarter of a second is far below what anybody could notice and a fortieth
	of the work.

	The seat test is what keeps a driver sitting at the lights from being anchored
	under themselves; the speed test is what lets a rig settle on its springs first,
	rather than freezing in mid-bounce.
]]
task.spawn(function()
	while true do
		task.wait(0.25)
		for _, e in pairs(fleet) do
			if e.base.Parent then
				--[[
					FREEING COMES FIRST, and it is a heal rather than a rule.

					The guard in setParked stops a rig being frozen under its driver from
					here on. This is for one that already was -- a profile mid-session when
					this shipped, or some later path that finds a way to set the flag with
					somebody in the seat. Without it the only cure is getting out and back
					in, which is a cure the player has to guess at.

					A quarter of a second, so it reads as the truck being slow to bite
					rather than as a truck that is broken.
				]]
				if e.parked and e.seat.Occupant ~= nil then
					setParked(e, false)
				elseif not e.parked and e.seat.Occupant == nil
					and e.base.AssemblyLinearVelocity.Magnitude < PARK_SPEED
					and e.base.AssemblyAngularVelocity.Magnitude < PARK_SPEED then
					setParked(e, true)
				end
			end
		end
	end
end)

--[[
	AND ANY TRUCK ALREADY STANDING THERE AT SERVER START IS A LEFTOVER.

	A rig only ever exists at runtime -- TruckBuilder makes one when somebody who
	owns it calls it up, and storeRig destroys it again -- so a SealcoatRig present
	before a single player has joined cannot belong to anybody. It got committed
	into the place by a Studio session that was saved with one out, which is the
	same stray ignoreList already has to make allowances for.

	Nothing else can clear one: it has no fleet entry, so no console, no store
	button and no PlayerRemoving will ever reach it. It just stands in the bay for
	the life of the place -- and since nobody poses its anchored pieces either, it
	is a truck's worth of "parts left behind in the garage" that no amount of
	fixing the live path can remove.

	Keyed on being a DIRECT child of Workspace, which the four showroom exhibits in
	RigDealership.Display are not -- they are scenery, they carry no RigId, and
	they are meant to stay.
]]
do
	local swept = 0
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and (m.Name == "SealcoatRig" or m:GetAttribute("RigId") ~= nil) then
			m:Destroy()
			swept += 1
		end
	end
	if swept > 0 then
		warn(("[TruckServer] cleared %d rig(s) saved into the place -- nobody owns those")
			:format(swept))
	end
end

--==[ BAY SPAWNER ]===========================================================

--[[
	The console the rig is called up from, stood beside the bay lane.

	Placed relative to the park spot rather than at written-down coordinates, so
	moving the bay moves the console with it.
]]
local function buildSpawner()
	local park = Config.TruckPark
	local at = Vector3.new(park.X + 13.6, park.Y, park.Z - 9)

	local model = Instance.new("Model")
	model.Name = "RigSpawner"

	local function piece(name: string, size: Vector3, colour: Color3, material: Enum.Material, pos: Vector3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = colour
		p.Material = material
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Position = pos
		p.Parent = model
		return p
	end

	piece("Base", Vector3.new(1.8, 0.3, 1.8), Color3.fromRGB(52, 54, 60),
		Enum.Material.DiamondPlate, at + Vector3.new(0, 0.15, 0))
	--[[
		The post stops UNDER the head, and the head is deeper than the post.

		It ran 3.2 tall from y0.2, which is 0.45 up INSIDE a head that is only 0.4
		deep against the post's 0.5 -- so the grey post came out through the black
		screen, 0.05 proud, as a bar up the bottom of the display. Two changes
		rather than one: the post now ends 0.1 inside the head's underside (a lap,
		so no hairline opens at the joint the way a flush butt would), and the head
		is 0.6 deep, which is wider than the post from every angle. The lap alone
		hides it from the lane; the deeper head is what also hides it from anyone
		stood off to the side.
	]]
	piece("Post", Vector3.new(0.5, 2.85, 0.5), Color3.fromRGB(70, 74, 82),
		Enum.Material.Metal, at + Vector3.new(0, 1.625, 0))
	local head = piece("Console", Vector3.new(0.6, 1.9, 2.6), Color3.fromRGB(28, 32, 40),
		Enum.Material.SmoothPlastic, at + Vector3.new(0, 3.9, 0))

	-- screen faces the bay lane, which is toward -X from here
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Left
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 90
	gui.LightInfluence = 0
	gui.Parent = head

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.42)
	title.Position = UDim2.fromScale(0, 0.08)
	title.Font = Enum.Font.GothamBlack
	title.Text = "RIG BAY"
	title.TextColor3 = Color3.fromRGB(150, 220, 255)
	title.TextScaled = true
	title.Parent = gui

	local sub = Instance.new("TextLabel")
	sub.Name = "Status"
	sub.BackgroundTransparency = 1
	sub.Size = UDim2.fromScale(1, 0.3)
	sub.Position = UDim2.fromScale(0, 0.55)
	sub.Font = Enum.Font.GothamMedium
	sub.Text = "Empty"
	sub.TextColor3 = Color3.fromRGB(210, 220, 232)
	sub.TextScaled = true
	sub.Parent = gui

	model.Parent = workspace

	--[[
		Named, because the client has to find it.

		Spawning is a CHOICE now -- see the picker below -- and the panel that offers
		it is opened client-side off this prompt's own Triggered, exactly the way the
		showroom counters open the buy screen. That needs no remote at all: a
		ProximityPrompt fires Triggered on the triggering client as well as here.
	]]
	local spawnPrompt = prompt(head, "Spawn Rig", "Rig Bay", 12, 0.2)
	spawnPrompt.Name = "RigBayPrompt"
	local storePrompt = prompt(head, "Store Rig", "Rig Bay", 12, 0.4)
	storePrompt.Name = "RigStorePrompt"

	--[[
		Both prompts stay enabled, because they mean different things to different
		people: with a rig each, the bay being occupied says nothing about whether
		YOUR truck is in it. The console reads out how full the bay is and the
		prompts sort out whose is whose when they fire.

		That is what this comment always said. What the code did was
		`storePrompt.Enabled = false` on the line above, and nothing ever set it
		back -- so Store Rig has never once been usable. A rig could be called up and
		then never put away. Deleting that line is the whole fix.

		WHETHER Store is on screen is decided per player, in SealerUIClient: it shows
		only while that player has a truck out. It cannot be decided here -- the
		prompt is one shared instance and the answer differs for every player in the
		bay. Left enabled on the server so the client's rule fails OPEN: a player
		whose shell did not mount gets a usable key rather than a truck they can never
		put away, which is the bug this whole block exists to have fixed.

		And a key of its own, because the two prompts share a part: Roblox shows one
		prompt per key per part, so with both on E the second stayed unreachable even
		once it was enabled.

		Sharing a part costs one more thing, which UIOffset pays. Both prompts draw
		centred on the SAME point, so with both visible the two labels printed on top
		of each other and neither could be read. The offsets stack them either side of
		that point -- spawn above, store below, matching the order the player does
		them in.

		PIXELS, not studs, and that is the reason this is not solved by hanging the
		second prompt on the post below instead. A prompt's UI is a fixed pixel size
		whatever the distance, so world separation shrinks on screen as you back away
		and the two would collide again at the far edge of the twelve studs. A pixel
		offset holds its gap everywhere in range.

		55 rather than the 34 tried first: the default prompt draws its ActionText
		and its ObjectText on two lines, which is taller than 68px of separation could
		clear. The store prompt drops the object line as well -- "Rig Bay" printed
		twice, once under each key, is the same words taking the room that was the
		problem.
	]]
	storePrompt.KeyboardKeyCode = Enum.KeyCode.X
	storePrompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	storePrompt.ObjectText = ""
	spawnPrompt.UIOffset = Vector2.new(0, -55)
	storePrompt.UIOffset = Vector2.new(0, 55)
	local function refresh()
		local n = 0
		for _ in pairs(fleet) do n += 1 end
		sub.Text = if n == 0 then "Empty"
			elseif n == 1 then "1 rig in bay"
			else ("%d rigs in bay"):format(n)
	end

	--[[
		The prompt no longer spawns anything, and that is the change.

		It used to call up Rigs.chosen outright, which is "whichever one you bought
		most recently" -- so a player who owned three trucks could reach exactly one
		of them from the bay, and the only way to drive a different one was to go and
		buy something. The choice was always in the data (RigChoice has existed all
		along); there was simply nowhere to make it.

		The picker on the client is that place, and SpawnRig below is the one road
		from it into the bay. There is deliberately NO Triggered handler here at all:
		a second way to put a truck in the bay is a second thing to keep in step with
		the ownership checks, and the showroom counters already prove the pattern --
		the prompt opens a screen, the screen is the only thing that acts.
	]]

	storePrompt.Triggered:Connect(function(plr)
		if not fleet[plr] then
			notify(plr, false, "You have no rig in the bay")
			return
		end
		storeRig(plr)
		refresh()
		notify(plr, true, "Rig stored")
	end)

	refresh()
	return refresh
end

local refreshSpawner = buildSpawner()

--==[ DEALERSHIP ]============================================================

--[[
	The showroom, on the grass west of the depot garage.

	It is an AUTHORED building now, saved in the place beside the depot and the
	houses, and this function's whole job is to leave it alone. What follows is the
	fallback for a place that has lost it, and the marker that tells the two apart.

	The fallback is still placed relative to the garage floor rather than at
	written-down coordinates, so the two buildings stay a short walk apart if either
	is ever moved. It is NOT rotated, and that matters: the showroom's frontage is
	local -Z, the same way the garage's roll door faces, so both shopfronts front
	the same yard with no turn at all -- and both halves of the purchase gate
	measure the slab in its own object space, so a turned model silently swaps which
	of its axes is 68 studs and which is 92. The old building carried a quarter turn
	because its frontage was local +X; this one must never.

	The prompts inside sell nothing themselves -- UpgradeService already owns cash,
	the zone check and the save file -- they open the buy screen on the browser's
	own client, which SealerUIClient picks up from the same event.

	--[ why there is a marker ]----------------------------------------------

	Whether this showroom is ours or somebody's used to be answered from the name,
	and it was answered wrongly in both directions. Originally the function skipped
	when it found an existing RigDealership -- and a copy of the building from
	before the frontage was rotated had been saved into the place, so the guard
	found it, returned, and the corrected code never ran. The fix at the time was to
	destroy anything called RigDealership on sight, on the grounds that "a building
	that is generated has to be generated".

	Both are the same mistake: inferring PROVENANCE FROM A NAME. A rule that deletes
	anything under this name deletes exactly the authored building this is now.

	So generated output is marked as generated, and only that is ever thrown away.
	An unmarked model is somebody's work and is adopted untouched: not re-pivoted,
	not re-grounded, not rebuilt. Its saved CFrame is the truth.
]]
local GENERATED_TAG = "Generated"

--[[
	Both halves of the purchase gate FAIL OPEN.

	UpgradeService.zoneFloor and Shell.atDealership each look for a BasePart named
	Floor directly under the model, and each treats "no such part" as "never lock
	anyone out" -- so a showroom missing its slab does not error, it quietly makes
	every rig buyable from anywhere on the map. That is the one failure here worth
	shouting about, because nothing else ever would.
]]
local function validate(hall: Instance): string?
	local floor = hall:FindFirstChild("Floor")
	if not (floor and floor:IsA("BasePart")) then
		return "no BasePart named Floor as a direct child -- the purchase zone would"
			.. " fail open and rigs would sell from anywhere on the map"
	end
	local prompts = 0
	for _, d in ipairs(hall:GetDescendants()) do
		if d:IsA("ProximityPrompt") and string.find(d.Name, "DealershipPrompt", 1, true) then
			prompts += 1
		end
	end
	if prompts == 0 then
		return "no prompt named DealershipPrompt -- nothing in the building opens the"
			.. " buy screen"
	end
	return nil
end

local function buildDealership()
	local existing = workspace:FindFirstChild("RigDealership")
	if existing and not existing:GetAttribute(GENERATED_TAG) then
		local why = validate(existing)
		if not why then return end   -- authored and sound: leave it entirely alone
		warn("[TruckServer] the saved RigDealership is unusable (" .. why
			.. ") -- generating a replacement over it")
	end
	if existing then existing:Destroy() end

	local g = Depot.garage()
	local shell = g and g:FindFirstChild("Shell")
	local floor = shell and shell:FindFirstChild("Floor")
	-- The builder's datum is the centre of its own site pad: x clear of the
	-- garage's west wall with a forecourt's worth of ground between, z set so the
	-- two frontages sit on the same line.
	local at = if floor and floor:IsA("BasePart")
		then (floor :: BasePart).Position + Vector3.new(-74, 0, -6.5)
		else Vector3.new(-74, 0, 210)

	local probe = workspace:Raycast(at + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0))
	local groundY = if probe then probe.Position.Y else 0
	local made = DealershipBuilder.build(CFrame.new(at.X, groundY, at.Z), workspace)
	made:SetAttribute(GENERATED_TAG, true)
end

buildDealership()

--==[ DELIVERY ]==============================================================

--[[
	Buying the rig delivers it.

	The bay console is still there to store it and call it back, but making a
	five-million-dollar purchase and then being sent to find a second prompt
	before anything happens is not a purchase, it is paperwork.

	Watched on the ownership attribute rather than hooked into the shop's buy
	handler, so it fires however the rig comes to be owned -- bought at the
	counter, restored from a save on join, or granted by hand -- and TruckServer
	still knows nothing about how the shop works.
]]
local function deliver(plr: Player, choice: Rigs.Rig)
	plr:SetAttribute("RigChoice", choice.id)
	if fleet[plr] then
		-- they already have one out; swapping it now would yank a truck out from
		-- under a driver, so the new one waits for them to store the old
		notify(plr, true, choice.name .. " is yours -- store your rig to call it up")
		return
	end
	if not spawnRig(plr, choice) then
		notify(plr, true, choice.name .. " is yours -- call it up when you have room for it")
		return
	end
	if refreshSpawner then refreshSpawner() end
	notify(plr, true, choice.name .. " delivered -- it is waiting in the bay")
end

local function watchOwnership(plr: Player)
	-- one watcher per rig, since each is its own unlock track. Rigs.All, not
	-- Rigs.List: the pass truck is unlocked by writing the same attribute, and
	-- without a watcher on it that write would never bring the truck round.
	for _, r in ipairs(Rigs.All) do
		plr:GetAttributeChangedSignal("Upg_" .. r.id):Connect(function()
			if not Rigs.owns(plr, r.id) then return end
			deliver(plr, r)
		end)
	end
end

--[[
	The Starter Rig pass, cashed in for an ordinary unlock.

	This is the whole of that pass on the server, and it is deliberately three
	lines of consequence: write the same attribute buying the truck would have
	written. Everything else in the game then behaves as though it had been bought
	-- the delivery watcher above fires and brings it round, the showroom stops
	offering to sell it, the picker lists it, and the profile saves it with the
	other unlock tracks. No second notion of ownership exists to be kept in step.

	Run on the attribute rather than once at join because PassService answers a
	second or two in, and a purchase mid-session takes the same path.

	Never written back to false. The pass says "forever", and a refund taking the
	truck away is the case the wording exists to rule out; the grant is also long
	since on disk by then. It is also the reason this only ever raises the level:
	somebody who bought the Dart with cash and then bought the pass must not have
	anything undone by it.
]]
local function watchStarterPass(plr: Player)
	local attr = Passes.attrName("PermanentRig")
	local function apply()
		if not Passes.owns(plr, "PermanentRig") then return end
		local rig = Rigs.cheapest()
		if Rigs.owns(plr, rig.id) then return end
		plr:SetAttribute("Upg_" .. rig.id, 2)
	end
	plr:GetAttributeChangedSignal(attr):Connect(apply)
	apply()
end

--[[
	The Cyberseal pass, cashed in the same way and for the same reasons.

	Deliberately the same shape as watchStarterPass above -- read that note, all
	of it applies here: run off the attribute because PassService answers a second
	or two in, only ever raise the level, never write it back to false.

	The one difference is which truck: Starter Rig asks Rigs.cheapest because it
	sells "the cheapest truck in the yard" and that answer has to follow the
	ladder. This pass sells one named truck, so it names it -- and if that rig is
	missing from the catalogue the pass grants nothing rather than erroring, which
	is the same shape as an assetId left at 0.
]]
local function watchCyberPass(plr: Player)
	local rig = Rigs.ById.Cyberseal
	if not rig or not rig.pass then return end
	local attr = Passes.attrName(rig.pass)
	local function apply()
		if not Passes.owns(plr, rig.pass :: string) then return end
		if Rigs.owns(plr, rig.id) then return end
		plr:SetAttribute("Upg_" .. rig.id, 2)
	end
	plr:GetAttributeChangedSignal(attr):Connect(apply)
	apply()
end

local function watchPlayer(plr: Player)
	watchOwnership(plr)
	watchStarterPass(plr)
	watchCyberPass(plr)
end

--[[
	The Cyberseal on the dealership forecourt.

	Authored and adopted, the arrangement the showroom, the VIP stand and the AFK
	yard already use: the model is saved into the place so it can be seen and
	edited in Studio like the rest of the world, and CyberStandBuilder is both the
	recipe it was made from and the fallback for a place that has lost it.

	Nothing here dresses it. The price and the owned state are facts about one
	player, so CyberStandClient writes both on that player's own screen -- a
	server that wrote them would be showing the first buyer's answer to the whole
	lobby.

	It lives in this file rather than in a service of its own for the reason
	VipService gives about its own stand: a second server script whose entire job
	is one FindFirstChild is a file nobody remembers exists, and everything else
	about that truck is already here.
]]
if not workspace:FindFirstChild(CyberStandBuilder.ModelName) then
	warn(("[TruckServer] no %s in Workspace -- building one from the recipe."
		.. " The saved model should be in the place; see CyberStandBuilder.")
		:format(CyberStandBuilder.ModelName))
	CyberStandBuilder.build(workspace)
end

Players.PlayerAdded:Connect(watchPlayer)
for _, plr in ipairs(Players:GetPlayers()) do watchPlayer(plr) end

--[[
	The picker's one road into the bay.

	Ownership is re-checked here and not merely trusted, for the ordinary reason:
	the client decides which BUTTON to draw, the server decides what a player
	actually has. A tampered client asking for a Cistern it never bought gets the
	same answer as a player who clicked a locked row.
]]
-- Created the same idempotent way BuyResult is above, and for the same reason:
-- which of the scripts touching this folder runs first is not guaranteed.
local SpawnRig = uiRemotes:FindFirstChild("SpawnRig") :: RemoteEvent?
if not SpawnRig then
	local r = Instance.new("RemoteEvent")
	r.Name = "SpawnRig"
	r.Parent = uiRemotes
	SpawnRig = r
end
assert(SpawnRig)

local StoreRig = uiRemotes:FindFirstChild("StoreRig") :: RemoteEvent?
if not StoreRig then
	local r = Instance.new("RemoteEvent")
	r.Name = "StoreRig"
	r.Parent = uiRemotes
	StoreRig = r
end
assert(StoreRig)

--[[
	Putting it away from the picker, which is where the player already is.

	The console's X prompt does the same job in one keypress; this exists because
	the picker is what you open when you want a DIFFERENT truck, and "store the one
	you have out" is the first half of that errand. Making them walk out of the
	panel to press X and then reopen it would be the panel sending them away to do
	something it is already showing them.

	No argument: you can only ever store your own, and you only have one out.
]]
--==[ TAKE ME TO THE DEALERSHIP ]============================================
--[[
	The picker lists trucks the player does not own yet and prices them "at the
	dealership", which is a signpost with no road attached: the showroom is the far
	side of the map and nothing in the panel would take you there.

	SERVER-SIDE, and that is not ceremony. The dealership streams -- a client stood
	in the neighbourhood may not have the model at all, so a client-side teleport
	would read the destination off an instance that is not there, and even if it
	were, moving a character into unstreamed ground drops them through the floor
	until it arrives. The server always holds the whole map and can ask for the
	region to be streamed in before it moves anybody.
]]
local GoDealership = uiRemotes:FindFirstChild("GoDealership") :: RemoteEvent?
if not GoDealership then
	local r = Instance.new("RemoteEvent")
	r.Name = "GoDealership"
	r.Parent = uiRemotes
	GoDealership = r
end
assert(GoDealership)

--[[
	Where to put them down, derived rather than written down.

	The mat is the threshold and the four totems are the middle of the showroom, so
	standing on one and facing the average of the others lands the player inside
	the door looking at the stock. Both are read from the model at call time, so
	moving or rebuilding the dealership moves this with it -- a pair of hardcoded
	coordinates is the thing that silently starts teleporting people into a wall.
]]
local function dealershipArrival(): CFrame?
	local shop = workspace:FindFirstChild("RigDealership")
	local mat = shop and shop:FindFirstChild("EntranceMat", true)
	if not (mat and mat:IsA("BasePart")) then return nil end

	local sum, n = Vector3.zero, 0
	for _, d in ipairs((shop :: Instance):GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name:find("DealershipPrompt")
			and d.Parent and d.Parent:IsA("BasePart") then
			sum += (d.Parent :: BasePart).Position
			n += 1
		end
	end

	local stand = mat.Position + Vector3.new(0, 3.5, 0)
	if n == 0 then return CFrame.new(stand) end
	local centre = sum / n
	return CFrame.lookAt(stand, Vector3.new(centre.X, stand.Y, centre.Z))
end

GoDealership.OnServerEvent:Connect(function(plr)
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 then return end

	local at = dealershipArrival()
	if not at then
		notify(plr, false, "The dealership is not loaded yet -- try again in a moment")
		return
	end

	--[[
		Out of the seat first, for the reason AfkService gives at its own teleport:
		PivotTo on a seated character fights the seat weld, and the loser is the
		TRUCK -- it ends up dragged across the map or left welded to a driver who is
		no longer anywhere near it.
	]]
	if hum.SeatPart then
		hum.Sit = false
		-- one frame for the weld to actually go before the move
		task.wait()
		if not (plr.Character == char and char.Parent) then return end
	end

	-- Ask for the ground to exist before standing on it; see the note above.
	pcall(function() plr:RequestStreamingAround(at.Position) end)
	char:PivotTo(at)
	notify(plr, true, "Welcome to the dealership")
end)

StoreRig.OnServerEvent:Connect(function(plr)
	if not fleet[plr] then
		notify(plr, false, "You have no rig in the bay")
		return
	end
	storeRig(plr)
	if refreshSpawner then refreshSpawner() end
	notify(plr, true, "Rig stored")
end)

SpawnRig.OnServerEvent:Connect(function(plr, rigId)
	if type(rigId) ~= "string" then return end
	local rig = Rigs.ById[rigId]
	if not rig then return end

	if not Rigs.owns(plr, rig.id) then
		notify(plr, false, "You do not own the " .. rig.name)
		return
	end
	if fleet[plr] then
		notify(plr, false, "Store the rig you have out first")
		return
	end

	-- Remembered before the spawn can fail, so a bay that was full still leaves
	-- the picker showing what they asked for next time they open it.
	plr:SetAttribute("RigChoice", rig.id)
	if not spawnRig(plr, rig) then
		notify(plr, false, "No room to drop your rig here -- move somewhere more open")
		return
	end
	if refreshSpawner then refreshSpawner() end
	notify(plr, true, rig.name .. " brought round to the bay")
end)

--==[ TANK ]==================================================================

--[[
	What the nozzle can physically flow, plus half again. Past that a client is
	reporting nonsense and it is dropped.

	Computed per player rather than fixed at Config.WandRate, because the wand is
	driven by the Pour Speed track AND the truck's own pump -- together nearly
	twenty times the base rate at the top of the ladder. Left as a constant this
	clamp silently throttled the tank draw instead of the tank, so a fully
	upgraded rig quietly poured several times what it was ever billed for.
]]
local function maxDrawFor(plr: Player, e: Fleet): number
	local pour = Upgrades.valueAt("Pour", (plr:GetAttribute("Upg_Pour") :: number?) or 1)
	local pump = (e.model:GetAttribute("Pump") :: number?) or 1
	return Config.WandRate * pour * pump * 1.5
end

--[[
	And the same ceiling for the OTHER outlet, which rides neither track.

	The spray bar is metered per stud, so its plausible maximum is its own cap --
	and that cap rides the RIG'S PUMP (softened by Config.TruckPourPumpShare), so
	this has to ride it too. It is not a function of the player's upgrade tracks the
	way the wand's is; it is a fact about the truck. Left flat here, a Cistern's
	legitimate pour would have been clamped back to a Dart's and the difference
	billed to nobody -- the client lays what Config tells it to and the tank is
	debited for part of it, which is free sealer and exactly the bug the note over
	maxDrawFor describes.

	It needs its own figure rather than sharing the wand's: at the bottom of the ladder the wand's is 156 a second and the bar can
	legitimately lay 460, so a bar billed against the wand's clamp would have had
	its DRAW throttled while the pour went on at full rate -- the client lays what
	Config tells it to, the tank is debited for part of it, and the difference is
	free sealer. That is the exact bug the note over maxDrawFor describes, one
	outlet later.

	Taking the max of the two would have fixed that too, and was what this did
	first. It is worse: it hands the WAND the bar's much looser bound at the bottom
	of the ladder, for no reason other than that the two share a reporting remote.
	Which outlet is running is knowable -- the wand is held and the bar is driven --
	so it is answered rather than guessed.
]]
local function maxTruckPour(e: Fleet): number
	local pump = (e.model:GetAttribute("Pump") :: number?) or 1
	return Config.TruckPourMaxRate
		* (1 + (pump - 1) * Config.TruckPourPumpShare) * 1.5
end
local lastDraw: { [Player]: number } = {}

TruckControl.OnServerEvent:Connect(function(plr, action, amount)
	if action == "draw" then
		if type(amount) ~= "number" or amount ~= amount or amount <= 0 then return end
		--[[
			Whichever rig they have the wand off, which need not be their own -- OR, for
			a driver, the one they are sitting in.

			The second half is what bills the spray bar, and without it the bar was a
			free pour: the client laid sealer and reported the draw exactly as the wand
			does, and every one of those reports was dropped on the floor here, because
			a player in a cab holds no wand and rigHeldBy alone answers nil for them. The
			tank sat at full through a driveway's worth of pouring.

			Wand first, so nothing about the existing path changes: the two cannot both
			be true at once anyway, since climbing in stows the wand.
		]]
		local e, viaWand = rigHeldBy(plr), true
		if not e then
			e, viaWand = rigDrivenBy(plr), false
		end
		if not e then return end

		local now = os.clock()
		local since = now - (lastDraw[plr] or now)
		lastDraw[plr] = now
		-- small absolute grace for the first report of a burst, in the same
		-- square-stud units as everything else. Which outlet this draw came out of
		-- decides the ceiling; see maxTruckPour for why they are not pooled.
		local rate = if viaWand then maxDrawFor(plr, e) else maxTruckPour(e)
		local allowed = rate * math.min(since, 0.5) + 5

		local tank = (e.model:GetAttribute("Tank") :: number?) or 0
		local left = math.max(0, tank - math.min(amount, allowed))
		e.model:SetAttribute("Tank", left)
		-- A dry drum shuts its own valve. The client stops pouring on an empty tank
		-- by itself, but the SWITCH has to come back up too, or the driver reaches the
		-- pump, fills, and the bar starts again under a truck nobody asked to pour.
		if left <= 0 and e.model:GetAttribute("Pouring") == true then
			e.model:SetAttribute("Pouring", false)
		end
	elseif action == "pour" then
		--[[
			The spray bar's valve, and it is sold -- see Passes.TruckPour.

			The gate is HERE and not only in the button, for exactly the reason written
			over the blade below: `Pouring` is an attribute every client reads to draw
			the stream, so the one place the pass can actually be enforced is the one
			place allowed to move it. A check in the UI alone would be a pass anybody
			could skip with one line.

			The pass is asked BEFORE the drum, and the order matters to the message: a
			non-owner sitting in a dry truck should be told what to buy, not sent to the
			pump to fill a tank they still will not be able to pour out. The button's
			own four-state draw resolves the same way and for the same reason.

			Whoever is IN the seat, exactly as the blade resolves it.
		]]
		local e = rigDrivenBy(plr)
		if not e then return end
		if not Passes.owns(plr, "TruckPour") then
			notify(plr, false, "The Spray Bar pass opens the valve on your rig")
			return
		end
		local want = amount == true
		if want and ((e.model:GetAttribute("Tank") :: number?) or 0) <= 0 then
			notify(plr, false, "The drum is empty -- fill up at the depot pump")
			return
		end
		e.model:SetAttribute("Pouring", want)
	elseif action == "blade" then
		--[[
			The game-pass gate, and it lives here rather than in the UI.

			The blade's state is an attribute on the rig model, because every client
			has to draw it -- so the only place the pass can actually be enforced is
			the one place allowed to move that attribute. A check in the button would
			be a pass anybody could skip with one line.

			Whoever is IN the seat, which since the cab became owner-only is the same
			person as the owner. Left as it was rather than switched to a fleet lookup:
			the pass is a fact about the driver and reading it off the driver keeps it
			true however the seating rule changes again.
		]]
		local e = rigDrivenBy(plr)
		if not e then return end
		if not Passes.owns(plr, "TruckBlade") then
			notify(plr, false, "The Truck Squeegee pass fits that bar to your rig")
			return
		end
		e.model:SetAttribute("BladeDown", amount == true)
	elseif action == "stow" then
		local e = rigHeldBy(plr)
		if e then stowWand(e) end
	elseif action == "spawn" then
		-- "Call Up" on an owned rig in the buy screen. Ownership is checked here,
		-- not there: the panel only decides which button to draw.
		if type(amount) ~= "string" then return end
		local choice = Rigs.ById[amount]
		if not choice or not Rigs.owns(plr, choice.id) then return end
		plr:SetAttribute("RigChoice", choice.id)
		-- Calling up a different rig swaps it, rather than refusing: the panel's
		-- whole job is picking which of your trucks is out, and making the player
		-- walk to the bay console to store one first is paperwork for its own sake.
		if fleet[plr] and fleet[plr].seat.Occupant then
			notify(plr, false, "Get out of the cab first")
			return
		end
		if not spawnRig(plr, choice) then
			notify(plr, false, "No room to drop your rig here -- move somewhere more open")
			return
		end
		if refreshSpawner then refreshSpawner() end
		notify(plr, true, choice.name .. " brought round to the bay")
	end
end)

Players.PlayerRemoving:Connect(function(plr)
	lastDraw[plr] = nil
	-- they may have been working someone else's truck
	local held = rigHeldBy(plr)
	if held then setHolder(held, nil) end
	-- The bay is a shared resource, and a rig belonging to someone who has left
	-- would otherwise sit in a slot blocking everyone else's.
	storeRig(plr)
	if refreshSpawner then refreshSpawner() end
end)

Players.PlayerAdded:Connect(function(plr)
	-- Dying drops the wand back onto the reel; the tool dies with the character.
	plr.CharacterRemoving:Connect(function()
		local held = rigHeldBy(plr)
		if held then setHolder(held, nil) end
	end)
end)

--==[ THE PUMP ]=============================================================

--[[
	The nozzles on the fill pads, and the one thing in the world that puts sealer
	into anything.

	They are built here rather than with the rest of the bay because they are
	behaviour rather than scenery: the pipework is static geometry saved into the
	place, and this is the part of it that has to know who is holding it.

	Hung on the swing arm's nozzle where a bay has one, since that is the piece a
	player would actually reach for, and on whatever Depot hands back first where
	it does not. There is one prompt per bay and they are held in a set, because
	the handlers below arbitrate by identity and a single upvalue could only ever
	answer for the last bay built.
]]
local fillPrompts: { [ProximityPrompt]: boolean } = {}

--[[
	Every bay's prompt host, not just the first.

	There are two bays now -- the depot's and the deck park's -- and a player stood
	at one has to get the prompt that is in front of them. Hosting on each part
	named ArmNozzle does that without this file having to know how many bays exist
	or where they are; Depot.refuelPoints is the one thing that knows.
]]
local function nozzles(): { BasePart }
	local points = Depot.refuelPoints()
	local hosts: { BasePart } = {}
	for _, p in ipairs(points) do
		if p.Name == "ArmNozzle" then table.insert(hosts, p) end
	end
	if #hosts > 0 then return hosts end
	-- Depot returns the fill pad first, which is a fine thing to hang a prompt on
	-- for a bay that was laid out without an arm.
	return if points[1] then { points[1] } else {}
end

local function equip(host: BasePart)
	for existing in pairs(fillPrompts) do
		if existing.Parent == host then return end
	end
	-- Anything already there is stale by definition: this prompt is made at
	-- runtime, so one saved into the place is a leftover from a session that got
	-- committed -- and it answers to nothing, since the handlers below only know
	-- the instance made here.
	for _, stale in ipairs(host:GetChildren()) do
		if stale:IsA("ProximityPrompt") and stale.Name == "FillPrompt" then
			stale:Destroy()
		end
	end

	local p = prompt(host, "Fill Up", "Sealer Pump", Config.FillReach, Config.FillGrab)
	p.Name = "FillPrompt"
	--[[
		E, the key everyone already reaches for, and the default this inherits.

		The rig parks with its tail beside this pad and brings the wand and reel
		prompts with it, so there are three E prompts within a few strides of each
		other -- which is survivable only because Exclusivity is OnePerButton and
		prompts arbitrate by distance: whichever you are stood closest to is the
		one on screen and the one E answers. Walk to the nozzle and the reel hands
		over. Anything that breaks that -- a second prompt on this same part, or a
		reach loose enough to overlap the parked rig's -- puts the player back to
		guessing, and the key would have to move.
	]]
	p.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	-- What the client half matches on. It cannot hold the instance -- the prompt
	-- is made here -- and matching on a name alone would catch any prompt that
	-- ever shared it.
	p:SetAttribute("DepotFill", true)
	fillPrompts[p] = true
end
CollectionService:GetInstanceAddedSignal(Depot.RefuelTag):Connect(function(part)
	if part:IsA("BasePart") and part.Name=="ArmNozzle" then
		task.defer(function()
			for prompt in pairs(fillPrompts) do if prompt.Parent==part then return end end
			if part:IsDescendantOf(workspace) then equip(part) end
		end)
	end
end)

-- Spawned rather than run inline, and patient about it. The bays are static
-- geometry saved into the place, so this finds them on the first pass every
-- ordinary start -- but warning instantly would make any place that builds or
-- streams a bay a little later look permanently broken, and a rig that cannot
-- be filled is not a failure worth guessing at.
task.spawn(function()
	local hosts = nozzles()
	local waited = 0
	while #hosts == 0 and waited < 10 do
		task.wait(0.25)
		waited += 0.25
		hosts = nozzles()
	end

	if #hosts == 0 then
		warn("[TruckServer] No refuel bay anywhere in the map -- nothing can be filled.")
		return
	end
	for _, host in ipairs(hosts) do
		equip(host)
	end
end)

--[[
	Who has the nozzle open right now.

	PromptTriggered and PromptTriggerEnded both fire on the server, so the hold
	needs no remote of its own: the button is a server-owned instance and the
	server is told directly when it goes down and when it comes up. The client
	listens to the same two signals for its own half (the pail), which is why the
	two halves cannot drift apart -- they are reading one event, not two.
]]
local filling: { [Player]: boolean } = {}

-- Still stood at the pump. The prompt stops the fill STARTING out of reach;
-- this is what stops one CONTINUING when the player walks off mid-hold, which
-- the prompt does not reliably report.
local function atPump(plr: Player): boolean
	local ch = plr.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return false end
	local d = Depot.distanceToRefuel(hrp.Position)
	-- nil is "this place has no refuel bay", which is a reason to let everyone
	-- fill rather than to lock everyone out; Depot's own note says the same
	return d == nil or d <= Config.FillReach + Config.FillLeash
end

--[[
	Whether this player's rig is backed onto the pad, and how big its drum is.

	Measured from the pump end of the truck rather than its middle, so backing
	onto the fill pad works and parking nose-in does not, and to the tanks'
	surfaces rather than their centres -- they are eleven studs across, and centre
	distance would have you refuelling from inside one.
]]
local function rigAtPad(plr: Player): (Fleet?, number)
	local e = fleet[plr]
	if not e or not e.base.Parent then return nil, 0 end
	local rear = e.base.CFrame * CFrame.new(0, 0, Config.TruckLength * 0.45)
	local distance = Depot.distanceToRefuel(rear.Position)
	if distance and distance >= Config.TankRefillRadius then return nil, 0 end
	local capacity = (e.model:GetAttribute("TankCapacity") :: number?)
		or ((e.model:GetAttribute("TankBase") :: number?) or Config.TankCapacity)
	return e, capacity
end

-- What the Instant Fill pass buys: the whole drum, on the touch of the nozzle.
-- The pail half of the same purchase happens on the client, off the same event.
local function fillNow(plr: Player)
	local e, capacity = rigAtPad(plr)
	if not e then return end
	e.model:SetAttribute("Tank", capacity)
end

ProximityPromptService.PromptTriggered:Connect(function(p, plr)
	if not fillPrompts[p] then return end
	if Passes.owns(plr, "InstantFill") then
		fillNow(plr)
		return
	end
	filling[plr] = true
end)

-- Fires when the button comes back up after a trigger. The distance check in
-- the loop below is the backstop for every other way a hold can end -- dying,
-- walking out of range, the rig being stored underneath them.
ProximityPromptService.PromptTriggerEnded:Connect(function(p, plr)
	if not fillPrompts[p] then return end
	filling[plr] = nil
end)

-- Its own handler rather than a line in the one further up: that one is written
-- before this table exists, and a player who drops with the nozzle open would
-- otherwise leave a true behind under a Player that has gone.
Players.PlayerRemoving:Connect(function(plr)
	filling[plr] = nil
end)

--[[
	And the fill itself, which had never been written.

	Everything around this existed and worked: the nozzle prompt, the hold, the
	leash, the pad radius, the Instant Fill pass, and on the client a drum bar, a
	"FILLING PAIL + DRUM" caption and a hint that tells you to back the rig up.
	The one thing missing was the loop in the middle -- `filling` was written and
	never read, `Config.TankRefill` was referenced by two comments and no code, and
	`Refilling` was read by RigController and set by nobody.

	So holding the nozzle filled the pail, the drum bar never appeared however the
	truck was parked, the hint said "back the rig up to the pump" to players who
	already had, and the tank never gained a drop. Without the Instant Fill pass
	the only way to get sealer back into a rig was to store it and call it up
	again, which is a bug players quite reasonably read as there being no way to
	refuel at all. The note over Config.TankRefillRadius records an earlier pass at
	the same complaint -- the radius was widened from 9 to 16 because "players read
	that as refuelling being broken, and they were not wrong about the outcome".
	They were right for a second reason nobody had found.

	The rig's own Pump multiplier is applied here, which is what the note over
	Config.TankRefill means by the bigger drums buying their fill time back: a
	Cistern holds far more than a base rig and would otherwise sit at the nozzle
	proportionally longer for it. The player's Refill Speed track is applied on
	top of it, for the reason written where it is read.
]]
--[[
	Whether each rig is close enough to the pump to take a fill, published so the
	player can be told BEFORE they hold rather than only after.

	`Refilling` cannot answer this: it is only ever true once somebody already has
	the nozzle open, so the one thing it can never say is "you have parked in the
	wrong place" -- which is the mistake being made, and it was made minutes ago
	at the other end of the map. This is the same rigAtPad test, published whether
	or not anyone is filling.

	Throttled because it is the only part of the loop that costs anything: each
	call walks the garage for its refuel points and measures to every one of their
	surfaces. A parked truck does not move between frames and the hint it feeds is
	read at walking pace.
]]
local AT_PUMP_EVERY = 0.2
local atPumpClock = 0

RunService.Heartbeat:Connect(function(dt)
	atPumpClock += dt
	local publishAtPump = atPumpClock >= AT_PUMP_EVERY
	if publishAtPump then atPumpClock = 0 end

	--[[
		Two passes, and they are not interchangeable.

		Every rig has to be told each frame whether sealer is going into it, not just
		the ones being filled -- a player who walks away from the nozzle has to see
		the drum row go away, and that only happens if somebody clears the flag. So
		the attribute is written from the fleet, not from `filling`.
	]]
	for plr in pairs(filling) do
		-- The prompt stops a fill STARTING out of reach; this is what ends one that
		-- is already running when the player wanders off mid-hold.
		if not atPump(plr) then filling[plr] = nil end
	end

	for owner, e in pairs(fleet) do
		if e.model.Parent then
			local connected = false
			if filling[owner] then
				local atPad, capacity = rigAtPad(owner)
				if atPad then
					connected = true
					local tank = (e.model:GetAttribute("Tank") :: number?) or 0
					if tank < capacity then
						-- Whichever is faster: the flat rate the rig's pump earns, or a rate
						-- that empties the whole drum inside TankFillSeconds. The second is
						-- what stops the Tank upgrade track -- x40 on capacity -- turning a
						-- five-second stop into a three-minute one. See Config.TankFillSeconds.
						local pump = (e.model:GetAttribute("Pump") :: number?) or 1
						--[[
							And the Refill Speed track, which had never reached the drum.

							One pump on one pad fills both the pail and the rig off one held
							nozzle, and the track sold as "the pump at the bulk tanks moves
							quicker" only ever moved the pail: SealerUIClient divides the pail's
							fill TIME by it and nothing here read it at all. A player fourteen
							rungs up that ladder watched their bucket snap full in 0.65 s while
							standing on the same trigger for the same drum as everyone else.

							That was survivable while a rig filled in under two seconds, and it
							is not now that TankRefill makes the stop proportional to the drum:
							a longer fill has to be something the player can BUY OUT OF, or it
							is just a tax on owning the truck the game sold them.

							It multiplies the rate -- both halves of the max, so it divides the
							clock whichever one is governing -- exactly as it divides the pail's
							fill time. Level 1 is 1.0, so a player who has bought nothing sees
							precisely the figures in the note over Config.TankRefill.
						]]
						local refill = Upgrades.valueAt("Refill",
							(owner:GetAttribute("Upg_Refill") :: number?) or 1)
						local rate = math.max(Config.TankRefill * pump,
							capacity / Config.TankFillSeconds) * refill
						e.model:SetAttribute("Tank", math.min(capacity, tank + rate * dt))
					end
				end
			end
			--[[
				True while the nozzle is CONNECTED to this drum, which is deliberately
				not the same as "the number is still going up".

				The client draws the drum row off this, so tying it to the tank actually
				gaining would make the row vanish the instant it topped out -- the one
				moment the player is watching it, and it would read as the fill breaking
				right at the end rather than as it being done. A full bar that stays put
				says finished. What the flag still refuses is the case it was written
				for: a rig parked out of reach of the pad, where no bar should appear at
				all because nothing is connected to it.
			]]
			if ((e.model:GetAttribute("Refilling") :: boolean?) or false) ~= connected then
				e.model:SetAttribute("Refilling", connected)
			end

			if publishAtPump then
				-- connected already proves it, and costs nothing; only ask again when
				-- nobody is holding the nozzle on this rig
				local near = connected or (rigAtPad(owner) ~= nil)
				if ((e.model:GetAttribute("AtPump") :: boolean?) or false) ~= near then
					e.model:SetAttribute("AtPump", near)
				end
				-- and where it is standing, for the owner's own locator tag
				publishMarker(owner, e)
				-- and the anchored pieces come with it, or the server leaves the blade,
				-- the beacons and the drum standing in the bay; see syncDynamics
				syncDynamics(e)
			end
		end
	end
end)

--==[ PEOPLE PASS THROUGH RIGS ]==============================================

--[[
	Every character part goes into the rig-player collision group.

	The group and the two "do not collide" pairs are TruckBuilder's -- see
	PLAYER_GROUP there -- and registering them here as well means a character that
	spawns before anybody has called up a truck still lands in a group that exists.

	DescendantAdded as well as the initial sweep, because a character grows parts
	after it loads: accessories stream in, and a Tool parented into it brings its
	own Handle. One left in Default would go back to being shoved by a truck, which
	is the same failure mode the note on PLAYER_GROUP describes for the rig side.
]]
TruckBuilder.ensureCollisionGroups()

local function joinPlayerGroup(inst: Instance)
	if inst:IsA("BasePart") then
		inst.CollisionGroup = TruckBuilder.PlayerGroup
	end
end

local function watchCharacter(character: Model)
	for _, d in ipairs(character:GetDescendants()) do joinPlayerGroup(d) end
	joinPlayerGroup(character)
	character.DescendantAdded:Connect(joinPlayerGroup)
end

local function watchForRigs(plr: Player)
	if plr.Character then watchCharacter(plr.Character) end
	plr.CharacterAdded:Connect(watchCharacter)
end

Players.PlayerAdded:Connect(watchForRigs)
for _, plr in ipairs(Players:GetPlayers()) do watchForRigs(plr) end
