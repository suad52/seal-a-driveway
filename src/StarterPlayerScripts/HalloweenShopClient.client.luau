local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

local allowed={[140010128837133]=true,[130455840259328]=true,[120014184236770]=true,[126526085744847]=true,[138676726700999]=true}
if not allowed[game.PlaceId] then return end

local remote = RS:WaitForChild("HalloweenShopRemote")
local playerGui=player:WaitForChild("PlayerGui")
local template=playerGui:WaitForChild("ShopUI_StudioPreview")
local Diagnostics=require(RS:WaitForChild("HalloweenDiagnostics"))
local gui=Instance.new("ScreenGui")
gui.Name="HalloweenEventShopUI";gui.DisplayOrder=math.max(60,template.DisplayOrder)
gui.IgnoreGuiInset=template.IgnoreGuiInset;gui.ZIndexBehavior=template.ZIndexBehavior
gui.ResetOnSpawn=false
local shop=template:WaitForChild("HalloweenShop"):Clone();shop.Parent=gui
local wheel=template:WaitForChild("HalloweenGachapon"):Clone();wheel.Parent=gui
template.HalloweenShop.Visible=false;template.HalloweenGachapon.Visible=false
gui.Parent=playerGui

gui.ResetOnSpawn = false
shop.Visible = false
wheel.Visible = false
gui.Enabled = false

local function nested(root, ...)
	local v = root
	for _, key in ipairs({...}) do
		v = v:WaitForChild(key)
	end
	return v
end

local sc = nested(shop, "Panel", "Inner", "Content")
local wc = nested(wheel, "Panel", "Inner", "Content")

local function bind(button, callback)
	button.Activated:Connect(callback)
end

local currentPage=""
local function open(section)
 currentPage=section
	local isShop = section == "Shop"
	local isWheel = section == "Wheel"
	shop.Visible = isShop
	wheel.Visible = isWheel
	gui.Enabled = isShop or isWheel
 Diagnostics.record(player,"HalloweenShopClient","Page",section=="" and "Closed" or section)
end

bind(nested(sc, "Tabs", "Wheel", "Cap"), function() open("Wheel") end)
bind(nested(wc, "Tabs", "Shop", "Cap"), function() open("Shop") end)
bind(nested(shop, "Panel", "Button", "Cap"), function() open("") end)
bind(nested(wheel, "Panel", "Button", "Cap"), function() open("") end)

local list = nested(sc, "Catalogue", "List")
local shopCards={}
for _, entry in ipairs({{"Squeegee", "Squeegee"}, {"AsphaltColor", "PumpkinRescue"}}) do
	local card = list:WaitForChild(entry[1])
	local attr="HalloweenOwned_"..(entry[2]=="Squeegee" and "Sweet" or "PumpkinRescue")
	local a,b=nested(card,"Pumpkins","Cap"),nested(card,"Robux","Cap")
	shopCards[#shopCards+1]={a=a,b=b,attr=attr,prices={entry[2]=="Squeegee" and "2200" or "1800",entry[2]=="Squeegee" and "R$ 129" or "R$ 99"}}
	bind(a,function() if player:GetAttribute(attr)~=true then remote:FireServer("Buy",entry[2]) end end)
	bind(b,function() if player:GetAttribute(attr)~=true then remote:FireServer("Robux",entry[2]) end end)
end

local buttons = nested(wc, "Catalogue", "PurchaseButtons")
bind(nested(buttons, "Pumpkins", "Cap"), function() remote:FireServer("Buy", "Roll") end)
bind(nested(buttons, "Robux", "Cap"), function() remote:FireServer("Robux", "Roll") end)

local Presentation = require(RS:WaitForChild("HalloweenShopPresentation"))
Presentation.install(shop, wheel)

local counts = {nested(sc, "Collected", "TextLabel"), nested(wc, "Collected", "TextLabel")}
local function refresh()
	local balance = tostring(player:GetAttribute("PumpkinCoins") or 0)
	for _, item in ipairs(counts) do
		item.Text = balance
	end
 for _,c in ipairs(shopCards) do
  local owned=player:GetAttribute(c.attr)==true
  for i,button in ipairs({c.a,c.b}) do
   local face=button:FindFirstChild("Face")
   button.Text=""
   if face then face.Text=owned and "OWNED" or c.prices[i] else button.Text=owned and "OWNED" or c.prices[i] end
   button.Active=not owned;button.Selectable=not owned;button.AutoButtonColor=not owned
  end
 end
end
player:GetAttributeChangedSignal("PumpkinCoins"):Connect(refresh)
player:GetAttributeChangedSignal("HalloweenOwned_Sweet"):Connect(refresh)
player:GetAttributeChangedSignal("HalloweenOwned_PumpkinRescue"):Connect(refresh)
refresh()

local bound=setmetatable({},{__mode="k"})
local function attach(prompt)
 if not prompt:IsA("ProximityPrompt") or prompt.Name~="HalloweenShopPrompt" or bound[prompt] then return end
 local model=prompt:FindFirstAncestor("chushiguo2")
 if not model then return end
 local container=model.Parent
	local correct=container and (container.Name=="HalloweenShop" and container.Parent==workspace or game.PlaceId==138676726700999 and container.Name=="Shop" and container.Parent and container.Parent.Name=="Neighbourhood")
 if not correct then return end
 bound[prompt]=true
 prompt.Triggered:Connect(function() open("Shop") end)
end
for _,v in ipairs(workspace:GetDescendants()) do attach(v) end
workspace.DescendantAdded:Connect(attach)
local audit=Instance.new("BindableFunction")
audit.Name="Audit";audit.Parent=script
audit.OnInvoke=function()
 print("[HalloweenShopClient] place="..game.PlaceId.." page="..currentPage.." enabled="..tostring(gui.Enabled).." shop="..tostring(shop.Visible).." wheel="..tostring(wheel.Visible).." parent="..tostring(gui.Parent))
 remote:FireServer("Debug")
end
gui:GetPropertyChangedSignal("Enabled"):Connect(function()
 if currentPage~="" and not gui.Enabled then
  Diagnostics.record(player,"HalloweenShopClient","UnexpectedDisable",currentPage,true)
  task.defer(function() if currentPage~="" and gui.Parent then gui.Enabled=true end end)
 end
end)

local toastGui = Instance.new("ScreenGui")
toastGui.Name = "HalloweenShopToast"
toastGui.ResetOnSpawn = false
toastGui.DisplayOrder = 140
toastGui.Parent = player.PlayerGui

local toast = Instance.new("TextLabel")
toast.Size = UDim2.fromOffset(420, 72)
toast.AnchorPoint = Vector2.new(0.5, 1)
toast.Position = UDim2.new(0.5, 0, 1, -95)
toast.BackgroundColor3 = Color3.fromRGB(45, 25, 61)
toast.TextColor3 = Color3.fromRGB(255, 225, 125)
toast.Font = Enum.Font.FredokaOne
toast.TextScaled = true
toast.TextWrapped = true
toast.Visible = false
toast.Parent = toastGui
Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 12)

local serial = 0
local function message(msg)
	serial += 1
	local id = serial
	toast.Text = tostring(msg)
	toast.Visible = true
	task.delay(4, function()
		if serial == id then
			toast.Visible = false
		end
	end)
end

remote.OnClientEvent:Connect(function(action, info)
	if action=="OpenShop" then open("Shop")
 elseif action=="Debug" then
  print("[HalloweenShopServer] "..tostring(info))
 elseif action == "Message" then
		message(info)
	elseif action == "RollResult" and type(info) == "table" then
		open("Wheel")
		Presentation.spin(wheel, info, function()
			if (info.compensation or 0)>0 then
    message("DUPLICATE: +"..info.compensation.." Pumpkins\nSpin cost: "..tostring(info.spent or 0).." | Balance: "..tostring(info.balanceAfter))
   else message("YOU WON: " .. tostring(info.name)) end
		end)
	end
end)
