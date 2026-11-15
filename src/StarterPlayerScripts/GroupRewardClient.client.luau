-- GroupRewardClient -- handles the group reward GUI and button interactions.
--
-- ProximityPrompt trigger shows the RewardFrame. The GetRewardButton asks
-- the server to verify group membership and grant the reward. Failures flash
-- the button red and show a red notification.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Remote
local remotes = ReplicatedStorage.SealerUI:WaitForChild("Remotes")
local remote = remotes:WaitForChild("GroupReward")

-- GUI references
local groupRewardGui = playerGui:WaitForChild("GroupReward")
local rewardFrame = groupRewardGui:WaitForChild("RewardFrame")
local rewardPanel = rewardFrame:WaitForChild("RewardPanel")
local closeButton = rewardPanel.CloseFrame:WaitForChild("CloseButton")
local getRewardButton = rewardPanel.InnerFrame.ContentFrame.ButtonFrame:WaitForChild("GetRewardButton")

-- ProximityPrompt
local interactionPart = Workspace:WaitForChild("GroupReward"):WaitForChild("InteractionPart")
local proximityPrompt = interactionPart:WaitForChild("ProximityPrompt")

-- State
local isBusy = false

-- Show GUI on prompt trigger
proximityPrompt.Triggered:Connect(function()
	rewardFrame.Visible = true
end)

-- Close button hides the GUI
closeButton.Activated:Connect(function()
	rewardFrame.Visible = false
end)

-- Create a temporary notification label
local function showNotification(text: string, textColor: Color3, bgColor: Color3)
	local notif = Instance.new("TextLabel")
	notif.Name = "Notification"
	notif.Text = text
	notif.TextColor3 = textColor
	notif.BackgroundColor3 = bgColor
	notif.BackgroundTransparency = 0.15
	notif.Size = UDim2.new(0, 450, 0, 50)
	notif.Position = UDim2.new(0.5, -225, 0.12, 0)
	notif.Font = Enum.Font.GothamBold
	notif.TextSize = 16
	notif.TextWrapped = true
	notif.ZIndex = 100
	notif.Parent = groupRewardGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = notif

	notif.TextTransparency = 1
	notif.BackgroundTransparency = 1
	TweenService:Create(notif, TweenInfo.new(0.3), {
		TextTransparency = 0,
		BackgroundTransparency = 0.15,
	}):Play()

	task.delay(3, function()
		local tweenOut = TweenService:Create(notif, TweenInfo.new(0.5), {
			TextTransparency = 1,
			BackgroundTransparency = 1,
		})
		tweenOut:Play()
		tweenOut.Completed:Wait()
		notif:Destroy()
	end)
end

-- Flash the reward button red a few times
local function flashButtonRed()
	local originalColor = getRewardButton.BackgroundColor3
	local flashColor = Color3.fromRGB(255, 40, 40)

	for _ = 1, 3 do
		getRewardButton.BackgroundColor3 = flashColor
		task.wait(0.12)
		getRewardButton.BackgroundColor3 = originalColor
		task.wait(0.12)
	end
end

-- Handle reward button click
getRewardButton.Activated:Connect(function()
	if isBusy then return end
	isBusy = true
	remote:FireServer()
	-- Safety timeout in case the server never responds
	task.delay(5, function()
		isBusy = false
	end)
end)

-- Handle server response
remote.OnClientEvent:Connect(function(result: string)
	isBusy = false

	if result == "success" then
		rewardFrame.Visible = false
		showNotification(
			"Reward claimed! +50,000 Cash and Instant Coat boost!",
			Color3.fromRGB(50, 255, 80),
			Color3.fromRGB(20, 60, 30)
		)
	elseif result == "not_in_group" then
		flashButtonRed()
		showNotification(
			"You have not met all the requirements!",
			Color3.fromRGB(255, 60, 60),
			Color3.fromRGB(60, 10, 10)
		)
	elseif result == "already_claimed" then
		showNotification(
			"You have already claimed this reward!",
			Color3.fromRGB(255, 180, 60),
			Color3.fromRGB(60, 40, 10)
		)
	elseif result == "error" then
		showNotification(
			"Something went wrong. Please try again.",
			Color3.fromRGB(255, 60, 60),
			Color3.fromRGB(60, 10, 10)
		)
	end
end)