--!strict
--[[
	LeaderboardService -- who is on the three boards in the depot courtyard.

	One OrderedDataStore per board (see Leaderboards for which stat and why), a
	write per player on a slow timer and on the way out, and a read of the top
	hundred on another slow timer. The answer is published as one JSON string in
	ReplicatedStorage rather than through a remote, so it replicates to everybody
	including players who join between refreshes, and the client that draws it
	needs no request of its own.

	EVERYTHING HERE IS FAIL-SOFT ON PURPOSE.

	OrderedDataStores are unavailable in a Studio session without API services,
	throttled under load, and occasionally just down. None of that should take the
	game with it -- a board that says it cannot reach the records is a far smaller
	failure than a server script that errors on startup and stops paying anybody.
	So every store call is pcall'd, the publish loop keeps running whatever
	happens, and a failed read leaves the last good payload up rather than
	blanking the boards.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local Leaderboards = require(SealerUI:WaitForChild("Leaderboards"))

--==[ THE STORES ]============================================================

local stores: { [string]: OrderedDataStore } = {}
local storesOK = true
for _, board in ipairs(Leaderboards.List) do
	local ok, s = pcall(function()
		return DataStoreService:GetOrderedDataStore(board.store)
	end)
	if ok and s then
		stores[board.id] = s
	else
		storesOK = false
	end
end
if not storesOK then
	warn("[LeaderboardService] No OrderedDataStore access -- the boards will show"
		.. " 'records unavailable'.\n  In Studio: File > Game Settings > Security >"
		.. " \"Enable Studio Access to API Services\".")
end

--==[ WHERE THE ANSWER GOES ]=================================================

local payload = SealerUI:FindFirstChild(Leaderboards.DataName)
if not payload then
	local made = Instance.new("StringValue")
	made.Name = Leaderboards.DataName
	made.Parent = SealerUI
	payload = made
end
local Payload = payload :: StringValue

--==[ NAMES ]=================================================================

--[[
	UserId -> name, resolved once per server.

	GetNameFromUserIdAsync is a web call and the top hundred is a hundred of them,
	so the cache is what keeps a refresh to the handful of ids that are new since
	the last one. Players already in the server are free, and are checked first --
	they are also the ids most likely to be near the top.
]]
local nameCache: { [number]: string } = {}

local function nameOf(userId: number): string
	local cached = nameCache[userId]
	if cached then return cached end

	local here = Players:GetPlayerByUserId(userId)
	if here then
		nameCache[userId] = here.Name
		return here.Name
	end

	local ok, n = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	-- A deleted or otherwise unresolvable account still holds its rank; it just
	-- shows as its id rather than dropping a row out of the middle of the board.
	local resolved = (ok and type(n) == "string" and n) or ("User " .. userId)
	nameCache[userId] = resolved
	return resolved
end

--==[ WRITING ]===============================================================

--[[
	Only non-zero values are written, and that is a display decision as much as a
	quota one.

	Every profile in the game has Rebirths = 0 the moment it is created, so
	writing unconditionally would fill a hundred places with people who have never
	taken one, sorted by nothing. A player who has not done the thing the board
	measures simply is not on that board yet.
]]
local pending = {}
local confirmed = {}
local closing = false
local function record(plr: Player)
	if plr:GetAttribute("ProfileLoaded") ~= true then return end
	for _,board in ipairs(Leaderboards.List) do
		if stores[board.id] then
			local value=Leaderboards.valueOf(plr,board)
			local key=board.id..":"..tostring(plr.UserId)
			if value>0 then
				local job=pending[key]
				if job then
					job.value=value
				elseif confirmed[key]~=value then
					pending[key]={store=stores[board.id],userId=tostring(plr.UserId),value=value,nextTry=0,failures=0}
				end
			end
		end
	end
end
local function writePending()
	for key,job in pairs(pending) do
		if os.clock()>=job.nextTry then
			if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementSortedAsync)<=(if closing then 0 else 2) then return end
			local value=job.value
			if confirmed[key]==value then pending[key]=nil;continue end
			local ok,err=pcall(function() job.store:SetAsync(job.userId,value) end)
			if ok then
				confirmed[key]=value
				job.failures=0
				if job.value==value then pending[key]=nil else job.nextTry=os.clock()+8 end
			else
				job.failures+=1
				job.nextTry=os.clock()+math.min(120,5*2^math.min(job.failures-1,5))+math.random()*5
				if job.failures==1 or job.failures%5==0 then warn("[LeaderboardService] Deferred "..key..": "..tostring(err)) end
			end
			task.wait(0.35)
		end
	end
end
task.spawn(function()
	while true do writePending();task.wait(0.5) end
end)

--==[ READING ]===============================================================

local cachedRows = {}
local function fetch(board): { { n: string, v: number } }?
	local s = stores[board.id]
	if not s then return nil end
	if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.GetSortedAsync) <= 1 then return cachedRows[board.id] end
	local ok, pages = pcall(function()
		return s:GetSortedAsync(false, Leaderboards.TopN)
	end)
	if not ok or not pages then return cachedRows[board.id] end

	local ok2, rows = pcall(function()
		return (pages :: DataStorePages):GetCurrentPage()
	end)
	if not ok2 or type(rows) ~= "table" then return cachedRows[board.id] end

	local out = {}
	for _, row in ipairs(rows) do
		local id = tonumber(row.key)
		local v = tonumber(row.value)
		if id and v then
			out[#out + 1] = { n = nameOf(id), v = v }
		end
	end
	cachedRows[board.id] = out
	return out
end

local function publish()
	local data: { [string]: any } = { ok = storesOK, boards = {} }
	local any = false
	for _, board in ipairs(Leaderboards.List) do
		local rows = fetch(board)
		if rows then
			any = true
			data.boards[board.id] = rows
		end
	end
	--[[
		A refresh where every read failed leaves the last good payload alone.

		The alternative is publishing an empty board, which turns a passing throttle
		into "the leaderboard reset" on every screen in the server. Stale by a minute
		is the better of the two wrong answers.

		Gated on storesOK as well, or a place with no OrderedDataStore access at all
		never gets to publish `ok = false` and the boards sit on "no entries yet" --
		which reads as "nobody has played" rather than "this cannot be checked".
	]]
	if not any and storesOK and Payload.Value ~= "" then return end

	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, data)
	if ok then Payload.Value = encoded end
end

--==[ TIMERS ]================================================================

-- Slow on purpose. Both numbers are quota, not taste: a full refresh is one
-- sorted read per board, and a write pass is three keys per player.
local REFRESH_SECONDS = 60
local WRITE_SECONDS = 120

task.spawn(function()
	while true do
		publish()
		task.wait(REFRESH_SECONDS + math.random(0,15))
	end
end)

task.spawn(function()
	while true do
		task.wait(WRITE_SECONDS + math.random(0,20))
		for _, plr in ipairs(Players:GetPlayers()) do
			record(plr)
		end
	end
end)

--[[
	And on the way out, which is the write that actually matters.

	A session shorter than WRITE_SECONDS would otherwise never reach the board at
	all, and the last timed write is up to two minutes behind whatever the player
	finished on.
]]
Players.PlayerRemoving:Connect(record)

-- BindToClose so a server shutting down still banks the last session. Roblox
-- gives this a few seconds; three keys per player is well inside it.
game:BindToClose(function()
	closing = true
	for _, plr in ipairs(Players:GetPlayers()) do
		record(plr)
	end
	local deadline=os.clock()+25
	while next(pending) and os.clock()<deadline do task.wait(0.2) end
	if next(pending) then warn("[LeaderboardService] Shutdown ended with pending leaderboard updates") end
end)
