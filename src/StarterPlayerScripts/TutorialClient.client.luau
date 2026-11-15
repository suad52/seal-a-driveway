
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Pack = ReplicatedStorage:WaitForChild("SealerUI")
local UIKit = require(Pack:WaitForChild("UIKit"))
local TopBand = require(Pack:WaitForChild("TopBand"))
local HudBus = require(Pack:WaitForChild("HudBus"))
local HudActions = require(Pack:WaitForChild("HudActions"))
local Sealer = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Config = require(Sealer:WaitForChild("Config"))
local Depot = require(Sealer:WaitForChild("Depot"))
local SoundKit = require(Sealer:WaitForChild("SoundKit"))
local Players = game:GetService("Players")
local plr = Players.LocalPlayer

local NAVY  = Color3.fromRGB(38, 44, 56)
local CREAM = Color3.fromRGB(236, 233, 222)
local GOLD  = Color3.fromRGB(255, 214, 92)
local LIME  = Color3.fromRGB(126, 255, 118)
local SLATE = Color3.fromRGB(84, 94, 110)

local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))

local OBJECTIVES = 5

local DEPOT_ATTR = "DepotSealed"

local POUR_SHARE = 0.85

local FIRST_PASS = 0.30

local PAIL_EMPTY = 0.03

local FILL_FULL = 0.97

local FILL_SHARE = 0.5

local STALL_LOOSE = 0.02

local STALL_PATIENCE = 2.0

local TICK_HOLD = 1.25

local TICK_MIN = 0.4

local HOLD_DONE = 8

local touchNow = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

UserInputService.LastInputTypeChanged:Connect(function(t: Enum.UserInputType)
	if t == Enum.UserInputType.Touch then
		touchNow = true
	elseif t == Enum.UserInputType.Keyboard
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseMovement then
		touchNow = false
	end
end)

export type Chip = {
	cap: string?,
	keys: { string }?,
	note: string?,
	hold: boolean?,
	action: string?,
}

local function chip(keyboard: Chip, touch: Chip): Chip
	return if Console.active() then Console.chip(keyboard) elseif touchNow then touch else keyboard
end

local cachedDrive: BasePart? = nil
local function drivewayPart(): BasePart?
	if cachedDrive and cachedDrive.Parent then return cachedDrive end
	local hood = workspace:FindFirstChild("Neighbourhood")
	local pave = hood and hood:FindFirstChild("Pavement")
	local lot = pave and pave:FindFirstChild("Lot_114")
	local d = lot and lot:FindFirstChild("Driveway")
	cachedDrive = if d and d:IsA("BasePart") then d else nil
	return cachedDrive
end

local function driveName(): string?
	local d = drivewayPart()
	if not d then return nil end
	return (d:GetAttribute("DrivewayName") :: string?) or d.Name
end

local function drivewaySpot(): Vector3?
	local d = drivewayPart()
	return if d then d.Position + Vector3.new(0, 0.5, 0) else nil
end

local function depotGarage(): Instance?
	local hood = workspace:FindFirstChild("Neighbourhood")
	local depot = hood and hood:FindFirstChild("Depot")
	return depot and depot:FindFirstChild("Garage")
end

local function pumpPart(): BasePart?
	local garage = depotGarage()
	local refuel = garage and garage:FindFirstChild("Refuel")
	local dripTray = refuel and refuel:FindFirstChild("DripTray")
	return if dripTray and dripTray:IsA("BasePart") then dripTray else nil
end

local function groundSpot(part: BasePart?): Vector3?
	if not part then return nil end

	return Vector3.new(part.Position.X,
		part.Position.Y - part.Size.Y * 0.5 + 0.12,
		part.Position.Z)
end

local function refuelSpot(): Vector3?
	return groundSpot(pumpPart())
end

local function counterPart(): BasePart?
	local garage = depotGarage()
	local counter = garage and garage:FindFirstChild("Counter")
	local terminal = counter and counter:FindFirstChild("ShopTerminal")
	local base = terminal and terminal:FindFirstChild("Base")
	return if base and base:IsA("BasePart") then base else nil
end

local function counterSpot(): Vector3?
	return groundSpot(counterPart())
end

local function mapExitPart(): BasePart?
	local hood = workspace:FindFirstChild("Neighbourhood")
	local depot = hood and hood:FindFirstChild("Depot")
	local apron = depot and depot:FindFirstChild("DepotApron")
	return if apron and apron:IsA("BasePart") then apron else nil
end

local function mapExitSpot(): Vector3?
	local apron = mapExitPart()
	if not apron then return nil end
	return Vector3.new(apron.Position.X,
		apron.Position.Y + apron.Size.Y * 0.5 + 0.12,
		apron.Position.Z)
end

local function rootPart(): BasePart?
	local ch = plr.Character
	local r = ch and ch:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function reachedMapExit(): boolean
	local gate = mapExitPart()
	local root = rootPart()
	if not gate or not root then return false end

	local p = gate.CFrame:PointToObjectSpace(root.Position)
	local margin = 4
	return math.abs(p.X) <= gate.Size.X * 0.5 + margin
		and math.abs(p.Z) <= gate.Size.Z * 0.5 + margin
		and math.abs(p.Y) <= gate.Size.Y * 0.5 + 10
end

local function heldTool(): string?
	local ch = plr.Character
	local t = ch and ch:FindFirstChildOfClass("Tool")
	return if t then t.Name else nil
end

local gui = Instance.new("ScreenGui")
gui.Name = "SealerTutorial"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 25
gui.Enabled = false
gui.Parent = plr:WaitForChild("PlayerGui")

local card = Instance.new("Frame")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 0)
card.Position = UDim2.fromOffset(0, 14)
card.Size = UDim2.fromOffset(460, 0)
card.AutomaticSize = Enum.AutomaticSize.Y
card.BackgroundColor3 = NAVY
card.BorderSizePixel = 0
card.ZIndex = 30
card.Parent = gui
UIKit.corner(card, 14)

local cardStroke = UIKit.stroke(card, 2.6)

UIKit.gradient(card, 0.55)

local cardScale = Instance.new("UIScale")
cardScale.Parent = card
local baseScale = 1.0

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 9)
pad.PaddingBottom = UDim.new(0, 11)
pad.PaddingLeft = UDim.new(0, 16)
pad.PaddingRight = UDim.new(0, 16)
pad.Parent = card

local rows = Instance.new("UIListLayout")
rows.SortOrder = Enum.SortOrder.LayoutOrder
rows.Padding = UDim.new(0, 6)
rows.Parent = card

local aspectRationConstraint = Instance.new("UIAspectRatioConstraint")
aspectRationConstraint.Parent = card
aspectRationConstraint.AspectRatio = 35/9

local header = Instance.new("Frame")
header.Name = "Header"
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 16)
header.LayoutOrder = 1
header.ZIndex = 31
header.Parent = card

local crumb = UIKit.label(header, "TUTORIAL", 13, GOLD)
crumb.Size = UDim2.new(1, -120, 1, 0)
crumb.TextXAlignment = Enum.TextXAlignment.Left
crumb.ZIndex = 31

local pipRow = Instance.new("Frame")
pipRow.BackgroundTransparency = 1
pipRow.AnchorPoint = Vector2.new(1, 0.5)
pipRow.Position = UDim2.new(1, 0, 0.5, 0)
pipRow.Size = UDim2.fromOffset(112, 11)
pipRow.ZIndex = 31
pipRow.Parent = header

local pipLayout = Instance.new("UIListLayout")
pipLayout.FillDirection = Enum.FillDirection.Horizontal
pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
pipLayout.Padding = UDim.new(0, 5)
pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
pipLayout.Parent = pipRow

local pips: { Frame } = {}
for i = 1, OBJECTIVES do
	local p = Instance.new("Frame")
	p.Size = UDim2.fromOffset(13, 10)
	p.BackgroundColor3 = SLATE
	p.BorderSizePixel = 0
	p.LayoutOrder = i
	p.ZIndex = 32
	p.Parent = pipRow
	UIKit.corner(p, 4)
	UIKit.stroke(p, 1.5)
	pips[i] = p
end

local title = UIKit.label(card, "", 27, CREAM)
title.Name = "Objective"
title.Font = UIKit.Display
title.Size = UDim2.new(1, 0, 0, 0)
title.AutomaticSize = Enum.AutomaticSize.Y
title.TextWrapped = true
title.TextXAlignment = Enum.TextXAlignment.Left
title.LayoutOrder = 2
title.ZIndex = 31
UIKit.stroke(title, 2.4, nil, true)

local barRow = Instance.new("Frame")
barRow.Name = "Bar"
barRow.BackgroundTransparency = 1
barRow.Size = UDim2.new(1, 0, 0, 16)
barRow.LayoutOrder = 3
barRow.Visible = false
barRow.ZIndex = 31
barRow.Parent = card

local barWell = Instance.new("Frame")
barWell.AnchorPoint = Vector2.new(0, 0.5)
barWell.Position = UDim2.new(0, 0, 0.5, 0)
barWell.Size = UDim2.new(1, -104, 0, 11)
barWell.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
barWell.BorderSizePixel = 0
barWell.ZIndex = 31
barWell.Parent = barRow
UIKit.corner(barWell, 6)
UIKit.stroke(barWell, 1.8)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = GOLD
barFill.BorderSizePixel = 0
barFill.ZIndex = 32
barFill.Parent = barWell
UIKit.corner(barFill, 6)

local barCap = UIKit.label(barRow, "", 14, CREAM)
barCap.AnchorPoint = Vector2.new(1, 0.5)
barCap.Position = UDim2.new(1, 0, 0.5, 0)
barCap.Size = UDim2.fromOffset(98, 16)
barCap.TextXAlignment = Enum.TextXAlignment.Right
barCap.ZIndex = 31

local barShown = 0

local CHIP_MAX = 2
local CAP_H = 38

local chipRow = Instance.new("Frame")
chipRow.Name = "Chips"
chipRow.BackgroundTransparency = 1
chipRow.Size = UDim2.new(1, 0, 0, CAP_H)
chipRow.LayoutOrder = 4
chipRow.Visible = false
chipRow.ZIndex = 31
chipRow.Parent = card

local chipLayout = Instance.new("UIListLayout")
chipLayout.FillDirection = Enum.FillDirection.Horizontal
chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
chipLayout.Padding = UDim.new(0, 14)
chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
chipLayout.Parent = chipRow

local function capWidth(text: string): number
	return if #text <= 2 then 46 else 18 + #text * 13
end

local CAPS_PER_CHIP = 4

type CapView = { btn: TextButton, fill: Frame }
type ChipView = { holder: Frame, caps: { CapView }, note: TextLabel }
local chips: { ChipView } = {}

local chipAction: { [number]: string? } = {}

for i = 1, CHIP_MAX do
	local holder = Instance.new("Frame")
	holder.Name = "Chip" .. i
	holder.BackgroundTransparency = 1
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Size = UDim2.fromOffset(0, CAP_H)
	holder.LayoutOrder = i
	holder.Visible = false
	holder.ZIndex = 31
	holder.Parent = chipRow

	local inner = Instance.new("UIListLayout")
	inner.FillDirection = Enum.FillDirection.Horizontal
	inner.VerticalAlignment = Enum.VerticalAlignment.Center
	inner.Padding = UDim.new(0, 5)
	inner.SortOrder = Enum.SortOrder.LayoutOrder
	inner.Parent = holder

	local caps: { CapView } = {}
	for k = 1, CAPS_PER_CHIP do
		local btn = Instance.new("TextButton")
		btn.Name = "Cap" .. k
		btn.Size = UDim2.fromOffset(46, CAP_H)
		btn.BackgroundColor3 = CREAM
		btn.Active = false
		btn.AutoButtonColor = false
		btn.Font = UIKit.Display
		btn.Text = ""
		btn.TextSize = 22
		btn.TextColor3 = NAVY

		btn.ClipsDescendants = true
		btn.LayoutOrder = k
		btn.Visible = false
		btn.ZIndex = 32
		btn.Parent = holder
		UIKit.corner(btn, 9)
		UIKit.stroke(btn, 2.4)

		local fill = Instance.new("Frame")
		fill.Name = "Hold"
		fill.AnchorPoint = Vector2.new(0, 1)
		fill.Position = UDim2.new(0, 0, 1, 0)
		fill.Size = UDim2.new(0, 0, 0, 5)
		fill.BackgroundColor3 = NAVY
		fill.BackgroundTransparency = 0.4
		fill.BorderSizePixel = 0
		fill.Visible = false
		fill.ZIndex = 33
		fill.Parent = btn

		btn.Activated:Connect(function()
			local channel = chipAction[i]
			if (touchNow or Console.active()) and channel then HudActions.fire(channel) end
		end)

		caps[k] = { btn = btn, fill = fill }
	end

	local note = UIKit.label(holder, "", 16, CREAM)
	note.AutomaticSize = Enum.AutomaticSize.X
	note.Size = UDim2.fromOffset(0, CAP_H)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.LayoutOrder = CAPS_PER_CHIP + 1
	note.ZIndex = 31

	chips[i] = { holder = holder, caps = caps, note = note }
end

local HOLD_SWEEP = 1.2

local function setChips(list: { Chip }?)
	local want: { Chip } = list or {}
	chipRow.Visible = #want > 0
	if not chipRow.Visible then return end

	for i, view in ipairs(chips) do
		local c = want[i]
		chipAction[i] = if c then c.action else nil
		if not c then
			view.holder.Visible = false
			continue
		end
		view.holder.Visible = true

		local tokens = c.keys or { c.cap or "" }
		for k, cap in ipairs(view.caps) do
			local word = tokens[k]
			cap.btn.Visible = word ~= nil and word ~= ""
			if not cap.btn.Visible then
				continue
			end
			cap.btn.Text = word
			cap.btn.Size = UDim2.fromOffset(capWidth(word), CAP_H)
			cap.btn.TextSize = if #word <= 2 then 22 else 17
			cap.btn.BackgroundColor3 = if c.hold then GOLD else CREAM

			cap.btn.Active = (touchNow or Console.active()) and c.action ~= nil
			cap.btn.AutoButtonColor = cap.btn.Active

			cap.fill.Visible = c.hold == true
			if c.hold then
				cap.fill.Size = UDim2.new((os.clock() % HOLD_SWEEP) / HOLD_SWEEP, 0, 0, 5)
			end
		end

		view.note.Visible = c.note ~= nil and c.note ~= ""
		view.note.Text = c.note or ""
	end
end

local nudge = UIKit.label(card, "", 15, GOLD)
nudge.Name = "Nudge"
nudge.Size = UDim2.new(1, 0, 0, 17)
nudge.TextXAlignment = Enum.TextXAlignment.Left
nudge.LayoutOrder = 5
nudge.Visible = false
nudge.ZIndex = 31

local function screen(): Vector2
	local cam = workspace.CurrentCamera
	local v = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	if v.X < 200 or v.Y < 200 then v = Vector2.new(1280, 720) end
	return Vector2.new(v.X, math.max(1, v.Y - GuiService:GetGuiInset().Y))
end

local FALLBACK_AREA = 24 + 460 + 14
local FALLBACK_RAIL = 22 + 82 + 14
local FALLBACK_DROP = 294
local EDGE_GAP  = 14
local CARD_MAX  = 460

local CARD_MIN  = 280

local shell: Instance? = nil
local function shellBlock(name: string): GuiObject?
	local sh = shell
	if not sh or not sh.Parent then return nil end
	local f = sh:FindFirstChild(name)
	return if f and f:IsA("GuiObject") and f.Visible and f.AbsoluteSize.X > 0
		then f :: GuiObject
		else nil
end

local baseY, baseX = 14, 0

local TOPBAR_CLEAR = 10
local TIGHT = 0.30

local function lift(): number
	local inset = GuiService:GetGuiInset().Y
	if inset <= 0 then return 0 end

	local vp = screen()
	if math.ceil(card.AbsoluteSize.Y) < vp.Y * TIGHT then return 0 end

	local side = if shell and shell.AbsoluteSize.X > 200
		then math.max(0, (vp.X - shell.AbsoluteSize.X) * 0.5)
		else 0
	local left = side + baseX - math.ceil(card.AbsoluteSize.X * 0.5)
	if left < GuiService.TopbarInset.Min.X + TOPBAR_CLEAR then return 0 end

	return math.max(0, inset - 6)
end

local function place()
	local vp = screen()
	local floor = vp.Y - 10
	local hotbar = shellBlock("Hotbar")
	if hotbar then floor = math.min(floor, hotbar.AbsolutePosition.Y - 10) end

	local y = math.min(baseY, math.max(8, floor - math.ceil(card.AbsoluteSize.Y))) - lift()
	if card.Position.Y.Offset ~= y or card.Position.X.Offset ~= baseX then
		card.Position = UDim2.fromOffset(baseX, y)
	end

	TopBand.refresh()
end

TopBand.reserve("Tutorial", function(): number?
	if not gui.Enabled or not card.Visible then return nil end
	return card.Position.Y.Offset + math.ceil(card.AbsoluteSize.Y)
end)

card:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
gui:GetPropertyChangedSignal("Enabled"):Connect(TopBand.refresh)

local function restyle()
	local vp = screen()

	baseScale = math.clamp(math.min(vp.X / 1100, vp.Y / 650), 0.55, 1.15)
	cardScale.Scale = baseScale

	local area = shellBlock("Area")
	local rail = shellBlock("Rail")

	local left = if area
		then area.AbsolutePosition.X + area.AbsoluteSize.X + EDGE_GAP
		else FALLBACK_AREA
	local right = if rail
		then vp.X - rail.AbsolutePosition.X + EDGE_GAP
		else FALLBACK_RAIL
	local gap = vp.X - left - right

	local wVis, x, y
	if gap >= CARD_MIN then
		wVis = math.min(CARD_MAX, gap)
		x = math.clamp(vp.X * 0.5, left + wVis * 0.5, vp.X - right - wVis * 0.5)
		y = 14
	else
		wVis = math.min(CARD_MAX, vp.X - 32)
		x = vp.X * 0.5

		y = if area
			then math.ceil(area.AbsolutePosition.Y + area.AbsoluteSize.Y) + 7
			else FALLBACK_DROP
	end

	card.Size = UDim2.fromOffset(math.floor(wVis / baseScale), 0)
	baseX, baseY = math.floor(x), y
	place()

	title.TextSize = if wVis < 380 then 21 elseif wVis < 440 then 24 else 27
	barWell.Size = UDim2.new(1, if wVis < 380 then -88 else -104, 0, 11)
	local noteSize = if wVis < 380 then 13 elseif wVis < 440 then 15 else 16
	for _, view in ipairs(chips) do view.note.TextSize = noteSize end
end

local SHELL_BLOCKS = { Area = true, Rail = true, Hotbar = true }
local hooked: { [Instance]: boolean } = {}

local function hookBlock(f: Instance)
	if hooked[f] or not f:IsA("GuiObject") or not SHELL_BLOCKS[f.Name] then return end
	hooked[f] = true
	f:GetPropertyChangedSignal("AbsoluteSize"):Connect(restyle)
	f:GetPropertyChangedSignal("AbsolutePosition"):Connect(restyle)
	f:GetPropertyChangedSignal("Visible"):Connect(restyle)
	restyle()
end

local function watchShell(sh: Instance)
	shell = sh
	for _, f in ipairs(sh:GetChildren()) do hookBlock(f) end
	sh.ChildAdded:Connect(hookBlock)
	restyle()
end

local shellNow = plr.PlayerGui:FindFirstChild("SealerShell")
if shellNow then watchShell(shellNow) end
plr.PlayerGui.ChildAdded:Connect(function(c)
	if c.Name == "SealerShell" then watchShell(c) end
end)

restyle()
local camera = workspace.CurrentCamera
if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(restyle) end

GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(restyle)

local function pop(mul: number?)

	local from = (mul or 0.94) * baseScale
	cardScale.Scale = from
	TweenService:Create(cardScale, TweenInfo.new(0.22, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = baseScale }):Play()
end

local bannerGui = Instance.new("ScreenGui")
bannerGui.Name = "SealerTutorialBanner"
bannerGui.ResetOnSpawn = false
bannerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
bannerGui.DisplayOrder = 27
bannerGui.Enabled = false
bannerGui.Parent = plr.PlayerGui

local bannerHolder = Instance.new("Frame")
bannerHolder.BackgroundTransparency = 1
bannerHolder.AnchorPoint = Vector2.new(0.5, 0.5)
bannerHolder.Position = UDim2.new(0.5, 0, 0.36, 0)
bannerHolder.Size = UDim2.new(1, 0, 0, 120)
bannerHolder.Parent = bannerGui

local bannerScale = Instance.new("UIScale")
bannerScale.Parent = bannerHolder

local bannerText = UIKit.outlined(bannerHolder, "", 62, LIME, 4)
bannerText.Size = UDim2.new(1, 0, 1, 0)
bannerText.TextXAlignment = Enum.TextXAlignment.Center
bannerText.Font = UIKit.Display

local bannerUntil = 0

local function banner(text: string, tint: Color3, seconds: number)
	bannerText.Text = text
	bannerText.TextColor3 = tint
	bannerGui.Enabled = true
	bannerUntil = os.clock() + seconds

	local s = baseScale
	bannerScale.Scale = 0.6 * s
	TweenService:Create(bannerScale, TweenInfo.new(0.34, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = s }):Play()
	SoundKit.play("Sparkle")
end

local fx = Instance.new("Folder")
fx.Name = "TutorialFX"
fx.Parent = workspace

local function decor(name: string, size: Vector3, colour: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false

	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = colour
	p.Size = size
	p.Parent = fx
	return p
end

local ring = decor("Ring", Vector3.new(0.4, 11, 11), GOLD)
ring.Shape = Enum.PartType.Cylinder
ring.Transparency = 0.35

local DASHES = 12
local dashes: { BasePart } = {}
for i = 1, DASHES do
	dashes[i] = decor("Dash", Vector3.new(2.6, 0.15, 1.1), GOLD)
end

local anchor = decor("Anchor", Vector3.new(0.2, 0.2, 0.2), GOLD)
anchor.Transparency = 1

local bb = Instance.new("BillboardGui")
bb.Name = "Marker"
bb.AlwaysOnTop = true
bb.Size = UDim2.fromOffset(190, 116)
bb.Parent = anchor

local chevron = UIKit.outlined(bb, "\u{25BC}", 62, GOLD, 3)
chevron.AnchorPoint = Vector2.new(0.5, 1)
chevron.Position = UDim2.new(0.5, 0, 1, 0)
chevron.Size = UDim2.fromOffset(190, 64)
chevron.TextXAlignment = Enum.TextXAlignment.Center

local markerCap = UIKit.outlined(bb, "", 24, CREAM, 3)
markerCap.AnchorPoint = Vector2.new(0.5, 0)
markerCap.Position = UDim2.new(0.5, 0, 0, 0)
markerCap.Size = UDim2.fromOffset(190, 44)
markerCap.TextXAlignment = Enum.TextXAlignment.Center

local ARROWS = 8
local ARROW_LIFT = 0.16

local LANE = 5.5
type Arrow = { a: BasePart, b: BasePart }
local arrows: { Arrow } = {}
for i = 1, ARROWS do

	arrows[i] = {
		a = decor("Chev", Vector3.new(1.3, 0.12, 3.4), LIME),
		b = decor("Chev", Vector3.new(1.3, 0.12, 3.4), LIME),
	}
end

local function hideArrows()
	for _, m in ipairs(arrows) do
		m.a.Transparency = 1
		m.b.Transparency = 1
	end
end

local function sweepAxis(slab: BasePart, from: Vector3, facing: Vector3?): Vector3
	local size = slab.Size
	local localAxis = if size.X >= size.Z then Vector3.xAxis else Vector3.zAxis
	local a = slab.CFrame:VectorToWorldSpace(localAxis)
	a = Vector3.new(a.X, 0, a.Z)
	if a.Magnitude < 1e-3 then return Vector3.xAxis end
	a = a.Unit

	local toMiddle = Vector3.new(slab.Position.X - from.X, 0, slab.Position.Z - from.Z)
	local reach = toMiddle:Dot(a)
	if math.abs(reach) < 4 and facing then
		local f = Vector3.new(facing.X, 0, facing.Z)
		if f.Magnitude > 1e-3 and f.Unit:Dot(a) < 0 then a = -a end
	elseif reach < 0 then
		a = -a
	end
	return a
end

local function showArrows(slab: BasePart, start: Vector3, facing: Vector3?, urgent: boolean)
	local fwd = sweepAxis(slab, start, facing)
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	local y = slab.Position.Y + slab.Size.Y * 0.5 + ARROW_LIFT

	local SPAN = 18
	local half = ARROWS // 2
	local slide = (os.clock() * 0.55) % 1

	for i, m in ipairs(arrows) do

		local outbound = i <= half
		local n = if outbound then i else i - half
		local f = ((n - 1) / half + slide) % 1

		local dir = if outbound then fwd else -fwd
		local base = if outbound then start
			else start + right * LANE + fwd * (3 + SPAN)
		local tip = base + dir * (3 + f * SPAN)
		local at = Vector3.new(tip.X, y, tip.Z)

		local dirA = (dir + right * 0.8).Unit
		local dirB = (dir - right * 0.8).Unit
		m.a.CFrame = CFrame.lookAt(at - dirA * 1.7, at)
		m.b.CFrame = CFrame.lookAt(at - dirB * 1.7, at)

		local fade = 0.15 + 0.55 * math.abs(f - 0.5) * 2
		if urgent then fade *= 0.5 end
		m.a.Transparency = fade
		m.b.Transparency = fade
	end
end

local glow = Instance.new("Highlight")
glow.Name = "TutorialGlow"
glow.FillTransparency = 1
glow.FillColor = GOLD
glow.OutlineColor = GOLD
glow.Enabled = false
glow.Parent = fx

local function setGlow(part: BasePart?, through: boolean, urgent: boolean)
	if not part then
		glow.Enabled = false
		glow.Adornee = nil
		return
	end

	if glow.Adornee ~= part then glow.Adornee = part end
	glow.Enabled = true

	glow.DepthMode = if through then Enum.HighlightDepthMode.AlwaysOnTop
		else Enum.HighlightDepthMode.Occluded
	local k = 0.5 + 0.5 * math.sin(os.clock() * 3.4)
	glow.OutlineTransparency = 0.05 + 0.35 * k

	glow.FillTransparency = if urgent then 0.72 + 0.16 * k else 1
end

local function hideWorld()
	ring.Transparency = 1
	anchor.Transparency = 1
	bb.Enabled = false
	for _, d in ipairs(dashes) do d.Transparency = 1 end
	hideArrows()
	glow.Enabled = false
end

local RING_NEAR = 14

local RING_LIFT = 0.2 + 0.15

local routeAt = 0
local routeFrom: Vector3? = nil
local routeTo: Vector3? = nil
local routePoints: { Vector3 } = {}
local routeBusy = false
local routeVersion = 0

local function worldRoute(from: Vector3, to: Vector3): { Vector3 }
	local now = os.clock()
	local moved = routeFrom == nil or (from - (routeFrom :: Vector3)).Magnitude >= 5
	local changedTarget = routeTo == nil or (to - (routeTo :: Vector3)).Magnitude >= 1
	local stale = now - routeAt >= 0.5 or moved or changedTarget

	if stale and not routeBusy then
		routeAt = now
		routeFrom = from
		routeTo = to
		routeBusy = true
		routeVersion += 1
		local myVersion = routeVersion
		local fromNow, toNow = from, to

		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true,
				WaypointSpacing = 5,
			})

			local ok = pcall(function()
				path:ComputeAsync(fromNow, toNow)
			end)

			local points: { Vector3 } = { fromNow }
			if ok and path.Status == Enum.PathStatus.Success then
				for _, waypoint in ipairs(path:GetWaypoints()) do
					table.insert(points, waypoint.Position)
				end
			end
			if #points < 2 then
				table.insert(points, toNow)
			elseif (points[#points] - toNow).Magnitude > 2 then
				table.insert(points, toNow)
			end

			if myVersion == routeVersion then
				routePoints = points
			end
			routeBusy = false
		end)
	end

	if #routePoints >= 2 and not changedTarget then
		return routePoints
	end
	return { from, to }
end

local function routeLength(points: { Vector3 }): number
	local total = 0
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		total += Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
	end
	return total
end

local function alongRoute(points: { Vector3 }, distance: number): (Vector3, Vector3)
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local len = flat.Magnitude
		if len > 0.001 then
			if distance <= len then
				local dir = flat.Unit
				return a + dir * distance, dir
			end
			distance -= len
		end
	end

	local last = points[#points]
	local prev = points[math.max(1, #points - 1)]
	local flat = Vector3.new(last.X - prev.X, 0, last.Z - prev.Z)
	local dir = if flat.Magnitude > 0.001 then flat.Unit else Vector3.new(0, 0, 1)
	return last, dir
end

local function showWorld(spot: Vector3, caption: string, from: Vector3?,
	ringClose: boolean?, urgent: boolean)
	local t = os.clock()
	local bob = math.sin(t * 3.2) * 0.55

	bb.Enabled = true
	markerCap.Text = caption
	anchor.CFrame = CFrame.new(spot + Vector3.new(0, 7.4 + bob, 0))

	chevron.TextSize = if urgent then 76 + 18 * (0.5 + 0.5 * math.sin(t * 5)) else 62

	local flat = if from then Vector3.new(spot.X - from.X, 0, spot.Z - from.Z) else nil
	local span = if flat then flat.Magnitude else 0

	if ringClose or not flat or span >= RING_NEAR then
		ring.Transparency = 0.35 + 0.18 * (0.5 + 0.5 * math.sin(t * 3.2))
		local y = if ringClose then spot.Y + RING_LIFT else spot.Y - 0.35

		ring.CFrame = CFrame.new(spot.X, y, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
		local pulse = (if urgent then 12 else 10) + 1.6 * math.sin(t * 3.2)
		ring.Size = Vector3.new(0.4, pulse, pulse)
	else
		ring.Transparency = 1
	end

	if not from or not flat or span < 4 then
		for _, d in ipairs(dashes) do d.Transparency = 1 end
		return
	end

	local points = worldRoute(from, spot)
	local routeSpan = routeLength(points)
	if routeSpan < 4 then
		for _, d in ipairs(dashes) do d.Transparency = 1 end
		return
	end

	local slide = (t * (if urgent then 0.95 else 0.35)) % 1
	for i, d in ipairs(dashes) do
		local f = ((i - 1) / DASHES + slide) % 1
		local distance = 3 + f * math.max(1, routeSpan - 4)
		local at, dir = alongRoute(points, distance)

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { fx, plr.Character }
		local hit = workspace:Raycast(at + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), params)
		local y = if hit then hit.Position.Y else at.Y
		local foot = Vector3.new(at.X, y + 0.12, at.Z)

		d.CFrame = CFrame.lookAt(foot, foot + dir)
		d.Material = if urgent then Enum.Material.Neon else Enum.Material.SmoothPlastic
		d.Size = if urgent then Vector3.new(4.2, 0.18, 1.55) else Vector3.new(2.6, 0.15, 1.1)
		d.Transparency = if urgent
			then 0.04 + 0.24 * math.abs(f - 0.5)
			else 0.25 + 0.6 * math.abs(f - 0.5)
	end
end

local pointerGui = Instance.new("ScreenGui")
pointerGui.Name = "SealerTutorialPointer"
pointerGui.ResetOnSpawn = false
pointerGui.IgnoreGuiInset = false
pointerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pointerGui.DisplayOrder = 26
pointerGui.Parent = plr.PlayerGui

local pulse = Instance.new("Frame")
pulse.Name = "Pulse"
pulse.BackgroundColor3 = GOLD
pulse.BackgroundTransparency = 0.82
pulse.BorderSizePixel = 0
pulse.ZIndex = 40
pulse.Visible = false
pulse.Parent = pointerGui
UIKit.corner(pulse, 14)

local pulseStroke = Instance.new("UIStroke")
pulseStroke.Color = GOLD
pulseStroke.Thickness = 3
pulseStroke.Parent = pulse

local shell = plr.PlayerGui:WaitForChild("SealerShell", 20)

local function slotFor(word: string): GuiObject?
	local bar = if shell then shell:FindFirstChild("Hotbar") else nil

	if not bar or not (bar :: GuiObject).Visible then return nil end
	for _, slot in ipairs(bar:GetChildren()) do
		if slot:IsA("GuiObject") and slot.Visible then
			local cap = slot:FindFirstChild("ToolName", true)
			if cap and cap:IsA("TextLabel") and cap.Text:lower():find(word) then
				return slot
			end
		end
	end
	return nil
end

local function keyFor(word: string): string?
	local slot = slotFor(word)
	local digit = if slot then slot:FindFirstChild("Digit", true) else nil
	if digit and digit:IsA("TextLabel") and digit.Text ~= "" then return digit.Text end
	return nil
end

local function onScreen(g: GuiObject): boolean
	local node: Instance? = g
	while node and not node:IsA("ScreenGui") do
		if node:IsA("GuiObject") and not node.Visible then return false end
		node = node.Parent
	end
	return node ~= nil and (node :: ScreenGui).Enabled
end

local bladeRow: GuiObject? = nil
local bladeButton: GuiObject? = nil

local BLADE_RESCAN = 0.2
local bladeScanAt = 0

local function bladeBuyButton(): GuiObject?
	if not shell then return nil end

	local row = bladeRow
	if row then

		if row:IsDescendantOf(shell) and row.AbsoluteSize.X > 0 then
			if not onScreen(row) then return nil end
			local cached = bladeButton
			if cached and cached:IsDescendantOf(row) then return cached end

			for _, b in ipairs(row:GetDescendants()) do
				if b:IsA("TextButton") then
					bladeButton = b
					return b
				end
			end
			return nil
		end
		bladeRow, bladeButton = nil, nil
	end

	local now = os.clock()
	if now < bladeScanAt then return nil end
	bladeScanAt = now + BLADE_RESCAN

	for _, d in ipairs(shell:GetDescendants()) do
		if d:IsA("GuiObject") and d.Name == "Blade" and d.AbsoluteSize.X > 0 and onScreen(d) then
			bladeRow = d
			for _, b in ipairs(d:GetDescendants()) do
				if b:IsA("TextButton") then
					bladeButton = b
					return b
				end
			end
			return nil
		end
	end
	return nil
end

local RING_TIGHT, RING_WIDE = 5, 21

local function markControl(target: GuiObject?)
	if not target or target.AbsoluteSize.X == 0 then
		pulse.Visible = false
		return
	end
	pulse.Visible = true
	local k = 0.5 + 0.5 * math.sin(os.clock() * 4.2)
	local grow = RING_TIGHT + (RING_WIDE - RING_TIGHT) * k

	local p, s = target.AbsolutePosition, target.AbsoluteSize
	pulse.Position = UDim2.fromOffset(math.round(p.X - grow), math.round(p.Y - grow))
	pulse.Size = UDim2.fromOffset(math.round(s.X + grow * 2), math.round(s.Y + grow * 2))

	pulseStroke.Thickness = 2.6 + 3.4 * (1 - k)
	pulseStroke.Transparency = 0.45 * k
	pulse.BackgroundTransparency = 0.66 + 0.30 * k
end

local toastLane = if shell then shell:FindFirstChild("Toasts") else nil

local TOAST_HOME = if toastLane and toastLane:IsA("Frame")
	then toastLane.Position.Y.Offset
	else 24
local laneAt = TOAST_HOME

local function setToastLane(y: number)
	if not (toastLane and toastLane:IsA("Frame")) then return end
	if math.abs(laneAt - y) < 1 then return end
	laneAt = y
	toastLane.Position = UDim2.new(0.5, 0, 0, y)
end

local function laneBelowCard(): number
	return card.Position.Y.Offset + math.ceil(card.AbsoluteSize.Y) + 12
end

local function panelOpen(): boolean
	if not shell then return false end
	for _, c in ipairs(shell:GetChildren()) do
		if c.Name == "PanelHolder" and c:IsA("GuiObject") and c.Visible then return true end
	end
	return false
end

local arrived = false
local pouredOut = false
local sweptOnce = false

local refilled = false

local pourSpent = 0
local prevBucket: number? = nil

local fillGain = 0

local lastBucket = 1
local lastCoverage = 0

local stallSince: number? = nil

local lastLoose = 0
local lastLooseAt: Vector3? = nil

local finishedAt: number? = nil

export type Beat = {
	step: number,
	key: string,
	title: string,
	chips: { Chip }?,
	bar: number?,
	barCap: string?,
	spot: Vector3?,
	caption: string?,
	ringClose: boolean?,
	point: string?,
	glow: BasePart?,
	glowThrough: boolean?,
	arrowsOn: BasePart?,
	arrowsFrom: Vector3?,
	hint: string?,
	finale: boolean?,
	strongGuide: boolean?,
}

local funnelSent: { [number]: boolean } = {}
local funnelQueue: { number } = {}
local funnelRemote: RemoteEvent? = nil

task.spawn(function()
	local pack = ReplicatedStorage:WaitForChild("SealerUI", 30)
	local rem = pack and pack:WaitForChild("Remotes", 30)
	local r = rem and rem:WaitForChild("TutorialStep", 30)
	if not (r and r:IsA("RemoteEvent")) then return end
	funnelRemote = r
	for _, n in ipairs(funnelQueue) do r:FireServer(n) end
	table.clear(funnelQueue)
end)

local function funnel(step: number)
	if funnelSent[step] then return end
	funnelSent[step] = true
	local r = funnelRemote
	if r then r:FireServer(step) else table.insert(funnelQueue, step) end
end

local mapExitViewed = false
local mapPromptConnection: RBXScriptConnection? = nil

local function promptWorldPosition(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if not parent then return nil end
	if parent:IsA("Attachment") then return parent.WorldPosition end
	if parent:IsA("BasePart") then return parent.Position end
	if parent:IsA("Model") then return parent:GetPivot().Position end
	return nil
end

mapPromptConnection = ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who ~= plr or mapExitViewed then return end
	if plr:GetAttribute("TutorialDone") ~= true
		and plr:GetAttribute(DEPOT_ATTR) ~= true
		and plr:GetAttribute("TutBought") ~= true then
		return
	end

	local promptPos = promptWorldPosition(prompt)
	local target = mapExitSpot()
	if not promptPos or not target then return end

	local flat = Vector3.new(promptPos.X - target.X, 0, promptPos.Z - target.Z)
	if flat.Magnitude > 30 then return end

	mapExitViewed = true
end)

local function currentBeat(): Beat?

	-- TutBought is deliberately NOT one of these. A replay leaves it set (see
	-- TutorialReplay: everybody replaying has already bought the blade, and
	-- clearing it would strand them on a buy step they cannot pay for a second
	-- time), so counting it as "over" dropped a fresh replay straight onto the
	-- finale beat -- a gold trail to the map exit whose only route is through
	-- the bay door the same reset had just re-locked. The player was sealed in
	-- the lot with nothing left to do. Bought-but-not-sealed now falls through
	-- to the driveway beats below, which is exactly what such a player owes.
	if plr:GetAttribute("TutorialDone") == true
		or plr:GetAttribute(DEPOT_ATTR) == true then

		if not mapExitViewed and reachedMapExit() then
			mapExitViewed = true
		end
		if mapExitViewed then return nil end

		local gate = mapExitPart()
		local spot = mapExitSpot()

		if gate and spot then
			return {
				step = OBJECTIVES, key = "done", title = "THE MAP IS YOURS", finale = true,
				spot = spot, caption = "MAP EXIT", ringClose = true,
				glow = gate, glowThrough = true, strongGuide = true,
				hint = if Console.active() then "Press " .. Console.promptKey() .. " at the sign" else "Press E at the sign",
			}
		end

		if not finishedAt or os.clock() - finishedAt > HOLD_DONE then return nil end
		return { step = OBJECTIVES, key = "done", title = "THE MAP IS YOURS", finale = true }
	end

	local st = HudBus.latest
	local onOurs = st.name ~= nil and st.name == driveName()

	local b = st.bucket
	if b then

		if prevBucket and onOurs and b < prevBucket then
			pourSpent += prevBucket - b
		end

		if prevBucket and b > prevBucket then
			fillGain += b - prevBucket
		end
		prevBucket, lastBucket = b, b
	end
	if st.coverage and onOurs then lastCoverage = st.coverage end
	if st.loose and onOurs then
		lastLoose = st.loose
		lastLooseAt = st.looseAt
	end

	local finished = plr:GetAttribute("TutSealed") == true
	local upgraded = plr:GetAttribute("TutBought") == true
	local pail = Config.BucketCapacity

	local slabDone = lastCoverage >= Config.CompleteAt

	local bare = lastLoose <= pail * STALL_LOOSE
	if bare and not finished and not slabDone and lastBucket > PAIL_EMPTY then
		stallSince = stallSince or os.clock()
	else
		stallSince = nil
	end
	local stalled = stallSince ~= nil and os.clock() - stallSince >= STALL_PATIENCE
	local held = heldTool()
	local drive = drivewayPart()
	local hrp = rootPart()

	if not refilled then
		local toPump = if hrp then Depot.distanceToRefuel(hrp.Position) else nil
		local atPump = toPump ~= nil and toPump <= Config.FillReach
		if (not finished and fillGain >= FILL_SHARE)
			or (atPump and lastBucket >= FILL_FULL) then
			refilled = true
		end
	end

	if lastLoose > 0 or lastCoverage > 0 then arrived = true end
	if not arrived and hrp and drive then

		local dx = math.abs(hrp.Position.X - drive.Position.X) - drive.Size.X * 0.5
		local dz = math.abs(hrp.Position.Z - drive.Position.Z) - drive.Size.Z * 0.5
		if math.max(dx, 0) <= 6 and math.max(dz, 0) <= 6 then
			arrived = true
		end
	end

	if lastCoverage >= 0.08 or finished then
		arrived, pouredOut = true, true
	end
	if lastCoverage >= FIRST_PASS or finished then sweptOnce = true end

	local landedHere = pourSpent >= POUR_SHARE or lastLoose >= pail * 0.5
	if not pouredOut and landedHere and lastBucket <= PAIL_EMPTY then
		pouredOut = true
	end

	funnel(1)
	if arrived then funnel(2) end
	if pouredOut then funnel(3) end
	if sweptOnce then funnel(4) end

	if not arrived then
		return {
			step = 1, key = "walk", title = "GO TO THE FRONT PATH",
			chips = { chip({ keys = { "W", "A", "S", "D" }, note = "MOVE" },
				{ cap = "STICK", note = "MOVE" }) },
			spot = drivewaySpot(), caption = "SEAL THIS ONE",
			glow = drive, hint = "Follow the gold marker",
		}
	end

	if not pouredOut then

		if lastBucket <= PAIL_EMPTY then
			return {
				step = 2, key = "refill-pour", title = "FILL THE PAIL",
				chips = { chip({ cap = "E", note = "HOLD AT PUMP", hold = true },
					{ cap = "HOLD", note = "AT THE PUMP", hold = true }) },
				spot = refuelSpot(), caption = "REFILL",
				glow = pumpPart(), glowThrough = true,

				bar = lastBucket, barCap = "PAIL",
				hint = "Sealer comes from the depot",
			}
		end
		if held ~= "Sealer Bucket" then
			return {
				step = 2, key = "take-pail", title = "TAKE THE SEALER",
				chips = { chip({ cap = keyFor("bucket") or "1", note = "SEALER" },
					{ cap = "TAP", note = "SEALER" }) },
				point = "bucket", spot = drivewaySpot(), caption = "POUR HERE",
				glow = drive, hint = "It is in your toolbar",
			}
		end
		return {
			step = 2, key = "pour", title = "POUR IT ALL OUT",

			chips = { chip({ cap = "LMB", note = "HOLD TO POUR" },
				{ cap = "POUR", note = "ON / OFF" }) },

			bar = (1 - lastBucket) / (1 - PAIL_EMPTY), barCap = "PAIL",
			spot = drivewaySpot(), caption = "ONE BIG PUDDLE", ringClose = true,
			glow = drive, hint = "Keep tipping it out in ONE place until it is empty",
		}
	end

	if stalled then
		return {
			step = if sweptOnce then 4 else 3, key = "top-up", title = "EMPTY THE PAIL",
			chips = { chip({ cap = keyFor("bucket") or "1", note = "SEALER" },
				{ cap = "TAP", note = "SEALER" }),
				chip({ cap = "LMB", note = "HOLD TO POUR" },
				{ cap = "POUR", note = "ON / OFF" }) },
			bar = 1 - lastBucket, barCap = "PAIL",

			point = if held ~= "Sealer Bucket" then "bucket" else nil,
			spot = drivewaySpot(), caption = "POUR THE REST", ringClose = true,

			glow = drive, hint = "Pour what is left onto the slab",
		}
	end

	if not sweptOnce then
		if held ~= "Squeegee" then
			return {
				step = 3, key = "take-blade", title = "TAKE THE SQUEEGEE",
				chips = { chip({ cap = keyFor("squeegee") or "2", note = "SQUEEGEE" },
					{ cap = "TAP", note = "SQUEEGEE" }) },
				point = "squeegee", spot = lastLooseAt or drivewaySpot(),
				caption = "STAND IN IT", ringClose = true,
				glow = drive, hint = "Then go and stand in the sealer",
			}
		end

		local from = lastLooseAt or (drive and drive.Position) or Vector3.zero
		return {
			step = 3, key = "spread", title = "PUSH THE PUDDLE",

			chips = { chip({ cap = "LMB", note = "HOLD", hold = true },
				{ cap = "SPREAD", note = "ON / OFF" }),
				chip({ cap = "W", note = "UP AND BACK" },
				{ cap = "STICK", note = "UP AND BACK" }) },
			bar = lastCoverage / FIRST_PASS, barCap = "SPREAD",
			spot = from, caption = "STAND IN IT", ringClose = true,
			glow = drive, arrowsOn = drive, arrowsFrom = from,
			hint = "Stand in the sealer and drag it",
		}
	end

	if not finished then

		if lastBucket <= PAIL_EMPTY and bare then
			return {
				step = 4, key = "refill-finish", title = "FILL THE PAIL",
				chips = { chip({ cap = "E", note = "HOLD AT PUMP", hold = true },
					{ cap = "HOLD", note = "AT THE PUMP", hold = true }) },
				spot = refuelSpot(), caption = "REFILL",
				glow = pumpPart(), glowThrough = true,

				bar = lastBucket, barCap = "PAIL",
				hint = "Out of sealer -- top up, then finish the path",
			}
		end
		return {
			step = 4, key = "finish", title = "FINISH THE PATH",
			chips = { chip({ cap = "LMB", note = "HOLD", hold = true },
				{ cap = "SPREAD", note = "ON / OFF" }) },
			bar = lastCoverage / Config.CompleteAt, barCap = "COATED",
			spot = drivewaySpot(), caption = "KEEP GOING",
			glow = drive, hint = "Up and back -- overlap every pass",
		}
	end

	if not refilled and pumpPart() then
		return {
			step = OBJECTIVES, key = "learn-fill", title = "FILL THE PAIL",
			chips = { chip({ cap = "E", note = "HOLD AT PUMP", hold = true },
				{ cap = "HOLD", note = "AT THE PUMP", hold = true }) },

			bar = lastBucket, barCap = "PAIL",
			spot = refuelSpot(), caption = "REFILL", ringClose = true,
			glow = pumpPart(), glowThrough = true, strongGuide = true,
			hint = "Follow the gold trail",
		}
	end

	if not upgraded then
		return {
			step = 5, key = "buy", title = "BUY AN UPGRADE",
			chips = { chip({ cap = "E", note = "THE COUNTER" }, { cap = "TAP", note = "THE COUNTER" }) },
			point = "blade", spot = counterSpot(), caption = "UPGRADES", ringClose = true,
			glow = counterPart(), glowThrough = true, strongGuide = true,
			hint = "Follow the gold trail",
		}
	end

	local gate = mapExitPart()
	local spot = mapExitSpot()
	if gate and spot then
		return {
			step = OBJECTIVES, key = "done", title = "THE MAP IS YOURS", finale = true,
			spot = spot, caption = "GO TO MAP", ringClose = true,
			glow = gate, glowThrough = true, strongGuide = true,
			hint = "Follow the gold trail",
		}
	end
	return { step = OBJECTIVES, key = "opening", title = "THE MAP IS YOURS", finale = true }
end

if plr:GetAttribute("ProfileLoaded") ~= true then
	local t0 = os.clock()
	while plr.Parent
		and plr:GetAttribute("ProfileLoaded") ~= true
		and os.clock() - t0 < 20 do
		task.wait(0.1)
	end
end

if not plr.Parent then
	return
end

if plr:GetAttribute("ProfileLoaded") ~= true then
	if mapPromptConnection then
		mapPromptConnection:Disconnect()
		mapPromptConnection = nil
	end
	gui:Destroy()
	bannerGui:Destroy()
	if fx.Parent then fx:Destroy() end
	return
end

local alreadyDone = plr:GetAttribute("TutorialDone") == true
	or plr:GetAttribute(DEPOT_ATTR) == true

local loop: RBXScriptConnection? = nil
local function teardown()
	gui.Enabled = false
	bannerGui.Enabled = false
	pulse.Visible = false
	pointerGui.Enabled = false
	hideWorld()
	setToastLane(TOAST_HOME)
	if fx.Parent then fx:Destroy() end
	if loop then
		loop:Disconnect()
		loop = nil
	end
	if mapPromptConnection then
		mapPromptConnection:Disconnect()
		mapPromptConnection = nil
	end
end

if alreadyDone then
	teardown()
	return
end

plr:GetAttributeChangedSignal("TutSealed"):Connect(function()
	if plr:GetAttribute("TutSealed") then
		banner("DRIVEWAY COMPLETE!", LIME, 3.5)
	end
end)

local function markTutorialComplete()
	if finishedAt then return end
	if plr:GetAttribute("TutorialDone") == true
		or plr:GetAttribute(DEPOT_ATTR) == true
		or plr:GetAttribute("TutBought") == true then
		finishedAt = os.clock()
		banner("TUTORIAL COMPLETE!", GOLD, 4.0)
	end
end

plr:GetAttributeChangedSignal("TutorialDone"):Connect(markTutorialComplete)
plr:GetAttributeChangedSignal(DEPOT_ATTR):Connect(markTutorialComplete)
plr:GetAttributeChangedSignal("TutBought"):Connect(markTutorialComplete)

local BUSY_HOLD = 1.0
local IDLE_SOFT, IDLE_HARD = 5, 11

local runtime = {
	shownKey = nil :: string?,
	shownTitle = "",
	shownStep = 0,
	shownAt = 0,
	tickUntil = 0,
	busyUntil = 0,
	movedAt = os.clock(),
	lastWhere = nil :: Vector3?,
	lastBar = 0,
	lastHeld = nil :: string?,
}

loop = RunService.RenderStepped:Connect(function()
	local now = os.clock()

	if bannerGui.Enabled and now > bannerUntil then
		bannerGui.Enabled = false
	end

	local beat = currentBeat()
	if not beat then
		teardown()
		return
	end

	local hrp = rootPart()
	local where = if hrp then hrp.Position else nil
	local held = heldTool()
	local barNow = beat.bar or 0

	if where and (not runtime.lastWhere or (where - runtime.lastWhere).Magnitude > 2.5) then
		runtime.movedAt = now
		runtime.lastWhere = where
	end
	if barNow > runtime.lastBar + 0.004 then
		runtime.movedAt = now
		runtime.lastBar = barNow
	elseif barNow < runtime.lastBar - 0.05 then

		runtime.lastBar = barNow
	end
	if held ~= runtime.lastHeld then
		runtime.movedAt = now
		runtime.lastHeld = held
	end

	local idle = now - runtime.movedAt
	local urgent = idle >= IDLE_HARD

	if beat.key ~= runtime.shownKey then

		if runtime.shownKey and now - runtime.shownAt >= TICK_MIN and not beat.finale then
			runtime.tickUntil = now + TICK_HOLD
			SoundKit.play("Ding", nil, 0.04)
			pop(0.9)
		else

			runtime.tickUntil = 0
			runtime.shownTitle, runtime.shownStep = beat.title, beat.step
			pop()
		end
		runtime.shownKey, runtime.shownAt = beat.key, now
		runtime.movedAt = now
	end

	local ticking = now < runtime.tickUntil
	if not ticking and (runtime.shownTitle ~= beat.title or runtime.shownStep ~= beat.step) then

		runtime.shownTitle, runtime.shownStep = beat.title, beat.step
		pop()
	end

	if panelOpen() then
		gui.Enabled = false
		hideWorld()
		setToastLane(TOAST_HOME)

		if beat.point == "blade" then
			markControl(bladeBuyButton())
		else
			pulse.Visible = false
		end
		return
	end
	gui.Enabled = true

	if HudBus.latest.laying == true then runtime.busyUntil = now + BUSY_HOLD end
	local compact = now < runtime.busyUntil and not ticking and not beat.finale
	header.Visible = not compact
	card.BackgroundTransparency = if compact then 0.3 else 0
	cardStroke.Transparency = if compact then 0.3 else 0

	if beat.finale then
		crumb.Text = "TUTORIAL COMPLETE"
		crumb.TextColor3 = LIME
	else
		crumb.Text = ("TUTORIAL  %d / %d"):format(runtime.shownStep, OBJECTIVES)
		crumb.TextColor3 = GOLD
	end

	if ticking then
		title.Text = "\u{2713}  " .. runtime.shownTitle
		title.TextColor3 = LIME
		cardStroke.Color = LIME
		setChips(nil)
		barRow.Visible = false
		nudge.Visible = false
	else
		title.Text = beat.title
		title.TextColor3 = if beat.finale then LIME else CREAM
		cardStroke.Color = UIKit.Theme.ink
		setChips(if compact then nil else beat.chips)

		barRow.Visible = beat.bar ~= nil
		if beat.bar then
			local want = math.clamp(beat.bar, 0, 1)

			barShown = if want < barShown - 0.05 then want
				else barShown + (want - barShown) * 0.18
			barFill.Size = UDim2.new(math.clamp(barShown, 0, 1), 0, 1, 0)
			barFill.BackgroundColor3 = if barShown >= 0.999 then LIME else GOLD
			barCap.Text = ("%s  %d%%"):format(beat.barCap or "", math.floor(barShown * 100 + 0.5))
		end

		nudge.Visible = not compact and idle >= IDLE_SOFT and beat.hint ~= nil
		if nudge.Visible then
			nudge.Text = "\u{2192}  " .. (beat.hint or "")
			nudge.TextTransparency = if urgent then 0.15 * (0.5 + 0.5 * math.sin(now * 6)) else 0
		end
	end

	for i, p in ipairs(pips) do
		p.BackgroundColor3 = if i < beat.step then LIME
			elseif i == runtime.shownStep then GOLD
			else SLATE
	end

	place()
	setToastLane(laneBelowCard())

	local strongWorldGuide = urgent or beat.strongGuide == true
	if beat.spot then
		showWorld(beat.spot, beat.caption or "", where, beat.ringClose, strongWorldGuide)
	else
		hideWorld()
	end
	setGlow(beat.glow, beat.glowThrough == true, strongWorldGuide)

	if beat.arrowsOn and beat.arrowsFrom and not ticking then
		showArrows(beat.arrowsOn, beat.arrowsFrom,
			if hrp then hrp.CFrame.LookVector else nil, urgent)
	else
		hideArrows()
	end

	if beat.point == "bucket" then
		markControl(slotFor("bucket"))
	elseif beat.point == "squeegee" then
		markControl(slotFor("squeegee"))
	elseif beat.point == "blade" then

		markControl(bladeBuyButton())
	else
		pulse.Visible = false
	end
end)
