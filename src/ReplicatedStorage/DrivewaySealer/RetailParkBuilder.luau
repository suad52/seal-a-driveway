--!strict
--[[
	RetailParkBuilder -- "Megamart Supercentre", and the six-block lot in front of
	it. A sibling of DealershipBuilder: the recipe the district was made from, and
	the fallback for a place that has lost it.

	To rebuild the saved one after editing this file, from the command bar:

		local M = require(game.ReplicatedStorage.DrivewaySealer.RetailParkBuilder)
		local old = workspace:FindFirstChild("RetailPark")
		if old then old:Destroy() end
		M.build(CFrame.new(1600, 0, -1470), workspace)

	No rotation in that snippet, and for the same reason DealershipBuilder gives:
	every number below is a world survey coordinate against DATUM, and `at()` only
	translates. A turned model would swap which axis is 144 studs of bay and which
	is 148 of row.

	The site is parked at x 1600 so it is clear of everything else on the map. Its
	Z centre is -1470, which is deliberately the Circuit infield's Z centre -- so
	if this ever replaces the racetrack, the move is `M.build(CFrame.new(0, 0,
	-1470), workspace)` and nothing else changes. Do NOT rename the model or the
	slabs when you do it: Sections.keyOf writes a slab's full path into every
	player's profile, so a rename silently un-finishes the lot for everyone who
	has already sealed it.

	⚠ DO NOT RUN THAT SNIPPET ANY MORE (2026-08-13). EDIT THIS FILE BY HAND.

	The module and the baked place have drifted, and a rebuild would settle the
	disagreement by destroying the place's half of it:

	  * ROAD_HALF is 180 here, which puts BoundRoadE/W at world x +/-180. Measured,
	    they stand at +/-62. A rebuild walks two correct walls 118 studs outward.
	  * this file tags SIX slabs -- the six lot blocks. The place has TWELVE. The
	    four ring arms, the entry drive and the approach carriageway were tagged
	    after it was generated and are real jobs with real progress recorded
	    against them. A rebuild deletes six sealable roads, and because keyOf
	    writes a full path into the profile, everyone who finished one loses it.

	So everything since is mirrored in BY HAND, which is why the deck-park spur
	below is written out rather than derived from anything. The snippet above is
	kept as archaeology and as the fallback for a place that has lost the district
	entirely -- at which point six untagged roads are the smaller problem.

	WHY A PARKING LOT IS BUILT DIFFERENTLY FROM A DRIVEWAY

	The lot is six separate slabs rather than one, because a DrivewaySurface grid
	is capped at Config.MaxGridCells and quietly RELAXES its cell size to fit --
	no warning, just a blurrier surface than its neighbours. One 464 x 296 slab
	would relax to about 0.72 studs a cell against a driveway's 0.16. At 144 x 148
	each block lands on 0.335, which is just inside Drive_Casa's 0.345, the
	coarsest thing the game already ships and looks right at.

	The seams are load-bearing, not arbitrary. Column seams fall in the 16-stud
	planting islands and the row seam falls on the back-to-back bay line at
	z -1381, so no seam ever runs through a bay a player is squeegeeing across.

	And NOTHING vertical stands on a slab. Every mast, corral, bollard and parked
	car is on an island, the apron or the ring road. DrivewaySurface builds its
	mask by raycasting and then subtracts anything anchored, queryable and opaque
	standing between +0.06 and +2.50 above the slab -- with an op.MaxParts of 400
	that TRUNCATES SILENTLY. Keeping the slabs clear means the mask is the
	rectangle, coverage can always reach Config.CompleteAt, and JobArea is honest
	without having to subtract anything.

	Painted lines are the one thing allowed on top, and every one of them is laid
	with `line`, which sets CanQuery false. A stripe that forgot it would read as
	a 0.08-stud blocker and punch a permanent hole in its own bay.
]]

local CollectionService = game:GetService("CollectionService")

local RetailParkBuilder = {}

local PAY_MULTIPLIER = 2.3

--==[ PALETTE ]===============================================================

local WALL     = Color3.fromRGB(236, 233, 222)
local REVEAL   = Color3.fromRGB(252, 250, 244)
local BLUE     = Color3.fromRGB(64, 142, 196)
local YELLOW   = Color3.fromRGB(240, 176, 44)
local INK      = Color3.fromRGB(38, 44, 56)
local SLATE    = Color3.fromRGB(58, 64, 74)
local LINER    = Color3.fromRGB(203, 206, 211)
local STEEL    = Color3.fromRGB(118, 124, 132)
local PAVING   = Color3.fromRGB(219, 216, 202)
local KERBC    = Color3.fromRGB(237, 235, 226)
local CONCRETE = Color3.fromRGB(92, 96, 104)
local GLASSC   = Color3.fromRGB(150, 200, 232)
local MULLION  = Color3.fromRGB(224, 227, 232)
local NEONW    = Color3.fromRGB(246, 240, 224)
local WHITEL   = Color3.fromRGB(228, 228, 224)
local SIGNTX   = Color3.fromRGB(255, 214, 92)
local SUBTX    = Color3.fromRGB(198, 210, 224)
local GRASS    = Color3.fromRGB(117, 205, 87)
local LAWN     = Color3.fromRGB(133, 205, 96)

local TARMAC   = Color3.fromRGB(121, 119, 110)
local FRESH    = Color3.fromRGB(62, 64, 70)

--==[ THE SURVEY ]============================================================

local DATUM = Vector3.new(1600, 0, -1470)

local PAD_TOP   = 0.00
local WALK_TOP  = 0.06
local ROAD_TOP  = 0.08
local SLAB_TOP  = 0.08
local KERB_TOP  = 0.10
local PAINT_T   = 0.10   -- stripe thickness, and so also how far it stands proud
local PAINT_Y   = 0.13   -- centre of that stripe lying on the lot: 0.08 .. 0.18
local FLOOR_TOP = 0.30   -- the store floor, a step up off the apron

local SITE_X0, SITE_X1 = 1150, 2050
local SITE_Z0, SITE_Z1 = -1855, -1085
local WOOD_M = 90
local WOOD_X0, WOOD_X1 = SITE_X0 - WOOD_M, SITE_X1 + WOOD_M
local WOOD_Z0 = SITE_Z0 - WOOD_M

local function span(a: number, b: number): number
	return math.abs(a - b)
end

-- The store.
local STORE_X0, STORE_X1 = 1390, 1810
local STORE_Z0, STORE_Z1 = -1775, -1595
local WALL_H  = 32      -- top of the shell wall
local FASCIA_H = 2.2    -- blue band above it
local PARA_H   = 2.0    -- cream parapet above that
local WALL_T   = 1.0
local LOBBY_Z  = -1631  -- back of the entrance lobby; the rest of the box is dark

-- The apron in front of the doors, the fire lane, and the lot.
local APRON_X0, APRON_X1 = 1360, 1840
local APRON_Z0, APRON_Z1 = -1595, -1559

local RING_W = 30
local LOT_X0, LOT_X1 = 1368, 1832
local LOT_Z0, LOT_Z1 = -1529, -1233

local BAY_W, BAY_D, AISLE_D = 12, 24, 26
local COL_W, ROW_D = 144, 148
local ISLAND_W = 16
local COLS = { 1368, 1528, 1688 }   -- west edge of each of the three columns
local ROWS = { -1529, -1381 }       -- north edge of each of the two rows
local BAY_ROWS = { 0, 50, 74, 124 } -- north edge of each bay row, within a block

-- Garden centre and service yard.
local GARDEN_X0, GARDEN_X1 = 1300, 1390
local GARDEN_Z0, GARDEN_Z1 = -1755, -1595
local YARD_Z0, YARD_Z1 = -1835, -1775

-- Entry drive, on the site's south edge.
local ENTRY_X = 1600
local ENTRY_Z0, ENTRY_Z1 = -1233, -1085

local LINK_Z    = -703       -- the Estate carriageway's north end
local ESTATE_Z  = -958       -- how far the Estate's ground slab already reaches
local GATE_Z    = -726       -- where this district's bounds meet the Estate's
local GATE_GAP  = 20         -- half-width of the doorway both districts leave there
local ROAD_HALF = 180
local ROADC     = Color3.fromRGB(121, 119, 110)  -- the map's public road grey
local DASHC     = Color3.fromRGB(251, 205, 59)

local SPUR_Z    = -1381      -- centreline: RingE's centre and the lot-row seam
local SPUR_X0   = 1862       -- RingE's east face; world x 262
local SPUR_X1   = 2055       -- where ParkingGarage takes the road over; world x 455

--==[ PRIMITIVES ]============================================================

type Ctx = {
	model: Model,
	origin: CFrame,
	folder: (name: string) -> Instance,
}

local function at(ctx: Ctx, x: number, y: number, z: number): CFrame
	return ctx.origin * CFrame.new(x - DATUM.X, y - DATUM.Y, z - DATUM.Z)
end

type Opts = {
	shape: Enum.PartType?,
	shadow: boolean?,
	query: boolean?,
	collide: boolean?,
	transparency: number?,
	reflectance: number?,
}

local function piece(into: Instance, name: string, size: Vector3, colour: Color3,
	material: Enum.Material, cf: CFrame, opts: Opts?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = (opts ~= nil) and opts.shadow == true
	p.CanQuery = (opts == nil) or (opts.query ~= false)
	p.CanCollide = (opts == nil) or (opts.collide ~= false)
	if opts then
		if opts.shape then p.Shape = opts.shape end
		if opts.transparency then p.Transparency = opts.transparency end
		if opts.reflectance then p.Reflectance = opts.reflectance end
	end
	p.CFrame = cf
	p.Parent = into
	return p
end

local function box(ctx: Ctx, into: Instance, name: string, sx: number, sy: number,
	sz: number, x: number, y: number, z: number, colour: Color3,
	material: Enum.Material, opts: Opts?): Part
	return piece(into, name, Vector3.new(sx, sy, sz), colour, material,
		at(ctx, x, y, z), opts)
end

-- Copied, not written through -- see the note in DealershipBuilder. Callers here
-- share one `prop` table across dozens of calls.
local function shaped(opts: Opts?): Opts
	local o: Opts = { shape = Enum.PartType.Cylinder }
	if opts then
		o.shadow = opts.shadow
		o.query = opts.query
		o.collide = opts.collide
		o.transparency = opts.transparency
	end
	return o
end

local function cylY(ctx: Ctx, into: Instance, name: string, len: number, dia: number,
	x: number, y: number, z: number, colour: Color3, material: Enum.Material,
	opts: Opts?): Part
	return piece(into, name, Vector3.new(len, dia, dia), colour, material,
		at(ctx, x, y, z) * CFrame.Angles(0, 0, math.rad(90)), shaped(opts))
end

local function cylZ(ctx: Ctx, into: Instance, name: string, len: number, dia: number,
	x: number, y: number, z: number, colour: Color3, material: Enum.Material,
	opts: Opts?): Part
	return piece(into, name, Vector3.new(len, dia, dia), colour, material,
		at(ctx, x, y, z) * CFrame.Angles(0, math.rad(90), 0), shaped(opts))
end

--==[ SIGNAGE ]===============================================================

-- LuckiestGuy in 255,214,92 is identity; GothamBold in 240,176,44 is every
-- operational label. Same rule as the dealership, and it is the strongest one
-- in the place.
local function ppsFor(letterStuds: number): number
	return 95 / letterStuds
end

local function surface(host: BasePart, face: Enum.NormalId, pps: number): SurfaceGui
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pps
	g.LightInfluence = 0
	g.Brightness = 1
	g.ZOffset = 0
	g.Parent = host
	return g
end

type Line = {
	text: string,
	h: number,
	y: number,
	colour: Color3?,
	font: Enum.Font?,
	name: string?,
}

local function lines(gui: SurfaceGui, rows: { Line })
	for i, l in ipairs(rows) do
		local t = Instance.new("TextLabel")
		t.Name = l.name or ("Line" .. i)
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, l.h)
		t.Position = UDim2.fromScale(0, l.y)
		t.Font = l.font or Enum.Font.GothamBold
		t.TextColor3 = l.colour or YELLOW
		t.Text = l.text
		t.TextScaled = true
		t.TextStrokeTransparency = 1
		t.Parent = gui
	end
end

-- Panel, gui and text in one call. The whole recipe, 11 call sites.
local function board(ctx: Ctx, into: Instance, name: string, sx: number, sy: number,
	sz: number, x: number, y: number, z: number, face: Enum.NormalId, pps: number,
	rows: { Line }, colour: Color3?): Part
	local p = box(ctx, into, name, sx, sy, sz, x, y, z, colour or INK,
		Enum.Material.SmoothPlastic, { query = false })
	lines(surface(p, face, pps), rows)
	return p
end

local function lamp(host: BasePart, colour: Color3, brightness: number, range: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Brightness = brightness
	l.Range = range
	l.Shadows = false
	l.Parent = host
end

local SOUTH = Enum.NormalId.Back
local NORTH = Enum.NormalId.Front

--==[ CLONED DRESSING ]=======================================================

local function donor(path: { string }): Instance?
	local node: Instance? = workspace
	for _, seg in ipairs(path) do
		node = node and node:FindFirstChild(seg)
	end
	return node
end

local function freeze(m: Instance, shadow: boolean)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CastShadow = shadow
			-- Props never answer a raycast, so the sealing tool cannot mistake a
			-- car bonnet for ground. Matches Neighbourhood.Scenery.
			d.CanQuery = false
		elseif d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("Script") then
			d:Destroy()
		end
	end
end

-- Seat by measurement, not arithmetic: rotate first, then lift by the gap
-- between where the bottom landed and where it was wanted.
local function seat(m: Model, x: number, y: number, z: number, yaw: number)
	m:PivotTo(CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(yaw), 0))
	local cf, size = m:GetBoundingBox()
	m:PivotTo(m:GetPivot() + Vector3.new(0, y - (cf.Position.Y - size.Y * 0.5), 0))
end

local function plant(ctx: Ctx, into: Instance, pool: Instance?, index: number,
	name: string, x: number, y: number, z: number, yaw: number): Model?
	if not pool then return nil end
	local kids = pool:GetChildren()
	if #kids == 0 then return nil end
	local src = kids[((index - 1) % #kids) + 1]
	if not src:IsA("Model") then return nil end
	local m = src:Clone()
	m.Name = name
	m.Parent = into
	freeze(m, name == "Tree")
	local p = at(ctx, x, y, z)
	seat(m, p.Position.X, p.Position.Y, p.Position.Z, yaw)
	return m
end

-- Bushes are loose MeshParts rather than Models, so they need their own copy.
local function scatter(ctx: Ctx, into: Instance, pool: Instance?, index: number,
	x: number, y: number, z: number, yaw: number): BasePart?
	if not pool then return nil end
	local kids = pool:GetChildren()
	if #kids == 0 then return nil end
	local src = kids[((index - 1) % #kids) + 1]
	if not src:IsA("BasePart") then return nil end
	local p = src:Clone()
	p.Name = "Bush"
	p.Anchored = true
	p.CanQuery = false
	p.CanCollide = false
	p.CastShadow = false
	p.CFrame = at(ctx, x, y + p.Size.Y * 0.5, z) * CFrame.Angles(0, math.rad(yaw), 0)
	p.Parent = into
	return p
end

--==[ SITE ]==================================================================

local function pad(ctx: Ctx)
	local f = ctx.folder("Site")
	local ground = { query = true }

	-- One slab for the whole site, finishes laid on top. Never tiled. It runs out
	-- to WOOD_* rather than SITE_*, because the treeline stands on it.
	box(ctx, f, "Ground", span(WOOD_X0, WOOD_X1), 6, span(WOOD_Z0, SITE_Z1),
		(WOOD_X0 + WOOD_X1) / 2, PAD_TOP - 3, (WOOD_Z0 + SITE_Z1) / 2,
		GRASS, Enum.Material.SmoothPlastic, ground)

	local verge: { { number } } = {
		{ 1240, -1470, 90, 700 }, { 1960, -1470, 90, 700 },
		{ 1600, -1810, 120, 60 }, { 1250, -1130, 180, 70 }, { 1950, -1130, 180, 70 },
	}
	for i, v in ipairs(verge) do
		box(ctx, f, "Verge" .. i, v[3], 1.6, v[4], v[1], PAD_TOP + 0.04 - 0.8, v[2],
			LAWN, Enum.Material.SmoothPlastic, { query = false, collide = false })
	end
end

local function roads(ctx: Ctx)
	local f = ctx.folder("Roads")
	local road = { query = true }
	local RX0, RX1 = LOT_X0 - RING_W, LOT_X1 + RING_W
	local RZ0, RZ1 = LOT_Z0 - RING_W, LOT_Z1 + RING_W

	-- North arm doubles as the fire lane in front of the doors; the two side arms
	-- stop at the lot so the corners are not two parts deep.
	box(ctx, f, "RingN", RX1 - RX0, 2, RING_W, (RX0 + RX1) / 2, ROAD_TOP - 1,
		LOT_Z0 - RING_W / 2, FRESH, Enum.Material.Asphalt, road)
	box(ctx, f, "RingS", RX1 - RX0, 2, RING_W, (RX0 + RX1) / 2, ROAD_TOP - 1,
		LOT_Z1 + RING_W / 2, FRESH, Enum.Material.Asphalt, road)
	box(ctx, f, "RingW", RING_W, 2, LOT_Z1 - LOT_Z0, LOT_X0 - RING_W / 2, ROAD_TOP - 1,
		(LOT_Z0 + LOT_Z1) / 2, FRESH, Enum.Material.Asphalt, road)
	box(ctx, f, "RingE", RING_W, 2, LOT_Z1 - LOT_Z0, LOT_X1 + RING_W / 2, ROAD_TOP - 1,
		(LOT_Z0 + LOT_Z1) / 2, FRESH, Enum.Material.Asphalt, road)

	box(ctx, f, "EntryDrive", 30, 2, ENTRY_Z1 - ENTRY_Z0, ENTRY_X, ROAD_TOP - 1,
		(ENTRY_Z0 + ENTRY_Z1) / 2, FRESH, Enum.Material.Asphalt, road)
	-- A flare where it meets the ring, so a car is not turning through a corner.
	box(ctx, f, "EntryFlare", 70, 2, 26, ENTRY_X, ROAD_TOP - 1, ENTRY_Z0 + 13,
		FRESH, Enum.Material.Asphalt, road)

	-- The apron the doors open onto. Sidewalk height, so the kerb below reads as
	-- the band between it and the fire lane.
	box(ctx, f, "Apron", APRON_X1 - APRON_X0, 2, APRON_Z1 - APRON_Z0,
		(APRON_X0 + APRON_X1) / 2, WALK_TOP - 1, (APRON_Z0 + APRON_Z1) / 2,
		PAVING, Enum.Material.SmoothPlastic, road)

	local kerb = { query = false }
	box(ctx, f, "KerbApron", APRON_X1 - APRON_X0 + 4, 2, 2, (APRON_X0 + APRON_X1) / 2,
		KERB_TOP - 1, APRON_Z1 + 1, KERBC, Enum.Material.SmoothPlastic, kerb)
	box(ctx, f, "KerbW", 2, 2, RZ1 - RZ0 + 4, RX0 - 1, KERB_TOP - 1, (RZ0 + RZ1) / 2,
		KERBC, Enum.Material.SmoothPlastic, kerb)
	-- East kerb is in two pieces because the deck-park spur comes through it, on
	-- the same +/-GATE_GAP doorway the south kerb leaves for the entry drive.
	box(ctx, f, "KerbE_S", 2, 2, span(SPUR_Z + GATE_GAP, RZ1 + 2), RX1 + 1, KERB_TOP - 1,
		(SPUR_Z + GATE_GAP + RZ1 + 2) / 2, KERBC, Enum.Material.SmoothPlastic, kerb)
	box(ctx, f, "KerbE_N", 2, 2, span(RZ0 - 2, SPUR_Z - GATE_GAP), RX1 + 1, KERB_TOP - 1,
		(RZ0 - 2 + SPUR_Z - GATE_GAP) / 2, KERBC, Enum.Material.SmoothPlastic, kerb)
	-- South kerb is in two pieces because the entry drive comes through it.
	local gapW, gapE = ENTRY_X - 17, ENTRY_X + 17
	box(ctx, f, "KerbS_W", gapW - (RX0 - 1), 2, 2, ((RX0 - 1) + gapW) / 2, KERB_TOP - 1,
		RZ1 + 1, KERBC, Enum.Material.SmoothPlastic, kerb)
	box(ctx, f, "KerbS_E", (RX1 + 1) - gapE, 2, 2, (gapE + (RX1 + 1)) / 2, KERB_TOP - 1,
		RZ1 + 1, KERBC, Enum.Material.SmoothPlastic, kerb)
	box(ctx, f, "KerbEntryW", 2, 2, ENTRY_Z1 - ENTRY_Z0 - 26, ENTRY_X - 16, KERB_TOP - 1,
		(ENTRY_Z0 + ENTRY_Z1) / 2 + 13, KERBC, Enum.Material.SmoothPlastic, kerb)
	box(ctx, f, "KerbEntryE", 2, 2, ENTRY_Z1 - ENTRY_Z0 - 26, ENTRY_X + 16, KERB_TOP - 1,
		(ENTRY_Z0 + ENTRY_Z1) / 2 + 13, KERBC, Enum.Material.SmoothPlastic, kerb)
	box(ctx, f, "SpurE", span(SPUR_X0, SPUR_X1), 2, 30, (SPUR_X0 + SPUR_X1) / 2,
		ROAD_TOP - 1, SPUR_Z, FRESH, Enum.Material.Asphalt, road)
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, f, "KerbSpur_" .. (s < 0 and "N" or "S"), span(SPUR_X0, SPUR_X1), 2, 2,
			(SPUR_X0 + SPUR_X1) / 2, KERB_TOP - 1, SPUR_Z + s * 16, KERBC,
			Enum.Material.SmoothPlastic, kerb)
	end
end

--==[ THE LOT ]===============================================================

local LETTERS = { "A", "B", "C", "D", "E", "F" }

local function lot(ctx: Ctx): { BasePart }
	local f = ctx.folder("Lot")
	local slabs: { BasePart } = {}
	local n = 0

	for ri, z0 in ipairs(ROWS) do
		for ci, x0 in ipairs(COLS) do
			n += 1
			local slab = box(ctx, f, "Lot_" .. LETTERS[n], COL_W, 0.5, ROW_D,
				x0 + COL_W / 2, SLAB_TOP - 0.25, z0 + ROW_D / 2,
				TARMAC, Enum.Material.SmoothPlastic, { query = true })

			slab:SetAttribute("DrivewayName", ("Megamart Lot %s - %d Bays")
				:format(LETTERS[n], (COL_W / BAY_W) * #BAY_ROWS))
			slab:SetAttribute("JobArea", COL_W * ROW_D)
			slabs[#slabs + 1] = slab
		end
	end

	-- Islands. Kerb frame with a planting bed dropped inside it, which is why
	-- the bed is 12 of the 16 and sits 0.04 proud of the kerb rather than level.
	for i, x0 in ipairs({ COLS[1] + COL_W, COLS[2] + COL_W }) do
		box(ctx, f, "Island" .. i, ISLAND_W, 2, LOT_Z1 - LOT_Z0, x0 + ISLAND_W / 2,
			KERB_TOP - 1, (LOT_Z0 + LOT_Z1) / 2, KERBC, Enum.Material.SmoothPlastic,
			{ query = false })
		box(ctx, f, "IslandBed" .. i, ISLAND_W - 4, 1.6, LOT_Z1 - LOT_Z0 - 4,
			x0 + ISLAND_W / 2, KERB_TOP + 0.04 - 0.8, (LOT_Z0 + LOT_Z1) / 2,
			LAWN, Enum.Material.SmoothPlastic, { query = false, collide = false })
	end

	return slabs
end

--==[ MARKINGS ]==============================================================

local function markings(ctx: Ctx)
	local f = ctx.folder("Markings")
	local line = { query = false, collide = false }

	for _, z0 in ipairs(ROWS) do
		for _, x0 in ipairs(COLS) do
			-- Bay dividers. Rows B and C are back to back, so one 48-long stripe
			-- does both rather than two abutting 24s with a seam down the middle.
			local runs = { { 0, BAY_D }, { 50, BAY_D * 2 }, { 124, BAY_D } }
			for _, r in ipairs(runs) do
				for i = 0, COL_W / BAY_W do
					box(ctx, f, "BayLine", 0.45, PAINT_T, r[2], x0 + i * BAY_W, PAINT_Y,
						z0 + r[1] + r[2] / 2, WHITEL, Enum.Material.SmoothPlastic, line)
				end
			end
			-- Head lines: where the bumpers stop. One at the closed end of row A
			-- and one on the back-to-back joint; the lot's south edge gets its own
			-- below so it is not drawn twice.
			for _, dz in ipairs({ 0, 74 }) do
				box(ctx, f, "HeadLine", COL_W, PAINT_T, 0.45, x0 + COL_W / 2, PAINT_Y,
					z0 + dz, WHITEL, Enum.Material.SmoothPlastic, line)
			end
		end
	end
	for _, x0 in ipairs(COLS) do
		box(ctx, f, "HeadLine", COL_W, PAINT_T, 0.45, x0 + COL_W / 2, PAINT_Y, LOT_Z1,
			WHITEL, Enum.Material.SmoothPlastic, line)
	end

	-- Aisle arrows. Two barbs off a shaft, turned to point the way the aisle runs.
	local function arrow(x: number, z: number, heading: number)
		local function bar(len: number, dx: number, dz: number, yaw: number)
			piece(f, "Arrow", Vector3.new(0.8, PAINT_T, len), WHITEL,
				Enum.Material.SmoothPlastic,
				at(ctx, x + dx, PAINT_Y, z + dz) * CFrame.Angles(0, math.rad(yaw), 0), line)
		end
		local s = if heading > 0 then 1 else -1
		bar(11, 0, 0, 0)
		bar(5.5, -1.7, s * 4.0, s * 40)
		bar(5.5, 1.7, s * 4.0, s * -40)
	end
	for _, z0 in ipairs(ROWS) do
		for _, x0 in ipairs(COLS) do
			arrow(x0 + 36, z0 + 37, 1)
			arrow(x0 + 108, z0 + 111, -1)
		end
	end

	local sign = { query = false, collide = false }
	for i = 4, 7 do
		local bx = COLS[2] + i * BAY_W + BAY_W / 2
		-- At the nose of the bay, just inside the head line, rather than beyond it:
		-- north of that line is the ring road, and signs do not stand in traffic.
		local bz = ROWS[1] + 1.4
		box(ctx, f, "AccessiblePost", 0.28, 5.2, 0.28, bx, 2.6, bz,
			STEEL, Enum.Material.Metal, sign)
		local panel = box(ctx, f, "AccessibleSign", 3.2, 3.2, 0.22, bx, 6.6, bz,
			BLUE, Enum.Material.SmoothPlastic, sign)

		lines(surface(panel, Enum.NormalId.Back, ppsFor(2.3)), {
			{ text = "\u{267F}", h = 0.9, y = 0.05, colour = WHITEL, name = "Symbol" },
		})
	end

	-- Crossings from the lot to each door, and the yellow fire-lane edge that
	-- runs the length of the apron kerb.
	for _, cx in ipairs({ 1480, 1720 }) do
		for i = 0, 6 do
			box(ctx, f, "Crossing", 2, PAINT_T, RING_W - 4, cx - 12 + i * 4, PAINT_Y,
				LOT_Z0 - RING_W / 2, WHITEL, Enum.Material.SmoothPlastic, line)
		end
	end
	box(ctx, f, "FireLaneEdge", APRON_X1 - APRON_X0, PAINT_T, 0.5,
		(APRON_X0 + APRON_X1) / 2, PAINT_Y, LOT_Z0 - RING_W + 1.6,
		YELLOW, Enum.Material.SmoothPlastic, line)

	-- Centre line up the entry drive.
	for i = 0, 5 do
		box(ctx, f, "EntryDash", 0.5, PAINT_T, 12, ENTRY_X, PAINT_Y,
			ENTRY_Z1 - 8 - i * 24, YELLOW, Enum.Material.SmoothPlastic, line)
	end
end

--==[ THE STORE ]=============================================================

local DOORS = { 1450, 1690 }        -- west edge of each 60-wide entrance
local DOOR_W, DOOR_H = 60, 18.3
local DOCKS = { 1540, 1610, 1680, 1750 }

local function store(ctx: Ctx)
	local f = ctx.folder("Store")
	local solid = { shadow = true }
	local midX = (STORE_X0 + STORE_X1) / 2
	local midZ = (STORE_Z0 + STORE_Z1) / 2
	local W, D = STORE_X1 - STORE_X0, STORE_Z1 - STORE_Z0

	box(ctx, f, "Floor", W, 0.6, D, midX, FLOOR_TOP - 0.3, midZ,
		CONCRETE, Enum.Material.Concrete, { query = true })

	box(ctx, f, "WallNorth", W, WALL_H, WALL_T, midX, WALL_H / 2, STORE_Z0 + WALL_T / 2,
		WALL, Enum.Material.SmoothPlastic, solid)
	box(ctx, f, "WallWest", WALL_T, WALL_H, D, STORE_X0 + WALL_T / 2, WALL_H / 2, midZ,
		WALL, Enum.Material.SmoothPlastic, solid)
	box(ctx, f, "WallEast", WALL_T, WALL_H, D, STORE_X1 - WALL_T / 2, WALL_H / 2, midZ,
		WALL, Enum.Material.SmoothPlastic, solid)

	-- The south wall is the frontage, so it comes in the three pieces the two
	-- entrances leave, plus a lintel over each.
	local segs = {
		{ STORE_X0, DOORS[1] }, { DOORS[1] + DOOR_W, DOORS[2] },
		{ DOORS[2] + DOOR_W, STORE_X1 },
	}
	for i, s in ipairs(segs) do
		box(ctx, f, "WallSouth_" .. i, s[2] - s[1], WALL_H, WALL_T, (s[1] + s[2]) / 2,
			WALL_H / 2, STORE_Z1 - WALL_T / 2, WALL, Enum.Material.SmoothPlastic, solid)
	end
	for i, x in ipairs(DOORS) do
		box(ctx, f, "Lintel" .. i, DOOR_W, WALL_H - DOOR_H, WALL_T, x + DOOR_W / 2,
			(WALL_H + DOOR_H) / 2, STORE_Z1 - WALL_T / 2, WALL,
			Enum.Material.SmoothPlastic, solid)
	end

	box(ctx, f, "RoofDeck", W, 0.9, D, midX, WALL_H + 0.45, midZ, STEEL,
		Enum.Material.Metal, { shadow = true, query = false })

	-- Fascia then parapet, both standing 0.8 proud of the wall so the shell reads
	-- as a band rather than a flat face.
	local bands = {
		{ "S", W + 2, 0.8, midX, STORE_Z1 + 0.4 },
		{ "N", W + 2, 0.8, midX, STORE_Z0 - 0.4 },
		{ "W", 0.8, D + 2, STORE_X0 - 0.4, midZ },
		{ "E", 0.8, D + 2, STORE_X1 + 0.4, midZ },
	}
	for _, b in ipairs(bands) do
		box(ctx, f, "Fascia_" .. b[1], b[2], FASCIA_H, b[3], b[4],
			WALL_H + FASCIA_H / 2, b[5], BLUE, Enum.Material.SmoothPlastic, solid)
		box(ctx, f, "Parapet_" .. b[1], b[2], PARA_H, b[3], b[4],
			WALL_H + FASCIA_H + PARA_H / 2, b[5], WALL, Enum.Material.SmoothPlastic, solid)
	end

	-- Roof plant. Nothing is ever seen from up here, but the silhouette off the
	-- lot is a flat line without it.
	local plant = { query = false }
	for i, x in ipairs({ 1450, 1530, 1610, 1690, 1770 }) do
		box(ctx, f, "RoofUnit" .. i, 16, 4, 11, x, WALL_H + 2.9, midZ + (i % 2) * 40 - 20,
			STEEL, Enum.Material.Metal, plant)
	end
	for i, x in ipairs({ 1420, 1600, 1780 }) do
		cylZ(ctx, f, "RoofDuct" .. i, 60, 3.2, x, WALL_H + 2.5, midZ - 45,
			STEEL, Enum.Material.Metal, plant)
	end

	-- Deliveries end. The doors are applied panels, not openings -- the box is
	-- sealed and nothing behind them is modelled.
	for i, x in ipairs(DOCKS) do
		local z = STORE_Z0 - 0.35
		box(ctx, f, "DockPanel" .. i, 24, 15, 0.4, x, 7.8, z, LINER,
			Enum.Material.SmoothPlastic, plant)
		box(ctx, f, "DockSlat" .. i, 24, 0.9, 0.5, x, 0.75, z - 0.1, YELLOW,
			Enum.Material.SmoothPlastic, plant)
		box(ctx, f, "DockHead" .. i, 26, 0.8, 0.6, x, 15.7, z - 0.1, REVEAL,
			Enum.Material.SmoothPlastic, plant)
		for _, s in ipairs({ -1, 1 }) do
			box(ctx, f, "DockReveal" .. i, 1, 16, 0.6, x + s * 12.5, 8, z - 0.1, REVEAL,
				Enum.Material.SmoothPlastic, plant)
			box(ctx, f, "DockBumper" .. i, 1.2, 1.8, 1, x + s * 11, 1.2, z - 0.7, INK,
				Enum.Material.SmoothPlastic, plant)
		end
	end
end

local function front(ctx: Ctx)
	local f = ctx.folder("Frontage")
	local pane = { transparency = 0.45, query = false }
	local trim = { query = false }
	local fix = { query = false, collide = false }
	local CAN_Y, CAN_Z = 20.1, -1589

	box(ctx, f, "Canopy", APRON_X1 - APRON_X0, 1.2, 12, (APRON_X0 + APRON_X1) / 2,
		CAN_Y, CAN_Z, BLUE, Enum.Material.SmoothPlastic, { shadow = true })
	box(ctx, f, "CanopyFascia", APRON_X1 - APRON_X0, 2.4, 0.8,
		(APRON_X0 + APRON_X1) / 2, CAN_Y - 1.2, CAN_Z + 5.6, BLUE,
		Enum.Material.SmoothPlastic, { shadow = true })
	for i, x in ipairs({ 1372, 1420, 1560, 1640, 1780, 1828 }) do
		cylY(ctx, f, "CanopyColumn" .. i, CAN_Y - 0.6, 1.2, x, (CAN_Y - 0.6) / 2,
			CAN_Z + 3, STEEL, Enum.Material.Metal, { shadow = true })
	end
	-- Soffit strips, lit on half of them: a tube that is only a tube still reads,
	-- and the light instance is the expensive half.
	for i = 1, 8 do
		local x = APRON_X0 + 30 + (i - 1) * 60
		local t = box(ctx, f, "CanopyTube", 26, 0.16, 1.1, x, CAN_Y - 0.68, CAN_Z,
			NEONW, Enum.Material.Neon, fix)
		if i % 2 == 1 then lamp(t, Color3.fromRGB(255, 238, 210), 0.6, 18) end
	end

	for d, x0 in ipairs(DOORS) do
		local z = STORE_Z1 - WALL_T / 2
		for i = 0, 4 do
			box(ctx, f, "Glass_" .. d, 11.4, DOOR_H - 1.2, 0.4, x0 + 6 + i * 12,
				(DOOR_H + 0.6) / 2, z, GLASSC, Enum.Material.SmoothPlastic, pane)
		end
		for i = 0, 5 do
			box(ctx, f, "Mullion_" .. d, 0.6, DOOR_H - 1.2, 0.55, x0 + i * 12,
				(DOOR_H + 0.6) / 2, z - 0.1, MULLION, Enum.Material.SmoothPlastic, trim)
		end
		box(ctx, f, "DoorHead_" .. d, DOOR_W + 1, 0.9, 0.7, x0 + DOOR_W / 2,
			DOOR_H - 0.15, z - 0.1, REVEAL, Enum.Material.SmoothPlastic, trim)
		box(ctx, f, "DoorCill_" .. d, DOOR_W + 1, 0.6, 0.7, x0 + DOOR_W / 2, 0.6,
			z - 0.1, REVEAL, Enum.Material.SmoothPlastic, trim)
	end

	local lw = STORE_X1 - STORE_X0 - 2
	local lz = (LOBBY_Z + STORE_Z1) / 2
	local ld = STORE_Z1 - LOBBY_Z
	box(ctx, f, "LobbyFloor", lw, 0.2, ld, (STORE_X0 + STORE_X1) / 2, FLOOR_TOP + 0.1,
		lz, PAVING, Enum.Material.SmoothPlastic, trim)
	box(ctx, f, "LobbyCeiling", lw, 0.4, ld, (STORE_X0 + STORE_X1) / 2, 14, lz,
		LINER, Enum.Material.SmoothPlastic, trim)
	box(ctx, f, "LobbyBack", lw, WALL_H, 1, (STORE_X0 + STORE_X1) / 2, WALL_H / 2,
		LOBBY_Z, LINER, Enum.Material.SmoothPlastic, trim)
	box(ctx, f, "LobbyDado", lw, 5.3, 0.2, (STORE_X0 + STORE_X1) / 2, 2.95,
		LOBBY_Z + 0.6, SLATE, Enum.Material.SmoothPlastic, trim)
	box(ctx, f, "LobbyRail", lw, 0.3, 0.22, (STORE_X0 + STORE_X1) / 2, 5.75,
		LOBBY_Z + 0.6, YELLOW, Enum.Material.SmoothPlastic, trim)
	for i = 1, 6 do
		local x = STORE_X0 + 40 + (i - 1) * 68
		box(ctx, f, "StripHousing", 24, 0.5, 1.5, x, 13.6, lz, SLATE,
			Enum.Material.Metal, fix)
		local t = box(ctx, f, "StripTube", 23, 0.16, 1.05, x, 13.3, lz, NEONW,
			Enum.Material.Neon, fix)
		if i % 2 == 1 then lamp(t, Color3.fromRGB(255, 244, 214), 0.85, 30) end
		box(ctx, f, "Checkout", 3.4, 3.2, 13, x, FLOOR_TOP + 1.8, lz - 4, LINER,
			Enum.Material.SmoothPlastic, trim)
		box(ctx, f, "CheckoutTop", 3.8, 0.3, 13.4, x, FLOOR_TOP + 3.55, lz - 4, INK,
			Enum.Material.SmoothPlastic, trim)
	end
end

--==[ GARDEN CENTRE AND SERVICE YARD ]========================================

local SOIL = Color3.fromRGB(104, 84, 62)

local function garden(ctx: Ctx, bushes: Instance?, trees: Instance?)
	local f = ctx.folder("Garden")
	local trim = { query = false }
	local mesh = { query = false, transparency = 0.5 }
	local midX, midZ = (GARDEN_X0 + GARDEN_X1) / 2, (GARDEN_Z0 + GARDEN_Z1) / 2
	local W, D = GARDEN_X1 - GARDEN_X0, GARDEN_Z1 - GARDEN_Z0

	box(ctx, f, "GardenPaving", W, 0.5, D, midX, SLAB_TOP - 0.25, midZ, PAVING,
		Enum.Material.SmoothPlastic, { query = true })

	local function run(name: string, sx: number, sz: number, x: number, z: number, n: number,
		stepX: number, stepZ: number)
		box(ctx, f, name .. "Mesh", sx, 10, sz, x, 5.6, z, STEEL, Enum.Material.Metal, mesh)
		box(ctx, f, name .. "Rail", sx + 0.4, 0.4, sz + 0.4, x, 10.8, z, SLATE,
			Enum.Material.Metal, trim)
		for i = 0, n do
			cylY(ctx, f, name .. "Post", 11.6, 0.8, x - stepX * n / 2 + i * stepX, 5.8,
				z - stepZ * n / 2 + i * stepZ, SLATE, Enum.Material.Metal, trim)
		end
	end
	run("FenceW", 0.3, D, GARDEN_X0, midZ, 8, 0, D / 8)
	run("FenceN", W, 0.3, midX, GARDEN_Z0, 5, W / 5, 0)
	run("FenceS", W - 20, 0.3, midX - 4, GARDEN_Z1, 4, (W - 20) / 4, 0)

	-- Benching, and the stock on it.
	for i = 0, 3 do
		local z = GARDEN_Z0 + 26 + i * 34
		box(ctx, f, "Bench", 60, 2.4, 10, midX, 1.3, z, SLATE, Enum.Material.Metal, trim)
		box(ctx, f, "BenchTray", 58, 0.7, 8.6, midX, 2.75, z, SOIL,
			Enum.Material.Ground, trim)
		for j = 0, 5 do
			scatter(ctx, f, bushes, i * 6 + j + 1, midX - 25 + j * 10, 3.1, z, j * 47)
		end
	end
	plant(ctx, f, trees, 3, "Tree", GARDEN_X0 + 20, PAD_TOP, GARDEN_Z1 - 26, 0)
	plant(ctx, f, trees, 9, "Tree", GARDEN_X0 + 20, PAD_TOP, GARDEN_Z0 + 30, 120)

	board(ctx, f, "GardenSign", 34, 5, 0.6, midX - 4, 13.6, GARDEN_Z1 + 0.5, SOUTH,
		ppsFor(5), {
		{ text = "GARDEN CENTRE", h = 1, y = 0, colour = SIGNTX, font = Enum.Font.LuckiestGuy },
	})
end

local function service(ctx: Ctx)
	local f = ctx.folder("Service")
	local trim = { query = false }
	local midZ = (YARD_Z0 + YARD_Z1) / 2

	box(ctx, f, "Yard", 330, 2, YARD_Z1 - YARD_Z0, 1645, ROAD_TOP - 1, midZ, FRESH,
		Enum.Material.Asphalt, { query = true })
	box(ctx, f, "YardKerb", 334, 2, 2, 1645, KERB_TOP - 1, YARD_Z0 - 1, KERBC,
		Enum.Material.SmoothPlastic, trim)

	box(ctx, f, "Compactor", 14, 9, 22, 1500, 4.6, midZ, SLATE, Enum.Material.Metal, trim)
	box(ctx, f, "CompactorChute", 6, 4, 6, 1500, 11, midZ + 6, STEEL,
		Enum.Material.Metal, trim)
	for i = 0, 5 do
		cylY(ctx, f, "YardBollard", 3.8, 1.1, 1530 + i * 56, 1.9, YARD_Z0 + 8, YELLOW,
			Enum.Material.Metal, trim)
	end

	board(ctx, f, "DeliveriesSign", 26, 3.6, 0.6, 1690, 19, STORE_Z0 - 0.9, NORTH,
		ppsFor(0.62 * 3.6), {
		{ text = "DELIVERIES", h = 0.62, y = 0 },
		{ text = "STAFF ONLY BEYOND THIS POINT", h = 0.3, y = 0.66, colour = SUBTX,
		  font = Enum.Font.Gotham },
	})
end

--==[ SIGNAGE ]===============================================================

local function signage(ctx: Ctx)
	local f = ctx.folder("Signage")
	local trim = { query = false }
	local fix = { query = false, collide = false }

	board(ctx, f, "StoreName", 130, 9, 0.7, 1600, 25.6, STORE_Z1 + 0.35, SOUTH,
		ppsFor(0.66 * 9), {
		{ text = "MEGAMART", h = 0.66, y = 0.02, colour = SIGNTX,
		  font = Enum.Font.LuckiestGuy },
		{ text = "S U P E R C E N T R E", h = 0.19, y = 0.73, colour = SUBTX,
		  font = Enum.Font.Gotham },
	})
	box(ctx, f, "NameGlow", 130, 0.18, 0.5, 1600, 20.8, STORE_Z1 + 0.35, YELLOW,
		Enum.Material.Neon, fix)

	-- Which door is which, on the canopy fascia where you read it from the lot.
	board(ctx, f, "DoorSign_1", 54, 1.8, 0.5, 1480, 18.9, -1582.7, SOUTH, ppsFor(1.8), {
		{ text = "GROCERY  \u{2022}  PHARMACY", h = 1, y = 0 },
	})
	board(ctx, f, "DoorSign_2", 54, 1.8, 0.5, 1720, 18.9, -1582.7, SOUTH, ppsFor(1.8), {
		{ text = "GENERAL MERCHANDISE", h = 1, y = 0 },
	})

	-- The pylon, out on the entry drive where it is read at speed.
	box(ctx, f, "PylonBase", 11, 2, 7, 1668, 1, -1150, CONCRETE, Enum.Material.Concrete, trim)
	cylY(ctx, f, "PylonPole", 30, 2.2, 1668, 15, -1150, SLATE, Enum.Material.Metal,
		{ shadow = true })
	local blade = box(ctx, f, "PylonBlade", 26, 15, 1.8, 1668, 34, -1150, INK,
		Enum.Material.SmoothPlastic, { shadow = true })
	box(ctx, f, "PylonCap", 27.4, 1.2, 2.4, 1668, 42.2, -1150, YELLOW,
		Enum.Material.SmoothPlastic, trim)
	for _, face in ipairs({ SOUTH, NORTH }) do
		lines(surface(blade, face, ppsFor(0.42 * 15)), {
			{ text = "MEGAMART", h = 0.42, y = 0.06, colour = SIGNTX,
			  font = Enum.Font.LuckiestGuy },
			{ text = "SUPERCENTRE", h = 0.16, y = 0.5, colour = SUBTX,
			  font = Enum.Font.Gotham },
			{ text = "OPEN 24 HOURS", h = 0.2, y = 0.72 },
		})
	end
	local up = Instance.new("SpotLight")
	up.Face = Enum.NormalId.Top
	up.Angle = 60
	up.Brightness = 1.4
	up.Range = 26
	up.Shadows = false
	up.Parent = blade

	local n = 0
	for _, z0 in ipairs(ROWS) do
		for _, x0 in ipairs(COLS) do
			n += 1
			local x = x0 - 3
			cylY(ctx, f, "LotPost", 7, 0.5, x, 3.5, z0 + 10, SLATE, Enum.Material.Metal, trim)
			board(ctx, f, "LotMarker", 5.4, 3.4, 0.4, x, 8.4, z0 + 10, SOUTH,
				ppsFor(0.56 * 3.4), {
				{ text = "LOT", h = 0.34, y = 0.04, colour = SUBTX, font = Enum.Font.Gotham },
				{ text = LETTERS[n], h = 0.56, y = 0.38, colour = SIGNTX,
				  font = Enum.Font.LuckiestGuy },
			})
		end
	end
end

--==[ LIGHTING ]==============================================================

local function lighting(ctx: Ctx)
	local f = ctx.folder("Lighting")
	local fix = { query = false, collide = false }
	local spots: { { number } } = {}
	for _, x in ipairs({ COLS[1] + COL_W + ISLAND_W / 2, COLS[2] + COL_W + ISLAND_W / 2 }) do
		for _, z in ipairs({ -1490, -1416, -1342, -1268 }) do
			spots[#spots + 1] = { x, z }
		end
	end
	for _, x in ipairs({ LOT_X0 - RING_W - 16, LOT_X1 + RING_W + 16 }) do
		for _, z in ipairs({ -1500, -1420, -1340, -1260 }) do
			spots[#spots + 1] = { x, z }
		end
	end

	for i, s in ipairs(spots) do
		local x, z = s[1], s[2]
		cylY(ctx, f, "MastBase", 1.4, 3.2, x, 0.7, z, CONCRETE, Enum.Material.Concrete,
			{ query = false })
		cylY(ctx, f, "MastPole", 30, 0.9, x, 15.7, z, SLATE, Enum.Material.Metal,
			{ query = false })
		box(ctx, f, "MastHead", 5, 1.2, 2.6, x, 30.4, z, SLATE, Enum.Material.Metal, fix)
		local lens = box(ctx, f, "MastLens", 4.2, 0.25, 1.7, x, 29.7, z, NEONW,
			Enum.Material.Neon, fix)
		if i % 8 ~= 0 and i % 8 ~= 5 then
			local sl = Instance.new("SpotLight")
			sl.Face = Enum.NormalId.Bottom
			sl.Angle = 100
			sl.Brightness = 1.6
			sl.Range = 34
			sl.Color = Color3.fromRGB(255, 244, 214)
			sl.Shadows = false
			sl.Parent = lens
		end
	end
end

--==[ DRESSING ]==============================================================

local function dressing(ctx: Ctx)
	local f = ctx.folder("Dressing")
	local trim = { query = false }
	local prop = { query = false, collide = false }
	local trees = donor({ "Neighbourhood", "Scenery", "Trees" })
	local bushes = donor({ "Neighbourhood", "Scenery", "Bushes" })
	local cars = donor({ "EstateDistrict", "Cars" })
	local islands = { COLS[1] + COL_W + ISLAND_W / 2, COLS[2] + COL_W + ISLAND_W / 2 }

	-- Trolley bays.
	for _, x in ipairs(islands) do
		for _, z in ipairs({ -1455, -1305 }) do
			for i = 0, 2 do
				for _, s in ipairs({ -1, 1 }) do
					cylY(ctx, f, "CorralPost", 4.2, 0.5, x + s * 4.5, 2.1, z - 6 + i * 6,
						YELLOW, Enum.Material.Metal, trim)
				end
			end
			for _, s in ipairs({ -1, 1 }) do
				box(ctx, f, "CorralRail", 0.3, 0.3, 12, x + s * 4.5, 3.7, z, YELLOW,
					Enum.Material.Metal, trim)
			end
			box(ctx, f, "CorralRail", 9.3, 0.3, 0.3, x, 3.7, z - 6, YELLOW,
				Enum.Material.Metal, trim)
			board(ctx, f, "CorralSign", 6, 2.8, 0.3, x, 5.9, z - 6, SOUTH, ppsFor(2.8), {
				{ text = "TROLLEYS", h = 1, y = 0 },
			})
		end
	end

	-- A trolley, eight parts of it. Charm is worth eight parts.
	local function trolley(x: number, z: number, yaw: number)
		local function at2(dx: number, dy: number, dz: number): CFrame
			return at(ctx, x, dy, z) * CFrame.Angles(0, math.rad(yaw), 0)
				* CFrame.new(dx, 0, dz)
		end
		piece(f, "TrolleyBasket", Vector3.new(3.4, 2.2, 4.8), STEEL,
			Enum.Material.Metal, at2(0, 2.3, 0), { query = false, transparency = 0.35 })
		piece(f, "TrolleyBase", Vector3.new(3.2, 0.25, 4.6), SLATE,
			Enum.Material.Metal, at2(0, 1.1, 0), trim)
		piece(f, "TrolleyHandle", Vector3.new(3.4, 0.25, 0.25), INK,
			Enum.Material.Metal, at2(0, 3.7, 2.5), trim)
		for _, s in ipairs({ -1, 1 }) do
			piece(f, "TrolleyUpright", Vector3.new(0.22, 1.5, 0.22), INK,
				Enum.Material.Metal, at2(s * 1.6, 3.1, 2.5), trim)
			for _, t in ipairs({ -1, 1 }) do
				piece(f, "TrolleyWheel", Vector3.new(0.45, 0.9, 0.9), INK,
					Enum.Material.Metal, at2(s * 1.4, 0.5, t * 1.8), prop)
			end
		end
	end
	for _, x in ipairs(islands) do
		for _, z in ipairs({ -1455, -1305 }) do
			trolley(x, z + 1, 0)
			trolley(x, z + 6, 0)
		end
	end
	trolley(1418, -1570, 20)
	trolley(1786, -1568, -35)

	-- Apron furniture.
	for i = 0, 9 do
		cylY(ctx, f, "Bollard", 3.8, 1.1, 1392 + i * 50, 1.9, APRON_Z1 - 3.5, YELLOW,
			Enum.Material.Metal, trim)
	end
	for i, x in ipairs({ 1396, 1420, 1560, 1640, 1780, 1828 }) do
		box(ctx, f, "Planter", 9, 3, 9, x, 1.5, APRON_Z0 + 9, KERBC,
			Enum.Material.SmoothPlastic, trim)
		box(ctx, f, "PlanterSoil", 7.6, 0.5, 7.6, x, 3.2, APRON_Z0 + 9, SOIL,
			Enum.Material.Ground, prop)
		for j = 0, 2 do
			scatter(ctx, f, bushes, i * 3 + j + 1, x - 2 + j * 2, 3.5, APRON_Z0 + 9, j * 61)
		end
	end

	-- Planting: island beds first, then the site verge, which is what stops the
	-- district reading as a car park floating on a lawn.
	for _, x in ipairs(islands) do
		plant(ctx, f, trees, 3, "Tree", x, PAD_TOP, -1381, 30)
		for i = 0, 9 do
			scatter(ctx, f, bushes, i + 3, x + (i % 2) * 3 - 1.5, KERB_TOP + 0.04,
				LOT_Z0 + 14 + i * 30, i * 37)
		end
	end
	for i = 0, 5 do
		plant(ctx, f, trees, i + 1, "Tree", 1205, PAD_TOP, -1740 + i * 110, i * 40)
		plant(ctx, f, trees, i + 7, "Tree", 1995, PAD_TOP, -1740 + i * 110, i * 55)
	end
	for i = 0, 3 do
		plant(ctx, f, trees, i + 13, "Tree", 1320 + i * 190, PAD_TOP, -1120, i * 70)
	end

	local park: { { number } } = {
		{ 1420, -1544, 0 }, { 1764, -1544, 180 }, { 1500, -1218, 0 }, { 1720, -1218, 180 },
		{ 1847, -1320, 90 }, { 1353, -1300, 270 }, { 1560, -1805, 0 }, { 1620, -1805, 0 },
	}
	for i, p in ipairs(park) do
		plant(ctx, f, cars, i, "Car", p[1], ROAD_TOP, p[2], p[3])
	end

	-- Cones across the lot mouth, and the board that says why.
	local function cone(x: number, z: number)
		box(ctx, f, "ConeFoot", 3, 0.3, 3, x, 0.23, z, INK, Enum.Material.SmoothPlastic, prop)
		cylY(ctx, f, "ConeLower", 1.5, 2.2, x, 1.1, z, Color3.fromRGB(226, 96, 44),
			Enum.Material.SmoothPlastic, prop)
		cylY(ctx, f, "ConeBand", 0.5, 2.0, x, 1.6, z, REVEAL, Enum.Material.SmoothPlastic, prop)
		cylY(ctx, f, "ConeTop", 1.6, 1.1, x, 2.6, z, Color3.fromRGB(226, 96, 44),
			Enum.Material.SmoothPlastic, prop)
	end
	for i = 0, 5 do cone(1420 + i * 76, LOT_Z0 - 7) end
	for i = 0, 2 do cone(ENTRY_X - 24 + i * 24, LOT_Z1 + 22) end

	box(ctx, f, "NoticeFoot", 9, 0.4, 6, ENTRY_X + 40, 0.28, LOT_Z1 + 20, INK,
		Enum.Material.SmoothPlastic, trim)
	local notice = piece(f, "Notice", Vector3.new(13, 9, 0.5), YELLOW,
		Enum.Material.SmoothPlastic,
		at(ctx, ENTRY_X + 40, 4.9, LOT_Z1 + 20) * CFrame.Angles(math.rad(-12), 0, 0), trim)
	lines(surface(notice, SOUTH, ppsFor(0.34 * 9)), {
		{ text = "LOT CLOSED", h = 0.34, y = 0.06, colour = INK,
		  font = Enum.Font.LuckiestGuy },
		{ text = "SEALCOATING IN PROGRESS", h = 0.18, y = 0.46, colour = INK,
		  font = Enum.Font.GothamBold },
		{ text = "LOTS A-F  \u{2022}  ALL BAYS", h = 0.14, y = 0.7, colour = INK,
		  font = Enum.Font.Gotham },
	})
end

--==[ APPROACH AND BOUNDS ]===================================================

local function approach(ctx: Ctx)
	local f = ctx.folder("Approach")
	local road = { query = true }
	local trim = { query = false }
	local line = { query = false, collide = false }

	box(ctx, f, "LinkGround", span(WOOD_X0, WOOD_X1), 6, span(ENTRY_Z1, ESTATE_Z),
		(WOOD_X0 + WOOD_X1) / 2, PAD_TOP - 3, (ENTRY_Z1 + ESTATE_Z) / 2,
		GRASS, Enum.Material.SmoothPlastic, road)

	local runZ = span(ENTRY_Z1, LINK_Z)
	box(ctx, f, "Carriageway", 30, 2, runZ, ENTRY_X, ROAD_TOP - 1,
		(ENTRY_Z1 + LINK_Z) / 2, ROADC, Enum.Material.Asphalt, road)
	for _, s in ipairs({ -1, 1 }) do
		box(ctx, f, "Kerb", 2, 2, runZ, ENTRY_X + s * 16, KERB_TOP - 1,
			(ENTRY_Z1 + LINK_Z) / 2, KERBC, Enum.Material.SmoothPlastic, trim)
	end
	
	for z = LINK_Z - 27, ENTRY_Z1 + 18, -36 do
		box(ctx, f, "Dash", 1.8, 0.4, 17.9, ENTRY_X, 0.18 - 0.2, z, DASHC,
			Enum.Material.SmoothPlastic, line)
	end

	for _, s in ipairs({ -1, 1 }) do
		box(ctx, f, "EntryPier", 6, 14, 6, ENTRY_X + s * 25, 7, ENTRY_Z1 - 2, WALL,
			Enum.Material.SmoothPlastic, { shadow = true })
		box(ctx, f, "EntryPierCap", 7.4, 1.2, 7.4, ENTRY_X + s * 25, 14.6, ENTRY_Z1 - 2,
			BLUE, Enum.Material.SmoothPlastic, trim)
	end
	box(ctx, f, "EntryGantry", 56, 1.6, 2, ENTRY_X, 16, ENTRY_Z1 - 2, BLUE,
		Enum.Material.SmoothPlastic, { shadow = true })
	board(ctx, f, "EntrySign", 22, 4, 0.6, ENTRY_X, 18.8, ENTRY_Z1 - 2, SOUTH,
		ppsFor(0.55 * 4), {
		{ text = "MEGAMART", h = 0.55, y = 0.04, colour = SIGNTX,
		  font = Enum.Font.LuckiestGuy },
		{ text = "CUSTOMER PARKING", h = 0.25, y = 0.66 },
	})
end

local function bounds(ctx: Ctx)
	local f = ctx.folder("Bounds")
	local BOUNDC = Color3.fromRGB(163, 162, 165)
	local X0, X1 = SITE_X0 + 1, SITE_X1 - 1     -- the site corridor
	local RW, RE = ENTRY_X - ROAD_HALF, ENTRY_X + ROAD_HALF   -- the road corridor
	local NZ = SITE_Z0 - 2
	local function slab(name: string, sx: number, sz: number, x: number, z: number)
		box(ctx, f, name, sx, 120, sz, x, 56, z, BOUNDC, Enum.Material.SmoothPlastic,
			{ query = false, transparency = 1 })
	end
	-- The site.
	slab("BoundW", 4, span(NZ, SITE_Z1), X0, (NZ + SITE_Z1) / 2)
	-- The east wall is in two pieces for the same reason the south one is: the
	-- deck-park spur comes through it on the same +/-GATE_GAP doorway. The gap IS
	-- the road, and closing it walls the player out of the fourth district.
	slab("BoundE_S", 4, span(SPUR_Z + GATE_GAP, SITE_Z1), X1, (SPUR_Z + GATE_GAP + SITE_Z1) / 2)
	slab("BoundE_N", 4, span(NZ, SPUR_Z - GATE_GAP), X1, (NZ + SPUR_Z - GATE_GAP) / 2)
	slab("BoundN", span(X0, X1), 4, (X0 + X1) / 2, NZ)
	-- The shoulders where the site narrows to the road.
	slab("BoundStep_W", span(X0, RW), 4, (X0 + RW) / 2, SITE_Z1)
	slab("BoundStep_E", span(RE, X1), 4, (RE + X1) / 2, SITE_Z1)
	-- The lane in.
	slab("BoundRoadW", 4, span(SITE_Z1, GATE_Z), RW, (SITE_Z1 + GATE_Z) / 2)
	slab("BoundRoadE", 4, span(SITE_Z1, GATE_Z), RE, (SITE_Z1 + GATE_Z) / 2)
	-- The doorway, which is the same +/-20 gap the Estate leaves at z -728. The
	-- gap IS the road; closing it walls the player out of the district.
	slab("BoundS_W", span(RW, ENTRY_X - GATE_GAP), 4, (RW + ENTRY_X - GATE_GAP) / 2, GATE_Z)
	slab("BoundS_E", span(ENTRY_X + GATE_GAP, RE), 4, (ENTRY_X + GATE_GAP + RE) / 2, GATE_Z)
end

--==[ TREELINE ]==============================================================

local function treeline(ctx: Ctx)
	local f = ctx.folder("Treeline")
	local pool = donor({ "EstateDistrict", "Treeline" })
	if not pool then return 0 end
	local rng = Random.new(20260807)
	local planted = 0
	local HEDGE, BELT, DEEP, INSIDE, VERGE = 46, 15, 5, 6, 20

	local AVOID = {
		{ 1288, 1876, -1846, -1194 },   -- store, yard, garden, lot, ring road, apron
		{ 1556, 1644, -1250, LINK_Z },  -- the carriageway and its verges
		{ SPUR_X0, 2250, -1443, -1319 },
	}

	-- Through at(), because every number in this file is a SURVEY coordinate and
	-- a raycast wants a world one. Casting the survey number directly put every
	-- ray 1600 studs east of the district, in clear sky, and the answer came back
	-- "no ground anywhere" -- which planted nothing at all and reported success.
	local function grounded(x: number, z: number): boolean
		local hit = workspace:Raycast(at(ctx, x, 20, z).Position, Vector3.new(0, -30, 0))
		return hit ~= nil and hit.Position.Y > (at(ctx, 0, -3, 0).Position.Y)
	end

	local function fill(x0: number, x1: number, z0: number, z1: number, per10k: number)
		local n = math.floor(span(x0, x1) * span(z0, z1) / 10000 * per10k + 0.5)
		for _ = 1, n do
			local x = rng:NextNumber(math.min(x0, x1), math.max(x0, x1))
			local z = rng:NextNumber(math.min(z0, z1), math.max(z0, z1))
			local ok = grounded(x, z)
			for _, r in ipairs(AVOID) do
				if x > r[1] and x < r[2] and z > r[3] and z < r[4] then ok = false break end
			end
			if ok then
				-- bedded 1.5 into the ground so the trunks do not sit on the grass
				plant(ctx, f, pool, rng:NextInteger(1, 4096), "Treeline",
					x, PAD_TOP - 1.5, z, rng:NextNumber(0, 360))
				planted += 1
			end
		end
	end

	local SW, SE = SITE_X0 - 2, SITE_X1 + 2
	local RW, RE = ENTRY_X - ROAD_HALF - 2, ENTRY_X + ROAD_HALF + 2

	-- Hedge hugging the site walls, then the belt behind it.
	fill(SW - 42, SW, WOOD_Z0, SITE_Z1, HEDGE)
	fill(SE, SE + 42, WOOD_Z0, SITE_Z1, HEDGE)
	fill(WOOD_X0, SW - 42, WOOD_Z0, SITE_Z1, BELT)
	fill(SE + 42, WOOD_X1, WOOD_Z0, SITE_Z1, BELT)
	-- Across the back of the store, which is the district's horizon from the lot.
	fill(WOOD_X0, WOOD_X1, WOOD_Z0, SITE_Z0 - 2, HEDGE * 0.75)

	-- The same again down the lane, where the corridor is only 360 wide and the
	-- trees are most of what the player actually sees on the way in.
	fill(RW - 42, RW, SITE_Z1, GATE_Z, HEDGE)
	fill(RE, RE + 42, SITE_Z1, GATE_Z, HEDGE)
	fill(WOOD_X0, RW - 42, SITE_Z1, GATE_Z, DEEP)
	fill(RE + 42, WOOD_X1, SITE_Z1, GATE_Z, DEEP)
	-- and on past the doorway, so the Estate's own treeline is met by this one
	-- rather than by a clearing.
	fill(RW - 42, RW, GATE_Z, LINK_Z, HEDGE)
	fill(RE, RE + 42, GATE_Z, LINK_Z, HEDGE)

	-- Inside the corridors. The site gets a wooded margin between its wall and the
	-- ring road; the lane gets both verges filled right up to that 44-stud margin.
	fill(SITE_X0 + 2, SITE_X1 - 2, SITE_Z0, SITE_Z1, INSIDE)
	fill(RW + 4, RE - 4, SITE_Z1, LINK_Z, VERGE)

	return planted
end

--==[ BUILD ]=================================================================

function RetailParkBuilder.build(origin: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "RetailPark"

	model.ModelStreamingMode = Enum.ModelStreamingMode.Nonatomic

	local folders: { [string]: Instance } = {}
	local ctx: Ctx = {
		model = model,
		origin = origin,
		folder = function(name: string): Instance
			local existing = folders[name]
			if existing then return existing end
			local fold = Instance.new("Folder")
			fold.Name = name
			fold.Parent = model
			folders[name] = fold
			return fold
		end,
	}

	pad(ctx)
	roads(ctx)
	local slabs = lot(ctx)
	markings(ctx)
	store(ctx)
	front(ctx)
	garden(ctx, donor({ "Neighbourhood", "Scenery", "Bushes" }),
		donor({ "Neighbourhood", "Scenery", "Trees" }))
	service(ctx)
	signage(ctx)
	lighting(ctx)
	dressing(ctx)
	approach(ctx)
	bounds(ctx)

	model.Parent = parent

	treeline(ctx)

	model:SetAttribute("PayMultiplier", PAY_MULTIPLIER)

	local site = folders["Site"]
	local ground = site and site:FindFirstChild("Ground")
	if ground and ground:IsA("BasePart") then
		model.PrimaryPart = ground
	end

	-- Tagged last, and after parenting. DrivewayClient watches
	-- GetInstanceAddedSignal, so a slab tagged while the model is still detached
	-- would announce itself from nowhere.
	for _, slab in ipairs(slabs) do
		CollectionService:AddTag(slab, "SealableDriveway")
	end

	return model
end

return RetailParkBuilder
