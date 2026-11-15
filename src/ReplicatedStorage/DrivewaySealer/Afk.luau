--!strict
--[[
	Afk -- the yard you leave a man working in, and what it pays.

	Shared by AfkService, which owns the wallet and the plots, and by AfkClient,
	which puppets the character and draws the readout. Both read the rate from
	here for the same reason Rebirth and Upgrades are shared modules: the figure
	on screen and the figure in the wallet cannot be allowed to disagree.

	WHY THIS IS NOT THE DRIVEWAY PAYOUT

	Every sealable slab in the game pays exactly once per rebirth -- that is
	DrivewayServer's purse-per-lap rule, and the whole progression is priced
	against it. An AFK driveway on that path would pay once, about forty seconds
	in, and then be worth nothing forever. So the yard has its own income: a rate
	per second, paid by the server on a timer, with no connection to the grid the
	client is drawing.

	That split is load-bearing in the other direction too. The sealing the puppet
	does is a PICTURE of work rather than the work itself, so a client that stalls,
	drops a frame, or fails to build its surface at all still earns -- and a client
	that lies about its coverage earns exactly the same as one that does not.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SealerUI = ReplicatedStorage:WaitForChild("SealerUI")
local Rebirth = require(SealerUI:WaitForChild("Rebirth"))
local Passes = require(SealerUI:WaitForChild("Passes"))
local FriendBonus = require(SealerUI:WaitForChild("FriendBonus"))

local Afk = {}

--==[ WHERE IT IS ]===========================================================

Afk.Origin = Vector3.new(6000, 0, 0)
Afk.Container = "AfkYard"

Afk.PlotCount = 8

Afk.SlabSize = Vector3.new(61, 0.5, 34)
Afk.SlabY = -0.17                          -- centre height; top face lands at 0.08
Afk.HouseOffset = Vector3.new(-47.53, 0, -12)   -- house bbox centre, from slab centre
Afk.HouseY = 14.652937889099121                 -- its bbox centre height, base sitting on 0
Afk.HouseSource = "House_106"                   -- cloned out of Neighbourhood.Lots

-- Plot pitch down the street. The neighbourhood's own lots sit about 88 apart
-- and a house plus its drive is 66 deep, so this is that spacing with the same
-- 22 studs of hedge between.
Afk.PlotPitch = 88

-- Where the street runs. The slab's east edge stops one stud short of the kerb,
-- exactly as it does on Maple Drive.
Afk.KerbX = -16
Afk.RoadHalf = 15

-- Attribute the server stamps on a player while they are in the yard: the plot
-- index, or nil. Everything else -- the puppet, the readout, the controls being
-- taken away -- hangs off this one value changing, so there is a single switch.
Afk.Attr = "AfkPlot"
-- Running total for this visit, for the readout. Server-written, like the rate.
Afk.EarnedAttr = "AfkEarned"

function Afk.plotName(i: number): string
	return ("Plot_%d"):format(i)
end

-- Centre of plot i's slab, in world space.
function Afk.slabCentre(i: number): Vector3
	return Afk.Origin + Vector3.new(-45.5, Afk.SlabY, (i - 1) * Afk.PlotPitch)
end

function Afk.standCFrame(i: number): CFrame
	local c = Afk.slabCentre(i)
	local at = Vector3.new(c.X + Afk.SlabSize.X * 0.5 - 3, 3.5, c.Z)
	return CFrame.lookAt(at, at - Vector3.xAxis)
end

--==[ HOW FAST IT WORKS ]====================================================

Afk.WalkSpeed = 12

--==[ WHAT IT PAYS ]==========================================================

Afk.BaseRate = 5

-- How often the money actually lands. A second is frequent enough that the
-- counter on screen visibly moves, which is the entire feedback this area has.
Afk.TickSeconds = 1

function Afk.rateFor(plr: Player?): number
	return Afk.BaseRate * Rebirth.multiplierOf(plr) * Passes.cashMultiplier(plr)
		* FriendBonus.multiplierOf(plr)
end

-- The figure the readout actually says, because nobody thinks in cash-seconds.
function Afk.perMinuteFor(plr: Player?): number
	return Afk.rateFor(plr) * 60
end

function Afk.plotOf(plr: Player?): number?
	if not plr then return nil end
	local n = (plr :: Player):GetAttribute(Afk.Attr)
	if type(n) ~= "number" then return nil end
	local i = math.floor(n)
	return if i >= 1 and i <= Afk.PlotCount then i else nil
end

return Afk
