--!strict
--[[
	Builds the two tools from primitives at server start, so they live in source
	rather than in a .rbxm nobody can diff.

	Named parts the client looks for:
	  Bucket   -> "Nozzle" (pour origin), "Level" (the sealer surface inside)
	  Squeegee -> "Blade" (its width and facing drive the simulation)
	  Wand     -> "Tip" (spray origin), "HoseEnd" (where the hose lands)
]]

local Config = require(script.Parent.Config)

local ToolBuilder = {}

local RUBBER = Color3.fromRGB(26, 26, 28)
local STEEL = Color3.fromRGB(122, 126, 132)
local SEALER = Color3.fromRGB(14, 14, 15)

local function part(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.CanCollide = false
	p.CanQuery = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function attach(handle: BasePart, p: BasePart, offset: CFrame)
	p.CFrame = handle.CFrame * offset
	local w = Instance.new("WeldConstraint")
	w.Part0 = handle
	w.Part1 = p
	w.Parent = p
	p.Parent = handle.Parent
end

--==[ BUCKET ]================================================================

function ToolBuilder.buildBucket(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Sealer Bucket"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	-- Not "hold": the pail is metered, and one press tips one puddle out of it.
	-- See Config.PourDump. The wand below is still a hose and still says hold.
	-- Both halves, because they are different pours: a tap is one metered puddle
	-- and a hold is a stream. See Config.PourDump / Config.PourHold.
	tool.ToolTip = "Click to tip a puddle, or hold to keep pouring"
	tool:SetAttribute("SealerTool", "Bucket")

	-- Part.Shape = Cylinder runs along the part's X axis, so Size.X is the
	-- height and the pail is stood upright by rotating X onto world Y.
	local handle = part("Handle", Vector3.new(2.0, 1.7, 1.7), Color3.fromRGB(38, 40, 44), Enum.Material.SmoothPlastic)
	handle.Shape = Enum.PartType.Cylinder
	handle.Parent = tool
	handle.CFrame = CFrame.Angles(0, 0, math.rad(90))

	local rim = part("Rim", Vector3.new(0.10, 1.82, 1.82), STEEL, Enum.Material.Metal)
	rim.Shape = Enum.PartType.Cylinder
	attach(handle, rim, CFrame.new(0.98, 0, 0))

	-- Sealer surface. The client slides this down as the bucket empties.
	local level = part("Level", Vector3.new(0.06, 1.55, 1.55), SEALER, Enum.Material.SmoothPlastic)
	level.Shape = Enum.PartType.Cylinder
	level.Reflectance = 0.10
	attach(handle, level, CFrame.new(0.80, 0, 0))

	local bail = part("Bail", Vector3.new(0.09, 0.09, 2.0), STEEL, Enum.Material.Metal)
	attach(handle, bail, CFrame.new(1.15, 0, 0))

	-- Pour origin, sitting on the lip.
	local nozzle = part("Nozzle", Vector3.new(0.2, 0.2, 0.2), STEEL, Enum.Material.Metal)
	nozzle.Transparency = 1
	attach(handle, nozzle, CFrame.new(1.02, 0, -0.85))

	--[[
		Stand the pail up in the hand.

		Tool.Grip is the HAND's frame expressed in the handle's own space, which is
		what makes both halves of this readable:

		  rotation  the cylinder runs along local X and that axis is the pail's
		            HEIGHT, so rolling X onto the hand's up axis is what stands it
		            upright. At -18 degrees it was 74 degrees off vertical -- the
		            pail lay on its side across the character's chest with the open
		            top pointing out sideways and the rim through the head.
		  position  a point on the bail: the wire sits at local X 1.15 and runs the
		            width of the pail along local Z, so the hand grips it and the
		            pail hangs underneath. The 0.45 slides the grip along that wire,
		            which swings the pail forward clear of the thigh.

		The Nozzle rides the lip on local -Z, which this puts at the character's
		front, so the stream still leaves the pail on the side it faces.
	]]
	tool.Grip = CFrame.new(1.15, 0, 0.45) * CFrame.Angles(0, 0, math.rad(-90))
	return tool
end

--==[ SQUEEGEE ]==============================================================

--[[
	The squeegee is not welded to the hand.

	A hand-welded pole inherits every idle and walk animation, so the rubber ends
	up hovering somewhere near the player's hip while the simulation insists it
	is flat on the slab. Since the blade line is the single thing the player is
	reading, the visual is driven from the simulated pose instead: the parts are
	anchored in a "Rig" model that the client re-frames each tick.

	Rig space: origin sits on the rubber's contact line, -Z is the push
	direction, so the pole leans back toward +Z.

	The handle is only baked to a resting shape here. SqueegeePose re-aims and
	re-lengths it every frame so that it ends at the player's upper hand, and
	puts both hands on it -- see that module for why it has to end there.
]]
--[[
	Re-size the visible rubber on a squeegee rig.

	One definition of how wide a squeegee is DRAWN, because there are now two
	callers and they must not drift: SealerUIClient sizes your own from the track
	you have bought, and RemoteToolsClient sizes everybody else's from theirs.
	Before that second caller existed, other people's blades were whatever the
	server built the StarterPack copy at -- 6.4 studs, forever, at every level.

	Blade and Head only. The collar, the pole and the hands are placed off the
	blade by SqueegeePose, so they follow for free; widening them here would put
	a ten-stud steel tube across somebody's chest.

	Guarded on an actual change because the remote caller runs this every frame
	for every player in sight, and a Size write on an anchored part is not free.
]]
--[[
	And anything a SKIN laid along the blade, which is the second half of "one
	definition of how wide a squeegee is drawn".

	A glowing inlay down the head has to be the length of the head, and the head's
	length is this function's answer -- so an inlay that baked in the default 6.4
	would stay 6.4 on a ten-stud blade the moment the player bought a level of
	Squeegee Length. SqueegeeSkins marks those parts and says how much SHORTER
	than the blade each one sits, because an inlay wants to stop short of the ends
	rather than run off them.

	The attribute names are written out rather than required from SqueegeeSkins:
	that module requires THIS one for the gold, and a cycle between them would not
	load. They are declared there, next to the skins that set them.
]]
local SKIN_WIDTH = "SkinFollowsWidth"
local SKIN_INSET = "SkinWidthInset"
-- and where the piece was MEANT to sit, in rig space; see `seatSkin`
local SKIN_LOCAL = "SkinLocal"

--[[
	Where the Blade sits in RIG SPACE, and the anchor of that whole coordinate
	system.

	Rig space is not a thing the engine knows about -- it exists only as an offset
	from a part that is really there, and the Blade is the part every reader
	already has in hand. Written once here so that a conversion between the two
	frames cannot drift from the build.
]]
ToolBuilder.SqueegeeBladeLocal = CFrame.new(0, 0.17, 0)

--[[
	The rig's own frame, in the world, wherever it was last put.

	⚠ NOT `rig:GetPivot()`. The pivot IS the PrimaryPart's CFrame while there is
	one -- the Blade, which would be the right answer -- but BOTH viewport stands
	(SkinCase, and the shell's skins key) clear PrimaryPart and re-point WorldPivot
	at the bounding-box centre, so that a squeegee turns on the spot instead of
	swinging round like a boom. GetPivot then answers the middle of the model and
	every conversion through it is out by half a rig. Asking the Blade directly is
	the same answer on a held tool and the correct one on a turntable.
]]
function ToolBuilder.rigFrame(rig: Instance?): CFrame?
	local blade = if rig then rig:FindFirstChild("Blade") else nil
	if not blade or not blade:IsA("BasePart") then return nil end
	return (blade :: BasePart).CFrame * ToolBuilder.SqueegeeBladeLocal:Inverse()
end

--[[
	Put every part a SKIN added back where the skin asked for it.

	⚠ THIS IS WHAT STOPS A SKIN'S DECORATION BEING LEFT 180 STUDS BEHIND, and it
	has to exist because a rig's world placement is CLIENT-ONLY state. The client
	holding a squeegee re-frames the whole model every tick with PivotTo; the
	server never places one at all. So a part added on the SERVER -- which is where
	skins are applied, and has to be, or nobody else ever sees one -- lands in
	whatever frame the server's copy of the rig happens to be in, and PivotTo is
	RIGID: it carries that error along forever rather than correcting it.

	The symptom is a skin that keeps all of its paint and silently loses every
	inlay, stripe and badge -- "the real one looks uglier than the case" -- with
	the missing pieces stood in a heap somewhere out in the map.

	Guarded on actually being wrong, so an ordinary frame is a compare and no write
	at all: once a piece is seated, the rig's own PivotTo keeps it seated.
]]
function ToolBuilder.seatSkin(rig: Instance?)
	if not rig then return end
	local frame = ToolBuilder.rigFrame(rig)
	if not frame then return end
	for _, part in ipairs(rig:GetChildren()) do
		if part:IsA("BasePart") then
			local want = part:GetAttribute(SKIN_LOCAL) :: CFrame?
			if want then
				local at = (frame :: CFrame) * (want :: CFrame)
				if (at.Position - part.Position).Magnitude > 1e-3 then
					part.CFrame = at
				end
			end
		end
	end
end

function ToolBuilder.setBladeWidth(rig: Instance?, width: number?)
	if not rig or type(width) ~= "number" or width <= 0 then return end
	for _, part in ipairs(rig:GetChildren()) do
		if part:IsA("BasePart") then
			local want: number? = nil
			if part.Name == "Blade" or part.Name == "Head" then
				want = width
			elseif part:GetAttribute(SKIN_WIDTH) then
				-- clamped rather than trusted: an inset longer than the blade would
				-- otherwise ask for a negative size, which Roblox silently turns into
				-- its 0.05 minimum and leaves as a sliver nobody can explain
				want = math.max(0.05, width - ((part:GetAttribute(SKIN_INSET) :: number?) or 0))
			end
			if want and math.abs(part.Size.X - want) > 1e-3 then
				part.Size = Vector3.new(want, part.Size.Y, part.Size.Z)
			end
		end
	end

	--[[
		And seated while we are here, which is how EVERY OTHER PLAYER's squeegee gets
		its skin pieces put right: RemoteToolsClient runs this every frame for every
		rig in sight and is the only per-frame client code that touches one. The local
		player's own rig comes through SqueegeePose.Update instead -- this call is far
		too rare for it, since SealerUIClient only re-sizes on an upgrade.
	]]
	ToolBuilder.seatSkin(rig)
end

function ToolBuilder.buildSqueegee(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Squeegee"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Hold and walk forward to spread"
	tool:SetAttribute("SealerTool", "Squeegee")

	-- Just an anchor point for the equip machinery; never seen.
	local handle = part("Handle", Vector3.new(0.2, 0.2, 0.2), STEEL, Enum.Material.Metal)
	handle.Transparency = 1
	handle.Parent = tool
	tool.Grip = CFrame.new(0, 0, 0)

	local rig = Instance.new("Model")
	rig.Name = "Rig"

	local function rigPart(name: string, size: Vector3, color: Color3, material: Enum.Material, cf: CFrame): Part
		local p = part(name, size, color, material)
		p.Anchored = true
		p.CFrame = cf
		p.Parent = rig
		return p
	end

	local blade = rigPart("Blade", Vector3.new(Config.BladeHalfLen * 2, 0.34, 0.13), RUBBER,
		Enum.Material.SmoothPlastic, ToolBuilder.SqueegeeBladeLocal)
	rigPart("Head", Vector3.new(Config.BladeHalfLen * 2, 0.30, 0.44), STEEL,
		Enum.Material.Metal, CFrame.new(0, 0.48, 0.02))
	rigPart("Collar", Vector3.new(0.34, 0.34, 0.34), STEEL,
		Enum.Material.Metal, CFrame.new(0, 0.66, 0.14))

	--[[
		This used to be 4.6 studs at 46 degrees off vertical, and that was the bug
		behind the pole going through the player: at a 2.9-stud blade offset the
		spare length carried the top of the handle straight past the hands and into
		the chest, crossing the torso's centre plane at HRP-local (0, 0.44, 0).

		Short and shallow now, matching roughly where SqueegeePose will put it, so
		the one frame between equipping and the first pose looks right -- and so a
		rig the poser bails on (R6, which has no arm chain to solve) still gets a
		handle that clears the body.
	]]
	rigPart("Pole", Vector3.new(0.22, 2.92, 0.22), Color3.fromRGB(196, 130, 62), Enum.Material.Wood,
		CFrame.new(0, 0.62, 0.10) * CFrame.Angles(math.rad(35), 0, 0) * CFrame.new(0, 1.46, 0))

	rig.PrimaryPart = blade
	rig.Parent = tool
	return tool
end

--==[ SET-DOWN PAIL -- REMOVED ]============================================
--[[
	buildStandingPail and setPailTone lived here and are gone (2026-08-11).

	The pail could be stood on a finished driveway and the leftover sealer swept
	into it with the squeegee; this file built the prop, its catchment disc, the
	gold ring that drew the radius, the inward particle pull and the red "full"
	recolour. The mechanic was removed outright -- a finished slab now settles to
	cured coat on the frame it completes, so there is never anything lying on one
	to sweep -- and MARKER / MARKER_FULL / MARKER_EDGE / DROPLET went with it,
	because the pail was the only thing that ever used them.
]]

--==[ SPRAY WAND ]============================================================

--[[
	Posed from code, for the same reason the squeegee is: a welded prop inherits
	every walk and idle animation, and a wand that is supposed to be pointing
	where the player is aiming cannot afford to wander off with the arm. The
	client re-frames this rig at the aim line each tick.

	Rig space: origin at the grip, -Z down the lance, so `CFrame.lookAt(hand,
	aim)` is the entire posing calculation.
]]
function ToolBuilder.buildWand(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Spray Wand"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Hold to pour, then spread it with the squeegee"
	tool:SetAttribute("SealerTool", "Wand")

	local handle = part("Handle", Vector3.new(0.2, 0.2, 0.2), STEEL, Enum.Material.Metal)
	handle.Transparency = 1
	handle.Parent = tool
	tool.Grip = CFrame.new(0, 0, 0)

	local rig = Instance.new("Model")
	rig.Name = "Rig"

	local function rigPart(name: string, size: Vector3, color: Color3, material: Enum.Material, cf: CFrame): Part
		local p = part(name, size, color, material)
		p.Anchored = true
		p.CFrame = cf
		p.Parent = rig
		return p
	end

	-- cylinders run along their own X, so the lance is rolled onto -Z
	local function rigTube(name: string, len: number, dia: number, color: Color3, cf: CFrame): Part
		local p = rigPart(name, Vector3.new(len, dia, dia), color, Enum.Material.Metal,
			cf * CFrame.Angles(0, math.rad(90), 0))
		p.Shape = Enum.PartType.Cylinder
		return p
	end

	rigPart("Grip", Vector3.new(0.34, 1.05, 0.42), RUBBER, Enum.Material.SmoothPlastic,
		CFrame.new(0, -0.5, 0.14) * CFrame.Angles(math.rad(-12), 0, 0))
	rigPart("Body", Vector3.new(0.44, 0.5, 1.5), STEEL, Enum.Material.Metal,
		CFrame.new(0, 0.04, -0.15))
	rigPart("Trigger", Vector3.new(0.12, 0.36, 0.16), Color3.fromRGB(188, 42, 38),
		Enum.Material.SmoothPlastic, CFrame.new(0, -0.22, -0.42))
	rigPart("TriggerGuard", Vector3.new(0.1, 0.5, 0.12), STEEL, Enum.Material.Metal,
		CFrame.new(0, -0.36, -0.62))

	rigTube("Lance", 3.0, 0.22, STEEL, CFrame.new(0, 0.04, -2.4))
	rigTube("LanceCollar", 0.3, 0.32, Color3.fromRGB(96, 100, 106), CFrame.new(0, 0.04, -0.95))
	rigTube("NozzleBody", 0.55, 0.36, Color3.fromRGB(96, 100, 106), CFrame.new(0, 0.04, -4.05))
	-- the flat tip the stream leaves through
	rigPart("FanTip", Vector3.new(0.52, 0.16, 0.26), Color3.fromRGB(150, 154, 160),
		Enum.Material.Metal, CFrame.new(0, 0.04, -4.4))

	-- Spray origin. Invisible: the beam starts here, so anything drawn would
	-- only ever sit inside the first few studs of it.
	local tip = rigPart("Tip", Vector3.new(0.16, 0.16, 0.16), STEEL, Enum.Material.Metal,
		CFrame.new(0, 0.04, -4.58))
	tip.Transparency = 1

	-- Where the hose meets the wand, behind and below the grip so the drawn
	-- hose falls away from the player's hand rather than through it.
	local hoseEnd = rigPart("HoseEnd", Vector3.new(0.16, 0.16, 0.16), STEEL, Enum.Material.Metal,
		CFrame.new(0, -0.92, 0.42))
	hoseEnd.Transparency = 1
	rigTube("Swivel", 0.5, 0.3, Color3.fromRGB(96, 100, 106),
		CFrame.new(0, -0.86, 0.3) * CFrame.Angles(math.rad(58), 0, 0))

	-- The pivot sits at the grip, not the tip, so posing the wand is exactly
	-- `CFrame.lookAt(hand, aim)` with nothing to correct for afterwards.
	local mount = rigPart("Mount", Vector3.new(0.16, 0.16, 0.16), STEEL, Enum.Material.Metal,
		CFrame.new())
	mount.Transparency = 1

	rig.PrimaryPart = mount
	rig.Parent = tool
	return tool
end

--==[ THE GOLD KIT ]=========================================================

--[[
	What VIP looks like in the hand.

	It lives in THIS file rather than in VipService because this is the file that
	knows what a tool is made of. Every name in the list below is a part built
	above, and a copy of that list kept anywhere else goes stale the first time one
	of them is renamed -- silently, because a name matching nothing is
	indistinguishable from a part that was already the right colour.

	One definition, two callers: VipService dresses the tools in a VIP's backpack,
	and VipStandBuilder dresses the giant squeegee on the plinth by the spawn. The
	display is therefore the product rather than an artist's impression of it.

	FITTINGS, NOT A GOLD BRICK. That was already the rule for the pail -- gilding
	every part of one made a yellow cylinder with no shape left in it -- and it is
	why the rubber, the pail body and the wand's grip stay dark. Gold reads as gold
	because of the black next to it.

	TWO TONES, which is the part that was missing. One flat yellow across head,
	collar and pole loses every edge between them past about ten studs: the whole
	silhouette goes to a single blob. Bright on the big faces, deep on the collars
	and the trim, and the shapes come back.

	Reflectance is the other half. Metal alone at this colour still reads as
	painted yellow plastic; it is the sky in the highlight that says metal. 0.28 is
	as far as it goes before the pieces flare to featureless white under Golden
	Hour, which runs Brightness 1.85 against a bloom threshold of 1.75.
]]

-- The game's one gold, the same value the VIP nameplate and the Lucky boards
-- are drawn in. Anything gilded anywhere should be reading these two.
ToolBuilder.Gold = Color3.fromRGB(255, 206, 56)
-- Pushed darker than a first pass had it. The squeegee's handle is WOOD at
-- (196, 130, 62), and a deep gold within a few points of that is a handle a VIP
-- would swear had not changed at all -- the perk they paid for, invisible.
ToolBuilder.GoldDeep = Color3.fromRGB(172, 114, 18)

--[[
	Named parts only, and named by tool: Rim and Bail are the pail's, Head, Collar
	and Pole the squeegee's, and the rest belong to the wand -- which used to get
	nothing at all, so a VIP holding the hose carried the same grey lance as
	everybody else while their pail and squeegee were gold.
]]
local GILT: { [string]: string } = {
	Rim = "bright", Bail = "bright",
	-- Pole bright, collar deep: the handle is the longest thing on the tool and
	-- the one piece read from across a street, so it is the piece that has to say
	-- gold. The collar between it and the head is what keeps the two apart.
	Head = "bright", Collar = "deep", Pole = "bright",
	Body = "bright", Lance = "bright", FanTip = "bright",
	LanceCollar = "deep", NozzleBody = "deep", TriggerGuard = "deep", Swivel = "deep",
}

-- The biggest flat gold face each of the three tools has. One glint per tool,
-- never one per gilded part -- see the rate note below.
local GLINT: { [string]: boolean } = { Head = true, Rim = true, Body = true }

--[[
	The shimmer, and why it is this small.

	Rate 5 against a lifetime under a second is about three particles alive per
	tool, and it has to stay near nothing: this is drawn on something held in front
	of the camera for the whole session, and drawn again for every other VIP in
	sight -- their tools are these same replicated instances, see RemoteToolsClient.

	LockedToPart is not decoration. The squeegee's rig is ANCHORED and teleported
	to the player every frame, and on equip it teleports in from the world origin;
	a free emitter draws that jump as a comet of sparks across the map. Locked, the
	particles ride the part and the jump cannot be seen at all.
]]
local function glint(host: BasePart)
	if host:FindFirstChild("VipGlint") then return end
	local e = Instance.new("ParticleEmitter")
	e.Name = "VipGlint"
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(255, 238, 176))
	e.LightEmission = 0.9
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.45, 0.34),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.35, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.4, 0.8)
	e.Rate = 5
	e.Speed = NumberRange.new(0.1, 0.5)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.LockedToPart = true
	e.Parent = host
end

--[[
	Gild one tool, or one bare Rig model.

	⚠ NEVER PASS A CHARACTER. The squeegee's steel top plate is called Head and so
	is the thing on the player's shoulders, and this matches by name through the
	whole subtree -- so a character walked through here comes out with a gold ball
	for a face. VipService hands the tools over one at a time for that reason.

	Transparency 1 is skipped because it is the invisible plumbing -- Handle,
	Nozzle, Tip, Mount. Colouring those buys nothing and a glint on one would hang
	sparks in mid-air off a part nobody can see.
]]
function ToolBuilder.gild(tool: Instance)
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("BasePart") then
			local tone = GILT[d.Name]
			if tone and d.Transparency < 1 then
				local deep = tone == "deep"
				d.Color = if deep then ToolBuilder.GoldDeep else ToolBuilder.Gold
				d.Material = Enum.Material.Metal
				d.Reflectance = if deep then 0.14 else 0.28
				if GLINT[d.Name] then glint(d) end
			end
		end
	end
end

--==[ REFILL STATION ]========================================================

function ToolBuilder.buildRefillStation(position: Vector3, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "SealerSupply"

	local drum = Instance.new("Part")
	drum.Name = "Drum"
	drum.Anchored = true
	drum.Size = Vector3.new(4.6, 3.4, 3.4)
	drum.Shape = Enum.PartType.Cylinder
	drum.Color = Color3.fromRGB(28, 30, 34)
	drum.Material = Enum.Material.Metal
	drum.CFrame = CFrame.new(position + Vector3.new(0, 2.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	drum.Parent = model

	local band = Instance.new("Part")
	band.Name = "Band"
	band.Anchored = true
	band.Size = Vector3.new(0.35, 3.6, 3.6)
	band.Shape = Enum.PartType.Cylinder
	band.Color = Color3.fromRGB(214, 176, 44)
	band.Material = Enum.Material.SmoothPlastic
	band.CFrame = drum.CFrame
	band.Parent = model

	local sign = Instance.new("BillboardGui")
	sign.Name = "Prompt"
	sign.Size = UDim2.fromScale(9, 2.4)
	sign.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	sign.AlwaysOnTop = true
	sign.Adornee = drum
	sign.Parent = drum

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 232, 150)
	label.TextStrokeTransparency = 0.35
	label.Text = "SEALER SUPPLY"
	label.Parent = sign

	model.PrimaryPart = drum
	model.Parent = parent
	return model
end

return ToolBuilder
