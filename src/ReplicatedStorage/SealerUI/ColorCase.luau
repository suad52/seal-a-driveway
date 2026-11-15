local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local Catalog = require(Pack:WaitForChild("ColorCatalog"))
local Palettes = require(Pack:WaitForChild("ColorPalettes"))
local UIKit = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("UIKit"))
local Visuals = require(Pack:WaitForChild("ColorVisuals"))
local T = UIKit.Theme
local ColorCase = {}
local function formatCash(amount)
	if amount >= 1000000 then
		local millions = amount / 1000000
		local label = if millions == math.floor(millions) then tostring(millions) else string.format("%.1f", millions)
		return "BUY $" .. label .. "M"
	elseif amount >= 1000 then
		return "BUY $" .. tostring(math.floor(amount / 1000)) .. "K"
	else
		return "BUY $" .. tostring(amount)
	end
end
local function make(class, props, parent)
	local instance = Instance.new(class)
	for key, value in pairs(props) do instance[key] = value end
	instance.Parent = parent
	return instance
end
local function preview(parent, palette)
	local viewport = make("ViewportFrame", {
		Name="AsphaltPreview", Size=UDim2.new(1,-20,0,130), Position=UDim2.fromOffset(10,36),
		BackgroundColor3=Color3.fromRGB(15,31,58), BorderSizePixel=0, ZIndex=10,
		Ambient=Color3.fromRGB(190,190,200), LightColor=Color3.new(1,1,1), LightDirection=Vector3.new(-1,-1,-.4),
	}, parent)
	UIKit.corner(viewport, 10)
	local world = make("WorldModel", {}, viewport)
	local camera = make("Camera", {FieldOfView=35, CFrame=CFrame.lookAt(Vector3.new(8,9,11),Vector3.zero)}, viewport)
	viewport.CurrentCamera = camera
	local base = make("Part", {Name="Slab", Size=Vector3.new(8,.45,6), Anchored=true,
		Color=Color3.fromRGB(34,37,43), Material=Enum.Material.Slate, CanCollide=false}, world)
	local count = if palette.lut then 32 else 1
	for i=1,count do
		local v = if palette.lut then palette.lut[math.floor((i-1)/(count-1)*255)+1] else palette.sealed
		make("Part", {Name="Finish", Size=Vector3.new(8/count,.06,6),
			Position=Vector3.new(-4+(i-.5)*8/count,.26,0), Anchored=true, CanCollide=false,
			Color=Color3.new(v.X,v.Y,v.Z), Material=if palette.id == "gold" then Enum.Material.Metal else Enum.Material.SmoothPlastic,
			Reflectance=palette.reflectance or 0}, world)
	end
	if palette.sparkles then
		for i=1,9 do
			make("Part", {Name="Glint", Shape=Enum.PartType.Ball, Size=Vector3.new(.09,.06,.09),
				Position=Vector3.new(-3.2+((i*17)%9)*.8,.32,-2+((i*7)%5)), Anchored=true,
				CanCollide=false, Color=Color3.fromRGB(255,249,225), Material=Enum.Material.Neon}, world)
		end
	end
	return base
end
function ColorCase.build(shell)
	local player = shell.plr
	local remotes = ReplicatedStorage:WaitForChild("AsphaltColorRemotes")
	local request = remotes:WaitForChild("Request")
	local result = remotes:WaitForChild("Result")
	local size = UDim2.fromScale(.54,.70)
	local holder, content, root = UIKit.panel(shell.gui, size, UDim2.fromScale(.5,.5), "Asphalt Colors", T.purple)
	UIKit.closeButton(root, function() shell:close() end)
	local tally = UIKit.outlined(content,"",20,T.gold,2.6)
	tally.Size = UDim2.new(1,0,0,28)
	tally.ZIndex = 9
	local list = UIKit.scroller(content,12)
	list.Position = UDim2.fromOffset(0,38)
	list.Size = UDim2.new(1,0,1,-42)
	list:FindFirstChildOfClass("UIListLayout"):Destroy()
	local grid = make("UIGridLayout",{CellSize=UDim2.new(.5,-16,0,248), CellPadding=UDim2.fromOffset(12,12),
		SortOrder=Enum.SortOrder.LayoutOrder},list)
	local function resize()
		local columns = if list.AbsoluteSize.X >= 480 then 2 else 1
		grid.CellSize = UDim2.new(1/columns,if columns == 2 then -16 else -24,0,248)
	end
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	resize()
	local palettes, cards, prices = {}, {}, {}
	for _, palette in ipairs(Palettes) do palettes[palette.id] = palette end
	local function refresh()
		local count = 0
		local ready = player:GetAttribute(Catalog.ReadyAttr) == true
		for _, item in ipairs(Catalog.List) do
			local card = cards[item.id]
			if not card then continue end
			local owned = Catalog.owns(player,item.id)
			local equipped = player:GetAttribute(Catalog.EquippedAttr) == item.id
			if owned then count += 1 end
			card.buy.Visible = not owned
			card.equip.Visible = owned
			card.buyCap.Text = if not ready then "Loading..." elseif item.event then (if item.id == "blueberry" then "BUNDLE" else "EVENT") elseif item.cash then
				formatCash(item.cash)
				else (if prices[item.id] then "BUY R$ " .. tostring(prices[item.id]) else "BUY WITH ROBUX")
			card.equipCap.Text = if equipped then "UNEQUIP" else "EQUIP"
			card.status.Text = if equipped then "EQUIPPED" elseif owned then "OWNED" else ""
			card.stroke.Color = if equipped then T.gold else T.navy
			card.buyCap.Active = ready
			card.equipCap.Active = ready
		end
		tally.Text = if ready then tostring(count) .. " / " .. tostring(#Catalog.List) .. " COLORS OWNED" else "LOADING YOUR COLORS..."
	end
	for index, item in ipairs(Catalog.List) do
		local palette = palettes[item.id]
		local card = make("Frame",{Name=item.id,BackgroundColor3=Color3.fromRGB(28,49,84),BorderSizePixel=0,
			LayoutOrder=index,ZIndex=9},list)
		UIKit.corner(card,12)
		local stroke = UIKit.stroke(card,2.4)
		local title = UIKit.outlined(card,item.name,20,T.white,2)
		title.Size = UDim2.new(1,-16,0,28)
		title.Position = UDim2.fromOffset(8,4)
		title.TextScaled = true
		title.ZIndex = 11
		preview(card,palette)
		local status = UIKit.outlined(card,"",14,T.gold,1.5)
		status.Position = UDim2.fromOffset(8,170)
		status.Size = UDim2.new(1,-16,0,20)
		status.ZIndex = 11
		local buy, buyCap = UIKit.button(card,"",UDim2.new(1,-24,0,46),if item.cash then T.green else T.purple,function()
			if player:GetAttribute(Catalog.ReadyAttr) then request:FireServer("buy",item.id) end
		end)
		buy.Position = UDim2.new(0,12,1,-52)
		local equip, equipCap = UIKit.button(card,"EQUIP",UDim2.new(1,-24,0,46),T.blue,function()
			if not player:GetAttribute(Catalog.ReadyAttr) then return end
			local id = if player:GetAttribute(Catalog.EquippedAttr) == item.id then "classic" else item.id
			request:FireServer("equip",id)
		end)
		equip.Position = buy.Position
		cards[item.id] = {buy=buy,buyCap=buyCap,equip=equip,equipCap=equipCap,status=status,stroke=stroke}
		if item.product then
			task.spawn(function()
				local ok, info = pcall(function() return MarketplaceService:GetProductInfo(item.product,Enum.InfoType.Product) end)
				if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then prices[item.id] = info.PriceInRobux end
				refresh()
			end)
		end
	end
	player:GetAttributeChangedSignal("HalloweenOwned_PumpkinRescue"):Connect(refresh)
 player:GetAttributeChangedSignal("HalloweenOwned_Nightmares"):Connect(refresh)
for _, attr in ipairs({Catalog.OwnedAttr,Catalog.EquippedAttr,Catalog.ReadyAttr,"BonusCollectionReward","GraveyardClaim2","Pass_BlueberryBundle"}) do
		player:GetAttributeChangedSignal(attr):Connect(refresh)
	end
	result.OnClientEvent:Connect(function(message, ok)
		if ok then Visuals.ClearTest() end
		shell:Toast(message,ok)
		refresh()
	end)
	refresh()
	shell:_register("Colors",holder,size)
end
return ColorCase
