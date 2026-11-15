local RS = game:GetService("ReplicatedStorage")
local Collection = game:GetService("CollectionService")
local pack = RS:WaitForChild("DrivewaySealer")
local Catalog = require(pack.World1RestorationCatalog)
local Appearance = require(pack.World1Appearance)

local function resolve(root, path)
    local node = root
    for name in path:gmatch("[^.]+") do
        node = node and node:FindFirstChild(name)
        if not node then return nil end
    end
    return node
end

for _, area in ipairs(Catalog.Areas) do
    local restored = area.restored and resolve(workspace, area.restored)
    local source = resolve(RS, area.broken)
    if area.sourceId then
        local parent = resolve(RS, area.broken:match("^(.*)%.[^.]+$"))
        source = nil
        if parent then
            for _, candidate in ipairs(parent:GetChildren()) do
                if candidate:GetAttribute("W1SourceId") == area.sourceId then source = candidate; break end
            end
        end
    end
    local zone = workspace:FindFirstChild(area.zone)
    if (area.restored and not restored) or not source or not zone then
        warn("[World1Restoration] Missing variant:", area.id)
        continue
    end
    if restored then
        restored:SetAttribute("W1Area", area.id)
        restored:SetAttribute("W1Variant", "Restored")
        Appearance.prepare(restored, false)
    end
    local holder = zone:FindFirstChild("RestorationBroken")
    if not holder then
        holder = Instance.new("Folder")
        holder.Name = "RestorationBroken"
        holder.Parent = zone
    end
    local previous = holder:FindFirstChild(area.name)
    if previous then previous:Destroy() end
    local broken = source:Clone()
    broken.Name = area.name
    for _, path in ipairs(area.excludeBroken) do
        local duplicateRoad = resolve(broken, path)
        if duplicateRoad then duplicateRoad:Destroy() end
    end
    for _, item in ipairs(broken:GetDescendants()) do
        if Collection:HasTag(item, "SealableDriveway") then
            Collection:RemoveTag(item, "SealableDriveway")
        end
        if item:IsA("BaseScript") then item.Disabled = true end
        if item:IsA("BasePart") then item.Anchored = true end
    end
    broken:SetAttribute("W1Area", area.id)
    broken:SetAttribute("W1Variant", "Broken")
    Appearance.prepare(broken, true)
    broken.Parent = holder
end

print("[World1Restoration] Prepared " .. #Catalog.Areas .. " areas, including Parking Garage.")
