local HttpService = game:GetService("HttpService")
local State = require(script.Parent.SkipZoneState)

local Bridge = {}

local function recover(data)
    local firstWorld = data.WorldProgress and data.WorldProgress["1"]

    if not data.SkipZoneState and firstWorld then
        data.SkipZoneState = firstWorld.SkipZoneState
    end

    return data
end

function Bridge.wrap(Profile)
    if Profile.SkipZoneProfileVersion == 1 then
        return
    end

    Profile.SkipZoneProfileVersion = 1

    local migrate = Profile.migrate
    local merge = Profile.merge

    Profile.migrate = function(raw)
        return recover(migrate(raw))
    end

    Profile.merge = function(raw, snapshot, world, baseMax, resetExtras)
        local previous = Profile.migrate(raw)
        local oldState = State.decode(previous.SkipZoneState)
        local nextState = State.decode(snapshot.SkipZoneState or previous.SkipZoneState)

        for purchaseId, zone in pairs(oldState.receipts) do
            nextState.receipts[purchaseId] = zone
        end

        for zoneId, unlocked in pairs(oldState.gates) do
            if unlocked == true then
                nextState.gates[zoneId] = true
            end
        end

        local result = merge(previous, snapshot, world, baseMax, resetExtras)
        local packed = HttpService:JSONEncode(nextState)

        result.SkipZoneState = packed
        result.WorldProgress["1"].SkipZoneState = packed

        return result
    end
end

return Bridge
