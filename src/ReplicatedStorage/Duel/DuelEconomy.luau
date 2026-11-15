--!strict
--[[
	DuelEconomy -- what a duel is worth, and the four gates that bound it.

	THE SUM IS THE BRIEF'S, AND IT IS ONE LINE:

		prize = (A.leaderstats.Cash.Value + B.leaderstats.Cash.Value) / 2

	Which is `prizeFor` below, and everything else in this file exists because
	that line, on its own, is a money press.

	WHY IT IS A PRESS, SPELLED OUT, BECAUSE THE FIX ONLY MAKES SENSE AFTER IT

	The purse is MINTED rather than transferred -- the loser is not charged,
	because the brief says a duel is free to enter and free to accept. So put a
	player holding ten million next to one holding nothing, let the rich one lose
	on purpose, and five million appears out of the air in the poor one's wallet.
	Repeat. Nothing about that needs an exploit or a modified client; it is what
	the rule says to do, and two players in a Discord call can run it all day.

	It is also, in its honest form, a genuinely good feature -- a new player who
	beats a veteran walks away with a veteran's payday, which is the single best
	thing that can happen to them, and it is the same instinct BattleEconomy's
	average-level purse is built on. So the answer is not to change the sum. It is
	to bound how often it can be collected and how much one collection can move.

	THE FOUR GATES, AND WHICH HALF OF THE ATTACK EACH ONE TAKES

	  age       an account younger than Duel.MinAccountAgeDays is never paid a
	            purse. This is the alt gate, and it is the one an attacker cannot
	            cheaply wait out -- a farm needs a SUPPLY of fresh wallets to move
	            cash into, and a week each makes the supply the bottleneck.

	  pair      the same two players are paid for Duel.PairPaidLimit duels and
	            then duel each other for pride. This is the one that survives two
	            REAL, aged, legitimate accounts agreeing to trade wins -- which no
	            age check can ever see.

	  cooldown  Duel.PaidCooldown between paid duels, per player, across ALL
	            opponents -- so the pair gate cannot be walked around by keeping a
	            queue of partners.

	  cap       Duel.MaxPrize on one payout. The blast radius, for when a patient
	            attacker defeats the other three.

	A duel that fails any of them still RUNS -- it is a free game and refusing to
	let two people play it would be the wrong answer to all of this. It pays zero,
	and `reasonFor` says why so the client can put it on the card before anybody
	commits. Being told up front is the difference between a rule and a swindle.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Duel = require(script.Parent.DuelConfig)

local FriendBonus = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("FriendBonus"))

local DuelEconomy = {}

--==[ THE WALLET ]============================================================

function DuelEconomy.cashStat(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	if not ls then return nil end
	for _, name in ipairs(Duel.CashStats) do
		local v = ls:FindFirstChild(name)
		if v and v:IsA("IntValue") then return v end
	end
	return nil
end

function DuelEconomy.cashOf(plr: Player): number
	local v = DuelEconomy.cashStat(plr)
	return if v then v.Value else 0
end

--==[ THE SUM ]===============================================================

function DuelEconomy.prizeFor(a: Player, b: Player): number
	local pot = (DuelEconomy.cashOf(a) + DuelEconomy.cashOf(b)) * Duel.PrizeShare
	local prize = math.floor(pot)
	if prize < Duel.MinPrize then prize = Duel.MinPrize end
	if prize > Duel.MaxPrize then prize = Duel.MaxPrize end
	return prize
end

--==[ THE GATES ]=============================================================

local paidPairs: { [string]: number } = {}
local lastPaid: { [number]: number } = {}

-- Both orderings of a pair are the same pair. Sorted rather than concatenated in
-- call order, or A-challenges-B and B-challenges-A would keep two allowances.
local function pairKey(a: Player, b: Player): string
	local x, y = a.UserId, b.UserId
	if x > y then x, y = y, x end
	return x .. ":" .. y
end

local function ageDaysOf(plr: Player): number
	-- AccountAge is in days already, and is 0 for an account made today. It is one
	-- of the few facts about a player that a client cannot influence at all.
	return plr.AccountAge
end

function DuelEconomy.reasonFor(a: Player, b: Player): string?
	if ageDaysOf(a) < Duel.MinAccountAgeDays or ageDaysOf(b) < Duel.MinAccountAgeDays then
		return ("Accounts must be %d days old to play for cash")
			:format(Duel.MinAccountAgeDays)
	end

	-- Both of the next two are OFF by default -- zero means unlimited. See the note
	-- over them in DuelConfig for what that leaves covered and what it does not.
	if Duel.PairPaidLimit > 0
		and (paidPairs[pairKey(a, b)] or 0) >= Duel.PairPaidLimit then
		return ("You have already played %s for cash %d times")
			:format(b.DisplayName, Duel.PairPaidLimit)
	end

	if Duel.PaidCooldown > 0 then
		local now = os.clock()
		for _, plr in ipairs({ a, b }) do
			local since = now - (lastPaid[plr.UserId] or -math.huge)
			if since < Duel.PaidCooldown then
				return ("%s has to wait %ds before another duel pays out")
					:format(plr.DisplayName, math.ceil(Duel.PaidCooldown - since))
			end
		end
	end

	return nil
end

function DuelEconomy.notePaid(a: Player, b: Player)
	local key = pairKey(a, b)
	paidPairs[key] = (paidPairs[key] or 0) + 1
	local now = os.clock()
	lastPaid[a.UserId] = now
	lastPaid[b.UserId] = now
end

-- How many paid duels this pair has left, for the challenge card. math.huge when
-- the limit is off, which is the honest answer rather than a misleading zero.
function DuelEconomy.pairRemaining(a: Player, b: Player): number
	if Duel.PairPaidLimit <= 0 then return math.huge end
	return math.max(0, Duel.PairPaidLimit - (paidPairs[pairKey(a, b)] or 0))
end

--==[ PAYING ]================================================================

function DuelEconomy.pay(plr: Player, amount: number): number
	if amount <= 0 then return 0 end
	amount = math.floor(amount * FriendBonus.multiplierOf(plr))
	if amount <= 0 then return 0 end
	local cash = DuelEconomy.cashStat(plr)
	if not cash then
		warn(("[Duel] %s has no cash leaderstat -- %d not paid"):format(plr.Name, amount))
		return 0
	end
	cash.Value += amount
	plr:SetAttribute("Q_Earned", ((plr:GetAttribute("Q_Earned") :: number?) or 0) + amount)
	return amount
end

Players.PlayerRemoving:Connect(function(plr)
	lastPaid[plr.UserId] = nil
end)

return DuelEconomy
