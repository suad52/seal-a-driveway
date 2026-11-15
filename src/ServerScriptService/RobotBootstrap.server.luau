require(game.ServerScriptService.RobotService).start()

local CS=game:GetService("CollectionService")
local Marketplace=game:GetService("MarketplaceService")
local Config=require(game.ReplicatedStorage.DrivewaySealer.RobotConfig)
local bound=setmetatable({}, {__mode="k"})
local function bind(model)
	if bound[model] then return end
	local part=model:FindFirstChild("InteractionPart",true) or model:FindFirstChildWhichIsA("BasePart",true)
	if not part then return end
	local prompt=part:FindFirstChildOfClass("ProximityPrompt") or Instance.new("ProximityPrompt",part)
	bound[model]=true;prompt.ObjectText=Config.Name.." · 5 minutes";prompt.ActionText="Buy · 99 Robux";prompt.MaxActivationDistance=12;prompt.RequiresLineOfSight=false;prompt.HoldDuration=0
	local board=model:FindFirstChild("BillboardPart")
	local gui=board and board:FindFirstChildWhichIsA("BillboardGui")
	if gui then
		local label=gui:FindFirstChildWhichIsA("TextLabel",true)
		if label then label.Text=Config.Name.."\n5 MINUTES · 99 R$" end
		local badge=gui:FindFirstChild("HelperNew");if badge then badge:Destroy() end
	end
	prompt.Triggered:Connect(function(p)
		local hrp=p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if not hrp or (hrp.Position-part.Position).Magnitude>16 then return end
		if Config.ProductId>0 then Marketplace:PromptProductPurchase(p,Config.ProductId) else game.ReplicatedStorage.DrivewaySealer.RobotRemote:FireClient(p,"Message","Helper is not on sale yet.") end
	end)
end
for _,model in ipairs(CS:GetTagged(Config.ShowcaseTag)) do bind(model) end
CS:GetInstanceAddedSignal(Config.ShowcaseTag):Connect(bind)


