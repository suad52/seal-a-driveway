--!strict
--[[
	PassService -- the only place the game asks Roblox about game passes.

	It answers once per player per join, writes the answer onto the Player as an
	attribute, and gets out of the way. Everything downstream reads the attribute
	through SealerUI.Passes; see the note there for why.

	Nothing here is saved. A pass is Roblox's record, not ours, and re-asking on
	each join is both cheaper and more correct than carrying a copy in the profile
	that could outlive a refund.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))

--[[
	The web call, with the retry it needs.

	UserOwnsGamePassAsync throws on a bad day, and a failure is emphatically not
	an answer: writing false because the call errored takes a pass away from
	somebody who paid for it, and they have no way to get it back short of
	rejoining. So a failed attempt leaves the attribute exactly as it is and comes
	round again, and the player is treated as not owning it in the meantime --
	which costs them a few seconds of holding a nozzle rather than their purchase.
]]
local ATTEMPTS = 3
local RETRY_WAIT = 4

local function query(plr: Player, pass: Passes.Pass)
	for attempt = 1, ATTEMPTS do
		if not plr.Parent then return end
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(plr.UserId, pass.assetId)
		end)
		if ok then
			plr:SetAttribute(Passes.attrName(pass.id), owns == true)
			return
		end
		warn(("[PassService] Could not read %s for %s (attempt %d): %s")
			:format(pass.id, plr.Name, attempt, tostring(owns)))
		task.wait(RETRY_WAIT)
	end
end

local function refresh(plr: Player)
	for _, pass in ipairs(Passes.List) do
		local attr = Passes.attrName(pass.id)
		--[[
			Set before the call, not after.

			The attribute has to exist and read false from the first frame the player
			is in the world, because the alternative is a window where a check answers
			nil -- and code that branches on nil once tends to grow a second branch
			that treats it as "unknown" and does something clever. There is nothing
			clever to do: you either have the pass or you are holding the nozzle.
		]]
		if plr:GetAttribute(attr) == nil then plr:SetAttribute(attr, false) end

		-- A pass with no asset id behind it is one nobody can own, and asking
		-- Roblox about id 0 is an error rather than a "no".
		if pass.assetId ~= 0 then
			task.spawn(query, plr, pass)
		end
	end
end

Players.PlayerAdded:Connect(refresh)
for _, plr in ipairs(Players:GetPlayers()) do refresh(plr) end

--[[
	And the moment one is bought, without waiting for a rejoin.

	The `wasPurchased` flag is trusted for the grant but the attribute is still
	written from it directly rather than re-queried: this signal only fires on a
	completed purchase Roblox has already taken the Robux for, and a re-query here
	regularly comes back stale within the same second.
]]
MarketplaceService.PromptGamePassPurchaseFinished:Connect(
	function(plr: Player, assetId: number, wasPurchased: boolean)
		if not wasPurchased then return end
		for _, pass in ipairs(Passes.List) do
			if pass.assetId ~= 0 and pass.assetId == assetId then
				plr:SetAttribute(Passes.attrName(pass.id), true)
			end
		end
	end)
