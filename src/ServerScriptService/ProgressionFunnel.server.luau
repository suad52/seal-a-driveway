--!strict
--[[
	ProgressionFunnel -- where players stop, AFTER the tutorial.

	TutorialFunnel covers the first five minutes and is correct, but it can only
	ever answer one question, and it answers it for a population this game does not
	have much of. The onboarding funnel is once-per-user and excludes anybody who
	arrives already finished, so its chart only ever fills from genuinely new
	players -- which is why it can look empty on a place with a healthy returning
	audience. This one covers the rest of the game and includes everybody.

		1 FirstJob        sealed anything at all
		2 FirstUpgrade    spent money on the ladder
		3 TenJobs         still here after a lap's worth of work
		4 FirstRebirth    took the deal the whole economy is built on
		5 SecondArea      the estate road opened
		6 FirstTruck      owns a rig

	Roughly increasing difficulty, which matters: Roblox auto-completes any step
	you skip, so a player who reaches 5 without having reported 3 counts for 3 as
	well. Ordering by difficulty is what keeps that from flattering the middle.
	The one soft spot is the last pair -- a player CAN grind 250K for a Dart before
	opening the estate -- but it costs ~172 driveways at the un-rebirthed rate, so
	it is rare enough to live with.

	A LIFETIME FUNNEL, NOT A PER-SESSION ONE, and `funnelSessionId` is what makes it
	so: it is the player's own user id, so every session they ever play is one run
	of the funnel. Roblox ignores a repeated step within a session, so re-reporting
	a milestone on a later day costs nothing and changes nothing. A per-session id
	would instead answer "what does one sitting look like", which is a different and
	less useful question when the wall is three rebirths wide.

	ONE EVENT PER JOIN, NOT SIX. Because skipped steps auto-complete, only the
	DEEPEST step a player has reached ever needs sending -- so an existing player
	enters the funnel at their true depth on their next join for the cost of a
	single call, and a full server costs one event each rather than six.

	⚠ STUDIO SESSIONS ARE DROPPED by Roblox before they reach the dashboard, exactly
	as they are for the other two. A playtest proves the calls fire and the depth is
	right; only live players move the chart.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsService = game:GetService("AnalyticsService")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Sections = require(Pack:WaitForChild("Sections"))
local Rigs = require(Pack:WaitForChild("Rigs"))
local Rebirth = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Rebirth"))

-- Shown on the dashboard tab, so it is a name rather than an id. Ten funnels are
-- allowed per experience and this is the second.
local FUNNEL = "Progression"

--[[
	Every step is read off an attribute the SERVER already owns and already
	persists. Nothing here is reported by a client and nothing new is stored: a
	funnel that needed its own bookkeeping would be a second thing to keep in step
	with the game, and it would be wrong the first time the game changed.
]]
type Step = { name: string, reached: (Player) -> boolean }

local STEPS: { Step } = {
	{ name = "FirstJob", reached = function(plr)
		return ((plr:GetAttribute("Q_Sealed") :: number?) or 0) >= 1
	end },
	{ name = "FirstUpgrade", reached = function(plr)
		-- the five tracks a rebirth resets; a rig is step 6 and not an "upgrade" here
		for _, id in ipairs(Rebirth.Tracks) do
			if ((plr:GetAttribute("Upg_" .. id) :: number?) or 1) > 1 then return true end
		end
		return false
	end },
	{ name = "TenJobs", reached = function(plr)
		return ((plr:GetAttribute("Q_Sealed") :: number?) or 0) >= 10
	end },
	{ name = "FirstRebirth", reached = function(plr)
		return Rebirth.countOf(plr) >= 1
	end },
	{ name = "SecondArea", reached = function(plr)
		-- the first gate being open IS having reached the second area; it is the
		-- server's own answer, and the same one the gate swings on
		local first = Sections.List[1]
		return first ~= nil and plr:GetAttribute(Sections.openAttr(first.id)) == true
	end },
	{ name = "FirstTruck", reached = function(plr)
		-- ownership is Upg_<rigId> >= 2; see TruckServer.watchOwnership
		for _, rig in ipairs(Rigs.List) do
			if ((plr:GetAttribute("Upg_" .. rig.id) :: number?) or 1) >= 2 then return true end
		end
		return false
	end },
}

-- The deepest step already sent for this player this session. In memory only:
-- Roblox dedupes a repeated step itself, and this is here to save the CALL.
local sent: { [Player]: number } = {}

Players.PlayerRemoving:Connect(function(plr)
	sent[plr] = nil
end)

local function deepestOf(plr: Player): number
	local deep = 0
	-- in order, so the last one that answers true is the furthest reached
	for i, step in ipairs(STEPS) do
		if step.reached(plr) then deep = i end
	end
	return deep
end

local function report(plr: Player)
	local deep = deepestOf(plr)
	if deep <= (sent[plr] or 0) then return end
	sent[plr] = deep

	local step = STEPS[deep]
	-- pcall because telemetry must never be able to take down the thing it is
	-- measuring, which is the rule the other two funnels follow
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			plr, FUNNEL, tostring(plr.UserId), deep, step.name)
	end)
	if not ok then
		-- released again, so a throttled call is retried on the next sweep rather
		-- than written off for the session
		sent[plr] = deep - 1
		warn(("[ProgressionFunnel] %s step %d (%s) failed: %s")
			:format(plr.Name, deep, step.name, tostring(err)))
	elseif RunService:IsStudio() then
		print(("[ProgressionFunnel] %s -> %d %s (Studio: not recorded)")
			:format(plr.Name, deep, step.name))
	end
end

--[[
	Polled rather than hung off a dozen attribute signals.

	Six steps read eleven attributes between them, and wiring each one would be
	eleven connections per player to catch an event that is never urgent -- a funnel
	does not care whether a milestone lands now or in five seconds. One sweep over
	the players is cheaper than the connections and cannot miss a change that
	happened while nothing was listening.

	The profile has to have landed first or every returning player reads as brand
	new for the second or two before their save arrives -- which would be a funnel
	that measures its own load time.
]]
task.spawn(function()
	while true do
		task.wait(5)
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr:GetAttribute("ProfileLoaded") then report(plr) end
		end
	end
end)

if RunService:IsStudio() then
	print(("[ProgressionFunnel] ready -- %q, %d steps, lifetime per player")
		:format(FUNNEL, #STEPS))
end
