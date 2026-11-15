local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SS = game:GetService("ServerStorage")
local CS = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Marketplace = game:GetService("MarketplaceService")
local Pack = RS:WaitForChild("DrivewaySealer")
local Config = require(Pack.RobotConfig)
local SurfaceFrame = require(Pack.SurfaceFrame)
local Sections = require(Pack.Sections)
local Store = require(script.Parent.RobotStore)
local M = {}
local states = {}
local remote = Pack:WaitForChild("RobotRemote")
local started = false
local function publish(p,s)
	p:SetAttribute("RobotReady", true)
	p:SetAttribute("RobotCredits", s.credits)
	p:SetAttribute("RobotRemaining", math.ceil(s.remaining))
end
local function stop(s)
	if s.model then s.model:Destroy(); s.model=nil end
	s.slab=nil; s.ready=false;s.label=nil
end
local function tool(p,s)
 local title=Config.Name..(s.credits>0 and (" ("..s.credits..")") or " (active)")
	if s.credits<=0 and s.remaining<=0 then
		for _,parent in ipairs({p.Backpack,p.Character}) do if parent then for _,t in ipairs(parent:GetChildren()) do if t:GetAttribute("RobotHelperTool") then t:Destroy() end end end end
		return
	end
	for _,parent in ipairs({p.Backpack,p.Character}) do if parent then for _,t in ipairs(parent:GetChildren()) do if t:GetAttribute("RobotHelperTool") then t.Name=title;return end end end end
	local t=Instance.new("Tool");t.Name=title;t.TextureId=Config.Image;t.RequiresHandle=false;t.CanBeDropped=false;t.ToolTip="Tap a road to place or move your robot";t:SetAttribute("RobotHelperTool",true)
	local held=SS.RobotHelperAssets.Robot:Clone();held.Name="HeldRobot";held:ScaleTo(.6)
	local handle=held:FindFirstChild("robot",true) or held:FindFirstChildWhichIsA("BasePart",true)
	if handle then
		for _,d in ipairs(held:GetDescendants()) do
			if d:IsA("BillboardGui") then d.Enabled=false elseif d:IsA("Script") or d:IsA("LocalScript") then d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored=false;d.CanCollide=false;d.CanTouch=false;d.CanQuery=false;d.Massless=true
				if d~=handle then local weld=Instance.new("WeldConstraint");weld.Part0=handle;weld.Part1=d;weld.Parent=handle end
			end
		end
		held.Parent=t;handle.Name="Handle";handle.Parent=t;t.RequiresHandle=true
	end
	t.Parent=p.Backpack
end
local function checkpoint(p,s,release)
	if s.pendingActivation then s.frozen=true;return nil end
	local d=Store.write(p.UserId,function(d) d.remaining=s.remaining;return d end,false,release)
	if d then s.credits=d.credits;s.saved=os.clock();s.frozen=false else s.frozen=true;if p.Parent then remote:FireClient(p,"Message","Robot paused: progress could not be saved. Retrying.") end end
	return d
end
local function valid(p,slab)
	if typeof(slab)~="Instance" or not slab:IsA("BasePart") or not slab:IsDescendantOf(workspace) or not CS:HasTag(slab,Sections.Tag) then return false end
	for index = 1, 2 do
        local bonus = workspace:FindFirstChild("BonusZone" .. index)
        if bonus and slab:IsDescendantOf(bonus) then
            local roads = bonus:FindFirstChild("Road")
            return roads ~= nil and slab:IsDescendantOf(roads)
                and p:GetAttribute("BonusClear_" .. index) == true
        end
    end
    for _,name in ipairs(Sections.reachableGround(function(id) return p:GetAttribute(Sections.openAttr(id))==true end)) do
		local c=workspace:FindFirstChild(name)
		if c and slab:IsDescendantOf(c) then return true end
	end
	local garage=workspace:FindFirstChild("ParkingGarage")
	return garage~=nil and slab:IsDescendantOf(garage) and p:GetAttribute(Sections.openAttr("Airport"))==true
end
local function spawnRobot(p,s,slab,position)
	stop(s)
	local model=SS.RobotHelperAssets.Robot:Clone()
	model.Name="RobotHelper_"..p.UserId
	for _,d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then d.Anchored=true;d.CanCollide=false;d.CanTouch=false;d.CanQuery=false
		elseif d:IsA("BillboardGui") then d.Enabled=false elseif d:IsA("Script") or d:IsA("LocalScript") then d:Destroy() end
	end
	model:SetAttribute("RobotOwner",p.UserId)
	local root=model:FindFirstChild("RootPart",true) or model:FindFirstChild("Primary",true) or model.PrimaryPart
 assert(root and root:IsA("BasePart"),"Helper requires a RootPart or Primary BasePart")
 local pivot=root.CFrame
 s.rootToPivot=pivot:ToObjectSpace(model:GetPivot())
	local bottom=math.huge
	for _,part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name~="BillboardPart" and part.Transparency<1 then
			for _,x in ipairs({-1,1}) do for _,y in ipairs({-1,1}) do for _,z in ipairs({-1,1}) do
						local point=pivot:PointToObjectSpace(part.CFrame:PointToWorldSpace(part.Size*Vector3.new(x,y,z)/2))
						bottom=math.min(bottom,point.Y)
					end end end
		end
	end
	s.bottom=if bottom<math.huge then bottom else 0
	s.yaw=0
	local pose=CFrame.new(position)*CFrame.new(0,-s.bottom,0)*s.rootToPivot
	model:PivotTo(pose)
	model:SetAttribute("HelperPose",pose)
	model.ModelStreamingMode=Enum.ModelStreamingMode.Persistent
	model.Parent=workspace;s.model=model;s.slab=slab;s.position=position;s.ready=false;s.index=0;s.target=nil;s.done=false;s.version=(s.version or 0)+1
	local board=model:FindFirstChild("BillboardPart",true)
	local gui=board and board:FindFirstChild("BillboardGui")
	local label=gui and gui:FindFirstChild("TextLabel",true)
	assert(label and label:IsA("TextLabel"),"Robot.BillboardPart.BillboardGui.TextLabel is missing")
	gui.Enabled=true;gui.Adornee=board
	s.label=label
	game:GetService("CollectionService"):AddTag(model,"HelperMovingRobot")
	remote:FireClient(p,"Target",slab,s.version)
end
local function placement(p,slab,pos)
 local function reject(code)
  require(RS.HalloweenDiagnostics).record(p,"HelperServer",code,typeof(slab)=="Instance" and slab:GetFullName() or "Invalid target",true)
  remote:FireClient(p,"Message","Cannot place Helper: "..code)
 end
 local s=states[p]
 if not s then reject("Inventory loading");return end
 if s.frozen and not s.pendingActivation then reject("Save pending");return end
 if not p:GetAttribute("ProfileLoaded") then reject("Profile loading");return end
 if typeof(pos)~="Vector3" or pos.X~=pos.X or pos.Y~=pos.Y or pos.Z~=pos.Z or pos.Magnitude>1e7 then reject("Invalid point");return end
 local hrp=p.Character and p.Character:FindFirstChild("HumanoidRootPart")
 local equipped=p.Character and p.Character:FindFirstChildWhichIsA("Tool")
 if not equipped or not equipped:GetAttribute("RobotHelperTool") then reject("Equip Helper first");return end
 if not hrp or (hrp.Position-pos).Magnitude>Config.PlaceRange then reject("Too far away");return end
 if pos.Y-hrp.Position.Y>6 or pos.Y-hrp.Position.Y < -12 then reject("Different road height");return end
 if not valid(p,slab) then reject("Road not unlocked");return end
 if Sections.nowSetOf(p)[Sections.keyOf(slab)] then reject("Road already finished");return end
 local rp=RaycastParams.new();rp.FilterType=Enum.RaycastFilterType.Include;rp.FilterDescendantsInstances={slab}
 -- The authored union's local UpVector may point sideways. Cast vertically onto its real top.
 local hit=workspace:Raycast(pos+Vector3.new(0,6,0),Vector3.new(0,-20,0),rp)
 if not hit or hit.Normal.Y<.45 then reject("No road surface");return end
 if (hrp.Position-hit.Position).Magnitude>Config.PlaceRange then reject("Too far away");return end
 require(RS.HalloweenDiagnostics).record(p,"HelperServer","Placed",slab:GetFullName())
	if s.remaining<=0 then
		if s.credits<=0 then return end
		s.pendingActivation=s.pendingActivation or game:GetService("HttpService"):GenerateGUID(false)
		local d=Store.write(p.UserId,function(d)
			if d.activation==s.pendingActivation then return d end
			if d.credits<=0 then return nil end
			d.credits-=1;d.remaining=Config.Duration;d.activation=s.pendingActivation;return d
		end)
		if not d then remote:FireClient(p,"Message","Could not activate the robot. Please try again.");return end
		s.pendingActivation=nil;s.credits=d.credits;s.remaining=d.remaining;s.saved=os.clock();s.frozen=false
	end
	spawnRobot(p,s,slab,hit.Position);publish(p,s)
end
local function nextTarget(s)
	local slab=s.slab
 local slabCF, size=SurfaceFrame.of(slab)
	local step=Config.Radius*1.2
	local nx=math.max(1,math.ceil(size.X/step));local nz=math.max(1,math.ceil(size.Z/step))
	local i=s.index%(nx*nz);s.index+=1
	local z=math.floor(i/nx);local x=i%nx;if z%2==1 then x=nx-1-x end
	local localPos=Vector3.new(-size.X/2+(x+.5)*size.X/nx,size.Y/2,-size.Z/2+(z+.5)*size.Z/nz)
	local at=slabCF:PointToWorldSpace(localPos)
	local rp=RaycastParams.new();rp.FilterType=Enum.RaycastFilterType.Include;rp.FilterDescendantsInstances={slab}
	local hit=workspace:Raycast(at+slabCF.UpVector*4,-slabCF.UpVector*8,rp)
	return hit and hit.Position
end
function M.isProduct(id) return Config.ProductId>0 and id==Config.ProductId end
function M.processReceipt(info)
	local p=Players:GetPlayerByUserId(info.PlayerId)
	if not p then return Enum.ProductPurchaseDecision.NotProcessedYet end
	return Store.serial(p.UserId,function()
		local s=states[p];if not s then return Enum.ProductPurchaseDecision.NotProcessedYet end
		local receipt=tostring(info.PurchaseId)
		local d=Store.write(p.UserId,function(d)
			if not s.pendingActivation then d.remaining=s.remaining end
			d.receipts=d.receipts or {}
			if not d.receipts[receipt] then d.receipts[receipt]=true;d.credits+=1 end
			return d
		end)
		if not d then return Enum.ProductPurchaseDecision.NotProcessedYet end
		s.credits=d.credits;s.saved=os.clock();publish(p,s);tool(p,s)
		remote:FireClient(p,"Message","Robot received! Equip Helper and tap a road.")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end) or Enum.ProductPurchaseDecision.NotProcessedYet
end
function M.grantCredit(p,grantId)
 return Store.serial(p.UserId,function()
  local s=states[p]
  if not s then return false end
  local d=Store.write(p.UserId,function(d)
   if grantId then
    d.eventGrants=type(d.eventGrants)=="table" and d.eventGrants or {}
    if d.eventGrants[grantId] then return d end
    d.eventGrants[grantId]=true
   end
   d.credits=(d.credits or 0)+1
   return d
  end)
  if not d then return false end
  s.credits=d.credits;s.saved=os.clock();publish(p,s);tool(p,s)
  return true
 end)==true
end

local function join(p)
	p:SetAttribute("RobotReady",false)
	p.CharacterAdded:Connect(function() task.defer(function() local s=states[p];if s then tool(p,s) end end) end)
	p:GetAttributeChangedSignal("Rebirths"):Connect(function() local s=states[p];if s then stop(s);remote:FireClient(p,"Target",nil,0) end end)
	task.spawn(function()
		while p.Parent and not states[p] do
			Store.serial(p.UserId,function()
				local d=Store.write(p.UserId,function(d) return d end,true)
				if d then
					if not p.Parent then Store.write(p.UserId,function(x)return x end,false,true);return end
					local s={credits=d.credits or 0,remaining=d.remaining or 0,saved=os.clock(),version=0,lastRequest=0};states[p]=s;publish(p,s);tool(p,s)
				end
			end)
			if not states[p] then task.wait(10) end
		end
	end)
end
local function leave(p)
	return Store.serial(p.UserId,function()
		local s=states[p];if not s then return end
		s.leaving=true;stop(s)
		for _=1,3 do if checkpoint(p,s,true) then break end task.wait(1) end
		states[p]=nil
	end)
end
function M.start()
	if started then return end;started=true
	Players.PlayerAdded:Connect(join);Players.PlayerRemoving:Connect(leave)
	for _,p in ipairs(Players:GetPlayers()) do join(p) end
	remote.OnServerEvent:Connect(function(p,action,a,b)
		local s=states[p];if not s then return end
		if action=="Ready" then if a==s.slab and b==s.version then s.ready=true;s.readyUntil=os.clock()+2 end;return end
		if os.clock()-s.lastRequest<.7 then return end;s.lastRequest=os.clock()
		if action=="Place" then Store.serial(p.UserId,function() placement(p,a,b) end)
		elseif action=="Buy" then if Config.ProductId>0 then Marketplace:PromptProductPurchase(p,Config.ProductId) else remote:FireClient(p,"Message","Robot Helper is not on sale yet.") end
		elseif action=="Test" and RunService:IsStudio() and Config.StudioFreeTest then Store.serial(p.UserId,function() local d=Store.write(p.UserId,function(d)d.credits+=1;return d end);if d then s.credits=d.credits;publish(p,s);tool(p,s) end end) end
	end)
	task.spawn(function()
		while true do
			task.wait(Config.Step)
			for p,s in pairs(states) do
				local now=os.clock();local dt=math.min(now-(s.tick or now),1);s.tick=now
				if s.remaining>0 and not s.frozen and not s.leaving then
					s.remaining=math.max(0,s.remaining-dt)
					if s.remaining==0 then stop(s);tool(p,s);remote:FireClient(p,"Target",nil,0);remote:FireClient(p,"Message","Robot shift finished!") end
				end
				if now-(s.lastPublish or 0)>1 then publish(p,s);s.lastPublish=now end
				if now-math.max(s.saved,s.lastSaveAttempt or 0)>30 and not s.saving then s.lastSaveAttempt=now;s.saving=true;task.spawn(function() Store.serial(p.UserId,function() if states[p]==s then checkpoint(p,s,false) end end);s.saving=false end) end
				if s.slab and (not s.slab:IsDescendantOf(workspace) or not valid(p,s.slab)) then stop(s);remote:FireClient(p,"Target",nil,0) end
				if s.ready and now>(s.readyUntil or 0) then s.ready=false end
				if s.label and now-(s.statusAt or 0)>=.5 then
					s.statusAt=now
					local left=math.ceil(s.remaining)
					s.done=s.slab and Sections.nowSetOf(p)[Sections.keyOf(s.slab)]==true
					s.label.Text=(if s.done then "I'm done!" elseif s.frozen then "Saving paused" elseif not s.ready then "Getting ready..." else "Sealing...")..string.format("\n%02d:%02d",math.floor(left/60),left%60)
				end
				if s.slab and s.model and s.ready and not s.done and not s.frozen then
					if not s.target then s.target=nextTarget(s) end
					if s.target then
						local delta=s.target-s.position
						local look=Vector3.new(delta.X,0,delta.Z)
						if look.Magnitude>.01 then
							local desired=math.atan2(-look.X,-look.Z)
							local angle=math.atan2(math.sin(desired-s.yaw),math.cos(desired-s.yaw))
							local turn=math.rad(Config.TurnDegreesPerSecond)*dt
							s.yaw+=math.clamp(angle,-turn,turn)
							if math.abs(angle)<math.rad(35) then
								local move=math.min(delta.Magnitude,Config.Speed*dt)
								if delta.Magnitude>.01 then s.position+=delta.Unit*move end
							end
						end
						if (s.target-s.position).Magnitude<.05 then s.target=nil end
						local pose=CFrame.new(s.position)*CFrame.Angles(0,s.yaw,0)*CFrame.new(0,-s.bottom,0)*s.rootToPivot
						s.model:SetAttribute("HelperPose",pose)
      if now-(s.quietAt or 0)>.7 then
       s.quietAt=now;p:SetAttribute("HelperQuietCashUntil",workspace:GetServerTimeNow()+2)
      end
						remote:FireClient(p,"Stamp",s.slab,s.position,s.version)
					end
				end
			end
		end
	end)
	game:BindToClose(function() local count=0;for p in pairs(states) do count+=1;task.spawn(function()leave(p);count-=1 end) end;local deadline=os.clock()+25;while count>0 and os.clock()<deadline do task.wait(.1) end end)
	print("[RobotHelper] Ready. ProductId="..Config.ProductId)
end
return M




