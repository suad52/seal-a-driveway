--!strict
--[[
	Rigs -- the four trucks on the dealership floor.

	A ladder with four personalities. Each is the best truck money can buy at its
	price, and each is best at something different, so the one you are saving for
	also changes how the job feels:

	  Dart      gets there. The fastest thing in the yard, and it stays the
	            fastest -- none of the others ever catches it between jobs.
	  Kerbline  is the one you can actually reach. More of everything than the
	            Dart and nothing it is bad at, at a fifth of the Longline.
	  Longline  parks once. Enough hose to reach both sides of a street from a
	            single stop, which is the slowest part of the lap removed.
	  Cistern   does not stop. A tank measured in driveways and a pump to match,
	            so both the refill and the pour get out of the way.

	They were sidegrades, and it did not survive contact with the curve: a strict
	sidegrade means the 25M truck is a downgrade from the 5M one in two stats out
	of three, and nothing priced like that is ever worth buying. Each is now
	strictly better overall than the one below it, with its own emphasis on top --
	which is what the buy screen's bars were always drawing anyway.

	--[ the prices ]----------------------------------------------------------

	These have been up and down twice, both times for the same underlying reason,
	and it is worth writing down.

	They started at 2.6M/5.2M/8.4M against an economy where every slab paid ONCE
	between rebirths. Twenty slabs, about 5,700 each: a complete sweep of the entire
	map was roughly 114,000, so the cheapest truck was twenty-three full sweeps
	and nobody was ever going to own one. They were then cut to 35K/90K/175K,
	which made them buyable and made the showroom real.

	The fix was in the wrong place. The problem was never the prices, it was that
	a map which pays once per lap has a FIXED worth per lap, and no price above it
	can exist. What lifts the ceiling is the rebirth multiplier: a lap is worth
	$283K flat and x434 at the top of the ladder, so seven figures is reachable a
	few rebirths in and the trucks are back to being the things you save for.

	Read against that curve: the Dart is affordable on the second lap, the Longline
	on the fourth, and the Cistern on the ninth of thirteen. A lap played well is
	worth up to 60% more than those figures (Economy.TipCap), which is what pulls
	each of them a lap earlier. Contracts refreshing on a timer used to be what did
	this work -- that is gone, and rebirth carries it alone now.

	Those laps used to have the next rebirth taken out of them as well, because a
	rebirth was bought with cash. It is bought with the lap itself now (see
	Rebirth.BaseShare), so the whole purse reaches the showroom and every figure
	above lands a little sooner than written -- in the right direction, and the
	reason the ladder changed at all.

	Rebirth deliberately keeps trucks, which makes one the most durable thing a
	player can buy and is the whole reason the top two can be priced like this.

	One table, read by the shop rows, the showroom build and the spawner, so a
	rig can never advertise a number it does not actually have.

	--[ the fifth truck ]------------------------------------------------------

	There is one more, and it is not on this ladder: the Cyberseal, sold by game
	pass rather than for cash. It lives in Rigs.Pass and the reasons it is kept
	out of Rigs.List are written over that table -- they are not stylistic.
]]

local Rigs = {}

export type Rig = {
	id: string,
	name: string,
	tagline: string,
	blurb: string,
	price: number,
	tint: Color3,        -- the livery, and the accent the UI uses for this rig
	cab: Color3,
	topSpeed: number,    -- studs/s flat out
	hose: number,        -- studs of hose on the reel
	tank: number,        -- coat-studs aboard
	--[[
		Set only on a rig that is BOUGHT WITH A PASS rather than with cash, and
		holding the Passes id that sells it. Its presence is what keeps the rig off
		the cash ladder -- see the note over Rigs.Pass.
	]]
	pass: string?,
	--[[
		A rig whose bodywork is an imported model rather than the procedural one,
		naming the shell under ReplicatedStorage.DrivewaySealer. TruckBuilder welds
		that in place of the cab and deck it would otherwise draw.

		Such a rig also brings its OWN barrel and reel dimensions, because the ones
		Rigs.body computes are sized for the flatbed: a shell has a bed of a fixed
		size and the drum has to be the size that fits in it, not the size its tank
		figure would imply.
	]]
	shell: string?,
	fixedBody: Body?,
	--[[
		Pump multiplier: how fast sealer leaves the wand, and how fast the drum
		fills at the depot.

		This stat exists because every other one saturates. Tank stops mattering
		once it covers the biggest job on the map in one fill, and hose stops
		mattering once it reaches the far corner of the lot -- so a top-end truck
		defined only by those two is worth nothing over the middle one by the time
		you can afford it. Pouring is a fixed share of every job at every scale, so
		a better pump is a gain that never runs out.
	]]
	pump: number,
	--[[
		BRAKES, as multipliers on Config's global figures. Absent means 1, so the
		four cash trucks brake exactly as they always have and a retune of
		Config.TruckBrake still moves the whole catalogue together.

		Per rig rather than global because stopping is the one thing that does NOT
		scale with the catalogue. Config sizes the brake against a 34 studs/s truck
		and calls it "a firm stop in a couple of seconds"; a rig doing 87.8 carries
		six and a half times the energy into the same four hubs, so the identical
		brake is a fraction of the stop it used to be. That is not a tuning opinion,
		it is v^2 -- see the Cyberseal's own note for the arithmetic.

		TWO NUMBERS BECAUSE A STOP HAS TWO HALVES, and raising one without the other
		leaves half the problem standing:

		  `brake` is MotorMaxTorque while coasting -- how hard the wheels may be
		    slowed. It is what binds at speed.
		  `brakeEase` is how fast the target velocity is bled toward zero, which is
		    the deliberate anti-rocking ramp Config.TruckBrakeEase exists to be. It
		    binds below (torque / ease) studs/s -- so on a fast rig it owns most of
		    the stop, and that tail is where "the brakes feel weak" actually lives.
	]]
	brake: number?,
	brakeEase: number?,
}

Rigs.List = {
	{
		id = "Dart",
		name = "Bantam Dart",
		tagline = "Quick between jobs",
		blurb = "Half the tank and a short reel, but it moves. Built for chasing "
			.. "small residential work close to the depot.",
		price = 250000,
		tint = Color3.fromRGB(250, 196, 62),
		cab = Color3.fromRGB(248, 214, 92),
		--[[
			Speeds came down hard across the whole catalogue, and the map is why.

			Maple Drive is about three hundred studs end to end. At 84 studs/s the
			entry truck crossed the whole neighbourhood in under four seconds, which
			makes the distance between jobs -- the thing a bigger tank and a longer
			hose exist to buy you out of -- cost nothing to begin with. It also put the
			rig well past what its tyres can hold in a corner (see TruckSteerEase).

			The Dart is still the fastest thing in the yard and still more than twice
			a stock walk. It is no longer faster than the map is big.
		]]
		-- All four came down together on 2026-08-09 (52/46/42/38 before); the spread
		-- between them is untouched, so the Dart is still the quick one. See the note
		-- over Config.TruckTopSpeed for why 34 rather than 52.
		topSpeed = 34,
		hose = 96,
		--[[
			4200 -> 3400 (2026-08-07, owner's call: the cheap truck should carry less).

			It also makes the blurb's "half the tank" literally true against the
			Kerbline's 6500, which it was not before.

			This moves Rigs.Range.tank.min, and the note further down about a rig that
			sets a new extreme reshaping the others applies -- so it was checked rather
			than assumed. The Dart is the minimum either way, so its own barrel is
			unchanged at the 0.18 floor; the three above it widen by about three
			percent of the span, which reads as the Dart being the small one. That is
			the direction this change wanted anyway.
		]]
		-- Roughly four and a half stock pails. Enough that a truck is a real step up
		-- from carrying one, short of a Maple driveway in a single fill -- so the
		-- drum is still a thing you spend upgrades on rather than a solved problem.
		tank = 2200,
		pump = 1.00,
	},
	--[[
		The rung between 250K and 5M.

		That gap was twenty times the price for the second truck in the game, which
		is a long time owning the one you bought in the tutorial's shadow. Every
		stat sits strictly inside the existing spread on purpose: Rigs.Range is
		computed across this list and Rigs.body normalises against it, so a rig that
		set a new minimum or maximum anywhere would silently resize the barrel and
		reel of all three of the others.
	]]
	{
		id = "Kerbline",
		name = "Kerbline 160",
		tagline = "The honest step up",
		blurb = "More tank, more reel and a better pump than the Dart, and it still "
			.. "moves. The truck you buy while you save for the big one.",
		price = 1200000,
		tint = Color3.fromRGB(158, 132, 232),
		cab = Color3.fromRGB(236, 232, 248),
		topSpeed = 30,
		hose = 160,
		tank = 3800,
		pump = 1.22,
	},
	{
		id = "Longline",
		name = "Longline 280",
		tagline = "Park once, do the street",
		blurb = "Two hundred and eighty studs on the drum. Reaches both sides of a "
			.. "road from one stop, so the walking stops being the job.",
		price = 5000000,
		tint = Color3.fromRGB(96, 200, 232),
		cab = Color3.fromRGB(226, 240, 246),
		topSpeed = 27,
		hose = 280,
		tank = 6000,
		pump = 1.50,
	},
	{
		id = "Cistern",
		name = "Cistern Heavy",
		tagline = "Never stops to refill",
		blurb = "Twenty-two thousand aboard and a pump to shift it -- a street at a "
			.. "time without seeing the depot. Everything but the sprint.",
		price = 25000000,
		tint = Color3.fromRGB(226, 92, 78),
		cab = Color3.fromRGB(238, 236, 232),
		topSpeed = 24,
		hose = 300,
		tank = 13000,
		pump = 2.60,
	},
} :: { Rig }

--[[
	Rigs SOLD BY GAME PASS, kept in their own list rather than added to the one
	above -- which is the whole reason the four cash trucks are untouched by this.

	Rigs.List is not merely a catalogue. It is read as "the cash ladder" by five
	other places, and every one of them would have done the wrong thing with a
	fifth entry in it:

	  Rigs.Range   spans the list to normalise the buy screen's bars AND to size
	               every truck's barrel and reel. A rig that beat an existing
	               maximum -- and this one beats three -- would silently reshape
	               all four of the others, on the forecourt and in the bay. The
	               warning over Rigs.Range says exactly this.
	  Rigs.cheapest is what the Starter Rig pass hands over. A pass truck has no
	               price, and a price of zero would have made it the cheapest
	               thing in the yard -- so that pass would have started handing
	               out this one for free.
	  Upgrades     turns each entry into a cash unlock track with a price. A pass
	               truck must not be buyable with cash.
	  DealershipBuilder and DealershipSigns build one showroom bay per entry, and
	               there are four bays on the floor.

	So: `List` stays the cash ladder, `All` is what asks "every truck that
	exists" -- ownership, the picker, the id lookup -- and the split is what keeps
	the two questions from being confused for each other.
]]
Rigs.Pass = {
	--[[
		The pass truck: fastest thing in the game, and the only one you cannot save
		up for.

		Its stats deliberately do NOT beat the Cistern everywhere. Speed, tank and
		hose are all new maxima -- that is what is being sold -- but the pump is
		1.60, between the Longline and the Cistern. The 25M truck is the top of a
		ladder somebody spends nine laps climbing, and a pass that strictly
		dominates it retires the endgame purchase the day it goes on sale. Pouring
		is the one stat that never saturates (see the note on `pump` above), so
		leaving it to the Cistern is what keeps that truck worth the climb.
	]]
	{
		id = "Cyberseal",
		name = "Cyberseal",
		tagline = "Pass only -- and it moves",
		blurb = "A stainless skid unit in the bed and the longest reel in the game,"
			.. " on the quickest thing in the yard. Sold by pass, kept forever.",
		-- Not for sale for cash. Nothing reads this -- the rig is off the cash
		-- ladder entirely -- and it is here because the type says every rig has one.
		price = 0,
		pass = "CyberRig",
		shell = "CyberSealShell",
		tint = Color3.fromRGB(158, 166, 178),
		cab = Color3.fromRGB(198, 204, 212),
		--[[
			55 MILES PER HOUR, which in this field's units is 87.8. Owner's call,
			2026-08-13.

			THE FIELD IS STUDS PER SECOND AND THE ASK WAS IN MPH, so the two are not
			the same 55 and the coincidence is worth flagging before somebody "fixes"
			it back. Shell's gauge converts with MPH_PER_STUD = 0.28 * 2.23694 (0.28
			metres in a stud, 2.23694 mph in a metre per second), so 55 mph is
			55 / 0.6263432 = 87.81, and 87.8 reads 55 on both the cab dial and the
			buy screen's spec line. This rig sat at 55 studs/s -- 34 mph -- until now.

			For scale: the Dart is 34 studs/s (21 mph), the Cistern 24 (15), a stock
			walk 16 (10).

			⚠ THIS IS PAST WHERE THE CATALOGUE WAS MEASURED, in both the arguments the
			2026-08-09 rollback was made on. Neither is a reason not to ship it -- it
			is what a pass truck is selling -- but neither has been re-tested, and the
			next person to touch this should know which figures are evidence and which
			are arithmetic.

			PACE, which is the argument that actually pulled the ladder down. 52 was
			rejected for crossing the whole 277-stud length of Maple Drive in five
			seconds and ceasing to feel like a work truck between driveways. 87.8
			crosses it in 3.2. That is a judgement about feel and the owner has made
			it.

			GRIP, which is the part that is no longer covered by a measurement.
			RigController normalises the steering-ease curve against THE RIG'S OWN top
			speed rather than a fixed reference --
				ease = 1 - (1 - TruckSteerEase) * clamp(speed / self.topSpeed, 0, 1)
			-- so every rig gets the same 34% of lock, 12.2 degrees, when it is flat
			out, and turning radius at a fixed steering angle is set by the wheelbase
			rather than by speed. A faster rig therefore traces THE SAME 68-stud
			circle; it only gets round it sooner. What does not stay the same is the
			grip that circle demands, which goes with the SQUARE of speed:

			                    radius   lateral    vs gravity   roll   slip
			  Dart at 34        67       17 st/s^2   0.09 g      0.6    6.4   measured
			  this at 55        68       44          0.23 g      1.3    6.3   measured
			  this at 87.8      68       113         0.58 g      ?      ?     NOT measured

			0.58 g is two and a half times the load the 1.3 degrees of roll was
			observed under, and the earlier note's conclusion -- "the tyre had the
			margin" -- was drawn at 0.23 g and does not carry to here. It may still
			hold; the low ballast is doing real work (see Config.BallastMass). It has
			simply not been checked, and full lock from flat out is the run to make.

			If it does need reining in, the dial is this rig's LOCK AT SPEED and not
			its top speed -- but TruckSteerEase is global, so pinning it per rig means
			giving Rig a steerEase field defaulting to Config's. Cutting the top speed
			back is the one fix that undoes what was asked for.
		]]
		topSpeed = 87.8,
		hose = 380,
		tank = 18000,
		pump = 1.60,
		--[[
			Raised on the owner's report that the brakes are "pretty weak" (2026-08-13)
			-- and READ THE SECOND HALF BEFORE RAISING IT FURTHER, because the bench
			says this is not the dial that is holding the truck back.

			The arithmetic that motivated it: Config sizes the brake against a 34
			studs/s truck, 1,400 a hub across four hubs on a 1.80 wheel, and stopping
			distance goes with the SQUARE of speed -- so a rig at 87.8 ought to need
			several times the brake to stop in the same ground.

			MEASURED, IT DOES NOT WORK THAT WAY, and the numbers are worth keeping
			because they are the opposite of what the arithmetic predicts. Rolled up to
			85 studs/s on the road and coasted to a stop, server-side, running exactly
			RigController's coasting branch:

			  brake x1  ramp x1     42-45 studs      peak tyre slip 52 studs/s
			  brake x4  ramp x1     41 studs         peak tyre slip 51
			  brake x20 ramp x1     42 studs         peak tyre slip 51
			  brake x1  ramp x20    60 studs         peak tyre slip 88

			Twenty times the brake is worth nothing, and a QUICKER ramp is worth less
			than nothing. The tyre slip says why: the motor drops the commanded wheel
			speed far below the speed the body is actually doing, the wheels lock
			almost at once, and the rest of the stop is a slide. A locked wheel cannot
			be locked harder, which is why the torque column is flat -- and a faster
			ramp locks it sooner, which is why x20 ramp is the worst row in the table.

			So x4 is kept as headroom -- it costs nothing, and it firms the standstill
			hold, which is TruckHoldFrac of this number -- and NO ramp multiplier is
			set, because the evidence says a quicker ramp makes the slide longer.

			⚠ THE REAL FIX IS NOT A NUMBER IN THIS TABLE. It is to stop the wheels
			locking: command the wheel to stay just under the body's own speed instead
			of bleeding it open-loop to zero, so the tyre works near its grip peak
			(friction 2.0 at weight 12, TruckBuilder.wheelPart) rather than sliding on
			it. That is a change to RigController's coasting branch and to every rig,
			so it wants a repeat-averaged test: the run-to-run spread on an UNCHANGED
			configuration above is 34 to 45 studs, which is the same size as the effect
			being looked for.

			Acceleration is untouched either way: MotorMaxTorque is only `brake` while
			coasting, and Config.TruckTorque still drives the wheels.
		]]
		brake = 4.0,
		--[[
			The drum that actually fits the bed, measured off the shell rather than
			derived from the tank figure.

			The bed floor sits at 3.92 above the ground and its walls stand at about
			2.5 studs either side of the centreline, so a barrel wider than 4.6 fouls
			them. Rigs.body would have asked for 5.60 by 10.80 on this tank figure,
			which is a barrel twice as long as the bed holding it.

			LENGTH is set by the reel rather than by the bed. Both have to live behind
			the cab, and the reel is the one with a job to do at a fixed height -- the
			hose has to pay out into the player's hands -- so it takes the rear and the
			barrel gets what is left. 3.8 is where the drum's dished head stops just
			clear of the coil; longer and the two intersect. The barrel is fat rather
			than long to compensate, which is also what a bed skid unit actually looks
			like.
		]]
		fixedBody = {
			tankDia = 4.4, tankLen = 3.8,
			reelDia = 4.0, reelWidth = 3.0,
		},
	},
} :: { Rig }

-- Every truck that exists, cash or pass. Ownership, the id lookup and the
-- picker ask this; anything pricing or displaying the ladder asks Rigs.List.
Rigs.All = {} :: { Rig }
for _, r in ipairs(Rigs.List) do table.insert(Rigs.All, r) end
for _, r in ipairs(Rigs.Pass) do table.insert(Rigs.All, r) end

Rigs.ById = {} :: { [string]: Rig }
for _, r in ipairs(Rigs.All) do
	Rigs.ById[r.id] = r
end

--[[
	The best and worst of each stat across the range.

	The buy screen draws its bars against these rather than against absolute
	maxima, so every stat uses the full width of the bar and the differences are
	visible. A tank bar scaled from zero would make the Dart and the Longline
	look nearly identical next to the Cistern.

	These are also what Rigs.body sizes a truck from, so the spread is load
	bearing: adding a rig that beats an existing extreme reshapes every other
	truck in the game, on the forecourt and in the bay.

	Which is why this spans Rigs.List and not Rigs.All. The pass truck beats the
	ladder's maximum in speed, tank and hose all three -- folding it in here would
	have shrunk the Cistern's barrel and the Longline's reel on the day it shipped,
	and flattened every bar on the buy screen against a truck that is not for sale
	there. It is off the ladder, so it does not get to redraw it.
]]
local function span(get: (Rig) -> number): { min: number, max: number }
	local lo, hi = math.huge, -math.huge
	for _, r in ipairs(Rigs.List) do
		local v = get(r)
		if v < lo then lo = v end
		if v > hi then hi = v end
	end
	return { min = lo, max = hi }
end

Rigs.Range = {
	speed = span(function(r) return r.topSpeed end),
	hose = span(function(r) return r.hose end),
	tank = span(function(r) return r.tank end),
	pump = span(function(r) return r.pump end),
}

-- 0..1 across the range, with a floor so the weakest still shows a stub
-- rather than an empty bar that reads as "none".
--
-- Clamped, because the range spans the cash ladder alone and a pass truck sits
-- outside it at the top: unclamped, its stats return more than 1 and the buy
-- screen draws a bar wider than the trough it sits in.
function Rigs.normal(kind: string, value: number): number
	local r = Rigs.Range[kind]
	if not r or r.max <= r.min then return 1 end
	return math.clamp(0.18 + 0.82 * ((value - r.min) / (r.max - r.min)), 0, 1)
end

--[[
	The physical proportions of a rig, worked out from its own stats.

	The showroom's display models already sized their barrel and reel this way,
	but the truck you actually drove did not: all three spawned identical bodies
	and differed only in paint, so buying a Cistern for its nineteen thousand got
	you a Dart in red. TruckBuilder reads this now, which is what makes the thing
	on the forecourt the thing that turns up in the bay.

	Length is the constrained one. The barrel shares a 14.5-stud deck with the
	pump skid and the hose reel, so it can only grow about two studs before it is
	inside the pump -- which is why the Cistern's nineteen thousand is expressed
	mostly as a fatter, taller barrel rather than a longer one. Diameter has
	nowhere to hit: it just stands proud of the cab, which is exactly what a
	heavy tanker looks like.
]]
export type Body = {
	tankDia: number, tankLen: number,
	reelDia: number, reelWidth: number,
}

function Rigs.body(rig: Rig): Body
	-- A rig built on an imported shell carries its own, measured against the bed
	-- that has to hold them -- see fixedBody on the Rig type.
	if rig.fixedBody then return rig.fixedBody end

	local tank = Rigs.normal("tank", rig.tank)
	local hose = Rigs.normal("hose", rig.hose)
	return {
	--[[
		The barrel grows mostly in LENGTH now, and that is a clearance fix.

		At 2.6 studs of diameter per unit of tank the Cistern stood 11.43 studs tall.
		The depot's SideLintel has its underside at 11.00 and is permanent geometry --
		the roll shutter above it is destroyed once the tutorial is done, but the
		lintel is not -- so the top rig simply could not be driven out of its own
		garage. Measured against every rig: Dart 9.30, Kerbline 9.61, Longline 10.05,
		Cistern 11.43. Only the last one was over, which is exactly the report.

		Moving the growth into length keeps the Cistern visibly the big truck -- a
		longer barrel down a longer deck -- without putting its crown through the
		doorway. Diameter still grows, just gently enough that the tallest rig clears
		the lintel with room rather than grazing it.
	]]
		tankDia   = 4.2 + 1.4 * tank,   -- 4.45 Dart .. 5.60 Cistern
		tankLen   = 7.4 + 3.4 * tank,   -- 8.01 Dart .. 10.80 Cistern
		reelDia   = 2.1 + 1.9 * hose,   -- 2.44 Dart .. 4.00 Longline
		reelWidth = 1.9 + 1.1 * hose,   -- 2.10 Dart .. 3.00 Longline
	}
end

--[[
	What this rig's drum actually holds FOR THIS PLAYER.

	The catalogue figure is a BASE, and the Bucket Capacity track scales it -- so
	the showroom advertised a Dart at 3,400 while handing over one that held
	4,760, and every readout downstream repeated the catalogue number. Measured on
	a live rig at Tank level 2. A spec sheet that does not match the vehicle is
	worse than no spec sheet: it is the one number the screen exists to compare.

	Deliberately the same expression TruckServer stamps onto the model, written
	here so both sides read one function instead of keeping two copies of the same
	arithmetic in step by hand.
]]
function Rigs.tankFor(plr: Player?, rig: Rig): number
	if not plr then return rig.tank end
	local Upgrades = require(game:GetService("ReplicatedStorage")
		:WaitForChild("SealerUI"):WaitForChild("Upgrades"))
	local lv = (plr:GetAttribute("Upg_Tank") :: number?) or 1
	return math.floor(rig.tank
		* (Upgrades.valueAt("Tank", lv) / Upgrades.valueAt("Tank", 1)) + 0.5)
end

function Rigs.owns(plr: Player, id: string): boolean
	return ((plr:GetAttribute("Upg_" .. id) :: number?) or 1) >= 2
end

--[[
	The bottom rung, computed rather than named.

	The Starter Rig pass sells "the cheapest truck in the yard", and the whole
	point of asking the list is that the answer follows the list: add a rung below
	the Dart one day and the pass hands over that one instead, with nothing to
	remember. Writing "Dart" into the pass would have been the same class of
	mistake as the hand-written rebirth copy in Shell -- a second copy of a fact
	that goes quietly wrong the first time the fact changes.

	Price, not list position: the list is written in ladder order today, and that
	is a convention rather than a guarantee.

	Rigs.List, so only the CASH ladder is a candidate. A pass truck has no price
	-- it carries 0 -- and asking Rigs.All here would have made the newest and
	best truck in the game "the cheapest", which is what the Starter Rig pass
	hands over for free.
]]
function Rigs.cheapest(): Rig
	local best = Rigs.List[1]
	for _, r in ipairs(Rigs.List) do
		if r.price < best.price then best = r end
	end
	return best
end

-- Whichever rig the player last called up, falling back to the first they own.
-- Nil when they own none.
--
-- Rigs.All: "which truck am I driving" has to be able to answer with the pass
-- one, or buying it would leave the owner still driving whatever they had.
function Rigs.chosen(plr: Player): Rig?
	local pick = plr:GetAttribute("RigChoice") :: string?
	if pick and Rigs.ById[pick] and Rigs.owns(plr, pick) then return Rigs.ById[pick] end
	for _, r in ipairs(Rigs.All) do
		if Rigs.owns(plr, r.id) then return r end
	end
	return nil
end

return Rigs
