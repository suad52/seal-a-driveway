--!strict
--[[
	TruckBuilder -- the sealcoating rig, assembled from primitives.

	Local frame: -Z is forward, +X is the kerb side, and the origin sits on the
	ground under the middle of the chassis, so every offset below reads directly
	as a height above the tarmac.

	Only two things collide: the chassis box and the six wheels. Every panel,
	tank and fitting is massless and non-colliding cosmetics welded to the
	chassis. A work truck built as one clean collider plus wheels is enormously
	more stable than one assembled out of eighty colliding boxes, and nothing
	about the driving reads as different.

	Named parts the rest of the system looks for:
	  Base        -- the chassis, and the model's PrimaryPart
	  Seat        -- VehicleSeat; its Throttle/Steer drive the hubs
	  ReelOutlet  -- where the hose leaves the reel
	  WandDock    -- where the wand hangs when it is stowed
	  PumpPanel   -- host for the PTO prompt
	  ReelWrap    -- the coil, spun as hose pays in and out
	  Agitator    -- turns while the pump is engaged
	  GaugeNeedle -- tank-level needle on the rear panel
	  Beacon1/2   -- amber rotators on the cab roof
]]

local PhysicsService = game:GetService("PhysicsService")

local Config = require(script.Parent.Config)

local TruckBuilder = {}

--==[ COLLISION GROUPS ]======================================================

--[[
	The wheels live inside the body's collision volume and there is no way round
	it: the rear duals sit close to the centreline and the steer wheels tuck up
	under the wings, so any hull that covers the cab must overlap them. Parts
	joined by a constraint still collide with each other, so without this the
	hubs are simply jammed against the truck's own shell and the rig will not
	roll no matter how much torque you give it.

	Groups are far less fragile than trying to carve a body shape that clears
	six wheels. The duals are also excused from each other -- they sit a
	twentieth of a stud apart and would otherwise grind.

	And since every colliding part of every rig is in one of these two groups,
	the same switch is what makes TRUCKS PASS THROUGH EACH OTHER -- see the
	body-to-body line below.
]]
local BODY_GROUP = "SealRigBody"
local WHEEL_GROUP = "SealRigWheel"
--[[
	And a group for the people, so a rig cannot shove one.

	Players are in Default, and Default still collides with both rig groups -- so a
	truck pulling out of the bay bulldozed anybody stood in the lane, and a player
	walking into a parked one was stopped dead by an invisible five-tonne box. Two
	players cannot cooperate over a truck any more than they can over each other's
	sealer, so there is nothing to win by keeping the contact.

	The group also passes through ITSELF, so PEOPLE WALK THROUGH EACH OTHER
	(2026-08-12, owner's call). Nothing here is a fight over space: each player
	seals their own private copy of every driveway, so another character standing
	in a garage doorway, on the fill pad or across a slab you are squeegeeing is
	only ever an obstacle. Blocking it also let one player pin another against a
	truck, or ride a head to somewhere the map does not lead.

	It stays collidable with Default, so characters still stand on the ground and
	bump into walls exactly as before -- the ground and the scenery are Default,
	and only the pairs listed below are dropped.

	Seating is unaffected: TruckBuilder switches the seat's CanTouch off and the
	Drive ProximityPrompt calls Sit() directly, so getting in never depended on
	touching the truck in the first place.
]]
local PLAYER_GROUP = "SealRigPlayer"
--[[
	And one for the showroom exhibits, which are a different problem from either.

	An exhibit is built by this same builder, so it arrives wearing BODY_GROUP --
	which now passes through everything, and a customer could drive their truck
	clean through the display they came to look at. DealershipBuilder's answer was
	to put the two colliders back into Default, and that fixed the driving at the
	cost of the walking: Default collides with people, so the exhibits were the one
	kind of truck left in the place that could still body-block a player.

	A group of their own separates the two. It keeps every default -- solid against
	driveable rigs, solid against scenery -- and drops exactly one pair, itself
	against PLAYER_GROUP. A driven truck still stops at an exhibit; a person walks
	through it.
]]
local DISPLAY_GROUP = "SealRigDisplay"

TruckBuilder.BodyGroup = BODY_GROUP
TruckBuilder.WheelGroup = WHEEL_GROUP
TruckBuilder.PlayerGroup = PLAYER_GROUP
TruckBuilder.DisplayGroup = DISPLAY_GROUP

local function ensureCollisionGroups()
	for _, name in ipairs({ BODY_GROUP, WHEEL_GROUP, PLAYER_GROUP, DISPLAY_GROUP }) do
		-- registering an existing group throws, which is the normal case on a
		-- rebuild and is not worth distinguishing
		pcall(function() PhysicsService:RegisterCollisionGroup(name) end)
	end
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, WHEEL_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(WHEEL_GROUP, WHEEL_GROUP, false)
		--[[
			Rigs drive THROUGH each other (2026-08-09, owner's call).

			Every player has their own rig and two of them never have to cooperate, so
			truck-on-truck contact was never a driving hazard -- it was somebody else's
			five-tonne assembly wedged across the lane you are trying to leave by, or
			shunted out of the bay and left in the road. There is nothing to win by
			keeping it.

			What it does NOT fix is two rigs standing in the same place: they stop
			fighting and start interpenetrating instead, which still reads as a glitch.
			Keeping them apart is TruckServer's job -- see freeSlot, where a stale bay
			reservation was putting every player after the first one's truck on top of
			the others inside the garage.

			This works BECAUSE every colliding part on a rig carries one of these two
			groups -- base and hull, the wheels, and the seat. A new collider added
			to the truck and left in Default would quietly go back to blocking other
			trucks, so anything solid built here has to be given a group.

			The showroom exhibits are the deliberate exception: DealershipBuilder
			puts their two colliders back into Default so a driven rig still can't
			park inside a display truck.
		]]
		PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, BODY_GROUP, false)

		-- and rigs pass through PEOPLE; see PLAYER_GROUP above
		PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, BODY_GROUP, false)
		-- ...as do other people, which works only because TruckServer puts EVERY
		-- character part in this group, accessories and tool handles included --
		-- one left in Default is a body-block that no longer looks deliberate
		PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, PLAYER_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, WHEEL_GROUP, false)

		--[[
			And through the showroom exhibits, which are the only other truck in the
			place a person could walk into. This ONE pair is all that is switched off
			for them: DISPLAY_GROUP is left collidable with both rig groups, so a driven
			truck still cannot park inside a display, and with Default, so the exhibits
			go on being scenery to everything else. See DISPLAY_GROUP above.
		]]
		PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, DISPLAY_GROUP, false)
	end)
end

-- Exposed so TruckServer can register the groups at startup, before any rig has
-- been built: a character that spawns first still has to have somewhere to go.
TruckBuilder.ensureCollisionGroups = ensureCollisionGroups

--==[ PALETTE ]===============================================================

local CAB_WHITE  = Color3.fromRGB(240, 240, 238)
local TANK_BLACK = Color3.fromRGB(24, 24, 26)
local BODY_BLACK = Color3.fromRGB(31, 31, 34)
local STEEL      = Color3.fromRGB(120, 124, 130)
local DARK_STEEL = Color3.fromRGB(56, 58, 64)
local CHROME     = Color3.fromRGB(198, 202, 210)
local AMBER      = Color3.fromRGB(255, 176, 32)
local GLASS      = Color3.fromRGB(146, 172, 188)
local TIRE       = Color3.fromRGB(26, 26, 28)
local GRIME      = Color3.fromRGB(34, 32, 30)
local SAFETY_RED = Color3.fromRGB(188, 42, 38)

--[[
	The name down the side of the tank, and the only one anything asks for.

	A caller may override it through the livery's `brand` field, but nothing does:
	any player-authored text on a surface this public would have to go through
	TextService:FilterStringAsync -- an async call that can fail, on every rig
	spawn, for every player in the server.
]]
--[[
	How much taller the cab is than it was drawn.

	Measured, not guessed: a seated R15's head centre sits 3.02 studs above the
	seat surface and the top of the head 3.62, while the roof underside was only
	2.78 above it -- so every driver wore the roof as a hat, 0.83 studs of skull
	through the panel.

	The roof rises rather than the seat dropping, because the seat is already
	sitting on the cab floor and has nowhere to go. Everything at roof level moves
	by this, and the four things that have to REACH the roof -- the rear wall, the
	three pillars and the windscreen -- grow by it instead.

	Safe against the world: this puts the roof at 8.0 and the beacons at 8.6 above
	ground, and the tallest thing on the truck is still the agitator at 9.96, which
	is what actually decides whether a rig fits anywhere. The depot's own lintel is
	at 11.0.
]]
local CAB_LIFT = 1.3

--==[ WHERE THE DRIVER SITS ]=================================================
--[[
	Two answers, because a drawn cab and an imported one are not the same room.

	DRAWN CAB. The floor is at 3.10 and the seat stands on it, which is where the
	note over CAB_LIFT starts from: the roof was raised to clear the driver's head
	rather than the seat being dropped to duck under it, so this is simply the
	floor plus a cushion and everything above it was built to suit.

	IMPORTED SHELL. Nothing was built to suit -- the cabin is whatever the model
	came with -- and the Cyberseal's is a real-scale one, which an R15 does not
	fit inside standing on its floor. Measured on the shipping shell: the cabin
	roof underside runs 5.47 to 6.01 over the seat, and the shell's own interior
	floor is at about 3.6. A seated R15 stands 2.96 studs from the seat surface to
	the crown and reaches only 0.32 below it -- so on that floor the driver's head
	and shoulders came out through the roof and the glass, which is the bug this
	fixes: people reported sitting ON the window.

	So the shell's seat is sunk 1.2 studs BELOW its drawn-cab equivalent, to 2.15.
	That is chosen against both walls rather than eyeballed:

	  crown  2.40 + 2.96 = 5.36, under the 5.47 roof, so nothing breaks the roofline
	  heels  2.40 - 0.32 = 2.08, over the 1.07 underbody pan, so nothing hangs below
	  head   centre lands at 4.54, which is the middle of the side glass -- the
	         driver reads as a driver from outside rather than as an empty cab

	The legs end up below the modelled interior floor and inside the sills. That is
	invisible (the bodywork is opaque and the glass is nearly black) and it is the
	only way to spend the 1.15 studs the cabin is short by. The alternative was the
	head through the roof, which is visible from every angle.

	⚠ IT IS SIZED FOR A STOCK AVATAR. Roblox scales bodies from about 0.9 to 1.05
	of standard height, and a tall one puts its crown a few tenths into the roof
	PANEL -- inside opaque geometry, so still hidden. Anything taller than that,
	or a hat, comes through the roof and there is no seat height that prevents it:
	the cabin is smaller than the avatar. The dial if it ever needs one is the
	shell, not this number.
]]
local SEAT_DRAWN = Vector3.new(-1.5, 3.35, -5.1)
local SEAT_SHELL = Vector3.new(-1.5, 2.15, -3.6)

local BRAND = "SEALPRO"

--==[ PRIMITIVES ]============================================================

-- Everything cosmetic goes through here: no mass, no collision, no queries.
local function cosmetic(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	-- Enum.Material.Glass at full opacity just renders as a pale slab; the glazing
	-- only reads as glazing once there is something to see through.
	if material == Enum.Material.Glass then p.Transparency = 0.55 end
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

--[[
	`body` carries this rig's proportions -- barrel and reel -- so one builder
	makes three visibly different trucks. Rigs.body derives them from the same
	stats the shop draws its bars from, so a fat barrel always means a big tank.
]]
type Body = { tankDia: number, tankLen: number, reelDia: number, reelWidth: number }
-- `brand` rides on the context because the only thing that draws it is buildDeck,
-- four calls down from the caller who knows it.
type Ctx = { model: Model, base: Part, frame: CFrame, body: Body, brand: string }

-- Place a cosmetic in truck-local space and weld it to the chassis.
-- `cf` is relative to the ground-level origin described at the top.
local function add(ctx: Ctx, p: BasePart, cf: CFrame): BasePart
	p.CFrame = ctx.frame * cf
	p.Parent = ctx.model
	local w = Instance.new("WeldConstraint")
	w.Part0 = ctx.base
	w.Part1 = p
	w.Parent = p
	return p
end

local function box(ctx: Ctx, name, size, color, material, cf): BasePart
	return add(ctx, cosmetic(name, size, color, material), cf)
end

--[[
	Parts that have to turn -- the beacons, the agitator, the reel drum and the
	gauge needle -- cannot be welded, because a weld is exactly the thing that
	stops them moving relative to the chassis. They are anchored instead, and
	the client re-frames them off the chassis every tick.

	Each one carries the three numbers that takes: where it sits relative to the
	chassis, which axis it turns about, and the fixed rotation its own shape
	needs (a cylinder lying on its side, a needle offset from the dial centre).
]]
local function dynamic(ctx: Ctx, p: BasePart, pos: Vector3, spinAxis: Vector3, shape: CFrame): BasePart
	-- offsets are authored against the ground origin; the client works from the
	-- chassis, so rebase them here rather than at sixty hertz
	local baseHeight = (ctx.frame:Inverse() * ctx.base.CFrame).Position.Y
	local baseLocal = pos - Vector3.new(0, baseHeight, 0)
	p.Anchored = true
	p.CFrame = ctx.frame * CFrame.new(pos) * shape
	p:SetAttribute("RigPos", baseLocal)
	p:SetAttribute("RigRot", shape)
	p:SetAttribute("SpinAxis", spinAxis)
	p.Parent = ctx.model
	return p
end

-- Part.Shape = Cylinder always runs along the part's own X axis. These three
-- wrappers pick the rotation that points it down each truck axis, so callers
-- never have to remember which way a bare cylinder faces.
local function cylX(ctx: Ctx, name, len, dia, color, material, cf): BasePart
	local p = cosmetic(name, Vector3.new(len, dia, dia), color, material)
	p.Shape = Enum.PartType.Cylinder
	return add(ctx, p, cf)
end

local function cylY(ctx: Ctx, name, len, dia, color, material, cf): BasePart
	local p = cosmetic(name, Vector3.new(len, dia, dia), color, material)
	p.Shape = Enum.PartType.Cylinder
	return add(ctx, p, cf * CFrame.Angles(0, 0, math.rad(90)))
end

local function cylZ(ctx: Ctx, name, len, dia, color, material, cf): BasePart
	local p = cosmetic(name, Vector3.new(len, dia, dia), color, material)
	p.Shape = Enum.PartType.Cylinder
	return add(ctx, p, cf * CFrame.Angles(0, math.rad(90), 0))
end

--==[ SIGNAGE ]===============================================================

local function surface(host: BasePart, face: Enum.NormalId, pixelsPerStud: number): SurfaceGui
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pixelsPerStud
	g.LightInfluence = 1
	g.Parent = host
	return g
end

-- The checker band off the reference rig: two rows, alternating, drawn as GUI
-- cells rather than forty little parts.
local function checkerBand(parent: Instance, columns: number, height: number, y: number)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, height)
	holder.Position = UDim2.fromScale(0, y)
	holder.Parent = parent

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromScale(1 / columns, 0.5)
	grid.CellPadding = UDim2.fromScale(0, 0)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = holder

	for row = 0, 1 do
		for col = 0, columns - 1 do
			local cell = Instance.new("Frame")
			cell.LayoutOrder = row * columns + col
			cell.BorderSizePixel = 0
			cell.BackgroundColor3 = if (row + col) % 2 == 0 then Color3.new(1, 1, 1) else TANK_BLACK
			cell.BackgroundTransparency = if (row + col) % 2 == 0 then 0 else 1
			cell.Parent = holder
		end
	end
end

local function label(parent: Instance, str: string, size: UDim2, pos: UDim2, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = Enum.Font.GothamBold
	l.Text = str
	l.TextColor3 = color
	l.TextScaled = true
	l.Parent = parent
	return l
end

--==[ CAB ]===================================================================

--[ the front squeegee bar ]-------------------------------------------------
--[[
	Built on every truck, whether or not the driver owns the pass that lets it
	down. A pass nobody can see is a pass nobody buys, and a bar folded up on the
	bumper is the advertisement.

	Authored in the LOWERED pose, because that is the one that has to be right --
	the rubber has to meet the deck. Parked is this same assembly swung up about
	the hinge, so it cannot be wrong by construction.

	Every moving piece is `dynamic` with the SAME RigPos -- the hinge -- and its
	offset carried in the shape CFrame instead. That is what turns per-part spin
	into one assembly swinging about a shared pivot: the client re-frames each as
	base * hinge * rotation * shape, and a shared hinge with a per-part shape is
	exactly a hinge.

	Its own function rather than a block inside buildCab, because a rig built on
	an imported shell never calls buildCab -- and the Squeegee Attachment pass is
	sold once, for every truck. Left where it was, the one truck you cannot buy
	with cash would have been the one truck the pass did nothing on.

	It hangs off Config.TruckBladePivot, which is a point in front of the bumper
	rather than anything the bodywork owns, so it is the same bar in the same
	place whichever body is bolted on above it.
]]
local function buildBlade(ctx: Ctx)
	local pivot = Config.TruckBladePivot
	local reach, sink = Config.TruckBladeReach, Config.TruckBladeSink
	local bw = Config.TruckBladeWidth
	local arm = Vector3.new(0, -sink, -reach)
	local armRot = CFrame.lookAt(Vector3.zero, arm).Rotation

	local function swings(name: string, size: Vector3, colour: Color3,
		material: Enum.Material, shape: CFrame): BasePart
		-- the "Blade" prefix is load-bearing: RigController finds these by name
		return dynamic(ctx, cosmetic(name, size, colour, material),
			pivot, Vector3.xAxis, shape)
	end

	-- the mount stays with the truck; only what hangs off it swings
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "BladeMount", Vector3.new(0.55, 0.62, 0.62), DARK_STEEL,
			Enum.Material.Metal, CFrame.new(pivot + Vector3.new(s * (bw * 0.5 - 1.1), 0, 0.2)))
		swings("BladeArm", Vector3.new(0.34, 0.34, arm.Magnitude), DARK_STEEL,
			Enum.Material.Metal,
			CFrame.new(s * (bw * 0.5 - 1.1), -sink * 0.5, -reach * 0.5) * armRot)
	end

	swings("BladeBar", Vector3.new(bw, 0.44, 0.52), CHROME, Enum.Material.Metal,
		CFrame.new(0, -sink, -reach))
	-- the rubber itself, and the only part of this that touches the driveway
	swings("BladeRubber", Vector3.new(bw, 0.40, 0.30), BODY_BLACK,
		Enum.Material.SmoothPlastic, CFrame.new(0, -sink - 0.34, -reach - 0.04))
	-- a splash guard behind the rubber, so a lowered bar reads as a working tool
	-- rather than a bare girder
	swings("BladeSkirt", Vector3.new(bw - 0.6, 0.62, 0.10), DARK_STEEL,
		Enum.Material.SmoothPlastic, CFrame.new(0, -sink - 0.10, -reach + 0.34))
end

local function buildCab(ctx: Ctx)
	local W = Config.TruckWidth
	local half = W * 0.5

	-- bonnet and grille
	box(ctx, "Hood", Vector3.new(W - 0.7, 1.7, 3.6), CAB_WHITE, Enum.Material.SmoothPlastic,
		CFrame.new(0, 3.95, -8.9))
	box(ctx, "HoodLip", Vector3.new(W - 0.6, 0.28, 0.5), CAB_WHITE, Enum.Material.SmoothPlastic,
		CFrame.new(0, 4.72, -10.5))
	box(ctx, "Grille", Vector3.new(W - 1.4, 1.35, 0.35), DARK_STEEL, Enum.Material.DiamondPlate,
		CFrame.new(0, 3.55, -10.72))
	for i = 0, 2 do
		box(ctx, "GrilleBar", Vector3.new(W - 1.5, 0.16, 0.12), CHROME, Enum.Material.Metal,
			CFrame.new(0, 3.15 + i * 0.42, -10.9))
	end
	box(ctx, "FrontBumper", Vector3.new(W + 0.2, 0.95, 0.75), CHROME, Enum.Material.Metal,
		CFrame.new(0, 2.35, -11.0))

	buildBlade(ctx)

	--[[
		Lamp colours are DIM on purpose, and that is the whole fix for the truck
		glowing like a bonfire.

		Neon renders at its own colour with no shading, and this place runs
		Lighting.Brightness 2.6 with a Bloom threshold of 1.75 -- so a near-white
		neon lens (this was 248,246,226) sails past the threshold and blooms across
		the whole cab in daylight. A saturated, darker colour still reads as a lit
		lens from any distance and never trips the bloom.
	]]
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "Headlight", Vector3.new(1.5, 0.75, 0.22), Color3.fromRGB(206, 196, 150),
			Enum.Material.Neon, CFrame.new(s * 2.35, 3.55, -10.92))
		box(ctx, "MarkerLight", Vector3.new(0.5, 0.3, 0.18), Color3.fromRGB(214, 142, 24),
			Enum.Material.Neon, CFrame.new(s * 3.2, 4.35, -10.72))
	end

	--[[
		The cab is a shell, not a solid block: floor, rear wall, roof, pillars and
		waist-high side panels. Leaving the window apertures genuinely open is what
		lets a player click the seat inside, and it also lets the driver be seen.
	]]
	box(ctx, "CabFloor", Vector3.new(W - 0.7, 0.3, 4.4), BODY_BLACK, Enum.Material.SmoothPlastic,
		CFrame.new(0, 2.9, -5.4))
	-- grows upward from a fixed sill: height gains the lift, centre gains half of it
	box(ctx, "CabRear", Vector3.new(W - 0.7, 3.3 + CAB_LIFT, 0.3), CAB_WHITE, Enum.Material.SmoothPlastic,
		CFrame.new(0, 4.75 + CAB_LIFT * 0.5, -3.35))
	box(ctx, "CabRoof", Vector3.new(W - 0.6, 0.34, 4.7), CAB_WHITE, Enum.Material.SmoothPlastic,
		CFrame.new(0, 6.55 + CAB_LIFT, -5.4))
	box(ctx, "RoofDrip", Vector3.new(W - 0.5, 0.14, 4.8), CAB_WHITE, Enum.Material.SmoothPlastic,
		CFrame.new(0, 6.4 + CAB_LIFT, -5.4))
	-- the back window grows with the wall it sits in rather than floating up it
	box(ctx, "RearGlass", Vector3.new(W - 2.0, 1.7 + CAB_LIFT, 0.14), GLASS, Enum.Material.Glass,
		CFrame.new(0, 5.5 + CAB_LIFT * 0.5, -3.35))

	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "CabSide", Vector3.new(0.3, 1.5, 4.4), CAB_WHITE, Enum.Material.SmoothPlastic,
			CFrame.new(s * (half - 0.35), 3.85, -5.4))
		box(ctx, "DoorSeam", Vector3.new(0.12, 1.4, 0.09), DARK_STEEL, Enum.Material.SmoothPlastic,
			CFrame.new(s * (half - 0.19), 3.9, -6.1))
		box(ctx, "DoorHandle", Vector3.new(0.16, 0.14, 0.6), CHROME, Enum.Material.Metal,
			CFrame.new(s * (half - 0.17), 4.3, -5.0))
		-- Window frame around an aperture that is left genuinely open, so the seat
		-- inside stays clickable and the driver is visible at the wheel.
		-- the three pillars stand on the same sill and stretch to the new roof
		box(ctx, "PillarA", Vector3.new(0.3, 2.2 + CAB_LIFT, 0.3), CAB_WHITE, Enum.Material.SmoothPlastic,
			CFrame.new(s * (half - 0.35), 5.45 + CAB_LIFT * 0.5, -7.45))
		box(ctx, "PillarB", Vector3.new(0.3, 2.2 + CAB_LIFT, 0.3), CAB_WHITE, Enum.Material.SmoothPlastic,
			CFrame.new(s * (half - 0.35), 5.45 + CAB_LIFT * 0.5, -3.45))
		box(ctx, "PillarMid", Vector3.new(0.26, 2.2 + CAB_LIFT, 0.26), CAB_WHITE, Enum.Material.SmoothPlastic,
			CFrame.new(s * (half - 0.35), 5.45 + CAB_LIFT * 0.5, -5.45))
		-- mirror on a stalk; rides up with the glasshouse so it stays by the window
		box(ctx, "MirrorArm", Vector3.new(0.75, 0.1, 0.1), DARK_STEEL, Enum.Material.Metal,
			CFrame.new(s * (half + 0.2), 5.6 + CAB_LIFT * 0.5, -7.3))
		-- deliberately Metal, not Glass: a wing mirror is a mirror, not a window
		box(ctx, "MirrorGlass", Vector3.new(0.12, 1.3, 0.55), Color3.fromRGB(178, 196, 208),
			Enum.Material.Metal, CFrame.new(s * (half + 0.55), 5.45 + CAB_LIFT * 0.5, -7.3))
		-- front wing over the steer wheel
		box(ctx, "FrontWing", Vector3.new(0.55, 1.6, 4.4), CAB_WHITE, Enum.Material.SmoothPlastic,
			CFrame.new(s * (half - 0.1), 3.6, Config.FrontAxleZ))
		box(ctx, "StepBar", Vector3.new(0.7, 0.16, 2.2), DARK_STEEL, Enum.Material.DiamondPlate,
			CFrame.new(s * (half - 0.1), 2.35, -5.3))
	end

	-- windscreen, raked back over the bonnet; taller by the lift so it still meets
	-- the roof rail at the top and the bonnet at the bottom
	box(ctx, "Windscreen", Vector3.new(W - 1.1, 2.9 + CAB_LIFT, 0.16), GLASS, Enum.Material.Glass,
		CFrame.new(0, 5.35 + CAB_LIFT * 0.5, -7.52) * CFrame.Angles(math.rad(-13), 0, 0))

	--[ amber rotators ]------------------------------------------------------
	for i, s in ipairs({ -1, 1 }) do
		-- the amber dome, fixed
		local dome = cylY(ctx, "Beacon" .. i, 0.55, 0.8, AMBER, Enum.Material.Neon,
			CFrame.new(s * 1.7, 7.05 + CAB_LIFT, -5.4))
		dome.Transparency = 0.35
		-- and the mirror turning inside it, which is what actually reads as a
		-- rotating beacon rather than a lamp that blinks. Amber rather than the
		-- near-white it was: see the note on the headlights -- a white neon at this
		-- place's bloom threshold lit the entire cab up like a floodlight.
		local rotor = cosmetic("BeaconRotor" .. i, Vector3.new(0.74, 0.34, 0.2),
			Color3.fromRGB(255, 178, 52), Enum.Material.Neon)
		dynamic(ctx, rotor, Vector3.new(s * 1.7, 7.05 + CAB_LIFT, -5.4), Vector3.new(0, 1, 0), CFrame.new())
		local pl = Instance.new("PointLight")
		pl.Color = AMBER
		-- 24 studs reached the far end of the deck and both wing mirrors, so the
		-- whole truck pulsed amber. 11 keeps the throw on the cab roof where the
		-- lamp actually is; RigController sets the brightness, and dimly.
		pl.Range = 11
		pl.Brightness = 0
		pl.Shadows = false
		pl.Parent = rotor
	end
	box(ctx, "LightBar", Vector3.new(4.2, 0.18, 0.5), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(0, 6.8 + CAB_LIFT, -5.4))
end

--==[ DECK + TANK ]===========================================================

local function buildDeck(ctx: Ctx)
	local W = Config.TruckWidth
	local half = W * 0.5
	local deck = Config.DeckY

	box(ctx, "Deck", Vector3.new(W, 0.4, 14.5), DARK_STEEL, Enum.Material.DiamondPlate,
		CFrame.new(0, deck - 0.2, 3.85))
	box(ctx, "Headboard", Vector3.new(W - 0.4, 1.7, 0.3), DARK_STEEL, Enum.Material.DiamondPlate,
		CFrame.new(0, deck + 0.85, -3.25))
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "DeckRail", Vector3.new(0.25, 0.55, 14.5), DARK_STEEL, Enum.Material.Metal,
			CFrame.new(s * (half - 0.12), deck + 0.27, 3.85))
		-- frame rail under the deck, visible between the wheels
		box(ctx, "FrameRail", Vector3.new(0.3, 0.7, 15.0), BODY_BLACK, Enum.Material.Metal,
			CFrame.new(s * 2.5, deck - 0.75, 3.6))
	end

	--[ the tank ]------------------------------------------------------------
	--[[
		The barrel grows backwards from a fixed front face just behind the
		headboard, rather than outwards from a fixed centre. Growing from the centre
		would push a Cistern's nose through the headboard and into the cab at the
		same time as its tail reached the pump skid; pinned at the front it only has
		to clear one thing, and it does.
	]]
	local tankDia = ctx.body.tankDia
	local tankLen = ctx.body.tankLen
	local tankY = deck + 0.3 + tankDia * 0.5
	local tankZ = -2.6 + tankLen * 0.5

	cylZ(ctx, "Tank", tankLen, tankDia, TANK_BLACK, Enum.Material.SmoothPlastic,
		CFrame.new(0, tankY, tankZ))
	for _, s in ipairs({ -1, 1 }) do
		-- dished heads, a shade proud of the barrel
		cylZ(ctx, "TankHead", 0.45, tankDia + 0.12, TANK_BLACK, Enum.Material.Metal,
			CFrame.new(0, tankY, tankZ + s * tankLen * 0.5))
		-- cradle straps holding it to the deck
		box(ctx, "TankCradle", Vector3.new(tankDia + 0.5, 0.9, 0.5), DARK_STEEL, Enum.Material.Metal,
			CFrame.new(0, deck + 0.45, tankZ + s * tankLen * 0.35))
	end

	--[ livery: checker band over the brand, both flanks ]--------------------
	for _, s in ipairs({ -1, 1 }) do
		-- inset from the dished heads so the lettering sits on the barrel proper
		local panel = cosmetic("TankLivery",
			Vector3.new(0.06, tankDia * 0.5, tankLen - 2.0), TANK_BLACK,
			Enum.Material.SmoothPlastic)
		panel.Transparency = 1
		add(ctx, panel, CFrame.new(s * (tankDia * 0.5 + 0.03), tankY + 0.15, tankZ))

		local gui = surface(panel, if s > 0 then Enum.NormalId.Right else Enum.NormalId.Left, 64)
		checkerBand(gui, 16, 0.30, 0.02)
		-- TextScaled, so a long name shrinks to fit the barrel rather than running
		-- off the dished heads -- which is what makes any name safe to accept here
		local brand = label(gui, ctx.brand, UDim2.fromScale(1, 0.52), UDim2.fromScale(0, 0.38),
			Color3.new(1, 1, 1))
		brand.Font = Enum.Font.GothamBlack
		label(gui, "PAVEMENT MAINTENANCE", UDim2.fromScale(1, 0.13), UDim2.fromScale(0, 0.87),
			Color3.fromRGB(206, 206, 206))
	end

	--[ top fittings ]--------------------------------------------------------
	cylY(ctx, "FillHatch", 0.42, 1.7, DARK_STEEL, Enum.Material.Metal,
		CFrame.new(0, tankY + tankDia * 0.5 + 0.15, tankZ - 2.6))
	box(ctx, "HatchHandle", Vector3.new(1.0, 0.14, 0.14), CHROME, Enum.Material.Metal,
		CFrame.new(0, tankY + tankDia * 0.5 + 0.42, tankZ - 2.6))
	box(ctx, "VentPipe", Vector3.new(0.2, 0.2, 1.4), STEEL, Enum.Material.Metal,
		CFrame.new(0.9, tankY + tankDia * 0.5 + 0.2, tankZ - 0.6))

	-- agitator drive: housing bolted to the tank crown, shaft turning inside
	box(ctx, "AgitatorHousing", Vector3.new(1.9, 1.15, 1.7), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(0, tankY + tankDia * 0.5 + 0.55, tankZ + 3.0))
	local agitator = cosmetic("Agitator", Vector3.new(0.7, 1.0, 1.0), STEEL, Enum.Material.Metal)
	agitator.Shape = Enum.PartType.Cylinder
	dynamic(ctx, agitator, Vector3.new(0, tankY + tankDia * 0.5 + 1.4, tankZ + 3.0),
		Vector3.new(0, 1, 0), CFrame.Angles(0, 0, math.rad(90)))

	local vane = cosmetic("AgitatorVane", Vector3.new(1.5, 0.12, 0.34), STEEL, Enum.Material.Metal)
	dynamic(ctx, vane, Vector3.new(0, tankY + tankDia * 0.5 + 1.72, tankZ + 3.0),
		Vector3.new(0, 1, 0), CFrame.new())

	return tankY, tankZ, tankDia, agitator
end

--==[ WORKING END ]===========================================================

local function buildRearRig(ctx: Ctx, tankY: number, tankZ: number, tankDia: number, tankLen: number)
	local W = Config.TruckWidth
	local half = W * 0.5
	local deck = Config.DeckY

	--[ ladder up the back of the tank ]--------------------------------------
	-- against the rear head wherever the barrel ends, and tall enough to reach
	-- the crown of whichever barrel this rig carries
	local ladderZ = tankZ + tankLen * 0.5 + 0.5
	local ladderH = tankY + tankDia * 0.5 - deck
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "LadderRail", Vector3.new(0.16, ladderH, 0.16), STEEL, Enum.Material.Metal,
			CFrame.new(s * 0.65, deck + ladderH * 0.5, ladderZ))
	end
	for i = 0, math.floor(ladderH / 1.05) - 1 do
		box(ctx, "LadderRung", Vector3.new(1.5, 0.12, 0.12), STEEL, Enum.Material.Metal,
			CFrame.new(0, deck + 0.9 + i * 1.05, ladderZ))
	end

	--[ pump and motor skid, driver side ]------------------------------------
	local px = -2.1
	box(ctx, "PumpSkid", Vector3.new(2.6, 0.3, 3.4), DARK_STEEL, Enum.Material.DiamondPlate,
		CFrame.new(px, deck + 0.15, 8.4))
	box(ctx, "PumpMotor", Vector3.new(1.9, 1.6, 2.3), BODY_BLACK, Enum.Material.Metal,
		CFrame.new(px, deck + 1.1, 8.6))
	box(ctx, "MotorFins", Vector3.new(1.95, 0.5, 1.2), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(px, deck + 1.95, 8.6))
	cylX(ctx, "PumpHead", 1.2, 1.15, STEEL, Enum.Material.Metal,
		CFrame.new(px, deck + 0.85, 7.1))
	cylY(ctx, "FilterPot", 1.5, 1.25, STEEL, Enum.Material.Metal,
		CFrame.new(px - 1.3, deck + 0.9, 9.6))
	box(ctx, "SuctionPipe", Vector3.new(0.3, 0.3, 3.2), STEEL, Enum.Material.Metal,
		CFrame.new(px, deck + 0.85, 5.6))
	for i, s in ipairs({ -1, 1 }) do
		box(ctx, "ValveHandle", Vector3.new(0.9, 0.12, 0.12), SAFETY_RED, Enum.Material.SmoothPlastic,
			CFrame.new(px + s * 0.1, deck + 1.5, 6.9 + i * 0.4))
	end

	--[ rear control panel: gauge, and where the PTO prompt lives ]-----------
	local panel = box(ctx, "PumpPanel", Vector3.new(2.4, 1.7, 0.22), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(px, deck + 1.5, 10.35))
	panel.CanQuery = true   -- the PTO prompt needs to be hit-testable
	local gui = surface(panel, Enum.NormalId.Front, 90)
	label(gui, "TANK LEVEL", UDim2.fromScale(1, 0.28), UDim2.fromScale(0, 0.06),
		Color3.fromRGB(228, 232, 240))

	local gaugeFace = cylZ(ctx, "GaugeFace", 0.12, 1.15, Color3.fromRGB(232, 232, 226),
		Enum.Material.SmoothPlastic, CFrame.new(px + 1.55, deck + 1.5, 10.3))
	cylZ(ctx, "GaugeBezel", 0.16, 1.35, CHROME, Enum.Material.Metal,
		CFrame.new(px + 1.55, deck + 1.5, 10.26))
	-- The needle turns about the dial centre, so it is anchored at the pivot and
	-- carries its own offset out to the tip as its shape rotation.
	local needle = cosmetic("GaugeNeedle", Vector3.new(0.08, 0.46, 0.06), SAFETY_RED,
		Enum.Material.SmoothPlastic)
	dynamic(ctx, needle, Vector3.new(px + 1.55, deck + 1.5, 10.36),
		Vector3.new(0, 0, 1), CFrame.new(0, 0.23, 0))

	--[ hose reel, kerb side ]------------------------------------------------
	-- Sized from the drum this rig actually carries: a Longline's 280 studs is a
	-- visibly bigger, wider coil than a Dart's 96, which is the whole difference
	-- between the two trucks made visible from across the yard.
	local rx = 2.1
	local reelDia = ctx.body.reelDia
	local reelW = ctx.body.reelWidth
	local reelZ = 8.7
	-- hung so the coil clears the deck whatever its diameter
	local reelY = deck + 0.35 + reelDia * 0.5

	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "ReelUpright", Vector3.new(0.22, reelDia + 0.3, reelDia + 0.1),
			DARK_STEEL, Enum.Material.Metal,
			CFrame.new(rx + s * (reelW * 0.5 + 0.15), deck + (reelDia + 0.3) * 0.5, reelZ))
	end
	cylX(ctx, "ReelDrum", reelW * 1.14, reelDia * 0.53, DARK_STEEL, Enum.Material.Metal,
		CFrame.new(rx, reelY, reelZ))
	-- the coil itself; spun as hose comes off and goes back on
	local wrap = cosmetic("ReelWrap", Vector3.new(reelW, reelDia, reelDia), Config.HoseColor,
		Enum.Material.SmoothPlastic)
	wrap.Shape = Enum.PartType.Cylinder
	dynamic(ctx, wrap, Vector3.new(rx, reelY, reelZ), Vector3.new(1, 0, 0), CFrame.new())
	-- A wrap that is a smooth cylinder never looks like it is turning. The
	-- flat-sided coil line rides with it and gives the eye something to track.
	local coil = cosmetic("ReelCoilLine", Vector3.new(reelW + 0.04, reelDia + 0.07, 0.5),
		Color3.fromRGB(58, 12, 11), Enum.Material.SmoothPlastic)
	dynamic(ctx, coil, Vector3.new(rx, reelY, reelZ), Vector3.new(1, 0, 0), CFrame.new())
	box(ctx, "ReelCrank", Vector3.new(0.14, 1.5, 0.14), STEEL, Enum.Material.Metal,
		CFrame.new(rx + reelW * 0.5 + 0.55, reelY, reelZ))
	box(ctx, "ReelHandle", Vector3.new(0.4, 0.14, 0.14), SAFETY_RED, Enum.Material.SmoothPlastic,
		CFrame.new(rx + reelW * 0.5 + 0.72, reelY + 0.7, reelZ))

	-- Where the hose actually leaves the machine. Invisible: the drawn hose
	-- starts here, so a visible part would only ever be inside the first segment.
	local outlet = cosmetic("ReelOutlet", Vector3.new(0.3, 0.3, 0.3), STEEL, Enum.Material.Metal)
	outlet.Transparency = 1
	add(ctx, outlet, CFrame.new(rx, deck + 0.6, 9.9))
	cylZ(ctx, "OutletElbow", 0.7, 0.5, DARK_STEEL, Enum.Material.Metal,
		CFrame.new(rx, deck + 0.6, 9.75))

	-- The wand's parking spot, and the host for the grab prompt.
	local dock = box(ctx, "WandDock", Vector3.new(0.5, 0.5, 1.5), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(rx + 1.0, deck + 0.5, 10.4))
	dock.CanQuery = true

	--[ rear skid, spray bar and warnings ]-----------------------------------
	box(ctx, "RearSkid", Vector3.new(W + 0.4, 0.85, 0.7), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(0, 1.85, 11.15))
	box(ctx, "SprayBar", Vector3.new(6.2, 0.4, 0.4), BODY_BLACK, Enum.Material.Metal,
		CFrame.new(0, 1.25, 11.35))
	for i = 0, 5 do
		box(ctx, "SprayTip", Vector3.new(0.18, 0.3, 0.18), STEEL, Enum.Material.Metal,
			CFrame.new(-2.6 + i * 1.04, 1.0, 11.35))
	end
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "TailLight", Vector3.new(0.55, 1.0, 0.2), SAFETY_RED, Enum.Material.Neon,
			CFrame.new(s * (half - 0.5), 2.75, 11.3))
	end

	-- chevron stripes across the skid
	for i = 0, 7 do
		box(ctx, "Chevron", Vector3.new(0.9, 0.8, 0.08), if i % 2 == 0 then SAFETY_RED
			else Color3.fromRGB(238, 238, 232), Enum.Material.SmoothPlastic,
			CFrame.new(-3.15 + i * 0.9, 1.85, 11.52))
	end

	local sign = box(ctx, "CautionSign", Vector3.new(4.6, 1.0, 0.12), Color3.fromRGB(236, 186, 32),
		Enum.Material.SmoothPlastic, CFrame.new(0, 3.3, 11.3))
	local signGui = surface(sign, Enum.NormalId.Front, 90)
	label(signGui, "CAUTION: WET SEALCOAT", UDim2.fromScale(1, 0.8), UDim2.fromScale(0, 0.1),
		Color3.fromRGB(24, 22, 18))

	return wrap, needle, dock, outlet, panel
end

--==[ IMPORTED BODYWORK ]=====================================================

--[[
	A rig whose bodywork is a MODEL rather than the boxes above.

	The shell replaces buildCab and buildDeck and nothing else. Everything that
	makes a truck a truck -- the Base collider, the Hull, the low ballast, the
	seat, the running gear, the blade, the collision groups -- is built by the
	same code for every rig, so an imported body is bodywork and never a second
	kind of vehicle. That is the whole reason this is forty lines: the shell has
	no physics, no scripts and no opinions. It is paint that happens to be a mesh.

	Shells are authored to the SAME truck-local frame the boxes are: X across with
	zero on the centreline, Y up from the ground, -Z forward. A shell's pivot sits
	at that origin, so placing it is one PivotTo and there is no per-shell offset
	table to keep in step with the models.

	The cosmetic properties are re-applied here rather than trusted from the
	asset. A shell is an imported thing and one collidable panel on it would be a
	truck that barges other rigs; one queryable panel would swallow the wand's
	raycasts. Both are silent failures that look like a physics bug days later,
	and both are one property.
]]
local function buildShellBody(ctx: Ctx, shellName: string): boolean
	local template = script.Parent:FindFirstChild(shellName)
	if not (template and template:IsA("Model")) then
		-- Missing shell is not fatal: the caller falls back to the procedural body,
		-- so a rig whose asset failed to replicate is an ordinary-looking truck
		-- rather than a chassis with no bodywork on it.
		warn(("TruckBuilder: shell %q not found under %s")
			:format(shellName, script.Parent:GetFullName()))
		return false
	end

	local shell = template:Clone()
	shell.Parent = ctx.model
	shell:PivotTo(ctx.frame)

	for _, p in ipairs(shell:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Massless = true
			p.Parent = ctx.model
			local w = Instance.new("WeldConstraint")
			w.Part0 = ctx.base
			w.Part1 = p
			w.Parent = p
		end
	end
	-- the now-empty wrapper; the parts are welded siblings of everything else
	shell:Destroy()
	return true
end

--[[
	The sealer plant, mounted in a pickup bed instead of standing on a flatbed.

	This is buildDeck and buildRearRig for a shell rig, and it exists as a third
	function rather than as branches inside those two because almost every
	measurement differs: a flatbed is a surface the builder chose, and a bed is a
	hole the bodywork already decided the shape of. Threading a dozen "unless it
	is a shell" conditions through two hundred lines of tuned offsets would have
	been a far better way to break the four trucks that already work.

	What it does NOT change is the names. RigController drives the moving parts by
	substring -- Reel, Gauge, Agitator -- and TruckServer and RigController find
	ReelOutlet and WandDock by name, so the same parts exist here under the same
	names doing the same jobs. See the note over `dynamic`.

	--[ the numbers ]---------------------------------------------------------

	BED and TAIL are measured off the shell, not chosen. The bed floor of the
	Cyberseal sits 3.92 above the ground with its walls about 2.5 studs either
	side of the centreline, and the bodywork ends at 9.80. Everything below is
	placed against those three figures, which is why a barrel wider than about 4.4
	or longer than about 5.4 does not belong in here -- and why the rig carries
	fixedBody rather than letting Rigs.body size it from its tank figure.

	The plant runs BACKWARDS out of the bed onto a carrier behind the tailgate,
	which is what a real bed-mounted sealcoat skid does: the drum takes the bed,
	and the reel, the pump and the gauge hang off the back where somebody stood on
	the road can reach them. It also keeps the reel outlet and the wand dock at
	roughly the height they sit at on the flatbed rigs, so the hose still pays out
	into the player's hands rather than over their head.
]]
local function buildBedRig(ctx: Ctx)
	local BED  = 3.92    -- the shell's bed floor, above the ground
	local TAIL = 9.80    -- where the bodywork stops

	local tankDia = ctx.body.tankDia
	local tankLen = ctx.body.tankLen
	-- Pinned at the FRONT of the bed and grown backwards, the same way buildDeck
	-- does it and for the same reason: the front is the end with something to hit
	-- (the sloped rear glass), and the back is open air.
	local tankZ = 4.10 + tankLen * 0.5
	local tankY = BED + 0.30 + tankDia * 0.5
	local crown = tankY + tankDia * 0.5

	--[ the skid the drum is strapped to ]-----------------------------------
	box(ctx, "BedSkid", Vector3.new(tankDia, 0.3, tankLen + 0.6), DARK_STEEL,
		Enum.Material.DiamondPlate, CFrame.new(0, BED + 0.15, tankZ))

	--[ the drum ]------------------------------------------------------------
	cylZ(ctx, "Tank", tankLen, tankDia, TANK_BLACK, Enum.Material.SmoothPlastic,
		CFrame.new(0, tankY, tankZ))
	for _, s in ipairs({ -1, 1 }) do
		cylZ(ctx, "TankHead", 0.45, tankDia + 0.12, TANK_BLACK, Enum.Material.Metal,
			CFrame.new(0, tankY, tankZ + s * tankLen * 0.5))
		box(ctx, "TankCradle", Vector3.new(tankDia + 0.3, 0.9, 0.45), DARK_STEEL,
			Enum.Material.Metal, CFrame.new(0, BED + 0.45, tankZ + s * tankLen * 0.32))
	end

	--[ livery down both flanks, exactly as the flatbed rigs wear it ]--------
	for _, s in ipairs({ -1, 1 }) do
		local panel = cosmetic("TankLivery",
			Vector3.new(0.06, tankDia * 0.5, tankLen - 1.4), TANK_BLACK,
			Enum.Material.SmoothPlastic)
		panel.Transparency = 1
		add(ctx, panel, CFrame.new(s * (tankDia * 0.5 + 0.03), tankY + 0.15, tankZ))

		local gui = surface(panel, if s > 0 then Enum.NormalId.Right else Enum.NormalId.Left, 64)
		checkerBand(gui, 14, 0.30, 0.02)
		local brand = label(gui, ctx.brand, UDim2.fromScale(1, 0.52), UDim2.fromScale(0, 0.38),
			Color3.new(1, 1, 1))
		brand.Font = Enum.Font.GothamBlack
		label(gui, "PAVEMENT MAINTENANCE", UDim2.fromScale(1, 0.13), UDim2.fromScale(0, 0.87),
			Color3.fromRGB(206, 206, 206))
	end

	--[ crown fittings ]------------------------------------------------------
	cylY(ctx, "FillHatch", 0.42, 1.5, DARK_STEEL, Enum.Material.Metal,
		CFrame.new(0, crown + 0.15, tankZ - 1.5))
	box(ctx, "HatchHandle", Vector3.new(0.9, 0.14, 0.14), CHROME, Enum.Material.Metal,
		CFrame.new(0, crown + 0.42, tankZ - 1.5))
	box(ctx, "VentPipe", Vector3.new(0.2, 0.2, 1.2), STEEL, Enum.Material.Metal,
		CFrame.new(0.8, crown + 0.2, tankZ - 0.2))

	--[[
		The agitator, and the tightest clearance on the truck.

		The depot's SideLintel has its underside at 11.00 and is permanent geometry,
		so the crown of this stack is what decides whether the rig can be driven out
		of its own garage -- see the note in Rigs.body, where a tall barrel once
		trapped the Cistern indoors. The vane tops out at about 10.0 here, which is
		where the Cistern's sits. Raise the drum and this is the thing that breaks.
	]]
	box(ctx, "AgitatorHousing", Vector3.new(1.7, 1.0, 1.5), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(0, crown + 0.45, tankZ + 1.5))
	local agitator = cosmetic("Agitator", Vector3.new(0.7, 0.9, 0.9), STEEL, Enum.Material.Metal)
	agitator.Shape = Enum.PartType.Cylinder
	dynamic(ctx, agitator, Vector3.new(0, crown + 1.15, tankZ + 1.5),
		Vector3.new(0, 1, 0), CFrame.Angles(0, 0, math.rad(90)))
	local vane = cosmetic("AgitatorVane", Vector3.new(1.3, 0.12, 0.32), STEEL, Enum.Material.Metal)
	dynamic(ctx, vane, Vector3.new(0, crown + 1.42, tankZ + 1.5), Vector3.new(0, 1, 0), CFrame.new())

	--[ the carrier behind the tailgate, which everything else hangs off ]-----
	local carrierZ = TAIL + 0.50
	local carrierY = 2.65
	local top = carrierY + 0.18
	box(ctx, "RearCarrier", Vector3.new(7.4, 0.35, 2.0), DARK_STEEL, Enum.Material.DiamondPlate,
		CFrame.new(0, carrierY, carrierZ))
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "CarrierLeg", Vector3.new(0.35, 1.5, 0.35), DARK_STEEL, Enum.Material.Metal,
			CFrame.new(s * 3.1, carrierY - 0.9, carrierZ))
		box(ctx, "CarrierArm", Vector3.new(0.3, 0.3, 2.2), DARK_STEEL, Enum.Material.Metal,
			CFrame.new(s * 3.1, carrierY, carrierZ - 1.7))
	end

	--[ hose reel, kerb side of the carrier ]---------------------------------
	local rx = 2.0
	local reelDia = ctx.body.reelDia
	local reelW = ctx.body.reelWidth
	local reelZ = carrierZ
	local reelY = top + 0.35 + reelDia * 0.5

	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "ReelUpright", Vector3.new(0.22, reelDia + 0.3, reelDia + 0.1),
			DARK_STEEL, Enum.Material.Metal,
			CFrame.new(rx + s * (reelW * 0.5 + 0.15), top + (reelDia + 0.3) * 0.5, reelZ))
	end
	cylX(ctx, "ReelDrum", reelW * 1.14, reelDia * 0.53, DARK_STEEL, Enum.Material.Metal,
		CFrame.new(rx, reelY, reelZ))
	local wrap = cosmetic("ReelWrap", Vector3.new(reelW, reelDia, reelDia), Config.HoseColor,
		Enum.Material.SmoothPlastic)
	wrap.Shape = Enum.PartType.Cylinder
	dynamic(ctx, wrap, Vector3.new(rx, reelY, reelZ), Vector3.new(1, 0, 0), CFrame.new())
	-- the flat-sided coil line, so the drum visibly turns -- see buildRearRig
	local coil = cosmetic("ReelCoilLine", Vector3.new(reelW + 0.04, reelDia + 0.07, 0.5),
		Color3.fromRGB(58, 12, 11), Enum.Material.SmoothPlastic)
	dynamic(ctx, coil, Vector3.new(rx, reelY, reelZ), Vector3.new(1, 0, 0), CFrame.new())
	box(ctx, "ReelCrank", Vector3.new(0.14, 1.4, 0.14), STEEL, Enum.Material.Metal,
		CFrame.new(rx + reelW * 0.5 + 0.5, reelY, reelZ))
	box(ctx, "ReelHandle", Vector3.new(0.4, 0.14, 0.14), SAFETY_RED, Enum.Material.SmoothPlastic,
		CFrame.new(rx + reelW * 0.5 + 0.67, reelY + 0.65, reelZ))

	-- Where the hose actually leaves the machine; invisible, because the drawn
	-- hose starts here and a visible part would sit inside its first segment.
	local outlet = cosmetic("ReelOutlet", Vector3.new(0.3, 0.3, 0.3), STEEL, Enum.Material.Metal)
	outlet.Transparency = 1
	add(ctx, outlet, CFrame.new(rx, top + 0.5, carrierZ + 0.95))
	cylZ(ctx, "OutletElbow", 0.7, 0.5, DARK_STEEL, Enum.Material.Metal,
		CFrame.new(rx, top + 0.5, carrierZ + 0.8))

	-- The wand's parking spot, and the host for the grab prompt.
	local dock = box(ctx, "WandDock", Vector3.new(0.5, 0.5, 1.4), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(rx + 1.3, top + 0.42, carrierZ + 0.1))
	dock.CanQuery = true

	--[[
		Pump skid and gauge, driver side of the carrier.

		The panel stands at the BACK of the carrier with the motor in front of it,
		rather than sitting on top of the motor. It hosts the PTO prompt, so its
		height is the one number here that is not cosmetic: stacked, it rode at 5.48
		above the road, which is over the head of the player stood behind the truck
		trying to press it. This puts it at 3.9, which is where the flatbed rigs
		keep theirs.
	]]
	local px = -2.15
	box(ctx, "PumpSkid", Vector3.new(2.3, 0.3, 1.8), DARK_STEEL, Enum.Material.DiamondPlate,
		CFrame.new(px, top + 0.15, carrierZ - 0.2))
	box(ctx, "PumpMotor", Vector3.new(1.8, 1.3, 1.5), BODY_BLACK, Enum.Material.Metal,
		CFrame.new(px, top + 0.95, carrierZ - 0.35))
	box(ctx, "MotorFins", Vector3.new(1.85, 0.4, 0.9), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(px, top + 1.7, carrierZ - 0.35))
	cylX(ctx, "PumpHead", 1.1, 1.0, STEEL, Enum.Material.Metal,
		CFrame.new(px, top + 0.75, carrierZ - 1.4))
	box(ctx, "SuctionPipe", Vector3.new(0.3, 0.3, 2.2), STEEL, Enum.Material.Metal,
		CFrame.new(px, top + 0.75, carrierZ - 2.5))

	-- the gauge, and the face the PTO prompt is hosted on
	local panel = box(ctx, "PumpPanel", Vector3.new(2.3, 1.7, 0.22), DARK_STEEL,
		Enum.Material.Metal, CFrame.new(px, top + 1.05, carrierZ + 1.05))
	panel.CanQuery = true
	local gui = surface(panel, Enum.NormalId.Front, 90)
	label(gui, "TANK LEVEL", UDim2.fromScale(1, 0.28), UDim2.fromScale(0, 0.06),
		Color3.fromRGB(228, 232, 240))

	cylZ(ctx, "GaugeFace", 0.12, 1.0, Color3.fromRGB(232, 232, 226),
		Enum.Material.SmoothPlastic, CFrame.new(px + 1.35, top + 1.05, carrierZ + 1.01))
	cylZ(ctx, "GaugeBezel", 0.16, 1.2, CHROME, Enum.Material.Metal,
		CFrame.new(px + 1.35, top + 1.05, carrierZ + 0.97))
	local needle = cosmetic("GaugeNeedle", Vector3.new(0.08, 0.42, 0.06), SAFETY_RED,
		Enum.Material.SmoothPlastic)
	dynamic(ctx, needle, Vector3.new(px + 1.35, top + 1.05, carrierZ + 1.07),
		Vector3.new(0, 0, 1), CFrame.new(0, 0.21, 0))

	--[ warnings across the back ]--------------------------------------------
	-- outboard of the panel and the wand dock, both of which stand on this face
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "TailLight", Vector3.new(0.5, 0.85, 0.2), SAFETY_RED, Enum.Material.Neon,
			CFrame.new(s * 3.9, carrierY + 0.75, carrierZ + 1.05))
	end
	for i = 0, 7 do
		box(ctx, "Chevron", Vector3.new(0.85, 0.7, 0.08), if i % 2 == 0 then SAFETY_RED
			else Color3.fromRGB(238, 238, 232), Enum.Material.SmoothPlastic,
			CFrame.new(-2.98 + i * 0.85, carrierY - 0.5, carrierZ + 1.05))
	end

	local sign = box(ctx, "CautionSign", Vector3.new(4.2, 0.9, 0.12), Color3.fromRGB(236, 186, 32),
		Enum.Material.SmoothPlastic, CFrame.new(0, carrierY - 1.45, carrierZ + 1.0))
	local signGui = surface(sign, Enum.NormalId.Front, 90)
	label(signGui, "CAUTION: WET SEALCOAT", UDim2.fromScale(1, 0.8), UDim2.fromScale(0, 0.1),
		Color3.fromRGB(24, 22, 18))
end

--==[ DECK CLUTTER ]==========================================================

-- Toolboxes, cones and hand tools. None of it is functional; a bare flatbed
-- reads as unfinished, and a loaded one reads as a truck that works for a living.
local function buildKit(ctx: Ctx)
	local half = Config.TruckWidth * 0.5
	local deck = Config.DeckY

	for _, s in ipairs({ -1, 1 }) do
		box(ctx, "Toolbox", Vector3.new(0.95, 1.5, 4.2), Color3.fromRGB(206, 206, 202),
			Enum.Material.Metal, CFrame.new(s * (half - 0.4), deck - 0.9, 5.0))
		box(ctx, "ToolboxLid", Vector3.new(1.0, 0.14, 4.2), DARK_STEEL, Enum.Material.Metal,
			CFrame.new(s * (half - 0.4), deck - 0.18, 5.0))
		box(ctx, "ToolboxLatch", Vector3.new(0.16, 0.3, 0.4), CHROME, Enum.Material.Metal,
			CFrame.new(s * (half - 0.02), deck - 0.6, 5.0))
	end

	-- utility box beside the tank
	box(ctx, "UtilityBox", Vector3.new(1.8, 1.6, 2.6), Color3.fromRGB(228, 228, 224),
		Enum.Material.SmoothPlastic, CFrame.new(2.4, deck + 0.8, -1.4))
	box(ctx, "UtilityLid", Vector3.new(1.85, 0.12, 2.65), DARK_STEEL, Enum.Material.Metal,
		CFrame.new(2.4, deck + 1.62, -1.4))

	-- cones, stacked as three tapering rings apiece
	for i = 0, 2 do
		local cz = -2.0 + i * 1.15
		box(ctx, "ConeBase", Vector3.new(1.0, 0.12, 1.0), Color3.fromRGB(28, 28, 30),
			Enum.Material.SmoothPlastic, CFrame.new(-2.5, deck + 0.06, cz))
		cylY(ctx, "ConeLo", 0.5, 0.78, Color3.fromRGB(232, 96, 26), Enum.Material.SmoothPlastic,
			CFrame.new(-2.5, deck + 0.37, cz))
		cylY(ctx, "ConeBand", 0.22, 0.62, Color3.fromRGB(240, 240, 236), Enum.Material.SmoothPlastic,
			CFrame.new(-2.5, deck + 0.72, cz))
		cylY(ctx, "ConeHi", 0.55, 0.4, Color3.fromRGB(232, 96, 26), Enum.Material.SmoothPlastic,
			CFrame.new(-2.5, deck + 1.08, cz))
	end

	-- squeegee and broom, stood in the corner behind the headboard rather than
	-- leaned out where the poles would clear the tank and read as floating
	for i, s in ipairs({ -1, 1 }) do
		local lean = CFrame.new(s * 2.9, deck + 1.9, -2.5) * CFrame.Angles(math.rad(14), 0, 0)
		box(ctx, "StowedPole", Vector3.new(0.2, 3.8, 0.2),
			if i == 1 then Color3.fromRGB(196, 130, 62) else Color3.fromRGB(150, 152, 158),
			if i == 1 then Enum.Material.Wood else Enum.Material.Metal, lean)
		box(ctx, "StowedHead", Vector3.new(1.5, 0.3, 0.35),
			if i == 1 then Color3.fromRGB(26, 26, 28) else Color3.fromRGB(178, 148, 96),
			Enum.Material.SmoothPlastic, lean * CFrame.new(0, -2.0, 0))
	end

	-- tape rolls in the corner
	for i = 0, 1 do
		cylY(ctx, "TapeRoll", 0.3, 0.9, Color3.fromRGB(38, 38, 40), Enum.Material.SmoothPlastic,
			CFrame.new(3.0, deck + 0.16 + i * 0.32, 1.6))
	end

	--[ grime: this is a truck that hauls tar ]-------------------------------
	for i = 1, 7 do
		local splat = cosmetic("Splatter", Vector3.new(0.6 + math.random() * 1.5, 0.04,
			0.5 + math.random() * 1.2), GRIME, Enum.Material.SmoothPlastic)
		splat.Transparency = 0.15
		add(ctx, splat, CFrame.new((math.random() - 0.5) * 6.4, Config.DeckY + 0.02,
			6.0 + math.random() * 5.0))
	end
	for _, s in ipairs({ -1, 1 }) do
		local streak = cosmetic("Streak", Vector3.new(0.06, 1.1, 2.6), GRIME, Enum.Material.SmoothPlastic)
		streak.Transparency = 0.35
		add(ctx, streak, CFrame.new(s * (Config.TruckWidth * 0.5 + 0.02), 2.1, 9.4))
	end
end

--==[ RUNNING GEAR ]==========================================================

local function wheelPart(name: string): Part
	local w = Instance.new("Part")
	w.Name = name
	w.Shape = Enum.PartType.Cylinder
	w.Size = Vector3.new(Config.WheelWidth, Config.WheelRadius * 2, Config.WheelRadius * 2)
	w.Color = TIRE
	w.Material = Enum.Material.Rubber
	w.CollisionGroup = WHEEL_GROUP
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	-- Grippy and dead: a bouncy tyre turns every kerb into a launch ramp. 2 is
	-- the engine's ceiling on friction; the weight is what biases the contact.
	-- The density is the unsprung-mass number -- see WheelDensity in Config for why
	-- it is no longer 1.1, and why that mattered more than any spring rate.
	w.CustomPhysicalProperties = PhysicalProperties.new(Config.WheelDensity, 2, 0, 12, 1)
	return w
end

-- Hub face detail, welded to the wheel rather than the chassis so it spins too.
local function dressWheel(model: Model, wheel: Part, outward: number)
	local hub = Instance.new("Part")
	hub.Name = "Hub"
	hub.Shape = Enum.PartType.Cylinder
	hub.Size = Vector3.new(0.14, Config.WheelRadius * 1.05, Config.WheelRadius * 1.05)
	hub.Color = Color3.fromRGB(206, 206, 200)
	hub.Material = Enum.Material.Metal
	hub.CanCollide = false
	hub.CanQuery = false
	hub.Massless = true
	hub.CFrame = wheel.CFrame * CFrame.new(outward * (Config.WheelWidth * 0.5 + 0.06), 0, 0)
	hub.Parent = model
	local w = Instance.new("WeldConstraint")
	w.Part0 = wheel
	w.Part1 = hub
	w.Parent = hub
end

--[[
	A hinge turns about its Attachment0's own X axis. Every part here is built
	unrotated relative to the truck, so a default attachment already points its
	X along the truck's right -- which is exactly the roll axis. The steering
	knuckles are the one exception: their attachments are rolled 90 degrees so
	the same X lands on the truck's up axis instead.
]]
local function hinge(part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame, name: string): HingeConstraint
	local a0 = Instance.new("Attachment")
	a0.Name = name .. "A0"
	a0.CFrame = c0
	a0.Parent = part0

	local a1 = Instance.new("Attachment")
	a1.Name = name .. "A1"
	a1.CFrame = c1
	a1.Parent = part1

	local h = Instance.new("HingeConstraint")
	h.Name = name
	h.Attachment0 = a0
	h.Attachment1 = a1
	h.Parent = part0
	return h
end

local VERTICAL = CFrame.Angles(0, 0, math.rad(90))  -- rolls local X onto local Y

--[[
	One corner of suspension: a slider for the travel and a spring across it.

	Returns the UPRIGHT, which is the part the wheel (or the steering knuckle)
	hangs off. Everything that used to bolt straight to the chassis bolts to this
	instead, and that one indirection is the whole fix -- see SUSPENSION in Config
	for the rates and for the measurements they came from.

	WHY BOTH CONSTRAINTS

	A SpringConstraint on its own is a rubber band between two points: it controls
	the DISTANCE and nothing else, so the wheel would swing, splay and wind up. The
	PrismaticConstraint is what makes it a suspension rather than a tether -- the
	wheel may only travel along one axis, and the spring decides where along it.
	The travel limits live on the slider because that is the joint that can enforce
	them rigidly; the spring's own MinLength/MaxLength are set to match purely so a
	stiff impact cannot walk past the slider's stop in a single step.

	The upright is deliberately given real mass, for the reason the steering knuckle
	already was: a near-massless link between two constraints is a reliable way to
	make the solver chatter, and this one now carries a whole corner.

	BUILT AT ITS OWN EQUILIBRIUM. FreeLength is arm + sag, so the spring is already
	carrying its share the instant the model is parented. Built at its free length
	instead, every rig would drop and wallow for a second on delivery, which reads
	exactly like the bug this is fixing.
]]
local function suspend(ctx: Ctx, x: number, y: number, z: number, name: string): BasePart
	local model, base, frame = ctx.model, ctx.base, ctx.frame
	local baseY = base.CFrame.Y - frame.Y
	local arm = Config.SuspensionArm

	local upright = Instance.new("Part")
	upright.Name = name
	upright.Size = Vector3.new(0.5, 0.5, 0.5)
	upright.Transparency = 1
	upright.CanCollide = false
	upright.CanQuery = false
	upright.CustomPhysicalProperties = PhysicalProperties.new(8, 0.3, 0, 1, 1)
	upright.CFrame = frame * CFrame.new(x, y, z)
	upright.Parent = model

	-- the travel. VERTICAL rolls the slider's own X axis onto the truck's up, the
	-- same trick the steering servo uses to stand a hinge on end.
	local sa0 = Instance.new("Attachment")
	sa0.Name = name .. "SlideA0"
	sa0.CFrame = CFrame.new(x, y - baseY, z) * VERTICAL
	sa0.Parent = base
	local sa1 = Instance.new("Attachment")
	sa1.Name = name .. "SlideA1"
	sa1.CFrame = VERTICAL
	sa1.Parent = upright

	local slide = Instance.new("PrismaticConstraint")
	slide.Name = name .. "Slide"
	slide.Attachment0 = sa0
	slide.Attachment1 = sa1
	slide.LimitsEnabled = true
	slide.LowerLimit = -Config.SuspensionDroop
	slide.UpperLimit = Config.SuspensionTravel
	slide.Restitution = 0                -- a stop that bounces is a stop that hops
	slide.Parent = base

	-- the spring, mounted above the upright so it has a line to work along
	local pa0 = Instance.new("Attachment")
	pa0.Name = name .. "SpringA0"
	pa0.CFrame = CFrame.new(x, y - baseY + arm, z)
	pa0.Parent = base
	local pa1 = Instance.new("Attachment")
	pa1.Name = name .. "SpringA1"
	pa1.Parent = upright

	local spring = Instance.new("SpringConstraint")
	spring.Name = name .. "Spring"
	spring.Attachment0 = pa0
	spring.Attachment1 = pa1
	spring.FreeLength = arm + Config.SuspensionSag
	spring.Stiffness = Config.SuspensionStiffness
	spring.Damping = Config.SuspensionDamping
	spring.LimitsEnabled = true
	spring.MinLength = math.max(0.05, arm - Config.SuspensionTravel)
	spring.MaxLength = arm + Config.SuspensionDroop
	spring.Parent = base

	return upright
end

local function buildRunningGear(ctx: Ctx)
	local model, base, frame = ctx.model, ctx.base, ctx.frame
	local r = Config.WheelRadius

	local drives: { HingeConstraint } = {}
	local steers: { HingeConstraint } = {}

	--[ steered front axle ]--------------------------------------------------
	for _, s in ipairs({ -1, 1 }) do
		local x = s * (Config.TruckWidth * 0.5 - 0.4)
		local z = Config.FrontAxleZ

		-- Suspension first, THEN steering: the spring carries the corner and the
		-- servo turns what is hanging on it. The other way round hangs the whole
		-- weight of the corner off the steering joint, which then has to fight the
		-- road as well as the driver.
		local upright = suspend(ctx, x, r, z, "UprightF" .. (if s < 0 then "L" else "R"))

		local knuckle = Instance.new("Part")
		knuckle.Name = "Knuckle"
		knuckle.Size = Vector3.new(0.5, 0.5, 0.5)
		knuckle.Transparency = 1
		knuckle.CanCollide = false
		knuckle.CanQuery = false
		-- Given some real weight on purpose. A near-massless link between two
		-- constraints is a reliable way to make the solver chatter, and this one
		-- carries the whole front axle.
		knuckle.CustomPhysicalProperties = PhysicalProperties.new(8, 0.3, 0, 1, 1)
		knuckle.CFrame = frame * CFrame.new(x, r, z)
		knuckle.Parent = model

		local servo = hinge(upright, knuckle, VERTICAL, VERTICAL, "Steer")
		servo.ActuatorType = Enum.ActuatorType.Servo
		servo.ServoMaxTorque = 90000
		servo.AngularSpeed = Config.TruckSteerRate
		servo.TargetAngle = 0
		servo.LimitsEnabled = true
		servo.LowerAngle = -Config.TruckSteerMax
		servo.UpperAngle = Config.TruckSteerMax
		table.insert(steers, servo)

		local wheel = wheelPart("WheelF")
		wheel.CFrame = frame * CFrame.new(x, r, z)
		wheel.Parent = model
		hinge(knuckle, wheel, CFrame.new(), CFrame.new(), "Roll")
		dressWheel(model, wheel, s)
	end

	--[ driven rear axle, dual wheels a side ]--------------------------------
	for _, s in ipairs({ -1, 1 }) do
		for _, inset in ipairs({ 0.62, 1.72 }) do
			local x = s * (Config.TruckWidth * 0.5 - 2.4 + inset)
			local z = Config.RearAxleZ

			-- Each dual gets its own spring rather than sharing one per side. They are
			-- 1.1 studs apart on the same axle line, so a shared upright would be a
			-- beam axle -- and a beam axle with no roll centre of its own is what makes
			-- one wheel dropping into a gutter lift the other clear of the road.
			local tag = (if s < 0 then "L" else "R") .. (if inset > 1.0 then "O" else "I")
			local upright = suspend(ctx, x, r, z, "UprightR" .. tag)

			local wheel = wheelPart("WheelR")
			wheel.CFrame = frame * CFrame.new(x, r, z)
			wheel.Parent = model

			local motor = hinge(upright, wheel, CFrame.new(), CFrame.new(), "Drive")
			motor.ActuatorType = Enum.ActuatorType.Motor
			motor.MotorMaxTorque = Config.TruckTorque
			motor.MotorMaxAcceleration = 90
			motor.AngularVelocity = 0
			table.insert(drives, motor)

			if inset > 1.0 then dressWheel(model, wheel, s) end
		end
		-- mudflap behind the duals
		box(ctx, "Mudflap", Vector3.new(2.2, 1.5, 0.1), Color3.fromRGB(22, 22, 24),
			Enum.Material.SmoothPlastic, CFrame.new(s * 2.6, 0.85, Config.RearAxleZ + 2.4))
	end

	return drives, steers
end

--==[ ASSEMBLY ]==============================================================

--[[
	`cab` and `tint` are paint; the four dimensions are the rig's own body, from
	Rigs.body. They are optional and default to the middle of the range, so a
	caller with no catalogue entry still gets a sensible truck rather than a
	zero-sized barrel.
]]
export type Livery = {
	cab: Color3, tint: Color3,
	tankDia: number?, tankLen: number?,
	reelDia: number?, reelWidth: number?,
	-- What goes down the side of the tank. Nil keeps SEALPRO -- see BRAND.
	brand: string?,
	-- Names a model under ReplicatedStorage.DrivewaySealer to use as the
	-- bodywork, in place of the cab and flatbed built here. See buildShellBody.
	shell: string?,
}

function TruckBuilder.build(frame: CFrame, parent: Instance, livery: Livery?): Model
	ensureCollisionGroups()

	local body: Body = {
		tankDia = (livery and livery.tankDia) or 5.2,
		tankLen = (livery and livery.tankLen) or 8.4,
		reelDia = (livery and livery.reelDia) or 2.85,
		reelWidth = (livery and livery.reelWidth) or 2.1,
	}

	local model = Instance.new("Model")
	model.Name = "SealcoatRig"

	--[[
		Two colliders and nothing else. The chassis box carries the wheels and
		the ground contact; the hull above it is what stops the cab driving
		through a garage. Both are light -- the ballast below is what the truck's
		mass actually is, and keeping it low is the whole rollover story.
	]]
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Size = Vector3.new(Config.TruckWidth - 0.6, 0.9, Config.TruckLength - 1.0)
	base.Color = BODY_BLACK
	base.Material = Enum.Material.Metal
	base.Transparency = 1
	base.CanQuery = false
	base.CollisionGroup = BODY_GROUP
	base.CFrame = frame * CFrame.new(0, 2.1, 0)
	base.CustomPhysicalProperties = PhysicalProperties.new(0.35, 0.4, 0, 1, 1)
	base.Parent = model

	local ctx: Ctx = {
		model = model, base = base, frame = frame, body = body,
		brand = (livery and livery.brand) or BRAND,
	}

	local hull = cosmetic("Hull", Vector3.new(Config.TruckWidth - 0.4, 4.7, Config.TruckLength - 1.4),
		BODY_BLACK, Enum.Material.Metal)
	hull.Transparency = 1
	hull.CanCollide = true
	hull.Massless = false
	hull.CollisionGroup = BODY_GROUP
	hull.CustomPhysicalProperties = PhysicalProperties.new(0.02, 0.3, 0, 1, 1)
	add(ctx, hull, CFrame.new(0, 4.9, -0.2))

	-- Ballast. Slung under the frame between the axles: a high centre of mass is
	-- the only reason a rig this tall would ever tip, and this is cheaper and far
	-- more predictable than fighting it with anti-roll torque later.
	local ballast = cosmetic("Ballast", Vector3.new(3.0, 0.8, 6.0), BODY_BLACK, Enum.Material.Metal)
	ballast.Transparency = 1
	ballast.Massless = false
	ballast.CustomPhysicalProperties = PhysicalProperties.new(
		Config.BallastMass / (3.0 * 0.8 * 6.0) / 100, 0.3, 0, 1, 1)
	add(ctx, ballast, CFrame.new(0, 1.15, 1.0))

	--[[
		Bodywork: either the boxes above, or an imported shell with its plant in
		the bed.

		The branch is only over the two functions that DRAW A BODY. Running gear,
		the seat, the colliders and the ballast are below and outside it, so a shell
		rig is the same vehicle with different panels rather than a second code path
		that has to be kept in step with this one.

		buildShellBody answers false if the asset is missing, and the fallback is
		the ordinary truck -- a rig whose model failed to replicate should look
		wrong, not arrive as a floating seat with no bodywork.

		buildKit is deliberately skipped for a shell: it is toolboxes and cones
		scattered over a 14.5-stud flatbed that a pickup does not have, and every
		one of its offsets would land inside the bodywork.
	]]
	local shelled = false
	if livery and livery.shell then
		shelled = buildShellBody(ctx, livery.shell)
	end

	if shelled then
		buildBedRig(ctx)
		buildBlade(ctx)
	else
		buildCab(ctx)
		local tankY, tankZ, tankDia = buildDeck(ctx)
		buildRearRig(ctx, tankY, tankZ, tankDia, body.tankLen)
		buildKit(ctx)
	end
	local drives, steers = buildRunningGear(ctx)

	--[ driver's seat ]-------------------------------------------------------
	local seat = Instance.new("VehicleSeat")
	seat.Name = "Seat"
	seat.Size = Vector3.new(2.2, 0.5, 2.0)
	seat.Color = Color3.fromRGB(42, 42, 46)
	seat.Material = Enum.Material.Fabric
	seat.Massless = true
	-- Its own drive model is left switched off; the hubs below are driven from
	-- Throttle/Steer directly, which is the only way to get a steered axle.
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	--[[
		No CoreGui speedometer.

		Sitting in a VehicleSeat makes Roblox draw its own -- a grey caption over a
		segmented bar, bottom centre, in nobody's art style and squarely on top of
		this game's hotbar. This is the only switch for it, and it has to be thrown
		on the seat rather than from the HUD. SealerUI.Shell draws the replacement.
	]]
	seat.HeadsUpDisplay = false
	-- Solid, and therefore grouped: the seat is the one collider on the truck
	-- that is not built through `cosmetic` or `wheelPart`, so left in Default it
	-- would be the single part of your rig that still barged another one.
	seat.CollisionGroup = BODY_GROUP
	--[[
		The ONLY way into this seat is the Drive prompt.

		Roblox seats sit whoever touches them, which is a door with no lock on it:
		TruckServer will only let a rig's owner drive, and a rule enforced by
		throwing people back out is one that is visibly enforced -- you get in, the
		camera cuts to the cab, and a moment later you are stood on the road again.
		With touch off there is one entrance, the server checks it before the weld
		exists, and a driver who is not allowed in simply never gets in.

		CanTouch, not Disabled: Disabled would shut the seat for its owner too.
	]]
	seat.CanTouch = false
	-- See SEAT_DRAWN / SEAT_SHELL: an imported cabin is not the room this builder
	-- drew, and the seat is the one part of the truck that has to be in the room.
	local sit = if shelled then SEAT_SHELL else SEAT_DRAWN
	seat.CFrame = frame * CFrame.new(sit.X, sit.Y, sit.Z)
	seat.Parent = model
	local seatWeld = Instance.new("WeldConstraint")
	seatWeld.Part0 = base
	seatWeld.Part1 = seat
	seatWeld.Parent = seat

	--[[
		Cabin furniture, and a shell rig gets none of it -- the same call buildKit
		gets, for the same reason.

		Every offset below was measured against the drawn cab. Against an imported
		one they land wherever they land: on the Cyberseal the dashboard and the
		wheel sit buried inside the nose, and the seat backs stand in mid-air a stud
		over a driver who is now sunk 1.2 studs below them. Ten parts per truck,
		none of them visible, one of them wrong in a way anyone can see through the
		glass.

		A shell brings its own interior -- seats, headrests and console are modelled
		into the asset -- so this is furniture being skipped rather than removed.
	]]
	if not shelled then
		box(ctx, "SeatBack", Vector3.new(2.2, 2.0, 0.3), Color3.fromRGB(42, 42, 46),
			Enum.Material.Fabric, CFrame.new(-1.5, 4.4, -4.0))
		box(ctx, "PassengerSeat", Vector3.new(2.2, 0.5, 2.0), Color3.fromRGB(42, 42, 46),
			Enum.Material.Fabric, CFrame.new(1.5, 3.35, -5.1))
		box(ctx, "PassengerBack", Vector3.new(2.2, 2.0, 0.3), Color3.fromRGB(42, 42, 46),
			Enum.Material.Fabric, CFrame.new(1.5, 4.4, -4.0))
		box(ctx, "Dashboard", Vector3.new(Config.TruckWidth - 1.0, 0.8, 0.6), BODY_BLACK,
			Enum.Material.SmoothPlastic, CFrame.new(0, 4.3, -7.1))
		cylZ(ctx, "SteeringWheel", 0.16, 1.5, Color3.fromRGB(28, 28, 30), Enum.Material.SmoothPlastic,
			CFrame.new(-1.5, 4.75, -6.6) * CFrame.Angles(math.rad(-22), 0, 0))
	end

	--[ bookkeeping the rest of the system reads ]----------------------------
	model.PrimaryPart = base
	model:SetAttribute("Tank", Config.TankCapacity)
	model:SetAttribute("TankCapacity", Config.TankCapacity)

	model:SetAttribute("HosePaidOut", 0)

	-- The drive and steer constraints are collected into folders so the control
	-- script can find them without walking the whole model every frame.
	local driveFolder = Instance.new("Folder")
	driveFolder.Name = "Drives"
	driveFolder.Parent = model
	for _, h in ipairs(drives) do
		local ref = Instance.new("ObjectValue")
		ref.Name = "Drive"
		ref.Value = h
		ref.Parent = driveFolder
	end

	local steerFolder = Instance.new("Folder")
	steerFolder.Name = "Steers"
	steerFolder.Parent = model
	for _, h in ipairs(steers) do
		local ref = Instance.new("ObjectValue")
		ref.Name = "Steer"
		ref.Value = h
		ref.Parent = steerFolder
	end

	--[[
		Livery, applied last by recolouring rather than by threading a colour
		through forty call sites. Every white panel on the cab is the one constant,
		so matching on it repaints exactly the bodywork and leaves the chrome, the
		glass, the black tank and the amber beacons alone.
	]]
	--[[
		Skipped entirely on a shell rig, and that is not an oversight.

		The recolour matches on CAB_WHITE, which is a constant this file paints its
		own panels with; an imported body is whatever colours it shipped in, so the
		match either finds nothing or -- worse -- finds one unrelated panel that
		happens to be that exact white and repaints only that. The stripes have the
		same problem from the other end: they are placed against the flatbed's
		flanks at Z -5.4 and its rear at -10.85, and on other bodywork they hang in
		mid-air or bury themselves inside a wing.

		A shell rig carries its livery in the model it was authored as, which is the
		only place that can know where its own flanks are.
	]]
	if livery and not shelled then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Color == CAB_WHITE then
				d.Color = livery.cab
			end
		end
		for _, s in ipairs({ -1, 1 }) do
			box(ctx, "LiveryStripe", Vector3.new(0.14, 0.42, 4.3), livery.tint,
				Enum.Material.SmoothPlastic,
				CFrame.new(s * (Config.TruckWidth * 0.5 - 0.16), 3.35, -5.4))
		end
		box(ctx, "LiveryBand", Vector3.new(Config.TruckWidth - 0.5, 0.35, 0.16), livery.tint,
			Enum.Material.SmoothPlastic, CFrame.new(0, 3.35, -10.85))
	end

	model.Parent = parent
	return model
end

return TruckBuilder
