--!strict
--[[
	SqueegeePose -- puts both of the player's hands on the squeegee handle, and
	leans them into it while the blade is down.

	The squeegee is posed from the simulation rather than welded to the hand (see
	ToolBuilder for why). That left the pole running from the blade at a fixed
	46-degree lean to wherever that happened to land -- which, measured, was
	HRP-local (0, 0.44, 0) at the torso's centre plane. In other words straight
	through the player's chest and out of their back, on the body's midline, with
	one arm waving beside it.

	The handle now ENDS at the hands rather than passing them. That is the whole
	fix for the clipping: the top of the pole is the upper grip, so there is no
	length left over to reach the body with. It also means the pole cannot be
	lengthened without pushing the grip into the chest again -- if you want a
	longer handle, move the blade further out (BLADE_FORWARD), not the pole.

	Everything is measured in the player's own shoulder span, so a tall avatar
	and a short one hold it the same way rather than one of them hugging it.

	=== how the two halves are driven, and why they differ ===

	This rig has no Motor6Ds at all. Limbs are joined by an AnimationConstraint
	plus a BallSocketConstraint each, so the usual "write Motor6D.Transform at a
	render-step priority after Character" trick has nothing to write to.

	The HANDS use IKControl, which solves a two-bone chain and blends against the
	playing animation by Weight.

	The LEAN does not, and must not -- see LEAN_DEGREES. It writes the waist
	AnimationConstraint's Transform directly, from RunService.Stepped.
]]

local RunService = game:GetService("RunService")

-- only for seatSkin: this is the one call that runs every frame on the LOCAL
-- player's own rig, so it is where that rig's skin pieces get put right. See the
-- note over ToolBuilder.seatSkin.
local ToolBuilder = require(script.Parent.ToolBuilder)

local SqueegeePose = {}
SqueegeePose.__index = SqueegeePose

--[[
	Grip placement, all in shoulder-span units.

	LATERAL is small on purpose. An off-centre pole reads better in isolation but
	puts the far hand outside its own shoulder's cone, and these ball sockets are
	not forgiving about that: a target 1.85 studs out and 0.85 across the body
	settles 0.45 short, where the same distance straight ahead of the shoulder
	lands within 0.09. Near-centred, both hands sit on the handle.

	Do not expect the hands to land exactly on the line. The elbow ball socket
	has UpperAngle 20 and a twist floor of 5 degrees, so the arm never straightens
	-- measured, it reaches about 1.6 studs of a 2.44-stud bone span. These values
	were swept against that: they settle both hands within ~0.4 of the handle's
	centreline, which is inside the 0.31 half-width of a hand, so the pole still
	passes through the fist. Winding them further out just makes the arms give up
	earlier, and the hand drifts visibly off the wood.
]]
local GRIP_FORWARD = 0.50   -- in front of the shoulder line
local GRIP_LATERAL = 0.05   -- barely right of centre
local GRIP_DROP    = 0.24   -- below the shoulder line
local GRIP_SPACING = 0.62   -- how far down the handle the leading hand grips
local HANDLE_OVER  = 0.28   -- studs of handle standing proud above the top hand
local POLE_THICK   = 0.22

-- Where the handle leaves the head, in the rig's own space.
local POLE_ROOT = Vector3.new(0, 0.45, 0.10)

--[[
	How far the back pitches when leaning on the blade.

	⚠ DO NOT DRIVE THIS WITH IKControl. Three versions shipped bent backwards or
	broke the walk before it read right, and the reasons are worth keeping.

	1. The shortest torso chain contains the ROOT joint. An IKControl needs at
	   least two parts, so the only valid chain is LowerTorso -> UpperTorso, and
	   that puts HumanoidRootPart -> LowerTorso inside it. The solver is then free
	   to satisfy a requested UpperTorso rotation by rolling the entire lower body
	   instead of bending the waist, and it does. Standing, that read as the waist
	   bending a healthy +0.66 forward while the hips had swung 36 degrees BACK
	   underneath. WALKING it was far worse -- the pelvis reached 67 degrees back
	   and the character travelled almost horizontal, legs out in front.
	   Setting ChainRoot = UpperTorso to exclude the root joint is not a way out:
	   ChainRoot == EndEffector is degenerate and produces NaN on the torso.

	2. So the waist AnimationConstraint is written directly instead, which moves
	   that one joint and leaves the hips alone -- measured, 25 degrees of bend
	   with hip tilt at 0.000, and a normal walk cycle underneath it.

	3. ⚠ The phase matters and is the whole reason this looked impossible at
	   first. Writing Transform from BindToRenderStep(Character + 1) does nothing
	   (0.5 degrees of 25), because the animator has already been consumed by then.
	   It has to go in RunService.Stepped, BEFORE the physics step reads it, and it
	   has to be an ABSOLUTE CFrame -- multiplying the current value just races the
	   animator. Same write from Heartbeat: nothing.

	4. The angle is NEGATIVE for forward. Measured on the head, not on the waist:
	   ToEulerAnglesXYZ across the waist happily reported +20 degrees for the
	   version that bent the player backwards, because it measures UpperTorso
	   against LowerTorso and both were wrong together. The honest test is
	   (Head.Position - HumanoidRootPart.Position):Dot(flatLook), which must come
	   out POSITIVE, or just look at it side-on.
]]
local LEAN_DEGREES = 25

-- Leaning already carries the shoulders forward, and the grips are measured off
-- the shoulders, so at full lean the handle would run away from the hands. Pull
-- the top grip back in by this much as the lean comes on.
local GRIP_LEAN_PULL = 0.12

-- R15 only. An R6 character has none of these parts, and there is no sensible
-- two-handed pose to fake on a rig with one joint per arm, so it keeps the
-- handle ToolBuilder baked and nothing here runs.
local NEEDED = {
	"HumanoidRootPart", "LowerTorso", "UpperTorso",
	"LeftUpperArm", "LeftHand", "RightUpperArm", "RightHand",
}

export type Class = typeof(setmetatable({} :: {
	player: Player,
	parent: Instance,
	character: Model?,
	waist: Instance?,
	leanAngle: number,
	stepped: RBXScriptConnection?,
	bound: boolean,
	active: boolean,
	parts: { [string]: any },
}, SqueegeePose))

function SqueegeePose.new(player: Player, parent: Instance): Class
	local self = setmetatable({
		player = player,
		parent = parent,
		character = nil,
		waist = nil,
		leanAngle = 0,
		stepped = nil,
		bound = false,
		active = false,
		parts = {},
	}, SqueegeePose)

	--[[
		The lean, written here and nowhere else.

		Stepped rather than Heartbeat or a render step, and an absolute CFrame
		rather than a multiply -- both load-bearing, see LEAN_DEGREES. Held for the
		life of the object rather than rebuilt per character, so a respawn mid-
		stroke cannot leave a dangling writer behind.

		Silent at zero on purpose: not writing at all is what hands the joint back
		to the walk animation, so carrying the squeegee looks completely untouched.
	]]
	self.stepped = RunService.Stepped:Connect(function()
		local waist = self.waist
		if not waist or not waist.Parent then return end
		if self.leanAngle <= 0.001 then return end
		(waist :: any).Transform = CFrame.Angles(-self.leanAngle, 0, 0)
	end)

	return (self :: any) :: Class
end

local function marker(name: string, parent: Instance): BasePart
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

function SqueegeePose.Destroy(self: Class)
	for _, v in pairs(self.parts) do
		if typeof(v) == "Instance" then v:Destroy() end
	end
	table.clear(self.parts)
	self.bound = false
	self.character = nil
	self.waist = nil
	self.leanAngle = 0
end

-- Builds the controls against whatever character is current, and rebuilds them
-- after a respawn: the IKControls hang off the Humanoid, which dies with it.
function SqueegeePose.Bind(self: Class): boolean
	local character = self.player.Character
	if self.bound and character == self.character and character and character.Parent then
		return true
	end
	SqueegeePose.Destroy(self)
	if not character then return false end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	for _, name in ipairs(NEEDED) do
		if not character:FindFirstChild(name) then return false end
	end
	local shoulderL = character.LeftUpperArm:FindFirstChild("LeftShoulderRigAttachment")
	local shoulderR = character.RightUpperArm:FindFirstChild("RightShoulderRigAttachment")
	if not shoulderL or not shoulderR then return false end

	local function control(name: string, kind: Enum.IKControlType, root: Instance, effector: Instance): IKControl
		local target = marker(name .. "Target", self.parent)
		local c = Instance.new("IKControl")
		c.Name = name
		c.Type = kind
		c.ChainRoot = root
		c.EndEffector = effector
		c.Target = target
		c.Weight = 0
		c.Parent = humanoid
		self.parts[name .. "Target"] = target
		self.parts[name] = c
		return c
	end

	self.character = character
	self.parts.shoulderL = shoulderL
	self.parts.shoulderR = shoulderR
	control("SqueegeeHandL", Enum.IKControlType.Position, character.LeftUpperArm, character.LeftHand)
	control("SqueegeeHandR", Enum.IKControlType.Position, character.RightUpperArm, character.RightHand)
	-- the lean is this one joint, written straight, not solved
	self.waist = character.UpperTorso:FindFirstChild("Waist")
	self.bound = true
	return true
end

-- Hands off. Left enabled-but-weightless rather than destroyed so that swapping
-- tools does not churn instances on the Humanoid every keypress.
function SqueegeePose.Clear(self: Class)
	if not self.active then return end
	self.active = false
	-- zero stops the Stepped writer touching the waist at all, which is what
	-- gives the joint back to the walk animation
	self.leanAngle = 0
	for _, name in ipairs({ "SqueegeeHandL", "SqueegeeHandR" }) do
		local c = self.parts[name]
		if c then c.Weight = 0 end
	end
end

--[[
	Pose the handle and the player around the blade the simulation is already
	driving. `engage` is the blade-down ramp, 0 carried to 1 pressed.
]]
function SqueegeePose.Update(self: Class, rig: Model, engage: number)
	--[[
		BEFORE the R6 bail below, and that ordering is the whole point of putting it
		here rather than inside the pose.

		The skin pieces belong to the RIG, not to the hands: an R6 player gets no pose
		at all -- Bind fails, there is no arm chain to solve -- but DrivewayClient is
		still placing their rig every frame and they are still owed the squeegee they
		paid for. Every caller of this runs it unconditionally each tick with the rig
		it just placed, which is exactly the contract seatSkin wants.
	]]
	ToolBuilder.seatSkin(rig)
	if not SqueegeePose.Bind(self) then return end
	local character = self.character :: Model
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local blade = rig:FindFirstChild("Blade") :: BasePart?
	local pole = rig:FindFirstChild("Pole") :: BasePart?
	if not hrp or not blade or not pole then return end

	local lv = hrp.CFrame.LookVector
	local flatV = Vector3.new(lv.X, 0, lv.Z)
	local flat = if flatV.Magnitude < 1e-4 then Vector3.new(0, 0, -1) else flatV.Unit
	local right = Vector3.new(-flat.Z, 0, flat.X)

	local sL = (self.parts.shoulderL :: Attachment).WorldPosition
	local sR = (self.parts.shoulderR :: Attachment).WorldPosition
	local mid = (sL + sR) / 2
	local span = (sR - sL).Magnitude
	if span < 1e-3 then return end

	local lean = math.clamp(engage, 0, 1)

	-- the handle runs from the head of the blade to the upper hand, and stops
	local root = (blade.CFrame * CFrame.new(POLE_ROOT)).Position
	local upper = mid
		+ flat * ((GRIP_FORWARD - GRIP_LEAN_PULL * lean) * span)
		+ right * (GRIP_LATERAL * span)
		- Vector3.new(0, GRIP_DROP * span, 0)
	local reach = upper - root
	if reach.Magnitude < 0.2 then return end
	local dir = reach.Unit
	local top = upper + dir * HANDLE_OVER
	local lower = upper - dir * (GRIP_SPACING * span)

	-- Part.Size.Y is the length, so the handle is aimed with lookAt and then
	-- rolled a quarter turn to put its own Y down that line
	local length = (top - root).Magnitude
	if math.abs(pole.Size.Y - length) > 0.02 then
		pole.Size = Vector3.new(POLE_THICK, length, POLE_THICK)
	end
	pole.CFrame = CFrame.lookAt((root + top) / 2, top) * CFrame.Angles(-math.pi / 2, 0, 0)

	-- Bound to locals rather than indexed inline: a statement that opens with "("
	-- is parsed as a call on the previous line's value, and every one of these
	-- follows a call.
	local targetL = self.parts.SqueegeeHandLTarget :: BasePart
	local targetR = self.parts.SqueegeeHandRTarget :: BasePart
	local handL = self.parts.SqueegeeHandL :: IKControl
	local handR = self.parts.SqueegeeHandR :: IKControl

	--[[
		Right hand on the back grip, left hand leading below it.

		That way round is measured, not stylistic. The lower grip is the harder
		reach -- it is down and forward, away from both shoulders -- and the right
		arm is the one already carrying the tool's welded Handle and Roblox's own
		tool-hold animation, so it gives up sooner. Left-on-top settles 0.04/0.65
		off the handle; right-on-top settles 0.40/0.28, which halves the worst hand.
	]]
	targetR.CFrame = CFrame.new(upper)
	targetL.CFrame = CFrame.new(lower)

	-- Handed to the Stepped writer rather than applied here: a Heartbeat write is
	-- too late in the frame for the constraint to see it.
	self.leanAngle = math.rad(LEAN_DEGREES) * lean

	handL.Weight = 1
	handR.Weight = 1
	self.active = true
end

return SqueegeePose
