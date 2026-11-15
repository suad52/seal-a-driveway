--!strict
--[[
	WandPose -- puts the spray wand in the player's hand.

	The wand is posed from code rather than welded, for the reason spelled out on
	the squeegee in ToolBuilder: a welded prop inherits every walk and idle
	animation, and a wand that is meant to point where the player is aiming cannot
	afford to wander off with the arm. What was missing was the other half of that
	bargain -- nothing ever put a HAND on it. The rig was dropped at a fixed offset
	from the ROOT (right 0.85, forward 0.55, up 0.35) and turned to face the mouse,
	while the arm carried on playing Roblox's generic tool-hold animation against
	the tool's invisible handle. So the gun hung in the air beside the player, and
	because it pivots about that fixed point it could swing through the chest and
	out the far side.

	=== position from the HAND, rotation from the AIM ===

	That split is the whole module. The grip is pinned to the hand's own grip
	attachment -- the exact point Roblox welds a tool handle to -- so it is in the
	fist to the millimetre, at every avatar size, in every animation. Only the
	ROTATION is ours, and that is the part the original design actually needed to
	own. A plain weld would have taken the rotation too, which is what it was
	avoiding; nothing about it required giving up the position as well.

	⚠ The first version of this drove the hands ONTO the wand with IKControl, the
	way SqueegeePose does, and it does not work for this tool. Measured on a
	default R15 aiming at the ground: the supporting hand's target on the lance
	sat 2.28 studs from its shoulder and the arm reached 1.54 -- 0.75 studs short,
	a fist visibly floating beside the pipe. Shortening the spacing barely moved
	it, because the limit is not distance along the lance, it is that a lance
	pointing downrange from the RIGHT hand never passes anywhere the LEFT arm can
	reach. Even the right hand's own solve missed by 0.48. The squeegee can put
	both hands on its pole because that pole runs BACK toward the body across the
	midline; a gun aimed away from you is not the same problem, and no amount of
	tuning the offsets turns it into one.

	So the wand is one-handed, which is how a light lance is really carried, and
	the free arm keeps its ordinary animation.
]]

local WandPose = {}
WandPose.__index = WandPose

--[[
	Where the pistol grip sits in the rig's own space.

	The rig's origin is the top of the receiver with -Z running down the lance (see
	ToolBuilder), NOT the pistol grip -- the rubber hangs about half a stud below
	it. Pivoting the model straight onto the fist would hang the whole gun
	underneath the hand, and this offset is that correction.
]]
local GRIP_LOCAL = Vector3.new(0, -0.42, 0.14)

-- Everything this needs. A rig missing any of it -- R6, or a character still
-- streaming in -- gets no posing and keeps whatever placement the caller gave it.
local NEEDED = { "HumanoidRootPart", "RightHand" }

export type Class = typeof(setmetatable({} :: {
	player: Player,
	parent: Instance,
	character: Model?,
	bound: boolean,
	active: boolean,
	parts: { [string]: any },
}, WandPose))

-- kept so the caller's `WandPose.new(player, fxFolder())` still reads the same
-- as squeegeePose's, even though nothing is parented into fxFolder any more

function WandPose.new(player: Player, parent: Instance): Class
	local self = setmetatable({
		player = player,
		parent = parent,
		character = nil,
		bound = false,
		active = false,
		parts = {},
	}, WandPose)
	return (self :: any) :: Class
end

function WandPose.Destroy(self: Class)
	for _, v in pairs(self.parts) do
		if typeof(v) == "Instance" then v:Destroy() end
	end
	table.clear(self.parts)
	self.bound = false
	self.character = nil
end

-- Rebound after a respawn: the attachment below belongs to the character.
function WandPose.Bind(self: Class): boolean
	local character = self.player.Character
	if self.bound and character == self.character and character and character.Parent then
		return true
	end
	WandPose.Destroy(self)
	if not character then return false end
	for _, name in ipairs(NEEDED) do
		if not character:FindFirstChild(name) then return false end
	end

	--[[
		The hand's own grip attachment, which is the exact point Roblox welds a
		tool's Handle to. Pinning the wand here is what makes it agree with the
		hold animation instead of arguing with it -- the gun ends up precisely
		where an ordinary equipped tool would be, just free to turn.
	]]
	local fist = character.RightHand:FindFirstChild("RightGripAttachment")
	if not fist then return false end

	self.character = character
	self.parts.fist = fist
	self.bound = true
	return true
end

-- Nothing to switch off any more: the wand is only ever moved while it is held,
-- and no joint is being driven. Kept so callers can stay symmetrical with
-- SqueegeePose, and so that turning the pose back into an IK one later does not
-- mean touching DrivewayClient again.
function WandPose.Clear(self: Class)
	self.active = false
end

-- Where the fist holding the wand is. nil when there is nothing to read it off,
-- which is the caller's cue to fall back to its own placement.
function WandPose.Grip(self: Class): Vector3?
	if not WandPose.Bind(self) then return nil end
	return (self.parts.fist :: Attachment).WorldPosition
end

--[[
	Place the wand.

	`cf` is the fist: its position is where the pistol grip goes, and it looks down
	the aim line -- exactly what `CFrame.lookAt(WandPose.Grip(), aim)` gives, since
	the rig is built with -Z running down the lance.
]]
function WandPose.Apply(self: Class, rig: Model, cf: CFrame)
	-- the PISTOL GRIP goes in the fist, so the model is pivoted back off it
	rig:PivotTo(cf * CFrame.new(-GRIP_LOCAL))
	self.active = true
end

return WandPose
