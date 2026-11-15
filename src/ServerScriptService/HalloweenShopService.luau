local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local SSS=game:GetService("ServerScriptService")
local Marketplace=game:GetService("MarketplaceService")
local Http=game:GetService("HttpService")
local C=require(RS.HalloweenShopConfig)
local State=require(RS.HalloweenShopState)
local Currency=require(SSS.PumpkinCurrency)
local Boosts=require(RS.SealerUI.Boosts)
local remote=RS:WaitForChild("HalloweenShopRemote")
local Diagnostics=require(RS:WaitForChild("HalloweenDiagnostics"))
local allowed={[140010128837133]=true,[130455840259328]=true,[120014184236770]=true,[126526085744847]=true,[138676726700999]=true}
local busy,dirty,last={},{},{}
local debugLast=setmetatable({},{__mode="k"})
local function tell(p,text) if p.Parent then remote:FireClient(p,"Message",text) end end
local function save(p)
 local hook=SSS:FindFirstChild("GraveyardSave")
 if not hook then return false end
 local ok,result=pcall(function() return hook:Invoke(p) end)
 if ok and result==true then dirty[p]=nil;return true end
 dirty[p]=true;return false
end
local function getCash(p)
 local stats=p:FindFirstChild("leaderstats")
 local c=stats and stats:FindFirstChild("Cash")
 if c and c:IsA("IntValue") then return c end
 return nil
end
local function deliverHelpers(p)
 local s=State.read(p)
 if s.helpers>0 then
  for _=1,s.helpers do s.pendingHelpers[Http:GenerateGUID(false)]=true end
  s.helpers=0;State.write(p,s)
  if not save(p) then return end
 end
 for id in pairs(s.pendingHelpers) do
  local ok,delivered=pcall(function() return require(SSS.RobotService).grantCredit(p,"Halloween:"..id) end)
  if not ok or delivered~=true then return end
  s.pendingHelpers[id]=nil;State.write(p,s)
  if not save(p) then return end
 end
end
local function syncTools(p)
 if not dirty[p] then deliverHelpers(p) end
 local s=State.read(p)
 local bag=p:FindFirstChild("Backpack")
 -- All unstarted Helpers use RobotService's one counted Tool.
 for _,parent in ipairs({bag,p.Character}) do
  if parent then for _,v in ipairs(parent:GetChildren()) do if v:IsA("Tool") and v:GetAttribute("HalloweenConsumable")=="Helper" then v:Destroy() end end end
 end
 for _,entry in ipairs({{"Coat",s.coats}}) do
  local typ,count=entry[1],entry[2]
  local existing={}
  for _,parent in ipairs({bag,p.Character}) do
   if parent then for _,item in ipairs(parent:GetChildren()) do
    if item:IsA("Tool") and item:GetAttribute("HalloweenConsumable")==typ then table.insert(existing,item) end
   end end
  end
  local tool=existing[1]
  for i=2,#existing do existing[i]:Destroy() end
  if count<=0 then if tool then tool:Destroy() end
  elseif tool then tool.Name="Instant Coat ("..count..")";tool.TextureId="rbxassetid://129999413073221"
  elseif bag then
   tool=Instance.new("Tool")
   tool.Name=(typ=="Helper" and "Helper" or "Instant Coat").." ("..count..")"
   tool.RequiresHandle=false;tool.CanBeDropped=false
   tool.TextureId="rbxassetid://129999413073221"
   tool:SetAttribute("HalloweenConsumable",typ)
   tool.Activated:Connect(function()
    if busy[p] or dirty[p] or not Currency.ready(p) or tool.Parent~=p.Character then return end
    busy[p]=true
    local current=State.read(p)
    local field=typ=="Helper" and "helpers" or "coats"
    if current[field]<=0 then busy[p]=nil;return end
    if typ=="Helper" then
     local ok,result=pcall(function() return require(SSS.RobotService).grantCredit(p) end)
     if not ok or result==false then busy[p]=nil;tell(p,"Helper could not be activated.");return end
    else
     local boost=Boosts.ById.Endless
     local attr=Boosts.attrName(boost.id)
     p:SetAttribute(attr,math.max(Boosts.now(),p:GetAttribute(attr) or 0)+boost.seconds)
    end
    current[field]-=1;State.write(p,current)
    dirty[p]=true
    local saved=save(p)
    syncTools(p)
    busy[p]=nil
    tell(p,saved and "Item activated!" or "Item activated, save pending.")
   end)
   tool.Parent=bag
  end
 end
end
local function reward(p,s)
 local r=C.pick(math.random(1,100))
 local duplicate=false
 if r.id=="pumpkins" then Currency.award(p,50)
 elseif r.id=="tickets" then p:SetAttribute("SpinCount",(p:GetAttribute("SpinCount") or 0)+3)
 elseif r.id=="cash100k" then local c=getCash(p);if not c then error("Cash missing") end;c.Value+=100000
 elseif r.id=="cash1m" then local c=getCash(p);if not c then error("Cash missing") end;c.Value+=1000000
 elseif r.id=="helper" then s.helpers+=1
 elseif r.id=="coat" then s.coats+=1
 elseif r.id=="nightmares" then duplicate=s.owned.Nightmares==true or p:GetAttribute("HalloweenOwned_Nightmares")==true;s.owned.Nightmares=true
 elseif r.id=="spell" then duplicate=s.owned.Spell==true or p:GetAttribute("HalloweenOwned_Spell")==true;s.owned.Spell=true end
 if duplicate then assert(Currency.award(p,C.DuplicatePumpkins),"Duplicate reward requires a loaded profile") end
 return {id=r.id,name=duplicate and (r.name.." (duplicate: +"..C.DuplicatePumpkins.." Pumpkins)") or r.name,compensation=duplicate and C.DuplicatePumpkins or 0}
end
local function transact(p,key,receipt)
 local before=p:GetAttribute("PumpkinCoins") or 0
 local s=State.read(p)
 if receipt and s.receipts[receipt] then return save(p) end
 if not Currency.ready(p) or not getCash(p) then return false end
 if C.ItemOwnedKey[key] and s.owned[C.ItemOwnedKey[key]] then
  if receipt then s.receipts[receipt]=true;State.write(p,s);return save(p) end
  tell(p,"Already owned!");return false
 end
 if not receipt then
  local price=C.Prices[key]
  local amount=p:GetAttribute("PumpkinCoins") or 0
  if amount<price then tell(p,"Not enough pumpkins");return false end
  p:SetAttribute("PumpkinCoins",amount-price)
  p:SetAttribute("PumpkinSpentTotal",(p:GetAttribute("PumpkinSpentTotal") or 0)+price)
 end
 local result
 if key=="Roll" then result=reward(p,s) else s.owned[C.ItemOwnedKey[key]]=true end
 if receipt then s.receipts[receipt]=true end
 State.write(p,s);dirty[p]=true
 local saved=save(p)
 syncTools(p)
 if result then
  result.spent=receipt and 0 or C.Prices.Roll;result.balanceBefore=before;result.balanceAfter=p:GetAttribute("PumpkinCoins")
  Diagnostics.record(p,"HalloweenShop","Roll",string.format("reward=%s before=%d cost=%d duplicateRefund=%d after=%d saved=%s",result.id,before,result.spent,result.compensation,result.balanceAfter,tostring(saved)))
  remote:FireClient(p,"RollResult",result)
 else tell(p,key=="Squeegee" and "Trick or Sweet! unlocked in Squeegee Skins!" or "Pumpkin Rescue unlocked in Asphalt Colors!") end
 if not saved then tell(p,"Reward received; saving is delayed.") end
 return saved
end
local module={}
function module.isProduct(id)
 for _,value in pairs(C.Products) do if value>0 and value==id then return true end end
 return false
end
function module.receipt(info)
 local p=Players:GetPlayerByUserId(info.PlayerId)
 if not p or not Currency.ready(p) or busy[p] then return Enum.ProductPurchaseDecision.NotProcessedYet end
 local key
 for k,id in pairs(C.Products) do if id>0 and id==info.ProductId then key=k;break end end
 if not key then return Enum.ProductPurchaseDecision.NotProcessedYet end
 busy[p]=true
 local ok,result=pcall(transact,p,key,tostring(info.PurchaseId))
 busy[p]=nil
 if not ok then dirty[p]=true;warn("[HalloweenShop]",result) end
 return ok and result and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
end
local started=false
function module.start()
 if started then return end;started=true
 remote.OnServerEvent:Connect(function(p,action,key)
  if action=="Debug" then
   local now=os.clock();if now-(debugLast[p] or -10)<2 then return end;debugLast[p]=now
   local text=string.format("place=%d profile=%s currencyReady=%s busy=%s dirty=%s pumpkins=%s",game.PlaceId,tostring(p:GetAttribute("ProfileLoaded")),tostring(Currency.ready(p)),tostring(busy[p]),tostring(dirty[p]),tostring(p:GetAttribute("PumpkinCoins")))
   remote:FireClient(p,"Debug",text.."\n"..table.concat(Diagnostics.history(p),"\n"));return
  end
  if type(key)~="string" or not C.Prices[key] or not Currency.ready(p) then return end
  if not allowed[game.PlaceId] or os.time()>=C.EndsAt or busy[p] or dirty[p] then return end
  if os.clock()-(last[p] or -10)<.8 then return end;last[p]=os.clock()
  if action=="Robux" then
   if C.Products[key]<=0 then tell(p,"Robux purchases are unavailable.");return end
   if C.ItemOwnedKey[key] and State.read(p).owned[C.ItemOwnedKey[key]] then tell(p,"Already owned!");return end
   local ok=pcall(Marketplace.PromptProductPurchase,Marketplace,p,C.Products[key])
   if not ok then tell(p,"Could not open purchase prompt.") end
  elseif action=="Buy" then
   busy[p]=true
   local ok,err=pcall(transact,p,key)
   busy[p]=nil
   if not ok then dirty[p]=true;warn("[HalloweenShop]",err) end
  end
 end)
 local function join(p)
  local function sync()
   if not p.Parent or not Currency.ready(p) or busy[p] then return end
   busy[p]=true
   local ok,err=pcall(syncTools,p)
   busy[p]=nil
   if not ok then warn("[HalloweenShop] inventory sync",err) end
  end
  p.CharacterAdded:Connect(function() task.delay(1,sync) end)
  p:GetAttributeChangedSignal("ProfileLoaded"):Connect(sync)
  task.defer(sync)
 end
 Players.PlayerAdded:Connect(join)
 for _,p in ipairs(Players:GetPlayers()) do join(p) end
 Players.PlayerRemoving:Connect(function(p) busy[p]=nil;dirty[p]=nil;last[p]=nil end)
 task.spawn(function()
  while task.wait(10) do
   for _,p in ipairs(Players:GetPlayers()) do
    if Currency.ready(p) and not busy[p] then
     busy[p]=true
     local ok,err=pcall(function() if not dirty[p] or save(p) then syncTools(p) end end)
     busy[p]=nil
     if not ok then warn("[HalloweenShop] inventory retry",err) end
    end
   end
  end
 end)
end
return module
