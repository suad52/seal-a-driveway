local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Pack = ReplicatedStorage:WaitForChild("SkipZone")
local Config = require(Pack.SkipZoneConfig)
local Remote = Pack:WaitForChild("Remote")
local Bound = {}

local function bind(source)
    if not source:IsA("SurfaceGui") or Bound[source] then
        return
    end

    local main = source.Parent
    local sign = main and main.Parent
    local folder = sign and sign.Parent

    if not main or main.Name ~= "Main" or not folder or folder ~= workspace:FindFirstChild("SkipZone") then
        return
    end

    local index

    for number, zone in ipairs(Config.Zones) do
        if sign.Name == zone.sign then
            index = number
            break
        end
    end

    if not index then
        return
    end

    local name = "SkipZoneSignUI_" .. index
    local previous = PlayerGui:FindFirstChild(name)

    if previous then
        previous:Destroy()
    end

    local gui = source:Clone()

    for _, descendant in ipairs(gui:GetDescendants()) do
        if descendant:IsA("LuaSourceContainer") then
            descendant:Destroy()
        end
    end

    gui.Name = name
    gui.Adornee = main
    gui.Enabled = true
    gui.Active = true
    gui.ResetOnSpawn = false
    gui.MaxDistance = 65
    gui.Parent = PlayerGui

    local button = gui:FindFirstChildWhichIsA("TextButton", true)

    if not button then
        gui:Destroy()
        return
    end

    source.Enabled = false
    Bound[source] = gui
    button.Text = ""
    button.Active = true
    button.Selectable = true

    local label = button:FindFirstChildWhichIsA("TextLabel", true)

    if label then
        label.Text = "SKIP ZONE\nR$ " .. Config.Price
        label.TextScaled = true
    else
        button.Text = "SKIP ZONE\nR$ " .. Config.Price
        button.TextScaled = true
    end

    button.Activated:Connect(function()
        Remote:FireServer("Buy", index)
    end)

    source.AncestryChanged:Connect(function()
        if not source:IsDescendantOf(workspace) then
            gui:Destroy()
            Bound[source] = nil
        end
    end)
end

for _, descendant in ipairs(workspace:GetDescendants()) do
    bind(descendant)
end

workspace.DescendantAdded:Connect(function(descendant)
    local source = descendant:IsA("SurfaceGui")
        and descendant
        or descendant:FindFirstAncestorWhichIsA("SurfaceGui")

    if source then
        task.defer(bind, source)
    end
end)

Remote.OnClientEvent:Connect(function(action, message)
    if action == "Message" then
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "Skip Zone",
                Text = message,
                Duration = 6,
            })
        end)
    end
end)
