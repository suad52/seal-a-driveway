--!strict
--[[
	WorldTime -- there is no day/night cycle, and this is what keeps it that way.

	Nothing in this place has ever set ClockTime. Grep it: the only other mentions
	are a comment in RigController and a dead package parked in ServerStorage,
	which does not run. The cycling comes from an installed Studio PLUGIN, and a
	plugin keeps running while you playtest -- which is why the sky rolls round to
	night in the middle of a session and never in a published server.

	So this is a guard, not a feature. The hour is asserted at start and put back
	if anything moves it.

	It has to run on BOTH sides, and that is the whole reason this module exists.
	The guard used to be a server Script alone, and a server Script cannot see the
	problem it was written for: ClockTime written on a client is local to that
	client and never replicates back, so the server's signal never fired, the
	server's copy stayed at 14.2 the whole time, and the player watched the sun go
	down anyway. The client half is the half that actually catches the plugin.

	To change the time of day, change HOUR here -- both halves read it, and setting
	Lighting.ClockTime by hand anywhere will now be undone.

	TO MOVE THE SKY TEMPORARILY, call setHour. Writing ClockTime directly is not a
	way round the guard, it is the thing the guard exists to undo -- see the note
	there.
]]

local Lighting = game:GetService("Lighting")

local WorldTime = {}

-- Early afternoon: high enough that the whole neighbourhood is lit, low enough
-- that kerbs and the truck still throw shadows long enough to read a slab by.
WorldTime.HOUR = 14.2

--[[
	The hour the guard is currently holding.

	Module-level rather than captured inside pin(), which is the whole of what
	makes setHour below possible. With nobody calling setHour it never moves off
	HOUR and this file behaves exactly as it always did.
]]
local target = WorldTime.HOUR
local holding = false
local pumpkinOverride = false

--[[
	Hold the hour, and keep holding it.

	The tolerance is not politeness, it is required: ClockTime is a float, so the
	hour read back is not bit-identical to the one written, and an exact compare
	would write again on every read and sit in a loop with its own signal.

	`holding` guards the same loop from the other direction -- our write re-enters
	the signal we are inside of.

	A plugin that tweens the time writes every frame, so this writes back every
	frame too. That is fine and it is cheap: one compare per write, and only while
	something is actually fighting it. In production nothing ever fires this.
]]
local function hold()
	if holding then return end
	local effective = if pumpkinOverride then 19 else target
	if math.abs(Lighting.ClockTime - effective) < 0.001 then return end
	holding = true
	Lighting.ClockTime = effective
	holding = false
end

function WorldTime.pin(): RBXScriptConnection
	hold()
	return Lighting:GetPropertyChangedSignal("ClockTime"):Connect(hold)
end

--[[
	Move the hour the guard is holding. The ONLY way to change the time of day.

	This exists because the guard above is otherwise unbeatable, and that is worth
	spelling out: anything writing ClockTime is put back inside the same frame, so
	a TweenService tween of the sky is not a slow sunset, it is a tug of war the
	guard wins every frame while the sky visibly does not move. Golden Hour drives
	its sunset through here one step per frame instead -- the guard agrees with
	every step it is asked to hold, and it is still holding the line against the
	Studio plugin the whole way through the transition.

	CLIENT-LOCAL when called on a client, which is where Golden Hour calls it:
	ClockTime written on a client does not replicate, so a player's sunset is their
	own and the server's copy never moves. See the note at the top for why the
	client is the half that matters here.
]]
function WorldTime.setHour(hour: number)
	target = hour
	hold()
end

-- Back to the authored hour: the end of anything that borrowed the sky.
function WorldTime.reset()
	WorldTime.setHour(WorldTime.HOUR)
end

function WorldTime.setPumpkinOverride(on: boolean)
 pumpkinOverride = on
 hold()
end

return WorldTime
