--!strict
--[[
	AnalyticsPing -- one event per player per session, with no gate of any kind.

	A DIAGNOSTIC, NOT A FEATURE. Delete it once it has answered its question.

	WHAT IT IS FOR

	The Funnels dashboard is empty, and TutorialFunnel -- which is correct -- cannot
	tell us why, because it is selective by design. It excludes anyone arriving with
	the tutorial already finished (see finishedOnArrival), and it only reports a
	player who actually reaches its beats. So an empty chart has three readings and
	no way to separate them:

		a) nothing this place logs is reaching Roblox at all
		b) it is reaching Roblox, but nobody NEW has played inside the date range
		c) it is reaching Roblox and the dashboard has simply not surfaced it yet

	This fires for every player the moment they join, whoever they are. If it never
	appears in the dashboard, the answer is (a) and the funnel is not the problem.
	If it appears while the funnel stays empty, the funnel is fine and the traffic
	is returning players -- which is (b), and no amount of code will change it.

	The custom field carries which of those a given session was, so the one event
	answers both halves: the total says whether analytics works, and the split says
	whether there is any new-player traffic to funnel.

	⚠ STUDIO SESSIONS ARE DROPPED by Roblox before they reach the dashboard, exactly
	as they are for the funnel. A playtest can prove this fires; only live players
	move the numbers. The print at the bottom is how a playtest shows its working.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local AnalyticsService = game:GetService("AnalyticsService")

local EVENT = "SessionStart"

--[[
	Roblox takes at most three custom fields and wants ITS OWN enum names as the
	keys -- anything else is dropped without complaint, which for a diagnostic would
	be the worst possible failure: a silent one that looks like it worked.

	Resolved defensively so a client running an engine build without the enum still
	sends the event, just without the split. The event arriving at all is the
	primary question; the field is the bonus.
]]
local FIELD: string? = nil
do
	local ok, key = pcall(function()
		return Enum.AnalyticsCustomFieldKeys.CustomField01.Name
	end)
	FIELD = ok and key or nil
end

local function ping(plr: Player)
	task.spawn(function()
		--[[
			Waits for the profile so "returning" is answered off saved state rather than
			off the second before it lands -- DepotSealed is nil until UpgradeService has
			restored it, and every player would otherwise be counted as new.

			Timed out, not waited on, because a place with no DataStore access never sets
			ProfileLoaded at all and the ping still has to fire. Same bound the funnel and
			the gates use, and for the same reason.
		]]
		local t0 = os.clock()
		while plr.Parent and not plr:GetAttribute("ProfileLoaded") and os.clock() - t0 < 15 do
			task.wait(0.2)
		end
		if not plr.Parent then return end

		local returning = plr:GetAttribute("DepotSealed") == true
		local fields = if FIELD
			then { [FIELD] = if returning then "returning" else "new" }
			else nil

		-- pcall because telemetry must never be able to take down the thing it is
		-- measuring; the same rule TutorialFunnel follows.
		local ok, err = pcall(function()
			AnalyticsService:LogCustomEvent(plr, EVENT, 1, fields)
		end)

		if not ok then
			warn(("[AnalyticsPing] %s failed: %s"):format(plr.Name, tostring(err)))
		elseif RunService:IsStudio() then
			print(("[AnalyticsPing] %s -> %s (%s) (Studio: not recorded)")
				:format(plr.Name, EVENT, if returning then "returning" else "new"))
		end
	end)
end

Players.PlayerAdded:Connect(ping)
-- anyone already in when this runs, which in Studio is always the case
for _, plr in ipairs(Players:GetPlayers()) do ping(plr) end

if RunService:IsStudio() then
	print(("[AnalyticsPing] ready -- %q on every join, custom field %s")
		:format(EVENT, FIELD or "UNAVAILABLE (event still sends)"))
end
