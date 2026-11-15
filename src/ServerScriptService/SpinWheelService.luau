local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Boosts = require(ReplicatedStorage.SealerUI:WaitForChild("Boosts"))
local ColorShop = require(script.Parent:WaitForChild("ColorShopService"))
local RobotService = require(script.Parent:WaitForChild("RobotService"))

local SpinWheel = {}
SpinWheel.Product3 = 3714513637
SpinWheel.Product10 = 3714513685
SpinWheel.FreeInterval = 20 * 60
SpinWheel.SpinDuration = 4

SpinWheel.Rewards = {
	{ id = "cash5000", name = "5,000 cash", chance = 35, index = 5 },
	{ id = "cash20000", name = "20k cash", chance = 24, index = 2 },
	{ id = "cash60000", name = "60k cash", chance = 23, index = 3 },
	{ id = "helper", name = "1 time helper use", chance = 15, index = 6 },
	{ id = "instantCoat", name = "1 time instant coat", chance = 2, index = 1 },
	{ id = "vivid", name = "Vivid rainbow sealer color", chance = 1, index = 4 },
}

local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage.SealerUI
end
local remote = remotes:FindFirstChild("SpinWheel")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "SpinWheel"
	remote.Parent = remotes
end

local save: ((Player) -> boolean)?
local profileReady: ((Player) -> boolean)?
local lastAction: { [Player]: number } = {}
local spinning: { [Player]: boolean } = {}
local started = false

function SpinWheel.capture(player: Player, data: { [string]: any })
	data.SpinCount = math.max(0, math.floor((player:GetAttribute("SpinCount") :: number?) or 0))
	local nextAt = player:GetAttribute("SpinNextFreeAt")
	data.SpinNextFreeAt = if type(nextAt) == "number" then nextAt else nil
end

function SpinWheel.restore(player: Player, data: { [string]: any })
	player:SetAttribute("SpinCount", math.max(0, math.floor(tonumber(data.SpinCount) or 0)))
	local nextAt = tonumber(data.SpinNextFreeAt)
	player:SetAttribute("SpinNextFreeAt", nextAt or (workspace:GetServerTimeNow() + SpinWheel.FreeInterval))
end

function SpinWheel.isProduct(productId: number): boolean
	return productId == SpinWheel.Product3 or productId == SpinWheel.Product10
end

function SpinWheel.productSpins(productId: number): number
	return if productId == SpinWheel.Product3 then 3 else 10
end

local function notify(player: Player, action: string, ...: any)
	if player.Parent then remote:FireClient(player, action, ...) end
end

local function chooseReward()
	local totalChance = 0
	for _, reward in SpinWheel.Rewards do
		totalChance += reward.chance
	end
	
	local roll = math.random(1, totalChance)
	
	local total = 0
	for _, reward in SpinWheel.Rewards do
		total += reward.chance
		if roll <= total then
			return reward 
		end
	end
	return SpinWheel.Rewards[#SpinWheel.Rewards]
end

local function grant(player: Player, reward): boolean
	if reward.id == "cash5000" or reward.id == "cash20000" or reward.id == "cash60000" then
		local values = { cash5000 = 5000, cash20000 = 20000, cash60000 = 60000 }
		local stats = player:FindFirstChild("leaderstats")
		local cash = stats and stats:FindFirstChild("Cash")
		if not cash or not cash:IsA("IntValue") then return false end
		cash.Value += values[reward.id]
		return true
	elseif reward.id == "helper" then
		return RobotService.grantCredit(player) == true
	elseif reward.id == "instantCoat" then
		local boost = Boosts.ById.Endless
		local attr = Boosts.attrName(boost.id)
		local now = Boosts.now()
		local from = math.max(now, (player:GetAttribute(attr) :: number?) or 0)
		player:SetAttribute(attr, from + boost.seconds)
		return true
	elseif reward.id == "vivid" then
		return ColorShop.grantForWheel(player, "vivid")
	end
	return false
end

local function spin(player: Player)
	if profileReady and not profileReady(player) then 
		return 
	end
	if spinning[player] then return end
	local count = (player:GetAttribute("SpinCount") :: number?) or 0
	if count <= 0 then
		notify(player, "Message", "You have no spins available.")
		return
	end
	player:SetAttribute("SpinCount", count - 1)
	local reward = chooseReward()
	spinning[player] = true
	notify(player, "Reward", reward.id, reward.index, reward.name)
	task.delay(SpinWheel.SpinDuration, function()
		spinning[player] = nil
		if not player.Parent then return end
		if not grant(player, reward) then
			player:SetAttribute("SpinCount", ((player:GetAttribute("SpinCount") :: number?) or 0) + 1)
			notify(player, "Message", "The reward could not be granted. Please try again.")
			return
		end
		-- StellarQuest successful spin
		require(game.ServerScriptService.StellarQuestService).record(player,"spin",1)
		if save then
			task.spawn(save, player)
		end
	end)
end

function SpinWheel.start(saveFn: (Player) -> boolean, readyFn: (Player) -> boolean)
	if started then return end
	started = true
	save = saveFn
	profileReady = readyFn
	remote.OnServerEvent:Connect(function(player, action: any, productId: any)
		if type(action) ~= "string" then return end
		local now = os.clock()
		if now - (lastAction[player] or -math.huge) < 0.2 then return end
		lastAction[player] = now
		if action == "Spin" then
			spin(player)
		elseif action == "Buy" and (productId == 3 or productId == 10) then
			MarketplaceService:PromptProductPurchase(player, if productId == 3 then SpinWheel.Product3 else SpinWheel.Product10)
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("SpinCount", player:GetAttribute("SpinCount") or 0)
		player:SetAttribute("SpinNextFreeAt", player:GetAttribute("SpinNextFreeAt") or workspace:GetServerTimeNow() + SpinWheel.FreeInterval)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
		spinning[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute("SpinCount", player:GetAttribute("SpinCount") or 0)
		player:SetAttribute("SpinNextFreeAt", player:GetAttribute("SpinNextFreeAt") or workspace:GetServerTimeNow() + SpinWheel.FreeInterval)
	end

	task.spawn(function()
		while true do
			task.wait(1)
			local now = workspace:GetServerTimeNow()
			for _, player in ipairs(Players:GetPlayers()) do
				local nextAt = player:GetAttribute("SpinNextFreeAt")
				if type(nextAt) == "number" and now >= nextAt and (not profileReady or profileReady(player)) then
					local count = (player:GetAttribute("SpinCount") :: number?) or 0
					player:SetAttribute("SpinCount", count + 1)
					player:SetAttribute("SpinNextFreeAt", now + SpinWheel.FreeInterval)
					if save then task.spawn(save, player) end
					notify(player, "FreeSpin", count + 1)
				end
			end
		end
	end)
end

function SpinWheel.grantPurchased(player: Player, productId: number): boolean
	local count = (player:GetAttribute("SpinCount") :: number?) or 0
	player:SetAttribute("SpinCount", count + SpinWheel.productSpins(productId))
	notify(player, "Purchased", SpinWheel.productSpins(productId))
	return true
end

return SpinWheel
