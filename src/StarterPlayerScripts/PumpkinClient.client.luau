local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local SoundService=game:GetService("SoundService")
local Lighting=game:GetService("Lighting")
local player=Players.LocalPlayer
local Pack=RS:WaitForChild("PumpkinEvent")
local C=require(Pack.PumpkinConfig)
local SoundKit=require(RS.DrivewaySealer.SoundKit)
local WorldTime=require(RS.WorldTime)
local state=Pack.State
local function make(class,props,parent)
 local item=Instance.new(class)
 for k,v in pairs(props) do item[k]=v end
 item.Parent=parent
 return item
end
local gui=make("ScreenGui",{Name="PumpkinHUD",ResetOnSpawn=false,IgnoreGuiInset=false,DisplayOrder=23},player:WaitForChild("PlayerGui"))
local panel=make("Frame",{AnchorPoint=Vector2.new(.5,0),Position=UDim2.new(.5,0,0,78),Size=UDim2.fromOffset(242,62),BackgroundColor3=Color3.fromRGB(42,22,62)},gui)
make("UICorner",{CornerRadius=UDim.new(0,14)},panel)
make("UIStroke",{Color=Color3.fromRGB(255,172,58),Thickness=2},panel)
local scale=make("UIScale",{Scale=1},panel)
make("ImageLabel",{Name="WeatherIcon",BackgroundTransparency=1,Size=UDim2.fromOffset(58,58),Position=UDim2.fromOffset(2,2),Image="rbxassetid://98835998247457",ScaleType=Enum.ScaleType.Fit},panel)
local title=make("TextLabel",{BackgroundTransparency=1,Position=UDim2.fromOffset(62,4),Size=UDim2.fromOffset(174,25),Font=Enum.Font.FredokaOne,TextSize=19,TextColor3=Color3.fromRGB(255,193,86),TextStrokeTransparency=.35,Text="PUMPKIN STORM"},panel)
local timer=make("TextLabel",{BackgroundTransparency=1,Position=UDim2.fromOffset(62,29),Size=UDim2.fromOffset(174,27),Font=Enum.Font.GothamBold,TextSize=15,TextColor3=Color3.new(1,1,1),Text=""},panel)
local balance=make("TextLabel",{BackgroundColor3=Color3.fromRGB(42,22,62),Position=UDim2.fromOffset(0,68),Size=UDim2.fromOffset(242,27),Font=Enum.Font.GothamBold,TextSize=14,TextColor3=Color3.fromRGB(255,193,86),Text=""},panel)
make("UICorner",{CornerRadius=UDim.new(0,9)},balance)
local toast=make("TextLabel",{BackgroundTransparency=1,Position=UDim2.fromOffset(0,98),Size=UDim2.fromOffset(242,26),Font=Enum.Font.FredokaOne,TextSize=20,TextColor3=Color3.fromRGB(255,207,94),TextStrokeTransparency=.3,Text=""},panel)
-- All clients render the same shared pickups; the server awards each ID only once.
local visualFolder=Instance.new("Folder")
visualFolder.Name="SharedPumpkinVisuals"
visualFolder.Parent=workspace
local visuals={}
local function removeVisual(id)
 local item=visuals[id]
 if item then item.model:Destroy();visuals[id]=nil end
end
local function visualMessage(message)
 if message.action=="Remove" then removeVisual(message.id);return end
 if message.action~="Spawn" or typeof(message.position)~="Vector3" then return end
 removeVisual(message.id)
 local model=Pack.Assets.Pumkin:Clone()
 local lightPart
 for _,item in ipairs(model:GetDescendants()) do
  if item:IsA("BaseScript") then item:Destroy()
  elseif item:IsA("BasePart") then
   item.Anchored=true;item.CanCollide=false;item.CanTouch=false;item.CanQuery=false
   if not lightPart or item.Size.Magnitude>lightPart.Size.Magnitude then lightPart=item end
  end
 end
 model:PivotTo(CFrame.new(message.position)*CFrame.Angles(0,message.yaw or 0,0))
 local box,size=model:GetBoundingBox()
 model:PivotTo(model:GetPivot()+Vector3.new(0,message.position.Y+.38-(box.Position.Y-size.Y*.5),0))
 if lightPart then
  make("PointLight",{Name="PumpkinGlow",Color=Color3.fromRGB(255,153,57),Brightness=.65,Range=7,Shadows=false},lightPart)
 end
 model.Parent=visualFolder
 visuals[message.id]={model=model,base=model:GetPivot(),phase=(message.id*2.399)% (math.pi*2)}
end
local animation=game:GetService("RunService").RenderStepped:Connect(function()
 local now=workspace:GetServerTimeNow()
 for _,item in pairs(visuals) do
  if item.model.Parent then
   item.model:PivotTo(item.base+Vector3.new(0,math.sin(now*1.65+item.phase)*.18,0))
  end
 end
end)
script.Destroying:Connect(function() animation:Disconnect();visualFolder:Destroy() end)
local revision=0
Pack.Pickup.OnClientEvent:Connect(function(amount)
 if type(amount)=="table" then visualMessage(amount);return end
 if type(amount)~="number" then return end
 SoundKit.play("Pop",SoundService)
 revision+=1;local token=revision
 toast.Text="+"..amount.." Pumpkin Coins"
 task.delay(1.5,function() if revision==token then toast.Text="" end end)
end)
Pack.Pickup:FireServer("Ready")
local active=false
local stored,clones={},{}
local music, musicEnd= nil,0
local musicIndex=0
local tracks={}
for _,item in ipairs(Pack.Assets.Halloween:GetChildren()) do if item:IsA("Sound") then table.insert(tracks,item) end end
table.sort(tracks,function(a,b) return a.Name<b.Name end)
local function apply(activeNow)
 if activeNow==active then return end
 active=activeNow
 if active then
  RS:SetAttribute("PumpkinWeatherActive",true)
  WorldTime.setPumpkinOverride(true)
  for _, sound in ipairs(SoundService:GetChildren()) do
   if sound:IsA("Sound") and sound.Name=="SealerMusic" then sound:Stop() end
  end
  for _,item in ipairs(Lighting:GetChildren()) do
   if item:IsA("Sky") or item:IsA("Atmosphere") or item:IsA("PostEffect") then
    table.insert(stored,item);item.Parent=script
   end
  end
  for _,item in ipairs(Pack.Assets.Helloween:GetChildren()) do
   local clone=item:Clone()
   if clone:IsA("PostEffect") and player:GetAttribute("Set_Fancy")==false then clone.Enabled=false end
   if clone:IsA("Atmosphere") then
    clone.Density=math.min(.4,clone.Density+.025)
    clone.Haze=math.min(2,clone.Haze+.15)
   end
   clone.Parent=Lighting;table.insert(clones,clone)
  end
  local tint=make("ColorCorrectionEffect",{Name="PumpkinWarmDusk",TintColor=Color3.fromRGB(255,239,226),Saturation=-.06,Contrast=.035,Brightness=-.01},Lighting)
  table.insert(clones,tint)
 else
  for id in pairs(visuals) do removeVisual(id) end
  if music then music:Destroy();music=nil end
  for _,item in ipairs(clones) do item:Destroy() end
  for _,item in ipairs(stored) do item.Parent=Lighting end
  table.clear(clones);table.clear(stored)
  WorldTime.setPumpkinOverride(false)
  RS:SetAttribute("PumpkinWeatherActive",false)
 end
end
-- Follow the existing PVP button in screen coordinates, including mobile scaling.
local layoutRoot=make("Frame",{Name="PumpkinLayout",BackgroundTransparency=1,Size=UDim2.fromScale(1,1)},gui)
panel.Parent=layoutRoot
panel.AnchorPoint=Vector2.new(1,0)
local function positionUnderPVP()
 local playerGui=gui.Parent
 local pvpGui=playerGui and playerGui:FindFirstChild("PvPLobbyGui")
 local frame=pvpGui and pvpGui:FindFirstChild("Frame")
 local button=frame and frame:FindFirstChild("PvPLobbyButton")
 local rootSize=layoutRoot.AbsoluteSize
 if rootSize.X<=0 or rootSize.Y<=0 then return end
 local targetScale=math.clamp(rootSize.X/1000,.65,1)
 local x,y=rootSize.X-16,150
 if button and button:IsA("GuiObject") and button.Visible and frame.Visible and pvpGui.Enabled then
  local pos=button.AbsolutePosition-layoutRoot.AbsolutePosition
  local size=button.AbsoluteSize
  targetScale=math.clamp(size.X/242,.65,1)
  x=pos.X+size.X
  y=pos.Y+size.Y+12
 end
 scale.Scale=targetScale
 local width,height=242*targetScale,124*targetScale
 panel.Position=UDim2.fromOffset(math.clamp(x,width+8,math.max(width+8,rootSize.X-8)),math.clamp(y,8,math.max(8,rootSize.Y-height-8)))
end

while gui.Parent do
 local on,deadline,ended=C.window(workspace:GetServerTimeNow())
 if state:GetAttribute("Deadline") then
  on=state:GetAttribute("Active")==true;deadline=state:GetAttribute("Deadline");ended=state:GetAttribute("Ended")==true
 end
 apply(on)
 panel.Visible=not ended
 local cameraNow=workspace.CurrentCamera
 positionUnderPVP()
 local remaining=math.max(0,math.ceil(deadline-workspace:GetServerTimeNow()))
 title.Text=if on then "PUMPKIN STORM!" else "PUMPKIN STORM"
 timer.Text=string.format("%s %02d:%02d",if on then "Ends in" else "Starts in",math.floor(remaining/60),remaining%60)
 balance.Text="Pumpkin Coins: "..tostring(player:GetAttribute("PumpkinCoins") or 0)
 if on and #tracks>0 and (not music or os.clock()>=musicEnd) then
  if music then music:Destroy() end
  musicIndex=musicIndex%#tracks+1
  music=tracks[musicIndex]:Clone();music.Name="PumpkinEventMusic";music.Looped=false
  music.SoundGroup=SoundKit.bus("Music");music.Parent=SoundService
  music:Play();musicEnd=os.clock()+math.max(15,music.TimeLength+3)
  local current=music
  current.Loaded:Once(function() if music==current then musicEnd=os.clock()+current.TimeLength+3 end end)
  current.Ended:Once(function() if music==current then musicEnd=0 end end)
 end
 task.wait(.25)
end


