local Appearance = {}
local function properties(instance)
 if instance:IsA("BasePart") then
  return {"Transparency", "CanCollide", "CanTouch", "CanQuery", "CastShadow"}
 elseif instance:IsA("Decal") or instance:IsA("Texture") then
  return {"Transparency"}
 elseif instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail")
  or instance:IsA("Light") or instance:IsA("Highlight") or instance:IsA("LayerCollector") then
  return {"Enabled"}
 elseif instance:IsA("Sound") then
  return {"Volume"}
 end
 return {}
end
function Appearance.remember(instance)
 for _, property in ipairs(properties(instance)) do
  local key = "NZOriginal_" .. property
  if instance:GetAttribute(key) == nil then instance:SetAttribute(key, instance[property]) end
 end
end
function Appearance.apply(instance, visible)
 for _, property in ipairs(properties(instance)) do
  local value = instance:GetAttribute("NZOriginal_" .. property)
  if value ~= nil then
   instance[property] = if visible then value elseif property == "Transparency" then 1 elseif property == "Volume" then 0 else false
  end
 end
end
function Appearance.prepare(model, visible)
 Appearance.remember(model)
 Appearance.apply(model, visible)
 for _, instance in ipairs(model:GetDescendants()) do
  Appearance.remember(instance)
  Appearance.apply(instance, visible)
 end
end
function Appearance.show(model, visible)
 Appearance.apply(model, visible)
 for _, instance in ipairs(model:GetDescendants()) do Appearance.apply(instance, visible) end
end
return Appearance
