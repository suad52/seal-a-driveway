local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local CS=game:GetService("CollectionService")
local StarterGui=game:GetService("StarterGui")
local player=Players.LocalPlayer
local pack=RS:WaitForChild("DrivewaySealer")
local remote=pack:WaitForChild("RobotRemote")
local config=require(pack.RobotConfig)
local Console = require(game:GetService("ReplicatedStorage"):WaitForChild("SealerUI"):WaitForChild("ConsoleControls"))
local mouse=player:GetMouse()
local connected=setmetatable({}, {__mode="k"})
local function message(text)
	pcall(function() StarterGui:SetCore("SendNotification",{Title=config.Name,Text=text,Duration=5}) end)
end
remote.OnClientEvent:Connect(function(action,text) if action=="Message" then message(text) end end)
local function bindTool(t)
	if not t:IsA("Tool") or not t:GetAttribute("RobotHelperTool") or connected[t] then return end
	connected[t]=true
	t.Equipped:Connect(function() message(if Console.active() then "Aim at a road and press "..Console.key(Enum.KeyCode.ButtonR2).." to place or move your robot. Its timer keeps running." else "Tap a road to place or move your robot. Its timer keeps running.") end)
	t.Activated:Connect(function()
		if Console.blocked() then return end

  local camera=workspace.CurrentCamera
  if not camera then return end
  local ray=mouse.UnitRay
  if Console.active() then
   local view=camera.ViewportSize;ray=camera:ViewportPointToRay(view.X*.5,view.Y*.5)
  end
  local rp=RaycastParams.new();rp.FilterType=Enum.RaycastFilterType.Exclude
  local skip={player.Character}
  for _,name in ipairs({"SealerVisuals","SharedPumpkinVisuals"}) do local v=workspace:FindFirstChild(name);if v then table.insert(skip,v) end end
  rp.FilterDescendantsInstances=skip
  local hit=workspace:Raycast(ray.Origin,ray.Direction*250,rp)
  local target,position=hit and hit.Instance,hit and hit.Position
  if hit and not CS:HasTag(target,"SealableDriveway") then
   local roads=RaycastParams.new();roads.FilterType=Enum.RaycastFilterType.Include
   roads.FilterDescendantsInstances=CS:GetTagged("SealableDriveway")
   local below=workspace:Raycast(position+Vector3.new(0,2,0),Vector3.new(0,-10,0),roads)
   if below then target=below.Instance;position=below.Position end
  end
  if target and position and CS:HasTag(target,"SealableDriveway") then
   require(RS.HalloweenDiagnostics).record(player,"HelperClient","PlaceRequest",target:GetFullName())
   remote:FireServer("Place",target,position)
  else
   require(RS.HalloweenDiagnostics).record(player,"HelperClient","NoRoad",target and target:GetFullName() or "No ray hit",true)
   message("Aim at a road nearby. Decorations may cover its surface.")
  end
	end)
end
local function watch(container)
	for _,t in ipairs(container:GetChildren()) do bindTool(t) end
	container.ChildAdded:Connect(bindTool)
end
watch(player:WaitForChild("Backpack"))
player.CharacterAdded:Connect(watch)
if player.Character then watch(player.Character) end
if game:GetService("RunService"):IsStudio() and config.StudioFreeTest then
	local gui=Instance.new("ScreenGui");gui.Name="RobotTestUI";gui.ResetOnSpawn=false;gui.Parent=player.PlayerGui
	local button=Instance.new("TextButton");button.Size=UDim2.fromOffset(160,38);button.Position=UDim2.new(.5,-80,0,70);button.Text="TEST: GET ROBOT";button.Parent=gui
	button.Activated:Connect(function()remote:FireServer("Test")end)
end

local RunService=game:GetService("RunService")
local moving={}
local function watchRobot(model)
	if moving[model] or not model:IsA("Model") then return end
	local initial=model:GetAttribute("HelperPose")
	if typeof(initial)~="CFrame" then return end
	local state={samples={{time=os.clock()-config.InterpolationDelay,pose=initial}}}
	moving[model]=state
	state.connection=model:GetAttributeChangedSignal("HelperPose"):Connect(function()
		local pose=model:GetAttribute("HelperPose")
		if typeof(pose)~="CFrame" then return end
		table.insert(state.samples,{time=os.clock(),pose=pose})
		while #state.samples>12 do table.remove(state.samples,1) end
	end)
end
local function unwatch(model)
	local state=moving[model]
	if state then state.connection:Disconnect();moving[model]=nil end
end
for _,model in ipairs(CS:GetTagged("HelperMovingRobot")) do watchRobot(model) end
CS:GetInstanceAddedSignal("HelperMovingRobot"):Connect(watchRobot)
CS:GetInstanceRemovedSignal("HelperMovingRobot"):Connect(unwatch)
RunService.RenderStepped:Connect(function()
	local now=os.clock()-config.InterpolationDelay
	local camera=workspace.CurrentCamera
	for model,state in pairs(moving) do
		if not model:IsDescendantOf(workspace) then unwatch(model);continue end
		local samples=state.samples
		while #samples>2 and samples[2].time<=now do table.remove(samples,1) end
		local first=samples[1];local second=samples[2]
		local pose=first.pose
		if second then
			local alpha=math.clamp((now-first.time)/math.max(.001,second.time-first.time),0,1)
			pose=first.pose:Lerp(second.pose,alpha)
		end
		if not camera or (camera.CFrame.Position-pose.Position).Magnitude<350 then model:PivotTo(pose) end
	end
end)
