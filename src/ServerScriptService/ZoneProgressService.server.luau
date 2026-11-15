local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local pack = RS:WaitForChild("ZoneProgress")
local State = require(pack.ZoneProgressState)
local Logic = require(pack.ZoneProgressLogic)
local Japan = require(pack.JapanRoadManifest)
local Sections = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local Pets = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Pets"))
local Halloween = require(RS.HalloweenShopState)
local remote = pack.Remote
local busy, dirty, cooldown = {}, {}, {}
local ids = {}
for _, section in ipairs(Sections.List) do table.insert(ids, section.id) end

local function save(player)
    local hook = SSS:FindFirstChild("GraveyardSave")
    if not hook then return false end
    local ok, result = pcall(function() return hook:Invoke(player) end)
    return ok and result == true
end

local function tell(player, message, asToast)
    if player.Parent then remote:FireClient(player, message, asToast) end
end

local function publish(player)
    local data = State.read(player)
    local sealed = Sections.sealedSetOf(player)
    for _, section in ipairs(Sections.List) do
        local slabs = Sections.slabsOf(section)
        local keys = {}
        for _, slab in ipairs(slabs) do table.insert(keys, Sections.keyOf(slab)) end
        local done, total = Logic.progress(keys, sealed)
        if data.worlds["1"][section.id] then done = total end
        player:SetAttribute("ZoneProgressDone_" .. section.id, done)
        player:SetAttribute("ZoneProgressTotal_" .. section.id, total)
        if total > 0 and done == total and not data.worlds["1"][section.id] then
            data.worlds["1"][section.id] = true
            dirty[player] = true
        end
    end
    local japanSealed = Sections.decode(player:GetAttribute("ZoneProgressWorld2Roads"))
    local japanIds = {}
    for id, keys in pairs(Japan) do
        table.insert(japanIds, id)
        local done, total = Logic.progress(keys, japanSealed)
        if total > 0 and done == total and not data.worlds["2"][id] then
            data.worlds["2"][id] = true
            dirty[player] = true
        end
    end
    State.write(player, data)
    player:SetAttribute("ZoneProgressWorld1", Logic.count(data.worlds["1"], ids))
    player:SetAttribute("ZoneProgressWorld2", Logic.count(data.worlds["2"], japanIds))
end

local function deliverHelper(player)
    local data = State.read(player)
    if data.claims["4"] ~= "pending" then return true end
    if not save(player) then return false end
    local ok, result = pcall(function()
        return require(SSS.RobotService).grantCredit(player, "ZoneProgress:World1:4:v1")
    end)
    if not ok or result ~= true then return false end
    data = State.read(player)
    data.claims["4"] = "claimed"
    State.write(player, data)
    dirty[player] = true
    return save(player)
end

remote.OnServerEvent:Connect(function(player, milestone)
    if player:GetAttribute("ProfileLoaded") ~= true or busy[player] then return end
    if type(milestone) ~= "number" then return end
    if os.clock() - (cooldown[player] or -10) < 1 then return end
    cooldown[player] = os.clock()
    publish(player)
    local data = State.read(player)
    if not Logic.eligible(data, milestone, Logic.count(data.worlds["1"], ids)) then return end
    busy[player] = true
    local ok, result = pcall(function()
        if milestone == 4 then
            data.claims["4"] = "pending"
            State.write(player, data)
            dirty[player] = true
            return deliverHelper(player)
        end
        if milestone == 2 then
            local inventory = Halloween.read(player)
            local grantId = "ZoneProgress:World1:2:v1"
            if not inventory.receipts[grantId] then
                inventory.receipts[grantId] = true
                inventory.coats += 1
                Halloween.write(player, inventory)
            end
        end
        if milestone == 6 then
            -- Final reward: the Bloom Tail pet for sealing every zone in World 1.
            -- Ownership is the PetsOwned attribute (CSV of pet ids), exactly like
            -- the future pet shop will write -- see the Pets catalogue.
            local set = Pets.ownedSet(player)
            if not set["BloomTail"] then
                set["BloomTail"] = true
                player:SetAttribute(Pets.OwnedAttr, Pets.serialise(set))
                print("[ZoneProgress] Granted BloomTail pet to", player.UserId)
            end
        end
        data.claims[tostring(milestone)] = "claimed"
        State.write(player, data)
        dirty[player] = true
        local saved = save(player)
        return saved
    end)
    busy[player] = nil
    if ok and result then
        dirty[player] = nil
        tell(player, milestone == 6 and "Bloom Tail pet added to your pet case! Your new pet is available through the Skins Menu." or "Reward added to your inventory!", milestone == 6)
    else
        tell(player, "Reward is pending. We will retry saving automatically.")
        if not ok then warn("[ZoneProgress] Claim:", result) end
    end
end)

local function join(player)
    local function refresh()
        if player:GetAttribute("ProfileLoaded") == true then publish(player) end
    end
    player:GetAttributeChangedSignal("ProfileLoaded"):Connect(refresh)
    player:GetAttributeChangedSignal(Sections.SealedAttr):Connect(refresh)
    task.defer(refresh)
end
Players.PlayerAdded:Connect(join)
for _, player in ipairs(Players:GetPlayers()) do join(player) end
Players.PlayerRemoving:Connect(function(player)
    dirty[player], busy[player], cooldown[player] = nil, nil, nil
end)
task.spawn(function()
    while task.wait(10) do
        for _, player in ipairs(Players:GetPlayers()) do
            if player:GetAttribute("ProfileLoaded") and not busy[player] then
                busy[player] = true
                local ok, err = pcall(function()
                    publish(player)
                    if State.read(player).claims["4"] == "pending" then deliverHelper(player) end
                    if dirty[player] and save(player) then dirty[player] = nil end
                end)
                busy[player] = nil
                if not ok then warn("[ZoneProgress] Retry:", err) end
            end
        end
    end
end)
