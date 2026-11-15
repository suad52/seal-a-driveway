local UIS = game:GetService("UserInputService")
local GS = game:GetService("GuiService")
local CAS = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local PPS = game:GetService("ProximityPromptService")
local C = {}
local changed = Instance.new("BindableEvent")
C.Changed = changed.Event
local callbacks = setmetatable({}, {__mode="k"})
local sliders = setmetatable({}, {__mode="k"})
local actions = {}
local closers = setmetatable({}, {__mode="k"})
local shown = {}
local menuOpen = false
local shell

function C.active()
 return UIS.PreferredInput == Enum.PreferredInput.Gamepad
end
function C.blocked()
 return menuOpen or GS.MenuIsOpen or GS.SelectedObject ~= nil or UIS:GetFocusedTextBox() ~= nil
end
function C.key(code)
 local ok, value = pcall(UIS.GetStringForKeyCode, UIS, code)
 if ok and value ~= "" then return value end
 local fallback = {ButtonR2="RT / R2",ButtonL2="LT / L2",ButtonL1="LB / L1",ButtonR1="RB / R1",ButtonA="A / Cross",ButtonB="B / Circle",ButtonX="X / Square",ButtonY="Y / Triangle"}
 return fallback[code.Name] or code.Name
end
function C.promptKey()
 for prompt in pairs(shown) do
  if prompt.Parent and prompt.Enabled then return C.key(prompt.GamepadKeyCode) end
 end
 return C.key(Enum.KeyCode.ButtonX)
end
function C.bindButton(button, callback)
 button.Selectable = true
 callbacks[button] = callback
end
function C.registerAction(name, callback) actions[name] = callback end
function C.registerClose(root, callback) closers[root] = callback end
function C.slider(button, adjust) sliders[button] = adjust; button.Selectable = true end
local function visible(object)
 local node = object
 while node do
  if node:IsA("GuiObject") and not node.Visible then return false end
  if node:IsA("ScreenGui") then return node.Enabled end
  node = node.Parent
 end
 return false
end
local function activate(button)
 local callback = button and callbacks[button]
 if callback and button.Active and visible(button) then callback();return true end
 return false
end
function C.focus(root)
 if not C.active() then return end
 task.defer(function()
  if not root or not root.Parent or not visible(root) then return end
  local best
  for _,button in ipairs(root:GetDescendants()) do
   if button:IsA("GuiButton") and button.Selectable and button.Active and visible(button) then
    if not best or button.AbsolutePosition.Y < best.AbsolutePosition.Y
     or (button.AbsolutePosition.Y == best.AbsolutePosition.Y and button.AbsolutePosition.X < best.AbsolutePosition.X) then best = button end
   end
  end
  GS.SelectedObject = best
 end)
end
function C.setMenu(open, root)
 menuOpen = open
 changed:Fire()
 if open then C.focus(root) else GS.SelectedObject = nil end
end
function C.watchPanel(root)
 root.SelectionGroup = true
 root:GetPropertyChangedSignal("Visible"):Connect(function()
  if root.Visible then C.focus(root)
  elseif GS.SelectedObject and GS.SelectedObject:IsDescendantOf(root) then GS.SelectedObject = nil end
 end)
 C.focus(root)
end
function C.chip(keyboard)
 local result = table.clone(keyboard)
 result.keys = nil
 if keyboard.keys or keyboard.cap == "W" then
  result.cap = "LEFT STICK"
 elseif keyboard.cap == "LMB" then
  result.cap = C.key(Enum.KeyCode.ButtonR2);result.hold = true
 elseif keyboard.cap == "E" then
  result.cap = C.promptKey()
 elseif tonumber(keyboard.cap or "") then
  result.cap = C.key(Enum.KeyCode.ButtonL1) .. " / " .. C.key(Enum.KeyCode.ButtonR1)
 end
 return result
end

UIS:GetPropertyChangedSignal("PreferredInput"):Connect(function()
 if not C.active() then GS.SelectedObject = nil end
 changed:Fire()
end)
UIS.GamepadDisconnected:Connect(function() changed:Fire() end)
UIS.WindowFocusReleased:Connect(function() changed:Fire() end)
GS:GetPropertyChangedSignal("SelectedObject"):Connect(function() changed:Fire() end)
GS.MenuOpened:Connect(function() changed:Fire() end)
PPS.PromptShown:Connect(function(prompt) shown[prompt] = true end)
PPS.PromptHidden:Connect(function(prompt) shown[prompt] = nil end)

local function cycle(direction)
 if not shell or shell.seat or C.blocked() then return false end
 if (tonumber(shell.plr:GetAttribute("AfkPlot")) or 0) > 0 then return false end
 local slots = {}
 local current = 0
 for i,slot in ipairs(shell.slots) do
  if slot.tool and slot.tool.Parent then
   table.insert(slots,i)
   if slot.tool.Parent == shell.plr.Character then current = #slots end
  end
 end
 if #slots == 0 then return false end
 local nextIndex = if current == 0 then (if direction > 0 then 1 else #slots) else ((current - 1 + direction) % #slots) + 1
 shell:_equipSlot(slots[nextIndex])
 return true
end

function C.attach(value)
 if shell then return end
 shell = value
 GS.AutoSelectGuiEnabled = true
 local function bind(name, key, callback)
  CAS:BindActionAtPriority(name, function(_,state)
   if not C.active() or GS.MenuIsOpen or UIS:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
   if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
   return if callback() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
  end, false, 2500, key)
 end
 bind("ConsolePreviousTool", Enum.KeyCode.ButtonL1, function()return cycle(-1)end)
 bind("ConsoleNextTool", Enum.KeyCode.ButtonR1, function()return cycle(1)end)
 bind("ConsoleMenu", Enum.KeyCode.DPadUp, function()
  if GS.SelectedObject then return false end
  C.focus(if shell.open then shell.panels[shell.open] else shell.gui)
  return true
 end)
 bind("ConsoleBack", Enum.KeyCode.ButtonB, function()
  local selected = GS.SelectedObject
  while selected do
   local close = closers[selected]
   if close then close();GS.SelectedObject=nil;return true end
   selected=selected.Parent
  end
  if shell.prompt and shell.prompt.Visible then shell.promptHide();GS.SelectedObject=nil;return true end
  if shell.open then shell:close();return true end
  if GS.SelectedObject then GS.SelectedObject=nil;return true end
  if shell.seat and shell.consoleExit then return activate(shell.consoleExit) end
  return false
 end)
 bind("ConsoleLastZone", Enum.KeyCode.DPadDown, function()
  if C.blocked() or shell.seat then return false end
  local action=actions.LastZone
  if action then action();return true end
  return false
 end)
 local function side(direction)
  local adjust=sliders[GS.SelectedObject]
  if adjust then adjust(direction*.05);return true end
  if C.blocked() or not shell.seat then return false end
  return activate(if direction < 0 then shell.pourBtn and shell.pourBtn.cap else shell.bladeBtn and shell.bladeBtn.cap)
 end
 bind("ConsoleLeft",Enum.KeyCode.DPadLeft,function()return side(-1)end)
 bind("ConsoleRight",Enum.KeyCode.DPadRight,function()return side(1)end)

 local gui=Instance.new("ScreenGui")
 gui.Name="ConsoleHints";gui.ResetOnSpawn=false;gui.IgnoreGuiInset=false;gui.DisplayOrder=19
 gui.Parent=shell.plr:WaitForChild("PlayerGui")
 local label=Instance.new("TextLabel")
 label.AnchorPoint=Vector2.new(.5,1);label.Position=UDim2.new(.5,0,1,-108)
 label.Size=UDim2.new(.72,0,0,50);label.BackgroundColor3=Color3.fromRGB(12,32,53)
 label.BackgroundTransparency=.18;label.TextColor3=Color3.new(1,1,1);label.TextSize=18
 label.TextWrapped=true;label.Font=Enum.Font.GothamBold;label.Parent=gui
 local corner=Instance.new("UICorner");corner.CornerRadius=UDim.new(0,9);corner.Parent=label
 local cross=Instance.new("TextLabel")
 cross.AnchorPoint=Vector2.new(.5,.5);cross.Position=UDim2.fromScale(.5,.5);cross.Size=UDim2.fromOffset(20,20)
 cross.BackgroundTransparency=1;cross.Text="+";cross.TextSize=24;cross.TextColor3=Color3.new(1,1,1)
 cross.TextStrokeTransparency=.25;cross.Parent=gui
 local function refresh()
  gui.Enabled=C.active()
  cross.Visible=C.active() and not C.blocked() and not shell.seat
  if shell.seat then
   label.Text=C.key(Enum.KeyCode.ButtonR2).." / "..C.key(Enum.KeyCode.ButtonL2).." DRIVE  |  LEFT STICK STEER  |  D-PAD LEFT POUR / RIGHT BLADE  |  "..C.key(Enum.KeyCode.ButtonB).." EXIT"
  elseif C.blocked() then
   label.Text="D-PAD / LEFT STICK SELECT  |  "..C.key(Enum.KeyCode.ButtonA).." CONFIRM  |  "..C.key(Enum.KeyCode.ButtonB).." BACK  |  LEFT / RIGHT ADJUST SLIDER"
  else
   label.Text=C.key(Enum.KeyCode.ButtonR2).." HOLD TO USE  |  "..C.key(Enum.KeyCode.ButtonL1).." / "..C.key(Enum.KeyCode.ButtonR1).." TOOLS  |  D-PAD UP MENU / DOWN LAST ZONE"
  end
 end
 C.Changed:Connect(refresh)
 task.spawn(function()
  while gui.Parent do refresh();task.wait(.25) end
 end)
 refresh()
end
return C
