local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local SSS=game:GetService("ServerScriptService")
local TeleportService=game:GetService("TeleportService")
local RunService=game:GetService("RunService")
local C=require(RS.HalloweenConfig)
local isEvent=game.PlaceId==C.PlaceId
local remote=RS:WaitForChild("HalloweenTravel")
local busy,last,homes={},{},{}
local function notice(player,text) remote:FireClient(player,text) end
local function joined(player)
 local data=player:GetJoinData().TeleportData
 local home=type(data)=="table" and data.HalloweenReturnPlace
 homes[player]=if C.HomePlaces[home] then home else C.DefaultHome
end
Players.PlayerAdded:Connect(joined)
for _,p in ipairs(Players:GetPlayers()) do joined(p) end
Players.PlayerRemoving:Connect(function(p) busy[p]=nil;last[p]=nil;homes[p]=nil end)
local function travel(player)
 if busy[player] or os.clock()-(last[player] or -10)<4 then return end
 last[player]=os.clock()
 if not isEvent and not C.available(os.time()) then notice(player,"The Halloween event has ended.");return end
 if player:GetAttribute("ProfileLoaded")~=true then notice(player,"Please wait for your save to load.");return end
 local char=player.Character
 local hum=char and char:FindFirstChildOfClass("Humanoid")
 if not hum or hum.Health<=0 then return end
 if hum.SeatPart then notice(player,"Leave your vehicle before travelling.");return end
 local target=if isEvent then homes[player] or C.DefaultHome else C.PlaceId
 if RunService:IsStudio() then notice(player,"Portal ready. Test teleporting in the published game.");return end
 local token={}
 busy[player]=token
 notice(player,"Saving progress and travelling...")
 local ok,err=pcall(function()
  local save=SSS:WaitForChild("WorldTravelSave",10)
  assert(save and save:Invoke(player),"Save could not be confirmed")
  if not player.Parent then return end
  local options=Instance.new("TeleportOptions")
  options:SetTeleportData({HalloweenReturnPlace=if isEvent then target else game.PlaceId,WorldPortalArrival=true})
  TeleportService:TeleportAsync(target,{player},options)
 end)
 if not ok then
  busy[player]=nil
  notice(player,"Travel failed. Your progress stays saved; please try again.")
  warn("[HalloweenPortal] "..tostring(err))
 end
 task.delay(25,function() if player.Parent and busy[player]==token then busy[player]=nil end end)
end
TeleportService.TeleportInitFailed:Connect(function(player)
 if busy[player] then busy[player]=nil;notice(player,"Teleport failed. Please try again.") end
end)
-- The return UI is allowed only in the event place. Entrance uses server proximity.
remote.OnServerEvent:Connect(function(player)
 if isEvent then travel(player) end
end)
local folder=workspace:FindFirstChild("Halloween Portal")
local prompt
if folder then
 local model=folder:FindFirstChild("Portal") or folder:FindFirstChild("Potal")
 local part
 if model then
  for _,item in ipairs(model:GetDescendants()) do
   if item:IsA("BasePart") and item.Name=="Portal" then part=item;break end
  end
 end
 if part then
  prompt=Instance.new("ProximityPrompt")
  prompt.Name="HalloweenTravelPrompt"
  prompt.ObjectText=if isEvent then "Return home" else "Graveyard Road"
  prompt.ActionText="Travel"
  prompt.KeyboardKeyCode=Enum.KeyCode.E
  prompt.GamepadKeyCode=Enum.KeyCode.ButtonX
  prompt.HoldDuration=.4
  prompt.MaxActivationDistance=16
  prompt.RequiresLineOfSight=false
  prompt.Parent=part
  prompt.Triggered:Connect(function(player)
   local root=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
   if root and part:IsDescendantOf(workspace) and (root.Position-part.Position).Magnitude<=20 then travel(player) end
  end)
 else warn("[HalloweenPortal] Portal mesh not found") end
end
while true do
 local ended=not C.available(os.time())
 if ended and folder and folder.Parent==workspace then
  folder.Parent=game.ServerStorage
 end
 if ended and isEvent then
  for _,player in ipairs(Players:GetPlayers()) do task.spawn(travel,player) end
 end
 task.wait(if ended then 10 else 1)
end

