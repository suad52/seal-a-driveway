--!strict
-- The HUD. Built in code so it can be diffed and retuned like the rest.

local TweenService = game:GetService("TweenService")
local SoundKit = require(script.Parent.SoundKit)

local Interface = {}
Interface.__index = Interface

local INK = Color3.fromRGB(236, 240, 248)
local DIM = Color3.fromRGB(150, 158, 174)
local GOLD = Color3.fromRGB(255, 208, 92)
local PANEL = Color3.fromRGB(14, 16, 21)

local function corner(p: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
end

local function text(parent: Instance, str: string, size: UDim2, pos: UDim2, font: Enum.Font, color: Color3)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = font
	l.Text = str
	l.TextColor3 = color
	l.TextScaled = true
	l.TextWrapped = true
	l.ClipsDescendants = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = 12
	constraint.MaxTextSize = 32
	constraint.Parent = l
	
	return l
end

local function panel(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = PANEL
	f.BackgroundTransparency = 0.25
	f.BorderSizePixel = 0
	f.Parent = parent
	corner(f, 14)
	
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(220, 98)
	sizeConstraint.MaxSize = Vector2.new(420, 98)
	sizeConstraint.Parent = f
	
	return f
end

function Interface.new(playerGui: Instance)
	local gui = Instance.new("ScreenGui")
	gui.Name = "DrivewaySealerHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	--[ coverage, top centre ]------------------------------------------------
	local top = panel(gui, "Coverage")
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, 0, 18)
	top.Size = UDim2.new(0, 340, 0, 98)

	local caption = text(top, "DRIVEWAY", UDim2.new(1, -24, 0, 15), UDim2.new(0, 14, 0, 10),
		Enum.Font.GothamMedium, DIM)
	local percent = text(top, "0.0%", UDim2.new(0.6, 0, 0, 42), UDim2.new(0, 12, 0, 26),
		Enum.Font.GothamBold, INK)
	local value = text(top, "$0", UDim2.new(0.42, -14, 0, 26), UDim2.new(0.58, 0, 0, 34),
		Enum.Font.GothamBold, GOLD)
	value.TextXAlignment = Enum.TextXAlignment.Right

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Position = UDim2.new(0, 14, 1, -22)
	barBg.Size = UDim2.new(1, -28, 0, 10)
	barBg.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
	barBg.BorderSizePixel = 0
	barBg.Parent = top
	corner(barBg, 5)

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(120, 205, 255)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg
	corner(barFill, 5)

	-- a highlight that slides along the filled portion
	local shine = Instance.new("UIGradient")
	shine.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 170, 230)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 235, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 170, 230)),
	})
	shine.Parent = barFill

	--[ combo chip ]----------------------------------------------------------
	local combo = panel(gui, "Combo")
	combo.AnchorPoint = Vector2.new(0.5, 0)
	combo.Position = UDim2.new(0.5, 0, 0, 124)
	combo.Size = UDim2.new(0, 116, 0, 34)
	combo.BackgroundColor3 = Color3.fromRGB(58, 34, 12)
	combo.Visible = false
	local comboText = text(combo, "x2 COMBO", UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		Enum.Font.GothamBold, GOLD)
	comboText.TextXAlignment = Enum.TextXAlignment.Center

	--[ bonus toasts ]--------------------------------------------------------
	local toasts = Instance.new("Frame")
	toasts.Name = "Toasts"
	toasts.BackgroundTransparency = 1
	toasts.AnchorPoint = Vector2.new(1, 0.5)
	toasts.Position = UDim2.new(1, -24, 0.5, 0)
	toasts.Size = UDim2.new(0, 260, 0, 300)
	toasts.Parent = gui
	local listing = Instance.new("UIListLayout")
	listing.HorizontalAlignment = Enum.HorizontalAlignment.Right
	listing.VerticalAlignment = Enum.VerticalAlignment.Center
	listing.SortOrder = Enum.SortOrder.LayoutOrder
	listing.Padding = UDim.new(0, 8)
	listing.Parent = toasts

	--[ bucket gauge ]--------------------------------------------------------
	local bucket = panel(gui, "Bucket")
	-- clear of the backpack hotbar along the bottom edge
	bucket.AnchorPoint = Vector2.new(0.5, 1)
	bucket.Position = UDim2.new(0.5, 0, 1, -96)
	bucket.Size = UDim2.new(0, 240, 0, 46)
	bucket.Visible = false
	local bucketCap = text(bucket, "SEALER", UDim2.new(1, -24, 0, 13), UDim2.new(0, 12, 0, 7),
		Enum.Font.GothamMedium, DIM)
	local bucketBg = Instance.new("Frame")
	bucketBg.Position = UDim2.new(0, 12, 0, 25)
	bucketBg.Size = UDim2.new(1, -24, 0, 11)
	bucketBg.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
	bucketBg.BorderSizePixel = 0
	bucketBg.Parent = bucket
	corner(bucketBg, 5)
	local bucketFill = Instance.new("Frame")
	bucketFill.Size = UDim2.new(1, 0, 1, 0)
	bucketFill.BackgroundColor3 = Color3.fromRGB(224, 190, 96)
	bucketFill.BorderSizePixel = 0
	bucketFill.Parent = bucketBg
	corner(bucketFill, 5)

	local rig = panel(gui, "Rig")
	rig.AnchorPoint = Vector2.new(0, 1)
	rig.Position = UDim2.new(0, 24, 1, -96)
	rig.Size = UDim2.new(0, 236, 0, 128)
	rig.Visible = false

	local rigCap = text(rig, "RIG", UDim2.new(1, -24, 0, 14), UDim2.new(0, 14, 0, 9),
		Enum.Font.GothamMedium, DIM)

	local function gauge(parent: Instance, caption: string, y: number, fillColor: Color3)
		local cap = text(parent, caption, UDim2.new(0, 90, 0, 12), UDim2.new(0, 14, 0, y),
			Enum.Font.GothamMedium, DIM)
		local readout = text(parent, "", UDim2.new(0, 110, 0, 12), UDim2.new(1, -124, 0, y),
			Enum.Font.GothamBold, INK)
		readout.TextXAlignment = Enum.TextXAlignment.Right
		local bg = Instance.new("Frame")
		bg.Position = UDim2.new(0, 14, 0, y + 16)
		bg.Size = UDim2.new(1, -28, 0, 9)
		bg.BackgroundColor3 = Color3.fromRGB(38, 42, 52)
		bg.BorderSizePixel = 0
		bg.Parent = parent
		corner(bg, 4)
		local fill = Instance.new("Frame")
		fill.Size = UDim2.new(1, 0, 1, 0)
		fill.BackgroundColor3 = fillColor
		fill.BorderSizePixel = 0
		fill.Parent = bg
		corner(fill, 4)
		return cap, readout, fill
	end

	local _, tankRead, tankFill = gauge(rig, "TANK", 34, Color3.fromRGB(224, 190, 96))
	local _, hoseRead, hoseFill = gauge(rig, "HOSE", 72, Color3.fromRGB(196, 96, 84))

	local fillPanel = panel(gui, "Fill")
	fillPanel.AnchorPoint = Vector2.new(0.5, 1)
	fillPanel.Position = UDim2.new(0.5, 0, 1, -210)
	fillPanel.Size = UDim2.new(0, 300, 0, 70)
	fillPanel.Visible = false
	local fillCap = text(fillPanel, "AT THE PUMP", UDim2.new(1, -28, 0, 13),
		UDim2.new(0, 14, 0, 9), Enum.Font.GothamMedium, DIM)

	local function fillRow(y: number, caption: string, fillColor: Color3)
		local row = Instance.new("Frame")
		row.Name = caption
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Position = UDim2.new(0, 0, 0, y)
		row.Size = UDim2.new(1, 0, 0, 26)
		row.Parent = fillPanel
		-- the same gauge the rig panel is built from, measured from the row's own
		-- top rather than the panel's
		local _, readout, bar = gauge(row, caption, 0, fillColor)
		return row, readout, bar
	end

	local pailRow, pailRead, pailFill = fillRow(30, "PAIL", Color3.fromRGB(224, 190, 96))
	local drumRow, drumRead, drumFill = fillRow(62, "DRUM", Color3.fromRGB(150, 210, 255))

	-- Was the fan/stream nozzle readout. The wand has one setting now, so the chip
	-- carries whatever the player is in the middle of instead -- which since the
	-- reclaim mechanic was removed (2026-08-11) is nothing: `state.status` is never
	-- filled and the chip stays hidden. This whole HUD is the legacy one, built and
	-- disabled on join, so the plumbing is left in place rather than unpicked.
	local statusChip = panel(gui, "RigStatus")
	statusChip.AnchorPoint = Vector2.new(0, 1)
	statusChip.Position = UDim2.new(0, 24, 1, -232)
	statusChip.Size = UDim2.new(0, 210, 0, 32)
	statusChip.BackgroundColor3 = Color3.fromRGB(20, 32, 44)
	statusChip.Visible = false
	local statusText = text(statusChip, "", UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0),
		Enum.Font.GothamBold, Color3.fromRGB(150, 210, 255))
	statusText.TextXAlignment = Enum.TextXAlignment.Center

	--[ hint line ]-----------------------------------------------------------
	-- sits clear above the sealer gauge, which itself clears the hotbar
	local hint = text(gui, "", UDim2.new(0, 520, 0, 22), UDim2.new(0.5, -260, 1, -176),
		Enum.Font.GothamMedium, DIM)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.TextTransparency = 0.25

	return setmetatable({
		gui = gui,
		caption = caption, percent = percent, value = value,
		barFill = barFill, shine = shine,
		combo = combo, comboText = comboText,
		toasts = toasts, order = 0,
		bucket = bucket, bucketFill = bucketFill, bucketCap = bucketCap,
		rig = rig, rigCap = rigCap,
		tankRead = tankRead, tankFill = tankFill,
		hoseRead = hoseRead, hoseFill = hoseFill,
		fillPanel = fillPanel, fillCap = fillCap,
		pailRow = pailRow, pailRead = pailRead, pailFill = pailFill,
		drumRow = drumRow, drumRead = drumRead, drumFill = drumFill,
		statusChip = statusChip, statusText = statusText,
		hint = hint,
		shownCoverage = 0, shownValue = 0, shownBucket = 1, shownTank = 1,
		shownPail = 0, shownDrum = 0,
		pulse = 0, shineOffset = 0,
	}, Interface)
end

--==[ LIVE UPDATE ]===========================================================

local function approach(current: number, target: number, rate: number, dt: number): number
	-- frame-rate independent exponential ease
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

function Interface:Update(dt: number, state)

	if not self.gui.Enabled then return end

	local prev = self.shownCoverage
	self.shownCoverage = approach(self.shownCoverage, state.coverage, 6.5, dt)
	self.shownValue = approach(self.shownValue, state.value, 7.0, dt)

	local pct = self.shownCoverage * 100
	self.percent.Text = string.format("%.1f%%", pct)
	self.value.Text = "$" .. string.format("%d", math.floor(self.shownValue + 0.5))
	self.caption.Text = string.upper(state.name or "DRIVEWAY")
	self.barFill.Size = UDim2.new(self.shownCoverage, 0, 1, 0)

	-- kick the number when it is actively climbing
	if self.shownCoverage - prev > 0.00015 then
		self.pulse = math.min(1, self.pulse + dt * 7)
	else
		self.pulse = math.max(0, self.pulse - dt * 4)
	end
	local scale = 1 + self.pulse * 0.11
	self.percent.Size = UDim2.new(0.6 * scale, 0, 0, 42 * scale)
	self.percent.TextColor3 = INK:Lerp(Color3.fromRGB(176, 232, 255), self.pulse)

	self.shineOffset = (self.shineOffset + dt * 0.75) % 2
	self.shine.Offset = Vector2.new(self.shineOffset - 1, 0)

	if state.combo > 1 then
		self.combo.Visible = true
		self.comboText.Text = string.format("x%d COMBO", state.combo)
	else
		self.combo.Visible = false
	end

	if state.bucket then
		self.bucket.Visible = true
		self.shownBucket = approach(self.shownBucket, state.bucket, 12, dt)
		self.bucketFill.Size = UDim2.new(self.shownBucket, 0, 1, 0)
		self.bucketCap.Text = if state.bucket <= 0.001 then "SEALER -- EMPTY" else "SEALER"
		self.bucketFill.BackgroundColor3 = if state.bucket < 0.2
			then Color3.fromRGB(226, 116, 82) else Color3.fromRGB(224, 190, 96)
	else
		self.bucket.Visible = false
	end

	self:_updateRig(dt, state.rig, state.status)
	self:_updateFill(dt, state.fill)
	self.hint.Text = state.hint or ""
end

--==[ THE PUMP ]=============================================================

function Interface:_updateFill(dt: number, fill)
	if not fill then
		self.fillPanel.Visible = false
		return
	end

	local opening = not self.fillPanel.Visible
	self.fillPanel.Visible = true
	self.fillCap.Text = fill.caption or "AT THE PUMP"

	local function bar(shown: number, target: number, read: TextLabel, meter: Frame): number
		local now = if opening then target else approach(shown, target, 14, dt)
		meter.Size = UDim2.new(math.clamp(now, 0, 1), 0, 1, 0)
		read.Text = if target >= 0.999 then "FULL"
			else string.format("%d%%", math.floor(target * 100 + 0.5))
		read.TextColor3 = if target >= 0.999 then Color3.fromRGB(150, 210, 255) else INK
		return now
	end

	self.shownPail = bar(self.shownPail, fill.pail, self.pailRead, self.pailFill)

	-- The drum row only exists while there is a rig on the pad taking sealer, and
	-- the panel closes up behind it rather than leaving a gap where it was.
	if fill.drum then
		self.drumRow.Visible = true
		self.shownDrum = bar(self.shownDrum, fill.drum, self.drumRead, self.drumFill)
		self.fillPanel.Size = UDim2.new(0, 300, 0, 102)
	else
		self.drumRow.Visible = false
		self.fillPanel.Size = UDim2.new(0, 300, 0, 70)
	end
end

--==[ RIG PANEL ]=============================================================

function Interface:_updateRig(dt: number, rig, status: string?)
	-- the status chip is not part of the rig panel: it shows for the pail too,
	-- which is a tool anyone has from the start
	if status then
		self.statusChip.Visible = true
		self.statusText.Text = status
	else
		self.statusChip.Visible = false
	end

	if not rig then
		self.rig.Visible = false
		return
	end
	self.rig.Visible = true

	-- the tank rolls like the coverage number rather than stepping with the
	-- server's attribute updates
	self.shownTank = approach(self.shownTank, rig.tankFrac, 9, dt)
	self.tankFill.Size = UDim2.new(math.clamp(self.shownTank, 0, 1), 0, 1, 0)
	self.tankFill.BackgroundColor3 = if rig.tankFrac < 0.12
		then Color3.fromRGB(226, 116, 82) else Color3.fromRGB(224, 190, 96)
	self.tankRead.Text = if rig.refilling
		then "FILLING"
		else string.format("%d%%", math.floor(rig.tankFrac * 100 + 0.5))
	self.tankRead.TextColor3 = if rig.refilling then Color3.fromRGB(150, 210, 255) else INK

	-- Hose reads as paid out against the drum, and goes red as it comes tight so
	-- the drag on the player's legs has a visible cause.
	local frac = math.clamp(rig.hoseOut / rig.hoseMax, 0, 1)
	self.hoseFill.Size = UDim2.new(frac, 0, 1, 0)
	self.hoseFill.BackgroundColor3 = Color3.fromRGB(196, 96, 84):Lerp(
		Color3.fromRGB(255, 96, 72), rig.tension)
	self.hoseRead.Text = if rig.deployed
		then string.format("%d / %d", math.floor(rig.hoseOut), math.floor(rig.hoseMax))
		else "ON REEL"
	self.hoseRead.TextColor3 = if rig.tension > 0.5 then Color3.fromRGB(255, 150, 130) else INK
end

function Interface:Toast(labelText: string, amount: number, combo: number)
	-- Same reasoning as Update: a toast on a disabled HUD is ~10 instances and 8
	-- tweens built, animated and destroyed where nobody can see them. The Shell
	-- draws the visible bonus cards now.
	if not self.gui.Enabled then return end

	self.order += 1
	local card = Instance.new("Frame")
	card.Name = "Toast"
	card.LayoutOrder = self.order
	card.Size = UDim2.new(0, 250, 0, 46)
	card.BackgroundColor3 = PANEL
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.Parent = self.toasts
	corner(card, 10)

	local stripe = Instance.new("Frame")
	stripe.Size = UDim2.new(0, 4, 1, -14)
	stripe.Position = UDim2.new(0, 9, 0, 7)
	stripe.BackgroundColor3 = GOLD
	stripe.BorderSizePixel = 0
	stripe.Parent = card
	corner(stripe, 2)

	local title = text(card, labelText, UDim2.new(1, -110, 0, 17), UDim2.new(0, 21, 0, 8),
		Enum.Font.GothamBold, INK)
	local sub = text(card, if combo > 1 then string.format("combo x%d", combo) else "bonus",
		UDim2.new(1, -110, 0, 13), UDim2.new(0, 21, 0, 26), Enum.Font.GothamMedium, DIM)
	local amt = text(card, "+$" .. amount, UDim2.new(0, 84, 0, 22), UDim2.new(1, -94, 0.5, -11),
		Enum.Font.GothamBold, GOLD)
	amt.TextXAlignment = Enum.TextXAlignment.Right

	for _, o in ipairs({ title, sub, amt }) do o.TextTransparency = 1 end
	card.Position = UDim2.new(0, 40, 0, 0)

	local inInfo = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(card, inInfo, { BackgroundTransparency = 0.15 }):Play()
	for _, o in ipairs({ title, amt }) do
		TweenService:Create(o, inInfo, { TextTransparency = 0 }):Play()
	end
	TweenService:Create(sub, inInfo, { TextTransparency = 0.3 }):Play()

	task.delay(1.9, function()
		local outInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(card, outInfo, { BackgroundTransparency = 1 }):Play()
		for _, o in ipairs({ title, sub, amt }) do
			TweenService:Create(o, outInfo, { TextTransparency = 1 }):Play()
		end
		TweenService:Create(stripe, outInfo, { BackgroundTransparency = 1 }):Play()
		task.wait(0.4)
		card:Destroy()
	end)
end

function Interface:Destroy()
	self.gui:Destroy()
end

return Interface
