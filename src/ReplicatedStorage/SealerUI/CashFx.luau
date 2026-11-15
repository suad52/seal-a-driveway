--!strict
--[[
	CashFx -- the shower of notes that flies to the cash counter when you are paid.

	Two phases, and the split is the whole effect. Notes are thrown outward from
	wherever the money appeared and fall under gravity for a moment, so the
	payment reads as bursting out of the thing that caused it; then they turn and
	home in on the counter, so the player's eye is carried to the number that
	just changed. One phase alone is confetti or a slide -- together they are a
	payment arriving somewhere.

	Drawn, not imaged: like the rest of this kit a note is a rounded green frame
	with a keyline and a ramp, so there is no asset to ship and it matches every
	other surface on screen.

	Where a burst comes FROM is a hint rather than an argument, because the thing
	that knows the money moved (a Cash value changing) is never the thing that
	knows why. Whoever causes a payment leaves a hint on the way past and the
	watcher picks it up if it is still warm; with no hint the notes come from the
	middle of the screen, which is wrong for nothing in particular.
]]

local RunService = game:GetService("RunService")
local UIKit = require(script.Parent.UIKit)

local CashFx = {}
CashFx.__index = CashFx

local SCATTER = 0.26      -- seconds the notes fly out before they turn for home
local HINT_LIFE = 2.0     -- how long a hinted origin stays warm
local GRAVITY = 1750      -- pixels/s^2 during the scatter
local MAX_NOTES = 16

--[[
	GETTING PAID MAKES NO SOUND (2026-08-12, owner's call).

	Three of them have gone: CashBurst when a shower spawned, CashBurst again as a
	solo note landed, and the thinned CashLand tick as an ordinary note reached the
	counter. So has everything that existed only to schedule them -- TICK_EVERY and
	the per-note `tick` flag that thinned the ticks, and the `quiet` switch the AFK
	yard used to turn them off while it paid once a second.

	Money is paid by the STUD, in instalments every half second while the blade is
	down, so this was not an event sound at all: it played for as long as anybody
	was working. Halving the volume was the first attempt and thinning the ticks to
	one in three was the second (both 2026-08-11, both in the notes they left
	behind), and the yard was silenced outright the same day. Silence everywhere is
	the third and it is the one that answers the complaint rather than softening it.

	The payment is still told, it is just told with the picture -- the notes still
	fly and the counter still kicks on every arrival. The library entries are left
	in SoundKit with their ids and levels, so putting the chime back is one line
	there and one call site here.
]]

--==[ the hint ]==============================================================

local hintAt: Vector2? = nil
local hintClock = 0

-- Called by whatever is about to cause a payment, in the same coordinate space
-- as GuiObject.AbsolutePosition.
function CashFx.hintFrom(pos: Vector2)
	hintAt = pos
	hintClock = os.clock()
end

local function takeHint(): Vector2?
	if hintAt and os.clock() - hintClock < HINT_LIFE then
		local p = hintAt
		hintAt = nil
		return p
	end
	return nil
end

--==[ one note ]==============================================================

local function makeNote(parent: Instance): Frame
	local n = Instance.new("Frame")
	n.Name = "Note"
	n.AnchorPoint = Vector2.new(0.5, 0.5)
	n.Size = UDim2.fromOffset(34, 22)
	n.BackgroundColor3 = Color3.fromRGB(108, 214, 124)
	n.BorderSizePixel = 0
	n.ZIndex = 60
	n.Parent = parent
	UIKit.corner(n, 5)
	UIKit.stroke(n, 2)
	UIKit.gradient(n, 0.9)

	-- the pale oval a banknote has in the middle, so it is not a plain rectangle
	local oval = Instance.new("Frame")
	oval.BackgroundColor3 = Color3.fromRGB(196, 244, 202)
	oval.BorderSizePixel = 0
	oval.AnchorPoint = Vector2.new(0.5, 0.5)
	oval.Position = UDim2.fromScale(0.5, 0.5)
	oval.Size = UDim2.fromOffset(18, 14)
	oval.ZIndex = 61
	oval.Parent = n
	UIKit.corner(oval, 7)

	local d = Instance.new("TextLabel")
	d.BackgroundTransparency = 1
	d.Size = UDim2.fromScale(1, 1)
	d.Font = UIKit.Display
	d.Text = "$"
	d.TextSize = 15
	d.TextColor3 = Color3.fromRGB(28, 96, 48)
	d.ZIndex = 62
	d.Parent = n

	return n
end

--==[ the effect ]============================================================

--[[
	`target` is the thing the notes fly to -- the cash readout. Its position is
	read fresh every frame rather than captured once, because the stat stack
	reflows when the rig line appears and a note aimed at where the counter used
	to be lands in empty screen.
]]
function CashFx.new(parent: Instance, target: GuiObject, onArrive: (() -> ())?)
	return setmetatable({
		parent = parent,
		target = target,
		onArrive = onArrive,
		live = {} :: { any },
		conn = nil :: RBXScriptConnection?,
	}, CashFx)
end

function CashFx:_ensureLoop()
	if self.conn then return end
	self.conn = RunService.RenderStepped:Connect(function(dt)
		self:_step(math.min(dt, 0.05))
	end)
end

function CashFx:_step(dt: number)
	local target = self.target
	local aim = target.AbsolutePosition + target.AbsoluteSize * 0.5

	for i = #self.live, 1, -1 do
		local n = self.live[i]
		n.age += dt

		if n.age < n.delay then
			-- staggered so they do not leave in one slab
		elseif n.age < n.delay + SCATTER then
			n.vel = Vector2.new(n.vel.X, n.vel.Y + GRAVITY * dt)
			n.pos += n.vel * dt
			n.frame.Rotation += n.spin * dt
		else
			--[[
				Homing, and it accelerates rather than easing out.

				A note that decelerates into the counter reads as being placed
				there; one that speeds up all the way in reads as being pulled,
				which is what money going into a till does.
			]]
			local t = math.min(1, (n.age - n.delay - SCATTER) / n.travel)
			local pull = t * t
			n.pos = n.pos:Lerp(aim, math.min(1, pull * 0.42))
			n.frame.Rotation += n.spin * dt * (1 - t)
			n.scale.Scale = 1 - 0.45 * t

			if t >= 1 or (n.pos - aim).Magnitude < 12 then
				n.frame:Destroy()
				table.remove(self.live, i)
				-- The counter's kick is the whole of the arrival now; the chime and the
				-- tick that used to fire here are gone -- see the note at the top.
				if self.onArrive then self.onArrive() end
				continue
			end
		end

		n.frame.Position = UDim2.fromOffset(n.pos.X, n.pos.Y)
	end

	if #self.live == 0 and self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
end

--[[
	`amount` only decides how many notes come out, and it is deliberately a very
	flat curve: a thousand and a million both have to read as "you got paid" in
	the same half second, and forty notes on screen is noise rather than a bigger
	reward.
]]
--[[
	`solo` is the whole payout as ONE note.

	The shower is right for something that happens occasionally. It is wrong for
	the end of a combo, which is a single deliberate moment the player has been
	watching build at the top of the screen -- a dozen notes turn that into a
	scramble rather than a payoff.

	It used to be one note and one chime, deliberately timed to land on the same
	frame as the counter's kick. The chime has gone -- see the note at the top --
	and the single note has not, because what it was really doing was making the
	payoff one arrival instead of twelve.
]]
function CashFx:Burst(amount: number, origin: Vector2?, solo: boolean?)
	local from = origin or takeHint()
	if not from then
		local vp = self.parent.AbsoluteSize
		from = Vector2.new(vp.X * 0.5, vp.Y * 0.42)
	end

	local count = if solo then 1
		else math.clamp(4 + math.floor(math.log(math.max(amount, 1), 4)), 5, MAX_NOTES)
	for i = 1, count do
		local angle = math.rad(-90 + (math.random() - 0.5) * 150)
		local speed = 320 + math.random() * 300
		local frame = makeNote(self.parent)
		local scale = Instance.new("UIScale")
		scale.Parent = frame

		local start = (from :: Vector2) + Vector2.new(
			(math.random() - 0.5) * 26, (math.random() - 0.5) * 18)
		frame.Position = UDim2.fromOffset(start.X, start.Y)
		frame.Rotation = math.random(-40, 40)

		table.insert(self.live, {
			frame = frame,
			scale = scale,
			pos = start,
			vel = Vector2.new(math.cos(angle), math.sin(angle)) * speed,
			spin = (math.random() - 0.5) * 460,
			age = 0,
			delay = (i - 1) * 0.022,
			-- a spread of flight times, so they arrive as a stream rather than
			-- all at once on the same frame
			travel = 0.42 + math.random() * 0.26,
		})
	end

	self:_ensureLoop()
end

function CashFx:Destroy()
	if self.conn then self.conn:Disconnect() end
	for _, n in ipairs(self.live) do n.frame:Destroy() end
	self.live = {}
end

return CashFx
