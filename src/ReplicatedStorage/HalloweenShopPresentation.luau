local RS=game:GetService("ReplicatedStorage")
local TweenService=game:GetService("TweenService")
local Pack=RS:WaitForChild("DrivewaySealer")
local Skins=require(Pack:WaitForChild("SqueegeeSkins"))
local Builder=require(Pack:WaitForChild("ToolBuilder"))
local Palettes=require(Pack:WaitForChild("ColorPalettes"))
local M={}
local SoundService=game:GetService("SoundService")
local Debris=game:GetService("Debris")
local SoundKit=require(Pack.SoundKit)
local function sound(id,volume)
 local s=Instance.new("Sound");s.SoundId="rbxassetid://"..id;s.Volume=volume
 s.SoundGroup=SoundKit.bus("Ui");s.Parent=SoundService;s:Play();Debris:AddItem(s,12)
end
local paletteById={}
for _,v in ipairs(Palettes) do paletteById[string.lower(v.id)]=v end
local function norm(v)
 return string.lower(tostring(v or "")):gsub("[^%w]","")
end
local function clearOld(parent)
 local old=parent:FindFirstChild("Halloween3DPreview")
 if old then old:Destroy() end
end
local function cameraFor(vp,model,margin)
 local cam=vp:FindFirstChild("HalloweenPreviewCamera") or Instance.new("Camera")
 cam.Name="HalloweenPreviewCamera"
 cam.FieldOfView=34;cam.Parent=vp;vp.CurrentCamera=cam
 local cf,size=model:GetBoundingBox()
 local aspect=vp.AbsoluteSize.X/math.max(1,vp.AbsoluteSize.Y)
 if vp.AbsoluteSize.Y<=1 then aspect=1 end
 local r=math.max(size.X,size.Y,size.Z)*1.7*(margin or 1)/math.min(1,math.max(.35,aspect))
 cam.CFrame=CFrame.lookAt(cf.Position+Vector3.new(r*.85,r*.52,r*.95),cf.Position)
end
local function newViewport(parent,rect)
 clearOld(parent)
 local vp=Instance.new("ViewportFrame")
 vp.Name="Halloween3DPreview"
 vp.BackgroundTransparency=1
 vp.BorderSizePixel=0
 vp.Size=rect and rect.Size or UDim2.fromScale(1,1)
 vp.Position=rect and rect.Position or UDim2.fromScale(0,0)
 vp.AnchorPoint=rect and rect.AnchorPoint or Vector2.zero
 vp.ZIndex=rect and rect.ZIndex+1 or (parent.ZIndex+2)
 vp.Ambient=Color3.fromRGB(190,195,210)
 vp.LightColor=Color3.fromRGB(255,245,225)
 vp.LightDirection=Vector3.new(-1,-1,-.5)
 vp.Parent=parent
 local wm=Instance.new("WorldModel");wm.Parent=vp
 return vp,wm
end
local function asSqueegee(parent,id,rect)
 local ok,err=pcall(function()
  local vp,world=newViewport(parent,rect)
  local tool=Builder.buildSqueegee()
  local rig=tool:FindFirstChild("Rig")
  if not rig or not rig:IsA("Model") then tool:Destroy();vp:Destroy();return end
  rig:SetAttribute("ForViewport",true)
  Skins.apply(rig,id)
  rig.Parent=world
  tool:Destroy()
  for _,v in ipairs(rig:GetDescendants()) do
   if v:IsA("BasePart") then v.Anchored=true;v.CanCollide=false
   elseif v:IsA("ParticleEmitter") or v:IsA("Sound") or v:IsA("Light") then v:Destroy() end
  end
  cameraFor(vp,rig,1.15)
 end)
 if not ok then warn("[HalloweenPreview] squeegee",id,err) end
end
local function asAsphalt(parent,id,rect)
 local pal=paletteById[string.lower(id)]
 if not pal then warn("[HalloweenPreview] No palette",id);return end
 local vp,world=newViewport(parent,rect)
 local road=Instance.new("Model");road.Name="Road";road.Parent=world
 local function part(name,size,cf,color,material)
  local p=Instance.new("Part");p.Name=name;p.Size=size;p.CFrame=cf;p.Color=color
  p.Anchored=true;p.CanCollide=false;p.Material=material;p.Parent=road
  return p
 end
 part("Base",Vector3.new(7,.25,5),CFrame.new(0,0,0),Color3.fromRGB(22,26,32),Enum.Material.Slate)
 local slices=if pal.lut then 32 else 1
 local mat=if id=="witchbrew" then Enum.Material.Neon else Enum.Material.SmoothPlastic
 for i=1,slices do
  local color=if pal.lut then pal.lut[math.floor((i-1)/(math.max(1,slices-1))*255)+1] else pal.sealed
  local c=if typeof(color)=="Vector3" then Color3.new(color.X,color.Y,color.Z) else if typeof(color)=="Color3" then color else Color3.fromRGB(255,110,35)
  local p=part("Finish",Vector3.new(7/slices,.055,5),CFrame.new(-3.5+(i-.5)*7/slices,.16,0),c,mat)
  if id=="witchbrew" then
   local texture=Instance.new("Texture");texture.Texture="rbxassetid://138228552962702"
   texture.Face=Enum.NormalId.Top;texture.StudsPerTileU=7.2;texture.StudsPerTileV=7.2
   texture.Transparency=.7;texture.Parent=p
  end
 end
 cameraFor(vp,road,1.13)
end
local function findImageSlot(card)
 local best,bestScore=nil,-1
 for _,v in ipairs(card:GetDescendants()) do
  if v:IsA("ImageLabel") and v.Visible then
   local s=norm(v.Name)
   if s:find("ring") or s:find("glow") or s:find("lock") or s:find("check") then continue end
   local area=v.AbsoluteSize.X*v.AbsoluteSize.Y
   if area==0 then area=1000 end
   if s:find("icon") or s:find("image") or s:find("preview") then area+=15000 end
   if area>bestScore then best,bestScore=v,area end
  end
 end
 return best
end
local function applyCard(card,kind,id)
 if not card or not card:IsA("GuiObject") then return end
 -- Use the authored viewport. A price/pumpkin icon is never a preview slot.
 local authored=card:FindFirstChildWhichIsA("ViewportFrame",true)
 if authored then
  if kind=="road" then
   -- The authored Finish still has the old coating. Rebuild the swatch from
   -- the actual palette, keeping the artist's viewport rectangle.
   asAsphalt(authored.Parent,id,authored)
   authored.Visible=false
   if card:IsA("ImageLabel") or card:IsA("ImageButton") then card.Image="" end
   return
  end
  authored.Visible=true;authored.BackgroundTransparency=1
  authored.Ambient=Color3.fromRGB(190,195,210);authored.LightColor=Color3.fromRGB(255,245,225)
  local world=authored:FindFirstChildWhichIsA("WorldModel")
  if world and world:FindFirstChildWhichIsA("BasePart",true) then
   local model=world:FindFirstChildWhichIsA("Model")
   if not model then
    model=Instance.new("Model");model.Name="Preview"
    for _,v in ipairs(world:GetChildren()) do v.Parent=model end
    model.Parent=world
   end
   if kind=="skin" then model:SetAttribute("ForViewport",true);Skins.apply(model,id) end
   cameraFor(authored,model,1)
   authored:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() if model.Parent then cameraFor(authored,model,1) end end)
   if card:IsA("ImageLabel") or card:IsA("ImageButton") then card.Image="" end
   return
  end
  -- Retain the authored viewport's rectangle while generating its missing content.
  local host=authored.Parent
  if kind=="skin" then asSqueegee(host,id,authored) else asAsphalt(host,id,authored) end
  authored.Visible=false
  if card:IsA("ImageLabel") or card:IsA("ImageButton") then card.Image="" end
  return
 end
 local slot=findImageSlot(card)
 if not slot then warn("[HalloweenPreview] No image in",card:GetFullName());return end
 local host=slot.Parent
 if not host:IsA("GuiObject") then return end
 if kind=="skin" then asSqueegee(host,id,slot) else asAsphalt(host,id,slot) end
 slot.Visible=false
end
local function findNamed(root,names)
 for _,name in ipairs(names) do
  local exact=root:FindFirstChild(name,true)
  if exact and exact:IsA("GuiObject") then return exact end
 end
 for _,v in ipairs(root:GetDescendants()) do
  if not v:IsA("GuiObject") then continue end
  for _,name in ipairs(names) do
   if norm(v.Name)==norm(name) then return v end
  end
 end
 return nil
end
local function targetWheelCard(wheel,id)
 local gachapons=wheel:FindFirstChild("Gachapons",true)
 if not gachapons then return nil end
 local names={
  nightmares={"AsphaltColor","Nightmares"},spell={"Squeegee","Spell"},
  pumpkins={"Pumpkins","Pumpkin","PumpkinCurrency"},tickets={"Tickets","SpinTickets","Spin"},
  cash100k={"Cash100K","100K","Cash100000"},cash1m={"Cash1M","1M","Cash1000000"},
  helper={"Helper"},coat={"InstantCoat","Coat"},
 }
 if id=="cash100k" or id=="cash1m" then
  local expected=id=="cash100k" and "100K" or "1M"
  for _,v in ipairs(gachapons:GetChildren()) do
   local amount=v:FindFirstChild("Amount")
   if amount and amount:IsA("TextLabel") and amount.Text==expected then return v end
  end
 end
 return findNamed(gachapons,names[id] or {id})
end
local function allRings(wheel)
 local gachapons=wheel:FindFirstChild("Gachapons",true)
 local entries={}
 if not gachapons then return entries end
 for _,v in ipairs(gachapons:GetDescendants()) do
  if v.Name=="GlowingRing" and v:IsA("GuiObject") then
   local item=v.Parent
   while item and item.Parent~=gachapons do item=item.Parent end
   if item and item:IsA("GuiObject") then
    table.insert(entries,{ring=v,card=item})
    v.Visible=false
   end
  end
 end
 table.sort(entries,function(a,b)
  local ai=a.card.LayoutOrder;local bi=b.card.LayoutOrder
  return if ai==bi then a.card.Name<b.card.Name else ai<bi
 end)
 return entries
end
local running=false
function M.spin(wheel,result,done)
 if running then return end
 running=true
 task.spawn(function()
  local ok,err=pcall(function()
   local entries=allRings(wheel)
   if #entries==0 then return end
   local target=targetWheelCard(wheel,result.id)
   local last=math.random(1,#entries)
   local steps=math.random(20,27)
   local targetIndex
   for i,e in ipairs(entries) do if target and (e.card==target or target:IsDescendantOf(e.card)) then targetIndex=i;break end end
   if targetIndex then
    local offset=(targetIndex-last)%#entries
    steps+=((offset-steps)%#entries)
   end
   for step=1,steps do
    for _,e in ipairs(entries) do e.ring.Visible=false end
    last=last%#entries+1
    entries[last].ring.Visible=true
    sound(88442833509532,.55)
    local x=step/steps
    task.wait(.045+.18*x*x)
   end
   for _=1,3 do
    entries[last].ring.Visible=false;task.wait(.17)
    entries[last].ring.Visible=true;task.wait(.24)
   end
   task.wait(.18)
   for _,e in ipairs(entries) do e.ring.Visible=false end
  end)
  if not ok then warn("[HalloweenWheel]",err) end
  sound(6161421479,.8)
  sound(104644728934074,.8)
  running=false
  if done then done() end
 end)
end
function M.install(shop,wheel)
 local list=shop:FindFirstChild("List",true)
 if list then
  applyCard(findNamed(list,{"Squeegee"}),"skin","Sweet")
  applyCard(findNamed(list,{"AsphaltColor"}),"road","pumpkinrescue")
 end
 local gachapons=wheel:FindFirstChild("Gachapons",true)
 if gachapons then
  applyCard(targetWheelCard(wheel,"spell"),"skin","Spell")
  applyCard(targetWheelCard(wheel,"nightmares"),"road","nightmares")
 end
 for _,e in ipairs(allRings(wheel)) do e.ring.Visible=false end
 local coat=targetWheelCard(wheel,"coat")
 if coat then
  local icon=coat:FindFirstChild("ImageLabel")
  if icon then icon.Image="rbxassetid://129999413073221" end
 end
end
return M
