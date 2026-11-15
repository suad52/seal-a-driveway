--!strict
--[[
	Passes -- the game passes, and whether this player holds one.

	Ownership is mirrored onto the Player as an attribute (Pass_InstantFill, and
	so on) by PassService, and everything else reads it from here. That is the
	same trick the upgrade ladder uses and for the same reasons: attributes
	replicate on their own, so the client can branch on a pass with no API call
	of its own and no remote to keep in sync, and the server can answer the same
	question from the same place without a web round trip in the middle of a
	frame.

	UserOwnsGamePassAsync is therefore called in exactly one place -- PassService
	-- and never from gameplay code.

	The asset id is the one thing that cannot be guessed, and a pass left at 0 is
	simply one that nobody owns: every check below answers false, the held fill
	stays held, and nothing else in the game changes shape. That is what makes it
	safe to ship the mechanic before the pass exists on the site.
]]

local Passes = {}

export type Pass = {
	-- our own name for it, and the attribute suffix; never the asset id, which
	-- can change while the thing it buys does not
	id: string,
	-- what Roblox knows it as. 0 means "not created yet" -- see the note above.
	assetId: number,
	name: string,
	blurb: string,
}

--[[
	Every pass below except Instant Refill ships with assetId 0 on purpose.

	The mechanics are live and testable now; the ids are the one thing that has to
	be created by hand in the Creator Dashboard. Until one is filled in, its pass
	is simply one nobody owns -- see the note at the top of this file -- so the
	game plays exactly as it did before. Fill in the number, publish, done: nothing
	else anywhere needs touching.
]]
local List: { Pass } = {
	{
		id = "InstantFill",
		assetId = 1940784359,
		-- Matches the pass's title on the site, and has to: this is what the buy
		-- button says, and Roblox's own purchase dialog says the other one. Two
		-- names for one purchase reads as having clicked the wrong thing.
		name = "Instant Refill",
		blurb = "Fill the pail and the rig's drum the instant you touch the depot"
			.. " pump -- no standing there holding the nozzle open.",
	},
	--[[
		The way into a truck for somebody who has not saved a quarter of a million.

		It hands over the CHEAPEST rig on the ladder, whichever that is -- the id is
		never written down here, because Rigs is where prices live and a second copy
		of "the cheap one is the Dart" is a copy that goes wrong the first time a
		rung is added below it. TruckServer resolves it through Rigs.cheapest().

		And it hands it over by GRANTING THE ORDINARY UNLOCK, not by teaching the
		game a second kind of ownership. Everything that asks whether you have a rig
		-- the bay, the picker, the showroom's OWNED badge, the delivery watcher --
		asks the same Upg_ attribute it always did, and none of it needed changing.
		The alternative was making Rigs.owns pass-aware, which would have left the
		buy screen still offering to sell you a truck you already had.

		That grant outliving a refund is the feature, not a leak: "keep it forever"
		is what is being sold.
	]]
	{
		id = "PermanentRig",
		assetId = 1941750683,
		name = "Starter Rig",
		blurb = "The cheapest truck in the yard, yours for good, right now -- no"
			.. " saving up for it and no losing it to a rebirth.",
	},
	--[[
		The squeegee bar across the front of the truck.

		The BAR is built on every rig whether or not anyone owns this, and that is
		deliberate: a pass nobody can see is a pass nobody buys. It rides parked and
		tilted up on the bumper, the control for it sits on the driver's gauge for
		every driver, and the only thing ownership decides is whether it will come
		down. Non-owners pressing it get Roblox's purchase dialog, which is the
		shortest path there is between wanting the thing and having it.

		Checked on the SERVER before the blade drops, not just in the UI. The blade
		state is an attribute on the rig model so every client can draw it, and an
		attribute a client could set itself would be a pass anybody could skip.
	]]
	{
		id = "TruckBlade",
		assetId = 1942770646,
		-- "Squeegee Attachment", which is the title on the site rather than the name
		-- the mechanic goes by everywhere else in the code. The site wins here and
		-- only here: this string is what the buy button prints, and Roblox's own
		-- dialog prints the listing's title beside it. The Upgrades track keeps
		-- calling itself Truck Squeegee -- that one is never shown next to a purchase.
		name = "Squeegee Attachment",
		blurb = "A squeegee bar on the nose of your rig. Drop it and drive -- the"
			.. " coat goes down the whole width of the truck as you go.",
	},
	--[[
		The valve on the spray bar, and the blade's opposite number on the dial.

		Sold the same way and for the same reason: the BAR and the VALVE are both
		built on every rig whether or not anyone owns them, because a control nobody
		can see is a pass nobody buys. The button sits on the driver's gauge for every
		driver, wears a padlock when it is not owned, and raises Roblox's dialog on
		press.

		WHAT IT SELLS IS NOT THE SAME THING THE BLADE SELLS, and the two are worth
		keeping distinct in the copy. The blade SPREADS what is already on the ground;
		this one PUTS IT THERE. Owned alone it drops fat puddles down the driveway for
		you to get out and squeegee by hand -- the pail's loop with the walk back to
		the depot removed, which is what a tank is for. Owned alongside the blade the
		two become one machine: the valve lays a bead a stud and a half in front of the
		rubber and the rubber spreads it in the same pass. Neither needs the other, and
		that is deliberate -- see Config's TRUCK POUR notes, where the bar being up or
		down picks the shape AND the rate the sealer goes down at.

		Checked on the SERVER before the valve opens, not just in the UI, for exactly
		the reason written over TruckBlade: the pouring state is an attribute every
		client reads to draw the stream, and an attribute a client could set itself
		would be a pass anybody could skip.
	]]
	{
		id = "TruckPour",
		assetId = 1949396708,
		--[[
			⚠ CONFIRM THIS AGAINST THE LISTING'S TITLE ON THE SITE. The rule is the one
			spelled out over Instant Refill and TruckBlade: this string is what the buy
			button prints, and Roblox's own purchase dialog prints the listing's title
			beside it, so two names for one purchase reads as having clicked the wrong
			thing. The id was supplied without the title, so this name is a guess that
			has not been checked -- and it is the one field here that cannot be checked
			from inside Studio.
		]]
		name = "Spray Bar",
		blurb = "Open the valve and lay sealer straight from the truck's own drum as"
			.. " you drive. Get out and squeegee it, or drop the bar and let it spread"
			.. " itself.",
	},
	{
		id = "DoubleCash",
		assetId = 1943688622,
		-- "2x Cash", not "Double Cash": this is the title on the site, and the rule
		-- at the top of Instant Refill applies here too -- the buy button and
		-- Roblox's own purchase dialog have to say the same words.
		name = "2x Cash",
		blurb = "Every driveway pays twice as much, for good. Stacks on top of your"
			.. " rebirth bonus.",
	},
	--[[
		Auto Reclaim (assetId 1943760643) was here and is delisted (2026-08-11,
		owner's call).

		It drank the sealer left on a finished driveway straight back into the pail,
		and it was one of two ways to get leftovers back -- the other being the pail
		set down by hand. Both are gone: a finished slab settles to cured coat on the
		frame it completes and the loose sealer goes with it, so there is nothing left
		for either to reclaim. An id kept in this list would have answered `owns` for
		people who paid and gated nothing, which is worse than not selling it.

		The pass itself still exists on the Roblox site -- taking it off sale there is
		a manual step on the listing, not something this file can do.
	]]
	--[[
		The Cyberseal, and the second pass that hands over a truck.

		It works the same way Starter Rig does and for the same reason: the server
		writes the ordinary Upg_Cyberseal unlock, and every part of the game that
		asks whether you have a rig goes on asking the one question it always did.
		See TruckServer.watchCyberPass, which is deliberately the same three lines
		as watchStarterPass.

		What is NOT the same: Starter Rig hands over a truck that is also for sale
		for cash, so buying it early is a shortcut. This one is the only way to get
		this truck at all -- it is not on the dealership floor and Upgrades never
		builds a cash track for it (see the note over Rigs.Pass). So the grant here
		is the whole of its ownership, and an assetId left at 0 means nobody owns
		it and the truck simply does not exist in the game yet.

	]]
	{
		id = "CyberRig",
		assetId = 1948310288,
		-- "Permanent Cyberseal", which is the listing's title on the site rather
		-- than the truck's name. The rule from Instant Refill applies: this string
		-- is what the buy button prints and Roblox's own dialog prints the listing's
		-- title beside it, so two names for one purchase reads as having clicked the
		-- wrong thing. The RIG goes on being called Cyberseal in Rigs -- that name
		-- is never shown next to a purchase, the same split TruckBlade already has
		-- against the Truck Squeegee upgrade track.
		name = "Permanent Cyberseal",
		blurb = "The quickest rig in the game, with the biggest drum and the longest"
			.. " reel. Yours for good, and never on the dealership floor.",
	},
	{
		id = "VIP",
		assetId = 1941984667,
		name = "VIP",
		--[[
			Premium contracts are part of this pass rather than one of their own -- see
			Lucky, which asks about VIP and nothing else.

			Which is why this line is terser than the four perks it sells. The shop
			card's blurb box is 48px and a TextLabel does not clip to its own size, so
			a blurb is only safe at the length the others are: three wrapped lines at
			a 1280-wide window, which is where the narrowest card still reads. Written
			out in full -- "a pay packet waiting every day you log in", "look for the
			gold board on the lawn" -- it needed five, and spilled out of the card.
		]]
		blurb = "A gold kit, a standout name, quicker on your feet, a pay packet"
			.. " daily, and premium jobs worth up to five times the money.",
	},
	--[[[
		The Blueberry Bundle: one pass, two things -- the Blueberry Howl pet and
		the Blueberry Cheesecake sealant color.

		Neither half is sold on its own. The COLOR is event-flagged in ColorCatalog
		(so the color case will not offer it for cash or Robux) and its ownership
		reads this pass through Passes.owns; the PET carries this pass id in its
		roster entry and Pets.owns answers from it the same way. Buying the pass
		therefore grants both at once, and neither can be picked up any other way.
	]]
	{
		id = "BlueberryBundle",
		assetId = 2062001604,
		name = "Blueberry Bundle",
		blurb = "The Blueberry Howl pet -- +30% cash gain, +30% bucket capacity,"
			.. " +20% walk speed -- and the Blueberry Cheesecake color, together.",
	},
}

local ById: { [string]: Pass } = {}
for _, p in ipairs(List) do
	ById[p.id] = p
end

Passes.List = List
Passes.ById = ById

function Passes.attrName(id: string): string
	return "Pass_" .. id
end

--[[
	The question everything else asks.

	Explicitly `== true`, not truthiness: the attribute is nil until PassService
	has answered for this player, and nil has to read as "not yet" rather than as
	anything else. A pass is a thing you have or do not have, and the seconds
	before the answer lands are the ones where the player has not.
]]
function Passes.owns(plr: Player, id: string): boolean
	return plr:GetAttribute(Passes.attrName(id)) == true
end

--[[
	What the player's passes multiply their pay by.

	One function so the three places that price a job -- ScoreModel for the running
	figure on the HUD, Shell for the "Job Reward" line, and DrivewayServer for the
	money that actually lands -- can never disagree about it. A HUD that promises a
	number the wallet does not pay is worse than no HUD.

	⚠ It has to be folded into the SAME `Economy.payout` call as the rebirth
	multiplier, not applied to the result. DrivewayServer clamps its own figure
	against the client's claim at three times -- see the note there -- so a bonus
	added after that clamp is silently clipped off.
]]
function Passes.cashMultiplier(plr: Player?): number
	if not plr then return 1 end
	return if Passes.owns(plr, "DoubleCash") then 2 else 1
end

-- VIP is quicker on their feet. Applied by SealerUIClient on top of the Walk
-- Speed track, so it rides the ladder rather than replacing it.
function Passes.walkMultiplier(plr: Player?): number
	if not plr then return 1 end
	return if Passes.owns(plr, "VIP") then 1.20 else 1
end

return Passes
