--!strict
--[[
	RigMarker -- the tag that says where you left your truck.

	A rig is twenty-four studs long and it is still easy to lose. You drive it up
	Maple Drive, get out to work a slab, walk two lots along on the end of the
	hose, and by the time the job pays out the truck is behind somebody's
	bungalow. Nothing on screen says which way, and "walk back and look" is a
	minute of nothing.

	So the truck labels itself the moment you are not in it: a blue YOUR TRUCK
	pill sat on a gold plate carrying the rig's own name and how far away it is,
	with an arrow hopping underneath.

	It is built as a STACK OF STICKERS rather than as one panel, because that is
	what makes it read as drawn rather than rendered: a plinth in a deeper shade
	of its own fill, the card on top of it, a pale shine across the card's
	shoulder, and the pill overlapping the whole thing from above. Every one of
	them wears the same thin black keyline, so the silhouette the tag cuts against
	the sky is one continuous line. Same four ideas as UIKit -- keyline, two-hue
	ramp, plinth, shine -- because this has to look like it came out of the same
	box as the rest of the interface.

	Two decisions carry the feature itself.

	  It is IN the world rather than drawn over it. AlwaysOnTop is off, so the
	  plate is depth-tested like any other object: park behind a bungalow and the
	  bungalow hides it, along the real edge of the roof rather than all at once.

	  That is the owner's call (2026-08-11: "make it to where it doesnt show if
	  its being covered by something") and it is a genuine trade, so do not
	  quietly put it back. A tag that cannot be seen through a wall cannot point
	  at a truck that is behind one -- the first build had it on for exactly that
	  reason. What switching it off buys is that the plate never floats over
	  scenery it is plainly behind, which is the thing that made it read as
	  stuck to the camera rather than as a sign hanging over a truck.

	  MissedHighlight's arrows still use AlwaysOnTop and should: they mark ground
	  the player is already standing on, so there is nothing for them to be
	  behind.

	  It fades out as you walk up to it. The tag answers "where is it"; standing
	  beside the truck has already answered that, and a plate hanging over the
	  reel while you work is clutter.

	Client-side, and only ever your own rig. Somebody else's truck is not the one
	you are looking for, and a depot with six labelled trucks in it is worse than
	a depot with none.
]]

local RigMarker = {}
RigMarker.__index = RigMarker

--[[
	UIKit's own ramps, copied rather than required.

	Nothing else in the DrivewaySealer pack reaches into SealerUI and one label is
	not worth turning that dependency round; MissedHighlight hardcodes its own
	tint for the same reason. These are the two-hue ENDS the kit's `ramp()`
	produces for T.gold and T.blue rather than the flat theme colours -- gold
	highlights into lemon and shades into orange, blue into sky and indigo. Keep
	them in step with UIKit by hand.
]]
local GOLD_TOP  = Color3.fromRGB(255, 245, 87)
local GOLD_BOT  = Color3.fromRGB(198, 123, 21)
local GOLD_DEEP = Color3.fromRGB(163, 96, 14)    -- the plinth the card sits on
local BLUE_TOP  = Color3.fromRGB(89, 212, 255)
local BLUE_BOT  = Color3.fromRGB(23, 88, 198)
local CREAM     = Color3.fromRGB(255, 250, 226)
local INK       = Color3.fromRGB(14, 16, 28)

--[[
	The plate at full size, in pixels, and the bands it is built from.

	A BillboardGui sized in OFFSET holds its size on screen however far away it
	is, which is exactly what a locator wants and the opposite of what a nameplate
	wants. Everything inside is sized in SCALE so the taper below moves the whole
	sticker instead of pulling the text off it -- which is why the layout is
	written as pixel bands and divided through once, here.
]]
local W, H = 214, 112
-- How wide the plate stands in the WORLD. The pixel pair above is the layout
-- grid the sticker is drawn on; this is the thing that decides how big it looks.
local PLATE_W = 7

local function band(top: number, height: number): (number, number)
	return top / H, height / H
end

local PILL_Y, PILL_H = band(0, 26)      -- the eyebrow, overlapping the card
local CARD_Y, CARD_H = band(22, 58)
local PLINTH_Y = 28 / H                 -- same size as the card, six pixels down
local ARROW_Y, ARROW_H = band(82, 28)
local PILL_W = 0.66

--[[
	NEAR ONLY, and one fixed size (2026-08-12, owner's call).

	This was the other way round: hidden inside 14 studs and drawn from there out
	to four thousand, because it was written as a LOCATOR -- the thing that finds a
	truck you have lost. It is a nameplate now. It appears when you are at your
	rig and is gone the rest of the time.

	Within NEAR it is fully drawn; past GONE it is not there at all; the ramp
	between the two is what stops it blinking as you step across a line, and it is
	the same reason the old pair had a ramp.

	NEAR is Shell's own RIG_NEAR, deliberately. That is the distance the rig row on
	the HUD appears at, so the plate over the truck and the readout in the corner
	turn up together instead of at two unexplained ranges.

	⚠ What this gives up: you can no longer find a truck you parked out of sight.
	The rig row still carries the distance once you are inside RIG_NEAR, and the
	dealership can still call one up, but nothing points across the map any more.
]]
local NEAR, GONE = 70, 95

-- Shell's MPH_PER_STUD is `0.28 * 2.23694`; 0.28 is the metres in a stud, and
-- this is that same conversion stopping one step earlier. Quoting the distance
-- in raw studs would put a unit on screen that nothing else in the game uses.
local METRES_PER_STUD = 0.28

--[[
	Two motions, deliberately out of step.

	The plate floats slowly in world space and the arrow hops on its own faster
	beat. Two rhythms that do not line up read as a cartoon; one rhythm reads as a
	tween. Neither fades, so the tag is equally legible at every point in the
	cycle rather than blinking out at the bottom of one.
]]
local BOB, BOB_RATE = 0.22, 1.9    -- studs of float, radians a second
local HOP, HOP_RATE = 0.035, 4.2   -- fraction of the plate's height

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end

--[[
	The black keyline everything here wears.

	ApplyStrokeMode matters more than it looks: Border outlines the object's
	RECTANGLE, Contextual outlines the GLYPHS of a text object -- so a label given
	Border gets a box drawn round an otherwise invisible frame instead of an edge
	on its letters. And only the FIRST UIStroke on an instance applies, which is
	why there is exactly one of these per object.
]]
local function outline(inst: Instance, thickness: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = INK
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.ApplyStrokeMode = if inst:IsA("TextLabel")
		then Enum.ApplyStrokeMode.Contextual
		else Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

--[[
	The two-hue ramp: a fill into a warmer or cooler fill, never into black.

	A UIGradient MULTIPLIES its background, so it cannot express anything brighter
	than the base and a keypoint over 1.0 is out of range and throws outright. The
	base is therefore set to the LIGHTER of the two hues and the bottom end is
	written as a ratio against it, which is the only route the API allows to a
	ramp whose top is lighter than the colour asked for. Same trick as
	UIKit.gradient.
]]
local function rampOn(frame: Frame, top: Color3, bottom: Color3)
	frame.BackgroundColor3 = top
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
		ColorSequenceKeypoint.new(1, Color3.new(
			bottom.R / top.R, bottom.G / top.G, bottom.B / top.B)),
	})
	g.Parent = frame
	return g
end

local function line(parent: Instance, font: Enum.Font, size: UDim2, pos: UDim2): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = size
	t.Position = pos
	t.Font = font
	t.TextColor3 = CREAM
	--[[
		TextScaled and NOTHING ELSE -- in particular, do not write TextWrapped after
		it.

		TextScaled turns wrapping on, and a wrapped scaled label can break a long
		word in HALF rather than shrink further, so switching wrapping back off
		looks like the careful thing to do. It is not: **writing TextWrapped clears
		TextScaled**. Measured live -- every label on this plate came back
		`TextScaled = false, TextSize = 8` in a 214x32 box, i.e. the whole tag was
		rendering at a quarter of the size it was laid out for, and quietly, because
		there is no error and TextFits still reads true.

		The half-word break it was guarding against cannot happen here anyway: the
		longest single word any of these lines carries is eight characters, which
		fits the plate's width at any size TextScaled would pick.
	]]
	t.TextScaled = true
	t.ZIndex = 3
	t.Parent = parent

	--[[
		TextScaled will fill every pixel it is given, so the margin has to be real
		padding: without it a long rig name renders touching both keylines.

		In SCALE, not pixels, and that is load-bearing now the plate is sized in
		studs. The frame's pixel width falls off with distance; a fixed 14px margin
		does not, so at the far end of the range the two of them together were most
		of the plate and TextScaled had almost nothing left to draw into. As a
		fraction it holds the same proportion at every range. 14 of the 214 the
		layout is written against.
	]]
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(14 / W, 0)
	pad.PaddingRight = UDim.new(14 / W, 0)
	pad.Parent = t
	return t
end

function RigMarker.new(parent: Instance)
	local pin = Instance.new("Part")
	pin.Name = "RigTag"
	pin.Anchored = true
	pin.CanCollide = false
	--[[
		It must never answer a raycast. The player pours and spreads by pointing
		THROUGH the world, and a box floating over the cab that could be hit would
		be a hole in the sky above their own truck. Same rule, and the same reason,
		as MissedHighlight's markers.
	]]
	pin.CanQuery = false
	pin.CanTouch = false
	pin.CastShadow = false
	pin.Transparency = 1
	pin.Size = Vector3.new(0.2, 0.2, 0.2)
	pin.Parent = parent

	local gui = Instance.new("BillboardGui")
	gui.Name = "Tag"
	--[[
		Off on purpose -- see the header before turning it back on.

		⚠️ Worth knowing before you wonder why an edit "did nothing": screen_capture
		cannot photograph an AlwaysOnTop layer AT ALL. With this false the tag shows
		up in a capture; set it true and it vanishes from every screenshot while
		still being perfectly visible in game.
	]]
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Just past the fade, so the engine stops drawing it at about the point the
	-- ramp has taken it to nothing anyway. It used to be 4000 -- far enough to
	-- find a lost truck from, which is not what this is for any more.
	gui.MaxDistance = GONE + 15
	--[[
		SIZED IN STUDS, which is what actually makes it hold still.

		This was offset -- pixels -- and offset is the one that GROWS. A pixel size is
		constant on screen, so as you walk away the truck shrinks under it and the
		plate does not: by the far end of the range it was a placard bigger than the
		vehicle it was labelling. Removing the taper last time made that worse, not
		better, because the taper had been the only thing pulling against it.

		Scale on a BillboardGui is world units, so the engine perspective-divides it
		like anything else in the scene and it stays the same size RELATIVE TO THE
		TRUCK at every distance -- a sign bolted to the cab rather than a HUD element
		pinned over it. Nothing rewrites it per frame; there is nothing left to taper.

		7 studs against a 22-stud truck, keeping the 214:112 the layout is drawn at.
		Everything inside is in SCALE already (see the note over W) so the whole
		sticker follows this one number.
	]]
	gui.Size = UDim2.fromScale(PLATE_W, PLATE_W * H / W)
	gui.Adornee = pin
	gui.Enabled = false
	gui.Parent = pin

	--[[
		Everything that fades, collected as it is built.

		The resting value is READ OFF THE OBJECT rather than written down twice, so
		the shine's 0.78 and the distance line's 0.10 live in exactly one place --
		where they are authored -- and adding a new layer to the sticker cannot
		leave it solid while the rest of the plate fades out from under it.
	]]
	local fades: { { any } } = {}
	local function fade(inst: Instance, prop: string)
		local any_: any = inst
		fades[#fades + 1] = { inst, prop, any_[prop] }
	end

	--[[
		The plinth, and it is deep gold rather than a grey shadow.

		The kit's buttons sit on a darker shade of their OWN fill; a blurred drop
		shadow is the one thing a cartoon does not do. Outlined like everything
		else, so what the tag cuts against a bright sky is a single black keyline
		rather than a card with a smudge under it.
	]]
	local plinth = Instance.new("Frame")
	plinth.Name = "Plinth"
	plinth.BackgroundColor3 = GOLD_DEEP
	plinth.BorderSizePixel = 0
	plinth.Size = UDim2.fromScale(1, CARD_H)
	plinth.Position = UDim2.fromScale(0, PLINTH_Y)
	plinth.ZIndex = 0
	plinth.Parent = gui
	corner(plinth, 13)
	fade(plinth, "BackgroundTransparency")
	fade(outline(plinth, 3), "Transparency")

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BorderSizePixel = 0
	card.Size = UDim2.fromScale(1, CARD_H)
	card.Position = UDim2.fromScale(0, CARD_Y)
	card.ZIndex = 1
	card.Parent = gui
	corner(card, 13)
	rampOn(card, GOLD_TOP, GOLD_BOT)
	fade(card, "BackgroundTransparency")
	fade(outline(card, 3), "Transparency")

	-- The kit's pale shine across the shoulder of a filled surface. Inset on all
	-- sides so it reads as light on the card rather than as a second card.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0.78
	shine.BorderSizePixel = 0
	shine.Size = UDim2.fromScale(0.90, 0.30)
	shine.Position = UDim2.fromScale(0.05, 0.10)
	shine.ZIndex = 2
	shine.Parent = card
	corner(shine, 8)
	fade(shine, "BackgroundTransparency")

	--[[
		Cream letters with a black keyline, not ink letters on gold.

		This is the house voice -- every readout on the HUD is an outlined glyph
		over the world -- and it is also the only treatment that survives the plate
		shrinking with distance: a thin dark letter on a saturated fill greys out
		long before an outlined one does.
	]]
	local name = line(card, Enum.Font.LuckiestGuy,
		UDim2.fromScale(1, 0.56), UDim2.fromScale(0, 0.04))
	name.Name = "RigName"
	name.Text = "SEALCOAT RIG"
	fade(name, "TextTransparency")
	fade(outline(name, 2.4), "Transparency")

	local dist = line(card, Enum.Font.FredokaOne,
		UDim2.fromScale(1, 0.32), UDim2.fromScale(0, 0.60))
	dist.Name = "Distance"
	dist.TextTransparency = 0.10
	dist.Text = ""
	fade(dist, "TextTransparency")
	fade(outline(dist, 1.8), "Transparency")

	--[[
		The eyebrow, and it is a separate sticker sat ON the card rather than a line
		inside it.

		It is also what the tag still says once it is too far away to read a rig
		name: a blue pill in a gold world means one thing, and it means it at a
		glance from the far end of the road.
	]]
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.BorderSizePixel = 0
	pill.Size = UDim2.fromScale(PILL_W, PILL_H)
	pill.Position = UDim2.fromScale((1 - PILL_W) * 0.5, PILL_Y)
	pill.ZIndex = 4
	pill.Parent = gui
	-- A radius past half the height is clamped to half, which is how you ask for
	-- a capsule rather than a rounded rectangle.
	corner(pill, 999)
	rampOn(pill, BLUE_TOP, BLUE_BOT)
	fade(pill, "BackgroundTransparency")
	fade(outline(pill, 2.6), "Transparency")

	local eyebrow = line(pill, Enum.Font.LuckiestGuy,
		UDim2.fromScale(1, 0.72), UDim2.fromScale(0, 0.14))
	eyebrow.Name = "Eyebrow"
	eyebrow.Text = "YOUR TRUCK"
	eyebrow.ZIndex = 5
	fade(eyebrow, "TextTransparency")
	fade(outline(eyebrow, 2.0), "Transparency")

	--[[
		The pointer, in GothamBlack rather than the display face.

		A glyph is a gamble on a custom font -- a missing codepoint renders as a
		blank box, silently -- and this exact arrow in this exact font is already
		proven in MissedHighlight. It wears a UIStroke rather than the built-in
		TextStroke so its keyline is the same weight as everything else's.
	]]
	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromScale(1, ARROW_H)
	arrow.Position = UDim2.fromScale(0, ARROW_Y)
	arrow.Font = Enum.Font.GothamBlack
	arrow.Text = "\u{25BC}"
	--[[
		The ramp's DEEP end, not its light one.

		The card can afford lemon because it is two hundred pixels of it; a
		fourteen-pixel glyph in the same colour sitting on a white garage wall is
		just its own black keyline with nothing inside. The saturated orange reads
		against pale walls and against sky, which between them is everywhere this
		thing gets used.
	]]
	arrow.TextColor3 = GOLD_BOT
	-- TextScaled last and alone; see `line` above for why TextWrapped must not
	-- follow it
	arrow.TextScaled = true
	arrow.ZIndex = 2
	arrow.Parent = gui
	fade(arrow, "TextTransparency")
	-- heavier than the plate's own keyline: it is thickening a thin glyph, not
	-- edging a slab
	fade(outline(arrow, 3.2), "Transparency")

	return setmetatable({
		pin = pin,
		gui = gui,
		name = name,
		dist = dist,
		arrow = arrow,
		fades = fades,
		clock = 0,
		-- last values actually written, so a plate that is not changing costs
		-- nothing but the two idle motions
		alpha = -1,
		scale = -1,
		shownName = "",
		shownDist = -1,
	}, RigMarker)
end

-- One number moves every layer. Written together or the card fades out from
-- under text that is still solid.
function RigMarker:_fade(a: number)
	if math.abs(a - self.alpha) < 0.01 then return end
	self.alpha = a
	for _, f in ipairs(self.fades) do
		local target: any = f[1]
		-- f[3] is the resting transparency, so a layer authored at 0.78 tops out
		-- there instead of going opaque
		target[f[2]] = 1 - (1 - f[3]) * a
	end
end

--[[
	Called every frame with where the truck is, what it is called, and where the
	player is standing.

	`at` is already the point to hover over -- the caller owns the height, because
	the caller is the one that knows how tall this particular rig is. Nil for any
	of the three means there is nothing to point at and the plate goes away.
]]
function RigMarker:Update(dt: number, at: Vector3?, rigName: string?, from: Vector3?)
	self.clock += dt

	if not at or not from then
		if self.gui.Enabled then self.gui.Enabled = false end
		return
	end

	--[[
		Measured flat, at the player's own height.

		The plate floats nine studs over the cab and neither the fade nor the readout
		has any business counting that: from beside the truck most of the
		straight-line distance to the tag IS the lift, so the closer you walked the
		less the number would fall. This is what a player means by how far away it
		is -- how far there is to walk.
	]]
	local away = Vector3.new(at.X - from.X, 0, at.Z - from.Z).Magnitude
	-- 1 inside NEAR, 0 beyond GONE. The subtraction runs the other way round from
	-- the old locator ramp, which is the whole of the inversion.
	local a = math.clamp((GONE - away) / (GONE - NEAR), 0, 1)
	if a <= 0.02 then
		if self.gui.Enabled then self.gui.Enabled = false end
		return
	end

	self.pin.CFrame = CFrame.new(at)
	self.gui.StudsOffset = Vector3.new(0, BOB * math.sin(self.clock * BOB_RATE), 0)
	local hop = HOP * (0.5 + 0.5 * math.sin(self.clock * HOP_RATE))
	self.arrow.Position = UDim2.fromScale(0, ARROW_Y + hop)

	local want = rigName or "SEALCOAT RIG"
	if want ~= self.shownName then
		self.shownName = want
		self.name.Text = want
	end

	local metres = math.floor(away * METRES_PER_STUD + 0.5)
	if metres ~= self.shownDist then
		self.shownDist = metres
		self.dist.Text = string.format("%d m away", metres)
	end

	-- The plate is never resized. It was tapered from 1.00 down to 0.62 across a
	-- 90-to-420 stud run; that range no longer exists, and a nameplate you only
	-- ever see up close has nothing to taper for.

	self:_fade(a)
	if not self.gui.Enabled then self.gui.Enabled = true end
end

function RigMarker:Destroy()
	self.pin:Destroy()
end

return RigMarker
