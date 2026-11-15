local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Catalog = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("ColorCatalog"))
local Service = {}
local paidStore = DataStoreService:GetDataStore("AsphaltColorEntitlements_v1")
local state = {}
local saveNow, profileLoaded
local folder = Instance.new("Folder")
folder.Name = "AsphaltColorRemotes"
local request = Instance.new("RemoteEvent")
request.Name = "Request"
request.Parent = folder
local result = Instance.new("RemoteEvent")
result.Name = "Result"
result.Parent = folder
folder.Parent = ReplicatedStorage

local function getState(plr)
 if not state[plr] then state[plr] = {cash={}, paid={}, last=0, busy=false, pendingSave=false} end
 return state[plr]
end
local function sync(plr, s)
 if not plr.Parent then return end
 local owned = table.clone(s.cash)
 for id in pairs(s.paid) do owned[id] = true end
 plr:SetAttribute(Catalog.OwnedAttr, Catalog.encode(owned))
end
local function reply(plr, text, ok)
 if plr.Parent then result:FireClient(plr, text, ok == true) end
end
local function persist(plr, s)
 if RunService:IsStudio() then return true end
 local ok, saved = pcall(saveNow, plr)
 if not ok then warn("[Colors] Profile save failed: " .. tostring(saved)) end
 s.pendingSave = not (ok and saved == true)
 return not s.pendingSave
end
local function scheduleSave(plr, s)
 if s.scheduled then return end
 s.scheduled = true
 task.delay(5, function()
  s.scheduled = false
  if plr.Parent and profileLoaded(plr) then persist(plr, s) end
 end)
end
function Service.provideSave(fn, ready)
 saveNow, profileLoaded = fn, ready
end
function Service.restore(plr, data)
 local s = getState(plr)
 local owned = Catalog.decode(data[Catalog.OwnedAttr])
 for id in pairs(owned) do if Catalog.ById[id].cash then s.cash[id] = true end end
 local equipped = data[Catalog.EquippedAttr]
 s.wanted = if type(equipped) == "string" and Catalog.ById[equipped] then equipped else "classic"
 sync(plr, s)
end
function Service.capture(plr, data)
 local s = getState(plr)
 data[Catalog.OwnedAttr] = Catalog.encode(s.cash)
 data[Catalog.EquippedAttr] = plr:GetAttribute(Catalog.EquippedAttr) or s.wanted or "classic"
end
function Service.profileReady(plr)
 local s = getState(plr)
 if s.loading or s.ready then return end
 s.loading = true
 plr:SetAttribute(Catalog.ReadyAttr, false)
 task.spawn(function()
  local ok, data
  if RunService:IsStudio() then
   ok, data = true, {}
  else
   for attempt=1,3 do
    ok, data = pcall(function() return paidStore:GetAsync("u_" .. plr.UserId) end)
    if ok then break end
    if attempt < 3 then task.wait(attempt * 2) end
   end
  end
  if not plr.Parent then return end
  s.loading = false
  if not ok then
   warn("[Colors] Entitlement load failed: " .. tostring(data))
   reply(plr, "Colors could not load. Retrying shortly.", false)
   task.delay(30, function() if plr.Parent then Service.profileReady(plr) end end)
   return
  end
  if type(data) == "table" then
   for id, owned in pairs(data) do
    if owned == true and Catalog.ById[id] and Catalog.ById[id].product then s.paid[id] = true end
   end
  end
  sync(plr, s)
  s.ready = true
  local equipped = s.wanted or "classic"
  if not Catalog.owns(plr, equipped) then equipped = "classic" end
  plr:SetAttribute(Catalog.EquippedAttr, equipped)
  plr:SetAttribute(Catalog.ReadyAttr, true)
 end)
end
function Service.isProduct(id) return Catalog.ByProduct[id] ~= nil end
function Service.processReceipt(info)
 local item = Catalog.ByProduct[info.ProductId]
 local plr = Players:GetPlayerByUserId(info.PlayerId)
 if not item or not plr or not profileLoaded or not profileLoaded(plr) then
  return Enum.ProductPurchaseDecision.NotProcessedYet
 end
 local s = getState(plr)
 if not RunService:IsStudio() then
  local ok, stored = pcall(function()
   return paidStore:UpdateAsync("u_" .. info.PlayerId, function(old)
    local merged = if type(old) == "table" then table.clone(old) else {}
    merged[item.id] = true
    return merged
   end)
  end)
  if not ok or type(stored) ~= "table" or stored[item.id] ~= true then
   warn("[Colors] Receipt entitlement write failed: " .. tostring(stored))
   return Enum.ProductPurchaseDecision.NotProcessedYet
  end
 end
 s.paid[item.id] = true
 sync(plr, s)
 if plr.Parent then
  s.wanted = item.id
  plr:SetAttribute(Catalog.EquippedAttr, item.id)
  scheduleSave(plr, s)
  reply(plr, item.name .. " purchased and equipped!", true)
 end
 return Enum.ProductPurchaseDecision.PurchaseGranted
end
function Service.grantForWheel(plr, id)
 local item = Catalog.ById[id]
 if not item or not item.product or not profileLoaded or not profileLoaded(plr) then return false end
 local s = getState(plr)
 if s.paid[id] then return true end
 if not RunService:IsStudio() then
  local ok, stored = pcall(function()
   return paidStore:UpdateAsync("u_" .. plr.UserId, function(old)
    local merged = if type(old) == "table" then table.clone(old) else {}
    merged[id] = true
    return merged
   end)
  end)
  if not ok or type(stored) ~= "table" or stored[id] ~= true then return false end
 end
 s.paid[id] = true
 sync(plr, s)
 s.wanted = id
 plr:SetAttribute(Catalog.EquippedAttr, id)
 scheduleSave(plr, s)
 return true
end
request.OnServerEvent:Connect(function(plr, action, id)
 if type(action) ~= "string" or type(id) ~= "string" or #id > 24 then return end
 local s = getState(plr)
 local now = os.clock()
 if now - s.last < 0.4 or s.busy then return end
 s.last = now
 if not s.ready or not profileLoaded or not profileLoaded(plr) then
  reply(plr, "Your colors are still loading. Please try again.", false)
  return
 end
 local item = Catalog.ById[id]
 if action == "equip" then
  if not Catalog.owns(plr, id) then return end
  if plr:GetAttribute(Catalog.EquippedAttr) == id then return end
  s.wanted = id
  plr:SetAttribute(Catalog.EquippedAttr, id)
  scheduleSave(plr, s)
  reply(plr, if id == "classic" then "Color unequipped" else item.name .. " equipped", true)
 elseif action == "buy" and item then
  if item.event then reply(plr, if item.id=="blueberry" then "This color comes with the Blueberry Bundle in the Shop." else "Unlock this color in the Halloween event.",false);return end
  if Catalog.owns(plr, id) then reply(plr, "You already own this color.", false); return end
  if item.product then
   if now - (s.lastPrompt or -math.huge) < 2 then return end
   s.lastPrompt = now
   local ok, err = pcall(function() MarketplaceService:PromptProductPurchase(plr, item.product) end)
   if not ok then
    warn("[Colors] Purchase prompt failed: " .. tostring(err))
    reply(plr, "Could not open the purchase. Please try again.", false)
   end
   return
  end
  if s.pendingSave then reply(plr, "Previous purchase is still saving. Please wait.", false); return end
  local stats = plr:FindFirstChild("leaderstats")
  local cash = stats and stats:FindFirstChild("Cash")
  if not cash or not cash:IsA("IntValue") or cash.Value < item.cash then
   reply(plr, "Not enough cash", false); return
  end
  s.busy = true
  cash.Value -= item.cash
  s.cash[id] = true
  s.wanted = id
  sync(plr, s)
  plr:SetAttribute(Catalog.EquippedAttr, id)
  local saved = persist(plr, s)
  s.busy = false
  reply(plr, if saved then item.name .. " purchased and equipped!" else "Color granted. Saving is delayed; retrying automatically.", saved)
 end
end)
task.spawn(function()
 while true do
  task.wait(30)
  for plr, s in pairs(state) do
   if s.pendingSave and not s.busy and plr.Parent and profileLoaded and profileLoaded(plr) then
    task.spawn(function() s.busy = true; persist(plr, s); s.busy = false end)
   end
  end
 end
end)
Players.PlayerRemoving:Connect(function(plr)
 local s = state[plr]
 task.delay(60, function() if state[plr] == s then state[plr] = nil end end)
end)
return Service
