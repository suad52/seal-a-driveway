local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local Pack = ReplicatedStorage:WaitForChild("SkipZone")
local Config = require(Pack.SkipZoneConfig)
local State = require(Pack.SkipZoneState)
local Sections = require(ReplicatedStorage.DrivewaySealer.Sections)
local Remote = Pack:WaitForChild("Remote")

local Service = {}
local saveProfile
local profileReady
local started = false
local busy = {}
local prompting = {}
local cooldown = {}

local function tell(player, message)
    if player.Parent == Players then
        Remote:FireClient(player, "Message", message)
    end
end

local function ready(player)
    return player.Parent == Players
        and player:GetAttribute("ProfileLoaded") == true
        and profileReady ~= nil
        and profileReady(player) == true
end

local function save(player)
    if not ready(player) or not saveProfile then
        return false
    end

    local success, result = pcall(saveProfile, player)
    return success and result == true
end

local function slabsOf(zone)
    local container = workspace:FindFirstChild(zone.id)
    local slabs = {}

    if container then
        for _, slab in ipairs(CollectionService:GetTagged(Sections.Tag)) do
            if slab:IsA("BasePart") and slab:IsDescendantOf(container) then
                table.insert(slabs, slab)
            end
        end
    end

    return slabs
end

local function completeNow(player, zone)
    local slabs = slabsOf(zone)

    if #slabs == 0 then
        return false
    end

    local sealed = Sections.nowSetOf(player)

    for _, slab in ipairs(slabs) do
        if not sealed[Sections.keyOf(slab)] then
            return false
        end
    end

    return true
end

local function accessible(player, index)
    if index == 1 then
        return true
    end

    local previous = Config.Zones[index - 1]
    return player:GetAttribute(Sections.openAttr(previous.id)) == true
end

local function request(player, index)
    if not ready(player) or busy[player] or prompting[player] then
        return
    end

    if type(index) ~= "number" or index % 1 ~= 0 then
        return
    end

    local zone = Config.Zones[index]

    if not zone then
        return
    end

    local now = os.clock()

    if now - (cooldown[player] or -10) < 1 then
        return
    end

    cooldown[player] = now

    local signs = workspace:FindFirstChild("SkipZone")
    local sign = signs and signs:FindFirstChild(zone.sign)
    local main = sign and sign:FindFirstChild("Main")
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not main or not root or (root.Position - main.Position).Magnitude > Config.MaxDistance then
        tell(player, "Move closer to the Skip Zone sign.")
        return
    end

    if not accessible(player, index) then
        tell(player, "Open the previous zone first.")
        return
    end

    local state = State.read(player)

    if state.pending and state.pending.zone ~= index then
        tell(player, "Your previous Skip Zone purchase is still pending.")
        return
    end

    if not state.pending and completeNow(player, zone)
        and player:GetAttribute(Sections.openAttr(zone.id)) == true then
        tell(player, "This zone is already complete and open.")
        return
    end

    if #slabsOf(zone) == 0 then
        tell(player, "The zone is still loading. Please try again.")
        return
    end

    busy[player] = true

    if not state.pending then
        state.pending = {
            zone = index,
            token = HttpService:GenerateGUID(false),
            created = os.time(),
        }
        State.write(player, state)
    end

    if not save(player) then
        busy[player] = nil
        tell(player, "Could not save the purchase target. Please try again.")
        return
    end

    prompting[player] = true
    busy[player] = nil

    local success = pcall(function()
        MarketplaceService:PromptProductPurchase(player, Config.ProductId)
    end)

    if not success then
        prompting[player] = nil
        tell(player, "Could not open the purchase window. Please try again.")
    end
end

function Service.configure(saveFunction, readyFunction)
    saveProfile = saveFunction
    profileReady = readyFunction
end

function Service.isProduct(productId)
    return productId == Config.ProductId
end

function Service.receipt(info)
    local retry = Enum.ProductPurchaseDecision.NotProcessedYet
    local player = Players:GetPlayerByUserId(info.PlayerId)

    if not player or not ready(player) or busy[player] then
        return retry
    end

    busy[player] = true

    local success, decision = pcall(function()
        local state = State.read(player)
        local purchaseId = tostring(info.PurchaseId)

        if state.receipts[purchaseId] then
            if player:GetAttribute("SkipZoneGrantPending") == true and not save(player) then
                return retry
            end

            player:SetAttribute("SkipZoneGrantPending", false)

            if not state.pending then
                prompting[player] = nil
            end

            return Enum.ProductPurchaseDecision.PurchaseGranted
        end

        local pending = state.pending
        local zone = pending and Config.Zones[pending.zone]

        if not zone then
            warn("[SkipZone] Receipt has no saved target: " .. purchaseId)
            return retry
        end

        local slabs = slabsOf(zone)
        local sealRoad = ServerScriptService:FindFirstChild("SkipZoneSealRoad")

        if #slabs == 0 or not sealRoad then
            return retry
        end

        player:SetAttribute("SkipZoneGrantPending", true)

        for _, slab in ipairs(slabs) do
            if sealRoad:Invoke(player, slab) ~= true then
                return retry
            end
        end

        state.gates[zone.id] = true
        state.receipts[purchaseId] = zone.id
        state.pending = nil
        State.write(player, state)

        if zone.id == "NewZone" then
            player:SetAttribute("World2Unlocked", true)
        end

        if not save(player) then
            return retry
        end

        player:SetAttribute("SkipZoneGrantPending", false)
        prompting[player] = nil
        tell(player, zone.id == "NewZone"
            and "Desert City complete! World 2 is now available."
            or (zone.name .. " complete! The next zone is open."))

        return Enum.ProductPurchaseDecision.PurchaseGranted
    end)

    busy[player] = nil

    if not success then
        warn("[SkipZone] Receipt retry: " .. tostring(decision))
        return retry
    end

    return decision
end

function Service.start()
    if started then
        return
    end

    started = true
    Remote.OnServerEvent:Connect(function(player, action, index)
        if action == "Buy" then
            request(player, index)
        end
    end)

    local signs = workspace:WaitForChild("SkipZone")

    for index, zone in ipairs(Config.Zones) do
        local sign = signs:FindFirstChild(zone.sign)
        local main = sign and sign:FindFirstChild("Main")

        if main then
            local prompt = main:FindFirstChild("SkipZonePrompt") or Instance.new("ProximityPrompt")
            prompt.Name = "SkipZonePrompt"
            prompt.ActionText = "Skip Zone • R$ " .. Config.Price
            prompt.ObjectText = zone.name
            prompt.KeyboardKeyCode = Enum.KeyCode.E
            prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
            prompt.MaxActivationDistance = 18
            prompt.HoldDuration = 0
            prompt.RequiresLineOfSight = false
            prompt.Parent = main

            prompt.Triggered:Connect(function(player)
                request(player, index)
            end)
        end
    end

    MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
        if productId ~= Config.ProductId then
            return
        end

        local player = Players:GetPlayerByUserId(userId)

        if not player then
            return
        end

        if purchased then
            prompting[player] = State.read(player).pending ~= nil and true or nil
            return
        end

        prompting[player] = nil

        if busy[player] then
            return
        end

        busy[player] = true
        local state = State.read(player)
        state.pending = nil
        State.write(player, state)
        save(player)
        busy[player] = nil
    end)

    Players.PlayerRemoving:Connect(function(player)
        busy[player] = nil
        prompting[player] = nil
        cooldown[player] = nil
    end)
end

return Service
