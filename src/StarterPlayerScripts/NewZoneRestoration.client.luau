local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local pack = RS:WaitForChild("DrivewaySealer")
local Sections = require(pack:WaitForChild("Sections"))
local Catalog = require(pack:WaitForChild("NewZoneCatalog"))
local Appearance = require(pack:WaitForChild("NewZoneAppearance"))
local root = workspace:WaitForChild("NewZone")
local zones = root:WaitForChild("Zones")
local definitions = {}
for _, zone in ipairs(Catalog.Zones) do definitions[zone.id] = zone end
local completed = {}
local modelStates = setmetatable({}, {__mode="k"})
local function variantOf(instance)
 local node = instance
 while node and node ~= zones do
  if node:GetAttribute("NZVariant") then return node end
  node = node.Parent
 end
 return nil
end
local function visible(model)
 local done = completed[model:GetAttribute("NZZone")] == true
 return if model:GetAttribute("NZVariant") == "Restored" then done else not done
end
local function updateModel(model)
 local show = visible(model)
 if modelStates[model] ~= show then
  Appearance.show(model, show)
  modelStates[model] = show
 end
end
local function refresh()
 local sealed = Sections.nowSetOf(player)
 for id, zone in pairs(definitions) do completed[id] = Catalog.complete(zone, sealed) end
 for _, folder in ipairs(zones:GetChildren()) do
  for _, model in ipairs(folder:GetChildren()) do
   if model:GetAttribute("NZVariant") then updateModel(model) end
  end
 end
end
zones.DescendantAdded:Connect(function(instance)
 task.defer(function()
  if not instance:IsDescendantOf(zones) then return end
  local model = variantOf(instance)
  if not model then return end
  if model == instance then updateModel(model) else Appearance.apply(instance, visible(model)) end
 end)
end)
player:GetAttributeChangedSignal(Sections.NowAttr):Connect(refresh)
player:GetAttributeChangedSignal("ProfileLoaded"):Connect(refresh)
refresh()
print("[NewZone] Personal restoration ready: 15 zones. Current-lap progress controls the buildings.")
