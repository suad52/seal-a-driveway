--!strict
--[[
	VipService -- the three things the VIP pass hands over that a client cannot,
	and the stand it is sold from.

	  A nameplate, so it is worth having in front of other people.
	  A gold kit, for the same reason.
	  A pay packet once a UTC day.

	The fourth perk -- quicker on your feet -- is applied by SealerUIClient, where
	every other walk-speed effect already lives, so the ladder and the pass do not
	fight over the same property from two places.

	Nothing here saves anything except the day of the last packet, which rides in
	the ordinary profile (see UpgradeService, VIP_DAY_KEY). Ownership itself is
	Roblox's record and is re-asked every join by PassService -- a saved copy of a
	pass is a copy that outlives a refund.

	The stand by the spawn is at the bottom of this file. It is here rather than in
	a service of its own because it sells exactly this pass and shows exactly this
	file's gold kit, and a second server script whose whole job is one
	FindFirstChild is a file nobody remembers exists.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIPack = ReplicatedStorage:WaitForChild("SealerUI")
local Passes = require(UIPack:WaitForChild("Passes"))
local Rebirth = require(UIPack:WaitForChild("Rebirth"))
local Upgrades = require(UIPack:WaitForChild("Upgrades"))

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local ToolBuilder = require(Pack:WaitForChild("ToolBuilder"))
local VipStandBuilder = require(Pack:WaitForChild("VipStandBuilder"))

local DAY_KEY = "VipDay"

--[[
	What the daily packet is worth.

	Scaled by the rebirth multiplier rather than fixed, because a fixed figure is
	one that matters enormously on day one and is a rounding error by the third
	lap -- the same defect the flat call-out fee had before Economy was rewritten.
	This way it stays worth roughly what it was worth when they bought the pass.
]]
local DAILY_BASE = 40000

-- The game's one gold, defined where the gold kit is. The nameplate below has to
-- be the same yellow as the tools in the hands under it or they read as two
-- unrelated perks.
local GOLD = ToolBuilder.Gold

-- One UTC day, as a number that sorts. Deliberately not os.time() bucketed by
-- 86400: that drifts against the calendar and a player would see the packet
-- arrive at a different hour every day.
local function utcDay(): number
	local t = os.date("!*t")
	return (t :: any).year * 1000 + (t :: any).yday
end

--==[ the nameplate ]=========================================================

local function nameplate(character: Model)
	local head = character:FindFirstChild("Head")
	if not head or head:FindFirstChild("VipTag") then return end

	local bb = Instance.new("BillboardGui")
	bb.Name = "VipTag"
	bb.Size = UDim2.fromOffset(72, 26)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	-- Deliberately NOT AlwaysOnTop: a tag that draws through walls turns into a
	-- wallhack the moment two players are on opposite sides of the depot.
	bb.AlwaysOnTop = false
	bb.MaxDistance = 90
	bb.Parent = head

	local plate = Instance.new("Frame")
	plate.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
	plate.BorderSizePixel = 0
	plate.Size = UDim2.fromScale(1, 1)
	plate.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = plate
	local stroke = Instance.new("UIStroke")
	stroke.Color = GOLD
	stroke.Thickness = 2
	stroke.Parent = plate

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.LuckiestGuy
	label.Text = "VIP"
	label.TextColor3 = GOLD
	label.TextSize = 18
	label.Parent = plate
end

--==[ the gold kit ]==========================================================

--[[
	Re-tint the player's own tools.

	The tools live in StarterPack, which is shared by everybody, so a gold version
	cannot be built there -- it would gild the whole server. What IS per-player is
	the copy Roblox clones into each backpack on spawn, so the tint goes on after
	the clone, on the instances this player owns.

	WHAT gold means is ToolBuilder.gild's business and deliberately no longer this
	file's. The same call dresses the display squeegee on the stand outside, so the
	thing on the plinth is the thing that lands in the backpack -- and the list of
	which parts turn lives next to the code that builds them, where renaming one
	cannot quietly stop gilding it.

	All that is left here is finding the tools, ONE AT A TIME. gild matches by name
	through everything it is handed and the squeegee's top plate is called Head,
	like the thing on the player's shoulders; a whole character walked through it
	comes out with a gold ball for a face.
]]
local function gild(container: Instance)
	for _, tool in ipairs(container:GetChildren()) do
		if tool:IsA("Tool") then ToolBuilder.gild(tool) end
	end
end

local function gildAll(plr: Player)
	if not Passes.owns(plr, "VIP") then return end
	local pack = plr:FindFirstChildOfClass("Backpack")
	if pack then gild(pack) end
	if plr.Character then gild(plr.Character) end
end

--[[
	AND TOOLS THAT ARRIVE LATER, which is not a nicety -- it is the spray wand.

	The pail and the squeegee are cloned out of StarterPack on spawn, so a sweep at
	spawn time finds them. The wand is not: TruckServer BUILDS a fresh one out of
	ToolBuilder the moment somebody pulls it off their rig's reel, and parents it
	straight into the character. That happens minutes after the sweep, so a VIP
	took a grey lance off a gold truck -- the one tool the gilt list was extended
	to cover, arriving by the one route the sweep could not see.

	One connection per container, and gilding is idempotent: the colours are
	already what they will be set to and the glint refuses to add a second emitter,
	so the equip-and-unequip traffic this also catches costs a walk of six parts
	and changes nothing.
]]
local watched: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function watchTools(where: Instance, plr: Player)
	if watched[where] then return end
	watched[where] = true
	where.ChildAdded:Connect(function(c)
		if c:IsA("Tool") and Passes.owns(plr, "VIP") then ToolBuilder.gild(c) end
	end)
end

--==[ the daily packet ]======================================================

local function payDaily(plr: Player)
	if not Passes.owns(plr, "VIP") then return end
	-- The profile has to be in, or a returning player is paid again for a day they
	-- were already paid for -- the saved day arrives a second or two after they do.
	if not plr:GetAttribute("ProfileLoaded") then return end

	local today = utcDay()
	if (plr:GetAttribute(DAY_KEY) :: number?) == today then return end

	local ls = plr:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash") :: IntValue?
	if not cash then return end

	local amount = math.floor(DAILY_BASE * Rebirth.multiplierOf(plr))
	plr:SetAttribute(DAY_KEY, today)
	cash.Value += amount
	-- a packet is earnings, so the Turnover quest track sees it like any other pay
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + amount)

	local remotes = UIPack:FindFirstChild("Remotes")
	local result = remotes and remotes:FindFirstChild("BuyResult") :: RemoteEvent?
	if result then
		result:FireClient(plr, "VIP", true,
			("VIP packet \u{2022} $%s"):format(Upgrades.short(amount)))
	end
end

--==[ wiring ]================================================================

local function watch(plr: Player)
	-- The backpack is remade on respawn, so it is caught as it arrives rather than
	-- looked up once. Both containers are watched whether or not the pass is held:
	-- ownership is re-asked inside the handler, so a mid-session purchase gilds the
	-- next tool without needing the connections rebuilt.
	plr.ChildAdded:Connect(function(c)
		if c:IsA("Backpack") then watchTools(c, plr) end
	end)
	local pack = plr:FindFirstChildOfClass("Backpack")
	if pack then watchTools(pack, plr) end

	local function onCharacter(character: Model)
		watchTools(character, plr)
		if not Passes.owns(plr, "VIP") then return end
		nameplate(character)
		-- the backpack is refilled from StarterPack on spawn, so the tint has to be
		-- re-applied to the new copies rather than only once at join
		task.defer(gildAll, plr)
	end
	plr.CharacterAdded:Connect(onCharacter)
	if plr.Character then task.spawn(onCharacter, plr.Character) end

	--[[
		PassService answers a second or two into the session, and ProfileLoaded lands
		around the same time, so both perks are re-run when either arrives rather than
		once at join. Buying the pass mid-session takes the same path.
	]]
	local function refresh()
		if plr.Character then onCharacter(plr.Character) end
		payDaily(plr)
	end
	plr:GetAttributeChangedSignal(Passes.attrName("VIP")):Connect(refresh)
	plr:GetAttributeChangedSignal("ProfileLoaded"):Connect(refresh)
	refresh()
end

Players.PlayerAdded:Connect(watch)
for _, plr in ipairs(Players:GetPlayers()) do task.spawn(watch, plr) end

--==[ the stand by the spawn ]================================================
--[[
	Authored and adopted, which is the arrangement the showroom and the AFK yard
	already use: the model is saved into the place so it can be seen and edited in
	Studio like the rest of the world, and VipStandBuilder is both the recipe it
	was made from and the fallback for a place that has lost it.

	Nothing here dresses it. The board's price and its owned state are facts about
	one player, so VipStandClient writes both on that player's own screen -- see
	the note at the top of that file for why a server that wrote them would be
	showing the first buyer's answer to the entire lobby.
]]
if not workspace:FindFirstChild(VipStandBuilder.ModelName) then
	warn(("[VipService] no %s in Workspace -- building one from the recipe."
		.. " The saved model should be in the place; see VipStandBuilder.")
		:format(VipStandBuilder.ModelName))
	VipStandBuilder.build(VipStandBuilder.originCFrame(), workspace)
end
