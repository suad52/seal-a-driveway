local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Config = require(RS:WaitForChild("WorldsConfig"))
local Access = require(SSS:WaitForChild("WorldsAccess"))
local Sections = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local environment, world = Config.resolve(game.PlaceId)

local function remote(name)
	local item = RS:FindFirstChild(name)
	if item then
		assert(item:IsA("RemoteEvent"), "Wrong class: " .. name)
		return item
	end
	item = Instance.new("RemoteEvent")
	item.Name = name
	item.Parent = RS
	return item
end

local status = remote("WorldPortalStatus")
local request = remote("WorldsRequest")
local busy, last, buying, hooked = {}, {}, {}, {}

local function notice(player, message)
	if player.Parent == Players then
		status:FireClient(player, message)
	end
end

local function allowed(player, destination)
	if destination == 1 or world == 2 then return true end
	if player:GetAttribute("WorldsPaid2") == true or player:GetAttribute("World2Unlocked") == true then return true end
	for _, section in ipairs(Sections.List) do
		if section.id == "NewZone" then
			local done, total = Sections.progressOf(player, section)
			return total > 0 and done >= total
		end
	end
	return false
end

local function refresh(player)
	if player.Parent ~= Players then return end
	player:SetAttribute("WorldsCurrent", world or 0)
	player:SetAttribute("WorldsEnvironment", environment or "Unknown")
	local ready = world ~= nil and player:GetAttribute("ProfileLoaded") == true
	player:SetAttribute("WorldsReady", ready)
	player:SetAttribute("WorldsCanTravel2", ready and allowed(player, 2))
end

local function travel(player, destination)
	if destination ~= 1 and destination ~= 2 then return end
	if busy[player] or os.clock() - (last[player] or -10) < 3 then return end
	last[player] = os.clock()
	if not world then notice(player, "This place is not configured for world travel."); return end
	if destination == world then notice(player, "You are already in this world."); return end
	if player:GetAttribute("ProfileLoaded") ~= true then notice(player, "Please wait for your save."); return end
	if not allowed(player, destination) then
		notice(player, "Finish World 1 to unlock World 2, or unlock it permanently in Worlds.")
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then notice(player, "Please wait for your character."); return end
	if humanoid.SeatPart then notice(player, "Leave your vehicle before travelling."); return end
	local target = Config.destination(game.PlaceId, destination)
	if not target then notice(player, "World destination is unavailable."); return end
	if RunService:IsStudio() then
		notice(player, "World " .. destination .. " is unlocked. Test teleporting in the published game.")
		return
	end
	busy[player] = {target = target}
	player:SetAttribute("WorldsTravelling", true)
	notice(player, "Saving progress and travelling to World " .. destination .. "...")
	local ok, err = pcall(function()
		if destination == 2 then player:SetAttribute("World2Unlocked", true) end
		local save = SSS:WaitForChild("WorldTravelSave", 10)
		if not save or not save:IsA("BindableFunction") or not save:Invoke(player) then
			error("Save could not be confirmed")
		end
		if player.Parent ~= Players then return end
		local options = Instance.new("TeleportOptions")
		options:SetTeleportData({WorldPortalArrival = true})
		TeleportService:TeleportAsync(target, {player}, options)
	end)
	if not ok then
		busy[player] = nil
		player:SetAttribute("WorldsTravelling", false)
		warn("[WorldPortal] " .. tostring(err))
		notice(player, "Travel failed. Your progress was not reset. Please try again.")
	end
end

local function buy(player)
	if not world or busy[player] or buying[player] or os.clock() - (last[player] or -10) < 3 then return end
	last[player] = os.clock()
	if player:GetAttribute("ProfileLoaded") ~= true then notice(player, "Please wait for your save."); return end
	if allowed(player, 2) then notice(player, "World 2 is already unlocked."); return end
	if player:GetAttribute("WorldsAccessReady") ~= true then
		notice(player, "Your world access is still loading. Please try again shortly.")
		return
	end
	buying[player] = true
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, Config.UnlockProductId)
	end)
	if not ok then
		buying[player] = nil
		warn("[Worlds] Purchase prompt failed: " .. tostring(err))
		notice(player, "Purchase is unavailable. Please try again.")
	end
end

request.OnServerEvent:Connect(function(player, action, destination)
	if action == "Travel" then
		travel(player, destination)
	elseif action == "BuyWorld2" then
		buy(player)
	end
end)

MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
	if productId ~= Config.UnlockProductId then return end
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end
	if purchased then
		notice(player, "Purchase submitted. Waiting for confirmation...")
	else
		buying[player] = nil
	end
end)

TeleportService.TeleportInitFailed:Connect(function(player, _, message, target)
	if busy[player] and busy[player].target == target then
		busy[player] = nil
		player:SetAttribute("WorldsTravelling", false)
		notice(player, "Travel failed. Please try again.")
		warn("[WorldPortal] " .. tostring(message))
	end
end)

local function hookPortal(part)
	if not world
		or part.Name ~= (if world == 1 then "PortalToWorld2" else "PortalToWorld1")
		or not part:IsA("BasePart")
		or hooked[part]
	then
		return
	end

	hooked[part] = true

	local prompt = part:FindFirstChild("WorldTravelPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
	end

	assert(prompt:IsA("ProximityPrompt"), "WorldTravelPrompt must be a ProximityPrompt")
	prompt.Name = "WorldTravelPrompt"
	prompt.ActionText = "Travel"
	prompt.ObjectText = if world == 1 then "World 2" else "World 1"
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0.5
	prompt.Parent = part

	part.CanTouch = false

	prompt.Triggered:Connect(function(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - part.Position).Magnitude <= 24 then
			travel(player, 3 - world)
		end
	end)
end

workspace.ChildAdded:Connect(hookPortal)
for _, item in ipairs(workspace:GetChildren()) do
	hookPortal(item)
end

local initialized = {}

local function joined(player)
	if initialized[player] then return end
	initialized[player] = true

	for _, name in ipairs({"ProfileLoaded", "World2Unlocked", "WorldsPaid2", Sections.SealedAttr, Sections.NowAttr}) do
		player:GetAttributeChangedSignal(name):Connect(function()
			refresh(player)
		end)
	end

	player:GetAttributeChangedSignal("WorldsPaid2"):Connect(function()
		if player:GetAttribute("WorldsPaid2") == true then
			buying[player] = nil
			notice(player, "World 2 is permanently unlocked!")
		end
	end)

	refresh(player)

	task.spawn(function()
		while player.Parent == Players and not Access.publish(player) do
			task.wait(30)
		end
		refresh(player)
	end)

	local data = player:GetJoinData()
	if type(data.TeleportData) == "table" and data.TeleportData.WorldPortalArrival == true then
		last[player] = os.clock() + 5
	end
end

Players.PlayerAdded:Connect(joined)
Players.PlayerRemoving:Connect(function(player)
	busy[player] = nil
	last[player] = nil
	buying[player] = nil
	initialized[player] = nil
end)
for _, player in ipairs(Players:GetPlayers()) do
	joined(player)
end

print("[Worlds] Ready: " .. tostring(environment) .. ", World " .. tostring(world))
