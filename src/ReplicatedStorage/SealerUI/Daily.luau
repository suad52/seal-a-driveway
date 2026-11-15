--!strict
--[[
	Daily -- the day book: one packet a day, and a streak worth keeping.

	Seven rungs, one claimable per UTC day. Claiming on consecutive days walks up
	the week and the seventh rung is worth more than the other six put together;
	missing a day drops the book back to Day 1. Taking the seventh starts a fresh
	week, so the ladder never runs out and the big rung comes round again.

	Shared by the server, which owns the wallet and is the only thing allowed to
	agree to a claim, and by the client, which draws the book. Both read the same
	rungs and the same statusOf from here, so a lit CLAIM button and a paid packet
	can never disagree -- the rule Upgrades, Rebirth and Quests all already follow.

	WHAT IS STORED, AND WHY IT IS ONLY TWO NUMBERS

	  DailyDay     the day number the last packet was taken on
	  DailyStreak  how many days in a row have been taken

	Everything on screen is derived from those two against today's date. That is
	what keeps it honest across a rejoin: there is no per-tile "claimed" flag to
	fall out of step with the calendar, and no timer running anywhere that a
	disconnect could lose. Both ride in the ordinary profile (see UpgradeService)
	and both deliberately survive a rebirth -- turning up is not something a
	rebirth should be able to take away.
]]

local Rebirth = require(script.Parent:WaitForChild("Rebirth"))

local Daily = {}

-- Kept on the Player as attributes, like the upgrade levels and the quest
-- counters, so they replicate on their own and the panel just watches them.
Daily.DayAttr = "DailyDay"
Daily.StreakAttr = "DailyStreak"

--[[
	The profile-loaded flag, spelled out rather than required from anywhere.

	UpgradeService owns it (PROFILE_READY) and this module only reads it, for one
	reason that matters enormously here: the saved day arrives a second or two
	after the player does, so for that second the book looks untouched. Without
	this gate a returning player is shown a lit CLAIM button for a day they were
	already paid for, presses it, and is refused by a server that knows better.
	The VIP packet waits on the same flag for the same reason.
]]
local PROFILE_READY = "ProfileLoaded"

local SECONDS_PER_DAY = 86400

--[[
	Today, as a number that can be SUBTRACTED.

	os.time() is UTC epoch seconds, so bucketing it by a day counts whole days
	since 1970 and rolls over at exactly 00:00 UTC -- the same instant
	os.date("!*t") rolls over. VipService keys its packet off year*1000 + yday
	instead, which answers the only question it asks (is this the same day as last
	time?) but cannot answer this one: 2027001 - 2026365 is 636, so a streak built
	on that would break every New Year. A streak is arithmetic on days, so the day
	number has to be arithmetic too.
]]
function Daily.today(): number
	return math.floor(os.time() / SECONDS_PER_DAY)
end

-- How long until the next rung opens. Display only -- nothing is decided from
-- it, so a client whose clock is wrong sees a wrong countdown and still cannot
-- claim early.
function Daily.secondsToRollover(): number
	return SECONDS_PER_DAY - (os.time() % SECONDS_PER_DAY)
end

-- "6h 41m", "41m", "synced in 30s". Here rather than in the panel because the
-- server quotes the same wait back when it refuses an early claim, and two
-- spellings of the same wait is how the two end up disagreeing by a minute.
function Daily.formatWait(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	if h > 0 then return ("%dh %dm"):format(h, m) end
	if m > 0 then return ("%dm"):format(m) end
	return ("%ds"):format(s)
end

--[[
	The week.

	Sized against the ground rather than against a feeling. A Maple driveway pays
	about $5.2K and a full sweep of the Neighbourhood about $67K, so Day 1 is half
	a driveway -- worth turning up for, not worth enough to make the tutorial's own
	economy pointless -- and the six cash rungs together come to $60K, near
	enough a full lap.
	Day 7 gives no cash; it grants the Instant Coat boost instead, which is what
	makes the seventh visit the one worth planning for.

	Well under the VIP packet at $40K a DAY, and deliberately: a pass has to stay
	worth paying for next to anything handed out free.

	A rung is a table rather than a bare number so a future one can carry
	something that is not cash without moving every index.
]]
Daily.Days = {
	{ cash = 2500 },
	{ cash = 4000 },
	{ cash = 6500, skin = "Brushed" },
	{ cash = 10000 },
	{ cash = 15000 },
	{ cash = 22000 },
	{ boost = "Endless" },
}

--[[
	What a rung pays THIS player.

	Scaled by the rebirth multiplier for the reason the VIP packet is: a fixed
	figure is a fortune on day one and a rounding error by the third lap, so a
	daily reward written as a constant stops being a reason to come back at exactly
	the point a player has been coming back longest.
]]
function Daily.amountAt(day: number, plr: Player?): number
	local rung = Daily.Days[math.clamp(day, 1, #Daily.Days)]
	if not rung.cash then return 0 end
	return math.floor(rung.cash * Rebirth.multiplierOf(plr))
end

--==[ where a player is in the book ]=========================================

export type Status = {
	-- the profile has not landed yet, so nothing on the book is known to be true
	loading: boolean,
	--[[
		The rung on offer, 1-based within the week.

		While today's packet has already been taken there is nothing on offer, and
		this reports the rung that WAS taken rather than guessing at tomorrow's --
		which keeps `day` and `collected` describing the same tile all day, and is
		why the panel's "is this the tile to light" test can be `day == st.day and
		st.ready` without a second case. Tomorrow's rung is not knowable anyway: it
		depends on whether they turn up tomorrow or in a week.
	]]
	day: number,
	amount: number,       -- what that rung pays this player, rebirth applied
	streak: number,       -- days in a row as recorded
	streakAfter: number,  -- what the streak becomes if the claim goes through
	collected: number,    -- rungs filled in the week on display, 0..#Days
	ready: boolean,       -- claimable right now
	resets: boolean,      -- a day was missed: claiming starts the week again
	secondsLeft: number,  -- until the next rung opens; 0 while one is ready
}

local function num(plr: Player, name: string): number
	local v = plr:GetAttribute(name)
	return if type(v) == "number" then math.max(0, math.floor(v)) else 0
end

--[[
	Everything a caller needs to draw, decide or refuse a claim, in one read.

	The panel and the server's till both work from this rather than each doing
	their own date arithmetic. The three cases the calendar can be in are named
	here once, which is the whole point: they are easy to get subtly wrong, and
	getting them wrong in only one of the two places is how a player ends up
	pressing a button that refuses them.
]]
function Daily.statusOf(plr: Player): Status
	local week = #Daily.Days
	local streak = num(plr, Daily.StreakAttr)
	local saved = plr:GetAttribute(Daily.DayAttr)
	local last: number? = if type(saved) == "number" then math.floor(saved) else nil
	local today = Daily.today()

	local claimedToday = last == today
	-- A day recorded with no streak behind it cannot happen from the till -- it
	-- writes both together -- but it can from a hand-edited or half-written
	-- profile, and the wrap arithmetic below turns a zero into rung 7 and lights
	-- the whole week. One is the smallest streak a recorded day can mean.
	if claimedToday and streak < 1 then streak = 1 end
	-- Yesterday exactly. Anything older is a broken streak; a `last` in the FUTURE
	-- (a hand-edited profile, or a server whose clock was wrong) lands here too and
	-- is treated as broken, which costs that player a streak rather than handing
	-- them a packet a day early forever.
	local continues = last ~= nil and last == today - 1
	local resets = last ~= nil and not claimedToday and not continues

	local streakAfter = if claimedToday then streak
		elseif continues then streak + 1
		else 1
	-- Which rung of the week that is. The streak keeps counting up forever and the
	-- book wraps, so week two's first rung is streak 8.
	local day = ((streakAfter - 1) % week) + 1

	--[[
		How many tiles are shown filled.

		Every case is "one less than the rung on offer" except the one where the
		packet has already been taken today -- then the rung on offer is tomorrow's
		and the one just taken is the one that should read as paid. Which also gives
		the nice property that the evening you take Day 7 the whole week is lit,
		rather than resetting to an empty book while you are still looking at it.
	]]
	local collected = if claimedToday then ((streak - 1) % week) + 1 else day - 1

	local loading = plr:GetAttribute(PROFILE_READY) ~= true
	return {
		loading = loading,
		day = day,
		amount = Daily.amountAt(day, plr),
		streak = streak,
		streakAfter = streakAfter,
		collected = collected,
		ready = not loading and not claimedToday,
		resets = resets,
		secondsLeft = if claimedToday then Daily.secondsToRollover() else 0,
	}
end

return Daily
