local Http = game:GetService("HttpService")
local State = {}
function State.decode(raw)
    local ok, data = pcall(Http.JSONDecode, Http, raw or "{}")
    if not ok or type(data) ~= "table" then data = {} end
    data.zones = data.zones or {}
    data.items = data.items or {}
    for index = 1, 2 do
        local key = tostring(index)
        data.zones[key] = data.zones[key] or {hp = {}, destroyed = {}, roads = {}, drops = {}}
    end
    return data
end
function State.read(player) return State.decode(player:GetAttribute("BonusState")) end
function State.write(player, data) player:SetAttribute("BonusState", Http:JSONEncode(data)) end
function State.restore(player, data)
    local backup = data.WorldProgress and data.WorldProgress["1"]
    State.write(player, State.decode(data.BonusState or (backup and backup.BonusState)))
end
function State.capture(player, data) data.BonusState = player:GetAttribute("BonusState") or "{}" end
function State.wrap(Profile)
    local migrate, merge = Profile.migrate, Profile.merge
    Profile.migrate = function(raw)
        local data = migrate(raw)
        data.BonusState = data.BonusState or data.WorldProgress["1"].BonusState
        return data
    end
    Profile.merge = function(raw, snapshot, world, maxima, reset)
        local old = Profile.migrate(raw)
        local result = merge(old, snapshot, world, maxima, reset)
        result.BonusState = snapshot.BonusState or old.BonusState
        result.WorldProgress["1"].BonusState = result.BonusState
        return result
    end
end
return State
