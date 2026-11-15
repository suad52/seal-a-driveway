--!strict
--[[
	MissedHighlight -- finding the last few percent.

	The end of a driveway is not a shrinking patch you can see. It is a scatter
	of single cells along the kerb line, in the ruts, and around whatever the
	mask cut out -- two-inch specks of grey on a black surface, at an angle where
	the sealer's own specular sheen is the brightest thing on screen. Players
	walked finished-looking driveways for a minute hunting them, and the honest
	description of that is not "a challenge", it is "the bar looks broken".

	So the last stretch marks itself. Past Config.HighlightAt the bare patches
	are found (SurfaceGrid:MissedPatches), clustered, and each one gets a marker.

	--[ why none of it can be drawn INTO the surface ]-------------------------

	The obvious implementation is to tint the unsealed cells in the texture, and
	it does not work. Bare cells are exactly the ones about to be covered: the
	moment a bead rolls over one the sealer sheet is drawn on top and the hint
	disappears under the very thing the player was aiming at. Worse, the sheet is
	a displaced MESH -- loose sealer stands up to Config.LiquidMaxHeight proud of
	the slab -- so a decal or a tint lying ON the driveway plane is physically
	underneath any sealer near it.

	Everything here therefore sits ABOVE that plane, by a margin measured off
	LiquidMaxHeight rather than guessed, and the arrow over each marker is an
	AlwaysOnTop billboard so it draws over the sealer, over the truck, and over
	the kerb from anywhere on the lot. That is what makes it findable rather than
	merely present.
]]

local Config = require(script.Parent.Config)

local MissedHighlight = {}
MissedHighlight.__index = MissedHighlight

--[[
	A soft amber rather than a hot one.

	The first pass was near-white gold on full Neon with a bright lamp under it,
	and up to twenty-four of those on one driveway lit the whole slab -- which
	works against the point of the feature twice over: it washes out the very
	surface you are reading for missed spots, and a marker that glares is harder
	to locate precisely than one that glows.
]]
local TINT = Color3.fromRGB(226, 176, 82)
local BEAM_HEIGHT = 3.2

--[[
	How far above the driveway everything floats.

	Derived, not typed in: LiquidMaxHeight is the tallest a pool of loose sealer
	can stand, so anything below it can be swallowed by a puddle. The extra is
	clearance for the fact that a marker sitting exactly ON another surface
	z-fights with it.
]]
local function lift(): number
	return Config.LiquidMaxHeight + 0.10
end

local function part(name: string, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	-- Never intercept the aim ray. The player points THROUGH these to pour and
	-- to spread, and a marker that ate the raycast would make the one patch it
	-- is pointing at the one patch you cannot work on.
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = TINT
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function newMarker(): { model: Model, pad: Part, beam: Part, gui: BillboardGui, arrow: TextLabel }
	local model = Instance.new("Model")
	model.Name = "MissedSpot"

	-- The footprint of the patch, so you can see how much is left as well as
	-- where it is. Thin and flat: it is a stain of light on the slab.
	local pad = part("Pad", model)
	pad.Size = Vector3.new(1, 0.06, 1)
	pad.Transparency = 0.68

	-- Visible from across the driveway when the pad itself is edge-on.
	local beam = part("Beam", model)
	beam.Size = Vector3.new(0.18, BEAM_HEIGHT, 0.18)
	beam.Transparency = 0.58

	-- Just enough to separate the beam from a black driveway at night. This was
	-- the loudest part of the first pass: two dozen 9-stud lamps at brightness
	-- 1.6 overlap into a floodlit slab, and bloom on top of that buried the
	-- half-sealed cells the markers are pointing at.
	local glow = Instance.new("PointLight")
	glow.Color = TINT
	glow.Range = 5.5
	glow.Brightness = 0.45
	glow.Shadows = false
	glow.Parent = beam

	--[[
		AlwaysOnTop, and that is the whole point of the billboard.

		The pad and the beam are real geometry: stand a truck between you and a
		patch, or work a slab that dips, and they are behind something. This is
		the layer that cannot be hidden -- including by the black, which is what
		it is here to solve.
	]]
	local gui = Instance.new("BillboardGui")
	gui.Name = "Tag"
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(44, 44)
	gui.MaxDistance = 220
	gui.Adornee = beam
	gui.Parent = beam

	local arrow = Instance.new("TextLabel")
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromScale(1, 1)
	arrow.Font = Enum.Font.GothamBlack
	arrow.Text = "\u{25BC}"
	arrow.TextColor3 = TINT
	arrow.TextScaled = true
	-- The arrow keeps most of its contrast: it is the layer that has to stay
	-- findable over the black, and it is 44 pixels rather than a light source, so
	-- it costs nothing in glare. Only the fill comes down with the rest.
	arrow.TextTransparency = 0.12
	arrow.TextStrokeColor3 = Color3.fromRGB(24, 18, 4)
	arrow.TextStrokeTransparency = 0.35
	arrow.Parent = gui

	return { model = model, pad = pad, beam = beam, gui = gui, arrow = arrow }
end

function MissedHighlight.new(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "MissedSpots"
	folder.Parent = parent
	return setmetatable({
		folder = folder,
		pool = {},          -- every marker ever built, parked or not
		free = {},          -- the parked ones, ready to be taken
		-- patch id -> marker. THE fix: a marker belongs to a piece of GROUND, not
		-- to a position in the scan's output. See MissedHighlight:_place.
		byId = {},
		shownIds = {},      -- insertion-ordered ids, so the pulse has something to walk
		clock = 0,
		-- when a scan LAST ACTUALLY RAN (os.clock), as opposed to when one was last
		-- asked for. This is what RESCAN_FLOOR is measured from; see :Update.
		lastScan = 0,
		surface = nil :: any,
		active = false,
	}, MissedHighlight)
end

function MissedHighlight:_take()
	local mk = table.remove(self.free)
	if not mk then
		mk = newMarker()
		self.pool[#self.pool + 1] = mk
	end
	mk.model.Parent = self.folder
	return mk
end

function MissedHighlight:_release(mk)
	mk.model.Parent = nil
	self.free[#self.free + 1] = mk
end

--[[
	Bind markers to PATCHES, and keep the ones already on screen.

	Two separate faults produced the same complaint -- "they do not go away
	properly and new ones appear out of nowhere" -- and both are here rather than
	in the scan:

	 1. Markers were bound by ARRAY POSITION: marker N drew list[N]. The list is
	    re-sorted by distance from the player every rescan, so N meant different
	    ground each time and nearly every marker teleported twice a second.
	    Measured on a walk up a driveway: 460 re-assignments in 20 rescans.
	 2. The list was cut at HighlightMaxSpots by DISTANCE, so a patch fell off the
	    end because the player walked, not because it was sealed -- 81 unearned
	    disappearances and 81 unearned reappearances over the same walk.

	So: identity comes from the patch (`spot.id`, the scan's own cell block), and
	membership is STICKY -- a patch already being shown keeps its marker for as
	long as it is still bare and still a candidate, and only the leftover markers
	go to the nearest new patches. A marker now disappears when, and only when,
	the ground under it has actually been sealed.
]]
function MissedHighlight:_place(spots, maxShown: number)
	local candidate = {}
	for _, spot in ipairs(spots) do candidate[spot.id] = spot end

	-- 1. let go of anything whose ground is no longer bare
	for id, mk in pairs(self.byId) do
		if not candidate[id] then
			self:_release(mk)
			self.byId[id] = nil
		end
	end

	--[[
		2. Everything still bare KEEPS its marker -- not "if it is still near enough".

		This is what makes a disappearance mean something. Ranking the held ones by
		distance and cutting at the cap reintroduces the whole bug at one remove: a
		marker would still vanish because the player walked toward something else,
		and from the other end of the driveway that is indistinguishable from the
		patch having been sealed. Held markers can never outnumber the cap anyway --
		they were placed under it -- so the nearest-first order below only decides
		which NEW patches get the slots that are actually free.
	]]
	local keep = {}
	for _, spot in ipairs(spots) do
		if self.byId[spot.id] then keep[#keep + 1] = spot end
	end
	-- a cap lowered at runtime is the only way this can overrun; drop the farthest
	for i = #keep, maxShown + 1, -1 do keep[i] = nil end
	-- anything still held but squeezed out by the cap goes back to the pool
	local kept = {}
	for _, spot in ipairs(keep) do kept[spot.id] = true end
	for id, mk in pairs(self.byId) do
		if not kept[id] then
			self:_release(mk)
			self.byId[id] = nil
		end
	end

	-- 3. spend what is left on the nearest patches not already marked
	local show = keep
	for _, spot in ipairs(spots) do
		if #show >= maxShown then break end
		if not self.byId[spot.id] and not kept[spot.id] then
			show[#show + 1] = spot
			kept[spot.id] = true
		end
	end

	table.clear(self.shownIds)
	for _, spot in ipairs(show) do
		local mk = self.byId[spot.id]
		if not mk then
			mk = self:_take()
			self.byId[spot.id] = mk
		end
		self.shownIds[#self.shownIds + 1] = spot.id
		-- Rotation from the slab, position from the patch, so a pad lies flat on
		-- a driveway however that driveway is turned or pitched.
		local base = (spot.cf - spot.cf.Position) + spot.pos
		local up = lift()

		--[[
			A single stray cell is 0.16 studs across and would draw a pad nobody can
			see, so each axis has a floor. Kept low, and applied per axis rather than
			as one square minimum: a half-sealed kerb is a long thin patch, and
			squaring it up would throw a 1.5-stud pad out over the lawn and point the
			player at ground that is not theirs to seal. The beam and the arrow are
			what make a speck findable; the pad only has to show its shape.
		]]
		mk.pad.Size = Vector3.new(math.max(spot.w, 0.8), 0.06, math.max(spot.h, 0.8))
		mk.pad.CFrame = base * CFrame.new(0, up, 0)
		mk.beam.CFrame = base * CFrame.new(0, up + BEAM_HEIGHT * 0.5, 0)
	end
end

function MissedHighlight:_pulse()
	local k = 0.5 + 0.5 * math.sin(os.clock() * 3.6)
	for _, id in ipairs(self.shownIds) do
		local mk = self.byId[id]
		if not mk then continue end
		mk.pad.Transparency = 0.60 + 0.16 * k
		mk.beam.Transparency = 0.50 + 0.20 * k
		-- the arrow bobs rather than fading, so it stays legible at the bottom
		-- of its cycle instead of blinking out
		mk.gui.StudsOffset = Vector3.new(0, BEAM_HEIGHT * 0.5 + 0.55 + 0.35 * k, 0)
	end
end

--[[
	The floor under the rescan rate, for the asks that are not on a clock.

	Config.HighlightRescan meters the steady state, but it was never the only
	thing that could ask for a scan. Update also rescans when the slab it is
	handed changes, and when it wakes back up -- and both of those come from the
	picker, which re-picks every frame off the cursor ray, the blade ray and the
	truck bar. So a pick that oscillated between two slabs, or a `want` that
	flickered off and straight back on, bought a full-grid scan EVERY OTHER
	FRAME: 1.0 ms and seven table allocations a go on a 120k-cell grid at 4%
	bare, to re-place markers that had not moved.

	No two scans may now fall closer together than this, whichever term asked for
	one. Small enough that stepping onto a new driveway still lights it up while
	you are looking down at it; large enough that a flapping pick cannot outrun
	it.
]]
local RESCAN_FLOOR = 0.15

--[[
	Called every frame with whatever slab the player is standing on.

	The scan behind this walks the whole grid, so it is metered two ways: it only
	runs at all inside the last few percent of a job, and only a couple of times
	a second even then. Between rescans the markers simply pulse, which costs
	nothing and is what sells them as live.

	Three ways, strictly: the two above are what the scan is FOR, and RESCAN_FLOOR
	just above is the floor under the asks that arrive off the clock.
]]
function MissedHighlight:Update(dt: number, surface: any, coverage: number, from: Vector3?)
	local want = surface ~= nil and surface.ready and not surface.completed
		and coverage >= Config.HighlightAt and coverage < Config.CompleteAt
	if not want then
		if self.active then self:Clear() end
		return false
	end

	self.clock -= dt

	--[[
		The clock is the cadence; RESCAN_FLOOR is the floor under everything else.

		Only the clock term rate-limits itself, so the two picker-driven terms get
		the floor put under them here. Deferred, never dropped: neither term is
		cleared until the scan actually runs, so the ask survives to the first frame
		past the floor and a slab the player has genuinely just walked onto still
		gets its markers within a fraction of a step.
	]]
	local now = os.clock()
	local asked = not self.active or self.surface ~= surface
	if (asked and now - self.lastScan >= RESCAN_FLOOR) or self.clock <= 0 then
		self.clock = Config.HighlightRescan
		self.lastScan = now
		self.surface = surface
		self.active = true
		-- Nearest first, so a cap that runs out spends its markers on the patches
		-- within reach rather than on the far end of a road slab.
		-- Scan wider than we draw, so the sticky pass above has somewhere to be
		-- sticky FROM; see Config.HighlightScanSpots.
		self:_place(surface:MissedSpots(Config.HighlightScanSpots, from),
			Config.HighlightMaxSpots)
	end
	self:_pulse()
	return true
end

function MissedHighlight:Clear()
	for _, mk in ipairs(self.pool) do
		mk.model.Parent = nil
	end
	-- Every marker is parked, so every marker is free again. Rebuilt wholesale
	-- rather than appended to: a stale `free` holding duplicates would hand the
	-- same marker to two patches and one of them would silently draw nothing.
	table.clear(self.free)
	for _, mk in ipairs(self.pool) do self.free[#self.free + 1] = mk end
	table.clear(self.byId)
	table.clear(self.shownIds)
	self.active = false
	self.surface = nil
end

function MissedHighlight:Destroy()
	self.folder:Destroy()
	self.pool = {}
end

return MissedHighlight
