local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local SIDE_OFFSET = Vector3.new(0, .5, 5)
local FOLLOW_SNAP = 8

local tracked: { [Model]: boolean } = {}


local function isPet(child: Instance): boolean
	return child:IsA("Model") and string.sub(child.Name, 1, 4) == "Pet_"
end

for _, child in ipairs(workspace:GetChildren()) do
	if isPet(child) then tracked[child] = true end
end

workspace.ChildAdded:Connect(function(child)
	if isPet(child) then tracked[child] = true end
end)

workspace.ChildRemoved:Connect(function(child)
	tracked[child] = nil
end)


local hidden: { [Model]: boolean } = {}

local function setVisible(model: Model, on: boolean)
	if hidden[model] == (not on) then return end
	hidden[model] = not on
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if on then 0 else 1
		elseif d:IsA("BillboardGui") then
			d.Enabled = on
		end
	end
end


RunService.RenderStepped:Connect(function(dt)
	local roots: { [Player]: BasePart? } = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then roots[plr] = hrp end
	end

	for model in pairs(tracked) do
		if model.Parent then
			local owner = Players:FindFirstChild(string.sub(model.Name, 5))
			local hrp = owner and roots[owner]
			if hrp then
				setVisible(model, true)

				local bob = math.sin(os.clock() * 2.2) * 0.25
				local target = hrp.CFrame * CFrame.new(SIDE_OFFSET + Vector3.new(0, bob, 0))

				local pivot = model:GetPivot()
				local alpha = math.min(dt * FOLLOW_SNAP, 1)
				local pos = pivot.Position:Lerp(target.Position, alpha)
				model:PivotTo(CFrame.new(pos) * target.Rotation)
			else
				setVisible(model, false)
			end
		end
	end
end)