local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pets = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Pets"))

local PetModels = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Pets")
local PetInfoTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("WorldUI"):WaitForChild("PetInfo")

-- The follow loop is NOT here: each client moves every pet on RenderStepped
-- (StarterPlayerScripts.PetFollowClient). The character's position reaches
-- this server a few frames late, so a server-side loop always played catch-up
-- and the pet visibly stuttered. The model is anchored, so a client pivoting
-- it moves only its local copy -- the position is cosmetic, never a fact.

local function buildPet(plr: Player, id: string): Model?
	local def = Pets.ById[id]
	if not def then return nil end
	local template = PetModels:FindFirstChild(def.model)
	if not template or not template:IsA("Model") then
		warn("[PetService] no model named " .. tostring(def.model) .. " for pet " .. id)
		return nil
	end

	local model = template:Clone()
	model.Name = "Pet_" .. plr.Name

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end

	local info = PetInfoTemplate:Clone()
	local nameText = info:FindFirstChild("Frame", true) and info.Frame:FindFirstChild("NameText")
	if nameText and nameText:IsA("TextLabel") then
		nameText.Text = def.name
	end
	info.Adornee = model
	info.Parent = model

	local ch = plr.Character
	if ch then model:PivotTo(ch:GetPivot()) end
	model.Parent = workspace
	return model
end

-- Just the model itself: the server spawns it and takes it away. Where it
-- sits from frame to frame is PetFollowClient's business, on every client.
local sessions: { [Player]: Model } = {}

local function stopFollow(plr: Player)
	local model = sessions[plr]
	if not model then return end
	sessions[plr] = nil
	model.Parent = nil
end

local function startFollow(plr: Player, id: string)
	stopFollow(plr)
	local model = buildPet(plr, id)
	if not model then return end
	sessions[plr] = model
end

local function applyChoice(plr: Player)
	local id = plr:GetAttribute(Pets.Attr)
	local def = type(id) == "string" and id ~= "" and Pets.ById[id] or nil

	if def then
		local b = def.bonuses
		plr:SetAttribute(Pets.CashAttr, 1 + (b.cash or 0))
		plr:SetAttribute(Pets.CapacityAttr, 1 + (b.capacity or 0))
		plr:SetAttribute(Pets.SpeedAttr, 1 + (b.speed or 0))
		startFollow(plr, def.id)
	else
		plr:SetAttribute(Pets.CashAttr, 1)
		plr:SetAttribute(Pets.CapacityAttr, 1)
		plr:SetAttribute(Pets.SpeedAttr, 1)
		stopFollow(plr)
	end
end

local function watch(plr: Player)
	plr.CharacterAdded:Connect(function()
		local id = plr:GetAttribute(Pets.Attr)
		if type(id) == "string" and id ~= "" then
			task.wait(0.2)
			if plr.Parent and plr:GetAttribute(Pets.Attr) == id then
				startFollow(plr, id)
			end
		end
	end)
	plr:GetAttributeChangedSignal(Pets.Attr):Connect(function()
		applyChoice(plr)
	end)
	applyChoice(plr)
end

local EquipReq = Pets.remotes():WaitForChild("PetEquip") :: RemoteEvent

local lastEquip: { [Player]: number } = {}

EquipReq.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local now = os.clock()
	if now - (lastEquip[plr] or 0) < 0.25 then return end
	lastEquip[plr] = now

	if id == "" then
		if plr:GetAttribute(Pets.Attr) ~= "" then plr:SetAttribute(Pets.Attr, "") end
		return
	end
	if not Pets.ById[id] then return end
	if not Pets.owns(plr, id) then return end
	if plr:GetAttribute(Pets.Attr) == id then return end

	plr:SetAttribute(Pets.Attr, id)
end)

Players.PlayerAdded:Connect(watch)
for _, plr in ipairs(Players:GetPlayers()) do task.spawn(watch, plr) end

Players.PlayerRemoving:Connect(function(plr)
	lastEquip[plr] = nil
	stopFollow(plr)
end)

print(("[PetService] ready -- %d pets, set the %s attribute on a player"):format(#Pets.List, Pets.Attr))