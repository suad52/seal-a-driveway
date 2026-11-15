--!strict
--[[
	RaceEconomy -- what the race pays, and why almost none of it is written here.

	The brief was "the same payout structure as the other event -- the average of
	the people playing", and the honest way to build that is to USE the other
	event's, not to write a second one that agrees with it today.

	So the level definition, the average, the wallet lookup and the payment itself
	are all BattleEconomy's, reached straight through. What is left in this file is
	the two places a race genuinely differs from an arena match, and they are both
	about who counts as having taken part.

	WHAT IS BORROWED, AND WHY IT MUST BE

	  levelOf        one rung of one upgrade track, plus a whole ladder per
	                 rebirth. There is no stat called Level in this game and
	                 inventing a SECOND definition of one would mean the two events
	                 size their purses against different ladders while paying into
	                 the same wallet.
	  averageLevel   the lobby's, not the player's. A new player who wins against
	                 veterans is paid like a veteran, and a veteran who turns up to
	                 a lobby of beginners is paid like one -- which is what stops
	                 the event being farmed by the strongest account on the server.
	  pay            moves Cash AND Q_Earned together. The quest board and the TOP
	                 EARNERS leaderboard run on the second one, and a payout that
	                 moved the wallet without it would make the board disagree with
	                 the money.

	The purse TABLE is RaceConfig's, which reads it back off BattleConfig -- see the
	note there for why the two events are deliberately worth the same, and where to
	cut them apart if that ever stops being true.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BattleEconomy = require(ReplicatedStorage:WaitForChild("SqueegeeBattle")
	:WaitForChild("BattleEconomy"))
local Rebirth = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Rebirth"))

local Race = require(script.Parent.RaceConfig)

local RaceEconomy = {}

RaceEconomy.levelOf = BattleEconomy.levelOf
RaceEconomy.averageLevel = BattleEconomy.averageLevel
RaceEconomy.cashStat = BattleEconomy.cashStat

--==[ PURSE ]=================================================================
function RaceEconomy.purseMultiplier(roster: { Player }): number
	local avg = BattleEconomy.averageLevel(roster)
	return Race.PurseScale * Rebirth.multiplierAt(avg / BattleEconomy.TrackSpan)
end

function RaceEconomy.award(rank: number, mult: number): number
	local base = Race.PayoutBase[math.clamp(rank, 1, #Race.PayoutBase)]
	return math.floor(base * mult)
end

-- Paid for turning up, to everybody who started, whatever happened after. It is
-- what makes a race somebody was never going to win still worth the minute.
function RaceEconomy.showUp(mult: number): number
	return math.floor(Race.PayoutBase[1] * Race.ShowUpBonus * mult)
end

-- The whole payout table for a lobby, for the HUD to quote before the flag drops.
-- Same call the server makes when it pays, so the number on the screen during the
-- count-in is the number that lands in the wallet.
function RaceEconomy.previewFor(roster: { Player }): { number }
	local mult = RaceEconomy.purseMultiplier(roster)
	local bonus = RaceEconomy.showUp(mult)
	local out = {}
	for rank = 1, #Race.PayoutBase do
		out[rank] = RaceEconomy.award(rank, mult) + bonus
	end
	return out
end

--==[ WALLET ]================================================================
RaceEconomy.pay = BattleEconomy.pay

return RaceEconomy
