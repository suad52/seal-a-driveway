--!strict
--[[
	Upgrades -- the progression table from the design doc, in one place.

	Shared by the server (which owns levels and takes the money) and the client
	(which draws the shop rows and applies the effects locally). Both read the
	same `values` array, so a level can never mean two different things.

	Level 1 is the starting kit and always costs nothing; `costs[n]` is what it
	takes to reach level n.

	THE SHAPE OF THE LADDER

	Fourteen real rungs in two halves, priced on different curves on purpose.

	The early half climbs at about 1.85x a rung. A Maple driveway pays around
	5,200 now, so the first rung is most of one job and the tenth is fifty of
	them: gentle enough that something is always nearly affordable, steep enough
	that a first playthrough stalls around level 6 or 7. That stall is the wall
	the first rebirth exists to answer.

	The last four rungs climb at 2.7x AND carry `reqs`, a minimum number of
	rebirths. They are out of reach on a first playthrough by construction rather
	than merely by price, and they are what keeps something worth saving for long
	after the four tracks would otherwise have run dry. Maxing Tank, Refill, Blade
	and Speed takes four rebirths; Pour runs two rungs past that, at five and six
	-- see its own note for why it is the deep one.

	A rebirth also discounts the whole ladder (Rebirth.discountAt), so the re-climb
	is far quicker than the first climb was. That discount is what makes rebirth
	read as a lever rather than as a punishment.

	Four tracks, deliberately. Sealing Efficiency and Income Multiplier were cut:
	efficiency was indistinguishable from capacity to a player -- the simulation
	folded it straight into the same number -- and income was a multiplier on a
	payout the shop never showed. The ids that remain are Tank/Blade/Pour/Speed,
	kept as they were so saved profiles and the effect code still line up with
	the names on the cards.
]]

local Upgrades = {}

--[[
	`unlock` marks a track that is a one-time purchase rather than a ladder: two
	levels, where level 2 simply means owned. It rides the same rails as every
	other track on purpose -- the server's cash handling, the zone gate, the save
	file and the buy remote all work on it unchanged -- and only the shop row
	draws it differently, as Not owned / OWNED instead of Lv 1 -> Lv 2.

	`zone` is where it may be bought, defaulting to the depot counter. `hidden`
	keeps it out of the Upgrades panel, for things sold on their own screen.
	Together they are what let the trucks live in a dealership across the road
	while still using every piece of machinery the counter already had.
]]
export type Track = {
	id: string, name: string, blurb: string, glyph: string,
	suffix: string, tint: Color3,
	values: { number },
	costs: { number },
	-- rebirths needed before a level may be bought at all; absent means never gated
	reqs: { number }?,
	--[[
		A Passes id, for a row bought with Robux rather than with cash.

		It rides the ordinary track rails so the shop draws it in the ladder where
		players look for it, but it is NOT for sale at the counter: the shop row
		branches on this before it quotes a price, and UpgradeService refuses the buy
		remote for it outright. Ownership is Roblox's record, read through Passes.
	]]
	pass: string?,
	unlock: boolean?,
	hidden: boolean?,
	zone: string?,
}

-- The last four rungs of every track each want another rebirth. Blade has the
-- extra tutorial rung underneath, so it carries its own copy shifted by one.
local LATE   = { 0,0,0,0,0,0,0,0,0,0, 1, 2, 3, 4 }
local LATE_B = { 0,0,0,0,0,0,0,0,0,0,0, 1, 2, 3, 4 }
--[[
	Pour's copy, and the gates on 11-14 are deliberately the SAME four.

	The track grew two rungs on the top rather than in the middle, so lifting the
	existing gates to keep "the last four" literal would have handed levels 11 and
	12 to players who have never rebirthed -- two rungs quietly cheaper than they
	were yesterday. Additive only: nothing that was gated moved, and the new pair
	sits behind five and six. The rebirth ladder has no top, so both are reachable.
]]
local LATE_P = { 0,0,0,0,0,0,0,0,0,0, 1, 2, 3, 4, 5, 6 }

Upgrades.Tracks = {
	{
		id = "Tank", name = "Bucket Capacity", glyph = "\u{1F6E2}", suffix = "L",
		blurb = "Carry more sealer, so you finish more before walking back.",
		tint = Color3.fromRGB(96, 190, 248),
		--[[
			These are LITRES, and they are display only.

			The simulation's only unit is the coat-stud -- one square stud covered to
			a full coat -- and this track used to be quoted straight in it, so a hand
			pail read "500 L". That is half a tonne of sealer in a bucket, and it made
			every other figure in the game read as nonsense with it.

			Twenty-five coat-studs to the litre, which is close to the real coverage
			rate of about 20 sq ft a litre a coat, so the stock pail comes out at 20 L
			-- an actual pail of sealer -- and a 61x34 driveway takes about 83.

			Nothing downstream has to know. SealerUIClient reads this track as a RATIO
			against level 1 (`tankL / TANK_BASE_L`) and multiplies the stock
			Config.BucketCapacity by it, so rescaling the whole column by any constant
			leaves the simulation, the economy and the balance of the ladder exactly
			where they were. It also scales the rig's drum, because a track a truck
			retires is a track that stops being worth buying halfway through the game.

			If these are ever re-quoted again, change them TOGETHER -- level 1 is the
			stock pail by definition, and moving it alone silently rescales what every
			other rung actually carries.
		]]
		values = { 20, 28, 38, 52, 70, 94, 124, 164, 216, 280,
		           368, 480, 620, 800 },
		costs  = { 0, 1900, 3520, 6500, 12000, 22300, 41200, 76200, 141000, 261000,
		           705000, 1900000, 5140000, 13900000 },
		reqs = LATE,
	},
	--[[
		The stock blade is a rung lower than the rest of the ladder starts, and the
		step up off it is cheap.

		That rung exists for the tutorial. Its last instruction is to walk into the
		store and buy something, and an upgrade is only a lesson if the player can
		feel it afterwards -- a wider blade is the most legible change in the game,
		the next pass visibly covers more. The ladder started at 6.4 with no rung a
		first job could reach, so 5.2 went in underneath at 1.2K rather than
		discounting the real progression.

		That extra rung is why Blade carries LATE_B instead of LATE: every gate is
		one level further along than on the other tracks.
	]]
	--[[
		How fast the pail fills at the bulk tanks.

		The value is a rate MULTIPLIER, and what it multiplies is a fill TIME rather
		than a flow rate -- see the note where SealerUIClient applies it. That is
		what keeps this track meaningful at every rung of Bucket Capacity: a flat
		units-per-second meant the stock pail filled in four seconds and a maxed one
		took a hundred and sixty, so the reward for buying the biggest tank in the
		game was standing still for nearly three minutes at a time.

		The top of the ladder is 0.65 seconds. Deliberately not instant: the pail
		visibly fills and there is a beat to it, which is the difference between a
		fast pump and a number teleporting.
	]]
	{
		id = "Refill", name = "Refill Speed", glyph = "\u{26FD}", suffix = "x",
		blurb = "The pump at the bulk tanks moves quicker, so topping up the pail "
			.. "is a pause rather than a wait.",
		tint = Color3.fromRGB(120, 226, 214),
		values = { 1, 1.14, 1.3, 1.48, 1.68, 1.9, 2.15, 2.45, 2.78, 3.15, 3.6, 4.15, 4.9, 6.15 },
		costs  = { 0, 1300, 2400, 4450, 8230, 15200, 28100, 52000, 96300, 178000,
			480000, 1300000, 3510000, 9480000 },
	},
	{
		id = "Blade", name = "Squeegee Length", glyph = "\u{1F9F9}", suffix = " studs",
		blurb = "A wider blade lays far more coat on every single pass.",
		tint = Color3.fromRGB(140, 210, 120),
		--[[
			The starting blade is 6.4, and the first five rungs were re-spaced to get
			there (2026-08-08, owner's call). It used to be 5.2, and that was wrong for
			two reasons that both point at the same number.

			The pour is Config.PourRadius = 3.00, so a puddle lands SIX STUDS across.
			A 5.2 blade is narrower than the thing it exists to spread: every pour left
			a rind down both sides that took a second pass to pick up, which reads as
			the tool being broken rather than as the tool being small.

			And the blade you can SEE has always been 6.4. ToolBuilder sizes the rubber
			from Config.BladeHalfLen, and DrivewayServer builds the tool once on the
			server where that is still the module default -- so the part is 6.4 studs
			for everybody at every level, while the simulation used the track's value.
			A level 1 player was pushing a 6.4 blade that only worked over 5.2 of
			itself. Now the two agree at the bottom of the ladder.

			What did NOT change, deliberately:

			  * `costs`, entry for entry. Same fifteen prices for the same fifteen
			    levels, so nothing anybody has already bought moved, and the tutorial's
			    "now buy an upgrade" step still costs exactly 1200.
			  * The top of the ladder. Only rungs 1-5 moved and they rejoin the original
			    numbers at rung 6; 22.5 is still the maximum. That is not tidiness --
			    DrivewayServer clamps reported coverage at 0.12/sec, and a top blade at
			    top walk speed already runs at 0.100/sec on an average slab. Widening
			    the top rung would have eaten most of what is left of that margin for a
			    problem nobody has at the top of the ladder.

			Level 1 -> 2 is still +0.6 studs, so the tutorial purchase is still a step
			the player can feel.
		]]
		values = { 6.4, 7.0, 7.5, 8.0, 8.6, 9.4, 10.4, 11.5, 12.7, 14.0, 15.4,
		           17.0, 18.7, 20.5, 22.5 },
		costs  = { 0, 1200, 2400, 4440, 8210, 15200, 28100, 52000, 96200, 178000,
		           329000, 888000, 2400000, 6480000, 17500000 },
		reqs = LATE_B,
	},
	{
		id = "Pour", name = "Pour Volume", glyph = "\u{1F4A7}", suffix = "x",
		blurb = "Every tip of the pail lays a bigger puddle, so one pour spreads "
			.. "further before you go back for more.",
		tint = Color3.fromRGB(120, 176, 250),
		--[[
			RENAMED from Pour Speed (2026-08-12), because it stopped selling speed.

			The pail is metered now -- a press tips it once for a fixed volume, see
			Config.PourDump -- so "sealer leaves the pail faster" buys nothing on its own:
			a glug spends the same units however quickly they come out. What the ladder
			multiplies is the VOLUME of a glug, and it multiplies Config.PourRate by the
			same figure only to hold the glug's duration constant at 1.56 s.

			`id` is untouched, so every saved profile keeps the level it bought. `values`
			and `costs` are untouched too, entry for entry -- and they did not need
			touching, which is the interesting half.

			THE WORRY WAS THAT BIGGER GLUGS RUN AWAY WITH THE GAME. They do not, because
			the blade widens alongside them, and the thing a player actually feels is how
			far one glug carries a pass -- glug volume over blade width:

			  rung    blade   pour     glug     pass
			   1       6.4    1.00x    125 u    19.5 studs
			   5       8.6    1.63x    204 u    23.7
			   10     14.0    3.00x    375 u    26.8
			   15     22.5    5.54x    693 u    30.8

			Nineteen studs to thirty-one across fifteen rungs, drifting gently up. On a
			59-stud driveway that is a third of the drive early and half of it late, which
			is the curve you would draw on purpose.

			And it still cannot touch income, for exactly the reason the note below gives:
			the payout clamp in DrivewayServer is coverage per second, and coverage comes
			off the BLADE. A bigger glug buys fewer presses per driveway -- about 16 at the
			bottom of the ladder against 3 at the top -- and never a penny.
		]]
		--[[
			The floor was raised, not the ceiling (2026-08-11, owner's call).

			Config.PourRate went 50 -> 80 and Config.WandRate 65 -> 104 in the same
			edit, so the STOCK pour is now what level 4 used to be. These multipliers
			were re-anchored against those new bases in the same breath, and that is the
			whole of why the change is safe to ship onto live profiles. What a level is
			worth in units per second:

			  level   1     4     8     10    14      15    16
			  was     50    82    154   210   382     --    --
			  now     80    115   188   240   392     443   500

			Every rung delivers at least what it delivered before, so no saved level was
			nerfed, and the gap closes as it climbs: +60% at the bottom, +2% at 14. The
			ceiling is the number that had to hold still -- the wand's server-side draw
			clamp, the depth the sheet can draw and the pace the blade can keep up with
			are all tuned against the top of this ladder, not the bottom of it.

			Rungs are 1.13x apart now rather than 1.17x. That is the price of raising the
			floor under a fixed ceiling, and it is paid for by the two rungs added on the
			end: the ladder still sells a 6.25x climb, and it now reaches 31% past where
			it used to stop. Each step is still legible on the card -- no two of these
			print the same figure through Upgrades.short.

			costs 2-14 are UNTOUCHED, entry for entry. The same rungs cost the same money
			they did yesterday, so nothing anybody has already bought changed meaning and
			the raise reads as a gift at the bottom rather than as a discount on the
			ladder -- which is also the honest accounting, because the absolute rate
			bought between level 1 and level 14 is within 6% of what it always was
			(312 units/s against 332). The two new prices continue the late curve at the
			same 2.7x every other track's last rungs climb at.

			Pour is a PACING track, not an income one: the payout clamp in DrivewayServer
			is coverage per second, and coverage comes off the blade. A faster spout buys
			time, never money -- which is why this could be handed out at the bottom
			without touching the economy. It does make Bucket Capacity and Refill Speed
			worth more, since the pail now empties 1.6x quicker at the stock rung, and
			that is the tension those two tracks exist to sell.
		]]
		values = { 1.00, 1.13, 1.28, 1.44, 1.63, 1.84, 2.08, 2.35, 2.65, 3.00,
		           3.39, 3.83, 4.33, 4.90, 5.54, 6.25 },
		costs  = { 0, 1650, 3050, 5650, 10400, 19300, 35800, 66100, 122000, 226000,
		           610000, 1650000, 4450000, 12000000, 32400000, 87500000 },
		reqs = LATE_P,
	},
	{
		id = "Speed", name = "Walk Speed", glyph = "\u{1F45F}", suffix = "",
		blurb = "Less time walking between jobs and back to the depot.",
		tint = Color3.fromRGB(250, 196, 92),
		-- Flatter than it was. 52 outran the blade badly enough that a fast player
		-- walked out from under their own bead; 44 is still more than double the
		-- stock pace and every rung of it is spendable.
		values = { 20, 21.5, 23, 24.5, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44 },
		costs  = { 0, 1400, 2590, 4790, 8860, 16400, 30300, 56100, 104000, 192000,
		           518000, 1400000, 3780000, 10200000 },
		reqs = LATE,
	},
	--[[
		The truck's front squeegee bar -- a game pass, and a row rather than a
		silence.

		It is listed here precisely BECAUSE it cannot be bought here. This is the
		screen a player opens when they want their rig to be better, so a truck
		attachment that exists and is missing from it reads as content they have not
		found yet. Listed and locked, it reads as content they can go and get.

		Two requirements, and it names both, because they fail differently: no pass
		is a purchase, no truck is an afternoon's work, and a row saying only
		"locked" would send a player who already holds the pass away none the wiser.
	]]
	{
		id = "TruckBlade", name = "Truck Squeegee", glyph = "\u{1F69B}", suffix = "",
		blurb = "A squeegee bar on the nose of your rig -- drop it and drive.",
		tint = Color3.fromRGB(206, 152, 255),
		pass = "TruckBlade",
		unlock = true,
		values = { 0, 1 },
		costs = { 0, 0 },
	},
} :: { Track }

--[[
	The trucks, generated from the rig catalogue rather than written out again.

	They are hidden here and sold on the dealership's own screen, but they are
	still ordinary tracks underneath: the server's cash handling, the level
	attribute and the save file need no idea that a truck is different from a
	wider squeegee. Prices live in Rigs beside the stats they buy, so a rig can
	never be advertised at a price the shop does not charge.
]]
local Rigs = require(game:GetService("ReplicatedStorage")
	:WaitForChild("DrivewaySealer"):WaitForChild("Rigs"))

for _, r in ipairs(Rigs.List) do
	table.insert(Upgrades.Tracks, {
		id = r.id,
		name = r.name,
		blurb = r.blurb,
		glyph = "\u{1F69B}",
		suffix = "",
		tint = r.tint,
		unlock = true,
		hidden = true,
		zone = "Dealership",
		values = { 0, 1 },
		costs = { 0, r.price },
	})
end

Upgrades.ById = {} :: { [string]: Track }
for _, t in ipairs(Upgrades.Tracks) do
	Upgrades.ById[t.id] = t
end

function Upgrades.maxLevel(id: string): number
	local t = Upgrades.ById[id]
	return t and #t.values or 1
end

-- value delivered at a given level, clamped so a bad level can never error
function Upgrades.valueAt(id: string, level: number): number
	local t = Upgrades.ById[id]
	if not t then return 1 end
	return t.values[math.clamp(level, 1, #t.values)]
end

-- cost of the NEXT level, or nil when maxed
function Upgrades.costOf(id: string, level: number): number?
	local t = Upgrades.ById[id]
	if not t then return nil end
	if level >= #t.values then return nil end
	return t.costs[level + 1]
end

--[[
	Rebirths needed before the NEXT level may be bought; 0 means it is open now.

	A gate is not a price, and the shop has to draw the difference. A player who
	cannot tell them apart will sit and save for something they are not allowed to
	buy yet, and blame the game when the money arrives and the button stays dead.
]]
function Upgrades.requiresOf(id: string, level: number): number
	local t = Upgrades.ById[id]
	if not t or not t.reqs then return 0 end
	return t.reqs[level + 1] or 0
end

-- 1.4M rather than 1400000; the shop rows have no room for the long form.
-- Two decimals with trailing zeros stripped, so 3040 reads 3.04K and 2500 reads
-- 2.5K -- matching the precision the reference HUD uses.
--
-- It stopped at B, which was enough while the rebirth ladder stopped at twelve
-- and the payout multiplier stopped with it. Neither stops now (see
-- Rebirth.Ladder), and a long enough run reaches figures that printed as
-- "1000000B" -- wide enough to shove the shop rows apart, and unreadable at a
-- glance regardless. Four more rungs cover anything the curve can produce.
function Upgrades.short(n: number): string
	-- the parens matter: gsub returns (string, count), and without them the count
	-- leaks out as a second return value and lands in whatever concatenates this
	if n >= 1e21 then return (string.format("%.2fSx", n / 1e21):gsub("%.?0+Sx$", "Sx")) end
	if n >= 1e18 then return (string.format("%.2fQi", n / 1e18):gsub("%.?0+Qi$", "Qi")) end
	if n >= 1e15 then return (string.format("%.2fQa", n / 1e15):gsub("%.?0+Qa$", "Qa")) end
	if n >= 1e12 then return (string.format("%.2fT", n / 1e12):gsub("%.?0+T$", "T")) end
	if n >= 1e9 then return (string.format("%.2fB", n / 1e9):gsub("%.?0+B$", "B")) end
	if n >= 1e6 then return (string.format("%.2fM", n / 1e6):gsub("%.?0+M$", "M")) end
	if n >= 1e3 then return (string.format("%.2fK", n / 1e3):gsub("%.?0+K$", "K")) end

	if n == math.floor(n) then return tostring(math.floor(n)) end
	return (string.format("%.1f", n):gsub("%.0$", ""))
end

return Upgrades
