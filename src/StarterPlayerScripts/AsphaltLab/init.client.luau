-- Asphalt Lab: removable LOCAL visual test. Install as one LocalScript in
-- StarterPlayerScripts, with Palettes, TestPaint and VisualFX as child modules.
-- Defaults to Studio only. Set boolean attribute AllowOutsideStudio=true
-- on this script for a private published test. No server writes or saves.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() and script:GetAttribute("AllowOutsideStudio") ~= true then
	print("[AsphaltLab] Studio-only mode. Set AllowOutsideStudio=true on AsphaltLab for a private published test.")
	return
end


local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
if playerGui:FindFirstChild("AsphaltLabUI") then return end
local pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local palettes = require(pack:WaitForChild("ColorPalettes"))
local controller = require(pack:WaitForChild("ColorVisuals"))
local selected = controller.Current()
local alive = true
local connections = {}
-- UI: no downloaded UI assets, remote calls, or per-frame UI animation.
local function make(class, props, parent)
	local instance = Instance.new(class)
	for key,value in pairs(props) do instance[key] = value end
	instance.Parent = parent
	return instance
end
local function corner(parent,radius) make("UICorner",{CornerRadius=UDim.new(0,radius)},parent) end
local function label(parent,text,size,pos,font,textColor)
	return make("TextLabel",{Text=text,TextSize=size,Font=font or Enum.Font.Gotham,
		TextColor3=textColor or Color3.fromRGB(237,239,246),BackgroundTransparency=1,
		TextXAlignment=Enum.TextXAlignment.Left,Position=pos,Size=UDim2.new(1,-36,0,size+8)},parent)
end
local gui = make("ScreenGui",{Name="AsphaltLabUI",ResetOnSpawn=false,DisplayOrder=100,
	ZIndexBehavior=Enum.ZIndexBehavior.Sibling},playerGui)
local panel = make("Frame",{Name="Panel",AnchorPoint=Vector2.new(1,.5),
	Position=UDim2.new(1,-18,.5,0),Size=UDim2.fromOffset(330,680),
	BackgroundColor3=Color3.fromRGB(19,21,29),BorderSizePixel=0},gui)
corner(panel,18)
make("UIStroke",{Color=Color3.fromRGB(66,70,88),Thickness=1},panel)
local uiScale = make("UIScale",{Scale=1},panel)
local badge = label(panel,"ASPHALT LAB  /  TEST",11,UDim2.fromOffset(18,15),Enum.Font.GothamBold,Color3.fromRGB(174,161,255))
label(panel,"Choose a finish",21,UDim2.fromOffset(18,37),Enum.Font.GothamBold)
label(panel,"Recolors all poured and finished asphalt",12,UDim2.fromOffset(18,67),nil,Color3.fromRGB(155,161,182))
local hide = make("TextButton",{Text="−",TextSize=24,Font=Enum.Font.Gotham,
	TextColor3=Color3.fromRGB(213,217,230),BackgroundTransparency=1,
	Position=UDim2.new(1,-43,0,9),Size=UDim2.fromOffset(32,28)},panel)
local cardList = make("ScrollingFrame",{Name="Finishes",
	Position=UDim2.fromOffset(0,100),Size=UDim2.new(1,0,0,476),
	CanvasSize=UDim2.fromOffset(0,#palettes*60),ScrollingDirection=Enum.ScrollingDirection.Y,
	ScrollBarThickness=3,ScrollBarImageColor3=Color3.fromRGB(177,153,255),
	BackgroundTransparency=1,BorderSizePixel=0,Active=true},panel)
local cards = {}
for i,p in ipairs(palettes) do
	local button = make("TextButton",{Name=p.id,Text="",AutoButtonColor=false,
		Position=UDim2.fromOffset(14,(i-1)*60),Size=UDim2.new(1,-28,0,53),
		BackgroundColor3=Color3.fromRGB(30,33,44),BorderSizePixel=0},cardList)
	corner(button,10)
	local stroke = make("UIStroke",{Color=Color3.fromRGB(57,62,80),Thickness=1},button)
	local swatch = make("Frame",{Position=UDim2.fromOffset(9,8),Size=UDim2.fromOffset(37,37),
		BackgroundColor3=Color3.new(1,1,1),BorderSizePixel=0},button)
	corner(swatch,9)
	make("UIGradient",{Color=p.sequence,Rotation=25},swatch)
	label(button,p.name,14,UDim2.fromOffset(56,6),Enum.Font.GothamBold)
	label(button,p.note,10,UDim2.fromOffset(56,28),nil,Color3.fromRGB(165,171,191))
	local dot = make("Frame",{Position=UDim2.new(1,-16,0,8),Size=UDim2.fromOffset(6,6),
		BackgroundColor3=Color3.fromRGB(191,175,255),BorderSizePixel=0,Visible=false},button)
	corner(dot,3)
	cards[i] = {button=button,stroke=stroke,dot=dot}
end
local status = label(panel,"Selected: Classic",12,UDim2.fromOffset(18,586),Enum.Font.GothamBold)
label(panel,"Local preview · no saving · F6 to hide",11,UDim2.fromOffset(18,610),nil,Color3.fromRGB(155,161,182))
local stop = make("TextButton",{Text="End test and restore equipped color",TextSize=11,
	Font=Enum.Font.GothamMedium,TextColor3=Color3.fromRGB(195,200,216),
	Position=UDim2.fromOffset(14,639),Size=UDim2.new(1,-28,0,28),
	BackgroundColor3=Color3.fromRGB(36,39,51),BorderSizePixel=0},panel)
corner(stop,8)
local reopen = make("TextButton",{Text="ASPHALT LAB",TextSize=12,Font=Enum.Font.GothamBold,
	TextColor3=Color3.fromRGB(235,228,255),BackgroundColor3=Color3.fromRGB(35,31,53),
	AnchorPoint=Vector2.new(1,0),Position=UDim2.new(1,-18,0,16),Size=UDim2.fromOffset(145,36),
	Visible=false,BorderSizePixel=0},gui)
corner(reopen,10)
local function paintSelection()
	for i,card in ipairs(cards) do
		local on = palettes[i] == selected
		card.stroke.Color = if on then Color3.fromRGB(177,153,255) else Color3.fromRGB(57,62,80)
		card.stroke.Thickness = if on then 2 else 1
		card.button.BackgroundColor3 = if on then Color3.fromRGB(47,40,67) else Color3.fromRGB(30,33,44)
		card.dot.Visible = on
	end
	status.Text = "Selected: " .. selected.name
end
connections[#connections+1] = controller.Changed:Connect(function(p)
 if not alive then return end
 selected = p
 paintSelection()
end)
local lastSwitch = -math.huge
local function selectPalette(p)
	if not alive or p == selected or os.clock()-lastSwitch < .25 then return end
	lastSwitch = os.clock()
	selected = p
	controller.SetTest(p.id)
	print("[AsphaltLab] Selected: " .. p.name)
	
	paintSelection()
end
for i,card in ipairs(cards) do
	connections[#connections+1] = card.button.Activated:Connect(function() selectPalette(palettes[i]) end)
end
local function toggle()
	panel.Visible = not panel.Visible
	reopen.Visible = not panel.Visible
end
connections[#connections+1] = hide.Activated:Connect(toggle)
connections[#connections+1] = reopen.Activated:Connect(toggle)
connections[#connections+1] = UserInputService.InputBegan:Connect(function(input,handled)
	if not handled and input.KeyCode == Enum.KeyCode.F6 then toggle() end
end)
local function resize()
	local camera = workspace.CurrentCamera
	if camera then
		local size = camera.ViewportSize
		uiScale.Scale = math.min(1,math.max(.25,math.min((size.Y-70)/680,(size.X-36)/330)))
	end
end
local viewportConnection
local function bindCamera()
	if viewportConnection then viewportConnection:Disconnect() end
	local camera = workspace.CurrentCamera
	if camera then viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize) end
	resize()
end
connections[#connections+1] = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera)

local function cleanup()
 if not alive then return end
 alive = false
 controller.ClearTest()
 for _, connection in ipairs(connections) do connection:Disconnect() end
 if viewportConnection then viewportConnection:Disconnect() end
 gui:Destroy()
end
connections[#connections+1] = stop.Activated:Connect(cleanup)
connections[#connections+1] = script.Destroying:Connect(cleanup)
connections[#connections+1] = gui.Destroying:Connect(cleanup)
panel.Visible = false
reopen.Visible = true
paintSelection()
bindCamera()
print("[AsphaltLab] Ready. Test previews do not grant ownership. F6 hides the panel.")
