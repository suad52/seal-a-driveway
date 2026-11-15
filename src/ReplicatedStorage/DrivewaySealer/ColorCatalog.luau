local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Blueberry Cheesecake is not an event reward and not a standalone sale: it
-- comes with the Blueberry Bundle pass and nothing else, so ownership reads
-- the pass attribute the same way every other pass-granted thing does.
local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))
local Catalog = {}
-- The bonus collection reward is recovered from its persistent collection.

Catalog.Icon = "rbxassetid://98653846210668"
Catalog.OwnedAttr = "AsphaltColorsOwned"
Catalog.EquippedAttr = "AsphaltColorEquipped"
Catalog.ReadyAttr = "AsphaltColorsReady"
Catalog.List = {
    {id = "bonusyard", name = "Raccoon Rescue", event = true},
 	{id="pink", name="Baby Pink", cash=100_000},
 	{id="mint", name="Mint Candy", cash=500_000},
	{id="ice", name="Ice Blue", cash=1_200_000},
	{id="gold", name="Champagne Gold", product=3712270200, robux=29},
	{id="rainbow", name="Pastel Rainbow", product=3712270250, robux=49},
	{id="pearl", name="Lavender Pearl", product=3713273169, robux=69},
	{id="vivid", name="Vivid Rainbow", product=3713273205, robux=99},
}
table.insert(Catalog.List,{id="witchbrew",name="Witch's Brew",event=true})
table.insert(Catalog.List,{id="pumpkinrescue",name="Pumpkin Rescue",event=true})
table.insert(Catalog.List,{id="nightmares",name="Nightmares",event=true})
table.insert(Catalog.List,{id="blueberry",name="Blueberry Cheesecake",event=true})
Catalog.ById = {}
Catalog.ByProduct = {}
for _, item in ipairs(Catalog.List) do
 Catalog.ById[item.id] = item
 if item.product then Catalog.ByProduct[item.product] = item end
end
function Catalog.decode(raw)
 local owned = {}
 if type(raw) == "string" then
  for id in string.gmatch(raw, "[^,]+") do
   if Catalog.ById[id] then owned[id] = true end
  end
 end
 return owned
end
function Catalog.encode(owned)
 local ids = {}
 for _, item in ipairs(Catalog.List) do
  if owned[item.id] then table.insert(ids, item.id) end
 end
 return table.concat(ids, ",")
end
-- HALLOWEEN_CROSSWORLD_COLOR_OWNERSHIP
local function halloweenOwned(player,id)
 if not player then return false end
 if player:GetAttribute("HalloweenOwned_"..id)==true then return true end
 local raw=player:GetAttribute("HalloweenShopState")
 if type(raw)=="string" then
  local ok,data=pcall(game:GetService("HttpService").JSONDecode,game:GetService("HttpService"),raw)
  if ok and type(data)=="table" and type(data.owned)=="table" then return data.owned[id]==true end
 end
 return false
end
function Catalog.owns(player, id)
	return (id == "bonusyard" and player:GetAttribute("BonusCollectionReward") == true) or id == "classic" or (id=="witchbrew" and player:GetAttribute("GraveyardClaim2")==1) or (id=="pumpkinrescue" and halloweenOwned(player,"PumpkinRescue")) or (id=="nightmares" and halloweenOwned(player,"Nightmares")) or (id=="blueberry" and Passes.owns(player,"BlueberryBundle")) or Catalog.decode(player:GetAttribute(Catalog.OwnedAttr))[id] == true
end
require(game.ReplicatedStorage.HalloweenSharedCosmetics).catalog(Catalog)

return Catalog
