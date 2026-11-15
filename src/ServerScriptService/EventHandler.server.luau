--!strict
--[[
	EventHandler -- THE server's event schedule. One timer, three events, a draw.

	There used to be two schedules. SqueegeeBattleServer timed its own 15-20
	minute gap and this file timed an identical one for Golden Hour, which meant
	two independent clocks of the same period drifting through each other -- so
	they overlapped regularly, and an overlap is close to the worst case for the
	player it lands on. The battle purse is paid by BattleEconomy straight to the
	Cash leaderstat and never passes through DrivewayServer's payMultiplier, so
	Golden Hour does not multiply it; and somebody standing in an arena six
	thousand studs from the neighbourhood is not sealing driveways either. The 3x
	window ran while the player was in the one place it could not apply.

	One slot at a time fixes it by construction rather than by negotiation: there
	is no arrangement of timers here that can put two events on at once, because
	there is only ever one. THAT IS THE PROPERTY TO PRESERVE when a fourth event
	is added -- add it to the draw below, not to a timer of its own. Every word of
	the paragraph above is true of the Driveway Race against Golden Hour as well.

	THE ONE EXCEPTION IS THE FRIDAY HOUR, which is not in the draw because it is
	not this file's to draw: it opens at 20:00 UTC every Friday whether any slot
	is free or not, so the schedule holds off ahead of it and hands the whole
	hour over (see THE FRIDAY HOUR below). It is still one event at a time -- the
	Friday hour is simply the one event, for sixty minutes, and the ordinary x3
	Golden Hour cannot land inside it because the draw is not running then.

	THE DRAW IS MADE AT THE START OF THE GAP, not the end, and that is what keeps
	the on-screen countdown honest. Its clock is an absolute deadline published for
	the whole wait (see BattleConfig.NextAtAttr), so the schedule has to know which
	event is coming before the waiting starts -- and a slot the drawn event
	declines can then be handed on with time to spare.

	This file owns WHEN and WHICH, and deliberately nothing else. What a window is
	worth is DrivewayServer's, what it looks like is GoldenHourClient's, how a
	battle is run is SqueegeeBattleServer's and how a race is run is
	DrivewayRaceServer's -- all reached through EventBus so that none of those
	files has to know this one exists.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local GoldenHour = require(Pack:WaitForChild("GoldenHour"))
local EventBus = require(game.ServerScriptService.EventBus)
local flag = GoldenHour.ensure()

--[[
	TEN MINUTES, FLAT -- every gap, including the first one of a server's life.

	This used to call BattleConfig.nextGap, which draws a random 15-20 minutes and
	a shorter 4-7 for the opening gap. Both are gone on purpose (owner's call): a
	random period means the clock on screen reads a different number every cycle
	and players cannot learn the rhythm, and the short first gap made the very
	first countdown of a session disagree with every one after it -- which is
	exactly the "it only shows six minutes, not ten" this replaces.

	One number, so the timer always reads 10:00 when it appears and every player
	learns the same beat.

	⚠ BattleConfig still carries GapMin, GapMax and the FirstGap pair, and NOTHING
	reads them for scheduling any more -- see the note left there. They are the
	battle's own history, not this file's knobs. Change the number below.
]]
local GAP = 600

-- Find-or-create, the same shape UpgradeService uses for its own remotes: the
-- folder is authored content but the events inside it are not, so a place saved
-- without this one still runs.
local remotes = Pack:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = Pack
end
local visuals = remotes:FindFirstChild(GoldenHour.RemoteName)
if not visuals then
	visuals = Instance.new("RemoteEvent")
	visuals.Name = GoldenHour.RemoteName
	visuals.Parent = remotes
end

--[[
	Random.new() rather than math.random, and the difference is visible in
	production.

	Luau seeds each VM's math.random the same way, so an unseeded math.random(900,
	1200) draws the SAME first number in every server of the game -- "random"
	would mean every server running an identical timetable offset only by when it
	booted. Random.new() is seeded independently, which is the entire point of
	drawing the number at all.
]]
local rng = Random.new()

--==[ ONE OF THE THREE EVENTS ]===============================================

local function runGoldenHour(mult: number, endsAt: number)
	--[[
		The deadline is written BEFORE the flag, and the order is load-bearing.

		Both replicate, but a client watching the BoolValue reads EndsAt inside that
		same handler -- so raising the flag first leaves a window of frames where the
		event is on and shuts at zero. That is a countdown that opens on 00:00 and a
		HUD that starts by contradicting itself.

		The multiplier rides the flag as an attribute too, written in the same
		order for the same reason: a player who joins forty minutes into the
		Friday hour has missed the remote entirely, and the flag is the only
		thing that reaches them already true. The rate and the deadline are one
		fact about one window, so they travel together.
	]]
	flag:SetAttribute(GoldenHour.MultAttr, mult)
	flag:SetAttribute(GoldenHour.EndsAtAttr, endsAt)
	flag.Value = true
	--[[
		Fired as well as replicated, and the clients treat it as a HINT rather than
		as the truth -- see GoldenHourClient, which converges on the BoolValue either
		way. A remote alone cannot carry this: it reaches the players who were here
		when it fired and nobody else, so a player joining ninety seconds in would
		earn triple under a midday sky with no timer.
	]]
	visuals:FireAllClients(true, endsAt)
	print(("[EventHandler] Golden Hour open -- x%d, %ds"):format(mult,
		math.max(0, math.floor(endsAt - workspace:GetServerTimeNow()))))

	--[[
		Waited out against the DEADLINE rather than as a flat 180.

		Every HUD draws its countdown from EndsAt, so the flag has to drop when that
		number is reached rather than a drifting fraction of a second afterwards --
		otherwise the last thing the player sees is a timer stopped on 00:00 with the
		sky still gold.
	]]
	task.wait(math.max(0, endsAt - workspace:GetServerTimeNow()))

	flag.Value = false
	flag:SetAttribute(GoldenHour.EndsAtAttr, 0)
	-- Back to the ordinary rate on the way down, so a flag read after the
	-- window answers x3-or-nothing rather than the ghost of the Friday x5.
	flag:SetAttribute(GoldenHour.MultAttr, GoldenHour.Multiplier)
	visuals:FireAllClients(false, 0)
	print("[EventHandler] Golden Hour over")
end

--==[ THE FRIDAY HOUR ]======================================================

local FRIDAY = 6                 -- os.date wday, Sunday = 1
local FRIDAY_OPEN = 20 * 3600    -- 20:00 UTC, as seconds into the Friday
local FRIDAY_LENGTH = 3600       -- one hour, to 21:00 UTC


local function fridayWindow(now: number): (number, number)
	local d = os.date("!*t", now)
	local dayStart = now - (d.hour * 3600 + d.min * 60 + d.sec)
	local start = dayStart + FRIDAY_OPEN
	
	if d.wday == FRIDAY and now < start + FRIDAY_LENGTH then
		return start, start + FRIDAY_LENGTH
	end
	
	local daysAhead = (FRIDAY - d.wday) % 7
	if daysAhead == 0 then daysAhead = 7 end
	start += daysAhead * 86400
	return start, start + FRIDAY_LENGTH
end


local HOLD_OFF = 300

--==[ THE SCHEDULE ]==========================================================

while true do
	local now = os.time()
	local winStart, winEnd = fridayWindow(now)

	if now >= winStart then
		EventBus.announceNext(nil)
		
		print(("[EventHandler] Friday Golden Hour -- x%d until 21:00 UTC"):format(
			GoldenHour.FridayMultiplier))
		
		runGoldenHour(GoldenHour.FridayMultiplier, winEnd)
		
		continue
	end

	if now + GAP > winStart - HOLD_OFF then
		local untilOpen = math.floor(winStart - now)
		
		EventBus.announceNext(untilOpen)
		
		print(("[EventHandler] holding the draw for the Friday x%d Golden"
				.. " Hour -- %d:%02d away"):format(GoldenHour.FridayMultiplier,
				untilOpen // 60, untilOpen % 60))
		task.wait(untilOpen)
		
		continue
	end

	local gap = GAP

	local draw = rng:NextInteger(1, 3)
	local kind = if draw == 1 then "battle" elseif draw == 2 then "race" else "golden"

	EventBus.announceNext(gap)

	local whole = math.floor(gap)
	
	print(("[EventHandler] next event in %d:%02d -- %s"):format(
		whole // 60, whole % 60,
		if kind == "battle" then "Squeegee Battle"
		elseif kind == "race" then "Driveway Race"
		else "Golden Hour"))

	task.wait(gap)

	EventBus.announceNext(nil)

	local ran = false
	if kind == "battle" then
		ran = EventBus.runBattle()
		if not ran then
			print("[EventHandler] the battle could not take its turn -- too few"
				.. " players, or it is already busy. Golden Hour takes the slot.")
		end
	elseif kind == "race" then
		ran = EventBus.runRace()
		if not ran then
			print("[EventHandler] the race could not take its turn -- too few"
				.. " players, or it is already busy. Golden Hour takes the slot.")
		end
	end
	if not ran then
		runGoldenHour(GoldenHour.Multiplier,
			workspace:GetServerTimeNow() + GoldenHour.Duration)
	end
end
