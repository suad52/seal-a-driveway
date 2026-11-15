--!strict
--[[
	VipStandClient -- the turning squeegee on the VIP stand by the spawn, the two
	lines on its board that are different for every player, and the key that buys
	the pass.

	Every part of this is client-side and every part of it has to be:

	  THE TURN is a CFrame written every frame. Done on the server it would be a
	  model's worth of anchored parts replicating continuously to everybody in the
	  district, forever, so that one prop could rotate. Anchored parts moved from a
	  client do not replicate, so each player turns their own copy of the exhibit
	  and nobody fights anybody -- the arrangement RemoteToolsClient already runs
	  every other player's tools on.

	  WHETHER IT IS OWNED is a fact about ONE player, and the stand is a single
	  model in Workspace shared by the whole server. A server that wrote MEMBER
	  onto that board would put it in front of the entire lobby the moment one
	  person bought. Written here it is seen by the one player it is true of --
	  the same local-change-to-a-replicated-instance trick SealerUIClient uses to
	  hide one player's Store Rig key.

	  THE PRICE is Roblox's answer and can be retuned on the Creator Dashboard
	  without this place being republished, so it is asked for rather than typed.
	  Until it answers the board says how to buy rather than what it costs, and
	  the purchase dialog states the real terms either way -- which is the same
	  three-valued rule the Shop card follows, for the same reason.

	The prompt sells nothing itself and fires nothing at the server: it opens
	Roblox's own purchase dialog. PassService is already listening for the far end
	of that (PromptGamePassPurchaseFinished) and flips the attribute, which is what
	dresses this board, gilds the backpack and puts the boards on the lawns. There
	is no second purchase path to keep in step.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
-- For the three names the stand is identified by, rather than a second copy of
-- them here. A prompt nobody hooks draws its key and then does nothing, which is
-- indistinguishable from a broken game and leaves nothing in the log.
local VipStand = require(Pack:WaitForChild("VipStandBuilder"))
local UIPack = ReplicatedStorage:WaitForChild("SealerUI")
local Passes = require(UIPack:WaitForChild("Passes"))

local plr = Players.LocalPlayer
local PASS = Passes.ById.VIP

local GOLD = Color3.fromRGB(255, 206, 56)
local MINT = Color3.fromRGB(120, 236, 180)
local INK = Color3.fromRGB(38, 28, 8)

--[[
	Slow. A turntable at a third of a revolution a second is a display; anything
	brisker is a fairground ride, and this one is eight studs of gold beside the
	place every player in the server stands still for a moment.
]]
local TURN = 0.55        -- radians a second
local BOB = 0.16         -- studs either side of the authored height
local BOB_RATE = 1.1

--[[
	And it stops when nobody is near it.

	A PivotTo across the exhibit is cheap but it is not free, and there is no
	reason at all to pay it while the player is three districts away sealing a
	drive -- the stand is not even drawn from there. 140 studs is comfortably past
	the far side of the depot lawn, so it can never stop while it is on screen.
]]
local NEAR = 140

--==[ finding it ]============================================================

local stand: Model? = nil
local hero: Model? = nil
local priceText: string? = nil
local hooked: { [Instance]: boolean } = {}

--[[
	The pose the exhibit turns about, READ OFF THE EXHIBIT rather than told to us.

	This was a CFrame attribute the builder stamped on the model, and it was wrong
	the first time the stand was dragged somewhere else in Studio: an absolute world
	CFrame does not move with the model it describes, so the model went to the depot
	garage and this file went on pinning the squeegee to a patch of lawn eighty
	studs away. The stand looked right in Studio and lost its squeegee the moment a
	playtest started, which is about the worst way for that to present.

	Whatever the exhibit is standing at before this file has touched it IS the
	authored pose, so there is nothing to publish and nothing to keep in step.
	Moving, turning or rescaling the model in Studio now needs no code change at
	all.

	Captured once per hero instance and never again -- `posed` is which model `pose`
	belongs to. Re-reading it later would be a snapshot of the turn rather than of
	the pose, and the exhibit would creep. A model streamed out and back arrives as
	a new instance at the server's own pose, so that case re-captures correctly, and
	one whose parts alone came back keeps the pose it already had.
]]
local pose: CFrame? = nil
local posed: Model? = nil

local function dress()
	local m = stand
	if not m then return end
	local owned = Passes.owns(plr, PASS.id)

	local prompt = m:FindFirstChild(VipStand.PromptName, true) :: ProximityPrompt?
	if prompt then
		--[[
			Enabled rather than MaxActivationDistance, and safe here where it was not
			safe on a truck: nothing on the server ever writes to this prompt after
			VipStandBuilder makes it, so there is no server-side write to clobber this
			one. See the note over the yard rule in RemoteToolsClient for the case where
			that is not true.
		]]
		prompt.Enabled = not owned
	end

	local foot = m:FindFirstChild("Price", true) :: TextLabel?
	if foot then
		local strip = foot.Parent :: Frame?
		if owned then
			foot.Text = "YOU ARE A MEMBER"
			foot.TextColor3 = Color3.fromRGB(10, 40, 26)
			if strip then strip.BackgroundColor3 = MINT end
		else
			foot.Text = if priceText then ("PRESS E   \u{2022}   " .. priceText)
				else "WALK UP AND PRESS E"
			foot.TextColor3 = INK
			if strip then strip.BackgroundColor3 = GOLD end
		end
	end
end

local function hook(d: Instance)
	if d.Name ~= VipStand.PromptName or not d:IsA("ProximityPrompt") then return end
	if hooked[d] then return end
	hooked[d] = true
	d.Destroying:Connect(function() hooked[d] = nil end)
	d.Triggered:Connect(function()
		if Passes.owns(plr, PASS.id) then return end
		-- A pass with no asset id behind it is one nobody can own, and opening the
		-- dialog for id 0 is an error rather than a refusal. It cannot happen while
		-- VIP has an id, and costs one comparison to be sure it never does.
		if PASS.assetId == 0 then return end
		MarketplaceService:PromptGamePassPurchase(plr, PASS.assetId)
	end)
end

--[[
	Adopted and then WATCHED, never snapshotted.

	The stand is built Atomic so it should arrive whole, but "should" is what the
	shop terminal's binding assumed for a year before it was measured arriving
	empty -- see the note over that block in SealerUIClient. A model that turns up
	without its prompt costs nothing to wait for and everything to assume.
]]
local function adopt(m: Model)
	if stand == m then return end
	stand = m
	hero = m:FindFirstChild("GoldenSqueegee") :: Model?
	for _, d in ipairs(m:GetDescendants()) do hook(d) end
	m.DescendantAdded:Connect(function(d)
		hook(d)
		if d.Name == "GoldenSqueegee" and d:IsA("Model") then hero = d end
		if d.Name == "Price" then dress() end
	end)
	dress()
end

local function look(c: Instance)
	if c.Name == VipStand.ModelName and c:IsA("Model") then adopt(c) end
end

for _, c in ipairs(workspace:GetChildren()) do look(c) end
workspace.ChildAdded:Connect(look)

--==[ the turn ]==============================================================

local spun = 0

RunService.Heartbeat:Connect(function(dt)
	local h = hero
	if not h or not h.Parent then return end

	if h ~= posed then
		-- Gated on the PrimaryPart rather than on the model, because GetPivot falls
		-- back to a bounding box when the blade has not arrived -- and a pose taken
		-- off half a squeegee is one the exhibit would turn about forever.
		if not h.PrimaryPart then return end
		posed, pose = h, h:GetPivot()
	end
	local base = pose :: CFrame

	local ch = plr.Character
	local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then return end
	if (root.Position - base.Position).Magnitude > NEAR then return end

	spun += dt
	-- Position and rotation composed separately: the exhibit is tilted forward 38
	-- degrees, and turning it by multiplying that pose on the right would spin it
	-- about its own leaning axis -- a wobble, not a turntable.
	local lift = math.sin(spun * BOB_RATE) * BOB
	h:PivotTo(CFrame.new(base.Position + Vector3.new(0, lift, 0))
		* CFrame.Angles(0, spun * TURN, 0)
		* base.Rotation)
end)

--==[ what changes it ]=======================================================

plr:GetAttributeChangedSignal(Passes.attrName(PASS.id)):Connect(dress)

task.spawn(function()
	if PASS.assetId == 0 then return end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(PASS.assetId, Enum.InfoType.GamePass)
	end)
	if ok and type(info) == "table" and info.IsForSale and tonumber(info.PriceInRobux) then
		priceText = ("R$ %d"):format(tonumber(info.PriceInRobux) :: number)
		dress()
	end
end)

-- And if the stand is not there at all, say so. Silence is the one outcome that
-- cannot be told apart from a stand nobody has walked past yet.
task.delay(25, function()
	if not stand then
		warn(("[VipStandClient] no %s in Workspace after 25s -- the VIP stand by the"
			.. " spawn will not turn and its key will do nothing")
			:format(VipStand.ModelName))
	end
end)
