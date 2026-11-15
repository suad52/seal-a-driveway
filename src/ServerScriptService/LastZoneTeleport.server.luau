local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local Sections=require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Sections"))
local remote=Instance.new("RemoteEvent")
remote.Name="LastZoneTeleport"
remote.Parent=RS
local busy,last={},{}
local function destination(player)
    local target, previous
    for _, id in ipairs({"Neighbourhood", "EstateDistrict", "RetailPark", "Airport", "ParkingGarage", "NewZone"}) do
        local section
        for _, candidate in ipairs(Sections.List) do
            if candidate.id == id then section = candidate; break end
        end
        if section then
            previous = target
            target = section
            if player:GetAttribute(Sections.openAttr(id)) ~= true then break end
        end
    end
    return target, previous
end
local function landing(player,character,humanoid,root)
 local target,previous=destination(player)
 local gate=previous and Sections.gateOf(previous)
 if target.id=="NewZone" then gate=Sections.gateOf(target) or gate end
 local slabs=Sections.slabsOf(target)
 if #slabs==0 then return end
 local center
 if gate then
  local marker=gate:FindFirstChild("StopLine")
  center=if marker and marker:IsA("BasePart") then marker.Position else gate:GetPivot().Position
 else
  local first=Sections.tutorialSlab()
  center=(first or slabs[1]).Position
 end
 local closest,best
 for _,slab in ipairs(slabs) do
  local d=Vector3.new(slab.Position.X-center.X,0,slab.Position.Z-center.Z)
  if d.Magnitude>1 and (not best or d.Magnitude<best) then closest=d;best=d.Magnitude end
 end
 local forward=if closest then closest.Unit else Vector3.new(0,0,-1)
 local right=Vector3.new(-forward.Z,0,forward.X)
 local skip={character}
 if gate then table.insert(skip,gate) end
 local visuals=workspace:FindFirstChild("SealerVisuals")
 if visuals then table.insert(skip,visuals) end
 local rp=RaycastParams.new();rp.FilterType=Enum.RaycastFilterType.Include;rp.FilterDescendantsInstances=slabs;rp.RespectCanCollide=true
 local op=OverlapParams.new();op.FilterType=Enum.RaycastFilterType.Exclude;op.FilterDescendantsInstances={character};op.RespectCanCollide=true
 for _,distance in ipairs({18,26,34,12}) do
  for _,side in ipairs({0,6,-6}) do
   local pos=center+forward*(if gate then distance else 0)+right*side
   local hit=workspace:Raycast(Vector3.new(pos.X,center.Y+35,pos.Z),Vector3.new(0,-120,0),rp)
   if hit and hit.Normal.Y>.85 then
    local height=humanoid.HipHeight+root.Size.Y/2+.5
    local cf=CFrame.lookAt(hit.Position+Vector3.new(0,height,0),hit.Position+Vector3.new(0,height,0)+forward)
    local occupied=workspace:GetPartBoundsInBox(CFrame.new(hit.Position+Vector3.new(0,3.5,0)),Vector3.new(4,5,4),op)
    if #occupied==0 then return cf,target.id end
   end
  end
 end
end
remote.OnServerEvent:Connect(function(player)
 if busy[player] or os.clock()-(last[player] or -10)<3 then return end
 last[player]=os.clock();busy[player]=true
 local ok,err=pcall(function()
  if player:GetAttribute("ProfileLoaded")~=true then remote:FireClient(player,false,"Please wait for your data");return end
  local character=player.Character
  local humanoid=character and character:FindFirstChildOfClass("Humanoid")
  local root=character and character:FindFirstChild("HumanoidRootPart")
  if not humanoid or humanoid.Health<=0 or not root or root.Anchored then remote:FireClient(player,false,"Cannot teleport right now");return end
  -- Event arenas must finish before leaving them.
  if math.abs(root.Position.X)>4000 or math.abs(root.Position.Z)>4000 then remote:FireClient(player,false,"Finish the event first");return end
  local cf=landing(player,character,humanoid,root)
  if not cf then remote:FireClient(player,false,"No clear landing spot");return end
  local seat=humanoid.SeatPart
  humanoid.Sit=false
  if seat then
   for _,weld in ipairs(seat:GetChildren()) do
    if weld:IsA("Weld") and weld.Name=="SeatWeld" and ((weld.Part0 and weld.Part0:IsDescendantOf(character)) or (weld.Part1 and weld.Part1:IsDescendantOf(character))) then weld:Destroy() end
   end
   game:GetService("RunService").Heartbeat:Wait()
  end
  if player.Character~=character or humanoid.Health<=0 then return end
  character:PivotTo(cf*root.CFrame:ToObjectSpace(character:GetPivot()))
  root.AssemblyLinearVelocity=Vector3.zero;root.AssemblyAngularVelocity=Vector3.zero
  remote:FireClient(player,true,"Arrived!")
 end)
 busy[player]=nil
 if not ok then warn("[LastZoneTeleport] "..tostring(err));remote:FireClient(player,false,"Teleport unavailable") end
end)
Players.PlayerRemoving:Connect(function(player) busy[player]=nil;last[player]=nil end)
