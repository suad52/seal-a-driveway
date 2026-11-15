local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local SSS=game:GetService("ServerScriptService")
local Sections=require(RS.DrivewaySealer.Sections)
local Currency=require(SSS.PumpkinCurrency)
local Remote=RS:WaitForChild("GraveyardRemote")
local holiday=game.PlaceId==138676726700999
local pending,busy,last={},{},{}
local function active() return os.time()<1793577600 end
local function number(p,k) return tonumber(p:GetAttribute(k)) or 0 end
local function save(p)
 local hook=SSS:FindFirstChild("GraveyardSave")
 if not hook then return false end
 local ok,result=pcall(function() return hook:Invoke(p) end)
 return ok and result==true
end
local revisions={}
local function mark(p)
 revisions[p]=(revisions[p] or 0)+1
 pending[p]=revisions[p]
end
local function flush(p)
 local revision=pending[p]
 local ok=save(p)
 if ok and pending[p]==revision then pending[p]=nil end
 return ok
end
local function completed(p)
 local now=Sections.nowSetOf(p)
 local total,done=0,0
 for _,section in ipairs(Sections.List) do
  for _,slab in ipairs(Sections.slabsOf(section)) do
   total+=1
   if now[Sections.keyOf(slab)] then done+=1 end
  end
 end
 return total>0 and done==total
end
local function notify(p,text) if p.Parent then Remote:FireClient(p,"Toast",text) end end
local function check(p)
 if not holiday or not active() or not Currency.ready(p) or busy[p] then return end
 if p:GetAttribute("GraveyardLapComplete") or not completed(p) then return end
 -- No yield between checking and recording the lap. Joining a completed map is also counted once.
 p:SetAttribute("GraveyardLapComplete",true)
 p:SetAttribute("GraveyardRuns",number(p,"GraveyardRuns")+1)
 mark(p)
 task.spawn(function()
  flush(p)
  if p.Parent then Remote:FireClient(p,"Completed") end
 end)
end
local function watch(p)
 p:GetAttributeChangedSignal("SealedNow"):Connect(function() task.defer(check,p) end)
 p:GetAttributeChangedSignal("ProfileLoaded"):Connect(function() task.defer(check,p) end)
 task.defer(check,p)
end
Players.PlayerAdded:Connect(watch)
for _,p in ipairs(Players:GetPlayers()) do watch(p) end
Remote.OnServerEvent:Connect(function(p,action,index)
 if not Currency.ready(p) or busy[p] then return end
 if os.clock()-(last[p] or 0)<.5 then return end
 last[p]=os.clock()
 if action=="EquipTruck" then
  if number(p,"GraveyardClaim4")~=1 then return end
  p:SetAttribute("HalloweenTruckEquipped",index==true)
  mark(p)
  return
 end
 if not holiday or not active() then return end
 if action=="Claim" then
  if type(index)~="number" or index%1~=0 or index<1 or index>4 then return end
  if number(p,"GraveyardRuns")<index or number(p,"GraveyardClaim"..index)==1 then return end
  p:SetAttribute("GraveyardClaim"..index,1)
  if index==1 then Currency.award(p,50) end
  if index==3 then Currency.award(p,120) end
  mark(p)
  busy[p]=true
  flush(p)
  busy[p]=nil
  if index==4 then notify(p,"New Truck skin available in Squeegee Skins menu")
  elseif index==2 then notify(p,"Witch's Brew unlocked in Asphalt Colors!")
  else notify(p,"Reward claimed!") end
 elseif action=="Reset" then
  if not p:GetAttribute("GraveyardLapComplete") or not completed(p) then return end
  busy[p]=true
  -- First persist the completed lap; never erase an unsaved completion.
  if not save(p) then busy[p]=nil;notify(p,"Could not save. Please try again.");return end
  p:SetAttribute("SecSealed","")
  p:SetAttribute("SealedNow","")
  p:SetAttribute("GraveyardLapComplete",false)
  require(SSS.RebirthBus).fire(p)
  p:SetAttribute("GraveyardResetVersion",number(p,"GraveyardResetVersion")+1)
  mark(p)
  flush(p)
  busy[p]=nil
  Remote:FireClient(p,"Reset")
 end
end)
task.spawn(function()
 while task.wait(15) do
  for p in pairs(pending) do
   if not p.Parent then pending[p]=nil
   elseif not busy[p] then
    busy[p]=true
    flush(p)
    busy[p]=nil
   end
  end
 end
end)
Players.PlayerRemoving:Connect(function(p) pending[p]=nil;busy[p]=nil;last[p]=nil;revisions[p]=nil end)
if holiday then
 task.spawn(function()
  local gift=workspace:WaitForChild("RoadReward")
  local part=gift:WaitForChild("InteractionPart")
  local prompt=part:FindFirstChildOfClass("ProximityPrompt") or Instance.new("ProximityPrompt",part)
  prompt.ObjectText="Graveyard Road Rewards";prompt.ActionText="View rewards"
  prompt.KeyboardKeyCode=Enum.KeyCode.E;prompt.GamepadKeyCode=Enum.KeyCode.ButtonX
  prompt.Triggered:Connect(function(p)
   local root=p.Character and p.Character:FindFirstChild("HumanoidRootPart")
   if root and (root.Position-part.Position).Magnitude<=20 then Remote:FireClient(p,"Open") end
  end)
 end)
end
