local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local Http=game:GetService("HttpService")
local GuiService=game:GetService("GuiService")
local UIS=game:GetService("UserInputService")
local player=Players.LocalPlayer
local playerGui=player:WaitForChild("PlayerGui")
local pack=RS:WaitForChild("StellarQuest")
local C=require(pack.StellarConfig)
local remote=pack:WaitForChild("Remote")
local gui=Instance.new("ScreenGui",playerGui)
gui.Name="StellarQuestUI";gui.ResetOnSpawn=false;gui.DisplayOrder=75;gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
local root=pack:WaitForChild("StellarQuestTemplate"):Clone()
root.Name="StellarQuest";root.Size=UDim2.fromOffset(960,680);root.Position=UDim2.fromScale(.5,.5);root.AnchorPoint=Vector2.new(.5,.5);root.Visible=false;root.Parent=gui
local scale=Instance.new("UIScale",root)
local function fit()
 local camera=workspace.CurrentCamera
 if camera then local size=camera.ViewportSize;scale.Scale=math.min(1,(size.X-32)/960,(size.Y-70)/680) end
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(fit)
local camera=workspace.CurrentCamera
if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end
fit()
local icon=Instance.new("ImageButton",gui)
icon.Name="StellarQuestOpen";icon.Image=C.Icon;icon.BackgroundTransparency=1
icon.AnchorPoint=Vector2.new(.5,0);icon.Position=UDim2.new(.5,0,0,105);icon.Size=UDim2.fromOffset(80,80);icon.ScaleType=Enum.ScaleType.Fit
icon.Selectable=true
local caption=Instance.new("TextLabel",icon)
caption.BackgroundTransparency=1;caption.Font=Enum.Font.FredokaOne;caption.TextColor3=Color3.fromRGB(255,226,100);caption.TextStrokeTransparency=0;caption.TextScaled=true
caption.Size=UDim2.new(1.3,0,0,22);caption.Position=UDim2.new(-.15,0,1,-7)
local timer=caption:Clone();timer.Name="Countdown";timer.Position=UDim2.new(-.2,0,1,15);timer.Size=UDim2.new(1.4,0,0,22);timer.TextColor3=Color3.new(1,1,1);timer.Parent=icon
caption.Text="STELLAR QUEST"
local panel=root.Panel
local content=panel.Inner.Content
local quests=content.Quests
local progress=quests.Progress
local rows={quests.Tasks.EachDayTask}
for _,v in ipairs(quests.Tasks:GetChildren()) do if v.Name=="RandomTask" then table.insert(rows,v) end end
table.sort(rows,function(a,b) return a.Position.Y.Scale<b.Position.Y.Scale end)
local claimFrame=quests.Claim
local claimButton=claimFrame.Robux.Cap
local close=panel.Button.Cap
local function setCaption(button,text)
 if button:IsA("TextButton") then button.Text="" end
 local face=button:FindFirstChild("Face")
 if face and face:IsA("TextLabel") then face.Text=text end
end
setCaption(claimButton,"CLAIM")
local message=Instance.new("TextLabel",gui)
message.Name="StellarMessage";message.AnchorPoint=Vector2.new(.5,1);message.Position=UDim2.new(.5,0,1,-90);message.Size=UDim2.new(.85,0,0,54)
message.BackgroundColor3=Color3.fromRGB(30,32,72);message.TextColor3=Color3.fromRGB(255,230,120);message.Font=Enum.Font.FredokaOne;message.TextSize=20;message.TextWrapped=true;message.Visible=false
Instance.new("UICorner",message).CornerRadius=UDim.new(0,12)
local serial=0
local function notify(text)
 serial+=1;local token=serial;message.Text=text;message.Visible=true
 task.delay(6,function() if serial==token then message.Visible=false end end)
end
local state={days={},completed=0}
local function decode()
 local ok,s=pcall(Http.JSONDecode,Http,player:GetAttribute("StellarState") or "{}")
 if ok and type(s)=="table" then state=s;state.days=state.days or {} end
end
local function refresh()
 decode()
 local day=C.day(os.time(),player:GetAttribute("StellarTestDay"))
 local ids=day and C.tasks(day) or {}
 local record=state.days[tostring(day)] or {}
 for i,row in ipairs(rows) do
  local id=ids[i]
  if id then
   local target=C.Tasks[id].target
   local amount=math.clamp(tonumber(record[id]) or 0,0,target)
   row.NameLabel.Text=C.Tasks[id].name
   row.ProgressFrame.ProgressBar.Size=UDim2.fromScale(amount/target,1)
   row.ProgressFrame.ProgressLabel.Text=id=="play" and (math.floor(amount/60).."/20 min") or (amount.."/"..target)
   row.Done.Visible=amount>=target
  else
   row.NameLabel.Text=os.time()<C.StartAt and "Event starts soon" or "Event ended"
   row.ProgressFrame.ProgressLabel.Text="";row.ProgressFrame.ProgressBar.Size=UDim2.fromScale(0,1);row.Done.Visible=false
  end
 end
 local n=math.clamp(tonumber(state.completed) or 0,0,7)
 progress.Bar.AnchorPoint=Vector2.new(0,.5);progress.Bar.Position=UDim2.fromScale(0,.5);progress.Bar.Size=UDim2.fromScale(n/7,1)
 for i=1,7 do
  local step=progress:FindFirstChild("D"..i)
  if step then
   local label=step:FindFirstChild("Text");if label then label.Text="DAY "..i end
   local check=step:FindFirstChild("ImageLabel");if check then check.Visible=i<=n end
   step.BackgroundColor3=i<=n and Color3.fromRGB(91,217,126) or Color3.fromRGB(80,72,136)
  end
 end
 local counter=progress:FindFirstChild("TextLabel")
 if counter then counter.Text=n.."/7" end
 local title=quests:FindFirstChild("Text")
 if title then title.Text=day and (player:GetAttribute("StellarTestDay") and ("DAILY TASKS • TEST DAY "..day) or ("DAILY TASKS • "..os.date("!%d %b").." UTC")) or "DAILY TASKS" end
 local ready=player:GetAttribute("StellarReady")==true
 claimFrame.Lock.Visible=not state.earned
 claimButton.Active=ready and state.earned==true and not state.claimed
 claimButton.Selectable=claimButton.Active
 setCaption(claimButton,not ready and "LOADING" or state.claimed and "CLAIMED" or state.earned and "CLAIM" or "7 DAYS")
end
local function open(on)
 root.Visible=on
 if on then
  refresh();remote:FireServer("Refresh")
  if UIS.GamepadEnabled then GuiService.SelectedObject=close end
 elseif GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(root) then GuiService.SelectedObject=nil end
end
icon.Activated:Connect(function() open(not root.Visible) end)
close.Activated:Connect(function() open(false) end)
claimButton.Activated:Connect(function() if state.earned and not state.claimed then remote:FireServer("Claim") end end)
UIS.InputBegan:Connect(function(input,processed)
 if root.Visible and input.KeyCode==Enum.KeyCode.ButtonB then open(false) end
end)
player:GetAttributeChangedSignal("StellarState"):Connect(refresh)
player:GetAttributeChangedSignal("StellarReady"):Connect(refresh)
player:GetAttributeChangedSignal("StellarTestDay"):Connect(refresh)
remote.OnClientEvent:Connect(function(action,text) if action=="Message" then notify(text) end end)
-- Use the authored reward illustration positions; replace only the truck image.
local images={}
for _,v in ipairs(content.Reward:GetChildren()) do if v:IsA("ImageLabel") then table.insert(images,v) end end
table.sort(images,function(a,b) return a.Position.X.Scale<b.Position.X.Scale end)
if images[2] then images[2].Image=C.Icon end
refresh()
task.spawn(function()
 while gui.Parent do
  local now=os.time()
  icon.Visible=now>=C.StartAt and (now<C.EndAt or state.earned and not state.claimed)
  local seconds=math.max(0,C.EndAt-now)
  timer.Text=("%dd %02d:%02d:%02d"):format(math.floor(seconds/86400),math.floor(seconds/3600)%24,math.floor(seconds/60)%60,seconds%60)
  if root.Visible then refresh() end
  task.wait(1)
 end
end)
