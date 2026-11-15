--!strict
--[[
	EventBus -- how the one scheduler reaches an event it does not own.

	EventHandler decides WHEN something happens and WHICH of the three it is.
	SqueegeeBattleServer and DrivewayRaceServer each own everything about running
	their event and are far too big a thing to be required by a scheduler. This is
	the seam between them, and it is deliberately one-way: an event registers what
	it can do, the scheduler asks for it, and no file requires another.

	The same shape as RebirthBus, and for the same reason -- a shared instance in
	ServerScriptService is the only thing two server Scripts can both reach
	without one of them owning the other.

	WHY run() ANSWERS A BOOLEAN. Both of the competitive events need two players.
	On a server with one person in it the answer is "no", and the scheduler needs
	to hear that rather than discover it as silence -- otherwise a solo player
	loses two slots in three to an event that was never going to open, which is
	the one player who can least afford to be given nothing. Hearing "no" lets the
	scheduler fall back to Golden Hour, which works perfectly well alone.
]]

local EventBus = {}

type Battle = {
	run: () -> boolean,
	ticker: (number?) -> (),
}

local battle: Battle? = nil

--[[
	The Driveway Race, which registers a `run` and NOTHING ELSE.

	There is one countdown widget in the game and it belongs to the battle's UI
	package -- it was built there when the battle was the only timed event and it
	now counts down to whichever event won the draw, saying only "NEXT EVENT". A
	second ticker hook here would be a second clock for one schedule, which is the
	exact bug the single scheduler was written to delete. So the race draws no
	countdown of its own; see the note at the top of RaceUI.
]]
local race: (() -> boolean)? = nil

--[[
	The last thing the scheduler put on the clock, kept so it can be replayed at
	registration.

	Both files are Scripts in ServerScriptService and neither is guaranteed to
	start first -- measured, not feared: the scheduler wins the race in practice,
	printing its first line before the arena has finished building. Without this
	the opening announcement would land in an empty room and the on-screen clock
	would sit blank for the whole of the first gap.
]]
local said = false
local lastAnnounce: number? = nil

--[[
	`ticker` is the shared countdown, not the battle's own.

	It is reached through this file because the widget it drives lives in the
	SqueegeeBattle package -- it was built there when the battle was the only timed
	event in the game. It now counts down to whichever event won the toss and says
	so in neutral words; see BattleUI:_buildTicker.
]]
function EventBus.provideBattle(run: () -> boolean, ticker: (number?) -> ())
	battle = { run = run, ticker = ticker }
	if said then ticker(lastAnnounce) end
end

--[[
	Put the next slot on the clock, or nil to take the clock down.

	Called for EVERY gap now, whichever event the coin picked, because a countdown
	that only appears half the time is a countdown players stop trusting. What it
	deliberately does NOT carry is WHICH event is coming: the scheduler knows, but
	the screen does not say, so the answer is still a surprise when it lands.

	nil is a state the widget already draws -- it is what stands while an event is
	actually running -- and it is what the scheduler sends the moment a slot is
	spent, so no clock is ever left counting backwards through it.
]]
function EventBus.announceNext(seconds: number?)
	said = true
	lastAnnounce = seconds
	local b = battle
	if b then b.ticker(seconds) end
end

-- Blocks for the whole event. False means it could not be run at all, and the
-- caller still has a slot to fill.
function EventBus.runBattle(): boolean
	local b = battle
	if not b then return false end
	return b.run()
end

function EventBus.provideRace(run: () -> boolean)
	race = run
end

-- Same contract as runBattle: blocks for the whole event, and false means the
-- slot is still the caller's to spend.
function EventBus.runRace(): boolean
	local r = race
	if not r then return false end
	return r()
end

return EventBus
