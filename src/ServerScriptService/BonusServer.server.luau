local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local Collection = game:GetService("CollectionService")
local pack = RS:WaitForChild("BonusZones")
local State = require(pack.BonusState)
local Sections = require(RS.DrivewaySealer.Sections)
local Economy = require(RS.DrivewaySealer.Economy)
local remote = pack.Remote
local busy, lastHit, dirty = {}, {}, {}
local zones = {}
local random = Random.new()
local function count(set)
    local n = 0
    for _, value in pairs(set) do if value then n += 1 end end
    return n
end
local function multiplier(player, slab)
    return require(RS.SealerUI.Rebirth).multiplierOf(player)
        * require(RS.SealerUI.Passes).cashMultiplier(player)
        * require(RS.SealerUI.FriendBonus).multiplierOf(player)
        * require(RS.SealerUI.GoldenHour).cashMultiplier(player)
        * require(RS.DrivewaySealer.Lucky).multiplierFor(player, slab)
        * (player:GetAttribute("Pet_CashMult") or 1)
end
local function save(player)
    local hook = SSS:FindFirstChild("GraveyardSave")
    if not hook then return false end
    local ok, result = pcall(function() return hook:Invoke(player) end)
    if ok and result then dirty[player] = nil; return true end
    dirty[player] = true
    return false
end
for index = 1, 2 do
    local root = workspace:WaitForChild("BonusZone" .. index)
    local obstacles, roads = {}, {}
    for _, item in ipairs(root.TrashInAZone:GetChildren()) do
        if item:GetAttribute("BonusObstacle") then obstacles[item:GetAttribute("BonusObstacle")] = item end
    end
    for _, item in ipairs(root.Road:GetDescendants()) do
        if item:IsA("BasePart") and Collection:HasTag(item, Sections.Tag) then table.insert(roads, item) end
    end
    zones[index] = {root = root, obstacles = obstacles, roads = roads}
    local prompt = root.Pet.InteractionPart:FindFirstChild("BonusIndexPrompt") or Instance.new("ProximityPrompt")
    prompt.Name = "BonusIndexPrompt"
    prompt.ActionText = "Collectibles"
    prompt.ObjectText = "Wire Raccoon"
    prompt.RequiresLineOfSight = false
    prompt.MaxActivationDistance = 20
    prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
    prompt.Parent = root.Pet.InteractionPart
    prompt.Triggered:Connect(function(player) remote:FireClient(player, "Open") end)
end
local function inside(player, index)
    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local area = workspace:FindFirstChild("ZoneB" .. index)
    if not area then return false end
    local parts = area:IsA("BasePart") and {area} or area:GetDescendants()
    for _, part in ipairs(parts) do
        if part:IsA("BasePart") then
            local point = part.CFrame:PointToObjectSpace(root.Position)
            local half = part.Size / 2
            if math.abs(point.X) <= half.X and math.abs(point.Z) <= half.Z
                and math.abs(point.Y) <= half.Y + 5 then return true end
        end
    end
    return false
end
local function refresh(player)
    if not player:GetAttribute("ProfileLoaded") then return end
    local data = State.read(player)
    local sealed = Sections.nowSetOf(player)
    for index, zone in ipairs(zones) do
        local progress = data.zones[tostring(index)]
        local cleared = true
        for id in pairs(zone.obstacles) do if not progress.destroyed[id] then cleared = false; break end end
        player:SetAttribute("BonusClear_" .. index, cleared)
        local done = cleared
        for _, road in ipairs(zone.roads) do
            local key = Sections.keyOf(road)
            if sealed[key] then progress.roads[key] = true end
            if not progress.roads[key] then done = false end
        end
        if done and not progress.complete then
            progress.complete = true
            local reward = 0
            for _, road in ipairs(zone.roads) do reward += Economy.payout(road, 1, 0, multiplier(player, road)) end
            local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
            if cash then cash.Value += math.floor(reward * 1.3) end
            remote:FireClient(player, "Fixed", index, math.floor(reward * 1.3))
            dirty[player] = true
        end
        player:SetAttribute("BonusComplete_" .. index, progress.complete == true)
    end
    if count(data.items) >= 30 then
        local Pets = require(RS.DrivewaySealer.Pets)
        local owned = Pets.ownedSet(player)
        owned.WireRaccoon = true
        player:SetAttribute(Pets.OwnedAttr, Pets.serialise(owned))
        player:SetAttribute("BonusCollectionReward", true)
    end
    State.write(player, data)
end
remote.OnServerEvent:Connect(function(player, index, id)
    if not player:GetAttribute("ProfileLoaded") or busy[player] or dirty[player] then return end
    if type(index) ~= "number" or not zones[index] or type(id) ~= "string" then return end
    if os.clock() - (lastHit[player] or 0) < 0.35 then return end
    local object = zones[index].obstacles[id]
    local character = player.Character
    local hammer = character and character:FindFirstChild("BonusHammer")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not object or not hammer or not root or not inside(player, index) then return end
    local part = object:IsA("BasePart") and object or object:FindFirstChildWhichIsA("BasePart", true)
    if not part or (root.Position - part.Position).Magnitude > 22 then return end
    local ray = RaycastParams.new()
    ray.FilterType = Enum.RaycastFilterType.Exclude
    ray.FilterDescendantsInstances = {character}
    local hit = workspace:Raycast(root.Position, part.Position - root.Position, ray)
    if hit and hit.Instance ~= object and not hit.Instance:IsDescendantOf(object) then return end
    lastHit[player] = os.clock()
    local data = State.read(player)
    local progress = data.zones[tostring(index)]
    if progress.destroyed[id] then return end
    busy[player] = true
    if not next(progress.drops) then
        local candidates = {}
        for obstacleId in pairs(zones[index].obstacles) do table.insert(candidates, obstacleId) end
        for n = #candidates, 2, -1 do local other = random:NextInteger(1, n); candidates[n], candidates[other] = candidates[other], candidates[n] end
        for n = 1, 5 do progress.drops[candidates[n]] = tostring((index - 1) * 5 + n) end
    end
    local hp = (progress.hp[id] or object:GetAttribute("BonusMaxHP")) - 1
    progress.hp[id] = hp
    remote:FireClient(player, "Hit")
    if hp <= 0 then
        progress.destroyed[id] = true
        local drop = progress.drops[id]
        if drop then data.items[drop] = true end
        local amount = math.floor(1000 * multiplier(player, zones[index].roads[1]))
        local cash = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Cash")
        if cash then cash.Value += amount end
        remote:FireClient(player, "Destroyed", index, id, amount, drop)
        dirty[player] = true
    end
    State.write(player, data)
    refresh(player)
    if dirty[player] then save(player) end
    busy[player] = nil
end)
local function join(player)
    player:GetAttributeChangedSignal("ProfileLoaded"):Connect(function() refresh(player) end)
    player:GetAttributeChangedSignal(Sections.NowAttr):Connect(function() refresh(player) end)
    task.spawn(function()
        while player.Parent do
            task.wait(0.5)
            local active
            for index in ipairs(zones) do if inside(player, index) then active = index; break end end
            player:SetAttribute("BonusActive", active)
            local bag = player:FindFirstChild("Backpack")
            local tool = bag and bag:FindFirstChild("BonusHammer") or player.Character and player.Character:FindFirstChild("BonusHammer")
            if active and bag and not tool then
                tool = pack.Hammer:Clone()
                tool.Name = "BonusHammer"
                tool.TextureId = "rbxassetid://104339650135000"
                tool.CanBeDropped = false
                for _, part in ipairs(tool:GetDescendants()) do
                    if part:IsA("BasePart") then part.Anchored = false; part.CanCollide = false; part.Massless = true end
                end
                tool.Parent = bag
                local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                if humanoid then humanoid:EquipTool(tool) end
            elseif not active and tool then tool:Destroy() end
            if active and tool and bag and tool.Parent == bag and player:GetAttribute("BonusClear_" .. active) ~= true then
                local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
                if humanoid then humanoid:EquipTool(tool) end
            end
        end
    end)
    task.defer(refresh, player)
end
Players.PlayerAdded:Connect(join)
for _, player in ipairs(Players:GetPlayers()) do join(player) end
Players.PlayerRemoving:Connect(function(player) busy[player], dirty[player], lastHit[player] = nil, nil, nil end)
task.spawn(function()
    while task.wait(10) do
        for _, player in ipairs(Players:GetPlayers()) do if dirty[player] and not busy[player] then save(player) end end
    end
end)


