local RS = game:GetService("ReplicatedStorage")
local Marketplace = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")
local Pack = RS:WaitForChild("SealerUI")
local Bindings = require(Pack:WaitForChild("ShopBindings"))
local Passes = require(Pack:WaitForChild("Passes"))
local CashPacks = require(Pack:WaitForChild("CashPacks"))
local Boosts = require(Pack:WaitForChild("Boosts"))
local Console = require(Pack:WaitForChild("ConsoleControls"))
local Robot = require(RS:WaitForChild("DrivewaySealer"):WaitForChild("RobotConfig"))
local Shop = {}
local function caption(button, text)
 if button:IsA("TextButton") and button.Text ~= text then button.Text = text end
 local face = button:FindFirstChild("Face")
 if face and face:IsA("TextLabel") and face.Text ~= text then face.Text = text end
end
function Shop.mount(self)
 local source = self.plr:WaitForChild("PlayerGui"):WaitForChild("ShopUI_StudioPreview", 15)
 assert(source, "[AuthoredShop] Missing StarterGui.ShopUI_StudioPreview")
 source.Enabled = false
 local first = assert(source:FindFirstChild("Shop_Passes"), "Missing Shop_Passes")
 local size = first.Size
 local holder = Instance.new("Frame")
 holder.Name = "AuthoredShop"
 holder.BackgroundTransparency = 1
 holder.BorderSizePixel = 0
 holder.AnchorPoint = first.AnchorPoint
 holder.Position = first.Position
 holder.Size = size
 holder.Visible = false
 holder.Parent = self.gui
 local pages, rows, connections = {}, {}, {}
 local alive = true
 local function connect(signal, callback)
  local connection = signal:Connect(callback)
  table.insert(connections, connection)
  return connection
 end
 local function bind(button, callback)
  button.Active = true
  button.Selectable = true
  local last = -math.huge
  local function activate()
   if not alive or not holder.Visible or not button.Active then return end
   local parent = button
   while parent and parent ~= holder do
    if parent:IsA("GuiObject") and not parent.Visible then return end
    parent = parent.Parent
   end
   if os.clock() - last < .2 then return end
   last = os.clock()
   callback()
  end
  connect(button.Activated, activate)
  Console.bindButton(button, activate)
 end
 for _, tab in ipairs(Bindings.Pages) do
  local template = assert(source:FindFirstChild("Shop_" .. tab), "Missing Shop_" .. tab)
  local page = template:Clone()
  page.Size = UDim2.fromScale(1, 1)
  page.Position = UDim2.fromScale(.5, .5)
  page.AnchorPoint = Vector2.new(.5, .5)
  page.Visible = false
  page.Parent = holder
  pages[tab] = page
 end
 local function refresh()
  for _, row in ipairs(rows) do row.refresh() end
 end
 local function select(tab, focus)
  if not pages[tab] then return end
  self.shopTab = tab
  for id, page in pairs(pages) do page.Visible = id == tab end
  refresh()
  if focus and Console.active() and holder.Visible then
   local tabs = pages[tab].Panel.Inner.Content.Tabs
   GuiService.SelectedObject = tabs["Tab_" .. tab].Cap
  end
 end
 self.selectShopTab = function(tab) select(tab, true) end
 for tab, page in pairs(pages) do
  local panel = page.Panel
  bind(panel.Button.Cap, function() self:close() end)
  for _, target in ipairs(Bindings.Pages) do
   bind(panel.Inner.Content.Tabs["Tab_" .. target].Cap, function() select(target, true) end)
  end
 end
 local requests = {}
 for _, item in ipairs(Bindings.Items) do
  local card = assert(Bindings.card(pages[item.tab], item), "Missing shop card: " .. item.id)
  local button = assert(Bindings.button(card), "Missing Buy button: " .. item.id)
  local data, kind, assetId
  if item.kind == "Pass" then
   data = assert(Passes.ById[item.id], "Unknown pass: " .. item.id)
   kind = Enum.InfoType.GamePass; assetId = data.assetId
  elseif item.kind == "Cash" then
   data = assert(CashPacks.ById[item.id], "Unknown cash pack: " .. item.id)
   kind = Enum.InfoType.Product; assetId = data.productId
  elseif item.kind == "Boost" then
   data = assert(Boosts.ById[item.id], "Unknown boost: " .. item.id)
   kind = Enum.InfoType.Product; assetId = data.productId
  else
   data = Robot; kind = Enum.InfoType.Product; assetId = Robot.ProductId
  end
  local row = {price=nil, loading=assetId>0, available=assetId>0, item=item, button=button}
  local tag = card:FindFirstChild("Tag")
  local tagText = tag and tag:FindFirstChildWhichIsA("TextLabel")
  local originalTag = tagText and tagText.Text
  local lastPrompt = -math.huge
  function row.refresh()
   if not alive or not button.Parent then return end
   local owned = item.kind == "Pass" and Passes.owns(self.plr, item.id)
   local text = if owned then "OWNED" elseif not row.available then "SOON" elseif row.price then "R$ " .. tostring(row.price) elseif row.loading then "..." else "BUY"
   caption(button, text)
   button.Active = not owned and row.available
   if item.kind == "Boost" and tagText then
    local seconds = Boosts.secondsLeft(self.plr, item.id)
    local text = if seconds > 0 then Boosts.clock(seconds) .. " LEFT" else originalTag
    if tagText.Text ~= text then tagText.Text = text end
   end
  end
  bind(button, function()
   if not row.available or assetId<=0 then return end
   if item.kind == "Pass" and Passes.owns(self.plr, item.id) then row.refresh(); return end
   if os.clock() - lastPrompt < 1 then return end
   lastPrompt = os.clock()
   local ok, err = pcall(function()
    if item.kind == "Pass" then Marketplace:PromptGamePassPurchase(self.plr, assetId)
    else Marketplace:PromptProductPurchase(self.plr, assetId) end
   end)
   if not ok then
    warn("[AuthoredShop] Purchase prompt failed for " .. item.id .. ": " .. tostring(err))
    self:Toast("Could not open the purchase. Please try again.", false)
   end
  end)
  row.refresh()
  table.insert(rows, row)
  if assetId>0 then table.insert(requests, {row=row, id=assetId, kind=kind}) end
 end
 local started = false
 local function loadPrices()
  if started then return end
  started = true
  local nextRequest = 0
  for _=1,3 do
   task.spawn(function()
    while alive do
     nextRequest += 1
     local request = requests[nextRequest]
     if not request then return end
     local ok, info = pcall(function() return Marketplace:GetProductInfo(request.id, request.kind) end)
     if not alive then return end
     local row = request.row
     row.loading = false
     if ok and type(info) == "table" then
      row.price = tonumber(info.PriceInRobux)
      if info.IsForSale == false then row.available = false end
     else
      warn("[AuthoredShop] Price unavailable for " .. row.item.id .. "; Roblox checkout will show the price.")
     end
     row.refresh()
    end
   end)
  end
 end
 self.shopRows = {refresh}
 self:_register("Shop", holder, size)
 Console.watchPanel(holder)
 Console.registerClose(holder, function() self:close() end)
 connect(holder:GetPropertyChangedSignal("Visible"), function()
  if holder.Visible then refresh(); loadPrices() end
 end)
 connect(holder.Destroying, function()
  alive = false
  for _, connection in ipairs(connections) do connection:Disconnect() end
 end)
 select(if pages[self.shopTab] then self.shopTab else "Passes", false)
 return holder
end
return Shop
