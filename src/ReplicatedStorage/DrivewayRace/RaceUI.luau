--!strict
--[[
	RaceUI -- the invitation, the race top bar and the results screen.

	Built with UIKit so the event looks like the rest of the game rather than like a
	bolt-on: same keyline, same two-hue ramp, same drop shadow, same Display face on
	every number. Nothing here draws a rectangle by hand.

	ONE OBJECT, THREE SCREENS, AND THEY NEVER OVERLAP

	The prompt, the HUD and the results are separate roots under one ScreenGui, and
	every one of them is shown and hidden through `reveal` below -- a scale tween
	from nothing with a Back ease in and a short Quad out. Same motion the panels in
	Shell use, so a race prompt opens the way a shop panel opens.

	The prompt DISMISSES ITSELF. It carries its own deadline and closes on it
	whether or not the server's close message arrives, because the one thing a 30
	second window must never do is stay on screen after it has shut.

	THERE IS NO COUNTDOWN BADGE IN HERE, and that is the deliberate omission.

	BattleUI owns the NEXT EVENT ticker. It was built there when the battle was the
	only timed event in the game, and it now counts down to whichever of the three
	the scheduler picked and says so in neutral words -- it is driven through
	EventBus, not by the battle. A second badge here would be a second clock for one
	schedule, which is the exact bug the single scheduler was written to delete.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(SealerUI:WaitForChild("UIKit"))
-- Who owns the top-centre strip. Six other widgets stand in it and know nothing
-- about each other -- see the header there.
local TopBand = require(SealerUI:WaitForChild("TopBand"))
-- Upgrades.short is the game's own money formatter (1.4M, not 1400000). Reused
-- so the results screen abbreviates cash exactly the way every shop row and
-- leaderboard in the game already does.
local Upgrades = require(SealerUI:WaitForChild("Upgrades"))

local Race = require(script.Parent.RaceConfig)

local T = UIKit.Theme

local RaceUI = {}
RaceUI.__index = RaceUI

local IN  = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OUT = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function reveal(root: GuiObject, scale: UIScale, on: boolean, done: (() -> ())?)
	if on then
		scale.Scale = 0.001
		root.Visible = true
		TweenService:Create(scale, IN, { Scale = 1 }):Play()
		if done then task.delay(0.34, done) end
	else
		if not root.Visible then
			if done then done() end
			return
		end
		local t = TweenService:Create(scale, OUT, { Scale = 0.001 })
		t.Completed:Once(function()
			root.Visible = false
			if done then done() end
		end)
		t:Play()
	end
end

local function scaled(root: GuiObject): UIScale
	local s = Instance.new("UIScale")
	s.Scale = 0.001
	s.Parent = root
	return s
end

local function clock(seconds: number): string
	seconds = math.max(0, seconds)
	return ("%d:%02d"):format(seconds // 60, math.floor(seconds % 60))
end

local function stamp(seconds: number): string
	seconds = math.max(0, seconds)
	return ("%d:%04.1f"):format(seconds // 60, seconds % 60)
end

--==[ CONSTRUCTION ]==========================================================

function RaceUI.new(player: Player)
	local gui = Instance.new("ScreenGui")
	gui.Name = "DrivewayRaceUI"
	-- The race outlives a death, and so must its HUD: a top bar that rebuilt itself
	-- on respawn would lose the clock and the standings with it.
	gui.ResetOnSpawn = false
	-- The same 50 BattleUI uses, and for its reason: while the race bar is up it is
	-- the most important thing on the screen, and Shell's rail sits at the default
	-- order. The two bars can never be up together -- one schedule runs both events.
	gui.DisplayOrder = 50
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local self = setmetatable({
		player = player,
		gui = gui,
		rows = {},          -- [slot] = the built row, reused between updates
		names = {} :: { [number]: string },
		promptDeadline = nil :: number?,
		promptClosing = false,
		-- this player pressed JOIN; see AcceptPrompt and HidePrompt
		promptJoined = false,
		countDeadline = nil :: number?,
		resultDeadline = nil :: number?,
		onJoin = nil :: (() -> ())?,
		onDecline = nil :: (() -> ())?,
		_tick = nil :: RBXScriptConnection?,
	}, RaceUI)

	self:_buildPrompt()
	self:_buildHud()
	self:_buildResults()
	self._tick = RunService.Heartbeat:Connect(function()
		self:_tickCountdowns()
	end)

	return self
end

--==[ THE INVITATION ]========================================================

function RaceUI:_buildPrompt()
	local holder = Instance.new("Frame")
	holder.Name = "Prompt"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.42)
	holder.Size = UDim2.fromOffset(430, 278)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.promptRoot = holder
	self.promptScale = scaled(holder)

	local _, content = UIKit.panel(holder, UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5),
		"Driveway Race", T.gold)

	local head = UIKit.label(content, "Driveway Race starting! Join?", 22, T.cream)
	head.Font = UIKit.Display
	head.Position = UDim2.fromOffset(0, 6)
	head.Size = UDim2.new(1, 0, 0, 30)
	head.TextXAlignment = Enum.TextXAlignment.Center
	head.ZIndex = 7

	local blurb = UIKit.label(content,
		"Your own driveway, your own kit, and a pail that never runs dry.\n"
		.. "<font color='#9fd7ff'>Bigger squeegee, bigger driveway.</font> First to finish wins.",
		15, T.blueLight)
	blurb.Position = UDim2.fromOffset(0, 36)
	blurb.Size = UDim2.new(1, 0, 0, 40)
	blurb.TextXAlignment = Enum.TextXAlignment.Center
	blurb.ZIndex = 7

	local timer = UIKit.outlined(content, "0:30", 42, T.gold, 3.4)
	timer.Position = UDim2.fromOffset(0, 82)
	timer.Size = UDim2.new(1, 0, 0, 48)
	timer.TextXAlignment = Enum.TextXAlignment.Center
	timer.ZIndex = 7
	self.promptTimer = timer

	local queueLabel = UIKit.label(content, "", 17, T.white)
	queueLabel.Position = UDim2.fromOffset(0, 132)
	queueLabel.Size = UDim2.new(1, 0, 0, 22)
	queueLabel.TextXAlignment = Enum.TextXAlignment.Center
	queueLabel.ZIndex = 7
	self.promptQueue = queueLabel

	local joinHolder, joinCap = UIKit.button(content, "JOIN",
		UDim2.fromOffset(160, 52), T.green, function()
			if self.onJoin then self.onJoin() end
		end)
	joinHolder.Position = UDim2.new(0.5, -168, 0, 166)
	self.promptJoin = joinCap

	local declineHolder = UIKit.button(content, "DECLINE",
		UDim2.fromOffset(160, 52), T.red, function()
			if self.onDecline then self.onDecline() end
		end)
	declineHolder.Position = UDim2.new(0.5, 8, 0, 166)
end

function RaceUI:ShowPrompt(seconds: number, onJoin: () -> (), onDecline: () -> ())
	self.onJoin, self.onDecline = onJoin, onDecline
	self.promptDeadline = os.clock() + seconds
	self.promptClosing = false
	self.promptJoined = false
	self.promptJoin.Text = "JOIN"
	self.promptQueue.Text = ("0 / %d racers in  <font color='#9fd7ff'>(%d needed)</font>")
		:format(Race.MaxPlayers, Race.MinPlayers)
	self.promptTimer.Text = clock(seconds)
	reveal(self.promptRoot, self.promptScale, true)
end

function RaceUI:SetQueue(info: { [string]: any })
	self.promptQueue.Text = ("%d / %d racers in  <font color='#9fd7ff'>(%d needed)</font>")
		:format(info.count or 0, info.max or Race.MaxPlayers, info.min or Race.MinPlayers)
	if info.you then
		self.promptJoin.Text = "YOU'RE IN"
	elseif info.full then
		self.promptJoin.Text = "FULL"
	elseif info.dead then
		self.promptJoin.Text = "RESPAWN FIRST"
	end
end

function RaceUI:AcceptPrompt()
	self.promptJoined = true
	self.promptDeadline = nil
	reveal(self.promptRoot, self.promptScale, false)
end

function RaceUI:HidePrompt(reason: string?)
	self.promptDeadline = nil
	if self.promptClosing then return end
	if reason and self.promptJoined and not self.promptRoot.Visible then
		self.promptClosing = true
		self.promptJoined = false
		self.promptTimer.Text = ""
		self.promptQueue.Text = reason
		self.promptJoin.Text = "JOINED"
		reveal(self.promptRoot, self.promptScale, true)
		task.delay(1.9, function()
			reveal(self.promptRoot, self.promptScale, false, function()
				self.promptClosing = false
			end)
		end)
		return
	end
	if reason and self.promptRoot.Visible then
		-- Say why before it goes. A prompt that simply vanishes reads as a bug; one
		-- that says "not enough racers" reads as the game working.
		self.promptClosing = true
		self.promptTimer.Text = ""
		self.promptQueue.Text = reason
		task.delay(1.6, function()
			reveal(self.promptRoot, self.promptScale, false, function()
				self.promptClosing = false
			end)
		end)
		return
	end
	reveal(self.promptRoot, self.promptScale, false)
end

--==[ THE RACE TOP BAR ]======================================================

function RaceUI:_buildHud()
	local holder = Instance.new("Frame")
	holder.Name = "RaceHud"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, 10)
	holder.Size = UDim2.fromOffset(380, 340)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.hudRoot = holder
	self.hudScale = scaled(holder)

	TopBand.claim("RaceHud", TopBand.Rank.MatchHud, holder, 330)

	-- The clock is its own pill above the board, not a row in it: it is the one
	-- number every racer looks at more than once a second.
	local clockHolder, clockBody = UIKit.shadowed(holder, UDim2.fromOffset(210, 54),
		UDim2.new(0.5, 0, 0, 0), Vector2.new(0.5, 0), 16, 6)
	clockBody.BackgroundColor3 = T.navy
	UIKit.stroke(clockBody, 2.8)
	UIKit.gradient(clockBody, 0.9)
	UIKit.gloss(clockBody, 6, 12, 0.28)
	clockHolder.ZIndex = 12

	local clockLabel = UIKit.outlined(clockBody, "0:00", 34, T.gold, 3.0)
	clockLabel.Size = UDim2.fromScale(1, 1)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Center
	clockLabel.ZIndex = 14
	self.hudClock = clockLabel

	local track = Instance.new("Frame")
	track.Name = "ClockTrack"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -5)
	track.Size = UDim2.new(1, -18, 0, 7)
	track.BackgroundColor3 = Color3.fromRGB(18, 40, 78)
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.ZIndex = 15
	track.Parent = clockBody
	UIKit.corner(track, 4)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = T.gold
	fill.BorderSizePixel = 0
	fill.ZIndex = 16
	fill.Parent = track
	UIKit.corner(fill, 4)
	self.hudClockFill = fill

	local boardHolder, board = UIKit.shadowed(holder, UDim2.fromOffset(380, 46),
		UDim2.new(0.5, 0, 0, 62), Vector2.new(0.5, 0), 16, 7)
	board.BackgroundColor3 = T.panelDeep
	UIKit.stroke(board, 2.6)
	UIKit.gradient(board, 0.75)
	boardHolder.ZIndex = 10
	boardHolder.AutomaticSize = Enum.AutomaticSize.Y
	board.AutomaticSize = Enum.AutomaticSize.Y
	self.hudBoard = board

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = board

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 5)
	list.Parent = board

	local count = Instance.new("Frame")
	count.Name = "CountIn"
	count.AnchorPoint = Vector2.new(0.5, 0.5)
	count.Position = UDim2.fromScale(0.5, 0.44)
	count.Size = UDim2.fromOffset(460, 120)
	count.BackgroundTransparency = 1
	count.Visible = false
	count.Parent = self.gui
	self.countRoot = count
	self.countScale = scaled(count)

	local countLabel = UIKit.outlined(count, "READY", 76, T.gold, 6)
	countLabel.Size = UDim2.fromScale(1, 1)
	countLabel.TextXAlignment = Enum.TextXAlignment.Center
	self.countLabel = countLabel

	local flash = Instance.new("Frame")
	flash.Name = "Finish"
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.Position = UDim2.fromScale(0.5, 0.38)
	flash.Size = UDim2.fromOffset(520, 150)
	flash.BackgroundTransparency = 1
	flash.Visible = false
	flash.Parent = self.gui
	self.flashRoot = flash
	self.flashScale = scaled(flash)

	local flashPlace = UIKit.outlined(flash, "", 74, T.gold, 6)
	flashPlace.Size = UDim2.new(1, 0, 0, 92)
	flashPlace.TextXAlignment = Enum.TextXAlignment.Center
	self.flashPlace = flashPlace

	local flashTime = UIKit.outlined(flash, "", 30, T.cream, 3.0)
	flashTime.Position = UDim2.fromOffset(0, 94)
	flashTime.Size = UDim2.new(1, 0, 0, 40)
	flashTime.TextXAlignment = Enum.TextXAlignment.Center
	self.flashTime = flashTime
end

function RaceUI:_row(slot: number)
	local existing = self.rows[slot]
	if existing then return existing end

	local row = Instance.new("Frame")
	row.Name = "Slot" .. slot
	row.Size = UDim2.new(1, 0, 0, 30)
	row.BackgroundColor3 = Color3.fromRGB(24, 58, 110)
	row.BorderSizePixel = 0
	row.ZIndex = 12
	row.Parent = self.hudBoard
	UIKit.corner(row, 8)

	-- the progress, drawn behind the text as a filling bar in the racer's colour
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BackgroundColor3 = Race.colorOf(slot)
	bar.BackgroundTransparency = 0.42
	bar.BorderSizePixel = 0
	bar.ZIndex = 13
	bar.Parent = row
	UIKit.corner(bar, 8)

	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AnchorPoint = Vector2.new(0, 0.5)
	chip.Position = UDim2.new(0, 6, 0.5, 0)
	chip.Size = UDim2.fromOffset(16, 16)
	chip.BackgroundColor3 = Race.colorOf(slot)
	chip.BorderSizePixel = 0
	chip.ZIndex = 15
	chip.Parent = row
	UIKit.corner(chip, 5)
	UIKit.stroke(chip, 2)

	local place = UIKit.outlined(row, "", 16, T.cream, 2.2)
	place.Position = UDim2.fromOffset(28, 0)
	place.Size = UDim2.fromOffset(24, 30)
	place.ZIndex = 15

	local name = UIKit.label(row, "", 16, T.white)
	name.Position = UDim2.fromOffset(54, 0)
	name.Size = UDim2.new(1, -150, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.ZIndex = 15

	local pct = UIKit.outlined(row, "0%", 17, T.cream, 2.4)
	pct.AnchorPoint = Vector2.new(1, 0)
	pct.Position = UDim2.new(1, -8, 0, 0)
	pct.Size = UDim2.fromOffset(88, 30)
	pct.TextXAlignment = Enum.TextXAlignment.Right
	pct.ZIndex = 15

	local built = { row = row, bar = bar, place = place, name = name, pct = pct }
	self.rows[slot] = built
	return built
end

function RaceUI:ShowHud(roster: { any })
	-- The invitation is settled the moment the race exists, so there is nothing
	-- left for a cancellation to tell this player about.
	self.promptJoined = false
	self.names = {}
	for _, e in ipairs(roster) do
		self.names[e.slot] = e.name
	end
	-- Anything left from a previous race whose slot is not in this one.
	for slot, built in pairs(self.rows) do
		built.row.Visible = self.names[slot] ~= nil
	end
	reveal(self.hudRoot, self.hudScale, true)
end

function RaceUI:HideHud()
	reveal(self.hudRoot, self.hudScale, false)
	reveal(self.flashRoot, self.flashScale, false)
end

function RaceUI:SetClock(elapsed: number, closing: number?)
	if closing then
		self.hudClock.Text = clock(closing)
		local frac = math.clamp(closing / math.max(1, Race.FinishGrace), 0, 1)
		self.hudClockFill.Size = UDim2.fromScale(frac, 1)
		local hot = closing <= 10
		self.hudClockFill.BackgroundColor3 = if hot then T.red else T.gold
		self.hudClock.TextColor3 = if hot then T.red else T.gold
		return
	end
	self.hudClock.Text = stamp(elapsed)
	self.hudClock.TextColor3 = T.gold
	-- Against the hard cap, which is the only span there is while nobody has
	-- finished. It fills rather than drains: nothing is running out yet.
	self.hudClockFill.BackgroundColor3 = T.gold
	self.hudClockFill.Size = UDim2.fromScale(
		math.clamp(elapsed / math.max(1, Race.MatchSeconds), 0, 1), 1)
end

function RaceUI:SetStandings(rows: { any })
	for rank, r in ipairs(rows) do
		local built = self:_row(r.slot)
		built.row.Visible = true
		built.row.LayoutOrder = rank
		built.place.Text = tostring(rank)
		built.name.Text = r.name or self.names[r.slot] or Race.slotNameOf(r.slot)
		if r.finishedAt then
			built.pct.Text = stamp(r.finishedAt)
			built.pct.TextColor3 = T.gold
			built.bar.Size = UDim2.fromScale(1, 1)
		else
			built.pct.Text = ("%.0f%%"):format((r.progress or 0) * 100)
			built.pct.TextColor3 = T.cream
			built.bar.Size = UDim2.fromScale(math.clamp(r.progress or 0, 0, 1), 1)
		end
		-- Your own row, picked out. Eight names go past quickly at a glance.
		local mine = r.userId == self.player.UserId
		built.row.BackgroundColor3 = if mine
			then Color3.fromRGB(46, 96, 160) else Color3.fromRGB(24, 58, 110)
	end
	-- Slots that dropped out of the standings entirely (a racer who left).
	local seen = {}
	for _, r in ipairs(rows) do seen[r.slot] = true end
	for slot, built in pairs(self.rows) do
		if not seen[slot] then built.row.Visible = false end
	end
end

function RaceUI:CountIn(seconds: number)
	self.countDeadline = os.clock() + seconds
	self.countLabel.Text = "READY"
	reveal(self.countRoot, self.countScale, true)
end

function RaceUI:Finished(place: number, at: number)
	local names = { "1ST!", "2ND!", "3RD!" }
	self.flashPlace.Text = names[place] or ("#" .. place)
	self.flashPlace.TextColor3 = if place == 1 then T.gold else T.cream
	self.flashTime.Text = "DRIVEWAY SEALED IN " .. stamp(at)
	reveal(self.flashRoot, self.flashScale, true)
	task.delay(3.4, function()
		reveal(self.flashRoot, self.flashScale, false)
	end)
end

--==[ RESULTS ]===============================================================

function RaceUI:_buildResults()
	local holder = Instance.new("Frame")
	holder.Name = "Results"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(520, 430)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.resultRoot = holder
	self.resultScale = scaled(holder)

	local _, content = UIKit.panel(holder, UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5),
		"Race Results", T.gold)

	local head = UIKit.outlined(content, "", 30, T.gold, 3.2)
	head.Position = UDim2.fromOffset(0, 2)
	head.Size = UDim2.new(1, 0, 0, 38)
	head.TextXAlignment = Enum.TextXAlignment.Center
	head.ZIndex = 8
	self.resultHead = head

	local sub = UIKit.label(content, "", 16, T.blueLight)
	sub.Position = UDim2.fromOffset(0, 40)
	sub.Size = UDim2.new(1, 0, 0, 20)
	sub.TextXAlignment = Enum.TextXAlignment.Center
	sub.ZIndex = 8
	self.resultSub = sub

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(14, 66)
	list.Size = UDim2.new(1, -28, 1, -76)
	list.ZIndex = 8
	list.Parent = content
	self.resultList = list

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list
end

function RaceUI:ShowResults(payload: { [string]: any })
	for _, c in ipairs(self.resultList:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end

	local you = payload.you
	if you then
		self.resultHead.Text = if you.finishedAt
			then ("#%d  -  %s"):format(you.rank, stamp(you.finishedAt))
			else ("#%d  -  %.0f%% done"):format(you.rank, (you.progress or 0) * 100)
		self.resultHead.TextColor3 = Race.colorOf(you.slot)
		self.resultSub.Text = ("You earned <b>$%s</b>  -  purse x%s at an average level of %d")
			:format(Upgrades.short(you.coins), Upgrades.short(payload.multiplier or 1),
				math.floor(payload.averageLevel or 0))
	else
		self.resultHead.Text = "DID NOT FINISH"
		self.resultHead.TextColor3 = T.slate
		self.resultSub.Text = ("You left the yard before the flag  -  <b>$%s</b> for turning up")
			:format(Upgrades.short(payload.showUp or 0))
	end

	for _, r in ipairs(payload.rows or {}) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 34)
		row.LayoutOrder = r.rank
		row.BackgroundColor3 = if r.userId == self.player.UserId
			then Color3.fromRGB(46, 96, 160) else Color3.fromRGB(24, 58, 110)
		row.BorderSizePixel = 0
		row.ZIndex = 9
		row.Parent = self.resultList
		UIKit.corner(row, 8)

		local chip = Instance.new("Frame")
		chip.AnchorPoint = Vector2.new(0, 0.5)
		chip.Position = UDim2.new(0, 8, 0.5, 0)
		chip.Size = UDim2.fromOffset(18, 18)
		chip.BackgroundColor3 = Race.colorOf(r.slot)
		chip.BorderSizePixel = 0
		chip.ZIndex = 10
		chip.Parent = row
		UIKit.corner(chip, 6)
		UIKit.stroke(chip, 2)

		local place = UIKit.outlined(row, "#" .. r.rank, 17, T.cream, 2.4)
		place.Position = UDim2.fromOffset(34, 0)
		place.Size = UDim2.fromOffset(40, 34)
		place.ZIndex = 10

		local name = UIKit.label(row, r.name, 16, T.white)
		name.Position = UDim2.fromOffset(78, 0)
		name.Size = UDim2.new(1, -270, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 10

		local detail = if r.finishedAt then stamp(r.finishedAt)
			else ("%.0f%%"):format((r.progress or 0) * 100)
		local got = UIKit.outlined(row, detail, 16, T.blueLight, 2.2)
		got.AnchorPoint = Vector2.new(1, 0)
		got.Position = UDim2.new(1, -104, 0, 0)
		got.Size = UDim2.fromOffset(90, 34)
		got.TextXAlignment = Enum.TextXAlignment.Right
		got.ZIndex = 10

		local coins = UIKit.outlined(row, "$" .. Upgrades.short(r.coins), 17, T.gold, 2.4)
		coins.AnchorPoint = Vector2.new(1, 0)
		coins.Position = UDim2.new(1, -8, 0, 0)
		coins.Size = UDim2.fromOffset(96, 34)
		coins.TextXAlignment = Enum.TextXAlignment.Right
		coins.ZIndex = 10
	end

	self.resultDeadline = os.clock() + (payload.seconds or Race.ResultSeconds)
	reveal(self.resultRoot, self.resultScale, true)
end

function RaceUI:HideResults()
	self.resultDeadline = nil
	reveal(self.resultRoot, self.resultScale, false)
end

--==[ COUNTDOWNS ]============================================================

function RaceUI:_tickCountdowns()
	local now = os.clock()

	local pd = self.promptDeadline
	if pd then
		local left = pd - now
		if left <= 0 then
			self.promptDeadline = nil
			reveal(self.promptRoot, self.promptScale, false)
		else
			self.promptTimer.Text = clock(left)
			self.promptTimer.TextColor3 = if left <= 5 then T.red else T.gold
		end
	end

	local cd = self.countDeadline
	if cd then
		local left = cd - now
		if left <= 0 then
			self.countDeadline = nil
			self.countLabel.Text = "SEAL!"
			self.countLabel.TextColor3 = T.green
			task.delay(0.7, function()
				if not self.countDeadline then
					reveal(self.countRoot, self.countScale, false)
				end
			end)
		else
			-- READY / SET / GO out of however many seconds the count actually is,
			-- rather than three hardcoded words that only work at CountIn == 3.
			local step = math.ceil(left)
			self.countLabel.Text = if step <= 1 then "SET" elseif step <= 2 then "READY"
				else tostring(step)
			self.countLabel.TextColor3 = T.gold
		end
	end

	local rd = self.resultDeadline
	if rd and now >= rd then
		self.resultDeadline = nil
		reveal(self.resultRoot, self.resultScale, false)
	end
end

function RaceUI:Destroy()
	if self._tick then self._tick:Disconnect() end
	self.gui:Destroy()
end

return RaceUI
