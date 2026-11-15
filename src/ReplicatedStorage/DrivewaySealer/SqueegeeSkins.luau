--!strict
--[[
	SqueegeeSkins -- ten dressings for the squeegee, and the four rules that keep a
	dressing from breaking the tool.

	A skin is COSMETIC ONLY. Everything the simulation reads -- the part named
	Blade, its width, its facing -- is untouched, so a skinned squeegee spreads
	exactly like a bare one. The rules below are not style guidance; each of them
	is a property something else in the game writes every frame, and writing it
	here means writing it into a fight.

	1. NEVER TOUCH Pole.Size OR Pole.CFrame.
	   SqueegeePose:Update re-lengths the handle to reach the player's hands and
	   re-aims it, every frame, from the blade. A skin that reshapes the pole is
	   overwritten before it is ever seen; one that moves it fights the poser.
	   Colour, material and reflectance on the pole are free.

	2. NEVER TOUCH Blade.Size.X OR Head.Size.X.
	   ToolBuilder.setBladeWidth owns those -- it is how the Squeegee Length track
	   is drawn, and RemoteToolsClient runs it every frame for every player in
	   sight. Size.Y and Size.Z are nobody else's, so a chunkier head is fine.
	   A skin part that SHOULD span the blade sets SkinFollowsWidth instead; see
	   the note over that attribute.

	3. EMITTERS MUST BE LockedToPart.
	   The rig is anchored and teleported to the player every frame, and on equip
	   it teleports in from the world origin. A free emitter draws that jump as a
	   comet of sparks across the map. This is the same trap ToolBuilder.gild's
	   glint documents; it applies to every emitter added here.
	   Trails are banned outright for the same reason -- there is no locked mode
	   for a Trail, so one on this rig streaks across the district on every equip.

	4. DECORATION GOES ON THE BLADE END, NOT THE POLE.
	   Blade, Head and Collar sit at fixed positions in rig space and are carried
	   by the rig's own PivotTo. The pole is re-posed independently by rule 1, so
	   anything parented near it is left behind the moment the player moves.

	APPLIED ON THE SERVER, ALWAYS. The tools are per-player clones out of
	StarterPack; dressing one on a client dresses it on that screen and nowhere
	else. SqueegeeSkinService does the applying, for the same reason VipService
	does the gilding -- see the note there about tools that arrive later.
]]

local ToolBuilder = require(script.Parent.ToolBuilder)
-- For the one kit that is owned by holding a game pass rather than by buying it.
-- Passes requires nothing, so there is no cycle back into here.
local Passes = require(game:GetService("ReplicatedStorage").SealerUI:WaitForChild("Passes"))

local SqueegeeVFX = game.ReplicatedStorage.Assets.VFX.Squeegee

local SqueegeeSkins = {}

--[[
	The attribute a player's choice rides on, and the one every added instance
	carries so a re-skin can find its own litter.

	An attribute rather than a name prefix: names collide (the squeegee's steel top
	plate is already called Head, like the thing on a character's shoulders) and a
	prefix is a convention a future skin can forget. An attribute cannot be added
	by accident and cannot be missed by the sweep.
]]
SqueegeeSkins.Attr = "Skin_Squeegee"
local MARK = "SqueegeeSkin"

--[[
	A skin part that has to span the blade sets this, and ToolBuilder.setBladeWidth
	resizes it along with Blade and Head. SkinWidthInset is how much SHORTER than
	the blade it sits -- an inlay wants to stop short of the ends rather than run
	off them.

	The alternative was baking the default width in, which is wrong the moment the
	player buys a level of Squeegee Length: their glowing inlay would stay 6.4
	studs on a 10-stud blade.
]]
SqueegeeSkins.FollowsWidth = "SkinFollowsWidth"
SqueegeeSkins.WidthInset = "SkinWidthInset"

--[[
	Where a piece was asked to sit, in rig space, carried on the piece itself.

	The placement below is a best effort from whatever frame this file happens to
	be running in; this attribute is the ANSWER, and ToolBuilder.seatSkin re-seats
	from it on the machine that is actually drawing the rig. See the note over
	`piece`, and the longer one over seatSkin for why the two can differ.
]]
SqueegeeSkins.LocalCFrame = "SkinLocal"

local RUBBER = Color3.fromRGB(26, 26, 28)
local STEEL = Color3.fromRGB(122, 126, 132)
local WOOD = Color3.fromRGB(196, 130, 62)

local SM = Enum.Material.SmoothPlastic
local MET = Enum.Material.Metal
local NEON = Enum.Material.Neon

--==[ BUILDING BLOCKS ]=======================================================

local function mark(inst: Instance): Instance
	inst:SetAttribute(MARK, true)
	return inst
end

--[[
	An added part, in the rig's own space.

	Parented straight to the rig rather than into a folder, because
	setBladeWidth walks GetChildren rather than GetDescendants -- a width-following
	inlay one level down would never be resized.

	⚠ `cf` IS RIG SPACE, AND THE RIG IS ALMOST NEVER AT THE ORIGIN.

	This used to write `cf` straight into p.CFrame, which is a world CFrame -- so a
	piece only landed where the skin drew it on a rig that happened to be sitting
	at the world origin. Exactly two things are: the freshly built rigs on the two
	viewport turntables. On a real tool the client has already re-framed the rig
	onto the player, so every piece was placed about 180 studs off the blade, and
	the rig's own PivotTo -- being rigid -- then carried that gap along forever.

	That is the "my squeegee looks nothing like the one in the case" report. The
	paint arrives, because paint is written onto parts that are already there; the
	pieces do not, because they are new ones. Every added inlay, stripe, crack,
	patch and badge in this file went the same way, and none of them were gone --
	they were stood in a heap out in the map, one set per skinned player.
]]
local function piece(rig: Model, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	-- rig space, the same frame ToolBuilder built Blade/Head/Collar in, converted
	-- through the Blade because that is the only part of it the world can see
	p.CFrame = (ToolBuilder.rigFrame(rig) or CFrame.new()) * cf
	p:SetAttribute(SqueegeeSkins.LocalCFrame, cf)
	p.Parent = rig
	mark(p)
	return p
end

-- An inlay running the length of the blade. Inset so it stops short of the ends
-- however wide the blade grows.
local function inlay(rig: Model, name: string, thick: number, cf: CFrame,
	colour: Color3, material: Enum.Material, inset: number): BasePart
	local blade = rig:FindFirstChild("Blade") :: BasePart
	local w = math.max(0.05, (blade and blade.Size.X or 6.4) - inset)
	local p = piece(rig, name, Vector3.new(w, thick, thick), cf, colour, material)
	p:SetAttribute(SqueegeeSkins.FollowsWidth, true)
	p:SetAttribute(SqueegeeSkins.WidthInset, inset)
	return p
end

local function light(host: BasePart, colour: Color3, brightness: number, range: number)
	local l = Instance.new("PointLight")
	l.Name = "SkinGlow"
	l.Color = colour
	l.Brightness = brightness
	l.Range = range
	-- No light in this place casts shadows (0 of 86 at the last perf pass) and a
	-- shadow-casting light on a tool held in front of the camera all session is
	-- the most expensive one that could be added.
	l.Shadows = false
	l.Parent = host
	mark(l)
end

--[[
	Rate is deliberately tiny on every emitter in this file.

	This is drawn on something in front of the camera for a whole session, and
	drawn again for every other player in sight -- their tools are these same
	replicated instances. ToolBuilder's VIP glint runs at Rate 5 for that reason
	and nothing here goes far past it.
]]
local function sparks(host: BasePart, colour: ColorSequence, rate: number,
	size: number, speed: number, texture: string?)
	local e = Instance.new("ParticleEmitter")
	e.Name = "SkinSparks"
	e.Texture = texture or "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = colour
	e.LightEmission = 0.9
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.4, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.4, 0.9)
	e.Rate = rate
	e.Speed = NumberRange.new(speed * 0.3, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-70, 70)
	-- Rule 3. Without this the equip teleport is drawn as a comet.
	e.LockedToPart = true
	e.Parent = host
	mark(e)
end

--==[ THE TEN ]===============================================================

--[[
	Ordered worst to best, and the order is load-bearing rather than decorative:
	this is the ladder a reward table draws from, so `order` is what decides which
	skin is a consolation prize and which is a jackpot.

	The escalation is deliberately in KIND, not just in hue, because ten recolours
	of the same object stop reading as ten things somewhere around the fourth:

	  1-3   paint. Work kit -- a real squeegee somebody would own.
	  4-5   materials. Metal and reflectance; the shape starts catching light.
	  6-7   paint plus a piece. An inlay, a badge, a glint.
	  8-9   emissive. Neon inlays that light the ground, and particles.
	  10    all of it at once.

	TONE, NOT A BRICK, throughout -- the rule ToolBuilder.gild's note already
	makes for gold. The rubber stays dark on nearly every skin, because the blade
	is the piece the player is actually reading, and a squeegee that is one colour
	end to end loses its own silhouette past about ten studs.
]]

export type Paint = { colour: Color3, material: Enum.Material?, reflect: number? }
export type Skin = {
	id: string,
	name: string,
	rarity: string,
	order: number,
	blurb: string,
	paint: { [string]: Paint },
	dress: ((rig: Model) -> ())?,
	-- Set only on a kit that comes with a game pass. It changes who owns it, what
	-- it costs, and how it is bought -- see priceOf / robuxPriceOf / owns.
	pass: string?,
}

local function applyVFX(rig: Model, name: string)
	if rig:GetAttribute("ForViewport") then
		return
	end
	
	local vfxTemplate = SqueegeeVFX:FindFirstChild(name) :: Part
	local pole = rig:FindFirstChild("Pole") :: Part
	
	if pole then
		if pole:FindFirstChild("VFX") then
			pole.VFX:Destroy()
		end
		
		if vfxTemplate then
			local vfx = vfxTemplate:Clone()
			vfx.Parent = pole
			local cframe = CFrame.new(pole.Position, pole.Position+vfx:GetPivot().LookVector)
			vfx:PivotTo(cframe)
			vfx.Name = "VFX"

			local weld = Instance.new("WeldConstraint", vfx)
			weld.Part0 = pole
			weld.Part1 = (vfx:IsA("BasePart") and vfx) or (vfx:IsA("Model") and vfx:WaitForChild("Primary"))
		end
	end
end

local List: { Skin } = {
	{
		id = "Standard", name = "Site Standard", rarity = "Common", order = 1,
		blurb = "Ash handle, steel head, black rubber. What everybody starts with.",
		paint = {
			Blade = { colour = RUBBER, material = SM },
			Head = { colour = STEEL, material = MET },
			Collar = { colour = STEEL, material = MET },
			Pole = { colour = WOOD, material = Enum.Material.Wood },
		},
	},
	{
		id = "HiVis", name = "Hi-Vis", rarity = "Common", order = 2,
		blurb = "Safety orange and a reflective edge. Cheap, loud, and you can find"
			.. " it when you put it down.",
		paint = {
			Blade = { colour = Color3.fromRGB(22, 22, 24), material = SM },
			Head = { colour = Color3.fromRGB(240, 112, 24), material = SM },
			Collar = { colour = Color3.fromRGB(38, 40, 44), material = MET },
			Pole = { colour = Color3.fromRGB(232, 196, 40), material = SM },
		},
		dress = function(rig)
			inlay(rig, "SkinEdge", 0.07, CFrame.new(0, 0.045, -0.085),
				Color3.fromRGB(248, 216, 60), SM, 0.5)
		end,
	},
	{
		id = "Contractor", name = "Contractor Blue", rarity = "Common", order = 3,
		blurb = "Fleet livery. The kit a firm buys forty of.",
		paint = {
			Blade = { colour = Color3.fromRGB(20, 22, 28), material = SM },
			Head = { colour = Color3.fromRGB(28, 64, 132), material = SM },
			Collar = { colour = Color3.fromRGB(150, 158, 170), material = MET, reflect = 0.12 },
			Pole = { colour = Color3.fromRGB(214, 200, 178), material = Enum.Material.Wood },
		},
		dress = function(rig)
			inlay(rig, "SkinPinstripe", 0.05, CFrame.new(0, 0.60, 0.02),
				Color3.fromRGB(236, 240, 248), SM, 0.8)
		end,
	},
	{
		id = "Brushed", name = "Brushed Steel", rarity = "Uncommon", order = 4,
		blurb = "Machined out of one billet. No paint to chip.",
		paint = {
			Blade = { colour = Color3.fromRGB(38, 38, 42), material = SM },
			Head = { colour = Color3.fromRGB(198, 204, 214), material = MET, reflect = 0.28 },
			Collar = { colour = Color3.fromRGB(140, 146, 156), material = MET, reflect = 0.18 },
			Pole = { colour = Color3.fromRGB(176, 182, 192), material = MET, reflect = 0.24 },
		},
	},
	{
		id = "Copper", name = "Copper Rig", rarity = "Uncommon", order = 5,
		blurb = "Walnut and beaten copper, gone green at the collar. Somebody's"
			.. " grandfather's, kept sharp.",
		paint = {
			Blade = { colour = Color3.fromRGB(30, 26, 24), material = SM },
			Head = { colour = Color3.fromRGB(196, 108, 52), material = MET, reflect = 0.22 },
			Collar = { colour = Color3.fromRGB(84, 146, 124), material = MET, reflect = 0.10 },
			Pole = { colour = Color3.fromRGB(96, 58, 36), material = Enum.Material.Wood },
		},
		dress = function(rig)
			-- a ferrule where the handle enters the collar: fixed size, because the
			-- collar does not grow with the blade
			piece(rig, "SkinFerrule", Vector3.new(0.40, 0.16, 0.40),
				CFrame.new(0, 0.79, 0.14), Color3.fromRGB(214, 128, 62), MET).Reflectance = 0.2
		end,
	},
	{
		id = "Carbon", name = "Carbon Fibre", rarity = "Rare", order = 6,
		blurb = "Woven black with an anodised collar. Lighter than it looks and"
			.. " twice the price.",
		paint = {
			Blade = { colour = Color3.fromRGB(16, 16, 18), material = SM },
			Head = { colour = Color3.fromRGB(28, 30, 34), material = MET, reflect = 0.16 },
			Collar = { colour = Color3.fromRGB(196, 40, 36), material = MET, reflect = 0.14 },
			Pole = { colour = Color3.fromRGB(22, 22, 26), material = MET, reflect = 0.10 },
		},
		dress = function(rig)
			inlay(rig, "SkinEdge", 0.06, CFrame.new(0, 0.045, -0.085),
				Color3.fromRGB(196, 40, 36), SM, 0.6)
			piece(rig, "SkinBadge", Vector3.new(0.5, 0.14, 0.05),
				CFrame.new(0, 0.60, -0.20), Color3.fromRGB(196, 40, 36), SM)
			
		end,
	},
	{
		id = "Gold", name = "Gold Standard", rarity = "Rare", order = 7,
		blurb = "The kit off the plinth by the spawn, in your hands.",
		-- ToolBuilder.Gold / GoldDeep, so this cannot drift from the VIP kit or from
		-- the display squeegee on the stand -- all three read the same two values.
		paint = {
			Blade = { colour = Color3.fromRGB(24, 22, 18), material = SM },
			Head = { colour = ToolBuilder.Gold, material = MET, reflect = 0.28 },
			Collar = { colour = ToolBuilder.GoldDeep, material = MET, reflect = 0.14 },
			Pole = { colour = ToolBuilder.Gold, material = MET, reflect = 0.28 },
		},
		dress = function(rig)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				sparks(head, ColorSequence.new(Color3.fromRGB(255, 238, 176)), 5, 0.34, 0.5)
			end
		end,
	},
	{
		id = "Neon", name = "Neon Circuit", rarity = "Epic", order = 8,
		blurb = "Charcoal body, cold cyan running through it. Lights the slab in"
			.. " front of you.",
		paint = {
			Blade = { colour = Color3.fromRGB(18, 20, 24), material = SM },
			Head = { colour = Color3.fromRGB(26, 30, 38), material = MET, reflect = 0.12 },
			Collar = { colour = Color3.fromRGB(0, 214, 226), material = NEON },
			Pole = { colour = Color3.fromRGB(24, 28, 34), material = MET, reflect = 0.10 },
		},
		dress = function(rig)
			local cyan = Color3.fromRGB(0, 214, 226)
			inlay(rig, "SkinInlayFront", 0.07, CFrame.new(0, 0.48, -0.205), cyan, NEON, 0.7)
			inlay(rig, "SkinInlayTop", 0.05, CFrame.new(0, 0.63, 0.02), cyan, NEON, 1.2)
			inlay(rig, "SkinEdge", 0.05, CFrame.new(0, 0.045, -0.085), cyan, NEON, 0.4)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then light(head, cyan, 1.4, 9) end
		end,
	},
	{
		id = "Molten", name = "Molten", rarity = "Epic", order = 9,
		blurb = "Cracked iron with something still burning in it. Sheds embers as"
			.. " you sweep.",
		paint = {
			Blade = { colour = Color3.fromRGB(20, 16, 14), material = SM },
			Head = { colour = Color3.fromRGB(38, 30, 28), material = MET, reflect = 0.10 },
			Collar = { colour = Color3.fromRGB(255, 122, 28), material = NEON },
			Pole = { colour = Color3.fromRGB(32, 26, 24), material = MET, reflect = 0.08 },
		},
		dress = function(rig)
			local ember = Color3.fromRGB(255, 122, 28)
			inlay(rig, "SkinCrackFront", 0.06, CFrame.new(0, 0.44, -0.205), ember, NEON, 1.4)
			inlay(rig, "SkinCrackTop", 0.05, CFrame.new(0, 0.63, 0.06), ember, NEON, 2.2)
			inlay(rig, "SkinEdge", 0.06, CFrame.new(0, 0.045, -0.085),
				Color3.fromRGB(255, 176, 60), NEON, 0.4)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, ember, 1.8, 11)
				sparks(head, ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 214, 120)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(214, 56, 12)),
				}), 7, 0.28, 0.9)
			end
		end,
	},
	{
		id = "Prism", name = "Prism", rarity = "Legendary", order = 10,
		blurb = "Nobody knows what it is made of. It throws colour on everything it"
			.. " touches.",
		paint = {
			Blade = { colour = Color3.fromRGB(14, 14, 18), material = SM },
			Head = { colour = Color3.fromRGB(244, 248, 255), material = NEON },
			Collar = { colour = Color3.fromRGB(180, 120, 255), material = NEON },
			Pole = { colour = Color3.fromRGB(226, 232, 248), material = MET, reflect = 0.3 },
		},
		dress = function(rig)
			inlay(rig, "SkinInlayFront", 0.09, CFrame.new(0, 0.48, -0.21),
				Color3.fromRGB(120, 220, 255), NEON, 0.5)
			inlay(rig, "SkinInlayTop", 0.06, CFrame.new(0, 0.64, 0.02),
				Color3.fromRGB(255, 140, 220), NEON, 0.9)
			inlay(rig, "SkinEdge", 0.07, CFrame.new(0, 0.045, -0.09),
				Color3.fromRGB(180, 255, 220), NEON, 0.3)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, Color3.fromRGB(198, 170, 255), 2.2, 13)
				-- the one place a full spectrum is right: it is the whole pitch
				sparks(head, ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 190)),
					ColorSequenceKeypoint.new(0.35, Color3.fromRGB(120, 200, 255)),
					ColorSequenceKeypoint.new(0.7, Color3.fromRGB(150, 255, 190)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 232, 140)),
				}), 9, 0.36, 0.7)
			end
			local collar = rig:FindFirstChild("Collar") :: BasePart?
			if collar then
				sparks(collar, ColorSequence.new(Color3.fromRGB(220, 190, 255)), 4, 0.2, 0.4)
			end
		end,
	},

	--==[ THE SECOND TEN (2026-08-14) ]=======================================

	--[[
		Appended rather than woven into the list above, and sorted into place
		afterwards -- see the note over the sort. `order` is the rung WITHIN a
		rarity, so these carry on from 10 and still land beside their own tier.

		The same escalation in KIND as the first ten, because ten more recolours of
		the same object would stop reading as ten more things: paint, then
		materials, then a piece, then emissive, then all of it at once. The two
		Legendaries are the only ones that get a light AND two emitters.

		⚠ NEON IS KEPT SATURATED AND UNDER ~230 ON EVERY CHANNEL. This place runs
		Lighting.Brightness 2.6 against a Bloom threshold of 1.75, so a near-white
		neon lens sails straight past it and floods the whole rig -- the same trap
		the truck headlights hit. "White hot" is done with a hot ORANGE, never with
		white.
	]]

	{
		id = "Sandstorm", name = "Sandstorm", rarity = "Common", order = 11,
		blurb = "Sun-bleached desert tan. It has been on a roof somewhere hot.",
		paint = {
			Blade = { colour = Color3.fromRGB(26, 24, 22), material = SM },
			Head = { colour = Color3.fromRGB(214, 178, 120), material = SM },
			Collar = { colour = Color3.fromRGB(146, 112, 68), material = MET, reflect = 0.08 },
			Pole = { colour = Color3.fromRGB(198, 172, 132), material = Enum.Material.Wood },
		},
	},
	{
		id = "Nightshift", name = "Nightshift", rarity = "Common", order = 12,
		blurb = "Matte black with one stripe of hi-vis. For the jobs that finish"
			.. " after dark.",
		paint = {
			Blade = { colour = Color3.fromRGB(16, 16, 18), material = SM },
			Head = { colour = Color3.fromRGB(32, 34, 40), material = SM },
			Collar = { colour = Color3.fromRGB(54, 58, 66), material = MET, reflect = 0.1 },
			Pole = { colour = Color3.fromRGB(26, 28, 34), material = SM },
		},
		dress = function(rig)
			inlay(rig, "SkinStripe", 0.06, CFrame.new(0, 0.60, 0.02),
				Color3.fromRGB(226, 208, 62), SM, 0.9)
		end,
	},
	{
		id = "Mint", name = "Mint Condition", rarity = "Uncommon", order = 13,
		blurb = "Pastel green and polished chrome, still in the wrapper.",
		paint = {
			Blade = { colour = Color3.fromRGB(30, 34, 32), material = SM },
			Head = { colour = Color3.fromRGB(150, 226, 196), material = SM },
			Collar = { colour = Color3.fromRGB(206, 214, 222), material = MET, reflect = 0.34 },
			Pole = { colour = Color3.fromRGB(238, 240, 232), material = SM },
		},
		dress = function(rig)
			inlay(rig, "SkinPinstripe", 0.05, CFrame.new(0, 0.63, 0.02),
				Color3.fromRGB(214, 222, 230), MET, 0.8)
		end,
	},
	{
		id = "Rust", name = "Rust Bucket", rarity = "Uncommon", order = 14,
		blurb = "Left out one winter too many. Still spreads perfectly well.",
		paint = {
			Blade = { colour = Color3.fromRGB(28, 22, 20), material = SM },
			Head = { colour = Color3.fromRGB(150, 78, 44), material = MET, reflect = 0.06 },
			Collar = { colour = Color3.fromRGB(88, 62, 48), material = MET },
			Pole = { colour = Color3.fromRGB(112, 92, 74), material = Enum.Material.Wood },
		},
		dress = function(rig)
			-- corrosion patches, on the BLADE END: rule 4, anything parented near
			-- the pole is left behind the moment the poser re-aims it
			piece(rig, "SkinPatchA", Vector3.new(0.9, 0.10, 0.08),
				CFrame.new(-1.1, 0.52, -0.20), Color3.fromRGB(96, 52, 30), MET)
			piece(rig, "SkinPatchB", Vector3.new(0.6, 0.09, 0.08),
				CFrame.new(1.4, 0.44, -0.20), Color3.fromRGB(74, 44, 28), MET)
		end,
	},
	{
		id = "Frost", name = "Frostbite", rarity = "Rare", order = 15,
		blurb = "Pale ice over a cold blue core. The handle is genuinely unpleasant"
			.. " to hold.",
		paint = {
			Blade = { colour = Color3.fromRGB(32, 40, 50), material = SM },
			Head = { colour = Color3.fromRGB(196, 226, 244), material = MET, reflect = 0.35 },
			Collar = { colour = Color3.fromRGB(120, 196, 226), material = NEON },
			Pole = { colour = Color3.fromRGB(210, 228, 240), material = MET, reflect = 0.22 },
		},
		dress = function(rig)
			local ice = Color3.fromRGB(140, 208, 230)
			inlay(rig, "SkinInlayFront", 0.06, CFrame.new(0, 0.48, -0.205), ice, NEON, 0.8)
			inlay(rig, "SkinEdge", 0.05, CFrame.new(0, 0.045, -0.085), ice, NEON, 0.5)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then light(head, Color3.fromRGB(150, 205, 230), 1.1, 8) end
			
		end,
	},
	{
		id = "Toxic", name = "Toxic", rarity = "Rare", order = 16,
		blurb = "Hazard green, and something is definitely dripping off it.",
		paint = {
			Blade = { colour = Color3.fromRGB(22, 26, 20), material = SM },
			Head = { colour = Color3.fromRGB(44, 52, 40), material = MET, reflect = 0.1 },
			Collar = { colour = Color3.fromRGB(150, 220, 40), material = NEON },
			Pole = { colour = Color3.fromRGB(34, 40, 32), material = MET, reflect = 0.08 },
		},
		dress = function(rig)
			local acid = Color3.fromRGB(150, 220, 40)
			inlay(rig, "SkinInlayFront", 0.07, CFrame.new(0, 0.46, -0.205), acid, NEON, 1.0)
			inlay(rig, "SkinEdge", 0.05, CFrame.new(0, 0.045, -0.085), acid, NEON, 0.4)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				sparks(head, ColorSequence.new(Color3.fromRGB(168, 224, 72)), 4, 0.26, 0.45)
			end
		end,
	},
	{
		id = "Voltage", name = "Voltage", rarity = "Epic", order = 17,
		blurb = "Something is arcing across the head and nobody has fixed it.",
		paint = {
			Blade = { colour = Color3.fromRGB(18, 20, 26), material = SM },
			Head = { colour = Color3.fromRGB(30, 34, 46), material = MET, reflect = 0.14 },
			Collar = { colour = Color3.fromRGB(86, 150, 226), material = NEON },
			Pole = { colour = Color3.fromRGB(24, 28, 38), material = MET, reflect = 0.1 },
		},
		dress = function(rig)
			local arc = Color3.fromRGB(96, 168, 230)
			inlay(rig, "SkinInlayFront", 0.07, CFrame.new(0, 0.48, -0.205), arc, NEON, 0.7)
			inlay(rig, "SkinInlayTop", 0.05, CFrame.new(0, 0.63, 0.02), arc, NEON, 1.2)
			inlay(rig, "SkinEdge", 0.05, CFrame.new(0, 0.045, -0.085), arc, NEON, 0.4)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, Color3.fromRGB(110, 170, 230), 1.5, 9)
				sparks(head, ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(198, 226, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(70, 130, 220)),
				}), 6, 0.24, 1.0)
			end
		end,
	},
	{
		id = "Nebula", name = "Nebula", rarity = "Epic", order = 18,
		blurb = "Deep violet with something drifting through it. Do not look too"
			.. " long.",
		paint = {
			Blade = { colour = Color3.fromRGB(20, 16, 30), material = SM },
			Head = { colour = Color3.fromRGB(42, 32, 66), material = MET, reflect = 0.16 },
			Collar = { colour = Color3.fromRGB(168, 96, 226), material = NEON },
			Pole = { colour = Color3.fromRGB(30, 24, 46), material = MET, reflect = 0.12 },
		},
		dress = function(rig)
			inlay(rig, "SkinInlayFront", 0.07, CFrame.new(0, 0.48, -0.205),
				Color3.fromRGB(158, 96, 222), NEON, 0.7)
			inlay(rig, "SkinInlayTop", 0.05, CFrame.new(0, 0.63, 0.02),
				Color3.fromRGB(210, 120, 200), NEON, 1.1)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, Color3.fromRGB(170, 110, 226), 1.6, 10)
				sparks(head, ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(216, 158, 240)),
					ColorSequenceKeypoint.new(0.6, Color3.fromRGB(120, 108, 226)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(70, 60, 150)),
				}), 7, 0.3, 0.35)
			end
		end,
	},
	{
		id = "Obsidian", name = "Obsidian Flame", rarity = "Legendary", order = 19,
		blurb = "Black glass with something still burning inside it.",
		paint = {
			Blade = { colour = Color3.fromRGB(12, 12, 14), material = SM },
			Head = { colour = Color3.fromRGB(18, 18, 22), material = MET, reflect = 0.34 },
			Collar = { colour = Color3.fromRGB(226, 118, 34), material = NEON },
			Pole = { colour = Color3.fromRGB(16, 16, 20), material = MET, reflect = 0.28 },
		},
		dress = function(rig)
			-- the core, hot ORANGE rather than white: see the bloom note above
			local core = Color3.fromRGB(226, 118, 34)
			local hot = Color3.fromRGB(230, 176, 96)
			inlay(rig, "SkinCoreFront", 0.08, CFrame.new(0, 0.46, -0.205), core, NEON, 0.5)
			inlay(rig, "SkinCoreTop", 0.06, CFrame.new(0, 0.63, 0.02), core, NEON, 1.0)
			inlay(rig, "SkinEdge", 0.06, CFrame.new(0, 0.045, -0.085), hot, NEON, 0.3)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, Color3.fromRGB(226, 140, 60), 2.0, 12)
				sparks(head, ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(230, 196, 130)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 60, 16)),
				}), 8, 0.3, 0.9)
			end
			local collar = rig:FindFirstChild("Collar") :: BasePart?
			if collar then
				sparks(collar, ColorSequence.new(Color3.fromRGB(226, 150, 70)), 4, 0.18, 0.4)
			end
		end,
	},
	{
		id = "Aurora", name = "Aurora", rarity = "Legendary", order = 20,
		blurb = "Ribbons of green and pink that will not hold still. Nobody has"
			.. " asked where it came from.",
		paint = {
			Blade = { colour = Color3.fromRGB(16, 22, 26), material = SM },
			Head = { colour = Color3.fromRGB(210, 226, 232), material = MET, reflect = 0.3 },
			Collar = { colour = Color3.fromRGB(96, 226, 176), material = NEON },
			Pole = { colour = Color3.fromRGB(196, 214, 222), material = MET, reflect = 0.26 },
		},
		dress = function(rig)
			inlay(rig, "SkinRibbonFront", 0.08, CFrame.new(0, 0.48, -0.21),
				Color3.fromRGB(96, 226, 176), NEON, 0.5)
			inlay(rig, "SkinRibbonTop", 0.06, CFrame.new(0, 0.64, 0.02),
				Color3.fromRGB(226, 128, 200), NEON, 0.9)
			inlay(rig, "SkinEdge", 0.06, CFrame.new(0, 0.045, -0.09),
				Color3.fromRGB(140, 200, 230), NEON, 0.3)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, Color3.fromRGB(140, 210, 200), 2.1, 12)
				sparks(head, ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 230, 190)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 200, 230)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(226, 130, 200)),
				}), 8, 0.32, 0.5)
			end
			local collar = rig:FindFirstChild("Collar") :: BasePart?
			if collar then
				sparks(collar, ColorSequence.new(Color3.fromRGB(180, 226, 210)), 4, 0.2, 0.35)
			end
			
		end,
	},

	--==[ THE PASS KIT ]=====================================================

	--[[
		THE VIP SQUEEGEE, and it is the one entry here that is not bought.

		It carries `pass`, which changes four things: it is owned by holding the
		game pass rather than by anything in `SkinsOwned`, it has no cash price, its
		Robux price is the PASS's price rather than a rung on the skin ladder, and
		it has no developer product because a pass is not a product. Everything
		that reads a price or an owner branches on that one field.

		⚠ IT IS DELIBERATELY NOT THE PLAIN GILD. `ToolBuilder.gild` and the Gold
		Standard skin are pixel-identical -- same Gold, same GoldDeep, same
		materials, same reflectances, same head glint -- so a VIP kit that was just
		the gild would be a 199 Robux copy of a skin already on sale for $500,000.
		This is the gold ABOVE that one: lit inlays, a badge, a warmer light and a
		second emitter, so paying for it visibly buys something.
	]]
	{
		id = "VipKit", name = "VIP Gold", rarity = "VIP", order = 21,
		pass = "VIP",
		blurb = "The gold kit, lit from the inside. Comes with everything else VIP"
			.. " carries.",
		paint = {
			Blade = { colour = Color3.fromRGB(24, 22, 18), material = SM },
			Head = { colour = ToolBuilder.Gold, material = MET, reflect = 0.34 },
			Collar = { colour = ToolBuilder.GoldDeep, material = MET, reflect = 0.18 },
			Pole = { colour = ToolBuilder.Gold, material = MET, reflect = 0.32 },
		},
		dress = function(rig)
			-- 226,178,72 rather than a paler gold: this place runs Bloom at a 1.75
			-- threshold against Brightness 2.6, and a near-white neon lens floods
			-- the whole rig. See the note over the second ten.
			local lit = Color3.fromRGB(226, 178, 72)
			inlay(rig, "SkinInlayFront", 0.08, CFrame.new(0, 0.48, -0.205), lit, NEON, 0.5)
			inlay(rig, "SkinInlayTop", 0.06, CFrame.new(0, 0.64, 0.02), lit, NEON, 0.9)
			inlay(rig, "SkinEdge", 0.06, CFrame.new(0, 0.045, -0.09),
				Color3.fromRGB(230, 200, 130), NEON, 0.3)
			-- the badge is what says VIP at a glance from across a driveway
			piece(rig, "SkinBadge", Vector3.new(0.46, 0.16, 0.06),
				CFrame.new(0, 0.60, -0.20), lit, NEON)
			local head = rig:FindFirstChild("Head") :: BasePart?
			if head then
				light(head, Color3.fromRGB(230, 190, 110), 2.0, 12)
				-- the canonical VIP shimmer, the same colour ToolBuilder.gild uses
				sparks(head, ColorSequence.new(Color3.fromRGB(255, 238, 176)), 7, 0.34, 0.5)
			end
			local collar = rig:FindFirstChild("Collar") :: BasePart?
			if collar then
				sparks(collar, ColorSequence.new(Color3.fromRGB(236, 206, 140)), 4, 0.2, 0.4)
			end
		end,
	},
}



--[[
	Sorted worst-to-best ACROSS rarities, not just within one.

	`order` is the rung inside a TIER, and the second ten carry on from 10 -- so
	on its own it would file a Common eleventh behind a Legendary tenth, and the
	catalogue in the Squeegee Case lists in array order. Sorting here means every
	consumer gets the ladder for free and no screen has to sort for itself.

	(tier, order) is unique across the roster, so this is deterministic.
]]
-- VIP sorts above Legendary: it is the top of the case, and it is the only rung
-- that cannot be reached by playing.
local TIER = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, VIP = 6 }
table.insert(List,{
 id="Sweet",name="Trick or Sweet!",rarity="Legendary",order=30,
 blurb="HALLOWEEN EVENT - available in the Event Shop",
 paint={
  Blade={colour=Color3.fromRGB(42,22,26),material=SM},
  Head={colour=Color3.fromRGB(255,119,35),material=NEON},
  Collar={colour=Color3.fromRGB(187,67,238),material=NEON},
  Pole={colour=Color3.fromRGB(67,31,42),material=MET},
 },
 dress=function(rig)
  local head=rig:FindFirstChild("Head")
  if head and head:IsA("BasePart") then
   sparks(head,ColorSequence.new(Color3.fromRGB(255,150,56)),10,0.35,1.1)
   light(head,Color3.fromRGB(255,112,44),1.3,10)
  end
 end,
})
table.insert(List,{
 id="Spell",name="Spell",rarity="Legendary",order=31,
 blurb="HALLOWEEN EVENT - rare Gachapon reward",
 paint={
  Blade={colour=Color3.fromRGB(34,22,42),material=SM},
  Head={colour=Color3.fromRGB(97,240,76),material=NEON},
  Collar={colour=Color3.fromRGB(159,64,230),material=NEON},
  Pole={colour=Color3.fromRGB(47,28,60),material=MET},
 },
 dress=function(rig)
  local head=rig:FindFirstChild("Head")
  if head and head:IsA("BasePart") then
   sparks(head,ColorSequence.new(Color3.fromRGB(157,249,93)),14,0.4,1.1)
   light(head,Color3.fromRGB(118,240,64),1.7,11)
  end
 end,
})
table.sort(List, function(a, b)
	local ta, tb = TIER[a.rarity] or 9, TIER[b.rarity] or 9
	if ta ~= tb then return ta < tb end
	return a.order < b.order
end)

local ById: { [string]: Skin } = {}
for _, s in ipairs(List) do ById[s.id] = s end

SqueegeeSkins.List = List
SqueegeeSkins.ById = ById
SqueegeeSkins.Default = "Standard"

--==[ WHAT ONE COSTS ]=====================================================

--[[
	Skins are bought with CASH, one price per rarity (2026-08-14, when the slot
	machine that used to hand them out was removed).

	⚠ THE LADDER IS ANCHORED TO THE UPGRADE TRACKS, NOT PICKED FOR ROUNDNESS.
	Those are the authored progression -- rungs run 1,200 / 15,200 / 96,300 /
	330,000 / 888,000 / 2,400,000 / 17,500,000, and the trucks sit at Dart
	250,000, Kerbline 1.2M, Longline 5M, Cistern 25M. Each price here lands just
	UNDER the rung a player is buying at that stage, so a skin is always a
	sidestep and never the thing that stops you affording a tank:

	  Common     20,000  -- between Blade L6 (15.2k) and L7 (28.1k)
	  Uncommon  100,000  -- just under Speed L9 (104k)
	  Rare      500,000  -- between the Dart (250k) and the Kerbline (1.2M)
	  Epic    2,500,000  -- around L13, under the Longline (5M)
	  Legendary 10,000,000 -- a trophy, and still under the Cistern (25M)

	Five prices rather than twenty: a player can learn a five-rung ladder and
	read a card's tier off its cost. The whole set comes to ~42.5M, less than two
	Cisterns, which is the right size for a long-tail sink.

	⚠ NO REBIRTH DISCOUNT, unlike upgrades. `Rebirth.priceOf` discounts the
	treadmill because rebirthing RESETS it; a skin is kept forever, so the same
	discount would let a late rebirth sweep the whole collection cheaply.
]]
local PRICES: { [string]: number } = {
	Common = 20000,
	Uncommon = 100000,
	Rare = 500000,
	Epic = 2500000,
	Legendary = 10000000,
}
SqueegeeSkins.Prices = PRICES

--[[
	OR ROBUX, 29 up to 99, and the ladder is the same five rungs.

	The two currencies are alternatives, not a conversion -- a Legendary is $10M or
	R$99, and nothing here tries to make those the same number. Cash is the long
	grind and Robux is the shortcut past it, which is exactly why the Robux ladder
	is SHALLOW (29 to 99, under 4x across the whole roster) where the cash ladder is
	steep (20k to 10M, 500x): the cash price is what makes a Legendary an
	achievement, and charging 500x the Robux would make it a paywall instead.
]]
local ROBUX: { [string]: number } = {
	Common = 29,
	Uncommon = 49,
	Rare = 69,
	Epic = 89,
	Legendary = 99,
}
SqueegeeSkins.RobuxPrices = ROBUX

--[[
	ONE DEVELOPER PRODUCT PER SKIN. Created 2026-08-14; ids pasted from the
	Creator Dashboard and verified against `GetProductInfo` -- every one came back
	named for its skin and priced on the ladder above.

	Per SKIN rather than per rarity, which is what was actually made and is the
	better of the two: a receipt names the product, so it names the skin outright.
	The five-product version this replaced had to write the intended skin down
	before the dialog opened and read it back when the receipt landed -- and then
	check that note against the product, or noting a Legendary and buying the
	Common product handed over a 99 R$ skin for 29. None of that exists now: there
	is nothing to note, nothing to persist across a rejoin, and nothing to spoof.

	Site Standard has no entry and never will -- it is the free starter.

	⚠ ADDING A SKIN MEANS ADDING A PRODUCT. A skin with no id here cannot be
	bought with Robux -- the button refuses and says so, and SkinShopService
	counts the gap at startup -- so the omission is loud rather than silent.
]]
local PRODUCTS: { [string]: number } = {
	-- Common, R$29
	HiVis      = 3707977889,
	Contractor = 3707977914,
	Sandstorm  = 3707977933,
	Nightshift = 3707977959,
	-- Uncommon, R$49
	Brushed    = 3707977993,
	Copper     = 3707978043,
	Mint       = 3707978064,
	Rust       = 3707978095,
	-- Rare, R$69
	Carbon     = 3707978115,
	Gold       = 3707978137,
	Frost      = 3707978185,
	Toxic      = 3707978208,
	-- Epic, R$89
	Neon       = 3707978300,
	Molten     = 3707978319,
	Voltage    = 3707978339,
	Nebula     = 3707978358,
	-- Legendary, R$99
	Prism      = 3707978378,
	Obsidian   = 3707978391,
	Aurora     = 3707978409,
}
SqueegeeSkins.ProductIds = PRODUCTS

--[[
	⚠ A PASS KIT'S ROBUX PRICE IS THE PASS'S, not a rung on the skin ladder.

	Buying it buys the whole VIP bundle -- the gold kit, the name, the walk speed,
	the daily packet and the premium jobs -- so it is priced as the bundle. Read
	from Roblox rather than typed: a price changed on the Dashboard would otherwise
	leave the card advertising the old one.
]]
local passPrice: { [string]: number } = {}

function SqueegeeSkins.robuxPriceOf(id: string): number
	if id == SqueegeeSkins.Default then return 0 end
	local s = ById[id]
	if not s then return 0 end
	if s.pass then return passPrice[s.pass] or 0 end
	return ROBUX[s.rarity] or 0
end

-- Told once by whoever asked Roblox; nil until then, and a card showing R$0 is
-- the visible symptom of nobody having asked.
function SqueegeeSkins.setPassPrice(passId: string, robux: number)
	if type(robux) == "number" and robux > 0 then passPrice[passId] = robux end
end

function SqueegeeSkins.passOf(id: string): string?
	local s = ById[id]
	return s and s.pass or nil
end

-- The product a skin is bought through, or 0 if it has none. A pass kit never
-- has one: a game pass is not a developer product and never reaches a receipt.
function SqueegeeSkins.productFor(id: string): number
	if SqueegeeSkins.passOf(id) then return 0 end
	return PRODUCTS[id] or 0
end

-- Which SKIN a receipt is for. Nil for anything that is not one of ours, so a
-- shop with a gap in it cannot claim an unrelated receipt.
function SqueegeeSkins.skinOfProduct(productId: number): string?
	if not productId or productId == 0 then return nil end
	for id, pid in pairs(PRODUCTS) do
		if pid == productId then return id end
	end
	return nil
end

-- Every buyable skin with no product yet. Empty is the healthy answer.
function SqueegeeSkins.missingProducts(): { string }
	local out = {}
	for _, sk in ipairs(List) do
		if sk.id ~= SqueegeeSkins.Default and not sk.pass
			and (PRODUCTS[sk.id] or 0) == 0 then
			table.insert(out, sk.id)
		end
	end
	return out
end

-- Zero means "not for sale", which is the starter and nothing else.
function SqueegeeSkins.priceOf(id: string): number
	if id == SqueegeeSkins.Default then return 0 end
	local s = ById[id]
	if not s then return 0 end
	-- A pass kit is Robux only. Zero here is what makes the cash button refuse it
	-- and what makes the case give the whole card to the Robux button.
	if s.pass or id=="Sweet" or id=="Spell" then return 0 end
	return PRICES[s.rarity] or 0
end

--==[ WHAT A PLAYER OWNS ]===================================================

--[[
	Ownership lived in `SealerUI.SkinRoll` until the slot machine was removed
	(2026-08-14), and it moved HERE rather than dying with it.

	It was never really about rolling. Which skins a player has, and which one is
	on, is a fact about the CATALOGUE -- and this file is the catalogue. Keeping
	it in the machine's contract module is what would have made the machine
	load-bearing for a wardrobe that has nothing to do with it.

	The Squeegee Case is the only reader, and SqueegeeSkinService the only writer.
]]

-- Comma-joined skin ids. A string rather than a folder of BoolValues because it
-- rides in the profile as one field.
SqueegeeSkins.OwnedAttr = "SkinsOwned"

-- HALLOWEEN_CROSSWORLD_SKIN_OWNERSHIP
local function halloweenSkinOwned(plr,id)
 if not plr then return false end
 if plr:GetAttribute("HalloweenOwned_"..id)==true then return true end
 local raw=plr:GetAttribute("HalloweenShopState")
 if type(raw)=="string" then
  local ok,data=pcall(game:GetService("HttpService").JSONDecode,game:GetService("HttpService"),raw)
  if ok and type(data)=="table" and type(data.owned)=="table" then return data.owned[id]==true end
 end
 return false
end
function SqueegeeSkins.ownedSet(plr: Player?): { [string]: boolean }
	-- Everybody owns the starter, written down rather than implied so a screen
	-- can draw an owned tick against it without a special case.
	local set: { [string]: boolean } = { [SqueegeeSkins.Default] = true }
	if not plr then return set end
	local raw = plr:GetAttribute(SqueegeeSkins.OwnedAttr)
	if type(raw) == "string" then
		for id in raw:gmatch("[^,]+") do
			if ById[id] then set[id] = true end
		end
	end
	for _,id in ipairs({"Sweet","Spell"}) do if halloweenSkinOwned(plr,id) then set[id]=true end end
	return set
end

--[[
	A PASS KIT IS OWNED BY HOLDING THE PASS, never by anything in `SkinsOwned`.

	Routing both through one function is what lets the case, the shop and the equip
	handler stay ignorant of the difference -- and it is what stops a pass kit ever
	being written into the owned string, which would survive a refund.
]]
function SqueegeeSkins.owns(plr: Player?, id: string): boolean
	local s = ById[id]
	if s and s.pass then
		return plr ~= nil and Passes.owns(plr, s.pass)
	end
	return ((id=="Sweet" or id=="Spell") and halloweenSkinOwned(plr,id)) or SqueegeeSkins.ownedSet(plr)[id] == true
end

--[[
	Serialised in the list's own order, so the stored string is stable -- a
	profile that saves the same set in a different order every time is a diff
	nobody can read and a write that never settles.

	⚠ Round-tripping through here on LOAD is what drops an id that is not a skin
	any more: retiring one from the roster cannot leave a dead entry riding in
	every profile that ever owned it.
]]
function SqueegeeSkins.serialise(set: { [string]: boolean }): string
	local out = {}
	for _, s in ipairs(List) do
		-- ⚠ a pass kit is never stored: ownership is the pass, and a copy written
		-- down here would outlive a refund
		if set[s.id] and not s.pass then table.insert(out, s.id) end
	end
	return table.concat(out, ",")
end

--[[
	The one remote this feature has: a skin id going UP from the Squeegee Case.

	⚠ Created on the SERVER only. A client that made its own would get a local
	instance that never reaches anybody, and then a second one when the real one
	replicated in. Readers use WaitForChild.
]]
function SqueegeeSkins.remotes(): Folder
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local ui = ReplicatedStorage:WaitForChild("SealerUI")
	local folder = ui:FindFirstChild("Remotes")
	if not folder then
		if not RunService:IsServer() then return ui:WaitForChild("Remotes") :: Folder end
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ui
	end
	if RunService:IsServer() then
		-- SkinEquip carries a choice up; SkinBuy carries a purchase up. Both are
		-- validated on arrival -- see SqueegeeSkinService.
		for _, n in ipairs({ "SkinEquip", "SkinBuy", "SkinBuyRobux" }) do
			if not folder:FindFirstChild(n) then
				local r = Instance.new("RemoteEvent")
				r.Name = n
				r.Parent = folder
			end
		end
	end
	return folder :: Folder
end

--==[ APPLYING ]==============================================================

-- Everything this file ever added, and nothing else. Keyed off the attribute
-- rather than a name so a skin that reuses one of ToolBuilder's names -- which
-- it must not, but might -- still cannot delete the tool.
function SqueegeeSkins.strip(rig: Instance?)
	if not rig then return end
	for _, d in ipairs(rig:GetDescendants()) do
		if d:GetAttribute(MARK) then d:Destroy() end
	end
end

--[[
	Paint one part. Size is never written -- see rules 1 and 2 at the top of the
	file -- and neither is CFrame, so this cannot move a squeegee out of the
	player's hands however wrong the skin data is.
]]
local function paintOne(rig: Instance, name: string, p: Paint?)
	if not p then return end
	local part = rig:FindFirstChild(name)
	if not part or not part:IsA("BasePart") then return end
	-- the invisible plumbing stays invisible: Handle is Transparency 1 and
	-- colouring it buys nothing
	if part.Transparency >= 1 then return end
	part.Color = p.colour
	part.Material = p.material or SM
	part.Reflectance = p.reflect or 0
end

--[[
	Dress a rig, from bare or from any other skin.

	Standard is laid down first every time rather than only when it is the one
	asked for. A skin sets only the properties it cares about, so without a known
	starting point, going from Molten to Contractor Blue would leave the collar
	glowing Neon orange -- the property Contractor never mentions. One base, then
	the difference, is the only version of this that cannot rot as skins are added.
]]
function SqueegeeSkins.apply(rig: Instance?, id: string?): boolean
	if not rig or not rig:IsA("Model") then return false end
	local skin = ById[id or ""] or ById[SqueegeeSkins.Default]
	if not skin then return false end

	SqueegeeSkins.strip(rig)
	local base = ById[SqueegeeSkins.Default]
	for _, name in ipairs({ "Blade", "Head", "Collar", "Pole" }) do
		paintOne(rig, name, base.paint[name])
		paintOne(rig, name, skin.paint[name])
	end
	if skin.dress then skin.dress(rig :: Model) end
	applyVFX(rig, skin.id)
	rig:SetAttribute("Skin", skin.id)
	return true
end

-- The Rig inside a Squeegee tool, or nil for any other tool. Kept here so no
-- caller has to know that the visible squeegee is a child model rather than the
-- tool itself.
function SqueegeeSkins.rigOf(tool: Instance?): Model?
	if not tool or not tool:IsA("Tool") then return nil end
	if tool:GetAttribute("SealerTool") ~= "Squeegee" then return nil end
	local rig = tool:FindFirstChild("Rig")
	return if rig and rig:IsA("Model") then rig else nil
end

require(game.ReplicatedStorage.HalloweenSharedCosmetics).skins(SqueegeeSkins)

return SqueegeeSkins
