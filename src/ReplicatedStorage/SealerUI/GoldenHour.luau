--!strict
--[[
	GoldenHour -- the server-wide window where every driveway pays triple.

	ONE module for both sides, for the reason Passes gives about itself: the HUD
	draws the figure and the server pays it, and a multiplier written down in two
	places is one that will eventually disagree with itself.

	THE STATE IS A BoolValue IN ReplicatedStorage rather than an attribute on a
	player, because it is not a fact about a player -- everybody in the server is
	inside the window or outside it together. A BoolValue replicates on its own,
	which is the same property the rest of the game leans on attributes for.

	`EndsAt` rides on it as an attribute carrying the SERVER CLOCK time the window
	shuts, and it is the half that makes a late joiner work. A player who arrives
	ninety seconds in has missed the RemoteEvent that announced the start; without
	a deadline to read they would be shown a fresh 03:00, which is a HUD lying
	about when the money stops.

	⚠ THE MULTIPLIER IS FOLDED INTO THE SAME Economy.payout CALL as the rebirth
	ladder and the passes -- never applied to the result. DrivewayServer clamps its
	own figure against the client's claim at three times (see the note there), so a
	bonus added AFTER that clamp is silently clipped off. The two places that fold
	it in are DrivewayServer's payMultiplier and ScoreModel:multiplier, and they
	have to move together or the HUD advertises a number the wallet does not pay.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Who the window is open TO. It is server-wide, but a player who has not
-- finished the tutorial is not in it yet -- see GoldenHour.appliesTo.
local Tutorial = require(script.Parent:WaitForChild("Tutorial"))

local GoldenHour = {}

--==[ THE WINDOW ]============================================================

GoldenHour.Multiplier = 3
GoldenHour.Duration = 180

--[[
	THE FRIDAY HOUR -- a second, bigger window on the same flag and under
	the same sky: every Friday 20:00-21:00 UTC the window opens at x5 for
	a full hour, for everybody in the server and everybody who joins
	inside the hour.

	The rate rides the flag as an attribute (MultAttr below) rather than
	living as a second constant at the pay sites, for the same reason this
	module exists at all: a number written down in two places eventually
	disagrees with itself, and the flag is the one thing that already reaches a
	player who joins mid-window. cashMultiplier and the HUD's "\u{00D7}N CASH" both
	read it from there, so the Friday x5 costs the money path
	nothing.

	WHEN the hour runs is EventHandler's business, same split as ever: this
	file owns what the window is worth, not when it opens.
]]
GoldenHour.FridayMultiplier = 5

--[[
	THE GAP IS NOT HERE, and this is the note saying where it went.

	This module used to carry MinGap/MaxGap of 900 and 1200. It does not, because
	Golden Hour no longer has a schedule of its own: ServerScriptService.EventHandler
	runs ONE timer for the whole server and tosses a coin between this and the
	Squeegee Battle, so the two can never be on at once. See the header there for
	why two timers of the same period was the wrong shape.

	The period itself is BattleConfig.nextGap -- still the same 15 to 20 minutes,
	drawn as a random number of SECONDS so a slot opens at 17:20 or 15:45 rather
	than only ever on the minute, which is what stops it becoming a timetable
	players can set a watch by and idle against.

	Deleted rather than left sitting here unread: a constant that no longer drives
	anything is a constant somebody will retune one day and then wonder why the
	schedule did not move.
]]

GoldenHour.StateName = "IsGoldenHour"
GoldenHour.EndsAtAttr = "EndsAt"
GoldenHour.MultAttr = "Multiplier"
GoldenHour.RemoteName = "GoldenHourVisuals"

--==[ THE SKY ]===============================================================

--[[
	The whole visual is a SKYBOX SWAP now, and what used to be here is gone on
	purpose (owner's call).

	What was here: an hour of 17.45, a warm OutdoorAmbient / Ambient /
	ColorShift_Top, a Brightness cut, Atmosphere values, a Bloom lift, and a
	full-screen ColorCorrection grade that desaturated the frame so that a tint
	could drag the blue sky round to orange. It worked, and it was the wrong
	trade: it recoloured the ENTIRE neighbourhood to get at the sky, and a game
	whose trees stop being green is paying too much for a sunset.

	A Sky replaces the skybox and touches nothing else. The neighbourhood keeps
	its own palette, the sunset is a real painted sunset rather than a tint over
	blue, and it costs one instance instead of a per-frame lerp of nine
	properties across three objects.

	CelestialBodiesShown is OFF on it, and that is not cosmetic -- see the note
	over it in GoldenHourClient, which builds this thing.

	The faces come from Creator Store asset 2241540541 ("Desert Sky", free), which
	is KnightEix's warm recolour of Polyhex's Magenta Orange Sky: gold cumulus over
	an amber gradient that deepens to red overhead. What is written down here is
	the TEXTURES, not the model -- nothing is inserted into the place, there is no
	asset to keep in the tree, and the swap is six string assignments.

	⚠ THE SIX ARE A MATCHED SET AND MOVE TOGETHER. A skybox is one painting cut
	into a cube, so a face borrowed from another sky meets its neighbours at a hard
	seam -- which is why "this one's horizon with that one's zenith" is not on the
	table, however tempting it looks written down as six independent strings.

	PICKED BY LOOKING, over the actual neighbourhood, against nine others
	(2026-08-12, owner's call that the old one "is not good"). What it replaces is
	541743453..., a Blockland sunset: a flat, muddy orange with no cloud shape left
	in it, which over lawns this green read as smoke rather than as evening. The
	value of this one is that the horizon stays BRIGHT and the clouds stay legible,
	so the window reads as something happening in the sky rather than as a filter
	dropped over the map. Its one weakness is straight up, where the zenith is a
	flat red -- that is the cost of the horizon being this good, and this game's
	camera points down at a driveway.
]]
GoldenHour.SkyboxBk = "rbxassetid://2241528789"
GoldenHour.SkyboxDn = "rbxassetid://2241529784"
GoldenHour.SkyboxFt = "rbxassetid://2241471924"
GoldenHour.SkyboxLf = "rbxassetid://2241530480"
GoldenHour.SkyboxRt = "rbxassetid://2241531201"
GoldenHour.SkyboxUp = "rbxassetid://2241531769"

--==[ READING IT ]============================================================

local cached: BoolValue? = nil

--[[
	The flag, or nil if it does not exist on this side yet.

	Cached, because cashMultiplier below is called every frame of a squeegee pass
	by ScoreModel and a FindFirstChild per frame is a lookup by string. The
	`.Parent` test is what makes the cache safe rather than merely fast: it
	re-finds the value if it is ever replaced, and answers nil rather than handing
	back a destroyed instance.
]]
function GoldenHour.value(): BoolValue?
	local c = cached
	if c and c.Parent then return c end
	local found = ReplicatedStorage:FindFirstChild(GoldenHour.StateName)
	cached = if found and found:IsA("BoolValue") then found else nil
	return cached
end

--[[
	Make the flag. Server side, and idempotent because it has to be: EventHandler
	owns the schedule but DrivewayServer reads the flag, and neither can be relied
	on to have started first.
]]
function GoldenHour.ensure(): BoolValue
	local existing = GoldenHour.value()
	if existing then return existing end
	local v = Instance.new("BoolValue")
	v.Name = GoldenHour.StateName
	v.Value = false
	v:SetAttribute(GoldenHour.EndsAtAttr, 0)
	v:SetAttribute(GoldenHour.MultAttr, GoldenHour.Multiplier)
	v.Parent = ReplicatedStorage
	cached = v
	return v
end

--[[
	Explicitly `== true`, for the reason Passes.owns gives about itself: the flag
	may not have replicated to this side yet, and "not yet" has to read as "no
	window" rather than as anything else.

	Off is the safe answer in both directions. A client that under-reads it draws a
	smaller number than it is about to be paid, which DrivewayServer's claim clamp
	already tolerates -- it takes max(own figure, claim), so an honest server
	figure wins over a stale client one.
]]
function GoldenHour.active(): boolean
	local v = GoldenHour.value()
	return v ~= nil and v.Value == true
end

--[[
	WHETHER THIS PLAYER IS IN THE WINDOW, which is a different question from
	whether the window is open.

	`active` is a fact about the SERVER and stays one -- EventHandler opens and
	shuts it for everybody at once, and the deadline on the flag is the same
	number on every machine. This is the per-player half: somebody still being
	taught is not in the event at all, so they get no sunset, no countdown and no
	triple money until they have finished (owner's call, 2026-08-12).

	ONE PREDICATE FOR ALL THREE, and that is the point of it being here rather
	than spelled out at each site. The sky is GoldenHourClient's, the timer is
	GoldenHourClient's too and the money is split between DrivewayServer and
	ScoreModel -- four places that must agree, or a player is shown a sunset they
	are not being paid for, or paid triple under a midday sky. Flip this one
	function to `return true` and the event goes back to being unconditional.

	`inProgress` rather than `not isDone` deliberately: the flag arrives from the
	DataStore a moment after the client does, and a returning player must not
	lose the multiplier for the second before it lands. See the note in Tutorial.
]]
function GoldenHour.appliesTo(plr: Player?): boolean
	return not Tutorial.inProgress(plr)
end

--[[
	⚠ TAKES A PLAYER, and both callers -- DrivewayServer's payMultiplier
	and ScoreModel:multiplier -- pass theirs. Called with no player at all
	appliesTo answers true, so this pays the window's rate unconditionally:
	the right default for anything that has no player to ask about, and the
	wrong thing to leave at a site that does.

	The rate itself is read off the flag so the Friday x5 and the ordinary
	x3 are one code path rather than two. The fallback is the regular
	multiplier: a flag without the attribute is a window opened by an older
	build, and the ordinary rate is the honest reading of that.
]]
local function rateOnFlag(): number
	local v = GoldenHour.value()
	if not v or v.Value ~= true then return 1 end
	local m = v:GetAttribute(GoldenHour.MultAttr)
	if type(m) ~= "number" or m < 1 then return GoldenHour.Multiplier end
	return m
end

function GoldenHour.cashMultiplier(plr: Player?): number
	if not GoldenHour.appliesTo(plr) then return 1 end
	return rateOnFlag()
end

-- What the open window pays, for the HUD's "\u{00D7}N CASH": the same read
-- the wallet makes, so the number on the screen and the number paid
-- cannot disagree. Answers the ordinary rate when no window is
-- open, which nobody calls it for but which keeps it from
-- ever answering 1-or-nothing.
function GoldenHour.currentMultiplier(): number
	local m = rateOnFlag()
	return if m > 1 then m else GoldenHour.Multiplier
end

--[[
	Seconds left, off the SERVER clock rather than a countdown started locally.

	workspace:GetServerTimeNow() is the same number on every machine in the server,
	so every player's timer agrees with every other player's and with the moment
	the server actually drops the flag. A local `os.clock()` countdown started from
	the remote would be right only for players who were present when it fired.
]]
function GoldenHour.secondsLeft(): number
	local v = GoldenHour.value()
	if not v or v.Value ~= true then return 0 end
	local endsAt = v:GetAttribute(GoldenHour.EndsAtAttr)
	if type(endsAt) ~= "number" then return 0 end
	return math.max(0, endsAt - workspace:GetServerTimeNow())
end

-- MM:SS for the HUD. Rounded UP, so the final second reads 00:01 rather than
-- sitting on 00:00 for a whole second while the money is still tripled.
function GoldenHour.clock(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return ("%02d:%02d"):format(math.floor(whole / 60), whole % 60)
end

return GoldenHour
