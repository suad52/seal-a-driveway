--!strict
--[[
	Economy -- what a job is worth, in one place.

	Required by ScoreModel (which draws the running figure on the HUD) and by
	DrivewayServer (which pays it), so the number the player watches climb is
	always the number that lands in their wallet.

	WHAT THIS REPLACED, AND WHY IT HAD TO GO

	The payout used to be `BaseValue + 100 * ValuePerPercent + CompletionBonus`,
	which is a hand-written BaseValue plus a flat 5,500 that was identical for
	every job in the game. The flat term dominated, so effort barely registered:

	    104 Maple front walk     282 sq studs -> 5,584   (19.80 per sq stud)
	    110 Maple driveway     2,196 sq studs -> 5,804   ( 2.64 per sq stud)
	    Ashcombe carriage dr. 26,313 sq studs -> 6,680   ( 0.25 per sq stud)

	A walkway paid seventy-nine times better per unit of work than the biggest
	drive on the map. The Estate District -- the content a player unlocks second
	-- was therefore the worst place in the game to work, and the optimal strategy
	was to farm five front walks forever. That is a progression system pointing
	backwards.

	Here a job is priced by the ground it covers, plus a small call-out fee so
	the little ones stay worth stopping for, times a multiplier that belongs to
	the district. Bigger jobs pay more because they ARE more; the estates pay
	better per stud on top of that, which is what makes unlocking them a reward
	rather than a trap.
]]

local Economy = {}

--==[ THE PRICE OF WORK ]=====================================================

Economy.RatePerStud = 2.35
Economy.CallOut = 120
Economy.Attribute = "PayMultiplier"
Economy.DefaultMultiplier = 1.0

--==[ TIPS ]==================================================================

Economy.TipPerfect    = 0.015
Economy.TipSmooth     = 0.022
Economy.TipNoMissed   = 0.035
Economy.TipCompletion = 0.10   -- share of the whole job, paid once at the end
Economy.TipCap        = 0.60

--==[ MEASURING A JOB ]=======================================================

function Economy.areaOf(slab: BasePart): number
	local override = slab:GetAttribute("JobArea")
	if type(override) == "number" and override > 0 then return override end
	return slab.Size.X * slab.Size.Z
end

function Economy.multiplierOf(slab: Instance): number
	local node: Instance? = slab
	while node do
		local m = node:GetAttribute(Economy.Attribute)
		if type(m) == "number" and m > 0 then return m end
		node = node.Parent
	end
	return Economy.DefaultMultiplier
end

function Economy.scaleOf(slab: Instance): number
	local s = slab:GetAttribute("PayScale")
	return (type(s) == "number" and s > 0) and s or 1
end

-- Cash per square stud on THIS slab. Tips are measured against it, so a tip is
-- worth what the ground under it is worth.
function Economy.studRate(slab: BasePart): number
	return Economy.RatePerStud * Economy.scaleOf(slab) * Economy.multiplierOf(slab)
end

-- What the job pays at full coverage, before tips and before the rebirth bonus.
function Economy.jobBase(slab: BasePart): number
	return (Economy.CallOut + Economy.RatePerStud * Economy.areaOf(slab))
		* Economy.scaleOf(slab) * Economy.multiplierOf(slab)
end

function Economy.payout(slab: BasePart, coverage: number, tips: number, mult: number): number
	local base = Economy.jobBase(slab) * math.clamp(coverage, 0, 1)
	local capped = math.clamp(tips, 0, Economy.jobBase(slab) * Economy.TipCap)
	return math.floor((base + capped) * mult)
end

return Economy
