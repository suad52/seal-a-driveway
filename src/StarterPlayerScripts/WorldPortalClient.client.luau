local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local Sections = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local Config = require(RS:WaitForChild("WorldsConfig"))
local _, world = Config.resolve(game.PlaceId)
local portalName = if world == 1 then "PortalToWorld2" else "PortalToWorld1"
local active, label, noticeUntil = nil, nil, 0
local screen = Instance.new("ScreenGui")
screen.Name = "WorldTravelNotices"
screen.ResetOnSpawn = false
screen.DisplayOrder = 120
screen.Parent = player:WaitForChild("PlayerGui")
local toast = Instance.new("Frame")
toast.AnchorPoint = Vector2.new(0.5,0)
toast.Position = UDim2.fromScale(0.5,0.12)
toast.Size = UDim2.new(0.88,0,0,94)
toast.BackgroundColor3 = Color3.fromRGB(20,35,66)
toast.BorderSizePixel = 0
toast.Visible = false
toast.Parent = screen
local bounds = Instance.new("UISizeConstraint")
bounds.MaxSize = Vector2.new(540,94)
bounds.Parent = toast
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0,14)
corner.Parent = toast
local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = Color3.fromRGB(255,218,88)
stroke.Parent = toast
local text = Instance.new("TextLabel")
text.BackgroundTransparency = 1
text.Position = UDim2.fromOffset(14,10)
text.Size = UDim2.new(1,-28,1,-20)
text.Font = Enum.Font.FredokaOne
text.TextColor3 = Color3.fromRGB(255,242,199)
text.TextStrokeTransparency = 0.5
text.TextWrapped = true
text.TextScaled = true
text.Parent = toast
local textLimit = Instance.new("UITextSizeConstraint")
textLimit.MinTextSize = 12
textLimit.MaxTextSize = 22
textLimit.Parent = text
local noticeGeneration = 0
local function refresh()
	if not label or os.clock() < noticeUntil then return end
	if world == 2 then label.Text = "RETURN TO WORLD 1"; return end
	local done = player:GetAttribute(Sections.doneAttr("NewZone")) or 0
	local total = player:GetAttribute(Sections.totalAttr("NewZone")) or 0
	label.Text = if player:GetAttribute("WorldsCanTravel2") == true or (total > 0 and done >= total) then "TRAVEL TO WORLD 2" else string.format("WORLD 2 • %d ROADS LEFT", math.max(0,total-done))
end
local function bind(part)
	if part.Name ~= portalName or part.Parent ~= workspace or not part:IsA("BasePart") or active == part then return end
	active = part
	local gui = Instance.new("BillboardGui")
	gui.Name = "WorldPortalLabel"
	gui.Size = UDim2.fromOffset(360, 75)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
	gui.MaxDistance = 110
	gui.AlwaysOnTop = false
	gui.Parent = part
	label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1,1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.fromRGB(255,231,119)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = gui
	refresh()
end
workspace.ChildAdded:Connect(bind)
for _, item in ipairs(workspace:GetChildren()) do bind(item) end
player:GetAttributeChangedSignal(Sections.doneAttr("NewZone")):Connect(refresh)
player:GetAttributeChangedSignal(Sections.totalAttr("NewZone")):Connect(refresh)
player:GetAttributeChangedSignal("WorldsCanTravel2"):Connect(refresh)
RS:WaitForChild("WorldPortalStatus").OnClientEvent:Connect(function(message)
	noticeGeneration += 1
	local token = noticeGeneration
	text.Text = tostring(message)
	toast.Visible = true
	noticeUntil = os.clock() + 5
	if label then label.Text = tostring(message) end
	task.delay(5.1, function()
		if token ~= noticeGeneration then return end
		toast.Visible = false
		refresh()
	end)
end)
