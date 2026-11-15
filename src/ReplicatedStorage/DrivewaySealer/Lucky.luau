--!strict
--[[
	Lucky -- premium contracts, part of what VIP buys.

	Some jobs come in worth several times the money. Which ones is decided HERE
	and nowhere else, and the whole design is that it is decided by ARITHMETIC
	rather than by a roll somebody has to remember:

		the answer is a pure function of (player, slab, lap)

	That one property buys everything awkward about this feature for free.

	  * The client can put a gold board on the lawn BEFORE the job is done,
	    because it can work out the same answer the server will pay against. No
	    remote, no "what is this one worth" round trip.
	  * There is no per-player, per-slab state to store, replicate, or migrate --
	    and no way for a disconnect to lose somebody's premium job.
	  * It cannot be re-rolled. Walking away from a premium contract and coming
	    back finds the same contract; walking away from an ordinary one does not
	    turn it premium. A roll the player could spin is not a reward, it is a
	    chore.
	  * The server never has to trust the client about any of it. Both sides
	    compute it; only the server's answer is paid.

	The LAP is in the seed on purpose: a rebirth hands the whole map back, and it
	deals a fresh hand of premium jobs with it. Same driveways, different money,
	which is exactly what a new lap should feel like.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Passes = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Passes"))
local Rebirth = require(ReplicatedStorage:WaitForChild("SealerUI"):WaitForChild("Rebirth"))

local Lucky = {}

Lucky.Chance = 0.18

local TIERS = {
	{ mult = 3, weight = 60, label = "PREMIUM" },
	{ mult = 4, weight = 30, label = "RUSH JOB" },
	{ mult = 5, weight = 10, label = "CONTRACT" },
}

local function hash32(s: string): number
	local h = 2166136261
	for i = 1, #s do
		h = bit32.band(h * 31 + string.byte(s, i), 0xFFFFFFFF)
	end
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = bit32.band(h * 31, 0xFFFFFFFF)
	return bit32.bxor(h, bit32.rshift(h, 13))
end

local function keyOf(slab: Instance): string
	return (slab:GetFullName():gsub("^Workspace%.", ""))
end

function Lucky.contractOf(plr: Player?, slab: Instance?): (number, string?)
	if not plr or not slab then return 1, nil end
	if not Passes.owns(plr, "VIP") then return 1, nil end
	if slab:GetAttribute("DuelSlab") ~= nil then return 1, nil end

	local lap = Rebirth.countOf(plr)
	local h = hash32(("%d|%s|%d"):format(plr.UserId, keyOf(slab), lap))
	if (h % 1000) / 1000 >= Lucky.Chance then return 1, nil end

	local total = 0
	for _, t in ipairs(TIERS) do total += t.weight end
	local roll = bit32.rshift(h, 10) % total
	for _, t in ipairs(TIERS) do
		if roll < t.weight then return t.mult, t.label end
		roll -= t.weight
	end
	return TIERS[1].mult, TIERS[1].label
end

function Lucky.multiplierFor(plr: Player?, slab: Instance?): number
	local mult = Lucky.contractOf(plr, slab)
	return mult
end

return Lucky
