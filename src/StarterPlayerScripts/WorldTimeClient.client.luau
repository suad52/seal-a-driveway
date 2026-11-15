--!strict
--[[
	WorldTime (client half) -- the one that actually catches the plugin.

	ClockTime written on a client stays on that client, so a Studio plugin rolling
	the sky round during a playtest is invisible to the server and its guard. This
	is the half that sees it and puts it back.

	Hour and hold both come from ReplicatedStorage.WorldTime; see there for why any
	of this exists.
]]

require(game:GetService("ReplicatedStorage").WorldTime).pin()
