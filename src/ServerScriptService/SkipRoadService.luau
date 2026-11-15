local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Pack = ReplicatedStorage:WaitForChild("SkipRoad")
local Config = require(Pack.SkipRoadConfig)
local State = require(Pack.SkipRoadState)
local Sections = require(ReplicatedStorage.DrivewaySealer.Sections)
local SurfaceFrame = require(ReplicatedStorage.DrivewaySealer.SurfaceFrame)
local Remote = Pack:WaitForChild("Remote")

local Service = {}
local saveProfile
local profileReady
local quotes = {}
local busy = {}
local prompting = {}
local lastSelect = {}
local pendingTargets = {}
local started = false

local function send(player, action, value)
    if player.Parent == Players then
        Remote:FireClient(player, action, value)
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

local function validRoad(slab)
    return typeof(slab) == "Instance"
        and slab:IsA("BasePart")
        and slab:IsDescendantOf(workspace)
        and CollectionService:HasTag(slab, Sections.Tag)
        and Sections.sectionOfSlab(slab) ~= nil
end

local function accessible(player, slab)
    for _, name in ipairs(Sections.reachableGround(function(id)
        return player:GetAttribute(Sections.openAttr(id)) == true
    end)) do
        local container = workspace:FindFirstChild(name)

        if container and slab:IsDescendantOf(container) then
            return true
        end
    end

    return false
end

local function standingRoad(player)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if not root or not humanoid or humanoid.SeatPart or humanoid.Sit then
        return nil
    end

    local excluded = { character }

    for _, name in ipairs({ "SealerVisuals", "SharedPumpkinVisuals" }) do
        local object = workspace:FindFirstChild(name)

        if object then
            table.insert(excluded, object)
        end
    end

    local feet = math.max(3, humanoid.HipHeight + root.Size.Y * 0.5)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = excluded
    params.IgnoreWater = true

    local hit = workspace:Raycast(
        root.Position + Vector3.new(0, 1, 0),
        Vector3.new(0, -(feet + 4), 0),
        params
    )

    if not hit then
        return nil
    end

    if not validRoad(hit.Instance) then
        local beneath = RaycastParams.new()
        beneath.FilterType = Enum.RaycastFilterType.Include
        beneath.FilterDescendantsInstances = CollectionService:GetTagged(Sections.Tag)
        beneath.IgnoreWater = true
        hit = workspace:Raycast(hit.Position + Vector3.new(0, 0.1, 0), Vector3.new(0, -2.25, 0), beneath)
    end

    if not hit or not validRoad(hit.Instance) or hit.Normal.Y < 0.45 then
        return nil
    end

    if math.abs(root.Position.Y - hit.Position.Y) > feet + 2 then
        return nil
    end

    return hit.Instance
end

local function finished(player, slab)
    return Sections.nowSetOf(player)[Sections.keyOf(slab)] == true
end

local function linkedParts(slab)
    local key = Sections.keyOf(slab)
    local parts = {}

    for _, part in ipairs(CollectionService:GetTagged(Sections.Tag)) do
        if validRoad(part) and Sections.keyOf(part) == key then
            table.insert(parts, part)
        end
    end

    return parts
end

local function reject(player, message)
    quotes[player] = nil
    send(player, "Error", message)
end

local function selectRoad(player, requestId, knownToken)
    if not ready(player) then
        reject(player, "Still loading your save. Please try again.")
        return
    end

    if busy[player] or prompting[player] then
        return
    end

    local now = os.clock()

    if now - (lastSelect[player] or -10) < 0.1 then
        return
    end

    lastSelect[player] = now

    local slab = standingRoad(player)

    if not slab then
        reject(player, "Stand on an unfinished road to skip.")
        return
    end

    if not validRoad(slab) or not accessible(player, slab) then
        reject(player, "This road is in a locked zone.")
        return
    end

    if finished(player, slab) then
        reject(player, "This road is already complete.")
        return
    end

    local state = State.read(player)
    local key = Sections.keyOf(slab)

    if state.pending and (state.pending.key ~= key or state.pending.world ~= Config.World) then
        reject(player, "Your previous Skip Road purchase is still pending.")
        return
    end

    local _, size = SurfaceFrame.of(slab)
    local tier, area = Config.tierOf(slab, size)
    local previous = quotes[player]
    local credit = state.credits[tostring(tier)] > 0
    local token = previous and previous.slab == slab and previous.tier == tier and previous.credit == credit
        and previous.token or HttpService:GenerateGUID(false)
    local quote = {
        slab = slab,
        key = key,
        tier = tier,
        token = token,
        expires = now + Config.QuoteSeconds,
        credit = state.credits[tostring(tier)] > 0,
    }

    quote.parts = previous and previous.token == token and previous.parts or linkedParts(slab)
    quotes[player] = quote

    if knownToken == token then
        return
    end

    send(player, "Quote", {
        token = token,
        slab = slab,
        parts = quote.parts,
        tier = tier,
        price = Config.Tiers[tier].price,
        name = slab:GetAttribute("DrivewayName") or Sections.plainName(slab),
        area = area,
        requestId = requestId,
        credit = quote.credit,
    })
end

local function confirm(player, token)
    if not ready(player) then
        reject(player, "Still loading your save. Please try again.")
        return
    end

    if busy[player] or prompting[player] then
        return
    end

    local quote = quotes[player]

    if not quote or quote.token ~= token or quote.expires < os.clock() then
        reject(player, "Selection expired. Choose the road again.")
        return
    end

    local slab = quote.slab

    if not validRoad(slab) or not accessible(player, slab) or standingRoad(player) ~= slab or finished(player, slab) then
        reject(player, "Stand on the selected road and try again.")
        return
    end

    local _, size = SurfaceFrame.of(slab)
    local tier = Config.tierOf(slab, size)

    if tier ~= quote.tier then
        reject(player, "The road size changed. Choose it again to check the price.")
        return
    end

    local state = State.read(player)

    if state.pending and (state.pending.key ~= quote.key or state.pending.world ~= Config.World or state.pending.tier ~= tier) then
        reject(player, "Your previous Skip Road purchase is still pending.")
        return
    end

    if quote.credit and state.credits[tostring(tier)] <= 0 then
        reject(player, "This skip credit was already used. Choose the road again.")
        return
    end

    busy[player] = true

    if not state.pending and state.credits[tostring(tier)] > 0 then
        local success, result = pcall(function()
            local sealRoad = ServerScriptService:FindFirstChild("SkipZoneSealRoad")

            if not sealRoad then
                return false
            end

            player:SetAttribute("SkipRoadGrantPending", true)

            if sealRoad:Invoke(player, slab) ~= true then
                return false
            end

            state.credits[tostring(tier)] -= 1
            state.creditUses[HttpService:GenerateGUID(false)] = tier
            State.write(player, state)

            if not save(player) then
                send(player, "Saving")
                return false
            end

            player:SetAttribute("SkipRoadGrantPending", false)
            quotes[player] = nil
            send(player, "Completed")
            return true
        end)

        busy[player] = nil

        if not success then
            warn("[SkipRoad] Credit completion retry: " .. tostring(result))
        end

        return
    end

    if not state.pending then
        state.pending = {
            key = quote.key,
            world = Config.World,
            tier = tier,
            token = token,
            position = { slab.Position.X, slab.Position.Y, slab.Position.Z },
        }
        State.write(player, state)
    end

    pendingTargets[player] = slab

    if not save(player) then
        busy[player] = nil
        reject(player, "Could not save the selected road. Please try again.")
        return
    end

    local productId = Config.Tiers[tier].productId
    prompting[player] = productId
    busy[player] = nil
    send(player, "PurchaseStarted", quote.token)

    local success = pcall(function()
        MarketplaceService:PromptProductPurchase(player, productId)
    end)

    if not success then
        prompting[player] = nil
        reject(player, "Could not open the purchase window. Please try again.")
    end
end

local function resolveRoad(player, pending)
    local target = pendingTargets[player]

    if validRoad(target) and Sections.keyOf(target) == pending.key then
        return target
    end

    target = nil

    local position = pending.position or {}
    local nearestDistance = math.huge

    for _, slab in ipairs(CollectionService:GetTagged(Sections.Tag)) do
        if validRoad(slab) and Sections.keyOf(slab) == pending.key then
            local distance = (slab.Position.X - (tonumber(position[1]) or 0)) ^ 2
                + (slab.Position.Y - (tonumber(position[2]) or 0)) ^ 2
                + (slab.Position.Z - (tonumber(position[3]) or 0)) ^ 2

            if distance < nearestDistance then
                target = slab
                nearestDistance = distance
            end
        end
    end

    return target
end

function Service.configure(saveFunction, readyFunction)
    saveProfile = saveFunction
    profileReady = readyFunction
end

function Service.isProduct(productId)
    return Config.isProduct(productId)
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
            if player:GetAttribute("SkipRoadGrantPending") == true then
                if not save(player) then
                    return retry
                end

                player:SetAttribute("SkipRoadGrantPending", false)
                send(player, "Completed")
            end

            if not state.pending then
                prompting[player] = nil
            end

            return Enum.ProductPurchaseDecision.PurchaseGranted
        end

        local pending = state.pending
        local tier = pending and Config.Tiers[pending.tier]

        -- A late second receipt must still deliver value if the first receipt
        -- already completed the saved target. Restore a credit for its tier.
        if not pending then
            local purchasedTier

            for index, product in ipairs(Config.Tiers) do
                if product.productId == info.ProductId then
                    purchasedTier = index
                    break
                end
            end

            if not purchasedTier then
                return retry
            end

            local key = tostring(purchasedTier)
            state.credits[key] += 1
            state.receipts[purchaseId] = { credit = true, tier = purchasedTier }
            player:SetAttribute("SkipRoadGrantPending", true)
            State.write(player, state)

            if not save(player) then
                return retry
            end

            player:SetAttribute("SkipRoadGrantPending", false)
            prompting[player] = nil
            send(player, "Credit", Config.Tiers[purchasedTier].price)
            return Enum.ProductPurchaseDecision.PurchaseGranted
        end

        if not pending or pending.world ~= Config.World or not tier or info.ProductId ~= tier.productId then
            return retry
        end

        local slab = resolveRoad(player, pending)
        local sealRoad = ServerScriptService:FindFirstChild("SkipZoneSealRoad")

        if not slab or not sealRoad then
            return retry
        end

        player:SetAttribute("SkipRoadGrantPending", true)

        if sealRoad:Invoke(player, slab) ~= true then
            return retry
        end

        state.receipts[purchaseId] = {
            key = pending.key,
            world = pending.world,
            tier = pending.tier,
        }
        state.pending = nil
        State.write(player, state)

        if not save(player) then
            send(player, "Saving")
            return retry
        end

        player:SetAttribute("SkipRoadGrantPending", false)
        prompting[player] = nil
        pendingTargets[player] = nil
        quotes[player] = nil
        send(player, "Completed")

        return Enum.ProductPurchaseDecision.PurchaseGranted
    end)

    busy[player] = nil

    if not success then
        warn("[SkipRoad] Receipt will retry: " .. tostring(decision))
        return retry
    end

    return decision
end

function Service.start()
    if started then
        return
    end

    started = true
    Remote.OnServerEvent:Connect(function(player, action, value, requestId)
        if action == "SelectStanding" then
            selectRoad(player, value, requestId)
        elseif action == "Confirm" then
            confirm(player, value)
        elseif action == "Cancel" then
            quotes[player] = nil
        end
    end)

    MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
        if not Config.isProduct(productId) then
            return
        end

        local player = Players:GetPlayerByUserId(userId)

        if not player then
            return
        end

        local state = State.read(player)

        if state.pending and Config.Tiers[state.pending.tier].productId ~= productId then
            return
        end

        if purchased then
            prompting[player] = state.pending and productId or nil
            return
        end

        prompting[player] = nil

        if busy[player] then
            return
        end

        busy[player] = true
        state.pending = nil
        State.write(player, state)
        save(player)
        busy[player] = nil
        send(player, "Cancelled")
    end)

    Players.PlayerRemoving:Connect(function(player)
        quotes[player] = nil
        busy[player] = nil
        prompting[player] = nil
        lastSelect[player] = nil
        pendingTargets[player] = nil
    end)

    task.spawn(function()
        while task.wait(10) do
            for _, player in ipairs(Players:GetPlayers()) do
                if ready(player) and not busy[player] and player:GetAttribute("SkipRoadGrantPending") == true then
                    local state = State.read(player)

                    if not state.pending then
                        busy[player] = true

                        if save(player) then
                            player:SetAttribute("SkipRoadGrantPending", false)
                            prompting[player] = nil
                            send(player, "Completed")
                        end

                        busy[player] = nil
                    end
                end
            end
        end
    end)
end

return Service
