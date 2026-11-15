--!strict
--[[
	FriendBonus -- +15% Cash per friend on the same server.

	Shared by the server (which counts friends and stamps the attribute) and the
	client (which reads the attribute for the HUD button and the payout figure),
	so the number on screen is always the number the server pays.
]]

local FriendBonus = {}

--==[ CONFIG ]================================================================

-- 15% extra Cash per friend sharing the server.
FriendBonus.BonusPerFriend = 0.15

-- Attribute the server writes onto each player: how many friends are on this
-- server with them right now.
FriendBonus.CountAttr = "FriendCount"

--==[ READING ]===============================================================

function FriendBonus.countOf(plr: Player?): number
	if not plr then return 0 end
	local n = plr:GetAttribute(FriendBonus.CountAttr)
	if type(n) ~= "number" then return 0 end
	return math.max(0, math.floor(n))
end

-- The multiplier to fold into every Cash payout: 1 + 0.15 * friendCount.
function FriendBonus.multiplierOf(plr: Player?): number
	return 1 + FriendBonus.BonusPerFriend * FriendBonus.countOf(plr)
end

-- The whole-number percent for the HUD button: 15 * friendCount.
function FriendBonus.bonusPercentOf(plr: Player?): number
	return FriendBonus.BonusPerFriend * 100 * FriendBonus.countOf(plr)
end

return FriendBonus
