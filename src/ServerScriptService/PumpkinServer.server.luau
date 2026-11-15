local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Pack = RS:WaitForChild("PumpkinEvent")
local C = require(Pack.PumpkinConfig)
local Currency = require(game.ServerScriptService:WaitForChild("PumpkinCurrency"))
local Sections = require(RS.DrivewaySealer.Sections)
local template = Pack.Assets.Pumkin
local state, pickup = Pack.State, Pack.Pickup
local rng = Random.new()
local serial = 0
local synced = {}
local records, counts, nextSpawn = {}, {}, {}
local roads = {}
local function noteRoad(part)
 if part:IsA("BasePart") then roads[part] = true end
end
for _, part in ipairs(CollectionService:GetTagged(Sections.Tag)) do noteRoad(part) end
CollectionService:GetInstanceAddedSignal(Sections.Tag):Connect(noteRoad)
CollectionService:GetInstanceRemovedSignal(Sections.Tag):Connect(function(part) roads[part] = nil end)
local function rootOf(player)
 local char = player.Character
 local hum = char and char:FindFirstChildOfClass("Humanoid")
 local root = char and char:FindFirstChild("HumanoidRootPart")
 if hum and hum.Health > 0 and root and Currency.ready(player) then return root end
 return nil
end
local function access(player)
 local allowed = {}
 for _, name in ipairs(Sections.reachableGround(function(id)
  return player:GetAttribute(Sections.openAttr(id)) == true
 end)) do
  local root = workspace:FindFirstChild(name)
  if root then table.insert(allowed, root) end
 end
 return allowed
end
local function inAllowed(part, allowed)
 for _, root in ipairs(allowed) do
  if part:IsDescendantOf(root) then return true end
 end
 return false
end
local function erase(id)
 local record = records[id]
 if record then
  counts[record.owner] = math.max(0, (counts[record.owner] or 1) - 1)
  pickup:FireAllClients({action="Remove",id=id})
 end
 records[id] = nil
end
local function sendSpawn(id,r,recipient)
 local message={action="Spawn",id=id,position=r.position,yaw=r.yaw}
 if recipient then pickup:FireClient(recipient,message) else pickup:FireAllClients(message) end
end
pickup.OnServerEvent:Connect(function(player,command)
 -- This endpoint only resends existing visuals. It cannot spawn or award coins.
 if command ~= "Ready" or os.clock()-(synced[player] or -math.huge)<5 then return end
 synced[player]=os.clock()
 for id,r in pairs(records) do sendSpawn(id,r,player) end
end)
local function spawnOne(player, root, allowed, sectorAngle)
 local ray = RaycastParams.new()
 ray.FilterType = Enum.RaycastFilterType.Include
 -- Only actual tagged road geometry in accessible districts, not rooftops or trees.
 local candidates = {}
 for road in pairs(roads) do
  if road.Parent and inAllowed(road, allowed) then
   local offset = road.Position - root.Position
   if Vector3.new(offset.X,0,offset.Z).Magnitude <= C.MaxRadius + road.Size.Magnitude * .5 then
    table.insert(candidates, road)
   end
  end
 end
 if #candidates == 0 then return end
 ray.FilterDescendantsInstances = candidates
 local obstruction = RaycastParams.new()
 obstruction.FilterType = Enum.RaycastFilterType.Exclude
 local excluded = {}
 for _, p in ipairs(Players:GetPlayers()) do if p.Character then table.insert(excluded,p.Character) end end
 obstruction.FilterDescendantsInstances = excluded
 obstruction.RespectCanCollide = true
 for _ = 1, 18 do
  local angle, radius = sectorAngle+rng:NextNumber(-math.pi/4,math.pi/4), rng:NextNumber(C.MinRadius,C.MaxRadius)
  local at = root.Position + Vector3.new(math.cos(angle)*radius,12,math.sin(angle)*radius)
  local hit = workspace:Raycast(at,Vector3.new(0,-35,0),ray)
  if not hit or hit.Normal.Y < .72 or math.abs(hit.Position.Y-root.Position.Y)>12 then continue end
  local actual = workspace:Raycast(at,Vector3.new(0,-35,0),obstruction)
  if not actual or actual.Instance ~= hit.Instance then continue end
  local crowded = false
  for _, r in pairs(records) do if (r.position-hit.Position).Magnitude<8 then crowded=true;break end end
  if crowded then continue end
  serial+=1
  records[serial]={owner=player,position=hit.Position,road=hit.Instance,expires=os.clock()+C.Lifetime,yaw=rng:NextNumber(0,math.pi*2)}
  counts[player]=(counts[player] or 0)+1
  sendSpawn(serial,records[serial])
  return
 end
end
Players.PlayerRemoving:Connect(function(player)
 for model,r in pairs(records) do if r.owner==player then erase(model) end end
 counts[player]=nil;nextSpawn[player]=nil;synced[player]=nil
end)
local wasActive=false
while true do
 local active, deadline, ended = C.window(os.time())
 local testUntil = state:GetAttribute("StudioTestUntil")
 if game:GetService("RunService"):IsStudio() and type(testUntil)=="number" and os.time()<testUntil then
  active,deadline,ended=true,testUntil,false
 end
 state:SetAttribute("Active",active)
 state:SetAttribute("Deadline",deadline)
 state:SetAttribute("Ended",ended)
 if active ~= wasActive then

  if not active then for model in pairs(records) do erase(model) end;table.clear(nextSpawn) end
  wasActive=active
 end
 if active then
  local now=os.clock()
  local players=Players:GetPlayers()
  local roots, allowedByPlayer = {}, {}
  for _, player in ipairs(players) do
   local root=rootOf(player)
   if root then
    roots[player]=root;allowedByPlayer[player]=access(player)
    if now >= (nextSpawn[player] or 0) then
     nextSpawn[player]=now+C.interval(#players)
     local angle=rng:NextNumber(0,math.pi*2)
     for index=1,math.min(C.BatchSize,C.MaxPerPlayer-(counts[player] or 0)) do
      spawnOne(player,root,allowedByPlayer[player],angle+(index-1)*math.pi*2/3)
     end
    end
   end
  end
  for id,r in pairs(records) do
   if now>=r.expires or not r.road.Parent then erase(id);continue end
   -- The closest eligible player collects it; no yield occurs before removal.
   local collector, nearest=nil,C.PickupRadius
   for player,root in pairs(roots) do
    local distance=(root.Position-r.position).Magnitude
    if distance<=nearest and inAllowed(r.road,allowedByPlayer[player]) then
     collector,nearest=player,distance
    end
   end
   if collector and Currency.award(collector,1) then
    erase(id)
    pickup:FireClient(collector,1)
   end
  end
 end
 task.wait(.25)
end


