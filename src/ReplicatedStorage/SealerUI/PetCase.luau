--[[
	PetCase -- the pet inventory pane inside the Squeegee Case, mounted as a
	third tab beside SQUEEGEES and TRUCK VFX.

	Same shape as TruckCosmetics' pane: a ScrollingFrame of cards on a grid, a
	caption and a button per pet, and everything live off the player's own
	attributes -- PetsOwned and PetEquipped replicate on their own, so this pane
	is right the moment it is built with no remote of its own beyond PetEquip.

	Nobody owns a pet yet: a card that is not owned says LOCKED, and when selling
	arrives it only has to write ids into PetsOwned for these cards to light up.
]]

local RS = game:GetService("ReplicatedStorage")
local UI = require(RS:WaitForChild("SealerUI"):WaitForChild("UIKit"))
local Pets = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("Pets"))

local M = {}

function M.mount(content, player)
	local pane = Instance.new("Frame")
	pane.Name = "PetCase"
	pane.BackgroundTransparency = 1
	pane.Visible = false
	pane.ZIndex = 12
	pane.Parent = content

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "PetCards"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.ZIndex = 12
	scroll.Parent = pane

	local layout = Instance.new("UIGridLayout", scroll)
	layout.CellPadding = UDim2.fromOffset(12, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	local function resize()
		local two = scroll.AbsoluteSize.X >= 480
		layout.CellSize = UDim2.new(two and 0.5 or 1, two and -16 or -24, 0, 254)
	end
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	resize()

	local EquipReq = Pets.remotes():WaitForChild("PetEquip")

	local cards = {}
	for i, pet in ipairs(Pets.List) do
		local card = Instance.new("Frame", scroll)
		card.Name = pet.id
		card.LayoutOrder = i
		card.BackgroundColor3 = Color3.fromRGB(28, 49, 84)
		card.BorderSizePixel = 0
		card.ZIndex = 12
		UI.corner(card, 12)
		local edge = UI.stroke(card, 2.4)

		local icon = Instance.new("ImageLabel", card)
		icon.Name = "PetIcon"
		icon.Image = pet.icon
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.new(1, -24, 0, 150)
		icon.Position = UDim2.fromOffset(12, 8)
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 14

		local title = UI.outlined(card, pet.name:upper(), 19, Color3.fromRGB(255, 238, 197), 2.4)
		title.Position = UDim2.fromOffset(8, 164)
		title.Size = UDim2.new(1, -16, 0, 26)
		title.TextXAlignment = Enum.TextXAlignment.Center
		title.ZIndex = 15

		local parts = {}
		local b = pet.bonuses
		if b.cash then table.insert(parts, ("CASH +%d%%"):format(math.floor(b.cash * 100 + 0.5))) end
		if b.capacity then table.insert(parts, ("BUCKET +%d%%"):format(math.floor(b.capacity * 100 + 0.5))) end
		if b.speed then table.insert(parts, ("SPEED +%d%%"):format(math.floor(b.speed * 100 + 0.5))) end
		local bonuses = UI.outlined(card, table.concat(parts, "  "), 12, Color3.fromRGB(255, 193, 67), 1.5)
		bonuses.Position = UDim2.fromOffset(8, 190)
		bonuses.Size = UDim2.new(1, -16, 0, 16)
		bonuses.TextXAlignment = Enum.TextXAlignment.Center
		bonuses.ZIndex = 15

		local button, cap = UI.button(card, "EQUIP", UDim2.new(1, -24, 0, 40), Color3.fromRGB(95, 168, 229), function()
			local owned = Pets.owns(player, pet.id)
			local on = player:GetAttribute(Pets.Attr) == pet.id
			if owned then
				EquipReq:FireServer(on and "" or pet.id)
			end
		end)
		button.Position = UDim2.fromOffset(12, 208)
		button.ZIndex = 16
		for _, o in ipairs(button:GetDescendants()) do
			if o:IsA("GuiObject") then o.ZIndex = math.max(o.ZIndex, 17) end
		end

		cards[pet.id] = { cap = cap, edge = edge }
	end

	local function refresh()
		for _, pet in ipairs(Pets.List) do
			local c = cards[pet.id]
			if c then
				local owned = Pets.owns(player, pet.id)
				local on = owned and player:GetAttribute(Pets.Attr) == pet.id
				c.cap.Text = owned and (on and "UNEQUIP" or "EQUIP") or "LOCKED"
				c.edge.Color = on and Color3.fromRGB(255, 203, 82) or Color3.fromRGB(64, 102, 179)
			end
		end
	end

	player:GetAttributeChangedSignal(Pets.OwnedAttr):Connect(refresh)
	player:GetAttributeChangedSignal(Pets.Attr):Connect(refresh)
	refresh()

	return pane
end

return M