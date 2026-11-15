local Products = require(game.ReplicatedStorage:WaitForChild("WorldProducts"))
local store = game:GetService("DataStoreService"):GetDataStore("AsphaltColorEntitlements_v1")
local Receipts = {}
function Receipts.colorOf(productId)
	if Products.FujiMist > 0 and productId == Products.FujiMist then return "fuji" end
	if Products.Torii > 0 and productId == Products.Torii then return "torii" end
	return nil
end
function Receipts.process(info)
	if game:GetService("RunService"):IsStudio() then return Enum.ProductPurchaseDecision.NotProcessedYet end
	local id = Receipts.colorOf(info.ProductId)
	if not id then return Enum.ProductPurchaseDecision.NotProcessedYet end
	local ok, result = pcall(function()
		return store:UpdateAsync("u_" .. info.PlayerId, function(previous)
			local data = if type(previous) == "table" then table.clone(previous) else {}
			data[id] = true
			return data
		end)
	end)
	if not ok or type(result) ~= "table" or result[id] ~= true then
		warn("[World2Receipts] Entitlement save failed: " .. tostring(result))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end
return Receipts
