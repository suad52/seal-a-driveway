--!strict
--[[
	DrivewayRaceServer -- the starter, the timekeeper and the till.

	When the scheduler gives it a slot this offers the server a 30 second window to
	opt in, takes up to eight of them to a plaza, gives each of them THEIR OWN
	driveway sized to their own kit, and pays out on who finishes first.

	WHAT IS AUTHORITATIVE HERE AND WHAT IS NOT

	The neighbourhood's sealing is client-side and client-reported, and
	DrivewayServer says in as many words that a competitive economy would want the
	grid mirrored on the server. This is a competitive economy, so it is mirrored:
	each racer's progress lives in a RaceGrid on this script, stamped from the same
	stroke packets their client draws from, and the payout reads that buffer and
	nothing a client claims. A client can make its own driveway look finished and it
	will not move a coin.

	What the clients still own is the PICTURE -- the fluid solver, the cure, the
	shading. That has no business on a server that also has a neighbourhood to run.

	EVERY REMOTE IS A BOUNDARY, AND EACH HANDLER OPENS WITH ITS CHECKS

	  JoinResponse   phase, tutorial, cooldown, alive, not already in, not full
	  StrokeSend     phase, is a racer, has not already finished, packet is nine
	                 finite numbers, token bucket, blade inside their OWN lane,
	                 blade within MaxAimError of the player's own root, squeegee
	                 equipped

	WHY THE LANE GEOMETRY IS FROZEN AT SEAT TIME

	A lane is sized against the player's Squeegee Length and Walk Speed, and the
	shop is reachable from the HUD rail -- so a player can buy a rung mid-race. The
	levels are read ONCE, when the roster is seated, and the width the score is
	stamped with is the width that was sent to the client. Reading them live would
	mean a purchase made at 80% resized the job under the player, and the server and
	the client would be stamping different blades at the same coordinates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewayRace")
local Race = require(Pack:WaitForChild("RaceConfig"))
local RaceYard = require(Pack:WaitForChild("RaceYard"))
local RaceGrid = require(Pack:WaitForChild("RaceGrid"))
local RaceNet = require(Pack:WaitForChild("RaceNet"))
local RaceEconomy = require(Pack:WaitForChild("RaceEconomy"))

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
-- Who this event is offered to at all. A player still working through the
-- tutorial is not in it -- see `toEligible`.
local Tutorial = require(SealerUI:WaitForChild("Tutorial"))
local Upgrades = require(SealerUI:WaitForChild("Upgrades"))

-- How ServerScriptService.EventHandler reaches this file; it owns the schedule
-- for all three events -- see the note over the registration at the foot.
local EventBus = require(game.ServerScriptService.EventBus)
-- And how this file tells the AFK yard to let go of somebody it is about to
-- teleport out of it -- see `homeFor`, and the header on AfkBus itself.
local AfkBus = require(game.ServerScriptService.AfkBus)
-- The purse is handed over in one go at the flag, which is one of the moments
-- the second helping is sold at -- see the foot of runRace.
local DoubleUpService = require(game.ServerScriptService.DoubleUpService)
-- Only for the name of the attribute a duel publishes onto its two players --
-- see `inDuel`, and the long note on it in AfkService, which reads it for the
-- same reason.
local Duel = require(ReplicatedStorage:WaitForChild("Duel"):WaitForChild("DuelConfig"))

local Remotes = RaceNet.remotes()
local PromptRaceUI = Remotes.PromptRaceUI :: RemoteEvent
local JoinResponse = Remotes.JoinResponse :: RemoteEvent
local QueueUpdate  = Remotes.QueueUpdate :: RemoteEvent
local RaceState    = Remotes.RaceState :: RemoteEvent
local StrokeSend   = Remotes.StrokeSend
local RaceResults  = Remotes.RaceResults :: RemoteEvent

--==[ YARD ]==================================================================

local yard = RaceYard.build()

--==[ STATE ]=================================================================

type Saved = {
	cf: CFrame,
	equipped: string?,
}

local phase = Race.State.Idle

-- INVITING only: who has pressed Join, in press order, so the eight lanes go to
-- the eight quickest rather than to whoever the hash happens to iterate first.
local queue: { Player } = {}
local queued: { [Player]: boolean } = {}
local lastPress: { [Player]: number } = {}

-- IN_GAME / CLEANUP
local roster: { Player } = {}            -- index IS the slot
local slotOf: { [Player]: number } = {}
local playerOf: { [number]: Player } = {}
local live: { [number]: boolean } = {}   -- slots still in the yard
local saved: { [Player]: Saved } = {}
local startedRoster: { Player } = {}     -- the roster the purse was sized on

local lanes: { [number]: RaceYard.Lane } = {}
local grids: { [number]: RaceGrid.Class } = {}
local halfLenOf: { [number]: number } = {}
local doneAt: { [number]: number } = {}  -- slot -> elapsed seconds at the flag
local finishes = 0

local purseMult = 1
local startedAt = 0
local hardEndsAt = 0
local closingEndsAt: number? = nil

-- StrokeSend token buckets, one per player. See `accept`.
local tokens: { [Player]: number } = {}
local tokenStamp: { [Player]: number } = {}

--==[ WHAT THE WHOLE SERVER CAN SEE ]=========================================
local function setPhase(p: string)
	phase = p
	Pack:SetAttribute(Race.PhaseAttr, p)
end

setPhase(Race.State.Idle)

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

local function levelOn(plr: Player, id: string): number
	local lv = plr:GetAttribute("Upg_" .. id)
	if type(lv) ~= "number" then return 1 end
	return math.clamp(math.floor(lv), 1, Upgrades.maxLevel(id))
end

local function toRoster(remote: RemoteEvent, ...)
	for _, plr in ipairs(roster) do
		if plr.Parent then
			remote:FireClient(plr, ...)
		end
	end
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
local function standings()
	local out = {}
	for slot, plr in pairs(playerOf) do
		if live[slot] then
			local grid = grids[slot]
			out[#out + 1] = {
				slot = slot,
				name = plr.DisplayName,
				userId = plr.UserId,
				progress = if grid then RaceGrid.progress(grid) else 0,
				finishedAt = doneAt[slot],
			}
		end
	end
	table.sort(out, function(a, b)
		if (a.finishedAt ~= nil) ~= (b.finishedAt ~= nil) then
			return a.finishedAt ~= nil
		end
		if a.finishedAt and b.finishedAt then
			if a.finishedAt ~= b.finishedAt then return a.finishedAt < b.finishedAt end
			return a.slot < b.slot
		end
		if a.progress ~= b.progress then return a.progress > b.progress end
		return a.slot < b.slot
	end)
	return out
end

local function publishState(extra: { [string]: any }?)
	local now = os.clock()
	local payload: { [string]: any } = {
		phase = phase,
		elapsed = math.max(0, now - startedAt),
		rows = standings(),
	}
	-- nil while the field is still all out there, which is what tells the HUD to
	-- show elapsed time instead of a countdown -- see RaceUI.SetClock.
	if closingEndsAt then
		payload.closing = math.max(0, closingEndsAt - now)
	end
	if extra then
		for k, v in pairs(extra) do payload[k] = v end
	end
	toRoster(RaceState, payload)
end

--==[ THE INVITATION ]========================================================

local function openQueue()
	setPhase(Race.State.Inviting)
	table.clear(queue)
	table.clear(queued)
	toEligible(PromptRaceUI, {
		open = true,
		seconds = Race.InviteSeconds,
		max = Race.MaxPlayers,
		min = Race.MinPlayers,
	})
end

local function publishQueue()
	toEligible(QueueUpdate, {
		count = #queue,
		max = Race.MaxPlayers,
		min = Race.MinPlayers,
	})
end

local function closePrompt(reason: string?)
	toEligible(PromptRaceUI, { open = false, reason = reason })
end

JoinResponse.OnServerEvent:Connect(function(plr, wantsIn)
	-- The window is shut, or never opened. Not a warning: a player can press Join
	-- on the same frame the queue closes and that is not their fault.
	if phase ~= Race.State.Inviting then return end
	if type(wantsIn) ~= "boolean" then return end

	if inDuel(plr) then return end

	if not Tutorial.isDone(plr) then return end

	-- One press every JoinCooldown. A button cannot be pressed faster than this by
	-- hand, so anything quicker is a script and gets nothing.
	local now = os.clock()
	if (lastPress[plr] or 0) + Race.JoinCooldown > now then return end
	lastPress[plr] = now

	if not wantsIn then
		if queued[plr] then
			queued[plr] = nil
			local at = table.find(queue, plr)
			if at then table.remove(queue, at) end
			publishQueue()
		end
		QueueUpdate:FireClient(plr, { count = #queue, max = Race.MaxPlayers,
			min = Race.MinPlayers, you = false })
		return
	end

	if queued[plr] then return end
	if #queue >= Race.MaxPlayers then
		QueueUpdate:FireClient(plr, { count = #queue, max = Race.MaxPlayers,
			min = Race.MinPlayers, you = false, full = true })
		return
	end
	-- A dead player cannot be teleported anywhere useful and would arrive as a
	-- corpse on a start line. Refused with a reason rather than silently, or the
	-- button reads as broken.
	if not isAlive(plr) then
		QueueUpdate:FireClient(plr, { count = #queue, max = Race.MaxPlayers,
			min = Race.MinPlayers, you = false, dead = true })
		return
	end

	queued[plr] = true
	queue[#queue + 1] = plr
	QueueUpdate:FireClient(plr, { count = #queue, max = Race.MaxPlayers,
		min = Race.MinPlayers, you = true })
	publishQueue()
end)

--==[ TELEPORT IN AND OUT ]===================================================
local function homeFor(plr: Player, hrp: BasePart): CFrame
	return AfkBus.wake(plr) or hrp.CFrame
end

local function snapshot(plr: Player): Saved?
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return nil end
	local equipped = char:FindFirstChildOfClass("Tool")
	return {
		cf = homeFor(plr, hrp),
		equipped = if equipped then equipped.Name else nil,
	}
end

local function squeegeeOf(plr: Player): Tool?
	local char = plr.Character
	if char then
		local held = char:FindFirstChild(Race.ToolName)
		if held and held:IsA("Tool") then return held end
	end
	local backpack = plr:FindFirstChildOfClass("Backpack")
	if backpack then
		local t = backpack:FindFirstChild(Race.ToolName)
		if t and t:IsA("Tool") then return t end
	end

	local gear = plr:FindFirstChild("StarterGear")
	if gear then
		local t = gear:FindFirstChild(Race.ToolName)
		if t and t:IsA("Tool") then
			local copy = t:Clone()
			copy.Parent = plr:FindFirstChildOfClass("Backpack")
			return copy
		end
	end
	return nil
end

local function placeOnLane(plr: Player, slot: number)
	local lane = lanes[slot]
	if not lane then return end
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return end

	pcall(function()
		plr:RequestStreamAroundAsync(lane.spawnCF.Position, 5)
	end)

	char:PivotTo(lane.spawnCF)
	hum.Health = hum.MaxHealth
	hum.AutoRotate = true

	local tool = squeegeeOf(plr)
	if tool then
		-- EquipTool rather than reparenting: it fires the tool's own Equipped and goes
		-- through the humanoid, so the pose and the hotbar agree with it.
		pcall(function() hum:EquipTool(tool) end)
	end

	plr:SetAttribute("DrivewayRace", slot)
end

local function restore(plr: Player)
	plr:SetAttribute("DrivewayRace", nil)
	local rec = saved[plr]
	saved[plr] = nil
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return end

	if rec then
		pcall(function()
			plr:RequestStreamAroundAsync(rec.cf.Position, 5)
		end)
		char:PivotTo(rec.cf)
	end

	hum.Health = hum.MaxHealth
	for _, e in ipairs(hum:GetChildren()) do
		if e:IsA("ForceField") then e:Destroy() end
	end

	-- Put back whatever they were holding, which for a lot of players is the
	-- squeegee they were already carrying. Never destroys or replaces a tool.
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
	local have = (tokens[plr] or Race.StrokeBurst) + (now - last) * Race.StrokeHz
	if have > Race.StrokeBurst then have = Race.StrokeBurst end
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

local function markFinished(slot: number, plr: Player)
	if doneAt[slot] then return end
	local at = math.max(0, os.clock() - startedAt)
	doneAt[slot] = at
	finishes += 1

	if not closingEndsAt then
		closingEndsAt = math.min(hardEndsAt, os.clock() + Race.FinishGrace)
	end

	-- Their own place, to their own screen, at the moment it happened. The results
	-- card is minutes away for a player who finishes first, and being told nothing
	-- at all until then is being told nothing at the one moment they played for.
	if plr.Parent then
		RaceState:FireClient(plr, { phase = phase, finished = { place = finishes, at = at } })
	end
	print(("[DrivewayRace] %s finished %d in %.1fs"):format(plr.Name, finishes, at))
end

StrokeSend.OnServerEvent:Connect(function(plr, packet)
	if phase ~= Race.State.InGame then return end
	local slot = slotOf[plr]
	if not slot or not live[slot] then return end
	-- Already home. Their lane is full and their time is taken, so there is nothing
	-- left for a stroke to change -- and a finisher who keeps sweeping should not be
	-- paying for packets nobody reads.
	if doneAt[slot] then return end
	local lane, grid = lanes[slot], grids[slot]
	if not lane or not grid then return end

	if type(packet) ~= "table" or #packet ~= 9 then return end
	for i = 1, 9 do
		if not finite(packet[i]) then return end
	end
	if not accept(plr) then return end

	local sx, sz, ex, ez, ax, az, lx, lz, dt = packet[1], packet[2], packet[3],
		packet[4], packet[5], packet[6], packet[7], packet[8], packet[9]

	local halfW = lane.cw * lane.cell * 0.5 + 2
	local halfL = lane.ch * lane.cell * 0.5 + 2
	if math.abs(ex) > halfW or math.abs(ez) > halfL then return end
	if math.abs(sx) > halfW or math.abs(sz) > halfL then return end


	local _, _, hrp = characterOf(plr)
	if not hrp then return end
	local l = lane.topCF:PointToObjectSpace(hrp.Position)
	local dx, dz = ex - l.X, ez - l.Z
	if dx * dx + dz * dz > Race.MaxAimError * Race.MaxAimError then return end

	-- And they have to be holding a squeegee. Equipped, not merely owned: this is
	-- "are you sealing", not "do you have the item".
	local char = plr.Character
	if not char then return end
	local held = char:FindFirstChild(Race.ToolName)
	if not held or not held:IsA("Tool") then return end

	local tx, tz = ex - sx, ez - sz
	local tl = math.sqrt(tx * tx + tz * tz)
	if tl > Race.MaxStrokeTravel then
		local k = Race.MaxStrokeTravel / tl
		sx, sz = ex - tx * k, ez - tz * k
	end

	RaceGrid.StampSweep(grid, sx, sz, ex, ez, ax, az,
		halfLenOf[slot] or 3.2, Race.StampHalfBand)

	if RaceGrid.progress(grid) >= Race.FinishAt then
		markFinished(slot, plr)
	end
end)

--==[ THE RACE ]==============================================================

local function seat()
	table.clear(roster)
	table.clear(slotOf)
	table.clear(playerOf)
	table.clear(live)
	table.clear(lanes)
	table.clear(grids)
	table.clear(halfLenOf)
	table.clear(doneAt)
	finishes = 0
	closingEndsAt = nil

	local geoms: { RaceYard.Geom } = {}
	for _, plr in ipairs(queue) do
		if plr.Parent and isAlive(plr) and Tutorial.isDone(plr) and not inDuel(plr)
			and #roster < Race.MaxPlayers then
			local slot = #roster + 1
			roster[slot] = plr
			slotOf[plr] = slot
			playerOf[slot] = plr
			live[slot] = true

			local bladeLv = levelOn(plr, "Blade")
			local speedLv = levelOn(plr, "Speed")
			local w, l, cell, cw, ch = Race.geomFor(bladeLv, speedLv)
			geoms[slot] = { w = w, l = l, cell = cell, cw = cw, ch = ch }
			halfLenOf[slot] = Upgrades.valueAt("Blade", bladeLv) * 0.5
		end
	end
	startedRoster = table.clone(roster)

	if #roster == 0 then return end

	for slot, lane in pairs(RaceYard.layout(yard, geoms)) do
		lanes[slot] = lane
		local ox, oz = Race.gridOrigin(lane.cw, lane.ch, lane.cell)
		grids[slot] = RaceGrid.new(lane.cw, lane.ch, lane.cell, ox, oz)
	end
end

local function drop(plr: Player, keepName: boolean?)
	local slot = slotOf[plr]
	if not slot then return end
	live[slot] = nil
	slotOf[plr] = nil
	if not keepName then playerOf[slot] = nil end
	tokens[plr] = nil
	tokenStamp[plr] = nil
	toRoster(RaceState, { phase = phase, dropped = slot })
end

local function cancel(reason: string)
	closePrompt(reason)
	toEligible(QueueUpdate, { count = 0, max = Race.MaxPlayers,
		min = Race.MinPlayers, cancelled = true, reason = reason })
	table.clear(queue)
	table.clear(queued)
	setPhase(Race.State.Idle)
end

local function payAndReport(): { [Player]: number }
	local paid: { [Player]: number } = {}

	local board = standings()
	local bonus = RaceEconomy.showUp(purseMult)
	local rows = {}
	local byUser: { [number]: any } = {}

	for rank, entry in ipairs(board) do
		local plr = playerOf[entry.slot]
		local coins = RaceEconomy.award(rank, purseMult) + bonus
		local row = {
			rank = rank,
			slot = entry.slot,
			progress = entry.progress,
			finishedAt = entry.finishedAt,
			coins = coins,
			name = if plr then plr.DisplayName else Race.slotNameOf(entry.slot),
			userId = if plr then plr.UserId else 0,
		}
		rows[#rows + 1] = row
		if plr and plr.Parent then
			byUser[plr.UserId] = row
			paid[plr] = (paid[plr] or 0) + RaceEconomy.pay(plr, coins)
		end
	end

	for _, plr in ipairs(startedRoster) do
		if plr.Parent then
			local mine = byUser[plr.UserId]
			if not mine then
				paid[plr] = (paid[plr] or 0) + RaceEconomy.pay(plr, bonus)
			end
			RaceResults:FireClient(plr, {
				rows = rows,
				you = mine,
				showUp = bonus,
				multiplier = purseMult,
				averageLevel = RaceEconomy.averageLevel(startedRoster),
				seconds = Race.ResultSeconds,
			})
		end
	end

	return paid
end

local function clearRace()
	table.clear(roster)
	table.clear(slotOf)
	table.clear(playerOf)
	table.clear(live)
	table.clear(saved)
	table.clear(startedRoster)
	table.clear(lanes)
	table.clear(grids)
	table.clear(halfLenOf)
	table.clear(doneAt)
	finishes = 0
	closingEndsAt = nil
	-- Every lane parked back under the plaza, which is also what hides the last
	-- race's driveways from anybody who wanders past between events.
	RaceYard.layout(yard, {})
end

local function runRace()
	setPhase(Race.State.InGame)

	for slot, plr in ipairs(roster) do
		saved[plr] = snapshot(plr)
		placeOnLane(plr, slot)
	end

	local intro = {}
	for slot, plr in ipairs(roster) do
		intro[#intro + 1] = { slot = slot, name = plr.DisplayName, userId = plr.UserId }
	end
	for slot, plr in ipairs(roster) do
		local lane = lanes[slot]
		if plr.Parent and lane then
			RaceState:FireClient(plr, {
				phase = phase,
				roster = intro,
				countIn = Race.CountInSeconds,
				cap = Race.MatchSeconds,
				purse = RaceEconomy.previewFor(startedRoster),
				multiplier = purseMult,
				lane = {
					slot = slot,
					topCF = lane.topCF,
					w = lane.w, l = lane.l,
					cell = lane.cell, cw = lane.cw, ch = lane.ch,
					halfLen = halfLenOf[slot],
				},
			})
		end
	end

	task.wait(Race.CountInSeconds)

	startedAt = os.clock()
	hardEndsAt = startedAt + Race.MatchSeconds
	toRoster(RaceState, { phase = phase, go = true, cap = Race.MatchSeconds })

	local boardAt = 0
	while true do
		task.wait(0.1)
		local now = os.clock()

		boardAt += 0.1
		if boardAt >= 0.2 then
			boardAt = 0
			publishState()
		end

		-- Everybody left. Nothing to referee, so stop refereeing.
		if next(live) == nil then break end
		if now >= hardEndsAt then break end
		if closingEndsAt and now >= closingEndsAt then break end

		local allIn = true
		for slot in pairs(live) do
			if not doneAt[slot] then allIn = false break end
		end
		if allIn then break end
	end

	setPhase(Race.State.Cleanup)
	publishState({ over = true })

	local paid = payAndReport()

	task.wait(Race.ResultSeconds)

	for _, plr in ipairs(startedRoster) do
		if plr.Parent then restore(plr) end
	end
	
	for plr, amount in pairs(paid) do
		if plr.Parent then
			DoubleUpService.offer(plr, amount, "race")
		end
	end

	clearRace()
	RaceState:FireAllClients({ phase = Race.State.Idle })
	setPhase(Race.State.Idle)
end

local function runEvent()
	openQueue()
	publishQueue()

	local deadline = os.clock() + Race.InviteSeconds
	while os.clock() < deadline do
		task.wait(0.25)
		-- Full house: there is nothing left to wait for, and making eight people who
		-- all pressed Join stand about for the rest of the window is the easiest
		-- twenty seconds in the game to give back.
		if #queue >= Race.MaxPlayers then break end
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

	if #queue < Race.MinPlayers then
		cancel(("Not enough racers -- %d of %d needed"):format(#queue, Race.MinPlayers))
		return
	end

	seat()
	if #roster < Race.MinPlayers then
		cancel("Not enough racers made it to the yard")
		clearRace()
		return
	end

	purseMult = RaceEconomy.purseMultiplier(startedRoster)
	table.clear(queue)
	table.clear(queued)

	local ok, err = pcall(runRace)
	if not ok then
		warn("[DrivewayRace] the race errored and is being unwound: " .. tostring(err))
		for _, plr in ipairs(startedRoster) do
			if plr.Parent then pcall(restore, plr) end
		end
		clearRace()
		RaceState:FireAllClients({ phase = Race.State.Idle })
		setPhase(Race.State.Idle)
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
			if phase == Race.State.Inviting then publishQueue() end
		end
		if phase == Race.State.Inviting then
			PromptRaceUI:FireClient(plr, { open = false })
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
		if phase == Race.State.Inviting then publishQueue() end
	end
	-- keepName so the results screen can still say who lane 3 was
	drop(plr, true)
end)

Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		local slot = slotOf[plr]
		if not slot or phase ~= Race.State.InGame then return end
		-- The character arrives before its parts do; one wait is enough, and the
		-- placement re-checks everything it needs.
		char:WaitForChild("HumanoidRootPart", 5)
		if slotOf[plr] == slot and phase == Race.State.InGame then
			placeOnLane(plr, slot)
		end
	end)
end)

--==[ REGISTRATION ]==========================================================
EventBus.provideRace(function(): boolean
	if not Race.Enabled then return false end
	if #Players:GetPlayers() < Race.MinPlayers then return false end
	if phase ~= Race.State.Idle then return false end
	-- Blocking, and it has to be: the scheduler must not begin timing the next gap
	-- until the yard is empty and the phase is back to Idle.
	local ok, err = pcall(runEvent)
	if not ok then
		warn("[DrivewayRace] the event errored: " .. tostring(err))
		setPhase(Race.State.Idle)
	end
	return true
end)

if not Race.Enabled then
	print("[DrivewayRace] scheduler is OFF (RaceConfig.Enabled = false)."
		.. " The yard and the remotes are up; no race will be offered.")
end

do
	local w, l = Race.maxSize()
	local bw, bl = Race.geomFor(1, 1)
	print(("[DrivewayRace] yard built at %s; lanes %.0f x %.0f to %d x %d studs")
		:format(tostring(Race.Origin), bw, bl, w, l))
end
