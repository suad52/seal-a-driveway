local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.SkipZoneConfig)

local State = {}

function State.decode(raw)
    local success, value = pcall(function()
        return HttpService:JSONDecode(type(raw) == "string" and raw or "{}")
    end)

    if not success or type(value) ~= "table" then
        value = {}
    end

    value.receipts = type(value.receipts) == "table" and value.receipts or {}
    value.gates = type(value.gates) == "table" and value.gates or {}

    if type(value.pending) ~= "table" then
        value.pending = nil
    end

    return value
end

function State.read(player)
    return State.decode(player:GetAttribute(Config.StateAttribute))
end

function State.write(player, value)
    player:SetAttribute(Config.StateAttribute, HttpService:JSONEncode(value))

    for _, zone in ipairs(Config.Zones) do
        player:SetAttribute("SkipZoneBypass_" .. zone.id, value.gates[zone.id] == true)
    end
end

function State.restore(player, data)
    local firstWorld = data.WorldProgress and data.WorldProgress["1"]
    local raw = data.SkipZoneState or (firstWorld and firstWorld.SkipZoneState)
    local value = State.decode(raw)

    -- Players who already reached Desert City before Garage became a gate
    -- keep their existing access. This grants no paint, cash or receipt.
    if not raw then
        local record = data.SecSealed or (firstWorld and firstWorld.SecSealed) or ""

        for key in string.gmatch(record, "[^|]+") do
            if key:sub(1, 8) == "NewZone." then
                value.gates.ParkingGarage = true
                break
            end
        end
    end

    State.write(player, value)
end

function State.capture(player, data)
    data.SkipZoneState = HttpService:JSONEncode(State.read(player))
end

return State
