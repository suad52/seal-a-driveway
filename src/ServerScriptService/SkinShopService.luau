--!strict
--[[
	SkinShopService -- selling squeegee skins, for cash or for Robux.

	SqueegeeSkinService WEARS them; this file SELLS them. They were one file until
	Robux came in, and the split is what that forced: a Robux purchase has to be
	answered from inside UpgradeService's ProcessReceipt, which means the seller
	has to be a ModuleScript something can require -- and SqueegeeSkinService is a
	Script that auto-runs.

	⚠ ProcessReceipt IS A SINGLE ASSIGNABLE FIELD FOR THE WHOLE GAME. A second
	script setting its own does not add a handler, it silently REPLACES
	UpgradeService's, and every Robux purchase in the game stops being granted.
	So nothing here touches it: UpgradeService calls `grantFromReceipt` from
	inside its own callback, the same arrangement the boosts and the doubling use.

	THE ORDER IS THE ANTI-DOUBLE-SPEND on the cash path: the wallet is charged
	BEFORE the skin is granted, with no yield between the two, so a second request
	arriving while the first is in flight finds a wallet that has already paid.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pack = ReplicatedStorage:WaitForChild("DrivewaySealer")
local SqueegeeSkins = require(Pack:WaitForChild("SqueegeeSkins"))
local Passes = require(ReplicatedStorage.SealerUI:WaitForChild("Passes"))

--[[
	The cash till's refusal is sent down the shared BuyResult remote so a skin the
	player cannot afford arrives in the same toast the counter uses -- and now also
	opens the shop's CASH tab (see SealerUIClient). Created the same idempotent way
	UpgradeService and TruckServer create it, because which script runs first is
	not guaranteed.
]]
local uiRemotes = ReplicatedStorage.SealerUI:FindFirstChild("Remotes")
if not uiRemotes then
	uiRemotes = Instance.new("Folder")
	uiRemotes.Name = "Remotes"
	uiRemotes.Parent = ReplicatedStorage.SealerUI
end
local BuyResult = uiRemotes:FindFirstChild("BuyResult") :: RemoteEvent?
if not BuyResult then
	local r = Instance.new("RemoteEvent")
	r.Name = "BuyResult"
	r.Parent = uiRemotes
	BuyResult = r
end

--[[
	⚠ THE PASS PRICE IS THE CLIENT'S JOB, NOT THIS FILE'S.

	It was fetched here first and that was wrong twice over. `setPassPrice` writes
	into a MODULE TABLE, and a module table does not replicate -- the card is drawn
	on the client, whose own copy of SqueegeeSkins would still read zero, so the VIP
	card advertised "R$ 0". And the server never needs the number anyway: the Robux
	handler below prompts by ASSET id and Roblox charges whatever the pass costs.

	SkinCase asks Roblox itself. See the note there.
]]

local Service = {}

local Remotes = SqueegeeSkins.remotes()
local BuyReq = Remotes:WaitForChild("SkinBuy") :: RemoteEvent
local RobuxReq = Remotes:WaitForChild("SkinBuyRobux") :: RemoteEvent

--==[ the profile hooks ]=====================================================

-- UpgradeService hands its own save in at startup, so a purchase is on disk
-- before the player can close the game on it.
local saveNow: ((Player) -> ())? = nil
function Service.provideSave(fn: (Player) -> ())
	saveNow = fn
end

local function pushSave(plr: Player)
	local fn = saveNow
	if not fn then return end
	task.spawn(function()
		local ok, err = pcall(fn, plr)
		if not ok then warn("[SkinShop] save failed for " .. plr.Name .. ": " .. tostring(err)) end
	end)
end

--[[
	NO PENDING NOTE, and that is the whole benefit of one product per skin.

	This file used to write the intended skin down before opening the dialog and
	read it back when the receipt landed, because five products could not say which
	of twenty skins was wanted -- which meant persisting it through a rejoin, and
	checking it against the product on arrival so that noting a Legendary and
	buying the Common product could not hand over a 99 R$ skin for 29.

	Nineteen products name their own skin. There is nothing to note, nothing to
	persist, and nothing to spoof.
]]

--==[ granting ]==============================================================

local function cashOf(plr: Player): IntValue?
	local ls = plr:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash")
	return (cash and cash:IsA("IntValue")) and cash or nil
end

--[[
	Hand it over and put it on.

	A bought skin is WORN immediately: buying something and then having to go and
	equip it is the moment a reward stops feeling like one.
]]
local function grant(plr: Player, id: string)
	local set = SqueegeeSkins.ownedSet(plr)
	set[id] = true
	plr:SetAttribute(SqueegeeSkins.OwnedAttr, SqueegeeSkins.serialise(set))
	plr:SetAttribute(SqueegeeSkins.Attr, id)
end

--==[ paying with cash ]======================================================

local lastBuy: { [Player]: number } = {}

BuyReq.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local now = os.clock()
	if now - (lastBuy[plr] or 0) < 0.4 then return end
	lastBuy[plr] = now

	if not SqueegeeSkins.ById[id] then return end
	-- already owned is a no-op, never a second charge
	if SqueegeeSkins.owns(plr, id) then return end

	local price = SqueegeeSkins.priceOf(id)
	if price <= 0 then return end
	local cash = cashOf(plr)
	if not cash or cash.Value < price then
		-- Was a SILENT refusal before -- the player clicked and nothing happened,
		-- which reads as the button being broken. Now it answers through the shared
		-- BuyResult remote with the same reason code the upgrade till uses, so the
		-- toast shows AND the shop opens on the CASH tab (see SealerUIClient).
		if BuyResult then
			(BuyResult :: RemoteEvent):FireClient(plr, id, false,
				"Not enough cash", "InsufficientCash")
		end
		return
	end

	-- charge, then grant, with nothing in between; see the header
	cash.Value -= price
	grant(plr, id)
	pushSave(plr)
end)

--==[ paying with Robux ]=====================================================

local lastPrompt: { [Player]: number } = {}

RobuxReq.OnServerEvent:Connect(function(plr, id)
	if type(id) ~= "string" then return end
	local now = os.clock()
	if now - (lastPrompt[plr] or 0) < 1 then return end
	lastPrompt[plr] = now

	local skin = SqueegeeSkins.ById[id]
	if not skin then return end
	if SqueegeeSkins.owns(plr, id) then return end

	--[[
		A PASS KIT PROMPTS THE GAME PASS, not a developer product.

		There is no receipt to answer either: a pass is owned the moment Roblox says
		it is, PassService mirrors that onto `Pass_VIP`, and the case is watching
		that attribute. Nothing here grants anything.
	]]
	local passId = SqueegeeSkins.passOf(id)
	if passId then
		local pass = Passes.ById[passId]
		local asset = pass and pass.assetId or 0
		if asset == 0 then
			RobuxReq:FireClient(plr, "That one is not on sale yet")
			return
		end
		local okPass, errPass = pcall(function()
			MarketplaceService:PromptGamePassPurchase(plr, asset)
		end)
		if not okPass then
			warn("[SkinShop] PromptGamePassPurchase failed: " .. tostring(errPass))
		end
		return
	end

	local product = SqueegeeSkins.productFor(id)
	if product == 0 then
		--[[
			Refused rather than prompted, and it SAYS SO.

			A dialog for a product that does not exist reaches the player as "the
			buy button is broken", which is worse than a button that explains
			itself. The same rule the spin pack had before it was removed.
		]]
		RobuxReq:FireClient(plr, "That one is not on sale yet")
		warn(("[SkinShop] no developer product for %s -- create one and paste its id"
			.. " into SqueegeeSkins.ProductIds"):format(id))
		return
	end

	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(plr, product)
	end)
	if not ok then
		warn("[SkinShop] PromptProductPurchase failed: " .. tostring(err))
	end
end)

--[[
	Spend the receipt. Called from UpgradeService's ProcessReceipt and NOWHERE
	else -- see the warning in the header.

	Answers whether it landed, and FALSE is the important answer: it means this
	receipt cannot be made whole right now, so the caller holds it and Roblox
	asks again rather than the player paying for nothing.
]]
function Service.grantFromReceipt(plr: Player, productId: number): boolean
	-- The product IS the answer: no note to read, and nothing a client said.
	local id = SqueegeeSkins.skinOfProduct(productId)
	if not id then return false end

	if SqueegeeSkins.owns(plr, id) then
		-- bought it with cash while the dialog was open. The receipt is consumed
		-- anyway: holding it forever is the worse of the two answers, and Roblox
		-- would re-ask on every join for something they already have.
		warn(("[SkinShop] %s already owned %s when its receipt landed")
			:format(plr.Name, id))
		return true
	end
	grant(plr, id)
	return true
end

Players.PlayerRemoving:Connect(function(plr)
	lastBuy[plr] = nil
	lastPrompt[plr] = nil
end)

-- The gap is printed rather than assumed away: a skin added without a product is
-- one nobody can buy with Robux, and this is where that gets noticed.
local missing = SqueegeeSkins.missingProducts()
-- Counted, not derived. The starter has no product and neither does a pass kit,
-- so arithmetic off the list length was one out the moment VIP was added.
local linked, gated = 0, 0
for _, sk in ipairs(SqueegeeSkins.List) do
	if sk.pass then
		gated += 1
	elseif SqueegeeSkins.productFor(sk.id) ~= 0 then
		linked += 1
	end
end
print(("[SkinShop] ready -- %d skins, cash %d..%d, Robux %d..%d,"
	.. " %d products (%s), %d pass-gated")
	:format(#SqueegeeSkins.List,
		SqueegeeSkins.Prices.Common, SqueegeeSkins.Prices.Legendary,
		SqueegeeSkins.RobuxPrices.Common, SqueegeeSkins.RobuxPrices.Legendary,
		linked,
		if #missing == 0 then "all linked"
		else "MISSING: " .. table.concat(missing, ", "),
		gated))

return Service
