--!strict
--[[
	WorldTime (server half) -- pins the hour on the copy that replicates.

	The hour, the reasoning and the hold itself all live in
	ReplicatedStorage.WorldTime, because the client half has to agree with this one
	and a number typed in two places drifts.

	This half is what a joining player gets handed. It is also the half that never
	fires in production -- see the module.
]]

require(game:GetService("ReplicatedStorage").WorldTime).pin()
