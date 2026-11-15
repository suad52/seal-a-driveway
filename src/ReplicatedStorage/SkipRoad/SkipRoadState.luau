local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.SkipRoadConfig)

local State = {}

function State.decode(raw)
    local success, value = pcall(function()
        return HttpService:JSONDecode(type(raw) == "string" and raw or "{}")
    end)

    if not success or type(value) ~= "table" then
        value = {}
    end

    value.receipts = type(value.receipts) == "table" and value.receipts or {}
    value.credits = type(value.credits) == "table" and value.credits or {}
    value.creditUses = type(value.creditUses) == "table" and value.creditUses or {}

    for index = 1, #Config.Tiers do
        local key = tostring(index)
        local available = 0

        for _, receipt in pairs(value.receipts) do
            if type(receipt) == "table" and receipt.credit == true and receipt.tier == index then
                available += 1
            end
        end

        for _, usedTier in pairs(value.creditUses) do
            if usedTier == index then
                available -= 1
            end
        end

        value.credits[key] = math.max(0, available)
    end

    if type(value.pending) ~= "table"
        or type(value.pending.key) ~= "string"
        or type(value.pending.world) ~= "string"
        or not Config.Tiers[value.pending.tier] then
        value.pending = nil
    end

    return value
end

function State.read(player)
    return State.decode(player:GetAttribute(Config.StateAttribute))
end

function State.write(player, value)
    player:SetAttribute(Config.StateAttribute, HttpService:JSONEncode(value))
end

function State.restore(player, data)
    local firstWorld = data.WorldProgress and data.WorldProgress["1"]
    local raw = data.SkipRoadState or (firstWorld and firstWorld.SkipRoadState)
    State.write(player, State.decode(raw))
end

function State.capture(player, data)
    data.SkipRoadState = HttpService:JSONEncode(State.read(player))
end

return State
