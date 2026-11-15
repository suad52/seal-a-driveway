local Logic = {}

function Logic.progress(keys, sealed)
    local completed = 0
    for _, key in ipairs(keys) do
        if sealed[key] then completed += 1 end
    end
    return completed, #keys
end

function Logic.count(completed, ids)
    local total = 0
    for _, id in ipairs(ids) do
        if completed[id] == true then total += 1 end
    end
    return total
end

function Logic.eligible(data, milestone, count)
    local id = tostring(milestone)
    return (milestone == 2 or milestone == 4 or milestone == 6)
        and count >= milestone and data.claims[id] ~= "claimed"
end

return Logic
