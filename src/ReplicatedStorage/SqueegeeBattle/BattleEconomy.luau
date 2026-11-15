--!strict
--[[
	BattleEconomy -- what the arena pays, and why it is not a flat table.

	The brief's purse was 500 / 300 / 150 / 50, scaled by the average LEVEL of
	the players in the match. This game has no stat called Level, so the first
	job here is to define one out of what progression actually exists, and the
	second is to make the purse ride the same curve every other payout in the
	game already rides.

	WHAT A LEVEL IS HERE

	Two ladders, and a player's standing is both of them:

	  * five upgrade tracks (Rebirth.Tracks), each 14 to 16 rungs
	  * rebirths, which wind those tracks back to 1 and are unbounded

	So one "level" is one rung of one track, and a rebirth is worth a complete
	set of them -- TrackSpan below, which is 68 at the time of writing and is
	DERIVED from Upgrades rather than typed, so adding a rung to a track moves it
	on its own.

	    level(p) = rebirths * TrackSpan + sum(Upg_<track> - 1)

	A brand new account is 0. A rebirth-0 player with everything maxed is 68. A
	player five rebirths deep with a fresh ladder is 340.

	WHY THE PURSE IS THE REBIRTH CURVE AND NOT A NEW ONE

	Rebirth.multiplierAt is what multiplies every driveway, every tip and every
	AFK tick in the game. Inventing a second curve for the arena would mean the
	event drifts out of step with the economy the moment either is retuned --
	and this event pays out in the same wallet. So the average level is converted
	back into FRACTIONAL REBIRTHS (level / TrackSpan) and handed to the game's own
	curve. A lobby averaging one full ladder is paid as rebirth 1; a lobby
	averaging five rebirths' worth of progress is paid as rebirth 5.

	It lands where you would want it to. At every rung, first place is worth
	roughly one Maple driveway:

	    avg level    multiplier      1st        2nd        3rd     4th-8th
	         0           1.00      6,000      3,600      1,800        600
	        68           5.28     31,700     19,000      9,500      3,170
	       340          71.60    429,600    257,700    128,900     42,960

	AND IT IS THE LOBBY'S AVERAGE, NOT THE PLAYER'S OWN

	That is what the brief asked for and it is the right call for a competitive
	event: everyone in the arena is playing for the same purse, so the ranking is
	the only thing that decides who gets what. A new player who wins against
	veterans is paid like a veteran, which is the best thing that can happen to
	them, and a veteran who turns up to a lobby of beginners is paid like one,
	which is what stops the event being farmed by the strongest account on the
	server.

	OwnMultFloor is the lever if that last property is ever unwanted -- see below.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local Rebirth = require(SealerUI:WaitForChild("Rebirth"))
local Upgrades = require(SealerUI:WaitForChild("Upgrades"))

local Battle = require(script.Parent.BattleConfig)

local FriendBonus = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("FriendBonus"))

local BattleEconomy = {}

local TrackSpan = 0
for _, id in ipairs(Rebirth.Tracks) do
	TrackSpan += math.max(0, Upgrades.maxLevel(id) - 1)
end

if TrackSpan <= 0 then TrackSpan = 1 end
BattleEconomy.TrackSpan = TrackSpan

BattleEconomy.OwnMultFloor = 0

--==[ LEVEL ]=================================================================
function BattleEconomy.levelOf(plr: Player): number
	local level = Rebirth.countOf(plr) * TrackSpan
	for _, id in ipairs(Rebirth.Tracks) do
		local lv = plr:GetAttribute("Upg_" .. id)
		if type(lv) == "number" then
			-- clamped against the track's own length, so a stale profile carrying a
			-- level from a longer ladder cannot inflate the purse
			level += math.clamp(math.floor(lv), 1, Upgrades.maxLevel(id)) - 1
		end
	end
	return level
end

function BattleEconomy.rankOf(plr: Player): string
	return Rebirth.rankAt(Rebirth.countOf(plr))
end

--==[ PURSE ]=================================================================
function BattleEconomy.averageLevel(roster: { Player }): number
	if #roster == 0 then return 0 end
	local total = 0
	for _, plr in ipairs(roster) do
		total += BattleEconomy.levelOf(plr)
	end
	return total / #roster
end


function BattleEconomy.purseMultiplier(roster: { Player }, plr: Player?): number
	local avg = BattleEconomy.averageLevel(roster)
	local mult = Battle.PurseScale * Rebirth.multiplierAt(avg / TrackSpan)

	if plr and BattleEconomy.OwnMultFloor > 0 then
		local own = Battle.PurseScale * Rebirth.multiplierOf(plr)
		local floor = own * BattleEconomy.OwnMultFloor
		if floor > mult then mult = floor end
	end
	return mult
end

function BattleEconomy.award(rank: number, mult: number): number
	local base = Battle.PayoutBase[math.clamp(rank, 1, #Battle.PayoutBase)]
	return math.floor(base * mult)
end

function BattleEconomy.showUp(mult: number): number
	return math.floor(Battle.PayoutBase[1] * Battle.ShowUpBonus * mult)
end

function BattleEconomy.previewFor(roster: { Player }): { number }
	local mult = BattleEconomy.purseMultiplier(roster)
	local bonus = BattleEconomy.showUp(mult)
	local out = {}
	for rank = 1, #Battle.PayoutBase do
		out[rank] = BattleEconomy.award(rank, mult) + bonus
	end
	return out
end

--==[ WALLET ]================================================================

function BattleEconomy.cashStat(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then return nil end
	for _, name in ipairs(Battle.CashStats) do
		local v = ls:FindFirstChild(name)
		if v and v:IsA("IntValue") then return v end
	end
	return nil
end

function BattleEconomy.pay(plr: Player, amount: number): number
	if amount <= 0 then return 0 end
	amount = math.floor(amount * FriendBonus.multiplierOf(plr))
	if amount <= 0 then return 0 end
	local cash = BattleEconomy.cashStat(plr)
	if not cash then
		warn(("[SqueegeeBattle] %s has no cash leaderstat -- %d not paid")
			:format(plr.Name, amount))
		return 0
	end
	cash.Value += amount
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + amount)
	return amount
end

return BattleEconomy
