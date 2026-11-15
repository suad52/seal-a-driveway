--!strict
--[[
	Waypoint -- the gold "go here" marker: a ring on the ground, a chevron floating
	over it, and a line of dashes running to it from wherever the player is standing.

	Built on this client and parented into Workspace, so it exists for this player
	only -- nobody sees anybody else's.

	EVERY PIECE IS CanQuery = false, and that matters twice over: it keeps the
	marker out of the pour aim ray in DrivewayClient, and out of the blocker sweep
	in DrivewaySurface._findBlockers, which would otherwise punch a permanent hole
	in the mask of whatever slab it is drawn on. Both roads this can land on are
	tagged SealableDriveway, so that is not hypothetical.

	The billboard is AlwaysOnTop on purpose. Half of what this points at is round a
	corner or behind a hedge, and a marker you cannot see is no help in finding the
	thing it is marking.

	⚠️ THE TUTORIAL HAS ITS OWN COPY OF THIS. TutorialClient's showWorld/hideWorld
	draw the same picture and are deliberately NOT built on this module: they carry
	an escalation for a player who has stalled, a Highlight on the target slab and
	the sweep chevrons, none of which anything else wants -- and rewiring a
	1,900-line file that currently works was not a risk worth taking for the second
	caller. If a third one turns up, unify them here. Until then a change to the
	LOOK belongs in both places, and this note is the only thing that says so.
]]

local Waypoint = {}
Waypoint.__index = Waypoint

local GOLD = Color3.fromRGB(255, 205, 74)
local CREAM = Color3.fromRGB(255, 248, 226)
local INK = Color3.fromRGB(24, 26, 32)

-- Eight is enough to read as a line without becoming a carpet.
local DASHES = 8
--[[
	0.2 to break the surface -- the cylinder is 0.4 thick on its side -- and then
	0.15 to clear the sealer overlay, which draws 0.035 studs over the slab. Under
	that, the ring is painted over by the coat the player is laying and disappears
	exactly when they start doing the thing it is asking for.
]]
local RING_LIFT = 0.2 + 0.15
-- Below this the dashes are a carpet round the player's feet rather than a trail,
-- and the ring alone already says where to go.
local TRAIL_MIN = 16

local function decor(parent: Instance, name: string, size: Vector3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = GOLD
	p.Size = size
	p.Transparency = 1
	p.Parent = parent
	return p
end

local function outlined(parent: Instance, text: string, px: number, colour: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.Text = text
	l.TextSize = px
	l.TextColor3 = colour
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.Parent = parent
	local s = Instance.new("UIStroke")
	s.Color = INK
	s.Thickness = 3
	s.Parent = l
	return l
end

function Waypoint.new(name: string)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = workspace

	local ring = decor(folder, "Ring", Vector3.new(0.4, 11, 11))
	ring.Shape = Enum.PartType.Cylinder

	local dashes: { BasePart } = {}
	for i = 1, DASHES do
		dashes[i] = decor(folder, "Dash", Vector3.new(2.6, 0.15, 1.1))
	end

	local anchor = decor(folder, "Anchor", Vector3.new(0.2, 0.2, 0.2))

	local bb = Instance.new("BillboardGui")
	bb.Name = "Marker"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(260, 116)
	bb.Enabled = false
	bb.Parent = anchor

	local chevron = outlined(bb, "\u{25BC}", 62, GOLD)
	chevron.AnchorPoint = Vector2.new(0.5, 1)
	chevron.Position = UDim2.new(0.5, 0, 1, 0)
	chevron.Size = UDim2.fromOffset(260, 64)

	local cap = outlined(bb, "", 21, CREAM)
	cap.AnchorPoint = Vector2.new(0.5, 0)
	cap.Position = UDim2.new(0.5, 0, 0, 0)
	cap.Size = UDim2.fromOffset(260, 44)

	--[[
		The ground ray has to ignore the trail it is laying.

		CanQuery = false does NOT keep a part out of workspace:Raycast on this engine
		build (measured 2026-08-12 on 0.734), so without this filter each dash rides
		up onto whichever dash was drawn under it a frame ago and the trail climbs.
	]]
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { folder }
	rp.IgnoreWater = true

	return setmetatable({
		folder = folder,
		ring = ring,
		dashes = dashes,
		anchor = anchor,
		bb = bb,
		cap = cap,
		rp = rp,
	}, Waypoint)
end

--[[
	Drawn fresh every frame it is wanted, rather than set up once and left.

	The ring breathes, the chevron bobs and the dashes slide, so there is no resting
	state to leave behind -- and the trail is measured from where the player is
	STANDING, which is the one input that changes every frame anyway.
]]
function Waypoint:Show(spot: Vector3, caption: string, from: Vector3?)
	local t = os.clock()
	local bob = math.sin(t * 3.2) * 0.55

	self.bb.Enabled = true
	self.cap.Text = caption
	self.anchor.CFrame = CFrame.new(spot + Vector3.new(0, 7.4 + bob, 0))

	self.ring.Transparency = 0.35 + 0.18 * (0.5 + 0.5 * math.sin(t * 3.2))
	-- a cylinder's flat faces are on its X axis, so it is tipped on its side to lie down
	self.ring.CFrame = CFrame.new(spot.X, spot.Y + RING_LIFT, spot.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	local breathe = 10 + 1.6 * math.sin(t * 3.2)
	self.ring.Size = Vector3.new(0.4, breathe, breathe)

	local flat = if from then Vector3.new(spot.X - from.X, 0, spot.Z - from.Z) else nil
	local span = if flat then flat.Magnitude else 0
	if not flat or span < TRAIL_MIN then
		for _, d in ipairs(self.dashes) do d.Transparency = 1 end
		return
	end

	local dir = flat.Unit
	local slide = (t * 0.35) % 1
	for i, d in ipairs(self.dashes) do
		local f = ((i - 1) / DASHES + slide) % 1
		local at = (from :: Vector3) + dir * (6 + f * (span - 8))
		-- ride the ground rather than assuming it is flat
		local hit = workspace:Raycast(at + Vector3.new(0, 14, 0), Vector3.new(0, -40, 0), self.rp)
		local y = if hit then hit.Position.Y else spot.Y
		local foot = Vector3.new(at.X, y + 0.12, at.Z)
		d.CFrame = CFrame.lookAt(foot, foot + dir)
		-- brightest in the middle of the run, so the trail reads as moving rather
		-- than as eight separate marks
		d.Transparency = 0.25 + 0.6 * math.abs(f - 0.5)
	end
end

function Waypoint:Hide()
	self.bb.Enabled = false
	self.ring.Transparency = 1
	for _, d in ipairs(self.dashes) do d.Transparency = 1 end
end

function Waypoint:Destroy()
	self.folder:Destroy()
end

return Waypoint
