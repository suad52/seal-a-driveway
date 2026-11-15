local Http = game:GetService("HttpService")
local State = {}

function State.decode(raw)
    local ok, data = pcall(Http.JSONDecode, Http, raw or "{}")
    if not ok or type(data) ~= "table" then data = {} end
    data.worlds = type(data.worlds) == "table" and data.worlds or {}
    data.claims = type(data.claims) == "table" and data.claims or {}
    data.worlds["1"] = type(data.worlds["1"]) == "table" and data.worlds["1"] or {}
    data.worlds["2"] = type(data.worlds["2"]) == "table" and data.worlds["2"] or {}
    return data
end

function State.read(player)
    return State.decode(player:GetAttribute("ZoneProgressState"))
end

function State.write(player, data)
    player:SetAttribute("ZoneProgressState", Http:JSONEncode(data))
end

function State.combine(a, b)
    local result = State.decode(a)
    local incoming = State.decode(b)
    for _, world in ipairs({"1", "2"}) do
        for id, completed in pairs(incoming.worlds[world]) do
            if completed == true then result.worlds[world][id] = true end
        end
    end
    for id, claim in pairs(incoming.claims) do
        if claim == "claimed" or (claim == "pending" and not result.claims[id]) then
            result.claims[id] = claim
        end
    end
    return Http:JSONEncode(result)
end

function State.restore(player, data)
    local backup = data.WorldProgress and data.WorldProgress["1"]
    State.write(player, State.decode(State.combine(data.ZoneProgressState,
        backup and backup.ZoneProgressState)))
    local second = data.WorldProgress and data.WorldProgress["2"]
    player:SetAttribute("ZoneProgressWorld2Roads", second and second.SecSealed or "")
end

function State.capture(player, data)
    data.ZoneProgressState = player:GetAttribute("ZoneProgressState") or "{}"
end

function State.wrap(Profile)
    if Profile.ZoneProgressVersion then return end
    Profile.ZoneProgressVersion = 1
    local migrate, merge = Profile.migrate, Profile.merge
    Profile.migrate = function(raw)
        local data = migrate(raw)
        local backup = data.WorldProgress and data.WorldProgress["1"]
        data.ZoneProgressState = State.combine(data.ZoneProgressState,
            backup and backup.ZoneProgressState)
        return data
    end
    Profile.merge = function(raw, snapshot, world, baseMax, resetExtras)
        local previous = Profile.migrate(raw)
        local packed = State.combine(previous.ZoneProgressState, snapshot.ZoneProgressState)
        local result = merge(previous, snapshot, world, baseMax, resetExtras)
        result.ZoneProgressState = packed
        result.WorldProgress["1"].ZoneProgressState = packed
        return result
    end
end

return State
