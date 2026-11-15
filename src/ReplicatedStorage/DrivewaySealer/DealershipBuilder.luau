--!strict
--[[
	DealershipBuilder -- Sealcoat Rigs, the showroom the trucks are sold from.

	--[ what this is now ]-----------------------------------------------------

	The building is AUTHORED. It is created once, saved into the place, and lives
	in Workspace beside the depot and the houses, which is the only way it can be
	seen or edited in Studio. TruckServer adopts whatever it finds under
	`workspace.RigDealership` and only calls this module when there is nothing to
	adopt -- see the provenance note there. So this file is two things at once:
	the recipe the building was made from, and the fallback for a place that has
	lost it. Both want the same code, and neither wants a second copy of it.

	To rebuild the saved one after editing this file, from the command bar:

		local M = require(game.ReplicatedStorage.DrivewaySealer.DealershipBuilder)
		local old = workspace:FindFirstChild("RigDealership")
		if old then old:Destroy() end
		M.build(CFrame.new(-74, 0, 210), workspace)

	Note what is NOT in that snippet: a rotation. Both halves of the purchase gate
	measure the slab in its OWN object space, so a turned model silently swaps
	which axis is 68 studs and which is 92. The old building carried a quarter
	turn; this one must never.

	--[ the site ]-------------------------------------------------------------

	A 68 x 92 pad on the grass west of the depot garage, inside the same fenced
	yard, with its frontage on the same southern line the garage's roll door
	faces. A player walking west off the depot apron crosses at x -36 and arrives
	on the forecourt.

	  forecourt   z 164..196   stock bays, customer parking, workshop approach
	  showroom    z 196..256   x -108..-58.5, 22 studs clear
	  workshop    z 196..256   x -58.5..-40, drive-through, 17 studs wide
	  rear yard   z 256..263   deliveries and staff bays

	Sixty-eight studs across is the depot garage's own width, on purpose. The two
	buildings face the same yard and reading as a pair is worth more than any
	number I could have picked freely.

	The pad is one part called `Floor`, and that is a contract rather than a
	convenience: UpgradeService and the buy panel both measure "is this player at
	the dealership" as a box in that part's own object space, found by a
	NON-recursive FindFirstChild on this model. Tuck it inside a Shell folder the
	way the garage does and both halves stop finding it -- and both FAIL OPEN, so
	the symptom is not an error, it is every rig quietly becoming buyable from
	anywhere on the map. The skirt round the slab rides on it as `ZoneMargin`, so
	the server and the client cannot disagree about how far the forecourt reaches.

	--[ the trucks ]-----------------------------------------------------------

	They are real. Each display rig is a genuine TruckBuilder rig in its own
	livery and its own proportions -- the thing that turns up in the bay when you
	buy it -- frozen: every part anchored, every hinge, weld and attachment
	removed, the seat taken out. The stand-ins that used to stand here were a
	dozen boxes each, and a showroom that shows you something other than the
	product is not a showroom.

	Freezing is what makes it affordable. The objection in the old header -- "a
	real one is 440 parts and carries a physics chassis with six wheel
	constraints" -- counted descendants of a live assembly. Stripped of its
	joints a rig is 170 anchored parts and simulates nothing at all, which is
	cheaper than most of the props in the depot.

	Nothing about them may look like a rig somebody owns. They are named
	Display_<id>, they live under this model rather than in Workspace, and they
	carry none of OwnerUserId / RigId / Tank / Pump -- RigController claims a
	truck by owner id and would otherwise start driving the exhibit.
]]

local Rigs = require(script.Parent.Rigs)
local TruckBuilder = require(script.Parent.TruckBuilder)

local DealershipBuilder = {}

--==[ PALETTE ]===============================================================
-- The depot's own colours, sampled from it. Three plus one: off-white mass, one
-- blue for roof and bands, one yellow for every painted line, charcoal for
-- posts and sign panels. Nothing architectural goes above RGB 236 -- Bloom is
-- thresholded at 1.75 against Brightness 2.6, and a near-white wall blows out.

local WALL     = Color3.fromRGB(236, 233, 222)
local REVEAL   = Color3.fromRGB(252, 250, 244)
local BLUE     = Color3.fromRGB(64, 142, 196)
local YELLOW   = Color3.fromRGB(240, 176, 44)
local INK      = Color3.fromRGB(38, 44, 56)
local INK2     = Color3.fromRGB(38, 42, 50)
local SLATE    = Color3.fromRGB(58, 64, 74)
local LINER    = Color3.fromRGB(203, 206, 211)
local STEEL    = Color3.fromRGB(118, 124, 132)
local TARMAC   = Color3.fromRGB(121, 119, 110)
local PAVING   = Color3.fromRGB(219, 216, 202)
local KERBC    = Color3.fromRGB(237, 235, 226)
local CONCRETE = Color3.fromRGB(92, 96, 104)
local SHOPFLOOR = Color3.fromRGB(116, 118, 122)  -- the garage's own floor tone
local GLASSC   = Color3.fromRGB(150, 200, 232)
local MULLION  = Color3.fromRGB(224, 227, 232)
local CILLC    = Color3.fromRGB(38, 48, 72)
local NEONW    = Color3.fromRGB(246, 240, 224)
local WHITEL   = Color3.fromRGB(228, 228, 224)
local SIGNTX   = Color3.fromRGB(255, 214, 92)
local SUBTX    = Color3.fromRGB(198, 210, 224)
local WOOD     = Color3.fromRGB(150, 113, 68)
local DRUMC    = Color3.fromRGB(40, 43, 49)
local RED      = Color3.fromRGB(188, 42, 38)
local DARK     = Color3.fromRGB(24, 27, 33)

--[[
	The datum every number below is written against.

	They are real world coordinates from the site survey, because that is what
	they were designed as and translating three hundred of them by hand is how a
	building ends up two studs inside a fence. `at()` turns one into a CFrame in
	the caller's frame, so the whole thing still moves if it is ever built
	somewhere else.
]]
local DATUM = Vector3.new(-74, 0, 210)

local FLOOR_TOP  = 0.05   -- top of the site pad
local FINISH_TOP = 0.20   -- top of the showroom's own floor, laid on the pad
local PAINT_Y    = 0.09   -- outdoor graphics: 0.08 tall, top 0.13
local GRAPHIC_Y  = 0.23   -- indoor graphics: 0.06 tall, top 0.26
local ZONE_MARGIN = 8

--==[ PRIMITIVES ]============================================================

type Ctx = {
	model: Model,
	origin: CFrame,
	folder: (name: string) -> Instance,
}

local function at(ctx: Ctx, x: number, y: number, z: number): CFrame
	return ctx.origin * CFrame.new(x - DATUM.X, y - DATUM.Y, z - DATUM.Z)
end

--[[
	One part, and the two disciplines that are invisible until they bite.

	CastShadow is OFF by default: the place runs 12% shadow casters and three
	trucks at the engine default would add five hundred more, so only silhouette
	geometry -- walls, roof, parapets, the rigs' bodywork -- casts. CanQuery is
	off for anything decorative, matching the 1,838-of-1,986 convention in
	Neighbourhood.Scenery, so the sealing tool's raycasts never report a coffee
	table as ground.
]]
type Opts = {
	shape: Enum.PartType?,
	shadow: boolean?,
	query: boolean?,
	collide: boolean?,
	transparency: number?,
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
	end
	p.CFrame = cf
	p.Parent = into
	return p
end

-- A box in world coordinates, which is what every table in this file is in.
local function box(ctx: Ctx, into: Instance, name: string, sx: number, sy: number,
	sz: number, x: number, y: number, z: number, colour: Color3,
	material: Enum.Material, opts: Opts?): Part
	return piece(into, name, Vector3.new(sx, sy, sz), colour, material,
		at(ctx, x, y, z), opts)
end

--[[
	Part.Shape = Cylinder always runs along the part's own X, so these three point
	it down each world axis and no caller has to remember which way a bare
	cylinder faces.

	The options table is COPIED rather than written through. Callers share one
	`prop` table across dozens of calls, and setting `shape` on it in place would
	leave every later box in that function a cylinder -- which is the kind of bug
	that looks like a physics problem for an hour.
]]
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

local function cylX(ctx: Ctx, into: Instance, name: string, len: number, dia: number,
	x: number, y: number, z: number, colour: Color3, material: Enum.Material,
	opts: Opts?): Part
	return piece(into, name, Vector3.new(len, dia, dia), colour, material,
		at(ctx, x, y, z), shaped(opts))
end

local function cylZ(ctx: Ctx, into: Instance, name: string, len: number, dia: number,
	x: number, y: number, z: number, colour: Color3, material: Enum.Material,
	opts: Opts?): Part
	return piece(into, name, Vector3.new(len, dia, dia), colour, material,
		at(ctx, x, y, z) * CFrame.Angles(0, math.rad(90), 0), shaped(opts))
end

--==[ SIGNAGE ]===============================================================

--[[
	Two fonts, two jobs, and it is the strongest rule in the place: LuckiestGuy
	in 255,214,92 is identity -- the name over the door, the price on a card --
	and Gotham Bold in 240,176,44 is every operational label. The old showroom
	used GothamBlack in white, which is most of why it did not look like it
	belonged to this game.
]]
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
	h: number,        -- share of the face height
	y: number,        -- top, as a share of the face height
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
		t.Text = l.text
		t.TextColor3 = l.colour or YELLOW
		t.TextScaled = true
		t.TextStrokeTransparency = 1
		t.Parent = gui
	end
end

-- The whole recipe in one call: a charcoal board, its gui, its text.
local function board(ctx: Ctx, into: Instance, name: string, sx: number, sy: number,
	sz: number, x: number, y: number, z: number, face: Enum.NormalId, pps: number,
	rows: { Line }, colour: Color3?): Part
	local p = box(ctx, into, name, sx, sy, sz, x, y, z, colour or INK,
		Enum.Material.SmoothPlastic, { query = false })
	lines(surface(p, face, pps), rows)
	return p
end

--==[ THE PAD ]==============================================================

--[[
	`Floor` is the whole paved site, not the showroom carpet.

	Both halves of the purchase gate measure an axis-aligned box in this part's
	object space plus a skirt, and there is no second slab they could consult. A
	player stood among the stock bays looking at a truck has to be inside it, or
	the buy button greys out and tells them to visit the dealership they are
	standing in. So the slab is the site, the visible finishes are separate parts
	laid on top of it, and the skirt is written on the slab itself.

	Kept thin and at walking height for the other half of the same rule: the box
	runs from 2 studs below the slab CENTRE to 18 above it, so a thick plinth of a
	slab would push a standing player toward the bottom of the range and a first
	floor would push them out of the top. There is deliberately no upstairs
	anywhere in this building.
]]
local function pad(ctx: Ctx): BasePart
	local floor = box(ctx, ctx.model, "Floor", 68, 0.60, 92, -74, -0.25, 210,
		TARMAC, Enum.Material.SmoothPlastic)
	floor:SetAttribute("ZoneMargin", ZONE_MARGIN)

	local site = ctx.folder("Site")

	-- Rear service pad. Outside the slab but inside the zone the slab's skirt
	-- draws, which is why it can be a separate part without breaking anything.
	box(ctx, site, "RearPad", 68, 0.60, 7, -74, -0.25, 259.5, TARMAC,
		Enum.Material.SmoothPlastic)

	-- Kerbs, 2 x 2 and mostly buried, so they read as a painted edge rather than
	-- a step -- the trick every kerb in the neighbourhood already uses.
	box(ctx, site, "Kerb_S", 70, 2, 2, -75, -0.90, 163, KERBC, Enum.Material.SmoothPlastic)
	box(ctx, site, "Kerb_W", 2, 2, 100, -109, -0.90, 214, KERBC, Enum.Material.SmoothPlastic)
	box(ctx, site, "Kerb_N", 70, 2, 2, -75, -0.90, 263.5, KERBC, Enum.Material.SmoothPlastic)
	-- broken for the crossover at z 172..190
	box(ctx, site, "Kerb_E_S", 2, 2, 8, -39, -0.90, 167, KERBC, Enum.Material.SmoothPlastic)
	box(ctx, site, "Kerb_E_N", 2, 2, 73, -39, -0.90, 226.5, KERBC, Enum.Material.SmoothPlastic)

	--[[
		The crossover onto the depot apron.

		The apron's top is 0.596 and the forecourt's is 0.05, so the two cannot
		simply meet: they butt at x -32 with a wedge taking the half stud between
		them. Overlapping them instead would put two coplanar top faces across the
		busiest seam on the site and z-fight the whole width of it.
	]]
	box(ctx, site, "CrossSlab", 8, 0.50, 18, -36, -0.20, 181, TARMAC,
		Enum.Material.SmoothPlastic)
	local ramp = Instance.new("WedgePart")
	ramp.Name = "CrossRamp"
	ramp.Size = Vector3.new(18, 0.55, 2.5)
	ramp.Color = TARMAC
	ramp.Material = Enum.Material.SmoothPlastic
	ramp.Anchored = true
	ramp.CastShadow = false
	-- A wedge's tall face is its BACK (+Z) and it falls away toward the front.
	-- Turned a quarter, the 18-stud span lies along world Z and the rise runs
	-- west to east, high edge against the apron.
	ramp.CFrame = at(ctx, -33.25, 0.325, 181) * CFrame.Angles(0, math.rad(90), 0)
	ramp.Parent = site
	box(ctx, site, "CrossKerb", 1, 0.50, 18, -40.5, -0.20, 181, KERBC,
		Enum.Material.SmoothPlastic)

	return floor
end

--==[ FORECOURT ]=============================================================

--[[
	Paint, and it is the cheapest dealership on the site.

	ONE RANK OF FIVE, all the same width and all the same depth. It was three
	things laid over each other -- three 12x24 bays, a pair of 7-wide disabled
	bays at half that depth, and a lone 12-deep bay sitting in the northern half
	of nothing -- with bare tarmac in the gaps and wheel stops under only the
	first three. Nothing about it read as one car park.

	Twelve by twenty-four is a RIG bay rather than a car bay, and that is the
	whole point: the customer arrives in a 22-stud tanker. A lot they cannot
	actually park in is scenery.

	Five stop at x -48 because the pylon stands at -44 and the pedestrian
	crossing lands at -40; that last eight studs is the way in on foot.

	Every line sits 0.08 proud of the pad rather than flush with it, because two
	surfaces at the same height fight each other and a painted line that flickers
	reads as a bug.

	The eight-stud strip at z 188..196 is left empty on purpose. It is the drive
	lane, and it is the reason every bay can actually be reached: a lamp post or a
	planter in it would wall the bays off from the only way in, which is what
	happens to most drawn car parks.
]]
local BAY_W = 12
local BAY_X = { -102, -90, -78, -66, -54 }   -- centres, west to east
local ACCESSIBLE_X = -90                     -- the bay the entrance canopy covers

local function forecourt(ctx: Ctx)
	local f = ctx.folder("Forecourt")
	local line = { query = false, collide = false }

	-- six dividers make five bays; z 164..188 is the full depth of the lot
	for i = 0, #BAY_X do
		box(ctx, f, "BayLine", 0.45, 0.08, 24, BAY_X[1] - BAY_W * 0.5 + i * BAY_W,
			PAINT_Y, 176, YELLOW, Enum.Material.SmoothPlastic, line)
	end
	for _, x in ipairs(BAY_X) do
		box(ctx, f, "BayHead", BAY_W, 0.08, 0.70, x, PAINT_Y, 187.65, YELLOW,
			Enum.Material.SmoothPlastic, line)
	end
	-- two per bay rather than a run under the first three only
	for _, x in ipairs(BAY_X) do
		for _, dx in ipairs({ -3, 3 }) do
			box(ctx, f, "WheelStop", 6, 0.50, 0.80, x + dx, 0.30, 166.5, YELLOW,
				Enum.Material.SmoothPlastic, { query = false })
		end
	end

	-- sized to its bay, not a 7-wide patch straddling two of them
	box(ctx, f, "DisabledFill", 10, 0.06, 20, ACCESSIBLE_X, 0.08, 176, BLUE,
		Enum.Material.SmoothPlastic, line)

	box(ctx, f, "WalkEdge", 68, 0.08, 0.35, -74, PAINT_Y, 188.2, WHITEL,
		Enum.Material.SmoothPlastic, line)

	--[[
		Bay markings, built 4 x 6 and turned a quarter.

		A SurfaceGui on a Top face runs its canvas along the part's LOCAL Z, so
		these printed sideways for as long as they have existed -- which is how the
		showroom's floor lockup came to be built the same wrong way round before it
		was caught on a screenshot.
	]]
	local n = 0
	for _, x in ipairs(BAY_X) do
		local accessible = x == ACCESSIBLE_X
		if not accessible then n += 1 end
		local pad = box(ctx, f, "BayPad", 4, 0.08, 6, x, PAINT_Y, 184, TARMAC,
			Enum.Material.SmoothPlastic, line)
		pad.CFrame = pad.CFrame * CFrame.Angles(0, math.rad(90), 0)
		lines(surface(pad, Enum.NormalId.Top, 42), {
			{ text = if accessible then "\u{267F}" else ("F" .. n), h = 0.54, y = 0.04 },
			{ text = if accessible then "ACCESSIBLE" else "CUSTOMER PARKING",
				h = 0.28, y = 0.62, colour = SUBTX, font = Enum.Font.Gotham },
		})
	end
end

--==[ SHELL ]=================================================================

--[[
	Two volumes under one roofline: a 22-stud showroom at x -108..-58.5 and a
	17-stud workshop beside it, both 60 deep.

	The frontage is the whole point of the exercise and it is why the wall is 22
	rather than 15: glazing that stops at head height reads as a shed with a
	window in it. This one runs from the floor to 19 studs, in a 16-stud open
	portal with mullioned runs either side, and everything inside is visible
	through it from the forecourt.
]]
local WALL_T = 1.00
local SHOW_H = 22
local SVC_H = 17

local function shell(ctx: Ctx)
	local s = ctx.folder("Shell")
	local solid = { shadow = true }

	--[ walls ]---------------------------------------------------------------
	-- A corner pier, not eleven studs of blank wall. The frontage was solid at
	-- this end and a workshop shutter at the other; both are glazed now, and the
	-- Bantam Dart stands three studs behind this one.
	box(ctx, s, "WallSouth_Show_W", 2, SHOW_H, WALL_T, -107, 11, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallSouth_Show_E", 1.5, SHOW_H, WALL_T, -59.25, 11, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallWest", WALL_T, SHOW_H, 58, -107.5, 11, 226, WALL,
		Enum.Material.SmoothPlastic, solid)

	-- north wall, split round the staff door at x -80..-76
	box(ctx, s, "WallNorth_Show_W", 28, SHOW_H, WALL_T, -94, 11, 255.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallNorth_Show_E", 17.5, SHOW_H, WALL_T, -67.25, 11, 255.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallNorth_Show_Lintel", 4, 13, WALL_T, -78, 15.5, 255.5, WALL,
		Enum.Material.SmoothPlastic, solid)

	-- No division wall. The east bay used to be a service workshop behind one;
	-- the hall runs the full 66 now and the only thing left on that line is the
	-- ceiling downstand in structure().

	-- The rear of the east bay is still a shutter between two piers -- that is how
	-- a rig gets in, and it faces the delivery yard. The front was the same
	-- opening and is glazed now: a dealership that shows a roller door to the road
	-- reads as a garage, which is exactly what this wing used to be. All that is
	-- left of it on the south face is the east corner pier.
	box(ctx, s, "WallSvc_E", 3.5, SVC_H, WALL_T, -41.75, 8.5, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallSvc_W", 3, SVC_H, WALL_T, -57, 8.5, 255.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallSvc_E", 3.5, SVC_H, WALL_T, -41.75, 8.5, 255.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallSvc_Lintel", 12, 3.95, WALL_T, -49.5, 15.025, 255.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "WallEast", WALL_T, SVC_H, 58, -40.5, 8.5, 226, WALL,
		Enum.Material.SmoothPlastic, solid)

	--[ glazed frontage ]-----------------------------------------------------
	--[[
		Glazing, and NOT Enum.Material.Glass. Twice measured, twice rejected.

		Glass at Transparency 0 -- which is what the circuit pit garages are, and
		right for them -- renders as an opaque tinted slab, and on a showroom that
		hides the entire point of the building. Turned transparent it does something
		worse: Roblox's Glass material refracts what is behind it in screen space,
		and a hall with three trucks, a dozen columns and a lit ceiling behind one
		pane comes out as radial smears converging on a point. It looked like
		z-fighting and it is not; swapping the material for SmoothPlastic at the same
		transparency removes it completely.

		So the panes are plain translucent plastic and the mullions do the work of
		saying "glass". 0.45 with a pale tint: below about 0.3 the trucks stop
		reading from the forecourt, above 0.6 the frontage stops reading at all.
		They collide, or a player walks through the shopfront and ends up standing
		inside a rig.
	]]
	local pane = { transparency = 0.45 }
	local function glass(name: string, w: number, x: number)
		box(ctx, s, name, w, 18.45, 0.30, x, 9.875, 196.35, GLASSC,
			Enum.Material.SmoothPlastic, pane)
	end
	glass("Glass_SideW", 2, -96)
	glass("Glass_SideE", 2, -78)
	for _, x in ipairs({ -74.875, -70.625, -66.375, -62.125 }) do
		glass("Glass", 4.25, x)
	end
	-- the west end, where the blank wall was
	for _, x in ipairs({ -103.75, -99.25 }) do
		glass("Glass_West", 4.5, x)
	end
	--[[
		The east bay, where the shutter was. Shorter panes, and that is the parapet
		rather than a preference: this wing tops out at SVC_H 17 with its fascia
		starting at 14.8, where the showroom's glass runs to 19.1. A full-height pane
		here comes out through its own roof.
	]]
	for _, x in ipairs({ -56.625, -52.875, -49.125, -45.375 }) do
		box(ctx, s, "Glass_Bay", 3.75, 14.15, 0.30, x, 7.725, 196.35, GLASSC,
			Enum.Material.SmoothPlastic, pane)
	end
	-- Mullions stand proud on the OUTSIDE face. At z 196.25 their back face landed
	-- exactly on the panes' at 196.50 and the pair strobed the length of the
	-- frontage; 196.05 puts the back face inside the glass instead, which is what
	-- a glazing bead actually does.
	for _, x in ipairs({ -106, -101.5, -97, -95, -79, -77, -72.75, -68.5, -64.25, -60 }) do
		box(ctx, s, "Mullion", 1.00, 18.45, 0.50, x, 9.875, 196.05, MULLION,
			Enum.Material.SmoothPlastic, { query = false })
	end
	-- the east bay's own, cut to its shorter pane
	for _, x in ipairs({ -58.5, -54.75, -51, -47.25, -43.5 }) do
		box(ctx, s, "Mullion", 1.00, 14.15, 0.50, x, 7.725, 196.05, MULLION,
			Enum.Material.SmoothPlastic, { query = false })
	end
	for _, m in ipairs({ { 9, -101.5 }, { 2, -96 }, { 2, -78 }, { 17, -68.5 },
		{ 15, -51 } }) do
		box(ctx, s, "Transom", m[1], 1, 0.50, m[2], 10, 196.05, MULLION,
			Enum.Material.SmoothPlastic, { query = false })
		box(ctx, s, "Cill", m[1], 0.60, 0.60, m[2], 0.35, 196.35, CILLC,
			Enum.Material.SmoothPlastic)
	end

	-- spandrels close the wall above the glass, and above the portal
	box(ctx, s, "Spandrel", 9, 2.90, WALL_T, -101.5, 20.55, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "Spandrel", 2, 2.90, WALL_T, -96, 20.55, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "Spandrel", 19, 2.90, WALL_T, -69.5, 20.55, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "Spandrel_Portal", 16, 8, WALL_T, -87, 18, 196.5, WALL,
		Enum.Material.SmoothPlastic, solid)

	--[ the way in ]----------------------------------------------------------
	-- Sixteen studs clear and no door leaves anywhere in the building. A
	-- shopfront you have to aim at reads as a gap in a wall, and a leaf is one
	-- more thing to be stuck behind.
	box(ctx, s, "PortalJamb", 1, 14, 0.35, -95.5, 7, 195.83, REVEAL,
		Enum.Material.SmoothPlastic)
	box(ctx, s, "PortalJamb", 1, 14, 0.35, -78.5, 7, 195.83, REVEAL,
		Enum.Material.SmoothPlastic)
	box(ctx, s, "PortalHead", 18, 0.80, 0.35, -87, 14.4, 195.83, REVEAL,
		Enum.Material.SmoothPlastic)
	box(ctx, s, "Threshold", 16, 0.16, 2.20, -87, 0.10, 196.9, YELLOW,
		Enum.Material.SmoothPlastic, { query = false })

	--[ delivery shutter ]----------------------------------------------------
	--[[
		One, at the BACK, shut. It faces the yard with the chevrons and the bins on
		it, which is where a rig actually arrives. There used to be a second one
		half-raised on the shopfront, and it was the last thing making the east wing
		read as a workshop from the road.

		The half-open case stays in the loop rather than being deleted: it is one
		boolean, and it is how this door gets drawn if it is ever opened.
	]]
	for _, spec in ipairs({
		{ rail = 255.6, slat = 255.45, rev = 256.17, sill = 255.1, half = false },
	}) do
		for _, x in ipairs({ -56, -43 }) do
			box(ctx, s, "ShutterReveal", 1, 13, 0.35, x, 6.5, spec.rev, REVEAL,
				Enum.Material.SmoothPlastic)
			box(ctx, s, "DoorRail", 0.50, 13.2, 0.50, x, 6.6, spec.rail, SLATE,
				Enum.Material.Metal, { query = false })
		end
		cylX(ctx, s, "ShutterDrum", 12, 2.80, -49.5, 13.6, spec.rail,
			Color3.fromRGB(240, 168, 56), Enum.Material.Metal, { query = false })
		box(ctx, s, "Threshold_Svc", 12, 0.16, 2.20, -49.5, 0.10, spec.sill, YELLOW,
			Enum.Material.SmoothPlastic, { query = false })
		local n = if spec.half then 6 else 15
		local y0 = if spec.half then 7.435 else 0.435
		for i = 0, n - 1 do
			box(ctx, s, "Slat", 12, 0.87, 0.42, -49.5, y0 + i * 0.87, spec.slat,
				if i == 0 then YELLOW else LINER, Enum.Material.SmoothPlastic)
		end
	end

	--[ roof, parapet, fascia ]-----------------------------------------------
	box(ctx, s, "Roof_Show", 51.5, 0.90, 64, -84.25, 22.45, 226, BLUE,
		Enum.Material.SmoothPlastic, solid)
	box(ctx, s, "Roof_Svc", 20.5, 0.90, 64, -48.25, 17.45, 226, BLUE,
		Enum.Material.SmoothPlastic, solid)

	for _, p in ipairs({
		{ 51.5, 0.80, -84.25, 23.65, 194.4 }, { 51.5, 0.80, -84.25, 23.65, 257.6 },
		{ 0.80, 64, -109.6, 23.65, 226 },     { 0.80, 64, -58.9, 23.65, 226 },
		{ 20.5, 0.80, -48.25, 18.65, 194.4 }, { 20.5, 0.80, -48.25, 18.65, 257.6 },
		{ 0.80, 64, -38.4, 18.65, 226 },
	}) do
		box(ctx, s, "Parapet", p[1], 1.5, p[2], p[3], p[4], p[5], WALL,
			Enum.Material.SmoothPlastic, { shadow = true })
	end

	-- Every band is dimensioned to its own wall plus 0.30, so it stands 0.15
	-- proud of each face and never overshoots the corner it turns.
	for _, b in ipairs({
		{ 49.8, 0.80, -83.25, 20.9, 195.75 }, { 49.8, 0.80, -83.25, 20.9, 256.25 },
		{ 0.80, 60.3, -108.25, 20.9, 226 },
		{ 18.8, 0.80, -49.25, 15.9, 195.75 }, { 18.8, 0.80, -49.25, 15.9, 256.25 },
		{ 0.80, 60.3, -39.75, 15.9, 226 },
	}) do
		box(ctx, s, "Fascia", b[1], 2.2, b[2], b[3], b[4], b[5], BLUE,
			Enum.Material.SmoothPlastic, { query = false })
	end

	box(ctx, s, "RoofPlant", 6, 2.5, 4, -98, 24.15, 250, STEEL, Enum.Material.Metal,
		{ query = false })
	box(ctx, s, "RoofPlant", 6, 2.5, 4, -68, 24.15, 250, STEEL, Enum.Material.Metal,
		{ query = false })

	--[ entrance canopy ]-----------------------------------------------------
	box(ctx, s, "Canopy", 18, 0.80, 9, -87, 12.5, 191.5, BLUE,
		Enum.Material.SmoothPlastic, solid)
	for _, x in ipairs({ -94, -80 }) do
		box(ctx, s, "CanopyCol", 1, 12.1, 1, x, 6.05, 189, STEEL, Enum.Material.Metal)
	end
end

--==[ INTERIOR ]=============================================================

--[[
	The rigs are round the walls and the floor is empty.

	One against the west liner facing the glass, one against the east liner facing
	it, and two turned broadside along the back -- so you walk in and the room is a
	single clear space with the whole range round its edge and the range laid into
	the floor in the middle of it.
	There is no customer strip: reception, the sofa, the sales desk and the parts
	counter were nine studs of furniture down one side and they are gone.

	It is 66 studs wide, not 48. It was 48 with a walled 17-stud service workshop
	beside it, and at that width two 12-stud plinth assemblies plus the furniture
	left only 15 studs of floor to split between three aisles -- walkable, and
	still a corridor with trucks in it. The workshop went and the hall took the bay.

	The centre is 39 studs clear between the two side kerbs and about 40 from the
	door to the hero's kerb. Drawn plans fail here far more often than they fail on
	proportion -- flood-fill the floor rather than trusting any of these numbers
	after a change.
]]
local function finishes(ctx: Ctx)
	local f = ctx.folder("Finishes")
	local flat = { query = false, collide = false }

	-- one floor across the whole hall. It used to stop at the division wall and
	-- carry on in garage grey beyond it; with the wall gone two finishes would
	-- read as two rooms that somebody knocked together.
	box(ctx, f, "ShowFloorFinish", 66, 0.15, 58, -74, 0.125, 226, PAVING,
		Enum.Material.SmoothPlastic)

	box(ctx, f, "EntranceMat", 14, 0.06, 5, -87, GRAPHIC_Y, 199.5, YELLOW,
		Enum.Material.SmoothPlastic, flat)
	box(ctx, f, "InlayBorder", 18, 0.06, 2, -87, GRAPHIC_Y, 253.5, SLATE,
		Enum.Material.SmoothPlastic, flat)

	-- a line of that rig's own colour running from the door to its plinth
	box(ctx, f, "LiveryStripe_Dart", 1.6, 0.06, 4, -99.5, GRAPHIC_Y, 199,
		Rigs.ById.Dart.tint, Enum.Material.SmoothPlastic, flat)
	box(ctx, f, "LiveryStripe_Longline", 1.6, 0.06, 4, -48.5, GRAPHIC_Y, 199,
		Rigs.ById.Longline.tint, Enum.Material.SmoothPlastic, flat)
	box(ctx, f, "LiveryStripe_Cistern", 1.6, 0.06, 4, -84, GRAPHIC_Y, 227,
		Rigs.ById.Cistern.tint, Enum.Material.SmoothPlastic, flat)
	box(ctx, f, "LiveryStripe_Kerbline", 1.6, 0.06, 4, -66, GRAPHIC_Y, 227,
		Rigs.ById.Kerbline.tint, Enum.Material.SmoothPlastic, flat)

	--[[
		The range, laid into the middle of the floor.

		It was two lines of vinyl on the brand wall, and there are two tankers parked
		against that wall now. The middle of the hall is the one surface in the
		building nothing stands on.

		The names are read off Rigs.List rather than typed out, so the floor cannot
		advertise three trucks on the day a fourth goes on sale -- the same rule the
		totems' prices already follow.

		Two parts, 0.03 apart. At the same height they z-fight the length of the
		border, which is the note on every other painted line in this file.
	]]
	local names = {}
	for _, r in ipairs(Rigs.List) do table.insert(names, string.upper(r.name)) end
	box(ctx, f, "LockupEdge", 32, 0.06, 15, -74, GRAPHIC_Y, 214, YELLOW,
		Enum.Material.SmoothPlastic, flat)
	--[[
		Built 13 x 30 and turned a quarter, not 30 x 13 laid flat.

		A SurfaceGui on a Top face runs its canvas along the part's LOCAL Z, so a
		floor board sized the obvious way round prints the whole lockup sideways --
		which is exactly what the forecourt's bay markings do, and nobody has ever
		read one of those. Swapping the part's own axes and rotating it puts the same
		30 x 13 footprint on the floor with the words running across it.
	]]
	local lock = box(ctx, f, "FloorLockup", 13, 0.06, 30, -74, GRAPHIC_Y + 0.03, 214,
		INK, Enum.Material.SmoothPlastic, flat)
	lock.CFrame = lock.CFrame * CFrame.Angles(0, math.rad(90), 0)
	-- Two rows of names, not one. Four across a 30-stud slab is TextScaled hard
	-- against both edges, and TextScaled WRAPS before it shrinks -- so the day a
	-- fifth rig goes on sale the single row would silently grow a second line and
	-- land it on the border rather than getting smaller.
	local half = math.ceil(#names / 2)
	lines(surface(lock, Enum.NormalId.Top, 34), {
		{ text = "SEALCOAT RIGS", h = 0.36, y = 0.08, colour = SIGNTX,
			font = Enum.Font.LuckiestGuy },
		{ text = table.concat({ table.unpack(names, 1, half) }, "  \u{2022}  "),
			h = 0.13, y = 0.54, colour = SUBTX, font = Enum.Font.GothamBold },
		{ text = table.concat({ table.unpack(names, half + 1) }, "  \u{2022}  "),
			h = 0.13, y = 0.72, colour = SUBTX, font = Enum.Font.GothamBold },
	})
end

local function structure(ctx: Ctx)
	local s = ctx.folder("Structure")
	local hide = { query = false }

	box(ctx, s, "CeilingDeck", 48, 0.40, 58, -83, 21.2, 226, LINER,
		Enum.Material.SmoothPlastic, hide)
	-- the east bay keeps its lower ceiling; a 66 x 58 lid at 21 would be a hangar
	box(ctx, s, "WorkshopCeiling", 17, 0.40, 58, -49.5, 15.7, 226, LINER,
		Enum.Material.SmoothPlastic, hide)
	-- The two ceilings are five studs apart on the line the division wall stood
	-- on. A downstand there makes the step a deliberate lower bay; without it the
	-- hall simply stops having a ceiling for a stud.
	box(ctx, s, "Bulkhead", 1.00, 5.50, 58, -58.5, 18.25, 226, LINER,
		Enum.Material.SmoothPlastic, hide)

	-- Liner, chair rail and dado, straight off the garage: a light grey sheet
	-- above, a slate dado below, split by a 0.30 yellow line. The cheapest thing
	-- that makes an interior read as finished rather than as the inside of a box.
	-- `top` is where the sheet stops. It defaults to the 18.6 the tall half of the
	-- hall uses; the east bay's ceiling is at 15.5 and a 18.6 sheet pokes through
	-- it, which reads as a wall growing out of the roof.
	local function lined(name: string, sx: number, sz: number, x: number, z: number,
		top: number?)
		local t = top or 18.6
		box(ctx, s, name .. "_Upper", sx, t - 5.6, sz, x, (t + 5.6) / 2, z, LINER,
			Enum.Material.SmoothPlastic, hide)
		box(ctx, s, name .. "_Rail", sx, 0.30, sz, x, 5.45, z, YELLOW,
			Enum.Material.SmoothPlastic, hide)
		box(ctx, s, name .. "_Dado", sx, 5.30, sz, x, 2.65, z, SLATE,
			Enum.Material.SmoothPlastic, hide)
	end
	lined("Liner_W", 0.20, 58, -106.9, 226)
	lined("Liner_E", 0.20, 58, -41.10, 226, 15.5)   -- the NEW east wall
	lined("Liner_N_W", 10, 0.20, -102, 254.9)
	lined("Liner_N_E", 18, 0.20, -68, 254.9)
	-- the low bay's north wall, either side of the delivery shutter
	lined("Liner_N_BayW", 2.00, 0.20, -57.50, 254.9, 15.5)
	lined("Liner_N_BayE", 2.50, 0.20, -42.25, 254.9, 15.5)

	--[[
		No columns, and that is the decision rather than an omission.

		The garage has exposed steel down the middle because it is a shed and the
		span is what it is. A showroom is the opposite building: the whole reason it
		is worth 22 studs of wall is that you can see the length of it from the door.
		Two went in on the cross aisle to break up the ceiling and both landed
		squarely in front of the hero rig; moved to the walls they took a third of a
		three-stud walk with them. A clear span costs nothing and hides nothing.
	]]
end

--==[ PLINTHS AND TOTEMS ]====================================================

--[[
	Kerb, plinth, neon pinstripe -- and no two of them share a top face.

	The kerb is 0.10 shorter than the plinth so a strip of plinth edge shows above
	it. Sizing them the same is the obvious thing to do and it z-fights round the
	entire perimeter.

	The pinstripe is FOUR strips laid on the kerb shoulder, not one slab the size
	of the plinth. Built as a slab it sat 0.06 proud of the deck, which does not
	read as an edge light -- it reads as the entire plinth top glowing in the rig's
	colour, and at this scene's exposure that is a hundred square studs of neon
	shouting at you from the far side of the glass. Neon in this place is a line
	and never a face.
]]
type Bay = {
	id: string,
	x: number, z: number,
	w: number, d: number, h: number,
	yaw: number,
	tx: number, tz: number,
	-- a podium you can walk onto needs a step; the two broadside bays have one
	step: boolean?,
}

--[[
	Four bays round the walls: one each side facing the glass, two broadside along
	the back, and nothing at all in the middle.

	Kerbs are w+1. The clearances are the whole design and every one of them was
	measured rather than drawn:

	  side bays      12 wide, ~1.5 off their liner -- parked against the wall
	  back bays      26 wide on 1.20 podiums, 8 studs of walkway between them
	  side to back   4.5 studs, which is the aisle round each corner
	  back to office 1.4 studs -- the manager's glass box is at z 246.4 and it is
	                 what stops the back pair moving any further north
	  the middle     39 x 35 of clear floor, with the range laid into it

	The back pair are 25 long rather than the hero's old 26: two 27-wide kerbs plus
	the office do not fit across 66 studs, and a stud off each plinth is invisible
	where a two-stud gap between two tankers is not.
]]
--[[
	Where the lecterns go changed with the layout, and a flood fill is what said so.

	They used to stand at each plinth's NOSE, which was right when the rigs faced
	each other across a promenade -- the nose was where a person stood. Round the
	walls it is not: a side bay's nose points at the glass, so a lectern there sits
	in the three-stud strip along the shopfront and seals it into pockets (21 floor
	cells were cut off in the south-west corner), and a back bay's lectern lands
	squarely in the corner aisle and cuts it to two studs.

	So the side ones stand BESIDE their plinth facing the open floor, and the back
	ones sit inboard of their step, flanking the walkway between the two podiums.
	Every aisle is seven studs or better and nothing is walled off.
]]
local BAYS: { Bay } = {
	{ id = "Dart",     x = -99.5, z = 214, w = 11, d = 26, h = 0.50, yaw = 0,
		tx = -90.5, tz = 214 },
	{ id = "Longline", x = -48.5, z = 214, w = 11, d = 26, h = 0.50, yaw = 180,
		tx = -57.5, tz = 214 },
	{ id = "Cistern",  x = -92, z = 238.5, w = 25, d = 12, h = 1.20, yaw = 90,
		tx = -84, tz = 230.3, step = true },
	{ id = "Kerbline", x = -58, z = 238.5, w = 25, d = 12, h = 1.20, yaw = 90,
		tx = -66, tz = 230.3, step = true },
}

local function plinths(ctx: Ctx)
	local f = ctx.folder("Plinths")
	for _, b in ipairs(BAYS) do
		local rig = Rigs.ById[b.id]
		local top = FINISH_TOP + b.h
		local kerbH = b.h - 0.10
		box(ctx, f, "PlinthKerb_" .. b.id, b.w + 1, kerbH, b.d + 1, b.x,
			FINISH_TOP + kerbH * 0.5, b.z, INK, Enum.Material.SmoothPlastic)
		box(ctx, f, "Plinth_" .. b.id, b.w, b.h, b.d, b.x, FINISH_TOP + b.h * 0.5,
			b.z, CONCRETE, Enum.Material.Concrete)
		-- the shoulder between plinth edge and kerb edge, lit
		local ly = FINISH_TOP + kerbH + 0.08
		for _, s in ipairs({ -1, 1 }) do
			box(ctx, f, "PlinthGlow_" .. b.id, b.w + 1, 0.16, 0.5, b.x, ly,
				b.z + s * (b.d * 0.5 + 0.25), rig.tint, Enum.Material.Neon,
				{ query = false })
			box(ctx, f, "PlinthGlow_" .. b.id, 0.5, 0.16, b.d, b.x + s * (b.w * 0.5 + 0.25),
				ly, b.z, rig.tint, Enum.Material.Neon, { query = false })
		end
	end
	-- one step up onto a podium, so it can actually be walked onto. Placed off the
	-- bay's own south edge rather than written down, so moving a bay takes its
	-- step with it -- the hero's used to be a constant and was left behind twice.
	for _, b in ipairs(BAYS) do
		if b.step then
			box(ctx, f, "PlinthStep_" .. b.id, 8, 0.60, 2, b.x, FINISH_TOP + 0.30,
				b.z - b.d * 0.5 - 1, SLATE, Enum.Material.SmoothPlastic)
		end
	end
end

--[[
	A lectern at the nose of each plinth carrying that rig's name, its line, its
	four numbers and its price -- and a prompt that opens the buy screen on the
	truck you are standing in front of.

	The old building put this on a wall plate behind the truck, where nobody
	stands. Reading a spec sheet is what a person does at a car in a showroom, so
	the sheet goes where they will be.

	The host is named NamePlate_<id> and its numbers are written at runtime from
	Rigs.List rather than baked here. That module's own note says it exists so a
	rig can never advertise a figure it does not have, and a price carved into a
	saved building is exactly how it would.
]]
local function totems(ctx: Ctx)
	local f = ctx.folder("Totems")
	for _, b in ipairs(BAYS) do
		local rig = Rigs.ById[b.id]
		box(ctx, f, "TotemBase", 2.20, 0.30, 1.40, b.tx, FINISH_TOP + 0.15, b.tz,
			INK, Enum.Material.SmoothPlastic)
		box(ctx, f, "TotemPost", 0.90, 3.20, 0.90, b.tx, FINISH_TOP + 1.60, b.tz,
			SLATE, Enum.Material.Metal)
		-- 4.4 wide, not 3.6. A TextLabel with TextScaled on WRAPS before it shrinks,
		-- so a stat line one word too long for the face does not get smaller, it
		-- grows a fourth line and lands on the price.
		local head = box(ctx, f, "NamePlate_" .. b.id, 4.40, 4.80, 0.60, b.tx,
			FINISH_TOP + 5.80, b.tz, INK, Enum.Material.SmoothPlastic)
		-- the livery colour as a cap over the plate, not a stripe down its side:
		-- beside the text it laps the face and the first and last letter of every
		-- line disappears behind it
		box(ctx, f, "TotemPip", 4.60, 0.30, 0.70, b.tx, FINISH_TOP + 8.35, b.tz,
			rig.tint, Enum.Material.SmoothPlastic, { query = false })

		-- Stats and price are filled by DealershipSigns at runtime. The blanks are
		-- what shows if that script ever goes missing, which is a visible failure
		-- rather than a stale number nobody notices.
		lines(surface(head, Enum.NormalId.Front, 64), {
			{ name = "Title", text = rig.name, h = 0.22, y = 0.04,
				colour = SIGNTX, font = Enum.Font.LuckiestGuy },
			{ name = "Tagline", text = rig.tagline, h = 0.12, y = 0.27,
				colour = SUBTX, font = Enum.Font.Gotham },
			{ name = "Stats", text = "", h = 0.30, y = 0.41,
				colour = SUBTX, font = Enum.Font.GothamBold },
			{ name = "Price", text = "", h = 0.20, y = 0.74,
				colour = SIGNTX, font = Enum.Font.LuckiestGuy },
		})

		--[[
			The prompt sells nothing itself -- UpgradeService owns cash, the zone check
			and the save file. It opens the panel on the browser's own client, which
			SealerUIClient picks up off Triggered with no remote in between.

			The name matters twice: SealerUIClient hooks only prompts whose name
			contains "DealershipPrompt", and TruckServer counts the same substring when
			it decides whether a saved building is sound. Call it anything else and it
			is dead AND the building gets regenerated over the top of it.
		]]
		local p = Instance.new("ProximityPrompt")
		p.Name = "DealershipPrompt_" .. b.id
		p.ActionText = "Browse Rigs"
		p.ObjectText = rig.name
		p.MaxActivationDistance = 12
		p.RequiresLineOfSight = false
		p.Parent = head
	end
end

--==[ REAR OF THE HALL ]=====================================================

local function rearHall(ctx: Ctx)
	local f = ctx.folder("RearHall")
	local prop = { query = false }
	-- same reasoning as the shopfront: SmoothPlastic, not Enum.Material.Glass
	local glass = { transparency = 0.45 }

	--[[
		The manager's glass box in the north-west corner. One office, not two: a
		second says nothing the first did not, and a glazed room deep in a building
		puts three transparent surfaces on one sightline, which is where glass starts
		to look like soup.
	]]
	box(ctx, f, "MgrGlass_S", 3, 9, 0.30, -105.5, 4.55, 246.5, GLASSC,
		Enum.Material.SmoothPlastic, glass)
	box(ctx, f, "MgrGlass_S", 1, 9, 0.30, -98.5, 4.55, 246.5, GLASSC,
		Enum.Material.SmoothPlastic, glass)
	box(ctx, f, "MgrGlass_E", 0.30, 9, 8.5, -98, 4.55, 250.75, GLASSC,
		Enum.Material.SmoothPlastic, glass)
	for _, x in ipairs({ -104, -99 }) do
		box(ctx, f, "MgrMullion", 0.80, 9, 0.50, x, 4.55, 246.5, MULLION,
			Enum.Material.SmoothPlastic, prop)
	end
	box(ctx, f, "MgrHeadBeam", 9.30, 0.80, 0.60, -102.5, 9.40, 246.5, MULLION,
		Enum.Material.SmoothPlastic, prop)
	box(ctx, f, "MgrCeiling", 9, 0.30, 8.5, -102.5, 9.55, 250.75, LINER,
		Enum.Material.SmoothPlastic, prop)
	box(ctx, f, "MgrDesk", 6.00, 2.50, 3.00, -103, 1.45, 252, INK2,
		Enum.Material.SmoothPlastic, prop)
	box(ctx, f, "MgrDeskTop", 6.60, 0.25, 3.40, -103, 2.82, 252, WALL,
		Enum.Material.SmoothPlastic, prop)
	box(ctx, f, "MgrChair", 1.80, 2.60, 1.80, -103, 1.50, 249, SLATE,
		Enum.Material.Fabric, prop)
	board(ctx, f, "Sign_Manager", 0.30, 1.60, 5.00, -97.7, 8.00, 250.75,
		Enum.NormalId.Right, 48, { { text = "SALES MANAGER", h = 0.72, y = 0.14 } })

	--[[
		The brand wall behind the hero. Livery stripes floor to ceiling, the name
		across them, and the three model names under it -- the one place in the
		building where the whole range is spelled out in a single look.
	]]
	-- The lettering has moved to the floor in the middle of the hall -- there is a
	-- tanker parked against this wall now and the words were reading out from
	-- behind it. What is left is the panel and the livery, one stripe per rig, and
	-- the stripes come off Rigs.List so a new truck brings its own colour with it.
	box(ctx, f, "BrandWall", 18, 8, 0.50, -87, 12, 254.8, INK,
		Enum.Material.SmoothPlastic, prop)
	for i, r in ipairs(Rigs.List) do
		box(ctx, f, "BrandStripe", 1.60, 20.80, 0.30, -93 + (i - 1) * 4.5, 10.60,
			254.45, r.tint, Enum.Material.SmoothPlastic, prop)
	end

	-- Accessories, on the north wall in the gap between the brand wall and the
	-- parts shelving. Narrow on purpose: at ten studs it ran into the parts
	-- shelving and closed the only route to the parts counter.
	box(ctx, f, "AccessoryShelving", 5, 9, 2, -74.5, 4.70, 253, SLATE,
		Enum.Material.Metal, prop)
	for i = 0, 5 do
		box(ctx, f, "StockBlock", 1.40, 1.40, 1.40, -76 + (i % 3) * 1.5,
			1.20 + math.floor(i / 3) * 3.20, 253,
			({ YELLOW, BLUE, LINER })[(i % 3) + 1], Enum.Material.SmoothPlastic, prop)
	end
	-- clear of the hero kerb, which now reaches x -70.5
	for _, dx in ipairs({ -1.2, 0, 1.2 }) do
		cylY(ctx, f, "WandRack", 6.00, 0.30, -66 + dx, 3.20, 247, STEEL,
			Enum.Material.Metal, prop)
	end
end

--==[ OUTSIDE ]==============================================================

--[[
	The pylon is the answer to "I never noticed the dealership".

	The compound wall tops out at 17.4 and every building on this side of it sits
	behind that line from the yard; the blade reaches 31.9, which clears it from
	the depot apron, from the crossover and from the yard gate. It does NOT clear
	it from the spawn point -- the tutorial notice board and the divide wall put
	that sightline about twenty studs out of reach of anything buildable -- and
	chasing it would only have made the sign taller for nothing.
]]
local function outside(ctx: Ctx)
	local f = ctx.folder("Outside")
	local prop = { query = false }

	--[ pylon ]---------------------------------------------------------------
	box(ctx, f, "PylonPlinth", 7.20, 4.00, 3.60, -44, 2.05, 167, INK,
		Enum.Material.SmoothPlastic, { shadow = true })
	local blade = box(ctx, f, "PylonBlade", 7.00, 27, 2.00, -44, 17.55, 167, INK,
		Enum.Material.SmoothPlastic, { shadow = true })
	box(ctx, f, "PylonCap", 7.60, 0.90, 2.60, -44, 31.5, 167, BLUE,
		Enum.Material.SmoothPlastic, { shadow = true })
	box(ctx, f, "PylonGlow", 6.80, 0.20, 2.40, -44, 4.25, 167, NEONW,
		Enum.Material.Neon, prop)
	for i, r in ipairs(Rigs.List) do
		box(ctx, f, "PylonPip", 0.50, 3.00, 2.20, -47.45, 10.5 + (i - 1) * 5, 167,
			r.tint, Enum.Material.SmoothPlastic, prop)
	end
	for _, face in ipairs({ Enum.NormalId.Right, Enum.NormalId.Left }) do
		lines(surface(blade, face, 26), {
			{ text = "SEALCOAT", h = 0.13, y = 0.08, colour = SIGNTX,
				font = Enum.Font.LuckiestGuy },
			{ text = "RIGS", h = 0.13, y = 0.22, colour = SIGNTX,
				font = Enum.Font.LuckiestGuy },
			{ text = "NEW", h = 0.07, y = 0.42 },
			{ text = "USED", h = 0.07, y = 0.51 },
			{ text = "HIRE", h = 0.07, y = 0.60 },
			{ text = "TRADE", h = 0.07, y = 0.69 },
			{ text = "FINANCE", h = 0.07, y = 0.78, colour = SUBTX,
				font = Enum.Font.Gotham },
		})
	end

	--[ lamp posts, on the drive lane's north edge and never inside a bay ]----
	-- Four, not five, and spread: at six studs apart they read as a picket fence
	-- across the shopfront rather than as lighting.
	for _, x in ipairs({ -106, -99, -72, -62 }) do
		cylY(ctx, f, "LampPost", 24, 0.60, x, 12.05, 191, SLATE,
			Enum.Material.Metal, prop)
		box(ctx, f, "LampHead", 4.00, 1.00, 2.00, x, 24.55, 191, SLATE,
			Enum.Material.Metal, prop)
		local lens = box(ctx, f, "LampLens", 3.40, 0.20, 1.20, x, 23.95, 191, NEONW,
			Enum.Material.Neon, prop)
		local sl = Instance.new("SpotLight")
		sl.Face = Enum.NormalId.Bottom
		sl.Angle = 100
		sl.Brightness = 1.6
		sl.Range = 34
		sl.Color = Color3.fromRGB(255, 244, 214)
		sl.Shadows = false
		sl.Parent = lens
	end

	--[ flags on the verge, read against sky over the yard wall ]--------------
	-- one per rig, off Rigs.List rather than a written-out three
	for i, r in ipairs(Rigs.List) do
		local x = -104 + (i - 1) * 8
		cylY(ctx, f, "Flagpole", 26, 0.40, x, 13, 161,
			Color3.fromRGB(236, 236, 232), Enum.Material.Metal, prop)
		cylY(ctx, f, "Finial", 0.60, 0.70, x, 26.3, 161, YELLOW,
			Enum.Material.Metal, prop)
		box(ctx, f, "Flag", 5.00, 4.00, 0.12, x + 3, 23.5, 161, r.tint,
			Enum.Material.SmoothPlastic, prop)
	end

	--[ planters, flanking the door without gating it ]------------------------
	for _, x in ipairs({ -105, -99, -76.5, -70.5 }) do
		box(ctx, f, "Planter", 5.00, 2.20, 2.60, x, 1.15, 194, PAVING,
			Enum.Material.SmoothPlastic, prop)
		box(ctx, f, "PlanterSoil", 4.40, 0.30, 2.00, x, 2.35, 194,
			Color3.fromRGB(74, 58, 44), Enum.Material.Ground, prop)
	end

	-- (two cones stood in front of the workshop shutter. There is no shutter on
	-- this face any more, and a cone in front of a shopfront is litter.)

	box(ctx, f, "SitePost", 0.60, 7.00, 0.60, -38.5, 3.55, 181, SLATE,
		Enum.Material.Metal, prop)
	board(ctx, f, "Blade_Site", 0.30, 2.50, 6.00, -38.5, 7.00, 181,
		Enum.NormalId.Right, 30, {
			{ text = "SHOWROOM  \u{2190}", h = 0.44, y = 0.06 },
			{ text = "SALES  \u{2190}", h = 0.30, y = 0.56, colour = SUBTX,
				font = Enum.Font.Gotham },
		})

	--[ rear yard ]-----------------------------------------------------------
	local line = { query = false, collide = false }
	for _, x in ipairs({ -106, -96, -86, -76 }) do
		box(ctx, f, "StaffBayLine", 0.45, 0.08, 7, x, PAINT_Y, 259.5, WHITEL,
			Enum.Material.SmoothPlastic, line)
	end
	for i = 0, 7 do
		local h = box(ctx, f, "DeliveryChevron", 0.30, 0.08, 4, -56 + i * 1.8,
			PAINT_Y, 259.5, YELLOW, Enum.Material.SmoothPlastic, line)
		h.CFrame = at(ctx, -56 + i * 1.8, PAINT_Y, 259.5) * CFrame.Angles(0, math.rad(45), 0)
	end
	for _, x in ipairs({ -68.5, -66 }) do
		box(ctx, f, "Bin", 2.20, 3.00, 2.00, x, 1.55, 259, SLATE,
			Enum.Material.SmoothPlastic, prop)
	end
	box(ctx, f, "BinScreen", 8.00, 4.00, 0.40, -67, 2.05, 261.2, WALL,
		Enum.Material.SmoothPlastic, prop)
	for i = 0, 2 do
		box(ctx, f, "PalletStack", 4.20, 0.50, 4.20, -80, 0.30 + i * 0.55, 260,
			WOOD, Enum.Material.WoodPlanks, prop)
	end
end

--==[ SIGNAGE ]==============================================================

local function signage(ctx: Ctx)
	local f = ctx.folder("Signage")

	-- the name over the door, on the portal spandrel between the head and the band
	board(ctx, f, "SignBoard", 18, 4.5, 0.80, -87, 17.3, 195.65,
		Enum.NormalId.Front, 40, {
			{ text = "SEALCOAT RIGS", h = 0.56, y = 0.06, colour = SIGNTX,
				font = Enum.Font.LuckiestGuy },
			{ text = "NEW  \u{2022}  USED  \u{2022}  FINANCE", h = 0.24, y = 0.66,
				colour = SUBTX, font = Enum.Font.GothamBold },
		})
	box(ctx, f, "SignGlow", 17, 0.18, 0.50, -87, 14.95, 195.65, YELLOW,
		Enum.Material.Neon, { query = false })

	board(ctx, f, "CanopyFascia", 18, 1.20, 0.50, -87, 12.1, 186.75,
		Enum.NormalId.Front, 40, {
			{ text = "SALES  \u{2022}  SHOWROOM", h = 0.80, y = 0.10 },
		}, BLUE)

	-- over the south shutter, which used to be the workshop's drive-through and is
	-- now how a rig gets into the hall
	board(ctx, f, "Blade_Stock", 12, 1.60, 0.30, -49.5, 15.9, 195.35,
		Enum.NormalId.Front, 48, {
			{ text = "RIGS IN STOCK", h = 0.78, y = 0.11 },
		})

	board(ctx, f, "Vinyl_Hours", 3.00, 5.00, 0.14, -70.625, 5.00, 196.15,
		Enum.NormalId.Front, 44, {
			{ text = "OPEN", h = 0.20, y = 0.05, colour = SIGNTX,
				font = Enum.Font.LuckiestGuy },
			{ text = "MON\u{2013}SAT", h = 0.12, y = 0.30, colour = SUBTX,
				font = Enum.Font.Gotham },
			{ text = "08:00 \u{2013} 18:00", h = 0.14, y = 0.44 },
			{ text = "SUN CLOSED", h = 0.11, y = 0.62, colour = SUBTX,
				font = Enum.Font.Gotham },
			{ text = "FINANCE MON\u{2013}FRI", h = 0.10, y = 0.78, colour = SUBTX,
				font = Enum.Font.Gotham },
		}, INK2)

	board(ctx, f, "Banner_Finance", 16, 3, 0.20, -69, 17.5, 195.85,
		Enum.NormalId.Front, 26, {
			{ text = "0% FINANCE ON EVERY RIG", h = 0.62, y = 0.18 },
		})

	-- Nothing on the east wall. The parts sign and the delivered-this-month board
	-- hung over the customer strip, and a rig is parked against that liner now --
	-- both would be reading out from behind a tanker.

	board(ctx, f, "Sign_Deliveries", 8, 1.60, 0.40, -80, 13.2, 256.35,
		Enum.NormalId.Back, 40, {
			{ text = "DELIVERIES", h = 0.76, y = 0.12 },
		})
end

--==[ LIGHTING ]=============================================================

--[[
	Twenty-seven lights, and the restraint is the point.

	The scene is Brightness 2.6 at two in the afternoon with Bloom thresholded at
	1.75. Twenty more PointLights in a daylight interior buy nothing you can see
	and cost plenty; what actually makes the hall read as lit is a pale floor, a
	light grey liner and a dozen near-white tubes -- which is the depot garage's
	own trick, and why its liner is 203,206,211 rather than white.

	Every light in this place has Shadows off. No exceptions anywhere, and this is
	not the building to start.
]]
local function lamp(host: BasePart, colour: Color3, brightness: number, range: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Brightness = brightness
	l.Range = range
	l.Shadows = false
	l.Parent = host
end

local function lighting(ctx: Ctx)
	local f = ctx.folder("Lighting")
	local fix = { query = false, collide = false }

	--[ hall pendants ]-------------------------------------------------------
	-- three columns over a 48-stud tall half: one over each rig and one down the
	-- promenade between them. Two left the middle of the hall lit only by bounce.
	for _, x in ipairs({ -97, -84, -71 }) do
		for _, z in ipairs({ 207, 220, 233, 246 }) do
			box(ctx, f, "PendantStem", 0.18, 3.35, 0.18, x, 19.53, z, SLATE,
				Enum.Material.Metal, fix)
			box(ctx, f, "PendantHousing", 9.00, 0.50, 1.50, x, 21.00, z, SLATE,
				Enum.Material.Metal, fix)
			local tube = box(ctx, f, "PendantTube", 8.30, 0.16, 1.05, x, 20.67, z,
				NEONW, Enum.Material.Neon, fix)
			-- lit in six of the eight; a tube that is only a tube still reads, and
			-- the light instance is the expensive half
			if x == -97 or z == 207 or z == 246 then
				lamp(tube, Color3.fromRGB(255, 244, 214), 0.85, 30)
			end
		end
	end

	--[ a spot over each rig, in that rig's own colour ]-----------------------
	for _, b in ipairs(BAYS) do
		local can = box(ctx, f, "PlinthCan", 1.60, 0.80, 1.60, b.x, 19.80, b.z,
			SLATE, Enum.Material.Metal, fix)
		local sl = Instance.new("SpotLight")
		sl.Face = Enum.NormalId.Bottom
		sl.Angle = 90
		sl.Brightness = 2.2
		sl.Range = 30
		sl.Color = Rigs.ById[b.id].tint
		sl.Shadows = false
		sl.Parent = can
	end

	--[ wall lamps down the east band ]---------------------------------------
	for _, z in ipairs({ 208, 222, 228, 240 }) do
		local w = box(ctx, f, "WallLamp", 0.70, 0.90, 1.40, -41.45, 9.50, z, SLATE,
			Enum.Material.Metal, fix)
		lamp(w, Color3.fromRGB(255, 228, 184), 0.45, 14)
	end

	--[ strips over the low east bay ]----------------------------------------
	for _, z in ipairs({ 204, 212, 220, 232, 240, 248 }) do
		box(ctx, f, "StripHousing", 14, 0.50, 1.50, -49.5, 14.60, z, SLATE,
			Enum.Material.Metal, fix)
		local tube = box(ctx, f, "StripTube", 13.30, 0.16, 1.05, -49.5, 14.28, z,
			NEONW, Enum.Material.Neon, fix)
		if z == 204 or z == 220 or z == 240 then
			lamp(tube, Color3.fromRGB(255, 244, 214), 0.85, 26)
		end
	end

	--[ outside ]-------------------------------------------------------------
	for _, x in ipairs({ -92, -82 }) do
		local d = cylY(ctx, f, "CanopyDownlight", 0.30, 1.60, x, 12.00, 191.5, NEONW,
			Enum.Material.Neon, fix)
		lamp(d, Color3.fromRGB(255, 238, 210), 0.60, 18)
	end

	-- washes the pylon blade from below; Face Top throws it up the sign, which
	-- Face Front would have thrown into the grass
	local up = box(ctx, f, "PylonUplight", 1.60, 0.30, 0.80, -44, 4.30, 169.2,
		SLATE, Enum.Material.Metal, fix)
	local ul = Instance.new("SpotLight")
	ul.Face = Enum.NormalId.Top
	ul.Angle = 60
	ul.Brightness = 1.4
	ul.Range = 26
	ul.Color = Color3.fromRGB(255, 244, 214)
	ul.Shadows = false
	ul.Parent = up

	for _, x in ipairs({ -96, -60 }) do
		local p = box(ctx, f, "WallPack", 1.20, 0.80, 0.60, x, 11.00, 256.35, SLATE,
			Enum.Material.Metal, fix)
		lamp(p, Color3.fromRGB(255, 244, 214), 0.50, 16)
	end
end

--==[ THE DISPLAY RIGS ]=====================================================

--[[
	Three real trucks, frozen.

	Each is a genuine TruckBuilder rig in its own livery AND its own proportions --
	Rigs.body turns the catalogue stats into the size of the barrel and the reel,
	so the Cistern on the podium really is the fat one and the Dart really is the
	small one. What is on the plinth is the thing that turns up in the bay.

	Freezing is four separate removals and every one of them matters. Anchoring
	alone is not enough: an anchored chassis with live motor hinges still simulates
	its wheels. The seat has to go too, or a player sits down in an exhibit that
	will never move. And nothing here may carry OwnerUserId, RigId or a tank
	figure -- RigController claims a truck by owner id and would otherwise start
	driving the showroom.

	Seated by MEASUREMENT rather than arithmetic: the pivot sits about two studs
	above the bottom of the bounding box, but that is a fact about the current
	wheel size rather than a promise, so the model is dropped onto its plinth from
	its own measured underside.
]]
-- the two hidden colliders TruckBuilder already uses; everything else on a
-- display rig is cosmetic and passes through
local SOLID = { Hull = true, Base = true }
-- only the silhouette casts, or three trucks would add ~500 shadow casters to a
-- place that runs 1,440 in total
local CASTS = {
	Tank = true, TankHead = true, CabRoof = true, CabRear = true, CabSide = true,
	Hood = true, Deck = true, Windscreen = true, PillarA = true, PillarB = true,
}

local function displayRigs(ctx: Ctx)
	local f = ctx.folder("Display")
	for _, b in ipairs(BAYS) do
		local rig = Rigs.ById[b.id]
		local shape = Rigs.body(rig)
		local m = TruckBuilder.build(
			at(ctx, b.x, 0, b.z) * CFrame.Angles(0, math.rad(b.yaw), 0), f, {
				cab = rig.cab, tint = rig.tint,
				tankDia = shape.tankDia, tankLen = shape.tankLen,
				reelDia = shape.reelDia, reelWidth = shape.reelWidth,
			})
		m.Name = "Display_" .. b.id

		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = SOLID[d.Name] == true
				--[[
					Out of the rig collision groups and into the exhibits' own.

					Driveable rigs pass through each other now (see ensureCollisionGroups
					in TruckBuilder), and an exhibit is built by the same builder -- so
					left in SealRigBody these would have inherited that and let a customer
					drive their truck clean through the display they came to look at.

					This was Default until 2026-08-10, which bought the driving back at the
					cost of the walking. Default collides with people, so these four were
					the last truck in the place that could body-block one -- the driveable
					rig had already stopped doing it, which is why "people collide into
					trucks" only ever happened in the showroom. SealRigDisplay keeps every
					default Default had and drops exactly one pair: itself against
					SealRigPlayer. A driven truck still stops at an exhibit.

					This line only reaches a REGENERATED showroom. The authored one saved
					in the place was built before any of it existed and is adopted
					untouched by TruckServer, so its four exhibits have been moved by hand
					to match -- to Default on 2026-08-09, to this group on 2026-08-10. A
					showroom re-saved from an older build would need the same doing again:
					there is no code path that will do it.
				]]
				d.CollisionGroup = TruckBuilder.DisplayGroup
				d.CanQuery = false
				d.CastShadow = CASTS[d.Name] == true
				-- The cab glazing goes with the shopfront's, and for the same reason:
				-- Enum.Material.Glass refracts what is behind it in screen space, and a
				-- windscreen with a lit showroom behind it smears into radial streaks.
				-- It is only wrong indoors -- the driveable rig keeps its real glass.
				if d.Material == Enum.Material.Glass then
					d.Material = Enum.Material.SmoothPlastic
					d.Transparency = 0.45
				end
			-- WeldConstraint is NOT a subclass of Constraint, so it needs saying
			-- separately or a hundred and fifty of them ride along into the place.
			elseif d:IsA("Constraint") or d:IsA("WeldConstraint") or d:IsA("Attachment")
				or d:IsA("JointInstance") or d:IsA("Light") then
				d:Destroy()
			end
		end
		for _, name in ipairs({ "Drives", "Steers" }) do
			local folder = m:FindFirstChild(name)
			if folder then folder:Destroy() end
		end
		for _, d in ipairs(m:GetChildren()) do
			if d:IsA("Seat") or d:IsA("VehicleSeat") or d.Name == "Knuckle" then
				d:Destroy()
			end
		end
		for _, key in ipairs({ "Tank", "TankCapacity", "HosePaidOut" }) do
			m:SetAttribute(key, nil)
		end

		local cf, size = m:GetBoundingBox()
		local want = at(ctx, 0, FINISH_TOP + b.h, 0).Y
		m:PivotTo(m:GetPivot() + Vector3.new(0, want - (cf.Y - size.Y * 0.5), 0))
	end
end

--==[ ASSEMBLY ]=============================================================

function DealershipBuilder.build(origin: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "RigDealership"

	local folders: { [string]: Instance } = {}
	local ctx: Ctx
	ctx = {
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

	-- Floor first, and as a DIRECT child. Both halves of the purchase gate find
	-- it with a non-recursive FindFirstChild on this model and both treat "not
	-- there" as "sell rigs anywhere on the map", so its position in the tree is a
	-- contract rather than tidiness.
	local floor = pad(ctx)
	model.PrimaryPart = floor

	forecourt(ctx)
	shell(ctx)
	finishes(ctx)
	structure(ctx)
	plinths(ctx)
	totems(ctx)
	rearHall(ctx)
	outside(ctx)
	signage(ctx)
	lighting(ctx)
	displayRigs(ctx)

	-- Pre-emptive: StreamingEnabled is off in this place today, but if it is ever
	-- turned on an unstreamed Floor is exactly the fail-open above, arriving from
	-- a setting nobody would connect to this building.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	model.Parent = parent
	return model
end

return DealershipBuilder
