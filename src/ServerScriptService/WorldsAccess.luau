local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Config = require(game.ReplicatedStorage:WaitForChild("WorldsConfig"))
local environment = Config.resolve(game.PlaceId)
local Access = {}
local cache, loading = {}, {}
local store
if environment then
	store = DataStoreService:GetDataStore("WorldsAccess_v1_" .. environment .. (if RunService:IsStudio() then "_Studio" else ""))
end

function Access.isProduct(productId)
	return productId == Config.UnlockProductId
end

function Access.paid(userId)
	if cache[userId] ~= nil then return cache[userId], true end
	if not store then return false, false end
	local deadline = os.clock() + 15
	while loading[userId] do
		if os.clock() >= deadline then return false, false end
		task.wait(.1)
	end
	if cache[userId] ~= nil then return cache[userId], true end
	loading[userId] = true
	local ok, value = pcall(function() return store:GetAsync("u_" .. userId) end)
	loading[userId] = nil
	if ok and (value == nil or type(value) == "table") then
		-- A receipt may have granted access while GetAsync was yielding.
		cache[userId] = cache[userId] == true or (type(value) == "table" and value.World2 == true)
		return cache[userId], true
	end
	warn("[WorldsAccess] Could not load access for " .. userId .. ": " .. tostring(value))
	return false, false
end

function Access.publish(player)
	local paid, ready = Access.paid(player.UserId)
	if player.Parent ~= Players then return ready end
	player:SetAttribute("WorldsAccessReady", ready)
	if ready then player:SetAttribute("WorldsPaid2", paid) end
	if paid then player:SetAttribute("World2Unlocked", true) end
	return ready
end

function Access.processReceipt(info)
	if not Access.isProduct(info.ProductId) or not store then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, value = pcall(function()
		return store:UpdateAsync("u_" .. info.PlayerId, function(previous)
			if previous ~= nil and type(previous) ~= "table" then error("Invalid access record") end
			local data = table.clone(previous or {})
			data.World2 = true
			data.FirstReceipt = data.FirstReceipt or tostring(info.PurchaseId)
			return data
		end)
	end)
	if not ok or type(value) ~= "table" or value.World2 ~= true then
		warn("[WorldsAccess] Purchase save failed: " .. tostring(value))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	cache[info.PlayerId] = true
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if player then
		player:SetAttribute("WorldsPaid2", true)
		player:SetAttribute("WorldsAccessReady", true)
		player:SetAttribute("World2Unlocked", true)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

Players.PlayerRemoving:Connect(function(player)
	cache[player.UserId] = nil
end)
return Access
