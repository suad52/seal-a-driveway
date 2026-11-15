--!strict
--[[
	BattleUI -- the invitation, the match top bar and the results screen.

	Built with UIKit so the event looks like the rest of the game rather than
	like a bolt-on: same keyline, same two-hue ramp, same drop shadow, same
	Display face on every number. Nothing here draws a rectangle by hand.

	ONE OBJECT, THREE SCREENS, AND THEY NEVER OVERLAP

	The prompt, the HUD and the results are separate roots under one ScreenGui,
	and every one of them is shown and hidden through `reveal` below -- a scale
	tween from nothing with a Back ease on the way in and a short Quad on the way
	out. That is the only motion in here, and it is the same motion the panels in
	Shell use, so a battle prompt opens the way a shop panel opens.

	The prompt DISMISSES ITSELF. It carries its own deadline and closes on it
	whether or not the server's close message arrives, because the one thing a
	30 second window must never do is stay on screen after it has shut.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(SealerUI:WaitForChild("UIKit"))
-- Who owns the top-centre strip. Both of this file's bars stand in it, and so do
-- four other widgets that know nothing about each other -- see the header there.
local TopBand = require(SealerUI:WaitForChild("TopBand"))
-- only for the ticker's handset size; see the note over TICKER_TOUCH
local UserInputService = game:GetService("UserInputService")
-- Upgrades.short is the game's own money formatter (1.4M, not 1400000). Reused
-- rather than reimplemented so the results screen abbreviates cash exactly the
-- way every shop row and leaderboard in the game already does.
local Upgrades = require(SealerUI:WaitForChild("Upgrades"))

local Battle = require(script.Parent.BattleConfig)

local T = UIKit.Theme

local BattleUI = {}
BattleUI.__index = BattleUI

local IN  = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OUT = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local ROW_H       = 30   -- one player's row
local ROW_GAP     = 5    -- the UIListLayout padding between them
local BOARD_PAD   = 8    -- the UIPadding inside the board, top and bottom
local BOARD_TOP   = 62   -- where the board sits under the clock pill
local BOARD_SHADOW = 7   -- how far UIKit.shadowed drops its shadow

local function boardHeight(n: number): number
	n = math.max(1, n)
	return BOARD_PAD * 2 + n * ROW_H + (n - 1) * ROW_GAP
end

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

local function fitted(root: GuiObject, anchor: Vector2): Frame
	local f = Instance.new("Frame")
	f.Name = "Fit"
	f.BackgroundTransparency = 1
	f.AnchorPoint = anchor
	f.Position = UDim2.fromScale(anchor.X, anchor.Y)
	f.Size = UDim2.fromScale(1, 1)
	f.Parent = root
	local s = Instance.new("UIScale")
	s.Parent = f
	UIKit.onFit(function(n) s.Scale = n end)
	return f
end

local function clock(seconds: number): string
	seconds = math.max(0, seconds)
	return ("%d:%02d"):format(seconds // 60, math.floor(seconds % 60))
end

--==[ CONSTRUCTION ]==========================================================

function BattleUI.new(player: Player)
	local gui = Instance.new("ScreenGui")
	gui.Name = "SqueegeeBattleUI"
	-- The match outlives a death, and so must its HUD: a top bar that rebuilt
	-- itself on respawn would lose the clock and the standings with it.
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local self = setmetatable({
		player = player,
		gui = gui,
		rows = {},          -- [slot] = the built row, reused between updates
		promptDeadline = nil :: number?,
		promptClosing = false,
		-- this player pressed JOIN; see AcceptPrompt and HidePrompt
		promptJoined = false,
		-- the standing clock: absolute server time, how long the whole gap was,
		-- and the last whole second drawn (so the text is retouched once a second
		-- rather than sixty times)
		tickerNextAt = nil :: number?,
		tickerSpan = 1,
		tickerLastWhole = -1,
		-- whether the badge WANTS to be up, and whether the player has told it to
		-- go away; the two are combined in _applyTicker
		tickerShow = false,
		tickerMinimised = false,
		countDeadline = nil :: number?,
		resultDeadline = nil :: number?,
		names = {} :: { [number]: string },
		onJoin = nil :: (() -> ())?,
		onDecline = nil :: (() -> ())?,
		_tick = nil :: RBXScriptConnection?,
	}, BattleUI)

	self:_buildTicker()
	self:_buildPrompt()
	self:_buildHud()
	self:_buildResults()

	self._tick = RunService.Heartbeat:Connect(function()
		self:_tickCountdowns()
	end)

	return self
end

--==[ THE STANDING CLOCK ]====================================================

function BattleUI:_buildTicker()
	local holder = Instance.new("Frame")
	holder.Name = "Ticker"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, 12)

	holder.Size = UDim2.fromOffset(280, 70)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.tickerRoot = holder
	self.tickerScale = scaled(holder)

	local TICKER_TOUCH = 0.72
	local shrink = if UserInputService.TouchEnabled then TICKER_TOUCH else 1

	TopBand.claim("Ticker", TopBand.Rank.Ticker, holder,
		function(f) return 70 * f * shrink end)

	local fitHolder = fitted(holder, Vector2.new(0.5, 0))
	local handHolder = Instance.new("Frame")
	handHolder.Name = "Handset"
	handHolder.BackgroundTransparency = 1
	handHolder.AnchorPoint = Vector2.new(0.5, 0)
	handHolder.Position = UDim2.fromScale(0.5, 0)
	handHolder.Size = UDim2.fromScale(1, 1)
	handHolder.Parent = fitHolder
	local handScale = Instance.new("UIScale")
	handScale.Scale = shrink
	handScale.Parent = handHolder

	local pulseHolder = Instance.new("Frame")
	pulseHolder.Name = "Pulse"
	pulseHolder.BackgroundTransparency = 1
	pulseHolder.Size = UDim2.fromScale(1, 1)
	pulseHolder.Parent = handHolder
	self.tickerPulse = Instance.new("UIScale")
	self.tickerPulse.Parent = pulseHolder

	local _, card = UIKit.shadowed(pulseHolder, UDim2.fromScale(1, 1),
		UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5), 18, 6)
	card.BackgroundColor3 = T.navy
	UIKit.stroke(card, 3)
	UIKit.gradient(card, 0.85)
	UIKit.gloss(card, 7, 13, 0.30)
	-- so the drain lip along the bottom respects the card's rounded corners
	-- instead of poking square out of them
	card.ClipsDescendants = true
	self.tickerCard = card

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 9, 0.5, -4)
	badge.Size = UDim2.fromOffset(46, 46)
	badge.BackgroundColor3 = T.gold
	badge.BorderSizePixel = 0
	badge.ZIndex = 6
	badge.Parent = card
	UIKit.corner(badge, 23)
	UIKit.stroke(badge, 2.6)
	UIKit.gradient(badge, 1.1)
	self.tickerBadge = badge

	local glyph = UIKit.label(badge, "\u{2B50}", 24, T.white)
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.TextXAlignment = Enum.TextXAlignment.Center
	glyph.ZIndex = 7

	local title = UIKit.label(card, "NEXT EVENT", 12.5, T.blueLight)
	title.Font = UIKit.Display
	title.Position = UDim2.fromOffset(64, 8)
	title.Size = UDim2.new(1, -108, 0, 15)
	title.ZIndex = 6
	self.tickerTitle = title

	local time = UIKit.outlined(card, "--:--", 28, T.gold, 3.0)
	time.Position = UDim2.fromOffset(64, 23)
	time.Size = UDim2.new(1, -108, 0, 36)
	time.ZIndex = 6
	self.tickerTime = time

	local mini = Instance.new("TextButton")
	mini.Name = "Minimise"
	mini.AnchorPoint = Vector2.new(1, 0.5)
	-- the same -4 the badge takes: the drain lip owns the bottom 7px, so the
	-- space this centres in is 63 tall, not 70
	mini.Position = UDim2.new(1, -9, 0.5, -4)
	mini.Size = UDim2.fromOffset(26, 26)
	mini.BackgroundColor3 = T.red
	mini.AutoButtonColor = true
	mini.BorderSizePixel = 0
	mini.Text = "X"
	mini.TextColor3 = T.white
	mini.Font = UIKit.Display
	mini.TextSize = 22
	mini.ZIndex = 8
	mini.Parent = card
	UIKit.corner(mini, 13)
	UIKit.stroke(mini, 2)
	mini.Activated:Connect(function()
		self.tickerMinimised = not self.tickerMinimised
		self:_applyTicker()
	end)
	self.tickerMini = mini

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.new(1, 0, 0, 7)
	track.BackgroundColor3 = Color3.fromRGB(18, 40, 78)
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.ZIndex = 6
	track.Parent = card

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = T.gold
	fill.BorderSizePixel = 0
	fill.ZIndex = 7
	fill.Parent = track
	self.tickerFill = fill
end

function BattleUI:_applyTicker()
	local want = self.tickerShow == true
	if want and self.tickerMinimised then
		local at = self.tickerNextAt
		want = at ~= nil and (at - workspace:GetServerTimeNow()) <= Battle.TimerWarnAt
	end
	if self.tickerMini then
		local shut = self.tickerMinimised == true
		self.tickerMini.Text = if shut then "+" else "X"
		self.tickerMini.BackgroundColor3 = if shut
			then Color3.fromRGB(18, 40, 78)
			else T.red
	end
	if want == self.tickerRoot.Visible then return end
	-- or it comes back still showing the second it was dismissed on, for the
	-- fraction of a second before the next whole one lands
	if want then self.tickerLastWhole = -1 end
	reveal(self.tickerRoot, self.tickerScale, want)
end

function BattleUI:SetTicker(nextAt: number?, phase: string?)
	self.tickerShow = nextAt ~= nil
		and (phase == nil or phase == Battle.State.Idle)
	if not self.tickerShow then
		self.tickerNextAt = nil
		self:_applyTicker()
		return
	end

	if self.tickerNextAt ~= nextAt then
		self.tickerNextAt = nextAt
		self.tickerSpan = math.max(1, (nextAt :: number) - workspace:GetServerTimeNow())
	end
	self:_applyTicker()
end

--==[ THE INVITATION ]========================================================

function BattleUI:_buildPrompt()
	local holder = Instance.new("Frame")
	holder.Name = "Prompt"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.42)
	holder.Size = UDim2.fromOffset(430, 260)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.promptRoot = holder
	self.promptScale = scaled(holder)

	local _, content = UIKit.panel(fitted(holder, Vector2.new(0.5, 0.5)),
		UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), "Squeegee Battle", T.gold)

	local head = UIKit.label(content, "Squeegee Battle starting! Join?", 22, T.cream)
	head.Font = UIKit.Display
	head.Position = UDim2.fromOffset(0, 6)
	head.Size = UDim2.new(1, 0, 0, 30)
	head.TextXAlignment = Enum.TextXAlignment.Center
	head.ZIndex = 7

	local blurb = UIKit.label(content,
		("60 seconds. Paint more of the arena than anyone else."):format(), 16, T.blueLight)
	blurb.Position = UDim2.fromOffset(0, 38)
	blurb.Size = UDim2.new(1, 0, 0, 22)
	blurb.TextXAlignment = Enum.TextXAlignment.Center
	blurb.ZIndex = 7

	local timer = UIKit.outlined(content, "0:30", 42, T.gold, 3.4)
	timer.Position = UDim2.fromOffset(0, 64)
	timer.Size = UDim2.new(1, 0, 0, 48)
	timer.TextXAlignment = Enum.TextXAlignment.Center
	timer.ZIndex = 7
	self.promptTimer = timer

	local queueLabel = UIKit.label(content, "0 / 8 painters in", 17, T.white)
	queueLabel.Position = UDim2.fromOffset(0, 114)
	queueLabel.Size = UDim2.new(1, 0, 0, 22)
	queueLabel.TextXAlignment = Enum.TextXAlignment.Center
	queueLabel.ZIndex = 7
	self.promptQueue = queueLabel

	local joinHolder, joinCap = UIKit.button(content, "JOIN",
		UDim2.fromOffset(160, 52), T.green, function()
			if self.onJoin then self.onJoin() end
		end)
	joinHolder.Position = UDim2.new(0.5, -168, 0, 148)
	self.promptJoin = joinCap

	local declineHolder = UIKit.button(content, "DECLINE",
		UDim2.fromOffset(160, 52), T.red, function()
			if self.onDecline then self.onDecline() end
		end)
	declineHolder.Position = UDim2.new(0.5, 8, 0, 148)
end

function BattleUI:ShowPrompt(seconds: number, onJoin: () -> (), onDecline: () -> ())
	self.onJoin, self.onDecline = onJoin, onDecline
	self.promptDeadline = os.clock() + seconds
	self.promptClosing = false
	self.promptJoined = false
	self.promptJoin.Text = "JOIN"
	self.promptQueue.Text = ("0 / %d painters in  <font color='#9fd7ff'>(%d needed)</font>")
		:format(Battle.MaxPlayers, Battle.MinPlayers)
	self.promptTimer.Text = clock(seconds)
	reveal(self.promptRoot, self.promptScale, true)
end

function BattleUI:SetQueue(info: { [string]: any })
	self.promptQueue.Text = ("%d / %d painters in  <font color='#9fd7ff'>(%d needed)</font>")
		:format(info.count or 0, info.max or Battle.MaxPlayers, info.min or Battle.MinPlayers)
	if info.you then
		self.promptJoin.Text = "YOU'RE IN"
	elseif info.full then
		self.promptJoin.Text = "FULL"
	elseif info.dead then
		self.promptJoin.Text = "RESPAWN FIRST"
	end
end

function BattleUI:AcceptPrompt()
	self.promptJoined = true
	self.promptDeadline = nil
	reveal(self.promptRoot, self.promptScale, false)
end

function BattleUI:HidePrompt(reason: string?)
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
		-- Say why before it goes. A prompt that simply vanishes reads as a bug;
		-- one that says "not enough painters" reads as the game working.
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

--==[ THE MATCH TOP BAR ]=====================================================

function BattleUI:_buildHud()
	local holder = Instance.new("Frame")
	holder.Name = "MatchHud"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, 10)
	holder.Size = UDim2.fromOffset(360, 320)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.hudRoot = holder
	self.hudScale = scaled(holder)


	local fit = fitted(holder, Vector2.new(0.5, 0))

	TopBand.claim("MatchHud", TopBand.Rank.MatchHud, holder, function(f)
		return (BOARD_TOP + boardHeight(self.hudRowCount or 1) + BOARD_SHADOW) * f
	end)

	local clockHolder, clockBody = UIKit.shadowed(fit, UDim2.fromOffset(190, 54),
		UDim2.new(0.5, 0, 0, 0), Vector2.new(0.5, 0), 16, 6)
	clockBody.BackgroundColor3 = T.navy
	UIKit.stroke(clockBody, 2.8)
	UIKit.gradient(clockBody, 0.9)
	UIKit.gloss(clockBody, 6, 12, 0.28)
	clockHolder.ZIndex = 12

	local clockLabel = UIKit.outlined(clockBody, "1:00", 34, T.gold, 3.0)
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
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = T.gold
	fill.BorderSizePixel = 0
	fill.ZIndex = 16
	fill.Parent = track
	UIKit.corner(fill, 4)
	self.hudClockFill = fill

	local boardHolder, board = UIKit.shadowed(fit, UDim2.fromOffset(360, boardHeight(1)),
		UDim2.new(0.5, 0, 0, BOARD_TOP), Vector2.new(0.5, 0), 16, BOARD_SHADOW)
	board.BackgroundColor3 = T.panelDeep
	UIKit.stroke(board, 2.6)
	UIKit.gradient(board, 0.75)
	boardHolder.ZIndex = 10

	self.hudBoard = board
	self.hudBoardHolder = boardHolder

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, BOARD_PAD)
	pad.PaddingBottom = UDim.new(0, BOARD_PAD)
	pad.PaddingLeft = UDim.new(0, BOARD_PAD)
	pad.PaddingRight = UDim.new(0, BOARD_PAD)
	pad.Parent = board

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, ROW_GAP)
	list.Parent = board

	local count = Instance.new("Frame")
	count.Name = "CountIn"
	count.AnchorPoint = Vector2.new(0.5, 0.5)
	count.Position = UDim2.fromScale(0.5, 0.44)
	count.Size = UDim2.fromOffset(420, 120)
	count.BackgroundTransparency = 1
	count.Visible = false
	count.Parent = self.gui
	self.countRoot = count
	self.countScale = scaled(count)

	local countFit = fitted(count, Vector2.new(0.5, 0.5))

	local countLabel = UIKit.outlined(countFit, "READY", 76, T.gold, 6)
	countLabel.Size = UDim2.fromScale(1, 1)
	countLabel.TextXAlignment = Enum.TextXAlignment.Center
	self.countLabel = countLabel
end

function BattleUI:_row(slot: number)
	local existing = self.rows[slot]
	if existing then return existing end

	local row = Instance.new("Frame")
	row.Name = "Slot" .. slot
	row.Size = UDim2.new(1, 0, 0, ROW_H)
	row.BackgroundColor3 = Color3.fromRGB(24, 58, 110)
	row.BorderSizePixel = 0
	row.ZIndex = 12
	row.Parent = self.hudBoard
	UIKit.corner(row, 8)

	-- the share, drawn behind the text as a filling bar in the player's colour
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BackgroundColor3 = Battle.colorOf(slot)
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
	chip.BackgroundColor3 = Battle.colorOf(slot)
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
	name.Size = UDim2.new(1, -140, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.ZIndex = 15

	local pct = UIKit.outlined(row, "0.0%", 17, T.cream, 2.4)
	pct.AnchorPoint = Vector2.new(1, 0)
	pct.Position = UDim2.new(1, -8, 0, 0)
	pct.Size = UDim2.fromOffset(78, 30)
	pct.TextXAlignment = Enum.TextXAlignment.Right
	pct.ZIndex = 15

	local built = { row = row, bar = bar, place = place, name = name, pct = pct }
	self.rows[slot] = built
	return built
end

function BattleUI:ShowHud(roster: { any })
	-- The invitation is settled the moment the match exists, so there is nothing
	-- left for a cancellation to tell this player about.
	self.promptJoined = false
	self.names = {}
	for _, e in ipairs(roster) do
		self.names[e.slot] = e.name
	end
	-- Anything left from a previous match whose slot is not in this one.
	for slot, built in pairs(self.rows) do
		built.row.Visible = self.names[slot] ~= nil
	end
	reveal(self.hudRoot, self.hudScale, true)
end

function BattleUI:HideHud()
	reveal(self.hudRoot, self.hudScale, false)
end

function BattleUI:SetClock(left: number, total: number)
	self.hudClock.Text = clock(left)
	local frac = if total > 0 then math.clamp(left / total, 0, 1) else 0
	self.hudClockFill.Size = UDim2.fromScale(frac, 1)

	local hot = left <= 10
	self.hudClockFill.BackgroundColor3 = if hot then T.red else T.gold
	self.hudClock.TextColor3 = if hot then T.red else T.gold
end

function BattleUI:SetStandings(rows: { any })
	for rank, r in ipairs(rows) do
		local built = self:_row(r.slot)
		built.row.Visible = true
		built.row.LayoutOrder = rank
		built.place.Text = tostring(rank)
		built.name.Text = r.name or (self.names and self.names[r.slot]) or Battle.slotNameOf(r.slot)
		built.pct.Text = ("%.1f%%"):format(r.share * 100)
		built.bar.Size = UDim2.fromScale(math.clamp(r.share, 0, 1), 1)
		-- Your own row, picked out. Eight names go past quickly at a glance.
		local mine = r.userId == self.player.UserId
		built.row.BackgroundColor3 = if mine
			then Color3.fromRGB(46, 96, 160) else Color3.fromRGB(24, 58, 110)
	end
	-- Slots that dropped out of the standings entirely (a player who left).
	local seen = {}
	for _, r in ipairs(rows) do seen[r.slot] = true end
	for slot, built in pairs(self.rows) do
		if not seen[slot] then built.row.Visible = false end
	end

	local count = #rows
	if count ~= self.hudRowCount then
		self.hudRowCount = count
		self.hudBoardHolder.Size = UDim2.fromOffset(360, boardHeight(count))
		TopBand.refresh()
	end
end

function BattleUI:CountIn(seconds: number)
	self.countDeadline = os.clock() + seconds
	self.countLabel.Text = "READY"
	reveal(self.countRoot, self.countScale, true)
end

--==[ RESULTS ]===============================================================

function BattleUI:_buildResults()
	local holder = Instance.new("Frame")
	holder.Name = "Results"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(500, 430)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = self.gui
	self.resultRoot = holder
	self.resultScale = scaled(holder)

	-- 500 x 430 is 60% of a desktop's height and 96% of a handset's: a card on a
	-- monitor and a full-screen takeover on a phone.
	local _, content = UIKit.panel(fitted(holder, Vector2.new(0.5, 0.5)),
		UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), "Final Scores", T.gold)
	self.resultContent = content

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

function BattleUI:ShowResults(payload: { [string]: any })
	for _, c in ipairs(self.resultList:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end

	local you = payload.you
	if you then
		self.resultHead.Text = ("#%d  -  %.1f%%"):format(you.rank, you.share * 100)
		self.resultHead.TextColor3 = Battle.colorOf(you.slot)
		self.resultSub.Text = ("You earned <b>$%s</b>  -  purse x%s at an average level of %d")
			:format(Upgrades.short(you.coins), Upgrades.short(payload.multiplier or 1),
				math.floor(payload.averageLevel or 0))
	else
		-- A player who was dropped mid-match: they are not in the standings, and
		-- saying so -- along with what they were still paid for turning up -- is
		-- better than showing them a blank card.
		self.resultHead.Text = "DID NOT FINISH"
		self.resultHead.TextColor3 = T.slate
		self.resultSub.Text = ("You left the arena before the buzzer  -  <b>$%s</b> for turning up")
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
		chip.BackgroundColor3 = Battle.colorOf(r.slot)
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
		name.Size = UDim2.new(1, -250, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 10

		local pct = UIKit.outlined(row, ("%.1f%%"):format(r.share * 100), 16, T.blueLight, 2.2)
		pct.AnchorPoint = Vector2.new(1, 0)
		pct.Position = UDim2.new(1, -104, 0, 0)
		pct.Size = UDim2.fromOffset(70, 34)
		pct.TextXAlignment = Enum.TextXAlignment.Right
		pct.ZIndex = 10

		local coins = UIKit.outlined(row, "$" .. Upgrades.short(r.coins), 17, T.gold, 2.4)
		coins.AnchorPoint = Vector2.new(1, 0)
		coins.Position = UDim2.new(1, -8, 0, 0)
		coins.Size = UDim2.fromOffset(96, 34)
		coins.TextXAlignment = Enum.TextXAlignment.Right
		coins.ZIndex = 10
	end

	self.resultDeadline = os.clock() + (payload.seconds or Battle.ResultSeconds)
	reveal(self.resultRoot, self.resultScale, true)
end

function BattleUI:HideResults()
	self.resultDeadline = nil
	reveal(self.resultRoot, self.resultScale, false)
end

--==[ COUNTDOWNS ]============================================================

function BattleUI:_tickCountdowns()
	local now = os.clock()

	if self.tickerShow and self.tickerMinimised and not self.tickerRoot.Visible then
		self:_applyTicker()
	end

	local nextAt = self.tickerNextAt
	if nextAt and self.tickerRoot.Visible then
		local left = nextAt - workspace:GetServerTimeNow()
		if left < 0 then left = 0 end

		local whole = math.ceil(left)
		if whole ~= self.tickerLastWhole then
			self.tickerLastWhole = whole

			local urgent = left <= Battle.TimerWarnAt
			self.tickerTime.Text = if urgent then whole .. "s" else clock(left)
			self.tickerTime.TextColor3 = if urgent then T.red else T.gold
			self.tickerFill.BackgroundColor3 = if urgent then T.red else T.gold
			self.tickerTitle.Text = if urgent then "STARTING SOON" else "NEXT EVENT"
			self.tickerBadge.BackgroundColor3 = if urgent then T.red else T.gold

			-- One nudge a second in the last few, and never before: a badge that
			-- pulses for fifteen minutes is a badge players stop seeing.
			if left <= Battle.TimerHurryAt and left > 0 then
				self.tickerPulse.Scale = 1.13
				TweenService:Create(self.tickerPulse,
					TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Scale = 1 }):Play()
			end
		end

		local span = self.tickerSpan or 1
		self.tickerFill.Size = UDim2.fromScale(math.clamp(1 - left / span, 0, 1), 1)
	end

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
			self.countLabel.Text = "PAINT!"
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
			self.countLabel.Text = if step <= 1 then "SET" elseif step <= 2 then "READY" else tostring(step)
			self.countLabel.TextColor3 = T.gold
		end
	end

	local rd = self.resultDeadline
	if rd and now >= rd then
		self.resultDeadline = nil
		reveal(self.resultRoot, self.resultScale, false)
	end
end

function BattleUI:Destroy()
	if self._tick then self._tick:Disconnect() end
	self.gui:Destroy()
end

return BattleUI
