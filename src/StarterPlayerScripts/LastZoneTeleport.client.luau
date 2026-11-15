local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local remote = ReplicatedStorage:WaitForChild("LastZoneTeleport")

local UIKit = require(
	ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("UIKit")
)

local gui = Instance.new("ScreenGui")
gui.Name = "LastZoneTeleportUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 25
gui.Parent = playerGui

local button = UIKit.chip(
	gui,
	"To the Last zone",
	172,
	Color3.fromRGB(91, 220, 112)
)

button.Name = "ToLastZone"
button.AnchorPoint = Vector2.zero
button.Visible = false
button.ClipsDescendants = false

local clickButton = button:WaitForChild("Cap")
local buttonLabel = clickButton:WaitForChild("Label")

clickButton.ClipsDescendants = false

local outline = clickButton:FindFirstChildOfClass("UIStroke")

if outline then
	outline.Color = Color3.fromRGB(12, 32, 53)
	outline.Thickness = 2.2
	outline.Transparency = 0
end

local function addGoldenOutline(name, thickness, transparency)
	local layer = Instance.new("Frame")
	layer.Name = name
	layer.AnchorPoint = Vector2.new(0.5, 0.5)
	layer.Position = UDim2.fromScale(0.5, 0.5)
	layer.Size = UDim2.new(1, 6, 1, 6)
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Active = false
	layer.ZIndex = math.max(1, clickButton.ZIndex - 1)
	layer.Parent = clickButton

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = layer

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.Parent = layer

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 210)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 239, 105)),
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(255, 207, 40)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 175, 20)),
	})
	gradient.Parent = stroke
end

addGoldenOutline("GoldGlowOuter", 8, 0.95)
addGoldenOutline("GoldGlowInner", 5, 0.85)
addGoldenOutline("GoldOutline", 2, 0.05)

local boundUpgrade
local connections = {}

local function disconnectLayout()
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end

	table.clear(connections)
end

local function bindUpgrade(item)
	if boundUpgrade or item.Name ~= "AffordableAlert" then
		return
	end

	local upgrade = item.Parent
	local area = upgrade and upgrade.Parent

	if not upgrade or not upgrade:IsA("GuiObject") then
		return
	end

	if not area or area.Name ~= "Area" then
		return
	end

	boundUpgrade = upgrade
	button.Parent = area

	local function position()
		button.Position = UDim2.new(
			upgrade.Position.X.Scale,
			upgrade.Position.X.Offset,
			upgrade.Position.Y.Scale + upgrade.Size.Y.Scale,
			upgrade.Position.Y.Offset + upgrade.Size.Y.Offset + 19
		)

		button.Visible = upgrade.Visible
	end

	table.insert(
		connections,
		upgrade:GetPropertyChangedSignal("Position"):Connect(position)
	)

	table.insert(
		connections,
		upgrade:GetPropertyChangedSignal("Size"):Connect(position)
	)

	table.insert(
		connections,
		upgrade:GetPropertyChangedSignal("Visible"):Connect(position)
	)

	table.insert(connections, upgrade.AncestryChanged:Connect(function()
		if not upgrade:IsDescendantOf(playerGui) then
			disconnectLayout()
			boundUpgrade = nil
			button.Visible = false
			button.Parent = gui
		end
	end))

	position()
end

playerGui.DescendantAdded:Connect(bindUpgrade)

for _, item in ipairs(playerGui:GetDescendants()) do
	bindUpgrade(item)
end

local generation = 0
local waiting = false

local function requestTeleport()
	if waiting then
		return
	end

	waiting = true
	generation += 1

	local token = generation
	buttonLabel.Text = "Teleporting..."
	remote:FireServer()

	task.delay(8, function()
		if generation == token then
			waiting = false
			buttonLabel.Text = "To the Last zone"
		end
	end)
end
clickButton.Activated:Connect(requestTeleport)
Console.registerAction("LastZone", requestTeleport)

remote.OnClientEvent:Connect(function(success, message)
	generation += 1
	local token = generation

	buttonLabel.Text = message

	task.delay(3, function()
		if generation == token then
			waiting = false
			buttonLabel.Text = "To the Last zone"
		end
	end)
end)