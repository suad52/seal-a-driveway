local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local playerGui=Players.LocalPlayer:WaitForChild("PlayerGui")
local screen=playerGui:WaitForChild("StellarQuestUI")
local icon=screen:WaitForChild("StellarQuestOpen")
local holder=Instance.new("Frame")
holder.Name="StellarIconAnchor"
holder.BackgroundTransparency=1
holder.Size=UDim2.fromScale(1,1)
holder.Position=UDim2.fromScale(0,0)
holder.Active=false
holder.Visible=false
holder.Parent=screen
icon.Parent=holder
icon.AnchorPoint=Vector2.new(.5,0)
local offer
local dirty=true
playerGui.DescendantAdded:Connect(function(v)
 if v.Name=="InstantCoatOffer" or v.Name=="Area" then dirty=true end
end)
local function visible(v)
 while v and v~=playerGui do
  if v:IsA("GuiObject") and not v.Visible then return false end
  if v:IsA("ScreenGui") and not v.Enabled then return false end
  v=v.Parent
 end
 return v==playerGui
end
local connection
connection=RunService.RenderStepped:Connect(function()
 if not screen.Parent or not icon.Parent then connection:Disconnect();return end
 if offer and not offer:IsDescendantOf(playerGui) then offer=nil;dirty=true end
 if dirty then
  dirty=false
  for _,v in ipairs(playerGui:GetDescendants()) do
   if v.Name=="InstantCoatOffer" and v:IsA("GuiObject") and v.Parent and v.Parent.Name=="Area" then offer=v;break end
  end
 end
 holder.Visible=offer~=nil and visible(offer)
 if not holder.Visible then return end
 local size=offer.AbsoluteSize
 local pos=offer.AbsolutePosition
 local origin=holder.AbsolutePosition
 local width=math.clamp(size.X*.95,60,114)
 icon.Size=UDim2.fromOffset(width,width)
 icon.Position=UDim2.fromOffset(pos.X+size.X*.5-origin.X,pos.Y+size.Y+38-origin.Y)
end)
