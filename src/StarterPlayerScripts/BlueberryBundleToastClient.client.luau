--!strict
--[[
	BlueberryBundleToastClient -- the toast the Blueberry Bundle purchase was
	missing.

	Buying the bundle grants the Blueberry Howl pet, but unlike the Zone Progress
	milestone there was no message at all: PassService flips the attribute and the
	card in the Skins Menu quietly unlocks. This listens for the client-side end
	of Roblox's own purchase dialog and says what was just added and where to find
	it -- the same hint the milestone claim gives, on the shell's own toast lane.

	Client-side on purpose: PromptGamePassPurchaseFinished also fires here, and the
	toast is for the one player who bought. PassService keeps the attribute as the
	source of truth; nothing here writes anything.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))
local Shell = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Shell"))

local plr = Players.LocalPlayer
local BUNDLE = Passes.ById.BlueberryBundle

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_player, assetId, wasPurchased)
	if not wasPurchased then return end
	if assetId ~= BUNDLE.assetId then return end
	Shell.toast("Blueberry Howl pet added to your pet case! Your new pet is available through the Skins Menu.", true)
end)