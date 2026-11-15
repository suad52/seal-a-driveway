local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer
local pack = RS:WaitForChild("BonusZones")
local State = require(pack.BonusState)
local Sections = require(RS.DrivewaySealer.Sections)
local Appearance = require(RS.DrivewaySealer.World1Appearance)
local ui = player:WaitForChild("PlayerGui"):WaitForChild("CollectiblesUI")
ui.Enabled = false
ui.ResetOnSpawn = false
ui.DisplayOrder = math.max(ui.DisplayOrder, 120)

--==[ on-screen text toasts for bonus zone rewards ]========================
-- replaces the system notification cards (StarterGui:SetCore) with plain
-- floating text the game draws itself
local toastGui = Instance.new("ScreenGui")
toastGui.Name = "BonusZoneToasts"
toastGui.ResetOnSpawn = false
toastGui.DisplayOrder = 130
toastGui.Parent = player.PlayerGui

local toastHolder = Instance.new("Frame")
toastHolder.Name = "Toasts"
toastHolder.AnchorPoint = Vector2.new(0.5, 0)
toastHolder.Position = UDim2.new(0.5, 0, 0, 60)
toastHolder.Size = UDim2.fromOffset(440, 220)
toastHolder.BackgroundTransparency = 1
toastHolder.Parent = toastGui

local toastLayout = Instance.new("UIListLayout")
toastLayout.Padding = UDim.new(0, 6)
toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
toastLayout.Parent = toastHolder

local TweenService = game:GetService("TweenService")
local function showZoneToast(mainText: string, foundName: string?)
	local label = Instance.new("TextLabel")
	label.Name = "Toast"
	label.BackgroundTransparency = 0.45
	label.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	label.Size = UDim2.new(1, 0, 0, foundName and 64 or 40)
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 20
	label.TextColor3 = Color3.fromRGB(255, 214, 92)
	label.RichText = true
	label.Text = foundName
		and (mainText .. "\n<font size=\"17\" color=\"#9ee7ff\"><b>You found: " .. foundName .. "</b></font>")
		or mainText
	label.TextWrapped = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	label.TextTransparency = 1
	label.BackgroundTransparency = 1
	label.Parent = toastHolder
	task.spawn(function()
		local ti = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(label, ti, {TextTransparency = 0, BackgroundTransparency = 0.45}):Play()
		task.wait(2.2)
		TweenService:Create(label, ti, {TextTransparency = 1, BackgroundTransparency = 1}):Play()
		task.wait(0.3)
		label:Destroy()
	end)
end

local panel = ui.Collectibles
panel.Visible = true
local close = panel.Main.CloseFrame.CloseButton
close.Activated:Connect(function() ui.Enabled = false end)
local content = panel.Main.InnerFrame.ContentFrame
local list = content.ScrollingFrame
local template = list:FindFirstChild("Template")
local cards = {}
local names = {"Battery","FishBones","Poop","Can","BrokenBottle","Banana Peel","Burger","Carton","EggContainer","BrokenMirror"}
local icons = {120920032183663,105785832295204,77136613848816,73952116010399,128428636891486,121209761073579,136213869501024,113116452094902,125756898308508,119042112450098}
for _, card in ipairs(list:GetChildren()) do
    if card:IsA("GuiObject") and card.Name == "Template" then
        local icon = card:FindFirstChildWhichIsA("ImageLabel", true)
        if icon then
            for index, asset in ipairs(icons) do
                if icon.Image:find(tostring(asset), 1, true) then cards[index] = {card = card, icon = icon} end
            end
        end
    end
end
local hammerGui = Instance.new("ScreenGui")
hammerGui.Name = "BonusHammerUI"
hammerGui.ResetOnSpawn = false
hammerGui.Enabled = false
ui.DisplayOrder = math.max(ui.DisplayOrder, 120)
hammerGui.Parent = player.PlayerGui
local equip = Instance.new("ImageButton")
equip.Image = "rbxassetid://104339650135000"
equip.Size = UDim2.fromOffset(68, 68)
equip.AnchorPoint = Vector2.new(1, 1)
equip.Position = UDim2.new(1, -20, 1, -18)
equip.BackgroundColor3 = Color3.fromRGB(4, 255, 0)
equip.Parent = hammerGui
local corner = Instance.new("UICorner", equip)
corner.CornerRadius = UDim.new(0, 14)
local function equipHammer()
    local tool = player.Backpack:FindFirstChild("BonusHammer")
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if tool and humanoid then humanoid:EquipTool(tool) end
end
equip.Activated:Connect(equipHammer)
UIS.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.Four or input.KeyCode == Enum.KeyCode.DPadRight then equipHammer() end
    if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then ui.Enabled = false end
end)
local hooked = setmetatable({}, {__mode = "k"})
local mouse = player:GetMouse()
local function hook(tool)
    if tool.Name ~= "BonusHammer" or hooked[tool] then return end
    hooked[tool] = true
    tool.Activated:Connect(function()
        local target = mouse.Target
        if tostring(UIS:GetLastInputType()):find("Gamepad") then
            local camera = workspace.CurrentCamera
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {player.Character}
            local ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
            local hit = workspace:Raycast(ray.Origin, ray.Direction * 100, params)
            target = hit and hit.Instance
        end
        local node = target
        while node and node ~= workspace do
            local id = node:GetAttribute("BonusObstacle")
            if id then
                pack.Remote:FireServer(node:GetAttribute("BonusZone"), id)
                return
            end
            node = node.Parent
        end
    end)
end
player.Backpack.ChildAdded:Connect(hook)
local function character(ch) ch.ChildAdded:Connect(hook); for _, tool in ipairs(ch:GetChildren()) do hook(tool) end end
player.CharacterAdded:Connect(character)
if player.Character then character(player.Character) end
for _, tool in ipairs(player.Backpack:GetChildren()) do hook(tool) end
local function cracks(object, hp, maximum)
    local part = object:IsA("BasePart") and object or object:FindFirstChildWhichIsA("BasePart", true)
    if not part then return end
    local gui = part:FindFirstChild("BonusCracks")
    if not gui then
        gui = Instance.new("SurfaceGui")
        gui.Name = "BonusCracks"
        gui.Face = Enum.NormalId.Front
        gui.CanvasSize = Vector2.new(256, 256)
        gui.Parent = part
        for index = 1, 7 do
            local line = Instance.new("Frame")
            line.Name = tostring(index)
            line.BorderSizePixel = 0
            line.BackgroundColor3 = Color3.fromRGB(35, 25, 20)
            line.Size = UDim2.fromOffset(3, 54)
            line.Position = UDim2.fromOffset(100 + (index % 3) * 17, 12 + index * 23)
            line.Rotation = index % 2 == 0 and 36 or -32
            line.Parent = gui
        end
    end
    gui.Enabled = hp > 0 and hp < maximum
    for _, line in ipairs(gui:GetChildren()) do
        line.Visible = tonumber(line.Name) <= math.ceil((1 - hp / maximum) * 7)
    end
end
local originals = setmetatable({}, {__mode = "k"})
local function show(root, visible)
    if not originals[root] then
        Appearance.prepare(root, visible)
        originals[root] = true
    else Appearance.show(root, visible) end
end
local function refresh()
    local data = State.read(player)
    local collected = 0
    for key in pairs(data.items) do collected += 1 end
    for index, card in pairs(cards) do
        if card.icon then card.icon.ImageTransparency = data.items[tostring(index)] and 0 or 0.7 end
    end
    local progress = content.Progress.Progress
    for _, label in ipairs(progress:GetDescendants()) do
        if label:IsA("TextLabel") and label.Text:match("%d+%s*/%s*%d+") then label.Text = collected .. "/30" end
    end
    local bar = progress:FindFirstChild("Bar") or progress:FindFirstChild("Fill")
    if bar and bar:IsA("GuiObject") then
        bar.AnchorPoint = Vector2.zero
        bar.Position = UDim2.fromScale(0, 0)
        bar.Size = UDim2.fromScale(math.clamp(collected / 30, 0, 1), 1)
    end
    for index = 1, 2 do
        local zone = workspace:FindFirstChild("BonusZone" .. index)
        if zone then
            local state = data.zones[tostring(index)]
            for _, object in ipairs(zone.TrashInAZone:GetChildren()) do
                local id = object:GetAttribute("BonusObstacle")
                if id then
                    local hp = state.hp[id] or object:GetAttribute("BonusMaxHP")
                    show(object, not state.destroyed[id])
                    cracks(object, hp, object:GetAttribute("BonusMaxHP"))
                    for _, label in ipairs(object:GetDescendants()) do
                        if label:IsA("TextLabel") and label.Text:match("%d+/%d+") then label.Text = math.max(0, hp) .. "/" .. object:GetAttribute("BonusMaxHP") end
                    end
                    local health = object:FindFirstChild("HealthBar", true)
                    local fill = health and health:FindFirstChild("Bar")
                    if fill and fill:IsA("GuiObject") then
                        for _, element in ipairs(health:GetDescendants()) do
                            if element.Name == "Back" then
                                if element:IsA("GuiObject") then element.Visible = false end
                                if element:IsA("UIGradient") then element.Enabled = false end
                            end
                        end
                        local foreground = fill:FindFirstChild("Main")
                        if foreground and foreground:IsA("GuiObject") then
                            local fraction = math.clamp(hp / object:GetAttribute("BonusMaxHP"), 0, 1)
                            local green = Color3.fromRGB(128, 244, 32)
                            local yellow = Color3.fromRGB(255, 211, 35)
                            local red = Color3.fromRGB(243, 55, 48)
                            local color = fraction >= 0.5 and yellow:Lerp(green, (fraction - 0.5) * 2)
                                or red:Lerp(yellow, fraction * 2)
                            foreground.BackgroundColor3 = color
                            for _, gradient in ipairs(foreground:GetChildren()) do
                                if gradient:IsA("UIGradient") then
                                    gradient.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.25), color)
                                end
                            end
                            foreground.AnchorPoint = Vector2.zero
                            foreground.Position = UDim2.fromScale(0, 0)
                            foreground.Size = UDim2.fromScale(math.clamp(hp / object:GetAttribute("BonusMaxHP"), 0, 1), 1)
                        end
                    end
                end
            end
            local roadsDone = true
            local sealed = Sections.nowSetOf(player)
            for _, item in ipairs(zone.Road:GetDescendants()) do
                if item:IsA("BasePart") and CS:HasTag(item, Sections.Tag)
                    and not sealed[Sections.keyOf(item)] then
                    roadsDone = false
                    break
                end
            end
            local restored = zone:FindFirstChild("RecoverPropsBonusZone" .. index)
            if restored then show(restored, roadsDone) end
            local broken = zone:FindFirstChild("BrokenPropsBonusZone" .. index)
            if broken then show(broken, not roadsDone) end
            local ordinaryTrash = zone:FindFirstChild("trash1")
            if ordinaryTrash then show(ordinaryTrash, not state.complete) end
        end
    end
end
player:GetAttributeChangedSignal("BonusState"):Connect(refresh)
player:GetAttributeChangedSignal("BonusActive"):Connect(function() equip.Visible = player:GetAttribute("BonusActive") ~= nil end)
pack.Remote.OnClientEvent:Connect(function(action, index, id, amount, drop)
    if action == "Hit" or action == "Destroyed" then
        local sound = Instance.new("Sound")
        sound.SoundId = action == "Hit" and "rbxassetid://180163738" or "rbxassetid://423041300"
        sound.Volume = 0.65
        sound.Parent = game:GetService("SoundService")
        sound:Play()
        Debris:AddItem(sound, 5)
    end
    if action == "Open" then
        ui.Enabled = true
        if UIS.GamepadEnabled then game:GetService("GuiService").SelectedObject = close end
    elseif action == "Destroyed" or action == "Fixed" then
        if action == "Fixed" or action == "Destroyed" then
            local fx = pack.Vfx.Fix:Clone()
            local zone = workspace["BonusZone" .. index]
            local origin = zone:GetAttribute("BonusCenter")
            if action == "Destroyed" then
                for _, obstacle in ipairs(zone.TrashInAZone:GetChildren()) do
                    if obstacle:GetAttribute("BonusObstacle") == id then
                        origin = obstacle:IsA("Model") and obstacle:GetPivot().Position or obstacle.Position
                        break
                    end
                end
            end
            fx.CFrame = CFrame.new(origin)
            fx.Anchored = true
            fx.CanCollide = false
            fx.Parent = workspace
            for _, emitter in ipairs(fx:GetDescendants()) do if emitter:IsA("ParticleEmitter") then emitter:Emit(30) end end
            Debris:AddItem(fx, 4)
        end
        if action == "Destroyed" and drop then
            local name = names[tonumber(drop)]
            local source = name and pack.Assets:FindFirstChild(name:gsub(" ", ""))
            local zone = workspace["BonusZone" .. index]
            local obstacle
            for _, item in ipairs(zone.TrashInAZone:GetChildren()) do if item:GetAttribute("BonusObstacle") == id then obstacle = item; break end end
            if source and obstacle then
                local pickup = source:Clone()
                for _, part in ipairs(pickup:GetDescendants()) do if part:IsA("BasePart") then part.Anchored = true; part.CanCollide = false; part.CanQuery = false end end
                local origin = obstacle:IsA("Model") and obstacle:GetPivot().Position or obstacle.Position
                pickup.Parent = workspace
                task.spawn(function()
                    for step = 1, 30 do
                        local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                        if not root then break end
                        local t = step / 30
                        pickup:PivotTo(CFrame.new(origin:Lerp(root.Position, t) + Vector3.new(0, math.sin(t * math.pi) * 4, 0)))
                        task.wait(0.025)
                    end
                    pickup:Destroy()
                end)
            end
        end
        local characterRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if characterRoot then
            local vfx = pack.Vfx.MoneyParticles:Clone()
            vfx.Parent = characterRoot
            for _, emitter in ipairs(vfx:GetDescendants()) do if emitter:IsA("ParticleEmitter") then emitter:Emit(15) end end
            Debris:AddItem(vfx, 3)
        end
        local text = action == "Fixed" and ("Yard restored! +$" .. tostring(id)) or ("+$" .. tostring(amount))
        local foundName = drop and names[tonumber(drop)] or nil
        showZoneToast(text, foundName)
    end
end)
workspace.DescendantAdded:Connect(function(item)
    if item:GetAttribute("BonusObstacle") then task.defer(refresh) end
end)
equip.Visible = false
refresh()





