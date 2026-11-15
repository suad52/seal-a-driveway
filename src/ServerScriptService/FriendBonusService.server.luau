--!strict
--[[
	FriendBonusService -- counts how many of a player's friends are on the same
	server and stamps the count onto a player attribute.

	FriendBonus (ReplicatedStorage.SealerUI.FriendBonus) reads that attribute to
	produce the +15%-per-friend multiplier that every Cash payout in the game folds
	into its product. The attribute is replicated, so the client reads the same
	figure for the HUD button.

	Friendship is checked with Player:IsFriendsWith, which yields and is cached
	per pair so a player leaving does not re-check the whole server. The cache is
	per-session: two players who become friends while in the same server will not
	see the bonus update until one rejoins, which is an acceptable trade-off for
	keeping this off a polling loop.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FriendBonus = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("FriendBonus"))

--==[ FRIENDSHIP CACHE ]======================================================

-- friendCache[userIdA][userIdB] = true/false, symmetric. Avoids re-calling
-- IsFriendsWith on every join/leave for pairs already checked this session.
local friendCache: { [number]: { [number]: boolean } } = {}

local function areFriends(a: Player, b: Player): boolean
	local aId, bId = a.UserId, b.UserId
	if aId == bId then return false end

	if friendCache[aId] and friendCache[aId][bId] ~= nil then
		return friendCache[aId][bId]
	end

	local ok, result = pcall(function()
		return a:IsFriendsWith(bId)
	end)
	local isFriend = ok and result or false

	friendCache[aId] = friendCache[aId] or {}
	friendCache[aId][bId] = isFriend
	friendCache[bId] = friendCache[bId] or {}
	friendCache[bId][aId] = isFriend

	return isFriend
end

--==[ COUNTING ]==============================================================

local function countFriends(plr: Player): number
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= plr and areFriends(plr, other) then
			count += 1
		end
	end
	return count
end

local function updatePlayer(plr: Player)
	local count = countFriends(plr)
	plr:SetAttribute(FriendBonus.CountAttr, count)
end

local function updateAll()
	for _, plr in ipairs(Players:GetPlayers()) do
		updatePlayer(plr)
	end
end

--==[ JOIN / LEAVE ]==========================================================

local function onPlayerAdded(plr: Player)
	task.spawn(function()
		-- Check friendship with every existing player. This yields; doing it in a
		-- task so the rest of the join is not held up.
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= plr then
				areFriends(plr, other)
			end
		end
		updateAll()
	end)
end

local function onPlayerRemoving(plr: Player)
	-- Drop this player from the cache entirely.
	friendCache[plr.UserId] = nil
	for _, other in ipairs(Players:GetPlayers()) do
		if friendCache[other.UserId] then
			friendCache[other.UserId][plr.UserId] = nil
		end
	end
	-- Update remaining players' counts (the leaving player was a friend to some).
	task.spawn(updateAll)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players already in the game when the script starts.
for _, plr in ipairs(Players:GetPlayers()) do
	onPlayerAdded(plr)
end
