local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local DSS=game:GetService("DataStoreService")
local Http=game:GetService("HttpService")
local Pack=RS:WaitForChild("StellarQuest")
local C=require(Pack.StellarConfig)
local Logic=require(Pack.StellarLogic)
local remote=Pack:WaitForChild("Remote")
local studio=game:GetService("RunService"):IsStudio()
local store=DSS:GetDataStore(C.Store..(studio and "_Studio" or ""))
local sessions={}
local M={}
local function publish(p,s)
 local d,e=Logic.normalize(s.data)
 local view=Http:JSONDecode(Http:JSONEncode(d))
 if s.inflight then view=Logic.apply(view,s.inflight) end
 view=Logic.apply(view,{session=s.id,seq=s.seq+1,days=s.pending})
 local _,preview=Logic.normalize(view)
 p:SetAttribute("StellarReady",true)
 p:SetAttribute("StellarTestDay",e.testDay)
 p:SetAttribute("TruckVFXPaidOwned",d.paid==true)
 p:SetAttribute("TruckVFXStellarOwned",e.earned==true)
 p:SetAttribute("TruckVFXSelected",d.selected or "")
 p:SetAttribute("StellarState",Http:JSONEncode({days=preview.days,completed=Logic.completed(e),earned=e.earned==true,claimed=e.claimed==true}))
end
function M.record(p,id,amount,day)
 local s=sessions[p]
 if not s or not s.ready or not C.Tasks[id] then return end
 day=day or C.day(os.time(),p:GetAttribute("StellarTestDay"))
 if not day then return end
 local key=tostring(day)
 s.pending[key]=s.pending[key] or {}
 s.pending[key][id]=(s.pending[key][id] or 0)+amount
end
local function transaction(p,change)
 local s=sessions[p]
 if not s or not s.ready then return false end
 local deadline=os.clock()+12
 while s.busy and os.clock()<deadline do task.wait(.1) end
 if s.busy then return false end
 s.busy=true
 -- Keep the SAME batch after a timeout: UpdateAsync may already have committed it.
 if not s.inflight then
  s.seq+=1
  s.inflight={session=s.id,seq=s.seq,days=s.pending}
  s.pending={}
 end
 local batch=s.inflight
 local ok,result=pcall(function()
  return store:UpdateAsync("u_"..p.UserId,function(raw)
   local d,e=Logic.apply(raw,batch)
   if change then change(d,e) end
   return d
  end)
 end)
 if ok and type(result)=="table" then
  s.data=result;s.inflight=nil
  if p.Parent then publish(p,s) end
 else
  warn("[StellarQuest] Save pending for "..p.UserId..": "..tostring(result))
 end
 s.busy=false
 return ok and type(result)=="table"
end
-- Server-console test helper only; deliberately not exposed through the remote.
function M.setTestDay(p,day)
 if day~=nil and (type(day)~="number" or day%1~=0 or not C.Pairs[day]) then return false end
 return transaction(p,function(_,event) event.testDay=day end)
end
function M.restoreMaxima(p,data)
 p:SetAttribute("StellarW2Extra",Http:JSONEncode(type(data.World2Extra)=="table" and data.World2Extra or {}))
end
local function allMaxed(p)
 local ok,extras=pcall(Http.JSONDecode,Http,p:GetAttribute("StellarW2Extra") or "{}")
 if not ok or type(extras)~="table" then return false end
 local worlds=RS.SealerUI:FindFirstChild("WorldsConfig")
 local world
 if worlds then local _,w=require(worlds).resolve(game.PlaceId);world=w end
 for id,base in pairs(C.BaseMax) do
  local level=p:GetAttribute("Upg_"..id) or 1
  if level<base then return false end
  if p:GetAttribute("World2Unlocked")==true then
   local extra=world==2 and math.max(0,level-base) or (tonumber(extras[id]) or 0)
   if extra<3 then return false end
  end
 end
 return true
end
local function claim(p)
 local s=sessions[p]
 if not s then return end
 if not transaction(p) then remote:FireClient(p,"Message","Save pending. Please try again.");return end
 local _,e=Logic.normalize(s.data)
 if not e.earned or e.claimed then return end
 local robot=require(game.ServerScriptService:WaitForChild("RobotService"))
 for i=1,2 do
  if not robot.grantCredit(p,C.EventId..":"..p.UserId..":"..i) then
   remote:FireClient(p,"Message","Helper delivery pending. Please try CLAIM again.");return
  end
 end
 if transaction(p,function(_,event) event.claimed=true end) then
  remote:FireClient(p,"Message","Rewards claimed: 2 Helper uses + exclusive Truck VFX!")
 end
end
function M.isProduct(id) return id==C.ProductId end
function M.receipt(info)
 local p=Players:GetPlayerByUserId(info.PlayerId)
 if not p or not p:GetAttribute("ProfileLoaded") then return Enum.ProductPurchaseDecision.NotProcessedYet end
 if not transaction(p,function(d) d.paid=true end) then return Enum.ProductPurchaseDecision.NotProcessedYet end
 return Enum.ProductPurchaseDecision.PurchaseGranted
end
local function loaded(p)
 if sessions[p] then return end
 local s={id=Http:GenerateGUID(false),seq=0,pending={},ready=false,data={}}
 sessions[p]=s
 while p.Parent and p:GetAttribute("ProfileLoaded")~=true do task.wait(.2) end
 if not p.Parent then sessions[p]=nil;return end
 while p.Parent and not s.ready do
  local ok,data=pcall(function() return store:GetAsync("u_"..p.UserId) end)
  if ok then s.data=Logic.normalize(data);s.ready=true;s.joinedAt=os.time();publish(p,s)
  else warn("[StellarQuest] Load retry for "..p.UserId);task.wait(8) end
 end
 if not p.Parent then sessions[p]=nil;return end
 local function counter(attr,id)
  local previous=tonumber(p:GetAttribute(attr)) or 0
  p:GetAttributeChangedSignal(attr):Connect(function()
   local value=tonumber(p:GetAttribute(attr)) or 0
   if value>previous then M.record(p,id,value-previous) end
   previous=value
  end)
 end
 counter("Q_Sealed","roads");counter("Q_Upgrades","upgrades")
 p:GetAttributeChangedSignal("Rebirths"):Connect(function()
  -- Every rebirth clears shared upgrade extras in the existing profile code.
  -- Do not keep the pre-rebirth World 2 maxima snapshot in World 1.
  p:SetAttribute("StellarW2Extra","{}")
 end)
 local color=p:GetAttribute("AsphaltColorEquipped")
 p:GetAttributeChangedSignal("AsphaltColorEquipped"):Connect(function()
  local value=p:GetAttribute("AsphaltColorEquipped")
  if value and value~=color then M.record(p,"color",1) end
  color=value
 end)
 -- Joining a server with a friend also counts; no unverified client completion.
 for _,other in ipairs(Players:GetPlayers()) do
  if other~=p then task.spawn(function()
   local ok,friends=pcall(function() return p:IsFriendsWithAsync(other.UserId) end)
   if ok and friends and p.Parent and other.Parent then
    M.record(p,"friend",1);M.record(other,"friend",1)
   end
  end) end
 end
end
local started=false
function M.start()
 if started then return end;started=true
 Players.PlayerAdded:Connect(function(p) task.spawn(loaded,p) end)
 for _,p in ipairs(Players:GetPlayers()) do task.spawn(loaded,p) end
 Players.PlayerRemoving:Connect(function(p)
  local s=sessions[p]
  if s and s.ready and (s.inflight or next(s.pending)~=nil) then
   for _=1,3 do
    transaction(p)
    if not s.inflight and next(s.pending)==nil then break end
   end
  end
  sessions[p]=nil
 end)
 local last=setmetatable({},{__mode="k"})
 remote.OnServerEvent:Connect(function(p,action,value)
  if os.clock()-(last[p] or -10)<.4 then return end;last[p]=os.clock()
  local s=sessions[p]
  if not s or not s.ready or p:GetAttribute("ProfileLoaded")~=true then return end
  if action=="Claim" then claim(p)
  elseif action=="Refresh" then transaction(p)
  elseif action=="Equip" then
   local _,e=Logic.normalize(s.data)
   if value~="" and value~="Haunted" and value~="Paid" and value~="Stellar" then return end
   if value=="Paid" and not s.data.paid then return end
   if value=="Stellar" and not e.earned then return end
   if value=="Haunted" and p:GetAttribute("GraveyardClaim4")~=1 then return end
   if transaction(p,function(d) d.selected=value end) then
    p:SetAttribute("HalloweenTruckEquipped",value=="Haunted")
   end
  end
 end)
 task.spawn(function()
  local tickAt=os.time()
  local sinceSave=0
  while task.wait(5) do
   local now=os.time()
   local first=math.max(tickAt,C.StartAt)
   local finish=math.min(now,C.EndAt)
   for p,s in pairs(sessions) do
    if s.ready and p.Parent and p:GetAttribute("ProfileLoaded")==true then
     -- Split seconds over UTC midnight so yesterday never consumes today's time.
     local cursor=math.max(first,s.joinedAt)
     while cursor<finish do
      local boundary=math.min(finish,(math.floor(cursor/86400)+1)*86400)
      M.record(p,"play",boundary-cursor,C.day(cursor,p:GetAttribute("StellarTestDay")));cursor=boundary
     end
     if C.day(now) then
      if allMaxed(p) then M.record(p,"upgrades",2) end
      local golden=require(RS.SealerUI.GoldenHour)
      if golden.active() and golden.appliesTo(p) then M.record(p,"golden",1) end
     end
     publish(p,s)
    end
   end
   tickAt=now;sinceSave+=5
   if sinceSave>=45 then
    sinceSave=0
    for p,s in pairs(sessions) do
     if s.ready and (s.inflight or next(s.pending)~=nil) then task.spawn(transaction,p) end
    end
   end
  end
 end)
 game:BindToClose(function()
  local left=0
  for p,s in pairs(sessions) do if s.ready and (s.inflight or next(s.pending)~=nil) then left+=1;task.spawn(function() transaction(p);left-=1 end) end end
  local deadline=os.clock()+24
  while left>0 and os.clock()<deadline do task.wait(.1) end
 end)
 print("[StellarQuest] Ready; 21 Oct - 1 Nov UTC; shared across worlds")
end
return M
