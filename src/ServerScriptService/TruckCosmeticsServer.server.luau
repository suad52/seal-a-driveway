local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local assets=RS:WaitForChild("StellarQuest"):WaitForChild("Assets")
local tracked=setmetatable({},{__mode="k"})
local function consider(v)
 if v:IsA("Model") and (v:GetAttribute("OwnerUserId") or v:GetAttribute("RigId")) then tracked[v]=true end
end
for _,v in ipairs(workspace:GetDescendants()) do consider(v) end
workspace.DescendantAdded:Connect(function(v) if v:IsA("Model") then task.defer(consider,v) end end)
while task.wait(1) do
 for model in pairs(tracked) do
  if not model.Parent then tracked[model]=nil;continue end
  local id=model:GetAttribute("HolderUserId")
  if not id or id==0 then id=model:GetAttribute("OwnerUserId") end
  local p=id and Players:GetPlayerByUserId(id)
  local selection=p and p:GetAttribute("TruckVFXSelected") or ""
  if p and (selection==nil or selection=="") and p:GetAttribute("HalloweenTruckEquipped")==true then selection="Haunted" end
  local template
  if p and selection=="Paid" and p:GetAttribute("TruckVFXPaidOwned")==true then template=assets:FindFirstChild("Paid")
  elseif p and selection=="Stellar" and p:GetAttribute("TruckVFXStellarOwned")==true then template=assets:FindFirstChild("Stellar")
  elseif p and selection=="Haunted" and p:GetAttribute("GraveyardClaim4")==1 then
   local oldAssets=RS:FindFirstChild("GraveyardAssets");template=oldAssets and oldAssets:FindFirstChild("TruckVFX")
  end
  local old=model:FindFirstChild("HalloweenTruckVFX")
  if old and (not template or old:GetAttribute("CosmeticId")~=selection) then old:Destroy();old=nil end
  if template and not old then
   local base=model:FindFirstChild("Base",true) or model.PrimaryPart
   if base and base:IsA("BasePart") then
    local v=template:Clone();v.Name="HalloweenTruckVFX";v:SetAttribute("CosmeticId",selection)
    for _,d in ipairs(v:GetDescendants()) do if d:IsA("LuaSourceContainer") then d:Destroy() end end
    v.Anchored=false;v.Massless=true;v.CanCollide=false;v.CanTouch=false;v.CanQuery=false;v.Transparency=1
    v.CFrame=base.CFrame*CFrame.new(0,2,0)*template.CFrame.Rotation;v.Parent=model
    local weld=Instance.new("WeldConstraint",v);weld.Part0=base;weld.Part1=v
   end
  end
 end
end
