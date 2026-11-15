--!strict
--[[
	Rebirth -- starting the whole business again, bigger.

	Rebirth and the business restarts from a single pail: the cash goes, the four
	upgrade tracks wind back to level 1, and every driveway you had sealed goes
	back to bare concrete to be sealed again. What you keep is the reputation you
	earned getting there, and that is a permanent multiplier on every job you will
	ever finish.

	What it COSTS is the lap, not the money. See the ladder below.

	Shared by the server, which owns the ledger and is the only thing allowed to
	agree to a rebirth, and by the client, which draws the panel and the running
	job value. Both read the curve from here so the figure on the HUD and the
	figure the till checks cannot disagree -- the same rule Upgrades already
	follows.
]]

local Rebirth = {}

-- Kept on the Player as an attribute, like the upgrade levels, so it replicates
-- on its own and every reader just watches it rather than asking for it.
Rebirth.Attr = "Rebirths"

Rebirth.BaseShare = 60   -- percent of the open map the first rebirth wants
Rebirth.SharePer  = 5    -- and this many more points per rebirth after it

Rebirth.ReachAttr = "LapSlabs"   -- number: slabs open to this player at all
Rebirth.DoneAttr  = "LapSealed"  -- number: how many of those are sealed this lap

Rebirth.PayPower = 2.4

Rebirth.DiscountPer   = 0.09
Rebirth.DiscountFloor = 0.35
Rebirth.Tracks = { "Tank", "Refill", "Blade", "Pour", "Speed" }

-- One rung per rebirth, and one spare on the end for the last NAMED one.
Rebirth.Ranks = {
	"Sole Trader",
	"Two-Truck Outfit",
	"Yard Crew",
	"Regional Contractor",
	"County Contractor",
	"Statewide Outfit",
	"National Contractor",
	"Franchise",
	"Sealcoat Empire",
	"Industry Legend",
	"Household Name",
	"Sealcoat Dynasty",
	"Retired Rich",
}

Rebirth.Ladder = #Rebirth.Ranks - 1

function Rebirth.countOf(plr: Player?): number
	if not plr then return 0 end
	local n = (plr :: Player):GetAttribute(Rebirth.Attr)
	-- Floored at zero and nothing else. There is no top to clamp to any more, and
	-- clamping to one would quietly delete rebirths the player actually took.
	return if type(n) == "number" then math.max(0, math.floor(n)) else 0
end

-- Slabs open to this player at all, and how many of them are sealed on the
-- current lap. Both are the server's count -- see the note on ReachAttr.
function Rebirth.reachOf(plr: Player?): number
	if not plr then return 0 end
	local n = (plr :: Player):GetAttribute(Rebirth.ReachAttr)
	return if type(n) == "number" then math.max(0, math.floor(n)) else 0
end

function Rebirth.doneOf(plr: Player?): number
	if not plr then return 0 end
	local n = (plr :: Player):GetAttribute(Rebirth.DoneAttr)
	return if type(n) == "number" then math.max(0, math.floor(n)) else 0
end

-- Percent of the open map the NEXT rebirth wants.
function Rebirth.shareAt(count: number): number
	return math.min(100, Rebirth.BaseShare
		+ Rebirth.SharePer * math.max(0, count))
end

function Rebirth.needAt(count: number, reach: number): number?
	if reach <= 0 then return nil end
	return math.max(1, math.ceil(reach * Rebirth.shareAt(count) / 100))
end

function Rebirth.multiplierAt(count: number): number
	return (1 + math.max(0, count)) ^ Rebirth.PayPower
end

-- What every upgrade price is multiplied by at this many rebirths.
function Rebirth.discountAt(count: number): number
	return math.max(Rebirth.DiscountFloor,
		1 - Rebirth.DiscountPer * math.max(0, count))
end

-- Takes a nil player and answers 1, for the same reason multiplierOf does.
function Rebirth.discountOf(plr: Player?): number
	return Rebirth.discountAt(Rebirth.countOf(plr))
end

-- The price of one upgrade level for this player, which is the ONLY figure the
-- shop and the till should ever quote. Passing the raw cost around is how the
-- two end up disagreeing about what something costs.
function Rebirth.priceOf(plr: Player?, cost: number): number
	return math.floor(cost * Rebirth.discountOf(plr))
end

-- The one every payout path goes through. Takes a nil player and answers 1, so
-- a module that runs on both sides can call it without knowing which it is on.
function Rebirth.multiplierOf(plr: Player?): number
	return Rebirth.multiplierAt(Rebirth.countOf(plr))
end

local ROMAN = {
	{ 1000, "M" }, { 900, "CM" }, { 500, "D" }, { 400, "CD" },
	{ 100, "C" }, { 90, "XC" }, { 50, "L" }, { 40, "XL" },
	{ 10, "X" }, { 9, "IX" }, { 5, "V" }, { 4, "IV" }, { 1, "I" },
}

local function numeral(n: number): string
	if n >= 4000 then return tostring(n) end
	local out = {}
	for _, step in ipairs(ROMAN) do
		while n >= step[1] do
			out[#out + 1] = step[2]
			n -= step[1]
		end
	end
	return table.concat(out)
end

function Rebirth.rankAt(count: number): string
	local top = #Rebirth.Ranks
	if count + 1 <= top then return Rebirth.Ranks[math.max(1, count + 1)] end
	-- II for the first sweep past the end, not I: the named one was already the first
	return ("%s %s"):format(Rebirth.Ranks[top], numeral(count + 2 - top))
end

export type Status = {
	count: number,
	rank: string,
	-- There is always a next rebirth now, so these three are never nil.
	nextRank: string,
	multiplier: number,
	nextMultiplier: number,
	discount: number,
	nextDiscount: number,
	-- driveways the next rebirth wants, nil when maxed or not yet counted
	need: number?,
	done: number,   -- of the open map, sealed on this lap
	reach: number,  -- of the open map, in total
	left: number,   -- how many more to go, 0 once ready
	progress: number,
	ready: boolean,
	-- The share has reached 100%: this rebirth, and every one after it, costs a
	-- complete sweep of the map. Replaces `maxed`, which cannot happen any more --
	-- it is the state that took over the job of being the end of the ladder.
	full: boolean,
	-- the server has published the map size. Everything above is a guess until
	-- it has, and "not ready" and "not counted yet" are different sentences to
	-- say to a player.
	counted: boolean,
}

function Rebirth.statusOf(plr: Player): Status
	local count = Rebirth.countOf(plr)
	local reach = Rebirth.reachOf(plr)
	local done  = Rebirth.doneOf(plr)
	local need  = Rebirth.needAt(count, reach)
	return {
		count = count,
		rank = Rebirth.rankAt(count),
		nextRank = Rebirth.rankAt(count + 1),
		multiplier = Rebirth.multiplierAt(count),
		nextMultiplier = Rebirth.multiplierAt(count + 1),
		discount = Rebirth.discountAt(count),
		nextDiscount = Rebirth.discountAt(count + 1),
		need = need,
		done = done,
		reach = reach,
		left = if need then math.max(0, need - done) else 0,
		progress = if need then math.clamp(done / need, 0, 1) else 0,
		ready = need ~= nil and done >= need,
		full = Rebirth.shareAt(count) >= 100,
		counted = reach > 0,
	}
end

return Rebirth
