local Appearance = {}

local function properties(instance)
    if instance:IsA("BasePart") then
        return {"Transparency", "CanCollide", "CanTouch", "CanQuery", "CastShadow"}
    elseif instance:IsA("Decal") or instance:IsA("Texture") then
        return {"Transparency"}
    elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
        or instance:IsA("Light") or instance:IsA("Highlight") or instance:IsA("LayerCollector")
        or instance:IsA("ProximityPrompt") then
        return {"Enabled"}
    elseif instance:IsA("Sound") then
        return {"Volume"}
    elseif instance:IsA("ClickDetector") then
        return {"MaxActivationDistance"}
    end
    return {}
end

function Appearance.remember(instance)
    for _, property in ipairs(properties(instance)) do
        local key = "W1Original_" .. property
        if instance:GetAttribute(key) == nil then
            local value = instance:GetAttribute("JapanOriginal_" .. property)
            if value == nil then value = instance:GetAttribute("NZOriginal_" .. property) end
            if value == nil then value = instance[property] end
            instance:SetAttribute(key, value)
        end
    end
end

function Appearance.apply(instance, visible)
    local ready = true
    for _, property in ipairs(properties(instance)) do
        local value = instance:GetAttribute("W1Original_" .. property)
        if value == nil then
            ready = false
        elseif visible then
            instance[property] = value
        else
            instance[property] = if property == "Transparency" then 1
                elseif property == "Volume" or property == "MaxActivationDistance" then 0 else false
        end
    end
    if not visible and (instance:IsA("ParticleEmitter") or instance:IsA("Trail")) then
        instance:Clear()
    end
    return ready
end

function Appearance.prepare(root, visible)
    Appearance.remember(root)
    Appearance.apply(root, visible)
    for _, instance in ipairs(root:GetDescendants()) do
        Appearance.remember(instance)
        Appearance.apply(instance, visible)
    end
end

function Appearance.show(root, visible)
    local ready = Appearance.apply(root, visible)
    for _, instance in ipairs(root:GetDescendants()) do
        if not Appearance.apply(instance, visible) then ready = false end
    end
    return ready
end

return Appearance
