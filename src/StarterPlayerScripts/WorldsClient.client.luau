local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local UIS = game:GetService("UserInputService")
local GS = game:GetService("GuiService")
local CAS = game:GetService("ContextActionService")
local SHOW_WORLDS_MENU = true
local Config = require(RS:WaitForChild("WorldsConfig"))
local request = RS:WaitForChild("WorldsRequest")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local openerGui = playerGui:WaitForChild("Worlds")
local ui = playerGui:WaitForChild("WorldUI")
local openButton = openerGui:WaitForChild("Worlds")
local frame = ui:WaitForChild("Frame")
local panel = frame:WaitForChild("Panel")
local list = panel:WaitForChild("InnerFrame"):WaitForChild("ScrollingFrame")
local closeButton = panel:WaitForChild("CloseFrame"):WaitForChild("CloseButton")
local one = list:WaitForChild("World1")
local two = list:WaitForChild("World2")
local button1 = one:WaitForChild("ButtonFrame"):WaitForChild("Button")
local button2 = two:WaitForChild("ButtonFrame"):WaitForChild("Button")
local face1, face2 = button1:WaitForChild("Face"), button2:WaitForChild("Face")
local Console
local sealerUI = RS:FindFirstChild("SealerUI")
local consoleModule = sealerUI and sealerUI:FindFirstChild("ConsoleControls")
if consoleModule then local ok, result = pcall(require, consoleModule); if ok then Console = result end end
ui.ResetOnSpawn = false; openerGui.ResetOnSpawn = false
ui.Enabled = false; openerGui.Enabled = true; openButton.Visible = true
ui.Enabled = false; openerGui.Enabled = SHOW_WORLDS_MENU; openButton.Visible = SHOW_WORLDS_MENU
ui.DisplayOrder = math.max(ui.DisplayOrder, 110)
frame.Visible = true; panel.Visible = true; list.Visible = true
panel.InnerFrame.Visible = true
local desert = list:FindFirstChild("Desert")
if desert and desert:IsA("GuiObject") then desert.Visible = false end
local subtitle
for _, child in ipairs(two:GetChildren()) do
	if child:IsA("TextLabel") and child.Text == "Finish all zones" then subtitle = child end
end
local price, pending = nil, false
local function refresh()
	local current = player:GetAttribute("WorldsCurrent") or 0
	local ready = player:GetAttribute("WorldsReady") == true
	local unlocked = player:GetAttribute("WorldsCanTravel2") == true
	local travelling = player:GetAttribute("WorldsTravelling") == true
	face1.Text = if not ready then "Loading..." elseif current == 1 then "You are here" else "Teleport"
	face2.Text = if not ready then "Loading..." elseif current == 2 then "You are here"
		elseif unlocked then "Teleport" elseif player:GetAttribute("WorldsAccessReady") ~= true then "Loading access..."
		else (if price then "Unlock world R$" .. price else "Unlock World 2")
	button1.Active = ready and current ~= 1 and not travelling
	button2.Active = ready and current ~= 2 and not travelling and (unlocked or player:GetAttribute("WorldsAccessReady") == true)
	button1.Selectable = button1.Active; button2.Selectable = button2.Active
	if subtitle then
		subtitle.Text = if player:GetAttribute("WorldsPaid2") == true then "Permanently unlocked" elseif unlocked then "Unlocked" else "Finish World 1 or unlock permanently"
	end
	local lock = two:FindFirstChild("Icon")
	if lock and lock:IsA("GuiObject") then lock.Visible = not unlocked end
end
local previousSelection
local function setOpen(open)
	if open and not SHOW_WORLDS_MENU then return end
	if ui.Enabled == open then return end
	if open then previousSelection = GS.SelectedObject end
	ui.Enabled = open
	if open then
		refresh()
		if Console then Console.setMenu(true, panel)
		elseif UIS.PreferredInput == Enum.PreferredInput.Gamepad then GS.SelectedObject = closeButton end
	else
		if Console then Console.setMenu(false) end
		if GS.SelectedObject and GS.SelectedObject:IsDescendantOf(ui) then GS.SelectedObject = nil end
		if UIS.PreferredInput == Enum.PreferredInput.Gamepad and previousSelection and previousSelection:IsDescendantOf(playerGui) then GS.SelectedObject = previousSelection end
	end
end
openButton.Activated:Connect(function() setOpen(not ui.Enabled) end)
closeButton.Activated:Connect(function() setOpen(false) end)
openButton.Selectable = true; closeButton.Selectable = true
if Console then Console.registerClose(panel, function() setOpen(false) end) end
CAS:BindActionAtPriority("WorldsMenuBack", function(_, state)
	if not ui.Enabled or GS.MenuIsOpen then return Enum.ContextActionResult.Pass end
	if state == Enum.UserInputState.Begin then setOpen(false) end
	return Enum.ContextActionResult.Sink
end, false, 3000, Enum.KeyCode.ButtonB)
local function send(action, destination)
	if pending then return end
	pending = true; request:FireServer(action, destination)
	task.delay(3, function() pending = false end)
end
button1.Activated:Connect(function()
	if button1.Active then send("Travel", 1) end
end)
button2.Activated:Connect(function()
	if not button2.Active then return end
	if player:GetAttribute("WorldsCanTravel2") == true then send("Travel", 2)
	else send("BuyWorld2", 2) end
end)
for _, name in ipairs({"WorldsCurrent", "WorldsReady", "WorldsCanTravel2", "WorldsPaid2", "WorldsAccessReady", "WorldsTravelling"}) do
	player:GetAttributeChangedSignal(name):Connect(refresh)
end
refresh()
task.spawn(function()
	local ok, info = pcall(function() return MarketplaceService:GetProductInfo(Config.UnlockProductId, Enum.InfoType.Product) end)
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		price = tostring(info.PriceInRobux); refresh()
	end
end)