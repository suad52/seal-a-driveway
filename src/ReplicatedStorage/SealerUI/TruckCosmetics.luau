local RS=game:GetService("ReplicatedStorage")
local UI=require(RS:WaitForChild("SealerUI"):WaitForChild("UIKit"))
local Pack=RS:WaitForChild("StellarQuest")
local C=require(Pack.StellarConfig)
local remote=Pack:WaitForChild("Remote")
local M={}
function M.mount(content,list,player)
 local pane=Instance.new("Frame")
 pane.Name="TruckVFX";pane.BackgroundTransparency=1;pane.Visible=false;pane.ZIndex=12;pane.Parent=content
 local scroll=Instance.new("ScrollingFrame")
 scroll.Name="TruckVFXCards";scroll.BackgroundTransparency=1;scroll.BorderSizePixel=0
 scroll.ScrollBarThickness=5;scroll.AutomaticCanvasSize=Enum.AutomaticSize.Y;scroll.CanvasSize=UDim2.new()
 scroll.Size=UDim2.fromScale(1,1);scroll.ZIndex=12;scroll.Parent=pane
 local layout=Instance.new("UIGridLayout",scroll)
 layout.CellPadding=UDim2.fromOffset(12,12);layout.SortOrder=Enum.SortOrder.LayoutOrder
 local function resize() local two=scroll.AbsoluteSize.X>=480;layout.CellSize=UDim2.new(two and .5 or 1,two and -16 or -24,0,254) end
 scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize);resize()
 local cards={}
 local items={
  {id="Haunted",title="HAUNTED TRUCK",subtitle="HALLOWEEN EVENT",icon="rbxassetid://83131450407277"},
  {id="Paid",title="STAR VFX",subtitle="TRUCK EFFECT",icon=C.Icon},
  {id="Stellar",title="STELLAR VFX",subtitle="7 DAILY TASK SETS",icon=C.Icon},
 }
 local function owned(id)
  if id=="Haunted" then return player:GetAttribute("GraveyardClaim4")==1 end
  return player:GetAttribute(id=="Paid" and "TruckVFXPaidOwned" or "TruckVFXStellarOwned")==true
 end
 local function selected()
  local id=player:GetAttribute("TruckVFXSelected")
  if (not id or id=="") and player:GetAttribute("HalloweenTruckEquipped")==true then return "Haunted" end
  return id
 end
 for i,item in ipairs(items) do
  local card=Instance.new("Frame",scroll)
  card.Name=item.id;card.LayoutOrder=i;card.BackgroundColor3=Color3.fromRGB(28,49,84);card.BorderSizePixel=0;card.ZIndex=12
  UI.corner(card,12);local edge=UI.stroke(card,2.4)
  local icon=Instance.new("ImageLabel",card)
  icon.Name="TruckVFXIcon";icon.Image=item.icon;icon.BackgroundTransparency=1
  icon.Size=UDim2.new(1,-24,0,150);icon.Position=UDim2.fromOffset(12,8);icon.ScaleType=Enum.ScaleType.Fit;icon.ZIndex=14
  local title=UI.outlined(card,item.title,19,Color3.fromRGB(255,238,197),2.4)
  title.Position=UDim2.fromOffset(8,164);title.Size=UDim2.new(1,-16,0,26);title.TextXAlignment=Enum.TextXAlignment.Center;title.ZIndex=15
  local rarity=UI.outlined(card,item.subtitle,12,Color3.fromRGB(255,193,67),1.5)
  rarity.Position=UDim2.fromOffset(8,190);rarity.Size=UDim2.new(1,-16,0,16);rarity.TextXAlignment=Enum.TextXAlignment.Center;rarity.ZIndex=15
  local button,cap=UI.button(card,"LOADING",UDim2.new(1,-24,0,40),Color3.fromRGB(95,168,229),function()
   if player:GetAttribute("StellarReady")~=true then return end
   if owned(item.id) then remote:FireServer("Equip",selected()==item.id and "" or item.id)
   elseif item.id=="Paid" then game:GetService("MarketplaceService"):PromptProductPurchase(player,C.ProductId) end
  end)
  button.Position=UDim2.fromOffset(12,208);button.ZIndex=16
  for _,o in ipairs(button:GetDescendants()) do if o:IsA("GuiObject") then o.ZIndex=math.max(o.ZIndex,17) end end
  cards[item.id]={cap=cap,edge=edge}
 end
 local function refresh()
  local ready=player:GetAttribute("StellarReady")==true
  for _,item in ipairs(items) do
   local on=owned(item.id) and selected()==item.id
   cards[item.id].cap.Text=not ready and "LOADING..." or owned(item.id) and (on and "UNEQUIP" or "EQUIP") or item.id=="Paid" and "R$ 49" or "EVENT"
   cards[item.id].edge.Color=on and Color3.fromRGB(255,203,82) or Color3.fromRGB(64,102,179)
  end
 end
 for _,attr in ipairs({"StellarReady","GraveyardClaim4","HalloweenTruckEquipped","TruckVFXPaidOwned","TruckVFXStellarOwned","TruckVFXSelected"}) do player:GetAttributeChangedSignal(attr):Connect(refresh) end
 local tabs=Instance.new("Frame",content)
 tabs.Name="CosmeticTabs";tabs.BackgroundTransparency=1;tabs.Position=UDim2.fromOffset(0,52);tabs.Size=UDim2.new(1,0,0,56);tabs.ZIndex=15
 -- the pet pane is a third tab of this same bar, mounted by its own module so
 -- this one never has to know what is in it
 local petPane=require(RS:WaitForChild("SealerUI"):WaitForChild("PetCase")).mount(content,player)
 local function show(which)
  list.Visible=which=="Skins";pane.Visible=which=="Truck";petPane.Visible=which=="Pets"
 end
 UI.button(tabs,"SQUEEGEES",UDim2.new(.32,0,0,46),Color3.fromRGB(90,170,230),function() show("Skins") end)
 local second=UI.button(tabs,"TRUCK VFX",UDim2.new(.32,0,0,46),Color3.fromRGB(180,100,225),function() show("Truck") end)
 second.Position=UDim2.fromScale(.34,0)
 local third=UI.button(tabs,"EQUIP PET",UDim2.new(.32,0,0,46),Color3.fromRGB(120,220,160),function() show("Pets") end)
 third.Position=UDim2.fromScale(.68,0)
 local badge=UI.outlined(second,"NEW",15,Color3.fromRGB(255,231,70),2)
 badge.AnchorPoint=Vector2.new(1,0);badge.Position=UDim2.new(1,-3,0,-12);badge.Size=UDim2.fromOffset(48,23);badge.ZIndex=30
 list.Position=UDim2.fromOffset(0,114);list.Size=UDim2.new(1,0,1,-122);pane.Position=list.Position;pane.Size=list.Size;petPane.Position=list.Position;petPane.Size=list.Size
 refresh()
end
return M
