local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local C=require(RS:WaitForChild("HalloweenConfig"))
local remote=RS:WaitForChild("HalloweenTravel")
local gui=Instance.new("ScreenGui")
gui.Name="HalloweenTravelUI";gui.ResetOnSpawn=false;gui.DisplayOrder=35
gui.Parent=Players.LocalPlayer:WaitForChild("PlayerGui")
local label=Instance.new("TextLabel")
label.AnchorPoint=Vector2.new(.5,1);label.Position=UDim2.new(.5,0,1,-75)
label.Size=UDim2.new(.8,0,0,40);label.BackgroundColor3=Color3.fromRGB(38,22,49)
label.TextColor3=Color3.fromRGB(255,205,125);label.Font=Enum.Font.GothamBold
label.TextSize=16;label.TextWrapped=true;label.Visible=false;label.Parent=gui
Instance.new("UICorner",label).CornerRadius=UDim.new(0,12)
local serial=0
remote.OnClientEvent:Connect(function(text)
 serial+=1;local token=serial;label.Text=tostring(text);label.Visible=true
 task.delay(5,function() if serial==token then label.Visible=false end end)
end)
if game.PlaceId==C.PlaceId then
 local button=Instance.new("TextButton")
 button.Name="ReturnHome";button.AnchorPoint=Vector2.new(1,0)
 button.Position=UDim2.new(1,-18,0,12);button.Size=UDim2.fromOffset(150,38)
 button.BackgroundColor3=Color3.fromRGB(94,49,127);button.TextColor3=Color3.new(1,1,1)
 button.Font=Enum.Font.GothamBold;button.TextSize=16;button.Text="RETURN HOME";button.Parent=gui
 Instance.new("UICorner",button).CornerRadius=UDim.new(0,12)
 button.Activated:Connect(function() remote:FireServer() end)
 local pvp=gui.Parent:FindFirstChild("PvPLobbyGui")
 if pvp then pvp.Enabled=false end
 gui.Parent.ChildAdded:Connect(function(item) if item.Name=="PvPLobbyGui" and item:IsA("ScreenGui") then item.Enabled=false end end)
end
