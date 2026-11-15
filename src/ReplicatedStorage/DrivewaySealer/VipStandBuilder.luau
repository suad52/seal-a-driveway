--!strict
--[[
	VipStandBuilder -- the golden squeegee on a plinth, eighteen studs off the
	spawn pad, and the only place in the world where VIP can be bought by walking
	up to it.

	--[ why it exists ]--------------------------------------------------------

	VIP was sold from exactly one place: a card in the Shop panel, behind a rail
	button, two rows down a scroller. And every single thing the pass gives is
	invisible until you already own it -- the gold kit is in a VIP's hands, the
	nameplate is over a VIP's head, the premium boards are on a VIP's lawn. A
	player who never opened that panel therefore never saw a reason to want it.

	A thing standing in the world, on the walk from the spawn pad to the
	leaderboards, is a reason.

	--[ what is on the plinth is the product ]---------------------------------

	The hero is a real squeegee out of ToolBuilder.buildSqueegee, gilded by the
	same ToolBuilder.gild call that dresses a VIP's backpack, and then scaled up.
	It is not a model of one and there is no second copy of the gold anywhere.
	Change the tool or change the gold and the display changes with it, which is
	the only arrangement in which a shop window stays honest.

	--[ the site ]-------------------------------------------------------------

	Inside the depot garage, at the west end of the shop floor by the refuel bay,
	turned east to face the roll door. Moved here by hand on 2026-08-12 -- it was
	first built out on the lawn beside the spawn pad -- and scaled down to 0.685 to
	sit under the roof.

	ORIGIN, FACING AND SCALE BELOW ARE A RECORD OF WHERE THE SAVED MODEL STANDS,
	not an instruction to it. Nothing at runtime reads them: VipService only calls
	this file when Workspace has no VipStand at all, so they decide one thing only,
	which is where a LOST stand comes back. Move the model again and they go stale
	silently -- re-read them off the placed model (see the snippet below) rather
	than trusting them.

	The one rule the site has to keep, wherever it ends up:

	  IT MUST NOT STAND ON A TAGGED SLAB. Anything anchored, queryable and opaque
	  between +0.06 and +2.50 above a SealableDriveway is subtracted from that
	  slab's coverage mask, and coverage is checked against Config.CompleteAt -- so
	  a plinth on one is a driveway nobody can ever finish. The depot apron is
	  tagged and starts twenty studs east of here; the garage Floor it actually
	  stands on is tagged nothing. Only Base, Ring, Deck and the sign posts are
	  queryable at all, which is the second half of the same guard.

	To rebuild the saved one after editing this file, from the command bar:

		local M = require(game.ReplicatedStorage.DrivewaySealer.VipStandBuilder)
		local old = workspace:FindFirstChild(M.ModelName)
		if old then old:Destroy() end
		M.build(M.originCFrame(), workspace)

	And to read the constants back off a stand that has been moved by hand, so this
	file can be brought into line with it:

		local m = workspace.VipStand
		local f = m.PrimaryPart.CFrame * CFrame.Angles(0, 0, math.rad(-90))
		local s = m:GetScale()
		print("Origin", f.Position - Vector3.new(0, 0.525 * s, 0))
		print("Facing", f.Position + f.LookVector * 20, "Scale", s)

	Unlike its siblings this one IS built rotated and scaled, and safely. Every
	number below is a local offset from the plinth's own centre rather than a world
	survey coordinate, and nothing here measures a zone in the model's object space
	the way the dealership's forecourt does. `Facing` is a POINT to turn towards
	rather than an angle, so the stand looks at something real instead of at an
	angle somebody has to keep in their head.

	And NOTHING published by this file is a world position. That was the bug behind
	"I moved the model but the squeegee did not move": the display's pose used to
	be stamped on the model as an absolute CFrame attribute for VipStandClient to
	turn about, so dragging the stand in Studio left the client spinning the
	squeegee back at the old address on the lawn. The attribute is gone -- the
	client reads the pose off the exhibit itself now, see the note there -- and
	moving, turning or rescaling this model needs no code change anywhere.

	Local space: the front is -Z, +X is the front's right, y 0 is the floor.
]]

local ToolBuilder = require(script.Parent.ToolBuilder)
local Passes = require(game:GetService("ReplicatedStorage")
	:WaitForChild("SealerUI"):WaitForChild("Passes"))

local VipStandBuilder = {}

VipStandBuilder.ModelName = "VipStand"

-- The site, and the thing it looks at. Both at the same height: CFrame.lookAt
-- between two points at different heights would tilt the whole stand to stare at
-- the ground. y 0.05 is the top of the garage floor.
VipStandBuilder.Origin = Vector3.new(-19.2, 0.05, 203.4)
VipStandBuilder.Facing = Vector3.new(0, 0.05, 203.4)

--[[
	Built full size and then taken down to this, because the garage has a roof on
	it and the lawn did not.

	One ScaleTo at the end rather than a scale factor threaded through two hundred
	numbers, and it reaches further than part sizes: measured on the placed model it
	also took the prompt's MaxActivationDistance from 14 to 9.6 and the sign's
	PixelsPerStud from 50 to 73 -- which is exactly right, the second one being what
	keeps the board's text canvas 680 pixels wide however big the board is.
]]
VipStandBuilder.Scale = 0.685

function VipStandBuilder.originCFrame(): CFrame
	return CFrame.lookAt(VipStandBuilder.Origin, VipStandBuilder.Facing)
end

-- The prompt's name, read by VipStandClient. Kept here so the two files cannot
-- drift: a prompt nobody hooks is one that draws its key and then does nothing,
-- which is indistinguishable from a broken game and leaves nothing in the log.
VipStandBuilder.PromptName = "VipStandPrompt"

--==[ PALETTE ]===============================================================

local GOLD     = ToolBuilder.Gold
local GOLD_DP  = ToolBuilder.GoldDeep
local INK      = Color3.fromRGB(26, 29, 36)
local PANEL    = Color3.fromRGB(30, 38, 56)
local CARPET   = Color3.fromRGB(124, 22, 30)
local VELVET   = Color3.fromRGB(150, 26, 34)
local CREAM    = Color3.fromRGB(246, 238, 214)
-- No mint here on purpose: the board's one green state ("you are a member") is a
-- fact about one player, so its colour lives with the code that writes it, in
-- VipStandClient. A copy of it in this file would be a constant that never runs.

--==[ THE SURVEY ]============================================================
--[[
	The plinth is a stack of upright discs and every height below is the TOP of
	one, not its centre, because that is the number that has to line up with the
	next piece. The neon collar is deliberately 0.10 shy of the deck: it is meant
	to be a ring of light seen from the side, and flush with the deck it would
	simply be a glowing floor with the carpet sitting on top of it.
]]
local BASE_TOP   = 1.05
local RING_TOP   = 1.42
local HALO_TOP   = 1.85
local DECK_TOP   = 1.95

local ROPE_R     = 7.8    -- stanchion ring radius
-- How far behind the plinth centre the board stands. Pulled in from 8.4 by hand
-- on the placed model and matched here: at 8.4 the board read as a separate thing
-- standing behind the plinth rather than as the stand's own sign. It still clears
-- everything -- the posts sit 8.5 studs out from the centre against a 6.7-stud
-- plinth and a 7.8-stud rope ring.
local SIGN_Z     = 4.42
local SIGN_W     = 13.6
local SIGN_H     = 8.0
--[[
	The board is hung ABOVE the hero rather than behind it, and that is what fixes
	its height rather than any taste about signs.

	The two overlap from the spawn pad whatever the depth between them, and what
	gets covered first is the bottom of the panel -- which is the footer, the one
	line that says how to buy the thing. So the board's bottom edge clears the top
	of the turning squeegee, and everything else follows from that.
]]
local SIGN_Y     = 13.4   -- centre of the board
local POST_TOP   = 18.2

--[[
	The hero, floating rather than stood on the deck.

	A squeegee resting on its blade leans back 35 degrees -- that is how one stands
	against a wall and it is what ToolBuilder bakes -- and 35 degrees on a
	turntable reads as a tool somebody dropped. The lift is also what lets it turn
	at all: a blade sweeping the carpet would clip through the deck twice a
	rotation.

	THE TILT IS OVER-ROTATED ON PURPOSE, past upright to 38, and it is the single
	change that made this read as a squeegee. The head is a flat plate whose big
	face points at the SKY, so anything near vertical shows a player standing on
	the lawn nothing but its edge -- a gold bar hanging in the air, which is what
	the first three passes at this looked like. Rolling it forward past vertical
	stands the handle up and turns the plate to face the path instead.

	SCALE IS SET BY THE BLADE, NOT BY THE HANDLE, and that is why it stops here. A
	squeegee is a wide, low thing -- 6.4 studs of rubber against 3.1 of handle --
	so scaling it until the HANDLE looks heroic swings a plank across the middle of
	the sign: at 2.6 the rubber came out 16.6 studs, wider than the 14.6-stud board
	behind it and wider than the plinth under it. 1.9 puts it at 12.2, which
	overhangs the 10.4-stud deck by about a stud on each side -- deliberate, it
	reads as an exhibit floating over the plinth rather than a lid sitting on it --
	and stays inside the board.

	The two numbers that must not drift: at this scale the handle ends 6.33 studs
	above the blade, so HERO_Y + 6.33 plus VipStandClient's bob has to stay under
	the bottom of the footer strip. As set that is 9.39 against 9.56. Raise the
	hero or grow it and the handle goes through the price.
]]
local HERO_SCALE = 1.9
local HERO_Y     = 2.9
local HERO_TILT  = -38   -- degrees, negative rolls the tool forward

--==[ PRIMITIVES ]============================================================

type Ctx = { model: Model, origin: CFrame }

local function at(ctx: Ctx, x: number, y: number, z: number): CFrame
	return ctx.origin * CFrame.new(x, y, z)
end

--[[
	One part.

	CanQuery off by default and turned back on only for the two pieces a player
	can stand on. It is not tidiness: the pour aim ray and the coverage mask's
	blocker sweep both use queryable parts, and the depot apron is a tagged slab
	twenty studs west of here -- see the site note at the top.
]]
local function piece(ctx: Ctx, name: string, size: Vector3, colour: Color3,
	material: Enum.Material, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = cf
	p.Parent = ctx.model
	return p
end

-- An upright disc or post. Part.Shape.Cylinder runs along the part's OWN X, so
-- X is the height and the part is rolled a quarter turn to stand it on end --
-- the same trick the pail in ToolBuilder is built with. Rolling about the
-- origin's local Z is safe because the origin carries yaw only, which leaves
-- local Y pointing at the sky.
local function pillar(ctx: Ctx, name: string, dia: number, height: number,
	x: number, yTop: number, z: number, colour: Color3, material: Enum.Material): Part
	local p = piece(ctx, name, Vector3.new(height, dia, dia), colour, material,
		at(ctx, x, yTop - height * 0.5, z) * CFrame.Angles(0, 0, math.rad(90)))
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function ball(ctx: Ctx, name: string, dia: number, x: number, y: number,
	z: number, colour: Color3): Part
	local p = piece(ctx, name, Vector3.new(dia, dia, dia), colour,
		Enum.Material.Metal, at(ctx, x, y, z))
	p.Shape = Enum.PartType.Ball
	return p
end

-- A horizontal cylinder slung between two local points. Built with lookAt in
-- LOCAL space and then carried into the world by the origin, so the maths never
-- has to know which way the stand is turned.
local function rope(ctx: Ctx, name: string, a: Vector3, b: Vector3): Part
	local len = (b - a).Magnitude
	local cf = ctx.origin * CFrame.lookAt((a + b) * 0.5, b) * CFrame.Angles(0, math.rad(90), 0)
	local p = piece(ctx, name, Vector3.new(len, 0.26, 0.26), VELVET,
		Enum.Material.SmoothPlastic, cf)
	p.Shape = Enum.PartType.Cylinder
	return p
end

--==[ THE PLINTH ]============================================================

-- Returns the two parts the caller needs a handle on: the model's PrimaryPart,
-- and the marker the prompt hangs off.
local function plinth(ctx: Ctx): (Part, Part)
	local base = pillar(ctx, "Base", 13.4, BASE_TOP, 0, BASE_TOP, 0, INK,
		Enum.Material.Slate)
	base.CanCollide = true
	base.CanQuery = true

	local ring = pillar(ctx, "Ring", 12.2, RING_TOP - BASE_TOP, 0, RING_TOP, 0,
		GOLD, Enum.Material.Metal)
	ring.Reflectance = 0.22
	ring.CanCollide = true
	ring.CanQuery = true

	-- the collar of light, wider than the deck so 0.5 studs of it shows all round
	local halo = pillar(ctx, "Halo", 11.4, HALO_TOP - RING_TOP, 0, HALO_TOP, 0,
		GOLD, Enum.Material.Neon)
	halo.Transparency = 0.1
	halo.CastShadow = false

	local deck = pillar(ctx, "Deck", 10.4, DECK_TOP - RING_TOP, 0, DECK_TOP, 0,
		CARPET, Enum.Material.Fabric)
	deck.Reflectance = 0
	deck.CanCollide = true
	deck.CanQuery = true

	--[[
		A marker in clear air above the front of the deck, and it exists because a
		ProximityPrompt's default UI is a BillboardGui at its host part's CENTRE with
		AlwaysOnTop off.

		Parented to the deck -- the obvious place, and where this started -- that
		centre is a point buried inside a stack of solid discs, so the prompt was
		drawn correctly and then painted over by the plinth it was sitting in. It was
		enabled, in range and in the PlayerGui the whole time; there was simply
		nothing on the screen. Nothing about that says which of the ten things it
		could be it actually is, which is why it is written down here.

		4.6 up and 5.4 forward is clear of everything that moves: the blade sweeps a
		6.1-stud circle but tops out around y 3.5, and the handle stays on the axis.
	]]
	local host = piece(ctx, "PromptHost", Vector3.new(0.6, 0.6, 0.6), GOLD,
		Enum.Material.Metal, at(ctx, 0, 4.6, -5.4))
	host.Transparency = 1
	host.CastShadow = false

	--[[
		One light, and only one.

		It is what makes the gold look like metal after dark and at the mouth of the
		garage, where the sky does not reach. On the marker rather than in the deck so
		it sits in the open air it is meant to be lighting. Shadows off and the range
		kept to the stand's own footprint plus a couple of studs: a shadow-casting
		light is the expensive kind, and this one has a turning tool inside it.
	]]
	local lamp = Instance.new("PointLight")
	lamp.Name = "Glow"
	lamp.Color = GOLD
	lamp.Brightness = 1.3
	lamp.Range = 26
	lamp.Shadows = false
	lamp.Parent = host

	-- the way in, pointed at the spawn pad and stopped at its edge
	piece(ctx, "Runner", Vector3.new(4.6, 0.10, 6.0), CARPET,
		Enum.Material.Fabric, at(ctx, 0, 0.05, -9.3))
	for _, side in ipairs({ -1, 1 }) do
		local edge = piece(ctx, "RunnerEdge", Vector3.new(0.36, 0.12, 6.0), GOLD,
			Enum.Material.Metal, at(ctx, side * 2.28, 0.06, -9.3))
		edge.Reflectance = 0.18
	end

	--[[
		Four posts and three ropes: the front is left open on purpose. A rope across
		the approach reads as "keep out", which is the exact opposite of what a shop
		window is for, and the runner walks straight into it.
	]]
	local corners: { Vector3 } = {}
	for i = 0, 3 do
		local a = math.rad(45 + i * 90)
		local x, z = ROPE_R * math.sin(a), -ROPE_R * math.cos(a)
		corners[i + 1] = Vector3.new(x, 2.42, z)
		local post = pillar(ctx, "Stanchion", 0.34, 3.0, x, 3.0, z, GOLD_DP,
			Enum.Material.Metal)
		post.Reflectance = 0.14
		ball(ctx, "Finial", 0.62, x, 3.2, z, GOLD).Reflectance = 0.24
	end
	rope(ctx, "Rope", corners[1], corners[2])
	rope(ctx, "Rope", corners[2], corners[3])
	rope(ctx, "Rope", corners[3], corners[4])

	return base, host
end

--==[ THE BOARD ]=============================================================

local function label(parent: Instance, name: string, s: string, font: Enum.Font,
	size: number, y: number, h: number, colour: Color3,
	align: Enum.TextXAlignment): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromScale(0, y)
	l.Size = UDim2.fromScale(1, h)
	l.Font = font
	l.Text = s
	l.TextSize = size
	l.TextColor3 = colour
	l.TextXAlignment = align
	l.Parent = parent
	return l
end

--[[
	The perks, in the order they are worth reading.

	The gold kit first because it is the one standing three feet away on the
	plinth, and the money last because a number is the easiest thing to scan back
	to. These say the same things as the pass's own blurb in SealerUI.Passes and
	deliberately say them at length: that blurb is squeezed into a 48-pixel box on
	a shop card, and this board is eight studs tall.
]]
local PERKS = {
	"Gold squeegee, pail and wand",
	"Gold VIP tag over your head",
	"20% quicker on your feet",
	"$40,000 pay packet every day",
	"Premium jobs worth up to 5x",
}

local function board(ctx: Ctx)
	-- Set back half a stud so the board stands proud of its own posts. Level with
	-- them the 0.8-stud posts poked through the FRONT of a 0.4-stud panel, which
	-- read as two gold bars laid over the sign rather than as a sign on two posts.
	for _, side in ipairs({ -1, 1 }) do
		local post = pillar(ctx, "SignPost", 0.8, POST_TOP, side * 6.9, POST_TOP,
			SIGN_Z + 0.5, GOLD_DP, Enum.Material.Metal)
		post.CanCollide = true
		ball(ctx, "SignCap", 1.05, side * 6.9, POST_TOP + 0.3, SIGN_Z + 0.5, GOLD)
			.Reflectance = 0.24
	end

	-- The frame is BEHIND the panel and slightly larger, so what shows is a gold
	-- border round a dark board rather than a gold slab with a hole in it.
	local frame = piece(ctx, "SignFrame", Vector3.new(SIGN_W + 1.0, SIGN_H + 0.8, 0.36),
		GOLD, Enum.Material.Metal, at(ctx, 0, SIGN_Y, SIGN_Z + 0.22))
	frame.Reflectance = 0.2

	local panel = piece(ctx, "SignPanel", Vector3.new(SIGN_W, SIGN_H, 0.4), PANEL,
		Enum.Material.SmoothPlastic, at(ctx, 0, SIGN_Y, SIGN_Z))

	-- Face.Front is the part's own -Z, which is the direction the whole stand
	-- faces, so the board reads to somebody standing on the spawn pad.
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = panel

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 34)
	pad.PaddingRight = UDim.new(0, 34)
	pad.Parent = root

	local title = label(root, "Title", "VIP", Enum.Font.LuckiestGuy, 96, 0.01, 0.25,
		GOLD, Enum.TextXAlignment.Center)
	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(18, 20, 26)
	edge.Thickness = 4
	edge.Parent = title

	label(root, "Sub", "SEALCOAT CLUB MEMBERSHIP", Enum.Font.GothamBold, 24, 0.26,
		0.08, CREAM, Enum.TextXAlignment.Center)

	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.BackgroundColor3 = GOLD
	rule.BackgroundTransparency = 0.35
	rule.BorderSizePixel = 0
	rule.Position = UDim2.fromScale(0.1, 0.35)
	rule.Size = UDim2.new(0.8, 0, 0, 3)
	rule.Parent = root

	for i, perk in ipairs(PERKS) do
		label(root, "Perk" .. i, "\u{2022}  " .. perk, Enum.Font.GothamBold, 27,
			0.385 + (i - 1) * 0.088, 0.082, CREAM, Enum.TextXAlignment.Left)
	end

	--[[
		The footer is the only thing on this board that changes, and both of the
		things that change it are facts about ONE player -- what VIP costs today, and
		whether this player already has it. So it is authored with neither: a plain
		standing invitation, which VipStandClient overwrites locally on the screen of
		whoever is reading it. A server that wrote either would be showing every
		player the first one's answer.
	]]
	local strip = Instance.new("Frame")
	strip.Name = "Footer"
	strip.BackgroundColor3 = GOLD
	strip.BorderSizePixel = 0
	strip.Position = UDim2.fromScale(0.06, 0.845)
	strip.Size = UDim2.fromScale(0.88, 0.135)
	strip.Parent = root
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = strip

	local foot = label(strip, "Price", "WALK UP AND PRESS E", Enum.Font.LuckiestGuy,
		34, 0, 1, Color3.fromRGB(38, 28, 8), Enum.TextXAlignment.Center)
	foot.Position = UDim2.fromScale(0, 0)
end

--==[ THE HERO ]==============================================================

--[[
	A real squeegee, gilded and grown.

	The Tool wrapper is thrown away and the Rig kept: everything you can SEE of a
	squeegee lives in that model (see ToolBuilder), and the Tool around it carries
	an invisible Handle and a SealerTool attribute that would make this exhibit
	look like a dropped tool to anything scanning for one.

	ScaleTo rather than a hand-written set of sizes, so the display cannot drift
	from the tool. It scales about the model's pivot, which is the Blade, so the
	rig grows upward and outward from its own contact line and the placement below
	stays a single number.

	The blade is left at the width ToolBuilder builds it -- level 1. A display
	sized to somebody's upgrade track would be a different width for every player
	in the server, and the server has one copy of this model.
]]
local function hero(ctx: Ctx): Model
	local tool = ToolBuilder.buildSqueegee()
	local rig = tool:FindFirstChild("Rig") :: Model
	rig.Name = "GoldenSqueegee"
	ToolBuilder.gild(rig)
	rig.Parent = ctx.model
	tool:Destroy()

	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end

	rig:ScaleTo(HERO_SCALE)
	-- Left standing here and nowhere else recorded. VipStandClient reads this pose
	-- straight off the rig on its first frame, so the exhibit's own transform is
	-- the only copy of it and cannot go stale when the stand is moved.
	rig:PivotTo(at(ctx, 0, HERO_Y, 0) * CFrame.Angles(math.rad(HERO_TILT), 0, 0))
	return rig
end

--==[ BUILD ]=================================================================

function VipStandBuilder.build(origin: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = VipStandBuilder.ModelName
	local ctx: Ctx = { model = model, origin = origin }

	local base, host = plinth(ctx)
	board(ctx)
	hero(ctx)

	--[[
		The prompt sells nothing itself and fires nothing on the server. It is read
		on the presser's own client, which then opens Roblox's purchase dialog -- the
		same one the Shop card opens, because there is only one way to take money for
		a game pass and PassService is already listening for the other end of it.

		Line of sight is off: the hero turns between the reader and the plinth all
		day, and a prompt that blinks out every time a squeegee crosses it reads as a
		broken one.

		On PromptHost rather than on the deck -- see the note over that part, which is
		the whole reason it exists.
	]]
	local p = Instance.new("ProximityPrompt")
	p.Name = VipStandBuilder.PromptName
	p.ActionText = "Get VIP"
	p.ObjectText = Passes.ById.VIP.name
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.MaxActivationDistance = 14
	p.RequiresLineOfSight = false
	p.Parent = host

	model.PrimaryPart = base

	--[[
		And down to size, last, once every part exists to be scaled.

		ScaleTo shrinks everything towards the model's PIVOT, which is the Base disc's
		own centre -- so on its own it leaves the plinth hovering, by half the base's
		height times however much was taken off. The lift is put back here rather than
		fudged into BASE_TOP so that the survey above stays readable at full size.

		Pre-multiplied, so the drop is along WORLD down. The pivot is a disc rolled a
		quarter turn, and its own local Y points sideways.
	]]
	if VipStandBuilder.Scale ~= 1 then
		model:ScaleTo(VipStandBuilder.Scale)
		local lift = BASE_TOP * 0.5 * (1 - VipStandBuilder.Scale)
		model:PivotTo(CFrame.new(0, -lift, 0) * model:GetPivot())
	end

	-- Atomic, so it arrives whole. The client hooks the prompt and turns the hero,
	-- and a model that streams in a piece at a time is one where both of those
	-- have to be written to survive finding half a stand -- see the note over the
	-- shop terminal binding in SealerUIClient for what that costs when it is
	-- forgotten.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Parent = parent
	return model
end

return VipStandBuilder
