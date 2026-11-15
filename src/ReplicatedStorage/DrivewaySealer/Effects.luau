--!strict
-- Beams, spatter and the finishing celebration.

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundKit = require(script.Parent.SoundKit)

local Effects = {}

local DROPLET = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local function anchor(name: string, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.Parent = parent
	return p
end

--==[ POUR STREAM ]===========================================================

local Stream = {}
Stream.__index = Stream

function Effects.newStream(parent: Instance)
	local impact = anchor("PourImpact", parent)

	local a0 = Instance.new("Attachment")
	a0.Name = "StreamOrigin"
	local a1 = Instance.new("Attachment")
	a1.Name = "StreamImpact"
	a1.Parent = impact

	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Segments = 14
	beam.FaceCamera = true
	beam.LightEmission = 0
	beam.LightInfluence = 1
	beam.Width0 = 0.30
	beam.Width1 = 0.20
	beam.Color = ColorSequence.new(Color3.fromRGB(16, 15, 15))
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.85, 0.15),
		NumberSequenceKeypoint.new(1, 0.7),
	})
	beam.Enabled = false
	beam.Parent = impact

	local spatter = Instance.new("ParticleEmitter")
	spatter.Texture = DROPLET
	spatter.Color = ColorSequence.new(Color3.fromRGB(20, 19, 19))
	spatter.LightEmission = 0
	spatter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	spatter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	spatter.Lifetime = NumberRange.new(0.25, 0.5)
	spatter.Speed = NumberRange.new(2, 5)
	spatter.SpreadAngle = Vector2.new(48, 48)
	spatter.Acceleration = Vector3.new(0, -55, 0)
	spatter.Rate = 0
	spatter.Enabled = false
	spatter.Parent = impact

	-- Two layers, because one never sounds like liquid: a steady hiss for the
	-- stream itself, and a slower glug underneath it that carries the weight.
	local loop = SoundKit.create("PourLoop", impact)
	local glug = SoundKit.create("Glug", impact)

	return setmetatable({
		impact = impact, a0 = a0, a1 = a1,
		beam = beam, spatter = spatter, loop = loop, glug = glug,
		active = false,
	}, Stream)
end

function Stream:Attach(nozzle: BasePart)
	self.a0.Parent = nozzle
end

-- `flow` is 0..1; the stream thins out as the bucket runs dry.
function Stream:Update(hitPos: Vector3, flow: number)
	local a0 = self.a0
	if not a0.Parent then return end
	local from = a0.WorldPosition
	local delta = hitPos - from
	local dist = delta.Magnitude
	if dist < 0.05 then return end

	local horizontal = Vector3.new(delta.X, 0, delta.Z)
	if horizontal.Magnitude < 0.05 then horizontal = Vector3.new(0, 0, -1) end
	horizontal = horizontal.Unit

	-- The two control points give the stream its arc: it leaves the spout
	-- travelling outward, and comes into the slab from above.
	a0.WorldCFrame = CFrame.lookAt(from, from + horizontal) * CFrame.Angles(0, math.rad(90), 0)
	self.impact.CFrame = CFrame.lookAt(hitPos, hitPos + Vector3.new(0, 1, 0), horizontal)
		* CFrame.Angles(0, math.rad(-90), 0)

	self.beam.CurveSize0 = dist * 0.30
	self.beam.CurveSize1 = dist * 0.42
	self.beam.Width0 = 0.30 * flow
	self.beam.Width1 = 0.21 * flow

	-- the glug thins and rises as the bucket empties
	self.glug.Volume = 0.34 * flow
	self.glug.PlaybackSpeed = 0.62 + 0.22 * flow
end

function Stream:SetActive(on: boolean)
	if on == self.active then return end
	self.active = on
	self.beam.Enabled = on
	self.spatter.Enabled = on
	self.spatter.Rate = if on then 34 else 0
	if on then
		self.loop:Play()
		self.glug:Play()
		SoundKit.play("PourStart", self.impact, 0.08)
	else
		self.loop:Stop()
		self.glug:Stop()
		-- the lip keeps dribbling for a moment after the pail comes back upright
		SoundKit.play("Drip", self.impact, 0.2, 0.6)
	end
end

function Stream:Destroy()
	self.a0:Destroy()
	self.impact:Destroy()
end

--==[ WAND STREAM ]===========================================================

--[[
	The wand's pour: a near-parallel rope of sealer landing hard in one spot.

	It used to lerp between this and a wide atomised fan. The fan is gone, so
	this draws one thing and draws it properly -- a heavy pumped stream, which is
	what a hose off a tank actually throws.

	It is a separate object from the pail's Stream above rather than a reuse of
	it, for one specific reason: the wand is created and destroyed every time it
	comes off and goes back on the reel, and Stream parents its origin attachment
	into the tool. See the note in the constructor.
]]

local Spray = {}
Spray.__index = Spray

function Effects.newWandStream(parent: Instance)
	local impact = anchor("SprayImpact", parent)

	--[[
		The emitter lives on an anchored part of our own that chases the wand tip,
		rather than being parented into the tool.

		That matters here in a way it does not for the bucket: the wand is created
		and destroyed every time it comes off and goes back on the reel, and
		anything parented inside it dies with it -- after which this object would
		be holding destroyed instances and every later re-attach would throw.
	]]
	local muzzle = anchor("SprayMuzzle", parent)

	-- Beam curvature is controlled by Attachment0's X axis, so the quarter turn
	-- puts that axis down the muzzle's own facing.
	local a0 = Instance.new("Attachment")
	a0.Name = "SprayOrigin"
	a0.CFrame = CFrame.Angles(0, math.rad(90), 0)
	a0.Parent = muzzle

	local a1 = Instance.new("Attachment")
	a1.Name = "SprayLand"
	a1.Parent = impact

	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Segments = 10
	beam.FaceCamera = true
	beam.LightEmission = 0
	beam.LightInfluence = 1
	beam.Color = ColorSequence.new(Color3.fromRGB(15, 14, 14))
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.10),
		NumberSequenceKeypoint.new(0.7, 0.30),
		NumberSequenceKeypoint.new(1, 0.75),
	})
	beam.Enabled = false
	beam.Parent = impact

	-- atomised sealer leaving the tip
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "Mist"
	mist.Texture = DROPLET
	mist.Color = ColorSequence.new(Color3.fromRGB(18, 17, 17))
	mist.LightEmission = 0
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.10),
		NumberSequenceKeypoint.new(1, 0.55),
	})
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Lifetime = NumberRange.new(0.16, 0.30)
	mist.Speed = NumberRange.new(26, 34)
	mist.SpreadAngle = Vector2.new(5, 3)
	mist.Acceleration = Vector3.new(0, -22, 0)
	mist.EmissionDirection = Enum.NormalId.Front  -- the muzzle's -Z, i.e. downrange
	mist.Rate = 0
	mist.Enabled = false
	mist.Parent = muzzle

	-- what bounces back off the slab
	local splash = Instance.new("ParticleEmitter")
	splash.Name = "Splash"
	splash.Texture = DROPLET
	splash.Color = ColorSequence.new(Color3.fromRGB(20, 19, 19))
	splash.LightEmission = 0
	splash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	splash.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	splash.Lifetime = NumberRange.new(0.2, 0.42)
	splash.Speed = NumberRange.new(3, 8)
	splash.SpreadAngle = Vector2.new(70, 70)
	splash.Acceleration = Vector3.new(0, -62, 0)
	splash.Rate = 0
	splash.Enabled = false
	splash.Parent = impact

	-- The pour itself, plus the runoff of it arriving on the slab. Both are the
	-- pail's sounds rather than the old pressurised hiss: it is the same sealer
	-- landing the same way, just more of it and from a hose.
	local loop = SoundKit.create("PourLoop", impact)
	local runoff = SoundKit.create("Runoff", impact)

	return setmetatable({
		impact = impact, muzzle = muzzle, a0 = a0, a1 = a1,
		beam = beam, mist = mist, splash = splash,
		loop = loop, runoff = runoff,
		tip = nil :: BasePart?,
		active = false,
		nextSplat = 0,
	}, Spray)
end

-- Only remembered, never re-parented: see the note in the constructor.
function Spray:Attach(tip: BasePart?)
	self.tip = tip
end

-- `flow` is 0..1 and fades the whole thing out as the tank runs down.
function Spray:Update(hitPos: Vector3, flow: number)
	local tip = self.tip
	if not tip or not tip.Parent then return end
	local from = tip.Position
	local delta = hitPos - from
	local dist = delta.Magnitude
	if dist < 0.05 then return end

	self.muzzle.CFrame = CFrame.lookAt(from, hitPos)

	local horizontal = Vector3.new(delta.X, 0, delta.Z)
	if horizontal.Magnitude < 0.05 then horizontal = Vector3.new(0, 0, -1) end
	self.impact.CFrame = CFrame.lookAt(hitPos, hitPos + Vector3.new(0, 1, 0), horizontal.Unit)
		* CFrame.Angles(0, math.rad(-90), 0)

	-- Pressure means it barely droops over this distance; the little sag that
	-- is left is what stops it reading as a laser.
	self.beam.CurveSize0 = dist * 0.06
	self.beam.CurveSize1 = dist * 0.14
	self.beam.Width0 = 0.28 * flow
	self.beam.Width1 = 0.34 * flow

	self.mist.Rate = 34 * flow
	self.splash.Rate = 52 * flow

	self.runoff.Volume = 0.42 * flow
	self.runoff.PlaybackSpeed = 0.66

	-- Irregular wet splats over the top of the loops. Even spacing reads as a
	-- machine; the scatter is what makes it sound like liquid hitting tarmac.
	local now = os.clock()
	if now >= self.nextSplat then
		self.nextSplat = now + 0.14 + math.random() * 0.13
		SoundKit.play("Splash", self.impact, 0.22, 0.26 * flow)
	end
end

function Spray:SetActive(on: boolean)
	if on == self.active then return end
	self.active = on
	self.beam.Enabled = on
	self.mist.Enabled = on
	self.splash.Enabled = on
	if not on then
		self.mist.Rate = 0
		self.splash.Rate = 0
		self.loop:Stop()
		self.runoff:Stop()
		-- a wand that has just been shut off keeps dribbling off the tip
		SoundKit.play("Drip", self.impact, 0.2, 0.75)
		task.delay(0.45, function()
			if not self.active and self.impact.Parent then
				SoundKit.play("Drip", self.impact, 0.25, 0.45)
			end
		end)
	else
		self.loop:Play()
		self.runoff:Play()
		self.nextSplat = 0
		SoundKit.play("PourStart", self.impact, 0.07)
	end
end

function Spray:Destroy()
	self.muzzle:Destroy()
	self.impact:Destroy()
end

--==[ SPOT REWARDS ]==========================================================

-- A little pop where a patch just finished sealing.
--[[
	ONE POOLED EMITTER, MOVED -- not a new pair every time.

	This used to build a Part and a ParticleEmitter, write a dozen properties, emit,
	and hand the pair to Debris on a two second timer. It fires every POP_EVERY
	cells sealed, which during a spread is more or less continuously, so dozens were
	alive at once and the churn never stopped while the player worked.

	That cost hid from every counter anyone would think to check. It is not drawing
	-- the owner measured Render at 0.9ms while the frame took 35 -- and it is not
	physics. It is instance creation and destruction, which shows up as script time
	and nowhere else. Worse, DrivewayClient calls this DELIBERATELY OUTSIDE the
	sealer's measured window, so the adaptive throttle that would otherwise back off
	under load could not see it and never did.

	Pooling costs one Part and one emitter for the whole session. Emitted particles
	are simulated in world space and do not follow their emitter, so moving it
	between bursts leaves the previous sparkles exactly where they were laid -- the
	effect is unchanged, which is the point.

	The pair is rebuilt if either half goes: fxFolder is cleared on some transitions,
	and a pooled instance whose parent has been destroyed is a nil dereference
	waiting for the next spread.
]]
local popPart: Part? = nil
local popEmitter: ParticleEmitter? = nil

function Effects.sealPop(position: Vector3, parent: Instance)
	local p, e = popPart, popEmitter
	if p and p.Parent and e and e.Parent then
		-- the folder can change between slabs; re-home rather than rebuild
		if p.Parent ~= parent then p.Parent = parent end
		p.CFrame = CFrame.new(position + Vector3.new(0, 0.15, 0))
		e:Emit(9)
		return
	end

	p = anchor("SealPop", parent)
	p.CFrame = CFrame.new(position + Vector3.new(0, 0.15, 0))

	e = Instance.new("ParticleEmitter")
	e.Texture = SPARKLE
	e.Color = ColorSequence.new(Color3.fromRGB(215, 232, 255))
	e.LightEmission = 0.85
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.35, 0.7)
	e.Speed = NumberRange.new(3, 7)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -14, 0)
	e.Rate = 0
	e.Parent = p
	popPart, popEmitter = p, e
	e:Emit(9)

	--[[
		Silent on purpose.

		This fires every few hundred cells sealed, which during a spread means
		more or less continuously, and a bright reward ping at that rate buries
		the wet layer the spreading is supposed to be carried by. The sparkle is
		still here -- the feedback is worth keeping, it just should not be the
		loudest thing happening while you push a bead.

		AND NO Debris:AddItem ANY MORE -- the pair is kept and reused. Handing it to
		Debris is what made this churn: two instances for the session, against two
		every few hundred cells sealed.
	]]
end

--==[ COMPLETION ]============================================================

-- A bar of light sweeps the length of the finished slab. On a black driveway
-- this reads as the whole thing catching the sun at once.
function Effects.shineSweep(topCF: CFrame, spanX: number, spanZ: number, parent: Instance)
	local bar = Instance.new("Part")
	bar.Name = "ShineSweep"
	bar.Anchored = true
	bar.CanCollide = false
	bar.CanQuery = false
	bar.CanTouch = false
	bar.CastShadow = false
	bar.Material = Enum.Material.Neon
	bar.Color = Color3.fromRGB(226, 238, 255)
	bar.Transparency = 1
	bar.Size = Vector3.new(spanX * 1.02, 0.02, 3.2)
	bar.CFrame = topCF * CFrame.new(0, 0.09, -spanZ * 0.5)
	bar.Parent = parent

	local travel = TweenService:Create(bar,
		TweenInfo.new(1.25, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ CFrame = topCF * CFrame.new(0, 0.09, spanZ * 0.5) })

	TweenService:Create(bar, TweenInfo.new(0.22), { Transparency = 0.55 }):Play()
	travel:Play()
	travel.Completed:Connect(function()
		TweenService:Create(bar, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		Debris:AddItem(bar, 0.5)
	end)
end

function Effects.completionBurst(topCF: CFrame, spanX: number, spanZ: number, parent: Instance)
	local p = anchor("CompletionBurst", parent)
	p.CFrame = topCF * CFrame.new(0, 1.2, 0)
	p.Size = Vector3.new(spanX * 0.8, 0.2, spanZ * 0.8)

	local e = Instance.new("ParticleEmitter")
	e.Texture = SPARKLE
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 206)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 214, 255)),
	})
	e.LightEmission = 1
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(1.1, 2.0)
	e.Speed = NumberRange.new(9, 20)
	e.SpreadAngle = Vector2.new(30, 180)
	e.Acceleration = Vector3.new(0, -11, 0)
	e.Rate = 0
	e.Parent = p
	e:Emit(150)

	Effects.shineSweep(topCF, spanX, spanZ, parent)
	SoundKit.play("Ding", p, 0, 1)
	task.delay(0.18, function() SoundKit.play("Sparkle", p, 0.05, 1) end)
	Debris:AddItem(p, 4)
end

return Effects
