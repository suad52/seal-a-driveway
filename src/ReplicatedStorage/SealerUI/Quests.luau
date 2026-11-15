--!strict
--[[
	Quests -- the reward board, and the rules behind it.

	Five tracks, each a ladder of tiers. A tier is met when the track's own
	counter reaches its target; claiming pays the cash and moves you onto the
	next rung. Nothing here is timed and nothing expires -- these are long-running
	goals that run alongside the job, not a daily chore list.

	Shared by the server, which owns the counters and the wallet, and by the
	client, which draws the board. Both read the same ladder from here, so the
	panel can never offer a reward the server will refuse -- the same rule
	Upgrades and Rebirth already follow.

	Progress is a function per track rather than a counter per track, and that is
	deliberate: two of the five are already recorded elsewhere -- how many rigs
	you own IS the rig unlock attributes, and how many times you have started over
	IS the rebirth count -- and keeping a second copy of a number the game already
	knows is how the two end up disagreeing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rigs = require(ReplicatedStorage:WaitForChild("DrivewaySealer"):WaitForChild("Rigs"))
local Rebirth = require(script.Parent:WaitForChild("Rebirth"))

local Quests = {}

--[[
	The counters the server keeps, as Player attributes.

	Attributes rather than a server-side table: they replicate on their own, so
	the board redraws the moment a driveway pays without a remote to carry the
	news. UpgradeService persists them with the rest of the profile.
]]
Quests.Counters = { "Q_Sealed", "Q_Earned", "Q_Upgrades" }

-- How far up a ladder the player has already claimed. One attribute per track.
function Quests.claimedAttr(id: string): string
	return "QT_" .. id
end

export type Track = {
	id: string,
	name: string,
	glyph: string,
	tint: Color3,
	-- "Seal 30 driveways" is built from these two plus the tier's target
	verb: string,
	unit: string,
	money: boolean?,       -- format the target as cash rather than a count
	tiers: { number },
	rewards: { number },
	progress: (Player) -> number,
}

local function attr(plr: Player, name: string): number
	local v = plr:GetAttribute(name)
	return if type(v) == "number" then v else 0
end

Quests.Tracks = {
	{
		id = "Sealer",
		name = "On The Tools",
		glyph = "\u{1F6E3}\u{FE0F}",
		tint = Color3.fromRGB(96, 190, 248),
		verb = "Seal", unit = "driveways",
		tiers   = { 3, 10, 30, 75, 150, 300 },
		rewards = { 1500, 6000, 20000, 60000, 150000, 400000 },
		progress = function(plr) return attr(plr, "Q_Sealed") end,
	},
	{
		id = "Earner",
		name = "Turnover",
		glyph = "\u{1F4B5}",
		tint = Color3.fromRGB(126, 232, 138),
		verb = "Earn", unit = "in total", money = true,
		tiers   = { 25000, 100000, 400000, 1500000, 5000000 },
		rewards = { 3000, 12000, 45000, 160000, 500000 },
		progress = function(plr) return attr(plr, "Q_Earned") end,
	},
	{
		id = "Workshop",
		name = "Kitted Out",
		glyph = "\u{1F527}",
		tint = Color3.fromRGB(250, 196, 92),
		verb = "Buy", unit = "upgrades",
		tiers   = { 3, 8, 15, 25, 40 },
		rewards = { 2000, 8000, 25000, 70000, 200000 },
		progress = function(plr) return attr(plr, "Q_Upgrades") end,
	},
	{
		id = "Fleet",
		name = "Run A Fleet",
		glyph = "\u{1F69B}",
		tint = Color3.fromRGB(140, 210, 120),
		verb = "Own", unit = "rigs",
		tiers   = { 1, 2, 3 },
		rewards = { 15000, 40000, 90000 },
		progress = function(plr)
			local n = 0
			for _, r in ipairs(Rigs.List) do
				if Rigs.owns(plr, r.id) then n += 1 end
			end
			return n
		end,
	},
	{
		id = "Franchise",
		name = "Start Again",
		glyph = "\u{1F501}",
		tint = Color3.fromRGB(52, 226, 214),
		verb = "Rebirth", unit = "times",
		tiers   = { 1, 3, 5, 10 },
		rewards = { 50000, 200000, 500000, 1500000 },
		progress = function(plr) return Rebirth.countOf(plr) end,
	},
} :: { Track }

Quests.ById = {} :: { [string]: Track }
for _, t in ipairs(Quests.Tracks) do
	Quests.ById[t.id] = t
end

--==[ where a player is on one ladder ]=======================================

export type Status = {
	tier: number,        -- 1-based rung being worked on
	target: number?,     -- nil once every tier is claimed
	reward: number?,
	have: number,
	fraction: number,
	ready: boolean,      -- target met, not yet claimed
	finished: boolean,   -- nothing left on this track
}

function Quests.statusOf(plr: Player, track: Track): Status
	local claimed = math.clamp(attr(plr, Quests.claimedAttr(track.id)), 0, #track.tiers)
	local tier = claimed + 1
	local have = track.progress(plr)
	local target = track.tiers[tier]
	return {
		tier = tier,
		target = target,
		reward = track.rewards[tier],
		have = have,
		fraction = if target then math.clamp(have / target, 0, 1) else 1,
		ready = target ~= nil and have >= target,
		finished = target == nil,
	}
end

-- Anything waiting to be collected? Drives the alert badge on the rail.
function Quests.claimableCount(plr: Player): number
	local n = 0
	for _, t in ipairs(Quests.Tracks) do
		if Quests.statusOf(plr, t).ready then n += 1 end
	end
	return n
end

return Quests
