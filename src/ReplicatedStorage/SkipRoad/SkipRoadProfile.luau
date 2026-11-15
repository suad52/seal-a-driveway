local HttpService = game:GetService("HttpService")
local State = require(script.Parent.SkipRoadState)

local Bridge = {}

function Bridge.wrap(Profile)
    if Profile.SkipRoadProfileVersion == 1 then
        return
    end

    Profile.SkipRoadProfileVersion = 1

    local migrate = Profile.migrate
    local merge = Profile.merge

    Profile.migrate = function(raw)
        local data = migrate(raw)
        local firstWorld = data.WorldProgress and data.WorldProgress["1"]

        if not data.SkipRoadState and firstWorld then
            data.SkipRoadState = firstWorld.SkipRoadState
        end

        return data
    end

    Profile.merge = function(raw, snapshot, world, baseMax, resetExtras)
        local previous = Profile.migrate(raw)
        local oldState = State.decode(previous.SkipRoadState)
        local nextState = State.decode(snapshot.SkipRoadState or previous.SkipRoadState)

        for purchaseId, receipt in pairs(oldState.receipts) do
            nextState.receipts[purchaseId] = receipt
        end

        for useId, tier in pairs(oldState.creditUses) do
            nextState.creditUses[useId] = tier
        end

        local result = merge(previous, snapshot, world, baseMax, resetExtras)
        local packed = HttpService:JSONEncode(nextState)
        result.SkipRoadState = packed
        result.WorldProgress["1"].SkipRoadState = packed

        return result
    end
end

return Bridge
