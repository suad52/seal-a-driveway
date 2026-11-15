--!strict
--[[
	CyberStandBuilder -- the Cyberseal parked in the dealership forecourt, and
	the lectern beside it that sells the pass.

	The truck is not on the showroom floor and never will be: it is not for sale
	for cash, so it has no bay, no plinth and no price plate in there. The reasons
	are written over Rigs.Pass and they are load bearing -- a fifth entry in
	Rigs.List reshapes all four cash trucks and hands this one to the Starter Rig
	pass for nothing.

	So it is parked OUTSIDE instead, in the last customer bay, which is the one
	place in the game a vehicle can stand where everybody walks past it: the
	forecourt is the only way in and out of the showroom on foot. It reads as a
	demonstrator somebody left on the lot rather than as stock, which is exactly
	what it is.

	--[ nose-in, and that is the whole point ]---------------------------------

	Parked facing SOUTH, into the bay, so the working end faces the walkway. The
	tank, the reel and the pump are what this truck is actually selling -- the
	bodywork is what gets somebody to look, and the drum standing two studs above
	its own roofline is what they see from the far side of the lot. Nose-out would
	have put the pretty end at the walkway and the whole plant behind a wall of
	stainless, and the nose would have overhung the walkway besides.

	--[ where the numbers come from ]------------------------------------------

	The bay is found by READING THE PAINT, not by writing -54 down here. The
	forecourt's bay pads are saved in the place and can be dragged in Studio like
	anything else, and a builder constant is a snapshot of where something used to
	be. `bayCFrame` walks the pads and takes the easternmost, so re-laying the lot
	moves the truck with it and this file needs no edit.

	The ground is raycast for the same reason. The forecourt is flat today; a
	baked Y is a truck floating over a re-laid one.

	The board's TEXT is not authored at all, for the reason DealershipSigns gives
	at length: the geometry is saved into the place and the numbers are not, so a
	retune can never leave a plate advertising a figure the game does not honour.
	Every label here is built empty and filled by CyberStandClient -- the stats
	from the catalogue, the price from Roblox, and the owned state from the one
	player it is true of.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rigs = require(script.Parent.Rigs)
local TruckBuilder = require(script.Parent.TruckBuilder)

local CyberStand = {}

-- The three names this is identified by, required by CyberStandClient rather
-- than copied there. A prompt nobody hooks draws its key and does nothing, which
-- is indistinguishable from a broken game and leaves nothing in the log.
CyberStand.ModelName = "CyberStand"
CyberStand.PromptName = "CyberStandPrompt"
-- Deliberately not "DealershipPrompt...": SealerUIClient hooks that substring to
-- open the cash buy screen, and TruckServer counts it to decide whether the
-- saved showroom is sound. This prompt opens Roblox's purchase dialog instead.
CyberStand.RigId = "Cyberseal"

local INK = Color3.fromRGB(22, 24, 30)
local SLATE = Color3.fromRGB(78, 84, 94)
local SIGNTX = Color3.fromRGB(240, 244, 250)
local SUBTX = Color3.fromRGB(176, 190, 206)

--[[
	How far the reel sits inside the bay's head line.

	The rig is about 25 studs from blade to reel and a customer bay is 24 deep, so
	it cannot be centred without overhanging one end. It is pushed south until the
	reel sits just inside the head: the overhang then lands on the far end, where
	it is a nose over a painted line on open tarmac rather than a hose reel in the
	walkway people are trying to use.

	The truck's own length is deliberately NOT written down. The exhibit is built
	first and then MEASURED, so retuning the bed rig or swapping the shell moves
	the truck to suit instead of quietly pushing its reel into the walkway.
]]
local REAR_GAP = 0.6
-- The lectern stands at the bay's north-east corner: clear of the truck's flank,
-- on the walkway, where somebody heading for the showroom door walks past it.
local TOTEM_DX = 5.5
local TOTEM_DZ = 1.8

--==[ FINDING THE BAY ]=======================================================

--[[
	The easternmost customer bay in the forecourt, read off the paint.

	BayHead is the stripe across the top of each bay, so its X is that bay's
	centreline and its Z is the line the vehicle must not cross -- both numbers
	this needs, from one part. Largest X wins, which is "the last one" as somebody
	walking the lot west to east would count them.

	Returns nil rather than guessing if the forecourt is not there. A truck
	dropped at the origin because a lookup failed is worse than no truck: it is a
	rig standing in the middle of the map with a purchase prompt on it.
]]
function CyberStand.bayHead(): Vector3?
	local hall = workspace:FindFirstChild("RigDealership")
	local fore = hall and hall:FindFirstChild("Forecourt")
	if not fore then return nil end

	local best: BasePart? = nil
	for _, p in ipairs(fore:GetChildren()) do
		if p:IsA("BasePart") and p.Name == "BayHead" then
			if not best or p.Position.X > best.Position.X then best = p end
		end
	end
	if not best then return nil end
	return best.Position
end

-- World axis-aligned extents of a model. Model:GetBoundingBox reports in the
-- model's own PIVOT space, which for a builder-made model is whatever its first
-- part happened to be -- so it cannot answer "how far north does this reach".
local function worldAABB(m: Model): (Vector3, Vector3)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") then
			local h = p.Size * 0.5
			for sx = -1, 1, 2 do for sy = -1, 1, 2 do for sz = -1, 1, 2 do
				local w = (p.CFrame * CFrame.new(h.X * sx, h.Y * sy, h.Z * sz)).Position
				lo = Vector3.new(math.min(lo.X, w.X), math.min(lo.Y, w.Y), math.min(lo.Z, w.Z))
				hi = Vector3.new(math.max(hi.X, w.X), math.max(hi.Y, w.Y), math.max(hi.Z, w.Z))
			end end end
		end
	end
	return lo, hi
end

-- Ground under a point, so the exhibit stands on the tarmac rather than at
-- whatever height the pad happens to be modelled at.
local function groundY(x: number, z: number, ignore: Instance?): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if ignore then { ignore } else {}
	local hit = workspace:Raycast(Vector3.new(x, 40, z), Vector3.new(0, -80, 0), params)
	return if hit then hit.Position.Y else 0
end

--==[ PRIMITIVES ]============================================================

local function piece(model: Model, name: string, size: Vector3, colour: Color3,
	material: Enum.Material, pos: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Position = pos
	p.Parent = model
	return p
end

local function label(gui: SurfaceGui, name: string, text: string, h: number,
	y: number, colour: Color3, font: Enum.Font): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(0.92, h)
	t.Position = UDim2.fromScale(0.04, y)
	t.Font = font
	t.Text = text
	t.TextColor3 = colour
	t.TextScaled = true
	t.Parent = gui
	return t
end

--==[ THE EXHIBIT ]===========================================================

--[[
	A real rig, turned into furniture.

	Built by TruckBuilder so the thing on the lot is the thing that turns up in
	the bay -- the showroom's four exhibits are made the same way for the same
	reason. What is stripped afterwards is what makes it an exhibit rather than a
	second driveable truck standing in a car park: the constraints, the seat and
	the drive folders all go, and every part is anchored.

	SealRigDisplay, not SealRigBody. Driveable rigs pass through each other, and
	an exhibit left in that group is one a customer could drive their own truck
	straight through. See ensureCollisionGroups in TruckBuilder.
]]
local SOLID = { Hull = true, Base = true }
local CASTS = { Tank = true, TankHead = true, ReelWrap = true }

local function exhibit(model: Model, at: CFrame): Model?
	local rig = Rigs.ById[CyberStand.RigId]
	if not rig then return nil end
	local shape = Rigs.body(rig)

	local m = TruckBuilder.build(at, model, {
		cab = rig.cab, tint = rig.tint,
		tankDia = shape.tankDia, tankLen = shape.tankLen,
		reelDia = shape.reelDia, reelWidth = shape.reelWidth,
		shell = rig.shell,
	})
	m.Name = "Exhibit"

	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = SOLID[d.Name] == true
			d.CollisionGroup = TruckBuilder.DisplayGroup
			d.CanQuery = false
			-- only the silhouette casts; the plant alone is forty parts and this is
			-- a place that already runs well over a thousand shadow casters
			d.CastShadow = CASTS[d.Name] == true
		elseif d:IsA("Constraint") or d:IsA("WeldConstraint") or d:IsA("Attachment")
			or d:IsA("JointInstance") or d:IsA("Light") or d:IsA("ProximityPrompt") then
			-- WeldConstraint is NOT a subclass of Constraint, so it needs saying
			-- separately or four hundred of them ride along into the place. The
			-- prompts go too: a parked exhibit must not offer Drive or Take Wand.
			d:Destroy()
		end
	end
	for _, name in ipairs({ "Drives", "Steers" }) do
		local folder = m:FindFirstChild(name)
		if folder then folder:Destroy() end
	end
	for _, d in ipairs(m:GetChildren()) do
		if d:IsA("Seat") or d:IsA("VehicleSeat") or d.Name == "Knuckle" then d:Destroy() end
	end
	-- An exhibit holds no sealer. Left set, anything walking Workspace for rigs
	-- reads a full 18,000-stud drum parked on the forecourt.
	for _, key in ipairs({ "Tank", "TankCapacity", "HosePaidOut" }) do
		m:SetAttribute(key, nil)
	end
	return m
end

--==[ THE LECTERN ]===========================================================

local function totem(model: Model, base: Vector3)
	local rig = Rigs.ById[CyberStand.RigId]
	if not rig then return end

	piece(model, "TotemBase", Vector3.new(2.20, 0.30, 1.40), INK,
		Enum.Material.SmoothPlastic, base + Vector3.new(0, 0.15, 0))
	piece(model, "TotemPost", Vector3.new(0.90, 3.20, 0.90), SLATE,
		Enum.Material.Metal, base + Vector3.new(0, 1.60, 0))

	--[[
		The head, and the host for the prompt.

		4.40 wide, matching the showroom's lecterns and for the reason written on
		them: a TextLabel with TextScaled on WRAPS before it shrinks, so a stat line
		one word too long does not get smaller, it grows a line and lands on the
		price.
	]]
	local head = piece(model, "PromptHost", Vector3.new(4.40, 4.80, 0.60), INK,
		Enum.Material.SmoothPlastic, base + Vector3.new(0, 5.80, 0))
	-- the pass's own colour as a cap, not a stripe down the side: beside the text
	-- it laps the face and eats the first and last letter of every line
	piece(model, "TotemPip", Vector3.new(4.60, 0.30, 0.70), rig.tint,
		Enum.Material.SmoothPlastic, base + Vector3.new(0, 8.35, 0))

	local gui = Instance.new("SurfaceGui")
	-- Front is +Z, and the head is unrotated, so the face looks north up the lot
	-- at whoever is walking in from the drive lane.
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 64
	gui.LightInfluence = 0
	gui.Parent = head

	--[[
		Every one of these is left BLANK and written at runtime by CyberStandClient.

		This is DealershipSigns' rule and it was learned here the expensive way: the
		first cut of this file baked the stat line in at build time, the model is
		saved into the place like the showroom is, and the day the truck's top speed
		changed from 42 to 55 the lectern went on advertising 42 with nothing
		anywhere to catch it. Geometry is authored; numbers are not.

		Blank rather than a plausible default, for the reason DealershipSigns gives:
		a blank is a visible failure if the writer ever goes missing, where a stale
		number is one nobody notices.
	]]
	label(gui, "Title", "", 0.20, 0.03, SIGNTX, Enum.Font.LuckiestGuy)
	label(gui, "Tagline", "", 0.10, 0.24, rig.tint, Enum.Font.Gotham)
	label(gui, "Stats", "", 0.26, 0.37, SUBTX, Enum.Font.GothamBold)
	label(gui, "Price", "", 0.17, 0.65, SIGNTX, Enum.Font.LuckiestGuy)
	label(gui, "Note", "", 0.10, 0.85, SUBTX, Enum.Font.Gotham)

	local p = Instance.new("ProximityPrompt")
	p.Name = CyberStand.PromptName
	p.ActionText = "Get Cyberseal"
	p.ObjectText = rig.name
	p.MaxActivationDistance = 14
	p.RequiresLineOfSight = false
	p.Parent = head
end

--==[ ASSEMBLY ]==============================================================

--[[
	Returns nil if the forecourt is not there to park in, and says so. The caller
	treats that as "no stand today" rather than dropping a truck at the origin.
]]
function CyberStand.build(parent: Instance): Model?
	local head = CyberStand.bayHead()
	if not head then
		warn("[CyberStandBuilder] no RigDealership.Forecourt in Workspace --"
			.. " nowhere to park the Cyberseal, so it has not been built")
		return nil
	end

	local model = Instance.new("Model")
	model.Name = CyberStand.ModelName

	local x, headZ = head.X, head.Z
	local y = groundY(x, headZ - 10, workspace:FindFirstChild(CyberStand.ModelName))

	--[[
		Built roughly, measured, then slid back so the reel lands just inside the
		head line. Two steps rather than one arithmetic expression because the only
		honest source for "how far back does this truck reach" is the truck.

		yaw 0 leaves the nose pointing -Z, which is south, into the bay.
	]]
	local ex = exhibit(model, CFrame.new(x, y, headZ))
	if ex then
		local _, hi = worldAABB(ex)
		ex:PivotTo(ex:GetPivot() * CFrame.new(0, 0, 0)
			+ Vector3.new(0, 0, (headZ - REAR_GAP) - hi.Z))
	end

	totem(model, Vector3.new(x + TOTEM_DX, y, headZ + TOTEM_DZ))

	model.Parent = parent
	return model
end

return CyberStand
