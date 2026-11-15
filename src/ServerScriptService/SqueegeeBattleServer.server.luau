--!strict
--[[
	SqueegeeBattleServer -- the scheduler, the referee and the till.

	Every 15-20 minutes this offers the server a 30 second window to opt in,
	takes up to eight of them to a 100 x 100 arena, gives them sixty seconds to
	paint it, and pays out on who is wearing the most of it.

	WHAT IS AUTHORITATIVE HERE AND WHAT IS NOT

	The neighbourhood's sealing is client-side and client-reported, and
	DrivewayServer says in as many words that a competitive economy would want
	the grid mirrored on the server. This IS the competitive economy, so it is
	mirrored: the score lives in a BattleGrid on this script, stamped from the
	same stroke packets the clients draw from, and the payout reads that buffer
	and nothing a client claims. A client can make its own screen say anything it
	likes and it will not move a coin.

	What the clients still own is the PICTURE -- the fluid solver, the cure, the
	shading. That is 50,000 cells of shallow-water physics thirty times a second
	and it has no business on a server that also has a neighbourhood to run.

	EVERY REMOTE IS A BOUNDARY, AND EACH HANDLER OPENS WITH ITS CHECKS

	  JoinResponse   phase, cooldown, alive, not already in, roster not full
	  StrokeSend     phase, is a participant, packet is nine finite numbers,
	                 token bucket, blade inside the canvas, blade within
	                 MaxAimError of the player's own root, squeegee equipped
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("SqueegeeBattle")
local Battle = require(Pack:WaitForChild("BattleConfig"))
local BattleArena = require(Pack:WaitForChild("BattleArena"))
local BattleGrid = require(Pack:WaitForChild("BattleGrid"))
local BattleEconomy = require(Pack:WaitForChild("BattleEconomy"))
local BattleNet = require(Pack:WaitForChild("BattleNet"))
-- Who this event is offered to at all. A player still working through the
-- tutorial is not in it -- see `toEligible`.
local Tutorial = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Tutorial"))
-- How ServerScriptService.EventHandler reaches this file. It owns the schedule
-- for both events now -- see the note over the registration at the foot.
local EventBus = require(game.ServerScriptService.EventBus)
-- And how this file tells the AFK yard to let go of somebody it is about to
-- teleport out of it -- see `homeFor`, and the header on AfkBus itself.
local AfkBus = require(game.ServerScriptService.AfkBus)
-- The purse is handed over in one go at the buzzer, which is one of the two
-- moments in the game the second helping is sold at -- see the foot of
-- runMatch, and DoubleUpService for the rules it goes through.
local DoubleUpService = require(game.ServerScriptService.DoubleUpService)
-- How a player-started 1v1 borrows this arena, and the config that says which
-- attribute marks somebody a duel is already holding. See the provider at the
-- foot of this file, and the header on DuelBus.
local DuelBus = require(game.ServerScriptService.DuelBus)
local Duel = require(ReplicatedStorage:WaitForChild("Duel"):WaitForChild("DuelConfig"))

local Remotes = BattleNet.remotes()
local PromptEventUI = Remotes.PromptEventUI :: RemoteEvent
local JoinResponse  = Remotes.JoinResponse :: RemoteEvent
local QueueUpdate   = Remotes.QueueUpdate :: RemoteEvent
local MatchState    = Remotes.MatchState :: RemoteEvent
local StrokeSend    = Remotes.StrokeSend
local StrokeRelay   = Remotes.StrokeRelay
local MatchResults  = Remotes.MatchResults :: RemoteEvent

--==[ ARENA ]=================================================================

local arena, canvas = BattleArena.build()
local canvasTopCF = BattleArena.topCF(canvas)
local spawnPads = BattleArena.spawnsOf(arena)

local gridOX, gridOZ = BattleArena.gridOrigin()
local score = BattleGrid.new(Battle.GridCells, Battle.CellSize, gridOX, gridOZ, Battle.MaxPlayers)

--==[ STATE ]=================================================================

type Saved = {
	cf: CFrame,
	walkSpeed: number,
	autoRotate: boolean,
	equipped: string?,
	tools: { string },
}

local phase = Battle.State.Idle

-- INVITING only: who has pressed Join, in press order, so the eight seats go to
-- the eight quickest rather than to whoever the hash happens to iterate first.
local queue: { Player } = {}
local queued: { [Player]: boolean } = {}
local lastPress: { [Player]: number } = {}

-- IN_GAME / CLEANUP
local roster: { Player } = {}            -- index IS the slot
local slotOf: { [Player]: number } = {}
local playerOf: { [number]: Player } = {}
local live: { [number]: boolean } = {}   -- slots still in the arena
local saved: { [Player]: Saved } = {}
local startedRoster: { Player } = {}     -- the roster the purse was sized on
local purseMult = 1
local matchEndsAt = 0
local matchStartedAt = 0
local duelPurse: number? = nil
local duelPaid = 0
local bladeHalf: { [number]: number } = {}
local function setDuel(on: boolean)
	Pack:SetAttribute(Battle.DuelAttr, on or nil)
end

setDuel(false)

-- StrokeSend token buckets, one per player. See `accept`.
local tokens: { [Player]: number } = {}
local tokenStamp: { [Player]: number } = {}

-- Strokes accepted since the last relay flush, as flat rows.
local pending: { { number } } = {}

-- The match's own Heartbeat. At file scope so the error unwind can kill it; see
-- where it is connected.
local matchConn: RBXScriptConnection? = nil

-- The Random that used to live here fed Battle.nextGap, and the gap is timed by
-- ServerScriptService.EventHandler now -- see the note where the scheduler was.

--==[ WHAT THE WHOLE SERVER CAN SEE ]=========================================
local function setPhase(p: string)
	phase = p
	Pack:SetAttribute(Battle.PhaseAttr, p)
end

-- `seconds` is a gap from now; the attribute is the absolute SERVER time the
-- event opens, so no client has to know when this was called.
local function publishNextAt(seconds: number?)
	if seconds then
		Pack:SetAttribute(Battle.NextAtAttr, workspace:GetServerTimeNow() + seconds)
	else
		-- nil while an event is actually running: there is no "next" to count to,
		-- and leaving a stale one up draws a clock ticking through the match
		Pack:SetAttribute(Battle.NextAtAttr, nil)
	end
end

setPhase(Battle.State.Idle)

--==[ SMALL HELPERS ]=========================================================

local function characterOf(plr: Player): (Model?, Humanoid?, BasePart?)
	local char = plr.Character
	if not char or not char.Parent then return nil, nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or not hrp:IsA("BasePart") then return char, hum, nil end
	return char, hum, hrp
end

local function isAlive(plr: Player): boolean
	local _, hum, hrp = characterOf(plr)
	return hum ~= nil and hrp ~= nil and hum.Health > 0
end

local function toRoster(remote: RemoteEvent, ...)
	for _, plr in ipairs(roster) do
		if plr.Parent then
			remote:FireClient(plr, ...)
		end
	end
end

local function toEveryone(remote: RemoteEvent, ...)
	remote:FireAllClients(...)
end

local function inDuel(plr: Player): boolean
	return plr:GetAttribute(Duel.PlayerAttr) ~= nil
end

local function toEligible(remote: RemoteEvent, ...)
	for _, plr in ipairs(Players:GetPlayers()) do
		if Tutorial.isDone(plr) and not inDuel(plr) then
			remote:FireClient(plr, ...)
		end
	end
end

--==[ THE SCORE, PUBLISHED ]==================================================
local function standingsPayload(): { any }
	local rows = {}
	for _, entry in ipairs(BattleGrid.standings(score, live)) do
		local plr = playerOf[entry.slot]
		rows[#rows + 1] = {
			slot = entry.slot,
			share = entry.share,
			name = if plr then plr.DisplayName else Battle.slotNameOf(entry.slot),
			userId = if plr then plr.UserId else 0,
		}
	end
	return rows
end

local function publishState(extra: { [string]: any }?)
	local left = math.max(0, matchEndsAt - os.clock())
	local payload: { [string]: any } = {
		phase = phase,
		left = left,
		total = Battle.MatchSeconds,
		rows = standingsPayload(),
	}
	if extra then
		for k, v in pairs(extra) do payload[k] = v end
	end
	toRoster(MatchState, payload)
end

--==[ THE INVITATION ]========================================================

local function openQueue()
	setPhase(Battle.State.Inviting)
	table.clear(queue)
	table.clear(queued)
	toEligible(PromptEventUI, {
		open = true,
		seconds = Battle.InviteSeconds,
		max = Battle.MaxPlayers,
		min = Battle.MinPlayers,
	})
end

local function publishQueue()
	toEligible(QueueUpdate, {
		count = #queue,
		max = Battle.MaxPlayers,
		min = Battle.MinPlayers,
	})
end

local function closePrompt(reason: string?)
	toEligible(PromptEventUI, { open = false, reason = reason })
end

JoinResponse.OnServerEvent:Connect(function(plr, wantsIn)
	-- The window is shut, or never opened. Not a warning: a player can press
	-- Join on the same frame the queue closes and that is not their fault.
	if phase ~= Battle.State.Inviting then return end
	if type(wantsIn) ~= "boolean" then return end
	if inDuel(plr) then return end
	if not Tutorial.isDone(plr) then return end

	-- One press every JoinCooldown. A button cannot be pressed faster than this
	-- by hand, so anything quicker is a script and gets nothing.
	local now = os.clock()
	if (lastPress[plr] or 0) + Battle.JoinCooldown > now then return end
	lastPress[plr] = now

	if not wantsIn then
		if queued[plr] then
			queued[plr] = nil
			local at = table.find(queue, plr)
			if at then table.remove(queue, at) end
			publishQueue()
		end
		QueueUpdate:FireClient(plr, { count = #queue, max = Battle.MaxPlayers,
			min = Battle.MinPlayers, you = false })
		return
	end

	if queued[plr] then return end
	if #queue >= Battle.MaxPlayers then
		QueueUpdate:FireClient(plr, { count = #queue, max = Battle.MaxPlayers,
			min = Battle.MinPlayers, you = false, full = true })
		return
	end
	
	if not isAlive(plr) then
		QueueUpdate:FireClient(plr, { count = #queue, max = Battle.MaxPlayers,
			min = Battle.MinPlayers, you = false, dead = true })
		return
	end

	queued[plr] = true
	queue[#queue + 1] = plr
	QueueUpdate:FireClient(plr, { count = #queue, max = Battle.MaxPlayers,
		min = Battle.MinPlayers, you = true })
	publishQueue()
end)

--==[ TELEPORT IN AND OUT ]===================================================
local function homeFor(plr: Player, hrp: BasePart): CFrame
	return AfkBus.wake(plr) or hrp.CFrame
end

local function snapshot(plr: Player): Saved?
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return nil end

	local tools: { string } = {}
	local backpack = plr:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, t in ipairs(backpack:GetChildren()) do
			if t:IsA("Tool") then tools[#tools + 1] = t.Name end
		end
	end
	local equipped = char:FindFirstChildOfClass("Tool")

	return {
		cf = homeFor(plr, hrp),
		walkSpeed = hum.WalkSpeed,
		autoRotate = hum.AutoRotate,
		equipped = if equipped then equipped.Name else nil,
		tools = tools,
	}
end

local function squeegeeOf(plr: Player): Tool?
	local char = plr.Character
	if char then
		local held = char:FindFirstChild(Battle.ToolName)
		if held and held:IsA("Tool") then return held end
	end
	local backpack = plr:FindFirstChildOfClass("Backpack")
	if backpack then
		local t = backpack:FindFirstChild(Battle.ToolName)
		if t and t:IsA("Tool") then return t end
	end

	local gear = plr:FindFirstChild("StarterGear")
	if gear then
		local t = gear:FindFirstChild(Battle.ToolName)
		if t and t:IsA("Tool") then
			local copy = t:Clone()
			copy.Parent = plr:FindFirstChildOfClass("Backpack")
			return copy
		end
	end
	return nil
end

local function padCFrame(slot: number): CFrame
	local pad = spawnPads[slot]
	if pad then
		return pad.CFrame * CFrame.new(0, Battle.SpawnRise, 0)
	end
	-- The arena always builds eight pads, so this is unreachable -- but a nil
	-- CFrame here would drop a player at the world origin, which is inside the
	-- neighbourhood's road.
	return CFrame.new(Battle.Origin + Vector3.new(0, Battle.SpawnRise, 0))
end

local function placeInArena(plr: Player, slot: number)
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return end

	local target = padCFrame(slot)

	pcall(function()
		plr:RequestStreamAroundAsync(target.Position, 5)
	end)

	char:PivotTo(target)
	hum.Health = hum.MaxHealth

	local speed = Battle.walkSpeedOf(plr)
	if speed then hum.WalkSpeed = speed end
	hum.AutoRotate = true

	local tool = squeegeeOf(plr)
	if tool then
		pcall(function() hum:EquipTool(tool) end)
	end
	
	plr:SetAttribute("BattleArena", slot)
end

local function restore(plr: Player)
	plr:SetAttribute("BattleArena", nil)
	local rec = saved[plr]
	saved[plr] = nil
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return end

	if rec then
		pcall(function()
			plr:RequestStreamAroundAsync(rec.cf.Position, 5)
		end)
		char:PivotTo(rec.cf)
		hum.AutoRotate = rec.autoRotate

		local eff = plr:GetAttribute("Eff_WalkSpeed")
		hum.WalkSpeed = if type(eff) == "number" and eff > 0 then eff else rec.walkSpeed
	end

	hum.Health = hum.MaxHealth
	for _, e in ipairs(hum:GetChildren()) do
		if e:IsA("ForceField") then e:Destroy() end
	end

	if rec then
		hum:UnequipTools()
		if rec.equipped then
			local backpack = plr:FindFirstChildOfClass("Backpack")
			local t = backpack and backpack:FindFirstChild(rec.equipped)
			if t and t:IsA("Tool") then
				pcall(function() hum:EquipTool(t) end)
			end
		end
	end
end

--==[ STROKES ]===============================================================

local function accept(plr: Player): boolean
	local now = os.clock()
	local last = tokenStamp[plr] or now
	local have = (tokens[plr] or Battle.StrokeBurst) + (now - last) * Battle.StrokeHz
	if have > Battle.StrokeBurst then have = Battle.StrokeBurst end
	tokenStamp[plr] = now
	if have < 1 then
		tokens[plr] = have
		return false
	end
	tokens[plr] = have - 1
	return true
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

StrokeSend.OnServerEvent:Connect(function(plr, packet)
	if phase ~= Battle.State.InGame then return end
	local slot = slotOf[plr]
	if not slot or not live[slot] then return end
	if type(packet) ~= "table" or #packet ~= 9 then return end
	for i = 1, 9 do
		if not finite(packet[i]) then return end
	end
	if not accept(plr) then return end

	local sx, sz, ex, ez, ax, az, lx, lz, dt = packet[1], packet[2], packet[3],
		packet[4], packet[5], packet[6], packet[7], packet[8], packet[9]

	local half = Battle.HalfCanvas + 2
	if math.abs(ex) > half or math.abs(ez) > half then return end
	if math.abs(sx) > half or math.abs(sz) > half then return end

	local _, _, hrp = characterOf(plr)
	if not hrp then return end
	local l = canvasTopCF:PointToObjectSpace(hrp.Position)
	local dx, dz = ex - l.X, ez - l.Z
	if dx * dx + dz * dz > Battle.MaxAimError * Battle.MaxAimError then return end

	local char = plr.Character
	if not char then return end
	local held = char:FindFirstChild(Battle.ToolName)
	if not held or not held:IsA("Tool") then return end

	local tx, tz = ex - sx, ez - sz
	local tl = math.sqrt(tx * tx + tz * tz)
	if tl > Battle.MaxStrokeTravel then
		local k = Battle.MaxStrokeTravel / tl
		sx, sz = ex - tx * k, ez - tz * k
	end
	dt = math.clamp(dt, 1 / 240, 0.25)

	-- This slot's blade, frozen at seat time. A duel scores each player with the
	-- rubber they actually bought; a scheduled match scores everyone with the
	-- arena's. See `bladeHalf`.
	score:StampSweep(slot, sx, sz, ex, ez, ax, az,
		bladeHalf[slot] or Battle.BladeHalfLen, Battle.StampHalfBand)

	pending[#pending + 1] = { slot, sx, sz, ex, ez, ax, az, lx, lz, dt }
end)

--==[ MATCH ]=================================================================
local function seat(forDuel: boolean?)
	table.clear(roster)
	table.clear(slotOf)
	table.clear(playerOf)
	table.clear(live)
	table.clear(bladeHalf)
	for _, plr in ipairs(queue) do
		if plr.Parent and isAlive(plr) and Tutorial.isDone(plr)
			and (forDuel or not inDuel(plr))
			and #roster < Battle.MaxPlayers then
			local slot = #roster + 1
			roster[slot] = plr
			slotOf[plr] = slot
			playerOf[slot] = plr
			live[slot] = true
			-- Frozen here, which is the point of it. See `bladeHalf`.
			bladeHalf[slot] = Battle.bladeHalfOf(plr)
		end
	end
	startedRoster = table.clone(roster)
end

local function drop(plr: Player, keepName: boolean?)
	local slot = slotOf[plr]
	if not slot then return end
	live[slot] = nil
	slotOf[plr] = nil
	if not keepName then playerOf[slot] = nil end
	score:release(slot)
	tokens[plr] = nil
	tokenStamp[plr] = nil
	toRoster(MatchState, { phase = phase, dropped = slot })
end

local function cancel(reason: string)
	closePrompt(reason)
	toEligible(QueueUpdate, { count = 0, max = Battle.MaxPlayers,
		min = Battle.MinPlayers, cancelled = true, reason = reason })
	table.clear(queue)
	table.clear(queued)
	setPhase(Battle.State.Idle)
end

local function payAndReport(): { [Player]: number }
	local paid: { [Player]: number } = {}
	local board = BattleGrid.standings(score, live)
	local duelling = duelPurse ~= nil
	local duelOK = duelling and #board >= 1 and (duelPurse :: number) > 0
	local bonus = if duelling then 0 else BattleEconomy.showUp(purseMult)
	duelPaid = 0

	local rows = {}
	local byUser: { [number]: any } = {}

	for rank, entry in ipairs(board) do
		local plr = playerOf[entry.slot]
		local coins
		if duelling then
			coins = if duelOK and rank == 1 then (duelPurse :: number) else 0
		else
			coins = BattleEconomy.award(rank, purseMult) + bonus
		end
		local row = {
			rank = rank,
			slot = entry.slot,
			share = entry.share,
			coins = coins,
			name = if plr then plr.DisplayName else Battle.slotNameOf(entry.slot),
			userId = if plr then plr.UserId else 0,
		}
		rows[#rows + 1] = row
		if plr and plr.Parent then
			byUser[plr.UserId] = row
			local got = BattleEconomy.pay(plr, coins)
			paid[plr] = (paid[plr] or 0) + got
			-- What the duel actually moved, reported back through DuelBus so DuelServer
			-- only spends the pair's allowance on a purse that really landed.
			if duelling then duelPaid += got end
		end
	end

	for slot, plr in ipairs(startedRoster) do
		if plr.Parent then
			local mine = byUser[plr.UserId]
			-- `bonus` is already 0 for a duel, so this pays a dropped duellist nothing
			-- and still gives them the screen. See the note over `duelling`.
			if not mine then
				paid[plr] = (paid[plr] or 0) + BattleEconomy.pay(plr, bonus)
			end
			MatchResults:FireClient(plr, {
				rows = rows,
				you = mine,
				finished = mine ~= nil,
				showUp = bonus,
				multiplier = purseMult,
				averageLevel = BattleEconomy.averageLevel(startedRoster),
				seconds = Battle.ResultSeconds,
				slot = slot,
			})
		end
	end

	return paid
end

local function runMatch()
	setPhase(Battle.State.InGame)
	score:Reset()
	table.clear(pending)

	for slot, plr in ipairs(roster) do
		saved[plr] = snapshot(plr)
		placeInArena(plr, slot)
	end

	local intro = {}
	for slot, plr in ipairs(roster) do
		intro[#intro + 1] = {
			slot = slot, name = plr.DisplayName, userId = plr.UserId,
			blade = bladeHalf[slot],
		}
	end
	toRoster(MatchState, {
		phase = phase,
		roster = intro,
		countIn = Battle.CountInSeconds,
		total = Battle.MatchSeconds,
		purse = BattleEconomy.previewFor(startedRoster),
		multiplier = purseMult,
	})
	
	task.wait(Battle.CountInSeconds)

	matchStartedAt = os.clock()
	matchEndsAt = matchStartedAt + Battle.MatchSeconds
	toRoster(MatchState, { phase = phase, go = true, total = Battle.MatchSeconds })

	local relayEvery = 1 / Battle.StrokeHz
	local boardEvery = 0.2
	local relayAt, boardAt = 0, 0

	matchConn = RunService.Heartbeat:Connect(function(dt)
		relayAt += dt
		boardAt += dt

		if relayAt >= relayEvery then
			relayAt = 0
			if #pending > 0 then
				local batch = pending
				pending = {}
				-- One table, fired at each participant. The client skips rows for
				-- its own slot: it applied those the frame it made them, and
				-- replaying them a fifth of a second late would double the paint.
				for _, plr in ipairs(roster) do
					if plr.Parent then
						StrokeRelay:FireClient(plr, batch)
					end
				end
			end
		end

		if boardAt >= boardEvery then
			boardAt = 0
			publishState()
		end
	end)

	local function liveCount(): number
		local n = 0
		for _ in pairs(live) do n += 1 end
		return n
	end

	while os.clock() < matchEndsAt do
		task.wait(0.1)
		-- Everybody left. Nothing to referee, so stop refereeing.
		if next(live) == nil then break end
		if duelPurse ~= nil and liveCount() < 2 then break end
	end

	matchConn:Disconnect()
	matchConn = nil
	setPhase(Battle.State.Cleanup)
	publishState({ over = true })

	local paid = payAndReport()

	task.wait(Battle.ResultSeconds)

	for _, plr in ipairs(startedRoster) do
		if plr.Parent then restore(plr) end
	end

	local duelling2 = duelPurse ~= nil
	local doubleSource = if duelling2 then "duel" else "battle"
	for plr, amount in pairs(paid) do
		if plr.Parent then
			local shown, why = DoubleUpService.offer(plr, amount, doubleSource)
			-- Only for duels: a scheduled match offers this to eight people at once and
			-- most of them are legitimately under the minimum, which would be eight
			-- lines of log an event for nothing. A duel offers it to exactly one.
			if duelling2 and not shown then
				print(("[Duel] no double-up card for %s (won %d): %s")
					:format(plr.Name, amount, tostring(why)))
			end
		end
	end
	if duelling2 and next(paid) == nil then
		print("[Duel] no double-up card: the arena duel paid nobody")
	end

	score:Reset()
	table.clear(pending)
	table.clear(roster)
	table.clear(slotOf)
	table.clear(playerOf)
	table.clear(live)
	table.clear(saved)
	table.clear(startedRoster)

	toEveryone(MatchState, { phase = Battle.State.Idle })
	setPhase(Battle.State.Idle)
end

local function runEvent()
	-- There is no "next event" while one is happening. Cleared rather than left
	-- at a passed deadline, or every clock in the game draws a countdown ticking
	-- backwards through the match it is already running.
	publishNextAt(nil)
	openQueue()
	publishQueue()

	local deadline = os.clock() + Battle.InviteSeconds
	while os.clock() < deadline do
		task.wait(0.25)
		-- Full house: there is nothing left to wait for, and making eight people
		-- who all pressed Join stand about for the rest of the window is the
		-- easiest twenty seconds in the game to give back.
		if #queue >= Battle.MaxPlayers then break end
	end

	closePrompt()

	-- Anybody who left or died between pressing Join and the window closing.
	for i = #queue, 1, -1 do
		local plr = queue[i]
		if not plr.Parent or not isAlive(plr) then
			queued[plr] = nil
			table.remove(queue, i)
		end
	end

	if #queue < Battle.MinPlayers then
		cancel(("Not enough painters -- %d of %d needed")
			:format(#queue, Battle.MinPlayers))
		return
	end

	seat()
	if #roster < Battle.MinPlayers then
		cancel("Not enough painters made it to the arena")
		return
	end

	purseMult = BattleEconomy.purseMultiplier(startedRoster)
	table.clear(queue)
	table.clear(queued)

	local ok, err = pcall(runMatch)
	if not ok then
		warn("[SqueegeeBattle] the match errored and is being unwound: " .. tostring(err))
		if matchConn then
			matchConn:Disconnect()
			matchConn = nil
		end
		for _, plr in ipairs(startedRoster) do
			if plr.Parent then pcall(restore, plr) end
		end
		score:Reset()
		table.clear(roster); table.clear(slotOf); table.clear(playerOf)
		table.clear(live); table.clear(saved); table.clear(startedRoster)
		toEveryone(MatchState, { phase = Battle.State.Idle })
		setPhase(Battle.State.Idle)
	end
end

--==[ PLAYER LIFECYCLE ]======================================================
local function watchDuelStart(plr: Player)
	plr:GetAttributeChangedSignal(Duel.PlayerAttr):Connect(function()
		if not inDuel(plr) then return end
		if queued[plr] then
			queued[plr] = nil
			local at = table.find(queue, plr)
			if at then table.remove(queue, at) end
			if phase == Battle.State.Inviting then publishQueue() end
		end
		if phase == Battle.State.Inviting then
			PromptEventUI:FireClient(plr, { open = false })
		end
	end)
end

Players.PlayerAdded:Connect(watchDuelStart)
for _, plr in ipairs(Players:GetPlayers()) do watchDuelStart(plr) end

Players.PlayerRemoving:Connect(function(plr)
	lastPress[plr] = nil
	tokens[plr] = nil
	tokenStamp[plr] = nil
	saved[plr] = nil

	if queued[plr] then
		queued[plr] = nil
		local at = table.find(queue, plr)
		if at then table.remove(queue, at) end
		if phase == Battle.State.Inviting then publishQueue() end
	end
	-- keepName so the results screen can still say who slot 3 was
	drop(plr, true)
end)

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		local slot = slotOf[plr]
		if not slot or phase ~= Battle.State.InGame then return end
		-- The character arrives before its parts do; one wait is enough, and the
		-- placement re-checks everything it needs.
		char:WaitForChild("HumanoidRootPart", 5)
		if slotOf[plr] == slot and phase == Battle.State.InGame then
			placeInArena(plr, slot)
		end
	end)
end)

--==[ SCHEDULER -- MOVED OUT ]================================================
EventBus.provideBattle(
	function(): boolean
		if not Battle.Enabled then return false end
		if #Players:GetPlayers() < Battle.MinPlayers then return false end
		if phase ~= Battle.State.Idle then return false end
		-- Blocking, and it has to be: the scheduler must not begin timing the next
		-- gap until the arena is empty and the phase is back to Idle.
		local ok, err = pcall(runEvent)
		if not ok then
			warn("[SqueegeeBattle] the event errored: " .. tostring(err))
			setPhase(Battle.State.Idle)
		end
		return true
	end,

	function(seconds: number?)
		publishNextAt(seconds)
	end
)

--==[ THE ARENA, LENT OUT FOR A 1v1 ]=========================================
DuelBus.provideReady(function(): boolean
	return Battle.Enabled and phase == Battle.State.Idle
end)

DuelBus.provideDuel(function(a: Player, b: Player, prize: number): (boolean, number)
	if not Battle.Enabled then return false, 0 end
	if phase ~= Battle.State.Idle then return false, 0 end
	if not (a.Parent and b.Parent and isAlive(a) and isAlive(b)) then return false, 0 end

	table.clear(queue)
	table.clear(queued)
	queue[1], queue[2] = a, b

	setDuel(true)

	-- forDuel: both of these players are marked as duelling, which is exactly what
	-- the ordinary seat() refuses. See the note over it.
	seat(true)
	table.clear(queue)

	if #roster < 2 then
		setDuel(false)
		table.clear(roster); table.clear(slotOf); table.clear(playerOf)
		table.clear(live); table.clear(startedRoster); table.clear(bladeHalf)
		return false, 0
	end

	purseMult = BattleEconomy.purseMultiplier(startedRoster)
	duelPurse = prize
	duelPaid = 0

	local ok, err = pcall(runMatch)
	if not ok then
		warn("[SqueegeeBattle] a duel errored and is being unwound: " .. tostring(err))
		if matchConn then
			matchConn:Disconnect()
			matchConn = nil
		end
		for _, plr in ipairs(startedRoster) do
			if plr.Parent then pcall(restore, plr) end
		end
		score:Reset()
		table.clear(roster); table.clear(slotOf); table.clear(playerOf)
		table.clear(live); table.clear(saved); table.clear(startedRoster)
		toEveryone(MatchState, { phase = Battle.State.Idle })
		setPhase(Battle.State.Idle)
	end
	
	local moved = duelPaid
	duelPurse = nil
	duelPaid = 0
	setDuel(false)
	return ok, moved
end)

if not Battle.Enabled then
	print("[SqueegeeBattle] scheduler is OFF (BattleConfig.Enabled = false)."
		.. " The arena and the remotes are up; no event will be offered.")
end

print("[SqueegeeBattle] arena built at " .. tostring(Battle.Origin)
	.. ("; %d x %d grid at %.2f studs/cell")
		:format(Battle.GridCells, Battle.GridCells, Battle.CellSize))
