-- GroupRewardService -- handles the group join reward claim.
--
-- A player who has joined the Roblox group 261071327 may claim a one-time
-- reward of 50,000 cash and one Instant Coat (Endless) boost activation.
-- The claim is persisted in its own DataStore so it survives a rejoin.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Boosts = require(ReplicatedStorage.SealerUI.Boosts)

local GROUP_ID = 261071327
local REWARD_CASH = 50000
local BOOST_ID = "Endless"
local STORE_NAME = "GroupReward_v1"
local MAX_CASH = 2 ^ 31 - 1

-- Find or create the RemoteEvent
local remotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = ReplicatedStorage.SealerUI
end

local remote = remotes:FindFirstChild("GroupReward")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "GroupReward"
	remote.Parent = remotes
end

-- DataStore for persisting claims across sessions
local store
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = ok and s or nil
	if not store then
		warn("[GroupRewardService] No DataStore access -- claims will not persist.")
	end
end

local function cashOf(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	return ls and ls:FindFirstChild("Cash") :: IntValue? or nil
end

-- Grant one activation of the Endless boost, stacking from the current deadline
local function grantBoost(plr: Player)
	local boost = Boosts.ById[BOOST_ID]
	if not boost then return end
	local attr = Boosts.attrName(BOOST_ID)
	local now = Boosts.now()
	local from = plr:GetAttribute(attr) :: number? or 0
	if from < now then from = now end
	plr:SetAttribute(attr, from + boost.seconds)
end

-- In-memory claim cache for the session
local claimed: { [Player]: boolean } = {}

local function loadClaim(plr: Player)
	if not store then return end
	local ok, data = pcall(function()
		return store:GetAsync("g_" .. plr.UserId)
	end)
	if ok and data then
		claimed[plr] = true
	end
end

local function saveClaim(plr: Player)
	if not store then return end
	pcall(function()
		store:SetAsync("g_" .. plr.UserId, true)
	end)
end

-- Load claim status on join
Players.PlayerAdded:Connect(function(plr)
	task.spawn(loadClaim, plr)
end)
for _, plr in ipairs(Players:GetPlayers()) do
	task.spawn(loadClaim, plr)
end

Players.PlayerRemoving:Connect(function(plr)
	claimed[plr] = nil
end)

remote.OnServerEvent:Connect(function(plr)
	-- Already claimed this reward
	if claimed[plr] then
		remote:FireClient(plr, "already_claimed")
		return
	end

	-- Check group membership
	local inGroup = false
	local ok = pcall(function()
		inGroup = plr:IsInGroup(GROUP_ID)
	end)

	if not ok or not inGroup then
		remote:FireClient(plr, "not_in_group")
		return
	end

	-- Grant cash reward
	local cash = cashOf(plr)
	if not cash then
		remote:FireClient(plr, "error")
		return
	end
	cash.Value = math.clamp(cash.Value + REWARD_CASH, 0, MAX_CASH)

	-- Grant one Endless boost activation
	grantBoost(plr)

	-- Mark as claimed and persist
	claimed[plr] = true
	saveClaim(plr)

	remote:FireClient(plr, "success")
end)