--!strict
--[[
	HoseRig -- the pressure hose between the reel and the wand.

	Two separate things are going on, and keeping them apart is what makes this
	tractable:

	  The *limit* is real physics. A RopeConstraint from the reel outlet to the
	  player's root, at the full length of the hose, is what actually stops them
	  walking to the next street. Letting the solver own the anchor means it
	  still holds when the player sprints, falls, or is shoved -- none of which a
	  script clamping CFrames survives cleanly.

	  The *look* is pure presentation. A chain of segments is laid along a
	  sagging curve each frame and dropped onto whatever is underneath, so slack
	  pools on the driveway instead of hanging in the air. It has no physics of
	  its own; a rope of thirty jointed parts dragged behind a running player is
	  a reliable way to make a place unplayable.

	Paid-out length comes off fast and goes back on slowly. Walking away drags it
	off the drum instantly; walking back lets the drum take it in at
	Config.HoseRewindRate, which is set below walk speed so slack still pools on
	the ground while you are moving and only draws in once you slow down.
]]

local Config = require(script.Parent.Config)

local HoseRig = {}
HoseRig.__index = HoseRig

local MIN_SLACK = 3.5   -- studs of hose that never pull straight

--[[
	Exposed because Out() has this subtracted and any MAXIMUM shown beside it must
	have it subtracted too.

	The drum's own length is the wrong denominator: paidOut is capped at maxLength,
	so Out() tops out at maxLength - MIN_SLACK, and a readout dividing that by the
	raw length could never reach full. On a 96-stud reel it sat at "92/96" with the
	hose pulled as far as the rope would allow, and the bar beside it stopped at
	96%. RigController is what reports both halves, so it is what needs this.
]]
HoseRig.MinSlack = MIN_SLACK

function HoseRig.new(parent: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "SealerHose"
	folder.Parent = parent

	local segments: { Part } = {}
	for i = 1, Config.HoseSegments do
		local p = Instance.new("Part")
		p.Name = "HoseSeg" .. i
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(1, Config.HoseRadius * 2, Config.HoseRadius * 2)
		p.Color = Config.HoseColor
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Transparency = 1
		p.Parent = folder
		segments[i] = p
	end

	-- Knuckles over the seams. Without them every bend in the hose shows a
	-- wedge of daylight where two cylinder ends meet at an angle.
	local joints: { Part } = {}
	for i = 1, Config.HoseSegments - 1 do
		local p = Instance.new("Part")
		p.Name = "HoseJoint" .. i
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(Config.HoseRadius * 2, Config.HoseRadius * 2, Config.HoseRadius * 2)
		p.Color = Config.HoseColor
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Transparency = 1
		p.Parent = folder
		joints[i] = p
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	return setmetatable({
		folder = folder,
		segments = segments,
		joints = joints,
		params = params,
		outlet = nil :: BasePart?,
		hoseEnd = nil :: BasePart?,
		endPos = nil :: Vector3?,   -- stands in for hoseEnd while winding in
		retracting = false,
		root = nil :: BasePart?,
		rope = nil :: RopeConstraint?,
		ropeA0 = nil :: Attachment?,
		ropeA1 = nil :: Attachment?,
		-- Per rig, not per Config: the three trucks carry very different drums,
		-- and Config.HoseMaxLength is only the fallback for one with no catalogue
		-- entry. Set by Deploy.
		maxLength = Config.HoseMaxLength,
		paidOut = MIN_SLACK,
		tension = 0,
		chord = 0,
		deployed = false,
		spin = 0,
		points = table.create(Config.HoseSegments + 1),
		groundHeights = table.create(Config.HoseSegments + 1),
		groundClock = 0,
		groundA = nil :: Vector3?,
		groundB = nil :: Vector3?,
	}, HoseRig)
end

--==[ DEPLOY / STOW ]=========================================================

function HoseRig:Deploy(outlet: BasePart, hoseEnd: BasePart, root: BasePart,
	ignore: { Instance }, maxLength: number?)
	self:Stow()
	self.maxLength = maxLength or Config.HoseMaxLength
	self.outlet = outlet
	self.hoseEnd = hoseEnd
	self.endPos = nil
	self.retracting = false
	self.root = root
	self.deployed = true
	-- Measured to the player, not to the wand. The wand's rig is anchored in its
	-- own local space and sits at the world origin until something poses it, so
	-- reading it here can pay out the length of the map on the first frame.
	self.paidOut = math.clamp((outlet.Position - root.Position).Magnitude + MIN_SLACK,
		MIN_SLACK, self.maxLength)

	local ignoreList = table.clone(ignore)
	table.insert(ignoreList, self.folder)
	self.params.FilterDescendantsInstances = ignoreList

	--[[
		The rope is built here on the client rather than on the server. The player
		owns their own character's physics, so a locally-created constraint is the
		one that will actually be enforced without a round trip -- and a hard stop
		that arrives 80ms late reads as rubber-banding.
	]]
	local a0 = Instance.new("Attachment")
	a0.Name = "HoseAnchor"
	a0.Parent = outlet

	local a1 = Instance.new("Attachment")
	a1.Name = "HoseHeld"
	a1.Position = Vector3.new(0, -0.5, 0)
	a1.Parent = root

	local rope = Instance.new("RopeConstraint")
	rope.Name = "HoseLimit"
	rope.Attachment0 = a0
	rope.Attachment1 = a1
	rope.Length = self.maxLength
	rope.Restitution = 0      -- no bounce; walking into the end should just stop you
	rope.Visible = false
	rope.Parent = outlet

	self.ropeA0, self.ropeA1, self.rope = a0, a1, rope
end

--[[
	The wand has gone back on the reel. The hose is not simply switched off: the
	free end is released from the wand and reeled home over the next moment, so
	the player sees the thing they were just holding get wound in.
]]
function HoseRig:BeginRetract()
	if not self.deployed or not self.hoseEnd then
		self:Stow()
		return
	end
	self.endPos = self.hoseEnd.Position
	self.hoseEnd = nil
	self.retracting = true
	if self.rope then self.rope:Destroy() end
	if self.ropeA1 then self.ropeA1:Destroy() end
	self.rope, self.ropeA1 = nil, nil
end

function HoseRig:Stow()
	self.deployed = false
	self.retracting = false
	self.outlet, self.hoseEnd, self.root, self.endPos = nil, nil, nil, nil
	if self.rope then self.rope:Destroy() end
	if self.ropeA0 then self.ropeA0:Destroy() end
	if self.ropeA1 then self.ropeA1:Destroy() end
	self.rope, self.ropeA0, self.ropeA1 = nil, nil, nil
	self.tension = 0
	self.groundA, self.groundB = nil, nil
	self.groundClock = 0
	--[[
		Back on the drum, and the LENGTH goes with it.

		This used to be left standing, on the reasoning that paid-out hose only ever
		grows -- which is true while the hose is out and is the whole feel of the
		reel. It is not true once the thing is wound in: Update's retract lerps the
		free end home in about half a second while Retract bleeds the length at
		HoseRetractRate, so whichever finishes first, Stow could land holding a
		stale forty studs that nothing would ever clear. Deploy overwrites it on the
		next pull, so the only thing that ever saw the stale figure was the HUD, and
		it read it as the truth.
	]]
	self.paidOut = MIN_SLACK
	for _, p in ipairs(self.segments) do p.Transparency = 1 end
	for _, p in ipairs(self.joints) do p.Transparency = 1 end
end

-- Winds hose back onto the drum. Returns true once there is nothing left out.
function HoseRig:Retract(dt: number): boolean
	self.paidOut = math.max(MIN_SLACK, self.paidOut - Config.HoseRetractRate * dt)
	return self.paidOut <= MIN_SLACK + 0.01
end

--[[
	How much hose the player has actually pulled off the drum -- which is NOT
	`paidOut`.

	`paidOut` is the simulation's figure and it never drops below MIN_SLACK, the
	couple of studs of coil that never pull straight; the sag maths needs that
	floor. Handed to a readout raw, a hose wound fully home reports three studs
	out, and that is exactly what put a permanent "Hose Length: 3/96" on the HUD
	of a player who had never taken the wand off the reel.

	Deploy sets paidOut to the outlet-to-player distance PLUS MIN_SLACK, so
	taking it off again leaves the honest answer at both ends: zero on the drum,
	and the real distance once it is out.
]]
function HoseRig:Out(): number
	return math.max(0, self.paidOut - MIN_SLACK)
end

--==[ SHAPE ]=================================================================

-- Ground height under a point, or nil where there is nothing below it.
function HoseRig:_groundAt(p: Vector3): number?
	local hit = workspace:Raycast(p + Vector3.new(0, 5, 0), Vector3.new(0, -60, 0), self.params)
	return if hit then hit.Position.Y else nil
end

function HoseRig:Update(dt: number)
	local outlet = self.outlet
	if not self.deployed or not outlet then return end

	local a = outlet.Position
	local b: Vector3
	if self.hoseEnd then
		b = self.hoseEnd.Position
	elseif self.endPos then
		b = (self.endPos :: Vector3):Lerp(a, 1 - math.exp(-7 * dt))
		self.endPos = b
		self:Retract(dt)
		if (b - a).Magnitude < 1.4 then
			self:Stow()
			return
		end
	else
		self:Stow()
		return
	end
	local chord = (b - a).Magnitude
	self.chord = chord

	--[[
		Hose comes off the drum as the player walks out, and goes back on as they
		return. The reel spin is driven from the delta either way, so the drum only
		turns when hose actually moves -- and now turns backwards when it is coming in.

		Paying out is instant: the hose is dragged off by the player walking, so it
		cannot be limited by a spool rate without the rope constraint and the visual
		disagreeing about where the end is.

		Taking it back is rate-limited, and that asymmetry is the point. It used to be
		a pure ratchet -- `if want > self.paidOut` and nothing else -- which is honest
		to a manual reel but left the readout pinned at the furthest the player had
		ever walked: back at the truck, the HUD still said ninety studs were out.

		HoseRewindRate is deliberately below walk speed so the belly of slack survives.
		Walking back opens slack faster than the drum takes it, so the hose still pools
		on the ground while you move and only draws in once you slow down.
	]]
	local want = math.min(self.maxLength, chord + MIN_SLACK)
	if want > self.paidOut then
		if not self.retracting then
			self.spin += (want - self.paidOut)
			self.paidOut = want
		end
	elseif not self.retracting then
		-- never past `want`, or the hose would pull tighter than the player is stood
		local wind = math.min(self.paidOut - want, Config.HoseRewindRate * dt)
		if wind > 0 then
			self.spin -= wind
			self.paidOut -= wind
		end
	end

	local taut = self.maxLength * Config.HoseTaut
	self.tension = math.clamp((chord - taut) / math.max(self.maxLength - taut, 0.01), 0, 1)

	--[[
		Sag depth comes from how much hose is out compared with how far apart the
		ends are. Pulled tight it is nearly a straight line; stood next to the
		truck with sixty studs paid out it puddles at your feet.
	]]
	-- Capped hard. The ground clamp below is what actually makes slack read as
	-- slack; letting the belly grow without limit just buries the middle of the
	-- hose under the driveway.
	local slack = math.max(0, self.paidOut - chord)
	local sag = math.min(chord * Config.HoseSag + slack * 0.35, Config.HoseSagMax)

	local n = Config.HoseSegments
	local pts = self.points
	-- Ground probes run at 10 Hz; endpoint motion refreshes them immediately.
	-- Shape and reel physics still update each frame.
	self.groundClock += dt
	local refreshGround = self.groundA == nil or self.groundB == nil
		or self.groundClock >= 0.1
		or (a - self.groundA).Magnitude >= 0.5
		or (b - self.groundB).Magnitude >= 0.5
	if refreshGround then
		self.groundClock = 0
		self.groundA, self.groundB = a, b
	end
	for i = 0, n do
		local t = i / n
		local chordPoint = a:Lerp(b, t)
		-- parabolic belly, pinned at both couplings
		local p = chordPoint - Vector3.new(0, 4 * t * (1 - t) * sag, 0)

		--[[
			Rest it on whatever is under it, but never lift the two ends: those are
			bolted to the reel and held in the player's hand.

			The probe drops from the straight chord rather than from the sagged
			point. A belly deep enough to go under the driveway would otherwise
			start its ray below the ground, find nothing, and stay buried -- which
			is exactly the case that needs catching.
		]]
		if i > 1 and i < n - 1 then
			if refreshGround then
				self.groundHeights[i + 1] = self:_groundAt(chordPoint)
			end
			local g = self.groundHeights[i + 1]
			if g and p.Y < g + Config.HoseGroundClear then
				p = Vector3.new(p.X, g + Config.HoseGroundClear, p.Z)
			end
		end
		pts[i + 1] = p
	end

	for i = 1, n do
		local p0, p1 = pts[i], pts[i + 1]
		local delta = p1 - p0
		local len = delta.Magnitude
		local seg = self.segments[i]
		if len < 1e-3 then
			seg.Transparency = 1
		else
			seg.Transparency = 0
			seg.Size = Vector3.new(len + Config.HoseRadius, Config.HoseRadius * 2, Config.HoseRadius * 2)
			-- cylinders run along their own X, hence the quarter turn
			seg.CFrame = CFrame.lookAt(p0:Lerp(p1, 0.5), p1) * CFrame.Angles(0, math.rad(90), 0)
		end
	end
	for i = 1, n - 1 do
		local j = self.joints[i]
		j.Transparency = 0
		j.CFrame = CFrame.new(pts[i + 1])
	end
end

function HoseRig:Destroy()
	self:Stow()
	self.folder:Destroy()
end

return HoseRig
