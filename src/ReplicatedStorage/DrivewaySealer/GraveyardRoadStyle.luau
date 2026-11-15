local RS=game:GetService("ReplicatedStorage")
local original=setmetatable({},{__mode="k"})
local M={}
function M.apply(part,on)
 if on then
  if original[part] then return end
  original[part]=part.Material
  part.Material=Enum.Material.Neon
  local texture=Instance.new("Texture")
  texture.Name="GraveyardBrewTexture";texture.Texture="rbxassetid://138228552962702"
  texture.Face=Enum.NormalId.Top;texture.StudsPerTileU=7.2;texture.StudsPerTileV=7.2;texture.Transparency=.7;texture.Parent=part
  -- A small bounded copy of the authored effects, attached only to painted surfaces.
  local a=Instance.new("Attachment",part);a.Name="GraveyardBrewVFX";a.Position=Vector3.new(0,part.Size.Y/2+.1,0)
  local source=RS:FindFirstChild("GraveyardAssets")
  source=source and source:FindFirstChild("WitchBrew")
  if source then
   for _,e in ipairs(source:GetChildren()) do
    if e:IsA("ParticleEmitter") then
     local clone=e:Clone();clone.Rate=math.min(clone.Rate,3);clone.Enabled=true;clone.Parent=a
    end
   end
  end
 elseif original[part] then
  part.Material=original[part];original[part]=nil
  for _,name in ipairs({"GraveyardBrewTexture","GraveyardBrewVFX"}) do
   local v=part:FindFirstChild(name);if v then v:Destroy() end
  end
 end
end
return M
