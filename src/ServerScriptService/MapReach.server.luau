-- Queue patch: numeric MapReach_v2 keys retained. Per-server pacing is not a global rate limiter.
--!strict
--[[
 MapReach: existing MapReach_v2 numeric counters and u_ depth marks retained.
 One worker handles this server's requests, with budget reserves and backoff.
 Each district key is spaced by 8-10 seconds per server, not globally.
 Successful increments are followed by a retriable user-mark save.
 Departed players remain queued for up to 300 seconds; shutdown drains for 25.
 These counters are approximate: separate counter/mark writes are not atomic.
 An ambiguous IncrementAsync failure or a server crash can still overcount.
 Studio reads marks but never writes counters or marks.
 Read totals with GetDataStore("MapReach_v2"):GetAsync("d_" .. districtName).
 District ordering must remain unchanged; append-only additions are supported.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local AnalyticsService = game:GetService("AnalyticsService")

local Sections = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))

-- Shown on the dashboard tab, so it is a name rather than an id. Ten funnels are
-- allowed per experience and this is the third.
--
-- Both of these were retired a version on 2026-08-15: inserting the airport at
-- depth 4 re-numbered the deck park to 5, and the marks in v1 are depth integers
-- that cannot be re-read against the new order. See the ⚠ note in the header.
local FUNNEL = "MapReach 2"

local STORE_NAME = "MapReach_v2"
-- Two shapes of key in the one store: a running total per district, and how many
-- districts a given account has already been counted for.
local COUNT_PREFIX = "d_"
local MARK_PREFIX = "u_"

--[[
	Polled rather than hung off the gate attributes, for ProgressionFunnel's reason:
	a reach counter does not care whether it notices now or in fifteen seconds, and
	one sweep cannot miss a change that happened while nothing was listening.

	Slower than the funnel's five, because opening a district is a thing that
	happens a handful of times per account rather than per session.
]]
local SWEEP = 15

--==[ THE DISTRICTS ]=========================================================

type District = {
	name: string,
	reached: (Player) -> boolean,
}

--[[
	Walked out of Sections rather than written down, which is the same walk
	Sections.reachableGround does: the first stretch is always open, and every other
	one is open exactly when the gate in front of it is. Built once -- the list is
	static, the attributes it reads are not.
]]
local DISTRICTS: { District } = {}
do
	local first = Sections.List[1]
	if first then
		-- Being in the game IS having reached the first one.
		DISTRICTS[1] = { name = first.container, reached = function() return true end }
		for _, s in ipairs(Sections.List) do
			local beyond = s.beyond
			if beyond then
				local attr = Sections.openAttr(s.id)
				DISTRICTS[#DISTRICTS + 1] = {
					name = beyond,
					reached = function(plr)
						return plr:GetAttribute(attr) == true
					end,
				}
			end
		end
	end
end

-- How many leading districts this player has reached. See the note on prefix
-- closure above: it stops at the first one they have not.
local function depthOf(plr: Player): number
	local deep = 0
	for _, d in ipairs(DISTRICTS) do
		if not d.reached(plr) then break end
		deep += 1
	end
	return deep
end

--==[ THE COUNTERS ]==========================================================

local store: DataStore? = nil
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = ok and s or nil
	if not store then
		warn("[MapReach] No DataStore access -- district counts will not be kept."
			.. " In Studio enable File > Game Settings > Security >"
			.. " \"Enable Studio Access to API Services\". The funnel still reports.")
	end
end

-- How many districts this account has already been counted for, once read. In
-- memory for the session; the store is what makes it survive one.
local jobs = {}
local sent: { [Player]: number } = {}
local closing = false
local nextCounterWrite = {}
local function markKey(plr: Player): string
	return MARK_PREFIX .. plr.UserId
end
local function bank(plr: Player, depth: number)
	if not store then return end
	local job=jobs[plr.UserId]
	if not job then
		job={key=markKey(plr), wanted=depth, nextTry=0, failures=0, player=plr}
		jobs[plr.UserId]=job
	else
		job.wanted=math.max(job.wanted,depth)
		job.player=plr
		job.expires=nil
	end
end
local function budget(kind)
	return DataStoreService:GetRequestBudgetForRequestType(kind) > (if closing then 0 else 10)
end
local function attempt(job, callback)
	local ok,result=pcall(callback)
	if ok then job.failures=0;job.nextTry=0;return true,result end
	job.failures+=1
	job.nextTry=os.clock()+math.min(120,5*2^math.min(job.failures-1,5))+math.random()*5
	if job.failures==1 or job.failures%5==0 then warn("[MapReach] Deferred request for "..job.key..": "..tostring(result)) end
	return false,result
end
local function step(job)
	if os.clock()<job.nextTry then return end
	local s=store :: DataStore
	if job.high==nil then
		if not budget(Enum.DataStoreRequestType.GetAsync) then return end
		local ok,value=attempt(job,function() return s:GetAsync(job.key) end)
		if ok then job.high=tonumber(value) or 0 end
		return
	end
	if RunService:IsStudio() then job.high=math.max(job.high,job.wanted);return end
	-- Retry a failed mark without repeating its already acknowledged increment.
	if job.markPending then
		if not budget(Enum.DataStoreRequestType.SetIncrementAsync) then return end
		local high=job.high
		local ok=attempt(job,function() s:SetAsync(job.key,high) end)
		if ok then job.markPending=false end
		return
	end
	if job.high>=job.wanted then return end
	local index=job.high+1
	local key=COUNT_PREFIX..DISTRICTS[index].name
	if os.clock()<(nextCounterWrite[key] or 0) then return end
	if not budget(Enum.DataStoreRequestType.SetIncrementAsync) then return end
	nextCounterWrite[key]=os.clock()+8+math.random()*2
	local ok=attempt(job,function() s:IncrementAsync(key,1) end)
	if ok then job.high=index;job.markPending=true end
end
Players.PlayerRemoving:Connect(function(plr)
	sent[plr]=nil
	local job=jobs[plr.UserId]
	if job and job.player==plr then job.player=nil;job.expires=os.clock()+300 end
end)
task.spawn(function()
	task.wait(math.random()*8)
	while true do
		for id,job in pairs(jobs) do
			if job.expires and (os.clock()>job.expires or (job.high and job.high>=job.wanted and not job.markPending)) then
				if job.markPending or not job.high or job.high<job.wanted then warn("[MapReach] Telemetry retry expired for "..job.key) end
				jobs[id]=nil
			else
				step(job)
				task.wait(0.15)
			end
		end
		task.wait(0.5)
	end
end)
game:BindToClose(function()
	closing=true
	local deadline=os.clock()+25
	repeat
		local pending=false
		for _,job in pairs(jobs) do
			if not job.high or job.high<job.wanted or job.markPending then pending=true;break end
		end
		if not pending then return end
		task.wait(0.2)
	until os.clock()>=deadline
	warn("[MapReach] Shutdown ended with pending telemetry; gameplay profiles are separate")
end)

--==[ THE FUNNEL ]============================================================

--[[
	A LIFETIME FUNNEL, for ProgressionFunnel's reasons: the session id is the
	player's own user id, so every session they ever play is one run, and only the
	deepest step needs sending because Roblox auto-completes the ones below it.
]]
local function reportFunnel(plr: Player, depth: number)
	if depth <= (sent[plr] or 0) then return end
	local district = DISTRICTS[depth]
	if not district then return end

	-- pcall because telemetry must never be able to take down the thing it is
	-- measuring, which is the rule the other two funnels follow
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			plr, FUNNEL, tostring(plr.UserId), depth, district.name)
	end)
	if not ok then
		-- left where it was, so a throttled call is retried on the next sweep
		-- rather than written off for the session
		warn(("[MapReach] %s funnel step %d (%s) failed: %s")
			:format(plr.Name, depth, district.name, tostring(err)))
		return
	end
	sent[plr] = depth
	if RunService:IsStudio() then
		print(("[MapReach] %s -> %d %s (Studio: not recorded)")
			:format(plr.Name, depth, district.name))
	end
end

--==[ THE SWEEP ]=============================================================

--[[
	The profile has to have landed first, or every returning player reads as
	standing in the first district with every gate shut -- which for the funnel is a
	measurement of its own load time, and for the counters is a write it would then
	have to make again a second later.
]]
task.spawn(function()
	while true do
		task.wait(SWEEP)
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr:GetAttribute("ProfileLoaded") then
				local depth = depthOf(plr)
				if depth > 0 then
					reportFunnel(plr, depth)
					bank(plr, depth)
				end
			end
		end
	end
end)

if RunService:IsStudio() then
	local names = {}
	for _, d in ipairs(DISTRICTS) do names[#names + 1] = d.name end
	print(("[MapReach] ready -- %d districts (%s), store %q, funnel %q")
		:format(#DISTRICTS, table.concat(names, " -> "), STORE_NAME, FUNNEL))
end

