local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
local Pack = ReplicatedStorage:WaitForChild("SkipRoad")
local Templates = Pack:WaitForChild("Templates")
local Remote = Pack:WaitForChild("Remote")
local UIKit = require(ReplicatedStorage.SealerUI.UIKit)

local Gui = Instance.new("ScreenGui")
Gui.Name = "SkipRoadUI"
Gui.ResetOnSpawn = false
Gui.DisplayOrder = 80
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent = PlayerGui

local Instruction = Instance.new("TextLabel")
Instruction.Name = "ChooseRoad"
Instruction.AnchorPoint = Vector2.new(0.5, 0)
Instruction.Position = UDim2.new(0.5, 0, 0, 100)
Instruction.Size = UDim2.new(0.8, 0, 0, 48)
Instruction.BackgroundColor3 = Color3.fromRGB(25, 35, 65)
Instruction.BackgroundTransparency = 0.12
Instruction.TextColor3 = Color3.new(1, 1, 1)
Instruction.TextStrokeTransparency = 0
Instruction.Font = Enum.Font.FredokaOne
Instruction.TextScaled = true
Instruction.Text = "Stand on a road to skip"
Instruction.Visible = false
Instruction.Parent = Gui
UIKit.corner(Instruction, 12)

local textLimit = Instance.new("UITextSizeConstraint")
textLimit.MinTextSize = 14
textLimit.MaxTextSize = 28
textLimit.Parent = Instruction

local Details = Instruction:Clone()
Details.Name = "SelectedRoad"
Details.Position = UDim2.new(0.5, 0, 0, 152)
Details.Size = UDim2.new(0.8, 0, 0, 36)
Details.TextColor3 = Color3.fromRGB(255, 225, 105)
Details.Parent = Gui

local Confirm = Templates.ConfirmButton:Clone()
Confirm.Name = "SkipRoadConfirm"
Confirm.AnchorPoint = Vector2.new(0.5, 1)
Confirm.Position = UDim2.new(0.5, 0, 1, -145)
Confirm.Size = UDim2.fromOffset(240, 84)
Confirm.Visible = false
Confirm.Parent = Gui

local confirmScale = Confirm:FindFirstChildOfClass("UIScale") or Instance.new("UIScale", Confirm)
local ConfirmCap = Confirm:FindFirstChild("Cap")
local ConfirmLabel = ConfirmCap:FindFirstChild("Label")
ConfirmLabel.TextScaled = true
ConfirmCap.Selectable = true

local cancelSelection
local Cancel = UIKit.button(Gui, "CANCEL", UDim2.fromOffset(130, 38), Color3.fromRGB(220, 95, 115), function()
    if cancelSelection then
        cancelSelection()
    end
end)
Cancel.Name = "SkipRoadCancel"
Cancel.AnchorPoint = Vector2.new(0.5, 0)
Cancel.Position = UDim2.new(0.5, 0, 0, 196)
Cancel.Visible = false

local phase = "off"
local quote
local sequence = 0
local lastStandingQuery = -10
local highlights = {}
local hudArea
local hudButton
local hudLabel
local hudConnection
local hudText = "SKIP ROAD"

local function gamepad()
    return UserInputService:GetLastInputType().Name:find("Gamepad") ~= nil
end

local function clearHighlights()
    for _, highlight in ipairs(highlights) do
        highlight:Destroy()
    end

    table.clear(highlights)
end

local function refresh()
    local active = phase ~= "off"
    Instruction.Visible = active
    Details.Visible = active
    Cancel.Visible = active and phase ~= "buying"
    Confirm.Visible = phase == "quoted"
    ConfirmCap.Active = phase == "quoted"
    Player:SetAttribute("SkipRoadPicking", active)

    if hudLabel and hudLabel.Parent then
        hudLabel.Text = active and "CANCEL SKIP" or hudText
    end
end

local function stop()
    phase = "off"
    quote = nil
    sequence += 1
    clearHighlights()

    if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(Gui) then
        GuiService.SelectedObject = nil
    end

    refresh()
end

cancelSelection = function()
    if phase ~= "buying" then
        Remote:FireServer("Cancel")
        stop()
    end
end

local function choose()
    sequence += 1
    quote = nil
    phase = "choosing"
    clearHighlights()
    Instruction.Text = "Stand on a road to skip"
    Details.Text = "Checking the road beneath you..."
    GuiService.SelectedObject = nil
    refresh()
end

local function requestStanding()
    if phase ~= "choosing" and phase ~= "quoted" then
        return
    end

    lastStandingQuery = os.clock()
    Remote:FireServer("SelectStanding", sequence, quote and quote.token)
end

ConfirmCap.Activated:Connect(function()
    if phase ~= "quoted" or not quote then
        return
    end

    phase = "buying"
    Instruction.Text = "Opening purchase..."
    refresh()
    Remote:FireServer("Confirm", quote.token)
end)

Remote.OnClientEvent:Connect(function(action, data)
    if action == "Quote" then
        if phase == "off" or phase == "buying" or data.requestId ~= sequence then
            return
        end

        if phase == "quoted" and quote and quote.token == data.token then
            return
        end

        clearHighlights()
        quote = data
        phase = "quoted"
        local count = 0

        for _, part in pairs(data.parts or { data.slab }) do
            if typeof(part) == "Instance" and part:IsA("BasePart") then
                local highlight = Templates.Highlight:Clone()
                highlight.Name = "SkipRoadSelection"
                highlight.Adornee = part
                highlight.Enabled = true
                highlight.Parent = workspace
                table.insert(highlights, highlight)
                count += 1
            end
        end

        if count == 0 then
            Remote:FireServer("Cancel")
            choose()
            Details.Text = "The road is no longer visible. Choose it again."
            return
        end

        Instruction.Text = "Confirm the road beneath you"
        Details.Text = tostring(data.name) .. (data.credit and " • 1 SKIP CREDIT" or (" • R$ " .. data.price))

        if count > 1 then
            Details.Text ..= " • " .. count .. " parts"
        end

        ConfirmLabel.Text = data.credit and "USE CREDIT" or ("CONFIRM • R$ " .. data.price)
        refresh()

        if gamepad() then
            GuiService.SelectedObject = ConfirmCap
        end
    elseif action == "Error" then
        if phase ~= "off" then
            choose()
            Details.Text = tostring(data)
        end
    elseif action == "Saving" then
        if phase ~= "off" then
            phase = "buying"
            Instruction.Text = "Road complete — saving..."
            refresh()
        end
    elseif action == "Completed" then
        stop()
    elseif action == "Credit" then
        stop()
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "Skip Road",
                Text = "Skip credit restored for the R$ " .. tostring(data) .. " tier.",
                Duration = 6,
            })
        end)
    elseif action == "Cancelled" then
        if phase ~= "off" then
            choose()
        end
    end
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if phase == "off" then
        return
    end

    if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
        if phase ~= "buying" then
            Remote:FireServer("Cancel")
            stop()
        end
        return
    end

    if processed then
        return
    end

    if input.KeyCode == Enum.KeyCode.ButtonX then
        requestStanding()
    end
end)

UserInputService.LastInputTypeChanged:Connect(function()
    if phase == "quoted" and gamepad() then
        GuiService.SelectedObject = ConfirmCap
    end
end)

Player.CharacterAdded:Connect(stop)

RunService.RenderStepped:Connect(function()
    local camera = workspace.CurrentCamera

    if camera then
        confirmScale.Scale = math.min(1, math.max(0.65, camera.ViewportSize.Y / 650))
        local compact = camera.ViewportSize.Y < 500
        local short = camera.ViewportSize.Y < 360
        local top = short and 8 or compact and 14 or 100
        Instruction.Position = UDim2.new(0.5, 0, 0, top)
        Instruction.Size = UDim2.new(0.8, 0, 0, short and 36 or 48)
        Details.Position = UDim2.new(0.5, 0, 0, top + (short and 40 or 52))
        Details.Size = UDim2.new(0.8, 0, 0, short and 28 or 36)
        Cancel.Position = UDim2.new(0.5, 0, 0, top + (short and 72 or 96))
        Cancel.Size = UDim2.fromOffset(130, short and 32 or 38)
        Confirm.Position = UDim2.new(0.5, 0, 1, compact and -100 or -145)
    end

    if hudButton and hudButton.Parent and hudArea then
        local anchor = hudArea:FindFirstChild("ToLastZone")

        if anchor and anchor:IsA("GuiObject") then
            hudButton.AnchorPoint = Vector2.zero
            hudButton.Size = anchor.Size
            hudButton.Position = UDim2.new(
                anchor.Position.X.Scale - anchor.AnchorPoint.X * anchor.Size.X.Scale,
                anchor.Position.X.Offset - anchor.AnchorPoint.X * anchor.Size.X.Offset,
                anchor.Position.Y.Scale + (1 - anchor.AnchorPoint.Y) * anchor.Size.Y.Scale,
                anchor.Position.Y.Offset + (1 - anchor.AnchorPoint.Y) * anchor.Size.Y.Offset + 12
            )
        end
    end
end)

task.spawn(function()
    while Gui.Parent do
        local shell = PlayerGui:FindFirstChild("SealerShell")
        local area = shell and shell:FindFirstChild("Area")

        if area and (area ~= hudArea or not hudButton or not hudButton.Parent) then
            if hudConnection then
                hudConnection:Disconnect()
            end

            hudArea = area
            hudButton = area:FindFirstChild("SkipRoad")

            if not hudButton then
                hudButton = Templates.SkipRoad:Clone()
                hudButton.Name = "SkipRoad"
                hudButton.Parent = area
            end

            hudButton.Visible = true
            local cap = hudButton:FindFirstChild("Cap")
            hudLabel = cap and cap:FindFirstChild("Label")
            hudText = hudLabel and hudLabel.Text or "SKIP ROAD"

            if cap then
                hudConnection = cap.Activated:Connect(function()
                    if phase == "off" then
                        choose()
                        requestStanding()
                    elseif phase ~= "buying" then
                        Remote:FireServer("Cancel")
                        stop()
                    end
                end)
            end

            refresh()
        end

        if (phase == "choosing" or phase == "quoted") and os.clock() - lastStandingQuery >= 0.35 then
            requestStanding()
        end

        task.wait(0.2)
    end
end)

refresh()
