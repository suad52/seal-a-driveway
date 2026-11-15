--!strict
--[[
	AfkYardBuilder -- the quiet street you leave a man working in.

	A sibling of DealershipBuilder and RetailParkBuilder: the recipe the area was
	made from, and the fallback for a place that has lost it. AfkService calls it
	on startup if Workspace has no AfkYard, so the area cannot go missing.

	To rebuild the saved one after editing this file, from the command bar:

		local M = require(game.ReplicatedStorage.DrivewaySealer.AfkYardBuilder)
		local Afk = require(game.ReplicatedStorage.DrivewaySealer.Afk)
		local old = workspace:FindFirstChild("AfkYard")
		if old then old:Destroy() end
		M.build(CFrame.new(Afk.Origin), workspace)

	No rotation in that snippet, for the reason its two siblings give: every
	number below is a survey coordinate and `at()` only translates. A turned model
	would swap which axis is 61 studs of drive and which is 34.

	WHY THE SLABS ARE NOT TAGGED

	Not one slab here carries SealableDriveway, and that is the single most
	important line in the file. The tag is what puts a slab into DrivewayClient's
	build queue, into Sections' progress counters, into the Lucky board's draw and
	onto DrivewayServer's payout path -- where it would pay once, forty seconds
	into the first visit, and never again for the rest of that rebirth.

	DrivewaySurface.new takes a BasePart and asks nothing about tags, so AfkClient
	builds its own surface on its own plot directly. The yard therefore runs the
	real simulation and touches none of the systems the real map runs on. Tagging
	one of these slabs "to make it work properly" would add it to every gate
	counter in the game and lengthen the road unlock for every player.

	AND NOTHING VERTICAL STANDS ON A SLAB

	Same rule as the retail park, same reason: DrivewaySurface subtracts anything
	anchored, queryable and opaque standing between +0.06 and +2.50 above a slab
	from its mask, coverage is sealed/mask against Config.CompleteAt = 0.98, so a
	prop on the drive is a driveway that can never finish -- and here that means a
	puppet that never gets to the end of its lap. The hedges stop 27 studs short,
	the pads sit 7 studs off the edge, and the kerb clears by 0.02, which is under
	the 0.06 lip and therefore ignored exactly as it is on Maple Drive.
]]

local AfkYardBuilder = {}

local Afk = require(script.Parent.Afk)

--==[ PALETTE ]===============================================================

-- Read off the built neighbourhood rather than picked, so the yard is the same
-- street as everywhere else the player has been.
local GRASS    = Color3.fromRGB(118, 206, 88)
local CONCRETE = Color3.fromRGB(121, 119, 110)
local ASPHALT  = Color3.fromRGB(74, 74, 78)
local KERB     = Color3.fromRGB(237, 235, 226)
local HEDGE    = Color3.fromRGB(62, 134, 62)
local PAINT    = Color3.fromRGB(240, 226, 150)
local POST     = Color3.fromRGB(94, 74, 56)
local SIGN     = Color3.fromRGB(28, 64, 126)
local MINT     = Color3.fromRGB(52, 226, 214)
local GOLD     = Color3.fromRGB(255, 206, 56)

--==[ THE SURVEY ]============================================================

local PLOTS  = Afk.PlotCount
local PITCH  = Afk.PlotPitch
local SLAB   = Afk.SlabSize
local KERB_X = Afk.KerbX
local ROAD_H = Afk.RoadHalf

-- Slab centre x, straight off Lot_106. Its east edge lands on -15, flush with
-- the kerb's road face, which is what makes the drive meet the street.
local SLAB_X = -45.5
local HALF_Z = SLAB.Z * 0.5

-- Ends of the street, a plot's breathing room past the first and last drive.
local Z0 = -PITCH
local Z1 = (PLOTS - 1) * PITCH + PITCH

-- The invisible wall, and the lawn that has to reach past both it and the trees
-- standing outside it. Sized here rather than at each call site because three
-- separate functions have to agree on where the edge of the world is.
local WALL_W, WALL_E = -215, 95
local YARD_MID = (Z0 + Z1) * 0.5
local WALL_LEN = (Z1 - Z0) + 180

--==[ PRIMITIVES ]============================================================

type Ctx = { root: CFrame, model: Model }

local function at(ctx: Ctx, x: number, y: number, z: number): CFrame
	return ctx.root * CFrame.new(x, y, z)
end

local function piece(into: Instance, name: string, size: Vector3, colour: Color3,
	material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = into
	return p
end

local function box(ctx: Ctx, into: Instance, name: string, sx: number, sy: number,
	sz: number, x: number, y: number, z: number, colour: Color3,
	material: Enum.Material?): Part
	local p = piece(into, name, Vector3.new(sx, sy, sz), colour, material)
	p.CFrame = at(ctx, x, y, z)
	return p
end

local function folder(ctx: Ctx, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = ctx.model
	return f
end

local function ppsFor(letterStuds: number): number
	return 95 / letterStuds
end

-- Clears the deepest support in the yard by 0.15: the entrance piers, which
-- stand 0.1 proud of a board placed on their header. A quarter stud of extra
-- thickness on boards ten to forty-four studs wide, i.e. nothing to look at.
local PROUD = 0.25

local function board(ctx: Ctx, into: Instance, name: string, sx: number, sy: number,
	x: number, y: number, z: number, text: string, letterStuds: number,
	face: Color3, ink: Color3, yawDeg: number?): Part
	local host = piece(into, name, Vector3.new(sx, sy, 0.4 + PROUD), face)
	host.CFrame = at(ctx, x, y, z)
		* CFrame.Angles(0, math.rad(yawDeg or 0), 0)
		* CFrame.new(0, 0, -PROUD * 0.5)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppsFor(letterStuds)
	gui.AlwaysOnTop = false
	gui.Parent = host
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.LuckiestGuy
	lbl.Text = text
	lbl.TextScaled = true
	lbl.TextColor3 = ink
	lbl.Parent = gui
	return host
end

-- Move every part by a delta rather than pivoting. These models have no
-- PrimaryPart, so PivotTo would work off the bounding box and quietly re-seat
-- anything whose own pivot had been moved; a translation cannot.
local function shift(m: Instance, delta: Vector3)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CFrame = d.CFrame + delta
		end
	end
	if m:IsA("BasePart") then
		local p = m :: BasePart
		p.Anchored = true
		p.CFrame = p.CFrame + delta
	end
end

--==[ GROUND AND STREET ]=====================================================

local function ground(ctx: Ctx)
	local f = folder(ctx, "Ground")
	box(ctx, f, "Lawn", 460, 6, (Z1 - Z0) + 300, -60, -3, YARD_MID, GRASS)
end

local function road(ctx: Ctx)
	local f = folder(ctx, "Street")
	local zLen = Z1 - Z0

	box(ctx, f, "Carriageway", ROAD_H * 2, 0.5, zLen, 0, -0.15, YARD_MID, ASPHALT)

	-- Dashes down the middle. CanQuery false on principle -- they are nowhere near
	-- a slab here, but a painted line that forgot it is a blocker everywhere else
	-- in this codebase and the habit is cheaper than the exception.
	local z = Z0 + 8
	while z < Z1 - 8 do
		local dash = box(ctx, f, "Dash", 0.7, 0.06, 7, 0, 0.1, z, PAINT)
		dash.CanQuery = false
		dash.CanTouch = false
		z += 16
	end

	local function kerbRun(zA: number, zB: number)
		if zB - zA < 1 then return end
		box(ctx, f, "Kerb", 2, 2, zB - zA, KERB_X, -0.9, (zA + zB) * 0.5, KERB)
	end
	local cursor = Z0
	for i = 1, PLOTS do
		local c = (i - 1) * PITCH
		kerbRun(cursor, c - HALF_Z)
		cursor = c + HALF_Z
	end
	kerbRun(cursor, Z1)
	box(ctx, f, "Kerb", 2, 2, zLen, -KERB_X, -0.9, YARD_MID, KERB)

	-- Verge between the kerb and the lawn, so the road is not a strip of tar laid
	-- straight onto grass.
	for _, side in ipairs({ -21, 21 }) do
		box(ctx, f, "Verge", 8, 0.4, zLen, side, -0.2, YARD_MID, GRASS)
	end
end

--==[ A PLOT ]================================================================

local function donorHouse(): Model?
	local lots = workspace:FindFirstChild("Neighbourhood")
	lots = lots and lots:FindFirstChild("Lots")
	local h = lots and lots:FindFirstChild(Afk.HouseSource)
	return (h and h:IsA("Model")) and h or nil
end

local function plot(ctx: Ctx, into: Instance, i: number, house: Model?)
	local cz = (i - 1) * PITCH

	local m = Instance.new("Model")
	m.Name = Afk.plotName(i)
	m.Parent = into

	local slab = box(ctx, m, "Driveway", SLAB.X, SLAB.Y, SLAB.Z,
		SLAB_X, Afk.SlabY, cz, CONCRETE)
	slab:SetAttribute("AfkPlot", i)
	slab:SetAttribute("DrivewayName", ("Yard Plot %d"):format(i))

	-- The house, seated so its garage door meets the top of the drive.
	if house then
		local clone = house:Clone()
		clone.Name = "House"
		local bcf = clone:GetBoundingBox()
		local want = at(ctx,
			SLAB_X + Afk.HouseOffset.X, Afk.HouseY, cz + Afk.HouseOffset.Z).Position
		shift(clone, want - bcf.Position)
		clone.Parent = m
	end

	if i < PLOTS then
		box(ctx, m, "Hedge", 92, 7, 3, -66, 3.5, cz + PITCH * 0.5, HEDGE,
			Enum.Material.Grass)
	end

	-- Mailbox at the kerb, and a post to stand it on, so the street reads as
	-- addresses rather than as eight copies of one house.
	box(ctx, m, "Post", 0.7, 4, 0.7, -20, 2, cz - HALF_Z - 5, POST, Enum.Material.Wood)
	local mb = box(ctx, m, "Mailbox", 1.6, 1.4, 3, -20, 4.6, cz - HALF_Z - 5, SIGN)
	mb.Material = Enum.Material.Metal

	local pz = cz + HALF_Z + 7
	local pad = box(ctx, m, "LeavePad", 8, 0.3, 8, -26, 0.15, pz, GOLD)
	pad.Material = Enum.Material.Neon
	local signPost = box(ctx, m, "SignPost", 0.6, 7.5, 0.6, -26, 3.75, pz, POST,
		Enum.Material.Wood)
	signPost.CanCollide = false

	board(ctx, m, "LeaveSign", 10, 2.6, -26, 8.6, pz, "BACK TO WORK", 1.7, SIGN, MINT)
	board(ctx, m, "LeaveKey", 10, 1.9, -26, 6.35, pz, "PRESS  E", 1.2, SIGN, GOLD)
end

--==[ THE ENTRANCE ]==========================================================

local function entrance(ctx: Ctx)
	local f = folder(ctx, "Entrance")
	local z = Z0 - 20

	for _, x in ipairs({ -20, 20 }) do
		box(ctx, f, "Pier", 4, 20, 4, x, 10, z, CONCRETE, Enum.Material.Concrete)
	end
	box(ctx, f, "Header", 48, 5, 3, 0, 22, z, SIGN)
	board(ctx, f, "YardSign", 44, 4.2, 0, 22, z + 1.7, "THE YARD", 3.0, SIGN, GOLD, 180)
	board(ctx, f, "YardBlurb", 44, 2.2, 0, 17.5, z + 1.7,
		"YOUR CREW WORKS WHILE YOU ARE AWAY", 1.3, SIGN, MINT, 180)
end

--==[ BOUNDS AND TREES ]======================================================

local function bounds(ctx: Ctx)
	local f = folder(ctx, "Bounds")
	local function wall(name: string, sx: number, sz: number, x: number, z: number)
		local w = box(ctx, f, name, sx, 120, sz, x, 56, z, Color3.new(1, 1, 1))
		w.Transparency = 1
		w.CanQuery = false
		w.CastShadow = false
	end
	wall("BoundW", 4, WALL_LEN, WALL_W, YARD_MID)
	wall("BoundE", 4, WALL_LEN, WALL_E, YARD_MID)
	wall("BoundS", WALL_E - WALL_W + 4, 4, (WALL_W + WALL_E) * 0.5,
		YARD_MID - WALL_LEN * 0.5)
	wall("BoundN", WALL_E - WALL_W + 4, 4, (WALL_W + WALL_E) * 0.5,
		YARD_MID + WALL_LEN * 0.5)
end

local function treeline(ctx: Ctx)
	local f = folder(ctx, "Treeline")
	local pool = workspace:FindFirstChild("EstateDistrict")
	pool = pool and pool:FindFirstChild("Treeline")
	if not pool then return end
	local donors = pool:GetChildren()
	if #donors == 0 then return end

	local z0, z1 = YARD_MID - WALL_LEN * 0.5, YARD_MID + WALL_LEN * 0.5

	-- A deterministic scatter: the same yard every rebuild, and no Random object
	-- to seed. The primes give a walk that does not visibly repeat over the couple
	-- of hundred trees this lays down.
	local n = 0
	local function tree(x: number, z: number)
		n += 1
		local src = donors[(n * 7) % #donors + 1]
		if not (src:IsA("Model") or src:IsA("BasePart")) then return end
		local c = src:Clone()
		local centre = if c:IsA("Model")
			then c:GetBoundingBox().Position
			else (c :: BasePart).Position
		shift(c, at(ctx, x, centre.Y, z).Position - centre)
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CanCollide, d.CanQuery, d.CastShadow = false, false, false
			end
		end
		if c:IsA("BasePart") then
			local p = c :: BasePart
			p.CanCollide, p.CanQuery, p.CastShadow = false, false, false
		end
		c.Parent = f
	end

	local STEP = 20
	local BANDS = { 8, 26 }
	local j = 0
	for z = z0, z1, STEP do
		j += 1
		local jitter = ((j * 37) % 23) - 11
		for _, band in ipairs(BANDS) do
			tree(WALL_W - band - jitter * 0.4, z + jitter)
			tree(WALL_E + band + jitter * 0.4, z - jitter)
		end
	end
	for x = WALL_W, WALL_E, STEP do
		j += 1
		local jitter = ((j * 37) % 23) - 11
		for _, band in ipairs(BANDS) do
			tree(x + jitter, z0 - band - jitter * 0.4)
			tree(x - jitter, z1 + band + jitter * 0.4)
		end
	end
end

--==[ THE DOOR IN ]==========================================================

-- The apothem: centre to WALL FACE, not to corner. An octagon's face is
-- 2*r*tan(22.5) across, and that is the one number the walls, the header and the
-- floor all have to agree on.
--
-- Sized down from 13 on 2026-08-14: at that radius it was a building rather than
-- a booth and it crowded the depot lawn. Nine is still two strides of room round
-- the disc, which is all the trigger needs.
local ARENA_R    = 9
local ARENA_FACE = 2 * ARENA_R * math.tan(math.rad(22.5))
local ARENA_WALL = 6      -- over a sight line, under a jump
local ARENA_DOOR = 3.2    -- half the opening
local ARENA_PIER = 1.2

AfkYardBuilder.ArenaName = "AfkArena"

function AfkYardBuilder.buildArena(origin: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = AfkYardBuilder.ArenaName
	local ctx: Ctx = { root = origin, model = model }

	for k = 1, 7 do
		local panel = piece(model, "Wall",
			Vector3.new(ARENA_FACE + 1.2, ARENA_WALL, 1), SIGN)
		panel.CFrame = origin
			* CFrame.Angles(0, math.rad(k * 45), 0)
			* CFrame.new(0, ARENA_WALL * 0.5, -ARENA_R)
	end

	local function disc(name: string, d: number, y: number, colour: Color3,
		material: Enum.Material?): Part
		local p = piece(model, name, Vector3.new(0.3, d, d), colour, material)
		p.Shape = Enum.PartType.Cylinder
		p.CFrame = at(ctx, 0, y, 0) * CFrame.Angles(0, 0, math.rad(90))
		return p
	end
	disc("Rim",  ARENA_R * 2 - 0.5, 0.15, SIGN)
	disc("Pad",  ARENA_R * 2 - 3.5, 0.22, GOLD, Enum.Material.Neon)
	disc("Core", 6.5,               0.30, MINT, Enum.Material.Neon)

	-- The arch: two piers, a header, and the sign that says what the room is for.
	-- Lamps on the piers because this is the one landmark that has to be findable
	-- at night, and the yard's own arch is lit the same way.
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (ARENA_DOOR + ARENA_PIER * 0.5)
		box(ctx, model, "Pier", ARENA_PIER, 11, 1.2, x, 5.5, -ARENA_R,
			POST, Enum.Material.Wood)
		box(ctx, model, "Lamp", 1.5, 0.6, 1.5, x, 11.3, -ARENA_R,
			GOLD, Enum.Material.Neon)
	end
	box(ctx, model, "Header", ARENA_DOOR * 2 + ARENA_PIER * 2 + 0.6, 3.6, 1,
		0, 9.3, -ARENA_R, SIGN)
	board(ctx, model, "ArenaSign", 8.6, 2.0, 0, 10.0, -ARENA_R - 0.5,
		"THE AFK YARD", 1.5, SIGN, GOLD)
	board(ctx, model, "ArenaBlurb", 8.6, 1.2, 0, 8.2, -ARENA_R - 0.5,
		"WALK IN AND KEEP EARNING", 0.7, SIGN, MINT)

	box(ctx, model, "Step", ARENA_DOOR * 2 + 1, 0.3, 4,
		0, 0.15, -ARENA_R - 2.5, CONCRETE)

	local trigger = piece(model, "Enter", Vector3.new(9, 12, 12), GOLD)
	trigger.Shape = Enum.PartType.Cylinder
	trigger.CFrame = at(ctx, 0, 4.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	trigger.Transparency = 1
	trigger.CanCollide = false
	trigger.CanQuery = false
	trigger.CastShadow = false

	-- So the model's pivot is the survey origin rather than the centre of its own
	-- bounding box, which the arch and the step pull off-centre.
	model.WorldPivot = origin
	model.Parent = parent
	return model
end

--==[ BUILD ]=================================================================

function AfkYardBuilder.build(origin: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = Afk.Container

	local ctx: Ctx = { root = origin, model = model }

	ground(ctx)
	road(ctx)
	entrance(ctx)

	local plots = folder(ctx, "Plots")
	local house = donorHouse()
	for i = 1, PLOTS do
		plot(ctx, plots, i, house)
	end

	bounds(ctx)
	treeline(ctx)

	model.Parent = parent
	return model
end

return AfkYardBuilder
