--!strict
--[[
	HudActions -- the shell asking this client to DO something.

	HudBus runs one way: DrivewayClient assembles the state, the shell draws it.
	This is the other direction, and it is a separate module rather than a field
	on HudBus deliberately -- that one is a snapshot pushed every frame, and a
	command posted into a snapshot either runs sixty times or not at all
	depending on who reads it first.

	A table of handlers rather than a BindableEvent, for the same reason HudBus is
	a plain module: both ends are on this client and nothing replicates. The
	difference that matters is `fire` reporting whether anyone was listening --
	an event fired into nowhere looks identical to one that worked, and a Quick
	Refill button that quietly does nothing is worse than one that says so.

	Whoever owns a thing registers the action for it. The pail is DrivewayClient's
	number and always has been, so DrivewayClient is the only thing that can fill
	it; the shell asks.
]]

local HudActions = {}

local handlers: { [string]: () -> () } = {}

function HudActions.register(name: string, fn: () -> ())
	handlers[name] = fn
end

--[[
	Returns whether the action actually ran.

	False covers both "nobody has registered this yet" and "the handler threw",
	because the caller wants the same thing in either case: fall back to telling
	the player what to do by hand rather than claiming to have done it. The throw
	is warned about rather than swallowed, since that one is a bug and the other
	is a startup race.
]]
function HudActions.fire(name: string): boolean
	local fn = handlers[name]
	if not fn then return false end
	local ok, err = pcall(fn)
	if not ok then
		warn(("[HudActions] %s failed: %s"):format(name, tostring(err)))
	end
	return ok
end

return HudActions
