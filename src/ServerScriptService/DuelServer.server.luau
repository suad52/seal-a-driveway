--!strict
--[[
	DuelServer -- the broker, the referee and the till for player-started 1v1s.

	A player presses E on another player, picks one of three modes, and the other
	one says yes or no. If they say yes, both are taken somewhere private, the mode
	is run, the winner is paid the purse and both are put back exactly where they
	were standing. Nothing about it costs either of them anything.

	WHAT IS AUTHORITATIVE HERE AND WHAT IS NOT

	The neighbourhood's sealing is client-side and client-reported -- DrivewayServer
	says so in its own header -- and the two sealing modes here are that same
	simulation, so their score is reported too. It is rate-limited on the way in
	(see `noteCoverage`), which stops casual tampering and is not a hard boundary.

	That is a deliberate trade and it is bounded by the money rather than by the
	simulation: a duel purse is capped, gated four ways and frozen before either
	player agrees to anything -- see DuelEconomy. The most a perfect cheat can win
	is one capped purse every Duel.PaidCooldown, three times per opponent, and only
	on an account old enough to be worth losing. Mirroring the grid for two players
	would cost the neighbourhood's frame time to raise that bar no higher.

	Squeegee Battle IS server-scored, and for free -- it is run by the arena, which
	has mirrored its grid since the day it shipped. See DuelBus.

	EVERY REMOTE IS A BOUNDARY, AND EACH HANDLER OPENS WITH ITS CHECKS

	  SendChallenge  enabled, is a Player, is not yourself, both alive, both
	                 tutorial-done, neither busy, in range, cooldown, mode exists
	  OfferReply     an offer is actually standing for this player, it has not
	                 lapsed, it is a boolean
	  ReportCoverage the slab is a duel slab, of THIS duel, the reporter is in it,
	                 they own the slab if it is owned, coverage is a number in
	                 range, and the area rate limiter accepts it
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("Duel")
local Duel = require(Pack:WaitForChild("DuelConfig"))
local DuelNet = require(Pack:WaitForChild("DuelNet"))
local DuelArena = require(Pack:WaitForChild("DuelArena"))
local DuelEconomy = require(Pack:WaitForChild("DuelEconomy"))

local Sealer = ReplicatedStorage:WaitForChild("DrivewaySealer")
local SealerRemotes = Sealer:WaitForChild("Remotes")
local ReportCoverage = SealerRemotes:WaitForChild("ReportCoverage") :: RemoteEvent
local DrivewayComplete = SealerRemotes:WaitForChild("DrivewayComplete") :: RemoteEvent

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
-- A player still being taught the game is not offered a duel and cannot send one
-- -- see `eligible`, and the same call SqueegeeBattleServer.toEligible makes.
local Tutorial = require(SealerUI:WaitForChild("Tutorial"))

-- How the arena is borrowed for the Squeegee Battle mode; see that file.
local DuelBus = require(game.ServerScriptService.DuelBus)
-- And how a duellist is let go of by the AFK yard before being teleported out of
-- it -- see `homeFor`, and the header on AfkBus itself.
local AfkBus = require(game.ServerScriptService.AfkBus)
-- The purse is handed over in one go at the flag, which is one of the moments the
-- second helping is sold at -- see the foot of `start`, and DoubleUpService for
-- the rules it goes through.
local DoubleUpService = require(game.ServerScriptService.DoubleUpService)

local Remotes = DuelNet.remotes()
local SendChallenge = Remotes.SendChallenge :: RemoteEvent
local Offer         = Remotes.Offer :: RemoteEvent
local OfferReply    = Remotes.OfferReply :: RemoteEvent
local Notice        = Remotes.Notice :: RemoteEvent
local DuelState     = Remotes.DuelState :: RemoteEvent
local DuelResult    = Remotes.DuelResult :: RemoteEvent

DuelArena.sweep()

--==[ STATE ]=================================================================

type Saved = {
	cf: CFrame,
	equipped: string?,
}

type Session = {
	id: number,
	mode: string,
	slot: number?,                        -- arena slot; nil for the borrowed arena
	arena: DuelArena.Arena?,
	players: { Player },                  -- index IS the side: 1 challenger, 2 acceptor
	sideOf: { [Player]: number },
	prize: number,
	reason: string?,                      -- why it will not pay, from DuelEconomy
	saved: { [Player]: Saved },
	score: { [Player]: number },           -- fraction done (SpeedRun) / slabs (TurfWar)
	covered: { [Player]: { [BasePart]: { cov: number, at: number } } },
	claimedBy: { [BasePart]: Player },
	claimArea: { [Player]: number },
	startedAt: number,
	endsAt: number,
	winner: Player?,
	quit: Player?,                        -- who walked out, if anybody did
	over: boolean,
	-- What actually reached a wallet, kept so the second-helping offer can be made
	-- AFTER both players are home. See the foot of `start`.
	paidTo: Player?,
	paidAmount: number,
}

local sessions: { [number]: Session } = {}
local duelOf: { [Player]: Session } = {}
local slotBusy: { [number]: boolean } = {}
local nextId = 0

-- The one offer standing for a player, keyed by the TARGET: a player can be
-- asked by several people at once and only the newest card is on their screen,
-- so only the newest is answerable. See `sendOffer`.
type Pending = { from: Player, mode: string, prize: number, reason: string?, at: number }
local offers: { [Player]: Pending } = {}
local lastChallenge: { [Player]: number } = {}
local freeAt: { [Player]: number } = {}   -- rematch cooldown, per player

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

local function say(plr: Player, text: string, ok: boolean?)
	if plr.Parent then Notice:FireClient(plr, { text = text, ok = ok == true }) end
end

local function busyReason(plr: Player): string?
	if not plr.Parent then return "They have left the game" end
	if duelOf[plr] then return "They are already in a duel" end
	if plr:GetAttribute("BattleArena") ~= nil then return "They are in the arena" end
	if plr:GetAttribute("DrivewayRace") ~= nil then return "They are in a race" end
	if not Tutorial.isDone(plr) then return "They are still learning the ropes" end
	if not isAlive(plr) then return "They are not on their feet" end
	local wait = (freeAt[plr] or 0) - os.clock()
	if wait > 0 then
		return ("They just finished a duel -- %ds"):format(math.ceil(wait))
	end
	return nil
end

local function toBoth(session: Session, remote: RemoteEvent, ...)
	for _, plr in ipairs(session.players) do
		if plr.Parent then remote:FireClient(plr, ...) end
	end
end

--==[ THE E PROMPT ]==========================================================
local function promptOf(plr: Player): ProximityPrompt?
	local _, _, hrp = characterOf(plr)
	if not hrp then return nil end
	-- Under the attachment, not directly under the root -- see Duel.PromptHeight.
	local at = hrp:FindFirstChild(Duel.PromptAttachName)
	local found = at and at:FindFirstChild(Duel.PromptName)
	return if found and found:IsA("ProximityPrompt") then found else nil
end

local function refreshPrompt(plr: Player)
	local p = promptOf(plr)
	if not p then return end
	local free = duelOf[plr] == nil
		and plr:GetAttribute("BattleArena") == nil
		and plr:GetAttribute("DrivewayRace") == nil
		and Tutorial.isDone(plr)
	if p.Enabled ~= free then p.Enabled = free end
end

local function buildPrompt(plr: Player, char: Model)
	if not Duel.Enabled then return end
	local hrp = char:WaitForChild("HumanoidRootPart", 10)
	if not hrp or not hrp:IsA("BasePart") then return end
	if hrp:FindFirstChild(Duel.PromptAttachName) then return end

	local at = Instance.new("Attachment")
	at.Name = Duel.PromptAttachName
	at.Position = Vector3.new(0, Duel.PromptHeight, 0)
	at.Parent = hrp

	local p = Instance.new("ProximityPrompt")
	p.Name = Duel.PromptName
	p.ActionText = Duel.PromptText
	p.ObjectText = plr.DisplayName
	p.KeyboardKeyCode = Duel.PromptKey
	p.HoldDuration = Duel.PromptHold
	p.MaxActivationDistance = Duel.PromptRange

	p.RequiresLineOfSight = false
	p.ClickablePrompt = true
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = at

	refreshPrompt(plr)
end

--==[ THE CHALLENGE ]=========================================================

local function quoteFor(a: Player, b: Player): (number, string?)
	return DuelEconomy.prizeFor(a, b), DuelEconomy.reasonFor(a, b)
end

SendChallenge.OnServerEvent:Connect(function(from, target, modeId)
	if not Duel.Enabled then return end
	if typeof(target) ~= "Instance" or not target:IsA("Player") then return end
	if target == from then return end

	local mode = Duel.modeById(modeId)
	if not mode then return end

	-- One press every ChallengeCooldown. A menu cannot be driven faster than this
	-- by hand, so anything quicker is a script and gets nothing.
	local now = os.clock()
	if (lastChallenge[from] or 0) + Duel.ChallengeCooldown > now then
		say(from, "Slow down a moment")
		return
	end
	lastChallenge[from] = now

	local mineBad = busyReason(from)
	if mineBad then
		-- Every reason is phrased about the OTHER player, because that is where all
		-- but one of them are read. Turning it round costs one substitution and saves
		-- writing the same eight sentences twice.
		say(from, (mineBad:gsub("^They", "You")))
		return
	end

	local theirs = busyReason(target)
	if theirs then
		say(from, theirs)
		return
	end

	local _, _, mine = characterOf(from)
	local _, _, theirs2 = characterOf(target)
	if not mine or not theirs2 then return end
	if (mine.Position - theirs2.Position).Magnitude > Duel.PromptRange * 2.5 then
		say(from, "Get closer to challenge them")
		return
	end

	-- Squeegee Battle borrows the one arena the scheduled event owns, so it can be
	-- unavailable in a way the other two modes never are. Said now rather than
	-- after the target has accepted.
	if mode.id == "Battle" and not DuelBus.arenaFree() then
		say(from, "The arena is busy -- try Speed Run or Turf War")
		return
	end

	local prize, reason = quoteFor(from, target)

	offers[target] = {
		from = from, mode = mode.id, prize = prize, reason = reason, at = now,
	}

	Offer:FireClient(target, {
		fromName = from.DisplayName,
		fromUserId = from.UserId,
		mode = mode.id,
		modeName = mode.name,
		blurb = mode.blurb,
		prize = prize,
		reason = reason,
		seconds = Duel.OfferSeconds,
	})
	say(from, ("Challenge sent to %s"):format(target.DisplayName), true)

	task.delay(Duel.OfferSeconds + 1, function()
		local standing = offers[target]
		if standing and standing.at == now then
			offers[target] = nil
			if from.Parent then
				say(from, ("%s did not answer"):format(target.DisplayName))
			end
		end
	end)
end)

--==[ TELEPORT IN AND OUT ]===================================================
local function snapshot(plr: Player): Saved?
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return nil end
	local equipped = char:FindFirstChildOfClass("Tool")
	return {
		cf = AfkBus.wake(plr) or hrp.CFrame,
		equipped = if equipped then equipped.Name else nil,
	}
end

local function toolOf(plr: Player, name: string): Tool?
	local char = plr.Character
	if char then
		local held = char:FindFirstChild(name)
		if held and held:IsA("Tool") then return held end
	end
	local backpack = plr:FindFirstChildOfClass("Backpack")
	if backpack then
		local t = backpack:FindFirstChild(name)
		if t and t:IsA("Tool") then return t end
	end
	return nil
end

local function squeegeeOf(plr: Player): Tool?
	return toolOf(plr, Duel.ToolName)
end

local function place(session: Session, plr: Player)
	local side = session.sideOf[plr]
	local arena = session.arena
	if not side or not arena then return end
	local cf = arena.spawns[side]
	if not cf then return end

	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then return end

	-- Ask for the geometry BEFORE moving them. The arena is Persistent so this
	-- should be a formality -- but the AFK yard shipped exactly this bug without
	-- it, and the cost of asking is one yield on a path that is already yielding.
	pcall(function() plr:RequestStreamAroundAsync(cf.Position, 5) end)

	char:PivotTo(cf)
	hum.Health = hum.MaxHealth
	hum.AutoRotate = true

	local tool = toolOf(plr, Duel.BucketName) or squeegeeOf(plr)
	if tool then
		-- EquipTool rather than reparenting: it fires the tool's own Equipped and
		-- goes through the humanoid, so the pose and the hotbar agree with it.
		pcall(function() hum:EquipTool(tool) end)
	end
end

local function markIn(session: Session, plr: Player)
	plr:SetAttribute(Duel.PlayerAttr, session.mode)
	if session.mode == "SpeedRun" or session.mode == "TurfWar" then
		plr:SetAttribute(Duel.InfiniteAttr, true)
	end
	refreshPrompt(plr)
end

local function restore(session: Session, plr: Player)
	plr:SetAttribute(Duel.PlayerAttr, nil)
	plr:SetAttribute(Duel.InfiniteAttr, nil)

	local rec = session.saved[plr]
	session.saved[plr] = nil
	local char, hum, hrp = characterOf(plr)
	if not char or not hum or not hrp then
		refreshPrompt(plr)
		return
	end

	if rec then
		pcall(function() plr:RequestStreamAroundAsync(rec.cf.Position, 5) end)
		char:PivotTo(rec.cf)
	end

	hum.Health = hum.MaxHealth
	for _, e in ipairs(hum:GetChildren()) do
		if e:IsA("ForceField") then e:Destroy() end
	end

	-- Put back whatever they were holding, which for most players is the squeegee
	-- they walked in with. Never destroys or replaces a tool.
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

	refreshPrompt(plr)
end

--==[ THE SCORE ]=============================================================
local function maxRate(area: number): number
	if area <= 0 then return 1 end
	return math.max(0.12, Duel.MaxAreaPerSecond / area)
end

local function sessionOfSlab(slab: BasePart): Session?
	local id = slab:GetAttribute(Duel.SlabAttr)
	if type(id) ~= "number" then return nil end
	return sessions[id]
end

local function rescore(session: Session, plr: Player)
	local mine = session.covered[plr]
	if not mine then return end

	if session.mode == "SpeedRun" then
		-- One slab, one number: how much of THEIR driveway is done.
		local best = 0
		for _, e in pairs(mine) do
			if e.cov > best then best = e.cov end
		end
		session.score[plr] = best
	else
		-- Turf War counts CLAIMED driveways, which is a different thing from
		-- coverage: half-sealing six of them is worth nothing at all, and that is the
		-- mode. `claimArea` rides along as the tie break.
		local n, area = 0, 0
		for part, owner in pairs(session.claimedBy) do
			if owner == plr then
				n += 1
				area += (part:GetAttribute(Duel.SlabAreaAttr) :: number?) or 0
			end
		end
		session.score[plr] = n
		session.claimArea[plr] = area
	end
end

local function tryClaim(session: Session, plr: Player, slab: BasePart, cov: number)
	if session.over then return end
	if session.mode ~= "TurfWar" then return end
	if cov < Duel.TurfWar.ClaimAt then return end
	if session.claimedBy[slab] then return end

	session.claimedBy[slab] = plr
	rescore(session, plr)
	print(("[Duel] %s claimed %s"):format(plr.Name, slab:GetAttribute("DrivewayName") or slab.Name))
end

local function finishSpeedRun(session: Session, plr: Player)
	if session.over or session.winner then return end
	session.winner = plr
	session.over = true
end

local function noteCoverage(plr: Player, slab: BasePart, coverage: number)
	local session = sessionOfSlab(slab)
	if not session or session.over then return end
	if duelOf[plr] ~= session then return end
	if session.startedAt <= 0 then return end   -- still in the count-in

	local owner = slab:GetAttribute(Duel.SlabOwnerAttr)
	if type(owner) == "number" and owner ~= plr.UserId then return end

	local mine = session.covered[plr]
	if not mine then return end

	local area = (slab:GetAttribute(Duel.SlabAreaAttr) :: number?) or (slab.Size.X * slab.Size.Z)
	local now = os.clock()
	local e = mine[slab]
	if not e then
		e = { cov = 0, at = now }
		mine[slab] = e
	end

	-- The limiter, and it CLAMPS rather than rejects: a player on a bad connection
	-- genuinely does send one long gap, and dropping it would punish lag rather
	-- than cheating. The next report picks the ground back up.
	local allowed = e.cov + maxRate(area) * (now - e.at) + 0.01
	e.at = now
	local was = e.cov
	e.cov = math.min(coverage, allowed)
	-- Coverage is a high-water mark. The clamp above can move the figure backwards
	-- when a client reports a smaller number, and a driveway that un-seals itself
	-- is not a thing that happens.
	if e.cov < was then e.cov = was end

	rescore(session, plr)

	if session.mode == "SpeedRun" then
		if e.cov >= Duel.SpeedRun.FinishAt then finishSpeedRun(session, plr) end
	else
		tryClaim(session, plr, slab, e.cov)
	end
end

ReportCoverage.OnServerEvent:Connect(function(plr, slab, coverage)
	if typeof(slab) ~= "Instance" or not slab:IsA("BasePart") then return end
	if slab:GetAttribute(Duel.SlabAttr) == nil then return end
	if type(coverage) ~= "number" or coverage ~= coverage then return end
	noteCoverage(plr, slab, math.clamp(coverage, 0, 1))
end)

DrivewayComplete.OnServerEvent:Connect(function(plr, slab)
	if typeof(slab) ~= "Instance" or not slab:IsA("BasePart") then return end
	local session = sessionOfSlab(slab)
	if not session or session.over or duelOf[plr] ~= session then return end

	local owner = slab:GetAttribute(Duel.SlabOwnerAttr)
	if type(owner) == "number" and owner ~= plr.UserId then return end

	local mine = session.covered[plr]
	local e = mine and mine[slab]
	local target = if session.mode == "SpeedRun"
		then Duel.SpeedRun.FinishAt else Duel.TurfWar.ClaimAt
	if not e or e.cov < target - 0.05 then return end

	e.cov = math.max(e.cov, target)
	rescore(session, plr)
	if session.mode == "SpeedRun" then
		finishSpeedRun(session, plr)
	else
		tryClaim(session, plr, slab, e.cov)
	end
end)

--==[ WHAT THE TWO OF THEM SEE ]==============================================

local function statePayload(session: Session, extra: { [string]: any }?): { [string]: any }
	local rows = {}
	for side, plr in ipairs(session.players) do
		rows[side] = {
			side = side,
			name = plr.DisplayName,
			userId = plr.UserId,
			score = session.score[plr] or 0,
			area = session.claimArea[plr] or 0,
		}
	end
	local payload: { [string]: any } = {
		mode = session.mode,
		rows = rows,
		prize = session.prize,
		reason = session.reason,
	}
	if session.startedAt > 0 and session.endsAt > 0 then
		payload.left = math.max(0, session.endsAt - os.clock())
	end
	if extra then
		for k, v in pairs(extra) do payload[k] = v end
	end
	return payload
end

local function publish(session: Session, extra: { [string]: any }?)
	toBoth(session, DuelState, statePayload(session, extra))
end

--==[ RUNNING ONE ]===========================================================

local function freeSlot(): number?
	for i = 1, Duel.MaxConcurrent do
		if not slotBusy[i] then return i end
	end
	return nil
end

local function settle(session: Session): Player?
	local a, b = session.players[1], session.players[2]
	if not a or not b then return nil end

	local quit = session.quit
	if quit then
		local other = if quit == a then b else a
		if other.Parent then return other end
		return nil
	end

	if session.winner then return session.winner end

	local sa, sb = session.score[a] or 0, session.score[b] or 0
	if sa ~= sb then return if sa > sb then a else b end

	-- Level on the headline number. Turf War breaks on total square footage, which
	-- is the brief's own second measure; Speed Run has nothing further to ask.
	if session.mode == "TurfWar" then
		local aa, ab = session.claimArea[a] or 0, session.claimArea[b] or 0
		if aa ~= ab then return if aa > ab then a else b end
	end
	return nil
end

local function payAndReport(session: Session)
	local winner = settle(session)
	local a, b = session.players[1], session.players[2]

	local paid = 0
	local reason = session.reason
	local forfeit = session.quit ~= nil and winner ~= nil

	if not winner then
		reason = reason or "A draw -- no purse"
	elseif a and b then
		local late = DuelEconomy.reasonFor(a, b)
		reason = reason or late
		if not reason then
			paid = DuelEconomy.pay(winner, session.prize)
			if paid > 0 then
				-- Taken from what pay() MANAGED rather than from what it was asked for,
				-- so a player whose leaderstats never appeared is not later offered the
				-- chance to double cash they were never given.
				session.paidTo = winner
				session.paidAmount = paid
				DuelEconomy.notePaid(a, b)
				print(("[Duel] %s beat %s at %s for %d")
					:format(winner.Name, (if winner == a then b else a).Name,
						session.mode, paid))
			end
		end
	end

	if forfeit then
		print(("[Duel] %s won a %s by forfeit -- %s left")
			:format((winner :: Player).Name, session.mode, (session.quit :: Player).Name))
	end

	if winner and paid == 0 and reason then
		print(("[Duel] %s won a %s but it paid nothing: %s")
			:format(winner.Name, session.mode, reason))
	end

	for _, plr in ipairs(session.players) do
		if plr.Parent then
			DuelResult:FireClient(plr, {
				mode = session.mode,
				modeName = Duel.nameOf(session.mode),
				rows = statePayload(session).rows,
				won = winner == plr,
				-- so the card can say WHY they won without a scoreline behind it
				forfeit = forfeit,
				draw = winner == nil,
				prize = if winner == plr then paid else 0,
				quoted = session.prize,
				reason = reason,
				seconds = Duel.ResultSeconds,
			})
		end
	end
end

--[[
	Tear one down. Safe to call twice, and it must be: it runs on the ordinary path
	and again from the error unwind.
]]
local function clear(session: Session)
	for _, plr in ipairs(session.players) do
		duelOf[plr] = nil
		-- Only for somebody still here. A Player instance that has left is never
		-- looked up again, and stamping one into a table keyed by Player is a leak
		-- that holds the instance for the life of the server.
		if plr.Parent then
			freeAt[plr] = os.clock() + Duel.RematchCooldown
			restore(session, plr)
		end
	end
	DuelArena.destroy(session.arena)
	session.arena = nil
	if session.slot then slotBusy[session.slot] = nil end
	sessions[session.id] = nil
end


local function runSealingMode(session: Session)
	for _, plr in ipairs(session.players) do
		session.saved[plr] = snapshot(plr)
		markIn(session, plr)
		place(session, plr)
	end

	local cap = if session.mode == "TurfWar" then Duel.TurfWar.Seconds else Duel.SpeedRun.Cap
	-- Turf War needs longer: eight slabs to build against Speed Run's two. See the
	-- note on Duel.TurfWar.CountIn.
	local countIn = if session.mode == "TurfWar"
		then Duel.TurfWar.CountIn else Duel.CountInSeconds

	publish(session, {
		phase = Duel.State.CountIn,
		countIn = countIn,
		cap = cap,
		-- Speed Run's headline is a percentage, Turf War's is a count of driveways.
		-- Sent once so the HUD knows which it is drawing rather than guessing from
		-- the shape of the numbers.
		unit = if session.mode == "SpeedRun" then "percent" else "count",
		target = if session.mode == "SpeedRun" then Duel.SpeedRun.FinishAt else Duel.TurfWar.Lots,
	})
	task.wait(countIn)

	if session.mode == "TurfWar" then
		for _, plr in ipairs(session.players) do
			plr:SetAttribute(Duel.InfiniteAttr, nil)
		end
	end


	if not session.over then
		session.startedAt = os.clock()
		session.endsAt = session.startedAt + cap
		publish(session, { phase = Duel.State.InGame, go = true, cap = cap })

		local tick = 0
		while true do
			task.wait(0.1)
			if session.over then break end
			if os.clock() >= session.endsAt then break end

			-- Both gone. Nothing to referee, so stop refereeing.
			local anyone = false
			for _, plr in ipairs(session.players) do
				if duelOf[plr] == session then anyone = true break end
			end
			if not anyone then break end

			tick += 0.1
			if tick >= 0.2 then
				tick = 0
				publish(session, { phase = Duel.State.InGame })
			end
		end
	end

	session.over = true
	publish(session, { phase = Duel.State.Over, over = true })
	payAndReport(session)

	task.wait(Duel.ResultSeconds)
end

local function runBattleMode(session: Session): boolean
	local a, b = session.players[1], session.players[2]
	if not a or not b then return false end

	for _, plr in ipairs(session.players) do
		plr:SetAttribute(Duel.PlayerAttr, session.mode)
		refreshPrompt(plr)
	end

	publish(session, {
		phase = Duel.State.CountIn,
		unit = "share",
		handOff = true,   -- the arena's own HUD takes over from here
	})

	local reason = DuelEconomy.reasonFor(a, b)
	local stake = if reason then 0 else session.prize

	local ok, moved = DuelBus.runDuel(a, b, stake)

	for _, plr in ipairs(session.players) do
		plr:SetAttribute(Duel.PlayerAttr, nil)
		refreshPrompt(plr)
	end

	if not ok then return false end

	if moved > 0 then DuelEconomy.notePaid(a, b) end
	return true
end

local function start(a: Player, b: Player, modeId: string, prize: number, reason: string?)
	nextId += 1
	local id = nextId

	local session: Session = {
		id = id,
		mode = modeId,
		slot = nil,
		arena = nil,
		players = { a, b },
		sideOf = { [a] = 1, [b] = 2 },
		prize = prize,
		reason = reason,
		saved = {},
		score = { [a] = 0, [b] = 0 },
		covered = { [a] = {}, [b] = {} },
		claimedBy = {},
		claimArea = { [a] = 0, [b] = 0 },
		startedAt = 0,
		endsAt = 0,
		winner = nil,
		quit = nil,
		over = false,
		paidTo = nil,
		paidAmount = 0,
	}

	sessions[id] = session
	duelOf[a] = session
	duelOf[b] = session
	refreshPrompt(a)
	refreshPrompt(b)

	local ok, err = pcall(function()
		if modeId == "Battle" then
			if not runBattleMode(session) then
				say(a, "The arena could not take the duel")
				say(b, "The arena could not take the duel")
			end
			return
		end

		local slot = freeSlot()
		if not slot then
			say(a, "Too many duels running -- try again in a minute")
			say(b, "Too many duels running -- try again in a minute")
			return
		end
		slotBusy[slot] = true
		session.slot = slot
		session.arena = if modeId == "SpeedRun"
			then DuelArena.buildSpeedRun(slot, id, a, b)
			else DuelArena.buildTurfWar(slot, id)

		runSealingMode(session)
	end)

	if not ok then
		warn("[Duel] a duel errored and is being unwound: " .. tostring(err))
	end

	clear(session)

	local who, amount = session.paidTo, session.paidAmount
	if who and who.Parent and amount > 0 then
		local shown, why = DoubleUpService.offer(who, amount, "duel")
		if not shown then
			print(("[Duel] no double-up card for %s (won %d): %s")
				:format(who.Name, amount, tostring(why)))
		end
	elseif session.winner or session.quit then
		print(("[Duel] no double-up card: the duel paid nothing (%s)")
			:format(tostring(session.reason or DuelEconomy.reasonFor(
				session.players[1], session.players[2]) or "no winner")))
	end
end

--==[ ACCEPT / DECLINE ]======================================================

OfferReply.OnServerEvent:Connect(function(plr, accept)
	if type(accept) ~= "boolean" then return end
	local pending = offers[plr]
	if not pending then return end
	offers[plr] = nil

	local from = pending.from
	-- Lapsed under them. Not a warning: a player can press Accept on the same frame
	-- the offer expires and that is not their fault.
	if os.clock() - pending.at > Duel.OfferSeconds + 1 then
		say(plr, "That challenge has expired")
		return
	end

	if not accept then
		if from.Parent then
			say(from, ("%s declined"):format(plr.DisplayName))
		end
		return
	end

	for _, side in ipairs({ { from, plr }, { plr, from } }) do
		local bad = busyReason(side[1])
		if bad then
			say(side[2], bad)
			say(side[1], (bad:gsub("^They", "You")))
			return
		end
	end

	if pending.mode == "Battle" and not DuelBus.arenaFree() then
		say(plr, "The arena is busy -- try Speed Run or Turf War")
		say(from, "The arena is busy -- try Speed Run or Turf War")
		return
	end

	task.spawn(start, from, plr, pending.mode, pending.prize, pending.reason)
end)

--==[ ZONE DUELS -- the PvP lobby pads ]=====================================

local ZoneTick = 0.25
local ZoneDwell = 5
local ZoneReDuelCooldown = 30

local ZoneFolders: { [string]: string } = {
	SpeedRun = "SpeedRun", Battle = "Battle", TurfWar = "TurfWar",
}

local zones: { { mode: string, part: BasePart } } = {}
local zoneLabels: { [string]: { label: TextLabel, shown: number } } = {}
local zoneFreeAt: { [Player]: number } = {}
local pendingZone: { [string]: { a: Player, b: Player, at: number } } = {}

local function padOf(zoneModel: Model): BasePart?
	local named = zoneModel:FindFirstChild(zoneModel.Name, true)
	if named and named:IsA("BasePart") then return named end
	for _, d in ipairs(zoneModel:GetDescendants()) do
		if d:IsA("BasePart") and string.match(d.Name, "^Zone") then return d end
	end
	return nil
end

local function buildZones(): number
	table.clear(zones)
	table.clear(zoneLabels)
	local lobby = workspace:FindFirstChild("PvPLobby")
	if not lobby then return 0 end
	for folderName, modeId in pairs(ZoneFolders) do
		local folder = lobby:FindFirstChild(folderName)
		if folder then
			local labelPart = folder:FindFirstChild("BayLabel")
			local gui = labelPart and labelPart:FindFirstChild("PlayerCountGui")
			local label = gui and gui:FindFirstChild("PlayerCountText")
			if label and label:IsA("TextLabel") then
				zoneLabels[modeId] = { label = label, shown = -1 }
			end

			for _, zoneModel in ipairs(folder:GetChildren()) do
				if zoneModel:IsA("Model") then
					local pad = padOf(zoneModel)
					if pad then
						table.insert(zones, { mode = modeId, part = pad })
					end
				end
			end
		end
	end
	return #zones
end

local function insidePad(part: BasePart, pos: Vector3): boolean
	local rel = part.CFrame:PointToObjectSpace(pos)
	local half = part.Size / 2
	return math.abs(rel.X) <= half.X + 1
		and math.abs(rel.Y) <= half.Y + 2
		and math.abs(rel.Z) <= half.Z + 1
end

task.spawn(function()
	local lobby = workspace:WaitForChild("PvPLobby", 10)
	if not lobby or buildZones() == 0 then
		warn("[Duel] no PvP lobby zone pads found -- zone duels are off")
		return
	end
	print(("[Duel] zone duels ready -- %d pads"):format(#zones))

	while true do
		task.wait(ZoneTick)

		-- Who is standing in which mode's pads this sweep. Counted whether or not
		-- duelling is on, because the bay signs are a lobby fixture, not a duel one.
		local standing: { [string]: { Player } } = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			local _, hum, hrp = characterOf(plr)
			if hum and hrp and hum.Health > 0 then
				for _, z in ipairs(zones) do
					if insidePad(z.part, hrp.Position) then
						local list = standing[z.mode]
						if not list then list = {} standing[z.mode] = list end
						table.insert(list, plr)
						break
					end
				end
			end
		end

		-- The bay signs. Both Zone1 and Zone2 of a mode show the same figure -- how
		-- many of the two pads are taken -- and it is only written when it moves, so
		-- an idle lobby costs nothing extra.
		for modeId, entry in pairs(zoneLabels) do
			local n = #(standing[modeId] or {})
			if n ~= entry.shown then
				entry.shown = n
				entry.label.Text = ("%d/2"):format(math.min(n, 2))
			end
		end

		if Duel.Enabled then
			local now = os.clock()
			for modeId, list in pairs(standing) do
				local free = {}
				for _, plr in ipairs(list) do
					if not busyReason(plr) and (zoneFreeAt[plr] or 0) <= now then
						table.insert(free, plr)
					end
				end

				local pending = pendingZone[modeId]
				if pending then
					if not table.find(free, pending.a) or not table.find(free, pending.b) then
						pendingZone[modeId] = nil
					elseif now - pending.at >= ZoneDwell then
						pendingZone[modeId] = nil
						local a, b = pending.a, pending.b
						if modeId == "Battle" and not DuelBus.arenaFree() then
							say(a, "The arena is busy -- try Speed Run or Turf War")
							say(b, "The arena is busy -- try Speed Run or Turf War")
						else
							local prize, reason = quoteFor(a, b)
							zoneFreeAt[a] = now + ZoneReDuelCooldown
							zoneFreeAt[b] = now + ZoneReDuelCooldown
							say(a, ("%s against %s -- good luck")
								:format(Duel.nameOf(modeId), b.DisplayName), true)
							say(b, ("%s against %s -- good luck")
								:format(Duel.nameOf(modeId), a.DisplayName), true)
							task.spawn(start, a, b, modeId, prize, reason)
						end
					end
				elseif #free >= 2 then
					pendingZone[modeId] = { a = free[1], b = free[2], at = now }
					local headsUp = ("Stay in the zone -- %s starts in %ds")
						:format(Duel.nameOf(modeId), ZoneDwell)
					say(free[1], headsUp, true)
					say(free[2], headsUp, true)
				end
			end

			for modeId in pairs(pendingZone) do
				if not standing[modeId] then pendingZone[modeId] = nil end
			end
		else
			table.clear(pendingZone)
		end
	end
end)

--==[ PLAYER LIFECYCLE ]======================================================

local function watch(plr: Player)
	local function bind(char: Model)
		-- Rebuilt on every character, because the prompt lives on the root and the
		-- root is replaced on every respawn.
		task.spawn(buildPrompt, plr, char)

		local session = duelOf[plr]
		if not session or session.over or not session.arena then return end
		task.spawn(function()
			char:WaitForChild("HumanoidRootPart", 5)
			if duelOf[plr] == session and not session.over then
				place(session, plr)
			end
		end)
	end

	if plr.Character then bind(plr.Character) end
	plr.CharacterAdded:Connect(bind)

	-- The prompt has to go dead the moment its owner is unavailable for any of the
	-- four reasons, and three of them are attributes somebody else writes.
	for _, attr in ipairs({ "BattleArena", "DrivewayRace", "TutorialDone" }) do
		plr:GetAttributeChangedSignal(attr):Connect(function() refreshPrompt(plr) end)
	end
end

Players.PlayerAdded:Connect(watch)
for _, plr in ipairs(Players:GetPlayers()) do watch(plr) end

Players.PlayerRemoving:Connect(function(plr)
	lastChallenge[plr] = nil
	freeAt[plr] = nil
	offers[plr] = nil
	zoneFreeAt[plr] = nil

	-- Any offer THIS player sent to somebody else dies with them, or the target is
	-- left holding a card from a ghost.
	for target, pending in pairs(offers) do
		if pending.from == plr then offers[target] = nil end
	end

	local session = duelOf[plr]
	if not session then return end
	duelOf[plr] = nil

	if not session.quit then session.quit = plr end
	session.over = true
end)

--==[ STARTUP ]===============================================================

if not Duel.Enabled then
	print("[Duel] duelling is OFF (DuelConfig.Enabled = false)."
		.. " The remotes are up; no prompt will be built.")
else
	print(("[Duel] ready -- %d modes, up to %d at once, arenas from %s")
		:format(#Duel.Modes, Duel.MaxConcurrent, tostring(Duel.Origin)))
end
