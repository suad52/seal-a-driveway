local Players = game:GetService("Players")
local Currency = {}
local save, ready
local dirty = {}
function Currency.configure(saveFunction, readyFunction)
 save, ready = saveFunction, readyFunction
end
function Currency.ready(player)
 return ready ~= nil and ready(player) and player:GetAttribute("ProfileLoaded") == true
end
function Currency.award(player, amount)
 if not Currency.ready(player) then return false end
 local value = player:GetAttribute("PumpkinCoins") or 0
 player:SetAttribute("PumpkinCoins", value + amount)
 dirty[player] = (dirty[player] or 0) + 1
 return true
end
task.spawn(function()
 while true do
  task.wait(30)
  for player, revision in pairs(dirty) do
   if player.Parent == Players and Currency.ready(player) then
    local ok, result = pcall(save, player)
    if ok and result and dirty[player] == revision then dirty[player] = nil end
   elseif player.Parent ~= Players then dirty[player] = nil end
  end
 end
end)
-- Departure, teleport and shutdown use the existing UpgradeService save path.
return Currency
