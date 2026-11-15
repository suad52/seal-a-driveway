--!strict
--[[
	CyberStandClient -- the key on the Cyberseal parked in the forecourt, and the
	two lines on its lectern that are different for every player.

	This is VipStandClient's job for a different pass, and it is client-side for
	the same two reasons written out at length there:

	  WHETHER IT IS OWNED is a fact about ONE player, and the stand is a single
	  model in Workspace shared by the whole server. A server that wrote OWNED
	  onto that board would put it in front of the entire lobby the moment one
	  person bought.

	  THE PRICE is Roblox's answer and can be retuned on the Creator Dashboard
	  without this place being republished, so it is asked for rather than typed.
	  Until it answers the board says how to buy rather than what it costs.

	The prompt sells nothing itself and fires nothing at the server: it opens
	Roblox's own purchase dialog. PassService is already listening for the far end
	of that (PromptGamePassPurchaseFinished) and flips the attribute; TruckServer's
	watchCyberPass turns that into the ordinary Upg_Cyberseal unlock and the rig
	is delivered. There is no second purchase path to keep in step.

	Which also answers "is it permanent": the pass is a game pass, so Roblox holds
	the record forever, and the unlock it writes is the same attribute a bought
	truck writes and is never written back to false. The truck survives a rebirth
	because every truck does.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local CyberStand = require(Pack:WaitForChild("CyberStandBuilder"))
local UIPack = ReplicatedStorage:WaitForChild("SealerUI")
local Passes = require(UIPack:WaitForChild("Passes"))
local Upgrades = require(UIPack:WaitForChild("Upgrades"))
local Rigs = require(Pack:WaitForChild("Rigs"))

local plr = Players.LocalPlayer
local PASS = Passes.ById.CyberRig

local MINT = Color3.fromRGB(120, 236, 180)
local GOLD = Color3.fromRGB(255, 206, 56)
local SUBTX = Color3.fromRGB(176, 190, 206)

local stand: Model? = nil
local priceText: string? = nil
local hooked: { [Instance]: boolean } = {}

local function find(name: string): TextLabel?
	local m = stand
	if not m then return nil end
	local t = m:FindFirstChild(name, true)
	return (t and t:IsA("TextLabel")) and t or nil
end

--[[
	Three states, and the middle one is the reason this is not a boolean.

	OWNED is read off the unlock rather than off the pass, deliberately. Somebody
	who holds Upg_Cyberseal already has the truck however they came by it, and a
	board offering to sell a pass for a truck already in the garage is the same
	defect the rig picker had before it was taught about passes.

	The unsold state -- a live listing with no price back yet, or a listing that
	does not exist at all -- says how to buy rather than what it costs, because a
	blank where a number should be reads as broken.
]]
local function dress()
	local m = stand
	if not m then return end
	local rig = Rigs.ById[CyberStand.RigId]
	local owned = Rigs.owns(plr, CyberStand.RigId)

	--[[
		The catalogue text, written here rather than authored into the saved model.

		This is DealershipSigns' job done for the one truck that has no showroom
		plate, and it exists because the alternative was measured failing: the
		lectern kept advertising a 42 the truck no longer had. It is per-frame-cheap
		and runs only when something actually changes.

		The four figures are in the same order and the same units the showroom's
		plates use, so the lectern outside and the buy panel inside can never tell
		two stories.
	]]
	if rig then
		local title = find("Title")
		if title then title.Text = rig.name end
		local tagline = find("Tagline")
		if tagline then tagline.Text = rig.tagline tagline.TextColor3 = rig.tint end
		local stats = find("Stats")
		if stats then
			stats.Text = ("%d spd  \u{2022}  %d hose\n%s tank  \u{2022}  x%.2f pump")
				:format(rig.topSpeed, rig.hose, Upgrades.short(rig.tank), rig.pump)
		end
	end

	local prompt = m:FindFirstChild(CyberStand.PromptName, true) :: ProximityPrompt?
	if prompt then
		-- Enabled rather than MaxActivationDistance, and safe here where it is not
		-- safe on a driveable rig: nothing on the server ever writes to this prompt
		-- after the stand is built, so there is no server write to clobber this one.
		prompt.Enabled = not owned
	end

	local price = find("Price")
	local note = find("Note")
	if owned then
		if price then price.Text = "YOURS" price.TextColor3 = MINT end
		if note then note.Text = "Call it up from the rig bay" note.TextColor3 = MINT end
	else
		if price then
			price.Text = priceText or "GAME PASS"
			price.TextColor3 = GOLD
		end
		if note then
			note.Text = if PASS and PASS.assetId ~= 0 then "Press E  \u{2022}  yours for good"
				else "Coming soon"
			note.TextColor3 = SUBTX
		end
	end
end

local function hook(d: Instance)
	if d.Name ~= CyberStand.PromptName or not d:IsA("ProximityPrompt") then return end
	if hooked[d] then return end
	hooked[d] = true
	d.Destroying:Connect(function() hooked[d] = nil end)
	d.Triggered:Connect(function()
		if Rigs.owns(plr, CyberStand.RigId) then return end
		-- A pass with no asset id behind it is one nobody can own, and opening the
		-- dialog for id 0 is an error rather than a refusal.
		if not PASS or PASS.assetId == 0 then return end
		MarketplaceService:PromptGamePassPurchase(plr, PASS.assetId)
	end)
end

--[[
	Adopted and then WATCHED, never snapshotted -- the same rule VipStandClient
	follows. A model that turns up without its prompt costs nothing to wait for
	and everything to assume; replication streams a model's children in after the
	model itself, which has silently killed features in this place before.
]]
local function adopt(m: Model)
	if stand == m then return end
	stand = m
	for _, d in ipairs(m:GetDescendants()) do hook(d) end
	m.DescendantAdded:Connect(function(d)
		hook(d)
		-- any of the five labels arriving late is a reason to redraw all of them;
		-- replication streams a model's children in after the model itself
		if d:IsA("TextLabel") then dress() end
	end)
	dress()
end

local function look(c: Instance)
	if c.Name == CyberStand.ModelName and c:IsA("Model") then adopt(c) end
end

for _, c in ipairs(workspace:GetChildren()) do look(c) end
workspace.ChildAdded:Connect(look)

--==[ what changes it ]=======================================================

-- The unlock, not the pass: see the note over `dress`. This is also what makes
-- a mid-session purchase redress the board without a refresh anywhere.
plr:GetAttributeChangedSignal("Upg_" .. CyberStand.RigId):Connect(dress)
if PASS then
	plr:GetAttributeChangedSignal(Passes.attrName(PASS.id)):Connect(dress)
end

task.spawn(function()
	if not PASS or PASS.assetId == 0 then return end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(PASS.assetId, Enum.InfoType.GamePass)
	end)
	if ok and type(info) == "table" and info.IsForSale and tonumber(info.PriceInRobux) then
		priceText = ("R$ %d"):format(tonumber(info.PriceInRobux) :: number)
		dress()
	end
end)

-- And if the stand is not there at all, say so. Silence is the one outcome that
-- cannot be told apart from a lot nobody has walked past yet.
task.delay(25, function()
	if not stand then
		warn(("[CyberStandClient] no %s in Workspace after 25s -- the Cyberseal on"
			.. " the forecourt will not sell its pass"):format(CyberStand.ModelName))
	end
end)
