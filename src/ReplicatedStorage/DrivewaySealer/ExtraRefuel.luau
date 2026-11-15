local RunService=game:GetService("RunService")
local CS=game:GetService("CollectionService")
local Extra={}
function Extra.folder()
	local airport=workspace:FindFirstChild("Airport")
	return airport and airport:FindFirstChild("RefuelNew")
end
function Extra.at(player)
	local folder=Extra.folder()
	local floor=folder and (folder:FindFirstChild("BayApron") or folder:FindFirstChild("FillPad"))
	local root=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not floor or not floor:IsA("BasePart") or not root then return false end
	local p=floor.CFrame:PointToObjectSpace(root.Position)
	return math.abs(p.X)<=floor.Size.X/2+18 and math.abs(p.Z)<=floor.Size.Z/2+18 and p.Y>-4 and p.Y<20
end
function Extra.prepare()
	if not RunService:IsServer() then return end
	local folder=Extra.folder()
	if not folder then return end
	for _,name in ipairs({"PumpBody","FillPad","ArmNozzle"}) do
		local part=folder:FindFirstChild(name)
		if part and part:IsA("BasePart") then CS:AddTag(part,"SealerRefuel") end
	end
	local host=folder:FindFirstChild("PumpBody") or folder:FindFirstChild("FillPad")
	if host and host:IsA("BasePart") and not host:FindFirstChild("ExtraRefuelShop") then
		local prompt=Instance.new("ProximityPrompt")
		prompt.Name="ExtraRefuelShop";prompt.ActionText="Buy / Call Truck";prompt.ObjectText="Truck station"
		prompt.KeyboardKeyCode=Enum.KeyCode.G;prompt.GamepadKeyCode=Enum.KeyCode.ButtonY
		prompt.MaxActivationDistance=14;prompt.RequiresLineOfSight=false;prompt.HoldDuration=0
		prompt:SetAttribute("ExtraRefuelShop",true);prompt.Parent=host
	end
end
Extra.prepare()
if RunService:IsServer() then
	workspace.DescendantAdded:Connect(function(instance)
		if instance.Name=="RefuelNew" or instance.Name=="ArmNozzle" or instance.Name=="PumpBody" or instance.Name=="FillPad" then task.defer(Extra.prepare) end
	end)
end
return Extra
