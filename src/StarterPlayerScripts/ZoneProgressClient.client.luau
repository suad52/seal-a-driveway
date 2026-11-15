local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Collection = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local pack = RS:WaitForChild("ZoneProgress")
local State = require(pack.ZoneProgressState)
local Sections = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local TopBand = require(RS:WaitForChild("SealerUI"):WaitForChild("TopBand"))
local Shell = require(RS:WaitForChild("SealerUI"):WaitForChild("Shell"))
local names = {
    Neighbourhood = "NEIGHBOURHOOD", EstateDistrict = "ESTATE DISTRICT",
    RetailPark = "RETAIL PARK", Airport = "AIRPORT",
    ParkingGarage = "PARKING GARAGE", NewZone = "DESERT CITY",
}
local gui = Instance.new("ScreenGui")
gui.Name = "ZoneProgressUI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 24
gui.Parent = playerGui

local function corner(parent, pixels)
    local item = Instance.new("UICorner")
    item.CornerRadius = UDim.new(0, pixels)
    item.Parent = parent
end

local frame = Instance.new("Frame")
frame.Name = "ZoneProgress"
frame.AnchorPoint = Vector2.new(0.5, 0)
frame.BackgroundColor3 = Color3.fromRGB(23, 48, 82)
frame.BorderSizePixel = 0
frame.Size = UDim2.fromOffset(380, 48)
frame.Visible = false
frame.Parent = gui
corner(frame, 14)
local stroke = Instance.new("UIStroke")
stroke.Thickness = 2
stroke.Color = Color3.fromRGB(8, 17, 31)
stroke.Parent = frame
local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 10, 0, 3)
title.Size = UDim2.new(1, -20, 0, 20)
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.Parent = frame
local track = Instance.new("Frame")
track.BackgroundColor3 = Color3.fromRGB(9, 26, 49)
track.Position = UDim2.new(0, 10, 0, 27)
track.Size = UDim2.new(1, -20, 0, 12)
track.BorderSizePixel = 0
track.Parent = frame
corner(track, 6)
local fill = Instance.new("Frame")
fill.BorderSizePixel = 0
fill.BackgroundColor3 = Color3.fromRGB(81, 239, 123)
fill.Size = UDim2.fromScale(0, 1)
fill.Parent = track
corner(fill, 6)
TopBand.claim("ZoneProgress", 1, frame, 48)
local currentId
local lastFraction = -1
local activeTween
local topMilestone
local topIcon = Instance.new("ImageLabel")
topIcon.Name = "MilestoneReward"
topIcon.BackgroundTransparency = 1
topIcon.Position = UDim2.new(1, -63, 0, 0)
topIcon.Size = UDim2.fromOffset(56, 30)
topIcon.ScaleType = Enum.ScaleType.Fit
topIcon.Parent = frame
local topClaim = Instance.new("TextButton")
topClaim.Name = "Claim"
topClaim.Position = UDim2.new(1, -63, 1, -18)
topClaim.Size = UDim2.fromOffset(56, 16)
topClaim.BackgroundColor3 = Color3.fromRGB(78, 205, 69)
topClaim.TextColor3 = Color3.new(1, 1, 1)
topClaim.Font = Enum.Font.FredokaOne
topClaim.TextScaled = true
topClaim.Parent = frame
corner(topClaim, 5)
topClaim.Activated:Connect(function()
    if topMilestone and topClaim.Active then
        topClaim.Active = false
        pack.Remote:FireServer(topMilestone)
    end
end)

local function rewardArt(name)
    local ui = playerGui:FindFirstChild("WorldUI")
    local card = ui and ui:FindFirstChild("World1", true)
    local progress = card and card:FindFirstChild("ProgressBar")
    local reward = progress and progress:FindFirstChild(name)
    return reward and reward.Image or ""
end

local function updateTop()
    if not currentId then frame.Visible = false; return end
    local done = player:GetAttribute("ZoneProgressDone_" .. currentId) or 0
    local total = player:GetAttribute("ZoneProgressTotal_" .. currentId) or 0
    frame.Visible = total > 0
    topMilestone = nil
    for index, section in ipairs(Sections.List) do
        if section.id == currentId and (index == 2 or index == 4 or index == 6) then
            topMilestone = index
        end
    end
    topIcon.Visible = topMilestone ~= nil
    topClaim.Visible = topMilestone ~= nil
    if topMilestone then
        topIcon.Image = topMilestone == 6 and "rbxassetid://96403103706999"
            or rewardArt(topMilestone == 2 and "InstantCoat" or "Helper")
        local status = State.read(player).claims[tostring(topMilestone)]
        local count = player:GetAttribute("ZoneProgressWorld1") or 0
        topClaim.Text = status == "claimed" and "CLAIMED" or status == "pending" and "PENDING" or count < topMilestone and "LOCKED" or "CLAIM"
        topClaim.Active = count >= topMilestone and status == nil and player:GetAttribute("ProfileLoaded") == true
        topClaim.Selectable = topClaim.Active
        topClaim.BackgroundColor3 = topClaim.Active and Color3.fromRGB(78, 205, 69) or Color3.fromRGB(72, 95, 88)
    end
    local reserved = topMilestone and 86 or 20
    title.Size = UDim2.new(1, -reserved, 0, 20)
    track.Size = UDim2.new(1, -reserved, 0, 12)
    title.Text = (names[currentId] or currentId) .. "  •  " .. done .. "/" .. total .. " ROADS"
    local fraction = total > 0 and math.clamp(done / total, 0, 1) or 0
    if fraction ~= lastFraction then
        lastFraction = fraction
        if activeTween then activeTween:Cancel() end
        activeTween = TweenService:Create(fill, TweenInfo.new(0.25), {Size = UDim2.fromScale(fraction, 1)})
        activeTween:Play()
    end
end

local bindings = setmetatable({}, {__mode = "k"})
local milestones = {InstantCoat = 2, Helper = 4, Pet = 6}
local function bindCard(card, world)
    local progress = card:FindFirstChild("ProgressBar")
    if not progress then return end
    local bar = progress:FindFirstChild("Bar")
    local label = progress:FindFirstChild("Text")
    local count = player:GetAttribute("ZoneProgressWorld" .. world) or 0
    local total = world == "1" and 6 or 5
    if bar then
        bar.AnchorPoint = Vector2.zero
        bar.Position = UDim2.fromScale(0, 0)
        bar.Size = UDim2.fromScale(math.clamp(count / total, 0, 1), 1)
        bar.Visible = count > 0
    end
    if label then
        label.Text = world == "1" and ("COMPLETED ZONES\n" .. count .. "/" .. total)
            or ("COMPLETED ZONES  " .. count .. "/" .. total)
    end
    local dividers = {}
    for _, child in ipairs(progress:GetChildren()) do
        if child.Name == "Divider" and child:IsA("GuiObject") then table.insert(dividers, child) end
    end
    for index, divider in ipairs(dividers) do
        divider.Visible = index < total
        divider.Position = UDim2.new(index / total, 0, 0, 0)
        divider.AnchorPoint = Vector2.new(0.5, 0)
    end
    if world ~= "1" then return end
    local data = State.read(player)
    for name, milestone in pairs(milestones) do
        local reward = progress:FindFirstChild(name)
        if reward then
            if name == "Pet" then reward.Image = "rbxassetid://96403103706999" end
            local button = reward:FindFirstChild("Claim")
            if button and button:IsA("GuiButton") then
                local status = data.claims[tostring(milestone)]
                local available = count >= milestone and status ~= "claimed" and status ~= "pending"
                local ready = player:GetAttribute("ProfileLoaded") == true
                button.Active = available and ready
                button.Selectable = button.Active
                local face = button:FindFirstChild("Face")
                if face then
                    face.Text = status == "claimed" and "CLAIMED" or status == "pending" and "PENDING" or "CLAIM"
                    face.TextTransparency = button.Active and 0 or 0.45
                end
                local lock = button:FindFirstChild("Lock")
                if lock then lock.Visible = count < milestone end
                if not bindings[button] then
                    bindings[button] = true
                    button.Activated:Connect(function()
                        if not button.Active then return end
                        button.Active = false
                        pack.Remote:FireServer(milestone)
                    end)
                end
            end
        end
    end
end

local function updateCards()
    local worlds = playerGui:FindFirstChild("WorldUI")
    if not worlds then return end
    local panel = worlds:FindFirstChild("Frame")
    panel = panel and panel:FindFirstChild("Panel")
    panel = panel and panel:FindFirstChild("InnerFrame")
    local list = panel and panel:FindFirstChild("ScrollingFrame")
    if not list then return end
    for _, world in ipairs({"1", "2"}) do
        local card = list:FindFirstChild("World" .. world)
        if card then bindCard(card, world) end
    end
end

player.AttributeChanged:Connect(function(name)
    if name:sub(1, 12) == "ZoneProgress" or name == "ProfileLoaded" then
        updateTop()
        updateCards()
    end
end)
pack.Remote.OnClientEvent:Connect(function(message, asToast)
    if asToast then
        -- the pet message rides the shell's own toast lane rather than Roblox's
        -- system notification, matching how the bundle purchase says it
        Shell.toast(tostring(message), true)
    else
        pcall(function()
            StarterGui:SetCore("SendNotification", {Title = "Zone Rewards", Text = message, Duration = 5})
        end)
    end
    updateCards()
end)

local function locate()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {character}
    local hit = workspace:Raycast(root.Position, Vector3.new(0, -100, 0), params)
    if hit then
        local section = Sections.sectionOfSlab(hit.Instance)
        if section then return section.id end
    end
    local best, distance = nil, 180
    for _, slab in ipairs(Collection:GetTagged(Sections.Tag)) do
        if slab:IsA("BasePart") and slab:IsDescendantOf(workspace) then
            local section = Sections.sectionOfSlab(slab)
            if section then
                local point = slab.CFrame:PointToObjectSpace(root.Position)
                local dx = math.max(0, math.abs(point.X) - slab.Size.X / 2)
                local dz = math.max(0, math.abs(point.Z) - slab.Size.Z / 2)
                local dy = math.max(0, math.abs(point.Y) - slab.Size.Y / 2)
                local score = math.sqrt(dx * dx + dz * dz + dy * dy)
                if score < distance then best, distance = section.id, score end
            end
        end
    end
    return best
end

task.spawn(function()
    while task.wait(0.5) do
        local camera = workspace.CurrentCamera
        if camera then frame.Size = UDim2.fromOffset(math.clamp(camera.ViewportSize.X * 0.35, 180, 380), 48) end
        currentId = locate()
        updateTop()
        updateCards()
    end
end)
