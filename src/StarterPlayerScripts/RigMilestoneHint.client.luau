local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local plr = Players.LocalPlayer
local Sealer = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Rigs = require(Sealer:WaitForChild("Rigs"))

local cheapest = Rigs.cheapest()
local TRIGGER_CASH = math.max(250000, cheapest.price)

local GOLD = Color3.fromRGB(255, 214, 92)
local CREAM = Color3.fromRGB(236, 233, 222)
local NAVY = Color3.fromRGB(38, 44, 56)

local function cashValue(): number
	local leaderstats = plr:FindFirstChild("leaderstats")
	local cash = leaderstats and leaderstats:FindFirstChild("Cash")
	return if cash and cash:IsA("IntValue") then cash.Value else 0
end

local function rootPart(): BasePart?
	local character = plr.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function targetPart(): BasePart?
	local hall = workspace:FindFirstChild("RigDealership")
	local totems = hall and hall:FindFirstChild("Totems")
	local target = totems and totems:FindFirstChild("NamePlate_Dart")

	if target and target:IsA("BasePart") then
		return target
	end
	if target and target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
	end
	return if target then target:FindFirstChildWhichIsA("BasePart", true) else nil
end

local function target(): (Vector3?, Instance?, string)
	local part = targetPart()
	if not part then return nil, nil, "" end

	-- The arrow names the Dart totem, but the ring belongs on the floor below it.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { part }
	local ray = workspace:Raycast(
		part.Position + Vector3.new(0, 12, 0),
		Vector3.new(0, -50, 0),
		params
	)
	local spot = if ray
		then ray.Position + Vector3.new(0, 0.15, 0)
		else Vector3.new(part.Position.X, part.Position.Y - part.Size.Y * 0.5 + 0.15, part.Position.Z)

	return spot, part, cheapest.name:upper()
end

local gui = Instance.new("ScreenGui")
gui.Name = "RigMilestoneHint"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 28
gui.Parent = plr:WaitForChild("PlayerGui")

local card = Instance.new("Frame")
card.AnchorPoint = Vector2.new(0.5, 0)
card.Position = UDim2.new(0.5, 0, 0, 24)
card.Size = UDim2.fromOffset(430, 58)
card.BackgroundColor3 = NAVY
card.BorderSizePixel = 0
card.Visible = false
card.ZIndex = 30
card.Parent = gui

local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0, 14)
cardCorner.Parent = card

local cardStroke = Instance.new("UIStroke")
cardStroke.Color = GOLD
cardStroke.Thickness = 3
cardStroke.Parent = card

local text = Instance.new("TextLabel")
text.BackgroundTransparency = 1
text.Position = UDim2.fromOffset(12, 0)
text.Size = UDim2.new(1, -24, 1, 0)
text.Font = Enum.Font.GothamBold
text.Text = "You can buy sealcoat rig!"
text.TextSize = 24
text.TextColor3 = CREAM
text.TextXAlignment = Enum.TextXAlignment.Center
text.TextYAlignment = Enum.TextYAlignment.Center
text.ZIndex = 31
text.Parent = card

local cardScale = Instance.new("UIScale")
cardScale.Parent = card

local fx = Instance.new("Folder")
fx.Name = "RigMilestoneFX"
fx.Parent = workspace

local function makePart(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = GOLD
	p.Size = size
	p.Transparency = 1
	p.Parent = fx
	return p
end

local ring = makePart("TargetRing", Vector3.new(0.35, 13, 13))
ring.Shape = Enum.PartType.Cylinder

local DASHES = 14
local dashes: { Part } = {}
for i = 1, DASHES do
	dashes[i] = makePart("Guide", Vector3.new(4.2, 0.18, 1.55))
end

local anchor = makePart("MarkerAnchor", Vector3.new(0.2, 0.2, 0.2))
anchor.Transparency = 1

local billboard = Instance.new("BillboardGui")
billboard.Name = "Marker"
billboard.Size = UDim2.fromOffset(250, 126)
billboard.AlwaysOnTop = true
billboard.Enabled = false
billboard.Parent = anchor

local caption = Instance.new("TextLabel")
caption.BackgroundTransparency = 1
caption.Size = UDim2.new(1, 0, 0, 42)
caption.Font = Enum.Font.GothamBold
caption.TextSize = 24
caption.TextColor3 = CREAM
caption.TextStrokeColor3 = Color3.new(0, 0, 0)
caption.TextStrokeTransparency = 0
caption.TextXAlignment = Enum.TextXAlignment.Center
caption.ZIndex = 2
caption.Parent = billboard

local arrow = Instance.new("TextLabel")
arrow.BackgroundTransparency = 1
arrow.Position = UDim2.fromOffset(0, 38)
arrow.Size = UDim2.new(1, 0, 0, 78)
arrow.Font = Enum.Font.GothamBold
arrow.Text = "▼"
arrow.TextSize = 82
arrow.TextColor3 = GOLD
arrow.TextStrokeColor3 = Color3.new(0, 0, 0)
arrow.TextStrokeTransparency = 0
arrow.TextXAlignment = Enum.TextXAlignment.Center
arrow.ZIndex = 2
arrow.Parent = billboard

local highlight = Instance.new("Highlight")
highlight.FillColor = GOLD
highlight.FillTransparency = 0.78
highlight.OutlineColor = GOLD
highlight.OutlineTransparency = 0
highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
highlight.Enabled = false
highlight.Parent = fx

local active = false
local announced = false
local hintUntil = 0
local nextCheck = 0

local function hideGuide()
	billboard.Enabled = false
	ring.Transparency = 1
	highlight.Enabled = false
	for _, dash in ipairs(dashes) do dash.Transparency = 1 end
end

local function showHint()
	if announced then return end
	announced = true
	hintUntil = os.clock() + 5
	card.Visible = true
	cardScale.Scale = 0.82
	TweenService:Create(cardScale,
		TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end
local function finishMenuHint()
	if plr:GetAttribute("RigMenuVisited") ~= true then
		return
	end

	active = false
	announced = true
	card.Visible = false
	hideGuide()
end

plr:GetAttributeChangedSignal("RigMenuVisited"):Connect(finishMenuHint)
finishMenuHint()
RunService.RenderStepped:Connect(function()
	local now = os.clock()

	if card.Visible and now >= hintUntil then
		card.Visible = false
	end

	if now >= nextCheck then
		nextCheck = now + 0.25
		active = plr:GetAttribute("RigMenuVisited") ~= true
			and plr:GetAttribute("DepotSealed") == true
			and not Rigs.owns(plr, cheapest.id)
			and cashValue() >= TRIGGER_CASH

		if active then showHint() end
	end

	if not active then
		hideGuide()
		return
	end

	local root = rootPart()
	local spot, adorn, label = target()
	if not root or not spot then
		hideGuide()
		return
	end

	billboard.Enabled = true
	caption.Text = label

	local bob = math.sin(now * 3.5) * 0.6
	anchor.CFrame = CFrame.new(spot + Vector3.new(0, 8 + bob, 0))
	arrow.TextSize = 82 + math.floor(14 * (0.5 + 0.5 * math.sin(now * 5)))

	highlight.Adornee = adorn
	highlight.Enabled = adorn ~= nil

	local delta = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
	local distance = delta.Magnitude

	ring.Transparency = 0.10 + 0.12 * (0.5 + 0.5 * math.sin(now * 4))
	ring.CFrame = CFrame.new(spot.X, spot.Y - 0.25, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
	local pulse = 12 + math.sin(now * 4) * 1.5
	ring.Size = Vector3.new(0.35, pulse, pulse)

	if distance < 4 then
		for _, dash in ipairs(dashes) do dash.Transparency = 1 end
		return
	end

	local dir = delta.Unit
	local slide = (now * 0.9) % 1
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { plr.Character, fx }

	for i, dash in ipairs(dashes) do
		local f = ((i - 1) / DASHES + slide) % 1
		local p = root.Position + dir * (5 + f * math.max(1, distance - 8))
		local ray = workspace:Raycast(p + Vector3.new(0, 15, 0), Vector3.new(0, -45, 0), params)
		local y = if ray then ray.Position.Y + 0.14 else p.Y
		local foot = Vector3.new(p.X, y, p.Z)
		dash.CFrame = CFrame.lookAt(foot, foot + dir)
		dash.Transparency = 0.03 + 0.24 * math.abs(f - 0.5)
	end
end)