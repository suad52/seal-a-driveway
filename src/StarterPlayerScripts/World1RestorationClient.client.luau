local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local pack = RS:WaitForChild("DrivewaySealer")
local Sections = require(pack:WaitForChild("Sections"))
local Catalog = require(pack:WaitForChild("World1RestorationCatalog"))
local Appearance = require(pack:WaitForChild("World1Appearance"))
local definitions, completed = {}, {}
local roots = setmetatable({}, {__mode = "k"})
local pending = setmetatable({}, {__mode = "k"})
local zones = {}
for _, area in ipairs(Catalog.Areas) do
    definitions[area.id] = area
    zones[area.zone] = true
end

local function visible(root)
    local done = completed[root:GetAttribute("W1Area")] == true
    return if root:GetAttribute("W1Variant") == "Restored" then done else not done
end

local function apply(root, force)
    local show = visible(root)
    if force or roots[root] ~= show then
        local ready = Appearance.show(root, show)
        roots[root] = show
        pending[root] = if ready then nil else true
    end
end

local function attach(root)
    if roots[root] ~= nil or not definitions[root:GetAttribute("W1Area")] then return end
    apply(root, true)
end

local function reconcile()
    for zoneName in pairs(zones) do
        local zone = workspace:FindFirstChild(zoneName)
        if zone then
            local restored = zone:FindFirstChild("PropsRestoredPlace" .. (
                zoneName == "Neighbourhood" and "1" or zoneName == "EstateDistrict" and "2"
                or zoneName == "RetailPark" and "3" or zoneName == "Airport" and "4" or "5"))
            local broken = zone:FindFirstChild("RestorationBroken")
            for _, container in ipairs({restored or false, broken or false}) do
                if container then for _, root in ipairs(container:GetChildren()) do attach(root) end end
            end
        end
    end
end

local function refresh()
    local sealed = Sections.nowSetOf(player)
    local loaded = player:GetAttribute("ProfileLoaded") == true
    for id, area in pairs(definitions) do completed[id] = loaded and Catalog.complete(area, sealed) end
    reconcile()
    for root in pairs(roots) do
        if root:IsDescendantOf(workspace) then apply(root) else roots[root], pending[root] = nil, nil end
    end
end

workspace.DescendantAdded:Connect(function(item)
    task.defer(function()
        if not item:IsDescendantOf(workspace) then return end
        local node = item
        while node and node ~= workspace do
            if definitions[node:GetAttribute("W1Area")] then
                attach(node)
                if not Appearance.apply(item, visible(node)) then pending[node] = true end
                return
            end
            node = node.Parent
        end
    end)
end)
player:GetAttributeChangedSignal(Sections.NowAttr):Connect(refresh)
player:GetAttributeChangedSignal("ProfileLoaded"):Connect(refresh)
refresh()
task.spawn(function()
    while task.wait(1) do
        reconcile()
        for root in pairs(pending) do
            if root:IsDescendantOf(workspace) then apply(root, true) else pending[root] = nil end
        end
    end
end)
